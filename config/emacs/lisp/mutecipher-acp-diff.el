;;; mutecipher-acp-diff.el --- Unified diff generation and rendering for ACP  -*- lexical-binding: t -*-
;;
;; Owns everything diff-shaped in the ACP transcript:
;;   - generating a unified diff between two strings via Emacs' built-in
;;     `diff' and stripping its headers
;;   - fontifying that diff with `diff-mode' + per-hunk refinement and
;;     flattening overlays to text properties
;;   - rendering each hunk line into a GitHub-styled banded row with a
;;     line-number gutter, anchored at the file line when known
;;   - finding the file-line where a diff's new-text first appears, with
;;     a memoization key tied to the tool-call's diff-count + locations

;;; Code:

(require 'cl-lib)
(require 'diff)
(require 'diff-mode)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)

(defcustom mutecipher-acp-diff-max-lines 500
  "Maximum old/new line count before inline tool-call diffs are summarized.
When either side of a diff exceeds this, the diff body is skipped and a
single summary line is shown instead."
  :type 'integer
  :group 'mutecipher-acp)

;;;; Diff generation

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

;;;; Per-line rendering

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

;;;; File-line anchoring

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

(provide 'mutecipher-acp-diff)
;;; mutecipher-acp-diff.el ends here
