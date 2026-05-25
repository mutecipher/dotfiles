;;; mutecipher-acp-session.el --- Session lifecycle and state machine for ACP  -*- lexical-binding: t -*-
;;
;; The connect / initialize / new-session / load-session lifecycle, the
;; idle ↔ thinking ↔ streaming ↔ awaiting-permission ↔ error state
;; machine and its 1Hz refresh timer, turn open/close, prompt
;; submission, and session teardown.
;;
;; Sits at the top of the dependency DAG — every other ACP module
;; loads before this one.

;;; Code:

(require 'cl-lib)
(require 'ewoc)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-rpc)
(require 'mutecipher-acp-ewoc)
(require 'mutecipher-acp-tools)
(require 'mutecipher-acp-completion)
(require 'mutecipher-acp-ui)
(require 'mutecipher-acp-protocol)

(defvar mutecipher-acp-agents)

;;;; Connection management

(defun mutecipher-acp--connect (agent-name)
  "Return an existing live connection for AGENT-NAME, or create a new one.
Connections are cached per agent name, NOT per (agent, cwd).  Two
sessions in different working directories share one subprocess; the
agent's cwd is supplied per-session via `session/new', so this is
correct as long as the agent honours that boundary."
  (let ((existing (gethash agent-name mutecipher-acp--connections)))
    (if (and existing
             (process-live-p (mutecipher-acp--conn-process existing)))
        existing
      (let* ((spec    (cdr (assoc agent-name mutecipher-acp-agents)))
             (command (plist-get spec :command))
             (args    (plist-get spec :args))
             (env     (plist-get spec :env)))
        (unless command
          (user-error "ACP: no agent named %S in `mutecipher-acp-agents'" agent-name))
        (let ((conn (mutecipher-acp--open
                     agent-name command args env
                     #'mutecipher-acp--handle-notification)))
          (puthash agent-name conn mutecipher-acp--connections)
          conn)))))

;;;; Protocol helpers

(defun mutecipher-acp--initialize (conn callback)
  "Send ACP initialize to CONN, call CALLBACK with the result."
  (mutecipher-acp--request
   conn "initialize"
   (list :protocolVersion 1)
   :success-fn (lambda (result) (funcall callback result))
   :error-fn   (lambda (err)
                 (message "ACP initialize failed: %s" (plist-get err :message)))))

(defun mutecipher-acp--new-session (conn cwd agent-name callback)
  "Send session/new to CONN with CWD, call CALLBACK with (session-id buffer) on success."
  (mutecipher-acp--request
   conn "session/new" (list :cwd cwd :mcpServers [])
   :success-fn
   (lambda (result)
     (let* ((session-id   (plist-get result :sessionId))
            (modes-data   (plist-get result :modes))
            (avail-modes  (plist-get modes-data :availableModes))
            (current-mode (plist-get modes-data :currentModeId))
            (buf          (mutecipher-acp--get-or-create-buffer session-id agent-name))
            (session      (mutecipher-acp--make-session
                           :id session-id :conn conn :buffer buf
                           :agent agent-name :cwd cwd
                           :available-modes avail-modes
                           :current-mode-id current-mode)))
       (puthash session-id session mutecipher-acp--sessions)
       (funcall callback session-id buf)))
   :error-fn
   (lambda (err)
     (message "ACP session/new failed: %s" (plist-get err :message)))))

(defun mutecipher-acp--load-session (conn session-id agent-name cwd callback)
  "Resume SESSION-ID via session/load on CONN; call CALLBACK with (session-id buf).
The session struct is created eagerly so replayed notifications have
somewhere to land before the success callback fires."
  (let* ((buf     (mutecipher-acp--get-or-create-buffer session-id agent-name))
         (session (mutecipher-acp--make-session
                   :id session-id :conn conn :buffer buf
                   :agent agent-name :cwd cwd)))
    (puthash session-id session mutecipher-acp--sessions)
    (mutecipher-acp--request
     conn "session/load" (list :sessionId session-id)
     :success-fn (lambda (_) (funcall callback session-id buf))
     :error-fn   (lambda (err)
                   (remhash session-id mutecipher-acp--sessions)
                   (kill-buffer buf)
                   (message "ACP session/load failed: %s"
                            (plist-get err :message))))))

;;;; State transitions

(defun mutecipher-acp--set-state (session-id new-state)
  "Transition SESSION-ID to NEW-STATE and refresh the buffer chrome.
Starts a 1Hz timer for `thinking' and `streaming' so the elapsed-
seconds counter ticks; cancels it for every other state.  Updates
the streaming caret so the visible `▌' appears/disappears alongside
the `streaming' state."
  (when-let ((session (gethash session-id mutecipher-acp--sessions)))
    (when-let ((t0 (macp-session-state-timer session)))
      (cancel-timer t0))
    (let* ((busy       (memq new-state '(thinking streaming)))
           (started-at (and busy (float-time)))
           (timer      (and busy
                            (run-at-time
                             1 1
                             (lambda ()
                               (when-let ((s (gethash session-id
                                                       mutecipher-acp--sessions)))
                                 (mutecipher-acp--refresh-mode-line s)))))))
      (setf (macp-session-state session) new-state
            (macp-session-state-started-at session) started-at
            (macp-session-state-timer session) timer)
      (mutecipher-acp--refresh-mode-line session)
      (mutecipher-acp--update-streaming-caret session))))

;;;; Prompt submission

(defun mutecipher-acp--open-turn (session-id user-text)
  "Open a new turn in SESSION-ID: enter turn-header + user nodes for USER-TEXT.
Clears per-turn scratch (`:current-assistant', `:current-plan-node')
and bumps `:turn-counter'.  Returns the turn-header node."
  (let* ((session (gethash session-id mutecipher-acp--sessions))
         (buf     (macp-session-buffer session))
         (counter (1+ (or (macp-session-turn-counter session) 0)))
         (turn    (make-macp-turn :id counter :started-at (float-time)))
         (turn-node nil))
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t))
        (setq turn-node (ewoc-enter-last
                         mutecipher-acp--ewoc
                         (make-macp-node :kind 'turn-header :data turn)))
        (ewoc-enter-last
         mutecipher-acp--ewoc
         (make-macp-node :kind 'user
                         :data (make-macp-user :text user-text)))))
    ;; Tool-call ids are turn-local — clear the index so the table
    ;; doesn't grow without bound across long sessions.
    (clrhash (macp-session-tool-call-index session))
    (setf (macp-session-turn-counter session) counter
          (macp-session-current-turn-node session) turn-node
          (macp-session-current-assistant session) nil
          (macp-session-current-plan-node session) nil)
    turn-node))

(defun mutecipher-acp--close-turn (session-id stop-reason)
  "Finalize SESSION-ID's current turn with STOP-REASON, invalidate its header.
Enters a trailer node for any non-normal STOP-REASON."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (node    (macp-session-current-turn-node session))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (let* ((turn (macp-node-data (ewoc-data node))))
      (setf (macp-turn-ended-at   turn) (float-time))
      (setf (macp-turn-stop-reason turn) stop-reason)
      (mutecipher-acp--with-sticky-tail buf
        (let ((inhibit-read-only t))
          (ewoc-invalidate mutecipher-acp--ewoc node)
          (unless (memq stop-reason '(end_turn nil))
            (ewoc-enter-last
             mutecipher-acp--ewoc
             (make-macp-node
              :kind 'trailer
              :data (make-macp-trailer :stop-reason stop-reason)))))))
    (setf (macp-session-current-turn-node session) nil)))

(defun mutecipher-acp--do-prompt (session-id text)
  "Send TEXT as a prompt for SESSION-ID."
  (let* ((session   (gethash session-id mutecipher-acp--sessions))
         (conn      (macp-session-conn session))
         (full-text text))
    (mutecipher-acp--open-turn session-id text)
    (mutecipher-acp--set-state session-id 'thinking)
    (mutecipher-acp--request
     conn "session/prompt"
     (list :sessionId session-id
           :prompt (mutecipher-acp--prompt-blocks
                    full-text (macp-session-cwd session)))
     :success-fn (lambda (result)
                   (let ((reason (or (plist-get result :stopReason) "end_turn")))
                     (mutecipher-acp--close-assistant session-id)
                     (mutecipher-acp--close-turn session-id (intern reason))
                     (mutecipher-acp--set-state session-id 'idle)))
     :error-fn   (lambda (err)
                   (mutecipher-acp--close-assistant session-id)
                   (mutecipher-acp--close-turn session-id 'error)
                   (mutecipher-acp--set-state session-id 'error)
                   (message "ACP: request failed: %s"
                            (or (plist-get err :message) "unknown error"))))))

;;;; Teardown

(defun mutecipher-acp--teardown-session (session-id &optional skip-buffer)
  "Cancel SESSION-ID's RPC, drop its timer + entry, and kill its buffer.
When SKIP-BUFFER is non-nil, skip the session buffer (used by the
`kill-buffer-hook' so we don't re-kill the buffer that's already dying)."
  (when-let ((session (gethash session-id mutecipher-acp--sessions)))
    (let ((conn (macp-session-conn session))
          (buf  (macp-session-buffer session)))
      (when (and conn (process-live-p (mutecipher-acp--conn-process conn)))
        (mutecipher-acp--request
         conn "session/cancel"
         (list :sessionId session-id)
         :success-fn (lambda (_) nil)
         :error-fn   (lambda (_) nil)))
      (when-let ((t0 (macp-session-state-timer session)))
        (cancel-timer t0))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (mutecipher-acp--stop-spinner)))
      (remhash session-id mutecipher-acp--sessions)
      (when (and (not skip-buffer) (buffer-live-p buf))
        (kill-buffer buf)))))

(defun mutecipher-acp--on-session-buffer-killed ()
  "`kill-buffer-hook' on session output buffers — tear down the session."
  (when-let ((sid mutecipher-acp--session-id))
    (mutecipher-acp--teardown-session sid 'skip-buffer)))

(provide 'mutecipher-acp-session)
;;; mutecipher-acp-session.el ends here
