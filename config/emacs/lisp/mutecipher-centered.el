;;; mutecipher-centered.el --- Centered Document Layout -*- lexical-binding: t; -*-

(use-package mutecipher-centered
  :ensure nil
  :no-require t
  :defer t
  :init
  (defvar mutecipher-center-document-desired-width 120
	"The desired width of a document centered in the window.")

  (defun mutecipher/center-document--adjust-margins ()
	(set-window-parameter nil 'min-margins nil)
	(set-window-margins nil nil)

	(when mutecipher/center-document-mode
	  (let ((margin-width (max 0
							   (truncate
								(/ (- (window-width)
									  mutecipher-center-document-desired-width)
								   2.0)))))
		(when (> margin-width 0)
		  (set-window-parameter nil 'min-margins '(0 . 0))
		  (set-window-margins nil margin-width margin-width)))))

  (define-minor-mode mutecipher/center-document-mode
	"Toggle a centered text layout in the current buffer."
	:lighter " Centered"
	:group 'editing
	(if mutecipher/center-document-mode
		(add-hook 'window-configuration-change-hook #'mutecipher/center-document--adjust-margins 'append 'local)
	  (remove-hook 'window-configuration-change-hook #'mutecipher/center-document--adjust-margins 'local))
	(mutecipher/center-document--adjust-margins))

  (add-hook 'org-mode-hook #'mutecipher/center-document-mode))

(provide 'mutecipher-centered)
