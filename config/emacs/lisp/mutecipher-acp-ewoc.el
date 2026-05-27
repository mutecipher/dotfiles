;;; mutecipher-acp-ewoc.el --- EWOC helpers for ACP rendering  -*- lexical-binding: t -*-
;;
;; Sticky-tail / sticky-window-start macros and the pulse-flash helper.
;; The session/update handlers and per-kind pretty-printers in other
;; modules use these to keep the user's reading position pinned across
;; ewoc growth and mutations.
;;
;; This module is intentionally small at this stage — step 8 of the
;; refactor adds the master `--pp' dispatcher and the non-tool-call
;; per-kind printers here.

;;; Code:

(require 'cl-lib)
(require 'ewoc)
(require 'pulse)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-log)

;; `--close-trailing-tool-group' lives in tools.el (which requires
;; this module) — forward-declare so the assistant/notice/thought/plan
;; enter helpers below byte-compile cleanly.  Runtime ordering is fine
;; because the agent never sends an assistant chunk before tools.el
;; has loaded alongside the rest of mutecipher-acp.
(declare-function mutecipher-acp--close-trailing-tool-group "mutecipher-acp-tools")

;; `mutecipher-acp--composer-start' lives in composer.el (loaded after
;; this module) — forward-declare so `--pulse-node' can clamp its end
;; position to the composer seam without dragging the require backwards.
(defvar mutecipher-acp--composer-start)

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

(defun mutecipher-acp--pulse-node (ewoc node)
  "Pulse-highlight the buffer region spanned by NODE in EWOC.
Skips any leading newline characters in the region so the flash
matches the visible body of the node — `--ensure-blank-above'
includes its inserted `\\n' inside the node's read-only region, and
without this skip the pulse would extend one row above the visible
content into the inter-node gap."
  (when (and ewoc node (fboundp 'pulse-momentary-highlight-region))
    (let* ((raw-beg  (ewoc-location node))
           (next     (ewoc-next ewoc node))
           (tail-cap (or (and (markerp mutecipher-acp--composer-start)
                              (marker-position mutecipher-acp--composer-start))
                         (point-max)))
           (end      (if next (ewoc-location next) tail-cap))
           (beg      (and raw-beg
                          (save-excursion
                            (goto-char raw-beg)
                            (skip-chars-forward "\n" end)
                            (point)))))
      (when (and beg (> end beg))
        (pulse-momentary-highlight-region
         beg end 'mutecipher-acp-pulse-face)))))

(defun mutecipher-acp--ewoc-enter-tail (ewoc anchor data)
  "Enter DATA at the tail of EWOC.
When ANCHOR is non-nil, insert just before it via `ewoc-enter-before' so
new transcript content lands above the pending-queue suffix.  Otherwise
falls through to `ewoc-enter-last'.  Callers pass the session's
`queue-head-node' as ANCHOR — nil whenever the queue is empty.

Also populates DATA's `:uuid' slot (unless already set — persistence
replay reuses the stored id) and registers `(uuid . node)' in the
current session's `node-index' for O(1) addressing."
  (let ((node (if anchor
                  (ewoc-enter-before ewoc anchor data)
                (ewoc-enter-last ewoc data))))
    ;; Stamp uuid AFTER the ewoc-enter succeeds — if the enter signals,
    ;; the caller's struct stays untouched and a retry generates a fresh id.
    (unless (macp-node-uuid data)
      (setf (macp-node-uuid data) (mutecipher-acp--new-node-uuid)))
    (when-let* ((session (gethash mutecipher-acp--session-id
                                  mutecipher-acp--sessions))
                (index   (macp-session-node-index session)))
      (puthash (macp-node-uuid data) node index))
    node))

;;;; Assistant-text streaming + node entry helpers

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
          (mutecipher-acp--close-trailing-tool-group session-id)
          (setq node (mutecipher-acp--ewoc-enter-tail
                      ewoc
                      (macp-session-queue-head-node session)
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

(defun mutecipher-acp--enter-notice (session-id text &optional face)
  "Enter a notice node in SESSION-ID's ewoc with TEXT and optional FACE."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--close-trailing-tool-group session-id)
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (mutecipher-acp--ewoc-enter-tail
         mutecipher-acp--ewoc
         (macp-session-queue-head-node session)
         (make-macp-node :kind 'notice
                         :data (make-macp-notice :text text :face face)))))))

(defun mutecipher-acp--enter-thought (session-id text)
  "Enter a thought node in SESSION-ID's ewoc carrying TEXT."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--close-trailing-tool-group session-id)
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (mutecipher-acp--ewoc-enter-tail
         mutecipher-acp--ewoc
         (macp-session-queue-head-node session)
         (make-macp-node :kind 'thought
                         :data (make-macp-thought :text text)))))))

(defun mutecipher-acp--enter-plan (session-id tasks)
  "Enter (or mutate) SESSION-ID's plan node with TASKS.
If the turn already has a plan node, its entries are replaced and the
node is invalidated.  Otherwise a fresh plan node is entered.  Both
paths close any open trailing tool-group — a plan-update is a phase
transition that should not let subsequent reads silently fold into
the previous group above the plan node."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--close-trailing-tool-group session-id)
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
          (let ((node (mutecipher-acp--ewoc-enter-tail
                       mutecipher-acp--ewoc
                       (macp-session-queue-head-node session)
                       (make-macp-node :kind 'plan
                                       :data (make-macp-plan :entries tasks)))))
            (setf (macp-session-current-plan-node session) node))))))))

;;;; Pretty-printer dispatch
;;
;; Each kind-specific pretty-printer is self-contained and idempotent:
;; it `insert's the node's rendering at point and ends with exactly one
;; newline.  Ewoc manages the region; we only produce text.
;;
;; `--pp' dispatches via `--pp-node-kinds' — an alist (KIND . PP-FN).
;; Built-ins register themselves at the bottom of this file; tool-call
;; lives in mutecipher-acp-tools.el and registers there.  New node
;; kinds use `mutecipher-acp-register-node-kind' to plug in without
;; touching the dispatcher.

(declare-function mutecipher-acp--apply-markdown "mutecipher-acp-markdown")
(declare-function mutecipher-acp--icon-or        "mutecipher-acp-tool-card")
(declare-function mutecipher/icon-for-acp        "mutecipher-icons")

(defvar mutecipher-acp--pp-node-kinds nil
  "Alist (KIND . PP-FN) used by `mutecipher-acp--pp' to dispatch on node kind.
PP-FN is called with the `macp-node' and is expected to `insert' the
node's rendering at point.")

(defun mutecipher-acp-register-node-kind (kind pp-fn)
  "Register PP-FN as the pretty-printer for KIND (a symbol)."
  (setf (alist-get kind mutecipher-acp--pp-node-kinds nil nil #'eq) pp-fn))

(defun mutecipher-acp--ensure-blank-above ()
  "Insert one `\\n' iff the line above point isn't already blank.
Used by the master `--pp' dispatcher to guarantee a single empty line
of padding before non-tool message bodies.  Idempotent — calling it
twice in a row inserts at most one `\\n'.  No-op at buffer-start so
the first rendered node doesn't get an empty leading line.

The blank-line predicate uses `[^[:graph:]\\n]' — the negation of the
`graph' POSIX class — which matches any non-printable character.
That catches ordinary whitespace AND the no-break space U+00A0
occasionally present in assistant content pasted from web/Markdown
sources; `[:space:]' alone would miss the NBSP and we would insert a
redundant `\\n' on top of an already-visually-blank line."
  (unless (or (bobp)
              (save-excursion
                (forward-line -1)
                (looking-at-p "^[^[:graph:]\n]*$")))
    (insert "\n")))

(defun mutecipher-acp--pp (node)
  "Master ewoc pretty-printer: dispatch on NODE kind via the registry.
Wraps the per-kind printer so every rendered region is marked
read-only via text properties.  `rear-nonsticky' on the trailing edge
keeps the inline composer (text past the ewoc footer) writable —
characters typed by the user just past the last node do not inherit
the transcript's read-only property.

Before dispatching, inserts a blank-line separator above any
non-tool kind via `--ensure-blank-above'.  Tool-call AND tool-group
nodes skip that step so adjacent tool / group cards stack tight;
everything else (user / assistant / thought / notice / plan /
trailer / turn-header) gets one blank line of padding from whatever
sits above."
  ;; `beg' is captured BEFORE `--ensure-blank-above' inserts so the
  ;; inserted `\\n' is included in the node's read-only region — the
  ;; user can't sneak edits into the gap between cards.  Ewoc's
  ;; start-marker for this node stays at the same buffer position
  ;; across the insert (marker insertion-type nil), and on
  ;; invalidate the leading `\\n' is deleted along with the rest of
  ;; the node's region, then re-inserted by the next render.
  (let ((beg  (point))
        (kind (macp-node-kind node)))
    (unless (memq kind '(tool-call tool-group))
      (mutecipher-acp--ensure-blank-above))
    (let ((fn (alist-get kind mutecipher-acp--pp-node-kinds nil nil #'eq)))
      (if fn
          (funcall fn node)
        ;; Surface the registration miss in *ACP-log* so a missing
        ;; `mutecipher-acp-register-node-kind' call doesn't only manifest
        ;; as silent uneditable text inside the transcript.
        (mutecipher-acp--log-warn
         'agent-warn nil
         (format "[--pp] unknown node kind: %s — register via mutecipher-acp-register-node-kind"
                 kind))
        (insert (format "[acp: unknown node kind: %s]\n" kind))))
    (add-text-properties beg (point)
                         '(read-only t
                           front-sticky (read-only)
                           rear-nonsticky (read-only)))))

(defun mutecipher-acp--gutter (icon-kind)
  "Return (PREFIX . INDENT) for a hanging-indent layout keyed by ICON-KIND.
PREFIX is the 2-char gutter (`<glyph> ' or two spaces) that sits at
the left edge of each row; INDENT matches its width so logical
newlines and wrapped continuations align under the body at column 2.
Chat-message roles consult `mutecipher-acp-role-glyph-alist' first;
other kinds fall back to `mutecipher/icon-for-acp' (Nerd Font), then
to a single space.

The gutter is always 2 chars wide — when a role's glyph is the empty
string (e.g. thought / notice / queued with no visible marker), the
prefix becomes `  ' so the body still starts at column 2 and aligns
with `▌'-prefixed user/assistant rows.  Consistent left edge, with
the role glyph as an optional signifier."
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
         (prefix (if (string-empty-p icon) "  " (concat icon " ")))
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

(defun mutecipher-acp--change-set-relativize (path)
  "Relativize PATH against the current session's cwd, falling back to basename.
`file-truename's the cwd before comparison so symlinked roots — macOS
`/tmp' → `/private/tmp', `$TMPDIR' firmlinks, symlinked project roots —
don't force absolute-path display.  Falls back to the basename when
PATH lies outside cwd or no session is current."
  (or (when-let* ((sid     mutecipher-acp--session-id)
                  (session (gethash sid mutecipher-acp--sessions))
                  (cwd     (macp-session-cwd session))
                  (cwd-tn  (condition-case _err
                               (file-truename cwd)
                             (error cwd))))
        (and (file-in-directory-p path cwd-tn)
             (file-relative-name path cwd-tn)))
      (file-name-nondirectory path)))

(defun mutecipher-acp--change-set-file-glyph (fc)
  "Return a status glyph for file-change FC.
`⚠' marks files whose pre-edit snapshot wasn't captured (and which therefore
can't be reverted); `✓' marks captured + still-applied edits; `↶' marks
captured edits the user has already reverted; `?' marks an unknown future
status so a missing migration is visible rather than silently rendered as
accepted."
  (let ((capture (macp-file-change-capture-status fc))
        (status  (macp-file-change-status fc)))
    (cond
     ((not (eq capture 'ok)) "⚠")
     ((eq status 'reverted)  "↶")
     ((eq status 'accepted)  "✓")
     (t                      "?"))))

(defun mutecipher-acp--change-set-file-note (fc)
  "Return a trailing parenthetical for file-change FC, or empty string."
  (pcase (macp-file-change-capture-status fc)
    ('suppressed-too-large "  (too large to capture)")
    ('reverse-apply-failed "  (capture failed)")
    (_ (if (eq (macp-file-change-status fc) 'reverted) "  (reverted)" ""))))

(defun mutecipher-acp--change-set-revertable-count (cs)
  "Return the count of file-changes in CS that `mutecipher/acp-revert-turn'
would actually act on (capture-status `ok' AND status `accepted')."
  (cl-loop for (_path . fc) in (macp-change-set-files cs)
           when (and (eq (macp-file-change-capture-status fc) 'ok)
                     (eq (macp-file-change-status fc) 'accepted))
           count fc))

(defun mutecipher-acp--pp-change-set-badge (cs)
  "Insert the per-turn change-set badge for CS at point.
No-op when CS holds no file-changes.  Non-revertible entries
(`suppressed-too-large', `reverse-apply-failed') still render with a `⚠'
glyph so the user can see the turn touched a file even when capture
declined.  Drops the `revert:' suffix once no file is left to revert."
  (when-let* ((files (cl-loop for (_p . fc) in (macp-change-set-files cs)
                              collect fc))
              (n      (length files))
              (header (if (zerop (mutecipher-acp--change-set-revertable-count cs))
                          (format "✎ %d file%s changed\n"
                                  n (if (= n 1) "" "s"))
                        (format "✎ %d file%s changed · revert: M-x mutecipher/acp-revert-turn\n"
                                n (if (= n 1) "" "s")))))
    (insert (propertize header 'face 'mutecipher-acp-change-set-face))
    (dolist (fc files)
      (let ((line (format "  %s %s%s\n"
                          (mutecipher-acp--change-set-file-glyph fc)
                          (mutecipher-acp--change-set-relativize
                           (macp-file-change-path fc))
                          (mutecipher-acp--change-set-file-note fc))))
        (insert (propertize line 'face 'mutecipher-acp-change-set-face))))
    (insert "\n")))

(defun mutecipher-acp--pp-turn-header (node)
  "Render a turn-header NODE.
If the turn has a non-empty `change-set' (any `macp-file-change' with
`capture-status' `ok'), render a badge listing the modified files and
their status.  Inter-turn blank-line padding is supplied by the master
`--pp' dispatcher's `--ensure-blank-above'; this printer no longer
emits its own leading `\\n' (which used to double up post-density
refactor)."
  (let* ((turn (macp-node-data node))
         (cs   (macp-turn-change-set turn)))
    (when cs
      (mutecipher-acp--pp-change-set-badge cs))))

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

(defun mutecipher-acp--pp-notice (node)
  "Render a notice NODE: `notice' icon gutter + one propertized line."
  (let* ((data (macp-node-data node))
         (text (or (macp-notice-text data) ""))
         (face (or (macp-notice-face data) 'default)))
    (mutecipher-acp--insert-with-gutter 'notice (concat text "\n") face)))

(defun mutecipher-acp--pp-queued (node)
  "Render a queued NODE: dim italic line representing a pending prompt.
Uses the `queued' icon-kind gutter (falls back to `…') so the queue
visually echoes the composer prompt above without being mistaken for
sent user content."
  (let ((text (or (macp-queued-text (macp-node-data node)) "")))
    (mutecipher-acp--insert-with-gutter
     'queued (concat text "\n") 'mutecipher-acp-queued-face)))

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
at a glance.  Leading blank-line padding comes from the master `--pp'
dispatcher's `--ensure-blank-above'; this printer no longer emits its
own `\\n' (which used to double up post-density refactor)."
  (let* ((plan    (macp-node-data node))
         (entries (macp-plan-entries plan)))
    (insert (propertize "[Plan]\n" 'face 'bold))
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

;; Register built-in node kinds.  `tool-call' lives in mutecipher-acp-tools.el
;; and registers itself there.
(mutecipher-acp-register-node-kind 'turn-header #'mutecipher-acp--pp-turn-header)
(mutecipher-acp-register-node-kind 'user        #'mutecipher-acp--pp-user)
(mutecipher-acp-register-node-kind 'assistant   #'mutecipher-acp--pp-assistant)
(mutecipher-acp-register-node-kind 'thought     #'mutecipher-acp--pp-thought)
(mutecipher-acp-register-node-kind 'notice      #'mutecipher-acp--pp-notice)
(mutecipher-acp-register-node-kind 'trailer     #'mutecipher-acp--pp-trailer)
(mutecipher-acp-register-node-kind 'plan        #'mutecipher-acp--pp-plan)
(mutecipher-acp-register-node-kind 'queued      #'mutecipher-acp--pp-queued)

(provide 'mutecipher-acp-ewoc)
;;; mutecipher-acp-ewoc.el ends here
