;;; mutecipher-git-blame.el --- Git blame info in the mode-line  -*- lexical-binding: t -*-
;;
;; Displays the git blame annotation for the line at point as a mode-line
;; segment.  The annotation updates automatically after a short idle delay and
;; is cached per line so git is only invoked when the cursor visits a line for
;; the first time (or after the buffer is edited and the cache is invalidated).
;;
;; Uncommitted lines (all-zero SHA) clear the segment silently.
;;
;; No third-party dependencies.  Requires only `git' on PATH.
;;
;; Entry points:
;;   `mutecipher-git-blame-mode'        — buffer-local minor mode
;;   `mutecipher-git-blame-global-mode' — enable automatically in vc files
;;
;; Mode-line integration — add this segment to `mode-line-format':
;;   (:eval (mutecipher-git-blame-mode-line-segment))

;;; Code:

;;;; Mode-line segment

(defvar-local mutecipher-git-blame--segment nil
  "Propertized mode-line string for the current line's blame, or nil.")

(defun mutecipher-git-blame-mode-line-segment ()
  "Return the blame mode-line string for the current buffer, or nil."
  (when (bound-and-true-p mutecipher-git-blame-mode)
    mutecipher-git-blame--segment))

;;;; Git subprocess

(defun mutecipher-git-blame--run (file line)
  "Return a blame plist for LINE (1-based) in FILE, or nil.
Plist keys: `:author' `:email' `:time'.
Returns nil when the line is uncommitted or git fails."
  (let ((default-directory (file-name-directory file)))
    (with-temp-buffer
      (when (zerop (call-process "git" nil t nil
                                 "blame" "--porcelain"
                                 "-L" (format "%d,%d" line line)
                                 "--" file))
        (goto-char (point-min))
        (when (looking-at "\\([0-9a-f]\\{40\\}\\)")
          (let ((sha (match-string 1)))
            (unless (string= sha "0000000000000000000000000000000000000000")
              (let (author email time)
                (while (not (eobp))
                  (cond
                   ((looking-at "author \\(.+\\)")
                    (setq author (match-string 1)))
                   ((looking-at "author-mail \\(.+\\)")
                    (setq email (match-string 1)))
                   ((looking-at "author-time \\([0-9]+\\)")
                    (setq time (string-to-number (match-string 1)))))
                  (forward-line 1))
                (when (and author time)
                  (list :sha sha :author author :email (or email "") :time time))))))))))

;;;; Remote URL (cached per buffer)

(defvar-local mutecipher-git-blame--remote-base nil
  "Cached HTTPS base URL for this buffer's git remote (e.g. https://github.com/user/repo).
The symbol `none' means the remote was fetched but could not be parsed.")

(defun mutecipher-git-blame--fetch-remote-base ()
  "Return the HTTPS base URL for the current buffer's git remote, or nil."
  (unless mutecipher-git-blame--remote-base
    (let ((raw (with-temp-buffer
                 (when (zerop (call-process "git" nil t nil
                                            "remote" "get-url" "origin"))
                   (string-trim (buffer-string))))))
      (setq mutecipher-git-blame--remote-base
            (if raw
                (let* ((r (replace-regexp-in-string   ; SSH → HTTPS
                           "\\`git@\\([^:]+\\):" "https://\\1/" raw))
                       (r (replace-regexp-in-string    ; strip .git suffix
                           "\\.git\\'" "" r)))
                  (if (string-match-p "\\`https?://" r) r 'none))
              'none))))
  (unless (eq mutecipher-git-blame--remote-base 'none)
    mutecipher-git-blame--remote-base))

(defun mutecipher-git-blame--commit-url (sha)
  "Return a browser URL for SHA on the remote, or nil."
  (when-let ((base (mutecipher-git-blame--fetch-remote-base)))
    (format "%s/commit/%s" base sha)))

;;;; Formatting

(defun mutecipher-git-blame--relative-time (unix-time)
  "Return a human-readable relative time string for UNIX-TIME."
  (let* ((delta  (- (float-time) unix-time))
         (minute 60.0)
         (hour   3600.0)
         (day    86400.0)
         (week   (* 7.0  day))
         (month  (* 30.0 day))
         (year   (* 365.0 day)))
    (cond
     ((< delta (* 2 minute)) "just now")
     ((< delta hour)         (format "%dm ago"      (round (/ delta minute))))
     ((< delta (* 2 hour))   "1h ago")
     ((< delta day)          (format "%dh ago"      (round (/ delta hour))))
     ((< delta (* 2 day))    "yesterday")
     ((< delta week)         (format "%dd ago"      (round (/ delta day))))
     ((< delta (* 2 week))   "last week")
     ((< delta month)        (format "%dw ago"      (round (/ delta week))))
     ((< delta (* 2 month))  "last month")
     ((< delta year)         (format "%dmo ago"     (round (/ delta month))))
     ((< delta (* 2 year))   "last year")
     (t                      (format "%dy ago"      (round (/ delta year)))))))

(defun mutecipher-git-blame--format (data)
  "Return a propertized mode-line string from blame plist DATA.
When a remote URL can be derived, the segment is clickable (mouse-1)."
  (let* ((author   (plist-get data :author))
         (email    (plist-get data :email))
         (time     (mutecipher-git-blame--relative-time (plist-get data :time)))
         (first    (car (split-string author)))
         (text     (format "%s · %s" first time))
         (tooltip  (format "%s %s · %s" author email time))
         (url      (mutecipher-git-blame--commit-url (plist-get data :sha)))
         (str      (propertize text 'face 'font-lock-comment-face)))
    (if url
        (let ((map (make-sparse-keymap)))
          (define-key map [mode-line mouse-1]
            (lambda () (interactive) (browse-url url)))
          (propertize str
                      'mouse-face  'mode-line-highlight
                      'help-echo   (format "mouse-1: open commit in browser\n%s\n%s" tooltip url)
                      'local-map   map))
      (propertize str 'help-echo tooltip))))

;;;; Per-line cache

(defvar-local mutecipher-git-blame--cache nil
  "Hash table mapping line numbers to blame plists (or `none') for this buffer.")

(defun mutecipher-git-blame--cache-get (line)
  "Return cached blame data for LINE, or `miss' if not cached."
  (if mutecipher-git-blame--cache
      (gethash line mutecipher-git-blame--cache 'miss)
    'miss))

(defun mutecipher-git-blame--cache-put (line data)
  "Cache DATA (or nil → stored as `none') for LINE."
  (unless mutecipher-git-blame--cache
    (setq mutecipher-git-blame--cache (make-hash-table :test 'eql)))
  (puthash line (or data 'none) mutecipher-git-blame--cache))

(defun mutecipher-git-blame--cache-invalidate (&rest _)
  "Discard the blame cache.  Bound to `after-change-functions'."
  (setq mutecipher-git-blame--cache nil))

;;;; Update logic

(defvar-local mutecipher-git-blame--last-line nil)
(defvar-local mutecipher-git-blame--timer nil)

(defun mutecipher-git-blame--schedule ()
  "Cancel any pending timer and schedule a fresh lookup."
  (when (timerp mutecipher-git-blame--timer)
    (cancel-timer mutecipher-git-blame--timer))
  (setq mutecipher-git-blame--timer
        (run-with-idle-timer 0.5 nil #'mutecipher-git-blame--update
                             (current-buffer))))

(defun mutecipher-git-blame--update (buf)
  "Refresh the blame mode-line segment for the line at point in BUF."
  (when (and (buffer-live-p buf)
             (buffer-local-value 'mutecipher-git-blame-mode buf))
    (with-current-buffer buf
      (let* ((line   (line-number-at-pos))
             (cached (mutecipher-git-blame--cache-get line)))
        (setq mutecipher-git-blame--last-line line)
        (cond
         ((and (not (eq cached 'miss)) (not (eq cached 'none)))
          (setq mutecipher-git-blame--segment (mutecipher-git-blame--format cached)))
         ((eq cached 'none)
          (setq mutecipher-git-blame--segment nil))
         (t
          (when buffer-file-name
            (let ((data (mutecipher-git-blame--run buffer-file-name line)))
              (mutecipher-git-blame--cache-put line data)
              (setq mutecipher-git-blame--segment
                    (when data (mutecipher-git-blame--format data)))))))
        (force-mode-line-update)))))

(defun mutecipher-git-blame--on-command ()
  "Schedule a blame update when the line at point changes."
  (when (and buffer-file-name (vc-registered buffer-file-name))
    (unless (eq (line-number-at-pos) mutecipher-git-blame--last-line)
      (mutecipher-git-blame--schedule))))

;;;; Minor modes

;;;###autoload
(define-minor-mode mutecipher-git-blame-mode
  "Show git blame for the line at point in the mode-line."
  :lighter nil
  (if mutecipher-git-blame-mode
      (progn
        (setq mutecipher-git-blame--last-line  nil
              mutecipher-git-blame--cache      nil
              mutecipher-git-blame--segment    nil
              mutecipher-git-blame--remote-base nil)
        (add-hook 'post-command-hook     #'mutecipher-git-blame--on-command  nil t)
        (add-hook 'after-change-functions #'mutecipher-git-blame--cache-invalidate nil t))
    (when (timerp mutecipher-git-blame--timer)
      (cancel-timer mutecipher-git-blame--timer))
    (setq mutecipher-git-blame--timer      nil
          mutecipher-git-blame--last-line  nil
          mutecipher-git-blame--cache      nil
          mutecipher-git-blame--segment    nil
          mutecipher-git-blame--remote-base nil)
    (remove-hook 'post-command-hook     #'mutecipher-git-blame--on-command  t)
    (remove-hook 'after-change-functions #'mutecipher-git-blame--cache-invalidate t)
    (force-mode-line-update)))

;;;###autoload
(define-globalized-minor-mode mutecipher-git-blame-global-mode
  mutecipher-git-blame-mode
  (lambda ()
    (when (and buffer-file-name (vc-registered buffer-file-name))
      (mutecipher-git-blame-mode 1))))

(provide 'mutecipher-git-blame)
;;; mutecipher-git-blame.el ends here
