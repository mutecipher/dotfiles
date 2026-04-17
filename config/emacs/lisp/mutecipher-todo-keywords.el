;;; mutecipher-todo-keywords.el --- Highlight TODO/FIXME/HACK/NOTE in comments  -*- lexical-binding: t -*-
;;
;; Adds font-lock rules for common comment keywords — TODO, FIXME, HACK,
;; XXX, NOTE, INFO — with faces themes can override.  Activate by adding
;; `mutecipher/highlight-todo-keywords' to `prog-mode-hook'.

;;; Code:

(defgroup mutecipher-todo-keywords nil
  "Font-lock highlighting for TODO/FIXME/HACK/NOTE comment keywords."
  :group 'faces)

(defface mutecipher-todo-keyword
  '((t :weight bold))
  "Face for high-priority keywords: TODO, FIXME."
  :group 'mutecipher-todo-keywords)

(defface mutecipher-hack-keyword
  '((t :weight bold))
  "Face for cautionary keywords: HACK, XXX."
  :group 'mutecipher-todo-keywords)

(defface mutecipher-note-keyword
  '((t :weight bold))
  "Face for informational keywords: NOTE, INFO."
  :group 'mutecipher-todo-keywords)

(defun mutecipher/highlight-todo-keywords ()
  "Add font-lock rules for TODO-style keywords."
  (font-lock-add-keywords
   nil
   '(("\\<\\(\\(?:FIXME\\|TODO\\)\\(?:(\\w+)\\)?\\):"  1 'mutecipher-todo-keyword prepend)
     ("\\<\\(\\(?:HACK\\|XXX\\)\\(?:(\\w+)\\)?\\):"    1 'mutecipher-hack-keyword  prepend)
     ("\\<\\(\\(?:NOTE\\|INFO\\)\\(?:(\\w+)\\)?\\):"   1 'mutecipher-note-keyword  prepend))
   t))

(provide 'mutecipher-todo-keywords)
;;; mutecipher-todo-keywords.el ends here
