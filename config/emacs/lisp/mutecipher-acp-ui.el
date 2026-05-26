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
(require 'mutecipher-acp-faces)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-ewoc)
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

;;;; Mode pill / header-line

(defun mutecipher-acp--find-mode (id modes)
  "Return the mode plist with :id ID from MODES, or nil."
  (cl-find id modes :key (lambda (m) (plist-get m :id)) :test #'string=))

(defun mutecipher-acp--mode-indicator (session)
  "Return (icon face mode-name) for SESSION's current mode.
ICON is nil when the mode is unrecognized and the server hasn't yet sent
`:available-modes' — callers treat nil ICON as \"no pill to show\".
When `:available-modes' is populated, MODE-NAME is suffixed with ` (N/M)'
showing the current mode's 1-based position and total count."
  (let* ((mode-id  (or (and session (macp-session-current-mode-id session)) "default"))
         (avail    (and session (macp-session-available-modes session)))
         (lookup-id (if (string-match "#\\(.+\\)$" mode-id)
                        (match-string 1 mode-id)
                      mode-id))
         (entry    (assoc lookup-id mutecipher-acp-mode-indicators))
         (icon     (cond (entry (cadr entry))
                         (avail "?")
                         (t nil)))
         (face     (if entry (caddr entry) 'mutecipher-acp-mode-default-face))
         (base     (and avail
                        (let ((m (mutecipher-acp--find-mode mode-id avail)))
                          (and m (plist-get m :name)))))
         (idx      (and avail (cl-position mode-id avail
                                           :key (lambda (m) (plist-get m :id))
                                           :test #'string=)))
         (name     (cond
                    ((and base idx) (format "%s (%d/%d)" base (1+ idx) (length avail)))
                    (base base)
                    (t nil))))
    (list icon face name)))

(defun mutecipher-acp--session-header-line ()
  "Return the pinned header-line content for a session buffer.
Two-column layout: identity (agent + abbreviated cwd tail) on the left;
state chunk, mode pill, and session-id prefix flush-right."
  (let* ((sid     mutecipher-acp--session-id)
         (session (and sid (gethash sid mutecipher-acp--sessions)))
         (agent   (or (and session (macp-session-agent session)) "?"))
         (cwd     (and session (macp-session-cwd session)))
         (state   (or (and session (macp-session-state session)) 'idle))
         (started (and session (macp-session-state-started-at session)))
         (mi      (mutecipher-acp--mode-indicator session))
         (m-icon  (nth 0 mi))
         (m-face  (nth 1 mi))
         (m-name  (nth 2 mi))
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
                       (mapconcat #'identity tail "/"))))
         (left    (concat
                   "  "
                   account-icon
                   " "
                   (propertize agent 'face 'mutecipher-acp-agent-face)
                   (when cwd-tail
                     (concat sep
                             (propertize cwd-tail
                                         'face 'mutecipher-acp-hint-face
                                         'help-echo cwd-abbr)))))
         (state-chunk (mutecipher-acp--state-label state started))
         (qcount  (and session (length (macp-session-prompt-queue session))))
         (q-chunk (when (and qcount (> qcount 0))
                    (propertize (format "%d queued" qcount)
                                'face 'mutecipher-acp-queued-face)))
         (mode-pill (when m-icon
                      (propertize (if m-name
                                      (format "%s %s" m-icon m-name)
                                    m-icon)
                                  'face m-face)))
         (id-chunk (if sid
                       (propertize (mutecipher-acp--id-prefix sid)
                                   'face 'shadow)
                     ""))
         (right (concat state-chunk
                        (when q-chunk (concat sep q-chunk))
                        (when mode-pill (concat sep mode-pill))
                        "   "
                        id-chunk)))
    (concat left
            (propertize " " 'display
                        `(space :align-to (- right ,(1+ (string-width right)))))
            right
            " ")))

;;;; State glyph / label / mode-line

(defun mutecipher-acp--state-glyph (state elapsed)
  "Return a status glyph for STATE.
Busy states (`thinking', `streaming') cycle through a 4-frame ASCII
rotation keyed off ELAPSED so the user sees motion while the agent
works.  Non-busy states render a steady `●'."
  (pcase state
    ((or 'thinking 'streaming)
     (let ((frames "-\\|/"))
       (string (aref frames (mod (or elapsed 0) (length frames))))))
    (_ "●")))

(defun mutecipher-acp--state-label (state started-at)
  "Render STATE as `<glyph> <label>' propertized with the matching status face.
STARTED-AT is a float-time used for elapsed seconds + glyph rotation."
  (let* ((elapsed (and started-at
                       (max 0 (truncate (- (float-time) started-at)))))
         (glyph   (mutecipher-acp--state-glyph state elapsed))
         (pair
          (pcase state
            ((or 'thinking 'streaming)
             (cons (format "%s %ds" (symbol-name state) (or elapsed 0))
                   'mutecipher-acp-status-busy-face))
            ('awaiting-permission
             (cons "awaiting permission" 'mutecipher-acp-status-await-face))
            ('error
             (cons "error" 'mutecipher-acp-status-error-face))
            (_
             (cons "idle" 'mutecipher-acp-status-idle-face)))))
    (propertize (concat glyph " " (car pair)) 'face (cdr pair))))

(defun mutecipher-acp--session-mode-line ()
  "Return mode-line content for a session buffer (state pill + session id)."
  (let* ((sid     mutecipher-acp--session-id)
         (session (and sid (gethash sid mutecipher-acp--sessions)))
         (state   (or (and session (macp-session-state session)) 'idle))
         (started (and session (macp-session-state-started-at session)))
         (sep     (propertize " · " 'face 'mutecipher-acp-hint-face))
         (state-chunk (mutecipher-acp--state-label state started))
         (id-chunk (when sid
                     (propertize (mutecipher-acp--id-prefix sid)
                                 'face 'shadow))))
    (concat "  "
            state-chunk
            (when id-chunk (concat sep id-chunk))
            " ")))

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

;;;; Session major mode

;; Declared BEFORE `define-derived-mode' so the mode picks up our keymap
;; instead of synthesizing one inheriting from `special-mode-map' (which
;; would remap `self-insert-command' to `undefined' via its
;; `suppress-keymap' setup and block all typing in the composer).
(defvar-keymap mutecipher-acp-session-mode-map
  :doc "Keymap for `mutecipher-acp-session-mode' — transcript above, composer below.
RET / `<return>' send the composer's contents; S-RET, S-<return>, and M-J
insert a literal newline so the composer can grow to multiple lines.
M-p / M-n cycle the per-session composer history.  TAB does the right
thing depending on point: completion-at-point in the composer, toggle
disclosure on a tool-call node, otherwise no-op."
  "RET"        #'mutecipher-acp--composer-send
  "<return>"   #'mutecipher-acp--composer-send
  "S-RET"      #'newline
  "S-<return>" #'newline
  "M-J"        #'newline
  "M-p"        #'mutecipher-acp--composer-history-prev
  "M-n"        #'mutecipher-acp--composer-history-next
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
  "C-c C-o"    #'mutecipher/acp-set-config)

(define-derived-mode mutecipher-acp-session-mode fundamental-mode "ACP"
  "Single-buffer ACP session: read-only transcript above, inline composer below.
The ewoc renders the transcript and `mutecipher-acp--pp' applies a
`read-only' text-property to every rendered region.  Past the ewoc's
footer, an inline composer region — text with no `read-only' property
— collects the user's in-progress message.  RET dispatches it via
`mutecipher-acp--composer-send'."
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
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
