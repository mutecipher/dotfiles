;;; liminal-light-theme.el --- Liminal light variant  -*- lexical-binding: t -*-

(deftheme liminal-light "Minimal warm light theme; the light half of liminal.")

(let ((bg       "#ffffff")
      (bg-sub   "#f5f5f7")
      (bg-hi    "#ebebef")
      (fg       "#000000")
      (fg-dim   "#545460")
      (fg-faint "#909090")
      (kw       "#0058a1")
      (str      "#ad1805")
      (fn       "#78492a")
      (ty       "#355d61")
      (bi       "#703daa")
      (co       "#9c2191")
      (cm       "#8a99a6")
      (err      "#ad1805")
      (wrn      "#78492a")
      (ok       "#355d61")
      (reg      "#b4d8fd")
      (search   "#f0d898")
      (lazy     "#eef6ff"))
  (custom-theme-set-faces
   'liminal-light
   ;; Core
   `(default                          ((t :background ,bg :foreground ,fg)))
   `(cursor                           ((t :background ,fg)))
   `(fringe                           ((t :background ,bg :foreground ,fg-faint)))
   `(vertical-border                  ((t :foreground ,bg-sub)))
   `(window-divider                   ((t :foreground ,bg-sub)))
   `(window-divider-first-pixel       ((t :foreground ,bg-sub)))
   `(window-divider-last-pixel        ((t :foreground ,bg-sub)))
   `(fill-column-indicator            ((t :foreground ,fg-faint)))
   `(shadow                           ((t :foreground ,fg-faint)))
   ;; Line numbers
   `(line-number                      ((t :background ,bg :foreground ,fg-faint)))
   `(line-number-current-line         ((t :background ,bg :foreground ,fg-dim :weight bold)))
   ;; Mode line
   `(mode-line                        ((t :background ,bg-hi :foreground ,fg-dim :box nil)))
   `(mode-line-inactive               ((t :background ,bg-sub :foreground ,fg-faint :box nil)))
   `(mode-line-buffer-id              ((t :foreground ,fg :weight bold)))
   `(header-line                      ((t :background ,bg-sub :foreground ,fg-dim :box nil)))
   ;; Minibuffer
   `(minibuffer-prompt                ((t :foreground ,kw :weight bold)))
   ;; Selection / highlight
   `(region                           ((t :background ,reg :extend t)))
   `(secondary-selection              ((t :background ,bg-hi :extend t)))
   `(highlight                        ((t :background ,bg-hi)))
   `(hl-line                          ((t :background ,bg-sub :extend t)))
   ;; Search
   `(isearch                          ((t :background ,search :foreground ,fg :weight bold)))
   `(isearch-fail                     ((t :background ,err :foreground ,bg)))
   `(lazy-highlight                   ((t :background ,lazy)))
   `(match                            ((t :background "#cce8f8" :foreground ,fg)))
   ;; Links
   `(link                             ((t :foreground ,kw :underline t)))
   `(link-visited                     ((t :foreground ,bi :underline t)))
   ;; Status
   `(error                            ((t :foreground ,err)))
   `(warning                          ((t :foreground ,wrn)))
   `(success                          ((t :foreground ,ok)))
   ;; Parens
   `(show-paren-match                 ((t :background ,bg-hi :foreground ,fn :weight bold)))
   `(show-paren-mismatch              ((t :background ,err :foreground ,bg)))
   ;; Completions
   `(completions-common-part          ((t :foreground ,kw)))
   `(completions-first-difference     ((t :foreground ,fn :weight bold)))
   ;; Font lock
   `(font-lock-builtin-face           ((t :foreground ,bi)))
   `(font-lock-comment-face           ((t :foreground ,cm :slant italic)))
   `(font-lock-comment-delimiter-face ((t :foreground ,cm :slant italic)))
   `(font-lock-constant-face          ((t :foreground ,co)))
   `(font-lock-doc-face               ((t :foreground ,cm :slant italic)))
   `(font-lock-function-name-face     ((t :foreground ,fn)))
   `(font-lock-keyword-face           ((t :foreground ,kw)))
   `(font-lock-negation-char-face     ((t :foreground ,err)))
   `(font-lock-preprocessor-face      ((t :foreground ,bi)))
   `(font-lock-string-face            ((t :foreground ,str)))
   `(font-lock-type-face              ((t :foreground ,ty)))
   `(font-lock-variable-name-face     ((t :foreground ,fg)))
   `(font-lock-warning-face           ((t :foreground ,wrn :weight bold)))
   ;; Flymake
   `(flymake-error                    ((t :underline (:style wave :color ,err))))
   `(flymake-warning                  ((t :underline (:style wave :color ,wrn))))
   `(flymake-note                     ((t :underline (:style wave :color ,ok))))
   ;; Compilation
   `(compilation-error                ((t :foreground ,err)))
   `(compilation-warning              ((t :foreground ,wrn)))
   `(compilation-info                 ((t :foreground ,ok)))
   ;; TODO keywords
   `(mutecipher-todo-keyword          ((t :background "#dceeff" :foreground "#003a70" :weight bold)))
   `(mutecipher-hack-keyword          ((t :background "#ecdcf4" :foreground "#4a1070" :weight bold)))
   `(mutecipher-note-keyword          ((t :background "#d0ecee" :foreground "#1a3d40" :weight bold)))
   ;; Icon colors
   `(mutecipher-icon-red              ((t :foreground ,co)))
   `(mutecipher-icon-yellow           ((t :foreground "#907020")))
   `(mutecipher-icon-blue             ((t :foreground ,kw)))
   `(mutecipher-icon-cyan             ((t :foreground "#0058a1")))
   `(mutecipher-icon-green            ((t :foreground ,str)))
   `(mutecipher-icon-purple           ((t :foreground ,bi)))
   `(mutecipher-icon-orange           ((t :foreground ,ty)))
   `(mutecipher-icon-dim              ((t :foreground ,fg-faint)))
   ;; Markdown
   `(mutecipher-markdown-code-block  ((t :background ,bg-sub :extend t)))
   `(mutecipher-markdown-inline-code ((t :background ,bg-sub)))
   `(mutecipher-markdown-table       ((t :foreground ,fg-dim)))))

(provide-theme 'liminal-light)
;;; liminal-light-theme.el ends here
