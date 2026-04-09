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

(defun mutecipher-icons--setup-fontset ()
  "Register Symbols Nerd Font Mono for all NF private-use ranges."
  (dolist (range '((#xe000 . #xe00f)    ; Pomicons
                   (#xe200 . #xe2af)    ; Font Awesome Extension
                   (#xe300 . #xe3ff)    ; Weather Icons
                   (#xe5fa . #xe6b5)    ; Seti-UI + Custom
                   (#xe700 . #xe7c5)    ; Devicons
                   (#xe900 . #xe9ff)    ; NF Custom / Extra
                   (#xea60 . #xebeb)    ; Codicons
                   (#xf000 . #xf2ff)    ; Font Awesome
                   (#xf300 . #xf375)    ; Font Logos
                   (#xf400 . #xf533)    ; Octicons
                   (#xe0a0 . #xe0d7)))  ; Powerline Extra (extends existing)
    (set-fontset-font t range
                      (font-spec :family "Symbols Nerd Font Mono")
                      nil 'prepend)))

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
    ("rb"      . ("\ue739" . mutecipher-icon-red))     ; nf-dev-ruby
    ("rake"    . ("\ue739" . mutecipher-icon-red))
    ("gemspec" . ("\ue739" . mutecipher-icon-red))
    ;; JavaScript
    ("js"      . ("\ue74e" . mutecipher-icon-yellow))  ; nf-dev-javascript
    ("mjs"     . ("\ue74e" . mutecipher-icon-yellow))
    ("cjs"     . ("\ue74e" . mutecipher-icon-yellow))
    ("jsx"     . ("\ue7ba" . mutecipher-icon-cyan))    ; nf-dev-react
    ;; TypeScript
    ("ts"      . ("\ue628" . mutecipher-icon-blue))    ; nf-seti-typescript
    ("tsx"     . ("\ue7ba" . mutecipher-icon-cyan))    ; nf-dev-react
    ;; Web
    ("css"     . ("\ue749" . mutecipher-icon-blue))    ; nf-dev-css3
    ("scss"    . ("\ue749" . mutecipher-icon-blue))
    ("html"    . ("\ue736" . mutecipher-icon-orange))  ; nf-dev-html5
    ("htm"     . ("\ue736" . mutecipher-icon-orange))
    ;; Data / Config
    ("json"    . ("\ue60b" . mutecipher-icon-yellow))  ; nf-seti-json
    ("yaml"    . ("\ue6a8" . mutecipher-icon-red))     ; nf-seti-yaml
    ("yml"     . ("\ue6a8" . mutecipher-icon-red))
    ("toml"    . ("\ue6b2" . mutecipher-icon-orange))  ; nf-seti-config
    ;; Shell
    ("sh"      . ("\ue795" . mutecipher-icon-green))   ; nf-dev-terminal
    ("bash"    . ("\ue795" . mutecipher-icon-green))
    ("zsh"     . ("\ue795" . mutecipher-icon-green))
    ;; Emacs Lisp
    ("el"      . ("\uf121" . mutecipher-icon-purple))  ; nf-fa-code
    ("elc"     . ("\uf121" . mutecipher-icon-purple))
    ;; Markup / Docs
    ("md"      . ("\ue73e" . mutecipher-icon-blue))    ; nf-dev-markdown
    ("org"     . ("\uf02d" . mutecipher-icon-green))   ; nf-fa-book
    ;; Systems
    ("py"      . ("\ue73c" . mutecipher-icon-blue))    ; nf-dev-python
    ("rs"      . ("\ue7a8" . mutecipher-icon-orange))  ; nf-dev-rust
    ("go"      . ("\ue724" . mutecipher-icon-cyan))    ; nf-dev-go
    ;; Misc
    ("lock"    . ("\uf023" . mutecipher-icon-dim)))    ; nf-fa-lock
  "Map file extensions to (ICON . FACE) pairs.")

(defvar mutecipher-icons-filename-alist
  '(("Dockerfile"         . ("\ue7b0" . mutecipher-icon-blue))    ; nf-dev-docker
    ("docker-compose.yml" . ("\ue7b0" . mutecipher-icon-blue))
    (".gitconfig"         . ("\ue702" . mutecipher-icon-red))      ; nf-dev-git
    (".gitignore"         . ("\ue702" . mutecipher-icon-red))
    (".gitmodules"        . ("\ue702" . mutecipher-icon-red))
    ("Gemfile"            . ("\ue739" . mutecipher-icon-red))      ; nf-dev-ruby
    ("Rakefile"           . ("\ue739" . mutecipher-icon-red))
    ("Makefile"           . ("\uf085" . mutecipher-icon-orange))   ; nf-fa-cogs
    (".env"               . ("\uf462" . mutecipher-icon-dim)))     ; nf-fa-user_secret
  "Map specific filenames to (ICON . FACE) pairs.")

(defvar mutecipher-icons-mode-alist
  '((ruby-ts-mode          . ("\ue739" . mutecipher-icon-red))     ; nf-dev-ruby
    (ruby-mode             . ("\ue739" . mutecipher-icon-red))
    (js-ts-mode            . ("\ue74e" . mutecipher-icon-yellow))  ; nf-dev-javascript
    (js-mode               . ("\ue74e" . mutecipher-icon-yellow))
    (typescript-ts-mode    . ("\ue628" . mutecipher-icon-blue))    ; nf-seti-typescript
    (tsx-ts-mode           . ("\ue7ba" . mutecipher-icon-cyan))    ; nf-dev-react
    (css-ts-mode           . ("\ue749" . mutecipher-icon-blue))    ; nf-dev-css3
    (css-mode              . ("\ue749" . mutecipher-icon-blue))
    (html-mode             . ("\ue736" . mutecipher-icon-orange))  ; nf-dev-html5
    (yaml-ts-mode          . ("\ue6a8" . mutecipher-icon-red))     ; nf-seti-yaml
    (yaml-mode             . ("\ue6a8" . mutecipher-icon-red))
    (bash-ts-mode          . ("\ue795" . mutecipher-icon-green))   ; nf-dev-terminal
    (sh-mode               . ("\ue795" . mutecipher-icon-green))
    (dockerfile-ts-mode    . ("\ue7b0" . mutecipher-icon-blue))    ; nf-dev-docker
    (python-ts-mode        . ("\ue73c" . mutecipher-icon-blue))    ; nf-dev-python
    (python-mode           . ("\ue73c" . mutecipher-icon-blue))
    (rust-ts-mode          . ("\ue7a8" . mutecipher-icon-orange))  ; nf-dev-rust
    (go-ts-mode            . ("\ue724" . mutecipher-icon-cyan))    ; nf-dev-go
    (markdown-ts-mode      . ("\ue73e" . mutecipher-icon-blue))    ; nf-dev-markdown
    (markdown-mode         . ("\ue73e" . mutecipher-icon-blue))
    (org-mode              . ("\uf02d" . mutecipher-icon-green))   ; nf-fa-book
    (emacs-lisp-mode       . ("\uf121" . mutecipher-icon-purple))  ; nf-fa-code
    (lisp-interaction-mode . ("\uf121" . mutecipher-icon-purple))
    (dired-mode            . ("\uf07b" . mutecipher-icon-yellow))  ; nf-fa-folder_open
    (ibuffer-mode          . ("\uf0c9" . mutecipher-icon-dim))     ; nf-fa-list
    (erc-mode              . ("\uf086" . mutecipher-icon-blue))    ; nf-fa-comments
    (text-mode             . ("\uf15c" . mutecipher-icon-dim)))    ; nf-fa-file_text
  "Map major modes to (ICON . FACE) pairs.")

(defvar mutecipher-icons-default '("\uf15b" . mutecipher-icon-dim)  ; nf-fa-file
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

(provide 'mutecipher-icons)
;;; mutecipher-icons.el ends here
