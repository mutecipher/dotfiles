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

;; Packages

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

(provide 'plugin)
