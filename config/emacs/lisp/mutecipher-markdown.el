;;; mutecipher-markdown.el --- Markdown major mode with visual prettification  -*- lexical-binding: t -*-
;;
;; Hides syntax markers and applies faces to give Markdown files a cleaner
;; reading experience while remaining fully editable.
;; Toggle between prettified and raw views with C-c C-t.

;;; Faces

(defgroup mutecipher-markdown nil
  "Faces and settings for `mutecipher-markdown-mode'."
  :group 'faces)

(defface mutecipher-markdown-syntax
  '((t :inherit shadow))
  "Markdown syntax markers — visible in raw view, hidden in pretty view."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-h1
  '((t :weight bold :height 1.6))
  "Level-1 heading."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-h2
  '((t :weight bold :height 1.4))
  "Level-2 heading."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-h3
  '((t :weight bold :height 1.2))
  "Level-3 heading."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-h4
  '((t :weight semi-bold :height 1.1))
  "Level-4 and deeper headings."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-inline-code
  '((((background dark))  :background "#232120")
   (((background light)) :background "#eae5dd"))
  "Inline code span.  Keeps the default font; adds a code-like background."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-code-block
  '((((background dark))  :background "#232120" :extend t)
   (((background light)) :background "#eae5dd" :extend t))
  "Fenced and indented code block content."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-code-fence
  '((t :inherit (shadow mutecipher-markdown-code-block)))
  "Fenced code block opening and closing fence lines."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-link
  '((t :inherit link))
  "Link text."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-blockquote
  '((t :inherit italic))
  "Blockquote text."
  :group 'mutecipher-markdown)

(defface mutecipher-markdown-table
  '((t))
  "GFM table row.  Themes can add a background here."
  :group 'mutecipher-markdown)

;;; Language tag → file extension mapping (for icon lookup)

(defvar mutecipher-markdown--lang-ext-alist
  '(;; All shell variants use the .sh terminal icon
    ("sh"         . "sh")
    ("bash"       . "sh")
    ("zsh"        . "sh")
    ("shell"      . "sh")
    ("emacs-lisp" . "el")
    ("elisp"      . "el")
    ("javascript" . "js")
    ("typescript" . "ts")
    ("python"     . "py")
    ("ruby"       . "rb")
    ("rust"       . "rs")
    ("golang"     . "go")
    ("yaml"       . "yaml")
    ("json"       . "json")
    ("html"       . "html")
    ("css"        . "css")
    ("scss"       . "scss")
    ("toml"       . "toml"))
  "Map code block language tags to file extensions for icon lookup.")

;;; Fence label builder

(defun mutecipher-markdown--fence-label (fence-text)
  "Return a propertized display string for the opening FENCE-TEXT.
Extracts the language tag and looks up its Nerd Font icon via
`mutecipher/icon-for-file'.  Falls back to the language name alone.

The icon's color face is reused for the language label so both render
in the same color against the code-fence background.

Uses `save-match-data' so internal regex calls do not corrupt the
match data that font-lock relies on for subsequent highlight groups."
  (save-match-data
    (let* (;; Preserve leading whitespace so indented blocks (e.g. inside lists)
           ;; keep the label aligned with their code content.
           (indent (progn (string-match "^\\([ \t]*\\)" fence-text)
                          (match-string 1 fence-text)))
           (lang   (if (string-match "^[ \t]*```\\([[:alnum:]_+-]*\\)" fence-text)
                       (match-string 1 fence-text)
                     ""))
           (ext    (cdr (assoc (downcase lang) mutecipher-markdown--lang-ext-alist)))
           ;; Try by extension first, then by capitalised lang name (e.g. "Dockerfile")
           (icon   (when (fboundp 'mutecipher/icon-for-file)
                     (or (when ext (mutecipher/icon-for-file (concat "x." ext)))
                         (mutecipher/icon-for-file (capitalize lang)))))
           ;; Reuse the icon's color face for the label; code-fence provides the background
           (color-face (when icon (get-text-property 0 'face icon)))
           (label-face (if color-face
                           `(,color-face mutecipher-markdown-code-fence)
                         'mutecipher-markdown-code-fence))
           (indent-str (propertize indent 'face 'mutecipher-markdown-code-fence)))
      (cond
       ((and icon (not (string-empty-p lang)))
        (concat indent-str
                (propertize (substring-no-properties icon) 'face label-face)
                (propertize (concat " " lang "\n") 'face label-face)))
       ((not (string-empty-p lang))
        (concat indent-str
                (propertize (concat lang "\n") 'face 'mutecipher-markdown-code-fence)))
       (t
        (concat indent-str
                (propertize "\n" 'face 'mutecipher-markdown-code-fence)))))))

;;; Helper: strip invisible characters from strings

(defun mutecipher-markdown--strip-invisible (str)
  "Return a copy of STR with `invisible' characters removed.
Text properties on visible characters are preserved."
  (let (chunks (pos 0) (len (length str)))
    (while (< pos len)
      (let* ((inv  (get-text-property pos 'invisible str))
             (next (next-single-property-change pos 'invisible str len)))
        (unless inv (push (substring str pos next) chunks))
        (setq pos next)))
    (apply #'concat (nreverse chunks))))

;;; Matchers for inline markup

(defun mutecipher-markdown--in-inline-code-p (pos)
  "Return non-nil if POS is inside a fontified inline code span."
  (memq 'mutecipher-markdown-inline-code
        (ensure-list (get-text-property pos 'face))))

(defun mutecipher-markdown--match-bold-italic (limit)
  "Match ***bold-italic*** spans before LIMIT."
  (re-search-forward "\\(\\*\\*\\*\\)\\([^*\n]+\\)\\(\\*\\*\\*\\)" limit t))

(defun mutecipher-markdown--match-bold (limit)
  "Match **bold** spans before LIMIT, skipping ***bold-italic***."
  (let (found)
    (while (and (not found)
                (re-search-forward "\\(\\*\\*\\)\\([^*\n]+\\)\\(\\*\\*\\)" limit t))
      (unless (or (eq (char-before (match-beginning 0)) ?*)
                  (eq (char-after  (match-end 0))       ?*)
                  (mutecipher-markdown--in-inline-code-p (match-beginning 2)))
        (setq found t)))
    found))

(defun mutecipher-markdown--match-bold-underscore (limit)
  "Match __bold__ spans before LIMIT, skipping intra-word patterns."
  (let (found)
    (while (and (not found)
                (re-search-forward "\\(__\\)\\([^_\n]+\\)\\(__\\)" limit t))
      (let ((before (char-before (match-beginning 0)))
            (after  (char-after  (match-end 0))))
        (unless (or (and before (= (char-syntax before) ?w))
                    (and after  (= (char-syntax after)  ?w))
                    (mutecipher-markdown--in-inline-code-p (match-beginning 2)))
          (setq found t))))
    found))

(defun mutecipher-markdown--match-italic (limit)
  "Match *italic* spans before LIMIT, skipping ** and *** markers."
  (let (found)
    (while (and (not found)
                (re-search-forward
                 "\\(\\*\\)\\([^* \t\n][^*\n]*[^* \t\n]\\|[^* \t\n]\\)\\(\\*\\)"
                 limit t))
      (unless (or (eq (char-before (match-beginning 0)) ?*)
                  (eq (char-after  (match-end 0))       ?*)
                  (mutecipher-markdown--in-inline-code-p (match-beginning 2)))
        (setq found t)))
    found))

(defun mutecipher-markdown--match-italic-underscore (limit)
  "Match _italic_ spans before LIMIT, skipping __ markers, inline code, and intra-word underscores.
Follows GFM rules: underscores only form emphasis at word boundaries."
  (let (found)
    (while (and (not found)
                (re-search-forward
                 "\\(_\\)\\([^_ \t\n][^_\n]*[^_ \t\n]\\|[^_ \t\n]\\)\\(_\\)"
                 limit t))
      (let ((before (char-before (match-beginning 0)))
            (after  (char-after  (match-end 0))))
        (unless (or (eq before ?_)
                    (eq after  ?_)
                    ;; GFM: skip intra-word underscores (e.g. NODE_ENV_VAL)
                    (and before (= (char-syntax before) ?w))
                    (and after  (= (char-syntax after)  ?w))
                    (mutecipher-markdown--in-inline-code-p (match-beginning 2)))
          (setq found t))))
    found))

;;; Code block matcher (multi-line)

(defun mutecipher-markdown--match-code-block (limit)
  "Match a fenced code block whose opening fence starts before LIMIT.
Searches to `point-max' for the closing fence so the block is always
fully covered.  Sets `font-lock-multiline' on the matched region.

Group 1: opening fence line including trailing newline.
Group 2: code content.
Group 3: closing fence line including trailing newline."
  (when (re-search-forward "^[ \t]*```[^\n]*\n" limit t)
    (let ((open-start (match-beginning 0))
          (open-end   (match-end 0)))
      (if (re-search-forward "^[ \t]*```[ \t]*\n?" nil t)
          (progn
            (put-text-property open-start (match-end 0) 'font-lock-multiline t)
            (set-match-data
             (list open-start          (match-end 0)
                   open-start          open-end
                   open-end            (match-beginning 0)
                   (match-beginning 0) (match-end 0)))
            t)
        (goto-char open-end)
        nil))))

;;; Region extension for code blocks

(defun mutecipher-markdown--extend-region ()
  "Expand the font-lock region to cover any enclosing fenced code block."
  (save-excursion
    (let (changed)
      (goto-char font-lock-beg)
      (when (and (re-search-backward "^[ \t]*```" nil t)
                 (< (point) font-lock-beg))
        (setq font-lock-beg (point) changed t))
      (goto-char font-lock-end)
      (when (and (re-search-forward "^[ \t]*```" nil t)
                 (> (match-end 0) font-lock-end))
        (setq font-lock-end (match-end 0) changed t))
      changed)))

;;; Font-lock keywords

(defconst mutecipher-markdown--keywords
  '(;; Inline code — before bold/italic to protect * inside backticks
    ("\\(`\\)\\([^`\n]+\\)\\(`\\)"
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'mutecipher-markdown-inline-code t)
     (3 '(face mutecipher-markdown-syntax invisible t) t))

    ;; ATX headings H1–H4+
    ("^\\(# \\)\\(.+?\\)[ \t]*#*$"
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'mutecipher-markdown-h1 t))
    ("^\\(## \\)\\(.+?\\)[ \t]*#*$"
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'mutecipher-markdown-h2 t))
    ("^\\(### \\)\\(.+?\\)[ \t]*#*$"
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'mutecipher-markdown-h3 t))
    ("^\\(#{4,6} \\)\\(.+?\\)[ \t]*#*$"
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'mutecipher-markdown-h4 t))

    ;; Bold+italic — before bold and italic to avoid partial matches
    (mutecipher-markdown--match-bold-italic
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 '(face (:weight bold :slant italic)) t)
     (3 '(face mutecipher-markdown-syntax invisible t) t))

    ;; Bold (** and __)
    (mutecipher-markdown--match-bold
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'bold t)
     (3 '(face mutecipher-markdown-syntax invisible t) t))
    (mutecipher-markdown--match-bold-underscore
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'bold t)
     (3 '(face mutecipher-markdown-syntax invisible t) t))

    ;; Italic (* and _)
    (mutecipher-markdown--match-italic
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'italic t)
     (3 '(face mutecipher-markdown-syntax invisible t) t))
    (mutecipher-markdown--match-italic-underscore
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'italic t)
     (3 '(face mutecipher-markdown-syntax invisible t) t))

    ;; Strikethrough ~~text~~
    ("\\(~~\\)\\([^~\n]+\\)\\(~~\\)"
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 '(face (:strike-through t)) t)
     (3 '(face mutecipher-markdown-syntax invisible t) t))

    ;; Links [text](url)
    ("\\(\\[\\)\\([^\]\n]+\\)\\(\\]([^)\n]+)\\)"
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'mutecipher-markdown-link t)
     (3 '(face mutecipher-markdown-syntax invisible t) t))

    ;; Blockquotes
    ("^\\(> \\)\\(.*\\)$"
     (1 '(face mutecipher-markdown-syntax invisible t) t)
     (2 'mutecipher-markdown-blockquote t))

    ;; Unordered list bullets
    ("^[ \t]*\\([-+*]\\) "
     (1 '(face nil display "•") t))

    ;; Horizontal rules
    ("^[-*_]\\{3,\\}[ \t]*$"
     (0 '(face shadow) t))

    ;; Indented code blocks (4 spaces or tab)
    ("^\\(?:    \\|\t\\).*$"
     (0 'mutecipher-markdown-code-block t))

    ;; GFM table separator rows (| :--- | ---: |)
    ("^|[ \t]*:?-+:?[ \t]*\\(?:|[ \t]*:?-+:?[ \t]*\\)*|[ \t]*$"
     (0 'mutecipher-markdown-table t))

    ;; GFM table content rows — nil override so inline code/bold inside cells still renders;
    ;; no t so fenced code block (applied later) wins
    ("^|[^\n]*|[ \t]*$"
     (0 'mutecipher-markdown-table))

    ;; Fenced code blocks — last so they win over indented block and table matches
    ;; Opening fence: ``` replaced by icon + language label via display property
    ;; Closing fence: made invisible, fence face background acts as footer bar
    (mutecipher-markdown--match-code-block
     (1 (list 'face 'mutecipher-markdown-code-fence
              'display (mutecipher-markdown--fence-label (match-string 1))) t)
     (2 '(face mutecipher-markdown-code-block invisible nil display nil) t)
     (3 '(face mutecipher-markdown-code-fence invisible t) t)))
  "Font-lock keywords for `mutecipher-markdown-mode'.")

;;; Table rendering via box-drawing overlays

(defvar-local mutecipher-markdown--table-overlays nil
  "Overlays used for GFM table box rendering.")

(defvar-local mutecipher-markdown--table-render-timer nil
  "Idle timer for deferred table re-rendering after buffer changes.")

(defun mutecipher-markdown--clear-table-overlays ()
  "Delete all table box overlays in the current buffer."
  (mapc #'delete-overlay mutecipher-markdown--table-overlays)
  (setq mutecipher-markdown--table-overlays nil))

(defun mutecipher-markdown--parse-cells (line)
  "Return a list of trimmed cell strings from GFM table row LINE."
  (when (string-match "^|\\(.*\\)|[ \t]*$" line)
    (mapcar #'string-trim (split-string (match-string 1 line) "|"))))

(defun mutecipher-markdown--sep-row-p (cells)
  "Return non-nil if CELLS is a separator row (all cells match :?-+:?)."
  (and cells
       (seq-every-p (lambda (c) (string-match-p "^:?-+:?$" c)) cells)))

(defun mutecipher-markdown--col-widths (all-cells)
  "Return a vector of max column widths from ALL-CELLS, ignoring separator rows."
  (let* ((ncols  (apply #'max (cons 1 (mapcar #'length all-cells))))
         (widths (make-vector ncols 0)))
    (dolist (cells all-cells)
      (unless (mutecipher-markdown--sep-row-p cells)
        (seq-do-indexed (lambda (cell i)
                          (when (< i ncols)
                            (aset widths i (max (aref widths i) (length cell)))))
                        cells)))
    widths))

(defun mutecipher-markdown--box-line (widths left junc right fill face)
  "Build a horizontal box border string.
WIDTHS: column width vector.  LEFT/JUNC/RIGHT: edge and junction chars.
FILL: horizontal fill character (e.g. ?─ or ?═).  FACE: applied to the result."
  (let ((segs (mapcar (lambda (w) (make-string (+ w 2) fill))
                      (append widths nil))))
    (propertize (concat left (mapconcat #'identity segs junc) right)
                'face face)))

(defun mutecipher-markdown--format-data-row (cells widths cell-face pipe-face)
  "Build a propertized data row display string.
CELLS: list of trimmed strings.  WIDTHS: column-width vector.
CELL-FACE: face for cell content.  PIPE-FACE: face for │ chars."
  (let ((pipe (propertize "│" 'face pipe-face))
        parts)
    (dotimes (i (length cells))
      (let* ((cell (or (nth i cells) ""))
             (w    (if (< i (length widths)) (aref widths i) (length cell)))
             (pad  (make-string (max 0 (- w (length cell))) ?\s)))
        (push pipe parts)
        (let ((segment (concat " " cell pad " ")))
          ;; Fill in cell-face only where no face is set; inline formatting
          ;; faces (mutecipher-markdown-inline-code, bold, etc.) are left
          ;; untouched so their foreground/background aren't overridden.
          (font-lock-fillin-text-property 0 (length segment) 'face cell-face segment)
          (push segment parts))))
    (push pipe parts)
    (apply #'concat (nreverse parts))))

(defun mutecipher-markdown--render-table (start)
  "Create box-drawing overlays for the GFM table beginning at START."
  (save-excursion
    (goto-char start)
    (let (line-starts raw-lines)
      (while (looking-at "^|[^\n]*|[ \t]*$")
        (push (point) line-starts)
        (push (buffer-substring (point) (line-end-position)) raw-lines)
        (forward-line 1))
      (when line-starts
        (let* ((starts    (nreverse line-starts))
               (lines     (nreverse raw-lines))
               (all-cells (mapcar #'mutecipher-markdown--parse-cells lines))
               ;; Strip invisible syntax markers (**, backticks, etc.) from cells;
               ;; display strings don't honour the `invisible' property.
               ;; Formatting faces (bold, inline-code) are preserved.
               (vis-cells (mapcar (lambda (row)
                                    (and row (mapcar #'mutecipher-markdown--strip-invisible row)))
                                  all-cells))
               (widths    (mutecipher-markdown--col-widths vis-cells))
               (syn       'mutecipher-markdown-syntax)
               (tbl       'mutecipher-markdown-table)
               (top       (mutecipher-markdown--box-line widths "┌" "┬" "┐" ?─ syn))
               (hdr-sep   (mutecipher-markdown--box-line widths "╞" "╪" "╡" ?═ syn))
               (bottom    (mutecipher-markdown--box-line widths "└" "┴" "┘" ?─ syn))
               (n         (length starts)))
          (seq-do-indexed
           (lambda (ls i)
             (let* ((cells  (nth i vis-cells))
                    (sep-p  (mutecipher-markdown--sep-row-p cells))
                    (last-p (= i (1- n)))
                    ;; For the last row, extend overlay to cover the trailing newline so
                    ;; after-string (bottom border) lands on its own line without an extra blank.
                    (le     (save-excursion
                              (goto-char ls)
                              (if last-p
                                  (min (1+ (line-end-position)) (point-max))
                                (line-end-position))))
                    (base   (if sep-p
                                hdr-sep
                              (mutecipher-markdown--format-data-row cells widths tbl syn)))
                    (disp   (if last-p (concat base "\n") base))
                    (ov     (make-overlay ls le nil t nil)))
               (overlay-put ov 'display disp)
               (when (= i 0)
                 (overlay-put ov 'before-string (concat top "\n")))
               (when last-p
                 (overlay-put ov 'after-string (concat bottom "\n")))
               (overlay-put ov 'mutecipher-markdown-table-ov t)
               (push ov mutecipher-markdown--table-overlays)))
           starts))))))

(defun mutecipher-markdown--render-all-tables ()
  "Re-render all GFM tables in the current buffer using box-drawing overlays."
  (when (derived-mode-p 'mutecipher-markdown-mode)
    (mutecipher-markdown--clear-table-overlays)
    (font-lock-ensure)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^|" nil t)
        (beginning-of-line)
        ;; Only start rendering at the first row of each table, not mid-table.
        (unless (save-excursion
                  (and (not (bobp))
                       (= 0 (forward-line -1))
                       (looking-at "^|[^\n]*|")))
          (mutecipher-markdown--render-table (point)))
        (forward-line 1)))))

(defun mutecipher-markdown--schedule-table-render (&rest _)
  "Schedule a deferred re-render of all tables after a buffer change."
  (when mutecipher-markdown--table-render-timer
    (cancel-timer mutecipher-markdown--table-render-timer))
  (setq mutecipher-markdown--table-render-timer
        (run-with-idle-timer 0.3 nil #'mutecipher-markdown--render-all-tables)))

;;; Raw/pretty toggle

(defvar-local mutecipher-markdown--raw-p nil
  "Non-nil when the buffer is in raw (unformatted) view.")

(defun mutecipher-markdown-toggle-raw ()
  "Toggle between prettified and raw Markdown display."
  (interactive)
  (setq mutecipher-markdown--raw-p (not mutecipher-markdown--raw-p))
  (if mutecipher-markdown--raw-p
      (progn
        (font-lock-remove-keywords nil mutecipher-markdown--keywords)
        (mutecipher-markdown--clear-table-overlays))
    (font-lock-add-keywords nil mutecipher-markdown--keywords t)
    (mutecipher-markdown--render-all-tables))
  (font-lock-flush)
  (message "Markdown: %s view" (if mutecipher-markdown--raw-p "raw" "pretty")))

;;; Mode map

(defvar mutecipher-markdown-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-t") #'mutecipher-markdown-toggle-raw)
    map)
  "Keymap for `mutecipher-markdown-mode'.")

;;; Major mode

(define-derived-mode mutecipher-markdown-mode text-mode "Markdown"
  "Major mode for Markdown with visual prettification.

Hides syntax markers (**, *, #, etc.) using text properties to give
a cleaner reading experience while remaining fully editable.

\\[mutecipher-markdown-toggle-raw] toggles between pretty and raw view.

\\{mutecipher-markdown-mode-map}"
  (setq-local font-lock-extra-managed-props '(display invisible))
  (setq-local font-lock-multiline t)
  (add-hook 'font-lock-extend-region-functions #'mutecipher-markdown--extend-region nil t)
  (font-lock-add-keywords nil mutecipher-markdown--keywords t)
  (visual-line-mode 1)
  (font-lock-mode 1)
  (mutecipher-markdown--render-all-tables)
  (add-hook 'after-change-functions #'mutecipher-markdown--schedule-table-render nil t)
  (add-hook 'kill-buffer-hook #'mutecipher-markdown--clear-table-overlays nil t))

(add-to-list 'auto-mode-alist '("\\.md\\'"       . mutecipher-markdown-mode))
(add-to-list 'auto-mode-alist '("\\.markdown\\'" . mutecipher-markdown-mode))

(provide 'mutecipher-markdown)
;;; mutecipher-markdown.el ends here
