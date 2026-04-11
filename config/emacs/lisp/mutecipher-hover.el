;;; mutecipher-hover.el --- Eglot hover popup with markdown rendering  -*- lexical-binding: t -*-
;;
;; Provides `mutecipher/hover', an interactive command that sends a
;; textDocument/hover LSP request via Eglot and renders the response in a
;; small popup window at the bottom of the frame.  Markdown is fontified
;; using the same keywords as `mutecipher-markdown-mode' so the popup looks
;; visually consistent with .md files.
;;
;; No external dependencies — only built-in Emacs packages and
;; mutecipher-markdown (which must be loaded first).

;;; Code:

(require 'eglot)
(require 'mutecipher-markdown)

;;;; Buffer

(defconst mutecipher-hover--buffer-name "*mutecipher-hover*"
  "Name of the dedicated hover popup buffer.")

(defun mutecipher-hover--get-or-create-buffer ()
  "Return the hover buffer, creating it if necessary."
  (get-buffer-create mutecipher-hover--buffer-name))

;;;; Markdown font-lock keywords

(defconst mutecipher-hover--keywords
  ;; Reuse the markdown keywords wholesale but drop the two GFM table rules —
  ;; LSP hover content never contains tables, and the overlay-based table
  ;; renderer is not set up in the popup mode.
  (seq-remove (lambda (kw)
                (and (stringp (car kw))
                     (string-match-p "^\\^|" (car kw))))
              mutecipher-markdown--keywords)
  "Font-lock keywords for `mutecipher-hover-mode'.")

;;;; Major mode

(define-derived-mode mutecipher-hover-mode special-mode "Hover"
  "Major mode for the Eglot hover popup buffer.
Derived from `special-mode', so the buffer is read-only and `q' quits."
  (setq-local font-lock-extra-managed-props '(display invisible))
  (setq-local font-lock-multiline t)
  (add-hook 'font-lock-extend-region-functions
            #'mutecipher-markdown--extend-region nil t)
  (font-lock-add-keywords nil mutecipher-hover--keywords t)
  (setq-local mode-line-format nil)
  (setq-local header-line-format
              (propertize "  LSP Hover    [q] close" 'face 'bold))
  (visual-line-mode 1)
  (font-lock-mode 1))

(define-key mutecipher-hover-mode-map (kbd "<escape>") #'quit-window)

;;;; Rendering

(defun mutecipher-hover--render (buf text)
  "Erase BUF, insert TEXT, activate `mutecipher-hover-mode', and fontify."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text)
      ;; Ensure there is a trailing newline so the last line is fontified.
      (unless (bolp) (insert "\n")))
    (mutecipher-hover-mode)
    (font-lock-ensure)
    (goto-char (point-min))))

;;;; Window display

(defun mutecipher-hover--display-buffer (buf)
  "Display BUF in a bottom popup window, sized to content, and focus it."
  (let ((win (display-buffer
              buf
              '((display-buffer-reuse-window
                 display-buffer-at-bottom)
                (window-height . 0.25)
                (dedicated . t)))))
    (when win
      (set-window-dedicated-p win t)
      (fit-window-to-buffer win (floor (frame-height) 3) 5 nil nil t)
      (select-window win))
    win))

;;;; LSP hover request helpers

(defun mutecipher-hover--extract-text (contents)
  "Extract a markdown string from LSP Hover CONTENTS.
Handles both the deprecated MarkedString vector form and the current
MarkupContent plist form.  This is a fallback for when `eglot--hover-info'
is unavailable."
  (cond
   ((stringp contents) contents)
   ((vectorp contents)
    (mapconcat (lambda (c)
                 (cond
                  ((stringp c) c)
                  ((plist-get c :language)
                   (format "```%s\n%s\n```"
                           (plist-get c :language)
                           (plist-get c :value)))
                  (t (or (plist-get c :value) ""))))
               contents "\n\n"))
   ((plist-get contents :value)
    (plist-get contents :value))
   (t "")))

(defun mutecipher-hover--hover-text (contents range)
  "Return a rendered string for CONTENTS and RANGE from a hover response."
  (if (fboundp 'eglot--hover-info)
      (eglot--hover-info contents range)
    (mutecipher-hover--extract-text contents)))

;;;; Interactive command

;;;###autoload
(defun mutecipher/hover ()
  "Show Eglot hover information for the symbol at point in a popup window."
  (interactive)
  (let ((server (eglot--current-server-or-lose))
        (buf (current-buffer)))
    (unless (eglot-server-capable :hoverProvider)
      (user-error "LSP server does not support hover"))
    (jsonrpc-async-request
     server
     :textDocument/hover
     (eglot--TextDocumentPositionParams)
     :success-fn
     (lambda (result)
       (when (buffer-live-p buf)
         (let* ((contents (plist-get result :contents))
                (range    (plist-get result :range))
                (text     (if (or (null contents)
                                  (and (sequencep contents)
                                       (seq-empty-p contents)))
                              nil
                            (mutecipher-hover--hover-text contents range))))
           (if (or (null text) (string-empty-p (string-trim text)))
               (message "Hover: no information at point")
             (let ((hbuf (mutecipher-hover--get-or-create-buffer)))
               (mutecipher-hover--render hbuf text)
               (mutecipher-hover--display-buffer hbuf))))))
     :error-fn
     (lambda (_err)
       (message "Hover: request failed")))))

(provide 'mutecipher-hover)
;;; mutecipher-hover.el ends here
