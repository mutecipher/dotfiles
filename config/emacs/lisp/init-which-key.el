(use-package which-key
  :diminish
  :custom
  (which-key-separator " ")
  (which-key-prefix-prefix "+")
  (which-key-show-early-on-C-h t)
  :config
  (which-key-mode))

(provide 'init-which-key)
