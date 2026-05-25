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
(require 'mutecipher-acp-markdown)

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

(defcustom mutecipher-acp-diff-max-lines 500
  "Maximum old/new line count before inline tool-call diffs are summarized.
When either side of a diff exceeds this, the diff body is skipped and a
single summary line is shown instead."
  :type 'integer
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-tool-output-max-lines 40
  "Maximum line count rendered inline for a tool call's raw output.
Outputs longer than this are truncated in the expanded card body with a
trailing \"… N more lines\" marker; the full text is still kept on the
struct so it remains available for copy or re-render at a higher cap."
  :type 'integer
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-composer-history-size 50
  "Maximum number of past prompts retained in the composer history ring."
  :type 'integer
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-collapse-tool-calls-by-default t
  "If non-nil, terminal-status tool calls render collapsed by default.
Collapsed = a single summary line; expanded = the summary plus the
tool's raw output, plan body, and diffs indented underneath.  Toggle
the whole transcript with `mutecipher/acp-toggle-tool-calls'."
  :type 'boolean
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-spinner-interval 0.1
  "Interval in seconds between spinner-frame updates.
Drives the rotating glyph rendered for tool calls in `pending' or
`running' state.  The spinner timer only runs while at least one
tool call in the session buffer is in flight."
  :type 'number
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-spinner-frames
  ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"]
  "Vector of single-character glyphs forming a spinner cycle.
Each `mutecipher-acp-spinner-interval' seconds the next frame in the
vector is rendered for in-flight tool calls."
  :type '(vector string)
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-file-cache-ttl 30
  "Seconds before `mutecipher-acp--session-files' re-walks a session's cwd."
  :type 'integer
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-file-cache-max-items 2000
  "Maximum number of candidate files returned per session by `@'-completion."
  :type 'integer
  :group 'mutecipher-acp)

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
            (mutecipher-acp--log 'in (process-name proc) line)
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
     (mutecipher-acp--log-warn 'in-parse
                                (process-name
                                 (mutecipher-acp--conn-process conn))
                                (format "[parse-error] %s — payload: %s"
                                        (error-message-string err)
                                        (mutecipher-acp--log-truncate
                                         (or json-line ""))))
     (mutecipher-acp--broadcast-parse-error conn json-line err))))

(defun mutecipher-acp--broadcast-parse-error (conn _json-line err)
  "Enter a notice node in any session attached to CONN noting the parse failure."
  (when-let ((session (mutecipher-acp--session-for-conn conn)))
    (mutecipher-acp--enter-notice
     (macp-session-id session)
     (format "ACP: dropped malformed JSON line (%s)"
             (error-message-string err))
     'mutecipher-acp-error-face)))

(cl-defun mutecipher-acp--request (conn method params &key success-fn error-fn)
  "Send an async JSON-RPC request over CONN.
METHOD is a string.  PARAMS is a plist or vector.
SUCCESS-FN and ERROR-FN are called with the result/error plist."
  (let* ((id  (mutecipher-acp--new-id))
         (msg (list :jsonrpc "2.0" :id id :method method :params params))
         (line (json-serialize msg :null-object nil :false-object :json-false)))
    (puthash id (list success-fn error-fn) (mutecipher-acp--conn-pending conn))
    (mutecipher-acp--log 'out (process-name (mutecipher-acp--conn-process conn)) line)
    (process-send-string (mutecipher-acp--conn-process conn) (concat line "\n"))))

(defun mutecipher-acp--respond (conn id result)
  "Send a JSON-RPC response with ID and RESULT over CONN.
Used to reply to inbound requests from the agent."
  (let ((line (json-serialize (list :jsonrpc "2.0" :id id :result result)
                              :null-object nil :false-object :json-false)))
    (mutecipher-acp--log 'out-resp (process-name (mutecipher-acp--conn-process conn)) line)
    (process-send-string (mutecipher-acp--conn-process conn) (concat line "\n"))))

(defun mutecipher-acp--respond-error (conn id code message)
  "Send a JSON-RPC error response with ID, error CODE and MESSAGE over CONN."
  (let ((line (json-serialize (list :jsonrpc "2.0" :id id
                                    :error (list :code code :message message))
                              :null-object nil :false-object :json-false)))
    (mutecipher-acp--log 'out-err (process-name (mutecipher-acp--conn-process conn)) line)
    (process-send-string (mutecipher-acp--conn-process conn) (concat line "\n"))))

;; JSON-RPC 2.0 standard error codes; -32000 is the "implementation
;; defined" floor we use for fs-permission denials and other errors
;; the protocol itself doesn't enumerate.
(defconst mutecipher-acp--rpc-error-method-not-found -32601)
(defconst mutecipher-acp--rpc-error-invalid-params  -32602)
(defconst mutecipher-acp--rpc-error-server          -32000)

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

;;;; Sticky reading-position across ewoc operations
;;
;; Without help, `ewoc-invalidate' and `ewoc-enter-last' grow or mutate
;; buffer content without moving window-point.  We need to preserve two
;; things across these operations:
;;
;; - The inline composer's text is buffer text living past the ewoc
;;   footer.  Ewoc inserts grow the transcript before the composer, so
;;   the composer's content is preserved verbatim — but we still have
;;   to fix up `mutecipher-acp--composer-start' (which has
;;   insertion-type nil so user typing at it stays inside the composer)
;;   and any window-point that was within the composer.
;; - When no composer is installed (early bring-up, test fixtures), the
;;   original "stick to `point-max'" behaviour applies.

(defmacro mutecipher-acp--with-sticky-tail (buf &rest body)
  "Run BODY with BUF current; preserve composer text + window points.
Composer-relative offsets survive ewoc growth.  Falls back to legacy
`point-max' sticky-tail when BUF has no composer installed yet."
  (declare (indent 1) (debug (form body)))
  (let ((buf-sym   (make-symbol "buf"))
        (cs-sym    (make-symbol "cs"))
        (tail-sym  (make-symbol "tail"))
        (wins-sym  (make-symbol "wins"))
        (tails-sym (make-symbol "tails")))
    `(let* ((,buf-sym ,buf)
            (,cs-sym  (and (buffer-live-p ,buf-sym)
                           (buffer-local-value
                            'mutecipher-acp--composer-start ,buf-sym))))
       (if ,cs-sym
           (let* ((,tail-sym
                   (with-current-buffer ,buf-sym
                     (- (point-max) (marker-position ,cs-sym))))
                  (,wins-sym
                   (cl-loop for w in (get-buffer-window-list ,buf-sym nil t)
                            for cs-pos = (marker-position ,cs-sym)
                            when (with-selected-window w
                                   (>= (point) cs-pos))
                            collect (cons w
                                          (with-selected-window w
                                            (- (point) cs-pos))))))
             (prog1 (with-current-buffer ,buf-sym ,@body)
               (when (buffer-live-p ,buf-sym)
                 (with-current-buffer ,buf-sym
                   (set-marker ,cs-sym
                               (- (point-max) ,tail-sym)))
                 (dolist (entry ,wins-sym)
                   (let ((win    (car entry))
                         (offset (cdr entry)))
                     (when (and (window-live-p win)
                                (eq (window-buffer win) ,buf-sym))
                       (with-selected-window win
                         (goto-char (+ (marker-position ,cs-sym)
                                       offset)))))))))
         (let ((,tails-sym
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
                   (goto-char (point-max)))))))))))

(defmacro mutecipher-acp--with-sticky-window-start (buf &rest body)
  "Run BODY in BUF, preserving window-start AND point across edits.
window-start is snapshotted as a marker so it tracks insertions/
deletions above it; point is preserved either by composer-relative
offset (when in the composer) or by marker (when elsewhere).  Composer
markers are reconciled when one is installed."
  (declare (indent 1) (debug (form body)))
  (let ((buf-sym  (make-symbol "buf"))
        (cs-sym   (make-symbol "cs"))
        (tail-sym (make-symbol "tail"))
        (snap-sym (make-symbol "snap")))
    `(let* ((,buf-sym  ,buf)
            (,cs-sym   (and (buffer-live-p ,buf-sym)
                            (buffer-local-value
                             'mutecipher-acp--composer-start ,buf-sym)))
            (,tail-sym (and ,cs-sym
                            (with-current-buffer ,buf-sym
                              (- (point-max) (marker-position ,cs-sym)))))
            (,snap-sym
             (and (buffer-live-p ,buf-sym)
                  (cl-loop for w in (get-buffer-window-list ,buf-sym nil t)
                           collect
                           (with-selected-window w
                             (let* ((start-m (copy-marker (window-start) nil))
                                    (pt      (window-point))
                                    (in-c
                                     (and ,cs-sym
                                          (>= pt (marker-position ,cs-sym))))
                                    (pt-info
                                     (if in-c
                                         (cons 'composer
                                               (- pt (marker-position
                                                      ,cs-sym)))
                                       (cons 'marker
                                             (copy-marker pt nil)))))
                               (list w start-m pt-info)))))))
       (prog1 (with-current-buffer ,buf-sym ,@body)
         (when (and (buffer-live-p ,buf-sym) ,cs-sym)
           (with-current-buffer ,buf-sym
             (set-marker ,cs-sym (- (point-max) ,tail-sym))))
         (dolist (entry ,snap-sym)
           (let ((win     (nth 0 entry))
                 (start-m (nth 1 entry))
                 (pt-info (nth 2 entry)))
             (when (and (window-live-p win)
                        (eq (window-buffer win) ,buf-sym))
               (set-window-start win (marker-position start-m) t)
               (set-window-point
                win
                (pcase pt-info
                  (`(composer . ,offset)
                   (+ (marker-position
                       (buffer-local-value
                        'mutecipher-acp--composer-start ,buf-sym))
                      offset))
                  (`(marker . ,m) (marker-position m)))))))))))

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

(defconst mutecipher-acp--raw-input-path-keys
  '(:file_path :filePath :path :file)
  "Keys probed in `rawInput' to recover a file path when an UPDATE
arrived without an explicit `:locations' entry.")

(defun mutecipher-acp--synthesize-locations (update)
  "Return a `:locations'-shaped vector for UPDATE.
Returns UPDATE's own `:locations' (coerced to a vector) when present
and non-empty.  Otherwise synthesizes `[{:path PATH}]' from the first
string-valued key in `rawInput' listed by
`mutecipher-acp--raw-input-path-keys'."
  (let ((locs (plist-get update :locations)))
    (cond
     ((and (vectorp locs) (> (length locs) 0)) locs)
     ((and (listp locs) locs) (apply #'vector locs))
     (t
      (when-let* ((raw (plist-get update :rawInput))
                  ((listp raw))
                  (fp (seq-some
                       (lambda (k)
                         (let ((v (plist-get raw k)))
                           (and (stringp v) v)))
                       mutecipher-acp--raw-input-path-keys)))
        (vector (list :path fp)))))))

(defun mutecipher-acp--enter-tool-call (session-id update)
  "Create a tool-call ewoc node from UPDATE and register it in SESSION-ID's index."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf))
              (index   (macp-session-tool-call-index session)))
    (mutecipher-acp--close-assistant session-id)
    (let* ((cc-name (plist-get (plist-get (plist-get update :_meta) :claudeCode) :toolName))
           (name    (or cc-name (plist-get update :title) (plist-get update :kind) "tool"))
           (raw-in  (plist-get update :rawInput))
           (plan    (mutecipher-acp--raw-input-plan raw-in))
           (detail  (mutecipher-acp--format-tool-input raw-in))
           (locs    (mutecipher-acp--synthesize-locations update))
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
               (collapsed (and mutecipher-acp-collapse-tool-calls-by-default
                               (not plan)))
               (node (ewoc-enter-last
                      mutecipher-acp--ewoc
                      (make-macp-node :kind 'tool-call
                                      :data tc
                                      :collapsed collapsed))))
          (when call-id
            (puthash call-id node index))))
      (mutecipher-acp--reconcile-spinner-for-session session))))

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

(defun mutecipher-acp--should-auto-collapse-p (tc)
  "Non-nil when tool-call TC should default to collapsed.
Triggers on terminal status (`done' / `error') when
`mutecipher-acp-collapse-tool-calls-by-default' is non-nil.
ExitPlanMode-style calls (`plan-body' set) opt out — that's the whole
point of the call, so they always stay expanded."
  (and mutecipher-acp-collapse-tool-calls-by-default
       (memq (macp-tool-call-status tc) '(done error))
       (not (macp-tool-call-plan-body tc))))

(defun mutecipher-acp--update-tool-call (session-id update)
  "Apply tool_call_update UPDATE to SESSION-ID's matching tool-call node."
  (let* ((session (gethash session-id mutecipher-acp--sessions))
         (buf     (and session (macp-session-buffer session)))
         (index   (and session (macp-session-tool-call-index session)))
         (call-id (plist-get update :toolCallId))
         (node    (and call-id index (gethash call-id index)))
         (agent   (and session (macp-session-agent session))))
    (cond
     ((not (and session buf (buffer-live-p buf))) nil)
     ((null call-id)
      (mutecipher-acp--log-warn 'agent-warn agent
                                 "[tool-call-update] missing :toolCallId"))
     ((null node)
      (mutecipher-acp--log-warn
       'agent-warn agent
       (format "[tool-call-update] unknown id %S" call-id)))
     (t
      (let* ((wrapper    (ewoc-data node))
             (tc         (macp-node-data wrapper))
             (status-str (plist-get update :status))
             (cmd-title  (plist-get update :title))
             (raw-in     (plist-get update :rawInput))
             (plan       (mutecipher-acp--raw-input-plan raw-in))
             (raw-out    (plist-get update :rawOutput))
             (new-locs   (mutecipher-acp--synthesize-locations update)))
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
          (setf (macp-tool-call-raw-output tc)
                (mutecipher-acp--normalize-raw-output raw-out)))
        ;; Locations may arrive on the initial `tool_call' or on a later
        ;; `tool_call_update'.  Keep the latest synthesized vector so
        ;; diff line numbers can anchor at the file line.
        (when (and new-locs (> (length new-locs) 0))
          (setf (macp-tool-call-locations tc) new-locs))
        (pcase status-str
          ("completed"   (setf (macp-tool-call-status tc) 'done
                               (macp-tool-call-ended-at tc) (float-time)))
          ("failed"      (setf (macp-tool-call-status tc) 'error
                               (macp-tool-call-ended-at tc) (float-time)))
          ("in_progress" (setf (macp-tool-call-status tc) 'running))
          ('nil          nil)
          (_             (mutecipher-acp--log-warn
                          'agent-warn agent
                          (format "[tool-call-update] unknown status %S"
                                  status-str))))
        (mutecipher-acp--ingest-tool-content tc (plist-get update :content))
        (when (and (not (macp-node-collapsed wrapper))
                   (mutecipher-acp--should-auto-collapse-p tc))
          (setf (macp-node-collapsed wrapper) t))
        (mutecipher-acp--with-sticky-tail buf
          (let ((inhibit-read-only t))
            (ewoc-invalidate mutecipher-acp--ewoc node)
            ;; Pulse only on terminal status transitions so chatty
            ;; in_progress / content-only updates don't strobe the buffer.
            (when (memq (macp-tool-call-status tc) '(done error))
              (mutecipher-acp--pulse-node mutecipher-acp--ewoc node))))
        (mutecipher-acp--reconcile-spinner-for-session session))))))

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

;;;; Prompt attachments (@-mentions)

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
`mutecipher-acp-file-cache-max-items'."
  (let ((root (file-name-as-directory (expand-file-name cwd)))
        (acc '())
        (count 0)
        (queue (list (file-name-as-directory (expand-file-name cwd)))))
    (while (and queue (< count mutecipher-acp-file-cache-max-items))
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
  (let* ((cwd   (macp-session-cwd session))
         (cache (macp-session-file-cache session))
         (now   (float-time)))
    (if (and cache
             (< (- now (nth 0 cache)) mutecipher-acp-file-cache-ttl))
        (cons (nth 1 cache) (nth 2 cache))
      (let* ((proj  (and cwd
                         (let ((default-directory cwd))
                           (project-current nil cwd))))
             (files (if proj
                        (mapcar (lambda (f) (file-relative-name f cwd))
                                (project-files proj))
                      (and cwd (mutecipher-acp--walk-cwd cwd))))
             (source (if proj 'project 'fs))
             (capped (if (> (length files) mutecipher-acp-file-cache-max-items)
                         (seq-take files mutecipher-acp-file-cache-max-items)
                       files)))
        (setf (macp-session-file-cache session) (list now source capped))
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
              (commands   (macp-session-commands session))
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

(defun mutecipher-acp--diff-line-render (kind lineno line)
  "Render LINE for KIND with a line-number gutter and a full-line bg.
KIND is `added' / `removed' / `context' / `hunk-header'; LINENO is the
line number to print in the gutter (nil leaves the gutter blank).  The
returned string carries a `face' text property that has `:extend t' so
the background stretches all the way to the right window edge — the
GitHub-style banding."
  (let* ((bg-face (pcase kind
                    ('added       'mutecipher-acp-diff-added-face)
                    ('removed     'mutecipher-acp-diff-removed-face)
                    ('context     'mutecipher-acp-diff-context-face)
                    ('hunk-header 'mutecipher-acp-diff-hunk-header-face)))
         (gutter  (propertize
                   (format "%5s " (if lineno (number-to-string lineno) ""))
                   'face 'mutecipher-acp-diff-line-number-face))
         (body    (concat line "\n")))
    (concat gutter
            (propertize body 'face bg-face))))

(defun mutecipher-acp--render-diff-for-card (old-text new-text &optional start-line)
  "Walk the unified diff for OLD-TEXT→NEW-TEXT and emit a GitHub-styled body.
When START-LINE is non-nil, the diff snippet is treated as beginning
at that 1-based file line — the gutter line numbers and the rewritten
`@@ -X,Y +A,B @@' header become file-relative instead of snippet-
relative.  The `\\ No newline at end of file' trailer is dropped."
  (when-let ((diff-str (mutecipher-acp--generate-unified-diff
                        old-text new-text)))
    (let* ((offset   (if start-line (1- start-line) 0))
           (result   nil)
           (old-line nil)
           (new-line nil)
           ;; `"\n+"' strips ALL trailing newlines so we don't end up with
           ;; an empty phantom line after `split-string'.
           (lines    (split-string (string-trim-right diff-str "\n+") "\n")))
      (dolist (line lines)
        (cond
         ((string-match
           "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@\\(.*\\)$"
           line)
          (let* ((old-start (+ offset (string-to-number (match-string 1 line))))
                 (old-count (match-string 2 line))
                 (new-start (+ offset (string-to-number (match-string 3 line))))
                 (new-count (match-string 4 line))
                 (tail      (or (match-string 5 line) "")))
            (setq old-line old-start
                  new-line new-start)
            (push (mutecipher-acp--diff-line-render
                   'hunk-header nil
                   (format "@@ -%d%s +%d%s @@%s"
                           old-start
                           (if old-count (format ",%s" old-count) "")
                           new-start
                           (if new-count (format ",%s" new-count) "")
                           tail))
                  result)))
         ((string-prefix-p "-" line)
          (push (mutecipher-acp--diff-line-render 'removed old-line line)
                result)
          (when old-line (cl-incf old-line)))
         ((string-prefix-p "+" line)
          (push (mutecipher-acp--diff-line-render 'added new-line line)
                result)
          (when new-line (cl-incf new-line)))
         ((string-prefix-p "\\" line) nil) ; \ No newline at end of file
         (t
          (push (mutecipher-acp--diff-line-render 'context new-line line)
                result)
          (when old-line (cl-incf old-line))
          (when new-line (cl-incf new-line)))))
      (apply #'concat (nreverse result)))))

(defun mutecipher-acp--diff-body-for (old-text new-text &optional start-line)
  "Return a renderable diff body (propertized string) for OLD-TEXT → NEW-TEXT.
GitHub-style: line-number gutter + colored full-line bands.  When
START-LINE is non-nil, gutter and hunk header are anchored at that
file line.  Honors `mutecipher-acp-diff-max-lines'."
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
      (when-let ((body (mutecipher-acp--render-diff-for-card
                        old new start-line)))
        (concat "\n" body)))))

(defun mutecipher-acp--find-line-in-file (path text)
  "Return the 1-based line where TEXT first appears in PATH, or nil."
  (when (and path text
             (stringp path) (stringp text)
             (not (string-empty-p text))
             (file-readable-p path))
    (condition-case _err
        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (when (search-forward text nil t)
            (line-number-at-pos (match-beginning 0))))
      (error nil))))

(defun mutecipher-acp--tool-call-start-line (tc &optional cwd)
  "Return the 1-based file line to anchor TC's diffs at, or nil.
claude-code-acp ships `:line 1' for every Edit, so we distrust `:line'
and search the file for the diff's `newText' first (correct post-edit),
then `oldText' (correct pre-edit), then fall back to `locations[0].line'.
Result is memoized on TC keyed by diff-count + locations so spinner
re-renders don't re-read the file."
  (let* ((locs   (macp-tool-call-locations tc))
         (loc    (and locs (> (length locs) 0) (aref locs 0)))
         (diffs  (macp-tool-call-diffs tc))
         (key    (cons (or (macp-tool-call-rendered-diff-count tc) 0) locs)))
    (cond
     ((null diffs) nil)
     ((equal key (macp-tool-call-cached-start-key tc))
      (macp-tool-call-cached-start-line tc))
     (t
      (let* ((path     (and loc (plist-get loc :path)))
             (abs-path (and path
                            (if (file-name-absolute-p path)
                                path
                              (and cwd (expand-file-name path cwd)))))
             (pair     (car diffs))
             (old-text (car pair))
             (new-text (cdr pair))
             (search (lambda (text)
                       (and (stringp text)
                            (not (string-empty-p text))
                            abs-path
                            (mutecipher-acp--find-line-in-file
                             abs-path text))))
             (start (or (funcall search new-text)
                        (funcall search old-text)
                        (and loc (plist-get loc :line)))))
        (setf (macp-tool-call-cached-start-line tc) start
              (macp-tool-call-cached-start-key tc) key)
        start)))))

(defun mutecipher-acp--raw-output-item-string (item)
  "Render a single :rawOutput content ITEM (plist) as a string."
  (cond
   ((stringp item) item)
   ((not (listp item)) (format "%S" item))
   ((stringp (plist-get item :text)) (plist-get item :text))
   ((stringp (plist-get item :tool_name))
    (format "→ %s" (plist-get item :tool_name)))
   (t (format "%S" item))))

(defun mutecipher-acp--normalize-raw-output (raw)
  "Coerce RAW (string, vector of content items, or nil) to a display string.
Shell-style tool calls deliver :rawOutput as a JSON string; MCP and
ToolSearch results deliver a vector of content items (each typically
`{:type \"text\" :text ...}' or `{:type \"tool_reference\" :tool_name
...}').  Flatten vectors to a newline-joined string so downstream
helpers can treat the field as text."
  (cond
   ((null raw) nil)
   ((stringp raw) raw)
   ((vectorp raw)
    (mapconcat #'mutecipher-acp--raw-output-item-string raw "\n"))
   (t (format "%S" raw))))

(defun mutecipher-acp--tool-output-line-count (raw)
  "Return the line count of RAW (0 if nil or empty)."
  (let ((s (mutecipher-acp--normalize-raw-output raw)))
    (cond
     ((or (null s) (string-empty-p s)) 0)
     (t (1+ (cl-count ?\n s))))))

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

(defun mutecipher-acp--first-output-line (raw)
  "Return the first line of RAW, or nil if RAW is empty/missing."
  (let ((s (mutecipher-acp--normalize-raw-output raw)))
    (and s (not (string-empty-p s))
         (car (split-string s "\n")))))

(defun mutecipher-acp--truncate-output-for-display (raw)
  "Return RAW (a string) clipped to `mutecipher-acp-tool-output-max-lines'.
If clipped, append a single dim marker noting how many lines were
hidden.  RAW is assumed already normalized to a string."
  (let* ((cap   (max 1 mutecipher-acp-tool-output-max-lines))
         (lines (split-string raw "\n"))
         (len   (length lines))
         (extra (- len cap)))
    (if (<= len cap)
        raw
      (concat (mapconcat #'identity (cl-subseq lines 0 cap) "\n")
              (format "\n… %d more line%s" extra (if (= 1 extra) "" "s"))))))

(defun mutecipher-acp--indent-block (text indent)
  "Return TEXT with INDENT (a string) prefixed to every line, no trailing newline."
  (let ((trimmed (string-trim-right text "\n")))
    (if (string-empty-p trimmed)
        ""
      (replace-regexp-in-string "^" indent trimmed))))

;;;; Tool-call spinner
;;
;; In-flight tool calls (`pending' / `running') render a rotating glyph
;; in place of the static circle.  A single buffer-local timer ticks at
;; `mutecipher-acp-spinner-interval' while at least one tool call is in
;; flight, incrementing `--spinner-tick' and invalidating each active
;; tool-call node so the pretty-printer picks the next frame.  The
;; timer stops itself as soon as no tool call needs it.

(defvar-local mutecipher-acp--spinner-tick 0
  "Buffer-local spinner frame counter, incremented by the spinner timer.")

(defvar-local mutecipher-acp--spinner-timer nil
  "Buffer-local timer driving the spinner animation, or nil when idle.")

(defun mutecipher-acp--spinner-glyph (status)
  "Return the current spinner frame for STATUS as a propertized string."
  (let* ((frames mutecipher-acp-spinner-frames)
         (idx    (mod mutecipher-acp--spinner-tick (max 1 (length frames))))
         (face   (if (eq status 'pending) 'shadow 'warning)))
    (propertize (aref frames idx) 'face face)))

(defun mutecipher-acp--tool-status-glyph (status)
  "Return a propertized status glyph for tool-call STATUS.
Animated for `pending' / `running' via the spinner; static glyph from
`mutecipher-icons-acp-alist' (or ASCII fallback) for terminal states."
  (pcase status
    ((or 'pending 'running)
     (mutecipher-acp--spinner-glyph status))
    ('done  (mutecipher-acp--icon-or 'status-done  "✓"))
    ('error (mutecipher-acp--icon-or 'status-error "✗"))
    (_      "?")))

(defun mutecipher-acp--tool-call-active-p (data)
  "Non-nil if ewoc node DATA is a tool-call in `pending' / `running' state."
  (and (eq (macp-node-kind data) 'tool-call)
       (memq (macp-tool-call-status (macp-node-data data))
             '(pending running))))

(defun mutecipher-acp--has-active-tool-calls-p ()
  "Non-nil when any tool-call in this buffer is `pending' or `running'.
Walks the ewoc with `ewoc-next' so the search short-circuits on the
first match instead of allocating a full list."
  (and mutecipher-acp--ewoc
       (let ((node  (ewoc-nth mutecipher-acp--ewoc 0))
             (found nil))
         (while (and node (not found))
           (when (mutecipher-acp--tool-call-active-p (ewoc-data node))
             (setq found t))
           (setq node (ewoc-next mutecipher-acp--ewoc node)))
         found)))

(defun mutecipher-acp--stop-spinner ()
  "Cancel the spinner timer in the current buffer, if any."
  (when (timerp mutecipher-acp--spinner-timer)
    (cancel-timer mutecipher-acp--spinner-timer))
  (setq mutecipher-acp--spinner-timer nil))

(defun mutecipher-acp--ensure-spinner ()
  "Start the spinner timer in the current buffer if it isn't running already."
  (unless (timerp mutecipher-acp--spinner-timer)
    (let ((buf (current-buffer)))
      (setq mutecipher-acp--spinner-timer
            (run-at-time mutecipher-acp-spinner-interval
                         mutecipher-acp-spinner-interval
                         (lambda () (mutecipher-acp--spinner-step buf)))))))

(defun mutecipher-acp--spinner-step (buf)
  "Advance the spinner in BUF and invalidate active tool-call nodes.
Single-walk: the same `ewoc-map' that invalidates also records whether
anything matched, so the spinner self-cancels without a second pass."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (cl-incf mutecipher-acp--spinner-tick)
      (let ((any-active nil))
        (mutecipher-acp--with-sticky-tail buf
          (let ((inhibit-read-only t))
            (ewoc-map
             (lambda (d)
               (when (mutecipher-acp--tool-call-active-p d)
                 (setq any-active t)
                 t))
             mutecipher-acp--ewoc)))
        (unless any-active
          (mutecipher-acp--stop-spinner))))))

(defun mutecipher-acp--reconcile-spinner-for-session (session)
  "Start or stop SESSION's spinner timer to match its tool-call state."
  (when-let ((buf (and session (macp-session-buffer session))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (mutecipher-acp--has-active-tool-calls-p)
            (mutecipher-acp--ensure-spinner)
          (mutecipher-acp--stop-spinner))))))

(defun mutecipher-acp--tool-meta (tc)
  "Return the right-side metadata string for tool-call TC, or nil.
For terminal statuses, summarizes output size (lines + diffs).  For
running/pending, returns nil — the spinner + status glyph already say
\"in flight\".  No leading `· ' separator; the right-alignment on the
summary line is what visually separates this from the LHS."
  (let* ((raw   (macp-tool-call-raw-output tc))
         (lines (mutecipher-acp--tool-output-line-count raw))
         (diffs (length (macp-tool-call-diffs tc))))
    (pcase (macp-tool-call-status tc)
      ('done
       (cond
        ((and (> lines 0) (> diffs 0))
         (format "%d line%s · %d diff%s"
                 lines (if (= 1 lines) "" "s")
                 diffs (if (= 1 diffs) "" "s")))
        ((> lines 0)
         (format "%d line%s" lines (if (= 1 lines) "" "s")))
        ((> diffs 0)
         (format "%d diff%s" diffs (if (= 1 diffs) "" "s")))
        (t nil)))
      ('error "failed")
      (_ nil))))

(defun mutecipher-acp--pp-tool-call-line (tc collapsed)
  "Insert the one-line summary for tool-call TC, no leading indent.
LHS — disclosure + status glyph + name(input) — is left-aligned next
to the card's rail.  Meta (line/diff counts) is right-aligned to the
window's right edge via a `display' (space :align-to right) property.
The card's `line-prefix' supplies the `│ ' rail on this line;
`wrap-prefix' keeps it in place if the line ever gets wrapped."
  (let* ((name       (or (macp-tool-call-name tc) "tool"))
         (input      (macp-tool-call-input tc))
         (disclosure (mutecipher-acp--icon-or
                      (if collapsed 'disclosure-collapsed 'disclosure-expanded)
                      (if collapsed "▸" "▾")))
         (status-g   (mutecipher-acp--tool-status-glyph
                      (macp-tool-call-status tc)))
         (meta       (mutecipher-acp--tool-meta tc)))
    (insert (propertize disclosure 'face 'mutecipher-acp-disclosure-face)
            " "
            status-g
            " "
            (propertize (concat name (if input (concat "(" input ")") ""))
                        'face 'mutecipher-acp-tool-face))
    (when meta
      (let* ((meta-str (propertize meta 'face 'shadow))
             (meta-w   (string-width meta-str)))
        (insert (propertize " "
                            'display `(space :align-to (- right ,meta-w)))
                meta-str)))
    (insert "\n")))

(defun mutecipher-acp--pp-tool-call-body (tc)
  "Insert the expanded body for TC: plan markdown, raw output, then diffs.
Lines are indented four spaces inside the card so body content aligns
with the tool name on the summary line.  The card's left rail is
supplied by `line-prefix' on the surrounding region.  Diffs are
anchored at the file line via `:locations[0].line' (or, falling back,
by searching the file at `:locations[0].path' for the diff's
`newText').  Relative paths are resolved against the session's cwd."
  (let* ((session (and mutecipher-acp--session-id
                       (gethash mutecipher-acp--session-id
                                mutecipher-acp--sessions)))
         (cwd     (and session (macp-session-cwd session)))
         (raw     (macp-tool-call-raw-output tc))
         (plan    (macp-tool-call-plan-body tc))
         (diffs   (macp-tool-call-diffs tc))
         (start   (mutecipher-acp--tool-call-start-line tc cwd)))
    (when plan
      (insert (propertize
               (concat (mutecipher-acp--indent-block plan "    ") "\n")
               'face 'shadow)))
    (when (and raw (not (string-empty-p raw)))
      (let ((clipped (mutecipher-acp--truncate-output-for-display raw)))
        (insert (propertize
                 (concat (mutecipher-acp--indent-block clipped "    ") "\n")
                 'face 'shadow))))
    (dolist (pair diffs)
      (when-let ((body (mutecipher-acp--diff-body-for
                        (car pair) (cdr pair) start)))
        (insert body)))))

(defun mutecipher-acp--pp-tool-call (node)
  "Render a tool-call NODE as a card encapsulating summary + body.
The card has a top border (╭ + strike-through rule), a left rail
(`│ ' supplied as `line-prefix' on every content line so it follows
wraps and unfolds), and a bottom border (╰ + strike-through rule).
Collapsed nodes show only the summary inside the card; expanded ones
include the indented body."
  (let* ((tc          (macp-node-data node))
         (collapsed   (macp-node-collapsed node))
         (rail-face   'mutecipher-acp-tool-card-face)
         (rule-face   'mutecipher-acp-tool-card-rule-face)
         (line-prefix (propertize "  │ " 'face rail-face))
         (rule        (propertize " "
                                  'display '(space :align-to right)
                                  'face rule-face)))
    (insert "  " (propertize "╭" 'face rail-face) rule "\n")
    (let ((content-beg (point)))
      (mutecipher-acp--pp-tool-call-line tc collapsed)
      (unless collapsed
        (mutecipher-acp--pp-tool-call-body tc))
      (add-text-properties content-beg (point)
                           (list 'line-prefix line-prefix
                                 'wrap-prefix line-prefix)))
    (insert "  " (propertize "╰" 'face rail-face) rule "\n\n")))

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
