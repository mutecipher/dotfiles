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
(require 'mutecipher-acp-persist)

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
somewhere to land before the success callback fires.

If a session with this id already exists in `mutecipher-acp--sessions'
its struct is reused (conn/buffer updated in place) — preventing a
state-timer leak and a dropped prompt-queue when the user
double-resumes a running session.

The session's `loading' flag is set t for the duration of the RPC.
While set, `mutecipher-acp--mark-dirty' and `--bump-last-active'
short-circuit, so replayed `session/update' notifications can't
overwrite the on-disk transcript with a partial replay or reset
`last-active' to now."
  (let* ((existing (gethash session-id mutecipher-acp--sessions))
         (buf      (if (and existing
                            (buffer-live-p (macp-session-buffer existing)))
                       (macp-session-buffer existing)
                     (mutecipher-acp--get-or-create-buffer
                      session-id agent-name)))
         (session  (or existing
                       (mutecipher-acp--make-session
                        :id session-id :conn conn :buffer buf
                        :agent agent-name :cwd cwd))))
    (setf (macp-session-conn session) conn
          (macp-session-buffer session) buf
          (macp-session-loading session) t)
    (puthash session-id session mutecipher-acp--sessions)
    ;; Render the prior transcript immediately from disk.  This also
    ;; restores the session's original `cwd' from the snapshot, so
    ;; the RPC below sends the directory the session was created in
    ;; rather than wherever the user invoked resume from.  The
    ;; `loading' flag set above gates `--save-session' so the disk
    ;; snapshot we just read from isn't clobbered while in-flight
    ;; notifications mutate state.
    (mutecipher-acp--hydrate-session-from-disk session)
    (let ((session-cwd (or (macp-session-cwd session) cwd)))
      (setf (macp-session-cwd session) session-cwd)
      (mutecipher-acp--request
       conn "session/load"
       ;; Per ACP spec, session/load takes the same `cwd' and
       ;; `mcpServers' envelope as session/new — not just :sessionId.
       ;; claude-code-acp rejects the shorter form with "Invalid params".
       (list :sessionId session-id :cwd session-cwd :mcpServers [])
       :success-fn
       (lambda (result)
         (when-let ((s (gethash session-id mutecipher-acp--sessions)))
           ;; session/load returns the same `:modes' envelope as
           ;; session/new — extract availableModes + currentModeId so
           ;; mode-line/picker pick up authoritative server state.
           (when-let ((modes-data (plist-get result :modes)))
             (when-let ((avail (plist-get modes-data :availableModes)))
               (setf (macp-session-available-modes s) avail))
             (when-let ((mode-id (plist-get modes-data :currentModeId)))
               (setf (macp-session-current-mode-id s) mode-id)))
           ;; Mark dirty so the post-load save flushes the modes we
           ;; just applied (and any mutations that happened during
           ;; replay).  Clearing `loading' must come BEFORE the save
           ;; — otherwise `--save-session' short-circuits.
           (mutecipher-acp--mark-dirty s)
           (setf (macp-session-loading s) nil)
           (mutecipher-acp--refresh-mode-line s)
           (when (macp-session-persist-dirty s)
             (mutecipher-acp--save-session s)))
         (funcall callback session-id buf))
     :error-fn
     (lambda (err)
       (when-let ((s (gethash session-id mutecipher-acp--sessions)))
         (setf (macp-session-loading s) nil))
       (remhash session-id mutecipher-acp--sessions)
       (when (buffer-live-p buf) (kill-buffer buf))
       (message "ACP session/load failed: %s%s"
                (plist-get err :message)
                (if (mutecipher-acp--session-file session-id)
                    (format " — M-x mutecipher/acp-forget-session to drop %s from picker"
                            (mutecipher-acp--id-prefix session-id))
                  "")))))))

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
and bumps `:turn-counter'.  Returns the turn-header node.

When a pending queue is present, the new nodes land ABOVE the
queue-head-node so queued items stay visually pinned just above the
composer."
  (let* ((session (gethash session-id mutecipher-acp--sessions))
         (buf     (macp-session-buffer session))
         (counter (1+ (or (macp-session-turn-counter session) 0)))
         (turn    (make-macp-turn :id counter :started-at (float-time)))
         (turn-node nil))
    (mutecipher-acp--with-sticky-tail buf
      (let ((inhibit-read-only t)
            (anchor (macp-session-queue-head-node session)))
        (setq turn-node (mutecipher-acp--ewoc-enter-tail
                         mutecipher-acp--ewoc anchor
                         (make-macp-node :kind 'turn-header :data turn)))
        (mutecipher-acp--ewoc-enter-tail
         mutecipher-acp--ewoc anchor
         (make-macp-node :kind 'user
                         :data (make-macp-user :text user-text)))))
    ;; Tool-call ids are agent-unique across a session — keeping the
    ;; full index lets a post-load `tool_call_update' for a historical
    ;; tool call still find its node after we re-registered them in
    ;; `--hydrate-session-from-disk'.  Bound is tens-of-thousands per
    ;; session in the worst case, which is fine.
    (setf (macp-session-turn-counter session) counter
          (macp-session-current-turn-node session) turn-node
          (macp-session-current-assistant session) nil
          (macp-session-current-plan-node session) nil)
    (mutecipher-acp--bump-last-active session)
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
            (mutecipher-acp--ewoc-enter-tail
             mutecipher-acp--ewoc
             (macp-session-queue-head-node session)
             (make-macp-node
              :kind 'trailer
              :data (make-macp-trailer :stop-reason stop-reason)))))))
    (setf (macp-session-current-turn-node session) nil)
    (mutecipher-acp--bump-last-active session)
    ;; Clean-boundary commit: the turn is finalized — flush to disk
    ;; synchronously so the most recent transcript survives a crash.
    (mutecipher-acp--save-session session)
    (mutecipher-acp--save-index)))

(defun mutecipher-acp--enqueue-prompt (session-id text)
  "Append TEXT to SESSION-ID's prompt queue and render a `queued' node.
Queued nodes form a contiguous suffix at the end of the EWOC just above
the composer marker; `--open-turn' and other tail-inserters route around
them via `--ewoc-enter-tail'.  The session's `queue-head-node' is set on
first enqueue so subsequent insertions know where to anchor.

The EWOC insertion runs FIRST; the list is mutated only after
`mutecipher-acp--ewoc-enter-tail' returns successfully so a signal in
the buffer update doesn't leave the two stores desynced.  Echoes a
one-line acknowledgment to the minibuffer so M-x callers know their
text was held."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (mutecipher-acp--with-sticky-tail buf
      (let* ((inhibit-read-only t)
             (node (mutecipher-acp--ewoc-enter-tail
                    mutecipher-acp--ewoc nil
                    (make-macp-node :kind 'queued
                                    :data (make-macp-queued :text text)))))
        ;; List mutation AFTER the ewoc-enter succeeds — keeps the two
        ;; stores in lockstep if the buffer update signals.
        (setf (macp-session-prompt-queue session)
              (append (macp-session-prompt-queue session) (list text)))
        (unless (macp-session-queue-head-node session)
          (setf (macp-session-queue-head-node session) node))))
    ;; Persist the queue so a crash before the active turn ends doesn't
    ;; drop pending user input.
    (mutecipher-acp--bump-last-active session)
    (mutecipher-acp--refresh-mode-line session)
    (let ((n (length (macp-session-prompt-queue session))))
      (message "ACP: queued (%d pending)" n))))

(defun mutecipher-acp--queue-recover-head-node (session)
  "Re-anchor SESSION's `queue-head-node' from the actual EWOC contents.
Returns the head node, or nil if no queued nodes remain.  Used to repair
a stale or nil head pointer before treating the cached slot as truth."
  (when-let ((buf (macp-session-buffer session))
             ((buffer-live-p buf)))
    (with-current-buffer buf
      (let ((n (ewoc-nth mutecipher-acp--ewoc 0))
            (found nil))
        (while (and n (not found))
          (if (eq (macp-node-kind (ewoc-data n)) 'queued)
              (setq found n)
            (setq n (ewoc-next mutecipher-acp--ewoc n))))
        (setf (macp-session-queue-head-node session) found)
        found))))

(defun mutecipher-acp--drain-queue (session-id)
  "If SESSION-ID is idle and has a pending queue, pop and send the head.
Removes the head's `queued' EWOC node, recomputes `queue-head-node' to
the next queued node (or nil), and re-enters `--do-prompt' so the popped
text fires through the normal send path.  No-op when state is not `idle'
or the queue is empty.

If `queue-head-node' is stale (nil while the queue list is non-empty),
recover it from the actual EWOC via `--queue-recover-head-node' before
proceeding.  All EWOC reads/writes run inside `with-current-buffer buf'
because this function is typically invoked from a JSON-dispatch callback
whose current-buffer is not the session buffer — and
`mutecipher-acp--ewoc' is buffer-local."
  (when-let* ((session (gethash session-id mutecipher-acp--sessions))
              (_       (eq (macp-session-state session) 'idle))
              (queue   (macp-session-prompt-queue session))
              (buf     (macp-session-buffer session))
              (_       (buffer-live-p buf)))
    (let ((text (car queue))
          (head (or (macp-session-queue-head-node session)
                    (mutecipher-acp--queue-recover-head-node session))))
      (with-current-buffer buf
        (when head
          (let ((next (ewoc-next mutecipher-acp--ewoc head)))
            (setf (macp-session-queue-head-node session)
                  (and next
                       (eq (macp-node-kind (ewoc-data next)) 'queued)
                       next))
            (mutecipher-acp--with-sticky-tail buf
              (let ((inhibit-read-only t))
                (mutecipher-acp--unindex-node session head)
                (ewoc-delete mutecipher-acp--ewoc head)))))
        ;; List mutation only after the EWOC update succeeded (or we
        ;; confirmed there was no head node to delete).
        (setf (macp-session-prompt-queue session) (cdr queue)))
      (mutecipher-acp--do-prompt session-id text))))

(defun mutecipher-acp--do-prompt (session-id text)
  "Send TEXT as a prompt for SESSION-ID, or enqueue if the session is busy.
While the session state is anything other than `idle', TEXT is appended
to the prompt queue and surfaced as a dimmed `queued' node above the
composer.  The queue drains automatically when a turn ends in any
session-completable stop reason (`end_turn', `max_tokens', `cancelled')
so a cancelled turn flows into the next queued item per the documented
intent.  RPC failure (state → `error') still leaves the queue intact for
manual resume."
  (let* ((session (gethash session-id mutecipher-acp--sessions))
         (state   (and session (macp-session-state session))))
    (cond
     ((null session)
      (user-error "ACP: no such session %S" session-id))
     ((not (eq state 'idle))
      (mutecipher-acp--enqueue-prompt session-id text))
     (t
      (mutecipher-acp--bump-last-active session)
      (let* ((conn      (macp-session-conn session))
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
                         (mutecipher-acp--set-state session-id 'idle)
                         ;; Drain on completion or user-cancel — both
                         ;; return the session to idle and the user's
                         ;; documented intent is for the queue to flow.
                         ;; Refusal/error leave the queue stranded for
                         ;; manual resume.
                         (when (memq (intern reason)
                                     '(end_turn max_tokens cancelled))
                           (mutecipher-acp--drain-queue session-id))))
         :error-fn   (lambda (err)
                       (mutecipher-acp--close-assistant session-id)
                       (mutecipher-acp--close-turn session-id 'error)
                       (mutecipher-acp--set-state session-id 'error)
                       (message "ACP: request failed: %s"
                                (or (plist-get err :message) "unknown error")))))))))

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
      ;; Final flush before dropping the in-memory entry — the .eld file
      ;; outlives teardown so the session is resumable later.
      (mutecipher-acp--save-session session)
      (remhash session-id mutecipher-acp--sessions)
      (mutecipher-acp--save-index)
      (when (and (not skip-buffer) (buffer-live-p buf))
        (kill-buffer buf)))))

(defun mutecipher-acp--on-session-buffer-killed ()
  "`kill-buffer-hook' on session output buffers — tear down the session."
  (when-let ((sid mutecipher-acp--session-id))
    (mutecipher-acp--teardown-session sid 'skip-buffer)))

(provide 'mutecipher-acp-session)
;;; mutecipher-acp-session.el ends here
