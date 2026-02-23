(require 'ui)
(require 'editor)
(require 'plugin)

;; Disable backups and lockfiles
(setq make-backup-files nil)
(setq backup-inhibited nil)
(setq create-lockfiles nil)

;; Send customization variables to hell
(setq custom-file (make-temp-file "emacs-customization-"))

;; Org Mode
(setq org-log-done 'time)
(setq org-hide-emphasis-markers t)

;; (require 'init-org)
(require 'init-which-key)
(require 'init-newsticker)
;; (require 'init-macos)
;; (require 'init-erc)
;; (require 'init-theme)
