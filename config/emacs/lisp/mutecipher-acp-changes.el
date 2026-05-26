;;; mutecipher-acp-changes.el --- Per-turn change tracking and revert for ACP  -*- lexical-binding: t -*-
;;
;; A turn's `:change-set' lets us roll its file mutations back to their
;; pre-edit state.  This module owns both halves of that:
;;
;; Capture (consumed by `mutecipher-acp-tools.el' during ingest):
;;   - reverse-applying the just-arrived (oldText . newText) pairs
;;     against the on-disk file to reconstruct the pre-turn content
;;   - merging incremental diff deliveries into one snapshot per file
;;     per turn
;;   - invalidating the turn's badge in the transcript on changes
;;
;; Revert:
;;   - locating the turn at point in the session buffer
;;   - applying a single file's revert (restore content or delete the
;;     newly-created file via the system trash)
;;   - refreshing any visiting buffer of a reverted file
;;   - cross-turn awareness: warning when newer turns also touched the
;;     same path and refusing to clobber unsaved buffer modifications
;;   - the interactive `mutecipher/acp-revert-turn' entry point

;;; Code:

(require 'cl-lib)
(require 'ewoc)
(require 'mutecipher-acp-model)
(require 'mutecipher-acp-ewoc)    ; for the `--with-sticky-tail' macro
(require 'mutecipher-acp-persist) ; for `--mark-dirty'
(require 'mutecipher-acp-log)     ; for `--log-warn'

(defcustom mutecipher-acp-change-set-max-bytes (* 256 1024)
  "Maximum file size for which pre-turn snapshots are stored inline.
Files larger than this are tracked in the change-set but with
`capture-status' = `suppressed-too-large' — revert refuses to operate on
them rather than ballooning the on-disk transcript."
  :type 'integer
  :group 'mutecipher-acp)

;;;; Change-set capture
;;
;; The ACP server applies edits BEFORE notifying us, so by the time a
;; diff lands on a tool-call the file on disk is already in its
;; post-edit state.  To support "revert this turn" we reverse-apply the
;; just-arrived (old . new) pairs against the current disk content to
;; reconstruct what the file looked like before the turn touched it.
;;
;; The snapshot is captured ONCE per file per turn — the first time we
;; see any mutation against a given path within the active turn.  All
;; subsequent edits to the same file in the turn append their call-ids
;; to the existing file-change without disturbing `pre-turn-content',
;; which is exactly the rollback target we want.

(defun mutecipher-acp--resolve-loc-path (tc cwd)
  "Return TC's first location's path canonicalized to an absolute path, or nil.
Always passes through `expand-file-name' (handles `./', `..', trailing
slashes, `~') and `file-truename' (resolves symlinks) so the same
physical file keys identically across `assoc' lookups regardless of
the form the agent reports."
  (let* ((locs (macp-tool-call-locations tc))
         (loc  (and locs (> (length locs) 0) (aref locs 0)))
         (path (and loc (plist-get loc :path))))
    (when (stringp path)
      (let ((expanded (expand-file-name path cwd)))
        (condition-case _err
            (file-truename expanded)
          (error expanded))))))

(defun mutecipher-acp--replace-unique (needle replacement haystack)
  "Return HAYSTACK with the unique occurrence of NEEDLE replaced by REPLACEMENT.
Returns nil if NEEDLE is absent OR appears more than once — the reverse-
apply must refuse ambiguous matches rather than silently rewriting the
wrong span of an unrelated occurrence."
  (when (and (stringp needle) (not (string-empty-p needle))
             (stringp haystack))
    (let* ((first  (string-search needle haystack))
           (second (and first
                        (string-search needle haystack (1+ first)))))
      (cond
       ((null first) nil)
       (second       nil)  ; ambiguous — multiple matches
       (t (concat (substring haystack 0 first)
                  (or replacement "")
                  (substring haystack (+ first (length needle)))))))))

(defun mutecipher-acp--reverse-apply-pairs (content pairs)
  "Reverse-apply PAIRS to CONTENT; return (RESULT . STATUS).
PAIRS is a list of (oldText . newText) cons cells in chronological
(arrival) order.  Iteration is REVERSE-chronological — for chained
edits (MultiEdit-style, where edit N+1's oldText was edit N's newText)
the last edit must be undone first against the post-edit content.

Status outcomes:
  `ok'                     all pairs reversed successfully
  `reverse-apply-failed'   any pair's newText is missing OR ambiguous
                           (multiple matches), OR a pair represents a
                           deletion (non-empty oldText, empty newText)
                           which cannot be reversed without a position
                           anchor

A pair with BOTH halves empty is a no-op and skipped."
  (let ((work content)
        (status 'ok))
    (catch 'fail
      (dolist (pair (reverse pairs))
        (let* ((old (car pair))
               (new (cdr pair))
               (old-empty (or (null old) (string-empty-p old)))
               (new-empty (or (null new) (string-empty-p new))))
          (cond
           ;; Both empty: trivial no-op pair.
           ((and old-empty new-empty) nil)
           ;; Deletion (non-empty old, empty new): we can't reinsert
           ;; without knowing where, so refuse.
           (new-empty
            (setq status 'reverse-apply-failed)
            (throw 'fail nil))
           ;; Normal case: replace unique occurrence of new with old.
           (t
            (let ((replaced (mutecipher-acp--replace-unique new old work)))
              (cond
               (replaced (setq work replaced))
               (t (setq status 'reverse-apply-failed)
                  (throw 'fail nil)))))))))
    (cons (and (eq status 'ok) work) status)))

(defun mutecipher-acp--capture-snapshot (path pairs)
  "Snapshot PATH's pre-turn content using PAIRS to reverse the on-disk state.
Returns a plist `(:pre-turn-content C :pre-turn-existed E :capture-status S)'.
Honors `mutecipher-acp-change-set-max-bytes' — files over the cap are
recorded with status `suppressed-too-large' and no content.

Heuristic for distinguishing Write-creates from Write-overwrites:
when reverse-apply yields the empty string AND at least one pair had
an empty `oldText', the file was created by the turn — revert will
delete it.  An empty file overwritten to empty falls into the same
branch, but deleting an empty file is benign."
  (let* ((existed (file-exists-p path))
         (attrs   (and existed (file-attributes path)))
         (size    (and attrs (file-attribute-size attrs))))
    (cond
     ((not existed)
      ;; Edge case: file is gone at capture time.  Nothing to snapshot;
      ;; revert is a no-op.
      (list :pre-turn-content nil
            :pre-turn-existed nil
            :capture-status   'ok))
     ((and size (> size mutecipher-acp-change-set-max-bytes))
      (list :pre-turn-content nil
            :pre-turn-existed t
            :capture-status   'suppressed-too-large))
     (t
      (let* ((current (with-temp-buffer
                        ;; Force `-unix' so a CRLF file isn't EOL-detected
                        ;; into LF in memory — otherwise `string-search'
                        ;; matches the LF-normalized newText against the
                        ;; LF buffer, snapshot is stored as LF, and revert
                        ;; flips the file's line endings.  Match the
                        ;; persist layer (mutecipher-acp-persist.el:87,99).
                        (let ((coding-system-for-read 'utf-8-unix))
                          (insert-file-contents path))
                        (buffer-string)))
             (result   (mutecipher-acp--reverse-apply-pairs current pairs))
             (restored (car result))
             (status   (cdr result))
             (likely-creation
              (and (eq status 'ok)
                   (or (null restored) (string-empty-p restored))
                   (cl-some (lambda (p)
                              (or (null (car p))
                                  (string-empty-p (car p))))
                            pairs))))
        (cond
         ((not (eq status 'ok))
          (list :pre-turn-content nil
                :pre-turn-existed t
                :capture-status   'reverse-apply-failed))
         (likely-creation
          (list :pre-turn-content nil
                :pre-turn-existed nil
                :capture-status   'ok))
         (t
          (list :pre-turn-content restored
                :pre-turn-existed t
                :capture-status   'ok))))))))

(defun mutecipher-acp--cs-merge-call-id (fc call-id)
  "Append CALL-ID to FC's tool-call-ids if not already present."
  (when (and call-id
             (not (member call-id (macp-file-change-tool-call-ids fc))))
    (setf (macp-file-change-tool-call-ids fc)
          (append (macp-file-change-tool-call-ids fc) (list call-id)))))

(defun mutecipher-acp--cs-write-file-change (cs path fc)
  "Insert or replace PATH's entry in change-set CS with FC.
The alist is appended-to (rather than nconc'd at the head) so the
visual order in any future review panel matches insertion order."
  (let ((existing (assoc path (macp-change-set-files cs))))
    (if existing
        (setcdr existing fc)
      (setf (macp-change-set-files cs)
            (append (macp-change-set-files cs) (list (cons path fc)))))))

(defun mutecipher-acp--maybe-capture-change-set (session tc new-pairs)
  "Update SESSION's current-turn change-set from a mutation on TC.
NEW-PAIRS is the just-ingested sublist of `(oldText . newText)' cells.
May be nil — see retroactive-capture rules below.

Capture decisions:

  - First observation of TC's path: snapshot from disk reverse-applied
    through every pair we have for this turn touching this path
    (NEW-PAIRS, or fall back to the tc's full `:diffs' for retroactive
    capture when locations arrived late on a follow-up update).
  - Existing entry with NEW-PAIRS: accumulate the new pairs into the
    file-change's history and re-snapshot.  Required so incremental
    diff delivery on a single tool call doesn't bake intermediate
    state into the pre-turn snapshot.
  - Existing entry currently `capture-status'=`reverse-apply-failed':
    retry — a failed capture during status='pending' (before the file
    was mutated) may now succeed against the post-edit disk content.
  - Existing entry with no new pairs and `ok' status: just record
    CALL-ID against the file-change.

All I/O is wrapped in `condition-case' so a permission or read failure
on one file doesn't cascade out into the RPC handler and break the
agent's turn — failures are logged and capture-status reflects the
gap."
  (when (and session (or new-pairs (macp-tool-call-diffs tc)))
    (when-let* ((turn-node (macp-session-current-turn-node session))
                (turn     (macp-node-data (ewoc-data turn-node)))
                ((macp-turn-p turn))
                (path     (mutecipher-acp--resolve-loc-path
                           tc (macp-session-cwd session))))
      (let ((badge-may-change nil))
        ;; Narrow to the error classes that can legitimately arise from
        ;; the on-disk file or a malformed pair payload: `file-error'
        ;; (permission, missing parent), `args-out-of-range' (slot
        ;; access on a truncated struct, e.g. cross-schema), and
        ;; `wrong-type-argument' (string-search/replace on a non-string
        ;; pair half).  Programmer mistakes — `void-function',
        ;; `void-variable', `wrong-number-of-arguments' — propagate so
        ;; we don't silently swallow accessor drift as a benign capture
        ;; warning.
        (condition-case err
            (let* ((cs (or (macp-turn-change-set turn)
                           (setf (macp-turn-change-set turn)
                                 (make-macp-change-set :files nil))))
                   (existing (cdr (assoc path (macp-change-set-files cs))))
                   (call-id (macp-tool-call-call-id tc))
                   (should-snapshot
                    (or (null existing)
                        new-pairs
                        (eq (macp-file-change-capture-status existing)
                            'reverse-apply-failed))))
              (cond
               (should-snapshot
                (let* ((prior-pairs (and existing
                                         (macp-file-change-accumulated-pairs
                                          existing)))
                       ;; For retroactive capture (first observation, no
                       ;; new-pairs), fall back to the tc's full diffs —
                       ;; that's the only history we have.
                       (effective-new (or new-pairs
                                          (and (null existing)
                                               (macp-tool-call-diffs tc))))
                       (all-pairs (append prior-pairs effective-new))
                       (snap (mutecipher-acp--capture-snapshot path all-pairs))
                       (fc (make-macp-file-change
                            :path             path
                            :pre-turn-content (plist-get snap :pre-turn-content)
                            :pre-turn-existed (plist-get snap :pre-turn-existed)
                            :capture-status   (plist-get snap :capture-status)
                            :status           (or (and existing
                                                       (macp-file-change-status
                                                        existing))
                                                  'accepted)
                            :tool-call-ids    (and existing
                                                   (macp-file-change-tool-call-ids
                                                    existing))
                            :accumulated-pairs all-pairs)))
                  (mutecipher-acp--cs-merge-call-id fc call-id)
                  (mutecipher-acp--cs-write-file-change cs path fc)
                  (setq badge-may-change t)))
               (t
                (mutecipher-acp--cs-merge-call-id existing call-id)))
              (mutecipher-acp--mark-dirty session))
          ((file-error args-out-of-range wrong-type-argument)
           (mutecipher-acp--log-warn
            'agent-warn (macp-session-agent session)
            (format "[change-set] capture failed for %s: %s"
                    path (error-message-string err)))))
        ;; Invalidation is intentionally OUTSIDE the capture's condition-case
        ;; so a render-side signal isn't logged as a capture failure, and is
        ;; skipped on the no-op merge-call-id branch where the badge text
        ;; can't have changed.
        (when badge-may-change
          (condition-case render-err
              (when-let* ((buf (macp-session-buffer session))
                          ((buffer-live-p buf)))
                (mutecipher-acp--with-sticky-tail buf
                  (let ((inhibit-read-only t))
                    (ewoc-invalidate mutecipher-acp--ewoc turn-node))))
            ;; Same narrowing rationale as the capture catch: data /
            ;; transient buffer state can fail here (text-property
            ;; collisions, EWOC mid-mutation); programmer errors must
            ;; propagate.
            ((args-out-of-range wrong-type-argument buffer-read-only)
             (mutecipher-acp--log-warn
              'agent-warn (macp-session-agent session)
              (format "[change-set] badge render failed for %s: %s"
                      path (error-message-string render-err))))))))))

;;;; Turn lookup

(defun mutecipher-acp--turn-at-point ()
  "Return the `macp-turn' for the turn enclosing point, or nil.
Walks backward from point through the EWOC until a `turn-header' node
is found.  If point is past the last turn (e.g. in the composer area),
falls back to the most recent turn-header in the buffer."
  (when (and (boundp 'mutecipher-acp--ewoc) mutecipher-acp--ewoc)
    (let* ((ewoc mutecipher-acp--ewoc)
           (node (ewoc-locate ewoc (point)))
           (found nil))
      (while (and node (not found))
        (let ((data (ewoc-data node)))
          (if (eq (macp-node-kind data) 'turn-header)
              (setq found data)
            (setq node (ewoc-prev ewoc node)))))
      (unless found
        (let ((cur (ewoc-nth ewoc 0)))
          (while cur
            (let ((data (ewoc-data cur)))
              (when (eq (macp-node-kind data) 'turn-header)
                (setq found data)))
            (setq cur (ewoc-next ewoc cur)))))
      (and found (macp-node-data found)))))

(defun mutecipher-acp--turn-node-for-turn (turn)
  "Return the EWOC node whose data wraps TURN, or nil."
  (when (and turn (boundp 'mutecipher-acp--ewoc) mutecipher-acp--ewoc)
    (let ((ewoc mutecipher-acp--ewoc)
          (cur nil)
          (found nil))
      (setq cur (ewoc-nth ewoc 0))
      (while (and cur (not found))
        (let ((data (ewoc-data cur)))
          (when (and (eq (macp-node-kind data) 'turn-header)
                     (eq (macp-node-data data) turn))
            (setq found cur)))
        (setq cur (ewoc-next ewoc cur)))
      found)))

(defun mutecipher-acp--later-turns-after (turn)
  "Return turn-header `macp-turn' structs that appear AFTER TURN in the EWOC.
Used to warn about out-of-order reverts: turn N's `pre-turn-content'
is the disk state AFTER turn (N-1) committed, so reverting an earlier
turn while later turns also touched the same paths leaves the file in
a logically-incoherent half-state."
  (let (after-target collected)
    (when (and (boundp 'mutecipher-acp--ewoc) mutecipher-acp--ewoc)
      (let ((cur (ewoc-nth mutecipher-acp--ewoc 0)))
        (while cur
          (let ((data (ewoc-data cur)))
            (when (eq (macp-node-kind data) 'turn-header)
              (cond
               (after-target
                (push (macp-node-data data) collected))
               ((eq (macp-node-data data) turn)
                (setq after-target t)))))
          (setq cur (ewoc-next mutecipher-acp--ewoc cur)))))
    (nreverse collected)))

(defun mutecipher-acp--paths-touched-by-later-turns (turn target-paths)
  "Return the subset of TARGET-PATHS that any turn AFTER TURN also touched.
Only counts file-changes whose `status' is `accepted' — already-reverted
later turns are not in conflict."
  (let ((later (mutecipher-acp--later-turns-after turn))
        (conflicts nil))
    (dolist (lt later)
      (when-let ((cs (macp-turn-change-set lt)))
        (dolist (cell (macp-change-set-files cs))
          (let ((fc (cdr cell)))
            (when (and (eq (macp-file-change-status fc) 'accepted)
                       (member (macp-file-change-path fc) target-paths)
                       (not (member (macp-file-change-path fc) conflicts)))
              (push (macp-file-change-path fc) conflicts))))))
    (nreverse conflicts)))

;;;; Buffer interaction

(defun mutecipher-acp--canonical-name (path)
  "Return PATH canonicalized through `file-truename', or `expand-file-name'
when truename fails (deleted file with a missing parent, permission
issues).  Same canonicalization rule as `--resolve-loc-path' so the two
keys collate."
  (let ((expanded (expand-file-name path)))
    (condition-case _err
        (file-truename expanded)
      (error expanded))))

(defun mutecipher-acp--buffers-visiting (path)
  "Return live buffers visiting PATH (compared via canonical name)."
  (let ((target (mutecipher-acp--canonical-name path))
        result)
    (dolist (buf (buffer-list))
      (when-let* (((buffer-live-p buf))
                  (bfn (buffer-file-name buf))
                  ((string= (mutecipher-acp--canonical-name bfn) target)))
        (push buf result)))
    (nreverse result)))

(defun mutecipher-acp--modified-buffers-for (paths)
  "Return list of (path . buffer) pairs where buffer visits path and is modified."
  (let (modified)
    (dolist (path paths)
      (dolist (buf (mutecipher-acp--buffers-visiting path))
        (when (buffer-modified-p buf)
          (push (cons path buf) modified))))
    (nreverse modified)))

(defun mutecipher-acp--refresh-visiting-buffers (path)
  "Update any live buffer visiting PATH.
If the file still exists on disk, revert the buffer noconfirm.  If the
file was just deleted, mark the buffer modified (so the user notices
the divergence) and print a message — we don't kill the buffer because
the user may still want to recover its contents."
  (dolist (buf (mutecipher-acp--buffers-visiting path))
    (with-current-buffer buf
      (cond
       ((file-exists-p path)
        (revert-buffer t t t))
       (t
        (set-buffer-modified-p t)
        (message "ACP: %s was deleted; buffer is now stale"
                 (abbreviate-file-name path)))))))

;;;; Single-file revert

(defun mutecipher-acp--apply-file-revert (fc)
  "Apply FC's revert and return a status symbol.
Returns one of:
  `reverted'   — disk restored (or file deleted) successfully
  `skipped'    — `capture-status' was not `ok', or `status' was already
                 `reverted'; nothing was done
  `failed'     — a file-error was caught; the error message is sent to
                 *Messages* so the user can diagnose it.

Mutates FC's `status' slot to `reverted' on success.  Uses the system
trash for deletions (`delete-file ... t') so accidental reverts can be
recovered.  The condition-case is narrowed to `file-error' — logic
errors (e.g. a malformed file-change record) still surface as crashes
during development instead of being silently counted as `failed'."
  (cond
   ((not (eq (macp-file-change-capture-status fc) 'ok)) 'skipped)
   ((eq (macp-file-change-status fc) 'reverted) 'skipped)
   (t
    (condition-case err
        (let* ((path (macp-file-change-path fc))
               (pre  (macp-file-change-pre-turn-content fc))
               (existed (macp-file-change-pre-turn-existed fc)))
          (cond
           ;; File didn't exist pre-turn → agent created it.  Delete via trash.
           ((not existed)
            (when (file-exists-p path)
              (delete-file path t)))
           ;; File existed → restore prior content.  `-unix' to match the
           ;; capture-side read and keep EOL conventions stable.
           (t
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (or pre "") nil path nil 'silent))))
          (setf (macp-file-change-status fc) 'reverted)
          (mutecipher-acp--refresh-visiting-buffers path)
          'reverted)
      (file-error
       (message "ACP revert: %s failed: %s"
                (abbreviate-file-name (macp-file-change-path fc))
                (error-message-string err))
       'failed)))))

;;;; Interactive command

(defun mutecipher-acp--summarize-change-set (cs)
  "Return (REVERTIBLE SKIPPED-LARGE SKIPPED-FAILED ALREADY-REVERTED) counts."
  (let ((rev 0) (large 0) (failed 0) (done 0))
    (dolist (cell (macp-change-set-files cs))
      (let ((fc (cdr cell)))
        (pcase (macp-file-change-capture-status fc)
          ('ok
           (if (eq (macp-file-change-status fc) 'reverted)
               (cl-incf done)
             (cl-incf rev)))
          ('suppressed-too-large (cl-incf large))
          (_ (cl-incf failed)))))
    (list rev large failed done)))

(defun mutecipher-acp--revertible-paths (cs)
  "Return paths in CS that are eligible for revert (ok + accepted)."
  (let (paths)
    (dolist (cell (macp-change-set-files cs))
      (let ((fc (cdr cell)))
        (when (and (eq (macp-file-change-capture-status fc) 'ok)
                   (eq (macp-file-change-status fc) 'accepted))
          (push (macp-file-change-path fc) paths))))
    (nreverse paths)))

;;;###autoload
(defun mutecipher/acp-revert-turn ()
  "Revert every file mutation captured in the turn at point.
Walks the turn's `:change-set' and, for each file with a usable
snapshot, restores the pre-turn content (or deletes the file if the
turn created it).  Files whose snapshot was suppressed (too large) or
failed to capture are reported and skipped.

Safety prompts:

  - When later turns in the same session also touched any of the
    paths, the command warns before proceeding — the later turns'
    snapshots are anchored at THIS turn's post-edit state, so a
    revert that doesn't account for them leaves files in an
    incoherent state.
  - When any visiting buffer of a target file is modified
    (unsaved), the command refuses by default; the user must save
    or discard those changes first.

Any open buffer of a reverted file is reverted-in-place; if the
file was deleted by the revert, the buffer is marked modified
(not killed) so the user can recover its contents if needed."
  (interactive)
  (unless (and (boundp 'mutecipher-acp--session-id)
               mutecipher-acp--session-id)
    (user-error "ACP: not in a session buffer"))
  ;; Pin the session reference up-front so a mid-command teardown can't
  ;; race us into skipping the post-revert `--mark-dirty'.  The session
  ;; struct's `persist-dirty' slot is still reachable through this
  ;; binding even if the session is removed from `--sessions'.
  (let* ((session (gethash mutecipher-acp--session-id
                           mutecipher-acp--sessions))
         (turn (mutecipher-acp--turn-at-point))
         (_    (or turn (user-error "ACP: no turn at point")))
         (cs   (macp-turn-change-set turn))
         (_    (or cs (user-error "ACP: this turn has no captured changes")))
         (counts (mutecipher-acp--summarize-change-set cs))
         (rev    (nth 0 counts))
         (large  (nth 1 counts))
         (failed (nth 2 counts))
         (done   (nth 3 counts))
         (paths  (mutecipher-acp--revertible-paths cs))
         (modified (mutecipher-acp--modified-buffers-for paths))
         (later-conflicts
          (mutecipher-acp--paths-touched-by-later-turns turn paths)))
    (when (zerop rev)
      (user-error
       "ACP: nothing to revert (skipped: %d too large, %d capture failed, %d already reverted)"
       large failed done))
    (when modified
      (user-error
       "ACP: refusing to clobber %d unsaved buffer modification%s — save or discard first: %s"
       (length modified) (if (= 1 (length modified)) "" "s")
       (mapconcat (lambda (cell) (abbreviate-file-name (car cell)))
                  modified ", ")))
    (let* ((extras (delq nil
                         (list (and (> large 0)
                                    (format "%d too large" large))
                               (and (> failed 0)
                                    (format "%d capture failed" failed))
                               (and (> done 0)
                                    (format "%d already reverted" done)))))
           (suffix (if extras (format " (%s)" (mapconcat #'identity extras ", "))
                     ""))
           (warning (and later-conflicts
                         (format "WARNING: %d path%s also touched by later turn%s (%s) — reverting now will leave files in an incoherent state. "
                                 (length later-conflicts)
                                 (if (= 1 (length later-conflicts)) "" "s")
                                 (if (= 1 (length later-conflicts)) "" "s")
                                 (mapconcat #'abbreviate-file-name
                                            later-conflicts ", "))))
           (prompt (format "%sRevert %d file%s from turn #%d%s? "
                           (or warning "")
                           rev (if (= 1 rev) "" "s")
                           (macp-turn-id turn) suffix)))
      ;; `y-or-n-p' for the common case; `yes-or-no-p' (full-word
      ;; confirmation) for the dangerous out-of-order case so the user
      ;; can't sleepwalk through it.
      (when (if later-conflicts (yes-or-no-p prompt) (y-or-n-p prompt))
        (let ((reverted 0) (errors 0))
          (dolist (cell (macp-change-set-files cs))
            (pcase (mutecipher-acp--apply-file-revert (cdr cell))
              ('reverted (cl-incf reverted))
              ('failed   (cl-incf errors))
              (_ nil)))
          ;; Mark dirty via the pinned `session' reference (not a fresh
          ;; lookup) so the `status'='reverted slot mutations reach disk
          ;; even if the session was removed from `--sessions' mid-command.
          (when (and (> reverted 0) session)
            (mutecipher-acp--mark-dirty session))
          (when-let ((node (mutecipher-acp--turn-node-for-turn turn)))
            (mutecipher-acp--with-sticky-tail (current-buffer)
              (let ((inhibit-read-only t))
                (ewoc-invalidate mutecipher-acp--ewoc node))))
          (message "ACP: reverted %d file%s%s"
                   reverted (if (= 1 reverted) "" "s")
                   (if (> errors 0)
                       (format " (%d error%s — see *Messages*)" errors
                               (if (= 1 errors) "" "s"))
                     "")))))))

(provide 'mutecipher-acp-changes)
;;; mutecipher-acp-changes.el ends here
