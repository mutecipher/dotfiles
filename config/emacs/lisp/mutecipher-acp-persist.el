;;; mutecipher-acp-persist.el --- On-disk transcript serialization for ACP  -*- lexical-binding: t -*-
;;
;; Persist each session's transcript to `<cache>/acp/<session-id>.eld' and
;; maintain a denormalized index at `<cache>/acp/index.eld' for the
;; resume picker.  Save triggers are hybrid: a debounced idle timer
;; drains dirty sessions during normal use, plus synchronous flushes at
;; turn-close, session teardown, and `kill-emacs-hook'.
;;
;; Two dirty-tracking primitives:
;;   `--mark-dirty'        — sets persist-dirty only (state changed, not user
;;                            activity); skipped during session/load replay.
;;   `--bump-last-active'  — sets last-active AND persist-dirty (user/agent
;;                            activity); skipped during replay.
;;
;; The on-disk transcript is the durable record.  Two guards prevent
;; clobbering a populated file:
;;   1. SESSION's `loading' flag is t while session/load is replaying —
;;      save-session short-circuits, so partial replay never overwrites
;;      the snapshot we're rebuilding from.
;;   2. When the in-memory EWOC has zero nodes and a file already exists,
;;      save-session skips (and clears dirty) rather than overwriting.

;;; Code:

(require 'cl-lib)
(require 'ewoc)
(require 'mutecipher-acp-model)

(defconst mutecipher-acp--persist-schema-version 5
  "Schema version for persisted ACP transcript files.
Bump when the on-disk format changes incompatibly.  The loader
silently skips files with an unknown version.

History:
  5 — `macp-tool-call' lost `cached-start-line' + `cached-start-key'
      (render-time memo slots replaced by ingest-time resolution) and
      gained a `start-line' slot.  Net layout shifts by one slot; v4
      records read against the new struct would mis-align `raw-input'
      and `cwd' with stale nil values left by the v4 strip-transient
      pass, dropping the structured rawInput payload that body
      renderers depend on.
  4 — `macp-tool-call' and `macp-change-set' each gained a `cwd' slot
      so pretty-printers can resolve relative paths without reaching
      into the session table.  v3 records are one slot short on both
      structs and would signal `args-out-of-range' through the new
      accessors at render time.
  3 — `macp-tool-call' gained a `raw-input' slot; v2 records are one
      slot short and would signal `args-out-of-range' through the new
      accessor at render time.
  2 — previous baseline.

v2 (2026-05): added `change-set' slot to `macp-turn'.  Old v1 records
are length-mismatched against the new struct layout and would signal
args-out-of-range on accessor calls, so v1 files are dropped by the
loader rather than partially migrated.")

(defcustom mutecipher-acp-persist-idle-seconds 1.5
  "Idle-seconds threshold before the persist sweeper flushes dirty sessions."
  :type 'number
  :group 'mutecipher-acp)

;;;; Paths

(defun mutecipher-acp--persist-dir ()
  "Return the cache directory for ACP transcripts (created if needed)."
  (let ((dir (expand-file-name
              "acp/"
              (or (getenv "XDG_CACHE_HOME")
                  (expand-file-name "~/.cache/emacs/")))))
    (make-directory dir t)
    dir))

(defun mutecipher-acp--persist-safe-id-p (id)
  "Return non-nil if ID is a safe filename component."
  (and (stringp id)
       (not (string-empty-p id))
       (not (member id '("." "..")))
       (string-match-p "\\`[A-Za-z0-9_.-]+\\'" id)))

(defun mutecipher-acp--session-file (session-id)
  "Path to the `.eld' file for SESSION-ID, or nil if the id is unsafe."
  (when (mutecipher-acp--persist-safe-id-p session-id)
    (expand-file-name (concat session-id ".eld")
                      (mutecipher-acp--persist-dir))))

(defun mutecipher-acp--index-file ()
  "Path to the index file."
  (expand-file-name "index.eld" (mutecipher-acp--persist-dir)))

(defun mutecipher-acp--persist-sweep-tmp ()
  "Delete stranded `<id>.eld.tmp' files left by crashes between write and rename."
  (condition-case err
      (let ((dir (mutecipher-acp--persist-dir)))
        (dolist (path (directory-files dir t "\\.eld\\.tmp\\'"))
          (delete-file path)))
    (error
     (message "ACP persist: tmp sweep failed: %s"
              (error-message-string err)))))

;;;; Atomic write/read

(defun mutecipher-acp--persist-write-sexp (path sexp)
  "Atomically write SEXP to PATH via temp+rename.
The file is encoded as UTF-8 so multibyte content round-trips."
  (let ((tmp (concat path ".tmp"))
        (print-circle t)
        (print-length nil)
        (print-level nil)
        (print-quoted t)
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file tmp
      (prin1 sexp (current-buffer)))
    (rename-file tmp path t)))

(defun mutecipher-acp--persist-read-sexp (path)
  "Read a single sexp from PATH; nil if the file is missing or unreadable.
Reads via UTF-8 so multibyte content matches what was written.
Failures are logged to *Messages* rather than swallowed silently."
  (when (and path (file-readable-p path))
    (condition-case err
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents path))
          (goto-char (point-min))
          (read (current-buffer)))
      (error
       (message "ACP persist: failed to read %s: %s"
                (file-name-nondirectory path)
                (error-message-string err))
       nil))))

;;;; Session snapshot

(defun mutecipher-acp--session-snapshot (session)
  "Return a plist of SESSION's persistent fields (drops transient state).
Includes `:commands' (the agent typically only sends them once after
`session/new') and `:prompt-queue' (pending user text not yet sent
— resumed sessions would otherwise see queued cards with no
backing strings)."
  (list :id              (macp-session-id session)
        :agent           (macp-session-agent session)
        :cwd             (macp-session-cwd session)
        :title           (macp-session-title session)
        :available-modes (macp-session-available-modes session)
        :current-mode-id (macp-session-current-mode-id session)
        :commands        (macp-session-commands session)
        :turn-counter    (macp-session-turn-counter session)
        :last-active     (macp-session-last-active session)
        :prompt-queue    (macp-session-prompt-queue session)))

(defun mutecipher-acp--collect-session-nodes (session)
  "Collect SESSION's EWOC nodes in order for serialization.
Skips `queued' nodes — those are reconstructed on hydrate by
re-enqueueing the persisted `:prompt-queue' string list, so the
visual cards and their backing strings stay in lockstep.  Returns the
live macp-node structs as-is; `macp-tool-call.start-line' is now
ingest-time data rather than a render cache, so there's nothing to
strip before prin1."
  (let ((buf (macp-session-buffer session)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (boundp 'mutecipher-acp--ewoc) mutecipher-acp--ewoc)
          (ewoc-collect mutecipher-acp--ewoc
                        (lambda (node)
                          (not (eq (macp-node-kind node) 'queued)))))))))

;;;; Index entries

(defun mutecipher-acp--resolve-model (available-modes mode-id)
  "Resolve MODE-ID to a display name via AVAILABLE-MODES (vector of plists).
Falls back to MODE-ID itself if no match is found."
  (or (and available-modes mode-id
           (cl-loop for mode across available-modes
                    when (equal (plist-get mode :id) mode-id)
                    return (or (plist-get mode :name) mode-id)))
      mode-id))

(defun mutecipher-acp--session->index-entry (session)
  "Build a picker-friendly index entry from a `macp-session' SESSION."
  (list :id          (macp-session-id session)
        :agent       (macp-session-agent session)
        :cwd         (macp-session-cwd session)
        :title       (macp-session-title session)
        :last-active (macp-session-last-active session)
        :model       (mutecipher-acp--resolve-model
                      (macp-session-available-modes session)
                      (macp-session-current-mode-id session))))

(defun mutecipher-acp--snapshot->index-entry (snap)
  "Build an index entry from a SNAP plist (as written to disk)."
  (list :id          (plist-get snap :id)
        :agent       (plist-get snap :agent)
        :cwd         (plist-get snap :cwd)
        :title       (plist-get snap :title)
        :last-active (plist-get snap :last-active)
        :model       (mutecipher-acp--resolve-model
                      (plist-get snap :available-modes)
                      (plist-get snap :current-mode-id))))

;;;; Save

(defun mutecipher-acp--save-session (session)
  "Persist SESSION's transcript and snapshot to disk.

Short-circuits in three cases:
  - The session id fails the safety regex.  Dirty flag is cleared so
    the sweeper stops re-trying.
  - SESSION's `loading' flag is t (session/load replay in progress).
    Dirty flag is preserved so a save fires once replay completes.
  - The session has no nodes and no queued prompts.  No content
    worth writing.  Clears dirty so we don't retry endlessly.

All errors are caught and logged.  On error the dirty flag is also
cleared so a programming bug (struct shape mismatch, void
variable, etc.) doesn't trap the idle sweeper in an infinite
log-spam loop — one failure is logged, then we stop trying for
this session until the next mutation."
  (let* ((id   (macp-session-id session))
         (path (and id (mutecipher-acp--session-file id))))
    (cond
     ((null path)
      (setf (macp-session-persist-dirty session) nil))
     ((macp-session-loading session)
      nil)
     (t
      (condition-case err
          (let ((nodes (mutecipher-acp--collect-session-nodes session))
                (queue (macp-session-prompt-queue session)))
            (cond
             ((and (null nodes) (null queue))
              ;; Nothing worth persisting.
              (setf (macp-session-persist-dirty session) nil))
             (t
              (let ((payload
                     (list :schema-version
                           mutecipher-acp--persist-schema-version
                           :session (mutecipher-acp--session-snapshot session)
                           :nodes nodes)))
                (mutecipher-acp--persist-write-sexp path payload)
                (setf (macp-session-persist-dirty session) nil)))))
        (error
         (message "ACP persist: save-session failed: %s"
                  (error-message-string err))
         ;; Clear dirty so a recurring programming bug doesn't
         ;; spam *Messages* every idle tick.  Real fixes will
         ;; surface again via the next legitimate mutation.
         (setf (macp-session-persist-dirty session) nil)))))))

(defun mutecipher-acp--load-disk-snapshots ()
  "Read every `<id>.eld' on disk; return alist of (id . snapshot-plist).
Files with unknown schema versions are skipped (and logged).
This is O(N) over the cache directory — call sparingly."
  (let ((dir (mutecipher-acp--persist-dir))
        (results nil))
    (dolist (path (directory-files dir t "\\.eld\\'"))
      (unless (string= (file-name-nondirectory path) "index.eld")
        (let* ((sexp (mutecipher-acp--persist-read-sexp path))
               (ver  (and sexp (plist-get sexp :schema-version)))
               (snap (and sexp (plist-get sexp :session))))
          (cond
           ((null sexp) nil)
           ((not (eql ver mutecipher-acp--persist-schema-version))
            (message "ACP persist: skipping %s (schema %S, want %d)"
                     (file-name-nondirectory path) ver
                     mutecipher-acp--persist-schema-version))
           (snap
            (push (cons (plist-get snap :id) snap) results))))))
    (nreverse results)))

(defun mutecipher-acp--save-index ()
  "Rewrite `index.eld' from in-memory sessions, preserving disk-only entries.
Reads ONLY the existing `index.eld' (one file) — does not rescan the
whole cache directory.  Live in-memory sessions win on conflict;
entries on disk that this Emacs has never loaded are passed through
so a parallel Emacs's contributions aren't clobbered.  Use
`mutecipher/acp-rebuild-index' to do a full O(N) rebuild from
on-disk `.eld' files."
  (condition-case err
      (let* ((live-ids
              (let (ids)
                (maphash (lambda (_id session)
                           (when (mutecipher-acp--persist-safe-id-p
                                  (macp-session-id session))
                             (push (macp-session-id session) ids)))
                         mutecipher-acp--sessions)
                ids))
             (live-entries
              (let (acc)
                (maphash
                 (lambda (_id session)
                   (when (mutecipher-acp--persist-safe-id-p
                          (macp-session-id session))
                     (push (mutecipher-acp--session->index-entry session)
                           acc)))
                 mutecipher-acp--sessions)
                acc))
             (existing (mutecipher-acp--persist-read-sexp
                        (mutecipher-acp--index-file)))
             (existing-version (and existing
                                    (plist-get existing :schema-version)))
             (existing-entries
              (cond
               ((and existing
                     (eql existing-version
                          mutecipher-acp--persist-schema-version))
                (plist-get existing :entries))
               (t
                ;; Index unreadable or wrong schema — recover by
                ;; harvesting headers from every `<id>.eld' on disk so a
                ;; parallel Emacs's entries (or older-format remnants)
                ;; aren't silently dropped by our save.
                (mapcar (lambda (pair)
                          (mutecipher-acp--snapshot->index-entry
                           (cdr pair)))
                        (mutecipher-acp--load-disk-snapshots)))))
             (preserved
              (cl-remove-if
               (lambda (e)
                 (or (null (plist-get e :id))
                     (member (plist-get e :id) live-ids)))
               existing-entries))
             (merged (append live-entries preserved))
             (sorted (sort merged
                           (lambda (a b)
                             (> (or (plist-get a :last-active) 0)
                                (or (plist-get b :last-active) 0)))))
             (payload (list :schema-version
                            mutecipher-acp--persist-schema-version
                            :entries sorted)))
        (mutecipher-acp--persist-write-sexp
         (mutecipher-acp--index-file) payload))
    (error
     (message "ACP persist: save-index failed: %s"
              (error-message-string err)))))

(defun mutecipher-acp--read-index ()
  "Return the list of index entries, or nil if the index is missing/invalid.
Falls back to a full O(N) glob+read of on-disk snapshots when the
index is unreadable or the schema doesn't match."
  (let* ((sexp (mutecipher-acp--persist-read-sexp
                (mutecipher-acp--index-file)))
         (ver  (and sexp (plist-get sexp :schema-version))))
    (cond
     ((and sexp (eql ver mutecipher-acp--persist-schema-version))
      (plist-get sexp :entries))
     (t
      (mapcar (lambda (pair)
                (mutecipher-acp--snapshot->index-entry (cdr pair)))
              (mutecipher-acp--load-disk-snapshots))))))

;;;###autoload
(defun mutecipher/acp-forget-session (session-id)
  "Delete the on-disk transcript for SESSION-ID and drop it from the index.
Useful after `session/load' fails with \"Invalid params\" or \"session
not found\" — the agent no longer recognizes the id, but the local
cache keeps offering it in the picker."
  (interactive
   (let* ((entries (mutecipher-acp--read-index))
          (alist
           (delq nil
                 (mapcar
                  (lambda (e)
                    (when-let ((label (mutecipher-acp--format-resume-label e)))
                      (cons label (plist-get e :id))))
                  entries))))
     (unless alist
       (user-error "ACP: no sessions in index"))
     (let ((choice (completing-read "Forget session: "
                                    (mapcar #'car alist) nil t)))
       (list (cdr (assoc choice alist))))))
  (condition-case err
      (progn
        ;; Tear down the in-memory session FIRST — otherwise the next
        ;; --close-turn or idle flush would recreate the .eld file and
        ;; index entry we're about to delete.
        (when (gethash session-id mutecipher-acp--sessions)
          (mutecipher-acp--teardown-session session-id))
        (let ((path (mutecipher-acp--session-file session-id)))
          (when (and path (file-exists-p path))
            (delete-file path)))
        (let* ((existing  (mutecipher-acp--persist-read-sexp
                           (mutecipher-acp--index-file)))
               (entries   (and existing (plist-get existing :entries)))
               (kept      (cl-remove-if
                           (lambda (e)
                             (equal (plist-get e :id) session-id))
                           entries)))
          (mutecipher-acp--persist-write-sexp
           (mutecipher-acp--index-file)
           (list :schema-version mutecipher-acp--persist-schema-version
                 :entries kept)))
        (message "ACP: forgot session %s"
                 (mutecipher-acp--id-prefix session-id)))
    (error
     (message "ACP persist: forget-session failed: %s"
              (error-message-string err)))))

;;;###autoload
(defun mutecipher/acp-rebuild-index ()
  "Rebuild `index.eld' from scratch by scanning every `<id>.eld'.
Use this after manual cache surgery (deleted files, migrated paths,
or to re-merge entries from a parallel Emacs)."
  (interactive)
  (let* ((live-ids
          (let (ids)
            (maphash (lambda (_id s)
                       (push (macp-session-id s) ids))
                     mutecipher-acp--sessions)
            ids))
         (live-entries
          (let (acc)
            (maphash
             (lambda (_id s)
               (when (mutecipher-acp--persist-safe-id-p
                      (macp-session-id s))
                 (push (mutecipher-acp--session->index-entry s) acc)))
             mutecipher-acp--sessions)
            acc))
         (disk-entries
          (mapcar (lambda (pair)
                    (mutecipher-acp--snapshot->index-entry (cdr pair)))
                  (mutecipher-acp--load-disk-snapshots)))
         (disk-only
          (cl-remove-if
           (lambda (e)
             (or (null (plist-get e :id))
                 (member (plist-get e :id) live-ids)))
           disk-entries))
         (merged (append live-entries disk-only))
         (sorted (sort merged
                       (lambda (a b)
                         (> (or (plist-get a :last-active) 0)
                            (or (plist-get b :last-active) 0))))))
    (condition-case err
        (progn
          (mutecipher-acp--persist-write-sexp
           (mutecipher-acp--index-file)
           (list :schema-version mutecipher-acp--persist-schema-version
                 :entries sorted))
          (message "ACP: rebuilt index (%d entries)" (length sorted)))
      (error
       (message "ACP persist: rebuild-index failed: %s"
                (error-message-string err))))))

;;;; Hydrate from disk

(declare-function mutecipher-acp--enqueue-prompt
                  "mutecipher-acp-session" (session-id text))
(declare-function mutecipher-acp--teardown-session
                  "mutecipher-acp-session" (session-id &optional skip-buffer))

(defun mutecipher-acp--hydrate-session-from-disk (session)
  "Populate SESSION's struct fields and EWOC from its on-disk transcript.
Idempotent: if the EWOC already has any content, returns without
touching it.  Re-registers `node-index' and `tool-call-index' as it
walks the saved nodes so callers downstream can address them by
uuid / call-id.

`cwd' is restored from the snapshot so the session continues to
treat its original directory as canonical even when the user
resumes from a different `default-directory'.

`prompt-queue' is replayed by calling `--enqueue-prompt' for each
saved string — that keeps the visual `queued' EWOC cards and the
in-memory queue list in lockstep (we don't persist queued EWOC
nodes; they're reconstructed here).

Used by `mutecipher-acp--load-session' BEFORE issuing `session/load'
so resumed sessions render their prior transcript immediately."
  (let* ((id   (macp-session-id session))
         (path (mutecipher-acp--session-file id))
         (sexp (and path (mutecipher-acp--persist-read-sexp path)))
         (ver  (and sexp (plist-get sexp :schema-version)))
         (snap (and sexp (plist-get sexp :session)))
         (nodes (and sexp (plist-get sexp :nodes)))
         (queue (and sexp (plist-get snap :prompt-queue)))
         (buf   (macp-session-buffer session)))
    (cond
     ((or (null sexp) (not (eql ver mutecipher-acp--persist-schema-version)))
      nil)
     ((not (buffer-live-p buf))
      (when nodes
        (message "ACP persist: skipping hydrate for %s — buffer not live"
                 (mutecipher-acp--id-prefix id))))
     (t
      (with-current-buffer buf
        (cond
         ((or (not (boundp 'mutecipher-acp--ewoc))
              (null mutecipher-acp--ewoc))
          (when nodes
            (message "ACP persist: skipping hydrate for %s — EWOC not initialized"
                     (mutecipher-acp--id-prefix id))))
         ((not (null (ewoc-nth mutecipher-acp--ewoc 0)))
          ;; Already populated; idempotent no-op.
          nil)
         (t
          ;; Apply persisted session metadata before nodes so the mode-line
          ;; refresh during/after hydration sees authoritative state.
          (when snap
            (when-let ((cwd (plist-get snap :cwd)))
              (setf (macp-session-cwd session) cwd))
            (when-let ((title (plist-get snap :title)))
              (setf (macp-session-title session) title))
            (when-let ((modes (plist-get snap :available-modes)))
              (setf (macp-session-available-modes session) modes))
            (when-let ((mode-id (plist-get snap :current-mode-id)))
              (setf (macp-session-current-mode-id session) mode-id))
            (when-let ((cmds (plist-get snap :commands)))
              (setf (macp-session-commands session) cmds))
            (when-let ((counter (plist-get snap :turn-counter)))
              (setf (macp-session-turn-counter session) counter))
            (when-let ((at (plist-get snap :last-active)))
              (setf (macp-session-last-active session) at)))
          ;; Replay nodes through `--ewoc-enter-tail' which preserves
          ;; existing uuids and (re)populates `node-index'.  Also
          ;; repopulate `tool-call-index' so a post-load `tool_call_update'
          ;; from the agent finds the right node — for grouped reads
          ;; that means mapping every child's call-id to the group's
          ;; ewoc node so the update path's `--node-find-tc' resolves
          ;; correctly.
          (let ((inhibit-read-only t)
                (tc-index (macp-session-tool-call-index session))
                (last-open-group-node nil))
            (dolist (node nodes)
              (let ((entered (mutecipher-acp--ewoc-enter-tail
                              mutecipher-acp--ewoc nil node)))
                (pcase (macp-node-kind node)
                  ('tool-call
                   (when-let* ((data (macp-node-data node))
                               ((macp-tool-call-p data))
                               (call-id (macp-tool-call-call-id data)))
                     (puthash call-id entered tc-index))
                   ;; Any node other than a tool-group ends the
                   ;; potential trailing-open-group run; clear the
                   ;; sentinel so we don't restore an earlier group.
                   (setq last-open-group-node nil))
                  ('tool-group
                   ;; Type-guard against a hand-edited or schema-skewed
                   ;; .eld that pairs `:kind 'tool-group' with mismatched
                   ;; `:data' — degrade gracefully instead of signalling
                   ;; `wrong-type-argument' mid-hydrate.
                   (when-let* ((group (macp-node-data node))
                               ((macp-tool-group-p group)))
                     (dolist (tc (macp-tool-group-children group))
                       (when-let ((call-id (macp-tool-call-call-id tc)))
                         (puthash call-id entered tc-index)))
                     ;; Remember the last STILL-OPEN group as we walk
                     ;; in insertion order; if it ends up being the
                     ;; trailing node, the next live read should fold
                     ;; into it instead of opening a fresh card next
                     ;; to the persisted one.
                     (setq last-open-group-node
                           (if (macp-tool-group-closed group)
                               nil
                             entered))))
                  ;; Any other kind closes the run too.
                  (_ (setq last-open-group-node nil)))))
            (when last-open-group-node
              (setf (mutecipher-acp--session-current-tool-group session)
                    last-open-group-node)))
          ;; Reset the queue field and replay via the normal enqueue path
          ;; — that re-creates the `queued' EWOC nodes and re-anchors
          ;; `queue-head-node' identically to a live enqueue.
          (when queue
            (setf (macp-session-prompt-queue session) nil
                  (macp-session-queue-head-node session) nil)
            (dolist (text queue)
              (mutecipher-acp--enqueue-prompt id text))))))))))

;;;; Dirty tracking

(defun mutecipher-acp--mark-dirty (session)
  "Mark SESSION as needing a save.
Does NOT bump `last-active' — see `--bump-last-active' for that.
Runs even during session/load replay so server-authoritative
state changes (mode, title, commands) reach disk; the WRITE itself
still waits because `--save-session' short-circuits while
`loading' is t."
  (when session
    (setf (macp-session-persist-dirty session) t)))

(defun mutecipher-acp--bump-last-active (session)
  "Mark SESSION dirty AND bump its `last-active' to now.
Used by sites that represent real user/agent activity (open-turn,
close-turn, user prompt, assistant streaming).  Runs during replay
too — the WRITE is gated by `--save-session', not the bump."
  (when session
    (setf (macp-session-last-active session) (float-time)
          (macp-session-persist-dirty session) t)))

(defun mutecipher-acp--mark-dirty-by-id (session-id)
  "Mark SESSION-ID dirty; no-op if no such session."
  (mutecipher-acp--mark-dirty
   (gethash session-id mutecipher-acp--sessions)))

(defun mutecipher-acp--bump-last-active-by-id (session-id)
  "Bump `last-active' on SESSION-ID; no-op if no such session."
  (mutecipher-acp--bump-last-active
   (gethash session-id mutecipher-acp--sessions)))

(defun mutecipher-acp--flush-all-dirty ()
  "Save every dirty session, then rewrite the index.
Called from the idle timer and `kill-emacs-hook'."
  (let ((any nil))
    (maphash (lambda (_id session)
               (when (macp-session-persist-dirty session)
                 (setq any t)
                 (mutecipher-acp--save-session session)))
             mutecipher-acp--sessions)
    (when any
      (mutecipher-acp--save-index))))

;;;; Picker label

(defun mutecipher-acp--format-relative-time (at)
  "Render AT (float-time) as a short relative string like \"5m ago\"."
  (if (not (numberp at))
      "—"
    (let* ((dt (max 0 (- (float-time) at))))
      (cond
       ((< dt 60)       (format "%ds ago"  (truncate dt)))
       ((< dt 3600)     (format "%dm ago"  (truncate (/ dt 60))))
       ((< dt 86400)    (format "%dh ago"  (truncate (/ dt 3600))))
       ((< dt 2592000)  (format "%dd ago"  (truncate (/ dt 86400))))
       (t               (format-time-string "%Y-%m-%d" at))))))

(defun mutecipher-acp--format-resume-label (entry)
  "Render an index ENTRY plist as a one-line picker label.
Returns nil for an entry whose `:id' is missing so callers can
skip it instead of crashing."
  (let* ((id (plist-get entry :id)))
    (when (stringp id)
      (let* ((title    (or (plist-get entry :title)
                           (mutecipher-acp--id-prefix id)))
             (cwd      (or (plist-get entry :cwd) ""))
             (cwd-s    (abbreviate-file-name cwd))
             (relative (mutecipher-acp--format-relative-time
                        (plist-get entry :last-active)))
             (model    (or (plist-get entry :model) ""))
             (pref     (mutecipher-acp--id-prefix id)))
        (format "%s  %s  %s  %s  [%s]"
                title cwd-s relative model pref)))))

;;;; Idle timer + kill-emacs

(defvar mutecipher-acp--persist-idle-timer nil
  "Running idle timer that sweeps dirty sessions to disk.")

(defun mutecipher-acp--persist-install-idle-timer ()
  "Ensure exactly one idle timer is sweeping dirty sessions.
Cancels any pre-existing timer running `--flush-all-dirty' first so
re-evaluating this file during development does not leak timers."
  (cancel-function-timers #'mutecipher-acp--flush-all-dirty)
  (setq mutecipher-acp--persist-idle-timer
        (run-with-idle-timer mutecipher-acp-persist-idle-seconds
                             t #'mutecipher-acp--flush-all-dirty)))

(defun mutecipher-acp-persist-unload-function ()
  "Cleanup hook run by `unload-feature' for `mutecipher-acp-persist'.
Cancels the idle timer and removes our `kill-emacs-hook'.  Returns
nil so `unload-feature' proceeds with its default symbol removal."
  (cancel-function-timers #'mutecipher-acp--flush-all-dirty)
  (setq mutecipher-acp--persist-idle-timer nil)
  (remove-hook 'kill-emacs-hook #'mutecipher-acp--flush-all-dirty)
  nil)

(mutecipher-acp--persist-sweep-tmp)
(mutecipher-acp--persist-install-idle-timer)
(add-hook 'kill-emacs-hook #'mutecipher-acp--flush-all-dirty)

(provide 'mutecipher-acp-persist)
;;; mutecipher-acp-persist.el ends here
