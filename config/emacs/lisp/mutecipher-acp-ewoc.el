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
  "Pulse-highlight the buffer region spanned by NODE in EWOC."
  (when (and ewoc node (fboundp 'pulse-momentary-highlight-region))
    (let* ((beg  (ewoc-location node))
           (next (ewoc-next ewoc node))
           (end  (if next (ewoc-location next) (point-max))))
      (when (and beg (> end beg))
        (pulse-momentary-highlight-region
         beg end 'mutecipher-acp-pulse-face)))))

(provide 'mutecipher-acp-ewoc)
;;; mutecipher-acp-ewoc.el ends here
