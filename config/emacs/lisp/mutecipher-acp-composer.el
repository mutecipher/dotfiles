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
(require 'ewoc)
(require 'ring)
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-completion)

(declare-function mutecipher-acp--do-prompt    "mutecipher-acp-session")
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
  "If TEXT starts with `/NAME' and NAME is registered, return (NAME PLIST . BODY).
BODY is the rest of TEXT after the name (or the empty string), and
spans embedded newlines so `/quote line1\\nline2' delivers the full
body to the registered handler."
  (when (and (stringp text)
             ;; \\(?:.\\|\n\\) so BODY spans newlines — plain `.' doesn't.
             (string-match
              "\\`/\\([A-Za-z0-9_-]+\\)\\(?:[ \t\n]+\\(\\(?:.\\|\n\\)*\\)\\)?\\'"
              text))
    (let* ((name  (match-string 1 text))
           (rest  (or (match-string 2 text) ""))
           (entry (assoc name mutecipher-acp--slash-commands)))
      (and entry (cons name (cons (cdr entry) rest))))))

(defun mutecipher-acp--composer-dispatch (text)
  "Route TEXT through the slash registry → send-hook → agent in order.
The slash registry takes priority over the abnormal hook so that a
matched local command is never masked by a hook that always returns
non-nil.  When TEXT matches a registered slash command, the input is
considered consumed even when the registered entry has no `:handler'
— this prevents the literal `/cmd' string from leaking to the agent."
  (let ((match (mutecipher-acp--composer-slash-match text)))
    (cond
     (match
      (let* ((name    (car match))
             (plist   (cadr match))
             (body    (cddr match))
             (handler (plist-get plist :handler)))
        (if handler
            (funcall handler body)
          (message "ACP: /%s has no handler" name))))
     ((run-hook-with-args-until-success
       'mutecipher-acp-composer-send-functions text))
     (t (mutecipher-acp--do-prompt mutecipher-acp--session-id text)))))

(defun mutecipher-acp--queued-node-at-point ()
  "Return the EWOC node at point if point is strictly inside a `queued' node.
`ewoc-locate' returns the NEAREST PRECEDING node, so on the read-only
separator just before composer-start it would falsely report the last
queued node.  We additionally require point to lie before the node's
end (the next node's start, or composer-start if at the tail)."
  (when (and mutecipher-acp--ewoc
             (not (mutecipher-acp--composer-region-p (point))))
    (let* ((ewoc mutecipher-acp--ewoc)
           (node (ewoc-locate ewoc)))
      (when (and node (eq (macp-node-kind (ewoc-data node)) 'queued))
        (let* ((next     (ewoc-next ewoc node))
               (node-end (cond
                          (next (ewoc-location next))
                          ;; The composer's separator newline sits at
                          ;; `(1- composer-start)' and is NOT part of
                          ;; the last EWOC node — point on it should
                          ;; not count as "inside" the queued node.
                          ((bound-and-true-p mutecipher-acp--composer-start)
                           (1- (marker-position
                                mutecipher-acp--composer-start)))
                          (t (point-max)))))
          (and (< (point) node-end) node))))))

(defun mutecipher-acp--queue-remove-node (session node)
  "Drop NODE from SESSION's prompt-queue + EWOC, repairing `queue-head-node'.
Looks up NODE's position among `queued' nodes via `ewoc-collect' so the
deletion targets the matching string in `prompt-queue' even when the
user removes a middle entry.  EWOC mutation runs FIRST; the list is
mutated only after `ewoc-delete' returns, so a signal in the buffer
update leaves both stores intact.  Returns the dropped text."
  (let* ((buf       (macp-session-buffer session))
         (text      nil))
    (mutecipher-acp--with-sticky-tail buf
      (let* ((ewoc   mutecipher-acp--ewoc)
             (queued (ewoc-collect ewoc
                                   (lambda (d)
                                     (eq (macp-node-kind d) 'queued))))
             (data   (ewoc-data node))
             (idx    (cl-position data queued :test #'eq))
             (queue  (macp-session-prompt-queue session))
             (inhibit-read-only t))
        (when idx
          (setq text (nth idx queue)))
        (when (eq node (macp-session-queue-head-node session))
          (let ((next (ewoc-next ewoc node)))
            (setf (macp-session-queue-head-node session)
                  (and next
                       (eq (macp-node-kind (ewoc-data next)) 'queued)
                       next))))
        (mutecipher-acp--unindex-node session node)
        (ewoc-delete ewoc node)
        ;; List mutation AFTER the ewoc-delete succeeds — keeps the two
        ;; stores in lockstep if the buffer update signals.
        (when idx
          (setf (macp-session-prompt-queue session)
                (append (cl-subseq queue 0 idx)
                        (cl-subseq queue (1+ idx)))))))
    (mutecipher-acp--refresh-mode-line session)
    text))

(defun mutecipher-acp--queue-edit-at-point ()
  "Pop the queued node at point back into the composer and remove it.
Mirrors the keymap idiom from `--tab-dwim': RET on a queued node is the
edit gesture; RET inside the composer is send.

Guarded against draft loss: if the composer already has non-empty text,
the queue-edit gesture is refused with a `user-error' rather than
silently replacing the draft.  Returns non-nil when a queued node was
consumed, regardless of whether text recovery succeeded."
  (when-let* ((sid     mutecipher-acp--session-id)
              (session (gethash sid mutecipher-acp--sessions))
              (node    (mutecipher-acp--queued-node-at-point)))
    (let ((draft (mutecipher-acp--composer-text)))
      (when (and draft (not (string-empty-p draft)))
        (user-error
         "ACP: composer has a draft — clear it before editing a queued item")))
    (let ((text (mutecipher-acp--queue-remove-node session node)))
      (when text
        (mutecipher-acp--composer-set-text text))
      (mutecipher-acp--composer-goto))
    t))

(defun mutecipher-acp--queue-remove-at-point ()
  "Remove the queued node at point without restoring it into the composer."
  (when-let* ((sid     mutecipher-acp--session-id)
              (session (gethash sid mutecipher-acp--sessions))
              (node    (mutecipher-acp--queued-node-at-point)))
    (mutecipher-acp--queue-remove-node session node)
    t))

(defun mutecipher-acp--composer-send ()
  "Send the composer's contents as a prompt to the current ACP session.
Empty input is silently ignored.  The composer is cleared and the
entry recorded in history ONLY AFTER dispatch returns successfully —
if a slash handler or send-hook signals, the user's text remains in
the composer for them to fix and retry.

When point sits on a `queued' node, RET instead pops that node's text
back into the composer for editing.  Dispatch order otherwise: local
slash registry, then `mutecipher-acp-composer-send-functions' (abnormal
hook), then RPC to the agent.  A matched slash command is always
consumed even when its registered entry has no `:handler', so
registering a name never leaks the literal `/cmd' text to the agent."
  (interactive)
  (cond
   ((mutecipher-acp--queue-edit-at-point) nil)
   ((not (mutecipher-acp--composer-region-p (point)))
    (mutecipher-acp--composer-goto)
    (user-error "ACP: jump to composer first"))
   (t
    (let ((text (mutecipher-acp--composer-text)))
      (unless (or (null text) (string-empty-p text))
        ;; Dispatch FIRST so errors leave the buffer state intact.
        (mutecipher-acp--composer-dispatch text)
        ;; Only on successful dispatch: record + clear.
        (when (and mutecipher-acp--composer-history
                   (ring-p mutecipher-acp--composer-history))
          (ring-insert mutecipher-acp--composer-history text))
        (setq mutecipher-acp--composer-history-index nil)
        (mutecipher-acp--composer-clear))))))

(defun mutecipher-acp--queue-delete-dwim ()
  "DEL on a queued node drops it from the queue; elsewhere, normal backspace.
Composer text deletion stays untouched so backspace works as usual."
  (interactive)
  (unless (mutecipher-acp--queue-remove-at-point)
    (call-interactively #'delete-backward-char)))

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

(declare-function mutecipher/acp-toggle-tool-call "mutecipher-acp-ui")

(defun mutecipher-acp--tab-dwim ()
  "TAB inside the composer commits a visible completion preview, else
falls back to `completion-at-point'.  When point sits on a tool-call
or tool-group node in the transcript, TAB folds/unfolds that card —
the in-buffer affordance for the per-card toggle, since the disclosure
glyph has been removed in favour of the gutter-status layout."
  (interactive)
  (cond
   ((mutecipher-acp--composer-region-p (point))
    ;; Route through the preview's own commit path so the overlay is
    ;; dismissed in the same step as the insertion — `completion-at-point'
    ;; defers the preview cleanup, briefly double-rendering the suffix.
    (if (bound-and-true-p completion-preview-active-mode)
        (completion-preview-insert)
      (completion-at-point)))
   ((and (boundp 'mutecipher-acp--ewoc)
         mutecipher-acp--ewoc
         (let* ((node (ewoc-locate mutecipher-acp--ewoc)))
           (and node
                (memq (macp-node-kind (ewoc-data node))
                      '(tool-call tool-group)))))
    (call-interactively #'mutecipher/acp-toggle-tool-call))
   (t
    (message "ACP: TAB toggles tool-calls in the transcript or completes in the composer"))))

(provide 'mutecipher-acp-composer)
;;; mutecipher-acp-composer.el ends here
