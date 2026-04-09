;;; mutecipher-colorize.el --- Inline colour previews  -*- lexical-binding: t -*-
;;
;; Overlays a background swatch on CSS-style colour codes:
;;   #RGB / #RRGGBB
;;   rgb(R, G, B) / rgba(R, G, B, A)
;;   hsl(H, S%, L%) / hsla(H, S%, L%, A)
;;
;; Foreground (black or white) is chosen by perceived luminance so the
;; original text stays readable against the swatch.

;;; Regexps

(defconst mutecipher-colorize--hex-re
  "#\\(?:[0-9a-fA-F]\\{6\\}\\|[0-9a-fA-F]\\{3\\}\\)\\b"
  "3- or 6-digit hex colour code.")

(defconst mutecipher-colorize--rgb-re
  "rgba?(\\s-*\\([0-9]\\{1,3\\}\\)\\s-*,\\s-*\\([0-9]\\{1,3\\}\\)\\s-*,\\s-*\\([0-9]\\{1,3\\}\\)\\s-*\\(?:,\\s-*[0-9.]+\\s-*\\)?)"
  "rgb() / rgba() with comma-separated components.")

(defconst mutecipher-colorize--hsl-re
  "hsla?(\\s-*\\([0-9]\\{1,3\\}\\(?:\\.[0-9]+\\)?\\)\\s-*,\\s-*\\([0-9]\\{1,3\\}\\(?:\\.[0-9]+\\)?\\)%\\s-*,\\s-*\\([0-9]\\{1,3\\}\\(?:\\.[0-9]+\\)?\\)%\\s-*\\(?:,\\s-*[0-9.]+\\s-*\\)?)"
  "hsl() / hsla() with comma-separated components.")

;;; Conversion helpers

(defun mutecipher-colorize--expand-hex (hex)
  "Expand a 3-digit HEX (#RGB) colour to 6-digit form (#RRGGBB)."
  (if (= (length hex) 4)
      (let ((r (substring hex 1 2))
            (g (substring hex 2 3))
            (b (substring hex 3 4)))
        (format "#%s%s%s%s%s%s" r r g g b b))
    hex))

(defun mutecipher-colorize--hue-to-rgb (p q h)
  "Map a hue H onto the RGB line segment defined by P and Q."
  (let ((h (cond ((< h 0) (+ h 1))
                 ((> h 1) (- h 1))
                 (t h))))
    (cond ((< h (/ 1.0 6)) (+ p (* (- q p) 6 h)))
          ((< h 0.5)       q)
          ((< h (/ 2.0 3)) (+ p (* (- q p) (- (/ 2.0 3) h) 6)))
          (t               p))))

(defun mutecipher-colorize--hsl-to-rgb (h s l)
  "Convert H (0–360), S and L (0–100) to a list (R G B) each 0–255."
  (let* ((h (/ h 360.0))
         (s (/ s 100.0))
         (l (/ l 100.0)))
    (if (= s 0)
        (let ((v (round (* l 255))))
          (list v v v))
      (let* ((q (if (< l 0.5)
                    (* l (+ 1 s))
                  (+ l s (- (* l s)))))
             (p (- (* 2 l) q)))
        (list (round (* 255 (mutecipher-colorize--hue-to-rgb p q (+ h (/ 1.0 3)))))
              (round (* 255 (mutecipher-colorize--hue-to-rgb p q h)))
              (round (* 255 (mutecipher-colorize--hue-to-rgb p q (- h (/ 1.0 3))))))))))

;;; Match → #RRGGBB converters (called with match-data set)

(defun mutecipher-colorize--hex-at-match ()
  (mutecipher-colorize--expand-hex (match-string 0)))

(defun mutecipher-colorize--rgb-at-match ()
  (format "#%02x%02x%02x"
          (min 255 (max 0 (string-to-number (match-string 1))))
          (min 255 (max 0 (string-to-number (match-string 2))))
          (min 255 (max 0 (string-to-number (match-string 3))))))

(defun mutecipher-colorize--hsl-at-match ()
  (pcase-let ((`(,r ,g ,b)
               (mutecipher-colorize--hsl-to-rgb
                (string-to-number (match-string 1))
                (string-to-number (match-string 2))
                (string-to-number (match-string 3)))))
    (format "#%02x%02x%02x" r g b)))

;;; Overlay machinery

(defun mutecipher-colorize--luminance (hex)
  "Return perceived luminance (0.0–1.0) of 6-digit HEX colour."
  (+ (* 0.299 (/ (string-to-number (substring hex 1 3) 16) 255.0))
     (* 0.587 (/ (string-to-number (substring hex 3 5) 16) 255.0))
     (* 0.114 (/ (string-to-number (substring hex 5 7) 16) 255.0))))

(defun mutecipher-colorize--clear (start end)
  "Remove colour overlays between START and END."
  (dolist (ov (overlays-in start end))
    (when (overlay-get ov 'mutecipher-colorize)
      (delete-overlay ov))))

(defun mutecipher-colorize--apply (re converter start end)
  "Search RE between START and END; overlay each match via CONVERTER."
  (save-excursion
    (goto-char start)
    (while (re-search-forward re end t)
      (let* ((hex (funcall converter))
             (fg  (if (> (mutecipher-colorize--luminance hex) 0.5) "#000000" "#ffffff"))
             (ov  (make-overlay (match-beginning 0) (match-end 0))))
        (overlay-put ov 'face `(:background ,hex :foreground ,fg))
        (overlay-put ov 'mutecipher-colorize t)
        (overlay-put ov 'evaporate t)))))

(defun mutecipher-colorize--update (start end)
  "Apply colour swatches to all supported formats between START and END."
  (mutecipher-colorize--clear start end)
  (mutecipher-colorize--apply mutecipher-colorize--hex-re #'mutecipher-colorize--hex-at-match start end)
  (mutecipher-colorize--apply mutecipher-colorize--rgb-re #'mutecipher-colorize--rgb-at-match start end)
  (mutecipher-colorize--apply mutecipher-colorize--hsl-re #'mutecipher-colorize--hsl-at-match start end))

;;; Minor mode

;;;###autoload
(define-minor-mode mutecipher-colorize-mode
  "Highlight colour codes (#hex, rgb(), hsl()) with inline background swatches."
  :lighter " #"
  (if mutecipher-colorize-mode
      (progn
        (jit-lock-register #'mutecipher-colorize--update)
        (jit-lock-fontify-now (point-min) (point-max)))
    (jit-lock-unregister #'mutecipher-colorize--update)
    (mutecipher-colorize--clear (point-min) (point-max))))

(provide 'mutecipher-colorize)
;;; mutecipher-colorize.el ends here
