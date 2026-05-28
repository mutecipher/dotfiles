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
  kind         ; 'turn-header 'user 'assistant 'thought 'tool-call 'tool-group 'plan 'trailer
  data         ; kind-specific struct below
  collapsed    ; bool; meaningful for 'tool-call and 'tool-group
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
  face)         ; face symbol applied to the line

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
  id conn buffer agent cwd
  (state 'idle)
  state-started-at
  state-timer
  commands
  file-cache
  (turn-counter 0)
  current-turn-node
  current-assistant
  current-plan-node
  available-modes
  current-mode-id
  title
  (tool-call-index (make-hash-table :test #'equal))
  (node-index (make-hash-table :test #'equal)) ; uuid -> ewoc node, populated by --ewoc-enter-tail
  prompt-queue        ; list of strings, FIFO (head = next to send)
  queue-head-node     ; ewoc node of the first queued entry, anchor for enter-before
  last-active         ; float-time of last user/agent activity, nil before any
  persist-dirty       ; t when in-memory state has unsaved changes
  loading             ; t while session/load replay is in progress (suppresses persist)
  current-tool-group) ; ewoc node of the open trailing tool-group, or nil

;;;; Node identity

;; Seed once at module load so uuids differ across Emacs sessions — without
;; this, two cold-started Emacs instances produce identical uuid sequences,
;; which would collide once persistence-replay loads transcripts from disk.
(random t)

(defun mutecipher-acp--new-node-uuid ()
  "Generate a fresh node uuid: short hex string suitable for addressing."
  (format "n_%012x" (random (expt 16 12))))

(defun mutecipher-acp--unindex-node (session node)
  "Remove NODE's uuid mapping from SESSION's `node-index'.
No-op when the node has no uuid (constructed outside `--ewoc-enter-tail')."
  (when-let* ((data (ewoc-data node))
              (uuid (macp-node-uuid data)))
    (remhash uuid (macp-session-node-index session))))

;;;; Session/connection state tables

(defvar mutecipher-acp--connections (make-hash-table :test #'equal)
  "Hash table mapping agent-name strings to mutecipher-acp--conn structs.")

(defvar mutecipher-acp--sessions (make-hash-table :test #'equal)
  "Hash table mapping session-id strings to session plists.")

(defvar-local mutecipher-acp--session-id nil
  "Session ID associated with the current ACP buffer (output or input).")

(defvar-local mutecipher-acp--ewoc nil
  "The ewoc managing the current ACP session buffer's transcript.")

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
