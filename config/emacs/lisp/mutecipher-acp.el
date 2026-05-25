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
(require 'mutecipher-acp-composer)
(require 'mutecipher-acp-ui)

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

;;;; session/update dispatch
;;
;; Each `session/update' arm either adds a node, mutates + invalidates
;; an existing node, or updates session state.  Unimplemented kinds log
;; to *Messages* so we can observe protocol traffic without rendering.

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
