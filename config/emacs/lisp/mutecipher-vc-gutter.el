;;; mutecipher-vc-gutter.el --- Git change indicators in the left fringe  -*- lexical-binding: t -*-
;;
;; Diffs the current buffer against HEAD and renders added / modified /
;; deleted line indicators in the left fringe using Emacs overlays and
;; built-in fringe bitmaps.  No third-party packages — only `git' on PATH
;; and built-in vc / overlay machinery.
;;
;; Entry points:
;;   `mutecipher-vc-gutter-mode'        — buffer-local minor mode
;;   `mutecipher-vc-gutter-global-mode' — enable automatically in vc files
;;   `mutecipher-vc-gutter-update'      — refresh indicators interactively

;;; Code:

;;;; Faces

(defface mutecipher-vc-gutter-added
  '((t :foreground "#4CAF50"))
  "Face for the added-line fringe indicator.")

(defface mutecipher-vc-gutter-modified
  '((t :foreground "#2196F3"))
  "Face for the modified-line fringe indicator.")

(defface mutecipher-vc-gutter-deleted
  '((t :foreground "#F44336"))
  "Face for the deleted-line fringe indicator.")

;;;; Fringe bitmaps

;; Solid 3-pixel wide bar, centred vertically — used for added and modified.
(define-fringe-bitmap 'mutecipher-vc-gutter-bar
  (make-vector 40 #b11100000)
  nil nil 'center)

;; Bar that flares into a downward-pointing triangle at the bottom — used for
;; deleted lines so deletions are visually distinct from additions.
(define-fringe-bitmap 'mutecipher-vc-gutter-deleted-arrow
  [#b11100000
   #b11100000
   #b11100000
   #b11100000
   #b11100000
   #b11100000
   #b11111100
   #b01111000
   #b00110000
   #b00000000]
  nil nil 'bottom)

;;;; Diff parsing

(defun mutecipher-vc-gutter--diff (file)
  "Return unified diff of FILE against HEAD, or nil if unavailable."
  (let ((default-directory (file-name-directory file)))
    (with-temp-buffer
      (when (zerop (call-process "git" nil t nil
                                 "diff" "HEAD" "--unified=0" "--" file))
        (unless (= (point-min) (point-max))
          (buffer-string))))))

(defun mutecipher-vc-gutter--parse (diff)
  "Parse unified DIFF into a list of (LINE . TYPE) pairs.
TYPE is one of: `added', `modified', `deleted'."
  (let ((result '())
        (hunk-re (rx bol "@@ -"
                     (group (+ digit)) (opt "," (group (+ digit)))
                     " +"
                     (group (+ digit)) (opt "," (group (+ digit)))
                     " @@")))
    (with-temp-buffer
      (insert diff)
      (goto-char (point-min))
      (while (re-search-forward hunk-re nil t)
        (let* ((old-count (if (match-string 2)
                              (string-to-number (match-string 2))
                            1))
               (new-start (string-to-number (match-string 3)))
               (new-count (if (match-string 4)
                              (string-to-number (match-string 4))
                            1)))
          (cond
           ;; Pure insertion — no old lines removed.
           ((= old-count 0)
            (dotimes (i new-count)
              (push (cons (+ new-start i) 'added) result)))
           ;; Pure deletion — mark the line at the deletion boundary.
           ((= new-count 0)
            (push (cons (max 1 new-start) 'deleted) result))
           ;; Replacement — first min(old,new) lines are modified; any
           ;; surplus new lines are added.
           (t
            (let ((shared (min old-count new-count)))
              (dotimes (i shared)
                (push (cons (+ new-start i) 'modified) result))
              (dotimes (i (- new-count old-count))
                (push (cons (+ new-start old-count i) 'added) result))
              (when (> old-count new-count)
                (push (cons (+ new-start new-count) 'deleted) result))))))))
    (nreverse result)))

;;;; Overlay management

(defun mutecipher-vc-gutter--clear ()
  "Remove all gutter overlays from the current buffer."
  (remove-overlays (point-min) (point-max) 'mutecipher-vc-gutter t))

(defun mutecipher-vc-gutter--indicator (type)
  "Return a fringe display string for change TYPE."
  (propertize " "
              'display `(left-fringe
                         ,(if (eq type 'deleted)
                              'mutecipher-vc-gutter-deleted-arrow
                            'mutecipher-vc-gutter-bar)
                         ,(pcase type
                            ('added    'mutecipher-vc-gutter-added)
                            ('modified 'mutecipher-vc-gutter-modified)
                            ('deleted  'mutecipher-vc-gutter-deleted)))))

(defun mutecipher-vc-gutter--apply (changes)
  "Place fringe overlays for CHANGES in the current buffer."
  (mutecipher-vc-gutter--clear)
  (save-excursion
    (dolist (change changes)
      (goto-char (point-min))
      (forward-line (1- (car change)))
      (let ((ov (make-overlay (line-beginning-position)
                              (line-beginning-position))))
        (overlay-put ov 'mutecipher-vc-gutter t)
        (overlay-put ov 'before-string
                     (mutecipher-vc-gutter--indicator (cdr change)))))))

;;;; Update

;;;###autoload
(defun mutecipher-vc-gutter-update ()
  "Refresh git gutter indicators for the current buffer."
  (interactive)
  (if (and buffer-file-name (vc-registered buffer-file-name))
      (if-let ((diff (mutecipher-vc-gutter--diff buffer-file-name)))
          (mutecipher-vc-gutter--apply (mutecipher-vc-gutter--parse diff))
        (mutecipher-vc-gutter--clear))
    (mutecipher-vc-gutter--clear)))

;;;; Minor modes

;;;###autoload
(define-minor-mode mutecipher-vc-gutter-mode
  "Show git change indicators in the left fringe."
  :lighter nil
  (if mutecipher-vc-gutter-mode
      (progn
        (add-hook 'after-save-hook   #'mutecipher-vc-gutter-update nil t)
        (add-hook 'after-revert-hook #'mutecipher-vc-gutter-update nil t)
        (mutecipher-vc-gutter-update))
    (remove-hook 'after-save-hook   #'mutecipher-vc-gutter-update t)
    (remove-hook 'after-revert-hook #'mutecipher-vc-gutter-update t)
    (mutecipher-vc-gutter--clear)))

;;;###autoload
(define-globalized-minor-mode mutecipher-vc-gutter-global-mode
  mutecipher-vc-gutter-mode
  (lambda ()
    (when (and buffer-file-name (vc-registered buffer-file-name))
      (mutecipher-vc-gutter-mode 1))))

(provide 'mutecipher-vc-gutter)
;;; mutecipher-vc-gutter.el ends here
