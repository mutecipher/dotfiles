;;; mutecipher-acp-tools.el --- Tool-call ingest for ACP  -*- lexical-binding: t -*-
;;
;; Protocol→model boundary for tool-call notifications:
;;   - normalize incoming `tool_call' / `tool_call_update' wire data
;;   - synthesize a `:locations'-shaped vector when the agent omits it
;;   - ingest streamed diff content into `macp-tool-call.diffs'
;;   - mutate the `macp-tool-call' struct as updates arrive
;;   - delegate change-set capture to mutecipher-acp-changes
;;   - delegate card rendering to mutecipher-acp-tool-card
;;
;; Everything render-side (diff banding, spinner, pretty-printer, body
;; renderers) lives in `mutecipher-acp-diff' and `mutecipher-acp-tool-card'.
;; Restyling the transcript does not require touching this file.

;;; Code:

(require 'cl-lib)
(require 'ewoc)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-log)
(require 'mutecipher-acp-ewoc)
(require 'mutecipher-acp-changes)

(declare-function mutecipher-acp--close-assistant      "mutecipher-acp-ewoc")

;; Presentation layer — provides the spinner reconcile entry point and
;; the defcustoms (`mutecipher-acp-collapse-tool-calls-by-default',
;; output line cap) consulted at ingest time for initial collapse
;; state.  Required up-front so a standalone `(require 'mutecipher-acp-tools)'
;; (test harness, autoload) doesn't trip a void-variable / void-function.
(require 'mutecipher-acp-tool-card)

;;;; Ingest / synthesize

(defun mutecipher-acp--ingest-tool-content (tc content-vec)
  "Append new diff items from CONTENT-VEC onto TC; return the list of new pairs.
Each pair is a cons cell `(oldText . newText)'.  Returns nil when nothing
new was added.  Mutates TC in place.  The returned list is in arrival
order so callers (notably the change-set capture) can apply reversals
in the order they happened."
  (when (and content-vec (vectorp content-vec))
    (let* ((total (length content-vec))
           (seen  (or (macp-tool-call-rendered-diff-count tc) 0))
           (new-pairs nil))
      (when (< seen total)
        (let ((i seen))
          (while (< i total)
            (let ((item (aref content-vec i)))
              (when (equal (plist-get item :type) "diff")
                (let ((pair (cons (plist-get item :oldText)
                                  (plist-get item :newText))))
                  (setf (macp-tool-call-diffs tc)
                        (append (macp-tool-call-diffs tc) (list pair)))
                  (push pair new-pairs))))
            (setq i (1+ i))))
        (setf (macp-tool-call-rendered-diff-count tc) total))
      (nreverse new-pairs))))

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
Returns UPDATE's own `:locations' (coerced to a vector of location
plists) when present and non-empty.  Otherwise synthesizes
`[{:path PATH}]' from the first string-valued key in `rawInput' listed
by `mutecipher-acp--raw-input-path-keys'.

A `:locations' value arriving as a *single* plist (e.g.
`(:path \"/x\" :line 3)' rather than `((:path …))') is wrapped in a
one-element vector rather than being blindly vectorized via
`apply' + `vector' — applying vector to a plist would produce
`[:path \"/x\" :line 3]', and the downstream
`(plist-get (aref locs 0) :path)' would return nil, silently dropping
the location for change-set capture."
  (let ((locs (plist-get update :locations)))
    (cond
     ((and (vectorp locs) (> (length locs) 0)) locs)
     ((and (consp locs) (keywordp (car locs)))
      ;; Single plist masquerading as `:locations'.
      (vector locs))
     ((and (listp locs) locs)
      ;; List of locations (each a plist or vector).
      (apply #'vector locs))
     (t
      (when-let* ((raw (plist-get update :rawInput))
                  ((listp raw))
                  (fp (seq-some
                       (lambda (k)
                         (let ((v (plist-get raw k)))
                           (and (stringp v) v)))
                       mutecipher-acp--raw-input-path-keys)))
        (vector (list :path fp)))))))

;;;; Tool input / raw output formatting

(defun mutecipher-acp--truncate-string (s max)
  "Return S clipped to MAX visual chars, with an ellipsis if truncated."
  (if (> (length s) max)
      (concat (substring s 0 (1- max)) "…")
    s))

(defun mutecipher-acp--abbreviate-path (s)
  "Return S abbreviated against `$HOME', falling back to the basename when
the absolute path is long.  Tool-call summary lines stay readable on
narrow windows."
  (let* ((abbr (abbreviate-file-name s)))
    (if (> (length abbr) 40)
        (file-name-nondirectory abbr)
      abbr)))

(defun mutecipher-acp--format-input-for-kind (raw kind)
  "Return a kind-specific summary string for RAW, or nil to fall through.
Handles the kinds whose default plist scan is unhelpful:
  - `move' renders `OLD → NEW' from `:source'/`:from' + `:destination'/`:to'
  - `switch_mode' renders `PREV → MODE' or just `MODE'
  - `fetch' surfaces `:url' over any generic string in the plist
Returns nil when nothing matches; the caller falls back to the
generic key scan in `--format-tool-input'."
  (when (listp raw)
    (pcase kind
      ("move"
       (let ((from (or (plist-get raw :source) (plist-get raw :from)))
             (to   (or (plist-get raw :destination) (plist-get raw :to))))
         (when (and (stringp from) (stringp to))
           (format "%s → %s"
                   (mutecipher-acp--abbreviate-path from)
                   (mutecipher-acp--abbreviate-path to)))))
      ("switch_mode"
       (let ((mode (plist-get raw :mode))
             (prev (plist-get raw :previousMode)))
         (cond
          ((and (stringp prev) (stringp mode)) (format "%s → %s" prev mode))
          ((stringp mode) mode))))
      ("fetch"
       (or (and (stringp (plist-get raw :url))   (plist-get raw :url))
           (and (stringp (plist-get raw :query)) (plist-get raw :query)))))))

(defun mutecipher-acp--format-tool-input (raw &optional max-len kind)
  "Format RAW tool input as a short display string.
MAX-LEN clamps the result (default 60).  Handles strings, plists, and
vectors.  KIND, when provided, selects a kind-specific formatter first
(see `--format-input-for-kind') before the generic plist scan."
  (let ((max (or max-len 60)))
    (when raw
      (let ((s (or (and kind (mutecipher-acp--format-input-for-kind raw kind))
                   (cond
                    ((stringp raw) raw)
                    ((listp raw)
                     (or (and (stringp (plist-get raw :command))  (plist-get raw :command))
                         (and (stringp (plist-get raw :cmd))      (plist-get raw :cmd))
                         (and (stringp (plist-get raw :url))      (plist-get raw :url))
                         (and (stringp (plist-get raw :query))    (plist-get raw :query))
                         (and (stringp (plist-get raw :path))     (plist-get raw :path))
                         (and (stringp (plist-get raw :content))  (plist-get raw :content))
                         (cl-loop for (_k v) on raw by #'cddr
                                  when (stringp v) return v)))
                    ((vectorp raw) (and (> (length raw) 0)
                                        (mutecipher-acp--format-tool-input (aref raw 0) max kind)))))))
        (when s
          (let* ((s1 (replace-regexp-in-string "\n" "\\\\n" (string-trim s)))
                 (s1 (replace-regexp-in-string "[ \t]+" " " s1)))
            (mutecipher-acp--truncate-string s1 max)))))))

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

;; Display-only helpers — `--truncate-output-for-display' and
;; `--indent-block' — live in `mutecipher-acp-tool-card.el' alongside
;; the body renderers that consume them.  `--first-output-line' was
;; unused after the split and has been dropped.

;;;; Enter / update tool-call nodes

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
           (kind    (plist-get update :kind))
           (detail  (mutecipher-acp--format-tool-input raw-in nil kind))
           (locs    (mutecipher-acp--synthesize-locations update))
           (loc-str (when (and locs (> (length locs) 0))
                      (plist-get (aref locs 0) :path)))
           (call-id (plist-get update :toolCallId))
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
                     :plan-body  plan
                     :raw-input  raw-in)))
      (let ((new-pairs (mutecipher-acp--ingest-tool-content
                        tc (plist-get update :content))))
        (mutecipher-acp--maybe-capture-change-set session tc new-pairs))
      (mutecipher-acp--with-sticky-tail buf
        (let* ((inhibit-read-only t)
               (collapsed (and mutecipher-acp-collapse-tool-calls-by-default
                               (not plan)))
               (node (mutecipher-acp--ewoc-enter-tail
                      mutecipher-acp--ewoc
                      (macp-session-queue-head-node session)
                      (make-macp-node :kind 'tool-call
                                      :data tc
                                      :collapsed collapsed))))
          (when call-id
            (puthash call-id node index))
          ;; A new tool-call inserted via `ewoc-enter-before' a non-tool
          ;; node (typically the queue-head) leaves that following node
          ;; with a stale leading-blank decision — it was rendered when
          ;; the prior node above it ended with `\n\n', so
          ;; `--ensure-blank-above' skipped.  Now the prior node IS
          ;; this tool-call which ends with `\n', so the following node
          ;; needs a fresh leading blank.  Force a re-render.
          (when-let* ((next (ewoc-next mutecipher-acp--ewoc node))
                      (next-kind (macp-node-kind (ewoc-data next)))
                      ((not (eq next-kind 'tool-call))))
            (ewoc-invalidate mutecipher-acp--ewoc next))))
      (mutecipher-acp--reconcile-spinner-for-session session))))

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
        ;; `:rawInput' is the *invocation* payload — tool_call carries
        ;; the canonical version.  Some agents echo a stripped or
        ;; status-only rawInput on later updates; replacing the ingest
        ;; snapshot would destroy the structured fields (`:todos',
        ;; `:url', `:prompt') that body renderers depend on.  Only
        ;; populate the slot the first time we see a value.
        (when (and raw-in (null (macp-tool-call-raw-input tc)))
          (setf (macp-tool-call-raw-input tc) raw-in))
        (when (and (null status-str) cmd-title)
          (let* ((prefix (concat (macp-tool-call-name tc) " "))
                 (detail (if (string-prefix-p prefix cmd-title)
                             (substring cmd-title (length prefix))
                           cmd-title)))
            (setf (macp-tool-call-input tc)
                  (mutecipher-acp--format-tool-input
                   detail nil (macp-tool-call-kind tc)))))
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
        (let ((new-pairs (mutecipher-acp--ingest-tool-content
                          tc (plist-get update :content))))
          (mutecipher-acp--maybe-capture-change-set session tc new-pairs))
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

(provide 'mutecipher-acp-tools)
;;; mutecipher-acp-tools.el ends here
