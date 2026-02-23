(menu-bar-mode 1)
(tool-bar-mode -1)
(tooltip-mode -1)
(scroll-bar-mode -1)

(setq modus-themes-italic-constructs t)

(add-hook 'package-menu-mode-hook #'hl-line-mode)

(global-prettify-symbols-mode 1)

(provide 'ui)
