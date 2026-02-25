;; Move the mode line to the top of the screen
(setq-default header-line-format mode-line-format
	      mode-line-format nil)

(prefer-coding-system 'utf-8)

(add-hook 'window-setup-hook 'toggle-frame-maximized t)

(setq frame-resize-pixelwise t
      frame-inhibit-implied-resize 'force
      frame-title-format ""
      ring-bell-function 'ignore
      use-dialog-box t
      use-file-dialog nil
      use-short-answers t
      inhibit-splash-screen t
      inhibit-startup-screen t
      inhibit-x-resources t
      inhibit-startup-echo-area-message user-login-name
      inhibit-startup-buffer-menu t)

(setq initial-frame-alist `((horizontal-scroll-bars . nil)
			    (menu-bar-lines . 0)
			    (tool-bar-lines . 0)
			    (vertical-scroll-bars . nil)
			    (width . (text-pixels . 800))
			    (height . (text-pixels . 900))
			    (border-width . 0)
			    (left-fringe . 0)
			    (right-fringe . 0)
			    (font . "MonoLisa Variable Light 12")
			    (list '(undecorated . t))
			    (list '(fullscreen . maximized))))

;; Set the titlebar as transparent on macOS
(when (eq system-type 'darwin)
  (push '(ns-transparent-titlebar t) initial-frame-alist))

(add-hook 'after-init-hook (lambda ()
			     (setq default-frame-alist `((horizontal-scroll-bars . nil)
							 (menu-bar-lines . 0)
							 (tool-bar-lines . 0)
							 (vertical-scroll-bars . nil)
							 (width . (text-pixels . 800))
							 (height . (text-pixels . 900))
							 (border-width . 0)
							 (left-fringe . 0)
							 (right-fringe . 0)
							 (font . "MonoLisa Variable Light 12")
							 (list '(undecorated . t))
							 (list '(fullscreen . maximized))))))

;; Set the titlebar as transparent on macOS
(when (eq system-type 'darwin)
  (push '(ns-transparent-titlebar t) default-frame-alist))

;; Temporarily increase the garbage collection threshold.  These
;; changes help shave off about half a second of startup time.  The
;; `most-positive-fixnum' is DANGEROUS AS A PERMANENT VALUE.  See the
;; `emacs-startup-hook' a few lines below for what I actually use.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.5)

(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 100 100 8)
                  gc-cons-percentage 0.1)))

;; Initialise installed packages at this early stage, by using the
;; available cache.  I had tried a setup with this set to nil in the
;; early-init.el, but (i) it ended up being slower and (ii) various
;; package commands, like `describe-package', did not have an index of
;; packages to work with, requiring a `package-refresh-contents'.
(setq package-enable-at-startup t)

(setq user-lisp-directory (locate-user-emacs-file "lisp"))
(add-to-list 'load-path user-lisp-directory)
