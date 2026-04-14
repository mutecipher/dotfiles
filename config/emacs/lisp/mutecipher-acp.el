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

(defcustom mutecipher-acp-org-responses t
  "When non-nil, instruct the agent to respond in Org-mode syntax.
Prepends `mutecipher-acp-org-system-prompt' to the first message of each
new session and activates Org font-lock in the session buffer."
  :type 'boolean
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-org-system-prompt
  "Format all your responses using Org-mode syntax:
- Use *, **, *** for headings
- Use #+begin_src LANG ... #+end_src for code blocks (always specify the language)
- Use *bold*, /italic/, ~code~, =verbatim= for inline markup in prose
- Use Org tables where appropriate: always include a space before and after each | separator, e.g. | col 1 | col 2 |, with a hline row of |---+---| after the header; do NOT use inline markup (*~=//) inside table cells as it breaks column alignment
- Do NOT wrap the entire response in a src block; use prose with embedded blocks"
  "System instruction prepended to the first prompt when `mutecipher-acp-org-responses' is enabled."
  :type 'string
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
         ;; Inbound request FROM the agent (has both :id and :method).
         ;; Must be checked before the response branch since it also has :id.
         ((and id method)
          (mutecipher-acp--handle-agent-request conn id method (plist-get msg :params)))
         ;; Response to a request we sent (has :id, no :method)
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

(defun mutecipher-acp--respond (conn id result)
  "Send a JSON-RPC response with ID and RESULT over CONN.
Used to reply to inbound requests from the agent."
  (process-send-string
   (mutecipher-acp--conn-process conn)
   (concat (json-serialize (list :jsonrpc "2.0" :id id :result result)
                           :null-object nil :false-object :json-false)
           "\n")))

(defun mutecipher-acp--respond-error (conn id code message)
  "Send a JSON-RPC error response with ID, error CODE and MESSAGE over CONN."
  (process-send-string
   (mutecipher-acp--conn-process conn)
   (concat (json-serialize (list :jsonrpc "2.0" :id id
                                 :error (list :code code :message message))
                           :null-object nil :false-object :json-false)
           "\n")))

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
    (mutecipher-acp--respond-error conn id -32601
                                   (format "Method not found: %s" method)))))

;;;; fs/* handlers

(defun mutecipher-acp--session-for-conn (conn)
  "Return the session plist for CONN, or nil if none is active."
  (let (found)
    (maphash (lambda (_id session)
               (when (eq (plist-get session :conn) conn)
                 (setq found session)))
             mutecipher-acp--sessions)
    found))

(defun mutecipher-acp--handle-fs-read (conn id params)
  "Handle an fs/read_text_file request from the agent.
Deferred via `run-at-time' so that `y-or-n-p' runs in the main event loop,
not inside the process filter where interactive prompts are suppressed."
  (let* ((path     (plist-get params :path))
         (session  (mutecipher-acp--session-for-conn conn))
         (cwd      (and session (plist-get session :cwd)))
         (abs-path (if (and path (not (file-name-absolute-p path)) cwd)
                       (expand-file-name path cwd)
                     path)))
    (if (not abs-path)
        (mutecipher-acp--respond-error conn id -32602 "Missing path parameter")
      (run-at-time 0 nil
                   (lambda ()
                     (if (not (y-or-n-p (format "ACP: read %s? " abs-path)))
                         (mutecipher-acp--respond-error conn id -32000 "Read denied by user")
                       (condition-case err
                           (let ((content
                                  (with-temp-buffer
                                    (insert-file-contents abs-path)
                                    (buffer-string))))
                             (mutecipher-acp--respond conn id (list :content content))
                             (when session
                               (mutecipher-acp--append
                                (plist-get session :id)
                                (concat "  \u1f4c4 read: " abs-path "\n")
                                'shadow)))
                         (error
                          (mutecipher-acp--respond-error conn id -32000
                                                         (error-message-string err))))))))))

(defun mutecipher-acp--handle-fs-write (conn id params)
  "Handle an fs/write_text_file request from the agent.
Deferred via `run-at-time' so that `y-or-n-p' runs in the main event loop."
  (let* ((path     (plist-get params :path))
         (content  (plist-get params :content))
         (session  (mutecipher-acp--session-for-conn conn))
         (cwd      (and session (plist-get session :cwd)))
         (abs-path (if (and path (not (file-name-absolute-p path)) cwd)
                       (expand-file-name path cwd)
                     path)))
    (cond
     ((not abs-path)
      (mutecipher-acp--respond-error conn id -32602 "Missing path parameter"))
     ((not content)
      (mutecipher-acp--respond-error conn id -32602 "Missing content parameter"))
     (t
      (run-at-time 0 nil
                   (lambda ()
                     (if (not (y-or-n-p (format "ACP: write %s? " abs-path)))
                         (mutecipher-acp--respond-error conn id -32000 "Write denied by user")
                       (condition-case err
                           (progn
                             (make-directory (file-name-directory abs-path) t)
                             (write-region content nil abs-path nil 'silent)
                             ;; Revert if the file is open in an unmodified buffer
                             (when-let ((buf (find-buffer-visiting abs-path)))
                               (when (not (buffer-modified-p buf))
                                 (with-current-buffer buf
                                   (revert-buffer t t t))))
                             (mutecipher-acp--respond conn id (list))
                             (when session
                               (mutecipher-acp--append
                                (plist-get session :id)
                                (concat "  \u270f wrote: " abs-path "\n")
                                'shadow)))
                         (error
                          (mutecipher-acp--respond-error conn id -32000
                                                         (error-message-string err)))))))))))

;;;; State

(defvar mutecipher-acp--connections (make-hash-table :test #'equal)
  "Hash table mapping agent-name strings to mutecipher-acp--conn structs.")

(defvar mutecipher-acp--sessions (make-hash-table :test #'equal)
  "Hash table mapping session-id strings to session plists.
Each plist has :conn, :buffer, :agent, :cwd, :tool-calls, :commands.")

(defvar-local mutecipher-acp--session-id nil
  "Session ID associated with the current ACP session buffer.")

;;;; Session buffer management

(defun mutecipher-acp--id-prefix (session-id)
  "Return the first 8 characters of SESSION-ID for display."
  (substring session-id 0 (min 8 (length session-id))))

(defun mutecipher-acp--buffer-name (agent-name session-id)
  "Return buffer name for AGENT-NAME and SESSION-ID."
  (format "*ACP: %s [%s]*" agent-name (mutecipher-acp--id-prefix session-id)))

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
  "Append TEXT to SESSION-ID's buffer at the end.
Scrolls all visible windows to the end."
  (when-let ((session (gethash session-id mutecipher-acp--sessions)))
    (let ((buf (plist-get session :buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (if face (propertize text 'face face) text))))
        (dolist (win (get-buffer-window-list buf nil t))
          (with-selected-window win
            (goto-char (point-max))))))))

(defun mutecipher-acp--append-line (session-id prefix text &optional face)
  "Append a labelled line \"PREFIX text\n\" to SESSION-ID's buffer."
  (mutecipher-acp--append session-id (concat prefix text "\n") face))

;;;; Notification dispatcher

(defun mutecipher-acp--format-tool-input (raw &optional max-len)
  "Format RAW tool input as a short string for display, truncated to MAX-LEN (default 60).
Handles strings, plists (JSON objects), and vectors."
  (let ((max (or max-len 60)))
    (when raw
      (let ((s (cond
                ((stringp raw) raw)
                ;; Plist (JSON object): grab first string value in order of
                ;; common field names, then any string value
                ((listp raw)
                 (or (and (stringp (plist-get raw :command))  (plist-get raw :command))
                     (and (stringp (plist-get raw :cmd))      (plist-get raw :cmd))
                     (and (stringp (plist-get raw :path))     (plist-get raw :path))
                     (and (stringp (plist-get raw :content))  (plist-get raw :content))
                     ;; Fall back to first string value in the plist
                     (cl-loop for (_k v) on raw by #'cddr
                               when (stringp v) return v)))
                ;; Vector: recurse on first element
                ((vectorp raw) (and (> (length raw) 0)
                                    (mutecipher-acp--format-tool-input (aref raw 0) max))))))
        (when s
          (let* ((s1 (replace-regexp-in-string "\n" "\\\\n" (string-trim s)))
                 (s1 (replace-regexp-in-string "[ \t]+" " " s1)))
            (if (> (length s1) max)
                (concat (substring s1 0 (1- max)) "\u2026")
              s1)))))))

(defun mutecipher-acp--handle-notification (method params)
  "Dispatch incoming JSON-RPC notification METHOD with PARAMS."
  (let ((session-id (plist-get params :sessionId))
        (update     (plist-get params :update)))
    (cond
     ((equal method "session/update")
      (when session-id
        (let ((type (plist-get update :sessionUpdate)))
          (mutecipher-acp--clear-thinking session-id)
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
            (let* ((cc-name (plist-get (plist-get (plist-get update :_meta) :claudeCode) :toolName))
                   (name    (or cc-name (plist-get update :title) (plist-get update :kind) "tool"))
                   (raw-in  (plist-get update :rawInput))
                   (detail  (mutecipher-acp--format-tool-input raw-in))
                   (locs    (plist-get update :locations))
                   (loc-str (when (and locs (> (length locs) 0))
                              (plist-get (aref locs 0) :path)))
                   (session (gethash session-id mutecipher-acp--sessions))
                   (calls   (and session (plist-get session :tool-calls)))
                   (call-id (plist-get update :toolCallId)))
              (mutecipher-acp--append
               session-id
               (concat "\n\u23fa " name
                       (cond (detail  (concat "(" detail ")"))
                             (loc-str (concat "(" loc-str ")"))
                             (t ""))
                       "\n")
               'mutecipher-acp-tool-face)
              ;; Store name + marker so tool_call_update can backfill rawInput
              (when (and call-id calls)
                (let ((buf (plist-get session :buffer)))
                  (with-current-buffer buf
                    (puthash call-id
                             (list :name name :marker (copy-marker (point-max) t))
                             calls))))))
           ((equal type "tool_call_update")
            (let* ((call-id    (plist-get update :toolCallId))
                   (status     (plist-get update :status))
                   (cmd-title  (plist-get update :title))
                   (raw-out    (plist-get update :rawOutput))
                   (session    (gethash session-id mutecipher-acp--sessions))
                   (calls      (and session (plist-get session :tool-calls)))
                   (entry      (and call-id calls (gethash call-id calls)))
                   (marker     (and entry (plist-get entry :marker)))
                   (name       (and entry (plist-get entry :name))))
              ;; First update (no status): title = the actual command — backfill it
              (when (and (null status) cmd-title marker name)
                (let ((buf (plist-get session :buffer)))
                  (with-current-buffer buf
                    (let ((inhibit-read-only t))
                      (save-excursion
                        (goto-char marker)
                        (when (re-search-backward
                               (concat "\u23fa " (regexp-quote name)) nil t)
                          (let ((detail (mutecipher-acp--format-tool-input cmd-title)))
                            (delete-region (point) (line-end-position))
                            (insert (concat "\u23fa " name "(" detail ")")))))))))
              (cond
               ((equal status "completed")
                (let ((out (and raw-out (not (string-empty-p raw-out))
                                (car (split-string raw-out "\n")))))
                  (mutecipher-acp--append
                   session-id
                   (concat "  \u2713" (if out (concat " " out) "") "\n")
                   'shadow)))
               ((equal status "failed")
                (let ((out (and raw-out (not (string-empty-p raw-out))
                                (car (split-string raw-out "\n")))))
                  (mutecipher-acp--append
                   session-id
                   (concat "  \u2718 " (or out "failed") "\n")
                   'mutecipher-acp-error-face))))
              (when (and call-id calls
                         (member status '("completed" "failed")))
                (remhash call-id calls))))
           ((equal type "plan")
            (let* ((tasks (plist-get update :tasks))
                   (lines (if (and tasks (not (eq tasks :json-false)))
                              (mapconcat (lambda (task) (concat "\u2022 " (or (plist-get task :title) "")))
                                         tasks "\n")
                            "")))
              (mutecipher-acp--append session-id "\n[Plan]\n" 'bold)
              (mutecipher-acp--append session-id (concat lines "\n"))))
           ((equal type "session_info_update")
            (let* ((title     (plist-get update :title))
                   (session   (gethash session-id mutecipher-acp--sessions))
                   (buf       (and session (plist-get session :buffer)))
                   (input-buf (and session (plist-get session :input-buffer))))
              (when (and title buf (buffer-live-p buf))
                (with-current-buffer buf
                  (rename-buffer (format "*ACP: %s*" title) t))
                (when (buffer-live-p input-buf)
                  (with-current-buffer input-buf
                    (rename-buffer (format "*ACP-input: %s*" title) t)))
                (puthash session-id
                         (plist-put session :title title)
                         mutecipher-acp--sessions))))
           ((equal type "available_commands_update")
            (let* ((cmds    (plist-get update :commands))
                   (session (gethash session-id mutecipher-acp--sessions)))
              (when (and session cmds)
                (puthash session-id
                         (plist-put session :commands cmds)
                         mutecipher-acp--sessions))))))))
     ((equal method "session/request_permission")
      ;; Fallback: this shouldn't arrive here — permission requests have :id
      ;; and are dispatched via mutecipher-acp--handle-agent-request.
      ;; Log and ignore.
      (message "ACP: unexpected session/request_permission notification")))))

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

(defun mutecipher-acp--handle-permission (conn rpc-id params)
  "Prompt user for permission and send JSON-RPC response with RPC-ID over CONN."
  (let* ((session-id (plist-get params :sessionId))
         (options    (plist-get params :options))
         (labels     (mapcar #'mutecipher-acp--option-label options)))
    ;; Show the permission prompt in the session buffer
    (mutecipher-acp--append
     session-id
     (concat "\n\u26a0 " (or (plist-get params :title) "Permission required") "\n")
     'mutecipher-acp-permission-face)
    (condition-case _
        (let* ((chosen-label (completing-read "[ACP] Permission: " labels nil t))
               (chosen-id    (mutecipher-acp--option-id
                              (seq-find (lambda (o)
                                          (equal (mutecipher-acp--option-label o) chosen-label))
                                        options))))
          (mutecipher-acp--append
           session-id
           (concat "  \u2192 " chosen-label "\n"))
          (mutecipher-acp--respond
           conn rpc-id
           (list :outcome (list :outcome "selected" :optionId chosen-id))))
      ;; C-g or other quit — respond with cancelled so the agent isn't left hanging
      (quit
       (mutecipher-acp--respond
        conn rpc-id
        (list :outcome (list :outcome "cancelled")))))))

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
    ("^\\(\u23fa\\) .*$"
     (1 'mutecipher-acp-tool-face t))
    ;; Tool result lines (indented ✓ / ✗ / …)
    ("^  [\u2713\u2718\u2026] .*$" (0 '(face shadow) t))
    ;; Permission prompt
    ("^\\(\u26a0\\) .*$"
     (1 'mutecipher-acp-permission-face t))
    ;; Error lines
    ("^\\(\u2718\\) .*$"
     (1 'mutecipher-acp-error-face t))
    ;; Plan header
    ("^\\[Plan\\]$" (0 '(face bold) t)))
  "Font-lock keywords for ACP session buffers.")

(defun mutecipher-acp--output-matcher (regexp)
  "Return a font-lock matcher for REGEXP in the output buffer."
  (lambda (limit)
    (re-search-forward regexp limit t)))

(defun mutecipher-acp--table-pipe-matcher (limit)
  "Font-lock matcher for | characters on Org table rows, up to LIMIT."
  (let (found)
    (while (and (not found)
                (< (point) limit)
                (re-search-forward "|" limit t))
      (when (save-excursion (beginning-of-line) (looking-at "|"))
        (setq found t)))
    found))

(defconst mutecipher-acp--org-keywords
  `(;; Headings: hide leading stars (org-hide-leading-stars), bold text
    ;; "** Heading" → first * hidden, second * in shadow, text bold+tall
    (,(mutecipher-acp--output-matcher "^\\(\\**\\)\\(\\*\\) \\(.*\\)$")
     (1 '(face nil invisible mutecipher-acp-markup) t)
     (2 'shadow t)
     (3 '(face (:weight bold :height 1.1)) t))
    ;; Bold *text* — hide markers (org-hide-emphasis-markers)
    (,(mutecipher-acp--output-matcher "\\(\\*\\)\\([^*\n]+\\)\\(\\*\\)")
     (1 '(face nil invisible mutecipher-acp-markup) t)
     (2 'bold t)
     (3 '(face nil invisible mutecipher-acp-markup) t))
    ;; Italic /text/ — hide markers
    (,(mutecipher-acp--output-matcher "\\(/\\)\\([^/\n]+\\)\\(/\\)")
     (1 '(face nil invisible mutecipher-acp-markup) t)
     (2 '(face (:slant italic)) t)
     (3 '(face nil invisible mutecipher-acp-markup) t))
    ;; Inline code ~text~ — hide markers
    (,(mutecipher-acp--output-matcher "\\(~\\)\\([^~\n]+\\)\\(~\\)")
     (1 '(face nil invisible mutecipher-acp-markup) t)
     (2 'font-lock-constant-face t)
     (3 '(face nil invisible mutecipher-acp-markup) t))
    ;; Verbatim =text= — hide markers
    (,(mutecipher-acp--output-matcher "\\(=\\)\\([^=\n]+\\)\\(=\\)")
     (1 '(face nil invisible mutecipher-acp-markup) t)
     (2 'font-lock-string-face t)
     (3 '(face nil invisible mutecipher-acp-markup) t))
    ;; src block delimiters
    (,(mutecipher-acp--output-matcher "^#\\+begin_src\\b.*$") (0 'font-lock-comment-face t))
    (,(mutecipher-acp--output-matcher "^#\\+end_src$")        (0 'font-lock-comment-face t))
    ;; Other #+KEYWORD lines
    (,(mutecipher-acp--output-matcher "^#\\+[A-Za-z_]+:?.*$") (0 'font-lock-preprocessor-face t))
    ;; List items: - item or + item
    (,(mutecipher-acp--output-matcher "^[ \t]*[-+] ")          (0 'font-lock-keyword-face t))
    ;; Table hlines  |---+---|  (full row dimmed)
    (,(mutecipher-acp--output-matcher "^|[-|+:]+|$")
     (0 'shadow t))
    ;; Table | separators — custom matcher walks each | on table lines
    (mutecipher-acp--table-pipe-matcher (0 'shadow t)))
  "Org-mode-inspired font-lock keywords for ACP session buffers.")

(defun mutecipher-acp--fontify-block (lang beg end)
  "Apply LANG's font-lock faces to region BEG..END in the current buffer.
Uses a persistent scratch buffer to avoid reloading the major mode each call.
Does not depend on org-src or org-element."
  (let* ((mode-sym (let ((ts  (intern (concat lang "-ts-mode")))
                         (leg (intern (concat lang "-mode"))))
                     (cond
                      ((and (fboundp ts)
                            (fboundp 'treesit-language-available-p)
                            (treesit-language-available-p (intern lang)))
                       ts)
                      ((fboundp leg) leg))))
         (src-buf (current-buffer)))
    (when mode-sym
      (let ((code (buffer-substring-no-properties beg end)))
        (with-current-buffer
            (get-buffer-create (format " *acp-fontify:%s*" lang))
          (erase-buffer)
          (insert code " ")         ; trailing space avoids partial last token
          (unless (eq major-mode mode-sym)
            (ignore-errors (funcall mode-sym)))
          (font-lock-ensure)
          (let ((pos 1))
            (while (< pos (point-max))
              (let* ((next (or (next-single-property-change pos 'face) (point-max)))
                     (face (get-text-property pos 'face)))
                (when face
                  (with-current-buffer src-buf
                    (let ((inhibit-read-only t))
                      (put-text-property (+ beg (1- pos))
                                         (min (+ beg (1- next)) end)
                                         'face face))))
                (setq pos next)))))))))

(defun mutecipher-acp--align-tables-in-region (beg end-marker)
  "Align all Org tables between BEG and END-MARKER using `org-table-align'.
END-MARKER is a marker so it tracks insertions made during alignment."
  (when (require 'org-table nil t)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char beg)
        (while (and (< (point) (marker-position end-marker))
                    (re-search-forward "^|" (marker-position end-marker) t))
          (beginning-of-line)
          (ignore-errors (org-table-align))
          (ignore-errors (goto-char (org-table-end)))
          (forward-line 1))))))

(defun mutecipher-acp--org-fontify-src-blocks (start end)
  "Fontify #+begin_src...#+end_src blocks in region START to END.
Registered as a jit-lock function in `mutecipher-acp-session-mode'."
  (save-excursion
    (goto-char start)
    (let ((scan-from (or (re-search-backward "^#\\+begin_src" nil t) start)))
      (goto-char scan-from)
      (while (re-search-forward "^#\\+begin_src \\(\\S-+\\)" end t)
        (let* ((lang    (match-string-no-properties 1))
               (blk-beg (1+ (line-end-position)))
               (blk-end (and (re-search-forward "^#\\+end_src" end t)
                             (line-beginning-position))))
          (when (and blk-end (< blk-beg blk-end))
            (mutecipher-acp--fontify-block lang blk-beg blk-end)))))))

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
     (let* ((session-id (plist-get result :sessionId))
            (buf        (mutecipher-acp--get-or-create-buffer session-id agent-name))
            (session    (list :id session-id :conn conn :buffer buf :agent agent-name
                              :cwd cwd
                              :input-buffer nil
                              :org-primed nil
                              :thinking-ov nil
                              :thinking-timer nil
                              :tool-calls (make-hash-table :test #'equal)
                              :commands nil)))
       (puthash session-id session mutecipher-acp--sessions)
       (funcall callback session-id buf)))
   :error-fn
   (lambda (err)
     (message "ACP session/new failed: %s" (plist-get err :message)))))

(defun mutecipher-acp--load-session (conn session-id agent-name cwd callback)
  "Resume SESSION-ID via session/load on CONN; call CALLBACK with (session-id buf)."
  ;; Create the session plist and buffer now so that replayed notifications
  ;; have somewhere to land before the success callback fires.
  ;; :org-primed is intentionally nil here — the system prompt is re-sent on the
  ;; first new message to re-establish Org formatting for the resumed conversation.
  (let* ((buf     (mutecipher-acp--get-or-create-buffer session-id agent-name))
         (session (list :id session-id :conn conn :buffer buf :agent agent-name
                        :cwd cwd
                        :input-buffer nil
                        :org-primed nil
                        :thinking-ov nil
                        :thinking-timer nil
                        :tool-calls (make-hash-table :test #'equal)
                        :commands nil)))
    (puthash session-id session mutecipher-acp--sessions)
    (mutecipher-acp--request
     conn "session/load" (list :sessionId session-id)
     :success-fn (lambda (_) (funcall callback session-id buf))
     :error-fn   (lambda (err)
                   (remhash session-id mutecipher-acp--sessions)
                   (kill-buffer buf)
                   (message "ACP session/load failed: %s"
                            (plist-get err :message))))))

;;;; Major modes

;;; Slash-command completion

(defun mutecipher-acp--commands-capf ()
  "Completion-at-point function for ACP slash commands.
Activates when the current line begins with \"/\"."
  (when-let* ((session-id mutecipher-acp--session-id)
              (session    (gethash session-id mutecipher-acp--sessions))
              (commands   (plist-get session :commands))
              (line-start (save-excursion (beginning-of-line) (point)))
              (_ (save-excursion
                   (beginning-of-line)
                   (looking-at "/"))))
    (let* ((slash-pos (save-excursion (beginning-of-line) (point)))
           (word-end  (point))
           (names     (mapcar (lambda (c)
                                (concat "/" (plist-get c :name)))
                              commands)))
      (list slash-pos word-end names
            :annotation-function
            (lambda (name)
              (when-let* ((cmd (seq-find (lambda (c)
                                           (equal (concat "/" (plist-get c :name)) name))
                                         commands))
                          (desc (plist-get cmd :description)))
                (concat "  " desc)))))))

;;; Session output buffer mode

(define-derived-mode mutecipher-acp-session-mode special-mode "ACP"
  "Read-only output buffer for an ACP session.
Content streams in from the agent; input is handled by a paired
`mutecipher-acp-input-mode' buffer pinned below this window."
  (setq-local truncate-lines nil)
  (setq-local cursor-type nil)
  (font-lock-add-keywords nil mutecipher-acp--session-keywords t)
  (when mutecipher-acp-org-responses
    (font-lock-add-keywords nil mutecipher-acp--org-keywords t)
    (add-to-invisibility-spec 'mutecipher-acp-markup)
    (jit-lock-register #'mutecipher-acp--org-fontify-src-blocks))
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
                             (mutecipher-acp--id-prefix mutecipher-acp--session-id)
                             'face 'shadow))))))

(define-key mutecipher-acp-session-mode-map (kbd "C-c C-c") #'mutecipher/acp-cancel)
(define-key mutecipher-acp-session-mode-map (kbd "C-c C-k") #'mutecipher/acp-kill-session)
(define-key mutecipher-acp-session-mode-map (kbd "C-c C-o") #'mutecipher/acp-set-config)

;;; Input buffer mode

(defvar-local mutecipher-acp--resize-last-size     nil
  "Last `buffer-size' seen by `mutecipher-acp--resize-input'; used to skip no-op resizes.")
(defvar-local mutecipher-acp--input-history       (make-ring 50)
  "Per-session input history ring for `mutecipher-acp-input-mode' buffers.")
(defvar-local mutecipher-acp--input-history-index nil
  "Current position in `mutecipher-acp--input-history', or nil when at the fresh prompt.")

(define-derived-mode mutecipher-acp-input-mode fundamental-mode "ACP-Input"
  "Dynamically-resizing input buffer paired with an ACP session output buffer.
RET sends the buffer contents as a prompt.  S-RET / M-J insert a newline.
M-p / M-n cycle the input history.  C-c C-c cancels; C-c C-k kills the session."
  (setq-local header-line-format
              (propertize "  > " 'face 'mutecipher-acp-user-face))
  (setq-local mode-line-format nil)
  (visual-line-mode 1)
  (add-hook 'post-command-hook #'mutecipher-acp--resize-input nil t)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp--commands-capf nil t))

(defun mutecipher-acp--resize-input ()
  "Grow or shrink the input window to fit the buffer content (1–12 lines)."
  (when-let ((win (get-buffer-window (current-buffer))))
    (let ((size (buffer-size)))
      (unless (eq size mutecipher-acp--resize-last-size)
        (setq mutecipher-acp--resize-last-size size)
        (let ((window-min-height 1))
          (fit-window-to-buffer win 12 1))))))

(defun mutecipher-acp--input-send ()
  "Send the input buffer contents as a prompt to the ACP session."
  (interactive)
  (let ((text (string-trim (buffer-string))))
    (unless (string-empty-p text)
      (ring-insert mutecipher-acp--input-history text)
      (setq mutecipher-acp--input-history-index nil)
      (erase-buffer)
      (mutecipher-acp--do-prompt mutecipher-acp--session-id text))))

(defun mutecipher-acp--input-history-prev ()
  "Replace buffer contents with the previous input history entry."
  (interactive)
  (let ((len (ring-length mutecipher-acp--input-history)))
    (when (> len 0)
      (setq mutecipher-acp--input-history-index
            (if mutecipher-acp--input-history-index
                (min (1+ mutecipher-acp--input-history-index) (1- len))
              0))
      (erase-buffer)
      (insert (ring-ref mutecipher-acp--input-history
                        mutecipher-acp--input-history-index)))))

(defun mutecipher-acp--input-history-next ()
  "Replace buffer contents with the next input history entry, or clear the buffer."
  (interactive)
  (cond
   ((null mutecipher-acp--input-history-index))
   ((= mutecipher-acp--input-history-index 0)
    (setq mutecipher-acp--input-history-index nil)
    (erase-buffer))
   (t
    (cl-decf mutecipher-acp--input-history-index)
    (erase-buffer)
    (insert (ring-ref mutecipher-acp--input-history
                      mutecipher-acp--input-history-index)))))

(let ((map mutecipher-acp-input-mode-map))
  (define-key map (kbd "RET")        #'mutecipher-acp--input-send)
  (define-key map (kbd "<return>")   #'mutecipher-acp--input-send)
  (define-key map (kbd "S-RET")      #'newline)
  (define-key map (kbd "S-<return>") #'newline)
  (define-key map (kbd "M-J")        #'newline)
  (define-key map (kbd "M-p")        #'mutecipher-acp--input-history-prev)
  (define-key map (kbd "M-n")        #'mutecipher-acp--input-history-next)
  (define-key map (kbd "C-c C-c")    #'mutecipher/acp-cancel)
  (define-key map (kbd "C-c C-k")    #'mutecipher/acp-kill-session)
  (define-key map (kbd "C-c C-o")    #'mutecipher/acp-set-config))

(defun mutecipher-acp--input-buffer-name (session-id)
  "Return the input buffer name for SESSION-ID."
  ;; No leading space — this buffer appears in the frame title when focused.
  (format "*ACP-input:%s*" (mutecipher-acp--id-prefix session-id)))

(defun mutecipher-acp--get-or-create-input-buffer (session-id)
  "Return (or create) the input buffer for SESSION-ID."
  (let ((buf (get-buffer-create (mutecipher-acp--input-buffer-name session-id))))
    (with-current-buffer buf
      (unless (derived-mode-p 'mutecipher-acp-input-mode)
        (mutecipher-acp-input-mode)
        (setq mutecipher-acp--session-id session-id)))
    buf))

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
  "Resume an existing ACP session for AGENT-NAME.
Lists sessions via session/list and prompts to choose one,
then loads it via session/load."
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
                                                  (substring sid 0 (min 8 (length sid))))
                                        (substring sid 0 (min 8 (length sid))))
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
  "Display output BUF (top) with a pinned, auto-resizing input buffer (bottom).
The input window starts at 1 line and grows with the user's text."
  (let* ((input-buf (mutecipher-acp--get-or-create-input-buffer session-id)))
    ;; Store input buffer on the session plist so kill-session can find it.
    (when-let ((session (gethash session-id mutecipher-acp--sessions)))
      (puthash session-id
               (plist-put session :input-buffer input-buf)
               mutecipher-acp--sessions))
    (pop-to-buffer-same-window buf)
    (goto-char (point-max))
    (let* ((window-min-height 1)
           (input-win (split-window-below -2)))
      (set-window-buffer input-win input-buf)
      (set-window-dedicated-p input-win t)
      (select-window input-win))))

(defconst mutecipher-acp--spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Braille spinner frames for the thinking indicator.")

(defun mutecipher-acp--show-thinking (session-id)
  "Show an animated thinking indicator at the end of SESSION-ID's buffer."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf)))
    (with-current-buffer buf
      (let* ((pos     (point-max))
             (nframes (length mutecipher-acp--spinner-frames))
             (ov      (make-overlay pos pos buf t nil))
             (frame   0)
             (timer   (run-at-time
                       0 0.1
                       (lambda ()
                         (when (overlay-buffer ov)
                           (overlay-put
                            ov 'before-string
                            (propertize
                             (concat "  "
                                     (aref mutecipher-acp--spinner-frames (% frame nframes))
                                     " thinking...\n")
                             'face 'mutecipher-acp-thought-face))
                           (cl-incf frame)))))
             (updated (plist-put session :thinking-ov ov)))
        (puthash session-id
                 (plist-put updated :thinking-timer timer)
                 mutecipher-acp--sessions)))))

(defun mutecipher-acp--clear-thinking (session-id)
  "Cancel the thinking spinner and remove its overlay for SESSION-ID."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions)))
    (when-let ((timer (plist-get session :thinking-timer)))
      (cancel-timer timer))
    (when-let ((ov (plist-get session :thinking-ov)))
      (delete-overlay ov))
    (let ((updated (plist-put session :thinking-ov nil)))
      (puthash session-id
               (plist-put updated :thinking-timer nil)
               mutecipher-acp--sessions))))

(defun mutecipher-acp--do-prompt (session-id text)
  "Send TEXT as a prompt for SESSION-ID."
  (let* ((session   (gethash session-id mutecipher-acp--sessions))
         (conn      (plist-get session :conn))
         (buf       (plist-get session :buffer))
         (primed    (plist-get session :org-primed))
         (full-text (if (and mutecipher-acp-org-responses (not primed))
                        (progn
                          (puthash session-id
                                   (plist-put session :org-primed t)
                                   mutecipher-acp--sessions)
                          (concat mutecipher-acp-org-system-prompt "\n\n" text))
                      text)))
    (mutecipher-acp--append session-id (concat "> " text "\n") 'mutecipher-acp-user-face)
    (mutecipher-acp--append session-id "\n")
    (mutecipher-acp--show-thinking session-id)
    ;; Capture response start so we can align tables over the completed response.
    (let ((resp-start
           (when (and mutecipher-acp-org-responses buf (buffer-live-p buf))
             (with-current-buffer buf
               (copy-marker (point-max))))))
      (mutecipher-acp--request
       conn "session/prompt"
       (list :sessionId session-id
             :prompt (vector (list :type "text" :text full-text)))
       :success-fn (lambda (_)
                     (mutecipher-acp--clear-thinking session-id)
                     (mutecipher-acp--append session-id "\n\n")
                     ;; Align tables in the completed response region.
                     (when (and resp-start (buffer-live-p buf))
                       (with-current-buffer buf
                         (let ((end-m (copy-marker (point-max))))
                           (mutecipher-acp--align-tables-in-region
                            (marker-position resp-start) end-m)
                           (set-marker end-m nil)))
                       (set-marker resp-start nil)))
       :error-fn   (lambda (err)
                     (mutecipher-acp--clear-thinking session-id)
                     (when resp-start (set-marker resp-start nil))
                     (mutecipher-acp--append
                      session-id
                      (concat "\u2718 " (or (plist-get err :message) "request failed") "\n")))))))

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
  "Kill the current ACP session and its output and input buffers."
  (interactive)
  (let ((session-id (or mutecipher-acp--session-id
                        (mutecipher-acp--pick-session))))
    (unless session-id
      (user-error "ACP: no active session"))
    (let* ((session   (gethash session-id mutecipher-acp--sessions))
           (conn      (plist-get session :conn))
           (buf       (plist-get session :buffer))
           (input-buf (plist-get session :input-buffer)))
      ;; Notify the agent before tearing down locally
      (mutecipher-acp--request
       conn "session/cancel"
       (list :sessionId session-id)
       :success-fn (lambda (_) nil)
       :error-fn   (lambda (_) nil))
      (mutecipher-acp--clear-thinking session-id)
      (remhash session-id mutecipher-acp--sessions)
      (when (buffer-live-p buf)       (kill-buffer buf))
      (when (buffer-live-p input-buf) (kill-buffer input-buf))
      (message "ACP: session %s killed" session-id))))

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
           (conn    (plist-get session :conn)))
      (mutecipher-acp--request
       conn "session/set_config_option"
       (list :sessionId session-id :key key :value value)
       :success-fn (lambda (_) (message "ACP: set %s = %s" key value))
       :error-fn   (lambda (err)
                     (message "ACP set_config_option failed: %s"
                              (plist-get err :message)))))))

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
