;;; mutecipher-blog.el --- Blog post creator  -*- lexical-binding: t -*-
;;
;; Interactive command that creates a dated Org file in
;; `mutecipher-blog-directory' and pre-fills its front-matter keywords.

;;; Code:

(require 'subr-x)

(defgroup mutecipher-blog nil
  "Blog post creation utilities."
  :group 'applications
  :prefix "mutecipher-blog-")

(defcustom mutecipher-blog-directory (expand-file-name "Documents/Blog/" (getenv "HOME"))
  "Directory where blog post Org files are stored."
  :type 'directory
  :group 'mutecipher-blog)

(defun mutecipher-blog--slugify (title)
  "Convert TITLE to a URL-safe slug."
  (thread-last title
    (downcase)
    (replace-regexp-in-string "[^a-z0-9]+" "-")
    (replace-regexp-in-string "^-\\|-$" "")))

;;;###autoload
(defun mutecipher/blog-new-post (title)
  "Create a new blog post Org file in `mutecipher-blog-directory'.
Prompts for TITLE (required) then all supported metadata fields.
If the computed filename already exists, opens it instead of prompting."
  (interactive "sBlog post title: ")
  (let* ((slug-derived (mutecipher-blog--slugify title))
         (date         (format-time-string "%Y-%m-%d"))
         (filename     (format "%s-%s.org" date slug-derived))
         (filepath     (expand-file-name filename mutecipher-blog-directory)))
    (if (file-exists-p filepath)
        (progn
          (find-file filepath)
          (message "Post already exists; opened %s" filename))
      (let* ((desc          (read-string "Description (optional): "))
             (tags-raw      (read-string "Tags, space-separated (optional): "))
             (tags          (unless (string-empty-p tags-raw)
                              (concat ":"
                                      (mapconcat #'identity (split-string tags-raw) ":")
                                      ":")))
             (image         (read-string "Hero image path or URL (optional): "))
             (image-alt     (unless (string-empty-p image)
                              (read-string "Hero image alt text (optional): ")))
             (slug-override (read-string (format "URL slug [%s]: " slug-derived)))
             (slug          (if (string-empty-p slug-override) slug-derived slug-override))
             (draft         (y-or-n-p "Save as draft? ")))
        (make-directory mutecipher-blog-directory t)
        (find-file filepath)
        (insert "#+TITLE:       " title "\n")
        (insert "#+DATE:        " date "\n")
        (insert "#+AUTHOR:      " (or user-full-name "") "\n")
        (insert "#+DESCRIPTION: " desc "\n")
        (insert "#+FILETAGS:    " (or tags "") "\n")
        (insert "#+IMAGE:       " image "\n")
        (insert "#+IMAGE_ALT:   " (or image-alt "") "\n")
        (insert "#+SLUG:        " slug "\n")
        (insert "#+DRAFT:       " (if draft "true" "false") "\n")
        (insert "\n")
        (save-buffer)))))

(provide 'mutecipher-blog)
;;; mutecipher-blog.el ends here
