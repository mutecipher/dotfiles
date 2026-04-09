;;; mutecipher-icons.el --- Nerd Font icon support  -*- lexical-binding: t -*-
;;
;; Maps file extensions and major modes to Nerd Font glyphs using
;; Symbols Nerd Font Mono (the symbols-only variant — no text glyphs).
;;
;; Call (mutecipher/buffer-icon) to get an icon string for the current buffer.
;; The fontset is configured automatically when this module is loaded.

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

;;; Icon alists

(defvar mutecipher-icons-extension-alist
  '(;; Ruby
    ("rb"      . "\ue739")   ; nf-dev-ruby
    ("rake"    . "\ue739")
    ("gemspec" . "\ue739")
    ;; JavaScript
    ("js"      . "\ue74e")   ; nf-dev-javascript
    ("mjs"     . "\ue74e")
    ("cjs"     . "\ue74e")
    ("jsx"     . "\ue7ba")   ; nf-dev-react
    ;; TypeScript
    ("ts"      . "\ue628")   ; nf-seti-typescript
    ("tsx"     . "\ue7ba")   ; nf-dev-react
    ;; Web
    ("css"     . "\ue749")   ; nf-dev-css3
    ("scss"    . "\ue749")
    ("html"    . "\ue736")   ; nf-dev-html5
    ("htm"     . "\ue736")
    ;; Data / Config
    ("json"    . "\ue60b")   ; nf-seti-json
    ("yaml"    . "\ue6a8")   ; nf-seti-yaml
    ("yml"     . "\ue6a8")
    ("toml"    . "\ue6b2")   ; nf-seti-config
    ;; Shell
    ("sh"      . "\ue795")   ; nf-dev-terminal
    ("bash"    . "\ue795")
    ("zsh"     . "\ue795")
    ;; Emacs Lisp
    ("el"      . "\uf121")   ; nf-fa-code
    ("elc"     . "\uf121")
    ;; Markup / Docs
    ("md"      . "\ue73e")   ; nf-dev-markdown
    ("org"     . "\uf02d")   ; nf-fa-book
    ;; Systems
    ("py"      . "\ue73c")   ; nf-dev-python
    ("rs"      . "\ue7a8")   ; nf-dev-rust
    ("go"      . "\ue724")   ; nf-dev-go
    ;; Misc
    ("lock"    . "\uf023"))  ; nf-fa-lock
  "Map file extensions to Nerd Font icon strings.")

(defvar mutecipher-icons-filename-alist
  '(("Dockerfile"         . "\ue7b0")  ; nf-dev-docker
    ("docker-compose.yml" . "\ue7b0")
    (".gitconfig"         . "\ue702")  ; nf-dev-git
    (".gitignore"         . "\ue702")
    (".gitmodules"        . "\ue702")
    ("Gemfile"            . "\ue739")  ; nf-dev-ruby
    ("Rakefile"           . "\ue739")
    ("Makefile"           . "\uf085")  ; nf-fa-cogs
    (".env"               . "\uf462")) ; nf-fa-user_secret
  "Map specific filenames to Nerd Font icon strings.")

(defvar mutecipher-icons-mode-alist
  '((ruby-ts-mode          . "\ue739")  ; nf-dev-ruby
    (ruby-mode             . "\ue739")
    (js-ts-mode            . "\ue74e")  ; nf-dev-javascript
    (js-mode               . "\ue74e")
    (typescript-ts-mode    . "\ue628")  ; nf-seti-typescript
    (tsx-ts-mode           . "\ue7ba")  ; nf-dev-react
    (css-ts-mode           . "\ue749")  ; nf-dev-css3
    (css-mode              . "\ue749")
    (html-mode             . "\ue736")  ; nf-dev-html5
    (yaml-ts-mode          . "\ue6a8")  ; nf-seti-yaml
    (yaml-mode             . "\ue6a8")
    (bash-ts-mode          . "\ue795")  ; nf-dev-terminal
    (sh-mode               . "\ue795")
    (dockerfile-ts-mode    . "\ue7b0")  ; nf-dev-docker
    (python-ts-mode        . "\ue73c")  ; nf-dev-python
    (python-mode           . "\ue73c")
    (rust-ts-mode          . "\ue7a8")  ; nf-dev-rust
    (go-ts-mode            . "\ue724")  ; nf-dev-go
    (markdown-ts-mode      . "\ue73e")  ; nf-dev-markdown
    (markdown-mode         . "\ue73e")
    (org-mode              . "\uf02d")  ; nf-fa-book
    (emacs-lisp-mode       . "\uf121")  ; nf-fa-code
    (lisp-interaction-mode . "\uf121")  ; nf-fa-code
    (dired-mode            . "\uf07b")  ; nf-fa-folder_open
    (ibuffer-mode          . "\uf0c9")  ; nf-fa-list
    (erc-mode              . "\uf086")  ; nf-fa-comments
    (text-mode             . "\uf15c")) ; nf-fa-file_text
  "Map major modes to Nerd Font icon strings.")

(defvar mutecipher-icons-default "\uf15b"  ; nf-fa-file
  "Fallback icon for buffers with no specific mapping.")

;;; Lookup API

(defun mutecipher/icon-for-file (filename)
  "Return a Nerd Font icon string for FILENAME, or nil."
  (when filename
    (let* ((base (file-name-nondirectory filename))
           (ext  (file-name-extension base)))
      (or (cdr (assoc base mutecipher-icons-filename-alist))
          (and ext (cdr (assoc (downcase ext) mutecipher-icons-extension-alist)))))))

(defun mutecipher/icon-for-mode (mode)
  "Return a Nerd Font icon string for major MODE symbol, or nil."
  (cdr (assq mode mutecipher-icons-mode-alist)))

(defun mutecipher/buffer-icon ()
  "Return the Nerd Font icon string for the current buffer."
  (or (mutecipher/icon-for-file buffer-file-name)
      (mutecipher/icon-for-mode major-mode)
      mutecipher-icons-default))

(provide 'mutecipher-icons)
;;; mutecipher-icons.el ends here
