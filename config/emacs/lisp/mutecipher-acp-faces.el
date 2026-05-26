;;; mutecipher-acp-faces.el --- Faces and presentation customs for ACP  -*- lexical-binding: t -*-
;;
;; Defines the parent customization group, presentation defcustoms
;; (variable-pitch, role glyphs, mode indicators, composer glyphs), and
;; every face used by the ACP client.  Pure leaf — no internal deps.

;;; Code:

(defgroup mutecipher-acp nil
  "ACP (Agent Client Protocol) client, ewoc-based rewrite."
  :group 'tools
  :prefix "mutecipher-acp-")

(defcustom mutecipher-acp-variable-pitch nil
  "When non-nil, render session buffers with `variable-pitch-mode'.
Prose reads nicer but table alignment, hanging-indent widths, and the
ExitPlanMode plan-body gutter all rely on monospace character widths;
enable at your own aesthetic-vs-alignment tradeoff.  Off by default."
  :type 'boolean
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-composer-prompt "❯ "
  "Glyph rendered at the start of the inline composer region.
Carried as an overlay `before-string', so it never contaminates the
buffer text the composer sends to the agent."
  :type 'string
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-composer-cursor-glyph "▌"
  "Caret rendered at the live assistant node's tail while streaming.
Set to nil to disable the streaming caret entirely."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-role-glyph-alist
  '((user      "▌" mutecipher-acp-user-face)
    (assistant "▌" mutecipher-acp-agent-face)
    (thought   "▌" shadow)
    (notice    "▌" shadow)
    (queued    "▌" mutecipher-acp-queued-face))
  "Alist mapping message-role symbols to (GLYPH FACE) pairs.
Overrides `mutecipher/icon-for-acp' for the four chat-message roles so
the transcript shows a subtle single-character marker rather than a
Nerd Font icon.  Set an entry's GLYPH to the empty string to drop the
marker entirely for that role."
  :type '(alist :key-type symbol :value-type (list string face))
  :group 'mutecipher-acp)

(defface mutecipher-acp-user-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user prompt labels in ACP session buffers.")

(defface mutecipher-acp-slash-command-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for slash-command prefixes (e.g. /review) in rendered user prompts.")

(defface mutecipher-acp-agent-face
  '((t :inherit font-lock-string-face :weight bold))
  "Face for agent response labels in ACP session buffers.")

(defface mutecipher-acp-tool-face
  '((t :inherit font-lock-builtin-face))
  "Face for tool call lines in ACP session buffers.")

(defface mutecipher-acp-thought-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for agent thought/reasoning lines in ACP session buffers.")

(defface mutecipher-acp-permission-face
  '((t :inherit warning :weight bold))
  "Face for permission request lines in ACP session buffers.")

(defface mutecipher-acp-error-face
  '((t :inherit error))
  "Face for error lines in ACP session buffers.")

(defface mutecipher-acp-status-idle-face
  '((t :inherit success))
  "Mode-line face used when the session is idle.")

(defface mutecipher-acp-status-busy-face
  '((t :inherit font-lock-comment-face))
  "Mode-line face used while the agent is thinking or streaming.")

(defface mutecipher-acp-status-await-face
  '((t :inherit warning))
  "Mode-line face used while awaiting a permission decision.")

(defface mutecipher-acp-status-error-face
  '((t :inherit error))
  "Mode-line face used after a request errors.")

(defface mutecipher-acp-hint-face
  '((t :inherit shadow))
  "Face for dimmed hint/help text in input and header lines.")

(defface mutecipher-acp-disclosure-face
  '((t :inherit shadow))
  "Face for the ▸/▾ (or chevron) disclosure glyph on collapsible nodes.")

(defface mutecipher-acp-tool-card-face
  '((t :inherit shadow))
  "Face for the tool-call card's border characters.
Used for the corners (╭ ╰), left rail (│), and horizontal rules drawn
across the top and bottom of the card.  Inherits `shadow' so theme-
appropriate dim colors come along for free.")

(defface mutecipher-acp-md-table-rule-face
  '((t :inherit shadow))
  "Face for border glyphs (corners, junctions, rules, `│') in rendered tables.")

(defface mutecipher-acp-tool-card-rule-face
  '((t :inherit mutecipher-acp-tool-card-face :strike-through t))
  "Face for the top and bottom horizontal rules of the tool-call card.
`:strike-through' draws a horizontal line across a space whose width
is anchored to the right window edge — the rule scales to whatever
width the buffer's window happens to have.")

(defface mutecipher-acp-plan-gutter-face
  '((t :inherit font-lock-comment-delimiter-face))
  "Face for the `│' gutter rendered alongside ExitPlanMode plan bodies.")

(defface mutecipher-acp-diff-added-face
  '((((class color) (background light))
     :background "#e6ffec" :extend t)
    (((class color) (background dark))
     :background "#0e2a17" :extend t)
    (t :inherit diff-added :extend t))
  "Face for `+' lines in tool-call diff bodies.
`:extend t' so the green background stretches to the right edge.")

(defface mutecipher-acp-diff-removed-face
  '((((class color) (background light))
     :background "#ffebe9" :extend t)
    (((class color) (background dark))
     :background "#2f1011" :extend t)
    (t :inherit diff-removed :extend t))
  "Face for `-' lines in tool-call diff bodies.")

(defface mutecipher-acp-diff-context-face
  '((t :inherit default))
  "Face for unchanged context lines in tool-call diff bodies.")

(defface mutecipher-acp-diff-hunk-header-face
  '((((class color) (background light))
     :inherit diff-hunk-header :background "#ddf4ff" :extend t)
    (((class color) (background dark))
     :inherit diff-hunk-header :background "#0a2640" :extend t)
    (t :inherit diff-hunk-header :extend t))
  "Face for `@@ -X,Y +A,B @@' hunk-header lines in tool-call diff bodies.")

(defface mutecipher-acp-diff-line-number-face
  '((t :inherit shadow))
  "Face for the line-number gutter on every diff line.")

(defface mutecipher-acp-pulse-face
  '((t :inherit pulse-highlight-start-face))
  "Face used by `pulse-momentary-highlight-region' after node invalidations.")

(defface mutecipher-acp-prompt-glyph-face
  '((t :inherit mutecipher-acp-user-face :weight bold))
  "Face for the `❯' prompt glyph in the ACP composer region.")

(defface mutecipher-acp-queued-face
  '((t :inherit shadow :slant italic))
  "Face for queued prompt nodes waiting to be sent.
Rendered between the active turn and the composer; dim + italic so the
queue reads as held / pending text rather than transcript content.")

(defface mutecipher-acp-streaming-caret-face
  '((t :inherit mutecipher-acp-agent-face :weight bold))
  "Face for the streaming caret overlay drawn at the live assistant node.")

(defface mutecipher-acp-mode-default-face
  '((t :inherit mutecipher-acp-user-face))
  "Header face for the default session mode.")

(defface mutecipher-acp-mode-auto-accept-face
  '((t :foreground "#e5a50a" :weight bold))
  "Header face for auto-accept session mode.")

(defface mutecipher-acp-mode-plan-face
  '((t :foreground "#56b6c2" :weight bold))
  "Header face for plan session mode.")

(defface mutecipher-acp-mode-bypass-face
  '((t :foreground "#e06c75" :weight bold))
  "Header face for bypass-permissions session mode.")

(defface mutecipher-acp-mode-dont-ask-face
  '((t :foreground "#a07840" :weight bold))
  "Header face for dont-ask session mode.")

(defcustom mutecipher-acp-mode-indicators
  `(("default"           ,(string #xf132) mutecipher-acp-mode-default-face)      ; nf-fa-shield
    ("auto"              ,(string #xf0e7) mutecipher-acp-mode-auto-accept-face)  ; nf-fa-bolt
    ("acceptEdits"       ,(string #xf05d) mutecipher-acp-mode-auto-accept-face)  ; nf-fa-check_circle
    ("plan"              ,(string #xf022) mutecipher-acp-mode-plan-face)         ; nf-fa-list_alt
    ("dontAsk"           ,(string #xf05e) mutecipher-acp-mode-dont-ask-face)     ; nf-fa-ban
    ("bypassPermissions" ,(string #xf09c) mutecipher-acp-mode-bypass-face)       ; nf-fa-unlock
    ("agent"             ,(string #xf0d0) mutecipher-acp-mode-default-face)      ; nf-fa-magic
    ("autopilot"         ,(string #xf135) mutecipher-acp-mode-bypass-face))      ; nf-fa-rocket
  "Alist mapping modeId to (icon face) for session header display.
Unknown mode IDs fall back to (\"?\" mutecipher-acp-mode-default-face)."
  :type '(alist :key-type string
                :value-type (list string face))
  :group 'mutecipher-acp)

(provide 'mutecipher-acp-faces)
;;; mutecipher-acp-faces.el ends here
