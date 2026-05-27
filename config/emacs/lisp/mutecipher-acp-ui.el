;;; mutecipher-acp-ui.el --- Session buffer UI / mode for ACP  -*- lexical-binding: t -*-
;;
;; The session-buffer major mode + chrome.  Two-column header-line with
;; agent/cwd on the left and state/mode/sid on the right; mode-line
;; with state + session-id; streaming-caret overlay anchored at the
;; live assistant node; tool-call disclosure commands; mode-indicator
;; pill resolver.

;;; Code:

(require 'cl-lib)
(require 'ewoc)
(require 'goto-addr)
(require 'rx)
(require 'thingatpt)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-ewoc)
;; `--state-glyph' uses `mutecipher-acp-spinner-frames' /
;; `mutecipher-acp-spinner-interval' so the chrome spinner matches the
;; tool-call card spinner — one visual vocabulary for `in flight'.
(require 'mutecipher-acp-tool-card)
;; `--update-streaming-caret' reads `mutecipher-acp--composer-start',
;; a defvar-local declared in composer.el.  Without this require the
;; symbol would only become bound transitively via the entry file,
;; turning load-order glitches into silent fallthroughs.
(require 'mutecipher-acp-composer)

(declare-function mutecipher-acp--composer-install        "mutecipher-acp-composer")
(declare-function mutecipher-acp--composer-send           "mutecipher-acp-composer")
(declare-function mutecipher-acp--composer-history-prev   "mutecipher-acp-composer")
(declare-function mutecipher-acp--composer-history-next   "mutecipher-acp-composer")
(declare-function mutecipher-acp--tab-dwim                "mutecipher-acp-composer")
(declare-function mutecipher-acp--maybe-complete          "mutecipher-acp-composer")
(declare-function mutecipher-acp--queue-delete-dwim       "mutecipher-acp-composer")
(declare-function mutecipher-acp--files-capf              "mutecipher-acp-completion")
(declare-function mutecipher-acp--commands-capf           "mutecipher-acp-completion")
(declare-function mutecipher-acp--on-session-buffer-killed "mutecipher-acp-session")
(declare-function mutecipher/acp-cycle-mode               "mutecipher-acp")
(declare-function mutecipher/acp-dispatch                 "mutecipher-acp")
(declare-function mutecipher/acp-cancel                   "mutecipher-acp")
(declare-function mutecipher/acp-kill-session             "mutecipher-acp")
(declare-function mutecipher/acp-set-config               "mutecipher-acp")
(declare-function mutecipher/icon-for-acp                 "mutecipher-icons")
(declare-function completion-preview-mode                 "completion-preview")

(defvar-local mutecipher-acp--streaming-caret-overlay nil
  "Overlay rendering `mutecipher-acp-composer-cursor-glyph' at the live
assistant node while state is `streaming'.")

(defvar-local mutecipher-acp--state-indicator-overlay nil
  "Overlay rendering the inline state indicator above the composer
while state is `thinking' — fills the visual gap between the user's
sent prompt and the first streamed chunk.  Managed by
`--update-state-indicator'; absent in every state but `thinking'
(streaming is self-evident from the live caret + text append; idle is
silent; awaiting-permission / error already have transcript nodes).")

;;;; Mode pill / header-line

(defun mutecipher-acp--find-mode (id modes)
  "Return the mode plist with :id ID from MODES, or nil."
  (cl-find id modes :key (lambda (m) (plist-get m :id)) :test #'string=))

(defun mutecipher-acp--mode-indicator (session)
  "Return (icon face mode-name) for SESSION's current mode.
ICON is nil whenever there is no pill worth showing: the resolved mode
is `default' (the implicit baseline — silence reads as `nothing to
warn about'), or the server hasn't yet sent `:available-modes' and the
id is unrecognized.  Callers treat nil ICON as \"render nothing\"."
  (let* ((mode-id  (or (and session (macp-session-current-mode-id session)) "default"))
         (avail    (and session (macp-session-available-modes session)))
         (lookup-id (if (string-match "#\\(.+\\)$" mode-id)
                        (match-string 1 mode-id)
                      mode-id))
         (entry    (assoc lookup-id mutecipher-acp-mode-indicators))
         (icon     (cond ((string= lookup-id "default") nil)
                         (entry (cadr entry))
                         (avail "?")
                         (t nil)))
         (face     (if entry (caddr entry) 'mutecipher-acp-mode-default-face))
         (name     (and avail
                        (let ((m (mutecipher-acp--find-mode mode-id avail)))
                          (and m (plist-get m :name))))))
    (list icon face name)))

(defun mutecipher-acp--session-header-line ()
  "Return the pinned header-line content for a session buffer.
Identity only: agent name + abbreviated cwd tail.  The mode pill lives
in the mode-line (left edge, where it reads as contextual to the
composer); state has an inline placeholder; session id and queued
count have inline equivalents or are intentionally hidden."
  (let* ((sid     mutecipher-acp--session-id)
         (session (and sid (gethash sid mutecipher-acp--sessions)))
         (agent   (or (and session (macp-session-agent session)) "?"))
         (cwd     (and session (macp-session-cwd session)))
         (sep     (propertize " · " 'face 'mutecipher-acp-hint-face))
         (account-icon (propertize
                        (or (and (fboundp 'mutecipher/icon-for-acp)
                                 (mutecipher/icon-for-acp 'assistant))
                            "")
                        'face 'mutecipher-acp-agent-face))
         (cwd-abbr (and cwd (abbreviate-file-name cwd)))
         (cwd-tail (when cwd-abbr
                     (let* ((segs (split-string cwd-abbr "/" t))
                            (tail (if (> (length segs) 2)
                                      (nthcdr (- (length segs) 2) segs)
                                    segs)))
                       (mapconcat #'identity tail "/")))))
    (concat "  "
            account-icon
            " "
            (propertize agent 'face 'mutecipher-acp-agent-face)
            (when cwd-tail
              (concat sep
                      (propertize cwd-tail
                                  'face 'mutecipher-acp-hint-face
                                  'help-echo cwd-abbr)))
            " ")))

;;;; State glyph / label / mode-line

(defun mutecipher-acp--state-glyph (state elapsed)
  "Return a status glyph for STATE.
Busy states (`thinking', `streaming') cycle through
`mutecipher-acp-spinner-frames' — the same vector the tool-call card
spinner uses — keyed off ELAPSED (a float of seconds since state
start).  Non-busy states render a steady `●'."
  (pcase state
    ((or 'thinking 'streaming)
     (let* ((frames mutecipher-acp-spinner-frames)
            (idx    (mod (truncate (/ (or elapsed 0)
                                      mutecipher-acp-spinner-interval))
                         (max 1 (length frames)))))
       (aref frames idx)))
    (_ "●")))

(defun mutecipher-acp--state-label (state started-at)
  "Render STATE as `<glyph> <label>' propertized with the matching status face.
STARTED-AT is a float-time used for elapsed seconds + glyph rotation;
the glyph cycles at `mutecipher-acp-spinner-interval' cadence so the
state timer needs to tick at least that often for smooth motion."
  (let* ((elapsed-f (and started-at
                         (max 0.0 (- (float-time) started-at))))
         (elapsed-i (and elapsed-f (truncate elapsed-f)))
         (glyph     (mutecipher-acp--state-glyph state elapsed-f))
         (pair
          (pcase state
            ((or 'thinking 'streaming)
             (cons (format "%s %ds" (symbol-name state) (or elapsed-i 0))
                   'mutecipher-acp-status-busy-face))
            ('awaiting-permission
             (cons "awaiting permission" 'mutecipher-acp-status-await-face))
            ('error
             (cons "error" 'mutecipher-acp-status-error-face))
            (_
             (cons "idle" 'mutecipher-acp-status-idle-face)))))
    (propertize (concat glyph " " (car pair)) 'face (cdr pair))))

(defun mutecipher-acp--session-mode-line ()
  "Return mode-line content for a session buffer.
Carries the active mode pill at the left — close enough to the composer
to read as contextual to what the user is about to type, without
sitting inside the composer's `before-string' itself.  Empty when the
resolved mode is `default' (silence = nothing unusual).  When a
non-default mode is active, appends a dim ` (shift+tab to cycle)' hint
so the affordance is discoverable without a manual lookup."
  (let* ((sid     mutecipher-acp--session-id)
         (session (and sid (gethash sid mutecipher-acp--sessions)))
         (mi      (and session (mutecipher-acp--mode-indicator session)))
         (m-icon  (nth 0 mi))
         (m-face  (nth 1 mi))
         (m-name  (nth 2 mi))
         (mode-pill (when m-icon
                      (propertize (if m-name
                                      (format "%s %s" m-icon m-name)
                                    m-icon)
                                  'face m-face)))
         (hint (propertize " (shift+tab to cycle)" 'face 'shadow)))
    (if mode-pill
        (concat "  " mode-pill hint " ")
      "")))

(defun mutecipher-acp--refresh-mode-line (session)
  "Force a mode-line / header-line redraw in SESSION's buffer."
  (when-let ((buf (and session (macp-session-buffer session))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (force-mode-line-update)))))

(defun mutecipher-acp--update-streaming-caret (session)
  "Show or hide the streaming caret overlay based on SESSION's state."
  (when-let ((buf (and session (macp-session-buffer session))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (overlayp mutecipher-acp--streaming-caret-overlay)
          (delete-overlay mutecipher-acp--streaming-caret-overlay)
          (setq mutecipher-acp--streaming-caret-overlay nil))
        (let ((assist (macp-session-current-assistant session)))
          (when (and assist
                     (eq (macp-session-state session) 'streaming)
                     mutecipher-acp-composer-cursor-glyph)
            (let* ((node-beg (ewoc-location assist))
                   (next     (ewoc-next mutecipher-acp--ewoc assist))
                   (node-end (cond
                              (next (ewoc-location next))
                              ((bound-and-true-p mutecipher-acp--composer-start)
                               (marker-position
                                mutecipher-acp--composer-start))
                              (t (point-max)))))
              (when (and node-beg node-end (> node-end node-beg))
                (let* ((pos (max node-beg (1- node-end)))
                       (ov  (make-overlay pos pos)))
                  (overlay-put ov 'after-string
                               (propertize
                                mutecipher-acp-composer-cursor-glyph
                                'face 'mutecipher-acp-streaming-caret-face))
                  (overlay-put ov 'mutecipher-acp-streaming-caret t)
                  (setq mutecipher-acp--streaming-caret-overlay ov))))))))))

(defun mutecipher-acp--inline-state-text (state started-at)
  "Return inline state-indicator text for STATE, or nil if no inline cue.
Only emits a string for `thinking' — every other state either has a
self-evident inline render (streaming text + caret, permission node,
error notice) or is silent by design (idle).

Spinner takes the column-0 gutter slot — the same column the
assistant's `▌' will occupy once streaming starts — propertized in
`mutecipher-acp-agent-face' so the row still reads as the agent's
voice in flight even without the static bar.  Body `Thinking (Ns)'
sits in `mutecipher-acp-status-busy-face'.  Terminates with `\\n' so
the overlay's `before-string' lays out on its own line.

Spinner placement mirrors the tool-call gutter pattern: motion belongs
in a fixed left-edge slot, not embedded in the body."
  (when (and (eq state 'thinking) started-at)
    (let* ((elapsed-f (max 0.0 (- (float-time) started-at)))
           (elapsed-i (truncate elapsed-f))
           (glyph     (mutecipher-acp--state-glyph state elapsed-f))
           (body      (propertize (format "Thinking (%ds)" elapsed-i)
                                  'face 'mutecipher-acp-status-busy-face)))
      (concat (propertize glyph 'face 'mutecipher-acp-agent-face)
              " " body "\n"))))

(defun mutecipher-acp--state-indicator-needs-blank-p (pos)
  "Return non-nil when the indicator at POS should prepend a leading `\\n'.
POS is the read-only separator newline just before `composer-start'.
The character two positions back (`pos - 2') is the buffer char that
starts the line directly above the separator.  When that char is a
`\\n', the line above is already blank and the indicator's
`before-string' fills the empty line below it cleanly.  When it's
not, the previous content ends with a single `\\n' (e.g. collapsed
tool calls trail one newline, not two) and the indicator needs to
prepend its own `\\n' to avoid sitting flush against the row above."
  (let ((p (- pos 2)))
    (and (>= p (point-min))
         (not (eq (char-after p) ?\n)))))

(defun mutecipher-acp--update-state-indicator (session)
  "Show, hide, or refresh the inline state indicator overlay for SESSION.
Reuses the existing overlay when one is live — only the `before-string'
is rewritten on each refresh.  Recreates when missing.  Drops the
overlay entirely when the live state has no inline cue (every state
but `thinking').

Anchored one position before `composer-start' — the read-only separator
newline at the ewoc tail, the same buffer position where ewoc inserts
new transcript content.  Marker insertion-types are both `t' so an
ewoc insert AT that position advances the overlay forward with the
inserted text instead of leaving BEG > END (which Emacs handles
ungracefully and produces visible jumbling).  Net effect: the
indicator sticks to the bottom of the ewoc content as tool calls and
chunks land above it, then snaps away when state leaves `thinking'.

Prepends a leading `\\n' to the before-string when the row above
doesn't already provide a blank line (e.g. collapsed tool calls trail
a single `\\n'); skips it after nodes that already trail `\\n\\n'
(user / assistant / expanded tool calls) so spacing doesn't double up."
  (when-let ((buf (and session (macp-session-buffer session))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((state    (macp-session-state session))
               (started  (macp-session-state-started-at session))
               (raw-text (mutecipher-acp--inline-state-text state started))
               (cs       (and (boundp 'mutecipher-acp--composer-start)
                              mutecipher-acp--composer-start
                              (marker-position
                               mutecipher-acp--composer-start)))
               (pos      (and cs (max (point-min) (1- cs))))
               (text     (when (and raw-text pos)
                           (if (mutecipher-acp--state-indicator-needs-blank-p pos)
                               (concat "\n" raw-text)
                             raw-text)))
               (ov       mutecipher-acp--state-indicator-overlay))
          (cond
           ;; No inline cue — tear down if present.
           ((null text)
            (when (overlayp ov)
              (delete-overlay ov)
              (setq mutecipher-acp--state-indicator-overlay nil)))
           ;; Live overlay — rewrite the text in place.  Marker flags
           ;; t/t keep it tracking the separator across ewoc inserts.
           ((and (overlayp ov) (overlay-buffer ov))
            (overlay-put ov 'before-string text))
           ;; First call (or after a teardown) — create with t/t flags.
           (pos
            (let ((new-ov (make-overlay pos pos nil t t)))
              (overlay-put new-ov 'before-string text)
              (overlay-put new-ov 'mutecipher-acp-state-indicator t)
              (setq mutecipher-acp--state-indicator-overlay
                    new-ov)))))))))

;;;; Session major mode

;; Declared BEFORE `define-derived-mode' so the mode picks up our keymap
;; instead of synthesizing one inheriting from `special-mode-map' (which
;; would remap `self-insert-command' to `undefined' via its
;; `suppress-keymap' setup and block all typing in the composer).
(defvar-keymap mutecipher-acp-session-mode-map
  :doc "Keymap for `mutecipher-acp-session-mode' — transcript above, composer below.
RET / `<return>' send the composer's contents; S-RET, S-<return>, and M-J
insert a literal newline so the composer can grow to multiple lines.
M-p / M-n cycle the per-session composer history.  C-S-p / C-S-n walk
the transcript by node (with M-{ / M-} as TTY-safe aliases since most
terminals drop Shift on Control+letter); C-c C-z jumps back to the
composer.  TAB does the right thing depending on point:
completion-at-point in the composer, toggle disclosure on a tool-call
node, otherwise no-op."
  "RET"        #'mutecipher-acp--composer-send
  "<return>"   #'mutecipher-acp--composer-send
  "S-RET"      #'newline
  "S-<return>" #'newline
  "M-J"        #'newline
  "M-p"        #'mutecipher-acp--composer-history-prev
  "M-n"        #'mutecipher-acp--composer-history-next
  "C-S-p"      #'mutecipher/acp-prev-node
  "C-S-n"      #'mutecipher/acp-next-node
  "M-{"        #'mutecipher/acp-prev-node
  "M-}"        #'mutecipher/acp-next-node
  "DEL"        #'mutecipher-acp--queue-delete-dwim
  "<backspace>" #'mutecipher-acp--queue-delete-dwim
  "TAB"        #'mutecipher-acp--tab-dwim
  "<tab>"      #'mutecipher-acp--tab-dwim
  "M-TAB"      #'mutecipher-acp--tab-dwim
  "M-<tab>"    #'mutecipher-acp--tab-dwim
  "<backtab>"  #'mutecipher/acp-cycle-mode
  "C-c TAB"    #'mutecipher/acp-toggle-tool-calls
  "C-c <tab>"  #'mutecipher/acp-toggle-tool-calls
  "C-c C-a"    #'mutecipher/acp-dispatch
  "C-c C-c"    #'mutecipher/acp-cancel
  "C-c C-k"    #'mutecipher/acp-kill-session
  "C-c C-o"    #'mutecipher/acp-set-config
  "C-c C-z"    #'mutecipher/acp-goto-composer)

(defconst mutecipher-acp--url-regexp
  ;; Buffer-local override for `goto-address-url-regexp'.  The default
  ;; (via `thing-at-point-url-path-regexp') does not exclude `)' from
  ;; URL chars, so the trailing `)' in tool-call labels like
  ;; `WebFetch(Fetch https://example.com)' gets absorbed into the link.
  ;; Schemes are pulled from `goto-address-uri-schemes' to preserve
  ;; coverage; URL body allows balanced single-level "(...)" so URLs
  ;; like `Foo_(bar)' still consume the parens; `\n' is excluded from
  ;; the paren body so the match can't span lines; trailing sentence
  ;; punctuation (`.,;:?') is trimmed.
  (concat "\\<"
          (regexp-opt goto-address-uri-schemes t)
          (rx (zero-or-more
               (or (any "-_.~!*'$&+,;:@=?#%/|\\" alphanumeric)
                   (seq "(" (zero-or-more (not (any "()\n" space))) ")")))
              (or (any "-_~!*'$&+@=#%/|\\" alphanumeric)
                  (seq "(" (zero-or-more (not (any "()\n" space))) ")"))))
  "URL regex used in `mutecipher-acp-session-mode' buffers.
Bound buffer-locally to `goto-address-url-regexp' for fontification, and
exposed via `thing-at-point-provider-alist' so `browse-url-url-at-point'
(the click target resolver) agrees with the fontified extent.")

(defun mutecipher-acp--bounds-of-url-at-point ()
  "Return the bounds of the URL at point per `mutecipher-acp--url-regexp', or nil.
Buffer-local provider for `bounds-of-thing-at-point-provider-alist'."
  (save-excursion
    (let ((pt (point))
          (line-start (line-beginning-position))
          (line-end (line-end-position))
          found)
      (goto-char line-start)
      (while (and (not found)
                  (re-search-forward mutecipher-acp--url-regexp line-end t))
        (when (and (<= (match-beginning 0) pt)
                   (<= pt (match-end 0)))
          (setq found (cons (match-beginning 0) (match-end 0)))))
      found)))

(defun mutecipher-acp--url-at-point ()
  "Return the URL at point per `mutecipher-acp--url-regexp', or nil.
Buffer-local provider for `thing-at-point-provider-alist' — keeps
`browse-url-url-at-point' (and other `thing-at-point' callers) in sync
with the fontified overlay extent."
  (when-let ((bounds (mutecipher-acp--bounds-of-url-at-point)))
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(define-derived-mode mutecipher-acp-session-mode fundamental-mode "ACP"
  "Single-buffer ACP session: read-only transcript above, inline composer below.
The ewoc renders the transcript and `mutecipher-acp--pp' applies a
`read-only' text-property to every rendered region.  Past the ewoc's
footer, an inline composer region — text with no `read-only' property
— collects the user's in-progress message.  RET dispatches it via
`mutecipher-acp--composer-send'."
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  (setq-local goto-address-url-regexp mutecipher-acp--url-regexp)
  ;; Without these provider entries, `browse-url-url-at-point' (the click
  ;; handler installed by `goto-address-mode') falls back to thingatpt's
  ;; default URL bounds, which re-include the trailing `)' — so the
  ;; overlay would highlight the right span but clicking would open the
  ;; wrong URL.
  (setq-local thing-at-point-provider-alist
              (cons '(url . mutecipher-acp--url-at-point)
                    thing-at-point-provider-alist))
  (setq-local bounds-of-thing-at-point-provider-alist
              (cons '(url . mutecipher-acp--bounds-of-url-at-point)
                    bounds-of-thing-at-point-provider-alist))
  (goto-address-mode 1)
  (add-to-invisibility-spec 'mutecipher-acp-md-markup)
  (when mutecipher-acp-variable-pitch
    (variable-pitch-mode 1))
  (setq-local header-line-format
              '((:eval (mutecipher-acp--session-header-line))))
  (setq-local mode-line-format
              '((:eval (mutecipher-acp--session-mode-line))))
  (setq-local completion-auto-help 'always)
  (setq-local completion-styles '(basic flex))
  (setq-local completions-format 'one-column)
  (setq-local completions-max-height 12)
  (completion-preview-mode 1)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp--files-capf nil t)
  (add-hook 'completion-at-point-functions
            #'mutecipher-acp--commands-capf nil t)
  (add-hook 'post-self-insert-hook
            #'mutecipher-acp--maybe-complete nil t)
  ;; Killing the buffer outside `mutecipher/acp-kill-session' must still
  ;; cancel the state timer + clear the sessions hash.  Without this, a
  ;; 1Hz timer would keep firing forever.
  (add-hook 'kill-buffer-hook
            #'mutecipher-acp--on-session-buffer-killed nil t)
  ;; Create the ewoc on a fresh buffer; NOSEP so each pretty-printer
  ;; owns its own newlines.  Header/footer left empty — we use the
  ;; pinned `header-line-format' above instead of a scrolling banner.
  ;; Immediately install the inline composer at point-max.
  (when (zerop (buffer-size))
    (let ((inhibit-read-only t))
      (setq-local mutecipher-acp--ewoc
                  (ewoc-create #'mutecipher-acp--pp "" "" t))
      (mutecipher-acp--composer-install))))

;;;; Transcript node navigation

(defun mutecipher-acp--node-navigable-p (data)
  "Return non-nil when DATA is a transcript node user navigation should stop on.
Skips structural nodes that carry no inspectable body: zero-width
`turn-header' (one with no change-set badge) and `queued' nodes
(pending user input rendered as a suffix below the transcript)."
  (and data
       (let ((kind (macp-node-kind data)))
         (cond
          ((eq kind 'queued) nil)
          ((eq kind 'turn-header)
           ;; Keep navigable iff the header renders a change-set badge.
           (and (macp-node-p data)
                (let ((turn (macp-node-data data)))
                  (and turn (macp-turn-change-set turn)))))
          (t t)))))

(defun mutecipher-acp--find-navigable-node (ewoc start direction)
  "Walk EWOC from node START in DIRECTION (`next' or `prev').
Returns the first node whose data satisfies
`mutecipher-acp--node-navigable-p', or nil at the end."
  (let* ((step (if (eq direction 'next) #'ewoc-next #'ewoc-prev))
         (node (funcall step ewoc start)))
    (while (and node (not (mutecipher-acp--node-navigable-p (ewoc-data node))))
      (setq node (funcall step ewoc node)))
    node))

(defun mutecipher-acp--goto-node-body (node)
  "Move point to NODE's visible body, skipping the leading `\\n' baked
into the node's read-only span by `--ensure-blank-above'.  Without
this skip `goto-char (ewoc-location node)' lands on a read-only
newline one row above the visible content, making the next typed
character signal `Text is read-only'."
  (let ((raw (ewoc-location node)))
    (when raw
      (goto-char raw)
      (skip-chars-forward "\n"))))

(defun mutecipher/acp-next-node ()
  "Move point to the start of the next transcript node, skipping structural ones.
Pushes the mark so `C-u C-SPC' returns to the prior position.  Pulses
the destination.  Signals `End of transcript' at the tail or when
point is already in the composer."
  (interactive)
  (unless mutecipher-acp--ewoc
    (user-error "ACP: no transcript in this buffer"))
  (let* ((ewoc mutecipher-acp--ewoc)
         (in-composer (mutecipher-acp--composer-region-p (point)))
         (current (ewoc-locate ewoc))
         (target (and current (not in-composer)
                      (mutecipher-acp--find-navigable-node ewoc current 'next))))
    (cond
     ((null current) (user-error "ACP: transcript is empty"))
     (in-composer    (user-error "End of transcript"))
     ((null target)  (user-error "End of transcript"))
     (t
      (push-mark nil t)
      (mutecipher-acp--goto-node-body target)
      (mutecipher-acp--pulse-node ewoc target)))))

(defun mutecipher/acp-prev-node ()
  "Move point to the previous transcript node, skipping structural ones.
From the composer, jumps directly to the last navigable node.  When
point is strictly inside a navigable node, jumps to that node's body.
Pushes the mark so `C-u C-SPC' returns to the prior position.  Pulses
the destination.  Signals `Beginning of transcript' at the head."
  (interactive)
  (unless mutecipher-acp--ewoc
    (user-error "ACP: no transcript in this buffer"))
  (let* ((ewoc mutecipher-acp--ewoc)
         (pt (point))
         (in-composer (mutecipher-acp--composer-region-p pt))
         (current (ewoc-locate ewoc))
         (target
          (cond
           ((null current) nil)
           ((or in-composer (> pt (ewoc-location current)))
            (if (mutecipher-acp--node-navigable-p (ewoc-data current))
                current
              (mutecipher-acp--find-navigable-node ewoc current 'prev)))
           (t (mutecipher-acp--find-navigable-node ewoc current 'prev)))))
    (cond
     ((null current) (user-error "ACP: transcript is empty"))
     ((null target)  (user-error "Beginning of transcript"))
     (t
      (push-mark nil t)
      (mutecipher-acp--goto-node-body target)
      (mutecipher-acp--pulse-node ewoc target)))))

(defun mutecipher/acp-goto-composer ()
  "Move point to the composer input region to start typing.
Errors when invoked outside an ACP session buffer."
  (interactive)
  (unless mutecipher-acp--ewoc
    (user-error "ACP: no transcript in this buffer"))
  (mutecipher-acp--composer-goto))

;;;; Tool-call disclosure commands

(defun mutecipher/acp-toggle-tool-call ()
  "Toggle the expanded/collapsed state of the tool-call or tool-group at point.
Preserves the surrounding `window-start' so expanding a long card does
not scroll the rest of the conversation off-screen."
  (interactive)
  (let* ((ewoc mutecipher-acp--ewoc)
         (node (and ewoc (ewoc-locate ewoc))))
    (cond
     ((null node)
      (user-error "ACP: no node at point"))
     ((not (memq (macp-node-kind (ewoc-data node)) '(tool-call tool-group)))
      (user-error "ACP: not on a tool-call or tool-group"))
     (t
      (let ((wrapper (ewoc-data node)))
        (setf (macp-node-collapsed wrapper)
              (not (macp-node-collapsed wrapper))))
      (mutecipher-acp--with-sticky-window-start (current-buffer)
        (let ((inhibit-read-only t))
          (ewoc-invalidate ewoc node)))))))

(defun mutecipher/acp-toggle-tool-calls ()
  "Toggle the collapsed state of every tool-call and tool-group in the transcript.
If any card is currently expanded, collapse all of them; otherwise
expand all.  Bound to \\[mutecipher/acp-toggle-tool-calls] in the
session buffer — useful because TAB is reserved for completion in the
composer region."
  (interactive)
  (unless mutecipher-acp--ewoc
    (user-error "ACP: no transcript in this buffer"))
  (let* ((wrappers (ewoc-collect mutecipher-acp--ewoc
                                  (lambda (d)
                                    (memq (macp-node-kind d)
                                          '(tool-call tool-group)))))
         (any-expanded (cl-some (lambda (d) (not (macp-node-collapsed d)))
                                wrappers))
         (new-collapsed (and any-expanded t)))
    (if (null wrappers)
        (message "ACP: no tool calls to toggle")
      (dolist (wrapper wrappers)
        (setf (macp-node-collapsed wrapper) new-collapsed))
      (mutecipher-acp--with-sticky-window-start (current-buffer)
        (let ((inhibit-read-only t))
          (ewoc-refresh mutecipher-acp--ewoc)))
      (message "ACP: %s %d card%s"
               (if new-collapsed "collapsed" "expanded")
               (length wrappers)
               (if (= 1 (length wrappers)) "" "s")))))

(provide 'mutecipher-acp-ui)
;;; mutecipher-acp-ui.el ends here
