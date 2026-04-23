;;; mutecipher-acp2.el --- ACP client, ewoc-based rewrite (WIP)  -*- lexical-binding: t -*-
;;
;; Parallel module under development — the ewoc-based successor to
;; `mutecipher-acp'.  The RPC transport, agents alist, @-mention
;; machinery, and input-buffer UX match the current module exactly;
;; rendering will move onto `ewoc' so each turn, message, tool-call,
;; and plan is an addressable, independently re-renderable node.
;;
;; This file is scaffolding — step 1 of the plan at
;; ~/.claude/plans/we-had-a-discussion-wise-pond.md.  Incoming ACP
;; notifications currently log to *Messages*; rendering lands in
;; subsequent steps.  Both modules coexist during development: the old
;; `C-c A' bindings keep working, this module sits under `C-c A 2'.
;;
;; No external dependencies — only built-in Emacs packages.

;;; Code:

(require 'cl-lib)
(require 'diff)
(require 'ewoc)
(require 'json)
(require 'project)
(require 'ring)
(require 'transient)
(require 'url-util)

;;;; Customization

(defgroup mutecipher-acp2 nil
  "ACP (Agent Client Protocol) client, ewoc-based rewrite."
  :group 'tools
  :prefix "mutecipher-acp2-")

(defcustom mutecipher-acp2-agents '()
  "Alist mapping agent names to launch plists.
Each element has the form (NAME :command CMD :args ARGS :env ENV) where
NAME is a string, CMD is the executable, ARGS is a list of strings, and
ENV is an optional alist of (VAR . VALUE) pairs for the subprocess
environment.

Example:
  ((\"claude\" :command \"claude-agent-acp\" :args ()))"
  :type '(alist :key-type string
                :value-type (plist :key-type symbol :value-type sexp))
  :group 'mutecipher-acp2)

(defcustom mutecipher-acp2-org-responses t
  "When non-nil, instruct the agent to respond in Org-mode syntax.
Prepends `mutecipher-acp2-org-system-prompt' to the first message of
each new session and activates Org font-lock in the session buffer."
  :type 'boolean
  :group 'mutecipher-acp2)

(defcustom mutecipher-acp2-org-system-prompt
  "Format all your responses using Org-mode syntax:
- Use *, **, *** for headings
- Use #+begin_src LANG ... #+end_src for code blocks (always specify the language)
- Use *bold*, /italic/, ~code~, =verbatim= for inline markup in prose
- Use Org tables where appropriate: always include a space before and after each | separator, e.g. | col 1 | col 2 |, with a hline row of |---+---| after the header; do NOT use inline markup (*~=//) inside table cells as it breaks column alignment
- Do NOT wrap the entire response in a src block; use prose with embedded blocks"
  "System instruction prepended to the first prompt when `mutecipher-acp2-org-responses' is enabled."
  :type 'string
  :group 'mutecipher-acp2)

(defcustom mutecipher-acp2-diff-max-lines 500
  "Maximum old/new line count before inline tool-call diffs are summarized.
When either side of a diff exceeds this, the diff body is skipped and a
single summary line is shown instead."
  :type 'integer
  :group 'mutecipher-acp2)

(defcustom mutecipher-acp2-log-max-line 800
  "Maximum characters shown per log line in `*ACP2-log*'.
Longer entries are truncated with a `…(+N chars)' tail so file contents
and large payloads don't bloat the buffer."
  :type 'integer
  :group 'mutecipher-acp2)

(defcustom mutecipher-acp2-log-keep-lines 5000
  "Maximum lines retained in `*ACP2-log*'; older lines are trimmed."
  :type 'integer
  :group 'mutecipher-acp2)

;;;; Faces

(defface mutecipher-acp2-user-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user prompt labels in ACP session buffers.")

(defface mutecipher-acp2-agent-face
  '((t :inherit font-lock-string-face :weight bold))
  "Face for agent response labels in ACP session buffers.")

(defface mutecipher-acp2-tool-face
  '((t :inherit font-lock-builtin-face))
  "Face for tool call lines in ACP session buffers.")

(defface mutecipher-acp2-thought-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for agent thought/reasoning lines in ACP session buffers.")

(defface mutecipher-acp2-permission-face
  '((t :inherit warning :weight bold))
  "Face for permission request lines in ACP session buffers.")

(defface mutecipher-acp2-error-face
  '((t :inherit error))
  "Face for error lines in ACP session buffers.")

(defface mutecipher-acp2-banner-face
  '((t :inherit shadow))
  "Face for the session welcome banner and trailing divider rule.")

(defface mutecipher-acp2-status-idle-face
  '((t :inherit success))
  "Mode-line face used when the session is idle.")

(defface mutecipher-acp2-status-busy-face
  '((t :inherit font-lock-comment-face))
  "Mode-line face used while the agent is thinking or streaming.")

(defface mutecipher-acp2-status-await-face
  '((t :inherit warning))
  "Mode-line face used while awaiting a permission decision.")

(defface mutecipher-acp2-status-error-face
  '((t :inherit error))
  "Mode-line face used after a request errors.")

(defface mutecipher-acp2-hint-face
  '((t :inherit shadow))
  "Face for dimmed hint/help text in input and header lines.")

;;;; Data model
;;
;; Every visible thing in the transcript buffer is an ewoc node whose
;; `data' is a `macp-node'.  The master pretty-printer
;; `mutecipher-acp2--pp' dispatches on `macp-node-kind' to kind-specific
;; renderers.  Kind-specific data lives in the dedicated structs below.

(cl-defstruct macp-node
  kind         ; 'turn-header 'user 'assistant 'thought 'tool-call 'plan 'trailer
  data         ; kind-specific struct below
  collapsed)   ; bool; only meaningful for 'tool-call

(cl-defstruct macp-turn
  id            ; monotonic counter per session
  started-at    ; float-time
  ended-at      ; float-time or nil
  stop-reason   ; 'end_turn 'max_tokens 'cancelled 'error or nil
  usage)        ; plist; reserved for a follow-on plan

(cl-defstruct macp-user
  text)

(cl-defstruct macp-assistant
  text)         ; accumulated chunks while streaming

(cl-defstruct macp-thought
  text)

(cl-defstruct macp-tool-call
  call-id name kind
  input locations
  status               ; 'pending 'running 'done 'error
  started-at ended-at
  raw-output
  diffs                ; list of (old . new) strings
  rendered-diff-count  ; int counter replacing :rendered-content-count
  plan-body)           ; full plan markdown (only for ExitPlanMode-style tools)

(cl-defstruct macp-plan
  entries)      ; vec of plists (:content :priority :status)

(cl-defstruct macp-trailer
  stop-reason)  ; 'max_tokens 'cancelled 'error 'refusal, etc.

(cl-defstruct macp-notice
  text          ; plain-text line content
  face)         ; face symbol applied to the line

;;;; Protocol-trace log buffer
;;
;; Always-on capture of every JSON-RPC line, inbound and outbound.
;; Lives in `*ACP2-log*'; switch to it with `mutecipher/acp2-show-log'.
;; Each entry is timestamped and tagged with a direction indicator:
;;   →  outbound (we sent it)
;;   ←  inbound  (agent sent it)
;; Long payloads are truncated per `mutecipher-acp2-log-max-line'.

(defconst mutecipher-acp2--log-buffer-name "*ACP2-log*")

(defun mutecipher-acp2--log-buffer ()
  "Return the `*ACP2-log*' buffer, creating it if necessary."
  (let ((buf (get-buffer-create mutecipher-acp2--log-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode)
        (special-mode)
        (setq-local truncate-lines t)
        (setq-local buffer-undo-list t)))
    buf))

(defun mutecipher-acp2--log-truncate (s)
  "Return S truncated to `mutecipher-acp2-log-max-line', with an overflow tail."
  (if (<= (length s) mutecipher-acp2-log-max-line)
      s
    (format "%s…(+%d chars)"
            (substring s 0 mutecipher-acp2-log-max-line)
            (- (length s) mutecipher-acp2-log-max-line))))

(defun mutecipher-acp2--log (tag agent payload)
  "Append a log entry to `*ACP2-log*'.
TAG is a short direction/kind marker (\"→\", \"←\", \"agent→\", etc.).
AGENT is the connection/agent label for the entry.  PAYLOAD is the raw
JSON line or a preformatted string."
  (let ((buf (mutecipher-acp2--log-buffer))
        (ts  (format-time-string "%H:%M:%S.%3N"))
        (line (mutecipher-acp2--log-truncate (or payload ""))))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (was-at-end (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert (format "%s %s %-10s %s\n"
                          ts tag (or agent "") line))
          (let ((excess (- (count-lines (point-min) (point-max))
                           mutecipher-acp2-log-keep-lines)))
            (when (> excess 0)
              (goto-char (point-min))
              (forward-line excess)
              (delete-region (point-min) (point)))))
        (when was-at-end
          (goto-char (point-max)))))))

;;;###autoload
(defun mutecipher/acp2-show-log ()
  "Pop up the `*ACP2-log*' protocol-trace buffer."
  (interactive)
  (pop-to-buffer (mutecipher-acp2--log-buffer)))

;;;###autoload
(defun mutecipher/acp2-clear-log ()
  "Erase the `*ACP2-log*' buffer."
  (interactive)
  (with-current-buffer (mutecipher-acp2--log-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer))))

;;;; NDJSON transport layer
;;
;; ACP uses newline-delimited JSON (one JSON object per line).
;; Emacs's built-in jsonrpc.el uses Content-Length framing (LSP-style),
;; so we implement a minimal custom transport instead.

(cl-defstruct (mutecipher-acp2--conn
               (:constructor mutecipher-acp2--make-conn))
  process    ; subprocess
  pending    ; hash-table: request-id → (success-fn error-fn)
  notify-fn) ; called as (method params) for incoming notifications

(defvar mutecipher-acp2--next-id 0
  "Monotonic counter for JSON-RPC request IDs.")

(defun mutecipher-acp2--new-id ()
  "Return the next request ID."
  (cl-incf mutecipher-acp2--next-id))

(defun mutecipher-acp2--open (agent-name command args env notify-fn)
  "Spawn COMMAND with ARGS and ENV for AGENT-NAME; return a connection struct.
NOTIFY-FN is called as (method params) for incoming JSON-RPC notifications."
  (let* ((process-environment
          (append (mapcar (lambda (pair) (format "%s=%s" (car pair) (cdr pair)))
                          (or env '()))
                  process-environment))
         (proc-buf (get-buffer-create (format " *acp2-%s*" agent-name)))
         (err-buf  (get-buffer-create (format " *acp2-%s-stderr*" agent-name)))
         (proc (make-process
                :name (format "acp2-%s" agent-name)
                :buffer proc-buf
                :command (cons command (or args '()))
                :connection-type 'pipe
                :noquery t
                :coding 'utf-8-unix
                :stderr err-buf))
         (conn (mutecipher-acp2--make-conn
                :process proc
                :pending (make-hash-table)
                :notify-fn notify-fn)))
    (set-process-filter proc (mutecipher-acp2--make-filter conn))
    (set-process-sentinel proc (mutecipher-acp2--make-sentinel conn))
    conn))

(defun mutecipher-acp2--make-filter (conn)
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
            (mutecipher-acp2--log "←" (process-name proc) line)
            (mutecipher-acp2--dispatch conn line)))))))

(defun mutecipher-acp2--make-sentinel (conn)
  "Return a process sentinel closure for CONN."
  (lambda (_proc event)
    (when (string-match-p "\\(exited\\|killed\\|finished\\|broken\\)" event)
      (maphash (lambda (_id cbs)
                 (when (cadr cbs)
                   (funcall (cadr cbs) `(:message "ACP agent process terminated"))))
               (mutecipher-acp2--conn-pending conn))
      (clrhash (mutecipher-acp2--conn-pending conn)))))

(defun mutecipher-acp2--dispatch (conn json-line)
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
          (mutecipher-acp2--handle-agent-request conn id method (plist-get msg :params)))
         ;; Response to a request we sent (has :id, no :method)
         ((not (null id))
          (when-let ((cbs (gethash id (mutecipher-acp2--conn-pending conn))))
            (remhash id (mutecipher-acp2--conn-pending conn))
            (if rpc-error
                (when (cadr cbs) (funcall (cadr cbs) rpc-error))
              (when (car cbs) (funcall (car cbs) result)))))
         ;; Incoming notification (has :method, no :id)
         (method
          (when-let ((fn (mutecipher-acp2--conn-notify-fn conn)))
            (funcall fn method (plist-get msg :params))))))
    (error
     (message "ACP2: JSON parse error (%s)" (error-message-string err)))))

(cl-defun mutecipher-acp2--request (conn method params &key success-fn error-fn)
  "Send an async JSON-RPC request over CONN.
METHOD is a string.  PARAMS is a plist or vector.
SUCCESS-FN and ERROR-FN are called with the result/error plist."
  (let* ((id  (mutecipher-acp2--new-id))
         (msg (list :jsonrpc "2.0" :id id :method method :params params))
         (line (json-serialize msg :null-object nil :false-object :json-false)))
    (puthash id (list success-fn error-fn) (mutecipher-acp2--conn-pending conn))
    (mutecipher-acp2--log "→" (process-name (mutecipher-acp2--conn-process conn)) line)
    (process-send-string (mutecipher-acp2--conn-process conn) (concat line "\n"))))

(defun mutecipher-acp2--respond (conn id result)
  "Send a JSON-RPC response with ID and RESULT over CONN.
Used to reply to inbound requests from the agent."
  (let ((line (json-serialize (list :jsonrpc "2.0" :id id :result result)
                              :null-object nil :false-object :json-false)))
    (mutecipher-acp2--log "→resp" (process-name (mutecipher-acp2--conn-process conn)) line)
    (process-send-string (mutecipher-acp2--conn-process conn) (concat line "\n"))))

(defun mutecipher-acp2--respond-error (conn id code message)
  "Send a JSON-RPC error response with ID, error CODE and MESSAGE over CONN."
  (let ((line (json-serialize (list :jsonrpc "2.0" :id id
                                    :error (list :code code :message message))
                              :null-object nil :false-object :json-false)))
    (mutecipher-acp2--log "→err" (process-name (mutecipher-acp2--conn-process conn)) line)
    (process-send-string (mutecipher-acp2--conn-process conn) (concat line "\n"))))

;;;; State

(defvar mutecipher-acp2--connections (make-hash-table :test #'equal)
  "Hash table mapping agent-name strings to mutecipher-acp2--conn structs.")

(defvar mutecipher-acp2--sessions (make-hash-table :test #'equal)
  "Hash table mapping session-id strings to session plists.")

(defvar-local mutecipher-acp2--session-id nil
  "Session ID associated with the current ACP2 buffer (output or input).")

(defvar-local mutecipher-acp2--ewoc nil
  "The ewoc managing the current ACP2 session buffer's transcript.")

;;;; Inbound agent-request dispatcher

(defun mutecipher-acp2--handle-agent-request (conn id method params)
  "Dispatch an inbound JSON-RPC request from the agent.
CONN is the connection, ID is the request id to respond to,
METHOD is the method string, PARAMS is the decoded plist."
  (cond
   ((equal method "session/request_permission")
    (mutecipher-acp2--handle-permission conn id params))
   ((equal method "fs/read_text_file")
    (mutecipher-acp2--handle-fs-read conn id params))
   ((equal method "fs/write_text_file")
    (mutecipher-acp2--handle-fs-write conn id params))
   (t
    (mutecipher-acp2--respond-error conn id -32601
                                    (format "Method not found: %s" method)))))

;;;; fs/* handlers

(defun mutecipher-acp2--session-for-conn (conn)
  "Return the session plist for CONN, or nil if none is active."
  (let (found)
    (maphash (lambda (_id session)
               (when (eq (plist-get session :conn) conn)
                 (setq found session)))
             mutecipher-acp2--sessions)
    found))

(defun mutecipher-acp2--handle-fs-read (conn id params)
  "Handle an fs/read_text_file request from the agent.
Deferred via `run-at-time' so that `y-or-n-p' runs in the main event loop,
not inside the process filter where interactive prompts are suppressed."
  (let* ((path     (plist-get params :path))
         (session  (mutecipher-acp2--session-for-conn conn))
         (cwd      (and session (plist-get session :cwd)))
         (abs-path (if (and path (not (file-name-absolute-p path)) cwd)
                       (expand-file-name path cwd)
                     path)))
    (if (not abs-path)
        (mutecipher-acp2--respond-error conn id -32602 "Missing path parameter")
      (run-at-time 0 nil
                   (lambda ()
                     (if (not (y-or-n-p (format "ACP2: read %s? " abs-path)))
                         (mutecipher-acp2--respond-error conn id -32000 "Read denied by user")
                       (condition-case err
                           (let ((content
                                  (with-temp-buffer
                                    (insert-file-contents abs-path)
                                    (buffer-string))))
                             (mutecipher-acp2--respond conn id (list :content content)))
                         (error
                          (mutecipher-acp2--respond-error conn id -32000
                                                          (error-message-string err))))))))))

(defun mutecipher-acp2--handle-fs-write (conn id params)
  "Handle an fs/write_text_file request from the agent.
Deferred via `run-at-time' so that `y-or-n-p' runs in the main event loop."
  (let* ((path     (plist-get params :path))
         (content  (plist-get params :content))
         (session  (mutecipher-acp2--session-for-conn conn))
         (cwd      (and session (plist-get session :cwd)))
         (abs-path (if (and path (not (file-name-absolute-p path)) cwd)
                       (expand-file-name path cwd)
                     path)))
    (cond
     ((not abs-path)
      (mutecipher-acp2--respond-error conn id -32602 "Missing path parameter"))
     ((not content)
      (mutecipher-acp2--respond-error conn id -32602 "Missing content parameter"))
     (t
      (run-at-time 0 nil
                   (lambda ()
                     (if (not (y-or-n-p (format "ACP2: write %s? " abs-path)))
                         (mutecipher-acp2--respond-error conn id -32000 "Write denied by user")
                       (condition-case err
                           (progn
                             (make-directory (file-name-directory abs-path) t)
                             (write-region content nil abs-path nil 'silent)
                             (when-let ((buf (find-buffer-visiting abs-path)))
                               (when (not (buffer-modified-p buf))
                                 (with-current-buffer buf
                                   (revert-buffer t t t))))
                             (mutecipher-acp2--respond conn id (list)))
                         (error
                          (mutecipher-acp2--respond-error conn id -32000
                                                          (error-message-string err)))))))))))

;;;; Permission handling

(defun mutecipher-acp2--option-label (o)
  "Extract a human-readable label from permission option O."
  (or (and (plist-get o :name)  (format "%s" (plist-get o :name)))
      (and (plist-get o :label) (format "%s" (plist-get o :label)))
      (and (plist-get o :title) (format "%s" (plist-get o :title)))
      (and (plist-get o :optionId) (format "%s" (plist-get o :optionId)))
      (and (plist-get o :id)    (format "%s" (plist-get o :id)))
      (format "%s" o)))

(defun mutecipher-acp2--option-id (o)
  "Extract the response id from permission option O."
  (or (plist-get o :optionId)
      (plist-get o :id)
      (plist-get o :value)
      (mutecipher-acp2--option-label o)))

(defun mutecipher-acp2--handle-permission (conn rpc-id params)
  "Prompt user for permission and send JSON-RPC response with RPC-ID over CONN."
  (let* ((session-id  (plist-get params :sessionId))
         (options     (plist-get params :options))
         (labels      (mapcar #'mutecipher-acp2--option-label options))
         (prior-state (when-let ((s (gethash session-id mutecipher-acp2--sessions)))
                        (plist-get s :state))))
    (mutecipher-acp2--set-state session-id 'awaiting-permission)
    (unwind-protect
        (condition-case _
            (let* ((chosen-label (completing-read "[ACP2] Permission: " labels nil t))
                   (chosen-id    (mutecipher-acp2--option-id
                                  (seq-find (lambda (o)
                                              (equal (mutecipher-acp2--option-label o) chosen-label))
                                            options))))
              (mutecipher-acp2--respond
               conn rpc-id
               (list :outcome (list :outcome "selected" :optionId chosen-id))))
          (quit
           (mutecipher-acp2--respond
            conn rpc-id
            (list :outcome (list :outcome "cancelled")))))
      (mutecipher-acp2--set-state session-id (or prior-state 'thinking)))))

;;;; Sticky-tail auto-scroll
;;
;; Without help, `ewoc-invalidate' and `ewoc-enter-last' grow or mutate
;; buffer content without moving window-point.  The user's natural
;; expectation is "if I'm at the bottom, keep showing me the tail — if
;; I've scrolled up to read, leave me alone."  This macro captures which
;; windows were at `point-max' before the body runs, then re-anchors
;; just those windows to the new `point-max' afterwards.

(defmacro mutecipher-acp2--with-sticky-tail (buf &rest body)
  "Run BODY with BUF current; re-tail only windows that were at `point-max'."
  (declare (indent 1) (debug (form body)))
  (let ((buf-sym   (make-symbol "buf"))
        (tails-sym (make-symbol "tails")))
    `(let* ((,buf-sym ,buf)
            (,tails-sym
             (and (buffer-live-p ,buf-sym)
                  (cl-loop for w in (get-buffer-window-list ,buf-sym nil t)
                           when (with-selected-window w
                                  (= (point) (point-max)))
                           collect w))))
       (prog1 (with-current-buffer ,buf-sym ,@body)
         (dolist (w ,tails-sym)
           (when (and (window-live-p w)
                      (eq (window-buffer w) ,buf-sym))
             (with-selected-window w
               (goto-char (point-max)))))))))

;;;; Notification dispatcher
;;
;; Each `session/update' arm either adds a node, mutates + invalidates
;; an existing node, or updates session state.  Kinds fill in across
;; plan steps 3–7; unimplemented kinds log to *Messages* so we can
;; observe protocol traffic without rendering.

(defun mutecipher-acp2--append-assistant-chunk (session-id text)
  "Append TEXT to SESSION-ID's current assistant node, creating one if needed.
Invalidates only that node so the rest of the transcript is untouched."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf)))
    (mutecipher-acp2--with-sticky-tail buf
      (unless mutecipher-acp2--ewoc
        (user-error "ACP2: no ewoc in session buffer"))
      (let* ((ewoc mutecipher-acp2--ewoc)
             (node (plist-get session :current-assistant))
             (inhibit-read-only t))
        (unless node
          (setq node (ewoc-enter-last
                      ewoc
                      (make-macp-node :kind 'assistant
                                      :data (make-macp-assistant :text ""))))
          (puthash session-id
                   (plist-put session :current-assistant node)
                   mutecipher-acp2--sessions))
        (let* ((msg (macp-node-data (ewoc-data node)))
               (old (or (macp-assistant-text msg) "")))
          (setf (macp-assistant-text msg) (concat old text)))
        (ewoc-invalidate ewoc node)))))

(defun mutecipher-acp2--close-assistant (session-id)
  "Drop SESSION-ID's :current-assistant reference so a new node is entered next."
  (when-let ((session (gethash session-id mutecipher-acp2--sessions)))
    (when (plist-get session :current-assistant)
      (puthash session-id
               (plist-put session :current-assistant nil)
               mutecipher-acp2--sessions))))

(defun mutecipher-acp2--ingest-tool-content (tc content-vec)
  "Append any new diff items from CONTENT-VEC onto TC, tracking rendered count.
Mutates TC in place; returns non-nil if anything new was added."
  (when (and content-vec (vectorp content-vec))
    (let* ((total (length content-vec))
           (seen  (or (macp-tool-call-rendered-diff-count tc) 0))
           (added nil))
      (when (< seen total)
        (let ((i seen))
          (while (< i total)
            (let ((item (aref content-vec i)))
              (when (equal (plist-get item :type) "diff")
                (setf (macp-tool-call-diffs tc)
                      (append (macp-tool-call-diffs tc)
                              (list (cons (plist-get item :oldText)
                                          (plist-get item :newText)))))
                (setq added t)))
            (setq i (1+ i))))
        (setf (macp-tool-call-rendered-diff-count tc) total))
      added)))

(defun mutecipher-acp2--raw-input-plan (raw-in)
  "Return the `:plan' string from RAW-IN, or nil.
Only returns strings — `ExitPlanMode' sends the proposed plan here as a
long markdown block that deserves inline rendering instead of being
truncated into the tool-call header."
  (let ((p (and (listp raw-in) (plist-get raw-in :plan))))
    (and (stringp p) (not (string-empty-p p)) p)))

(defun mutecipher-acp2--enter-tool-call (session-id update)
  "Create a tool-call ewoc node from UPDATE and register it in SESSION-ID's index."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf))
              (index   (plist-get session :tool-call-index)))
    (mutecipher-acp2--close-assistant session-id)
    (let* ((cc-name (plist-get (plist-get (plist-get update :_meta) :claudeCode) :toolName))
           (name    (or cc-name (plist-get update :title) (plist-get update :kind) "tool"))
           (raw-in  (plist-get update :rawInput))
           (plan    (mutecipher-acp2--raw-input-plan raw-in))
           (detail  (mutecipher-acp2--format-tool-input raw-in))
           (locs    (plist-get update :locations))
           (loc-str (when (and locs (> (length locs) 0))
                      (plist-get (aref locs 0) :path)))
           (call-id (plist-get update :toolCallId))
           (kind    (plist-get update :kind))
           (tc      (make-macp-tool-call
                     :call-id    call-id
                     :name       name
                     :kind       kind
                     :input      (or detail loc-str)
                     :locations  locs
                     :status     'pending
                     :started-at (float-time)
                     :diffs      nil
                     :rendered-diff-count 0
                     :plan-body  plan)))
      (mutecipher-acp2--ingest-tool-content tc (plist-get update :content))
      (mutecipher-acp2--with-sticky-tail buf
        (let* ((inhibit-read-only t)
               (node (ewoc-enter-last
                      mutecipher-acp2--ewoc
                      (make-macp-node :kind 'tool-call :data tc))))
          (when call-id
            (puthash call-id node index)))))))

(defun mutecipher-acp2--enter-notice (session-id text &optional face)
  "Enter a notice node in SESSION-ID's ewoc with TEXT and optional FACE."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf)))
    (mutecipher-acp2--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (ewoc-enter-last
         mutecipher-acp2--ewoc
         (make-macp-node :kind 'notice
                         :data (make-macp-notice :text text :face face)))))))

(defun mutecipher-acp2--enter-thought (session-id text)
  "Enter a thought node in SESSION-ID's ewoc carrying TEXT."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf)))
    (mutecipher-acp2--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (ewoc-enter-last
         mutecipher-acp2--ewoc
         (make-macp-node :kind 'thought
                         :data (make-macp-thought :text text)))))))

(defun mutecipher-acp2--enter-plan (session-id tasks)
  "Enter (or mutate) SESSION-ID's plan node with TASKS.
If the turn already has a plan node, its entries are replaced and the
node is invalidated.  Otherwise a fresh plan node is entered."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf)))
    (mutecipher-acp2--with-sticky-tail buf
      (let ((inhibit-read-only t)
            (existing (plist-get session :current-plan-node)))
        (cond
         (existing
          (let ((plan (macp-node-data (ewoc-data existing))))
            (setf (macp-plan-entries plan) tasks)
            (ewoc-invalidate mutecipher-acp2--ewoc existing)))
         (t
          (let ((node (ewoc-enter-last
                       mutecipher-acp2--ewoc
                       (make-macp-node :kind 'plan
                                       :data (make-macp-plan :entries tasks)))))
            (puthash session-id
                     (plist-put session :current-plan-node node)
                     mutecipher-acp2--sessions))))))))

(defun mutecipher-acp2--update-tool-call (session-id update)
  "Apply tool_call_update UPDATE to SESSION-ID's matching tool-call node."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf))
              (index   (plist-get session :tool-call-index))
              (call-id (plist-get update :toolCallId))
              (node    (gethash call-id index)))
    (let* ((wrapper    (ewoc-data node))
           (tc         (macp-node-data wrapper))
           (status-str (plist-get update :status))
           (cmd-title  (plist-get update :title))
           (raw-in     (plist-get update :rawInput))
           (plan       (mutecipher-acp2--raw-input-plan raw-in))
           (raw-out    (plist-get update :rawOutput)))
      (when (and (null status-str) cmd-title)
        (setf (macp-tool-call-input tc)
              (mutecipher-acp2--format-tool-input cmd-title)))
      (when plan
        (setf (macp-tool-call-plan-body tc) plan))
      (when raw-out
        (setf (macp-tool-call-raw-output tc) raw-out))
      (pcase status-str
        ("completed" (setf (macp-tool-call-status tc) 'done
                           (macp-tool-call-ended-at tc) (float-time)))
        ("failed"    (setf (macp-tool-call-status tc) 'error
                           (macp-tool-call-ended-at tc) (float-time)))
        ("in_progress" (setf (macp-tool-call-status tc) 'running)))
      (mutecipher-acp2--ingest-tool-content tc (plist-get update :content))
      ;; Auto-collapse on completion when output is long or diffs exist.
      ;; Plans (ExitPlanMode-style) are a hard opt-out: the whole point
      ;; of that tool call is the plan body, so we never auto-collapse it.
      (when (and (memq (macp-tool-call-status tc) '(done error))
                 (not (macp-node-collapsed wrapper))
                 (not (macp-tool-call-plan-body tc))
                 (or (> (mutecipher-acp2--tool-output-line-count
                         (macp-tool-call-raw-output tc))
                        3)
                     (macp-tool-call-diffs tc)))
        (setf (macp-node-collapsed wrapper) t))
      (mutecipher-acp2--with-sticky-tail buf
        (let ((inhibit-read-only t))
          (ewoc-invalidate mutecipher-acp2--ewoc node))))))

(defun mutecipher-acp2--handle-notification (method params)
  "Dispatch an incoming JSON-RPC notification with METHOD and PARAMS."
  (let ((session-id (plist-get params :sessionId))
        (update     (plist-get params :update)))
    (cond
     ((equal method "session/update")
      (when session-id
        (let ((type (plist-get update :sessionUpdate)))
          (cond
           ((equal type "agent_message_chunk")
            (when-let ((s (gethash session-id mutecipher-acp2--sessions)))
              (when (eq (plist-get s :state) 'thinking)
                (mutecipher-acp2--set-state session-id 'streaming)))
            (let ((text (or (plist-get (plist-get update :content) :text) "")))
              (mutecipher-acp2--append-assistant-chunk session-id text)
              (when (string-match-p "|" text)
                (mutecipher-acp2--schedule-align session-id))))
           ((equal type "tool_call")
            (mutecipher-acp2--enter-tool-call session-id update))
           ((equal type "tool_call_update")
            (mutecipher-acp2--update-tool-call session-id update))
           ((equal type "thought")
            (mutecipher-acp2--close-assistant session-id)
            (mutecipher-acp2--enter-thought session-id
                                            (or (plist-get update :thought) "")))
           ((equal type "plan")
            (mutecipher-acp2--close-assistant session-id)
            (mutecipher-acp2--enter-plan session-id
                                         (plist-get update :tasks)))
           ((equal type "session_info_update")
            (let* ((title     (plist-get update :title))
                   (session   (gethash session-id mutecipher-acp2--sessions))
                   (buf       (and session (plist-get session :buffer)))
                   (input-buf (and session (plist-get session :input-buffer))))
              (when (and title buf (buffer-live-p buf))
                (with-current-buffer buf
                  (rename-buffer (format "*ACP2: %s*" title) t))
                (when (buffer-live-p input-buf)
                  (with-current-buffer input-buf
                    (rename-buffer (format "*ACP2-input: %s*" title) t)))
                (puthash session-id
                         (plist-put session :title title)
                         mutecipher-acp2--sessions))))
           ((equal type "available_commands_update")
            (let* ((cmds    (plist-get update :commands))
                   (session (gethash session-id mutecipher-acp2--sessions)))
              (when (and session cmds)
                (puthash session-id
                         (plist-put session :commands cmds)
                         mutecipher-acp2--sessions))))
           (t
            (message "ACP2 [%s] update: %s (unhandled)"
                     (mutecipher-acp2--id-prefix session-id) type))))))
     (t
      (message "ACP2 notification: %s" method)))))

;;;; Connection management

(defun mutecipher-acp2--connect (agent-name)
  "Return an existing live connection for AGENT-NAME, or create a new one."
  (let ((existing (gethash agent-name mutecipher-acp2--connections)))
    (if (and existing
             (process-live-p (mutecipher-acp2--conn-process existing)))
        existing
      (let* ((spec    (cdr (assoc agent-name mutecipher-acp2-agents)))
             (command (plist-get spec :command))
             (args    (plist-get spec :args))
             (env     (plist-get spec :env)))
        (unless command
          (user-error "ACP2: no agent named %S in `mutecipher-acp2-agents'" agent-name))
        (let ((conn (mutecipher-acp2--open
                     agent-name command args env
                     #'mutecipher-acp2--handle-notification)))
          (puthash agent-name conn mutecipher-acp2--connections)
          conn)))))

;;;; Session buffer management

(defun mutecipher-acp2--id-prefix (session-id)
  "Return the first 8 characters of SESSION-ID for display."
  (substring session-id 0 (min 8 (length session-id))))

(defun mutecipher-acp2--buffer-name (agent-name session-id)
  "Return buffer name for AGENT-NAME and SESSION-ID."
  (format "*ACP2: %s [%s]*" agent-name (mutecipher-acp2--id-prefix session-id)))

(defun mutecipher-acp2--get-or-create-buffer (session-id agent-name)
  "Return (or create) the session buffer for SESSION-ID / AGENT-NAME."
  (let* ((name (mutecipher-acp2--buffer-name agent-name session-id))
         (buf  (get-buffer-create name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'mutecipher-acp2-session-mode)
        (mutecipher-acp2-session-mode)
        (setq mutecipher-acp2--session-id session-id)))
    buf))

;;;; Protocol helpers

(defun mutecipher-acp2--initialize (conn callback)
  "Send ACP initialize to CONN, call CALLBACK with the result."
  (mutecipher-acp2--request
   conn "initialize"
   (list :protocolVersion 1)
   :success-fn (lambda (result) (funcall callback result))
   :error-fn   (lambda (err)
                 (message "ACP2 initialize failed: %s" (plist-get err :message)))))

(defun mutecipher-acp2--new-session (conn cwd agent-name callback)
  "Send session/new to CONN with CWD, call CALLBACK with (session-id buffer) on success."
  (mutecipher-acp2--request
   conn "session/new" (list :cwd cwd :mcpServers [])
   :success-fn
   (lambda (result)
     (let* ((session-id (plist-get result :sessionId))
            (buf        (mutecipher-acp2--get-or-create-buffer session-id agent-name))
            (session    (list :id session-id :conn conn :buffer buf :agent agent-name
                              :cwd cwd
                              :input-buffer nil
                              :org-primed nil
                              :state 'idle
                              :state-started-at nil
                              :state-timer nil
                              :commands nil
                              :file-cache nil
                              :turn-counter 0
                              :current-turn-node nil
                              :current-assistant nil
                              :current-plan-node nil
                              :tool-call-index (make-hash-table :test #'equal)
                              :align-timer nil)))
       (puthash session-id session mutecipher-acp2--sessions)
       (mutecipher-acp2--set-banner session-id)
       (funcall callback session-id buf)))
   :error-fn
   (lambda (err)
     (message "ACP2 session/new failed: %s" (plist-get err :message)))))

(defun mutecipher-acp2--load-session (conn session-id agent-name cwd callback)
  "Resume SESSION-ID via session/load on CONN; call CALLBACK with (session-id buf).
The session plist is created eagerly so replayed notifications have
somewhere to land before the success callback fires."
  (let* ((buf     (mutecipher-acp2--get-or-create-buffer session-id agent-name))
         (session (list :id session-id :conn conn :buffer buf :agent agent-name
                        :cwd cwd
                        :input-buffer nil
                        :org-primed nil
                        :state 'idle
                        :state-started-at nil
                        :state-timer nil
                        :commands nil
                        :file-cache nil
                        :turn-counter 0
                        :current-turn-node nil
                        :current-assistant nil
                        :current-plan-node nil
                        :tool-call-index (make-hash-table :test #'equal)
                        :align-timer nil)))
    (puthash session-id session mutecipher-acp2--sessions)
    (mutecipher-acp2--set-banner session-id)
    (mutecipher-acp2--request
     conn "session/load" (list :sessionId session-id)
     :success-fn (lambda (_) (funcall callback session-id buf))
     :error-fn   (lambda (err)
                   (remhash session-id mutecipher-acp2--sessions)
                   (kill-buffer buf)
                   (message "ACP2 session/load failed: %s"
                            (plist-get err :message))))))

;;;; Prompt attachments (@-mentions)

(defconst mutecipher-acp2--file-cache-ttl 30
  "Seconds before `mutecipher-acp2--session-files' re-walks a session's cwd.")

(defconst mutecipher-acp2--file-cache-cap 2000
  "Maximum number of candidate files returned per session.")

(defconst mutecipher-acp2--file-exclude-dirs
  '(".git" "node_modules" ".direnv" ".venv" "vendor" "elpa" ".cache")
  "Directory basenames skipped by the fs fallback walker.")

(defun mutecipher-acp2--path->file-uri (abs-path)
  "Return a file:// URI for ABS-PATH with path segments percent-encoded."
  (concat "file://"
          (mapconcat #'url-hexify-string
                     (split-string (expand-file-name abs-path) "/")
                     "/")))

(defun mutecipher-acp2--walk-cwd (cwd)
  "Walk CWD collecting relative file paths, skipping excluded dirs.
Returns a list sorted shallowest-first, capped at
`mutecipher-acp2--file-cache-cap'."
  (let ((root (file-name-as-directory (expand-file-name cwd)))
        (acc '())
        (count 0)
        (queue (list (file-name-as-directory (expand-file-name cwd)))))
    (while (and queue (< count mutecipher-acp2--file-cache-cap))
      (let ((dir (pop queue)))
        (dolist (entry (ignore-errors
                         (directory-files
                          dir t directory-files-no-dot-files-regexp t)))
          (cond
           ((file-directory-p entry)
            (unless (member (file-name-nondirectory entry)
                            mutecipher-acp2--file-exclude-dirs)
              (push (file-name-as-directory entry) queue)))
           ((file-regular-p entry)
            (push (file-relative-name entry root) acc)
            (setq count (1+ count)))))))
    (sort acc (lambda (a b)
                (let ((da (cl-count ?/ a))
                      (db (cl-count ?/ b)))
                  (if (= da db) (string< a b) (< da db)))))))

(defun mutecipher-acp2--session-files (session)
  "Return a cached (SOURCE . LIST) pair of relative paths for SESSION's :cwd.
SOURCE is the symbol `project' or `fs'."
  (let* ((cwd   (plist-get session :cwd))
         (cache (plist-get session :file-cache))
         (now   (float-time)))
    (if (and cache
             (< (- now (nth 0 cache)) mutecipher-acp2--file-cache-ttl))
        (cons (nth 1 cache) (nth 2 cache))
      (let* ((proj  (and cwd
                         (let ((default-directory cwd))
                           (project-current nil cwd))))
             (files (if proj
                        (mapcar (lambda (f) (file-relative-name f cwd))
                                (project-files proj))
                      (and cwd (mutecipher-acp2--walk-cwd cwd))))
             (source (if proj 'project 'fs))
             (capped (if (> (length files) mutecipher-acp2--file-cache-cap)
                         (seq-take files mutecipher-acp2--file-cache-cap)
                       files)))
        (puthash (plist-get session :id)
                 (plist-put session :file-cache (list now source capped))
                 mutecipher-acp2--sessions)
        (cons source capped)))))

(defun mutecipher-acp2--extract-attachments (text cwd)
  "Scan TEXT for @-mentions and return ((TOKEN . ABS-PATH) ...)."
  (let ((seen (make-hash-table :test #'equal))
        (out  '())
        (case-fold-search nil))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "@\\([^ \t\n\r]+\\)" nil t)
        (let* ((raw     (match-string-no-properties 1))
               (trimmed (replace-regexp-in-string
                         "[.,;:!?)}'\"]+\\'" "" raw))
               (abs     (when (and cwd (> (length trimmed) 0))
                          (if (file-name-absolute-p trimmed)
                              (expand-file-name trimmed)
                            (expand-file-name trimmed cwd)))))
          (when (and abs
                     (not (gethash abs seen))
                     (file-regular-p abs))
            (puthash abs t seen)
            (push (cons trimmed abs) out)))))
    (nreverse out)))

(defun mutecipher-acp2--prompt-blocks (text cwd)
  "Return the :prompt vector for TEXT resolved against CWD."
  (let* ((attachments (mutecipher-acp2--extract-attachments text cwd))
         (text-block  (list :type "text" :text text))
         (link-blocks (mapcar
                       (lambda (a)
                         (let ((abs (cdr a)))
                           (list :type "resource_link"
                                 :uri  (mutecipher-acp2--path->file-uri abs)
                                 :name (file-name-nondirectory abs))))
                       attachments)))
    (apply #'vector text-block link-blocks)))

;;;; Completion-at-point functions

(defun mutecipher-acp2--commands-capf ()
  "Completion-at-point function for ACP slash commands.
Activates when the current line begins with \"/\"."
  (when-let* ((session-id mutecipher-acp2--session-id)
              (session    (gethash session-id mutecipher-acp2--sessions))
              (commands   (plist-get session :commands))
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

(defun mutecipher-acp2--files-capf ()
  "Completion-at-point function for @-mention file attachments."
  (when-let* ((session-id mutecipher-acp2--session-id)
              (session    (gethash session-id mutecipher-acp2--sessions))
              (at-pos     (save-excursion
                            (skip-chars-backward "^ \t\n")
                            (and (eq (char-after) ?@) (point)))))
    (let* ((cache      (mutecipher-acp2--session-files session))
           (source     (car cache))
           (files      (cdr cache))
           (candidates (mapcar (lambda (f) (concat "@" f)) files))
           (tag        (if (eq source 'project) "[project]" "[fs]")))
      (list at-pos (point) candidates
            :annotation-function (lambda (_) (concat "  " tag))
            :exclusive 'no))))

;;;; Pretty-printer dispatch
;;
;; Each kind-specific pretty-printer is self-contained and idempotent:
;; it `insert's the node's rendering at point and ends with exactly one
;; newline.  Ewoc manages the region; we only produce text.
;;
;; Per-kind implementations fill in as later plan steps bring node
;; kinds online.  Unimplemented kinds render a placeholder so stray
;; nodes don't silently break the buffer.

(defun mutecipher-acp2--pp (node)
  "Master ewoc pretty-printer: dispatch on NODE kind."
  (pcase (macp-node-kind node)
    ('turn-header (mutecipher-acp2--pp-turn-header node))
    ('user        (mutecipher-acp2--pp-user        node))
    ('assistant   (mutecipher-acp2--pp-assistant   node))
    ('thought     (mutecipher-acp2--pp-thought     node))
    ('tool-call   (mutecipher-acp2--pp-tool-call   node))
    ('plan        (mutecipher-acp2--pp-plan        node))
    ('trailer     (mutecipher-acp2--pp-trailer     node))
    ('notice      (mutecipher-acp2--pp-notice      node))
    (other        (insert (format "[acp2: unknown node kind: %s]\n" other)))))

(defun mutecipher-acp2--pp-turn-header (node)
  "Render a turn-header NODE: a blank-line separator for all turns after the first."
  (let* ((turn (macp-node-data node))
         (id   (macp-turn-id turn)))
    (if (and id (> id 1))
        (insert "\n")
      (insert ""))))

(defun mutecipher-acp2--pp-user (node)
  "Render a user NODE: a `> ' prefix line followed by a blank line."
  (let* ((user (macp-node-data node))
         (text (or (macp-user-text user) "")))
    (insert (propertize (concat "> " text) 'face 'mutecipher-acp2-user-face)
            "\n\n")))

(defun mutecipher-acp2--pp-assistant (node)
  "Render an assistant NODE: the accumulated streamed text, ending in a newline."
  (let* ((msg  (macp-node-data node))
         (text (or (macp-assistant-text msg) "")))
    (insert text)
    (unless (or (string-empty-p text)
                (eq (aref text (1- (length text))) ?\n))
      (insert "\n"))))

(defun mutecipher-acp2--pp-thought (node)
  "Render a thought NODE: italic/shadow-faced text ending in a newline."
  (let* ((thought (macp-node-data node))
         (text    (or (macp-thought-text thought) "")))
    (insert (propertize (concat text "\n")
                        'face 'mutecipher-acp2-thought-face
                        'acp-raw t))))

(defun mutecipher-acp2--format-tool-input (raw &optional max-len)
  "Format RAW tool input as a short display string, truncated to MAX-LEN (default 60).
Handles strings, plists (JSON objects), and vectors."
  (let ((max (or max-len 60)))
    (when raw
      (let ((s (cond
                ((stringp raw) raw)
                ((listp raw)
                 (or (and (stringp (plist-get raw :command))  (plist-get raw :command))
                     (and (stringp (plist-get raw :cmd))      (plist-get raw :cmd))
                     (and (stringp (plist-get raw :path))     (plist-get raw :path))
                     (and (stringp (plist-get raw :content))  (plist-get raw :content))
                     (cl-loop for (_k v) on raw by #'cddr
                              when (stringp v) return v)))
                ((vectorp raw) (and (> (length raw) 0)
                                    (mutecipher-acp2--format-tool-input (aref raw 0) max))))))
        (when s
          (let* ((s1 (replace-regexp-in-string "\n" "\\\\n" (string-trim s)))
                 (s1 (replace-regexp-in-string "[ \t]+" " " s1)))
            (if (> (length s1) max)
                (concat (substring s1 0 (1- max)) "…")
              s1)))))))

(defun mutecipher-acp2--generate-unified-diff (old-text new-text)
  "Return the hunk body comparing OLD-TEXT and NEW-TEXT as a unified diff.
File headers and any trailing `Diff finished' line are stripped; result
starts at the first `@@' line.  Returns nil if the texts are identical."
  (let ((old-file (make-temp-file "acp2-diff-old-"))
        (new-file (make-temp-file "acp2-diff-new-"))
        (diff-buf (generate-new-buffer " *acp2-diff*")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8))
            (write-region (or old-text "") nil old-file nil 'silent)
            (write-region (or new-text "") nil new-file nil 'silent))
          (diff-no-select old-file new-file "-u" t diff-buf)
          (with-current-buffer diff-buf
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (when (re-search-backward "^Diff finished" nil t)
                (delete-region (line-beginning-position) (point-max)))
              (goto-char (point-min))
              (when (re-search-forward "^@@" nil t)
                (buffer-substring-no-properties
                 (line-beginning-position) (point-max))))))
      (ignore-errors (delete-file old-file))
      (ignore-errors (delete-file new-file))
      (when (buffer-live-p diff-buf) (kill-buffer diff-buf)))))

(defun mutecipher-acp2--diff-body-for (old-text new-text)
  "Return a renderable diff body (propertized string) for OLD-TEXT → NEW-TEXT.
Honors `mutecipher-acp2-diff-max-lines' — oversize diffs render as a one-line
summary instead."
  (let* ((old (or old-text ""))
         (new (or new-text ""))
         (old-lines (1+ (cl-count ?\n old)))
         (new-lines (1+ (cl-count ?\n new)))
         (over (or (> old-lines mutecipher-acp2-diff-max-lines)
                   (> new-lines mutecipher-acp2-diff-max-lines))))
    (if over
        (propertize
         (format "  … diff suppressed (%d old, %d new lines)\n"
                 old-lines new-lines)
         'face 'shadow 'acp-raw t)
      (when-let ((diff-str (mutecipher-acp2--generate-unified-diff old new)))
        (propertize
         (concat "\n" (string-trim-right diff-str "\n") "\n")
         'acp-raw t 'acp-diff-region t)))))

(defun mutecipher-acp2--tool-output-line-count (raw)
  "Return the line count of RAW (0 if nil or empty)."
  (cond
   ((or (null raw) (string-empty-p raw)) 0)
   (t (1+ (cl-count ?\n raw)))))

(defun mutecipher-acp2--pp-tool-call (node)
  "Render a tool-call NODE: disclosure glyph + summary + optional full body.
When the node's `collapsed' flag is non-nil, emit only the summary line
with a `+N lines' hint.  When nil, emit the full raw output and any diff
bodies below the summary."
  (let* ((tc         (macp-node-data node))
         (name       (or (macp-tool-call-name tc) "tool"))
         (input      (macp-tool-call-input tc))
         (status     (macp-tool-call-status tc))
         (raw-output (macp-tool-call-raw-output tc))
         (diffs      (macp-tool-call-diffs tc))
         (collapsed  (macp-node-collapsed node))
         (lines      (mutecipher-acp2--tool-output-line-count raw-output))
         (disclosure (if collapsed "▸" "▾")))
    (insert (propertize
             (concat "\n" disclosure " " name
                     (if input (concat "(" input ")") ""))
             'face 'mutecipher-acp2-tool-face 'acp-raw t)
            "\n")
    (pcase status
      ('done
       (cond
        (collapsed
         (let ((first (and raw-output (not (string-empty-p raw-output))
                           (car (split-string raw-output "\n"))))
               (extra (max 0 (1- lines))))
           (insert (propertize
                    (concat "  ✓"
                            (if first (concat " " first) "")
                            (when (or (> extra 0) diffs)
                              (format " (+%d%s, TAB to expand)"
                                      extra
                                      (if diffs
                                          (format ", %d diff%s"
                                                  (length diffs)
                                                  (if (= 1 (length diffs)) "" "s"))
                                        "")))
                            "\n")
                    'face 'shadow 'acp-raw t))))
        (t
         (insert (propertize
                  (concat "  ✓"
                          (if (and raw-output (not (string-empty-p raw-output)))
                              (concat " " raw-output
                                      (unless (string-suffix-p "\n" raw-output)
                                        "\n"))
                            "\n"))
                  'face 'shadow 'acp-raw t)))))
      ('error
       (insert (propertize
                (concat "  ✘ "
                        (or (and raw-output (not (string-empty-p raw-output))
                                 (if collapsed
                                     (car (split-string raw-output "\n"))
                                   (string-trim-right raw-output "\n")))
                            "failed")
                        "\n")
                'face 'mutecipher-acp2-error-face 'acp-raw t))))
    (unless collapsed
      (when-let ((plan-body (macp-tool-call-plan-body tc)))
        (insert (propertize
                 (concat "\n"
                         (replace-regexp-in-string
                          "^" "  │ "
                          (string-trim-right plan-body "\n"))
                         "\n\n")
                 'acp-raw t)))
      (dolist (pair diffs)
        (when-let ((body (mutecipher-acp2--diff-body-for (car pair) (cdr pair))))
          (insert body))))))

(defun mutecipher-acp2--pp-notice (node)
  "Render a notice NODE: one propertized plain-text line."
  (let* ((notice (macp-node-data node))
         (text   (or (macp-notice-text notice) ""))
         (face   (or (macp-notice-face notice) 'default)))
    (insert (propertize (concat text "\n")
                        'face face
                        'acp-raw t))))

(defun mutecipher-acp2--pp-trailer (node)
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
                        'face 'shadow
                        'acp-raw t))))

(defun mutecipher-acp2--pp-plan (node)
  "Render a plan NODE: bold `[Plan]' header followed by a bullet list."
  (let* ((plan    (macp-node-data node))
         (entries (macp-plan-entries plan))
         (lines   (if (and entries (not (eq entries :json-false)))
                      (mapconcat
                       (lambda (task)
                         (concat "• " (or (plist-get task :title)
                                          (plist-get task :content) "")))
                       entries "\n")
                    "")))
    (insert (propertize "\n[Plan]\n" 'face 'bold 'acp-raw t))
    (insert (propertize (concat lines "\n") 'acp-raw t))))

;;;; Font-lock / jit-lock for Org-formatted agent prose
;;
;; Ported from `mutecipher-acp.el'.  `acp-raw' text-property regions —
;; banner, user lines, tool-call rows, diff blocks, plan nodes — are
;; shielded so Org markup matchers skip them.

(defun mutecipher-acp2--output-matcher (regexp)
  "Return a font-lock matcher for REGEXP that skips `acp-raw' regions."
  (lambda (limit)
    (let (found)
      (while (and (not found)
                  (re-search-forward regexp limit t))
        (unless (text-property-any (match-beginning 0) (match-end 0)
                                   'acp-raw t)
          (setq found t)))
      found)))

(defun mutecipher-acp2--table-pipe-matcher (limit)
  "Font-lock matcher for `|' on Org table rows up to LIMIT; skips `acp-raw'."
  (let (found)
    (while (and (not found)
                (< (point) limit)
                (re-search-forward "|" limit t))
      (when (and (save-excursion (beginning-of-line) (looking-at "|"))
                 (not (get-text-property (match-beginning 0) 'acp-raw)))
        (setq found t)))
    found))

(defconst mutecipher-acp2--org-keywords
  `((,(mutecipher-acp2--output-matcher "^\\(\\*\\) \\(.*\\)$")
     (1 'shadow t)
     (2 '(face (:weight bold :height 1.25)) t))
    (,(mutecipher-acp2--output-matcher "^\\(\\*\\)\\(\\*\\) \\(.*\\)$")
     (1 '(face nil invisible mutecipher-acp2-markup) t)
     (2 'shadow t)
     (3 '(face (:weight bold :height 1.15)) t))
    (,(mutecipher-acp2--output-matcher "^\\(\\*\\{2,\\}\\)\\(\\*\\) \\(.*\\)$")
     (1 '(face nil invisible mutecipher-acp2-markup) t)
     (2 'shadow t)
     (3 '(face (:weight bold :height 1.05)) t))
    (,(mutecipher-acp2--output-matcher "\\(\\*\\)\\([^*\n]+\\)\\(\\*\\)")
     (1 '(face nil invisible mutecipher-acp2-markup) t)
     (2 'bold t)
     (3 '(face nil invisible mutecipher-acp2-markup) t))
    (,(mutecipher-acp2--output-matcher "\\(/\\)\\([^/\n]+\\)\\(/\\)")
     (1 '(face nil invisible mutecipher-acp2-markup) t)
     (2 '(face (:slant italic)) t)
     (3 '(face nil invisible mutecipher-acp2-markup) t))
    (,(mutecipher-acp2--output-matcher "\\(~\\)\\([^~\n]+\\)\\(~\\)")
     (1 '(face nil invisible mutecipher-acp2-markup) t)
     (2 'font-lock-constant-face t)
     (3 '(face nil invisible mutecipher-acp2-markup) t))
    (,(mutecipher-acp2--output-matcher "\\(=\\)\\([^=\n]+\\)\\(=\\)")
     (1 '(face nil invisible mutecipher-acp2-markup) t)
     (2 'font-lock-string-face t)
     (3 '(face nil invisible mutecipher-acp2-markup) t))
    (,(mutecipher-acp2--output-matcher "^#\\+begin_src\\b.*$") (0 'font-lock-comment-face t))
    (,(mutecipher-acp2--output-matcher "^#\\+end_src$")        (0 'font-lock-comment-face t))
    (,(mutecipher-acp2--output-matcher "^#\\+begin_quote\\b.*$") (0 'font-lock-comment-face t))
    (,(mutecipher-acp2--output-matcher "^#\\+end_quote$")        (0 'font-lock-comment-face t))
    (,(mutecipher-acp2--output-matcher "^#\\+[A-Za-z_]+:?.*$") (0 'font-lock-preprocessor-face t))
    (,(mutecipher-acp2--output-matcher "^[ \t]*[-+] ")          (0 'font-lock-keyword-face t))
    (,(mutecipher-acp2--output-matcher "^|[-|+:]+|$")
     (0 'shadow t))
    (mutecipher-acp2--table-pipe-matcher (0 'shadow t)))
  "Org-mode-inspired font-lock keywords for ACP2 session buffers.")

(defun mutecipher-acp2--fontify-block (lang beg end)
  "Apply LANG's font-lock faces to region BEG..END in the current buffer.
Uses a persistent scratch buffer to avoid reloading the major mode each call."
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
            (get-buffer-create (format " *acp2-fontify:%s*" lang))
          (erase-buffer)
          (insert code " ")
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

(defun mutecipher-acp2--org-fontify-src-blocks (start end)
  "Fontify #+begin_src...#+end_src blocks in region START..END."
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
            (mutecipher-acp2--fontify-block lang blk-beg blk-end)))))))

(defun mutecipher-acp2--link-follow (&optional _event)
  "Follow the Org-style link at point (or at the mouse click position)."
  (interactive)
  (when-let ((url (get-text-property (point) 'mutecipher-acp2-link)))
    (cond
     ((string-prefix-p "file:" url)
      (find-file (substring url 5)))
     ((string-match-p "\\`[a-zA-Z][-+.a-zA-Z0-9]*:" url)
      (browse-url url))
     (t
      (find-file url)))))

(defvar mutecipher-acp2--link-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")   #'mutecipher-acp2--link-follow)
    (define-key map [mouse-2]     #'mutecipher-acp2--link-follow)
    (define-key map [follow-link] 'mouse-face)
    map)
  "Keymap attached to Org-link descriptions in ACP2 session buffers.")

(defun mutecipher-acp2--org-fontify-links (start end)
  "Render Org-style [[url]] / [[url][desc]] as clickable buttons in START..END."
  (let ((scan-start (save-excursion (goto-char start) (line-beginning-position)))
        (scan-end   (save-excursion (goto-char end)   (line-end-position)))
        (inhibit-read-only t))
    (save-excursion
      (goto-char scan-start)
      (with-silent-modifications
        (while (re-search-forward
                "\\[\\[\\([^]\n]+\\)\\]\\(?:\\[\\([^]\n]+\\)\\]\\)?\\]"
                scan-end t)
          (let* ((full-beg  (match-beginning 0))
                 (full-end  (match-end 0))
                 (url-beg   (match-beginning 1))
                 (url-end   (match-end 1))
                 (desc-beg  (match-beginning 2))
                 (desc-end  (match-end 2))
                 (url       (buffer-substring-no-properties url-beg url-end))
                 (btn-props `(font-lock-face link
                                             mouse-face highlight
                                             follow-link t
                                             keymap ,mutecipher-acp2--link-keymap
                                             mutecipher-acp2-link ,url)))
            (if desc-beg
                (progn
                  (put-text-property full-beg desc-beg 'invisible 'mutecipher-acp2-markup)
                  (add-text-properties desc-beg desc-end btn-props)
                  (put-text-property desc-end full-end 'invisible 'mutecipher-acp2-markup))
              (put-text-property full-beg (+ full-beg 2) 'invisible 'mutecipher-acp2-markup)
              (add-text-properties url-beg url-end btn-props)
              (put-text-property (- full-end 2) full-end 'invisible 'mutecipher-acp2-markup))))))))

(defun mutecipher-acp2--org-fontify-quotes (start end)
  "Apply italic face to #+begin_quote block bodies in START..END."
  (save-excursion
    (goto-char start)
    (let ((scan-from (or (re-search-backward "^#\\+begin_quote" nil t) start))
          (inhibit-read-only t))
      (goto-char scan-from)
      (with-silent-modifications
        (while (re-search-forward "^#\\+begin_quote\\b" end t)
          (let* ((blk-beg (1+ (line-end-position)))
                 (blk-end (and (re-search-forward "^#\\+end_quote" end t)
                               (line-beginning-position))))
            (when (and blk-end (< blk-beg blk-end))
              (put-text-property blk-beg blk-end 'face 'italic))))))))

;;;; Table alignment (scheduled around assistant nodes)

(defun mutecipher-acp2--align-tables-in-region (beg end)
  "Align all Org tables in BEG..END using `org-table-align'."
  (when (require 'org-table nil t)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char beg)
        (while (and (< (point) end)
                    (re-search-forward "^|" end t))
          (beginning-of-line)
          (ignore-errors (org-table-align))
          (ignore-errors (goto-char (org-table-end)))
          (forward-line 1))))))

(defun mutecipher-acp2--align-assistant-node (session-id node)
  "Run `--align-tables-in-region' over the buffer region spanned by NODE."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf))
              (ewoc    (buffer-local-value 'mutecipher-acp2--ewoc buf))
              (beg     (ewoc-location node))
              (next    (ewoc-next ewoc node))
              (end     (if next (ewoc-location next) (point-max))))
    (mutecipher-acp2--with-sticky-tail buf
      (mutecipher-acp2--align-tables-in-region beg end))))

(defun mutecipher-acp2--schedule-align (session-id)
  "Schedule a debounced table re-alignment for SESSION-ID's current assistant."
  (when-let ((session (gethash session-id mutecipher-acp2--sessions)))
    (when-let ((t0 (plist-get session :align-timer)))
      (cancel-timer t0))
    (let* ((node  (plist-get session :current-assistant))
           (timer (and node
                       (run-at-time
                        0.25 nil
                        (lambda ()
                          (when-let ((s (gethash session-id mutecipher-acp2--sessions)))
                            (mutecipher-acp2--align-assistant-node session-id node)
                            (puthash session-id
                                     (plist-put s :align-timer nil)
                                     mutecipher-acp2--sessions)))))))
      (when timer
        (puthash session-id
                 (plist-put session :align-timer timer)
                 mutecipher-acp2--sessions)))))

;;;; Session output buffer mode

(define-derived-mode mutecipher-acp2-session-mode special-mode "ACP2"
  "Read-only output buffer for an ACP2 session.
Content streams in from the agent as ewoc nodes; input is handled by a
paired `mutecipher-acp2-input-mode' buffer pinned below this window."
  (setq-local truncate-lines nil)
  (setq-local cursor-type nil)
  (when mutecipher-acp2-org-responses
    (font-lock-add-keywords nil mutecipher-acp2--org-keywords t)
    (add-to-invisibility-spec 'mutecipher-acp2-markup)
    (jit-lock-register #'mutecipher-acp2--org-fontify-src-blocks)
    (jit-lock-register #'mutecipher-acp2--org-fontify-links)
    (jit-lock-register #'mutecipher-acp2--org-fontify-quotes))
  (visual-line-mode 1)
  (font-lock-mode 1)
  (setq-local mode-line-format
              '((:eval (propertize " ACP2 " 'face '(:weight bold)))
                " · "
                (:eval (let ((s (gethash mutecipher-acp2--session-id
                                         mutecipher-acp2--sessions)))
                         (or (and s (plist-get s :agent)) "")))
                "  "
                (:eval (and mutecipher-acp2--session-id
                            (propertize
                             (mutecipher-acp2--id-prefix mutecipher-acp2--session-id)
                             'face 'shadow)))))
  ;; Create the ewoc on a fresh buffer; NOSEP so each pretty-printer
  ;; owns its own newlines.  Header/footer are filled in by
  ;; `mutecipher-acp2--set-banner' once the session plist is known.
  (when (zerop (buffer-size))
    (let ((inhibit-read-only t))
      (setq-local mutecipher-acp2--ewoc
                  (ewoc-create #'mutecipher-acp2--pp "" "" t)))))

(defun mutecipher-acp2--banner-string (agent cwd)
  "Return the welcome banner for AGENT at CWD."
  (concat (propertize (format "ACP2 · %s" agent)
                      'face 'mutecipher-acp2-user-face)
          "\n"
          (propertize (abbreviate-file-name cwd)
                      'face 'mutecipher-acp2-banner-face)
          "\n"
          (propertize
           "  RET send · S-RET newline · M-p/M-n history · / commands"
           'face 'mutecipher-acp2-hint-face)
          "\n"
          (propertize
           "  C-c C-a menu · C-c C-c cancel · C-c C-k kill · C-c C-o config"
           'face 'mutecipher-acp2-hint-face)
          "\n\n"))

(defun mutecipher-acp2--set-banner (session-id)
  "Install the session banner as the ewoc header in SESSION-ID's buffer."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf))
              (agent   (plist-get session :agent))
              (cwd     (plist-get session :cwd)))
    (mutecipher-acp2--with-sticky-tail buf
      (when mutecipher-acp2--ewoc
        (let ((inhibit-read-only t))
          (ewoc-set-hf mutecipher-acp2--ewoc
                       (mutecipher-acp2--banner-string agent cwd)
                       ""))))))

(defun mutecipher/acp2-toggle-tool-call ()
  "Toggle the expanded/collapsed state of the tool-call node at point."
  (interactive)
  (let* ((ewoc mutecipher-acp2--ewoc)
         (node (and ewoc (ewoc-locate ewoc))))
    (cond
     ((null node)
      (user-error "ACP2: no node at point"))
     ((not (eq (macp-node-kind (ewoc-data node)) 'tool-call))
      (user-error "ACP2: not on a tool-call"))
     (t
      (let ((wrapper (ewoc-data node)))
        (setf (macp-node-collapsed wrapper) (not (macp-node-collapsed wrapper))))
      (mutecipher-acp2--with-sticky-tail (current-buffer)
        (let ((inhibit-read-only t))
          (ewoc-invalidate ewoc node)))))))

(define-key mutecipher-acp2-session-mode-map (kbd "TAB")     #'mutecipher/acp2-toggle-tool-call)
(define-key mutecipher-acp2-session-mode-map (kbd "<tab>")   #'mutecipher/acp2-toggle-tool-call)
(define-key mutecipher-acp2-session-mode-map (kbd "C-c C-a") #'mutecipher/acp2-dispatch)
(define-key mutecipher-acp2-session-mode-map (kbd "C-c C-c") #'mutecipher/acp2-cancel)
(define-key mutecipher-acp2-session-mode-map (kbd "C-c C-k") #'mutecipher/acp2-kill-session)
(define-key mutecipher-acp2-session-mode-map (kbd "C-c C-o") #'mutecipher/acp2-set-config)

;;;; Input buffer mode

(defvar-local mutecipher-acp2--resize-last-size nil
  "Last `buffer-size' seen by `mutecipher-acp2--resize-input'.")

(defvar-local mutecipher-acp2--input-history (make-ring 50)
  "Per-session input history ring for `mutecipher-acp2-input-mode' buffers.")

(defvar-local mutecipher-acp2--input-history-index nil
  "Current position in the history ring, or nil at the fresh prompt.")

(defconst mutecipher-acp2--input-hint
  "RET send · S-RET newline · / cmds · @ file · C-c C-a menu"
  "Right-aligned hint text shown in the input buffer's header line.")

(defun mutecipher-acp2--input-header-line ()
  "Return the header-line content for the input buffer."
  (let* ((win   (get-buffer-window (current-buffer)))
         (width (if win (window-total-width win) 80))
         (hint  mutecipher-acp2--input-hint)
         (hint-w (string-width hint)))
    (concat
     (propertize "  > " 'face 'mutecipher-acp2-user-face)
     (if (> width (+ hint-w 8))
         (concat
          (propertize " " 'display `(space :align-to (- right ,(1+ hint-w))))
          (propertize hint 'face 'mutecipher-acp2-hint-face))
       ""))))

(defun mutecipher-acp2--state-label (state started-at)
  "Render STATE as a propertized mode-line label.
STARTED-AT is a float-time used to display elapsed seconds for busy states."
  (let ((elapsed (and started-at (max 0 (truncate (- (float-time) started-at))))))
    (pcase state
      ('thinking
       (propertize (format " thinking %ds " (or elapsed 0))
                   'face 'mutecipher-acp2-status-busy-face))
      ('streaming
       (propertize (format " streaming %ds " (or elapsed 0))
                   'face 'mutecipher-acp2-status-busy-face))
      ('awaiting-permission
       (propertize " awaiting permission "
                   'face 'mutecipher-acp2-status-await-face))
      ('error
       (propertize " error " 'face 'mutecipher-acp2-status-error-face))
      (_
       (propertize " idle " 'face 'mutecipher-acp2-status-idle-face)))))

(defun mutecipher-acp2--input-mode-line ()
  "Return the mode-line content for the input buffer."
  (let* ((sid     mutecipher-acp2--session-id)
         (session (and sid (gethash sid mutecipher-acp2--sessions)))
         (state   (or (and session (plist-get session :state)) 'idle))
         (started (and session (plist-get session :state-started-at)))
         (agent   (and session (plist-get session :agent))))
    (concat
     (mutecipher-acp2--state-label state started)
     (when agent
       (concat "  " (propertize agent 'face 'shadow)))
     (when sid
       (concat "  " (propertize (mutecipher-acp2--id-prefix sid)
                                'face 'shadow))))))

(define-derived-mode mutecipher-acp2-input-mode fundamental-mode "ACP2-Input"
  "Dynamically-resizing input buffer paired with an ACP2 session output buffer.
RET sends the buffer contents as a prompt.  S-RET / M-J insert a newline.
M-p / M-n cycle the input history.  C-c C-c cancels; C-c C-k kills the session."
  (setq-local header-line-format '((:eval (mutecipher-acp2--input-header-line))))
  (setq-local mode-line-format '((:eval (mutecipher-acp2--input-mode-line))))
  (setq-local completion-auto-help t)
  (visual-line-mode 1)
  (add-hook 'post-command-hook #'mutecipher-acp2--resize-input nil t)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp2--files-capf nil t)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp2--commands-capf nil t))

(defun mutecipher-acp2--resize-input ()
  "Grow or shrink the input window to fit the buffer content (1–12 lines)."
  (when-let ((win (get-buffer-window (current-buffer))))
    (let ((size (buffer-size)))
      (unless (eq size mutecipher-acp2--resize-last-size)
        (setq mutecipher-acp2--resize-last-size size)
        (let ((window-min-height 1))
          (fit-window-to-buffer win 12 1))))))

(defun mutecipher-acp2--input-send ()
  "Send the input buffer contents as a prompt to the ACP2 session."
  (interactive)
  (let ((text (string-trim (buffer-string))))
    (unless (string-empty-p text)
      (ring-insert mutecipher-acp2--input-history text)
      (setq mutecipher-acp2--input-history-index nil)
      (erase-buffer)
      (mutecipher-acp2--do-prompt mutecipher-acp2--session-id text))))

(defun mutecipher-acp2--input-history-prev ()
  "Replace buffer contents with the previous input history entry."
  (interactive)
  (let ((len (ring-length mutecipher-acp2--input-history)))
    (when (> len 0)
      (setq mutecipher-acp2--input-history-index
            (if mutecipher-acp2--input-history-index
                (min (1+ mutecipher-acp2--input-history-index) (1- len))
              0))
      (erase-buffer)
      (insert (ring-ref mutecipher-acp2--input-history
                        mutecipher-acp2--input-history-index)))))

(defun mutecipher-acp2--input-history-next ()
  "Replace buffer contents with the next input history entry, or clear the buffer."
  (interactive)
  (cond
   ((null mutecipher-acp2--input-history-index))
   ((= mutecipher-acp2--input-history-index 0)
    (setq mutecipher-acp2--input-history-index nil)
    (erase-buffer))
   (t
    (cl-decf mutecipher-acp2--input-history-index)
    (erase-buffer)
    (insert (ring-ref mutecipher-acp2--input-history
                      mutecipher-acp2--input-history-index)))))

(let ((map mutecipher-acp2-input-mode-map))
  (define-key map (kbd "RET")        #'mutecipher-acp2--input-send)
  (define-key map (kbd "<return>")   #'mutecipher-acp2--input-send)
  (define-key map (kbd "S-RET")      #'newline)
  (define-key map (kbd "S-<return>") #'newline)
  (define-key map (kbd "M-J")        #'newline)
  (define-key map (kbd "M-p")        #'mutecipher-acp2--input-history-prev)
  (define-key map (kbd "M-n")        #'mutecipher-acp2--input-history-next)
  (define-key map (kbd "C-c C-a")    #'mutecipher/acp2-dispatch)
  (define-key map (kbd "C-c C-c")    #'mutecipher/acp2-cancel)
  (define-key map (kbd "C-c C-k")    #'mutecipher/acp2-kill-session)
  (define-key map (kbd "C-c C-o")    #'mutecipher/acp2-set-config))

(defun mutecipher-acp2--input-buffer-name (session-id)
  "Return the input buffer name for SESSION-ID."
  (format "*ACP2-input:%s*" (mutecipher-acp2--id-prefix session-id)))

(defun mutecipher-acp2--get-or-create-input-buffer (session-id)
  "Return (or create) the input buffer for SESSION-ID."
  (let ((buf (get-buffer-create (mutecipher-acp2--input-buffer-name session-id))))
    (with-current-buffer buf
      (unless (derived-mode-p 'mutecipher-acp2-input-mode)
        (mutecipher-acp2-input-mode)
        (setq mutecipher-acp2--session-id session-id)))
    buf))

;;;; State transitions

(defun mutecipher-acp2--force-input-mode-line (session)
  "Refresh the mode-line in SESSION's input buffer, if live."
  (when-let ((input-buf (plist-get session :input-buffer)))
    (when (buffer-live-p input-buf)
      (with-current-buffer input-buf
        (force-mode-line-update)))))

(defun mutecipher-acp2--set-state (session-id new-state)
  "Transition SESSION-ID to NEW-STATE and refresh the input buffer mode-line.
Starts a 1Hz timer for `thinking' and `streaming' so the elapsed-seconds
counter ticks; cancels it for every other state."
  (when-let ((session (gethash session-id mutecipher-acp2--sessions)))
    (when-let ((t0 (plist-get session :state-timer)))
      (cancel-timer t0))
    (let* ((busy       (memq new-state '(thinking streaming)))
           (started-at (and busy (float-time)))
           (timer      (and busy
                            (run-at-time
                             1 1
                             (lambda ()
                               (when-let ((s (gethash session-id mutecipher-acp2--sessions)))
                                 (mutecipher-acp2--force-input-mode-line s))))))
           (updated    (thread-first session
                         (plist-put :state new-state)
                         (plist-put :state-started-at started-at)
                         (plist-put :state-timer timer))))
      (puthash session-id updated mutecipher-acp2--sessions)
      (mutecipher-acp2--force-input-mode-line updated))))

;;;; Prompt submission

(defun mutecipher-acp2--open-turn (session-id user-text)
  "Open a new turn in SESSION-ID: enter turn-header + user nodes for USER-TEXT.
Clears per-turn scratch (`:current-assistant', `:current-plan-node')
and bumps `:turn-counter'.  Returns the turn-header node."
  (let* ((session (gethash session-id mutecipher-acp2--sessions))
         (buf     (plist-get session :buffer))
         (counter (1+ (or (plist-get session :turn-counter) 0)))
         (turn    (make-macp-turn :id counter :started-at (float-time)))
         (turn-node nil))
    (mutecipher-acp2--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (setq turn-node (ewoc-enter-last
                         mutecipher-acp2--ewoc
                         (make-macp-node :kind 'turn-header :data turn)))
        (ewoc-enter-last
         mutecipher-acp2--ewoc
         (make-macp-node :kind 'user
                         :data (make-macp-user :text user-text)))))
    (puthash session-id
             (thread-first session
               (plist-put :turn-counter counter)
               (plist-put :current-turn-node turn-node)
               (plist-put :current-assistant nil)
               (plist-put :current-plan-node nil))
             mutecipher-acp2--sessions)
    turn-node))

(defun mutecipher-acp2--close-turn (session-id stop-reason)
  "Finalize SESSION-ID's current turn with STOP-REASON, invalidate its header.
Enters a trailer node for any non-normal STOP-REASON."
  (when-let* ((session (gethash session-id mutecipher-acp2--sessions))
              (node    (plist-get session :current-turn-node))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf)))
    (let* ((turn (macp-node-data (ewoc-data node))))
      (setf (macp-turn-ended-at   turn) (float-time))
      (setf (macp-turn-stop-reason turn) stop-reason)
      (mutecipher-acp2--with-sticky-tail buf
        (let ((inhibit-read-only t))
          (ewoc-invalidate mutecipher-acp2--ewoc node)
          (unless (memq stop-reason '(end_turn nil))
            (ewoc-enter-last
             mutecipher-acp2--ewoc
             (make-macp-node
              :kind 'trailer
              :data (make-macp-trailer :stop-reason stop-reason)))))))
    (puthash session-id
             (plist-put session :current-turn-node nil)
             mutecipher-acp2--sessions)))

(defun mutecipher-acp2--do-prompt (session-id text)
  "Send TEXT as a prompt for SESSION-ID."
  (let* ((session   (gethash session-id mutecipher-acp2--sessions))
         (conn      (plist-get session :conn))
         (primed    (plist-get session :org-primed))
         (full-text (if (and mutecipher-acp2-org-responses (not primed))
                        (progn
                          (puthash session-id
                                   (plist-put session :org-primed t)
                                   mutecipher-acp2--sessions)
                          (concat mutecipher-acp2-org-system-prompt "\n\n" text))
                      text)))
    (mutecipher-acp2--open-turn session-id text)
    (mutecipher-acp2--set-state session-id 'thinking)
    (mutecipher-acp2--request
     conn "session/prompt"
     (list :sessionId session-id
           :prompt (mutecipher-acp2--prompt-blocks
                    full-text (plist-get session :cwd)))
     :success-fn (lambda (result)
                   (let ((reason (or (plist-get result :stopReason) "end_turn")))
                     (mutecipher-acp2--close-assistant session-id)
                     (mutecipher-acp2--close-turn session-id (intern reason))
                     (mutecipher-acp2--set-state session-id 'idle)))
     :error-fn   (lambda (err)
                   (mutecipher-acp2--close-assistant session-id)
                   (mutecipher-acp2--close-turn session-id 'error)
                   (mutecipher-acp2--set-state session-id 'error)
                   (message "ACP2: request failed: %s"
                            (or (plist-get err :message) "unknown error"))))))

;;;; Public interactive commands

;;;###autoload
(defun mutecipher/acp2-start (agent-name)
  "Start an ACP2 session with AGENT-NAME.
Spawns the agent process, creates a session via session/new, opens the
session buffer, and pins a small input buffer below it."
  (interactive
   (list (completing-read "ACP2 agent: "
                          (mapcar #'car mutecipher-acp2-agents)
                          nil t)))
  (let* ((conn (mutecipher-acp2--connect agent-name))
         (cwd  (expand-file-name default-directory)))
    (mutecipher-acp2--initialize
     conn
     (lambda (_)
       (mutecipher-acp2--new-session
        conn cwd agent-name
        (lambda (session-id buf)
          (message "ACP2: session started (%s)" session-id)
          (mutecipher-acp2--open-pane session-id buf agent-name)))))))

;;;###autoload
(defun mutecipher/acp2-resume (agent-name)
  "Resume an existing ACP2 session for AGENT-NAME."
  (interactive
   (list (completing-read "ACP2 agent: "
                          (mapcar #'car mutecipher-acp2-agents)
                          nil t)))
  (let* ((conn (mutecipher-acp2--connect agent-name))
         (cwd  (expand-file-name default-directory)))
    (mutecipher-acp2--initialize
     conn
     (lambda (_)
       (mutecipher-acp2--request
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
                (message "ACP2: no existing sessions for %s" agent-name)
              (let* ((choice     (completing-read "Resume session: "
                                                  (mapcar #'car entries) nil t))
                     (session-id (cdr (assoc choice entries))))
                (mutecipher-acp2--load-session
                 conn session-id agent-name cwd
                 (lambda (sid buf)
                   (message "ACP2: resumed session (%s)" sid)
                   (mutecipher-acp2--open-pane sid buf agent-name)))))))
        :error-fn
        (lambda (err)
          (message "ACP2 session/list failed: %s" (plist-get err :message))))))))

(defun mutecipher-acp2--open-pane (session-id buf _agent-name)
  "Display output BUF (top) with a pinned, auto-resizing input buffer (bottom)."
  (let* ((input-buf (mutecipher-acp2--get-or-create-input-buffer session-id)))
    (when-let ((session (gethash session-id mutecipher-acp2--sessions)))
      (puthash session-id
               (plist-put session :input-buffer input-buf)
               mutecipher-acp2--sessions))
    (pop-to-buffer-same-window buf)
    (goto-char (point-max))
    (let* ((window-min-height 1)
           (input-win (split-window-below -3)))
      (set-window-buffer input-win input-buf)
      (set-window-dedicated-p input-win t)
      (select-window input-win))))

;;;###autoload
(defun mutecipher/acp2-prompt (text)
  "Send TEXT as a prompt to the most recently started ACP2 session."
  (interactive "sACP2 prompt: ")
  (let ((session-id (mutecipher-acp2--pick-session)))
    (unless session-id
      (user-error "ACP2: no active session"))
    (mutecipher-acp2--do-prompt session-id text)))

;;;###autoload
(defun mutecipher/acp2-prompt-region (beg end)
  "Send the active region (BEG to END) as a prompt to the current ACP2 session."
  (interactive "r")
  (unless (use-region-p)
    (user-error "ACP2: no region selected"))
  (mutecipher/acp2-prompt (buffer-substring-no-properties beg end)))

;;;###autoload
(defun mutecipher/acp2-cancel ()
  "Cancel the ongoing ACP2 request for the current session."
  (interactive)
  (let ((session-id (or mutecipher-acp2--session-id
                        (mutecipher-acp2--pick-session))))
    (unless session-id
      (user-error "ACP2: no active session"))
    (let* ((session (gethash session-id mutecipher-acp2--sessions))
           (conn    (plist-get session :conn)))
      (mutecipher-acp2--request
       conn "session/cancel"
       (list :sessionId session-id)
       :success-fn (lambda (_) (message "ACP2: cancelled"))
       :error-fn   (lambda (_) (message "ACP2: cancel failed"))))))

;;;###autoload
(defun mutecipher/acp2-kill-session ()
  "Kill the current ACP2 session and its output and input buffers."
  (interactive)
  (let ((session-id (or mutecipher-acp2--session-id
                        (mutecipher-acp2--pick-session))))
    (unless session-id
      (user-error "ACP2: no active session"))
    (let* ((session   (gethash session-id mutecipher-acp2--sessions))
           (conn      (plist-get session :conn))
           (buf       (plist-get session :buffer))
           (input-buf (plist-get session :input-buffer)))
      (mutecipher-acp2--request
       conn "session/cancel"
       (list :sessionId session-id)
       :success-fn (lambda (_) nil)
       :error-fn   (lambda (_) nil))
      (when-let ((t0 (plist-get session :state-timer)))
        (cancel-timer t0))
      (when-let ((t1 (plist-get session :align-timer)))
        (cancel-timer t1))
      (remhash session-id mutecipher-acp2--sessions)
      (when (buffer-live-p buf)       (kill-buffer buf))
      (when (buffer-live-p input-buf) (kill-buffer input-buf))
      (message "ACP2: session %s killed" session-id))))

;;;###autoload
(defun mutecipher/acp2-set-config (key value)
  "Set a session config option KEY to VALUE for the current ACP2 session."
  (interactive
   (let* ((k (completing-read "Config key: "
                              '("model" "mode" "thoughtLevel") nil nil))
          (v (read-string (format "Value for %s: " k))))
     (list k v)))
  (let ((session-id (or mutecipher-acp2--session-id
                        (mutecipher-acp2--pick-session))))
    (unless session-id
      (user-error "ACP2: no active session"))
    (let* ((session (gethash session-id mutecipher-acp2--sessions))
           (conn    (plist-get session :conn)))
      (mutecipher-acp2--request
       conn "session/set_config_option"
       (list :sessionId session-id :key key :value value)
       :success-fn (lambda (_) (message "ACP2: set %s = %s" key value))
       :error-fn   (lambda (err)
                     (message "ACP2 set_config_option failed: %s"
                              (plist-get err :message)))))))

;;;###autoload
(defun mutecipher/acp2-set-model (value)
  "Set the current session's model to VALUE."
  (interactive "sModel: ")
  (mutecipher/acp2-set-config "model" value))

;;;###autoload
(defun mutecipher/acp2-set-mode (value)
  "Set the current session's mode to VALUE."
  (interactive "sMode: ")
  (mutecipher/acp2-set-config "mode" value))

;;;###autoload
(defun mutecipher/acp2-set-thought-level (value)
  "Set the current session's thoughtLevel to VALUE."
  (interactive "sThought level: ")
  (mutecipher/acp2-set-config "thoughtLevel" value))

;;;###autoload
(defun mutecipher/acp2-list-sessions ()
  "Pick an active ACP2 session and switch to its output buffer."
  (interactive)
  (let ((sessions (hash-table-values mutecipher-acp2--sessions)))
    (unless sessions
      (user-error "ACP2: no active sessions"))
    (let* ((entries (mapcar
                     (lambda (s)
                       (cons (format "%-10s  %-20s  %s"
                                     (or (plist-get s :agent) "?")
                                     (or (plist-get s :state) 'idle)
                                     (mutecipher-acp2--id-prefix (plist-get s :id)))
                             (plist-get s :id)))
                     sessions))
           (choice  (completing-read "ACP2 session: "
                                     (mapcar #'car entries) nil t))
           (sid     (cdr (assoc choice entries))))
      (when-let* ((s   (gethash sid mutecipher-acp2--sessions))
                  (buf (plist-get s :buffer)))
        (pop-to-buffer buf)))))

;;;###autoload (autoload 'mutecipher/acp2-dispatch "mutecipher-acp2" nil t)
(transient-define-prefix mutecipher/acp2-dispatch ()
  "Dispatch menu for ACP2 session commands."
  ["Session"
   ("n" "New"           mutecipher/acp2-start)
   ("r" "Resume"        mutecipher/acp2-resume)
   ("l" "List / switch" mutecipher/acp2-list-sessions)
   ("c" "Cancel"        mutecipher/acp2-cancel)
   ("k" "Kill"          mutecipher/acp2-kill-session)]
  ["Config"
   ("m" "Model"         mutecipher/acp2-set-model)
   ("M" "Mode"          mutecipher/acp2-set-mode)
   ("t" "Thought level" mutecipher/acp2-set-thought-level)
   ("o" "Other option"  mutecipher/acp2-set-config)]
  ["Debug"
   ("L" "Show log"      mutecipher/acp2-show-log)
   ("C" "Clear log"     mutecipher/acp2-clear-log)]
  ["Help"
   ("?" "Describe mode" describe-mode)])

;;;; Helper

(defun mutecipher-acp2--pick-session ()
  "Return a session-id string, or nil if none exist."
  (let ((ids (hash-table-keys mutecipher-acp2--sessions)))
    (cond
     ((null ids)         nil)
     ((= 1 (length ids)) (car ids))
     (t (completing-read "ACP2 session: " ids nil t)))))

(provide 'mutecipher-acp2)
;;; mutecipher-acp2.el ends here
