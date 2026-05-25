;;; mutecipher-acp-log.el --- Protocol-trace log for ACP  -*- lexical-binding: t -*-
;;
;; Always-on capture of every JSON-RPC line, inbound and outbound,
;; lives in `*ACP-log*'.  Switch to it with `mutecipher/acp-show-log'.
;;
;; Two independent dimensions:
;; - DIRECTION (one column wide):
;;     →    outbound request from us
;;     ←    inbound message from the agent
;;     ⇐    outbound success response (we replied to an agent request)
;;     ⨯    outbound error response  (we rejected an agent request)
;; - FORMAT (per `mutecipher-acp-log-format'):
;;     summary  — one parsed-summary line + raw JSON on a dim continuation
;;     compact  — summary line only (no raw)
;;     raw      — original wire format (for full-fidelity dumps)
;;
;; `mutecipher-acp-log-suppress' drops noisy `sessionUpdate' types
;; (default: usage_update); empty `agent_message_chunk's drop via
;; `mutecipher-acp-log-suppress-empty-chunks'.  Long entries are
;; truncated per `mutecipher-acp-log-max-line'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)

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

(defcustom mutecipher-acp-log-format 'summary
  "How to render entries in `*ACP-log*'.
- `summary' — one-line summary (method/event + key fields), raw JSON
  on a dim continuation line.  Best for scanning.
- `raw'     — raw JSON line only, like the original protocol-trace.
- `compact' — summary line only, no raw payload."
  :type '(choice (const :tag "Summary + raw"  summary)
                 (const :tag "Raw JSON only"  raw)
                 (const :tag "Summary only"   compact))
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-log-suppress
  '("usage_update")
  "List of `sessionUpdate' types to drop from the log.
The default suppresses `usage_update' notifications, which fire many
times per turn and drown out interesting traffic.  Set to nil to keep
everything; toggle interactively with `mutecipher/acp-toggle-log-noise'."
  :type '(repeat string)
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-log-suppress-empty-chunks t
  "When non-nil, skip `agent_message_chunk' entries whose text is empty.
The agent emits a leading empty chunk before each response — useful as a
streaming-start marker but rarely useful in the log."
  :type 'boolean
  :group 'mutecipher-acp)

(defface mutecipher-acp-log-direction-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the direction glyph (→ ← ⇐ ⨯) in `*ACP-log*'.")

(defface mutecipher-acp-log-method-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the method/event name in summary log lines.")

(defface mutecipher-acp-log-id-face
  '((t :inherit shadow))
  "Face for request-ids and session-id prefixes in summary log lines.")

(defface mutecipher-acp-log-error-face
  '((t :inherit error :weight bold))
  "Face for error rows in `*ACP-log*'.")

(defface mutecipher-acp-log-raw-face
  '((t :inherit shadow :height 0.92))
  "Face for the dim continuation line that carries raw JSON.")

(defconst mutecipher-acp--log-buffer-name "*ACP-log*")

(defconst mutecipher-acp--log-direction-glyphs
  '((in       . "←")
    (out      . "→")
    (out-resp . "⇐")
    (out-err  . "⨯"))
  "Alist mapping log-direction symbols to their display glyph.")

(defvar-local mutecipher-acp--log-line-count 0
  "Buffer-local running line count for `*ACP-log*'.
Maintained incrementally so the per-entry trim doesn't pay for
`count-lines' over the whole buffer on every write.")

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

(defun mutecipher-acp--log-parse (payload)
  "Return the JSON-RPC PAYLOAD as a plist, or nil on parse failure."
  (and (stringp payload)
       (not (string-empty-p payload))
       (condition-case nil
           (json-parse-string payload
                              :object-type 'plist
                              :null-object nil
                              :false-object :json-false)
         (error nil))))

(defun mutecipher-acp--log-summarize (msg)
  "Return a short, human-scannable summary string for parsed JSON-RPC MSG.
MSG is a plist; returns nil to fall through to raw rendering."
  (when (listp msg)
    (let* ((id     (plist-get msg :id))
           (method (plist-get msg :method))
           (result (plist-get msg :result))
           (err    (plist-get msg :error))
           (params (plist-get msg :params)))
      (cond
       ;; Inbound or outbound request (has both :id and :method).
       ((and id method)
        (format "%s id=%s%s"
                (propertize method 'face 'mutecipher-acp-log-method-face)
                (propertize (format "%s" id) 'face 'mutecipher-acp-log-id-face)
                (mutecipher-acp--log-summarize-method method params)))
       ;; Notification (method, no id).
       (method
        (format "%s%s"
                (propertize method 'face 'mutecipher-acp-log-method-face)
                (mutecipher-acp--log-summarize-method method params)))
       ;; Error response (id + error).
       ((and id err)
        (let ((code (plist-get err :code))
              (m    (plist-get err :message)))
          (propertize (format "error id=%s code=%s %s" id code (or m ""))
                      'face 'mutecipher-acp-log-error-face)))
       ;; Success response (id + result).
       ((and id (or result (plist-member msg :result)))
        (format "ok id=%s%s"
                (propertize (format "%s" id) 'face 'mutecipher-acp-log-id-face)
                (mutecipher-acp--log-summarize-result result)))))))

(defun mutecipher-acp--log-summarize-method (method params)
  "Return a small detail suffix for METHOD with PARAMS."
  (cond
   ((null params) "")
   ((equal method "session/update")
    (let* ((update (plist-get params :update))
           (type   (and update (plist-get update :sessionUpdate)))
           (sid    (plist-get params :sessionId)))
      (format " %s%s%s"
              (propertize (or type "?") 'face 'mutecipher-acp-log-method-face)
              (mutecipher-acp--log-summarize-update type update)
              (mutecipher-acp--log-session-tag sid))))
   ((equal method "session/prompt")
    (let* ((sid    (plist-get params :sessionId))
           (prompt (plist-get params :prompt))
           (text   (and (vectorp prompt) (> (length prompt) 0)
                        (plist-get (aref prompt 0) :text))))
      (format " %s%s"
              (mutecipher-acp--log-session-tag sid)
              (if text (format " %S" (mutecipher-acp--log-shorten text 60)) ""))))
   ((equal method "session/request_permission")
    (let* ((sid (plist-get params :sessionId))
           (tc  (plist-get params :toolCall))
           (kind (plist-get tc :kind))
           (name (plist-get tc :title)))
      (format " %s%s"
              (mutecipher-acp--log-session-tag sid)
              (if name (format " %s(%s)"
                                (or kind "tool")
                                (mutecipher-acp--log-shorten name 50))
                ""))))
   ((equal method "session/cancel")
    (mutecipher-acp--log-session-tag (plist-get params :sessionId)))
   ((equal method "session/new")
    (let ((cwd (plist-get params :cwd)))
      (if cwd (format " cwd=%s" (abbreviate-file-name cwd)) "")))
   ((equal method "session/load")
    (mutecipher-acp--log-session-tag (plist-get params :sessionId)))
   ((equal method "session/set_config_option")
    (format " %s %s=%S"
            (mutecipher-acp--log-session-tag (plist-get params :sessionId))
            (plist-get params :configId)
            (plist-get params :value)))
   ((equal method "fs/read_text_file")
    (let ((p (plist-get params :path)))
      (if p (format " %s" p) "")))
   ((equal method "fs/write_text_file")
    (let ((p (plist-get params :path)))
      (if p (format " %s" p) "")))
   (t "")))

(defun mutecipher-acp--log-summarize-update (type update)
  "Detail for a `session/update' of TYPE carrying UPDATE plist."
  (cond
   ((equal type "agent_message_chunk")
    (let ((text (plist-get (plist-get update :content) :text)))
      (format " %S" (mutecipher-acp--log-shorten (or text "") 50))))
   ((equal type "tool_call")
    (let ((kind (plist-get update :kind))
          (name (plist-get update :title))
          (cid  (plist-get update :toolCallId)))
      (format " %s(%s)%s"
              (or kind "tool")
              (mutecipher-acp--log-shorten (or name "") 40)
              (if cid (format " cid=%s"
                               (propertize (mutecipher-acp--log-short-id cid)
                                           'face 'mutecipher-acp-log-id-face))
                ""))))
   ((equal type "tool_call_update")
    (let ((status (plist-get update :status))
          (cid    (plist-get update :toolCallId)))
      (format "%s%s"
              (if status (format " %s" status) "")
              (if cid (format " cid=%s"
                               (propertize (mutecipher-acp--log-short-id cid)
                                           'face 'mutecipher-acp-log-id-face))
                ""))))
   ((equal type "thought")
    (format " %S" (mutecipher-acp--log-shorten
                   (or (plist-get update :thought) "") 60)))
   ((equal type "plan")
    (let ((tasks (plist-get update :tasks)))
      (format " (%d task%s)"
              (length tasks)
              (if (= 1 (length tasks)) "" "s"))))
   ((equal type "session_info_update")
    (let ((title (plist-get update :title)))
      (if title (format " title=%S" title) "")))
   ((equal type "current_mode_update")
    (format " mode=%s" (plist-get update :currentModeId)))
   ((equal type "config_option_update")
    (let* ((opts    (plist-get update :configOptions))
           (mode-opt (and opts
                          (cl-find "mode" opts
                                   :key (lambda (o) (plist-get o :id))
                                   :test #'string=))))
      (if mode-opt
          (format " mode=%s" (plist-get mode-opt :currentValue))
        "")))
   ((equal type "available_commands_update")
    (let ((cmds (plist-get update :availableCommands)))
      (format " (%d cmd%s)"
              (length cmds) (if (= 1 (length cmds)) "" "s"))))
   ((equal type "usage_update")
    (let ((used (plist-get update :used))
          (size (plist-get update :size))
          (cost (plist-get (plist-get update :cost) :amount)))
      (format " %s/%s%s"
              (or used "?") (or size "?")
              (if cost (format " $%.4f" cost) ""))))
   (t "")))

(defun mutecipher-acp--log-summarize-result (result)
  "One-line summary suffix for an RPC RESULT value."
  (cond
   ((null result) "")
   ((not (listp result)) "")
   ((plist-get result :sessionId)
    (mutecipher-acp--log-session-tag (plist-get result :sessionId)))
   ((plist-get result :stopReason)
    (format " stopReason=%s" (plist-get result :stopReason)))
   ((plist-get result :outcome)
    (let* ((o   (plist-get result :outcome))
           (oid (plist-get o :optionId))
           (out (plist-get o :outcome)))
      (format " %s%s" (or out "?") (if oid (format "/%s" oid) ""))))
   (t "")))

(defun mutecipher-acp--log-session-tag (sid)
  "Return ` sid=…' tag for SID, or empty string."
  (if sid
      (format " sid=%s"
              (propertize (mutecipher-acp--id-prefix sid)
                          'face 'mutecipher-acp-log-id-face))
    ""))

(defun mutecipher-acp--log-short-id (id)
  "Return the first 8 chars of an opaque ID like a toolCallId."
  (if (and (stringp id) (> (length id) 12))
      (concat (substring id 0 12) "…")
    (format "%s" id)))

(defun mutecipher-acp--log-shorten (s max)
  "Return S with embedded newlines escaped, truncated to MAX chars."
  (let ((s1 (replace-regexp-in-string "[\n\t]+" " " (or s ""))))
    (if (> (length s1) max)
        (concat (substring s1 0 (1- max)) "…")
      s1)))

(defun mutecipher-acp--log-suppressed-p (msg)
  "Non-nil if MSG should be dropped per the user's filter customs."
  (let* ((method (plist-get msg :method))
         (update (plist-get msg :update))
         (params (plist-get msg :params))
         (update (or update (plist-get params :update)))
         (type   (and update (plist-get update :sessionUpdate))))
    (and (equal method "session/update")
         (or (and type (member type mutecipher-acp-log-suppress))
             (and mutecipher-acp-log-suppress-empty-chunks
                  (equal type "agent_message_chunk")
                  (let ((text (plist-get (plist-get update :content) :text)))
                    (or (null text) (string-empty-p text))))))))

(defun mutecipher-acp--log-needs-parse-p ()
  "Non-nil when an entry must be parsed before we can decide what to do.
Parsing is needed for any summary format and for any active suppression
filter; in `raw' mode with no filters it's pure waste on a hot path."
  (or (memq mutecipher-acp-log-format '(summary compact))
      mutecipher-acp-log-suppress
      mutecipher-acp-log-suppress-empty-chunks))

(defun mutecipher-acp--log (direction agent payload)
  "Append a log entry to `*ACP-log*'.
DIRECTION is one of `in', `out', `out-resp', `out-err'.  AGENT is the
connection/agent label.  PAYLOAD is the raw JSON-RPC line on the wire."
  (let ((msg (and (mutecipher-acp--log-needs-parse-p)
                  (mutecipher-acp--log-parse payload))))
    (unless (and msg (mutecipher-acp--log-suppressed-p msg))
      (let* ((buf      (mutecipher-acp--log-buffer))
             (ts       (format-time-string "%H:%M:%S.%3N"))
             (glyph    (or (cdr (assq direction
                                       mutecipher-acp--log-direction-glyphs))
                            "?"))
             (dir-face (if (eq direction 'out-err)
                           'mutecipher-acp-log-error-face
                         'mutecipher-acp-log-direction-face))
             (summary  (and msg (mutecipher-acp--log-summarize msg)))
             (raw-line (mutecipher-acp--log-truncate (or payload "")))
             (header   (format "%s %s %-10s "
                                ts
                                (propertize glyph 'face dir-face)
                                (or agent "")))
             (entry
              (pcase mutecipher-acp-log-format
                ('raw     (concat header raw-line "\n"))
                ('compact (concat header (or summary raw-line) "\n"))
                (_ (concat header (or summary raw-line) "\n"
                            (when (and summary
                                       (not (string-empty-p raw-line)))
                              (concat "  "
                                      (propertize raw-line
                                                  'face 'mutecipher-acp-log-raw-face)
                                      "\n")))))))
        (mutecipher-acp--log-append buf entry)))))

(defun mutecipher-acp--log-append (buf entry)
  "Insert ENTRY (a string ending in newline) at the end of BUF and trim
leading lines so `mutecipher-acp--log-line-count' stays within
`mutecipher-acp-log-keep-lines'.  Preserves end-of-buffer follow."
  (with-current-buffer buf
    (let ((inhibit-read-only t)
          (was-at-end  (= (point) (point-max)))
          (added-lines (cl-count ?\n entry)))
      (save-excursion
        (goto-char (point-max))
        (insert entry)
        (cl-incf mutecipher-acp--log-line-count added-lines)
        (let ((excess (- mutecipher-acp--log-line-count
                          mutecipher-acp-log-keep-lines)))
          (when (> excess 0)
            (goto-char (point-min))
            (forward-line excess)
            (delete-region (point-min) (point))
            (cl-decf mutecipher-acp--log-line-count excess))))
      (when was-at-end
        (goto-char (point-max))))))

(defun mutecipher-acp--log-warn (kind agent text)
  "Append a freeform warning row to `*ACP-log*'.
KIND is a symbol used as the direction glyph, AGENT is the connection
label, TEXT is the message body."
  (let* ((buf  (mutecipher-acp--log-buffer))
         (ts   (format-time-string "%H:%M:%S.%3N"))
         (gly  (pcase kind
                 ('in-parse   "‼")
                 ('agent-warn "·")
                 (_           "?")))
         (line (format "%s %s %-10s %s\n"
                       ts
                       (propertize gly 'face 'mutecipher-acp-log-error-face)
                       (or agent "")
                       (propertize text 'face 'mutecipher-acp-log-error-face))))
    (mutecipher-acp--log-append buf line)))

;;;###autoload
(defun mutecipher/acp-show-log ()
  "Pop up the `*ACP-log*' protocol-trace buffer."
  (interactive)
  (pop-to-buffer (mutecipher-acp--log-buffer)))

;;;###autoload
(defun mutecipher/acp-toggle-log-noise ()
  "Toggle whether noisy `usage_update' notifications appear in `*ACP-log*'.
Also covers empty `agent_message_chunk's via the related custom."
  (interactive)
  (cond
   ((member "usage_update" mutecipher-acp-log-suppress)
    (setq mutecipher-acp-log-suppress
          (delete "usage_update" mutecipher-acp-log-suppress))
    (setq mutecipher-acp-log-suppress-empty-chunks nil)
    (message "ACP log: showing usage_update + empty chunks"))
   (t
    (cl-pushnew "usage_update" mutecipher-acp-log-suppress :test #'equal)
    (setq mutecipher-acp-log-suppress-empty-chunks t)
    (message "ACP log: hiding usage_update + empty chunks"))))

;;;###autoload
(defun mutecipher/acp-cycle-log-format ()
  "Cycle `mutecipher-acp-log-format' through summary → compact → raw."
  (interactive)
  (setq mutecipher-acp-log-format
        (pcase mutecipher-acp-log-format
          ('summary 'compact)
          ('compact 'raw)
          (_        'summary)))
  (message "ACP log: format=%s" mutecipher-acp-log-format))

;;;###autoload
(defun mutecipher/acp-clear-log ()
  "Erase the `*ACP-log*' buffer."
  (interactive)
  (with-current-buffer (mutecipher-acp--log-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq mutecipher-acp--log-line-count 0))))

(provide 'mutecipher-acp-log)
;;; mutecipher-acp-log.el ends here
