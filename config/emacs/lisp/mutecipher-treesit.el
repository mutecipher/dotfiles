;;; mutecipher-treesit.el --- Tree-sitter grammar installer  -*- lexical-binding: t -*-
;;
;; One-shot installer for tree-sitter grammars declared in
;; `treesit-language-source-alist'.  Handles the Emacs 29 vs 30 API shift
;; and installs under `mutecipher/data-dir'.

;;; Code:

(require 'treesit)
(require 'mutecipher-tidy)

;;;###autoload
(defun mutecipher/treesit-install-all-grammars ()
  "Install any missing grammars declared in `treesit-language-source-alist'.
Grammars are placed under `mutecipher/data-dir'."
  (interactive)
  (let ((out-dir (expand-file-name "tree-sitter/" mutecipher/data-dir)))
    (make-directory out-dir t)
    (dolist (lang (mapcar #'car treesit-language-source-alist))
      (if (treesit-language-available-p lang)
          (message "Tree-sitter: %s already installed, skipping" lang)
        ;; Emacs 30+ accepts an explicit out-dir argument; Emacs 29 does not.
        (if (>= emacs-major-version 30)
            (treesit-install-language-grammar lang out-dir)
          (let ((user-emacs-directory mutecipher/data-dir))
            (treesit-install-language-grammar lang)))))
    (message "Tree-sitter grammars installed to %s" out-dir)))

(provide 'mutecipher-treesit)
;;; mutecipher-treesit.el ends here
