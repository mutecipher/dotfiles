;;; mutecipher-containers.el --- Container management via Podman/Docker  -*- lexical-binding: t -*-
;;
;; Provides a transient-based UI for managing containers and images through
;; Podman or Docker.  Container and image listings use tabulated-list-mode;
;; transient menus handle actions.  Log streaming, exec sessions (via term),
;; and JSON inspection are all opened in dedicated buffers.
;;
;; Entry points:
;;   `mutecipher-containers/dispatch' — main transient menu (bind to a key)
;;   `mutecipher-containers/list'     — list running containers
;;   `mutecipher-containers/list-all' — list all containers
;;   `mutecipher-containers/images'   — list images

;;; Code:

(require 'cl-lib)
(require 'transient)
(require 'tabulated-list)
(require 'ansi-color)
(require 'term)
(require 'json)

;;;; Customization

(defgroup mutecipher-containers nil
  "Container management via Podman or Docker."
  :group 'tools
  :prefix "mutecipher-containers-")

(defun mutecipher-containers--detect-backend ()
  "Return first available container CLI, or \"podman\" as fallback."
  (or (executable-find "podman")
      (executable-find "docker")
      "podman"))

(defcustom mutecipher-containers-backend (mutecipher-containers--detect-backend)
  "Container CLI executable. Auto-detected, prefers podman over docker."
  :type 'string
  :group 'mutecipher-containers)

(defcustom mutecipher-containers-shell "/bin/sh"
  "Shell to launch inside a container for exec sessions."
  :type 'string
  :group 'mutecipher-containers)

(defcustom mutecipher-containers-log-lines 200
  "Number of recent log lines to fetch on initial log view (0 = all)."
  :type 'integer
  :group 'mutecipher-containers)

;;;; Faces

(defface mutecipher-containers-running
  '((t :inherit success))
  "Face for containers with a running status."
  :group 'mutecipher-containers)

(defface mutecipher-containers-stopped
  '((t :inherit liminal-faded))
  "Face for containers that are stopped or exited."
  :group 'mutecipher-containers)

(defface mutecipher-containers-error
  '((t :inherit error))
  "Face for containers in an error or dead state."
  :group 'mutecipher-containers)

(defface mutecipher-containers-id
  '((t :inherit liminal-faded))
  "Face for short container/image IDs."
  :group 'mutecipher-containers)

(defface mutecipher-containers-header
  '((t :inherit liminal-strong))
  "Face for section headers in output buffers."
  :group 'mutecipher-containers)

;;;; Core subprocess helpers

(defun mutecipher-containers--run-sync (&rest args)
  "Run the container backend with ARGS synchronously.
Return stdout as a string, or nil on non-zero exit."
  (with-temp-buffer
    (when (zerop (apply #'call-process mutecipher-containers-backend
                        nil t nil args))
      (buffer-string))))

(defun mutecipher-containers--run-async (callback &rest args)
  "Run the container backend with ARGS asynchronously.
On successful exit, CALLBACK is invoked with stdout in the buffer that
was current when this function was called.  Non-zero exits are reported
via `message'."
  (let* ((source-buf (current-buffer))
         (buf (generate-new-buffer " *containers-async*"))
         (proc (apply #'start-process "mutecipher-containers" buf
                      mutecipher-containers-backend args)))
    (set-process-sentinel
     proc
     (lambda (p _)
       (let* ((status (process-status p))
              (exit   (process-exit-status p))
              (stdout (and (buffer-live-p (process-buffer p))
                           (with-current-buffer (process-buffer p)
                             (buffer-string)))))
         (when (buffer-live-p (process-buffer p))
           (kill-buffer (process-buffer p)))
         (cond
          ((and (memq status '(exit signal)) (zerop exit))
           (when (buffer-live-p source-buf)
             (with-current-buffer source-buf
               (funcall callback stdout))))
          ((memq status '(exit signal))
           (message "%s %s failed (exit %s): %s"
                    mutecipher-containers-backend
                    (string-join args " ")
                    exit (string-trim (or stdout ""))))))))))

(defun mutecipher-containers--mutate-and-refresh (refresh-fn &rest args)
  "Run backend with ARGS, then call REFRESH-FN in the source buffer.
Point is restored to its original line after the refresh so that mutating
actions don't kick the cursor back to the top of the list."
  (let ((line (line-number-at-pos)))
    (apply #'mutecipher-containers--run-async
           (lambda (_)
             (funcall refresh-fn)
             (goto-char (point-min))
             (forward-line (max 0 (1- line))))
           args)))

(defun mutecipher-containers--parse-json (str)
  "Parse STR as a JSON array or newline-delimited JSON objects.
Returns a list of alists."
  (when (and str (not (string-empty-p (string-trim str))))
    (condition-case nil
        (let ((parsed (json-parse-string str :object-type 'alist :array-type 'list)))
          (if (listp parsed) parsed (list parsed)))
      (json-parse-error
       ;; newline-delimited JSON (docker --format json output)
       (delq nil
             (mapcar (lambda (line)
                       (when (not (string-empty-p (string-trim line)))
                         (condition-case nil
                             (json-parse-string line :object-type 'alist :array-type 'list)
                           (json-parse-error nil))))
                     (split-string str "\n" t)))))))

(defun mutecipher-containers--prepare-stream-buffer (name header-text)
  "Get-or-create NAME as a log-mode buffer with HEADER-TEXT inserted."
  (let ((buf (get-buffer-create name)))
    (with-current-buffer buf
      (mutecipher-containers-log-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize header-text
                            'face 'mutecipher-containers-header))))
    buf))

(defun mutecipher-containers--stream-into-buffer (proc-name buf argv)
  "Start ARGV under PROC-NAME, streaming stdout into BUF with ANSI colors.
Follows the tail when point is at `point-max'; appends an `[exit-status]'
trailer when the process finishes."
  (let ((proc (apply #'start-process proc-name buf argv)))
    (set-process-filter
     proc
     (lambda (p str)
       (when (buffer-live-p (process-buffer p))
         (with-current-buffer (process-buffer p)
           (let ((inhibit-read-only t)
                 (at-end (= (point) (point-max))))
             (save-excursion
               (goto-char (point-max))
               (insert str)
               (ansi-color-apply-on-region
                (- (point) (length str)) (point)))
             (when at-end (goto-char (point-max))))))))
    (set-process-sentinel
     proc
     (lambda (p _)
       (when (buffer-live-p (process-buffer p))
         (with-current-buffer (process-buffer p)
           (let ((inhibit-read-only t))
             (goto-char (point-max))
             (insert (propertize (format "\n[%s]\n" (process-status p))
                                 'face 'mutecipher-containers-stopped)))))))
    proc))

;;;; List rendering and filtering

(defvar-local mutecipher-containers--filter nil
  "Regexp filter applied to the current list buffer, or nil for no filter.")

(defvar-local mutecipher-containers--all-rows nil
  "Last computed tabulated-list rows for the current buffer, pre-filter.")

(defun mutecipher-containers--rerender ()
  "Set `tabulated-list-entries' from cached rows, applying any filter."
  (setq tabulated-list-entries
        (if mutecipher-containers--filter
            (cl-remove-if-not
             (lambda (row)
               (cl-some (lambda (cell)
                          (string-match-p mutecipher-containers--filter
                                          (substring-no-properties cell)))
                        (cadr row)))
             mutecipher-containers--all-rows)
          mutecipher-containers--all-rows))
  (tabulated-list-print t))

(defun mutecipher-containers--do-filter (&optional clear)
  "Set a regexp filter on the current list buffer.
With prefix arg CLEAR, remove the filter.  An empty input also clears."
  (interactive "P")
  (setq mutecipher-containers--filter
        (cond (clear nil)
              (t (let ((input (read-string
                               "Filter (regexp, empty = clear): "
                               (or mutecipher-containers--filter ""))))
                   (and (not (string-empty-p input)) input)))))
  (mutecipher-containers--rerender))

;;;; Container list buffer

(defvar mutecipher-containers--show-all nil
  "When non-nil, show all containers; otherwise only running ones.")

(defvar-local mutecipher-containers--entries nil
  "Last fetched list of container alists for this buffer.")

(defun mutecipher-containers--status-face (status)
  "Return a face for STATUS string."
  (cond
   ((string-match-p "\\`[Uu]p\\|running" status) 'mutecipher-containers-running)
   ((string-match-p "\\(error\\|dead\\|oom\\)" status) 'mutecipher-containers-error)
   (t 'mutecipher-containers-stopped)))

(defun mutecipher-containers--format-ports (ports)
  "Format PORTS (a list or string) into a short display string."
  (cond
   ((null ports) "")
   ((stringp ports) ports)
   ((listp ports)
    (mapconcat
     (lambda (p)
       (let ((host (alist-get 'hostPort p))
             (cont (alist-get 'containerPort p))
             (proto (alist-get 'protocol p)))
         (if (and host cont)
             (format "%s→%s/%s" host cont (or proto "tcp"))
           "")))
     ports ", "))
   (t "")))

(defun mutecipher-containers--container-entries (data)
  "Convert a list of container alists DATA into tabulated-list entries."
  (mapcar
   (lambda (c)
     (let* ((id     (substring (or (alist-get 'Id c)
                                   (alist-get 'ID c) "?") 0 12))
            (names  (let ((n (alist-get 'Names c)))
                      (cond ((stringp n) n)
                            ((listp n)   (mapconcat (lambda (x)
                                                      (string-trim x "/"))
                                                    n ", "))
                            (t ""))))
            (image  (or (alist-get 'Image c) ""))
            (status (or (alist-get 'Status c)
                        (alist-get 'State c) ""))
            (ports  (mutecipher-containers--format-ports
                     (alist-get 'Ports c)))
            (created (or (alist-get 'Created c)
                         (alist-get 'CreatedAt c)
                         ""))
            (sface   (mutecipher-containers--status-face status)))
       (list id
             (vector
              (propertize id 'face 'mutecipher-containers-id)
              (propertize names 'face 'liminal-strong)
              image
              (propertize status 'face sface)
              ports
              (if (numberp created)
                  (format-time-string "%Y-%m-%d" created)
                (format "%s" created))))))
   data))

(defun mutecipher-containers--refresh ()
  "Fetch container data and re-render the list buffer."
  (let* ((args (if mutecipher-containers--show-all
                   '("ps" "-a" "--format" "json")
                 '("ps" "--format" "json")))
         (raw (apply #'mutecipher-containers--run-sync args)))
    (cond
     ((null raw)
      (message "%s %s failed" mutecipher-containers-backend (string-join args " "))
      (setq mutecipher-containers--entries nil
            mutecipher-containers--all-rows nil))
     (t
      (let ((data (mutecipher-containers--parse-json raw)))
        (setq mutecipher-containers--entries data
              mutecipher-containers--all-rows
              (mutecipher-containers--container-entries (or data '()))))))
    (mutecipher-containers--rerender)))

(defvar mutecipher-containers-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'mutecipher-containers--action-dispatch)
    (define-key map (kbd "g")   #'mutecipher-containers--do-refresh)
    (define-key map (kbd "s")   #'mutecipher-containers--do-start)
    (define-key map (kbd "S")   #'mutecipher-containers--do-stop)
    (define-key map (kbd "r")   #'mutecipher-containers--do-restart)
    (define-key map (kbd "d")   #'mutecipher-containers--do-rm)
    (define-key map (kbd "e")   #'mutecipher-containers--do-exec)
    (define-key map (kbd "l")   #'mutecipher-containers--do-logs)
    (define-key map (kbd "i")   #'mutecipher-containers--do-inspect)
    (define-key map (kbd "/")   #'mutecipher-containers--do-filter)
    (define-key map (kbd "?")   #'mutecipher-containers/container-actions)
    map)
  "Keymap for `mutecipher-containers-mode'.")

(define-derived-mode mutecipher-containers-mode tabulated-list-mode "Containers"
  "Major mode for listing and managing containers."
  (setq tabulated-list-format
        [("ID"      12 t)
         ("Name"    24 t)
         ("Image"   30 t)
         ("Status"  20 t)
         ("Ports"   22 t)
         ("Created" 12 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header)
  (setq-local revert-buffer-function (lambda (&rest _) (mutecipher-containers--refresh))))

(defun mutecipher-containers--container-id-at-point ()
  "Return the full container ID for the entry at point, or nil.
The tabulated row id is the short 12-char form; look up the full ID
in cached entries when available."
  (when-let ((id (tabulated-list-get-id)))
    (or (and mutecipher-containers--entries
             (cl-some (lambda (c)
                        (let ((full (or (alist-get 'Id c)
                                        (alist-get 'ID c))))
                          (when (and full (string-prefix-p id full)) full)))
                      mutecipher-containers--entries))
        id)))

(defun mutecipher-containers--container-name-at-point ()
  "Return a display name (Name or short ID) for the container at point."
  (when-let ((entry (tabulated-list-get-entry)))
    (let ((name (aref entry 1)))
      (if (string-empty-p (substring-no-properties name))
          (tabulated-list-get-id)
        (substring-no-properties name)))))

;;;; Container actions

(defun mutecipher-containers--do-refresh ()
  "Refresh the container list."
  (interactive)
  (mutecipher-containers--refresh))

(defun mutecipher-containers--do-start ()
  "Start container at point."
  (interactive)
  (when-let ((id (mutecipher-containers--container-id-at-point)))
    (message "Starting %s..." (mutecipher-containers--container-name-at-point))
    (mutecipher-containers--mutate-and-refresh
     #'mutecipher-containers--refresh "start" id)))

(defun mutecipher-containers--do-stop ()
  "Stop container at point."
  (interactive)
  (when-let ((id (mutecipher-containers--container-id-at-point)))
    (message "Stopping %s..." (mutecipher-containers--container-name-at-point))
    (mutecipher-containers--mutate-and-refresh
     #'mutecipher-containers--refresh "stop" id)))

(defun mutecipher-containers--do-restart ()
  "Restart container at point."
  (interactive)
  (when-let ((id (mutecipher-containers--container-id-at-point)))
    (message "Restarting %s..." (mutecipher-containers--container-name-at-point))
    (mutecipher-containers--mutate-and-refresh
     #'mutecipher-containers--refresh "restart" id)))

(defun mutecipher-containers--do-rm ()
  "Delete container at point (prompts for confirmation)."
  (interactive)
  (when-let ((id   (mutecipher-containers--container-id-at-point))
             (name (mutecipher-containers--container-name-at-point)))
    (when (yes-or-no-p (format "Delete container %s? " name))
      (mutecipher-containers--mutate-and-refresh
       #'mutecipher-containers--refresh "rm" "-f" id))))

(defun mutecipher-containers--do-exec ()
  "Open an exec session inside the container at point via term."
  (interactive)
  (when-let ((id   (mutecipher-containers--container-id-at-point))
             (name (mutecipher-containers--container-name-at-point)))
    (let* ((bufname (format "*containers-exec: %s*" name))
           (cmd (list mutecipher-containers-backend
                      "exec" "-it" id mutecipher-containers-shell))
           (buf (apply #'make-term (car (split-string bufname "[*: ]" t))
                       (car cmd) nil (cdr cmd))))
      (with-current-buffer buf
        (term-mode)
        (term-char-mode))
      (pop-to-buffer buf))))

(defun mutecipher-containers--do-logs ()
  "Stream recent logs for the container at point."
  (interactive)
  (when-let ((id   (mutecipher-containers--container-id-at-point))
             (name (mutecipher-containers--container-name-at-point)))
    (let* ((buf (mutecipher-containers--prepare-stream-buffer
                 (format "*containers-log: %s*" name)
                 (format "Logs: %s\n\n" name)))
           (tail-args (when (> mutecipher-containers-log-lines 0)
                        (list "--tail" (number-to-string mutecipher-containers-log-lines))))
           (argv (flatten-list (list mutecipher-containers-backend
                                     "logs" "-f" tail-args id))))
      (pop-to-buffer buf)
      (mutecipher-containers--stream-into-buffer "containers-log" buf argv))))

(defun mutecipher-containers--do-inspect ()
  "Show JSON inspection of the container at point."
  (interactive)
  (when-let ((id   (mutecipher-containers--container-id-at-point))
             (name (mutecipher-containers--container-name-at-point)))
    (let ((raw (mutecipher-containers--run-sync "inspect" id)))
      (when raw
        (let* ((bufname (format "*containers-inspect: %s*" name))
               (buf (get-buffer-create bufname)))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert raw))
            (if (fboundp 'json-ts-mode)
                (json-ts-mode)
              (js-mode))
            (read-only-mode 1)
            (goto-char (point-min)))
          (pop-to-buffer buf))))))

(defun mutecipher-containers--action-dispatch ()
  "Open per-container transient for the entry at point."
  (interactive)
  (if (tabulated-list-get-id)
      (mutecipher-containers/container-actions)
    (user-error "No container at point")))

;;;; Log buffer mode

(define-derived-mode mutecipher-containers-log-mode special-mode "Container-Log"
  "Mode for streaming container log output.")

;;;; Image list buffer

(defvar-local mutecipher-images--entries nil
  "Last fetched list of image alists for this buffer.")

(defun mutecipher-containers--image-entries (data)
  "Convert image alist DATA to tabulated-list entries."
  (mapcar
   (lambda (img)
     (let* ((id    (let ((raw (or (alist-get 'Id img)
                                  (alist-get 'ID img) "")))
                     (if (string-prefix-p "sha256:" raw)
                         (substring raw 7 19)
                       (substring raw 0 (min 12 (length raw))))))
            (repo  (or (alist-get 'Repository img)
                       (let ((names (alist-get 'Names img)))
                         (when names
                           (let* ((first (if (listp names) (car names) names))
                                  (parts (split-string first ":")))
                             (car parts))))
                       "<none>"))
            (tag   (or (alist-get 'Tag img)
                       (let ((names (alist-get 'Names img)))
                         (when names
                           (let* ((first (if (listp names) (car names) names))
                                  (parts (split-string first ":")))
                             (if (cdr parts) (cadr parts) "latest"))))
                       "<none>"))
            (size  (let ((s (alist-get 'Size img)))
                     (if (numberp s)
                         (file-size-human-readable s 'iec)
                       (or (format "%s" s) ""))))
            (created (or (alist-get 'Created img)
                         (alist-get 'CreatedAt img)
                         "")))
       (list id
             (vector
              (propertize id 'face 'mutecipher-containers-id)
              (propertize repo 'face 'liminal-strong)
              tag
              size
              (if (numberp created)
                  (format-time-string "%Y-%m-%d" created)
                (format "%s" created))))))
   data))

(defun mutecipher-images--refresh ()
  "Fetch image data and re-render the list buffer."
  (let ((raw (mutecipher-containers--run-sync "images" "--format" "json")))
    (cond
     ((null raw)
      (message "%s images failed" mutecipher-containers-backend)
      (setq mutecipher-images--entries nil
            mutecipher-containers--all-rows nil))
     (t
      (let ((data (mutecipher-containers--parse-json raw)))
        (setq mutecipher-images--entries data
              mutecipher-containers--all-rows
              (mutecipher-containers--image-entries (or data '()))))))
    (mutecipher-containers--rerender)))

(defvar mutecipher-images-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'mutecipher-images--action-dispatch)
    (define-key map (kbd "g")   #'mutecipher-images--do-refresh)
    (define-key map (kbd "d")   #'mutecipher-images--do-rm)
    (define-key map (kbd "p")   #'mutecipher-containers/pull)
    (define-key map (kbd "b")   #'mutecipher-containers/build)
    (define-key map (kbd "/")   #'mutecipher-containers--do-filter)
    (define-key map (kbd "?")   #'mutecipher-containers/image-actions)
    map)
  "Keymap for `mutecipher-images-mode'.")

(define-derived-mode mutecipher-images-mode tabulated-list-mode "Images"
  "Major mode for listing and managing container images."
  (setq tabulated-list-format
        [("ID"         12 t)
         ("Repository" 35 t)
         ("Tag"        20 t)
         ("Size"       10 t)
         ("Created"    12 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header)
  (setq-local revert-buffer-function (lambda (&rest _) (mutecipher-images--refresh))))

(defun mutecipher-images--image-id-at-point ()
  "Return the image ID for the entry at point."
  (tabulated-list-get-id))

(defun mutecipher-images--image-name-at-point ()
  "Return a display name (repo:tag) for the image at point."
  (when-let ((entry (tabulated-list-get-entry)))
    (let ((repo (substring-no-properties (aref entry 1)))
          (tag  (substring-no-properties (aref entry 2))))
      (if (string= repo "<none>") (tabulated-list-get-id)
        (format "%s:%s" repo tag)))))

(defun mutecipher-images--do-refresh ()
  "Refresh the image list."
  (interactive)
  (mutecipher-images--refresh))

(defun mutecipher-images--do-rm ()
  "Delete image at point (prompts for confirmation)."
  (interactive)
  (when-let ((id   (mutecipher-images--image-id-at-point))
             (name (mutecipher-images--image-name-at-point)))
    (when (yes-or-no-p (format "Delete image %s? " name))
      (mutecipher-containers--mutate-and-refresh
       #'mutecipher-images--refresh "rmi" id))))

(defun mutecipher-images--action-dispatch ()
  "Open per-image transient for the entry at point."
  (interactive)
  (if (tabulated-list-get-id)
      (mutecipher-containers/image-actions)
    (user-error "No image at point")))

;;;; Volume list buffer

(defvar-local mutecipher-volumes--entries nil
  "Last fetched list of volume alists for this buffer.")

(defun mutecipher-volumes--rows (data)
  "Convert volume alist DATA to tabulated-list rows."
  (mapcar
   (lambda (v)
     (let* ((name    (or (alist-get 'Name v) ""))
            (driver  (or (alist-get 'Driver v) ""))
            (mount   (or (alist-get 'Mountpoint v) ""))
            (created (or (alist-get 'CreatedAt v) (alist-get 'Created v) "")))
       (list name
             (vector
              (propertize name 'face 'liminal-strong)
              driver
              (propertize mount 'face 'mutecipher-containers-id)
              (if (numberp created)
                  (format-time-string "%Y-%m-%d" created)
                (format "%s" created))))))
   data))

(defun mutecipher-volumes--refresh ()
  "Fetch volume data and re-render the list buffer."
  (let ((raw (mutecipher-containers--run-sync "volume" "ls" "--format" "json")))
    (cond
     ((null raw)
      (message "%s volume ls failed" mutecipher-containers-backend)
      (setq mutecipher-volumes--entries nil
            mutecipher-containers--all-rows nil))
     (t
      (let ((data (mutecipher-containers--parse-json raw)))
        (setq mutecipher-volumes--entries data
              mutecipher-containers--all-rows
              (mutecipher-volumes--rows (or data '()))))))
    (mutecipher-containers--rerender)))

(defun mutecipher-volumes--do-refresh ()
  "Refresh the volume list."
  (interactive)
  (mutecipher-volumes--refresh))

(defun mutecipher-volumes--do-rm ()
  "Delete the volume at point (prompts for confirmation)."
  (interactive)
  (when-let ((name (tabulated-list-get-id)))
    (when (yes-or-no-p (format "Delete volume %s? " name))
      (mutecipher-containers--mutate-and-refresh
       #'mutecipher-volumes--refresh "volume" "rm" name))))

(defvar mutecipher-volumes-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'mutecipher-volumes--do-refresh)
    (define-key map (kbd "d") #'mutecipher-volumes--do-rm)
    (define-key map (kbd "/") #'mutecipher-containers--do-filter)
    map)
  "Keymap for `mutecipher-volumes-mode'.")

(define-derived-mode mutecipher-volumes-mode tabulated-list-mode "Volumes"
  "Major mode for listing and managing container volumes."
  (setq tabulated-list-format
        [("Name"       30 t)
         ("Driver"     10 t)
         ("Mountpoint" 50 t)
         ("Created"    12 t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header)
  (setq-local revert-buffer-function (lambda (&rest _) (mutecipher-volumes--refresh))))

;;;; Network list buffer

(defvar-local mutecipher-networks--entries nil
  "Last fetched list of network alists for this buffer.")

(defun mutecipher-networks--rows (data)
  "Convert network alist DATA to tabulated-list rows."
  (mapcar
   (lambda (n)
     (let* ((id     (let ((raw (or (alist-get 'Id n) (alist-get 'ID n) "")))
                      (substring raw 0 (min 12 (length raw)))))
            (name   (or (alist-get 'Name n) ""))
            (driver (or (alist-get 'Driver n) ""))
            (scope  (or (alist-get 'Scope n) "")))
       (list (or (and (not (string-empty-p name)) name) id)
             (vector
              (propertize id 'face 'mutecipher-containers-id)
              (propertize name 'face 'liminal-strong)
              driver
              scope))))
   data))

(defun mutecipher-networks--refresh ()
  "Fetch network data and re-render the list buffer."
  (let ((raw (mutecipher-containers--run-sync "network" "ls" "--format" "json")))
    (cond
     ((null raw)
      (message "%s network ls failed" mutecipher-containers-backend)
      (setq mutecipher-networks--entries nil
            mutecipher-containers--all-rows nil))
     (t
      (let ((data (mutecipher-containers--parse-json raw)))
        (setq mutecipher-networks--entries data
              mutecipher-containers--all-rows
              (mutecipher-networks--rows (or data '()))))))
    (mutecipher-containers--rerender)))

(defun mutecipher-networks--do-refresh ()
  "Refresh the network list."
  (interactive)
  (mutecipher-networks--refresh))

(defun mutecipher-networks--do-rm ()
  "Delete the network at point (prompts for confirmation)."
  (interactive)
  (when-let ((name (tabulated-list-get-id)))
    (when (yes-or-no-p (format "Delete network %s? " name))
      (mutecipher-containers--mutate-and-refresh
       #'mutecipher-networks--refresh "network" "rm" name))))

(defvar mutecipher-networks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'mutecipher-networks--do-refresh)
    (define-key map (kbd "d") #'mutecipher-networks--do-rm)
    (define-key map (kbd "/") #'mutecipher-containers--do-filter)
    map)
  "Keymap for `mutecipher-networks-mode'.")

(define-derived-mode mutecipher-networks-mode tabulated-list-mode "Networks"
  "Major mode for listing and managing container networks."
  (setq tabulated-list-format
        [("ID"     12 t)
         ("Name"   25 t)
         ("Driver" 10 t)
         ("Scope"  10 t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header)
  (setq-local revert-buffer-function (lambda (&rest _) (mutecipher-networks--refresh))))

;;;; Transient menus

;;;###autoload (autoload 'mutecipher-containers/dispatch "mutecipher-containers" nil t)
(transient-define-prefix mutecipher-containers/dispatch ()
  "Container and image management."
  [["Containers"
    ("c" "List running"  mutecipher-containers/list)
    ("a" "List all"      mutecipher-containers/list-all)]
   ["Images"
    ("i" "List images"   mutecipher-containers/images)]
   ["Other"
    ("v" "Volumes"       mutecipher-containers/volumes)
    ("n" "Networks"      mutecipher-containers/networks)]]
  [["Quick Actions"
    ("p" "Pull image"    mutecipher-containers/pull)
    ("b" "Build image"   mutecipher-containers/build)
    ("r" "Run container" mutecipher-containers/run)]
   ["Maintenance"
    ("P" "Prune containers" mutecipher-containers/prune-containers)
    ("I" "Prune images"     mutecipher-containers/prune-images)
    ("X" "Prune system"     mutecipher-containers/prune-system)]])

(transient-define-prefix mutecipher-containers/container-actions ()
  "Actions for the container at point."
  [["Lifecycle"
    ("s" "Start"   mutecipher-containers--do-start)
    ("S" "Stop"    mutecipher-containers--do-stop)
    ("r" "Restart" mutecipher-containers--do-restart)
    ("d" "Delete"  mutecipher-containers--do-rm)]
   ["Interact"
    ("e" "Exec shell" mutecipher-containers--do-exec)
    ("l" "Logs"       mutecipher-containers--do-logs)
    ("i" "Inspect"    mutecipher-containers--do-inspect)]])

(transient-define-prefix mutecipher-containers/image-actions ()
  "Actions for the image at point."
  [["Actions"
    ("d" "Delete"        mutecipher-images--do-rm)
    ("p" "Push"          mutecipher-containers/push)
    ("r" "Run from here" mutecipher-containers/run-from-image)]])

;;;; Interactive commands

(defun mutecipher-containers--show (all)
  "Open the container list buffer, showing all containers when ALL is non-nil."
  (let* ((buf (get-buffer-create "*containers*"))
         (win (display-buffer buf)))
    (with-current-buffer buf
      (mutecipher-containers-mode)
      (setq mutecipher-containers--show-all all)
      (mutecipher-containers--refresh))
    (select-window win)))

;;;###autoload
(defun mutecipher-containers/list ()
  "List running containers."
  (interactive)
  (mutecipher-containers--show nil))

;;;###autoload
(defun mutecipher-containers/list-all ()
  "List all containers (running and stopped)."
  (interactive)
  (mutecipher-containers--show t))

;;;###autoload
(defun mutecipher-containers/images ()
  "List container images."
  (interactive)
  (let* ((buf (get-buffer-create "*container-images*"))
         (win (display-buffer buf)))
    (with-current-buffer buf
      (mutecipher-images-mode)
      (mutecipher-images--refresh))
    (select-window win)))

;;;###autoload
(defun mutecipher-containers/volumes ()
  "List container volumes."
  (interactive)
  (let* ((buf (get-buffer-create "*container-volumes*"))
         (win (display-buffer buf)))
    (with-current-buffer buf
      (mutecipher-volumes-mode)
      (mutecipher-volumes--refresh))
    (select-window win)))

;;;###autoload
(defun mutecipher-containers/networks ()
  "List container networks."
  (interactive)
  (let* ((buf (get-buffer-create "*container-networks*"))
         (win (display-buffer buf)))
    (with-current-buffer buf
      (mutecipher-networks-mode)
      (mutecipher-networks--refresh))
    (select-window win)))

(defun mutecipher-containers--stream-prune (buf-name proc-name header args)
  "Pop to BUF-NAME, stream backend ARGS under PROC-NAME, prefix with HEADER."
  (let ((buf (mutecipher-containers--prepare-stream-buffer
              buf-name (concat header "\n\n"))))
    (pop-to-buffer buf)
    (mutecipher-containers--stream-into-buffer
     proc-name buf
     (cons mutecipher-containers-backend args))))

;;;###autoload
(defun mutecipher-containers/prune-containers ()
  "Remove all stopped containers."
  (interactive)
  (when (yes-or-no-p "Remove all stopped containers? ")
    (mutecipher-containers--stream-prune
     "*containers-prune*" "containers-prune"
     "Pruning stopped containers"
     '("container" "prune" "-f"))))

;;;###autoload
(defun mutecipher-containers/prune-images (&optional all)
  "Remove dangling images.  With prefix arg ALL, remove all unused images."
  (interactive "P")
  (when (yes-or-no-p (if all "Remove all unused images? "
                       "Remove dangling images? "))
    (mutecipher-containers--stream-prune
     "*containers-prune-images*" "containers-prune-images"
     (format "Pruning images%s" (if all " (all unused)" ""))
     (append '("image" "prune" "-f") (when all '("-a"))))))

;;;###autoload
(defun mutecipher-containers/prune-system ()
  "Remove unused containers, networks, images, and build cache."
  (interactive)
  (when (yes-or-no-p "Remove all unused resources (system prune)? ")
    (mutecipher-containers--stream-prune
     "*containers-prune-system*" "containers-prune-system"
     "System prune"
     '("system" "prune" "-f"))))

;;;###autoload
(defun mutecipher-containers/pull (image)
  "Pull IMAGE from a registry."
  (interactive "sPull image: ")
  (let ((buf (mutecipher-containers--prepare-stream-buffer
              "*containers-pull*"
              (format "Pulling: %s\n\n" image))))
    (pop-to-buffer buf)
    (mutecipher-containers--stream-into-buffer
     "containers-pull" buf
     (list mutecipher-containers-backend "pull" image))))

;;;###autoload
(defun mutecipher-containers/build (context tag)
  "Build an image from CONTEXT directory with TAG."
  (interactive
   (list (read-directory-name "Build context: " default-directory)
         (read-string "Image tag: ")))
  (let* ((buf (mutecipher-containers--prepare-stream-buffer
               "*containers-build*"
               (format "Building: %s → %s\n\n" context tag)))
         (args (cons mutecipher-containers-backend
                     (if (string-empty-p tag)
                         (list "build" context)
                       (list "build" "-t" tag context)))))
    (pop-to-buffer buf)
    (mutecipher-containers--stream-into-buffer "containers-build" buf args)))

;;;###autoload
(defun mutecipher-containers/run (image)
  "Run a new container from IMAGE, prompting for the image name."
  (interactive "sRun image: ")
  (let ((cmd (read-string (format "Command [%s %s]: " mutecipher-containers-backend image))))
    (let* ((bufname (format "*containers-run: %s*" image))
           (argv (flatten-list
                  (list mutecipher-containers-backend "run" "--rm" "-it"
                        image
                        (when (not (string-empty-p cmd))
                          (split-string-and-unquote cmd)))))
           (buf (apply #'make-term
                       (format "containers-run-%s" image)
                       (car argv) nil (cdr argv))))
      (with-current-buffer buf
        (rename-buffer bufname t)
        (term-mode)
        (term-char-mode))
      (pop-to-buffer buf))))

;;;###autoload
(defun mutecipher-containers/push (image)
  "Push IMAGE to a registry."
  (interactive
   (list (or (and (derived-mode-p 'mutecipher-images-mode)
                  (mutecipher-images--image-name-at-point))
             (read-string "Push image: "))))
  (message "Pushing %s..." image)
  (mutecipher-containers--run-async
   (lambda (_) (message "Pushed %s" image))
   "push" image))

;;;###autoload
(defun mutecipher-containers/run-from-image ()
  "Run a container from the image at point in the images list."
  (interactive)
  (if-let ((name (and (derived-mode-p 'mutecipher-images-mode)
                      (mutecipher-images--image-name-at-point))))
      (mutecipher-containers/run name)
    (call-interactively #'mutecipher-containers/run)))

(provide 'mutecipher-containers)
;;; mutecipher-containers.el ends here
