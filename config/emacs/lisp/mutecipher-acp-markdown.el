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
The fenced-code and inline-code passes set the dedicated
`mutecipher-acp-md-code' text property; that property is the source
of truth.  As a defence-in-depth fallback we also accept
`font-lock-constant-face' on POS — that covers any caller that styled
code via face but forgot the dedicated property (e.g. a future
markdown-extension pass or a tool-call body containing inline code).
Bold/italic spans that *wrap around* a code span still apply —
checking only the starting position lets the faces compose via
`add-face-text-property'."
  (or (get-text-property pos 'mutecipher-acp-md-code)
      (let ((f (get-text-property pos 'face)))
        (or (eq f 'font-lock-constant-face)
            (and (listp f) (memq 'font-lock-constant-face f))))))

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

(defcustom mutecipher-acp-md-table-max-width nil
  "Optional hard cap on rendered GFM table width, in columns.
When nil, tables fit the body width of the window showing them.  When an
integer, the table never grows past that many columns even in a wide
window."
  :type '(choice (const :tag "Fit window" nil) integer)
  :group 'mutecipher-acp)

(defconst mutecipher-acp--md-table-min-col-width 5
  "Preferred minimum content width for a column when shrinking to fit.
Dropped automatically toward a fair per-column share when even this
won't fit the available width.")

(defvar mutecipher-acp--md-table-width-override nil
  "When non-nil, the text width (columns) to lay tables out against.
Bound by the resize handler so re-fitting uses the new width without
re-querying the window.")

(defvar-local mutecipher-acp--md-has-tables nil
  "Non-nil once this buffer has rendered at least one GFM table.
Gates the global resize handler so it skips table-free buffers.")

(defvar-local mutecipher-acp--md-last-window-width nil
  "Window body width (columns) used at the last table re-fit.")

(defun mutecipher-acp--md-table-parse-cells (line)
  "Return trimmed cells from pipe-delimited LINE, or nil if not table-shaped."
  (when (string-match "^[ \t]*|\\(.*\\)|[ \t]*$" line)
    (mapcar #'string-trim (split-string (match-string 1 line) "|"))))

(defun mutecipher-acp--md-table-sep-cells-p (cells)
  "Non-nil if CELLS is a GFM separator row (each cell `:?-+:?')."
  (and cells
       (seq-every-p (lambda (c) (string-match-p "^:?-+:?$" c)) cells)))

(defun mutecipher-acp--md-table-col-widths (all-cells)
  "Vector of max column widths across ALL-CELLS, ignoring separator rows.
Widths are measured in display columns (`string-width'), so double-width
glyphs are budgeted correctly; `length' here counts cells-per-row to size
the vector, not characters."
  (let* ((data-cells (seq-remove #'mutecipher-acp--md-table-sep-cells-p
                                 (delq nil all-cells)))
         (ncols      (apply #'max 1 (mapcar #'length data-cells)))
         (widths     (make-vector ncols 0)))
    (dolist (cells data-cells)
      (seq-do-indexed (lambda (cell i)
                        (when (< i ncols)
                          (aset widths i (max (aref widths i) (string-width cell)))))
                      cells))
    widths))

(defun mutecipher-acp--md-table-text-width (start)
  "Columns available to lay out a table whose head sits at START.
Honours `mutecipher-acp--md-table-width-override' when bound; otherwise
queries the window showing the buffer (falling back to `fill-column' or
80 when undisplayed).  Subtracts the body's hanging indent — read from
the `wrap-prefix' at START — plus a one-column right margin so a fitted
table never abuts the window edge and triggers a continuation glyph."
  (let* ((cap    mutecipher-acp-md-table-max-width)
         (full   (or mutecipher-acp--md-table-width-override
                     (let ((win (get-buffer-window (current-buffer) 'visible)))
                       (cond
                        (win (window-body-width win))
                        ((and (integerp fill-column) (> fill-column 0)) fill-column)
                        (t 80)))))
         (full   (if (integerp cap) (min full cap) full))
         (pfx    (get-text-property start 'wrap-prefix))
         (indent (cond ((stringp pfx)  (string-width pfx))
                       ((integerp pfx) pfx)
                       (t 0)))
         ;; Floor the result so a degenerate window still gets a usable
         ;; table — but never let the floor exceed an explicit small cap.
         (floor  (if (integerp cap) (min 16 cap) 16)))
    (max floor (- full indent 1))))

(defun mutecipher-acp--md-table-fit-widths (natural text-width)
  "Shrink NATURAL column widths so the rendered table fits TEXT-WIDTH.
NATURAL is a vector of max-content widths; the result is a fresh vector
never exceeding NATURAL and, where shrinking is forced, repeatedly
trimming the widest column.  A per-column floor of
`mutecipher-acp--md-table-min-col-width' is honoured but lowered toward
an equal share of the available space when the window is too narrow to
grant every column that floor — guaranteeing the fitted total never
exceeds the budget, so rows never soft-wrap."
  (let* ((ncols    (length natural))
         (overhead (+ (* 3 ncols) 1))            ; │ + 2 pad per col, +1 closer
         (avail    (max ncols (- text-width overhead)))
         (min-w    (max 1 (min mutecipher-acp--md-table-min-col-width
                               (/ avail (max 1 ncols)))))
         (ws       (copy-sequence natural))
         (total    (apply #'+ 0 (append ws nil))))
    (while (and (> total avail)
                (let ((shrinkable nil) (i 0))
                  (while (< i ncols)
                    (when (> (aref ws i) min-w) (setq shrinkable t))
                    (setq i (1+ i)))
                  shrinkable))
      (let ((idx -1) (best -1) (i 0))
        (while (< i ncols)
          (when (and (> (aref ws i) min-w) (> (aref ws i) best))
            (setq best (aref ws i) idx i))
          (setq i (1+ i)))
        (aset ws idx (1- (aref ws idx)))
        (setq total (1- total))))
    ws))

(defun mutecipher-acp--md-take-columns (s width)
  "Split S into (PREFIX . REST) at the most leading chars fitting WIDTH columns.
Display-width aware (`char-width'), so double-width glyphs are not cut
mid-cell and a single wide char wider than WIDTH still advances by one so
callers can't loop forever."
  (let ((i 0) (n (length s)) (w 0))
    (while (and (< i n)
                (<= (+ w (char-width (aref s i))) width))
      (setq w (+ w (char-width (aref s i)))
            i (1+ i)))
    (when (and (= i 0) (> n 0)) (setq i 1))  ; force progress on a too-wide glyph
    (cons (substring s 0 i) (substring s i))))

(defun mutecipher-acp--md-wrap-cell (text width)
  "Greedily word-wrap TEXT into a list of lines each at most WIDTH columns.
Widths are display columns (`string-width'), so double-width glyphs are
budgeted correctly.  A single word wider than WIDTH is hard-split at
column boundaries, with its trailing remainder kept on its own line
rather than glued to the following word.  Always returns at least one
\(possibly empty) line."
  (let ((text (string-trim text)))
    (if (<= (string-width text) width)
        (list text)
      (let ((words (split-string text "[ \t]+" t))
            (cur "") lines)
        (dolist (word words)
          (cond
           ((> (string-width word) width)
            (when (> (length cur) 0) (push cur lines) (setq cur ""))
            (let ((w word))
              (while (> (string-width w) width)
                (let ((cut (mutecipher-acp--md-take-columns w width)))
                  (push (car cut) lines)
                  (setq w (cdr cut))))
              (when (> (length w) 0) (push w lines))))
           ((= (length cur) 0) (setq cur word))
           ((<= (+ (string-width cur) 1 (string-width word)) width)
            (setq cur (concat cur " " word)))
           (t (push cur lines) (setq cur word))))
        (when (> (length cur) 0) (push cur lines))
        (nreverse (or lines (list "")))))))

(defun mutecipher-acp--md-table-box-line (widths left junc right fill)
  "Build a horizontal border string from WIDTHS using LEFT/JUNC/RIGHT/FILL."
  (let ((segs (mapcar (lambda (w) (make-string (+ w 2) fill))
                      (append widths nil))))
    (propertize (concat left (mapconcat #'identity segs junc) right)
                'face 'mutecipher-acp-md-table-rule-face)))

(defun mutecipher-acp--md-table-format-row (cells widths &optional align)
  "Build a propertized data row, wrapping cells to WIDTHS.
Returns a string of one or more newline-separated visual lines — a row
is as tall as its most-wrapped cell, with shorter cells blank-padded.
ALIGN is `center' or nil (left); each wrapped line is padded
independently."
  (let* ((pipe    (propertize "│" 'face 'mutecipher-acp-md-table-rule-face))
         (ncols   (length widths))
         (wrapped (make-vector ncols nil))
         (height  1))
    (dotimes (i ncols)
      (let* ((cell  (or (nth i cells) ""))
             (lines (mutecipher-acp--md-wrap-cell cell (aref widths i))))
        (aset wrapped i lines)
        (setq height (max height (length lines)))))
    (let (out-lines)
      (dotimes (k height)
        (let (parts)
          (dotimes (i ncols)
            (let* ((w     (aref widths i))
                   (line  (or (nth k (aref wrapped i)) ""))
                   (slack (max 0 (- w (string-width line))))
                   (lpad  (if (eq align 'center) (/ slack 2) 0))
                   (rpad  (- slack lpad)))
              (push pipe parts)
              (push (concat " " (make-string lpad ?\s)
                            line (make-string rpad ?\s) " ")
                    parts)))
          (push pipe parts)
          (push (apply #'concat (nreverse parts)) out-lines)))
      (mapconcat #'identity (nreverse out-lines) "\n"))))

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
          (let* ((widths   (mutecipher-acp--md-table-fit-widths
                            (mutecipher-acp--md-table-col-widths cell-rows)
                            (mutecipher-acp--md-table-text-width start)))
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
                ;; `evaporate' auto-deletes the overlay if it ever
                ;; collapses to zero length, e.g. when ewoc-invalidate
                ;; deletes the assistant node's text during streaming.
                ;; Without it, orphan zero-length overlays survive in
                ;; the buffer with their before/after-strings still
                ;; visible, painting stray border lines that escape the
                ;; next `apply-markdown's range-scoped clear.
                (overlay-put ov 'evaporate t)
                (overlay-put ov 'display disp)
                (when (= i 0)
                  (overlay-put ov 'before-string (concat top "\n")))
                (cond
                 (last-p
                  (overlay-put ov 'after-string (concat bottom "\n")))
                 (inject-p
                  (overlay-put ov 'after-string (concat row-sep "\n"))))
                ;; Tag with the table's source head, not just t, so the
                ;; resize handler can regroup a table's overlays and re-fit.
                (overlay-put ov 'mutecipher-acp-md-table start)))
            (setq mutecipher-acp--md-has-tables t)
            (point)))))))

(defun mutecipher-acp--md-table-clear-overlays (beg end)
  "Delete any rendered-table overlays inside BEG..END."
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov 'mutecipher-acp-md-table)
      (delete-overlay ov))))

(defun mutecipher-acp--md-rerender-tables ()
  "Re-fit every rendered GFM table in the current buffer to the live width.
The underlying pipe-delimited source survives behind each table's
overlays, so dropping them and re-rendering recomputes column widths
against the current window (or `mutecipher-acp--md-table-width-override'
when bound).  Re-render heads are taken from each table's live
`overlay-start' — NOT the integer tag value, which froze at first-render
position and goes stale once text above the table shifts (e.g. a
tool-call card above it expands).  The tag is used only to group a
table's overlays.  Clears `mutecipher-acp--md-has-tables' when no table
overlays remain so a later resize stops scanning a now-tableless buffer."
  (let ((groups (make-hash-table :test #'eql)))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (let ((key (overlay-get ov 'mutecipher-acp-md-table)))
        (when key
          (push (overlay-start ov) (gethash key groups)))))
    (if (zerop (hash-table-count groups))
        (setq mutecipher-acp--md-has-tables nil)
      (let (heads)
        (maphash (lambda (_key starts) (push (apply #'min starts) heads))
                 groups)
        (mutecipher-acp--md-table-clear-overlays (point-min) (point-max))
        (save-excursion
          (dolist (start (sort heads #'<))
            (goto-char start)
            (when (looking-at mutecipher-acp--md-table-line-re)
              (mutecipher-acp--md-table-render-at start))))))))

(defun mutecipher-acp--md-refit-buffer (buf)
  "Re-fit BUF's GFM tables to the narrowest window currently showing it.
Fitting to the minimum body width across every window displaying BUF
keeps the table within bounds in all of them (rather than reflowing to
whichever window the caller happened to visit last).  No-ops unless that
width actually changed since the last fit.  `window-start' is
snapshotted and restored per window so a narrowing reflow that grows a
table's height can't scroll the reader's position away."
  (let* ((wins (get-buffer-window-list buf 'no-minibuffer t))
         (w    (and wins (apply #'min (mapcar #'window-body-width wins)))))
    (when w
      (with-current-buffer buf
        (unless (eql w mutecipher-acp--md-last-window-width)
          (setq mutecipher-acp--md-last-window-width w)
          (let ((mutecipher-acp--md-table-width-override w)
                (snap (mapcar (lambda (win)
                                (cons win (copy-marker (window-start win) nil)))
                              wins)))
            (with-demoted-errors "mutecipher-acp md table re-fit: %S"
              (mutecipher-acp--md-rerender-tables))
            (dolist (entry snap)
              (when (and (window-live-p (car entry))
                         (eq (window-buffer (car entry)) buf))
                (set-window-start (car entry) (marker-position (cdr entry)) t))
              (set-marker (cdr entry) nil))))))))

(defun mutecipher-acp--md-on-window-change (frame)
  "Re-fit GFM tables in FRAME's table-bearing buffers when their width changed.
Registered on both `window-size-change-functions' (frame resize) and
`window-buffer-change-functions' (a buffer rendered while undisplayed, at
the fallback width, becoming visible).  Skips buffers that have never
rendered a table; each buffer is refit at most once per call even when
shown in several of FRAME's windows."
  (let (seen)
    (dolist (win (window-list frame 'no-minibuffer))
      (let ((buf (window-buffer win)))
        (when (and (not (memq buf seen))
                   (buffer-local-value 'mutecipher-acp--md-has-tables buf))
          (push buf seen)
          (mutecipher-acp--md-refit-buffer buf))))))

(add-hook 'window-size-change-functions   #'mutecipher-acp--md-on-window-change)
(add-hook 'window-buffer-change-functions #'mutecipher-acp--md-on-window-change)

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
  "Render `**bold**' between BEG and END.
The inner run admits lone `*' (matched as `* + non-*') so nested
emphasis like `**bold *italic* bold**' is captured whole; the bold face
covers the inner `*italic*' markers and the later italic pass — which
skips the now-invisible `**' delimiters — composes italic on top."
  (goto-char beg)
  (while (re-search-forward "\\*\\*\\(\\(?:[^*\n]\\|\\*[^*\n]\\)+?\\)\\*\\*" end t)
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
  ;; `list' (not quoted '(...)) so `setcdr' in `register-md-pass' can
  ;; safely splice without mutating a read-only literal.
  (list 'mutecipher-acp--md-pass-fenced-code
        'mutecipher-acp--md-pass-inline-code
        'mutecipher-acp--md-pass-headings
        'mutecipher-acp--md-pass-blockquotes
        'mutecipher-acp--md-pass-tables
        'mutecipher-acp--md-pass-checkboxes
        'mutecipher-acp--md-pass-bold
        'mutecipher-acp--md-pass-italic
        'mutecipher-acp--md-pass-italic-underscore
        'mutecipher-acp--md-pass-strike
        'mutecipher-acp--md-pass-links)
  "Ordered list of markdown rendering passes.
Each is called as (FN BEG END LINE-STARTS).  Order matters: code passes
run first so their content is opaque to later matchers; block-level
runs before inline so contents compose.")

(defun mutecipher-acp-register-md-pass (fn &optional after)
  "Add FN to `mutecipher-acp--md-passes' if not already present.
With no AFTER, append.  With AFTER (a symbol), insert FN immediately
after that pass; signals an error if AFTER is not currently
registered, since silently appending would violate the ordering the
caller asked for."
  (unless (memq fn mutecipher-acp--md-passes)
    (cond
     ((null after)
      (setq mutecipher-acp--md-passes
            (append mutecipher-acp--md-passes (list fn))))
     (t
      (let ((tail (memq after mutecipher-acp--md-passes)))
        (unless tail
          (error "mutecipher-acp-register-md-pass: AFTER pass %S is not registered"
                 after))
        (setcdr tail (cons fn (cdr tail))))))))

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
