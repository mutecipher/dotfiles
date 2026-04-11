;;; mutecipher-acp.el --- ACP (Agent Client Protocol) client  -*- lexical-binding: t -*-
;;
;; Provides an interactive ACP client that communicates with AI coding agents
;; over JSON-RPC 2.0 / stdio using newline-delimited JSON (NDJSON) framing.
;; Agents are spawned as subprocesses; sessions produce a dedicated buffer
;; where responses stream in real time.
;;
;; ACP is described at https://agentclientprotocol.com — it is the LSP for
;; AI coding agents.  This client implements the session flow:
;;
;;   session/new → session/prompt (streaming via session/update notifications)
;;
;; No external dependencies — only built-in Emacs packages.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'mutecipher-markdown)

;;;; Customization

(defgroup mutecipher-acp nil
  "ACP (Agent Client Protocol) client."
  :group 'tools
  :prefix "mutecipher-acp-")

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

;;;; Faces

(defface mutecipher-acp-user-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user prompt labels in ACP session buffers.")

(defface mutecipher-acp-agent-face
  '((t :inherit font-lock-string-face :weight bold))
  "Face for agent response labels in ACP session buffers.")

(defface mutecipher-acp-tool-face
  '((t :inherit font-lock-builtin-face))
  "Face for tool call lines in ACP session buffers.")

(defface mutecipher-acp-thought-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for agent thought/reasoning lines in ACP session buffers.")

(defface mutecipher-acp-permission-face
  '((t :inherit warning :weight bold))
  "Face for permission request lines in ACP session buffers.")

(defface mutecipher-acp-error-face
  '((t :inherit error))
  "Face for error lines in ACP session buffers.")

;;;; NDJSON transport layer
;;
;; ACP uses newline-delimited JSON (one JSON object per line).
;; Emacs's built-in jsonrpc.el uses Content-Length framing (LSP-style),
;; so we implement a minimal custom transport instead.

(cl-defstruct (mutecipher-acp--conn
               (:constructor mutecipher-acp--make-conn))
  process    ; subprocess
  pending    ; hash-table: request-id → (success-fn error-fn)
  notify-fn) ; called as (method params) for incoming notifications

(defvar mutecipher-acp--next-id 0
  "Monotonic counter for JSON-RPC request IDs.")

(defun mutecipher-acp--new-id ()
  "Return the next request ID."
  (cl-incf mutecipher-acp--next-id))

(defun mutecipher-acp--open (agent-name command args env notify-fn)
  "Spawn COMMAND with ARGS and ENV for AGENT-NAME; return a connection struct.
NOTIFY-FN is called as (method params) for incoming JSON-RPC notifications."
  (let* ((process-environment
          (append (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair)))
                          (or env '()))
                  process-environment))
         (proc-buf (get-buffer-create (format " *acp-%s*" agent-name)))
         (err-buf  (get-buffer-create (format " *acp-%s-stderr*" agent-name)))
         (proc (make-process
                :name (format "acp-%s" agent-name)
                :buffer proc-buf
                :command (cons command (or args '()))
                :connection-type 'pipe
                :noquery t
                :coding 'utf-8-unix
                :stderr err-buf))
         (conn (mutecipher-acp--make-conn
                :process proc
                :pending (make-hash-table)
                :notify-fn notify-fn)))
    (set-process-filter proc (mutecipher-acp--make-filter conn))
    (set-process-sentinel proc (mutecipher-acp--make-sentinel conn))
    conn))

(defun mutecipher-acp--make-filter (conn)
  "Return a process filter closure that parses NDJSON for CONN."
  (lambda (proc string)
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))
      (while (search-forward "\n" nil t)
        (let ((line (string-trim (buffer-substring (point-min) (match-end 0)))))
          (delete-region (point-min) (match-end 0))
          (goto-char (point-min))
          (unless (string-empty-p line)
            (mutecipher-acp--dispatch conn line)))))))

(defun mutecipher-acp--make-sentinel (conn)
  "Return a process sentinel closure for CONN."
  (lambda (_proc event)
    (when (string-match-p "\\(exited\\|killed\\|finished\\|broken\\)" event)
      (maphash (lambda (_id cbs)
                 (when (cadr cbs)
                   (funcall (cadr cbs) `(:message "ACP agent process terminated"))))
               (mutecipher-acp--conn-pending conn))
      (clrhash (mutecipher-acp--conn-pending conn)))))

(defun mutecipher-acp--dispatch (conn json-line)
  "Parse JSON-LINE and dispatch to response or notification handler for CONN."
  (condition-case err
      (let* ((msg       (json-parse-string json-line
                                           :object-type 'plist
                                           :null-object nil
                                           :false-object :json-false))
             (id        (plist-get msg :id))
             (method    (plist-get msg :method))
             (result    (plist-get msg :result))
             (rpc-error (plist-get msg :error)))
        (cond
         ;; Response to a request we sent (has :id)
         ((not (null id))
          (when-let ((cbs (gethash id (mutecipher-acp--conn-pending conn))))
            (remhash id (mutecipher-acp--conn-pending conn))
            (if rpc-error
                (when (cadr cbs) (funcall (cadr cbs) rpc-error))
              (when (car cbs) (funcall (car cbs) result)))))
         ;; Incoming notification (has :method, no :id)
         (method
          (when-let ((fn (mutecipher-acp--conn-notify-fn conn)))
            (funcall fn method (plist-get msg :params))))))
    (error
     (message "ACP: JSON parse error (%s)" (error-message-string err)))))

(cl-defun mutecipher-acp--request (conn method params &key success-fn error-fn)
  "Send an async JSON-RPC request over CONN.
METHOD is a string.  PARAMS is a plist or vector.
SUCCESS-FN and ERROR-FN are called with the result/error plist."
  (let* ((id  (mutecipher-acp--new-id))
         (msg (list :jsonrpc "2.0" :id id :method method :params params)))
    (puthash id (list success-fn error-fn) (mutecipher-acp--conn-pending conn))
    (process-send-string
     (mutecipher-acp--conn-process conn)
     (concat (json-serialize msg :null-object nil :false-object :json-false) "\n"))))

;;;; State

(defvar mutecipher-acp--connections (make-hash-table :test #'equal)
  "Hash table mapping agent-name strings to mutecipher-acp--conn structs.")

(defvar mutecipher-acp--sessions (make-hash-table :test #'equal)
  "Hash table mapping session-id strings to session plists.
Each plist has :conn, :buffer, :agent.")

(defvar-local mutecipher-acp--session-id nil
  "Session ID associated with the current ACP session buffer.")

;;;; Session buffer management

(defun mutecipher-acp--buffer-name (agent-name session-id)
  "Return buffer name for AGENT-NAME and SESSION-ID."
  (format "*ACP: %s [%s]*"
          agent-name
          (substring session-id 0 (min 8 (length session-id)))))

(defun mutecipher-acp--get-or-create-buffer (session-id agent-name)
  "Return (or create) the session buffer for SESSION-ID / AGENT-NAME."
  (let* ((name (mutecipher-acp--buffer-name agent-name session-id))
         (buf  (get-buffer-create name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'mutecipher-acp-session-mode)
        (mutecipher-acp-session-mode)
        (setq mutecipher-acp--session-id session-id)))
    buf))

(defun mutecipher-acp--append (session-id text &optional face)
  "Append TEXT to SESSION-ID's buffer, optionally with FACE.
Scrolls any visible window to the end."
  (when-let ((session (gethash session-id mutecipher-acp--sessions)))
    (let ((buf (plist-get session :buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (if face (propertize text 'face face) text)))
          (when-let ((win (get-buffer-window buf t)))
            (with-selected-window win
              (goto-char (point-max)))))))))

(defun mutecipher-acp--append-line (session-id prefix text &optional face)
  "Append a labelled line \"PREFIX text\n\" to SESSION-ID's buffer."
  (mutecipher-acp--append session-id (concat prefix text "\n") face))

;;;; Notification dispatcher

(defun mutecipher-acp--handle-notification (method params)
  "Dispatch incoming JSON-RPC notification METHOD with PARAMS."
  (let ((session-id (plist-get params :sessionId))
        (update     (plist-get params :update)))
    (cond
     ((equal method "session/update")
      (when session-id
        (let ((type (plist-get update :sessionUpdate)))
          (cond
           ((equal type "agent_message_chunk")
            (mutecipher-acp--append
             session-id
             (or (plist-get (plist-get update :content) :text) "")))
           ((equal type "thought")
            (mutecipher-acp--append
             session-id
             (concat (or (plist-get update :thought) "") "\n")
             'mutecipher-acp-thought-face))
           ((equal type "tool_call")
            (mutecipher-acp--append
             session-id
             (concat "\n⏺ " (or (plist-get update :toolName) "tool") "\n")))
           ((equal type "tool_call_update")
            (when-let ((res (plist-get update :result)))
              (mutecipher-acp--append
               session-id
               (concat "  ↳ " (format "%s" res) "\n"))))))))
     ((equal method "session/request_permission")
      (when session-id
        (mutecipher-acp--handle-permission session-id params))))))

(defun mutecipher-acp--handle-permission (session-id params)
  "Prompt user for permission for SESSION-ID."
  (let* ((options      (plist-get params :options))
         (labels       (mapcar (lambda (o) (plist-get o :label)) options))
         (chosen-label (completing-read "[ACP] Permission: " labels nil t))
         (chosen-id    (plist-get
                        (seq-find (lambda (o)
                                    (equal (plist-get o :label) chosen-label))
                                  options)
                        :id)))
    (mutecipher-acp--append
     session-id
     (concat "\n⚠ " chosen-label "\n"))
    (when-let ((session (gethash session-id mutecipher-acp--sessions)))
      (puthash session-id
               (plist-put session :pending-permission chosen-id)
               mutecipher-acp--sessions))))

;;;; Connection management

(defun mutecipher-acp--connect (agent-name)
  "Return an existing live connection for AGENT-NAME, or create a new one."
  (let ((existing (gethash agent-name mutecipher-acp--connections)))
    (if (and existing
             (process-live-p (mutecipher-acp--conn-process existing)))
        existing
      (let* ((spec    (cdr (assoc agent-name mutecipher-acp-agents)))
             (command (plist-get spec :command))
             (args    (plist-get spec :args))
             (env     (plist-get spec :env)))
        (unless command
          (user-error "ACP: no agent named %S in `mutecipher-acp-agents'" agent-name))
        (let ((conn (mutecipher-acp--open
                     agent-name command args env
                     #'mutecipher-acp--handle-notification)))
          (puthash agent-name conn mutecipher-acp--connections)
          conn)))))

;;;; Session font-lock keywords

(defconst mutecipher-acp--session-keywords
  '(;; User message prefix: the > character only
    ("^\\(>\\) "
     (1 'mutecipher-acp-user-face t))
    ;; Tool call lines  ⏺ name
    ("^\\(⏺\\) .*$"
     (1 'mutecipher-acp-tool-face t))
    ;; Tool result lines (indented)
    ("^  ↳ .*$" (0 '(face shadow) t))
    ;; Permission prompt
    ("^\\(⚠\\) .*$"
     (1 'mutecipher-acp-permission-face t))
    ;; Error lines
    ("^\\(✘\\) .*$"
     (1 'mutecipher-acp-error-face t)))
  "Font-lock keywords for ACP session buffers.")

;;;; Protocol helpers

(defun mutecipher-acp--initialize (conn callback)
  "Send ACP initialize to CONN, call CALLBACK with the result."
  (mutecipher-acp--request
   conn "initialize"
   (list :protocolVersion 1)
   :success-fn (lambda (result) (funcall callback result))
   :error-fn   (lambda (err)
                 (message "ACP initialize failed: %s" (plist-get err :message)))))

(defun mutecipher-acp--new-session (conn cwd agent-name callback)
  "Send session/new to CONN, call CALLBACK with (session-id buffer) on success."
  (mutecipher-acp--request
   conn "session/new" (list :cwd cwd :mcpServers [])
   :success-fn
   (lambda (result)
     (let* ((session-id (plist-get result :sessionId))
            (buf        (mutecipher-acp--get-or-create-buffer session-id agent-name))
            (session    (list :conn conn :buffer buf :agent agent-name)))
       (puthash session-id session mutecipher-acp--sessions)
       (funcall callback session-id buf)))
   :error-fn
   (lambda (err)
     (message "ACP session/new failed: %s" (plist-get err :message)))))

;;;; Major modes

;;; Input buffer mode

(defun mutecipher-acp--create-input-buffer (session-id agent-name)
  "Create and return the input buffer for SESSION-ID / AGENT-NAME."
  (let ((buf (get-buffer-create
              (format "*ACP input: %s [%s]*"
                      agent-name
                      (substring session-id 0 (min 8 (length session-id)))))))
    (with-current-buffer buf
      (mutecipher-acp-input-mode)
      (setq mutecipher-acp--session-id session-id))
    buf))

(define-derived-mode mutecipher-acp-input-mode fundamental-mode "ACP-Input"
  "Major mode for the ACP prompt input area.
RET sends the prompt.  S-RET inserts a newline for multi-line input."
  (setq-local header-line-format
              '((:eval (propertize " > " 'face 'mutecipher-acp-user-face))
                (:eval (propertize "RET send" 'face 'bold))
                "  ·  S-RET newline  ·  C-c C-c cancel")))

(define-key mutecipher-acp-input-mode-map (kbd "RET")       #'mutecipher/acp-input-send)
(define-key mutecipher-acp-input-mode-map (kbd "<return>")  #'mutecipher/acp-input-send)
(define-key mutecipher-acp-input-mode-map (kbd "S-RET")     #'newline)
(define-key mutecipher-acp-input-mode-map (kbd "S-<return>") #'newline)
(define-key mutecipher-acp-input-mode-map (kbd "C-c C-c")   #'mutecipher/acp-cancel)

;;;###autoload
(defun mutecipher/acp-input-send ()
  "Send the contents of the current ACP input buffer as a prompt."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
    (unless (string-empty-p text)
      (erase-buffer)
      (mutecipher-acp--do-prompt mutecipher-acp--session-id text))))

;;; Session buffer mode

(define-derived-mode mutecipher-acp-session-mode special-mode "ACP"
  "Major mode for ACP session output buffers.
Content streams in as the agent responds.  The buffer is read-only;
`q' buries it, `C-c C-c' cancels the current request, and `C-c C-k'
kills the session."
  (setq-local truncate-lines nil)
  (setq-local font-lock-extra-managed-props '(display invisible))
  (setq-local font-lock-multiline t)
  (add-hook 'font-lock-extend-region-functions
            #'mutecipher-markdown--extend-region nil t)
  (font-lock-add-keywords nil mutecipher-markdown--keywords t)
  (font-lock-add-keywords nil mutecipher-acp--session-keywords t)
  (visual-line-mode 1)
  (font-lock-mode 1)
  (setq-local mode-line-format
              '((:eval (propertize " ACP " 'face '(:weight bold)))
                " · "
                (:eval (let ((s (gethash mutecipher-acp--session-id
                                         mutecipher-acp--sessions)))
                          (or (and s (plist-get s :agent)) "")))
                "  "
                (:eval (and mutecipher-acp--session-id
                            (propertize
                             (substring mutecipher-acp--session-id 0 8)
                             'face 'shadow))))))

(define-key mutecipher-acp-session-mode-map (kbd "C-c C-c") #'mutecipher/acp-cancel)
(define-key mutecipher-acp-session-mode-map (kbd "C-c C-k") #'mutecipher/acp-kill-session)

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
          (let ((input-buf (mutecipher-acp--create-input-buffer session-id agent-name)))
            (let ((win (display-buffer
                        buf
                        '((display-buffer-reuse-window display-buffer-at-bottom)
                          (window-height . 0.4)))))
              (when win
                (with-selected-window win
                  (let ((input-win (split-window nil -6 'below)))
                    (set-window-buffer input-win input-buf)
                    (set-window-dedicated-p input-win t)
                    (select-window input-win))))))))))))

(defun mutecipher-acp--do-prompt (session-id text)
  "Send TEXT as a prompt for SESSION-ID."
  (let* ((session (gethash session-id mutecipher-acp--sessions))
         (conn    (plist-get session :conn))
         (buf     (plist-get session :buffer)))
    (when (> (buffer-size buf) 0)
      (mutecipher-acp--append session-id "\n"))
    (mutecipher-acp--append session-id (concat "> " text "\n\n"))
    (mutecipher-acp--request
     conn "session/prompt"
     (list :sessionId session-id
           :prompt (vector (list :type "text" :text text)))
     :success-fn (lambda (_) (mutecipher-acp--append session-id "\n"))
     :error-fn   (lambda (err)
                   (mutecipher-acp--append
                    session-id
                    (concat "✘ " (or (plist-get err :message) "request failed") "\n"))))))

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
           (conn    (plist-get session :conn)))
      (mutecipher-acp--request
       conn "session/cancel"
       (list :sessionId session-id)
       :success-fn (lambda (_) (message "ACP: cancelled"))
       :error-fn   (lambda (_) (message "ACP: cancel failed"))))))

;;;###autoload
(defun mutecipher/acp-kill-session ()
  "Kill the current ACP session and its buffer."
  (interactive)
  (let ((session-id (or mutecipher-acp--session-id
                        (mutecipher-acp--pick-session))))
    (unless session-id
      (user-error "ACP: no active session"))
    (let* ((session (gethash session-id mutecipher-acp--sessions))
           (buf     (plist-get session :buffer)))
      (remhash session-id mutecipher-acp--sessions)
      (when (buffer-live-p buf)
        (kill-buffer buf))
      (message "ACP: session %s killed" session-id))))

;;;; Helper

(defun mutecipher-acp--pick-session ()
  "Return a session-id string, or nil if none exist.
If exactly one session is active, return it.  If multiple, prompt."
  (let ((ids (hash-table-keys mutecipher-acp--sessions)))
    (cond
     ((null ids)         nil)
     ((= 1 (length ids)) (car ids))
     (t (completing-read "ACP session: " ids nil t)))))

(provide 'mutecipher-acp)
;;; mutecipher-acp.el ends here
