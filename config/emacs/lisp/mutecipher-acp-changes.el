;;; mutecipher-acp-changes.el --- Change-set revert for ACP turns  -*- lexical-binding: t -*-
;;
;; A turn's `:change-set' (populated lazily by `--maybe-capture-change-set'
;; in tools.el) lets us roll a turn back to its pre-edit state.  This
;; module owns:
;;
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
