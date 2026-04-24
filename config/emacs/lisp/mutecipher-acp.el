;;; mutecipher-acp.el --- ACP client, ewoc-based rewrite (WIP)  -*- lexical-binding: t -*-
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
(require 'diff-mode)
(require 'ewoc)
(require 'json)
(require 'mutecipher-icons)
(require 'project)
(require 'ring)
(require 'transient)
(require 'url-util)

;;;; Customization

(defgroup mutecipher-acp nil
  "ACP (Agent Client Protocol) client, ewoc-based rewrite."
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

(defcustom mutecipher-acp-diff-max-lines 500
  "Maximum old/new line count before inline tool-call diffs are summarized.
When either side of a diff exceeds this, the diff body is skipped and a
single summary line is shown instead."
  :type 'integer
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-variable-pitch nil
  "When non-nil, render session buffers with `variable-pitch-mode'.
Prose reads nicer but table alignment, hanging-indent widths, and the
ExitPlanMode plan-body gutter all rely on monospace character widths;
enable at your own aesthetic-vs-alignment tradeoff.  Off by default."
  :type 'boolean
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-log-max-line 800
  "Maximum characters shown per log line in `*ACP-log*'.
Longer entries are truncated with a `…(+N chars)' tail so file contents
and large payloads don't bloat the buffer."
  :type 'integer
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-log-keep-lines 5000
  "Maximum lines retained in `*ACP-log*'; older lines are trimmed."
  :type 'integer
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

(defface mutecipher-acp-status-idle-face
  '((t :inherit success))
  "Mode-line face used when the session is idle.")

(defface mutecipher-acp-status-busy-face
  '((t :inherit font-lock-comment-face))
  "Mode-line face used while the agent is thinking or streaming.")

(defface mutecipher-acp-status-await-face
  '((t :inherit warning))
  "Mode-line face used while awaiting a permission decision.")

(defface mutecipher-acp-status-error-face
  '((t :inherit error))
  "Mode-line face used after a request errors.")

(defface mutecipher-acp-hint-face
  '((t :inherit shadow))
  "Face for dimmed hint/help text in input and header lines.")

(defface mutecipher-acp-separator-face
  '((t :inherit shadow :strike-through t))
  "Face for the horizontal rule separating turns.
Renders as a theme-derived dim strike-through on a propertized space.")

(defface mutecipher-acp-disclosure-face
  '((t :inherit shadow))
  "Face for the ▸/▾ (or chevron) disclosure glyph on collapsible nodes.")

(defface mutecipher-acp-plan-gutter-face
  '((t :inherit font-lock-comment-delimiter-face))
  "Face for the `│' gutter rendered alongside ExitPlanMode plan bodies.")

(defface mutecipher-acp-pulse-face
  '((t :inherit pulse-highlight-start-face))
  "Face used by `pulse-momentary-highlight-region' after node invalidations.")

(defface mutecipher-acp-prompt-glyph-face
  '((t :inherit mutecipher-acp-user-face :weight bold))
  "Face for the `❯' prompt glyph in the ACP input buffer.")

(defface mutecipher-acp-mode-default-face
  '((t :inherit mutecipher-acp-user-face))
  "Header face for the default session mode.")

(defface mutecipher-acp-mode-auto-accept-face
  '((t :foreground "#e5a50a" :weight bold))
  "Header face for auto-accept session mode.")

(defface mutecipher-acp-mode-plan-face
  '((t :foreground "#56b6c2" :weight bold))
  "Header face for plan session mode.")

(defface mutecipher-acp-mode-bypass-face
  '((t :foreground "#e06c75" :weight bold))
  "Header face for bypass-permissions session mode.")

(defface mutecipher-acp-mode-dont-ask-face
  '((t :foreground "#a07840" :weight bold))
  "Header face for dont-ask session mode.")

(defcustom mutecipher-acp-mode-indicators
  `(("default"           ,(string #xf0ac3) mutecipher-acp-mode-default-face)     ; nf-md-shield
    ("auto"              ,(string #xf0f4f) mutecipher-acp-mode-auto-accept-face)  ; nf-md-lightning-bolt
    ("acceptEdits"       ,(string #xf05e0) mutecipher-acp-mode-auto-accept-face)  ; nf-md-check-circle
    ("plan"              ,(string #xf0932) mutecipher-acp-mode-plan-face)         ; nf-md-clipboard-list
    ("dontAsk"           ,(string #xf0159) mutecipher-acp-mode-dont-ask-face)     ; nf-md-cancel
    ("bypassPermissions" ,(string #xf0e9b) mutecipher-acp-mode-bypass-face))     ; nf-md-shield-off
  "Alist mapping modeId to (icon face) for session header display.
Unknown mode IDs fall back to (\"?\" mutecipher-acp-mode-default-face)."
  :type '(alist :key-type string
                :value-type (list string face))
  :group 'mutecipher-acp)

;;;; Data model
;;
;; Every visible thing in the transcript buffer is an ewoc node whose
;; `data' is a `macp-node'.  The master pretty-printer
;; `mutecipher-acp--pp' dispatches on `macp-node-kind' to kind-specific
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
;; Lives in `*ACP-log*'; switch to it with `mutecipher/acp-show-log'.
;; Each entry is timestamped and tagged with a direction indicator:
;;   →  outbound (we sent it)
;;   ←  inbound  (agent sent it)
;; Long payloads are truncated per `mutecipher-acp-log-max-line'.

(defconst mutecipher-acp--log-buffer-name "*ACP-log*")

(defun mutecipher-acp--log-buffer ()
  "Return the `*ACP-log*' buffer, creating it if necessary."
  (let ((buf (get-buffer-create mutecipher-acp--log-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode)
        (special-mode)
        (setq-local truncate-lines t)
        (setq-local buffer-undo-list t)))
    buf))

(defun mutecipher-acp--log-truncate (s)
  "Return S truncated to `mutecipher-acp-log-max-line', with an overflow tail."
  (if (<= (length s) mutecipher-acp-log-max-line)
      s
    (format "%s…(+%d chars)"
            (substring s 0 mutecipher-acp-log-max-line)
            (- (length s) mutecipher-acp-log-max-line))))

(defun mutecipher-acp--log (tag agent payload)
  "Append a log entry to `*ACP-log*'.
TAG is a short direction/kind marker (\"→\", \"←\", \"agent→\", etc.).
AGENT is the connection/agent label for the entry.  PAYLOAD is the raw
JSON line or a preformatted string."
  (let ((buf (mutecipher-acp--log-buffer))
        (ts  (format-time-string "%H:%M:%S.%3N"))
        (line (mutecipher-acp--log-truncate (or payload ""))))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (was-at-end (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert (format "%s %s %-10s %s\n"
                          ts tag (or agent "") line))
          (let ((excess (- (count-lines (point-min) (point-max))
                           mutecipher-acp-log-keep-lines)))
            (when (> excess 0)
              (goto-char (point-min))
              (forward-line excess)
              (delete-region (point-min) (point)))))
        (when was-at-end
          (goto-char (point-max)))))))

;;;###autoload
(defun mutecipher/acp-show-log ()
  "Pop up the `*ACP-log*' protocol-trace buffer."
  (interactive)
  (pop-to-buffer (mutecipher-acp--log-buffer)))

;;;###autoload
(defun mutecipher/acp-clear-log ()
  "Erase the `*ACP-log*' buffer."
  (interactive)
  (with-current-buffer (mutecipher-acp--log-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer))))

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
            (mutecipher-acp--log "←" (process-name proc) line)
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
         (msg (list :jsonrpc "2.0" :id id :method method :params params))
         (line (json-serialize msg :null-object nil :false-object :json-false)))
    (puthash id (list success-fn error-fn) (mutecipher-acp--conn-pending conn))
    (mutecipher-acp--log "→" (process-name (mutecipher-acp--conn-process conn)) line)
    (process-send-string (mutecipher-acp--conn-process conn) (concat line "\n"))))

(defun mutecipher-acp--respond (conn id result)
  "Send a JSON-RPC response with ID and RESULT over CONN.
Used to reply to inbound requests from the agent."
  (let ((line (json-serialize (list :jsonrpc "2.0" :id id :result result)
                              :null-object nil :false-object :json-false)))
    (mutecipher-acp--log "→resp" (process-name (mutecipher-acp--conn-process conn)) line)
    (process-send-string (mutecipher-acp--conn-process conn) (concat line "\n"))))

(defun mutecipher-acp--respond-error (conn id code message)
  "Send a JSON-RPC error response with ID, error CODE and MESSAGE over CONN."
  (let ((line (json-serialize (list :jsonrpc "2.0" :id id
                                    :error (list :code code :message message))
                              :null-object nil :false-object :json-false)))
    (mutecipher-acp--log "→err" (process-name (mutecipher-acp--conn-process conn)) line)
    (process-send-string (mutecipher-acp--conn-process conn) (concat line "\n"))))

;;;; State

(defvar mutecipher-acp--connections (make-hash-table :test #'equal)
  "Hash table mapping agent-name strings to mutecipher-acp--conn structs.")

(defvar mutecipher-acp--sessions (make-hash-table :test #'equal)
  "Hash table mapping session-id strings to session plists.")

(defvar-local mutecipher-acp--session-id nil
  "Session ID associated with the current ACP buffer (output or input).")

(defvar-local mutecipher-acp--ewoc nil
  "The ewoc managing the current ACP session buffer's transcript.")

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
                             (mutecipher-acp--respond conn id (list :content content)))
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
                             (when-let ((buf (find-buffer-visiting abs-path)))
                               (when (not (buffer-modified-p buf))
                                 (with-current-buffer buf
                                   (revert-buffer t t t))))
                             (mutecipher-acp--respond conn id (list)))
                         (error
                          (mutecipher-acp--respond-error conn id -32000
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

(defun mutecipher-acp--handle-permission (conn rpc-id params)
  "Prompt user for permission and send JSON-RPC response with RPC-ID over CONN."
  (let* ((session-id  (plist-get params :sessionId))
         (options     (plist-get params :options))
         (labels      (mapcar #'mutecipher-acp--option-label options))
         (prior-state (when-let ((s (gethash session-id mutecipher-acp--sessions)))
                        (plist-get s :state))))
    (mutecipher-acp--set-state session-id 'awaiting-permission)
    (unwind-protect
        (condition-case _
            (let* ((chosen-label (completing-read "[ACP] Permission: " labels nil t))
                   (chosen-id    (mutecipher-acp--option-id
                                  (seq-find (lambda (o)
                                              (equal (mutecipher-acp--option-label o) chosen-label))
                                            options))))
              (mutecipher-acp--respond
               conn rpc-id
               (list :outcome (list :outcome "selected" :optionId chosen-id))))
          (quit
           (mutecipher-acp--respond
            conn rpc-id
            (list :outcome (list :outcome "cancelled")))))
      (mutecipher-acp--set-state session-id (or prior-state 'thinking)))))

;;;; Pulse flash on node invalidate
;;
;; Visual cue that "this node just changed" — a ~0.3s background pulse
;; over the invalidated node's region.  Applied to tool-call updates
;; and live plan mutations; NOT to assistant streaming (fires too often,
;; would strobe the buffer).

(require 'pulse)

(defun mutecipher-acp--pulse-node (ewoc node)
  "Pulse-highlight the buffer region spanned by NODE in EWOC."
  (when (and ewoc node (fboundp 'pulse-momentary-highlight-region))
    (let* ((beg  (ewoc-location node))
           (next (ewoc-next ewoc node))
           (end  (if next (ewoc-location next) (point-max))))
      (when (and beg (> end beg))
        (pulse-momentary-highlight-region
         beg end 'mutecipher-acp-pulse-face)))))

;;;; Sticky-tail auto-scroll
;;
;; Without help, `ewoc-invalidate' and `ewoc-enter-last' grow or mutate
;; buffer content without moving window-point.  The user's natural
;; expectation is "if I'm at the bottom, keep showing me the tail — if
;; I've scrolled up to read, leave me alone."  This macro captures which
;; windows were at `point-max' before the body runs, then re-anchors
;; just those windows to the new `point-max' afterwards.

(defmacro mutecipher-acp--with-sticky-tail (buf &rest body)
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

(defun mutecipher-acp--append-assistant-chunk (session-id text)
  "Append TEXT to SESSION-ID's current assistant node, creating one if needed.
Invalidates only that node so the rest of the transcript is untouched.
Trims leading whitespace off the very first chunk so agents that start
a response with a stray `\\n' don't leave the icon alone on a line."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--with-sticky-tail buf
      (unless mutecipher-acp--ewoc
        (user-error "ACP: no ewoc in session buffer"))
      (let* ((ewoc mutecipher-acp--ewoc)
             (node (plist-get session :current-assistant))
             (inhibit-read-only t))
        (unless node
          (setq node (ewoc-enter-last
                      ewoc
                      (make-macp-node :kind 'assistant
                                      :data (make-macp-assistant :text ""))))
          (puthash session-id
                   (plist-put session :current-assistant node)
                   mutecipher-acp--sessions))
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
    (when (plist-get session :current-assistant)
      (puthash session-id
               (plist-put session :current-assistant nil)
               mutecipher-acp--sessions))))

(defun mutecipher-acp--ingest-tool-content (tc content-vec)
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

(defun mutecipher-acp--raw-input-plan (raw-in)
  "Return the `:plan' string from RAW-IN, or nil.
Only returns strings — `ExitPlanMode' sends the proposed plan here as a
long markdown block that deserves inline rendering instead of being
truncated into the tool-call header."
  (let ((p (and (listp raw-in) (plist-get raw-in :plan))))
    (and (stringp p) (not (string-empty-p p)) p)))

(defun mutecipher-acp--enter-tool-call (session-id update)
  "Create a tool-call ewoc node from UPDATE and register it in SESSION-ID's index."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf))
              (index   (plist-get session :tool-call-index)))
    (mutecipher-acp--close-assistant session-id)
    (let* ((cc-name (plist-get (plist-get (plist-get update :_meta) :claudeCode) :toolName))
           (name    (or cc-name (plist-get update :title) (plist-get update :kind) "tool"))
           (raw-in  (plist-get update :rawInput))
           (plan    (mutecipher-acp--raw-input-plan raw-in))
           (detail  (mutecipher-acp--format-tool-input raw-in))
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
      (mutecipher-acp--ingest-tool-content tc (plist-get update :content))
      (mutecipher-acp--with-sticky-tail buf
        (let* ((inhibit-read-only t)
               (node (ewoc-enter-last
                      mutecipher-acp--ewoc
                      (make-macp-node :kind 'tool-call :data tc))))
          (when call-id
            (puthash call-id node index)))))))

(defun mutecipher-acp--enter-notice (session-id text &optional face)
  "Enter a notice node in SESSION-ID's ewoc with TEXT and optional FACE."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (plist-get session :buffer))
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
              (buf     (plist-get session :buffer))
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
              (buf     (plist-get session :buffer))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t)
            (existing (plist-get session :current-plan-node)))
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
            (puthash session-id
                     (plist-put session :current-plan-node node)
                     mutecipher-acp--sessions))))))))

(defun mutecipher-acp--update-tool-call (session-id update)
  "Apply tool_call_update UPDATE to SESSION-ID's matching tool-call node."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
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
           (plan       (mutecipher-acp--raw-input-plan raw-in))
           (raw-out    (plist-get update :rawOutput)))
      (when (and (null status-str) cmd-title)
        (let* ((prefix (concat (macp-tool-call-name tc) " "))
               (detail (if (string-prefix-p prefix cmd-title)
                           (substring cmd-title (length prefix))
                         cmd-title)))
          (setf (macp-tool-call-input tc)
                (mutecipher-acp--format-tool-input detail))))
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
      (mutecipher-acp--ingest-tool-content tc (plist-get update :content))
      ;; Auto-collapse on completion when output is long or diffs exist.
      ;; Plans (ExitPlanMode-style) are a hard opt-out: the whole point
      ;; of that tool call is the plan body, so we never auto-collapse it.
      (when (and (memq (macp-tool-call-status tc) '(done error))
                 (not (macp-node-collapsed wrapper))
                 (not (macp-tool-call-plan-body tc))
                 (or (> (mutecipher-acp--tool-output-line-count
                         (macp-tool-call-raw-output tc))
                        3)
                     (macp-tool-call-diffs tc)))
        (setf (macp-node-collapsed wrapper) t))
      (mutecipher-acp--with-sticky-tail buf
        (let ((inhibit-read-only t))
          (ewoc-invalidate mutecipher-acp--ewoc node)
          ;; Pulse only on terminal status transitions so chatty
          ;; in_progress / content-only updates don't strobe the buffer.
          (when (memq (macp-tool-call-status tc) '(done error))
            (mutecipher-acp--pulse-node mutecipher-acp--ewoc node)))))))

(defun mutecipher-acp--handle-notification (method params)
  "Dispatch an incoming JSON-RPC notification with METHOD and PARAMS."
  (let ((session-id (plist-get params :sessionId))
        (update     (plist-get params :update)))
    (cond
     ((equal method "session/update")
      (when session-id
        (let ((type (plist-get update :sessionUpdate)))
          (cond
           ((equal type "agent_message_chunk")
            (when-let ((s (gethash session-id mutecipher-acp--sessions)))
              (when (eq (plist-get s :state) 'thinking)
                (mutecipher-acp--set-state session-id 'streaming)))
            (let ((text (or (plist-get (plist-get update :content) :text) "")))
              (mutecipher-acp--append-assistant-chunk session-id text)))
           ((equal type "tool_call")
            (mutecipher-acp--enter-tool-call session-id update))
           ((equal type "tool_call_update")
            (mutecipher-acp--update-tool-call session-id update))
           ((equal type "thought")
            (mutecipher-acp--close-assistant session-id)
            (mutecipher-acp--enter-thought session-id
                                            (or (plist-get update :thought) "")))
           ((equal type "plan")
            (mutecipher-acp--close-assistant session-id)
            (mutecipher-acp--enter-plan session-id
                                         (plist-get update :tasks)))
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
                         mutecipher-acp--sessions))))
           ((equal type "current_mode_update")
            (let* ((new-id  (plist-get update :currentModeId))
                   (session (gethash session-id mutecipher-acp--sessions)))
              (when (and session new-id)
                (plist-put session :current-mode-id new-id)
                (mutecipher-acp--force-input-mode-line session)
                (let* ((avail (plist-get session :available-modes))
                       (m     (and avail (mutecipher-acp--find-mode new-id avail))))
                  (message "Mode → %s" (or (and m (plist-get m :name)) new-id))))))
           (t
            (message "ACP [%s] update: %s (unhandled)"
                     (mutecipher-acp--id-prefix session-id) type))))))
     (t
      (message "ACP notification: %s" method)))))

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

;;;; Protocol helpers

(defun mutecipher-acp--make-session-plist (session-id conn buf agent cwd)
  "Return a fresh session plist with all slots initialised to their defaults."
  (list :id session-id :conn conn :buffer buf :agent agent :cwd cwd
        :input-buffer nil
        :state 'idle
        :state-started-at nil
        :state-timer nil
        :commands nil
        :file-cache nil
        :turn-counter 0
        :current-turn-node nil
        :current-assistant nil
        :current-plan-node nil
        :available-modes nil
        :current-mode-id nil
        :tool-call-index (make-hash-table :test #'equal)))

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
            (session      (mutecipher-acp--make-session-plist
                           session-id conn buf agent-name cwd)))
       (plist-put session :available-modes avail-modes)
       (plist-put session :current-mode-id current-mode)
       (puthash session-id session mutecipher-acp--sessions)
       (funcall callback session-id buf)))
   :error-fn
   (lambda (err)
     (message "ACP session/new failed: %s" (plist-get err :message)))))

(defun mutecipher-acp--load-session (conn session-id agent-name cwd callback)
  "Resume SESSION-ID via session/load on CONN; call CALLBACK with (session-id buf).
The session plist is created eagerly so replayed notifications have
somewhere to land before the success callback fires."
  (let* ((buf     (mutecipher-acp--get-or-create-buffer session-id agent-name))
         (session (mutecipher-acp--make-session-plist
                   session-id conn buf agent-name cwd)))
    (puthash session-id session mutecipher-acp--sessions)
    (mutecipher-acp--request
     conn "session/load" (list :sessionId session-id)
     :success-fn (lambda (_) (funcall callback session-id buf))
     :error-fn   (lambda (err)
                   (remhash session-id mutecipher-acp--sessions)
                   (kill-buffer buf)
                   (message "ACP session/load failed: %s"
                            (plist-get err :message))))))

;;;; Prompt attachments (@-mentions)

(defconst mutecipher-acp--file-cache-ttl 30
  "Seconds before `mutecipher-acp--session-files' re-walks a session's cwd.")

(defconst mutecipher-acp--file-cache-cap 2000
  "Maximum number of candidate files returned per session.")

(defconst mutecipher-acp--file-exclude-dirs
  '(".git" "node_modules" ".direnv" ".venv" "vendor" "elpa" ".cache")
  "Directory basenames skipped by the fs fallback walker.")

(defun mutecipher-acp--path->file-uri (abs-path)
  "Return a file:// URI for ABS-PATH with path segments percent-encoded."
  (concat "file://"
          (mapconcat #'url-hexify-string
                     (split-string (expand-file-name abs-path) "/")
                     "/")))

(defun mutecipher-acp--walk-cwd (cwd)
  "Walk CWD collecting relative file paths, skipping excluded dirs.
Returns a list sorted shallowest-first, capped at
`mutecipher-acp--file-cache-cap'."
  (let ((root (file-name-as-directory (expand-file-name cwd)))
        (acc '())
        (count 0)
        (queue (list (file-name-as-directory (expand-file-name cwd)))))
    (while (and queue (< count mutecipher-acp--file-cache-cap))
      (let ((dir (pop queue))
            (new-dirs nil))
        (dolist (entry (ignore-errors
                         (directory-files
                          dir t directory-files-no-dot-files-regexp t)))
          (cond
           ((file-directory-p entry)
            (unless (member (file-name-nondirectory entry)
                            mutecipher-acp--file-exclude-dirs)
              (push (file-name-as-directory entry) new-dirs)))
           ((file-regular-p entry)
            (push (file-relative-name entry root) acc)
            (setq count (1+ count)))))
        (when new-dirs
          (setq queue (nconc queue (nreverse new-dirs))))))
    (sort acc (lambda (a b)
                (let ((da (cl-count ?/ a))
                      (db (cl-count ?/ b)))
                  (if (= da db) (string< a b) (< da db)))))))

(defun mutecipher-acp--session-files (session)
  "Return a cached (SOURCE . LIST) pair of relative paths for SESSION's :cwd.
SOURCE is the symbol `project' or `fs'."
  (let* ((cwd   (plist-get session :cwd))
         (cache (plist-get session :file-cache))
         (now   (float-time)))
    (if (and cache
             (< (- now (nth 0 cache)) mutecipher-acp--file-cache-ttl))
        (cons (nth 1 cache) (nth 2 cache))
      (let* ((proj  (and cwd
                         (let ((default-directory cwd))
                           (project-current nil cwd))))
             (files (if proj
                        (mapcar (lambda (f) (file-relative-name f cwd))
                                (project-files proj))
                      (and cwd (mutecipher-acp--walk-cwd cwd))))
             (source (if proj 'project 'fs))
             (capped (if (> (length files) mutecipher-acp--file-cache-cap)
                         (seq-take files mutecipher-acp--file-cache-cap)
                       files)))
        (puthash (plist-get session :id)
                 (plist-put session :file-cache (list now source capped))
                 mutecipher-acp--sessions)
        (cons source capped)))))

(defun mutecipher-acp--extract-attachments (text cwd)
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

(defun mutecipher-acp--prompt-blocks (text cwd)
  "Return the :prompt vector for TEXT resolved against CWD."
  (let* ((attachments (mutecipher-acp--extract-attachments text cwd))
         (text-block  (list :type "text" :text text))
         (link-blocks (mapcar
                       (lambda (a)
                         (let ((abs (cdr a)))
                           (list :type "resource_link"
                                 :uri  (mutecipher-acp--path->file-uri abs)
                                 :name (file-name-nondirectory abs))))
                       attachments)))
    (apply #'vector text-block link-blocks)))

;;;; Completion-at-point functions

(defun mutecipher-acp--commands-capf ()
  "Completion-at-point function for ACP slash commands.
Activates when the current line begins with \"/\"."
  (when-let* ((session-id mutecipher-acp--session-id)
              (session    (gethash session-id mutecipher-acp--sessions))
              (commands   (plist-get session :commands))
              (_ (save-excursion
                   (beginning-of-line)
                   (looking-at "/"))))
    (let* ((slash-pos (save-excursion (beginning-of-line) (point)))
           (word-end  (point))
           (cmd-map   (mapcar (lambda (c)
                                (cons (concat "/" (plist-get c :name))
                                      (plist-get c :description)))
                              commands)))
      (list slash-pos word-end (mapcar #'car cmd-map)
            :annotation-function
            (lambda (name)
              (when-let ((desc (cdr (assoc name cmd-map))))
                (concat "  " desc)))
            :company-kind (lambda (_) 'keyword)))))

(defun mutecipher-acp--files-capf ()
  "Completion-at-point function for @-mention file attachments."
  (when-let* ((session-id mutecipher-acp--session-id)
              (session    (gethash session-id mutecipher-acp--sessions))
              (at-pos     (save-excursion
                            (skip-chars-backward "^ \t\n")
                            (and (eq (char-after) ?@) (point)))))
    (let* ((cache      (mutecipher-acp--session-files session))
           (source     (car cache))
           (files      (cdr cache))
           (candidates (mapcar (lambda (f) (concat "@" f)) files))
           (tag        (if (eq source 'project) "[project]" "[fs]")))
      (list at-pos (point) candidates
            :annotation-function (lambda (_) (concat "  " tag))
            :exclusive 'no
            :exit-function (lambda (_s status)
                             (when (eq status 'finished)
                               (insert " ")))
            :company-kind (lambda (_) 'file)))))

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
  "Master ewoc pretty-printer: dispatch on NODE kind."
  (pcase (macp-node-kind node)
    ('turn-header (mutecipher-acp--pp-turn-header node))
    ('user        (mutecipher-acp--pp-user        node))
    ('assistant   (mutecipher-acp--pp-assistant   node))
    ('thought     (mutecipher-acp--pp-thought     node))
    ('tool-call   (mutecipher-acp--pp-tool-call   node))
    ('plan        (mutecipher-acp--pp-plan        node))
    ('trailer     (mutecipher-acp--pp-trailer     node))
    ('notice      (mutecipher-acp--pp-notice      node))
    (other        (insert (format "[acp: unknown node kind: %s]\n" other)))))

(defun mutecipher-acp--gutter (icon-kind)
  "Return (PREFIX . INDENT) for a hanging-indent layout keyed by ICON-KIND.
PREFIX is `  <icon> ' for the first display line; INDENT is matching
whitespace so logical-newline and wrapped continuations align under the
body.  Falls back to two-space prefix if the icon isn't available."
  (let* ((icon   (or (and (fboundp 'mutecipher/icon-for-acp)
                          (mutecipher/icon-for-acp icon-kind))
                     " "))
         (prefix (concat "  " icon " "))
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
  "Render a turn-header NODE: for turns >1, emit a full-width hrule separator."
  (let* ((turn (macp-node-data node))
         (id   (macp-turn-id turn)))
    (if (and id (> id 1))
        (insert "\n"
                (propertize " "
                            'display '(space :align-to right)
                            'face 'mutecipher-acp-separator-face)
                "\n\n")
      (insert ""))))

(defun mutecipher-acp--pp-user (node)
  "Render a user NODE: `user' icon gutter + hanging-indent body."
  (let ((text (or (macp-user-text (macp-node-data node)) "")))
    (mutecipher-acp--insert-with-gutter 'user text 'mutecipher-acp-user-face)
    (insert "\n\n")))

(defun mutecipher-acp--pp-assistant (node)
  "Render an assistant NODE: `assistant' icon gutter + hanging-indent prose.
Applies minimal markdown overlays over the inserted body."
  (let* ((text       (or (macp-assistant-text (macp-node-data node)) ""))
         (body-start (mutecipher-acp--insert-with-gutter 'assistant text)))
    (unless (or (string-empty-p text)
                (eq (aref text (1- (length text))) ?\n))
      (insert "\n"))
    (mutecipher-acp--apply-markdown body-start (point))))

(defun mutecipher-acp--pp-thought (node)
  "Render a thought NODE: `thought' icon gutter + italic shadow-faced text."
  (let ((text (or (macp-thought-text (macp-node-data node)) "")))
    (mutecipher-acp--insert-with-gutter 'thought
                                         (concat text "\n")
                                         'mutecipher-acp-thought-face)))

(defun mutecipher-acp--format-tool-input (raw &optional max-len)
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
                                    (mutecipher-acp--format-tool-input (aref raw 0) max))))))
        (when s
          (let* ((s1 (replace-regexp-in-string "\n" "\\\\n" (string-trim s)))
                 (s1 (replace-regexp-in-string "[ \t]+" " " s1)))
            (if (> (length s1) max)
                (concat (substring s1 0 (1- max)) "…")
              s1)))))))

(defun mutecipher-acp--generate-unified-diff (old-text new-text)
  "Return the hunk body comparing OLD-TEXT and NEW-TEXT as a unified diff.
File headers and any trailing `Diff finished' line are stripped; result
starts at the first `@@' line.  Returns nil if the texts are identical."
  (let ((old-buf (generate-new-buffer " *acp-diff-old*"))
        (new-buf (generate-new-buffer " *acp-diff-new*"))
        (out-buf (generate-new-buffer " *acp-diff*")))
    (unwind-protect
        (progn
          (with-current-buffer old-buf (insert (or old-text "")))
          (with-current-buffer new-buf (insert (or new-text "")))
          (diff-no-select old-buf new-buf "-u" t out-buf)
          (with-current-buffer out-buf
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (when (re-search-backward "^Diff finished" nil t)
                (delete-region (line-beginning-position) (point-max)))
              (goto-char (point-min))
              (when (re-search-forward "^@@" nil t)
                (buffer-substring-no-properties
                 (line-beginning-position) (point-max))))))
      (dolist (b (list old-buf new-buf out-buf))
        (when (buffer-live-p b) (kill-buffer b))))))

(defun mutecipher-acp--flatten-face-overlays ()
  "Convert `face' overlays in the current buffer to text properties.
`buffer-string' preserves text properties but not overlays, so any
fontifier that uses overlays (notably `diff-refine-hunk') needs this
pass before the string is extracted."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when-let ((face (overlay-get ov 'face)))
      (add-face-text-property (overlay-start ov) (overlay-end ov) face))
    (delete-overlay ov)))

(defun mutecipher-acp--fontify-diff-string (s)
  "Return S with `diff-mode' font-lock and per-hunk refinement applied.
Hunk headers, added/removed lines, and within-line refinement
(`diff-refine-added' / `diff-refine-removed') all come along as text
properties in the returned string."
  (with-temp-buffer
    (insert s)
    (delay-mode-hooks (diff-mode))
    (font-lock-ensure)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward diff-hunk-header-re nil t)
        (ignore-errors (diff-refine-hunk))))
    (mutecipher-acp--flatten-face-overlays)
    (buffer-string)))

(defun mutecipher-acp--transfer-faces (src buffer-beg)
  "Copy `face' text properties from string SRC onto the current buffer.
Properties are applied starting at BUFFER-BEG, character-by-character,
via `add-face-text-property' so they compose with existing faces rather
than replacing them."
  (let ((i 0) (len (length src)))
    (while (< i len)
      (let* ((next (or (next-single-property-change i 'face src) len))
             (face (get-text-property i 'face src)))
        (when face
          (add-face-text-property (+ buffer-beg i) (+ buffer-beg next) face))
        (setq i next)))))

(defun mutecipher-acp--diff-body-for (old-text new-text)
  "Return a renderable diff body (propertized string) for OLD-TEXT → NEW-TEXT.
Honors `mutecipher-acp-diff-max-lines' — oversize diffs render as a one-line
summary instead."
  (let* ((old (or old-text ""))
         (new (or new-text ""))
         (old-lines (1+ (cl-count ?\n old)))
         (new-lines (1+ (cl-count ?\n new)))
         (over (or (> old-lines mutecipher-acp-diff-max-lines)
                   (> new-lines mutecipher-acp-diff-max-lines))))
    (if over
        (propertize
         (format "  … diff suppressed (%d old, %d new lines)\n"
                 old-lines new-lines)
         'face 'shadow)
      (when-let ((diff-str (mutecipher-acp--generate-unified-diff old new)))
        (concat "\n"
                (mutecipher-acp--fontify-diff-string
                 (string-trim-right diff-str "\n"))
                "\n")))))

(defun mutecipher-acp--tool-output-line-count (raw)
  "Return the line count of RAW (0 if nil or empty)."
  (cond
   ((or (null raw) (string-empty-p raw)) 0)
   (t (1+ (cl-count ?\n raw)))))

(defun mutecipher-acp--tool-kind-icon-key (kind)
  "Map a tool-call KIND string from ACP to a `mutecipher-icons-acp-alist' key."
  (pcase kind
    ("edit"     'tool-edit)
    ("write"    'tool-write)
    ("execute"  'tool-bash)
    ("read"     'tool-read)
    ("search"   'tool-grep)
    (_          'tool-other)))

(defun mutecipher-acp--status-icon-key (status)
  "Map a macp-tool-call STATUS symbol to an icon alist key."
  (pcase status
    ('pending 'status-pending)
    ('running 'status-running)
    ('done    'status-done)
    ('error   'status-error)))

(defun mutecipher-acp--icon-or (kind fallback)
  "Return the propertized icon for KIND, or FALLBACK string if unavailable."
  (or (and (fboundp 'mutecipher/icon-for-acp)
           (mutecipher/icon-for-acp kind))
      fallback))

(defun mutecipher-acp--pp-tool-call (node)
  "Render a tool-call NODE: disclosure + kind icon + summary + optional body.
Collapsed nodes show one summary line with a `+N lines' hint.  Expanded
nodes show the full raw output, inline plan body (for ExitPlanMode),
and any diff bodies."
  (let* ((tc         (macp-node-data node))
         (name       (or (macp-tool-call-name tc) "tool"))
         (input      (macp-tool-call-input tc))
         (status     (macp-tool-call-status tc))
         (raw-output (macp-tool-call-raw-output tc))
         (diffs      (macp-tool-call-diffs tc))
         (collapsed  (macp-node-collapsed node))
         (lines      (mutecipher-acp--tool-output-line-count raw-output))
         (disclosure (mutecipher-acp--icon-or
                      (if collapsed 'disclosure-collapsed 'disclosure-expanded)
                      (if collapsed "▸" "▾")))
         (kind-icon  (mutecipher-acp--icon-or
                      (mutecipher-acp--tool-kind-icon-key (macp-tool-call-kind tc))
                      "")))
    ;; Header: (disclosure) (kind icon) name(input)
    (insert "\n"
            "  "
            (propertize disclosure 'face 'mutecipher-acp-disclosure-face)
            " "
            kind-icon
            " "
            (propertize (concat name
                                (if input (concat "(" input ")") ""))
                        'face 'mutecipher-acp-tool-face)
            "\n")
    ;; Status / output line
    (pcase status
      ('done
       (let ((done-icon (mutecipher-acp--icon-or 'status-done "✓")))
         (cond
          (collapsed
           (let ((first (and raw-output (not (string-empty-p raw-output))
                             (car (split-string raw-output "\n"))))
                 (extra (max 0 (1- lines))))
             (insert "    "
                     done-icon
                     (propertize
                      (concat (if first (concat " " first) "")
                              (when (or (> extra 0) diffs)
                                (format " (+%d%s, TAB to expand)"
                                        extra
                                        (if diffs
                                            (format ", %d diff%s"
                                                    (length diffs)
                                                    (if (= 1 (length diffs)) "" "s"))
                                          "")))
                              "\n")
                      'face 'shadow))))
          (t
           (insert "    "
                   done-icon
                   (propertize
                    (concat (if (and raw-output (not (string-empty-p raw-output)))
                                (concat " " raw-output
                                        (unless (string-suffix-p "\n" raw-output)
                                          "\n"))
                              "\n"))
                    'face 'shadow))))))
      ('error
       (let ((err-icon (mutecipher-acp--icon-or 'status-error "✘")))
         (insert "    "
                 err-icon
                 (propertize
                  (concat " "
                          (or (and raw-output (not (string-empty-p raw-output))
                                   (if collapsed
                                       (car (split-string raw-output "\n"))
                                     (string-trim-right raw-output "\n")))
                              "failed")
                          "\n")
                  'face 'mutecipher-acp-error-face)))))
    ;; Expanded body: plan markdown + diffs
    (unless collapsed
      (when-let ((plan-body (macp-tool-call-plan-body tc)))
        (insert (propertize
                 (concat "\n"
                         (replace-regexp-in-string
                          "^"
                          (propertize "    │ " 'face 'mutecipher-acp-plan-gutter-face)
                          (string-trim-right plan-body "\n"))
                         "\n\n"))))
      (dolist (pair diffs)
        (when-let ((body (mutecipher-acp--diff-body-for (car pair) (cdr pair))))
          (insert body))))
    ;; Trailing blank line so the next node doesn't abut the tool-call card.
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

;;;; Minimal markdown rendering
;;
;; Applied imperatively from the pretty-printers via text properties —
;; NOT via font-lock.  Going through font-lock clobbered the `face'
;; properties our pretty-printers set on icons/glyphs/gutters, because
;; refontification treats the buffer as a "dumb" fontifiable region.
;; This approach applies overlays once per `ewoc-invalidate' (the pp
;; re-runs, re-applies), and leaves everything else alone.
;;
;; Scope deliberately tiny: `**text**' → `bold' face with hidden
;; markers.  Extend in pretty-printers with more patterns as needed.

(defvar mutecipher-acp--md-link-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")   #'mutecipher-acp--follow-md-link)
    (define-key map [mouse-2]     #'mutecipher-acp--follow-md-link)
    (define-key map [follow-link] 'mouse-face)
    map)
  "Keymap on inline markdown link text.  RET / mouse-2 → `browse-url'.")

(defun mutecipher-acp--follow-md-link (&optional _event)
  "Follow the inline markdown link at point."
  (interactive)
  (when-let ((url (get-text-property (point) 'mutecipher-acp-md-link)))
    (browse-url url)))

(defun mutecipher-acp--md-inside-code-p (pos)
  "Non-nil if the char at POS already carries `font-lock-constant-face'.
Used to gate non-code matchers so `*asterisks*' etc. *inside* an inline
code span don't get italicized/bolded.  Bold/italic spans that *wrap
around* a code span still apply — checking only the starting position
lets the faces compose via `add-face-text-property'."
  (let ((f (get-text-property pos 'face)))
    (or (eq f 'font-lock-constant-face)
        (and (listp f) (memq 'font-lock-constant-face f)))))

(defun mutecipher-acp--md-hide (beg end)
  "Mark region BEG..END invisible via `mutecipher-acp-md-markup'."
  (put-text-property beg end 'invisible 'mutecipher-acp-md-markup))

(defun mutecipher-acp--md-line-starts (beg end)
  "Return buffer positions of logical line starts in BEG..END.
Includes BEG as the first line even when BEG isn't preceded by a
newline — the assistant pretty-printer inserts body text inline after
the icon gutter, so the first body line has no leading `\\n' in the
buffer.  Returned positions are suitable starting points for per-line
`looking-at' matchers."
  (let (starts)
    (push beg starts)
    (save-excursion
      (goto-char beg)
      (while (and (< (point) end)
                  (search-forward "\n" end t))
        (when (<= (point) end)
          (push (point) starts))))
    (nreverse starts)))

(defun mutecipher-acp--apply-markdown (beg end)
  "Apply minimal markdown rendering to region BEG..END.

Covers inline: `` `inline code` '', `**bold**', `*italic*',
`~~strike~~', `[text](url)' links.  Block-level: fenced code blocks
```` ``` ````, ATX headings (# / ## / ###), blockquotes (> …), tables
(| … |), and task-list checkboxes (- [x] / - [ ]).  Markers that don't
carry meaning post-render hide via `mutecipher-acp-md-markup'.

Order runs code first so `*', `#', etc. inside code spans stay
literal; block-level patterns before inline so header/quote/cell
contents still compose bold/italic on top.  Idempotent — safe to call
repeatedly after `ewoc-invalidate'."
  (save-excursion
    (let ((line-starts (mutecipher-acp--md-line-starts beg end)))
      ;; 1. Fenced code blocks ``` … ``` (multi-line)
      ;;    Fence lines hide; body gets constant-face so later matchers
      ;;    skip via `--md-inside-code-p'.  A ```diff tag routes the body
      ;;    through `diff-mode' fontification instead of the plain wash.
      (let (open-beg open-body-beg open-lang)
        (dolist (start line-starts)
          (save-excursion
            (goto-char start)
            (when (looking-at "```\\([^\n]*\\)$")
              (let ((fence-beg (point))
                    (fence-eol (line-end-position))
                    (lang (string-trim (match-string-no-properties 1))))
                (cond
                 ((null open-beg)
                  (setq open-beg      fence-beg
                        open-body-beg (min end (1+ fence-eol))
                        open-lang     lang))
                 (t
                  (mutecipher-acp--md-hide open-beg open-body-beg)
                  (if (string= (downcase open-lang) "diff")
                      (let* ((body (buffer-substring-no-properties
                                    open-body-beg fence-beg))
                             (fontified
                              (mutecipher-acp--fontify-diff-string body)))
                        (mutecipher-acp--transfer-faces
                         fontified open-body-beg))
                    (add-face-text-property open-body-beg fence-beg
                                            'font-lock-constant-face))
                  (mutecipher-acp--md-hide fence-beg (min end (1+ fence-eol)))
                  (setq open-beg nil open-body-beg nil open-lang nil)))))))
        ;; Unclosed fence (still streaming) — face what we have so far.
        (when open-beg
          (mutecipher-acp--md-hide open-beg open-body-beg)
          (add-face-text-property open-body-beg end 'font-lock-constant-face)))
      ;; 2. Inline code `text`
      (goto-char beg)
      (while (re-search-forward "`\\([^`\n]+\\)`" end t)
        (let ((mb (match-beginning 0)) (me (match-end 0))
              (ib (match-beginning 1)) (ie (match-end 1)))
          (unless (mutecipher-acp--md-inside-code-p mb)
            (mutecipher-acp--md-hide mb (1+ mb))
            (add-face-text-property ib ie 'font-lock-constant-face)
            (mutecipher-acp--md-hide (1- me) me))))
      ;; 3. ATX headings: # / ## / ### at line start (line-1 aware)
      (dolist (start line-starts)
        (save-excursion
          (goto-char start)
          (when (looking-at "\\(#\\{1,3\\}\\) \\(.+\\)$")
            (let* ((hashes     (match-string 1))
                   (marker-beg (match-beginning 1))
                   (marker-end (1+ (match-end 1)))
                   (text-beg   marker-end)
                   (text-end   (match-end 2))
                   (height     (pcase (length hashes)
                                 (1 1.3) (2 1.2) (_ 1.1))))
              (unless (mutecipher-acp--md-inside-code-p marker-beg)
                (mutecipher-acp--md-hide marker-beg marker-end)
                (add-face-text-property text-beg text-end
                                        `(:weight bold :height ,height)))))))
      ;; 4. Blockquotes: replace leading `> ' with a thin bar, italic body
      (dolist (start line-starts)
        (save-excursion
          (goto-char start)
          (when (looking-at "\\(> \\)\\(.*\\)$")
            (let ((marker-beg (match-beginning 1))
                  (marker-end (match-end 1))
                  (text-beg   (match-beginning 2))
                  (text-end   (match-end 2)))
              (unless (mutecipher-acp--md-inside-code-p marker-beg)
                (put-text-property marker-beg marker-end 'display
                                   (propertize "▎ " 'face 'shadow))
                (add-face-text-property text-beg text-end
                                        '(:slant italic :inherit shadow)))))))
      ;; 5. Tables: dim the `|' separators, shadow the separator rule row
      (dolist (start line-starts)
        (save-excursion
          (goto-char start)
          (cond
           ;; `|---|:---:|---:|' separator row — all shadow
           ((looking-at "|[-:| ]+|[ \t]*$")
            (unless (mutecipher-acp--md-inside-code-p (point))
              (add-face-text-property (match-beginning 0) (match-end 0) 'shadow)))
           ;; Regular row `| foo | bar |' — face just the `|' columns
           ((looking-at "|\\([^\n]*\\)|[ \t]*$")
            (unless (mutecipher-acp--md-inside-code-p (point))
              (let ((row-end (match-end 0)))
                (goto-char (match-beginning 0))
                (while (re-search-forward "|" row-end t)
                  (add-face-text-property (1- (point)) (point) 'shadow))))))))
      ;; 6. Checkboxes: `- [x]' / `- [ ]' → ☑ / ☐
      (dolist (start line-starts)
        (save-excursion
          (goto-char start)
          (when (looking-at "\\([ \t]*\\)- \\(\\[[ xX]\\]\\) \\(.*\\)$")
            (let* ((box-beg (match-beginning 0)) ; swallow indent + "- [x]"
                   (box-end (match-end 2))
                   (text-beg (1+ box-end))       ; skip the trailing space
                   (text-end (match-end 3))
                   (indent  (match-string 1))
                   (checked (member (match-string 2) '("[x]" "[X]"))))
              (unless (mutecipher-acp--md-inside-code-p box-beg)
                (put-text-property
                 box-beg box-end 'display
                 (concat indent
                         (propertize (if checked "☑" "☐")
                                     'face (if checked 'success 'shadow))))
                (when checked
                  (add-face-text-property text-beg text-end
                                          '(:strike-through t :inherit shadow))))))))
      ;; 7. Bold **text**
      (goto-char beg)
      (while (re-search-forward "\\*\\*\\([^*\n]+\\)\\*\\*" end t)
        (let ((mb (match-beginning 0)) (me (match-end 0)))
          (if (or (eq (char-before mb) ?*)
                  (eq (char-after  me) ?*)
                  (mutecipher-acp--md-inside-code-p mb))
              (goto-char (1+ mb))
            (mutecipher-acp--md-hide mb (+ mb 2))
            (add-face-text-property (+ mb 2) (- me 2) 'bold)
            (mutecipher-acp--md-hide (- me 2) me))))
      ;; 8. Italic *text*
      (goto-char beg)
      (while (re-search-forward "\\*\\([^*\n]+\\)\\*" end t)
        (let ((mb (match-beginning 0)) (me (match-end 0)))
          (if (or (eq (char-before mb) ?*)
                  (eq (char-after  me) ?*)
                  (get-text-property mb 'invisible)
                  (mutecipher-acp--md-inside-code-p mb))
              (goto-char (1+ mb))
            (mutecipher-acp--md-hide mb (1+ mb))
            (add-face-text-property (1+ mb) (1- me) 'italic)
            (mutecipher-acp--md-hide (1- me) me))))
      ;; 9. Strikethrough ~~text~~
      (goto-char beg)
      (while (re-search-forward "~~\\([^~\n]+\\)~~" end t)
        (let ((mb (match-beginning 0)) (me (match-end 0)))
          (unless (mutecipher-acp--md-inside-code-p mb)
            (mutecipher-acp--md-hide mb (+ mb 2))
            (add-face-text-property (+ mb 2) (- me 2) '(:strike-through t))
            (mutecipher-acp--md-hide (- me 2) me))))
      ;; 10. Inline links [text](url)
      (goto-char beg)
      (while (re-search-forward "\\[\\([^]\n]+\\)\\](\\([^)\n]+\\))" end t)
        (let* ((mb       (match-beginning 0))
               (me       (match-end 0))
               (text-beg (match-beginning 1))
               (text-end (match-end 1))
               (url      (match-string-no-properties 2)))
          (unless (mutecipher-acp--md-inside-code-p mb)
            (mutecipher-acp--md-hide mb text-beg)
            (add-face-text-property text-beg text-end 'link)
            (add-text-properties text-beg text-end
                                 `(mouse-face highlight
                                   follow-link t
                                   keymap ,mutecipher-acp--md-link-keymap
                                   mutecipher-acp-md-link ,url))
            (mutecipher-acp--md-hide text-end me)))))))

;;;; Session output buffer mode

(defun mutecipher-acp--find-mode (id modes)
  "Return the mode plist with :id ID from MODES, or nil."
  (cl-find id modes :key (lambda (m) (plist-get m :id)) :test #'string=))

(defun mutecipher-acp--mode-indicator (session)
  "Return (icon face mode-name) for SESSION's current mode.
Falls back to (\"?\" mutecipher-acp-mode-default-face nil) for unknown modes."
  (let* ((mode-id  (or (and session (plist-get session :current-mode-id)) "default"))
         (avail    (and session (plist-get session :available-modes)))
         (entry    (or (assoc mode-id mutecipher-acp-mode-indicators)
                       (list mode-id "?" 'mutecipher-acp-mode-default-face)))
         (icon     (cadr entry))
         (face     (caddr entry))
         (name     (and avail
                        (let ((m (mutecipher-acp--find-mode mode-id avail)))
                          (and m (plist-get m :name))))))
    (list icon face name)))

(defun mutecipher-acp--session-header-line ()
  "Return the pinned header-line content for a session buffer.
Left side: mode-icon · agent · abbreviated-cwd · state+elapsed · mode-name.
Right side: session-id prefix."
  (let* ((sid     mutecipher-acp--session-id)
         (session (and sid (gethash sid mutecipher-acp--sessions)))
         (agent   (or (and session (plist-get session :agent)) "?"))
         (cwd     (and session (plist-get session :cwd)))
         (state   (or (and session (plist-get session :state)) 'idle))
         (started (and session (plist-get session :state-started-at)))
         (mi      (mutecipher-acp--mode-indicator session))
         (m-icon  (nth 0 mi))
         (m-face  (nth 1 mi))
         (m-name  (nth 2 mi))
         (right   (if sid
                      (propertize (mutecipher-acp--id-prefix sid)
                                  'face 'shadow)
                    ""))
         (left    (concat
                   (propertize (format "  %s %s" m-icon agent) 'face m-face)
                   (when cwd
                     (concat "  "
                             (propertize (abbreviate-file-name cwd)
                                         'face 'mutecipher-acp-hint-face)))
                   "  "
                   (mutecipher-acp--state-label state started)
                   (when m-name
                     (concat "  " (propertize m-name 'face m-face))))))
    (concat left
            (propertize " " 'display
                        `(space :align-to (- right ,(1+ (length right)))))
            right
            " ")))

(define-derived-mode mutecipher-acp-session-mode special-mode "ACP"
  "Read-only output buffer for an ACP session.
Content streams in from the agent as ewoc nodes; input is handled by a
paired `mutecipher-acp-input-mode' buffer pinned below this window."
  (setq-local truncate-lines nil)
  (setq-local cursor-type nil)
  (visual-line-mode 1)
  (goto-address-mode 1)
  (add-to-invisibility-spec 'mutecipher-acp-md-markup)
  (when mutecipher-acp-variable-pitch
    (variable-pitch-mode 1))
  (setq-local header-line-format
              '((:eval (mutecipher-acp--session-header-line))))
  (setq-local mode-line-format nil)
  ;; Create the ewoc on a fresh buffer; NOSEP so each pretty-printer
  ;; owns its own newlines.  Header/footer left empty — we use the
  ;; pinned `header-line-format' above instead of a scrolling banner.
  (when (zerop (buffer-size))
    (let ((inhibit-read-only t))
      (setq-local mutecipher-acp--ewoc
                  (ewoc-create #'mutecipher-acp--pp "" "" t)))))

(defun mutecipher/acp-toggle-tool-call ()
  "Toggle the expanded/collapsed state of the tool-call node at point."
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
        (setf (macp-node-collapsed wrapper) (not (macp-node-collapsed wrapper))))
      (mutecipher-acp--with-sticky-tail (current-buffer)
        (let ((inhibit-read-only t))
          (ewoc-invalidate ewoc node)))))))

(define-key mutecipher-acp-session-mode-map (kbd "TAB")     #'mutecipher/acp-toggle-tool-call)
(define-key mutecipher-acp-session-mode-map (kbd "<tab>")   #'mutecipher/acp-toggle-tool-call)
(define-key mutecipher-acp-session-mode-map (kbd "C-c C-a") #'mutecipher/acp-dispatch)
(define-key mutecipher-acp-session-mode-map (kbd "C-c C-c") #'mutecipher/acp-cancel)
(define-key mutecipher-acp-session-mode-map (kbd "C-c C-k") #'mutecipher/acp-kill-session)
(define-key mutecipher-acp-session-mode-map (kbd "C-c C-o") #'mutecipher/acp-set-config)

;;;; Input buffer mode

(defvar-local mutecipher-acp--resize-last-size nil
  "Last `buffer-size' seen by `mutecipher-acp--resize-input'.")

(defvar-local mutecipher-acp--input-history (make-ring 50)
  "Per-session input history ring for `mutecipher-acp-input-mode' buffers.")

(defvar-local mutecipher-acp--input-history-index nil
  "Current position in the history ring, or nil at the fresh prompt.")

(defconst mutecipher-acp--input-hint
  "RET send · / cmds · @ file · C-c C-a menu"
  "One-shot hint shown in the echo area when the input window first opens.")

(defvar-local mutecipher-acp--prompt-overlay nil
  "Overlay that paints the `❯ ' glyph at point-min of the input buffer.")

(defun mutecipher-acp--install-prompt-glyph ()
  "Install a `❯ ' prompt overlay at point-min of the input buffer.
The overlay's `before-string' is purely visual — it does not contaminate
`buffer-string', so send/history/resize code can continue to read the
buffer verbatim."
  (setq mutecipher-acp--prompt-overlay
        (make-overlay (point-min) (point-min) nil t nil))
  (overlay-put mutecipher-acp--prompt-overlay 'before-string
               (propertize "❯ " 'face 'mutecipher-acp-prompt-glyph-face)))

(defun mutecipher-acp--state-label (state started-at)
  "Render STATE as a propertized mode-line label.
STARTED-AT is a float-time used to display elapsed seconds for busy states."
  (let ((elapsed (and started-at (max 0 (truncate (- (float-time) started-at))))))
    (pcase state
      ('thinking
       (propertize (format " thinking %ds " (or elapsed 0))
                   'face 'mutecipher-acp-status-busy-face))
      ('streaming
       (propertize (format " streaming %ds " (or elapsed 0))
                   'face 'mutecipher-acp-status-busy-face))
      ('awaiting-permission
       (propertize " awaiting permission "
                   'face 'mutecipher-acp-status-await-face))
      ('error
       (propertize " error " 'face 'mutecipher-acp-status-error-face))
      (_
       (propertize " idle " 'face 'mutecipher-acp-status-idle-face)))))

(defun mutecipher-acp--maybe-complete ()
  (when (memq last-command-event '(?/ ?@))
    (completion-at-point)))

(define-derived-mode mutecipher-acp-input-mode fundamental-mode "ACP-Input"
  "Dynamically-resizing input buffer paired with an ACP session output buffer.
RET sends the buffer contents as a prompt.  S-RET / M-J insert a newline.
M-p / M-n cycle the input history.  C-c C-c cancels; C-c C-k kills the session."
  (setq-local header-line-format nil)
  (setq-local mode-line-format nil)
  (setq-local completion-auto-help 'always)
  (setq-local completion-styles '(basic flex))
  (setq-local completions-format 'one-column)
  (setq-local completions-max-height 12)
  (visual-line-mode 1)
  (completion-preview-mode 1)
  (add-hook 'post-command-hook #'mutecipher-acp--resize-input nil t)
  (add-hook 'post-self-insert-hook #'mutecipher-acp--maybe-complete nil t)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp--files-capf nil t)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp--commands-capf nil t)
  (mutecipher-acp--install-prompt-glyph))

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
  (define-key map (kbd "C-c C-a")    #'mutecipher/acp-dispatch)
  (define-key map (kbd "C-c C-c")    #'mutecipher/acp-cancel)
  (define-key map (kbd "C-c C-k")    #'mutecipher/acp-kill-session)
  (define-key map (kbd "C-c C-o")    #'mutecipher/acp-set-config)
  (define-key map (kbd "<backtab>")  #'mutecipher/acp-cycle-mode))

(defun mutecipher-acp--input-buffer-name (session-id)
  "Return the input buffer name for SESSION-ID."
  (format "*ACP-input:%s*" (mutecipher-acp--id-prefix session-id)))

(defun mutecipher-acp--get-or-create-input-buffer (session-id)
  "Return (or create) the input buffer for SESSION-ID."
  (let ((buf (get-buffer-create (mutecipher-acp--input-buffer-name session-id))))
    (with-current-buffer buf
      (unless (derived-mode-p 'mutecipher-acp-input-mode)
        (mutecipher-acp-input-mode)
        (setq mutecipher-acp--session-id session-id)))
    buf))

;;;; State transitions

(defun mutecipher-acp--force-input-mode-line (session)
  "Refresh the mode-line in SESSION's input buffer, and header-line in output.
Called by the 1Hz state timer so the elapsed-seconds counter ticks in
both places while the agent is thinking/streaming."
  (when-let ((input-buf (plist-get session :input-buffer)))
    (when (buffer-live-p input-buf)
      (with-current-buffer input-buf
        (force-mode-line-update))))
  (when-let ((buf (plist-get session :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (force-mode-line-update)))))

(defun mutecipher-acp--set-state (session-id new-state)
  "Transition SESSION-ID to NEW-STATE and refresh the input buffer mode-line.
Starts a 1Hz timer for `thinking' and `streaming' so the elapsed-seconds
counter ticks; cancels it for every other state."
  (when-let ((session (gethash session-id mutecipher-acp--sessions)))
    (when-let ((t0 (plist-get session :state-timer)))
      (cancel-timer t0))
    (let* ((busy       (memq new-state '(thinking streaming)))
           (started-at (and busy (float-time)))
           (timer      (and busy
                            (run-at-time
                             1 1
                             (lambda ()
                               (when-let ((s (gethash session-id mutecipher-acp--sessions)))
                                 (mutecipher-acp--force-input-mode-line s))))))
           (updated    (thread-first session
                         (plist-put :state new-state)
                         (plist-put :state-started-at started-at)
                         (plist-put :state-timer timer))))
      (puthash session-id updated mutecipher-acp--sessions)
      (mutecipher-acp--force-input-mode-line updated))))

;;;; Prompt submission

(defun mutecipher-acp--open-turn (session-id user-text)
  "Open a new turn in SESSION-ID: enter turn-header + user nodes for USER-TEXT.
Clears per-turn scratch (`:current-assistant', `:current-plan-node')
and bumps `:turn-counter'.  Returns the turn-header node."
  (let* ((session (gethash session-id mutecipher-acp--sessions))
         (buf     (plist-get session :buffer))
         (counter (1+ (or (plist-get session :turn-counter) 0)))
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
    (puthash session-id
             (thread-first session
               (plist-put :turn-counter counter)
               (plist-put :current-turn-node turn-node)
               (plist-put :current-assistant nil)
               (plist-put :current-plan-node nil))
             mutecipher-acp--sessions)
    turn-node))

(defun mutecipher-acp--close-turn (session-id stop-reason)
  "Finalize SESSION-ID's current turn with STOP-REASON, invalidate its header.
Enters a trailer node for any non-normal STOP-REASON."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (node    (plist-get session :current-turn-node))
              (buf     (plist-get session :buffer))
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
    (puthash session-id
             (plist-put session :current-turn-node nil)
             mutecipher-acp--sessions)))

(defun mutecipher-acp--do-prompt (session-id text)
  "Send TEXT as a prompt for SESSION-ID."
  (let* ((session   (gethash session-id mutecipher-acp--sessions))
         (conn      (plist-get session :conn))
         (full-text text))
    (mutecipher-acp--open-turn session-id text)
    (mutecipher-acp--set-state session-id 'thinking)
    (mutecipher-acp--request
     conn "session/prompt"
     (list :sessionId session-id
           :prompt (mutecipher-acp--prompt-blocks
                    full-text (plist-get session :cwd)))
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
  "Display output BUF (top) with a pinned, auto-resizing input buffer (bottom)."
  (let* ((input-buf (mutecipher-acp--get-or-create-input-buffer session-id)))
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
      (select-window input-win)
      (let ((message-log-max nil))
        (message "%s" (propertize mutecipher-acp--input-hint
                                  'face 'mutecipher-acp-hint-face))))))

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
      (mutecipher-acp--request
       conn "session/cancel"
       (list :sessionId session-id)
       :success-fn (lambda (_) nil)
       :error-fn   (lambda (_) nil))
      (when-let ((t0 (plist-get session :state-timer)))
        (cancel-timer t0))
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
           (conn    (plist-get session :conn))
           (modes   (plist-get session :available-modes)))
      (when (zerop (length modes)) (user-error "ACP: no mode list from server"))
      (let* ((current (or (plist-get session :current-mode-id)
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
                       (plist-put session :available-modes
                                  (cl-remove-if
                                   (lambda (m) (string= (plist-get m :id) next-id))
                                   (plist-get session :available-modes)))
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
                                     (or (plist-get s :agent) "?")
                                     (or (plist-get s :state) 'idle)
                                     (mutecipher-acp--id-prefix (plist-get s :id)))
                             (plist-get s :id)))
                     sessions))
           (choice  (completing-read "ACP session: "
                                     (mapcar #'car entries) nil t))
           (sid     (cdr (assoc choice entries))))
      (when-let* ((s   (gethash sid mutecipher-acp--sessions))
                  (buf (plist-get s :buffer)))
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
   ("L" "Show log"      mutecipher/acp-show-log)
   ("C" "Clear log"     mutecipher/acp-clear-log)]
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
