;;; mutecipher-acp-tools.el --- Tool-call rendering, diffs, and spinner for ACP  -*- lexical-binding: t -*-
;;
;; Owns everything tool-call shaped:
;; - macp-tool-call mutation (ingest content, update from RPC)
;; - raw-input / raw-output normalization
;; - unified diff generation, line-anchored rendering, file-line resolution
;; - the per-buffer spinner timer
;; - the tool-call pretty-printer (card with rail + summary + body)

;;; Code:

(require 'cl-lib)
(require 'diff)
(require 'diff-mode)
(require 'ewoc)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-log)
(require 'mutecipher-acp-ewoc)

(declare-function mutecipher-acp--close-assistant      "mutecipher-acp-ewoc")
(declare-function mutecipher/icon-for-acp              "mutecipher-icons")

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

(defcustom mutecipher-acp-change-set-max-bytes (* 256 1024)
  "Maximum file size for which pre-turn snapshots are stored inline.
Files larger than this are tracked in the change-set but with
`capture-status' = `suppressed-too-large' — revert refuses to operate on
them rather than ballooning the on-disk transcript."
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

;;;; Change-set capture
;;
;; The ACP server applies edits BEFORE notifying us, so by the time a
;; diff lands on a tool-call the file on disk is already in its
;; post-edit state.  To support "revert this turn" we reverse-apply the
;; just-arrived (old . new) pairs against the current disk content to
;; reconstruct what the file looked like before the turn touched it.
;;
;; The snapshot is captured ONCE per file per turn — the first time we
;; see any mutation against a given path within the active turn.  All
;; subsequent edits to the same file in the turn append their call-ids
;; to the existing file-change without disturbing `pre-turn-content',
;; which is exactly the rollback target we want.

(defun mutecipher-acp--resolve-loc-path (tc cwd)
  "Return TC's first location's path canonicalized to an absolute path, or nil.
Always passes through `expand-file-name' (handles `./', `..', trailing
slashes, `~') and `file-truename' (resolves symlinks) so the same
physical file keys identically across `assoc' lookups regardless of
the form the agent reports."
  (let* ((locs (macp-tool-call-locations tc))
         (loc  (and locs (> (length locs) 0) (aref locs 0)))
         (path (and loc (plist-get loc :path))))
    (when (stringp path)
      (let ((expanded (expand-file-name path cwd)))
        (condition-case _err
            (file-truename expanded)
          (error expanded))))))

(defun mutecipher-acp--replace-unique (needle replacement haystack)
  "Return HAYSTACK with the unique occurrence of NEEDLE replaced by REPLACEMENT.
Returns nil if NEEDLE is absent OR appears more than once — the reverse-
apply must refuse ambiguous matches rather than silently rewriting the
wrong span of an unrelated occurrence."
  (when (and (stringp needle) (not (string-empty-p needle))
             (stringp haystack))
    (let* ((first  (string-search needle haystack))
           (second (and first
                        (string-search needle haystack (1+ first)))))
      (cond
       ((null first) nil)
       (second       nil)  ; ambiguous — multiple matches
       (t (concat (substring haystack 0 first)
                  (or replacement "")
                  (substring haystack (+ first (length needle)))))))))

(defun mutecipher-acp--reverse-apply-pairs (content pairs)
  "Reverse-apply PAIRS to CONTENT; return (RESULT . STATUS).
PAIRS is a list of (oldText . newText) cons cells in chronological
(arrival) order.  Iteration is REVERSE-chronological — for chained
edits (MultiEdit-style, where edit N+1's oldText was edit N's newText)
the last edit must be undone first against the post-edit content.

Status outcomes:
  `ok'                     all pairs reversed successfully
  `reverse-apply-failed'   any pair's newText is missing OR ambiguous
                           (multiple matches), OR a pair represents a
                           deletion (non-empty oldText, empty newText)
                           which cannot be reversed without a position
                           anchor

A pair with BOTH halves empty is a no-op and skipped."
  (let ((work content)
        (status 'ok))
    (catch 'fail
      (dolist (pair (reverse pairs))
        (let* ((old (car pair))
               (new (cdr pair))
               (old-empty (or (null old) (string-empty-p old)))
               (new-empty (or (null new) (string-empty-p new))))
          (cond
           ;; Both empty: trivial no-op pair.
           ((and old-empty new-empty) nil)
           ;; Deletion (non-empty old, empty new): we can't reinsert
           ;; without knowing where, so refuse.
           (new-empty
            (setq status 'reverse-apply-failed)
            (throw 'fail nil))
           ;; Normal case: replace unique occurrence of new with old.
           (t
            (let ((replaced (mutecipher-acp--replace-unique new old work)))
              (cond
               (replaced (setq work replaced))
               (t (setq status 'reverse-apply-failed)
                  (throw 'fail nil)))))))))
    (cons (and (eq status 'ok) work) status)))

(defun mutecipher-acp--capture-snapshot (path pairs)
  "Snapshot PATH's pre-turn content using PAIRS to reverse the on-disk state.
Returns a plist `(:pre-turn-content C :pre-turn-existed E :capture-status S)'.
Honors `mutecipher-acp-change-set-max-bytes' — files over the cap are
recorded with status `suppressed-too-large' and no content.

Heuristic for distinguishing Write-creates from Write-overwrites:
when reverse-apply yields the empty string AND at least one pair had
an empty `oldText', the file was created by the turn — revert will
delete it.  An empty file overwritten to empty falls into the same
branch, but deleting an empty file is benign."
  (let* ((existed (file-exists-p path))
         (attrs   (and existed (file-attributes path)))
         (size    (and attrs (file-attribute-size attrs))))
    (cond
     ((not existed)
      ;; Edge case: file is gone at capture time.  Nothing to snapshot;
      ;; revert is a no-op.
      (list :pre-turn-content nil
            :pre-turn-existed nil
            :capture-status   'ok))
     ((and size (> size mutecipher-acp-change-set-max-bytes))
      (list :pre-turn-content nil
            :pre-turn-existed t
            :capture-status   'suppressed-too-large))
     (t
      (let* ((current (with-temp-buffer
                        ;; Force `-unix' so a CRLF file isn't EOL-detected
                        ;; into LF in memory — otherwise `string-search'
                        ;; matches the LF-normalized newText against the
                        ;; LF buffer, snapshot is stored as LF, and revert
                        ;; flips the file's line endings.  Match the
                        ;; persist layer (mutecipher-acp-persist.el:87,99).
                        (let ((coding-system-for-read 'utf-8-unix))
                          (insert-file-contents path))
                        (buffer-string)))
             (result   (mutecipher-acp--reverse-apply-pairs current pairs))
             (restored (car result))
             (status   (cdr result))
             (likely-creation
              (and (eq status 'ok)
                   (or (null restored) (string-empty-p restored))
                   (cl-some (lambda (p)
                              (or (null (car p))
                                  (string-empty-p (car p))))
                            pairs))))
        (cond
         ((not (eq status 'ok))
          (list :pre-turn-content nil
                :pre-turn-existed t
                :capture-status   'reverse-apply-failed))
         (likely-creation
          (list :pre-turn-content nil
                :pre-turn-existed nil
                :capture-status   'ok))
         (t
          (list :pre-turn-content restored
                :pre-turn-existed t
                :capture-status   'ok))))))))

(defun mutecipher-acp--cs-merge-call-id (fc call-id)
  "Append CALL-ID to FC's tool-call-ids if not already present."
  (when (and call-id
             (not (member call-id (macp-file-change-tool-call-ids fc))))
    (setf (macp-file-change-tool-call-ids fc)
          (append (macp-file-change-tool-call-ids fc) (list call-id)))))

(defun mutecipher-acp--cs-write-file-change (cs path fc)
  "Insert or replace PATH's entry in change-set CS with FC.
The alist is appended-to (rather than nconc'd at the head) so the
visual order in any future review panel matches insertion order."
  (let ((existing (assoc path (macp-change-set-files cs))))
    (if existing
        (setcdr existing fc)
      (setf (macp-change-set-files cs)
            (append (macp-change-set-files cs) (list (cons path fc)))))))

(defun mutecipher-acp--maybe-capture-change-set (session tc new-pairs)
  "Update SESSION's current-turn change-set from a mutation on TC.
NEW-PAIRS is the just-ingested sublist of `(oldText . newText)' cells.
May be nil — see retroactive-capture rules below.

Capture decisions:

  - First observation of TC's path: snapshot from disk reverse-applied
    through every pair we have for this turn touching this path
    (NEW-PAIRS, or fall back to the tc's full `:diffs' for retroactive
    capture when locations arrived late on a follow-up update).
  - Existing entry with NEW-PAIRS: accumulate the new pairs into the
    file-change's history and re-snapshot.  Required so incremental
    diff delivery on a single tool call doesn't bake intermediate
    state into the pre-turn snapshot.
  - Existing entry currently `capture-status'=`reverse-apply-failed':
    retry — a failed capture during status='pending' (before the file
    was mutated) may now succeed against the post-edit disk content.
  - Existing entry with no new pairs and `ok' status: just record
    CALL-ID against the file-change.

All I/O is wrapped in `condition-case' so a permission or read failure
on one file doesn't cascade out into the RPC handler and break the
agent's turn — failures are logged and capture-status reflects the
gap."
  (when (and session (or new-pairs (macp-tool-call-diffs tc)))
    (when-let* ((turn-node (macp-session-current-turn-node session))
                (turn     (macp-node-data (ewoc-data turn-node)))
                ((macp-turn-p turn))
                (path     (mutecipher-acp--resolve-loc-path
                           tc (macp-session-cwd session))))
      (condition-case err
          (let* ((cs (or (macp-turn-change-set turn)
                         (setf (macp-turn-change-set turn)
                               (make-macp-change-set :files nil))))
                 (existing (cdr (assoc path (macp-change-set-files cs))))
                 (call-id (macp-tool-call-call-id tc))
                 (should-snapshot
                  (or (null existing)
                      new-pairs
                      (eq (macp-file-change-capture-status existing)
                          'reverse-apply-failed))))
            (cond
             (should-snapshot
              (let* ((prior-pairs (and existing
                                       (macp-file-change-accumulated-pairs
                                        existing)))
                     ;; For retroactive capture (first observation, no
                     ;; new-pairs), fall back to the tc's full diffs —
                     ;; that's the only history we have.
                     (effective-new (or new-pairs
                                        (and (null existing)
                                             (macp-tool-call-diffs tc))))
                     (all-pairs (append prior-pairs effective-new))
                     (snap (mutecipher-acp--capture-snapshot path all-pairs))
                     (fc (make-macp-file-change
                          :path             path
                          :pre-turn-content (plist-get snap :pre-turn-content)
                          :pre-turn-existed (plist-get snap :pre-turn-existed)
                          :capture-status   (plist-get snap :capture-status)
                          :status           (or (and existing
                                                     (macp-file-change-status
                                                      existing))
                                                'accepted)
                          :tool-call-ids    (and existing
                                                 (macp-file-change-tool-call-ids
                                                  existing))
                          :accumulated-pairs all-pairs)))
                (mutecipher-acp--cs-merge-call-id fc call-id)
                (mutecipher-acp--cs-write-file-change cs path fc)))
             (t
              (mutecipher-acp--cs-merge-call-id existing call-id)))
            (mutecipher-acp--mark-dirty session))
        (error
         (mutecipher-acp--log-warn
          'agent-warn (macp-session-agent session)
          (format "[change-set] capture failed for %s: %s"
                  path (error-message-string err))))))))

(declare-function mutecipher-acp--mark-dirty "mutecipher-acp-persist")

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
            (puthash call-id node index))))
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

;;;; Tool input / raw output formatting

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

;;;; Diff generation and rendering

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

;;;; Icon helpers (shared with pretty-printer)

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

;;;; Spinner
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

;;;; Tool-call pretty-printer

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

;; Register the tool-call node kind in the ewoc dispatcher.
(declare-function mutecipher-acp-register-node-kind "mutecipher-acp-ewoc")
(mutecipher-acp-register-node-kind 'tool-call #'mutecipher-acp--pp-tool-call)

(provide 'mutecipher-acp-tools)
;;; mutecipher-acp-tools.el ends here
