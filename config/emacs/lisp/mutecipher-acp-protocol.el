;;; mutecipher-acp-protocol.el --- Protocol method handlers for ACP  -*- lexical-binding: t -*-
;;
;; Inbound JSON-RPC method handlers (fs/read, fs/write, permission) and
;; `session/update' notification handlers.  Two registries expose the
;; declarative extension points:
;;
;; - mutecipher-acp--agent-request-handlers
;;     alist METHOD -> HANDLER-FN; register with
;;     mutecipher-acp-register-agent-request-handler.  --handle-agent-request
;;     does the lookup; new MCP-style or custom agent requests plug in
;;     here without touching the dispatcher.
;;
;; - mutecipher-acp--update-handlers
;;     alist TYPE -> HANDLER-FN for `session/update' notifications;
;;     register with mutecipher-acp-register-update-handler.

;;; Code:

(require 'cl-lib)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-log)
(require 'mutecipher-acp-rpc)
(require 'mutecipher-acp-ewoc)
(require 'mutecipher-acp-tools)
(require 'mutecipher-acp-ui)
(require 'mutecipher-acp-persist)

(declare-function mutecipher-acp--set-state             "mutecipher-acp-session")

;;;; Inbound agent-request dispatcher

(defvar mutecipher-acp--agent-request-handlers nil
  "Alist of (METHOD . HANDLER-FN) for inbound agent-initiated requests.
HANDLER-FN is called as (CONN ID PARAMS) and is responsible for
responding via `mutecipher-acp--respond' or `--respond-error'.")

(defun mutecipher-acp-register-agent-request-handler (method fn)
  "Register FN as the handler for inbound METHOD (a string)."
  (setf (alist-get method mutecipher-acp--agent-request-handlers
                   nil nil #'equal)
        fn))

(defun mutecipher-acp--handle-agent-request (conn id method params)
  "Dispatch an inbound JSON-RPC request from the agent via the registry.
CONN is the connection, ID is the request id to respond to,
METHOD is the method string, PARAMS is the decoded plist."
  (if-let ((fn (cdr (assoc method mutecipher-acp--agent-request-handlers))))
      (funcall fn conn id params)
    (mutecipher-acp--respond-error
     conn id mutecipher-acp--rpc-error-method-not-found
     (format "Method not found: %s" method))))

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
         ;; Pass `kind' so move / switch_mode / fetch render the same
         ;; "from → to" / URL-preferred summary in the prompt as they do
         ;; in the transcript card.  Without it, the generic plist scan
         ;; might surface `:prompt' instead of `:url' for WebFetch.
         (input (and raw (mutecipher-acp--format-tool-input raw 60 kind))))
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
  ;; `list' (not quoted '(...)) so `setf alist-get' can replace built-in
  ;; entries without mutating a read-only literal.
  (list (cons "agent_message_chunk"       #'mutecipher-acp--update-agent-message-chunk)
        (cons "tool_call"                 #'mutecipher-acp--update-tool-call-new)
        (cons "tool_call_update"          #'mutecipher-acp--update-tool-call-update)
        (cons "thought"                   #'mutecipher-acp--update-thought)
        (cons "plan"                      #'mutecipher-acp--update-plan)
        (cons "session_info_update"       #'mutecipher-acp--update-session-info)
        (cons "available_commands_update" #'mutecipher-acp--update-available-commands)
        (cons "current_mode_update"       #'mutecipher-acp--update-current-mode)
        (cons "config_option_update"      #'mutecipher-acp--update-config-option)
        (cons "usage_update"              #'mutecipher-acp--update-usage))
  "Alist of (sessionUpdate-type . handler-fn).
HANDLER-FN is called as (SESSION-ID UPDATE-PLIST).  Register a new
entry with `mutecipher-acp-register-update-handler' to add support for
a new `sessionUpdate' kind without touching the dispatcher.")

(defun mutecipher-acp-register-update-handler (type fn)
  "Register FN as the handler for `sessionUpdate' TYPE (a string)."
  (setf (alist-get type mutecipher-acp--update-handlers
                   nil nil #'equal)
        fn))

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
        (let* ((session  (gethash session-id mutecipher-acp--sessions))
               (loading  (and session (macp-session-loading session)))
               ;; During session/load, the agent replays history via
               ;; `session/update' notifications.  We already hydrated
               ;; the buffer from disk, so suppress the *node-creating*
               ;; kinds (chunk, tool_call, thought, plan) to avoid
               ;; duplicates.  `tool_call_update' is NOT suppressed:
               ;; it mutates an existing node addressed by call-id
               ;; (hydrate populated the index), so in-flight tools
               ;; that finished between disk-save and resume can still
               ;; transition to their terminal state.
               (replay-dup
                (and loading
                     (member type '("agent_message_chunk"
                                    "tool_call"
                                    "thought"
                                    "plan")))))
          (cond
           (replay-dup nil)
           (handler (funcall handler session-id update))
           (type    (let ((inhibit-message t))
                      (message "ACP [%s] update: %s (unhandled)"
                               (mutecipher-acp--id-prefix session-id)
                               type))))
          ;; Persist-dirty bookkeeping is by update type:
          ;;   - `usage_update' is metadata noise — no flag.
          ;;   - session-level updates (mode/info/commands/config)
          ;;     change state that should reach disk but aren't user
          ;;     activity — mark dirty WITHOUT bumping last-active.
          ;;   - everything else is real activity — bump.
          ;; Mark/bump always run; the WRITE is gated by --save-session.
          (when (and handler (not replay-dup))
            (cond
             ((equal type "usage_update")
              nil)
             ((member type '("session_info_update"
                             "available_commands_update"
                             "current_mode_update"
                             "config_option_update"))
              (mutecipher-acp--mark-dirty-by-id session-id))
             (t
              (mutecipher-acp--bump-last-active-by-id session-id))))))))
   (t
    (let ((inhibit-message t))
      (message "ACP notification: %s" method)))))

;; Register the built-in inbound agent-request handlers.
(mutecipher-acp-register-agent-request-handler
 "session/request_permission" #'mutecipher-acp--handle-permission)
(mutecipher-acp-register-agent-request-handler
 "fs/read_text_file"          #'mutecipher-acp--handle-fs-read)
(mutecipher-acp-register-agent-request-handler
 "fs/write_text_file"         #'mutecipher-acp--handle-fs-write)

(provide 'mutecipher-acp-protocol)
;;; mutecipher-acp-protocol.el ends here
