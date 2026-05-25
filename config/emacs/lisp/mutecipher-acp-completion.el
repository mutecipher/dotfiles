;;; mutecipher-acp-completion.el --- File cache, attachments, capfs for ACP  -*- lexical-binding: t -*-
;;
;; @-mention file resolution, per-session file cache (project.el-aware,
;; with a fs-walk fallback), and the two completion-at-point functions
;; that drive `/'-slash and `@'-file completion in the composer.
;;
;; Also defines the local slash-command registry: a plist-of-plists
;; populated via `mutecipher-acp-register-slash-command'.  The capf
;; merges these with the server-provided command list.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'url-util)
(require 'mutecipher-acp-model)

(defcustom mutecipher-acp-file-cache-ttl 30
  "Seconds before `mutecipher-acp--session-files' re-walks a session's cwd."
  :type 'integer
  :group 'mutecipher-acp)

(defcustom mutecipher-acp-file-cache-max-items 2000
  "Maximum number of candidate files returned per session by `@'-completion."
  :type 'integer
  :group 'mutecipher-acp)

(defconst mutecipher-acp--file-exclude-dirs
  '(".git" "node_modules" ".direnv" ".venv" "vendor" "elpa" ".cache")
  "Directory basenames skipped by the fs fallback walker.")

(defvar mutecipher-acp--slash-commands nil
  "Alist of (NAME . PLIST) for client-side slash commands.
PLIST keys: :description (string), :handler (function of one arg, the
trimmed body string after the command name; returns non-nil if the
input was consumed and should NOT be sent to the agent).")

(defun mutecipher-acp-register-slash-command (name &rest plist)
  "Register a client-side slash command NAME with PLIST options."
  (setf (alist-get name mutecipher-acp--slash-commands nil nil #'equal) plist))

(defun mutecipher-acp--path->file-uri (abs-path)
  "Return a file:// URI for ABS-PATH with path segments percent-encoded."
  (concat "file://"
          (mapconcat #'url-hexify-string
                     (split-string (expand-file-name abs-path) "/")
                     "/")))

(defun mutecipher-acp--walk-cwd (cwd)
  "Walk CWD collecting relative file paths, skipping excluded dirs.
Returns a list sorted shallowest-first, capped at
`mutecipher-acp-file-cache-max-items'."
  (let ((root (file-name-as-directory (expand-file-name cwd)))
        (acc '())
        (count 0)
        (queue (list (file-name-as-directory (expand-file-name cwd)))))
    (while (and queue (< count mutecipher-acp-file-cache-max-items))
      (let ((dir (pop queue))
            (new-dirs nil))
        (dolist (entry (ignore-errors
                         (directory-files
                          dir t directory-files-no-dot-files-regexp t)))
          (cond
           ((file-directory-p entry)
            (unless (member (file-name-nondirectory entry)
                            mutecipher-acp--file-exclude-dirs)
              (push (file-name-as-directory entry) new-dirs)))
           ((file-regular-p entry)
            (push (file-relative-name entry root) acc)
            (setq count (1+ count)))))
        (when new-dirs
          (setq queue (nconc queue (nreverse new-dirs))))))
    (sort acc (lambda (a b)
                (let ((da (cl-count ?/ a))
                      (db (cl-count ?/ b)))
                  (if (= da db) (string< a b) (< da db)))))))

(defun mutecipher-acp--session-files (session)
  "Return a cached (SOURCE . LIST) pair of relative paths for SESSION's :cwd.
SOURCE is the symbol `project' or `fs'."
  (let* ((cwd   (macp-session-cwd session))
         (cache (macp-session-file-cache session))
         (now   (float-time)))
    (if (and cache
             (< (- now (nth 0 cache)) mutecipher-acp-file-cache-ttl))
        (cons (nth 1 cache) (nth 2 cache))
      (let* ((proj  (and cwd
                         (let ((default-directory cwd))
                           (project-current nil cwd))))
             (files (if proj
                        (mapcar (lambda (f) (file-relative-name f cwd))
                                (project-files proj))
                      (and cwd (mutecipher-acp--walk-cwd cwd))))
             (source (if proj 'project 'fs))
             (capped (if (> (length files) mutecipher-acp-file-cache-max-items)
                         (seq-take files mutecipher-acp-file-cache-max-items)
                       files)))
        (setf (macp-session-file-cache session) (list now source capped))
        (cons source capped)))))

(defun mutecipher-acp--extract-attachments (text cwd)
  "Scan TEXT for @-mentions and return ((TOKEN . ABS-PATH) ...)."
  (let ((seen (make-hash-table :test #'equal))
        (out  '())
        (case-fold-search nil))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "@\\([^ \t\n\r]+\\)" nil t)
        (let* ((raw     (match-string-no-properties 1))
               (trimmed (replace-regexp-in-string
                         "[.,;:!?)}'\"]+\\'" "" raw))
               (abs     (when (and cwd (> (length trimmed) 0))
                          (if (file-name-absolute-p trimmed)
                              (expand-file-name trimmed)
                            (expand-file-name trimmed cwd)))))
          (when (and abs
                     (not (gethash abs seen))
                     (file-regular-p abs))
            (puthash abs t seen)
            (push (cons trimmed abs) out)))))
    (nreverse out)))

(defun mutecipher-acp--prompt-blocks (text cwd)
  "Return the :prompt vector for TEXT resolved against CWD."
  (let* ((attachments (mutecipher-acp--extract-attachments text cwd))
         (text-block  (list :type "text" :text text))
         (link-blocks (mapcar
                       (lambda (a)
                         (let ((abs (cdr a)))
                           (list :type "resource_link"
                                 :uri  (mutecipher-acp--path->file-uri abs)
                                 :name (file-name-nondirectory abs))))
                       attachments)))
    (apply #'vector text-block link-blocks)))

(defun mutecipher-acp--commands-capf ()
  "Completion-at-point function for ACP slash commands.
Activates when the current line begins with \"/\".  Merges server-
provided commands with the local registry."
  (when-let* ((session-id mutecipher-acp--session-id)
              (session    (gethash session-id mutecipher-acp--sessions))
              (_ (save-excursion
                   (beginning-of-line)
                   (looking-at "/"))))
    (let* ((server   (macp-session-commands session))
           (cmd-map  (nconc
                      (mapcar (lambda (c)
                                (cons (concat "/" (plist-get c :name))
                                      (plist-get c :description)))
                              server)
                      (mapcar (lambda (entry)
                                (cons (concat "/" (car entry))
                                      (plist-get (cdr entry) :description)))
                              mutecipher-acp--slash-commands)))
           (slash-pos (save-excursion (beginning-of-line) (point)))
           (word-end  (point)))
      (when cmd-map
        (list slash-pos word-end (mapcar #'car cmd-map)
              :annotation-function
              (lambda (name)
                (when-let ((desc (cdr (assoc name cmd-map))))
                  (concat "  " desc)))
              :company-kind (lambda (_) 'keyword))))))

(defun mutecipher-acp--files-capf ()
  "Completion-at-point function for @-mention file attachments."
  (when-let* ((session-id mutecipher-acp--session-id)
              (session    (gethash session-id mutecipher-acp--sessions))
              (at-pos     (save-excursion
                            (skip-chars-backward "^ \t\n")
                            (and (eq (char-after) ?@) (point)))))
    (let* ((cache      (mutecipher-acp--session-files session))
           (source     (car cache))
           (files      (cdr cache))
           (candidates (mapcar (lambda (f) (concat "@" f)) files))
           (tag        (if (eq source 'project) "[project]" "[fs]")))
      (list at-pos (point) candidates
            :annotation-function (lambda (_) (concat "  " tag))
            :exclusive 'no
            :exit-function (lambda (_s status)
                             (when (eq status 'finished)
                               (insert " ")))
            :company-kind (lambda (_) 'file)))))

(provide 'mutecipher-acp-completion)
;;; mutecipher-acp-completion.el ends here
