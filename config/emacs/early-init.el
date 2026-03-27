;; -*- lexical-binding: t -*-

;; Delay garbage collection while booting
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

;; Return to sensible defaults after boot
(add-hook 'after-init-hook
	  (lambda ()
	    (setq gc-cons-threshold (* 100 1024 1024)
		  gc-cons-percentage 0.1)))

;; Having a single VC backend speeds up boot time
(setq vc-handled-backends '(Git))

;; Always start maximized
(add-to-list 'default-frame-alist '(fullscreen . maximized))

;; Better window management
(setq frame-resize-pixelwise t
      frame-inhibit-implied-resize t)

(when (eq system-type 'darwin)
  (setq ns-use-proxy-icon nil))

(setq inhibit-compacting-font-caches t)

;; Disable useless UI elements
(if (fboundp 'menu-bar-mode) (menu-bar-mode -1))
(if (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(if (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(if (fboundp 'tooltip-mode) (tooltip-mode -1))
(if (fboundp 'fringe-mode) (fringe-mode -1))

;; Don't log about lexical bindings
(setq warning-suppress-types '((lexical-binding)))

;; Redirect package installs out of dotfiles — must be set before package.el loads
(setq package-user-dir
      (expand-file-name "emacs/elpa/"
                        (or (getenv "XDG_DATA_HOME") "~/.local/share/")))

(provide 'early-init)

;; Configure package archives
;; (setq package-archives
;;       '(( "gnu-elpa" . "https://elpa.gnu.org/packages/")
;; 	("nongnu" . "https://elpa.gnu.org/nongnu/")
;; 	("melpa" . "https://melpa.org/packages/")))

;; Highest number gets priority
;; (setq package-archive-priorities
;;       '(("gnu-elpa" . 3)
;; 	("melpa" . 2)
;; 	("nongnu" . 1)))
