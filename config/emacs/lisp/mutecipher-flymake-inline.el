;;; mutecipher-flymake-inline.el --- Inline Flymake diagnostic overlays  -*- lexical-binding: t -*-
;;
;; Renders Flymake diagnostic messages as after-string overlays at the end of
;; each flagged line, similar to inline errors in VS Code or lsp-ui.  When
;; multiple diagnostics share a line the highest-severity one is shown.
;;
;; Hooks into Flymake via advice on `flymake--handle-report', the internal
;; function called each time a backend delivers new results.  The advice is
;; registered globally but only acts in buffers where the mode is active.
;;
;; Entry points:
;;   `mutecipher-flymake-inline-mode' — buffer-local minor mode
;;
;; Typical setup (activate alongside flymake):
;;   (add-hook 'flymake-mode-hook #'mutecipher-flymake-inline-mode)

;;; Code:

;;;; Options

(defcustom mutecipher-flymake-inline-max-width 80
  "Maximum character width for an inline diagnostic message."
  :type 'integer
  :group 'flymake)

;;;; Faces

(defface mutecipher-flymake-inline-error
  '((t :inherit font-lock-comment-face :foreground "#F44336"))
  "Face for inline error diagnostics.")

(defface mutecipher-flymake-inline-warning
  '((t :inherit font-lock-comment-face :foreground "#FF9800"))
  "Face for inline warning diagnostics.")

(defface mutecipher-flymake-inline-note
  '((t :inherit font-lock-comment-face))
  "Face for inline note/info diagnostics.")

;;;; Overlay management

(defun mutecipher-flymake-inline--clear ()
  "Remove all inline diagnostic overlays from the current buffer."
  (remove-overlays (point-min) (point-max) 'mutecipher-flymake-inline t))

(defun mutecipher-flymake-inline--face (type)
  "Return the inline face for diagnostic TYPE."
  (pcase type
    (:error   'mutecipher-flymake-inline-error)
    (:warning 'mutecipher-flymake-inline-warning)
    (_        'mutecipher-flymake-inline-note)))

(defun mutecipher-flymake-inline--show (diag)
  "Place an end-of-line overlay for DIAG in the current buffer."
  (let* ((pos  (flymake-diagnostic-beg diag))
         (face (mutecipher-flymake-inline--face
                (flymake-diagnostic-type diag)))
         (label (propertize
                 (truncate-string-to-width
                  (concat "  " (flymake-diagnostic-text diag))
                  mutecipher-flymake-inline-max-width nil nil "…")
                 'face face
                 'cursor t)))
    (save-excursion
      (goto-char pos)
      (let ((ov (make-overlay (line-end-position) (line-end-position)
                              nil t t)))
        (overlay-put ov 'mutecipher-flymake-inline t)
        (overlay-put ov 'after-string label)))))

;;;; Severity ordering (higher = more severe)

(defun mutecipher-flymake-inline--severity (type)
  "Return a numeric severity for diagnostic TYPE."
  (pcase type
    (:error   2)
    (:warning 1)
    (_        0)))

;;;; Refresh

(defun mutecipher-flymake-inline--refresh (&rest _)
  "Rebuild inline overlays for the current buffer from live Flymake data."
  (when (bound-and-true-p mutecipher-flymake-inline-mode)
    (mutecipher-flymake-inline--clear)
    ;; Collect one diagnostic per line — keep the highest-severity entry.
    (let ((by-line (make-hash-table :test 'eql)))
      (dolist (diag (flymake-diagnostics))
        (let* ((line     (line-number-at-pos (flymake-diagnostic-beg diag)))
               (existing (gethash line by-line)))
          (when (or (null existing)
                    (> (mutecipher-flymake-inline--severity
                        (flymake-diagnostic-type diag))
                       (mutecipher-flymake-inline--severity
                        (flymake-diagnostic-type existing))))
            (puthash line diag by-line))))
      (maphash (lambda (_line diag)
                 (mutecipher-flymake-inline--show diag))
               by-line))))

;;;; Minor mode

;; The advice is added globally once and relies on the buffer-local mode
;; variable so it is harmless in buffers where the mode is inactive.
(defun mutecipher-flymake-inline--on-report (&rest _)
  "Advice for `flymake--handle-report': refresh overlays in active buffers."
  (mutecipher-flymake-inline--refresh))

;;;###autoload
(define-minor-mode mutecipher-flymake-inline-mode
  "Show Flymake diagnostics as inline end-of-line overlays."
  :lighter nil
  (if mutecipher-flymake-inline-mode
      (progn
        (advice-add 'flymake--handle-report :after
                    #'mutecipher-flymake-inline--on-report)
        (mutecipher-flymake-inline--refresh))
    (mutecipher-flymake-inline--clear)))

(provide 'mutecipher-flymake-inline)
;;; mutecipher-flymake-inline.el ends here
