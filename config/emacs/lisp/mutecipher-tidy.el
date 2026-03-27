;;; mutecipher-tidy.el --- Keep ~/.config/emacs clean  -*- lexical-binding: t -*-
;;
;; Redirects generated and volatile files out of the dotfiles directory,
;; following XDG Base Directory conventions.
;;
;; Load this early (before any package configuration) so that paths are
;; correct from the moment Emacs starts processing init.

(defvar mutecipher/cache-dir
  (expand-file-name "emacs/" (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Directory for volatile/ephemeral data (recentf, history, auto-saves, etc.).")

(defvar mutecipher/data-dir
  (expand-file-name "emacs/" (or (getenv "XDG_DATA_HOME") "~/.local/share/"))
  "Directory for persistent data (tree-sitter grammars, etc.).")

(dolist (dir (list mutecipher/cache-dir mutecipher/data-dir))
  (make-directory dir t))

;; Custom file — keep Emacs customize output out of dotfiles
(setq custom-file (expand-file-name "custom-vars.el" mutecipher/cache-dir))

;; Auto-saves
(make-directory (expand-file-name "auto-saves/" mutecipher/cache-dir) t)
(setq auto-save-list-file-prefix
      (expand-file-name "auto-saves/sessions" mutecipher/cache-dir)
      auto-save-file-name-transforms
      `((".*" ,(expand-file-name "auto-saves/" mutecipher/cache-dir) t)))

;; Persistence files
(setq recentf-save-file         (expand-file-name "recentf"           mutecipher/cache-dir)
      savehist-file             (expand-file-name "history"           mutecipher/cache-dir)
      save-place-file           (expand-file-name "saveplace"         mutecipher/cache-dir)
      project-list-file         (expand-file-name "projects"          mutecipher/cache-dir)
      ielm-history-file-name    (expand-file-name "ielm-history.eld"  mutecipher/cache-dir)
      url-configuration-directory (expand-file-name "url/"            mutecipher/cache-dir))

;; Transient
(setq transient-history-file (expand-file-name "transient/history.el" mutecipher/cache-dir)
      transient-levels-file  (expand-file-name "transient/levels.el"  mutecipher/cache-dir)
      transient-values-file  (expand-file-name "transient/values.el"  mutecipher/cache-dir))

;; Eshell
(setq eshell-directory-name (expand-file-name "eshell/" mutecipher/cache-dir))

;; Image-dired
(setq image-dired-dir (expand-file-name "image-dired/" mutecipher/cache-dir))

;; ERC logs
(setq erc-log-channels-directory (expand-file-name "erc/logs/" mutecipher/cache-dir))

;; Tree-sitter grammars
;; Deferred via `with-eval-after-load' because `treesit-extra-load-path' is
;; defined in treesit.el, which is not loaded at startup — `add-to-list' on an
;; unbound variable is a hard error.
(with-eval-after-load 'treesit
  (make-directory (expand-file-name "tree-sitter/" mutecipher/data-dir) t)
  (add-to-list 'treesit-extra-load-path (expand-file-name "tree-sitter/" mutecipher/data-dir)))

(provide 'mutecipher-tidy)
;;; mutecipher-tidy.el ends here
