;; Configure package archives
(setq package-archives
      '(("gnu-elpa" . "https://elpa.gnu.org/packages/")
	("nongnu" . "https://elpa.gnu.org/nongnu/")
	("melpa" . "https://melpa.org/packages/")))

;; Highest number gets priority
(setq package-archive-priorities
      '(("gnu-elpa" . 3)
	("melpa" . 2)
	("nongnu" . 1)))

;; Help learning what key combos do
(use-package which-key
  :diminish
  :custom
  (which-key-separator " ")
  (which-key-prefix-prefix "+")
  (which-key-show-early-on-C-h t)
  :config
  (which-key-mode))

;; Don't litter `~/.config/emacs/` folder with files
(use-package no-littering
  :ensure t)

;; Make UI look cleaner
(use-package spacious-padding
  :ensure t)
(spacious-padding-mode 1)

;; Automatic light/dark themes
(use-package circadian
  :ensure t
  :config
  (setq calendar-latitude 51.050
        calendar-longitude -114.067)
  (setq circadian-themes '((:sunrise . modus-operandi)
                           (:sunset  . modus-vivendi)))
  (circadian-setup))

(setq monolisa-ligatures
      '(;; coding ligatures
        "<!---" "--->" "|||>" "<!--" "<|||" "<==>" "-->" "->>" "-<<" "..=" "!=="
        "#_(" "/==" "||>" "||=" "|->" "===" "==>" "=>>" "=<<" "=/=" ">->" ">=>"
        ">>-" ">>=" "<--" "<->" "<-<" "<||" "<|>" "<=" "<==" "<=>" "<=<" "<<-"
        "<<=" "<~>" "<~~" "~~>" ">&-" "<&-" "&>>" "&>" "->" "-<" "-~" ".=" "!="
        "#_" "/=" "|=" "|>" "==" "=>" ">-" ">=" "<-" "<|" "<~" "~-" "~@" "~="
        "~>" "~~"

        ;; whitespace ligatures
        "---" "'''" "\"\"\"" "..." "..<" "{|" "[|" ".?" "::" ":::" "::=" ":="
        ":>" ":<" "\;\;" "!!" "!!." "!!!"  "?." "?:" "??" "?=" "**" "***" "*>"
        "*/" "--" "#:" "#!" "#?" "##" "###" "####" "#=" "/*" "/>" "//" "/**"
        "///" "$(" ">&" "<&" "&&" "|}" "|]" "$>" ".." "++" "+++" "+>" "=:="
        "=!=" ">:" ">>" ">>>" "<:" "<*" "<*>" "<$" "<$>" "<+" "<+>" "<>" "<<"
        "<<<" "</" "</>" "^=" "%%"

	;; others
	"www"))

;; Font ligatures
(use-package ligature
  :ensure t
  :config
  (ligature-set-ligatures 't monolisa-ligatures)
  (global-ligature-mode t))

;; Markdown support
(use-package markdown-mode
  :ensure t)

(setq treesit-language-source-alist
   '((bash "https://github.com/tree-sitter/tree-sitter-bash")
     (cmake "https://github.com/uyha/tree-sitter-cmake")
     (css "https://github.com/tree-sitter/tree-sitter-css")
     (elisp "https://github.com/Wilfred/tree-sitter-elisp")
     (go "https://github.com/tree-sitter/tree-sitter-go")
     (html "https://github.com/tree-sitter/tree-sitter-html")
     (javascript "https://github.com/tree-sitter/tree-sitter-javascript" "master" "src")
     (json "https://github.com/tree-sitter/tree-sitter-json")
     (make "https://github.com/alemuller/tree-sitter-make")
     (markdown "https://github.com/ikatyang/tree-sitter-markdown")
     (python "https://github.com/tree-sitter/tree-sitter-python")
     (toml "https://github.com/tree-sitter/tree-sitter-toml")
     (tsx "https://github.com/tree-sitter/tree-sitter-typescript" "master" "tsx/src")
     (typescript "https://github.com/tree-sitter/tree-sitter-typescript" "master" "typescript/src")
     (yaml "https://github.com/ikatyang/tree-sitter-yaml")))


(mapc #'treesit-install-language-grammar (mapcar #'car treesit-language-source-alist))
(setq treesit-load-name-override-list '((js "libtree-sitter-js" "tree_sitter_javascript")))

(provide 'plugin)
