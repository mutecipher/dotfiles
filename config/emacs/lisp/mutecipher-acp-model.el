;;; mutecipher-acp-model.el --- Data model and session state for ACP  -*- lexical-binding: t -*-
;;
;; Every visible thing in the transcript buffer is an ewoc node whose
;; `data' is a `macp-node'.  The master pretty-printer
;; `mutecipher-acp--pp' dispatches on `macp-node-kind' to kind-specific
;; renderers.  Kind-specific data lives in the dedicated structs below.
;;
;; Prefix convention: file-internal identifiers are `mutecipher-acp-…'
;; (or `mutecipher/acp-…' for interactive entry points).  The shorter
;; `macp-…' prefix is reserved for `cl-defstruct' types and accessors —
;; cl's auto-generated names show up at every call site, so the long
;; prefix would punish readability.  No other identifiers should use
;; `macp-…'.

;;; Code:

(require 'cl-lib)

(cl-defstruct macp-node
  ;; New slots MUST be added at the END.  `cl-defstruct' accessors are
  ;; `defsubst'-inlined, so reordering shifts every call site's
  ;; (aref struct N) and silently corrupts any stale `.elc' linked
  ;; against the old layout.
  ;;
  ;; Collapse state is intentionally NOT a slot — it lived here once,
  ;; but presentation preference round-tripping through prin1/read meant
  ;; resumed sessions ignored later changes to
  ;; `mutecipher-acp-collapse-tool-calls-by-default'.  The render-time
  ;; lookup now goes through `--node-collapsed-p', which consults a
  ;; buffer-local override map (see below) and falls back to the
  ;; defcustom for any unrecorded uuid.
  kind         ; 'turn-header 'user 'assistant 'thought 'tool-call 'tool-group 'plan 'trailer
  data         ; kind-specific struct below
  uuid)        ; stable string id, populated lazily by --ewoc-enter-tail

(cl-defstruct macp-turn
  id            ; monotonic counter per session
  started-at    ; float-time
  ended-at      ; float-time or nil
  stop-reason   ; 'end_turn 'max_tokens 'cancelled 'error or nil
  usage         ; plist; reserved for a follow-on plan
  change-set)   ; macp-change-set or nil; lazily created on first mutation

(cl-defstruct macp-user
  text)

(cl-defstruct macp-assistant
  text)         ; accumulated chunks while streaming

(cl-defstruct macp-thought
  text)

(cl-defstruct macp-tool-call
  call-id name kind
  input locations
  status               ; 'pending 'running 'done 'error
  started-at ended-at
  raw-output
  diffs                ; list of (old . new) strings
  rendered-diff-count  ; int counter replacing :rendered-content-count
  plan-body            ; full plan markdown (only for ExitPlanMode-style tools)
  raw-input            ; original :rawInput plist; consumed by per-tool body renderers
  cwd                  ; cwd in effect when the call was entered; used to resolve
                       ; relative `:locations[0].path' for diff line anchoring
                       ; without the renderer reaching into the session table
  start-line)          ; 1-based file line where this call's diffs anchor, or nil.
                       ; Resolved at ingest time (whenever new diffs or locations
                       ; land) so the pretty-printer never reads the file or
                       ; mutates the struct.  Persisted with the tool-call —
                       ; reflects the file content at the moment the agent
                       ; reported the edit, which is the truthful anchor

(cl-defstruct macp-tool-group
  ;; Ordered list of `macp-tool-call' children that share a "read-only"
  ;; classification — successive Read / Grep / Glob / WebFetch /
  ;; WebSearch invocations land inside one group node instead of each
  ;; getting its own card.  Closed means the group is no longer
  ;; accepting children: a subsequent write/edit/bash, an assistant
  ;; chunk, a new turn, or any non-read node fires the close.
  children      ; list of macp-tool-call structs in insertion order
  closed)       ; bool

(cl-defstruct macp-plan
  entries)      ; vec of plists (:content :priority :status)

(cl-defstruct macp-trailer
  stop-reason)  ; 'max_tokens 'cancelled 'error 'refusal, etc.

(cl-defstruct macp-notice
  text          ; plain-text line content
  kind)         ; domain symbol (e.g. `parse-error') — the renderer
                ; resolves face from kind via the alist in
                ; `mutecipher-acp--notice-kind-faces' so face stops
                ; doubling as the discriminator across notice variants

(cl-defstruct macp-queued
  text)         ; pending prompt text waiting for the active turn to end

(cl-defstruct macp-file-change
  path                ; absolute path string (normalized via file-truename)
  pre-turn-content    ; full file content as string, or nil
  pre-turn-existed    ; t if file existed on disk before the turn began
  capture-status      ; 'ok | 'suppressed-too-large | 'reverse-apply-failed
  status              ; 'accepted (default) | 'reverted
  tool-call-ids       ; list of call-ids that touched this path in the turn
  accumulated-pairs)  ; chronological list of (oldText . newText) from every
                      ; tool call in this turn that touched this path; the
                      ; snapshot is re-derived from this list on every capture
                      ; so incremental diff delivery doesn't bake intermediate
                      ; state into pre-turn-content

(cl-defstruct macp-change-set
  files               ; alist ((abs-path . macp-file-change) ...)
                      ; alist not hash table — round-trips cleanly through
                      ; the existing prin1/read persistence layer
  cwd)                ; cwd in effect when the change-set was created; pins
                      ; the anchor for `--change-set-relativize' so the badge
                      ; renders against the right root even when the session's
                      ; cwd has drifted or `--session-id' isn't bound

(cl-defstruct (macp-session (:constructor mutecipher-acp--make-session))
  ;; Durable identity + protocol state — what the session IS, independent
  ;; of how it's currently rendered.  EWOC-insertion-cursor view state
  ;; (`current-turn-node', `current-assistant', `current-plan-node',
  ;; `current-tool-group') lives buffer-local in the session buffer
  ;; rather than on this struct — see the defvar-locals below + their
  ;; `--session-current-*' accessors.
  id conn buffer agent cwd
  (state 'idle)
  state-started-at
  state-timer
  commands
  file-cache
  (turn-counter 0)
  available-modes
  current-mode-id
  title
  (tool-call-index (make-hash-table :test #'equal))
  (node-index (make-hash-table :test #'equal)) ; uuid -> ewoc node, populated by --ewoc-enter-tail
  prompt-queue        ; list of strings, FIFO (head = next to send)
  queue-head-node     ; ewoc node of the first queued entry, anchor for enter-before
  last-active         ; float-time of last user/agent activity, nil before any
  persist-dirty       ; t when in-memory state has unsaved changes
  loading)            ; t while session/load replay is in progress (suppresses persist)

;;;; Node identity

;; Seed once at module load so uuids differ across Emacs sessions — without
;; this, two cold-started Emacs instances produce identical uuid sequences,
;; which would collide once persistence-replay loads transcripts from disk.
(random t)

(defun mutecipher-acp--new-node-uuid ()
  "Generate a fresh node uuid: short hex string suitable for addressing."
  (format "n_%012x" (random (expt 16 12))))

(defun mutecipher-acp--unindex-node (session node)
  "Remove NODE's uuid mapping from SESSION's `node-index' and from the
buffer-local `--collapse-overrides' map.  No-op when the node has no
uuid (constructed outside `--ewoc-enter-tail').

Cleaning the override map at delete time keeps the per-buffer hash
sized to live nodes — without this, every user-toggle or auto-collapse
write on a since-deleted node leaks an entry for the lifetime of the
session buffer."
  (when-let* ((data (ewoc-data node))
              (uuid (macp-node-uuid data)))
    (remhash uuid (macp-session-node-index session))
    (when-let* ((buf (macp-session-buffer session))
                ((buffer-live-p buf))
                (map (buffer-local-value 'mutecipher-acp--collapse-overrides
                                         buf)))
      (remhash uuid map))))

;;;; Session/connection state tables

(defvar mutecipher-acp--connections (make-hash-table :test #'equal)
  "Hash table mapping agent-name strings to mutecipher-acp--conn structs.")

(defvar mutecipher-acp--sessions (make-hash-table :test #'equal)
  "Hash table mapping session-id strings to session plists.")

(defvar-local mutecipher-acp--session-id nil
  "Session ID associated with the current ACP buffer (output or input).")

(defvar-local mutecipher-acp--ewoc nil
  "The ewoc managing the current ACP session buffer's transcript.")

;;;; Renderer insertion cursors (per session buffer, not on the session struct)
;;
;; These four buffer-locals replace `current-*' slots that used to live on
;; `macp-session'.  They're EWOC view state — where the next streamed chunk,
;; tool-call, or plan update should land — not durable session identity.
;; Keeping them buffer-local lets a future feature render one session into
;; two buffers (split inspector, comparison view) without the cursors
;; fighting for a single slot, and makes the conflation visible at the
;; storage layer rather than implicit in which fields persist.el omits.
;;
;; Callers use the `mutecipher-acp--session-current-*' accessor pairs
;; (read + setf) so the call-site shape stays session-centric even though
;; storage moved.

(defvar-local mutecipher-acp--current-turn-node nil
  "EWOC node of the active turn in this session buffer, or nil between turns.
Set on `--open-turn', cleared on `--close-turn'.  `--maybe-capture-change-set'
reads it via `--session-current-turn-node' to locate the turn whose
change-set is being mutated.")

(defvar-local mutecipher-acp--current-assistant nil
  "EWOC node currently receiving streamed assistant chunks, or nil.
`--append-assistant-chunk' sets this on first chunk and clears it on
`--close-assistant', so subsequent chunks invalidate the same node
instead of entering fresh ones.")

(defvar-local mutecipher-acp--current-plan-node nil
  "EWOC node carrying the active turn's plan, or nil.
Lets `--enter-plan' mutate-in-place when the agent sends a plan update
instead of stacking a new plan node per revision.")

(defvar-local mutecipher-acp--current-tool-group nil
  "EWOC node of the open trailing `tool-group', or nil.
A run of adjacent read-only tool-calls folds into one group via this
slot; `--close-trailing-tool-group' clears it whenever a new node
kind interrupts the run.  Re-derived at hydrate time by walking the
EWOC for the last still-open group.")

(defvar-local mutecipher-acp--collapse-overrides nil
  "Hash table uuid → bool of explicit collapse-state overrides.
nil until first use; populated lazily by user toggle, auto-collapse on
terminal status, and plan-body force-expand at construction.

Lookup falls back to `mutecipher-acp-collapse-tool-calls-by-default'
for any uuid not in the map — buffer-local + non-persisted on purpose,
so a defcustom flip applies to resumed sessions instead of being
shadowed by stale per-node bools from when the prior session was
saved.  Cleared with the buffer.")

(defun mutecipher-acp--collapse-overrides-table ()
  "Return the buffer-local collapse-overrides hash, creating it lazily."
  (or mutecipher-acp--collapse-overrides
      (setq mutecipher-acp--collapse-overrides
            (make-hash-table :test 'equal))))

(defun mutecipher-acp--node-collapsed-p (node)
  "Return non-nil when NODE should render as collapsed.
Only `tool-call' and `tool-group' kinds are foldable — every other
kind returns nil regardless of the override map.  For foldable kinds
the buffer-local override map wins; absent any entry (or a missing
uuid, which is the case for synthetic test nodes), the value of
`mutecipher-acp-collapse-tool-calls-by-default' is used.  Read via
`bound-and-true-p' so a standalone `(require \\='mutecipher-acp-model)'
without tool-card.el (test harness, partial autoload) returns nil
instead of signalling `void-variable'."
  (when (memq (macp-node-kind node) '(tool-call tool-group))
    (let* ((uuid     (macp-node-uuid node))
           (map      mutecipher-acp--collapse-overrides)
           (sentinel '--unset)
           (entry    (if (and uuid map)
                         (gethash uuid map sentinel)
                       sentinel)))
      (if (eq entry sentinel)
          (bound-and-true-p mutecipher-acp-collapse-tool-calls-by-default)
        entry))))

;; The setter is a SILENT NO-OP when NODE has no uuid — synthetic test
;; nodes constructed via `make-macp-node' but not entered via
;; `--ewoc-enter-tail' fall here.  Callers that need to seed override
;; state must `setf' AFTER the node is in the ewoc (uuid is assigned
;; there).  The gensym'd VAL is still evaluated for its side effects
;; regardless of uuid presence.
(gv-define-setter mutecipher-acp--node-collapsed-p (val node)
  (let ((v (gensym "val")))
    `(let ((,v ,val))
       (when-let ((uuid (macp-node-uuid ,node)))
         (puthash uuid (and ,v t)
                  (mutecipher-acp--collapse-overrides-table)))
       ,v)))

;; Setters use `gv-define-setter' with an explicit gensymmed binding
;; for VAL so the RHS is evaluated unconditionally — preserving the
;; "setf evaluates the new value once" contract even when the session
;; buffer has been killed (the buffer-local write itself is then a
;; no-op).  A future caller writing `(setf (...) (progn (record) v))'
;; against a torn-down session still runs the `record' side effect.

(defun mutecipher-acp--session-current-turn-node (session)
  "Return SESSION's active-turn EWOC node, or nil.
Reads the `--current-turn-node' buffer-local in SESSION's buffer."
  (when-let ((buf (macp-session-buffer session)))
    (and (buffer-live-p buf)
         (buffer-local-value 'mutecipher-acp--current-turn-node buf))))

(gv-define-setter mutecipher-acp--session-current-turn-node (val session)
  (let ((v (gensym "val")))
    `(let ((,v ,val))
       (when-let ((buf (macp-session-buffer ,session)))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq mutecipher-acp--current-turn-node ,v)))))))

(defun mutecipher-acp--session-current-assistant (session)
  "Return SESSION's active assistant-streaming EWOC node, or nil."
  (when-let ((buf (macp-session-buffer session)))
    (and (buffer-live-p buf)
         (buffer-local-value 'mutecipher-acp--current-assistant buf))))

(gv-define-setter mutecipher-acp--session-current-assistant (val session)
  (let ((v (gensym "val")))
    `(let ((,v ,val))
       (when-let ((buf (macp-session-buffer ,session)))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq mutecipher-acp--current-assistant ,v)))))))

(defun mutecipher-acp--session-current-plan-node (session)
  "Return SESSION's active plan EWOC node, or nil."
  (when-let ((buf (macp-session-buffer session)))
    (and (buffer-live-p buf)
         (buffer-local-value 'mutecipher-acp--current-plan-node buf))))

(gv-define-setter mutecipher-acp--session-current-plan-node (val session)
  (let ((v (gensym "val")))
    `(let ((,v ,val))
       (when-let ((buf (macp-session-buffer ,session)))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq mutecipher-acp--current-plan-node ,v)))))))

(defun mutecipher-acp--session-current-tool-group (session)
  "Return SESSION's open trailing tool-group EWOC node, or nil."
  (when-let ((buf (macp-session-buffer session)))
    (and (buffer-live-p buf)
         (buffer-local-value 'mutecipher-acp--current-tool-group buf))))

(gv-define-setter mutecipher-acp--session-current-tool-group (val session)
  (let ((v (gensym "val")))
    `(let ((,v ,val))
       (when-let ((buf (macp-session-buffer ,session)))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq mutecipher-acp--current-tool-group ,v)))))))

;;;; Session lookup / buffer naming

(defun mutecipher-acp--session-for-conn (conn)
  "Return the session plist for CONN, or nil if none is active."
  (let (found)
    (maphash (lambda (_id session)
               (when (eq (macp-session-conn session) conn)
                 (setq found session)))
             mutecipher-acp--sessions)
    found))

(defun mutecipher-acp--id-prefix (session-id)
  "Return the first 8 characters of SESSION-ID for display."
  (substring session-id 0 (min 8 (length session-id))))

(defun mutecipher-acp--buffer-name (agent-name session-id)
  "Return buffer name for AGENT-NAME and SESSION-ID."
  (format "*ACP: %s [%s]*" agent-name (mutecipher-acp--id-prefix session-id)))

(declare-function mutecipher-acp-session-mode "mutecipher-acp-ui")

(defun mutecipher-acp--get-or-create-buffer (session-id agent-name)
  "Return (or create) the session buffer for SESSION-ID / AGENT-NAME."
  (let* ((name (mutecipher-acp--buffer-name agent-name session-id))
         (buf  (get-buffer-create name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'mutecipher-acp-session-mode)
        (mutecipher-acp-session-mode)
        (setq mutecipher-acp--session-id session-id)))
    buf))

(provide 'mutecipher-acp-model)
;;; mutecipher-acp-model.el ends here
