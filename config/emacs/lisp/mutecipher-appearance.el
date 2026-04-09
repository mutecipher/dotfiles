;;; mutecipher-appearance.el --- System appearance detection and hooks  -*- lexical-binding: t -*-
;;
;; Provides a hook that fires whenever the system light/dark appearance changes,
;; so other modules can react without knowing about the detection machinery.
;;
;; Quickstart — theme switching in two lines:
;;
;;   (require 'mutecipher-appearance)
;;   (mutecipher-appearance-use-themes 'my-light-theme 'my-dark-theme)
;;
;; For custom behaviour beyond theme switching, add to the hook directly:
;;
;;   (add-hook 'mutecipher-appearance-change-functions #'my-handler)
;;
;; Each hook function receives one argument: the symbol `light' or `dark'.
;;
;; To override detection on an unsupported platform, set
;; `mutecipher-appearance-detect-function' to any zero-argument function
;; that returns `light' or `dark'.

;;; Hooks and state

(defvar mutecipher-appearance-change-functions nil
  "Abnormal hook run when the system appearance changes.
Each function is called with one argument, the appearance symbol:
`light' or `dark'.")

(defvar mutecipher--last-appearance nil
  "Last appearance dispatched; prevents redundant hook runs.")

;;; Detection backends

(defun mutecipher--detect-macos ()
  "Return appearance on macOS via `defaults read', or nil if unavailable."
  (when (eq system-type 'darwin)
    (if (string-match-p "Dark"
                        (shell-command-to-string
                         "defaults read -g AppleInterfaceStyle 2>/dev/null"))
        'dark
      'light)))

(defun mutecipher--detect-linux-gsettings ()
  "Return appearance via gsettings (GNOME/GTK), or nil if unavailable."
  (when (and (eq system-type 'gnu/linux)
             (executable-find "gsettings"))
    (let ((scheme (string-trim
                   (shell-command-to-string
                    "gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null"))))
      (cond
       ((string-match-p "dark"    scheme) 'dark)
       ((string-match-p "light\\|default" scheme) 'light)))))

(defun mutecipher--detect-linux-kde ()
  "Return appearance via kreadconfig5 (KDE Plasma), or nil if unavailable."
  (when (and (eq system-type 'gnu/linux)
             (executable-find "kreadconfig5"))
    (let ((scheme (string-trim
                   (shell-command-to-string
                    "kreadconfig5 --group General --key ColorScheme 2>/dev/null"))))
      (when (not (string-empty-p scheme))
        (if (string-match-p "[Dd]ark" scheme) 'dark 'light)))))

(defun mutecipher--detect-linux-darkman ()
  "Return appearance via darkman (cross-DE Linux tool), or nil if unavailable."
  (when (and (eq system-type 'gnu/linux)
             (executable-find "darkman"))
    (let ((result (string-trim
                   (shell-command-to-string "darkman get 2>/dev/null"))))
      (cond
       ((string= result "dark")  'dark)
       ((string= result "light") 'light)))))

(defun mutecipher--detect-default ()
  "Try each detection backend in order, falling back to `light'."
  (or (mutecipher--detect-macos)
      (mutecipher--detect-linux-darkman)
      (mutecipher--detect-linux-gsettings)
      (mutecipher--detect-linux-kde)
      'light))

(defvar mutecipher-appearance-detect-function #'mutecipher--detect-default
  "Zero-argument function that returns the current appearance as `light' or `dark'.
Override this to support additional platforms or custom detection logic.")

;;; Core API

(defun mutecipher/detect-appearance ()
  "Return the current system appearance as `light' or `dark'."
  (funcall mutecipher-appearance-detect-function))

(defun mutecipher/apply-appearance (appearance)
  "Run `mutecipher-appearance-change-functions' for APPEARANCE, if it changed."
  (unless (eq appearance mutecipher--last-appearance)
    (setq mutecipher--last-appearance appearance)
    (run-hook-with-args 'mutecipher-appearance-change-functions appearance)))

(defun mutecipher/sync-appearance ()
  "Detect the current system appearance and dispatch if it changed."
  (mutecipher/apply-appearance (mutecipher/detect-appearance)))

;;; Built-in theme switching

(defvar mutecipher-appearance-light-theme nil
  "Theme to enable when the system appearance is light.")

(defvar mutecipher-appearance-dark-theme nil
  "Theme to enable when the system appearance is dark.")

(defun mutecipher--apply-theme (appearance)
  "Load the configured light or dark theme for APPEARANCE."
  (when (and mutecipher-appearance-light-theme mutecipher-appearance-dark-theme)
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme (if (eq appearance 'dark)
                    mutecipher-appearance-dark-theme
                  mutecipher-appearance-light-theme)
                t)))

(add-hook 'mutecipher-appearance-change-functions #'mutecipher--apply-theme)

(defun mutecipher-appearance-use-themes (light dark)
  "Switch between LIGHT and DARK themes to match system appearance.
Sets `mutecipher-appearance-light-theme' and `mutecipher-appearance-dark-theme',
then syncs immediately."
  (setq mutecipher-appearance-light-theme light
        mutecipher-appearance-dark-theme  dark)
  (mutecipher/sync-appearance))

;;; Platform hooks

;; Ideal path on macOS: the NS layer notifies us directly when appearance changes.
(when (boundp 'ns-system-appearance-change-functions)
  (add-hook 'ns-system-appearance-change-functions #'mutecipher/apply-appearance))

;; Fallback: re-check when Emacs regains focus. Covers builds where the NS hook
;; doesn't fire, and serves as the only mechanism on non-macOS platforms.
(add-function :after after-focus-change-function
              (lambda ()
                (when (frame-focus-state)
                  (mutecipher/sync-appearance))))

(provide 'mutecipher-appearance)
;;; mutecipher-appearance.el ends here
