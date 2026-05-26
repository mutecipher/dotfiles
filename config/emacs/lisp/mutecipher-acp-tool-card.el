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

(defun mutecipher-acp--pp-tool-call-line (tc collapsed)
  "Insert the one-line summary for tool-call TC, no leading indent.
LHS — disclosure + status glyph + kind glyph + name(input) — is
left-aligned next to the card's rail.  The kind glyph (pencil for
edit, terminal for execute, cloud for fetch, …) makes the tool's
intent scannable at a glance, independent of the streaming status
glyph next to it.  Meta (line/diff counts) is right-aligned to the
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
         (kind-key   (mutecipher-acp--tool-kind-icon-key
                      (macp-tool-call-kind tc) name))
         ;; nil fallback so kind glyph is silently dropped if no Nerd
         ;; Font is installed — the status glyph already conveys liveness.
         (kind-g     (mutecipher-acp--icon-or kind-key nil))
         (meta       (mutecipher-acp--tool-meta tc)))
    (insert (propertize disclosure 'face 'mutecipher-acp-disclosure-face)
            " "
            status-g
            " ")
    (when kind-g
      (insert kind-g " "))
    (insert (propertize (concat name (if input (concat "(" input ")") ""))
                        'face 'mutecipher-acp-tool-face))
    (when meta
      (let* ((meta-str (propertize meta 'face 'shadow))
             (meta-w   (string-width meta-str)))
        (insert (propertize " "
                            'display `(space :align-to (- right ,meta-w)))
                meta-str)))
    (insert "\n")))

(defun mutecipher-acp--pp-tool-call-body (tc)
  "Insert the expanded body for TC, dispatching to a registered renderer if any.
Looks up `mutecipher-acp-tool-body-renderers' via
`--lookup-tool-body-renderer' (name first, then kind); falls back to
`mutecipher-acp--pp-default-tool-body' when neither key matches."
  (if-let ((fn (mutecipher-acp--lookup-tool-body-renderer tc)))
      (funcall fn tc)
    (mutecipher-acp--pp-default-tool-body tc)))

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

(mutecipher-acp-register-node-kind 'tool-call #'mutecipher-acp--pp-tool-call)

(provide 'mutecipher-acp-tool-card)
;;; mutecipher-acp-tool-card.el ends here
