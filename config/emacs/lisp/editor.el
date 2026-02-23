;; Unicode all the things
(set-default-coding-systems 'utf-8)
(prefer-coding-system 'utf-8)

;; Highlight current line
(global-hl-line-mode 1)

;; Display line numbers in buffers
(add-hook 'prog-mode-hook 'display-line-numbers-mode)

;; (global-completion-preview-mode 1)
;; (fido-mode 1)
(fido-vertical-mode 1)
(setf completion-styles '(basic flex partial-completion)
      completion-auto-select t
      completion-auto-help 'visible
      completions-format 'one-column
      completions-sort 'historical
      completions-max-height 20
      completions-ignore-case t)

(provide 'editor)
