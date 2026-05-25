;;; mutecipher-acp-markdown.el --- Minimal markdown rendering for ACP  -*- lexical-binding: t -*-
;;
;; Applied imperatively from the pretty-printers via text properties —
;; NOT via font-lock.  Going through font-lock clobbered the `face'
;; properties our pretty-printers set on icons/glyphs/gutters, because
;; refontification treats the buffer as a "dumb" fontifiable region.
;; This approach applies overlays once per `ewoc-invalidate' (the pp
;; re-runs, re-applies), and leaves everything else alone.
;;
;; Passes are listed in `mutecipher-acp--md-passes' and applied in
;; order.  Use `mutecipher-acp-register-md-pass' to install a new pass.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'mutecipher-acp-faces)

(declare-function mutecipher-acp--fontify-diff-string "mutecipher-acp-tools")
(declare-function mutecipher-acp--transfer-faces      "mutecipher-acp-tools")

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
  "Non-nil if the char at POS is inside a code span.
Set by the fenced-code and inline-code passes via the dedicated
`mutecipher-acp-md-code' text property — independent of which face
the colorizer happens to apply.  Used to gate non-code matchers so
`*asterisks*' etc. *inside* a code span don't get italicized/bolded.
Bold/italic spans that *wrap around* a code span still apply —
checking only the starting position lets the faces compose via
`add-face-text-property'."
  (get-text-property pos 'mutecipher-acp-md-code))

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

(defun mutecipher-acp--md-pass-fenced-code (_beg end line-starts)
  "Render fenced code blocks ``` … ``` ending at END.
A ```diff tag routes the body through `diff-mode' fontification."
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
              (put-text-property open-body-beg fence-beg
                                 'mutecipher-acp-md-code t)
              (mutecipher-acp--md-hide fence-beg (min end (1+ fence-eol)))
              (setq open-beg nil open-body-beg nil open-lang nil)))))))
    ;; Unclosed fence (still streaming) — face what we have so far.
    (when open-beg
      (mutecipher-acp--md-hide open-beg open-body-beg)
      (add-face-text-property open-body-beg end 'font-lock-constant-face)
      (put-text-property open-body-beg end 'mutecipher-acp-md-code t))))

(defun mutecipher-acp--md-pass-inline-code (beg end _line-starts)
  "Render inline `code` between BEG and END."
  (goto-char beg)
  (while (re-search-forward "`\\([^`\n]+\\)`" end t)
    (let ((mb (match-beginning 0)) (me (match-end 0))
          (ib (match-beginning 1)) (ie (match-end 1)))
      (unless (mutecipher-acp--md-inside-code-p mb)
        (mutecipher-acp--md-hide mb (1+ mb))
        (add-face-text-property ib ie 'font-lock-constant-face)
        (put-text-property ib ie 'mutecipher-acp-md-code t)
        (mutecipher-acp--md-hide (1- me) me)))))

(defun mutecipher-acp--md-pass-headings (_beg _end line-starts)
  "Render ATX headings (# / ## / ###) at every line start in LINE-STARTS."
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
                                    `(:weight bold :height ,height))))))))

(defun mutecipher-acp--md-pass-blockquotes (_beg _end line-starts)
  "Render `> …' blockquotes by replacing the marker with a thin bar."
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
                                    '(:slant italic :inherit shadow))))))))

(defconst mutecipher-acp--md-table-line-re "^[ \t]*|.*|[ \t]*$"
  "Regexp matching a single pipe-delimited line of a GFM table.")

(defun mutecipher-acp--md-table-parse-cells (line)
  "Return trimmed cells from pipe-delimited LINE, or nil if not table-shaped."
  (when (string-match "^[ \t]*|\\(.*\\)|[ \t]*$" line)
    (mapcar #'string-trim (split-string (match-string 1 line) "|"))))

(defun mutecipher-acp--md-table-sep-cells-p (cells)
  "Non-nil if CELLS is a GFM separator row (each cell `:?-+:?')."
  (and cells
       (seq-every-p (lambda (c) (string-match-p "^:?-+:?$" c)) cells)))

(defun mutecipher-acp--md-table-col-widths (all-cells)
  "Vector of max column widths across ALL-CELLS, ignoring separator rows."
  (let* ((data-cells (seq-remove #'mutecipher-acp--md-table-sep-cells-p
                                 (delq nil all-cells)))
         (ncols      (apply #'max 1 (mapcar #'length data-cells)))
         (widths     (make-vector ncols 0)))
    (dolist (cells data-cells)
      (seq-do-indexed (lambda (cell i)
                        (when (< i ncols)
                          (aset widths i (max (aref widths i) (length cell)))))
                      cells))
    widths))

(defun mutecipher-acp--md-table-box-line (widths left junc right fill)
  "Build a horizontal border string from WIDTHS using LEFT/JUNC/RIGHT/FILL."
  (let ((segs (mapcar (lambda (w) (make-string (+ w 2) fill))
                      (append widths nil))))
    (propertize (concat left (mapconcat #'identity segs junc) right)
                'face 'mutecipher-acp-md-table-rule-face)))

(defun mutecipher-acp--md-table-format-row (cells widths &optional align)
  "Build a propertized data row string. ALIGN is `center' or nil (left)."
  (let ((pipe (propertize "│" 'face 'mutecipher-acp-md-table-rule-face))
        parts)
    (dotimes (i (length cells))
      (let* ((cell  (or (nth i cells) ""))
             (w     (if (< i (length widths)) (aref widths i) (length cell)))
             (slack (max 0 (- w (length cell))))
             (lpad  (if (eq align 'center) (/ slack 2) 0))
             (rpad  (- slack lpad)))
        (push pipe parts)
        (push (concat " "
                      (make-string lpad ?\s)
                      cell
                      (make-string rpad ?\s)
                      " ")
              parts)))
    (push pipe parts)
    (apply #'concat (nreverse parts))))

(defun mutecipher-acp--md-table-render-at (start)
  "Render the GFM table beginning at line containing START.
Requires a header + separator pair; otherwise returns START unchanged.
On success, returns the buffer position just after the last consumed line."
  (save-excursion
    (goto-char start)
    (let (line-starts raw-cells)
      (while (and (not (eobp))
                  (looking-at mutecipher-acp--md-table-line-re))
        (push (point) line-starts)
        (push (mutecipher-acp--md-table-parse-cells
               (buffer-substring-no-properties (point) (line-end-position)))
              raw-cells)
        (forward-line 1))
      (let* ((starts    (vconcat (nreverse line-starts)))
             (cell-rows (nreverse raw-cells))
             (seps      (vconcat (mapcar #'mutecipher-acp--md-table-sep-cells-p
                                         cell-rows)))
             (cells-vec (vconcat cell-rows))
             (n         (length starts)))
        (if (not (and (>= n 2) (aref seps 1)))
            start
          (let* ((widths   (mutecipher-acp--md-table-col-widths cell-rows))
                 (top      (mutecipher-acp--md-table-box-line widths "┌" "┬" "┐" ?─))
                 (row-sep  (mutecipher-acp--md-table-box-line widths "├" "┼" "┤" ?─))
                 (bottom   (mutecipher-acp--md-table-box-line widths "└" "┴" "┘" ?─)))
            (dotimes (i n)
              (let* ((ls         (aref starts i))
                     (cells      (aref cells-vec i))
                     (sep-p      (aref seps i))
                     (last-p     (= i (1- n)))
                     (next-sep-p (and (not last-p) (aref seps (1+ i))))
                     (inject-p   (and (not last-p) (not sep-p) (not next-sep-p)))
                     (extend-p   (or last-p inject-p))
                     (le         (save-excursion
                                   (goto-char ls)
                                   (if extend-p
                                       (min (1+ (line-end-position)) (point-max))
                                     (line-end-position))))
                     (align      (when (= i 0) 'center))
                     (base       (if sep-p
                                     row-sep
                                   (mutecipher-acp--md-table-format-row
                                    cells widths align)))
                     (disp       (if extend-p (concat base "\n") base))
                     (ov         (make-overlay ls le nil t nil)))
                (overlay-put ov 'display disp)
                (when (= i 0)
                  (overlay-put ov 'before-string (concat top "\n")))
                (cond
                 (last-p
                  (overlay-put ov 'after-string (concat bottom "\n")))
                 (inject-p
                  (overlay-put ov 'after-string (concat row-sep "\n"))))
                (overlay-put ov 'mutecipher-acp-md-table t)))
            (point)))))))

(defun mutecipher-acp--md-table-clear-overlays (beg end)
  "Delete any rendered-table overlays inside BEG..END."
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov 'mutecipher-acp-md-table)
      (delete-overlay ov))))

(defun mutecipher-acp--md-pass-tables (_beg _end line-starts)
  "Render GFM tables as an aligned Unicode grid via overlays.
Walks LINE-STARTS, rendering at each table head and skipping subsequent
starts that fall inside an already-rendered table region."
  (let ((skip-until 0))
    (dolist (start line-starts)
      (when (> start skip-until)
        (save-excursion
          (goto-char start)
          (when (and (looking-at mutecipher-acp--md-table-line-re)
                     (not (mutecipher-acp--md-inside-code-p start)))
            (let ((after (mutecipher-acp--md-table-render-at start)))
              (when (> after start)
                (setq skip-until after)))))))))

(defun mutecipher-acp--md-pass-checkboxes (_beg _end line-starts)
  "Render `- [x]' / `- [ ]' as ☑ / ☐ at every applicable line start."
  (dolist (start line-starts)
    (save-excursion
      (goto-char start)
      (when (looking-at "\\([ \t]*\\)- \\(\\[[ xX]\\]\\) \\(.*\\)$")
        (let* ((box-beg (match-beginning 0))
               (box-end (match-end 2))
               (text-beg (1+ box-end))
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
                                      '(:strike-through t :inherit shadow)))))))))

(defun mutecipher-acp--md-pass-bold (beg end _line-starts)
  "Render `**bold**' between BEG and END."
  (goto-char beg)
  (while (re-search-forward "\\*\\*\\([^*\n]+\\)\\*\\*" end t)
    (let ((mb (match-beginning 0)) (me (match-end 0)))
      (if (or (eq (char-before mb) ?*)
              (eq (char-after  me) ?*)
              (mutecipher-acp--md-inside-code-p mb))
          (goto-char (1+ mb))
        (mutecipher-acp--md-hide mb (+ mb 2))
        (add-face-text-property (+ mb 2) (- me 2) 'bold)
        (mutecipher-acp--md-hide (- me 2) me)))))

(defun mutecipher-acp--md-pass-italic (beg end _line-starts)
  "Render `*italic*' between BEG and END.  Skips already-hidden bold markers."
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
        (mutecipher-acp--md-hide (1- me) me)))))

(defun mutecipher-acp--md-word-char-p (ch)
  "Non-nil when CH would extend an identifier (alnum or `_').
Used to enforce CommonMark's intraword-underscore rule so `_' inside
`snake_case' tokens doesn't open or close an italic span."
  (and ch (or (and (>= ch ?0) (<= ch ?9))
              (and (>= ch ?a) (<= ch ?z))
              (and (>= ch ?A) (<= ch ?Z))
              (eq ch ?_))))

(defun mutecipher-acp--md-pass-italic-underscore (beg end _line-starts)
  "Render `_italic_' between BEG and END.
Intraword `_' (e.g. `snake_case', `tool_name') is left alone — only
runs whose outer neighbours are not alnum/`_' qualify."
  (goto-char beg)
  (while (re-search-forward "_\\([^_\n]+\\)_" end t)
    (let* ((mb     (match-beginning 0))
           (me     (match-end 0))
           (before (and (> mb (point-min)) (char-before mb)))
           (after  (and (< me (point-max)) (char-after me))))
      (if (or (mutecipher-acp--md-word-char-p before)
              (mutecipher-acp--md-word-char-p after)
              (get-text-property mb 'invisible)
              (mutecipher-acp--md-inside-code-p mb))
          (goto-char (1+ mb))
        (mutecipher-acp--md-hide mb (1+ mb))
        (add-face-text-property (1+ mb) (1- me) 'italic)
        (mutecipher-acp--md-hide (1- me) me)))))

(defun mutecipher-acp--md-pass-strike (beg end _line-starts)
  "Render `~~strike~~' between BEG and END."
  (goto-char beg)
  (while (re-search-forward "~~\\([^~\n]+\\)~~" end t)
    (let ((mb (match-beginning 0)) (me (match-end 0)))
      (unless (mutecipher-acp--md-inside-code-p mb)
        (mutecipher-acp--md-hide mb (+ mb 2))
        (add-face-text-property (+ mb 2) (- me 2) '(:strike-through t))
        (mutecipher-acp--md-hide (- me 2) me)))))

(defun mutecipher-acp--md-pass-links (beg end _line-starts)
  "Render `[text](url)' inline links between BEG and END."
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
        (mutecipher-acp--md-hide text-end me)))))

(defvar mutecipher-acp--md-passes
  '(mutecipher-acp--md-pass-fenced-code
    mutecipher-acp--md-pass-inline-code
    mutecipher-acp--md-pass-headings
    mutecipher-acp--md-pass-blockquotes
    mutecipher-acp--md-pass-tables
    mutecipher-acp--md-pass-checkboxes
    mutecipher-acp--md-pass-bold
    mutecipher-acp--md-pass-italic
    mutecipher-acp--md-pass-italic-underscore
    mutecipher-acp--md-pass-strike
    mutecipher-acp--md-pass-links)
  "Ordered list of markdown rendering passes.
Each is called as (FN BEG END LINE-STARTS).  Order matters: code passes
run first so their content is opaque to later matchers; block-level
runs before inline so contents compose.")

(defun mutecipher-acp-register-md-pass (fn &optional after)
  "Add FN to `mutecipher-acp--md-passes'.
With no AFTER, append.  With AFTER, insert FN immediately after the
pass named AFTER (a symbol)."
  (if (null after)
      (setq mutecipher-acp--md-passes
            (append mutecipher-acp--md-passes (list fn)))
    (let* ((tail (memq after mutecipher-acp--md-passes)))
      (if tail
          (setcdr tail (cons fn (cdr tail)))
        (setq mutecipher-acp--md-passes
              (append mutecipher-acp--md-passes (list fn)))))))

(defun mutecipher-acp--apply-markdown (beg end)
  "Apply minimal markdown rendering to region BEG..END.
Idempotent — safe to call repeatedly after `ewoc-invalidate'.
See `mutecipher-acp--md-passes' for the ordered set of rules.
Stale table overlays inside the region are cleared first so that
streaming re-renders don't accumulate them."
  (mutecipher-acp--md-table-clear-overlays beg end)
  (save-excursion
    (let ((line-starts (mutecipher-acp--md-line-starts beg end)))
      (dolist (pass mutecipher-acp--md-passes)
        (funcall pass beg end line-starts)))))

(provide 'mutecipher-acp-markdown)
;;; mutecipher-acp-markdown.el ends here
