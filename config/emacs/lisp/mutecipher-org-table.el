;;; mutecipher-org-table.el --- Grid-style table rendering for Org  -*- lexical-binding: t -*-
;;
;; Renders Org tables as a clean Unicode grid with `┌─┬─┐' top, `├─┼─┤'
;; separator after every row, `└─┴─┘' bottom, and `│' between columns.
;; The first row is treated as the header and centered; subsequent rows
;; are left-aligned.  Buffer text is unchanged (overlays only), so
;; `org-table-align', TAB navigation, and editing all work normally.
;;
;; Toggle with `mutecipher-org-table-mode'; auto-enabled in `org-mode'.

(declare-function org-in-src-block-p "org" (&optional inside))

;;; Faces

(defgroup mutecipher-org-table nil
  "Grid-style table rendering for `org-mode'."
  :group 'org)

(defface mutecipher-org-table-rule
  '((t :inherit shadow))
  "Border glyphs (corners, junctions, rules, vertical pipes) in styled Org tables."
  :group 'mutecipher-org-table)

;;; State

(defvar-local mutecipher-org-table--overlays nil
  "Overlays used for Org table rendering.")

(defvar-local mutecipher-org-table--render-timer nil
  "Idle timer for deferred table re-rendering after buffer changes.")

;;; Helpers

(defun mutecipher-org-table--clear-overlays ()
  "Delete all rendering overlays in the current buffer."
  (mapc #'delete-overlay mutecipher-org-table--overlays)
  (setq mutecipher-org-table--overlays nil))

(defun mutecipher-org-table--parse-cells (line)
  "Return a list of trimmed cell strings from Org table row LINE.
Returns nil if LINE is not table-shaped."
  (when (string-match "^[ \t]*|\\(.*\\)|[ \t]*$" line)
    (mapcar #'string-trim (split-string (match-string 1 line) "|"))))

(defun mutecipher-org-table--sep-cells-p (cells)
  "Return non-nil if CELLS is a separator row (each cell is dashes)."
  (and cells
       (seq-every-p (lambda (c) (string-match-p "^-+$" c)) cells)))

(defun mutecipher-org-table--col-widths (all-cells)
  "Return a vector of max column widths from ALL-CELLS, ignoring separator rows."
  (let* ((data-cells (seq-remove #'mutecipher-org-table--sep-cells-p
                                 (delq nil all-cells)))
         (ncols (apply #'max 1 (mapcar #'length data-cells)))
         (widths (make-vector ncols 0)))
    (dolist (cells data-cells)
      (seq-do-indexed (lambda (cell i)
                        (when (< i ncols)
                          (aset widths i (max (aref widths i) (length cell)))))
                      cells))
    widths))

(defun mutecipher-org-table--box-line (widths left junc right fill face)
  "Build a horizontal box border string.
WIDTHS: column-width vector.  LEFT/JUNC/RIGHT: edge and junction chars.
FILL: horizontal fill character.  FACE: applied to the result."
  (let ((segs (mapcar (lambda (w) (make-string (+ w 2) fill))
                      (append widths nil))))
    (propertize (concat left (mapconcat #'identity segs junc) right)
                'face face)))

(defun mutecipher-org-table--format-row (cells widths pipe-face &optional align)
  "Build a propertized data row display string.
CELLS: list of trimmed strings.  WIDTHS: column-width vector.
PIPE-FACE: face for │ chars.  ALIGN is `center' or nil (left-align, default)."
  (let ((pipe (propertize "│" 'face pipe-face))
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

;;; Renderer

(defun mutecipher-org-table--render-table (start)
  "Create grid-style overlays for the Org table beginning at START.
No-op if START is inside a `#+begin_src' block."
  (save-excursion
    (goto-char start)
    (unless (org-in-src-block-p)
      (let (line-starts raw-lines)
        (while (and (not (eobp))
                    (looking-at "^[ \t]*|.*|[ \t]*$"))
          (push (point) line-starts)
          (push (buffer-substring (point) (line-end-position)) raw-lines)
          (forward-line 1))
        (when line-starts
          (let* ((starts    (nreverse line-starts))
                 (lines     (nreverse raw-lines))
                 (all-cells (mapcar #'mutecipher-org-table--parse-cells lines))
                 (widths    (mutecipher-org-table--col-widths all-cells))
                 (rule-face 'mutecipher-org-table-rule)
                 (top       (mutecipher-org-table--box-line widths "┌" "┬" "┐" ?─ rule-face))
                 (row-sep   (mutecipher-org-table--box-line widths "├" "┼" "┤" ?─ rule-face))
                 (bottom    (mutecipher-org-table--box-line widths "└" "┴" "┘" ?─ rule-face))
                 (n         (length starts)))
            (seq-do-indexed
             (lambda (ls i)
               (let* ((cells       (nth i all-cells))
                      (sep-p       (mutecipher-org-table--sep-cells-p cells))
                      (last-p      (= i (1- n)))
                      (next-cells  (and (not last-p) (nth (1+ i) all-cells)))
                      (next-sep-p  (mutecipher-org-table--sep-cells-p next-cells))
                      ;; Inject a row-sep between two adjacent data rows.
                      (inject-p    (and (not last-p) (not sep-p) (not next-sep-p)))
                      (extend-p    (or last-p inject-p))
                      (le          (save-excursion
                                     (goto-char ls)
                                     (if extend-p
                                         (min (1+ (line-end-position)) (point-max))
                                       (line-end-position))))
                      (align       (when (= i 0) 'center))
                      (base        (if sep-p
                                       row-sep
                                     (mutecipher-org-table--format-row
                                      cells widths rule-face align)))
                      (disp        (if extend-p (concat base "\n") base))
                      (ov          (make-overlay ls le nil t nil)))
                 (overlay-put ov 'display disp)
                 (when (= i 0)
                   (overlay-put ov 'before-string (concat top "\n")))
                 (cond
                  (last-p
                   (overlay-put ov 'after-string (concat bottom "\n")))
                  (inject-p
                   (overlay-put ov 'after-string (concat row-sep "\n"))))
                 (overlay-put ov 'mutecipher-org-table-ov t)
                 (push ov mutecipher-org-table--overlays)))
             starts)))))))

(defun mutecipher-org-table--render-all ()
  "Re-render all Org tables in the current buffer."
  (when (derived-mode-p 'org-mode)
    (mutecipher-org-table--clear-overlays)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*|" nil t)
        (beginning-of-line)
        ;; Only start rendering at the first row of each table, not mid-table.
        (unless (save-excursion
                  (and (not (bobp))
                       (= 0 (forward-line -1))
                       (looking-at "^[ \t]*|.*|[ \t]*$")))
          (mutecipher-org-table--render-table (point)))
        (forward-line 1)))))

(defun mutecipher-org-table--schedule-render (&rest _)
  "Schedule a deferred re-render of all Org tables after a buffer change."
  (when (timerp mutecipher-org-table--render-timer)
    (cancel-timer mutecipher-org-table--render-timer))
  (setq mutecipher-org-table--render-timer
        (run-with-idle-timer 0.25 nil #'mutecipher-org-table--render-all)))

;;; Mode

(defun mutecipher-org-table--cleanup ()
  "Cancel the pending render timer and remove all rendering overlays."
  (when (timerp mutecipher-org-table--render-timer)
    (cancel-timer mutecipher-org-table--render-timer)
    (setq mutecipher-org-table--render-timer nil))
  (mutecipher-org-table--clear-overlays))

;;;###autoload
(define-minor-mode mutecipher-org-table-mode
  "Render Org tables in a styled Unicode grid."
  :group 'mutecipher-org-table
  (cond
   (mutecipher-org-table-mode
    (add-hook 'after-change-functions #'mutecipher-org-table--schedule-render nil t)
    (add-hook 'kill-buffer-hook #'mutecipher-org-table--cleanup nil t)
    (mutecipher-org-table--render-all))
   (t
    (remove-hook 'after-change-functions #'mutecipher-org-table--schedule-render t)
    (remove-hook 'kill-buffer-hook #'mutecipher-org-table--cleanup t)
    (mutecipher-org-table--cleanup))))

(add-hook 'org-mode-hook #'mutecipher-org-table-mode)

(provide 'mutecipher-org-table)
;;; mutecipher-org-table.el ends here
