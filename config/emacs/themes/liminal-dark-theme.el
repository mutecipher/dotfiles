;;; liminal-dark-theme.el --- Liminal dark variant  -*- lexical-binding: t -*-

(deftheme liminal-dark "Minimal warm dark theme; the dark half of liminal.")

(let ((bg       "#1a1918")
	  (bg-sub   "#232120")
	  (bg-hi    "#2d2b28")
	  (fg       "#ddd8cf")
	  (fg-dim   "#7d7468")
	  (fg-faint "#4e4840")
	  (kw       "#7db5d0")
	  (str      "#90b57a")
	  (fn       "#d3b57a")
	  (ty       "#c4906a")
	  (bi       "#a893c2")
	  (co       "#c88888")
	  (cm       "#685e54")
	  (err      "#be6e6e")
	  (wrn      "#c09e5a")
	  (ok       "#76a874")
	  (reg      "#38322c")
	  (search   "#584828")
	  (lazy     "#34302a"))
  (custom-theme-set-faces
   'liminal-dark
   ;; Core
   `(default                          ((t :background ,bg :foreground ,fg)))
   `(cursor                           ((t :background ,fg)))
   `(fringe                           ((t :background ,bg :foreground ,fg-faint)))
   `(vertical-border                  ((t :foreground ,bg-sub)))
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
   `(match                            ((t :background "#344030" :foreground ,fg)))
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
   `(mutecipher-todo-keyword          ((t :background "#4a3810" :foreground "#e8c060" :weight bold)))
   `(mutecipher-hack-keyword          ((t :background "#26204a" :foreground "#b0a0e0" :weight bold)))
   `(mutecipher-note-keyword          ((t :background "#183020" :foreground "#80c890" :weight bold)))
   ;; Icon colors
   `(mutecipher-icon-red              ((t :foreground ,co)))
   `(mutecipher-icon-yellow           ((t :foreground "#d0b060")))
   `(mutecipher-icon-blue             ((t :foreground ,kw)))
   `(mutecipher-icon-cyan             ((t :foreground "#70c0c0")))
   `(mutecipher-icon-green            ((t :foreground ,str)))
   `(mutecipher-icon-purple           ((t :foreground ,bi)))
   `(mutecipher-icon-orange           ((t :foreground ,ty)))
   `(mutecipher-icon-dim              ((t :foreground ,fg-faint)))))

(provide-theme 'liminal-dark)
;;; liminal-dark-theme.el ends here
