;;; mutecipher-icons.el --- Nerd Font icon support  -*- lexical-binding: t -*-
;;
;; Maps file extensions and major modes to colored Nerd Font glyphs using
;; Symbols Nerd Font Mono (the symbols-only variant — no text glyphs).
;;
;; Call (mutecipher/buffer-icon) to get a propertized icon string for the
;; current buffer. The fontset is configured automatically when this module
;; is loaded.
;;
;; Icon colors are controlled by the mutecipher-icon-* faces below; both
;; liminal theme variants override these with palette-matched values.

;;; Fontset registration
;;
;; On macOS, Hoefler Text carries Apple-private glyphs across several
;; PUA codepoints that overlap the Nerd Font ranges (e.g. U+F075 — FA
;; comment — renders as an Hoefler moon ornament).  Core Text resolves
;; symbol codepoints through the current face's font first, and even
;; after `use-default-font-for-symbols' is flipped, a `'prepend'
;; registration leaves Hoefler in the fallback chain where it can
;; still win via font-coverage checks.
;;
;; The reliable fix on macOS is three things together:
;;   1. `use-default-font-for-symbols nil'
;;   2. REPLACE (no `'prepend') so our font becomes the sole resolver
;;      for each PUA range — drops any system/default font that may
;;      have claimed coverage
;;   3. Clear the face cache so existing frames re-resolve

(setq use-default-font-for-symbols nil)

(defconst mutecipher-icons--nf-pua-ranges
  '((#xe000 . #xe00f)    ; Pomicons
    (#xe200 . #xe2af)    ; Font Awesome Extension
    (#xe300 . #xe3ff)    ; Weather Icons
    (#xe5fa . #xe6b5)    ; Seti-UI + Custom
    (#xe700 . #xe7c5)    ; Devicons
    (#xe900 . #xe9ff)    ; NF Custom / Extra
    (#xea60 . #xebeb)    ; Codicons
    (#xf000 . #xf2ff)    ; Font Awesome
    (#xf300 . #xf375)    ; Font Logos
    (#xf400 . #xf533)    ; Octicons
    (#xe0a0 . #xe0d7)    ; Powerline Extra
    (#xf0000 . #xfffff)) ; Nerd Fonts v3 Material Design supplementary PUA
  "Private-Use Area ranges covered by Symbols Nerd Font Mono.")

(defun mutecipher-icons--setup-fontset ()
  "Install Nerd Font coverage as the sole resolver for NF PUA ranges.

Registers two fonts per range: `Symbols Nerd Font Mono' (primary) and
`Symbols Nerd Font' (proportional fallback).  The Mono variant is
strict monospace and subsets its glyphs — codicons (`nf-cod-*') and
devicons (`nf-dev-*') live only in the proportional variant, so the
fallback is required for full coverage.  Replaces (not prepends) so
macOS system fonts can't win character-coverage battles in the
fallback chain.  Clears the face cache so already-displayed frames
re-resolve."
  (let* ((families (font-family-list))
         (mono (and (member "Symbols Nerd Font Mono" families)
                    (font-spec :family "Symbols Nerd Font Mono")))
         (prop (and (member "Symbols Nerd Font" families)
                    (font-spec :family "Symbols Nerd Font"))))
    (cond
     ((and mono prop)
      (dolist (range mutecipher-icons--nf-pua-ranges)
        ;; Mono first — use it for codepoints it covers
        (set-fontset-font t range mono)
        ;; Proportional fills the gaps (codicons, devicons)
        (set-fontset-font t range prop nil 'append)))
     ((or mono prop)
      (let ((only (or mono prop)))
        (dolist (range mutecipher-icons--nf-pua-ranges)
          (set-fontset-font t range only))))
     (t
      (message "mutecipher-icons: no Symbols Nerd Font variant installed"))))
  (when (fboundp 'clear-face-cache)
    (clear-face-cache)))

(mutecipher-icons--setup-fontset)

;;; Icon color faces
;;
;; Defaults use the liminal-light palette; both theme variants override these.

(defface mutecipher-icon-red
  '((t :foreground "#a03030"))
  "Icon face: red — Ruby, YAML, Git.")

(defface mutecipher-icon-yellow
  '((t :foreground "#907020"))
  "Icon face: yellow — JavaScript, JSON, folders.")

(defface mutecipher-icon-blue
  '((t :foreground "#2b68a8"))
  "Icon face: blue — TypeScript, CSS, Python, Docker, Markdown.")

(defface mutecipher-icon-cyan
  '((t :foreground "#287880"))
  "Icon face: cyan — React/TSX, Go.")

(defface mutecipher-icon-green
  '((t :foreground "#3a7030"))
  "Icon face: green — Shell, Org.")

(defface mutecipher-icon-purple
  '((t :foreground "#564898"))
  "Icon face: purple — Emacs Lisp.")

(defface mutecipher-icon-orange
  '((t :foreground "#884820"))
  "Icon face: orange — HTML, Rust, TOML, Makefile.")

(defface mutecipher-icon-dim
  '((t :foreground "#9e9285"))
  "Icon face: dim — generic file and lock icons.")

;;; Icon alists
;;
;; Each value is (ICON-STRING . FACE-SYMBOL).

(defvar mutecipher-icons-extension-alist
  '(;; Ruby
    ("rb"      . ("" . mutecipher-icon-red))     ; nf-dev-ruby
    ("rake"    . ("" . mutecipher-icon-red))
    ("gemspec" . ("" . mutecipher-icon-red))
    ;; JavaScript
    ("js"      . ("" . mutecipher-icon-yellow))  ; nf-dev-javascript
    ("mjs"     . ("" . mutecipher-icon-yellow))
    ("cjs"     . ("" . mutecipher-icon-yellow))
    ("jsx"     . ("" . mutecipher-icon-cyan))    ; nf-dev-react
    ;; TypeScript
    ("ts"      . ("" . mutecipher-icon-blue))    ; nf-seti-typescript
    ("tsx"     . ("" . mutecipher-icon-cyan))    ; nf-dev-react
    ;; Web
    ("css"     . ("" . mutecipher-icon-blue))    ; nf-dev-css3
    ("scss"    . ("" . mutecipher-icon-blue))
    ("html"    . ("" . mutecipher-icon-orange))  ; nf-dev-html5
    ("htm"     . ("" . mutecipher-icon-orange))
    ;; Data / Config
    ("json"    . ("" . mutecipher-icon-yellow))  ; nf-seti-json
    ("yaml"    . ("" . mutecipher-icon-red))     ; nf-seti-yaml
    ("yml"     . ("" . mutecipher-icon-red))
    ("toml"    . ("" . mutecipher-icon-orange))  ; nf-seti-config
    ;; Shell
    ("sh"      . ("" . mutecipher-icon-green))   ; nf-dev-terminal
    ("bash"    . ("" . mutecipher-icon-green))
    ("zsh"     . ("" . mutecipher-icon-green))
    ;; Lisp family
    ("el"      . ("\U000f0627" . mutecipher-icon-purple))  ; nf-md-lambda
    ("elc"     . ("\U000f0627" . mutecipher-icon-purple))
    ("lisp"    . ("\U000f0627" . mutecipher-icon-purple))
    ("lsp"     . ("\U000f0627" . mutecipher-icon-purple))
    ("cl"      . ("\U000f0627" . mutecipher-icon-purple))
    ("fasl"    . ("\U000f0627" . mutecipher-icon-purple))
    ("scm"     . ("\U000f0627" . mutecipher-icon-purple))
    ("ss"      . ("\U000f0627" . mutecipher-icon-purple))
    ;; Markup / Docs
    ("md"      . ("" . mutecipher-icon-blue))    ; nf-dev-markdown
    ("org"     . ("" . mutecipher-icon-green))   ; nf-fa-book
    ;; Systems
    ("py"      . ("" . mutecipher-icon-blue))    ; nf-dev-python
    ("rs"      . ("" . mutecipher-icon-orange))  ; nf-dev-rust
    ("go"      . ("" . mutecipher-icon-cyan))    ; nf-dev-go
    ;; Misc
    ("lock"    . ("" . mutecipher-icon-dim)))    ; nf-fa-lock
  "Map file extensions to (ICON . FACE) pairs.")

(defvar mutecipher-icons-filename-alist
  '(("Dockerfile"         . ("" . mutecipher-icon-blue))    ; nf-dev-docker
    ("docker-compose.yml" . ("" . mutecipher-icon-blue))
    (".gitconfig"         . ("" . mutecipher-icon-red))      ; nf-dev-git
    (".gitignore"         . ("" . mutecipher-icon-red))
    (".gitmodules"        . ("" . mutecipher-icon-red))
    ("Gemfile"            . ("" . mutecipher-icon-red))      ; nf-dev-ruby
    ("Rakefile"           . ("" . mutecipher-icon-red))
    ("Makefile"           . ("" . mutecipher-icon-orange))   ; nf-fa-cogs
    (".env"               . ("" . mutecipher-icon-dim)))     ; nf-fa-user_secret
  "Map specific filenames to (ICON . FACE) pairs.")

(defvar mutecipher-icons-mode-alist
  '((ruby-ts-mode          . ("" . mutecipher-icon-red))     ; nf-dev-ruby
    (ruby-mode             . ("" . mutecipher-icon-red))
    (js-ts-mode            . ("" . mutecipher-icon-yellow))  ; nf-dev-javascript
    (js-mode               . ("" . mutecipher-icon-yellow))
    (typescript-ts-mode    . ("" . mutecipher-icon-blue))    ; nf-seti-typescript
    (tsx-ts-mode           . ("" . mutecipher-icon-cyan))    ; nf-dev-react
    (css-ts-mode           . ("" . mutecipher-icon-blue))    ; nf-dev-css3
    (css-mode              . ("" . mutecipher-icon-blue))
    (html-mode             . ("" . mutecipher-icon-orange))  ; nf-dev-html5
    (yaml-ts-mode          . ("" . mutecipher-icon-red))     ; nf-seti-yaml
    (yaml-mode             . ("" . mutecipher-icon-red))
    (bash-ts-mode          . ("" . mutecipher-icon-green))   ; nf-dev-terminal
    (sh-mode               . ("" . mutecipher-icon-green))
    (dockerfile-ts-mode    . ("" . mutecipher-icon-blue))    ; nf-dev-docker
    (python-ts-mode        . ("" . mutecipher-icon-blue))    ; nf-dev-python
    (python-mode           . ("" . mutecipher-icon-blue))
    (rust-ts-mode          . ("" . mutecipher-icon-orange))  ; nf-dev-rust
    (go-ts-mode            . ("" . mutecipher-icon-cyan))    ; nf-dev-go
    (markdown-ts-mode      . ("" . mutecipher-icon-blue))    ; nf-dev-markdown
    (markdown-mode         . ("" . mutecipher-icon-blue))
    (org-mode              . ("" . mutecipher-icon-green))   ; nf-fa-book
    (emacs-lisp-mode       . ("\U000f0627" . mutecipher-icon-purple))  ; nf-md-lambda
    (lisp-interaction-mode . ("\U000f0627" . mutecipher-icon-purple))
    (lisp-mode             . ("\U000f0627" . mutecipher-icon-purple))
    (scheme-mode           . ("\U000f0627" . mutecipher-icon-purple))
    (dired-mode            . ("" . mutecipher-icon-yellow))  ; nf-fa-folder_open
    (ibuffer-mode          . ("" . mutecipher-icon-dim))     ; nf-fa-list
    (erc-mode              . ("" . mutecipher-icon-blue))    ; nf-fa-comments
    (text-mode             . ("" . mutecipher-icon-dim)))    ; nf-fa-file_text
  "Map major modes to (ICON . FACE) pairs.")

(defvar mutecipher-icons-default '("" . mutecipher-icon-dim)  ; nf-fa-file
  "Fallback (ICON . FACE) for buffers with no specific mapping.")

;;; Lookup API

(defun mutecipher--icon-propertize (pair)
  "Return PAIR's icon string propertized with its face."
  (propertize (car pair) 'face (cdr pair)))

(defun mutecipher/icon-for-file (filename)
  "Return a propertized Nerd Font icon string for FILENAME, or nil."
  (when filename
    (let* ((base (file-name-nondirectory filename))
           (ext  (file-name-extension base))
           (pair (or (cdr (assoc base mutecipher-icons-filename-alist))
                     (and ext (cdr (assoc (downcase ext)
                                          mutecipher-icons-extension-alist))))))
      (when pair (mutecipher--icon-propertize pair)))))

(defun mutecipher/icon-for-mode (mode)
  "Return a propertized Nerd Font icon string for major MODE symbol, or nil."
  (let ((pair (cdr (assq mode mutecipher-icons-mode-alist))))
    (when pair (mutecipher--icon-propertize pair))))

(defun mutecipher/buffer-icon ()
  "Return the propertized Nerd Font icon string for the current buffer."
  (or (mutecipher/icon-for-file buffer-file-name)
      (mutecipher/icon-for-mode major-mode)
      (mutecipher--icon-propertize mutecipher-icons-default)))

;;; ACP glyphs
;;
;; Icon set used by `mutecipher-acp2' to decorate message roles,
;; tool-call kinds, completion statuses, and disclosure triangles.
;; Role and tool-kind icons use the palette faces for visual variety;
;; status icons use built-in semantic faces (success/warning/error/
;; shadow) so themes color them correctly by meaning — a "done" check
;; is always green-ish, an error x is always red-ish, regardless of
;; how a theme paints the file-kind palette.

(defvar mutecipher-icons-acp-alist
  `(;; Message roles
    (user            . (,(string #xf0004) . mutecipher-icon-cyan))    ; nf-md-account
    (assistant       . (,(string #xf0b79) . mutecipher-icon-purple))  ; nf-md-chat
    (thought         . (,(string #xf0335) . shadow))                  ; nf-md-lightbulb
    (notice          . (,(string #xf02fd) . shadow))                  ; nf-md-information
    ;; Tool-call kinds
    (tool-edit       . (,(string #xf03eb) . mutecipher-icon-orange))  ; nf-md-pencil
    (tool-write      . (,(string #xf03eb) . mutecipher-icon-orange))
    (tool-bash       . (,(string #xf018d) . mutecipher-icon-green))   ; nf-md-console
    (tool-read       . (,(string #xf0214) . mutecipher-icon-blue))    ; nf-md-file
    (tool-grep       . (,(string #xf0349) . mutecipher-icon-blue))    ; nf-md-magnify
    (tool-other      . (,(string #xf0842) . shadow))                  ; nf-md-wrench
    ;; Tool statuses — semantic faces
    (status-pending  . (,(string #xf0130) . shadow))                  ; nf-md-circle-outline
    (status-running  . (,(string #xf0453) . warning))                 ; nf-md-sync
    (status-done     . (,(string #xf012c) . success))                 ; nf-md-check
    (status-error    . (,(string #xf0156) . error))                   ; nf-md-close
    ;; Plan entry statuses — same semantic treatment
    (plan-pending    . (,(string #xf0130) . shadow))                  ; nf-md-circle-outline
    (plan-inprogress . (,(string #xf0150) . warning))                 ; nf-md-clock
    (plan-done       . (,(string #xf012c) . success))                 ; nf-md-check
    ;; Disclosure triangles
    (disclosure-collapsed . (,(string #xf0142) . shadow))             ; nf-md-chevron-right
    (disclosure-expanded  . (,(string #xf0140) . shadow))             ; nf-md-chevron-down
    ;; Turn indicators (status of the turn as a whole)
    (turn-running    . (,(string #xf0453) . warning))                 ; nf-md-sync
    (turn-done       . (,(string #xf012c) . success))                 ; nf-md-check
    (turn-error      . (,(string #xf0156) . error))                   ; nf-md-close
    (turn-cancelled  . (,(string #xf0376) . shadow)))                 ; nf-md-minus-circle
  "Map ACP kind symbols to (ICON . FACE) pairs.
All icons drawn from the Material Design family (nf-md-*) in the
U+F0000+ supplementary PUA range, so they render consistently out of
`Symbols Nerd Font' (the proportional variant).  Role and tool-kind
icons use the palette faces so kinds stay visually distinct; status
icons use built-in semantic faces (success/warning/error/shadow) so
themes color them correctly by meaning.")

(defun mutecipher/icon-for-acp (kind)
  "Return a propertized Nerd Font icon string for the ACP KIND symbol, or nil."
  (when-let ((pair (cdr (assq kind mutecipher-icons-acp-alist))))
    (mutecipher--icon-propertize pair)))

(provide 'mutecipher-icons)
;;; mutecipher-icons.el ends here
