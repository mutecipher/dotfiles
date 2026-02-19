;; (custom-set-faces! '(font-lock-comment-face italic))
;; (advice-add #'load-theme :after (lambda (&rest _) (set-face-italic 'font-lock-comment-face t)))

(setq modus-themes-italic-constructs t)
(use-package spacious-padding
  :ensure t)

(spacious-padding-mode 1)

(use-package circadian                  ; you need to install this
  :ensure t
  :config
  (setq calendar-latitude 51.050
        calendar-longitude -114.067)
  (setq circadian-themes '((:sunrise . modus-operandi)
                           (:sunset  . modus-vivendi)))
  (circadian-setup))

(provide 'init-theme)
