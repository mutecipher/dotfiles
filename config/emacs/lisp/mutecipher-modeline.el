;;; mutecipher-modeline.el --- Custom mode line  -*- lexical-binding: t -*-
;;
;; Custom mode-line displaying buffer state, VC branch, file type icon, eglot
;; status, flymake diagnostics, git blame, word count, and cursor position.

(require 'mutecipher-icons)
(require 'mutecipher-git-blame)

(defun mutecipher/flymake-mode-line ()
  "Return a mode line segment for flymake errors/warnings only, nil when clean."
  (when (bound-and-true-p flymake-mode)
    (let* ((diags (flymake-diagnostics))
           (errs  (seq-count (lambda (d) (eq :error   (flymake-diagnostic-type d))) diags))
           (warns (seq-count (lambda (d) (eq :warning (flymake-diagnostic-type d))) diags)))
      (unless (and (zerop errs) (zerop warns))
        (concat
         (unless (zerop errs)
           (concat " " (propertize (format "\uf057 %d" errs) 'face 'mutecipher-icon-red)))
         (unless (zerop warns)
           (concat " " (propertize (format "\uf071 %d" warns) 'face 'mutecipher-icon-yellow))))))))

(setq-default mode-line-format
  '("%e"
    " "
    (:eval (cond
            (buffer-read-only    (propertize "\uf023 " 'face 'mutecipher-icon-dim))
            ((buffer-modified-p) (propertize "● "     'face 'mutecipher-icon-orange))
            (t                   "  ")))
    (:eval (concat "("
                   (car (split-string (string-trim (format-mode-line mode-name)) "/"))
                   ")"))
    "  "
    (:eval (when vc-mode
             (let* ((branch  (string-trim-left vc-mode "[ Git@:-]+"))
                    (max-len (min 20 (max 6 (- (window-width) 85))))
                    (display (if (> (length branch) max-len)
                                 (concat (substring branch 0 (1- max-len)) "…")
                               branch)))
               (concat (propertize "\uf126" 'face 'liminal-faded)
                       " "
                       (propertize display 'face 'liminal-faded)))))
    "  "
    (:eval (propertize (substring-no-properties (mutecipher/buffer-icon)) 'face 'liminal-faded))
    " "
    (:eval (propertize (format-mode-line "%b") 'face 'bold))
    (:eval (when (and (fboundp 'eglot-managed-p) (eglot-managed-p))
             (concat " " (propertize "●" 'face 'mutecipher-icon-green))))
    (:eval (when-let ((s (mutecipher/flymake-mode-line)))
             (concat "  " s)))
    mode-line-format-right-align
    (:eval (mutecipher-git-blame-mode-line-segment))
    (:eval (when (mutecipher-git-blame-mode-line-segment) "  ·  "))
    (:eval (when (derived-mode-p 'text-mode 'org-mode)
             (concat (propertize (format "%dw" (count-words (point-min) (point-max)))
                                 'face 'shadow)
                     "  ·  ")))
    (:eval (propertize (format-mode-line "%l:%C") 'face 'shadow))
    "  "
    (:eval (propertize (format-mode-line mode-line-misc-info) 'face 'shadow))))

(provide 'mutecipher-modeline)
;;; mutecipher-modeline.el ends here
