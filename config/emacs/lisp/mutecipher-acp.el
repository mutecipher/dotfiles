;;; mutecipher-acp.el --- ACP (Agent Client Protocol) client  -*- lexical-binding: t -*-
;;
;; An Emacs client for the Agent Client Protocol — a JSON-RPC interface
;; spoken by coding agents (e.g. claude-code-acp) over stdio NDJSON.
;;
;; Layout (each submodule provides its own feature):
;;
;;   faces       — defgroup, 23 faces, presentation customs
;;   model       — cl-defstructs (macp-node, -turn, -user, -assistant,
;;                 -thought, -tool-call, -plan, -trailer, -notice,
;;                 -session) and the session/connection hash tables
;;   log         — *ACP-log* buffer + summarizer + log commands
;;   rpc         — NDJSON JSON-RPC transport (no Content-Length framing,
;;                 unlike built-in jsonrpc.el)
;;   markdown    — 11 markdown passes driven by --md-passes; extensible
;;                 via mutecipher-acp-register-md-pass
;;   ewoc        — sticky-tail macros, --pp dispatcher (registry of
;;                 node kinds, register with -register-node-kind),
;;                 gutter + non-tool-call per-kind printers
;;   tools       — tool-call ingest/update, raw-input/output handling,
;;                 unified diff with file-line anchoring, spinner timer,
;;                 tool-call card pretty-printer
;;   completion  — @-file capf, file cache, attachment extraction,
;;                 slash-command capf + local registry
;;   composer    — inline composer (writable region past the ewoc),
;;                 history ring, send pipeline with the
;;                 composer-send-functions abnormal hook and local
;;                 slash-command interception
;;   ui          — session major mode, header-line, mode-line, state
;;                 glyph, streaming caret, tool-call disclosure cmds
;;   protocol    — inbound agent-request and session/update handlers,
;;                 each backed by a registry
;;   session     — connect / new / load / state machine / prompt / teardown
;;
;; This entry point requires every submodule and defines the public
;; `mutecipher/acp-*' interactive commands plus the transient menu.

;;; Code:

(require 'transient)
;; Submodules only `(declare-function mutecipher/icon-for-acp ...)' and
;; fall back to ASCII via `(fboundp ...)' if the feature is absent.
;; Require it here so glyphs are guaranteed when this package is loaded
;; in isolation (e.g. `emacs -Q -l mutecipher-acp').
(require 'mutecipher-icons)

(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-log)
(require 'mutecipher-acp-rpc)
(require 'mutecipher-acp-markdown)
(require 'mutecipher-acp-ewoc)
(require 'mutecipher-acp-tools)
(require 'mutecipher-acp-completion)
(require 'mutecipher-acp-composer)
(require 'mutecipher-acp-ui)
(require 'mutecipher-acp-protocol)
(require 'mutecipher-acp-session)

;;;; Customization

(defcustom mutecipher-acp-agents '()
  "Alist mapping agent names to launch plists.
Each element has the form (NAME :command CMD :args ARGS :env ENV) where
NAME is a string, CMD is the executable, ARGS is a list of strings, and
ENV is an optional alist of (VAR . VALUE) pairs for the subprocess
environment.

Example:
  ((\"claude\" :command \"claude-agent-acp\" :args ()))"
  :type '(alist :key-type string
                :value-type (plist :key-type symbol :value-type sexp))
  :group 'mutecipher-acp)


;;;; Public interactive commands

;;;###autoload
(defun mutecipher/acp-start (agent-name)
  "Start an ACP session with AGENT-NAME.
Spawns the agent process, creates a session via session/new, opens the
session buffer, and pins a small input buffer below it."
  (interactive
   (list (completing-read "ACP agent: "
                          (mapcar #'car mutecipher-acp-agents)
                          nil t)))
  (let* ((conn (mutecipher-acp--connect agent-name))
         (cwd  (expand-file-name default-directory)))
    (mutecipher-acp--initialize
     conn
     (lambda (_)
       (mutecipher-acp--new-session
        conn cwd agent-name
        (lambda (session-id buf)
          (message "ACP: session started (%s)" session-id)
          (mutecipher-acp--open-pane session-id buf agent-name)))))))

;;;###autoload
(defun mutecipher/acp-resume (agent-name)
  "Resume an existing ACP session for AGENT-NAME."
  (interactive
   (list (completing-read "ACP agent: "
                          (mapcar #'car mutecipher-acp-agents)
                          nil t)))
  (let* ((conn (mutecipher-acp--connect agent-name))
         (cwd  (expand-file-name default-directory)))
    (mutecipher-acp--initialize
     conn
     (lambda (_)
       (mutecipher-acp--request
        conn "session/list" (list)
        :success-fn
        (lambda (result)
          (let* ((sessions (or result []))
                 (entries  (mapcar
                            (lambda (s)
                              (let ((sid   (plist-get s :sessionId))
                                    (title (plist-get s :title)))
                                (cons (if title
                                          (format "%s  [%s]" title
                                                  (mutecipher-acp--id-prefix sid))
                                        (mutecipher-acp--id-prefix sid))
                                      sid)))
                            sessions)))
            (if (null entries)
                (message "ACP: no existing sessions for %s" agent-name)
              (let* ((choice     (completing-read "Resume session: "
                                                  (mapcar #'car entries) nil t))
                     (session-id (cdr (assoc choice entries))))
                (mutecipher-acp--load-session
                 conn session-id agent-name cwd
                 (lambda (sid buf)
                   (message "ACP: resumed session (%s)" sid)
                   (mutecipher-acp--open-pane sid buf agent-name)))))))
        :error-fn
        (lambda (err)
          (message "ACP session/list failed: %s" (plist-get err :message))))))))

(defun mutecipher-acp--open-pane (session-id buf _agent-name)
  "Open the session BUF for SESSION-ID in the current window.
Single-buffer model: the ewoc-rendered transcript plus the inline
composer share one buffer.  Cursor is parked in the composer so the
user can type immediately.  A one-shot key hint is echoed."
  (pop-to-buffer-same-window buf)
  (with-current-buffer buf
    (unless mutecipher-acp--session-id
      (setq mutecipher-acp--session-id session-id))
    (mutecipher-acp--composer-goto))
  (let ((message-log-max nil))
    (message "%s" (propertize mutecipher-acp--composer-hint
                              'face 'mutecipher-acp-hint-face))))

;;;###autoload
(defun mutecipher/acp-prompt (text)
  "Send TEXT as a prompt to the most recently started ACP session."
  (interactive "sACP prompt: ")
  (let ((session-id (mutecipher-acp--pick-session)))
    (unless session-id
      (user-error "ACP: no active session"))
    (mutecipher-acp--do-prompt session-id text)))

;;;###autoload
(defun mutecipher/acp-prompt-region (beg end)
  "Send the active region (BEG to END) as a prompt to the current ACP session."
  (interactive "r")
  (unless (use-region-p)
    (user-error "ACP: no region selected"))
  (mutecipher/acp-prompt (buffer-substring-no-properties beg end)))

;;;###autoload
(defun mutecipher/acp-cancel ()
  "Cancel the ongoing ACP request for the current session."
  (interactive)
  (let ((session-id (or mutecipher-acp--session-id
                        (mutecipher-acp--pick-session))))
    (unless session-id
      (user-error "ACP: no active session"))
    (let* ((session (gethash session-id mutecipher-acp--sessions))
           (conn    (macp-session-conn session)))
      (mutecipher-acp--request
       conn "session/cancel"
       (list :sessionId session-id)
       :success-fn (lambda (_) (message "ACP: cancelled"))
       :error-fn   (lambda (_) (message "ACP: cancel failed"))))))

;;;###autoload
(defun mutecipher/acp-kill-session ()
  "Kill the current ACP session and its output and input buffers."
  (interactive)
  (let ((session-id (or mutecipher-acp--session-id
                        (mutecipher-acp--pick-session))))
    (unless session-id
      (user-error "ACP: no active session"))
    (mutecipher-acp--teardown-session session-id)
    (message "ACP: session %s killed" session-id)))

;;;###autoload
(defun mutecipher/acp-set-config (key value)
  "Set a session config option KEY to VALUE for the current ACP session."
  (interactive
   (let* ((k (completing-read "Config key: "
                              '("model" "mode" "thoughtLevel") nil nil))
          (v (read-string (format "Value for %s: " k))))
     (list k v)))
  (let ((session-id (or mutecipher-acp--session-id
                        (mutecipher-acp--pick-session))))
    (unless session-id
      (user-error "ACP: no active session"))
    (let* ((session (gethash session-id mutecipher-acp--sessions))
           (conn    (macp-session-conn session)))
      (mutecipher-acp--request
       conn "session/set_config_option"
       (list :sessionId session-id :configId key :value value)
       :success-fn (lambda (_) (message "ACP: set %s = %s" key value))
       :error-fn   (lambda (err)
                     (message "ACP set_config_option failed: %s"
                              (plist-get err :message)))))))

;;;###autoload
(defun mutecipher/acp-set-model (value)
  "Set the current session's model to VALUE."
  (interactive "sModel: ")
  (mutecipher/acp-set-config "model" value))

;;;###autoload
(defun mutecipher/acp-set-mode (value)
  "Set the current session's mode to VALUE."
  (interactive "sMode: ")
  (mutecipher/acp-set-config "mode" value))

;;;###autoload
(defun mutecipher/acp-cycle-mode ()
  "Cycle the current session's mode through server-provided available modes."
  (interactive)
  (let ((session-id (or mutecipher-acp--session-id
                        (mutecipher-acp--pick-session))))
    (unless session-id (user-error "ACP: no active session"))
    (let* ((session (gethash session-id mutecipher-acp--sessions))
           (conn    (macp-session-conn session))
           (modes   (macp-session-available-modes session)))
      (when (zerop (length modes)) (user-error "ACP: no mode list from server"))
      (let* ((current (or (macp-session-current-mode-id session)
                          (plist-get (aref modes 0) :id)))
             (ids     (mapcar (lambda (m) (plist-get m :id)) modes))
             (idx     (or (cl-position current ids :test #'string=) 0))
             (next    (aref modes (mod (1+ idx) (length modes))))
             (next-id (plist-get next :id)))
        (mutecipher-acp--request
         conn "session/set_config_option"
         (list :sessionId session-id :configId "mode" :value next-id)
         :success-fn (lambda (_) nil)
         :error-fn   (lambda (_err)
                       (setf (macp-session-available-modes session)
                             (cl-remove-if
                              (lambda (m) (string= (plist-get m :id) next-id))
                              (macp-session-available-modes session)))
                       (let ((mutecipher-acp--session-id session-id))
                         (mutecipher/acp-cycle-mode))))))))

;;;###autoload
(defun mutecipher/acp-set-thought-level (value)
  "Set the current session's thoughtLevel to VALUE."
  (interactive "sThought level: ")
  (mutecipher/acp-set-config "thoughtLevel" value))

;;;###autoload
(defun mutecipher/acp-list-sessions ()
  "Pick an active ACP session and switch to its output buffer."
  (interactive)
  (let ((sessions (hash-table-values mutecipher-acp--sessions)))
    (unless sessions
      (user-error "ACP: no active sessions"))
    (let* ((entries (mapcar
                     (lambda (s)
                       (cons (format "%-10s  %-20s  %s"
                                     (or (macp-session-agent s) "?")
                                     (or (macp-session-state s) 'idle)
                                     (mutecipher-acp--id-prefix (macp-session-id s)))
                             (macp-session-id s)))
                     sessions))
           (choice  (completing-read "ACP session: "
                                     (mapcar #'car entries) nil t))
           (sid     (cdr (assoc choice entries))))
      (when-let* ((s   (gethash sid mutecipher-acp--sessions))
                  (buf (macp-session-buffer s)))
        (pop-to-buffer buf)))))

;;;###autoload (autoload 'mutecipher/acp-dispatch "mutecipher-acp" nil t)
(transient-define-prefix mutecipher/acp-dispatch ()
  "Dispatch menu for ACP session commands."
  ["Session"
   ("n" "New"           mutecipher/acp-start)
   ("r" "Resume"        mutecipher/acp-resume)
   ("l" "List / switch" mutecipher/acp-list-sessions)
   ("c" "Cancel"        mutecipher/acp-cancel)
   ("k" "Kill"          mutecipher/acp-kill-session)]
  ["Config"
   ("m" "Model"         mutecipher/acp-set-model)
   ("M" "Mode"          mutecipher/acp-set-mode)
   ("t" "Thought level" mutecipher/acp-set-thought-level)
   ("o" "Other option"  mutecipher/acp-set-config)]
  ["Debug"
   ("L" "Show log"        mutecipher/acp-show-log)
   ("C" "Clear log"       mutecipher/acp-clear-log)
   ("F" "Cycle log format" mutecipher/acp-cycle-log-format)
   ("N" "Toggle log noise" mutecipher/acp-toggle-log-noise)]
  ["Help"
   ("?" "Describe mode" describe-mode)])

;;;; Helper

(defun mutecipher-acp--pick-session ()
  "Return a session-id string, or nil if none exist."
  (let ((ids (hash-table-keys mutecipher-acp--sessions)))
    (cond
     ((null ids)         nil)
     ((= 1 (length ids)) (car ids))
     (t (completing-read "ACP session: " ids nil t)))))

(provide 'mutecipher-acp)
;;; mutecipher-acp.el ends here
