;;; mutecipher-acp-rpc.el --- NDJSON JSON-RPC transport for ACP  -*- lexical-binding: t -*-
;;
;; ACP uses newline-delimited JSON (one JSON object per line).
;; Emacs's built-in jsonrpc.el uses Content-Length framing (LSP-style),
;; so we implement a minimal custom transport instead.
;;
;; Inbound requests from the agent are routed via
;; `mutecipher-acp--handle-agent-request' (in mutecipher-acp-protocol.el).
;; Responses to our own outbound requests resolve via the per-conn
;; pending hash.  Notifications go to the conn's `:notify-fn'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-log)

(declare-function mutecipher-acp--handle-agent-request "mutecipher-acp-protocol")
(declare-function mutecipher-acp--enter-notice         "mutecipher-acp-ewoc")

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

(provide 'mutecipher-acp-rpc)
;;; mutecipher-acp-rpc.el ends here
