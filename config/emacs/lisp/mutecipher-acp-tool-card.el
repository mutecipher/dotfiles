;;; mutecipher-acp-tool-card.el --- Tool-call card pretty-printer + spinner  -*- lexical-binding: t -*-
;;
;; Pure render-side module for tool-call nodes:
;;   - icon-key derivation from kind / claudeCode tool name
;;   - status / kind glyphs and the rotating spinner
;;   - the one-line summary + card body pretty-printer
;;   - a tool-name-keyed body-renderer registry so individual tools
;;     (TodoWrite, Task, WebFetch, WebSearch, ...) can override the
;;     default plan/raw-output/diffs body without forking the card
;;
;; Knows nothing about the JSON wire format: consumes
;; `macp-tool-call' structs that `mutecipher-acp-tools.el' has already
;; populated.  Changes here restyle the transcript; data flow lives
;; elsewhere.

;;; Code:

(require 'cl-lib)
(require 'ewoc)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-diff)
(require 'mutecipher-acp-ewoc)

(declare-function mutecipher/icon-for-acp                "mutecipher-icons")
(declare-function mutecipher-acp--normalize-raw-output   "mutecipher-acp-tools")

(defcustom mutecipher-acp-tool-output-max-lines 40
  "Maximum line count rendered inline for a tool call's raw output.
Outputs longer than this are truncated in the expanded card body with a
trailing \"… N more lines\" marker; the full text is still kept on the
struct so it remains available for copy or re-render at a higher cap."
  :type 'integer
  :group 'mutecipher-acp)

;;;; Output display helpers
;;
;; Truncation + indentation utilities used by body renderers and the
;; default body.  Display-only — they assume `--normalize-raw-output'
;; (in `mutecipher-acp-tools.el') has already coerced wire shapes to a
;; plain string at ingest time.

(defun mutecipher-acp--tool-output-line-count (raw)
  "Return the line count of RAW (0 if nil or empty).
RAW is normally a string at this point; `--normalize-raw-output' may
still be called for legacy structs whose `raw-output' slot holds the
wire-form vector."
  (let ((s (if (stringp raw) raw
             (mutecipher-acp--normalize-raw-output raw))))
    (cond
     ((or (null s) (string-empty-p s)) 0)
     (t (1+ (cl-count ?\n s))))))

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

(defcustom mutecipher-acp-collapse-tool-calls-by-default t
  "If non-nil, terminal-status tool calls render collapsed by default.
Collapsed = a single summary line; expanded = the summary plus the
tool's raw output, plan body, and diffs indented underneath.  Toggle
the whole transcript with `mutecipher/acp-toggle-tool-calls'."
  :type 'boolean
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-group-read-only-tool-calls t
  "If non-nil, fold adjacent read-only tool calls into one `Explored …' group.
A run of consecutive Read / Grep / Glob / WebFetch / WebSearch
invocations renders as a single summary line (\"Explored 6 files,
3 searches\") that the user can expand on demand.  A subsequent
write/edit/bash, an assistant chunk, a new turn, or any non-read node
closes the group; the next read opens a fresh one.  Set to nil to fall
back to the original one-card-per-tool layout."
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

;;;; Icon helpers

(defun mutecipher-acp--probe-kind-from-name (name)
  "Return an icon-key derived from claudeCode tool NAME, or nil.
Used when the ACP `:kind' field is missing or under-specified — the
tool name often carries the real intent (WebFetch → tool-fetch,
TodoWrite → tool-todo, Task → tool-task)."
  (when (stringp name)
    (cond
     ((string-match-p "\\`Todo" name)               'tool-todo)
     ((string-equal name "Task")                    'tool-task)
     ((string-match-p "\\`Web\\(Fetch\\|Search\\)" name) 'tool-fetch)
     ((string-match-p "\\`Notebook" name)
      ;; Substring (not anchored) so `NotebookEditCell' / future
      ;; `Notebook*Edit*' variants route to the edit icon rather than
      ;; silently falling through to read.
      (if (string-match-p "Edit" name) 'tool-edit 'tool-read))
     ((string-equal name "Glob")                    'tool-grep)
     ((string-equal name "ExitPlanMode")            'tool-switch-mode)
     ((string-prefix-p "mcp__" name)                'tool-other))))

(defun mutecipher-acp--tool-kind-icon-key (kind &optional name)
  "Map a tool-call KIND string from ACP to a `mutecipher-icons-acp-alist' key.
When KIND is `\"other\"' or nil, falls back to a NAME-based probe so
tools that ship without a precise `:kind' still get a meaningful icon."
  (or (pcase kind
        ("edit"        'tool-edit)
        ("write"       'tool-write)
        ("execute"     'tool-bash)
        ("read"        'tool-read)
        ("search"      'tool-grep)
        ("delete"      'tool-delete)
        ("move"        'tool-move)
        ("fetch"       'tool-fetch)
        ("think"       'tool-think)
        ("switch_mode" 'tool-switch-mode))
      (mutecipher-acp--probe-kind-from-name name)
      'tool-other))

(defconst mutecipher-acp--tool-group-bucket-alist
  '((tool-read  . files)
    (tool-grep  . searches)
    (tool-fetch . searches))
  "Maps a read-only icon-key to its `Explored …' summary bucket.
A key with an entry here is foldable into an adjacent tool-group AND
counts toward the named bucket on the summary line.  Adding a new
read-only category (e.g. `tool-readdir' → `files') only needs one
entry here — the fold predicate `--tool-call-read-only-p' and the
per-bucket counter `--tool-group-counts' both consult this alist so
they can't drift apart.  Bash, edits, writes, deletes, moves,
`think', `switch_mode', and unclassified tools have no entry and stay
out of groups.")

(defun mutecipher-acp--tool-call-read-only-p (tc)
  "Non-nil when tool-call TC has a bucket in `--tool-group-bucket-alist'.
Routes through `--tool-kind-icon-key' so the ACP `kind' string and
the claudeCode name-based fallback (Glob, WebFetch, WebSearch) yield
consistent classification."
  (and (assq (mutecipher-acp--tool-kind-icon-key
              (macp-tool-call-kind tc)
              (macp-tool-call-name tc))
             mutecipher-acp--tool-group-bucket-alist)
       t))

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
  "Return a propertized status glyph for tool-call STATUS, or nil.
Returns the animated spinner for `pending' / `running' — the only
state where motion adds signal.  Returns nil for terminal states
(`done', `error') and for nil/unrecognized: success is the default
(markers denote exceptions), and failure surfaces via tool-name face
+ `failed' badge in the meta slot rather than a leading glyph."
  (pcase status
    ((or 'pending 'running)
     (mutecipher-acp--spinner-glyph status))
    (_ nil)))

(defun mutecipher-acp--tool-call-active-p (data)
  "Non-nil if ewoc node DATA carries any `pending' / `running' tool call.
Recognizes both stand-alone `tool-call' wrappers and `tool-group'
wrappers (the spinner needs to keep ticking while a grouped read is
still in flight)."
  (pcase (macp-node-kind data)
    ('tool-call
     (memq (macp-tool-call-status (macp-node-data data))
           '(pending running)))
    ('tool-group
     (cl-some (lambda (tc)
                (memq (macp-tool-call-status tc) '(pending running)))
              (macp-tool-group-children (macp-node-data data))))))

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

;;;; Body-renderer registry
;;
;; A per-tool body renderer overrides the default plan/raw-output/diffs
;; body for the expanded card.  Lookup keys on the claudeCode tool name
;; (the most specific source of intent) with a fallback to the ACP
;; `:kind' field.  Renderer contract:
;;
;;   (FN tc) → inserts the body at point, no leading indent, lines
;;             ending in newline.  Card's `line-prefix' supplies the
;;             rail; the renderer just produces content.
;;
;; To compose with the default body (e.g. show a URL header THEN the
;; agent's raw output), call `mutecipher-acp--pp-default-tool-body'
;; from within the renderer.

(defvar mutecipher-acp-tool-body-renderers nil
  "Alist mapping tool key (string) → body-renderer function.
Keys may be a claudeCode tool name (`\"WebFetch\"', `\"TodoWrite\"', …)
or an ACP `:kind' value (`\"fetch\"', `\"edit\"', …).  Lookup
(`--lookup-tool-body-renderer') tries the `name' slot first, then the
`kind' slot — so a renderer registered under the ACP kind also fires
for agents that omit `_meta.claudeCode.toolName'.

Each renderer is called with one argument (the `macp-tool-call'
struct) and is expected to `insert' the expanded card body at point.
Falls back to the default plan/raw-output/diffs renderer when no key
matches.")

(defun mutecipher-acp-register-tool-body-renderer (key fn)
  "Register FN as the body renderer for tool KEY.
KEY is a claudeCode tool name OR an ACP `:kind' string; the lookup
tries name then kind, so registering under either form is valid."
  (setf (alist-get key mutecipher-acp-tool-body-renderers nil nil #'equal) fn))

(defun mutecipher-acp--lookup-tool-body-renderer (tc)
  "Return the registered body renderer for TC, or nil.
Tries `(macp-tool-call-name tc)' first (preserving the existing
claudeCode-tool-name keying), then `(macp-tool-call-kind tc)' — so
renderers also fire for agents that ship a recognizable ACP kind
without setting `_meta.claudeCode.toolName'."
  (let ((name (macp-tool-call-name tc))
        (kind (macp-tool-call-kind tc)))
    (or (and (stringp name)
             (alist-get name mutecipher-acp-tool-body-renderers
                        nil nil #'equal))
        (and (stringp kind)
             (alist-get kind mutecipher-acp-tool-body-renderers
                        nil nil #'equal)))))

;;;; Default body (plan + raw output + diffs)
;;
;; The body is split into two pieces so per-tool renderers (TodoWrite,
;; Task, …) can replace the "header" (raw output) with bespoke
;; formatting while still emitting the universal "attachments" trailer
;; — plan-body (ExitPlanMode markdown) and diffs.  Any tool can ship
;; diffs alongside its primary payload (a Task subagent that edits a
;; file, a TodoWrite that batches a file mutation), and losing those
;; attachments was the pre-fix regression.

(defun mutecipher-acp--pp-tool-call-plan (tc)
  "Insert TC's plan-body markdown block at point, if any.
Indented four spaces inside the card."
  (when-let ((plan (macp-tool-call-plan-body tc)))
    (insert (propertize
             (concat (mutecipher-acp--indent-block plan "    ") "\n")
             'face 'shadow))))

(defun mutecipher-acp--pp-tool-call-diffs (tc)
  "Insert TC's diffs at point, anchored at the file line when known.
Relative paths in `:locations[0].path' resolve against the session's
cwd.  Each diff pair (oldText . newText) renders via the diff module."
  (let* ((session (and mutecipher-acp--session-id
                       (gethash mutecipher-acp--session-id
                                mutecipher-acp--sessions)))
         (cwd     (and session (macp-session-cwd session)))
         (diffs   (macp-tool-call-diffs tc))
         (start   (mutecipher-acp--tool-call-start-line tc cwd)))
    (dolist (pair diffs)
      (when-let ((body (mutecipher-acp--diff-body-for
                        (car pair) (cdr pair) start)))
        (insert body)))))

(defun mutecipher-acp--pp-tool-call-attachments (tc)
  "Insert TC's plan-body and diffs at point.
Every per-tool body renderer should end with a call to this helper so
plan markdown (ExitPlanMode) and any attached diffs render under the
tool's bespoke header — pre-fix, registered renderers silently
dropped both."
  (mutecipher-acp--pp-tool-call-plan tc)
  (mutecipher-acp--pp-tool-call-diffs tc))

(defun mutecipher-acp--pp-default-tool-body (tc)
  "Insert the default expanded body for TC: plan, raw output, then diffs.
Lines are indented four spaces inside the card so body content aligns
with the tool name on the summary line.  Diffs are anchored at the
file line via `:locations[0].line' (or, falling back, by searching the
file at `:locations[0].path' for the diff's `newText').  Relative
paths are resolved against the session's cwd."
  (mutecipher-acp--pp-tool-call-plan tc)
  (let ((raw (macp-tool-call-raw-output tc)))
    (when (and raw (stringp raw) (not (string-empty-p raw)))
      (let ((clipped (mutecipher-acp--truncate-output-for-display raw)))
        (insert (propertize
                 (concat (mutecipher-acp--indent-block clipped "    ") "\n")
                 'face 'shadow)))))
  (mutecipher-acp--pp-tool-call-diffs tc))

;;;; Tier-1 body renderers
;;
;; TodoWrite renders the :todos array as a checklist using the existing
;; plan-* status icons (so themes color them by meaning).  Task renders
;; the subagent type + truncated prompt + the result.  WebFetch and
;; WebSearch share a renderer that shows the URL/query line plus the
;; default raw-output body underneath.

(defun mutecipher-acp--todo-item-icon-key (status)
  "Map a TodoWrite item STATUS string to a plan-icon key."
  (pcase status
    ("completed"   'plan-done)
    ("in_progress" 'plan-inprogress)
    (_             'plan-pending)))

(defun mutecipher-acp--render-todo-body (tc)
  "Body renderer for TodoWrite: render `:todos' as a checklist.
Falls back to the default body when `:todos' is missing, empty, or
not a usable sequence (a list or vector).  Always appends
attachments (plan-body + diffs) after the checklist so a TodoWrite
call that also ships file edits doesn't silently drop them."
  (let* ((raw   (macp-tool-call-raw-input tc))
         (todos (and (listp raw) (plist-get raw :todos)))
         ;; Coerce to a list once so we can `dolist' regardless of
         ;; whether the JSON parser produced a vector or a list.  An
         ;; unexpected scalar (`:json-false', number, …) becomes nil
         ;; and trips the empty fallback rather than signalling.
         (items (cond
                 ((vectorp todos) (append todos nil))
                 ((listp todos)   todos)
                 (t               nil))))
    (cond
     ((null items)
      (mutecipher-acp--pp-default-tool-body tc))
     (t
      (dolist (item items)
        (let* ((content (or (and (listp item) (plist-get item :content)) ""))
               (active  (and (listp item) (plist-get item :activeForm)))
               (status  (and (listp item) (plist-get item :status)))
               (icon    (mutecipher-acp--icon-or
                         (mutecipher-acp--todo-item-icon-key status)
                         "•"))
               (label   (if (and (stringp active)
                                 (not (string-empty-p active))
                                 (equal status "in_progress"))
                            active
                          content))
               (face    (if (equal status "completed")
                            '(:strike-through t :inherit shadow)
                          'default)))
          (insert "    " icon " "
                  (propertize label 'face face)
                  "\n")))
      (mutecipher-acp--pp-tool-call-attachments tc)))))

(defun mutecipher-acp--render-task-body (tc)
  "Body renderer for Task (subagent): subagent header + prompt + result.
Always emits attachments (plan-body + diffs) at the end — a subagent
that produces file edits ships those as diffs on the parent tool-call;
pre-fix they were silently dropped.  Falls back to the default body
when none of the structured fields nor output are present so an
expanded card never renders as an empty rail-bounded region."
  (let* ((raw     (macp-tool-call-raw-input tc))
         (subtype (and (listp raw) (plist-get raw :subagent_type)))
         (desc    (and (listp raw) (plist-get raw :description)))
         (prompt  (and (listp raw) (plist-get raw :prompt)))
         (output  (macp-tool-call-raw-output tc))
         (rendered nil))
    (when subtype
      (insert "    "
              (propertize "subagent: " 'face 'shadow)
              (propertize (format "%s" subtype) 'face 'mutecipher-acp-tool-face)
              "\n")
      (setq rendered t))
    (when (and (stringp desc) (not (string-empty-p desc)))
      (insert "    "
              (propertize desc 'face 'shadow)
              "\n")
      (setq rendered t))
    (when (and (stringp prompt) (not (string-empty-p prompt)))
      (let ((clipped (mutecipher-acp--truncate-output-for-display prompt)))
        (insert (propertize
                 (concat (mutecipher-acp--indent-block clipped "    ") "\n")
                 'face 'shadow)))
      (setq rendered t))
    (when (and (stringp output) (not (string-empty-p output)))
      (let ((clipped (mutecipher-acp--truncate-output-for-display output)))
        (insert "\n"
                (propertize
                 (concat (mutecipher-acp--indent-block clipped "    ") "\n")
                 'face 'default)))
      (setq rendered t))
    (if rendered
        (mutecipher-acp--pp-tool-call-attachments tc)
      ;; Nothing structured to show — fall back so the user at least
      ;; sees plan/raw-output/diffs rather than an empty body.
      (mutecipher-acp--pp-default-tool-body tc))))

(defun mutecipher-acp--render-fetch-body (tc)
  "Body renderer for WebFetch / WebSearch: URL/query header + default output.
The URL gets the `link' face (it really is one) but a plain WebSearch
query stays at the default face — applying `link' to non-URL text
makes search terms look underlined/clickable in many themes."
  (let* ((raw   (macp-tool-call-raw-input tc))
         (url   (and (listp raw) (plist-get raw :url)))
         (query (and (listp raw) (plist-get raw :query)))
         (label (cond
                 ((and (stringp url) (not (string-empty-p url)))
                  (list "url: " url 'link))
                 ((and (stringp query) (not (string-empty-p query)))
                  (list "query: " query 'default)))))
    (when label
      (insert "    "
              (propertize (nth 0 label) 'face 'shadow)
              (propertize (nth 1 label) 'face (nth 2 label))
              "\n"))
    (mutecipher-acp--pp-default-tool-body tc)))

(mutecipher-acp-register-tool-body-renderer "TodoWrite"  #'mutecipher-acp--render-todo-body)
(mutecipher-acp-register-tool-body-renderer "Task"       #'mutecipher-acp--render-task-body)
(mutecipher-acp-register-tool-body-renderer "WebFetch"   #'mutecipher-acp--render-fetch-body)
(mutecipher-acp-register-tool-body-renderer "WebSearch"  #'mutecipher-acp--render-fetch-body)
;; Kind-keyed fallback for fetch — agents that ship `:kind "fetch"' but
;; omit `_meta.claudeCode.toolName' still get URL-header rendering.
;; TodoWrite/Task have no clean kind equivalent (both flow through
;; `:kind "other"'), so they stay name-only.
(mutecipher-acp-register-tool-body-renderer "fetch"      #'mutecipher-acp--render-fetch-body)

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

(defun mutecipher-acp--pp-tool-call-line (tc)
  "Insert the one-line summary for tool-call TC.

Layout — the row gutter at col 0-1 is shared with message rows so any
state signifier (spinner here, `▌' on user/assistant rows) sits in the
same column across the transcript.  Tool calls then add an additional
2-column indent to mark themselves as subordinate to the assistant
turn that triggered them, putting the body at col 4.

  col 0-1: gutter — spinner + space when in-flight, two spaces otherwise
  col 2-3: tool-call indent (the `additional 2 spaces' on top of the
           message-level col-2 body)
  col 4  : kind icon (pencil for edit, terminal for execute, …) when
           a Nerd Font glyph resolves; if no glyph, name shifts left
           to col 4 directly
  col 5  : single space separator (only when a kind icon was emitted)
  col 6+ : Name(input), in `mutecipher-acp-tool-face' on success or
           `mutecipher-acp-error-face' on failure
  right  : meta chunk (`N lines · M diffs', `failed', …) flush-right
           via `display' (space :align-to right)

Examples:

  ⠋   ✎ Edit(foo.el)           — running: spinner in the gutter
      ✎ Edit(foo.el)            — done: gutter empty
      ✎ Bash(npm test)  failed  — error: red name, `failed' badge,
                                  body stays expanded below"
  (let* ((name      (or (macp-tool-call-name tc) "tool"))
         (input     (macp-tool-call-input tc))
         (status    (macp-tool-call-status tc))
         (status-g  (mutecipher-acp--tool-status-glyph status))
         (kind-key  (mutecipher-acp--tool-kind-icon-key
                     (macp-tool-call-kind tc) name))
         (kind-g    (mutecipher-acp--icon-or kind-key nil))
         (meta      (mutecipher-acp--tool-meta tc))
         (name-face (if (eq status 'error)
                        'mutecipher-acp-error-face
                      'mutecipher-acp-tool-face))
         (line-beg  (point)))
    (if status-g
        (insert status-g " ")
      (insert "  "))
    (insert "  ")
    (when kind-g
      (insert kind-g " "))
    (insert (propertize (concat name (if input (concat "(" input ")") ""))
                        'face name-face))
    (when meta
      (let* ((meta-str (propertize meta 'face 'shadow))
             (meta-w   (string-width meta-str)))
        (insert (propertize " "
                            'display `(space :align-to (- right ,meta-w)))
                meta-str)))
    (insert "\n")
    ;; Wrap continuation aligns at column 4 — the body column where
    ;; the kind icon (or name, when no Nerd Font) sits.
    (add-text-properties line-beg (point)
                         '(wrap-prefix "    "))))

(defun mutecipher-acp--pp-tool-call-body (tc)
  "Insert the expanded body for TC, dispatching to a registered renderer if any.
Looks up `mutecipher-acp-tool-body-renderers' via
`--lookup-tool-body-renderer' (name first, then kind); falls back to
`mutecipher-acp--pp-default-tool-body' when neither key matches."
  (if-let ((fn (mutecipher-acp--lookup-tool-body-renderer tc)))
      (funcall fn tc)
    (mutecipher-acp--pp-default-tool-body tc)))

(defun mutecipher-acp--pp-tool-call (node)
  "Render a tool-call NODE.
Collapsed nodes render as a single summary line with the status glyph
at column 0 (the `gutter' position, same as the `▌' role glyphs on
user/assistant rows) and no card chrome — so a turn with many tool
calls (subagent dispatches, parallel reads) doesn't fill the window
with stacked rails.  Expanded nodes emit the same summary line, then
a `╭ │ … ╰' card indented to column 2 around the body content;
chrome sits under the body so visually the card belongs to the
summary above.

Trailing single newline in both states; the master `--pp' dispatcher
in `mutecipher-acp-ewoc.el' inserts a blank-line separator before
non-tool nodes, so adjacent tools stack tight while a tool → non-tool
transition still gets one blank line of padding."
  (let* ((tc        (macp-node-data node))
         (collapsed (macp-node-collapsed node)))
    (mutecipher-acp--pp-tool-call-line tc)
    (unless collapsed
      (let* ((rail-face   'mutecipher-acp-tool-card-face)
             (rule-face   'mutecipher-acp-tool-card-rule-face)
             (line-prefix (propertize "  │ " 'face rail-face))
             (rule        (propertize " "
                                      'display '(space :align-to right)
                                      'face rule-face)))
        (insert "  " (propertize "╭" 'face rail-face) rule "\n")
        (let ((body-beg (point)))
          (mutecipher-acp--pp-tool-call-body tc)
          (add-text-properties body-beg (point)
                               (list 'line-prefix line-prefix
                                     'wrap-prefix line-prefix)))
        ;; Single trailing `\n' (no blank line below `╰').  Adjacent
        ;; tool calls stack tight; if the next node is a non-tool
        ;; kind, the master `--pp' dispatcher's `--ensure-blank-above'
        ;; takes care of separating it from the `╰' rule.
        (insert "  " (propertize "╰" 'face rail-face) rule "\n")))))

(mutecipher-acp-register-node-kind 'tool-call #'mutecipher-acp--pp-tool-call)

;;;; Tool-group pretty-printer
;;
;; A run of adjacent read-only tool calls (Read, Grep, Glob, WebFetch,
;; WebSearch) renders as a single `Explored N files, M searches' card
;; instead of stacked individual cards.  Single-child groups delegate
;; to the standard tool-call card so a lone read looks identical to
;; today; multi-child groups switch to the summary line, with TAB
;; expanding to a terse one-line-per-child list (no card chrome — the
;; chrome belongs to the group, not each child).

(defun mutecipher-acp--tool-group-status (children)
  "Return an aggregate status symbol for CHILDREN.
Resolves to `running'/`pending' (any in-flight child), `error' (every
child terminal but at least one failed), or `done' (every child
completed cleanly).  The collapsed group summary line uses this to
pick its gutter glyph so the user can tell at a glance whether reads
are still landing — same role the per-card status glyph plays for
stand-alone tool-call nodes."
  (let ((has-running nil) (has-pending nil) (has-error nil))
    (dolist (tc children)
      (pcase (macp-tool-call-status tc)
        ('running (setq has-running t))
        ('pending (setq has-pending t))
        ('error   (setq has-error t))))
    (cond (has-running 'running)
          (has-pending 'pending)
          (has-error   'error)
          (t           'done))))

(defun mutecipher-acp--tool-group-counts (children)
  "Return (FILES . SEARCHES) counts for CHILDREN.
Routes each child's icon-key through
`mutecipher-acp--tool-group-bucket-alist' so this counter shares its
vocabulary with the fold predicate — they can't drift apart.  An
unclassified child (e.g. a future kind added to the predicate without
a bucket here) is silently skipped; `--tool-group-summary' has a
fallback for the all-zero case."
  (let ((files 0) (searches 0))
    (dolist (tc children)
      (pcase (cdr (assq (mutecipher-acp--tool-kind-icon-key
                         (macp-tool-call-kind tc)
                         (macp-tool-call-name tc))
                        mutecipher-acp--tool-group-bucket-alist))
        ('files    (cl-incf files))
        ('searches (cl-incf searches))))
    (cons files searches)))

(defun mutecipher-acp--tool-group-summary (children)
  "Return the propertized `Explored N files, M searches' summary for CHILDREN.
The base text is `shadow' face.  When any child has status `error',
appends a `(K failed)' suffix in `error' face so a partial failure
inside an otherwise quiet group line is visible at a glance.  Omits
the absent half when only one category is present (pure search runs
read `Explored 3 searches', not `0 files, 3 searches').  Defensive
fallback handles a group whose classification shifted and produced
zero counts."
  (let* ((counts   (mutecipher-acp--tool-group-counts children))
         (files    (car counts))
         (searches (cdr counts))
         (failed   (cl-count-if (lambda (tc)
                                  (eq (macp-tool-call-status tc) 'error))
                                children))
         (parts    nil))
    (when (> files 0)
      (push (format "%d file%s" files (if (= files 1) "" "s")) parts))
    (when (> searches 0)
      (push (format "%d search%s" searches (if (= searches 1) "" "es"))
            parts))
    (let* ((base-text (if parts
                          (concat "Explored "
                                  (mapconcat #'identity (nreverse parts) ", "))
                        (format "Explored %d call%s"
                                (length children)
                                (if (= 1 (length children)) "" "s"))))
           (base (propertize base-text 'face 'shadow)))
      (if (> failed 0)
          (concat base
                  (propertize (format " (%d failed)" failed) 'face 'error))
        base))))

(defun mutecipher-acp--pp-tool-group (node)
  "Render a tool-group NODE.
N=1: delegate to `--pp-tool-call' with a synthetic wrapper that
carries the group's uuid + collapsed state, so a lone read renders
identically to today and any uuid-keyed feature still resolves.  N>=2
collapsed: one muted `Explored …' line with an aggregate status glyph
at column 0 (spinner while any child is in flight, ✓/✗ otherwise) —
matches the existing tool-card gutter convention.  N>=2 expanded:
same summary line, then each child rendered as its own full
`--pp-tool-call' card below — preserves the body the user was reading
across an N=1→N=2 transition."
  (let* ((group     (macp-node-data node))
         (children  (macp-tool-group-children group))
         (n         (length children))
         (collapsed (macp-node-collapsed node)))
    (cond
     ((zerop n)
      ;; Defensive only — `--enter-tool-call' never creates an empty
      ;; group, but a corrupted persisted node shouldn't render as a
      ;; zero-width region that the user can't interact with.
      (insert (propertize "Explored (empty group)\n" 'face 'shadow)))
     ((= 1 n)
      (mutecipher-acp--pp-tool-call
       (make-macp-node :kind 'tool-call
                       :data (car children)
                       :collapsed collapsed
                       :uuid (macp-node-uuid node))))
     (t
      (let* ((summary  (mutecipher-acp--tool-group-summary children))
             (status   (mutecipher-acp--tool-group-status children))
             (status-g (mutecipher-acp--tool-status-glyph status))
             (line-beg (point)))
        ;; Same gutter-first layout as `--pp-tool-call-line': the
        ;; spinner sits in the shared col-0 gutter (or two blank
        ;; columns when terminal), then a 2-column tool-call indent,
        ;; then the `Explored …' summary at column 4.  Body stays at
        ;; col 4 regardless of state — no jitter when the last child
        ;; finishes.
        (if status-g
            (insert status-g " ")
          (insert "  "))
        (insert "  ")
        (insert summary "\n")
        (add-text-properties line-beg (point)
                             '(wrap-prefix "    ")))
      (unless collapsed
        (dolist (tc children)
          ;; Children render as their own full cards.  Each carries its
          ;; status glyph + (when expanded) raw output / diffs.  Per-
          ;; child collapse state lives on the synthetic node and
          ;; resets to `--should-auto-collapse-p' so terminal children
          ;; render as one-line summaries and in-flight ones show the
          ;; spinner.
          (mutecipher-acp--pp-tool-call
           (make-macp-node :kind 'tool-call
                           :data tc
                           :collapsed
                           (mutecipher-acp--should-auto-collapse-p tc))))
        ;; Trailing blank so the next non-tool node has consistent
        ;; spacing — same as `--pp-tool-call' expanded.
        (insert "\n"))))))

(mutecipher-acp-register-node-kind 'tool-group #'mutecipher-acp--pp-tool-group)

(provide 'mutecipher-acp-tool-card)
;;; mutecipher-acp-tool-card.el ends here
