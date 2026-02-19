;;; Customizations

;; Unicode all the things
(set-default-coding-systems 'utf-8)
(prefer-coding-system 'utf-8)

;; Theme
(load-theme 'modus-operandi)

(menu-bar-mode 1)
(tool-bar-mode -1)
(tooltip-mode -1)
(scroll-bar-mode -1)

;; Disable backups and lockfiles
(setq make-backup-files nil)
(setq backup-inhibited nil)
(setq create-lockfiles nil)

(global-hl-line-mode 1)

;; Send customization variables to hell
(setq custom-file (make-temp-file "emacs-customization-"))

(add-hook 'prog-mode-hook 'display-line-numbers-mode)

;;; Packages

(add-hook 'package-menu-mode-hook #'hl-line-mode)

;; Configure package archives
(setq package-archives
      '(("gnu-elpa" . "https://elpa.gnu.org/packages/")
	("nongnu" . "https://elpa.gnu.org/nongnu/")
	("melpa" . "https://melpa.org/packages/")))

;; Highest number gets priority
(setq package-archive-priorities
      '(("gnu-elpa" . 3)
	("melpa" . 2)
	("nongnu" . 1)))

(require 'init-org)
(require 'init-which-key)
(require 'init-newsticker)
;; (require 'init-macos)
;; (require 'init-erc)
(require 'init-theme)
