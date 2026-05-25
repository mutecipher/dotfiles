;;; mutecipher-acp.el --- ACP (Agent Client Protocol) client  -*- lexical-binding: t -*-
;;
;; An Emacs client for the Agent Client Protocol — a JSON-RPC interface
;; spoken by coding agents (e.g. claude-code-acp) over stdio NDJSON.
;;
;; Architecture, top to bottom:
;;
;;   • Transport: minimal NDJSON JSON-RPC layer over `make-process'
;;     (Emacs's built-in `jsonrpc.el' uses Content-Length framing, which
;;     ACP does not — hence the custom layer).
;;   • Dispatch:  inbound lines split into responses, agent-initiated
;;     requests (fs/*, session/request_permission), and notifications.
;;   • Session:   `:cwd', `:state', `:current-*' scratch slots, plus
;;     1Hz state-timer for the elapsed-seconds counter.
;;   • Render:    every transcript element is an ewoc node whose data is
;;     a `macp-node' wrapping a kind-specific struct (turn, user,
;;     assistant, thought, tool-call, plan, trailer, notice).
;;     `mutecipher-acp--pp' dispatches on kind to per-kind printers.
;;   • Input:     a paired `mutecipher-acp-input-mode' buffer below the
;;     output window — slash-command + @-file completion, history ring,
;;     dynamic resize.
;;   • Markdown:  a small imperative renderer for assistant prose
;;     (fenced code, headings, blockquotes, tables, checkboxes,
;;     bold/italic/strike, inline links).  Applies via text properties
;;     so it composes with the icon-gutter face overlays.
;;
;; No external dependencies — only built-in Emacs packages plus the
;; `mutecipher-icons' module for tool/status glyphs.

;;; Code:

(require 'cl-lib)
(require 'diff)
(require 'diff-mode)
(require 'ewoc)
(require 'json)
(require 'mutecipher-icons)
(require 'project)
(require 'ring)
(require 'transient)
(require 'url-util)

(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-log)
(require 'mutecipher-acp-rpc)
(require 'mutecipher-acp-markdown)
(require 'mutecipher-acp-ewoc)
(require 'mutecipher-acp-tools)
(require 'mutecipher-acp-completion)

(declare-function completion-preview-insert "completion-preview")

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

(defcustom mutecipher-acp-composer-history-size 50
  "Maximum number of past prompts retained in the composer history ring."
  :type 'integer
  :group 'mutecipher-acp)

;;;; Inbound agent-request dispatcher

(defun mutecipher-acp--handle-agent-request (conn id method params)
  "Dispatch an inbound JSON-RPC request from the agent.
CONN is the connection, ID is the request id to respond to,
METHOD is the method string, PARAMS is the decoded plist."
  (cond
   ((equal method "session/request_permission")
    (mutecipher-acp--handle-permission conn id params))
   ((equal method "fs/read_text_file")
    (mutecipher-acp--handle-fs-read conn id params))
   ((equal method "fs/write_text_file")
    (mutecipher-acp--handle-fs-write conn id params))
   (t
    (mutecipher-acp--respond-error conn id mutecipher-acp--rpc-error-method-not-found
                                    (format "Method not found: %s" method)))))

;;;; fs/* handlers

(defun mutecipher-acp--handle-fs-read (conn id params)
  "Handle an fs/read_text_file request from the agent.
Deferred via `run-at-time' so that `y-or-n-p' runs in the main event loop,
not inside the process filter where interactive prompts are suppressed."
  (let* ((path     (plist-get params :path))
         (session  (mutecipher-acp--session-for-conn conn))
         (cwd      (and session (macp-session-cwd session)))
         (abs-path (if (and path (not (file-name-absolute-p path)) cwd)
                       (expand-file-name path cwd)
                     path)))
    (if (not abs-path)
        (mutecipher-acp--respond-error conn id -32602 "Missing path parameter")
      (run-at-time 0 nil
                   (lambda ()
                     (if (not (y-or-n-p (format "ACP: read %s? " abs-path)))
                         (mutecipher-acp--respond-error conn id mutecipher-acp--rpc-error-server "Read denied by user")
                       (condition-case err
                           (let ((content
                                  (with-temp-buffer
                                    (insert-file-contents abs-path)
                                    (buffer-string))))
                             (mutecipher-acp--respond conn id (list :content content)))
                         (error
                          (mutecipher-acp--respond-error conn id mutecipher-acp--rpc-error-server
                                                          (error-message-string err))))))))))

(defun mutecipher-acp--handle-fs-write (conn id params)
  "Handle an fs/write_text_file request from the agent.
Deferred via `run-at-time' so that `y-or-n-p' runs in the main event loop."
  (let* ((path     (plist-get params :path))
         (content  (plist-get params :content))
         (session  (mutecipher-acp--session-for-conn conn))
         (cwd      (and session (macp-session-cwd session)))
         (abs-path (if (and path (not (file-name-absolute-p path)) cwd)
                       (expand-file-name path cwd)
                     path)))
    (cond
     ((not abs-path)
      (mutecipher-acp--respond-error conn id mutecipher-acp--rpc-error-invalid-params "Missing path parameter"))
     ((not content)
      (mutecipher-acp--respond-error conn id mutecipher-acp--rpc-error-invalid-params "Missing content parameter"))
     (t
      (run-at-time 0 nil
                   (lambda ()
                     (if (not (y-or-n-p (format "ACP: write %s? " abs-path)))
                         (mutecipher-acp--respond-error conn id mutecipher-acp--rpc-error-server "Write denied by user")
                       (condition-case err
                           (progn
                             (make-directory (file-name-directory abs-path) t)
                             (write-region content nil abs-path nil 'silent)
                             (when-let ((buf (find-buffer-visiting abs-path)))
                               (when (not (buffer-modified-p buf))
                                 (with-current-buffer buf
                                   (revert-buffer t t t))))
                             (mutecipher-acp--respond conn id (list)))
                         (error
                          (mutecipher-acp--respond-error conn id mutecipher-acp--rpc-error-server
                                                          (error-message-string err)))))))))))

;;;; Permission handling

(defun mutecipher-acp--option-label (o)
  "Extract a human-readable label from permission option O."
  (or (and (plist-get o :name)  (format "%s" (plist-get o :name)))
      (and (plist-get o :label) (format "%s" (plist-get o :label)))
      (and (plist-get o :title) (format "%s" (plist-get o :title)))
      (and (plist-get o :optionId) (format "%s" (plist-get o :optionId)))
      (and (plist-get o :id)    (format "%s" (plist-get o :id)))
      (format "%s" o)))

(defun mutecipher-acp--option-id (o)
  "Extract the response id from permission option O."
  (or (plist-get o :optionId)
      (plist-get o :id)
      (plist-get o :value)
      (mutecipher-acp--option-label o)))

(defun mutecipher-acp--permission-char-for (label used)
  "Pick a single accelerator char for LABEL, avoiding USED.
Labels beginning with `always' get the uppercase first letter of the
word after `always' (so `Allow' → `a' coexists with `Always Allow' →
`A').  Otherwise the lowercase first letter of the label is preferred.
Falls through to the next unused alphabetic char in the label, or `?'
if every character collides."
  (let* ((case-fold-search t)
         (preferred
          (cond
           ((string-match "\\`always[ _-]+\\([A-Za-z]\\)" label)
            (upcase (aref (match-string 1 label) 0)))
           ((string-match "[A-Za-z]" label)
            (downcase (aref label (match-beginning 0)))))))
    (cond
     ((and preferred (not (memq preferred used))) preferred)
     (t
      (let ((found nil) (i 0))
        (while (and (< i (length label)) (not found))
          (let ((c (downcase (aref label i))))
            (when (and (>= c ?a) (<= c ?z) (not (memq c used)))
              (setq found c)))
          (cl-incf i))
        (or found ??))))))

(defun mutecipher-acp--permission-choices (options)
  "Build (CHOICES . ID-MAP) for `read-multiple-choice' from ACP OPTIONS.
OPTIONS comes off the wire as a JSON array, which Emacs parses as a
vector; we coerce to a list so `dolist' is safe.  CHOICES is the list
of (CHAR LABEL) tuples; ID-MAP is an alist mapping each accelerator
CHAR back to the matching option's optionId."
  (let ((opts    (if (vectorp options) (append options nil) options))
        (used    '())
        (choices '())
        (id-map  '()))
    (dolist (o opts)
      (let* ((label (mutecipher-acp--option-label o))
             (id    (mutecipher-acp--option-id o))
             (char  (mutecipher-acp--permission-char-for label used)))
        (push char used)
        (push (list char label) choices)
        (push (cons char id) id-map)))
    (cons (nreverse choices) (nreverse id-map))))

(defun mutecipher-acp--permission-prompt-string (tc)
  "Build a context-bearing prompt string for the permission of tool-call TC.
Includes the requesting tool's display title and a truncated rendition
of its input — e.g. `[ACP] Bash (npm test)? ' — so the user knows what
they're authorizing without scrolling the transcript."
  (let* ((kind  (plist-get tc :kind))
         (title (plist-get tc :title))
         (raw   (plist-get tc :rawInput))
         (input (and raw (mutecipher-acp--format-tool-input raw 60))))
    (format "[ACP] %s%s? "
            (or title kind "tool")
            (if input (format " (%s)" input) ""))))

(defun mutecipher-acp--handle-permission (conn rpc-id params)
  "Prompt user for permission and send a JSON-RPC response over CONN.
Deferred via `run-at-time' so the prompt runs on the main event loop,
not inside the process filter.  Uses `read-multiple-choice' for keyed
single-keystroke selection and includes the requesting tool's title
and input in the prompt for context."
  (let* ((session-id  (plist-get params :sessionId))
         (options     (plist-get params :options))
         (tc          (plist-get params :toolCall))
         (prior-state (when-let ((s (gethash session-id
                                              mutecipher-acp--sessions)))
                        (macp-session-state s))))
    (mutecipher-acp--set-state session-id 'awaiting-permission)
    (run-at-time
     0 nil
     (lambda ()
       (unwind-protect
           (condition-case _
               (let* ((built     (mutecipher-acp--permission-choices options))
                      (choices   (car built))
                      (id-map    (cdr built))
                      (chosen    (car (read-multiple-choice
                                       (mutecipher-acp--permission-prompt-string tc)
                                       choices)))
                      (chosen-id (cdr (assq chosen id-map))))
                 (mutecipher-acp--respond
                  conn rpc-id
                  (list :outcome (list :outcome "selected"
                                       :optionId chosen-id))))
             (quit
              (mutecipher-acp--respond
               conn rpc-id
               (list :outcome (list :outcome "cancelled")))))
         (mutecipher-acp--set-state session-id
                                     (or prior-state 'thinking)))))))

;;;; Notification dispatcher
;;
;; Each `session/update' arm either adds a node, mutates + invalidates
;; an existing node, or updates session state.  Kinds fill in across
;; plan steps 3–7; unimplemented kinds log to *Messages* so we can
;; observe protocol traffic without rendering.

(defun mutecipher-acp--append-assistant-chunk (session-id text)
  "Append TEXT to SESSION-ID's current assistant node, creating one if needed.
Invalidates only that node so the rest of the transcript is untouched.
Trims leading whitespace off the very first chunk so agents that start
a response with a stray `\\n' don't leave the icon alone on a line."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--with-sticky-tail buf
      (unless mutecipher-acp--ewoc
        (user-error "ACP: no ewoc in session buffer"))
      (let* ((ewoc mutecipher-acp--ewoc)
             (node (macp-session-current-assistant session))
             (inhibit-read-only t))
        (unless node
          (setq node (ewoc-enter-last
                      ewoc
                      (make-macp-node :kind 'assistant
                                      :data (make-macp-assistant :text ""))))
          (setf (macp-session-current-assistant session) node))
        (let* ((msg (macp-node-data (ewoc-data node)))
               (old (or (macp-assistant-text msg) ""))
               (chunk (if (string-empty-p old)
                          (string-trim-left text)
                        text)))
          (setf (macp-assistant-text msg) (concat old chunk)))
        (ewoc-invalidate ewoc node)))))

(defun mutecipher-acp--close-assistant (session-id)
  "Drop SESSION-ID's :current-assistant reference so a new node is entered next."
  (when-let ((session (gethash session-id mutecipher-acp--sessions)))
    (when (macp-session-current-assistant session)
      (setf (macp-session-current-assistant session) nil))))


(defun mutecipher-acp--enter-notice (session-id text &optional face)
  "Enter a notice node in SESSION-ID's ewoc with TEXT and optional FACE."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (ewoc-enter-last
         mutecipher-acp--ewoc
         (make-macp-node :kind 'notice
                         :data (make-macp-notice :text text :face face)))))))

(defun mutecipher-acp--enter-thought (session-id text)
  "Enter a thought node in SESSION-ID's ewoc carrying TEXT."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (ewoc-enter-last
         mutecipher-acp--ewoc
         (make-macp-node :kind 'thought
                         :data (make-macp-thought :text text)))))))

(defun mutecipher-acp--enter-plan (session-id tasks)
  "Enter (or mutate) SESSION-ID's plan node with TASKS.
If the turn already has a plan node, its entries are replaced and the
node is invalidated.  Otherwise a fresh plan node is entered."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t)
            (existing (macp-session-current-plan-node session)))
        (cond
         (existing
          (let ((plan (macp-node-data (ewoc-data existing))))
            (setf (macp-plan-entries plan) tasks)
            (ewoc-invalidate mutecipher-acp--ewoc existing)
            (mutecipher-acp--pulse-node mutecipher-acp--ewoc existing)))
         (t
          (let ((node (ewoc-enter-last
                       mutecipher-acp--ewoc
                       (make-macp-node :kind 'plan
                                       :data (make-macp-plan :entries tasks)))))
            (setf (macp-session-current-plan-node session) node))))))))


;;;; session/update dispatch

(defun mutecipher-acp--update-agent-message-chunk (session-id update)
  "Render an `agent_message_chunk' UPDATE for SESSION-ID."
  (when-let ((s (gethash session-id mutecipher-acp--sessions)))
    (when (eq (macp-session-state s) 'thinking)
      (mutecipher-acp--set-state session-id 'streaming)))
  (let ((text (or (plist-get (plist-get update :content) :text) "")))
    (mutecipher-acp--append-assistant-chunk session-id text)))

(defun mutecipher-acp--update-tool-call-new (session-id update)
  "Handle a new `tool_call' UPDATE for SESSION-ID."
  (mutecipher-acp--enter-tool-call session-id update))

(defun mutecipher-acp--update-tool-call-update (session-id update)
  "Handle a `tool_call_update' UPDATE for SESSION-ID."
  (mutecipher-acp--update-tool-call session-id update))

(defun mutecipher-acp--update-thought (session-id update)
  "Handle a `thought' UPDATE for SESSION-ID."
  (mutecipher-acp--close-assistant session-id)
  (mutecipher-acp--enter-thought session-id
                                  (or (plist-get update :thought) "")))

(defun mutecipher-acp--update-plan (session-id update)
  "Handle a `plan' UPDATE for SESSION-ID."
  (mutecipher-acp--close-assistant session-id)
  (mutecipher-acp--enter-plan session-id (plist-get update :tasks)))

(defun mutecipher-acp--update-session-info (session-id update)
  "Handle a `session_info_update' UPDATE for SESSION-ID — rename the buffer."
  (let* ((title   (plist-get update :title))
         (session (gethash session-id mutecipher-acp--sessions))
         (buf     (and session (macp-session-buffer session))))
    (when (and title buf (buffer-live-p buf))
      (with-current-buffer buf
        (rename-buffer (format "*ACP: %s*" title) t))
      (setf (macp-session-title session) title))))

(defun mutecipher-acp--update-available-commands (session-id update)
  "Handle an `available_commands_update' UPDATE for SESSION-ID."
  (let ((cmds    (plist-get update :availableCommands))
        (session (gethash session-id mutecipher-acp--sessions)))
    (when (and session cmds)
      (setf (macp-session-commands session) cmds))))

(defun mutecipher-acp--apply-mode-change (session new-id)
  "Mutate SESSION's current mode to NEW-ID and refresh the mode-line / echo.
No-op when NEW-ID already matches the session's current mode — the agent
re-emits `current_mode_update' / `config_option_update' on every prompt
turn, and we don't want each turn to repaint the pill and spam the echo."
  (when (and session new-id
             (not (equal new-id (macp-session-current-mode-id session))))
    (setf (macp-session-current-mode-id session) new-id)
    (mutecipher-acp--refresh-mode-line session)
    (let* ((avail (macp-session-available-modes session))
           (m     (and avail (mutecipher-acp--find-mode new-id avail))))
      (message "Mode → %s" (or (and m (plist-get m :name)) new-id)))))

(defun mutecipher-acp--update-current-mode (session-id update)
  "Handle a `current_mode_update' UPDATE for SESSION-ID."
  (mutecipher-acp--apply-mode-change
   (gethash session-id mutecipher-acp--sessions)
   (plist-get update :currentModeId)))

(defun mutecipher-acp--update-config-option (session-id update)
  "Handle a `config_option_update' UPDATE for SESSION-ID.
Currently we only react to the `mode' config; other keys are ignored."
  (let* ((opts     (plist-get update :configOptions))
         (session  (gethash session-id mutecipher-acp--sessions))
         (mode-opt (and opts
                        (cl-find "mode" opts
                                 :key (lambda (o) (plist-get o :id))
                                 :test #'string=)))
         (new-id   (and mode-opt (plist-get mode-opt :currentValue))))
    (when (and session new-id)
      (mutecipher-acp--apply-mode-change session new-id))))

(defun mutecipher-acp--update-usage (_session-id _update)
  "No-op handler for `usage_update' notifications.
Usage stats are captured in `*ACP-log*' for the curious, but they
fire many times per turn and would otherwise drown the echo area —
especially during interactive prompts like permission requests."
  nil)

(defvar mutecipher-acp--update-handlers
  '(("agent_message_chunk"      . mutecipher-acp--update-agent-message-chunk)
    ("tool_call"                . mutecipher-acp--update-tool-call-new)
    ("tool_call_update"         . mutecipher-acp--update-tool-call-update)
    ("thought"                  . mutecipher-acp--update-thought)
    ("plan"                     . mutecipher-acp--update-plan)
    ("session_info_update"      . mutecipher-acp--update-session-info)
    ("available_commands_update". mutecipher-acp--update-available-commands)
    ("current_mode_update"      . mutecipher-acp--update-current-mode)
    ("config_option_update"     . mutecipher-acp--update-config-option)
    ("usage_update"             . mutecipher-acp--update-usage))
  "Alist of (sessionUpdate-type . handler-fn).
HANDLER-FN is called as (SESSION-ID UPDATE-PLIST).  Add an entry to
support a new `sessionUpdate' kind without touching the dispatcher.")

(defun mutecipher-acp--handle-notification (method params)
  "Dispatch an incoming JSON-RPC notification with METHOD and PARAMS.
Unhandled types and non-session-update methods are logged to
`*Messages*' with `inhibit-message' bound so they never pollute the
echo area mid-prompt; diagnostics survive but the user's minibuffer
interactions stay clean."
  (cond
   ((equal method "session/update")
    (let* ((session-id (plist-get params :sessionId))
           (update     (plist-get params :update))
           (type       (and update (plist-get update :sessionUpdate)))
           (handler    (and type (cdr (assoc type
                                             mutecipher-acp--update-handlers)))))
      (when session-id
        (cond
         (handler (funcall handler session-id update))
         (type    (let ((inhibit-message t))
                    (message "ACP [%s] update: %s (unhandled)"
                             (mutecipher-acp--id-prefix session-id)
                             type)))))))
   (t
    (let ((inhibit-message t))
      (message "ACP notification: %s" method)))))

;;;; Connection management

(defun mutecipher-acp--connect (agent-name)
  "Return an existing live connection for AGENT-NAME, or create a new one.
Connections are cached per agent name, NOT per (agent, cwd).  Two
sessions in different working directories share one subprocess; the
agent's cwd is supplied per-session via `session/new', so this is
correct as long as the agent honours that boundary."
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
  "Send session/new to CONN with CWD, call CALLBACK with (session-id buffer) on success."
  (mutecipher-acp--request
   conn "session/new" (list :cwd cwd :mcpServers [])
   :success-fn
   (lambda (result)
     (let* ((session-id   (plist-get result :sessionId))
            (modes-data   (plist-get result :modes))
            (avail-modes  (plist-get modes-data :availableModes))
            (current-mode (plist-get modes-data :currentModeId))
            (buf          (mutecipher-acp--get-or-create-buffer session-id agent-name))
            (session      (mutecipher-acp--make-session
                           :id session-id :conn conn :buffer buf
                           :agent agent-name :cwd cwd
                           :available-modes avail-modes
                           :current-mode-id current-mode)))
       (puthash session-id session mutecipher-acp--sessions)
       (funcall callback session-id buf)))
   :error-fn
   (lambda (err)
     (message "ACP session/new failed: %s" (plist-get err :message)))))

(defun mutecipher-acp--load-session (conn session-id agent-name cwd callback)
  "Resume SESSION-ID via session/load on CONN; call CALLBACK with (session-id buf).
The session struct is created eagerly so replayed notifications have
somewhere to land before the success callback fires."
  (let* ((buf     (mutecipher-acp--get-or-create-buffer session-id agent-name))
         (session (mutecipher-acp--make-session
                   :id session-id :conn conn :buffer buf
                   :agent agent-name :cwd cwd)))
    (puthash session-id session mutecipher-acp--sessions)
    (mutecipher-acp--request
     conn "session/load" (list :sessionId session-id)
     :success-fn (lambda (_) (funcall callback session-id buf))
     :error-fn   (lambda (err)
                   (remhash session-id mutecipher-acp--sessions)
                   (kill-buffer buf)
                   (message "ACP session/load failed: %s"
                            (plist-get err :message))))))

;;;; Pretty-printer dispatch
;;
;; Each kind-specific pretty-printer is self-contained and idempotent:
;; it `insert's the node's rendering at point and ends with exactly one
;; newline.  Ewoc manages the region; we only produce text.
;;
;; Per-kind implementations fill in as later plan steps bring node
;; kinds online.  Unimplemented kinds render a placeholder so stray
;; nodes don't silently break the buffer.

(defun mutecipher-acp--pp (node)
  "Master ewoc pretty-printer: dispatch on NODE kind.
Wraps the per-kind printer so every rendered region is marked
read-only via text properties.  `rear-nonsticky' on the trailing edge
keeps the inline composer (text past the ewoc footer) writable —
characters typed by the user just past the last node do not inherit
the transcript's read-only property."
  (let ((beg (point)))
    (pcase (macp-node-kind node)
      ('turn-header (mutecipher-acp--pp-turn-header node))
      ('user        (mutecipher-acp--pp-user        node))
      ('assistant   (mutecipher-acp--pp-assistant   node))
      ('thought     (mutecipher-acp--pp-thought     node))
      ('tool-call   (mutecipher-acp--pp-tool-call   node))
      ('plan        (mutecipher-acp--pp-plan        node))
      ('trailer     (mutecipher-acp--pp-trailer     node))
      ('notice      (mutecipher-acp--pp-notice      node))
      (other        (insert (format "[acp: unknown node kind: %s]\n" other))))
    (add-text-properties beg (point)
                         '(read-only t
                           front-sticky (read-only)
                           rear-nonsticky (read-only)))))

(defun mutecipher-acp--gutter (icon-kind)
  "Return (PREFIX . INDENT) for a hanging-indent layout keyed by ICON-KIND.
PREFIX is `<glyph> ' for the first display line; INDENT is matching
whitespace so logical-newline and wrapped continuations align under the
body.  Chat-message roles consult `mutecipher-acp-role-glyph-alist'
first for a subtle single-character marker; other kinds fall back to
`mutecipher/icon-for-acp' (Nerd Font), then to a single space."
  (let* ((override (cdr (assq icon-kind mutecipher-acp-role-glyph-alist)))
         (icon
          (cond
           ((and override (stringp (car override)))
            (let ((glyph (car override))
                  (face  (cadr override)))
              (if (string-empty-p glyph)
                  ""
                (propertize glyph 'face face))))
           ((and (fboundp 'mutecipher/icon-for-acp)
                 (mutecipher/icon-for-acp icon-kind)))
           (t " ")))
         (prefix (if (string-empty-p icon) "" (concat icon " ")))
         (indent (make-string (string-width prefix) ?\s)))
    (cons prefix indent)))

(defun mutecipher-acp--insert-with-gutter (icon-kind text &optional face)
  "Insert TEXT at point after ICON-KIND's gutter, with a hanging indent.
If FACE is non-nil, the body is propertized with it.  Returns the
buffer position of the body start — useful for post-processing the
inserted region (e.g. `--apply-markdown')."
  (let* ((g          (mutecipher-acp--gutter icon-kind))
         (body-start (+ (point) (length (car g))))
         (props      (append (and face (list 'face face))
                             (list 'line-prefix (cdr g)
                                   'wrap-prefix (cdr g)))))
    (insert (car g) (apply #'propertize text props))
    body-start))

(defun mutecipher-acp--pp-turn-header (node)
  "Render a turn-header NODE: for turns >1, emit one blank line as a separator."
  (let* ((turn (macp-node-data node))
         (id   (macp-turn-id turn)))
    (when (and id (> id 1))
      (insert "\n"))))

(defun mutecipher-acp--pp-user (node)
  "Render a user NODE: `user' icon gutter + hanging-indent body.
A leading `/word' is overlaid with `mutecipher-acp-slash-command-face'
so invoked slash commands stand out from surrounding prompt text."
  (let* ((text       (or (macp-user-text (macp-node-data node)) ""))
         (body-start (mutecipher-acp--insert-with-gutter
                      'user text 'mutecipher-acp-user-face)))
    (save-excursion
      (goto-char body-start)
      (when (looking-at "/[A-Za-z0-9_-]+")
        (add-face-text-property (match-beginning 0) (match-end 0)
                                'mutecipher-acp-slash-command-face)))
    (insert "\n\n")))

(defun mutecipher-acp--pp-assistant (node)
  "Render an assistant NODE: `assistant' icon gutter + hanging-indent prose.
Applies minimal markdown overlays over the inserted body.  Terminates
with a blank-line spacer so adjacent nodes (including tool-call cards
that follow inline tool invocations) get the same single-line gap as
user → tool-call transitions."
  (let* ((text       (or (macp-assistant-text (macp-node-data node)) ""))
         (body-start (mutecipher-acp--insert-with-gutter 'assistant text)))
    (unless (or (string-empty-p text)
                (eq (aref text (1- (length text))) ?\n))
      (insert "\n"))
    (mutecipher-acp--apply-markdown body-start (point))
    (insert "\n")))

(defun mutecipher-acp--pp-thought (node)
  "Render a thought NODE: `thought' icon gutter + italic shadow-faced text.
Trailing blank line keeps spacing uniform across node kinds."
  (let ((text (or (macp-thought-text (macp-node-data node)) "")))
    (mutecipher-acp--insert-with-gutter 'thought
                                         (concat text "\n")
                                         'mutecipher-acp-thought-face)
    (insert "\n")))


(defun mutecipher-acp--pp-notice (node)
  "Render a notice NODE: `notice' icon gutter + one propertized line."
  (let* ((data (macp-node-data node))
         (text (or (macp-notice-text data) ""))
         (face (or (macp-notice-face data) 'default)))
    (mutecipher-acp--insert-with-gutter 'notice (concat text "\n") face)))

(defun mutecipher-acp--pp-trailer (node)
  "Render a trailer NODE: a single dim line naming the non-normal stop reason."
  (let* ((trailer (macp-node-data node))
         (reason  (macp-trailer-stop-reason trailer))
         (label   (pcase reason
                    ('cancelled  "— cancelled")
                    ('max_tokens "— stopped: max_tokens")
                    ('error      "— error")
                    ('refusal    "— refused")
                    (_           (format "— stopped: %s" reason)))))
    (insert (propertize (concat label "\n")
                        'face 'shadow))))

(defun mutecipher-acp--plan-entry-icon-key (task)
  "Map a plan TASK's `:status' field to a plan-icon key."
  (pcase (plist-get task :status)
    ("completed"   'plan-done)
    ("in_progress" 'plan-inprogress)
    (_             'plan-pending)))

(defun mutecipher-acp--pp-plan (node)
  "Render a plan NODE: `[Plan]' header + per-entry status icon list.
Completed tasks render with strike-through to make progress visible
at a glance."
  (let* ((plan    (macp-node-data node))
         (entries (macp-plan-entries plan)))
    (insert "\n"
            (propertize "[Plan]\n" 'face 'bold))
    (when (and entries (not (eq entries :json-false)))
      (cl-loop for task across entries do
               (let* ((title (or (plist-get task :title)
                                 (plist-get task :content) ""))
                      (done  (equal (plist-get task :status) "completed"))
                      (icon  (mutecipher-acp--icon-or
                              (mutecipher-acp--plan-entry-icon-key task)
                              "•")))
                 (insert "  "
                         icon
                         " "
                         (propertize title
                                     'face (if done '(:strike-through t :inherit shadow)
                                             'default))
                         "\n"))))))


;;;; Session output buffer mode

(defun mutecipher-acp--find-mode (id modes)
  "Return the mode plist with :id ID from MODES, or nil."
  (cl-find id modes :key (lambda (m) (plist-get m :id)) :test #'string=))

(defun mutecipher-acp--mode-indicator (session)
  "Return (icon face mode-name) for SESSION's current mode.
ICON is nil when the mode is unrecognized and the server hasn't yet sent
`:available-modes' — callers treat nil ICON as \"no pill to show\".
When `:available-modes' is populated, MODE-NAME is suffixed with ` (N/M)'
showing the current mode's 1-based position and total count."
  (let* ((mode-id  (or (and session (macp-session-current-mode-id session)) "default"))
         (avail    (and session (macp-session-available-modes session)))
         (lookup-id (if (string-match "#\\(.+\\)$" mode-id)
                        (match-string 1 mode-id)
                      mode-id))
         (entry    (assoc lookup-id mutecipher-acp-mode-indicators))
         (icon     (cond (entry (cadr entry))
                         (avail "?")
                         (t nil)))
         (face     (if entry (caddr entry) 'mutecipher-acp-mode-default-face))
         (base     (and avail
                        (let ((m (mutecipher-acp--find-mode mode-id avail)))
                          (and m (plist-get m :name)))))
         (idx      (and avail (cl-position mode-id avail
                                           :key (lambda (m) (plist-get m :id))
                                           :test #'string=)))
         (name     (cond
                    ((and base idx) (format "%s (%d/%d)" base (1+ idx) (length avail)))
                    (base base)
                    (t nil))))
    (list icon face name)))

(defun mutecipher-acp--session-header-line ()
  "Return the pinned header-line content for a session buffer.
Two-column layout: identity (agent + abbreviated cwd tail) on the left;
state chunk, mode pill, and session-id prefix flush-right."
  (let* ((sid     mutecipher-acp--session-id)
         (session (and sid (gethash sid mutecipher-acp--sessions)))
         (agent   (or (and session (macp-session-agent session)) "?"))
         (cwd     (and session (macp-session-cwd session)))
         (state   (or (and session (macp-session-state session)) 'idle))
         (started (and session (macp-session-state-started-at session)))
         (mi      (mutecipher-acp--mode-indicator session))
         (m-icon  (nth 0 mi))
         (m-face  (nth 1 mi))
         (m-name  (nth 2 mi))
         (sep     (propertize " · " 'face 'mutecipher-acp-hint-face))
         (account-icon (propertize
                        (or (and (fboundp 'mutecipher/icon-for-acp)
                                 (mutecipher/icon-for-acp 'assistant))
                            "")
                        'face 'mutecipher-acp-agent-face))
         (cwd-abbr (and cwd (abbreviate-file-name cwd)))
         (cwd-tail (when cwd-abbr
                     (let* ((segs (split-string cwd-abbr "/" t))
                            (tail (if (> (length segs) 2)
                                      (nthcdr (- (length segs) 2) segs)
                                    segs)))
                       (mapconcat #'identity tail "/"))))
         (left    (concat
                   "  "
                   account-icon
                   " "
                   (propertize agent 'face 'mutecipher-acp-agent-face)
                   (when cwd-tail
                     (concat sep
                             (propertize cwd-tail
                                         'face 'mutecipher-acp-hint-face
                                         'help-echo cwd-abbr)))))
         (state-chunk (mutecipher-acp--state-label state started))
         (mode-pill (when m-icon
                      (propertize (if m-name
                                      (format "%s %s" m-icon m-name)
                                    m-icon)
                                  'face m-face)))
         (id-chunk (if sid
                       (propertize (mutecipher-acp--id-prefix sid)
                                   'face 'shadow)
                     ""))
         (right (concat state-chunk
                        (when mode-pill (concat sep mode-pill))
                        "   "
                        id-chunk)))
    (concat left
            (propertize " " 'display
                        `(space :align-to (- right ,(1+ (string-width right)))))
            right
            " ")))

;; Declared BEFORE `define-derived-mode' so the mode picks up our keymap
;; instead of synthesizing one inheriting from `special-mode-map' (which
;; would remap `self-insert-command' to `undefined' via its
;; `suppress-keymap' setup and block all typing in the composer).
(defvar-keymap mutecipher-acp-session-mode-map
  :doc "Keymap for `mutecipher-acp-session-mode' — transcript above, composer below.
RET / `<return>' send the composer's contents; S-RET, S-<return>, and M-J
insert a literal newline so the composer can grow to multiple lines.
M-p / M-n cycle the per-session composer history.  TAB does the right
thing depending on point: completion-at-point in the composer, toggle
disclosure on a tool-call node, otherwise no-op."
  "RET"        #'mutecipher-acp--composer-send
  "<return>"   #'mutecipher-acp--composer-send
  "S-RET"      #'newline
  "S-<return>" #'newline
  "M-J"        #'newline
  "M-p"        #'mutecipher-acp--composer-history-prev
  "M-n"        #'mutecipher-acp--composer-history-next
  "TAB"        #'mutecipher-acp--tab-dwim
  "<tab>"      #'mutecipher-acp--tab-dwim
  "M-TAB"      #'mutecipher-acp--tab-dwim
  "M-<tab>"    #'mutecipher-acp--tab-dwim
  "<backtab>"  #'mutecipher/acp-cycle-mode
  "C-c TAB"    #'mutecipher/acp-toggle-tool-calls
  "C-c <tab>"  #'mutecipher/acp-toggle-tool-calls
  "C-c C-a"    #'mutecipher/acp-dispatch
  "C-c C-c"    #'mutecipher/acp-cancel
  "C-c C-k"    #'mutecipher/acp-kill-session
  "C-c C-o"    #'mutecipher/acp-set-config)

(define-derived-mode mutecipher-acp-session-mode fundamental-mode "ACP"
  "Single-buffer ACP session: read-only transcript above, inline composer below.
The ewoc renders the transcript and `mutecipher-acp--pp' applies a
`read-only' text-property to every rendered region.  Past the ewoc's
footer, an inline composer region — text with no `read-only' property
— collects the user's in-progress message.  RET dispatches it via
`mutecipher-acp--composer-send'."
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  (goto-address-mode 1)
  (add-to-invisibility-spec 'mutecipher-acp-md-markup)
  (when mutecipher-acp-variable-pitch
    (variable-pitch-mode 1))
  (setq-local header-line-format
              '((:eval (mutecipher-acp--session-header-line))))
  (setq-local mode-line-format
              '((:eval (mutecipher-acp--session-mode-line))))
  (setq-local completion-auto-help 'always)
  (setq-local completion-styles '(basic flex))
  (setq-local completions-format 'one-column)
  (setq-local completions-max-height 12)
  (completion-preview-mode 1)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp--files-capf nil t)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp--commands-capf nil t)
  (add-hook 'post-self-insert-hook
            #'mutecipher-acp--maybe-complete nil t)
  ;; Killing the buffer outside `mutecipher/acp-kill-session' must still
  ;; cancel the state timer + clear the sessions hash.  Without this, a
  ;; 1Hz timer would keep firing forever.
  (add-hook 'kill-buffer-hook
            #'mutecipher-acp--on-session-buffer-killed nil t)
  ;; Create the ewoc on a fresh buffer; NOSEP so each pretty-printer
  ;; owns its own newlines.  Header/footer left empty — we use the
  ;; pinned `header-line-format' above instead of a scrolling banner.
  ;; Immediately install the inline composer at point-max.
  (when (zerop (buffer-size))
    (let ((inhibit-read-only t))
      (setq-local mutecipher-acp--ewoc
                  (ewoc-create #'mutecipher-acp--pp "" "" t))
      (mutecipher-acp--composer-install))))

(defun mutecipher/acp-toggle-tool-call ()
  "Toggle the expanded/collapsed state of the tool-call node at point.
Preserves the surrounding `window-start' so expanding a long tool-call
does not scroll the rest of the conversation off-screen."
  (interactive)
  (let* ((ewoc mutecipher-acp--ewoc)
         (node (and ewoc (ewoc-locate ewoc))))
    (cond
     ((null node)
      (user-error "ACP: no node at point"))
     ((not (eq (macp-node-kind (ewoc-data node)) 'tool-call))
      (user-error "ACP: not on a tool-call"))
     (t
      (let ((wrapper (ewoc-data node)))
        (setf (macp-node-collapsed wrapper)
              (not (macp-node-collapsed wrapper))))
      (mutecipher-acp--with-sticky-window-start (current-buffer)
        (let ((inhibit-read-only t))
          (ewoc-invalidate ewoc node)))))))

(defun mutecipher/acp-toggle-tool-calls ()
  "Toggle the collapsed state of every tool-call in the transcript.
If any tool-call is currently expanded, collapse all of them; otherwise
expand all.  Bound to \\[mutecipher/acp-toggle-tool-calls] in the
session buffer — useful because TAB is reserved for completion in the
composer region."
  (interactive)
  (unless mutecipher-acp--ewoc
    (user-error "ACP: no transcript in this buffer"))
  (let* ((wrappers (ewoc-collect mutecipher-acp--ewoc
                                  (lambda (d)
                                    (eq (macp-node-kind d) 'tool-call))))
         (any-expanded (cl-some (lambda (d) (not (macp-node-collapsed d)))
                                wrappers))
         (new-collapsed (and any-expanded t)))
    (if (null wrappers)
        (message "ACP: no tool calls to toggle")
      (dolist (wrapper wrappers)
        (setf (macp-node-collapsed wrapper) new-collapsed))
      (mutecipher-acp--with-sticky-window-start (current-buffer)
        (let ((inhibit-read-only t))
          (ewoc-refresh mutecipher-acp--ewoc)))
      (message "ACP: %s %d tool call%s"
               (if new-collapsed "collapsed" "expanded")
               (length wrappers)
               (if (= 1 (length wrappers)) "" "s")))))

;;;; Composer
;;
;; The composer region lives past the ewoc's footer in the same buffer.
;; `mutecipher-acp--composer-start' is a marker at the seam.  The
;; transcript region (everything before composer-start) is read-only
;; via text-property; ewoc inserts grow it via `inhibit-read-only'.
;;
;; `mutecipher-acp--with-sticky-tail' captures the composer's text
;; length before an ewoc operation and resets composer-start to
;; `(- (point-max) length)' afterwards, so the marker tracks the seam
;; across transcript growth without competing with the user's typing.
;;
;; Read-only protection: `mutecipher-acp--pp' applies
;; `read-only t' with `rear-nonsticky (read-only)' to every rendered
;; node, so characters typed just past the last node inherit no
;; read-only and stay writable.

(defvar-local mutecipher-acp--composer-start nil
  "Marker at the boundary between the read-only transcript and the
writable composer region.  Insertion-type nil — typing here stays
inside the composer.  Reconciled by `mutecipher-acp--with-sticky-tail'.")

(defvar-local mutecipher-acp--composer-overlay nil
  "Overlay covering the composer region; carries the prompt glyph
in its `before-string' so the glyph never enters the buffer text.")

(defvar-local mutecipher-acp--composer-history nil
  "Per-session ring of past prompts sent from this composer.")

(defvar-local mutecipher-acp--composer-history-index nil
  "Current position in the composer history ring, or nil at a fresh prompt.")

(defvar-local mutecipher-acp--streaming-caret-overlay nil
  "Overlay rendering `mutecipher-acp-composer-cursor-glyph' at the live
assistant node while state is `streaming'.")

(defconst mutecipher-acp--composer-hint
  "RET send · / cmds · @ file · C-c TAB expand · C-c C-a menu"
  "One-shot hint shown in the echo area when a session pane first opens.")

(defun mutecipher-acp--composer-install ()
  "Install the inline composer region at the end of the current buffer.
Adds a one-line read-only separator, places the composer markers,
attaches the prompt-glyph overlay, and seeds an empty history ring.
Called once from `mutecipher-acp-session-mode' on a fresh buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    ;; Read-only newline separator.  `rear-nonsticky (read-only)' ensures
    ;; the first character the user types does NOT inherit read-only.
    (insert (propertize "\n"
                        'read-only t
                        'front-sticky '(read-only)
                        'rear-nonsticky '(read-only)))
    (setq mutecipher-acp--composer-start (copy-marker (point) nil))
    (let ((ov (make-overlay (point) (point-max) nil nil t)))
      (overlay-put ov 'before-string
                   (propertize mutecipher-acp-composer-prompt
                               'face 'mutecipher-acp-prompt-glyph-face))
      (overlay-put ov 'mutecipher-acp-composer t)
      (setq mutecipher-acp--composer-overlay ov))
    (setq mutecipher-acp--composer-history
          (make-ring mutecipher-acp-composer-history-size))
    (setq mutecipher-acp--composer-history-index nil)
    (goto-char (point-max))))

(defun mutecipher-acp--composer-bounds ()
  "Return (START . END) of the writable composer region, or nil if absent."
  (when (and mutecipher-acp--composer-start
             (marker-position mutecipher-acp--composer-start))
    (cons (marker-position mutecipher-acp--composer-start)
          (point-max))))

(defun mutecipher-acp--composer-text ()
  "Return the composer's text trimmed of surrounding whitespace."
  (when-let ((b (mutecipher-acp--composer-bounds)))
    (string-trim (buffer-substring-no-properties (car b) (cdr b)))))

(defun mutecipher-acp--composer-extend-overlay ()
  "Ensure the composer overlay still spans the writable region."
  (when (and (overlayp mutecipher-acp--composer-overlay)
             mutecipher-acp--composer-start)
    (move-overlay mutecipher-acp--composer-overlay
                  (marker-position mutecipher-acp--composer-start)
                  (point-max))))

(defun mutecipher-acp--composer-clear ()
  "Erase the composer's contents without disturbing its markers."
  (when-let ((b (mutecipher-acp--composer-bounds)))
    (let ((inhibit-read-only t))
      (delete-region (car b) (cdr b)))
    (mutecipher-acp--composer-extend-overlay)))

(defun mutecipher-acp--composer-set-text (text)
  "Replace the composer's contents with TEXT.
Used by history navigation and edit-and-resend.  Leaves point at
`point-max' so the cursor stays inside the writable region."
  (mutecipher-acp--composer-clear)
  (when (and text (not (string-empty-p text)))
    (goto-char (point-max))
    (insert text))
  (mutecipher-acp--composer-extend-overlay))

(defun mutecipher-acp--composer-region-p (pos)
  "Non-nil when POS is inside the writable composer region."
  (and mutecipher-acp--composer-start
       (>= pos (marker-position mutecipher-acp--composer-start))))

(defun mutecipher-acp--composer-goto ()
  "Move point to the end of the composer region."
  (goto-char (point-max)))

(defun mutecipher-acp--composer-send ()
  "Send the composer's contents as a prompt to the current ACP session.
Empty input is silently ignored.  Resets the history index so M-p
starts from the most recent entry on the next iteration."
  (interactive)
  (unless (mutecipher-acp--composer-region-p (point))
    (mutecipher-acp--composer-goto)
    (user-error "ACP: jump to composer first"))
  (let ((text (mutecipher-acp--composer-text)))
    (unless (or (null text) (string-empty-p text))
      (when (and mutecipher-acp--composer-history
                 (ring-p mutecipher-acp--composer-history))
        (ring-insert mutecipher-acp--composer-history text))
      (setq mutecipher-acp--composer-history-index nil)
      (mutecipher-acp--composer-clear)
      (mutecipher-acp--do-prompt mutecipher-acp--session-id text))))

(defun mutecipher-acp--composer-history-prev ()
  "Replace composer contents with the previous history entry."
  (interactive)
  (unless (mutecipher-acp--composer-region-p (point))
    (user-error "ACP: jump to composer first"))
  (let* ((ring mutecipher-acp--composer-history)
         (len  (and ring (ring-p ring) (ring-length ring))))
    (when (and len (> len 0))
      (setq mutecipher-acp--composer-history-index
            (if mutecipher-acp--composer-history-index
                (min (1+ mutecipher-acp--composer-history-index) (1- len))
              0))
      (mutecipher-acp--composer-set-text
       (ring-ref ring mutecipher-acp--composer-history-index)))))

(defun mutecipher-acp--composer-history-next ()
  "Replace composer contents with the next history entry, or clear it."
  (interactive)
  (unless (mutecipher-acp--composer-region-p (point))
    (user-error "ACP: jump to composer first"))
  (cond
   ((null mutecipher-acp--composer-history-index))
   ((= mutecipher-acp--composer-history-index 0)
    (setq mutecipher-acp--composer-history-index nil)
    (mutecipher-acp--composer-clear))
   (t
    (cl-decf mutecipher-acp--composer-history-index)
    (mutecipher-acp--composer-set-text
     (ring-ref mutecipher-acp--composer-history
               mutecipher-acp--composer-history-index)))))

(defun mutecipher-acp--maybe-complete ()
  "Trigger completion after `/' or `@' inside the composer."
  (when (and (mutecipher-acp--composer-region-p (point))
             (memq last-command-event '(?/ ?@)))
    (completion-at-point)))

(defun mutecipher-acp--tab-dwim ()
  "TAB inside the composer commits a visible completion preview, else
falls back to `completion-at-point'.  Outside the composer it's a no-op
— use \\[mutecipher/acp-toggle-tool-calls] to fold/unfold tool calls."
  (interactive)
  (cond
   ((not (mutecipher-acp--composer-region-p (point)))
    (message "ACP: TAB is composer-only — use C-c TAB to toggle tool calls"))
   ;; Route through the preview's own commit path so the overlay is
   ;; dismissed in the same step as the insertion — `completion-at-point'
   ;; defers the preview cleanup, briefly double-rendering the suffix.
   ((bound-and-true-p completion-preview-active-mode)
    (completion-preview-insert))
   (t (completion-at-point))))

;;;; State + state-driven display

(defun mutecipher-acp--state-glyph (state elapsed)
  "Return a status glyph for STATE.
Busy states (`thinking', `streaming') cycle through a 4-frame ASCII
rotation keyed off ELAPSED so the user sees motion while the agent
works.  Non-busy states render a steady `●'."
  (pcase state
    ((or 'thinking 'streaming)
     (let ((frames "-\\|/"))
       (string (aref frames (mod (or elapsed 0) (length frames))))))
    (_ "●")))

(defun mutecipher-acp--state-label (state started-at)
  "Render STATE as `<glyph> <label>' propertized with the matching status face.
STARTED-AT is a float-time used for elapsed seconds + glyph rotation."
  (let* ((elapsed (and started-at
                       (max 0 (truncate (- (float-time) started-at)))))
         (glyph   (mutecipher-acp--state-glyph state elapsed))
         (pair
          (pcase state
            ((or 'thinking 'streaming)
             (cons (format "%s %ds" (symbol-name state) (or elapsed 0))
                   'mutecipher-acp-status-busy-face))
            ('awaiting-permission
             (cons "awaiting permission" 'mutecipher-acp-status-await-face))
            ('error
             (cons "error" 'mutecipher-acp-status-error-face))
            (_
             (cons "idle" 'mutecipher-acp-status-idle-face)))))
    (propertize (concat glyph " " (car pair)) 'face (cdr pair))))

(defun mutecipher-acp--session-mode-line ()
  "Return mode-line content for a session buffer (state pill + session id)."
  (let* ((sid     mutecipher-acp--session-id)
         (session (and sid (gethash sid mutecipher-acp--sessions)))
         (state   (or (and session (macp-session-state session)) 'idle))
         (started (and session (macp-session-state-started-at session)))
         (sep     (propertize " · " 'face 'mutecipher-acp-hint-face))
         (state-chunk (mutecipher-acp--state-label state started))
         (id-chunk (when sid
                     (propertize (mutecipher-acp--id-prefix sid)
                                 'face 'shadow))))
    (concat "  "
            state-chunk
            (when id-chunk (concat sep id-chunk))
            " ")))

(defun mutecipher-acp--refresh-mode-line (session)
  "Force a mode-line / header-line redraw in SESSION's buffer.
Replaces the previous `--force-input-mode-line' helper now that the
session lives in a single buffer with no paired input pane."
  (when-let ((buf (and session (macp-session-buffer session))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (force-mode-line-update)))))

(defun mutecipher-acp--update-streaming-caret (session)
  "Show or hide the streaming caret overlay based on SESSION's state."
  (when-let ((buf (and session (macp-session-buffer session))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (overlayp mutecipher-acp--streaming-caret-overlay)
          (delete-overlay mutecipher-acp--streaming-caret-overlay)
          (setq mutecipher-acp--streaming-caret-overlay nil))
        (let ((assist (macp-session-current-assistant session)))
          (when (and assist
                     (eq (macp-session-state session) 'streaming)
                     mutecipher-acp-composer-cursor-glyph)
            (let* ((node-beg (ewoc-location assist))
                   (next     (ewoc-next mutecipher-acp--ewoc assist))
                   (node-end (cond
                              (next (ewoc-location next))
                              (mutecipher-acp--composer-start
                               (marker-position
                                mutecipher-acp--composer-start))
                              (t (point-max)))))
              (when (and node-beg node-end (> node-end node-beg))
                (let* ((pos (max node-beg (1- node-end)))
                       (ov  (make-overlay pos pos)))
                  (overlay-put ov 'after-string
                               (propertize
                                mutecipher-acp-composer-cursor-glyph
                                'face 'mutecipher-acp-streaming-caret-face))
                  (overlay-put ov 'mutecipher-acp-streaming-caret t)
                  (setq mutecipher-acp--streaming-caret-overlay ov))))))))))

;;;; State transitions

(defun mutecipher-acp--set-state (session-id new-state)
  "Transition SESSION-ID to NEW-STATE and refresh the buffer chrome.
Starts a 1Hz timer for `thinking' and `streaming' so the elapsed-
seconds counter ticks; cancels it for every other state.  Updates
the streaming caret so the visible `▌' appears/disappears alongside
the `streaming' state."
  (when-let ((session (gethash session-id mutecipher-acp--sessions)))
    (when-let ((t0 (macp-session-state-timer session)))
      (cancel-timer t0))
    (let* ((busy       (memq new-state '(thinking streaming)))
           (started-at (and busy (float-time)))
           (timer      (and busy
                            (run-at-time
                             1 1
                             (lambda ()
                               (when-let ((s (gethash session-id
                                                       mutecipher-acp--sessions)))
                                 (mutecipher-acp--refresh-mode-line s)))))))
      (setf (macp-session-state session) new-state
            (macp-session-state-started-at session) started-at
            (macp-session-state-timer session) timer)
      (mutecipher-acp--refresh-mode-line session)
      (mutecipher-acp--update-streaming-caret session))))

;;;; Prompt submission

(defun mutecipher-acp--open-turn (session-id user-text)
  "Open a new turn in SESSION-ID: enter turn-header + user nodes for USER-TEXT.
Clears per-turn scratch (`:current-assistant', `:current-plan-node')
and bumps `:turn-counter'.  Returns the turn-header node."
  (let* ((session (gethash session-id mutecipher-acp--sessions))
         (buf     (macp-session-buffer session))
         (counter (1+ (or (macp-session-turn-counter session) 0)))
         (turn    (make-macp-turn :id counter :started-at (float-time)))
         (turn-node nil))
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (setq turn-node (ewoc-enter-last
                         mutecipher-acp--ewoc
                         (make-macp-node :kind 'turn-header :data turn)))
        (ewoc-enter-last
         mutecipher-acp--ewoc
         (make-macp-node :kind 'user
                         :data (make-macp-user :text user-text)))))
    ;; Tool-call ids are turn-local — clear the index so the table
    ;; doesn't grow without bound across long sessions.
    (clrhash (macp-session-tool-call-index session))
    (setf (macp-session-turn-counter session) counter
          (macp-session-current-turn-node session) turn-node
          (macp-session-current-assistant session) nil
          (macp-session-current-plan-node session) nil)
    turn-node))

(defun mutecipher-acp--close-turn (session-id stop-reason)
  "Finalize SESSION-ID's current turn with STOP-REASON, invalidate its header.
Enters a trailer node for any non-normal STOP-REASON."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (node    (macp-session-current-turn-node session))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (let* ((turn (macp-node-data (ewoc-data node))))
      (setf (macp-turn-ended-at   turn) (float-time))
      (setf (macp-turn-stop-reason turn) stop-reason)
      (mutecipher-acp--with-sticky-tail buf
        (let ((inhibit-read-only t))
          (ewoc-invalidate mutecipher-acp--ewoc node)
          (unless (memq stop-reason '(end_turn nil))
            (ewoc-enter-last
             mutecipher-acp--ewoc
             (make-macp-node
              :kind 'trailer
              :data (make-macp-trailer :stop-reason stop-reason)))))))
    (setf (macp-session-current-turn-node session) nil)))

(defun mutecipher-acp--do-prompt (session-id text)
  "Send TEXT as a prompt for SESSION-ID."
  (let* ((session   (gethash session-id mutecipher-acp--sessions))
         (conn      (macp-session-conn session))
         (full-text text))
    (mutecipher-acp--open-turn session-id text)
    (mutecipher-acp--set-state session-id 'thinking)
    (mutecipher-acp--request
     conn "session/prompt"
     (list :sessionId session-id
           :prompt (mutecipher-acp--prompt-blocks
                    full-text (macp-session-cwd session)))
     :success-fn (lambda (result)
                   (let ((reason (or (plist-get result :stopReason) "end_turn")))
                     (mutecipher-acp--close-assistant session-id)
                     (mutecipher-acp--close-turn session-id (intern reason))
                     (mutecipher-acp--set-state session-id 'idle)))
     :error-fn   (lambda (err)
                   (mutecipher-acp--close-assistant session-id)
                   (mutecipher-acp--close-turn session-id 'error)
                   (mutecipher-acp--set-state session-id 'error)
                   (message "ACP: request failed: %s"
                            (or (plist-get err :message) "unknown error"))))))

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

(defun mutecipher-acp--teardown-session (session-id &optional skip-buffer)
  "Cancel SESSION-ID's RPC, drop its timer + entry, and kill its buffer.
When SKIP-BUFFER is non-nil, skip the session buffer (used by the
`kill-buffer-hook' so we don't re-kill the buffer that's already dying)."
  (when-let ((session (gethash session-id mutecipher-acp--sessions)))
    (let ((conn (macp-session-conn session))
          (buf  (macp-session-buffer session)))
      (when (and conn (process-live-p (mutecipher-acp--conn-process conn)))
        (mutecipher-acp--request
         conn "session/cancel"
         (list :sessionId session-id)
         :success-fn (lambda (_) nil)
         :error-fn   (lambda (_) nil)))
      (when-let ((t0 (macp-session-state-timer session)))
        (cancel-timer t0))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (mutecipher-acp--stop-spinner)))
      (remhash session-id mutecipher-acp--sessions)
      (when (and (not skip-buffer) (buffer-live-p buf))
        (kill-buffer buf)))))

(defun mutecipher-acp--on-session-buffer-killed ()
  "`kill-buffer-hook' on session output buffers — tear down the session."
  (when-let ((sid mutecipher-acp--session-id))
    (mutecipher-acp--teardown-session sid 'skip-buffer)))

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
