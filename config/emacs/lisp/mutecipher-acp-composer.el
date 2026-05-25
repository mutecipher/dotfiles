;;; mutecipher-acp-composer.el --- Inline composer for ACP sessions  -*- lexical-binding: t -*-
;;
;; The composer region lives past the ewoc's footer in the same buffer.
;; `mutecipher-acp--composer-start' is a marker at the seam.  The
;; transcript region (everything before composer-start) is read-only
;; via text-property; ewoc inserts grow it via `inhibit-read-only'.
;;
;; `mutecipher-acp--with-sticky-tail' captures the composer's text
;; length before an ewoc operation and resets composer-start to
;; `(- (point-max) length)' afterwards, so the marker tracks the seam
;; across transcript growth without competing with the user's typing.
;;
;; Read-only protection: `mutecipher-acp--pp' applies
;; `read-only t' with `rear-nonsticky (read-only)' to every rendered
;; node, so characters typed just past the last node inherit no
;; read-only and stay writable.
;;
;; Slash-command interception: before sending the composer's contents
;; to the agent, `--composer-send' (a) runs
;; `mutecipher-acp-composer-send-functions' as an
;; abnormal-hook-until-success, and (b) consults
;; `mutecipher-acp--slash-commands' (from
;; mutecipher-acp-completion.el) for a local handler.  Either one
;; returning non-nil consumes the input so it never reaches the agent.

;;; Code:

(require 'cl-lib)
(require 'ring)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-completion)

(declare-function mutecipher-acp--do-prompt    "mutecipher-acp")
(declare-function completion-preview-insert    "completion-preview")
(defvar completion-preview-active-mode)

(defcustom mutecipher-acp-composer-history-size 50
  "Maximum number of past prompts retained in the composer history ring."
  :type 'integer
  :group 'mutecipher-acp)

(defvar mutecipher-acp-composer-send-functions nil
  "Abnormal hook run before the composer sends TEXT to the agent.
Each function is called with one argument, TEXT.  If any returns
non-nil, the input is considered consumed and is NOT forwarded to
the agent (the composer is still cleared and the entry is still
added to history).  Use for image-paste, draft autosave, multi-attach
preprocessing, etc.")

(defvar-local mutecipher-acp--composer-start nil
  "Marker at the boundary between the read-only transcript and the
writable composer region.  Insertion-type nil — typing here stays
inside the composer.  Reconciled by `mutecipher-acp--with-sticky-tail'.")

(defvar-local mutecipher-acp--composer-overlay nil
  "Overlay covering the composer region; carries the prompt glyph
in its `before-string' so the glyph never enters the buffer text.")

(defvar-local mutecipher-acp--composer-history nil
  "Per-session ring of past prompts sent from this composer.")

(defvar-local mutecipher-acp--composer-history-index nil
  "Current position in the composer history ring, or nil at a fresh prompt.")

(defconst mutecipher-acp--composer-hint
  "RET send · / cmds · @ file · C-c TAB expand · C-c C-a menu"
  "One-shot hint shown in the echo area when a session pane first opens.")

(defun mutecipher-acp--composer-install ()
  "Install the inline composer region at the end of the current buffer.
Adds a one-line read-only separator, places the composer markers,
attaches the prompt-glyph overlay, and seeds an empty history ring.
Called once from `mutecipher-acp-session-mode' on a fresh buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    ;; Read-only newline separator.  `rear-nonsticky (read-only)' ensures
    ;; the first character the user types does NOT inherit read-only.
    (insert (propertize "\n"
                        'read-only t
                        'front-sticky '(read-only)
                        'rear-nonsticky '(read-only)))
    (setq mutecipher-acp--composer-start (copy-marker (point) nil))
    (let ((ov (make-overlay (point) (point-max) nil nil t)))
      (overlay-put ov 'before-string
                   (propertize mutecipher-acp-composer-prompt
                               'face 'mutecipher-acp-prompt-glyph-face))
      (overlay-put ov 'mutecipher-acp-composer t)
      (setq mutecipher-acp--composer-overlay ov))
    (setq mutecipher-acp--composer-history
          (make-ring mutecipher-acp-composer-history-size))
    (setq mutecipher-acp--composer-history-index nil)
    (goto-char (point-max))))

(defun mutecipher-acp--composer-bounds ()
  "Return (START . END) of the writable composer region, or nil if absent."
  (when (and mutecipher-acp--composer-start
             (marker-position mutecipher-acp--composer-start))
    (cons (marker-position mutecipher-acp--composer-start)
          (point-max))))

(defun mutecipher-acp--composer-text ()
  "Return the composer's text trimmed of surrounding whitespace."
  (when-let ((b (mutecipher-acp--composer-bounds)))
    (string-trim (buffer-substring-no-properties (car b) (cdr b)))))

(defun mutecipher-acp--composer-extend-overlay ()
  "Ensure the composer overlay still spans the writable region."
  (when (and (overlayp mutecipher-acp--composer-overlay)
             mutecipher-acp--composer-start)
    (move-overlay mutecipher-acp--composer-overlay
                  (marker-position mutecipher-acp--composer-start)
                  (point-max))))

(defun mutecipher-acp--composer-clear ()
  "Erase the composer's contents without disturbing its markers."
  (when-let ((b (mutecipher-acp--composer-bounds)))
    (let ((inhibit-read-only t))
      (delete-region (car b) (cdr b)))
    (mutecipher-acp--composer-extend-overlay)))

(defun mutecipher-acp--composer-set-text (text)
  "Replace the composer's contents with TEXT.
Used by history navigation and edit-and-resend.  Leaves point at
`point-max' so the cursor stays inside the writable region."
  (mutecipher-acp--composer-clear)
  (when (and text (not (string-empty-p text)))
    (goto-char (point-max))
    (insert text))
  (mutecipher-acp--composer-extend-overlay))

(defun mutecipher-acp--composer-region-p (pos)
  "Non-nil when POS is inside the writable composer region."
  (and mutecipher-acp--composer-start
       (>= pos (marker-position mutecipher-acp--composer-start))))

(defun mutecipher-acp--composer-goto ()
  "Move point to the end of the composer region."
  (goto-char (point-max)))

(defun mutecipher-acp--composer-slash-match (text)
  "If TEXT starts with `/NAME', return (NAME . BODY) from the registry, else nil.
BODY is the rest of TEXT after `/NAME ' (or the empty string)."
  (when (and (stringp text)
             (string-match "^/\\([A-Za-z0-9_-]+\\)\\(?:[ \t\n]+\\(.*\\)\\)?\\'" text))
    (let* ((name (match-string 1 text))
           (rest (or (match-string 2 text) ""))
           (entry (assoc name mutecipher-acp--slash-commands)))
      (and entry (cons (cdr entry) rest)))))

(defun mutecipher-acp--composer-send ()
  "Send the composer's contents as a prompt to the current ACP session.
Empty input is silently ignored.  Resets the history index so M-p
starts from the most recent entry on the next iteration.

Before reaching the agent, the input passes through
`mutecipher-acp-composer-send-functions' (abnormal hook until success)
and the `mutecipher-acp--slash-commands' local registry.  If either
consumes the input it is NOT forwarded."
  (interactive)
  (unless (mutecipher-acp--composer-region-p (point))
    (mutecipher-acp--composer-goto)
    (user-error "ACP: jump to composer first"))
  (let ((text (mutecipher-acp--composer-text)))
    (unless (or (null text) (string-empty-p text))
      (when (and mutecipher-acp--composer-history
                 (ring-p mutecipher-acp--composer-history))
        (ring-insert mutecipher-acp--composer-history text))
      (setq mutecipher-acp--composer-history-index nil)
      (mutecipher-acp--composer-clear)
      (or (run-hook-with-args-until-success
           'mutecipher-acp-composer-send-functions text)
          (let ((match (mutecipher-acp--composer-slash-match text)))
            (and match
                 (let ((handler (plist-get (car match) :handler))
                       (body    (cdr match)))
                   (and handler (funcall handler body)))))
          (mutecipher-acp--do-prompt mutecipher-acp--session-id text)))))

(defun mutecipher-acp--composer-history-prev ()
  "Replace composer contents with the previous history entry."
  (interactive)
  (unless (mutecipher-acp--composer-region-p (point))
    (user-error "ACP: jump to composer first"))
  (let* ((ring mutecipher-acp--composer-history)
         (len  (and ring (ring-p ring) (ring-length ring))))
    (when (and len (> len 0))
      (setq mutecipher-acp--composer-history-index
            (if mutecipher-acp--composer-history-index
                (min (1+ mutecipher-acp--composer-history-index) (1- len))
              0))
      (mutecipher-acp--composer-set-text
       (ring-ref ring mutecipher-acp--composer-history-index)))))

(defun mutecipher-acp--composer-history-next ()
  "Replace composer contents with the next history entry, or clear it."
  (interactive)
  (unless (mutecipher-acp--composer-region-p (point))
    (user-error "ACP: jump to composer first"))
  (cond
   ((null mutecipher-acp--composer-history-index))
   ((= mutecipher-acp--composer-history-index 0)
    (setq mutecipher-acp--composer-history-index nil)
    (mutecipher-acp--composer-clear))
   (t
    (cl-decf mutecipher-acp--composer-history-index)
    (mutecipher-acp--composer-set-text
     (ring-ref mutecipher-acp--composer-history
               mutecipher-acp--composer-history-index)))))

(defun mutecipher-acp--maybe-complete ()
  "Trigger completion after `/' or `@' inside the composer."
  (when (and (mutecipher-acp--composer-region-p (point))
             (memq last-command-event '(?/ ?@)))
    (completion-at-point)))

(defun mutecipher-acp--tab-dwim ()
  "TAB inside the composer commits a visible completion preview, else
falls back to `completion-at-point'.  Outside the composer it's a no-op
— use \\[mutecipher/acp-toggle-tool-calls] to fold/unfold tool calls."
  (interactive)
  (cond
   ((not (mutecipher-acp--composer-region-p (point)))
    (message "ACP: TAB is composer-only — use C-c TAB to toggle tool calls"))
   ;; Route through the preview's own commit path so the overlay is
   ;; dismissed in the same step as the insertion — `completion-at-point'
   ;; defers the preview cleanup, briefly double-rendering the suffix.
   ((bound-and-true-p completion-preview-active-mode)
    (completion-preview-insert))
   (t (completion-at-point))))

(provide 'mutecipher-acp-composer)
;;; mutecipher-acp-composer.el ends here
