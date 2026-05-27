;;; mutecipher-acp-tests.el --- Tests for mutecipher-acp  -*- lexical-binding: t -*-

;; Run with:
;;   emacs -Q --batch -L config/emacs/lisp -L config/emacs/test \
;;         -l config/emacs/test/mutecipher-acp-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'mutecipher-acp)

;;;; Pure helpers

(ert-deftest macp-test-id-prefix ()
  (should (equal (mutecipher-acp--id-prefix "abcd") "abcd"))
  (should (equal (mutecipher-acp--id-prefix "abcdefghij") "abcdefgh")))

(ert-deftest macp-test-tool-output-line-count ()
  (should (= 0 (mutecipher-acp--tool-output-line-count nil)))
  (should (= 0 (mutecipher-acp--tool-output-line-count "")))
  (should (= 1 (mutecipher-acp--tool-output-line-count "single")))
  (should (= 3 (mutecipher-acp--tool-output-line-count "a\nb\nc")))
  ;; Vector :rawOutput from MCP / ToolSearch tools must not crash and
  ;; should count joined text lines.
  (should (= 1 (mutecipher-acp--tool-output-line-count
                [(:type "text" :text "hello")])))
  (should (= 3 (mutecipher-acp--tool-output-line-count
                [(:type "text" :text "a\nb")
                 (:type "text" :text "c")]))))

(ert-deftest macp-test-normalize-raw-output ()
  (should (null (mutecipher-acp--normalize-raw-output nil)))
  (should (equal "hi" (mutecipher-acp--normalize-raw-output "hi")))
  (should (equal "hello"
                 (mutecipher-acp--normalize-raw-output
                  [(:type "text" :text "hello")])))
  (should (equal "a\nb"
                 (mutecipher-acp--normalize-raw-output
                  [(:type "text" :text "a")
                   (:type "text" :text "b")])))
  (should (equal "→ mcp__foo__bar"
                 (mutecipher-acp--normalize-raw-output
                  [(:type "tool_reference" :tool_name "mcp__foo__bar")]))))

(ert-deftest macp-test-truncate-output-for-display ()
  (let ((mutecipher-acp-tool-output-max-lines 3))
    (should (equal "a\nb\nc"
                   (mutecipher-acp--truncate-output-for-display "a\nb\nc")))
    (should (equal "a\nb\nc\n… 2 more lines"
                   (mutecipher-acp--truncate-output-for-display
                    "a\nb\nc\nd\ne")))
    (should (equal "a\nb\nc\n… 1 more line"
                   (mutecipher-acp--truncate-output-for-display
                    "a\nb\nc\nd")))))

(ert-deftest macp-test-format-tool-input-truncates ()
  (let ((mutecipher-acp-diff-max-lines 500))
    (should (equal "ls -la"
                   (mutecipher-acp--format-tool-input '(:command "ls -la"))))
    (should (equal "abc"
                   (mutecipher-acp--format-tool-input "abc")))
    (let ((s (make-string 80 ?x)))
      (should (string-suffix-p "…"
                               (mutecipher-acp--format-tool-input s 60))))))

(ert-deftest macp-test-option-extractors ()
  (should (equal "Allow"
                 (mutecipher-acp--option-label '(:name "Allow" :optionId "ok"))))
  (should (equal "ok"
                 (mutecipher-acp--option-id   '(:name "Allow" :optionId "ok"))))
  ;; Falls back to label when no id-shaped key is present.
  (should (equal "Allow"
                 (mutecipher-acp--option-id   '(:name "Allow")))))

(ert-deftest macp-test-path-to-file-uri-encodes-spaces ()
  (let ((uri (mutecipher-acp--path->file-uri "/tmp/some path/file.txt")))
    (should (string-prefix-p "file:///" uri))
    (should (string-match-p "some%20path" uri))))

(ert-deftest macp-test-raw-input-plan-extracts-string ()
  (should (equal "step 1\nstep 2"
                 (mutecipher-acp--raw-input-plan '(:plan "step 1\nstep 2"))))
  (should (null (mutecipher-acp--raw-input-plan '(:plan ""))))
  (should (null (mutecipher-acp--raw-input-plan '(:other "x")))))

;;;; Auto-collapse policy

(ert-deftest macp-test-auto-collapse-off-when-defcustom-nil ()
  "With `mutecipher-acp-collapse-tool-calls-by-default' nil, nothing collapses."
  (let ((mutecipher-acp-collapse-tool-calls-by-default nil))
    (let ((tc (make-macp-tool-call :status 'done
                                   :raw-output (make-string 1000 ?a))))
      (should-not (mutecipher-acp--should-auto-collapse-p tc)))
    (let ((tc (make-macp-tool-call :status 'done :raw-output ""
                                   :diffs '(("a" . "b")))))
      (should-not (mutecipher-acp--should-auto-collapse-p tc)))))

(ert-deftest macp-test-auto-collapse-on-by-default ()
  "Default-on: terminal-status tool calls collapse regardless of size."
  (let ((mutecipher-acp-collapse-tool-calls-by-default t))
    (let ((tc (make-macp-tool-call :status 'done :raw-output "one line")))
      (should (mutecipher-acp--should-auto-collapse-p tc)))
    (let ((tc (make-macp-tool-call :status 'done :raw-output "a\nb\nc\nd\ne")))
      (should (mutecipher-acp--should-auto-collapse-p tc)))
    (let ((tc (make-macp-tool-call :status 'error :raw-output ""
                                   :diffs '(("a" . "b")))))
      (should (mutecipher-acp--should-auto-collapse-p tc)))))

(ert-deftest macp-test-auto-collapse-pending ()
  (let ((mutecipher-acp-collapse-tool-calls-by-default t)
        (tc (make-macp-tool-call :status 'pending
                                 :raw-output (make-string 1000 ?a))))
    (should-not (mutecipher-acp--should-auto-collapse-p tc))))

(ert-deftest macp-test-auto-collapse-running ()
  (let ((mutecipher-acp-collapse-tool-calls-by-default t)
        (tc (make-macp-tool-call :status 'running
                                 :raw-output "a\nb\nc\nd\n")))
    (should-not (mutecipher-acp--should-auto-collapse-p tc))))

(ert-deftest macp-test-auto-collapse-plan-body-opts-out ()
  "Plan-body tool calls (ExitPlanMode) always stay expanded."
  (let ((mutecipher-acp-collapse-tool-calls-by-default t)
        (tc (make-macp-tool-call :status 'done
                                 :raw-output "a\nb\nc\nd\ne"
                                 :plan-body "Markdown plan body")))
    (should-not (mutecipher-acp--should-auto-collapse-p tc))))

;;;; Tool-content ingestion

(ert-deftest macp-test-ingest-tool-content-appends-diffs ()
  (let ((tc (make-macp-tool-call :rendered-diff-count 0))
        (vec (vector '(:type "diff" :oldText "a" :newText "b")
                     '(:type "text" :text "ignored")
                     '(:type "diff" :oldText "c" :newText "d"))))
    (should (mutecipher-acp--ingest-tool-content tc vec))
    (should (equal (macp-tool-call-diffs tc)
                   '(("a" . "b") ("c" . "d"))))
    (should (= 3 (macp-tool-call-rendered-diff-count tc)))
    ;; A second call with the same vector should be a no-op.
    (should-not (mutecipher-acp--ingest-tool-content tc vec))
    (should (equal (macp-tool-call-diffs tc)
                   '(("a" . "b") ("c" . "d"))))))

;;;; Notification dispatch alist

(ert-deftest macp-test-update-handlers-cover-known-types ()
  ;; Every key resolves to a defined function …
  (dolist (entry mutecipher-acp--update-handlers)
    (should (fboundp (cdr entry))))
  ;; … and the keys we actually depend on are still registered.
  (dolist (key '("agent_message_chunk"
                 "tool_call"
                 "tool_call_update"
                 "thought"
                 "plan"
                 "session_info_update"
                 "available_commands_update"
                 "current_mode_update"
                 "config_option_update"))
    (should (assoc key mutecipher-acp--update-handlers))))

;;;; Markdown rendering passes

(defun macp-test--render-md (text)
  "Render TEXT through `mutecipher-acp--apply-markdown' and return the buffer."
  (let ((buf (generate-new-buffer " *macp-md-test*")))
    (with-current-buffer buf
      (insert text)
      (mutecipher-acp--apply-markdown (point-min) (point-max)))
    buf))

(defun macp-test--face-at (pos face)
  "Non-nil if FACE is set at POS (handles a list-of-faces value)."
  (let ((f (get-text-property pos 'face)))
    (or (eq f face)
        (and (listp f) (memq face f)))))

(ert-deftest macp-test-md-bold ()
  (let ((buf (macp-test--render-md "**hi** there")))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          ;; Body of `**hi**' is at positions 3..4 ("h", "i").
          (should (macp-test--face-at 3 'bold))
          (should (macp-test--face-at 4 'bold)))
      (kill-buffer buf))))

(ert-deftest macp-test-md-italic-underscore ()
  (let ((buf (macp-test--render-md "_hi_ there")))
    (unwind-protect
        (with-current-buffer buf
          ;; Body of `_hi_' is at positions 2..3 ("h", "i").
          (should (macp-test--face-at 2 'italic))
          (should (macp-test--face-at 3 'italic))
          ;; Surrounding `_' chars are hidden.
          (should (eq (get-text-property 1 'invisible)
                      'mutecipher-acp-md-markup))
          (should (eq (get-text-property 4 'invisible)
                      'mutecipher-acp-md-markup)))
      (kill-buffer buf))))

(ert-deftest macp-test-md-italic-underscore-skips-intraword ()
  (let ((buf (macp-test--render-md "tool_name and field_value")))
    (unwind-protect
        (with-current-buffer buf
          ;; No `_' between alnum chars should be hidden.
          (goto-char (point-min))
          (while (search-forward "_" nil t)
            (should-not (get-text-property (1- (point)) 'invisible))))
      (kill-buffer buf))))

(ert-deftest macp-test-md-inline-code-applies-constant-face ()
  (let ((buf (macp-test--render-md "use `let` in code")))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward "let")
          (should (macp-test--face-at (1- (point)) 'font-lock-constant-face)))
      (kill-buffer buf))))

(ert-deftest macp-test-md-link-stores-url-property ()
  (let ((buf (macp-test--render-md "[anchor](https://example.test/x)")))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward "anchor")
          (should (equal (get-text-property (1- (point)) 'mutecipher-acp-md-link)
                         "https://example.test/x")))
      (kill-buffer buf))))

(defun macp-test--url-match (s)
  "Return the substring matched by `mutecipher-acp--url-regexp' in S, or nil."
  (and (string-match mutecipher-acp--url-regexp s)
       (match-string 0 s)))

(ert-deftest macp-test-url-regexp-stops-at-tool-label-close-paren ()
  (should (equal "https://urllo.com"
                 (macp-test--url-match
                  "WebFetch(Fetch https://urllo.com)"))))

(ert-deftest macp-test-url-regexp-keeps-balanced-parens ()
  (should (equal "https://en.wikipedia.org/wiki/Foo_(bar)"
                 (macp-test--url-match
                  "Visit https://en.wikipedia.org/wiki/Foo_(bar) today"))))

(ert-deftest macp-test-url-regexp-trims-sentence-period ()
  (should (equal "https://example.com"
                 (macp-test--url-match "See https://example.com."))))

(ert-deftest macp-test-url-regexp-preserves-query-string ()
  (should (equal "https://example.com/path?q=1"
                 (macp-test--url-match "https://example.com/path?q=1"))))

(ert-deftest macp-test-url-regexp-preserves-trailing-slash ()
  (should (equal "https://urllo.com/"
                 (macp-test--url-match "https://urllo.com/"))))

(ert-deftest macp-test-url-regexp-preserves-non-http-schemes ()
  (should (equal "ftp://example.com/foo"
                 (macp-test--url-match "ftp://example.com/foo")))
  (should (equal "file:///etc/hosts"
                 (macp-test--url-match "file:///etc/hosts")))
  (should (equal "git://github.com/foo/bar.git"
                 (macp-test--url-match "git://github.com/foo/bar.git"))))

(ert-deftest macp-test-url-regexp-paren-group-stops-at-newline ()
  (should (equal "https://x.com/"
                 (macp-test--url-match "https://x.com/(a\nb)c"))))

(ert-deftest macp-test-url-regexp-preserves-pipe-in-path ()
  (should (equal "https://example.com/path|pipe"
                 (macp-test--url-match "https://example.com/path|pipe"))))

(defun macp-test--browse-url-at-point (text point-offset)
  "Insert TEXT into a session-mode buffer, position point at POINT-OFFSET,
and return what `browse-url-url-at-point' (the click handler's URL
resolver) would resolve."
  (require 'browse-url)
  (let ((buf (generate-new-buffer " *macp-url-test*")))
    (unwind-protect
        (with-current-buffer buf
          (mutecipher-acp-session-mode)
          (let ((inhibit-read-only t))
            (insert text))
          (goto-char (+ (point-min) point-offset))
          (browse-url-url-at-point))
      (let ((kill-buffer-hook nil))
        (kill-buffer buf)))))

(ert-deftest macp-test-click-path-trims-tool-label-close-paren ()
  "Clicking a URL inside `WebFetch(Fetch https://x)' opens `https://x',
not `https://x)'.  The provider-alist override keeps `thing-at-point' (and
therefore `browse-url-url-at-point') in sync with the fontified extent."
  (should (equal "https://urllo.com"
                 (macp-test--browse-url-at-point
                  "WebFetch(Fetch https://urllo.com)" 20))))

(ert-deftest macp-test-click-path-keeps-balanced-parens ()
  (should (equal "https://en.wikipedia.org/wiki/Foo_(bar)"
                 (macp-test--browse-url-at-point
                  "Visit https://en.wikipedia.org/wiki/Foo_(bar) today" 15))))

(ert-deftest macp-test-fontify-overlay-extent-trims-close-paren ()
  "After `goto-address-mode' fontifies, the URL overlay covers exactly the
regex match — no trailing `)'."
  (let ((buf (generate-new-buffer " *macp-overlay-test*")))
    (unwind-protect
        (with-current-buffer buf
          (mutecipher-acp-session-mode)
          (let ((inhibit-read-only t))
            (insert "WebFetch(Fetch https://urllo.com)"))
          ;; Force jit-lock to run synchronously over the inserted text.
          (jit-lock-fontify-now (point-min) (point-max))
          (let ((url-overlay
                 (seq-find (lambda (ov) (overlay-get ov 'goto-address))
                           (overlays-in (point-min) (point-max)))))
            (should url-overlay)
            (should (equal "https://urllo.com"
                           (buffer-substring-no-properties
                            (overlay-start url-overlay)
                            (overlay-end url-overlay))))))
      (let ((kill-buffer-hook nil))
        (kill-buffer buf)))))

(defun macp-test--str-face-at (str pos face)
  "Non-nil if FACE is set at POS in STR (handles a list-of-faces value)."
  (let ((f (get-text-property pos 'face str)))
    (or (eq f face)
        (and (listp f) (memq face f)))))

(ert-deftest macp-test-md-cell-inline-strips-code-backticks ()
  (let ((s (mutecipher-acp--md-render-cell-inline "`Macintosh/`")))
    (should (equal s "Macintosh/"))
    (should (macp-test--str-face-at s 0 'font-lock-constant-face))))

(ert-deftest macp-test-md-cell-inline-strips-bold-asterisks ()
  (let ((s (mutecipher-acp--md-render-cell-inline "**bold**")))
    (should (equal s "bold"))
    (should (macp-test--str-face-at s 0 'bold))))

(ert-deftest macp-test-md-cell-inline-strips-italic-underscores ()
  (let ((s (mutecipher-acp--md-render-cell-inline "_June 2025_")))
    (should (equal s "June 2025"))
    (should (macp-test--str-face-at s 0 'italic))))

(ert-deftest macp-test-md-cell-inline-strips-link-brackets ()
  (let ((s (mutecipher-acp--md-render-cell-inline "[anchor](https://example.test/x)")))
    (should (equal s "anchor"))
    (should (macp-test--str-face-at s 0 'link))
    (should (equal (get-text-property 0 'mutecipher-acp-md-link s)
                   "https://example.test/x"))))

(ert-deftest macp-test-md-cell-inline-mixed-markup ()
  ;; A cell with code + plain text + bold; literal markers must all be gone.
  (let ((s (mutecipher-acp--md-render-cell-inline "`code` and **bold**")))
    (should (equal s "code and bold"))
    (should (macp-test--str-face-at s 0 'font-lock-constant-face))
    (should (macp-test--str-face-at s (- (length s) 1) 'bold))))

(ert-deftest macp-test-md-table-cell-renders-inline-code ()
  "End-to-end: a table cell containing `code` produces an overlay whose
display string omits the backticks and applies the constant face."
  (let ((buf (macp-test--render-md
              "| Folder       | Theme |\n|--------------|-------|\n| `Macintosh/` | retro |\n")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((ovs (seq-filter
                       (lambda (ov) (overlay-get ov 'mutecipher-acp-md-table))
                       (overlays-in (point-min) (point-max))))
                 (disp (mapconcat (lambda (ov)
                                    (or (overlay-get ov 'display) ""))
                                  ovs "")))
            (should (> (length ovs) 0))
            (should-not (string-match-p "`" disp))
            (should (string-match-p "Macintosh/" disp))
            (let ((idx (string-match "Macintosh/" disp)))
              (should (macp-test--str-face-at disp idx 'font-lock-constant-face)))))
      (kill-buffer buf))))

(ert-deftest macp-test-md-wrap-cell-bridges-link-face-on-space ()
  "When `wrap-cell' joins two propertized words onto one line, the
joining space must inherit the shared face/keymap so an in-cell
multi-word link doesn't gap visually at the space."
  (let* ((rendered (mutecipher-acp--md-render-cell-inline "[anchor text](https://example.test/x)"))
         (lines    (mutecipher-acp--md-wrap-cell rendered 12)))
    (should (equal (mapcar #'substring-no-properties lines) '("anchor text")))
    (let* ((line (car lines))
           (idx  (string-match " " line)))
      (should idx)
      (should (macp-test--str-face-at line idx 'link))
      (should (equal (get-text-property idx 'mutecipher-acp-md-link line)
                     "https://example.test/x")))))

(ert-deftest macp-test-md-strip-invisible-only-strips-md-markup ()
  "`strip-invisible' must only drop chars hidden by the
`mutecipher-acp-md-markup' key — other invisibility layers pass through.
Prevents silent erasure when a future subsystem uses its own key."
  (let ((s (concat (propertize "a" 'invisible 'mutecipher-acp-md-markup)
                   "b"
                   (propertize "c" 'invisible 'some-other-layer)
                   "d")))
    (should (equal (mutecipher-acp--md-strip-invisible s) "bcd"))))

(ert-deftest macp-test-md-bold-italic-triple-star ()
  (let ((buf (macp-test--render-md "***Phoenix*** rises")))
    (unwind-protect
        (with-current-buffer buf
          ;; Body of `***Phoenix***' is at positions 4..10 ("Phoenix").
          (should (macp-test--face-at 4 'bold))
          (should (macp-test--face-at 4 'italic))
          (should (macp-test--face-at 10 'bold))
          (should (macp-test--face-at 10 'italic))
          ;; Surrounding `*' chars hidden.
          (should (eq (get-text-property 1 'invisible) 'mutecipher-acp-md-markup))
          (should (eq (get-text-property 11 'invisible) 'mutecipher-acp-md-markup)))
      (kill-buffer buf))))

(ert-deftest macp-test-md-cell-inline-triple-star ()
  (let ((s (mutecipher-acp--md-render-cell-inline "***Phoenix***")))
    (should (equal s "Phoenix"))
    (should (macp-test--str-face-at s 0 'bold))
    (should (macp-test--str-face-at s 0 'italic))))

(ert-deftest macp-test-md-bold-italic-skips-quad-star-strands ()
  "`****hi****' must not match as inner `***hi***' and strand outer stars.
Without the neighbour-`*' guard, bold-italic binds positions 1–8 and
leaves `*' at positions 0 and 9 visible."
  (let ((s (mutecipher-acp--md-render-cell-inline "****hi****")))
    (should (equal s "****hi****"))))

(ert-deftest macp-test-md-table-n2-degenerate-collapses-sep-into-bottom ()
  "A header + separator table with no data rows must not render the
separator row immediately above the bottom border — collapse the two."
  (let ((buf (macp-test--render-md "| H1 | H2 |\n|----|----|\n")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((ovs (sort (seq-filter (lambda (o) (overlay-get o 'mutecipher-acp-md-table))
                                        (overlays-in (point-min) (point-max)))
                            (lambda (a b) (< (overlay-start a) (overlay-start b)))))
                 (last-disp (and ovs (overlay-get (car (last ovs)) 'display))))
            (should (= 2 (length ovs)))
            (should (stringp last-disp))
            (should-not (string-match-p "├" last-disp))
            (should (string-match-p "└" last-disp))
            (should (string-match-p "┘" last-disp))))
      (kill-buffer buf))))

(ert-deftest macp-test-md-table-renders-when-body-starts-mid-line ()
  "An assistant body that begins with a table head — point sitting after
the icon gutter, not at a real `^' — must still render the table."
  (let ((buf (generate-new-buffer " *macp-md-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "X")  ;; stand-in for the icon-gutter glyph
          (let ((beg (point)))
            (insert "| Foo | Bar |\n|-----|-----|\n| a | b |\n")
            (mutecipher-acp--apply-markdown beg (point-max)))
          (let ((ovs (seq-filter (lambda (o) (overlay-get o 'mutecipher-acp-md-table))
                                 (overlays-in (point-min) (point-max)))))
            (should (> (length ovs) 0))))
      (kill-buffer buf))))

(ert-deftest macp-test-md-checkbox-display ()
  (let ((buf (macp-test--render-md "- [x] done\n- [ ] todo")))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (let* ((d1 (get-text-property (point) 'display)))
            (should (and (stringp d1) (string-match-p "☑" d1))))
          (forward-line 1)
          (let ((d2 (get-text-property (point) 'display)))
            (should (and (stringp d2) (string-match-p "☐" d2)))))
      (kill-buffer buf))))

(ert-deftest macp-test-md-fenced-code-fences-hide ()
  (let ((buf (macp-test--render-md "before\n```\ncode\n```\nafter")))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward "```")
          ;; The opening fence should be marked invisible via our markup spec.
          (should (eq (get-text-property (match-beginning 0) 'invisible)
                      'mutecipher-acp-md-markup)))
      (kill-buffer buf))))

;;;; Log summary

(defun macp-test--strip-faces (s)
  "Return S with text properties stripped — easier to match in asserts."
  (substring-no-properties s))

(ert-deftest macp-test-log-summarize-outbound-prompt ()
  (let* ((line "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"abcdef1234\",\"prompt\":[{\"type\":\"text\",\"text\":\"hello\"}]}}")
         (msg (mutecipher-acp--log-parse line))
         (s   (macp-test--strip-faces (mutecipher-acp--log-summarize msg))))
    (should (string-match-p "session/prompt id=3" s))
    (should (string-match-p "sid=abcdef12" s))
    (should (string-match-p "\"hello\"" s))))

(ert-deftest macp-test-log-summarize-tool-call-update ()
  (let* ((line "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess123abcdef\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"status\":\"completed\",\"toolCallId\":\"toolu_xyz1234567890\"}}}")
         (msg (mutecipher-acp--log-parse line))
         (s   (macp-test--strip-faces (mutecipher-acp--log-summarize msg))))
    (should (string-match-p "session/update tool_call_update" s))
    (should (string-match-p "completed" s))
    (should (string-match-p "cid=toolu_xyz123" s))))

(ert-deftest macp-test-log-summarize-error-response ()
  (let* ((line "{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}")
         (msg (mutecipher-acp--log-parse line))
         (s   (macp-test--strip-faces (mutecipher-acp--log-summarize msg))))
    (should (string-match-p "error id=6 code=-32601" s))
    (should (string-match-p "Method not found" s))))

(ert-deftest macp-test-log-summarize-permission-outcome ()
  (let* ((line "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow\"}}}")
         (msg (mutecipher-acp--log-parse line))
         (s   (macp-test--strip-faces (mutecipher-acp--log-summarize msg))))
    (should (string-match-p "ok id=0" s))
    (should (string-match-p "selected/allow" s))))

(ert-deftest macp-test-log-suppressed-usage-update ()
  (let ((mutecipher-acp-log-suppress '("usage_update")))
    (should (mutecipher-acp--log-suppressed-p
             '(:method "session/update"
               :params (:sessionId "x" :update (:sessionUpdate "usage_update" :used 1)))))
    (should-not (mutecipher-acp--log-suppressed-p
                 '(:method "session/update"
                   :params (:sessionId "x" :update (:sessionUpdate "agent_message_chunk"
                                                    :content (:text "hi"))))))))

(ert-deftest macp-test-log-suppressed-empty-chunk ()
  (let ((mutecipher-acp-log-suppress-empty-chunks t))
    (should (mutecipher-acp--log-suppressed-p
             '(:method "session/update"
               :params (:sessionId "x" :update (:sessionUpdate "agent_message_chunk"
                                                :content (:text ""))))))
    (should-not (mutecipher-acp--log-suppressed-p
                 '(:method "session/update"
                   :params (:sessionId "x" :update (:sessionUpdate "agent_message_chunk"
                                                    :content (:text "real")))))))
  (let ((mutecipher-acp-log-suppress-empty-chunks nil))
    (should-not (mutecipher-acp--log-suppressed-p
                 '(:method "session/update"
                   :params (:sessionId "x" :update (:sessionUpdate "agent_message_chunk"
                                                    :content (:text ""))))))))

(ert-deftest macp-test-log-shorten-truncates-and-flattens ()
  (should (equal "a b c"
                 (mutecipher-acp--log-shorten "a\nb\tc" 99)))
  (let ((s (mutecipher-acp--log-shorten (make-string 200 ?x) 30)))
    (should (= 30 (length s)))
    (should (string-suffix-p "…" s))))

;;;; Mode-change idempotence

(ert-deftest macp-test-apply-mode-change-noop-on-same-id ()
  (let ((s (mutecipher-acp--make-session :id "x" :current-mode-id "plan"))
        (calls 0))
    (cl-letf (((symbol-function 'mutecipher-acp--refresh-mode-line)
               (lambda (&rest _) (cl-incf calls))))
      (mutecipher-acp--apply-mode-change s "plan")
      (should (= 0 calls))
      (mutecipher-acp--apply-mode-change s "default")
      (should (= 1 calls))
      (should (equal "default" (macp-session-current-mode-id s))))))

;;;; Session struct sanity

(ert-deftest macp-test-make-session-defaults ()
  (let ((s (mutecipher-acp--make-session :id "abc" :cwd "/tmp")))
    (should (equal "abc" (macp-session-id s)))
    (should (equal "/tmp" (macp-session-cwd s)))
    (should (eq 'idle (macp-session-state s)))
    (should (= 0 (macp-session-turn-counter s)))
    (should (hash-table-p (macp-session-tool-call-index s)))))

;;;; Diff rendering

(ert-deftest macp-test-render-diff-emits-line-numbers-and-faces ()
  "Every line of the rendered diff carries a line-number gutter and a
GitHub-style background face on the body."
  (let ((rendered (mutecipher-acp--render-diff-for-card
                   "alpha\nbeta\ngamma"
                   "alpha\nBETA\ngamma")))
    (should rendered)
    ;; The body face is propertized; check we see the expected diff lines.
    (should (string-match-p "@@ -1,3 \\+1,3 @@" rendered))
    (should (string-match-p "-beta"  rendered))
    (should (string-match-p "\\+BETA" rendered))
    ;; No phantom trailing empty line and no `\\ No newline' artifact.
    (should-not (string-match-p "No newline at end of file" rendered))
    ;; Line numbers appear in the gutter.
    (should (string-match-p "    1 " rendered))
    (should (string-match-p "    2 " rendered))
    (should (string-match-p "    3 " rendered))))

(ert-deftest macp-test-render-diff-uses-start-line-offset ()
  "When START-LINE is provided, gutter numbers + hunk header are
file-relative, not snippet-relative."
  (let ((rendered (mutecipher-acp--render-diff-for-card
                   "old line"
                   "new line"
                   42)))
    (should rendered)
    (should (string-match-p "@@ -42 \\+42 @@" rendered))
    (should (string-match-p "   42 -old line" rendered))
    (should (string-match-p "   42 \\+new line" rendered))))

(ert-deftest macp-test-tool-call-start-line-reads-locations ()
  "With a diff present and `:line' in locations (no path or path
unreadable), the function returns the agent-provided line."
  (let ((tc (make-macp-tool-call
             :name "Edit"
             :locations (vector (list :path "/nonexistent/x" :line 17))
             :diffs (list (cons "old" "new")))))
    (should (eq 17 (mutecipher-acp--tool-call-start-line tc)))))

(ert-deftest macp-test-tool-call-start-line-nil-without-diffs ()
  "No diffs → nil (no point computing anchor for a non-diff tool call)."
  (let ((tc (make-macp-tool-call
             :name "Read"
             :locations (vector (list :path "/x" :line 1)))))
    (should-not (mutecipher-acp--tool-call-start-line tc)))
  (let ((tc (make-macp-tool-call :name "Edit" :locations nil)))
    (should-not (mutecipher-acp--tool-call-start-line tc))))

(ert-deftest macp-test-synthesize-locations-from-locations ()
  (let ((built (mutecipher-acp--synthesize-locations
                (list :locations (vector (list :path "/x" :line 7))))))
    (should (vectorp built))
    (should (eq 7 (plist-get (aref built 0) :line)))))

(ert-deftest macp-test-synthesize-locations-from-list-locations ()
  "Locations may arrive as a list (older agents); we coerce to a vector."
  (let ((built (mutecipher-acp--synthesize-locations
                (list :locations (list (list :path "/x"))))))
    (should (vectorp built))
    (should (equal "/x" (plist-get (aref built 0) :path)))))

(ert-deftest macp-test-synthesize-locations-from-raw-input ()
  "When `:locations' is missing, synthesize a single-entry vector from
the first path-bearing key in `rawInput'."
  (let ((built (mutecipher-acp--synthesize-locations
                (list :rawInput (list :file_path "/abs/path.md"
                                       :old_string "x" :new_string "y")))))
    (should (vectorp built))
    (should (= 1 (length built)))
    (should (equal "/abs/path.md" (plist-get (aref built 0) :path)))
    (should-not (plist-get (aref built 0) :line))))

(ert-deftest macp-test-synthesize-locations-returns-nil-when-no-path ()
  (should-not (mutecipher-acp--synthesize-locations
               (list :rawInput (list :command "ls -la")))))

(ert-deftest macp-test-start-line-file-search-overrides-bogus-agent-line ()
  "claude-code-acp ships `:line 1' for every Edit regardless of where
the edit landed.  File search must win over that bogus default."
  (let ((tmp (make-temp-file "macp-prefer-")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "line one\nline two\nNEEDLE here\nfour\n"))
          (let ((tc (make-macp-tool-call
                     :name "Edit"
                     ;; Agent claims line 1 — but the new text really
                     ;; sits at line 3.  Render should believe the file.
                     :locations (vector (list :path tmp :line 1))
                     :diffs (list (cons "needle" "NEEDLE here")))))
            (should (eq 3 (mutecipher-acp--tool-call-start-line tc)))))
      (delete-file tmp))))

(ert-deftest macp-test-start-line-falls-back-to-line-when-search-empty ()
  "If both newText and oldText are missing from the file, fall back to
`:line' from locations."
  (let ((tmp (make-temp-file "macp-fallback-search-")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "alpha\nbeta\n"))
          (let ((tc (make-macp-tool-call
                     :name "Edit"
                     :locations (vector (list :path tmp :line 42))
                     :diffs (list (cons "not-in-file" "also-not-in-file")))))
            (should (eq 42 (mutecipher-acp--tool-call-start-line tc)))))
      (delete-file tmp))))

(ert-deftest macp-test-start-line-pending-edit-uses-old-text ()
  "Before the edit is applied, the file contains oldText (not newText).
File-search must fall through from newText to oldText so the pending
diff still renders at the correct file line."
  (let ((tmp (make-temp-file "macp-pending-")))
    (unwind-protect
        (progn
          ;; File pre-edit — has oldText but not newText.
          (with-temp-file tmp
            (insert "line one\nline two\nORIGINAL content\nline four\n"))
          (let ((tc (make-macp-tool-call
                     :name "Edit"
                     :locations (vector (list :path tmp :line 1))
                     :diffs (list (cons "ORIGINAL content"
                                        "UPDATED content")))))
            (should (eq 3 (mutecipher-acp--tool-call-start-line tc)))))
      (delete-file tmp))))

(ert-deftest macp-test-start-line-resolves-relative-path-against-cwd ()
  "When `locations[0].path' is relative, the file-search fallback
expands it against the session cwd before opening."
  (let* ((dir (make-temp-file "macp-cwd-" t))
         (relpath "subdir/notes.md")
         (absfile (expand-file-name relpath dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory absfile) t)
          (with-temp-file absfile
            (insert "alpha\nbeta\nNEEDLE here\nomega\n"))
          (let ((tc (make-macp-tool-call
                     :name "Edit"
                     :locations (vector (list :path relpath))
                     :diffs (list (cons "needle" "NEEDLE here")))))
            (should (eq 3 (mutecipher-acp--tool-call-start-line tc dir)))))
      (delete-directory dir t))))

(ert-deftest macp-test-find-line-in-file ()
  "`--find-line-in-file' returns the 1-based line of TEXT in a real file."
  (let ((tmp (make-temp-file "macp-find-")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "alpha\nbeta\ngamma needle here\ndelta\n"))
          (should (eq 3 (mutecipher-acp--find-line-in-file tmp "needle")))
          (should (eq 1 (mutecipher-acp--find-line-in-file tmp "alpha")))
          (should-not (mutecipher-acp--find-line-in-file tmp "not present"))
          (should-not (mutecipher-acp--find-line-in-file "/nonexistent/x" "a"))
          (should-not (mutecipher-acp--find-line-in-file tmp "")))
      (delete-file tmp))))

(ert-deftest macp-test-start-line-falls-back-to-file-search ()
  "When `locations[0].line' is missing but `path' is set, the renderer
searches the file for the diff's `newText' to discover the line."
  (let ((tmp (make-temp-file "macp-fallback-")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "line one\nline two\nline THREE (edited)\nline four\n"))
          (let ((tc (make-macp-tool-call
                     :name "Edit"
                     :locations (vector (list :path tmp))
                     :diffs (list (cons "line three"
                                        "line THREE (edited)")))))
            (should (eq 3 (mutecipher-acp--tool-call-start-line tc)))))
      (delete-file tmp))))

(ert-deftest macp-test-render-diff-context-bumps-both-counters ()
  "A context line increments BOTH the old and new line counters; an
added line increments only new; a removed line increments only old."
  (let ((rendered (mutecipher-acp--render-diff-for-card
                   "a\nb\nc\n"
                   "a\nB\nc\n")))
    ;; The plus line for `B' shows new-line 2, not 1 (because `a' was a
    ;; context line that bumped new from 1 to 2).
    (should (string-match-p "    2 \\+B" rendered))
    (should (string-match-p "    2 -b" rendered))))

;;;; Tool-call spinner

(ert-deftest macp-test-tool-status-glyph-spins-pending-and-running ()
  "Pending and running statuses render the current spinner frame, not the
static circle.  The frame is keyed off `--spinner-tick'."
  (let ((mutecipher-acp-spinner-frames ["A" "B" "C" "D"])
        (mutecipher-acp--spinner-tick 0))
    (should (equal "A" (substring-no-properties
                        (mutecipher-acp--tool-status-glyph 'running))))
    (should (equal "A" (substring-no-properties
                        (mutecipher-acp--tool-status-glyph 'pending))))
    (setq mutecipher-acp--spinner-tick 7)
    (should (equal "D" (substring-no-properties
                        (mutecipher-acp--tool-status-glyph 'running))))))

(ert-deftest macp-test-has-active-tool-calls-p ()
  (with-temp-buffer
    (setq mutecipher-acp--ewoc
          (ewoc-create #'mutecipher-acp--pp "" "" t))
    (should-not (mutecipher-acp--has-active-tool-calls-p))
    (ewoc-enter-last
     mutecipher-acp--ewoc
     (make-macp-node :kind 'tool-call
                     :data (make-macp-tool-call :status 'done)))
    (should-not (mutecipher-acp--has-active-tool-calls-p))
    (ewoc-enter-last
     mutecipher-acp--ewoc
     (make-macp-node :kind 'tool-call
                     :data (make-macp-tool-call :status 'running)))
    (should (mutecipher-acp--has-active-tool-calls-p))))

;;;; Inline composer

(defmacro macp-test--with-session-buffer (&rest body)
  "Run BODY in a freshly-installed session buffer.
The buffer is in `mutecipher-acp-session-mode' so the composer is set
up and `mutecipher-acp--pp' will apply read-only properties.  The
buffer is killed unconditionally on exit."
  (declare (indent 0) (debug (body)))
  `(let ((buf (generate-new-buffer " *macp-composer-test*")))
     (unwind-protect
         (with-current-buffer buf
           (mutecipher-acp-session-mode)
           ,@body)
       (let ((kill-buffer-hook nil))
         (kill-buffer buf)))))

(ert-deftest macp-test-composer-install-places-markers ()
  (macp-test--with-session-buffer
    (should (markerp mutecipher-acp--composer-start))
    (should (overlayp mutecipher-acp--composer-overlay))
    (should (<= (marker-position mutecipher-acp--composer-start)
                (point-max)))
    (let ((cs (marker-position mutecipher-acp--composer-start)))
      (should (> cs (point-min)))
      (should (get-text-property (1- cs) 'read-only)))))

(ert-deftest macp-test-composer-text-strips-prompt-glyph ()
  (macp-test--with-session-buffer
    (mutecipher-acp--composer-set-text "hello world")
    (should (equal "hello world" (mutecipher-acp--composer-text)))
    (let* ((b   (mutecipher-acp--composer-bounds))
           (raw (buffer-substring-no-properties (car b) (cdr b))))
      (should-not (string-match-p "❯" raw)))))

(ert-deftest macp-test-composer-region-p-boundary ()
  (macp-test--with-session-buffer
    (let ((cs (marker-position mutecipher-acp--composer-start)))
      (should-not (mutecipher-acp--composer-region-p (1- cs)))
      (should (mutecipher-acp--composer-region-p cs))
      (mutecipher-acp--composer-set-text "abc")
      (should (mutecipher-acp--composer-region-p (point-max))))))

(ert-deftest macp-test-composer-send-records-history-and-clears ()
  (let ((sent nil))
    (cl-letf (((symbol-function 'mutecipher-acp--do-prompt)
               (lambda (_sid text) (setq sent text))))
      (macp-test--with-session-buffer
        (mutecipher-acp--composer-set-text "first message")
        (mutecipher-acp--composer-send)
        (should (equal "first message" sent))
        (should (equal "" (mutecipher-acp--composer-text)))
        (should (= 1 (ring-length mutecipher-acp--composer-history)))
        (should (equal "first message"
                       (ring-ref mutecipher-acp--composer-history 0)))))))

(ert-deftest macp-test-composer-send-empty-is-noop ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'mutecipher-acp--do-prompt)
               (lambda (&rest _) (cl-incf calls))))
      (macp-test--with-session-buffer
        (mutecipher-acp--composer-send)
        (should (= 0 calls))))))

(ert-deftest macp-test-composer-history-prev-cycles ()
  (cl-letf (((symbol-function 'mutecipher-acp--do-prompt)
             (lambda (&rest _) nil)))
    (macp-test--with-session-buffer
      (dolist (msg '("one" "two" "three"))
        (mutecipher-acp--composer-set-text msg)
        (mutecipher-acp--composer-send))
      (mutecipher-acp--composer-history-prev)
      (should (equal "three" (mutecipher-acp--composer-text)))
      (mutecipher-acp--composer-history-prev)
      (should (equal "two" (mutecipher-acp--composer-text)))
      (mutecipher-acp--composer-history-prev)
      (should (equal "one" (mutecipher-acp--composer-text))))))

(ert-deftest macp-test-readonly-transcript-rejects-self-insert ()
  (macp-test--with-session-buffer
    ;; Render a node so we have a propertized read-only region to test.
    (let ((inhibit-read-only t))
      (ewoc-enter-last mutecipher-acp--ewoc
                       (make-macp-node :kind 'user
                                       :data (make-macp-user
                                              :text "hello"))))
    (goto-char (1+ (point-min)))
    (let ((this-command 'self-insert-command)
          (last-command-event ?x))
      (should-error (self-insert-command 1) :type 'text-read-only))))

(ert-deftest macp-test-session-mode-map-allows-self-insert ()
  "Self-insertion must not be suppressed (regression: deriving from
`special-mode' previously inherited a `suppress-keymap' remap that
remapped every printable key to `undefined', blocking typing)."
  (macp-test--with-session-buffer
    (let ((cmd (lookup-key mutecipher-acp-session-mode-map [?a])))
      ;; If the remap is suppressed, this is non-nil and points at a
      ;; binding (often `undefined' from `suppress-keymap').
      (should (or (null cmd) (eq cmd 'self-insert-command))))
    (let ((cmd (key-binding [remap self-insert-command])))
      ;; Globally, no remap should point self-insert-command at undefined.
      (should-not (eq cmd 'undefined)))
    (mutecipher-acp--composer-goto)
    (let ((this-command 'self-insert-command)
          (last-command-event ?x))
      (self-insert-command 1))
    (should (equal "x" (mutecipher-acp--composer-text)))))

(ert-deftest macp-test-toggle-tool-calls-flips-all ()
  "`mutecipher/acp-toggle-tool-calls' collapses all if any is expanded,
otherwise expands all."
  (macp-test--with-session-buffer
    (let ((inhibit-read-only t))
      (dotimes (_ 3)
        (ewoc-enter-last
         mutecipher-acp--ewoc
         (make-macp-node :kind 'tool-call
                         :data (make-macp-tool-call :status 'done
                                                    :name "x")))))
    (let ((wrappers (ewoc-collect mutecipher-acp--ewoc
                                   (lambda (d) (eq (macp-node-kind d)
                                                   'tool-call)))))
      (should (= 3 (length wrappers)))
      (should (cl-every (lambda (d) (not (macp-node-collapsed d))) wrappers))
      ;; First toggle: all expanded → collapse all.
      (mutecipher/acp-toggle-tool-calls)
      (should (cl-every #'macp-node-collapsed wrappers))
      ;; Second toggle: all collapsed → expand all.
      (mutecipher/acp-toggle-tool-calls)
      (should (cl-every (lambda (d) (not (macp-node-collapsed d))) wrappers)))))

(ert-deftest macp-test-tab-dwim-in-composer-runs-completion ()
  (let ((called 0))
    (cl-letf (((symbol-function 'completion-at-point)
               (lambda () (cl-incf called))))
      (macp-test--with-session-buffer
        (mutecipher-acp--composer-goto)
        (mutecipher-acp--tab-dwim)
        (should (= 1 called))))))

;;;; Permission UI

(ert-deftest macp-test-permission-char-for-prefers-first-letter ()
  (should (eq ?a (mutecipher-acp--permission-char-for "Allow" nil)))
  (should (eq ?r (mutecipher-acp--permission-char-for "Reject" nil))))

(ert-deftest macp-test-permission-char-for-always-uses-uppercase ()
  "`Always Allow' must not collide with `Allow'; uppercase A is reserved."
  (should (eq ?A (mutecipher-acp--permission-char-for "Always Allow" '(?a))))
  (should (eq ?A (mutecipher-acp--permission-char-for "always allow" '(?a)))))

(ert-deftest macp-test-permission-char-for-fallthrough-on-collision ()
  "If the preferred letter is taken, pick the next unused alphabetic char."
  (should (eq ?l (mutecipher-acp--permission-char-for "Allow" '(?a)))))

(ert-deftest macp-test-permission-choices-returns-choices-and-id-map ()
  (let* ((options (list (list :name "Allow"        :optionId "allow")
                        (list :name "Reject"       :optionId "reject")
                        (list :name "Always Allow" :optionId "always_allow")))
         (built   (mutecipher-acp--permission-choices options))
         (choices (car built))
         (id-map  (cdr built)))
    (should (equal '((?a "Allow") (?r "Reject") (?A "Always Allow"))
                   choices))
    (should (equal "allow"        (cdr (assq ?a id-map))))
    (should (equal "reject"       (cdr (assq ?r id-map))))
    (should (equal "always_allow" (cdr (assq ?A id-map))))))

(ert-deftest macp-test-permission-choices-accepts-vector ()
  "Regression: JSON parses arrays as vectors, so OPTIONS arrives as a
vector here.  `--permission-choices' must coerce, not crash."
  (let* ((options (vector (list :name "Always Allow" :optionId "allow_always")
                          (list :name "Allow"        :optionId "allow")
                          (list :name "Reject"       :optionId "reject")))
         (built   (mutecipher-acp--permission-choices options))
         (choices (car built))
         (id-map  (cdr built)))
    (should (equal '((?A "Always Allow") (?a "Allow") (?r "Reject"))
                   choices))
    (should (equal "allow_always" (cdr (assq ?A id-map))))))

(ert-deftest macp-test-permission-prompt-includes-tool-context ()
  (let ((s (mutecipher-acp--permission-prompt-string
            '(:kind "execute" :title "Bash"
              :rawInput (:command "npm test")))))
    (should (string-match-p "Bash" s))
    (should (string-match-p "npm test" s))))

(ert-deftest macp-test-update-usage-is-noop ()
  "`usage_update' must be dispatched (so no \"unhandled\" message fires)
even though its handler does nothing."
  (should (assoc "usage_update" mutecipher-acp--update-handlers))
  (should (eq 'mutecipher-acp--update-usage
              (cdr (assoc "usage_update" mutecipher-acp--update-handlers))))
  (should-not (mutecipher-acp--update-usage "x" nil)))

;;;; Prompt queue

(defmacro macp-test--with-queue-session (var-session &rest body)
  "Install a fresh session-buffer wired up for queue testing and run BODY.
Binds VAR-SESSION to the `macp-session' struct stored in
`mutecipher-acp--sessions'.  Stubs `mutecipher-acp--request' to a no-op
so prompts don't actually fire RPC.  The session and buffer are torn
down unconditionally on exit."
  (declare (indent 1) (debug ((symbolp) body)))
  `(let* ((buf (generate-new-buffer " *macp-queue-test*"))
          (sid (format "test-sid-%s" (random)))
          (,var-session (mutecipher-acp--make-session
                          :id sid :buffer buf :agent "claude"
                          :cwd "/tmp")))
     (puthash sid ,var-session mutecipher-acp--sessions)
     (cl-letf (((symbol-function 'mutecipher-acp--request)
                (lambda (&rest _) nil))
               ;; Stub the persistence layer so queue tests don't leak
               ;; `test-sid-*.eld' files into the real cache directory.
               ((symbol-function 'mutecipher-acp--save-session) #'ignore)
               ((symbol-function 'mutecipher-acp--save-index)   #'ignore))
       (unwind-protect
           (with-current-buffer buf
             (mutecipher-acp-session-mode)
             (setq mutecipher-acp--session-id sid)
             ,@body)
         (let ((kill-buffer-hook nil))
           (when (buffer-live-p buf) (kill-buffer buf)))
         (remhash sid mutecipher-acp--sessions)))))

(defun macp-test--queued-nodes ()
  "Return the list of `macp-queued' structs (unwrapped) for every queued node."
  (mapcar #'macp-node-data
          (ewoc-collect mutecipher-acp--ewoc
                         (lambda (d) (eq (macp-node-kind d) 'queued)))))

(ert-deftest macp-test-queue-do-prompt-idle-fires-rpc ()
  "Idle session: --do-prompt opens a turn, sets thinking, queue stays empty."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session))
          (fired 0))
      (cl-letf (((symbol-function 'mutecipher-acp--request)
                 (lambda (&rest _) (cl-incf fired))))
        (mutecipher-acp--do-prompt sid "hello"))
      (should (= 1 fired))
      (should (null (macp-session-prompt-queue session)))
      (should (null (macp-session-queue-head-node session)))
      (should (eq 'thinking (macp-session-state session))))))

(ert-deftest macp-test-queue-do-prompt-busy-enqueues ()
  "Busy session: --do-prompt drops to enqueue, no RPC fires."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session))
          (fired 0))
      (setf (macp-session-state session) 'thinking)
      (cl-letf (((symbol-function 'mutecipher-acp--request)
                 (lambda (&rest _) (cl-incf fired))))
        (mutecipher-acp--do-prompt sid "queued-1"))
      (should (= 0 fired))
      (should (equal '("queued-1") (macp-session-prompt-queue session)))
      (should (macp-session-queue-head-node session))
      (let ((data (macp-test--queued-nodes)))
        (should (= 1 (length data)))
        (should (equal "queued-1"
                       (macp-queued-text (car data))))))))

(ert-deftest macp-test-queue-multiple-items-stack-in-order ()
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'streaming)
      (mutecipher-acp--do-prompt sid "first")
      (mutecipher-acp--do-prompt sid "second")
      (mutecipher-acp--do-prompt sid "third")
      (should (equal '("first" "second" "third")
                     (macp-session-prompt-queue session)))
      (let ((data (macp-test--queued-nodes)))
        (should (= 3 (length data)))
        (should (equal "first"  (macp-queued-text (nth 0 data))))
        (should (equal "second" (macp-queued-text (nth 1 data))))
        (should (equal "third"  (macp-queued-text (nth 2 data))))))))

(ert-deftest macp-test-queue-drain-pops-head-and-fires ()
  "On idle + non-empty queue, --drain-queue pops head and recurses through
do-prompt — which now fires the RPC because state is back to idle."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session))
          (sent nil))
      ;; Enqueue two while busy.
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "alpha")
      (mutecipher-acp--do-prompt sid "beta")
      ;; Simulate turn ending naturally → state idle, then drain.
      (setf (macp-session-state session) 'idle)
      (cl-letf (((symbol-function 'mutecipher-acp--request)
                 (lambda (_conn _method params &rest _)
                   (push (plist-get params :prompt) sent))))
        (mutecipher-acp--drain-queue sid))
      ;; Head popped, only "beta" remains.
      (should (equal '("beta") (macp-session-prompt-queue session)))
      ;; Exactly one RPC fired carrying "alpha".
      (should (= 1 (length sent)))
      ;; The new state should be thinking (alpha now in flight).
      (should (eq 'thinking (macp-session-state session)))
      ;; queue-head-node now points at the second (only remaining) queued node.
      (should (macp-session-queue-head-node session))
      (let ((data (macp-test--queued-nodes)))
        (should (= 1 (length data)))
        (should (equal "beta" (macp-queued-text (car data))))))))

(ert-deftest macp-test-queue-drain-empties-clears-head-node ()
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "only-one")
      (setf (macp-session-state session) 'idle)
      (mutecipher-acp--drain-queue sid)
      (should (null (macp-session-prompt-queue session)))
      (should (null (macp-session-queue-head-node session)))
      (should (= 0 (length (macp-test--queued-nodes)))))))

(ert-deftest macp-test-queue-drain-from-foreign-buffer ()
  "Drain is invoked from the JSON-dispatch callback, whose current-buffer
is not the session buffer.  Reading `mutecipher-acp--ewoc' there would
return nil — drain must switch into the session buffer first."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session))
          (sent nil))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "alpha")
      (mutecipher-acp--do-prompt sid "beta")
      (setf (macp-session-state session) 'idle)
      (cl-letf (((symbol-function 'mutecipher-acp--request)
                 (lambda (_conn _method params &rest _)
                   (push (plist-get params :prompt) sent))))
        ;; Step OUT of the session buffer before draining — this mirrors
        ;; how the success-fn callback fires from the RPC layer.
        (with-temp-buffer
          (should (null mutecipher-acp--ewoc))
          (mutecipher-acp--drain-queue sid)))
      (should (= 1 (length sent)))
      (should (equal '("beta") (macp-session-prompt-queue session)))
      (should (macp-session-queue-head-node session)))))

(ert-deftest macp-test-queue-drain-noop-when-not-idle ()
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "a")
      (mutecipher-acp--drain-queue sid)  ; state still thinking
      (should (equal '("a") (macp-session-prompt-queue session))))))

(defun macp-test--goto-queued (text)
  "Move point inside the `queued' node whose text equals TEXT."
  (cl-loop for n = (ewoc-nth mutecipher-acp--ewoc 0)
           then (ewoc-next mutecipher-acp--ewoc n)
           while n
           when (and (eq (macp-node-kind (ewoc-data n)) 'queued)
                     (equal text (macp-queued-text
                                  (macp-node-data (ewoc-data n)))))
           return (progn (ewoc-goto-node mutecipher-acp--ewoc n) n)))

(ert-deftest macp-test-queue-remove-at-point-shrinks-queue ()
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "a")
      (mutecipher-acp--do-prompt sid "b")
      (mutecipher-acp--do-prompt sid "c")
      (macp-test--goto-queued "b")
      (should (mutecipher-acp--queue-remove-at-point))
      (should (equal '("a" "c") (macp-session-prompt-queue session)))
      (should (= 2 (length (macp-test--queued-nodes))))
      ;; head node is still "a"
      (should (equal "a"
                     (macp-queued-text
                      (macp-node-data
                       (ewoc-data (macp-session-queue-head-node session)))))))))

(ert-deftest macp-test-queue-edit-at-point-restores-to-composer ()
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "to-edit")
      (macp-test--goto-queued "to-edit")
      (should (mutecipher-acp--queue-edit-at-point))
      (should (null (macp-session-prompt-queue session)))
      (should (null (macp-session-queue-head-node session)))
      (should (equal "to-edit" (mutecipher-acp--composer-text))))))

(ert-deftest macp-test-queue-removing-head-shifts-head-node ()
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "first")
      (mutecipher-acp--do-prompt sid "second")
      (macp-test--goto-queued "first")
      (mutecipher-acp--queue-remove-at-point)
      (should (equal '("second") (macp-session-prompt-queue session)))
      (should (macp-session-queue-head-node session))
      (should (equal "second"
                     (macp-queued-text
                      (macp-node-data
                       (ewoc-data (macp-session-queue-head-node session)))))))))

(ert-deftest macp-test-queue-do-prompt-error-state-still-enqueues ()
  "Sending while the session is in `error' state should enqueue (any
non-idle state queues).  Drain stays gated on natural completion."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session))
          (fired 0))
      (setf (macp-session-state session) 'error)
      (cl-letf (((symbol-function 'mutecipher-acp--request)
                 (lambda (&rest _) (cl-incf fired))))
        (mutecipher-acp--do-prompt sid "after-error"))
      (should (= 0 fired))
      (should (equal '("after-error") (macp-session-prompt-queue session))))))

(ert-deftest macp-test-queue-edit-refuses-when-composer-has-draft ()
  "RET on a queued node must NOT clobber an in-progress composer draft.
Instead, signal a `user-error' so the user keeps their text."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "queued-text")
      (mutecipher-acp--composer-set-text "draft I am still writing")
      (macp-test--goto-queued "queued-text")
      (should-error (mutecipher-acp--queue-edit-at-point) :type 'user-error)
      ;; Draft preserved, queue intact.
      (should (equal "draft I am still writing"
                     (mutecipher-acp--composer-text)))
      (should (equal '("queued-text") (macp-session-prompt-queue session)))
      (should (= 1 (length (macp-test--queued-nodes)))))))

(ert-deftest macp-test-queued-node-at-point-rejects-separator ()
  "ewoc-locate returns the nearest preceding node, so on the read-only
separator just before composer-start it falsely yields the last queued
node.  --queued-node-at-point must filter that out via a range check."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "the-queued")
      ;; Position point ON the read-only separator at (1- composer-start).
      (goto-char (1- (marker-position mutecipher-acp--composer-start)))
      (should-not (mutecipher-acp--queued-node-at-point))
      ;; Sanity: same point sees a preceding node via raw ewoc-locate.
      (should (eq 'queued
                  (macp-node-kind
                   (ewoc-data (ewoc-locate mutecipher-acp--ewoc))))))))

(ert-deftest macp-test-ewoc-enter-tail-assigns-uuid-and-indexes ()
  "Every node entered via --ewoc-enter-tail gets a stable uuid and is
registered in the session's node-index for O(1) addressing."
  (macp-test--with-queue-session session
    (let* ((node (mutecipher-acp--ewoc-enter-tail
                  mutecipher-acp--ewoc nil
                  (make-macp-node :kind 'notice
                                  :data (make-macp-notice :text "hi"))))
           (uuid (macp-node-uuid (ewoc-data node))))
      (should (stringp uuid))
      (should (string-match-p "\\`n_[0-9a-f]\\{12\\}\\'" uuid))
      (should (eq node (gethash uuid (macp-session-node-index session)))))))

(ert-deftest macp-test-ewoc-enter-tail-preserves-existing-uuid ()
  "Persistence-replay path: when DATA already carries a uuid, --ewoc-enter-tail
keeps it instead of generating a fresh one."
  (macp-test--with-queue-session session
    (let* ((data (make-macp-node :uuid "n_deadbeef0000"
                                 :kind 'notice
                                 :data (make-macp-notice :text "hi")))
           (node (mutecipher-acp--ewoc-enter-tail
                  mutecipher-acp--ewoc nil data)))
      (should (equal "n_deadbeef0000" (macp-node-uuid (ewoc-data node))))
      (should (eq node (gethash "n_deadbeef0000"
                                (macp-session-node-index session)))))))

(ert-deftest macp-test-queue-remove-also-unindexes-node ()
  "Removing a queued node from the EWOC must also drop its uuid from
the session's node-index — otherwise the index leaks a pointer to a
deleted ewoc node."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "to-remove")
      (let* ((node (mutecipher-acp--queue-recover-head-node session))
             (uuid (macp-node-uuid (ewoc-data node)))
             (idx  (macp-session-node-index session)))
        (should (gethash uuid idx))
        (mutecipher-acp--queue-remove-node session node)
        (should-not (gethash uuid idx))))))

(ert-deftest macp-test-queue-drain-also-unindexes-head ()
  "Draining a queued node must also drop its uuid from node-index."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "to-drain")
      (let* ((node (mutecipher-acp--queue-recover-head-node session))
             (uuid (macp-node-uuid (ewoc-data node)))
             (idx  (macp-session-node-index session)))
        (should (gethash uuid idx))
        (setf (macp-session-state session) 'idle)
        (mutecipher-acp--drain-queue sid)
        (should-not (gethash uuid idx))))))

(ert-deftest macp-test-do-prompt-user-errors-on-missing-session ()
  "`--do-prompt' must signal rather than silently swallowing when the
session-id resolves to nothing — otherwise `--composer-send' would clear
the user's text after a no-op dispatch."
  (should-error (mutecipher-acp--do-prompt "no-such-session" "hi")
                :type 'user-error))

(ert-deftest macp-test-queue-drains-after-cancelled-stop-reason ()
  "Cancel mid-turn must auto-drain the queue on the resulting idle
transition.  Encode the success-fn drain gate's behavior directly: any
stop reason in '(end_turn max_tokens cancelled) should drive a drain;
'error / 'refusal should not."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session))
          (sent nil))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "queued-after-cancel")
      (setf (macp-session-state session) 'idle)
      (cl-letf (((symbol-function 'mutecipher-acp--request)
                 (lambda (_conn _method params &rest _)
                   (push (plist-get params :prompt) sent))))
        ;; This is what the success-fn does for stopReason "cancelled".
        (mutecipher-acp--drain-queue sid))
      (should (= 1 (length sent)))
      (should (null (macp-session-prompt-queue session))))))

(ert-deftest macp-test-enqueue-prompt-order-keeps-stores-in-sync ()
  "If ewoc-enter-last signals during enqueue, prompt-queue must NOT have
grown — the list mutation runs only after the EWOC insert succeeds."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (cl-letf (((symbol-function 'ewoc-enter-last)
                 (lambda (&rest _) (error "simulated ewoc failure"))))
        (ignore-errors (mutecipher-acp--do-prompt sid "should-not-stick")))
      (should (null (macp-session-prompt-queue session)))
      (should (null (macp-session-queue-head-node session)))
      (should (= 0 (length (macp-test--queued-nodes)))))))

(ert-deftest macp-test-queue-remove-node-order-keeps-stores-in-sync ()
  "Same invariant on the removal side: if ewoc-delete signals,
prompt-queue must still contain the entry."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "a")
      (mutecipher-acp--do-prompt sid "b")
      (macp-test--goto-queued "a")
      (cl-letf (((symbol-function 'ewoc-delete)
                 (lambda (&rest _) (error "simulated ewoc failure"))))
        (ignore-errors (mutecipher-acp--queue-remove-at-point)))
      ;; List intact; both nodes still in the EWOC.
      (should (equal '("a" "b") (macp-session-prompt-queue session)))
      (should (= 2 (length (macp-test--queued-nodes)))))))

(ert-deftest macp-test-drain-recovers-when-head-node-nil-but-queue-nonempty ()
  "Stale state: `queue-head-node' is nil while prompt-queue still has an
entry whose queued EWOC node lives in the buffer.  --drain-queue should
recover by walking the EWOC for the actual head node."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session))
          (sent nil))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "orphan")
      ;; Simulate the stale state.
      (setf (macp-session-queue-head-node session) nil)
      (setf (macp-session-state session) 'idle)
      (cl-letf (((symbol-function 'mutecipher-acp--request)
                 (lambda (_conn _method params &rest _)
                   (push (plist-get params :prompt) sent))))
        (mutecipher-acp--drain-queue sid))
      ;; Drain succeeded — node deleted, queue popped, RPC fired.
      (should (= 1 (length sent)))
      (should (null (macp-session-prompt-queue session)))
      (should (= 0 (length (macp-test--queued-nodes)))))))

(ert-deftest macp-test-queued-nodes-stay-below-new-content ()
  "When a turn opens while the queue is non-empty, the new turn-header +
user nodes must land ABOVE the queued suffix."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (setf (macp-session-state session) 'thinking)
      (mutecipher-acp--do-prompt sid "queued-msg")
      ;; Now drain.  The popped item becomes a real turn — should appear
      ;; ABOVE remaining queued items (here, none remain, but exercise the
      ;; insertion path with a second queued item still present).
      (mutecipher-acp--do-prompt sid "stays-queued")
      (setf (macp-session-state session) 'idle)
      (mutecipher-acp--drain-queue sid)
      ;; Walk the ewoc: turn-header + user (from drained "queued-msg") must
      ;; precede the lone remaining queued node ("stays-queued").
      (let* ((kinds (cl-loop for n = (ewoc-nth mutecipher-acp--ewoc 0)
                              then (ewoc-next mutecipher-acp--ewoc n)
                              while n
                              collect (macp-node-kind (ewoc-data n)))))
        (should (memq 'turn-header kinds))
        (should (memq 'user kinds))
        (should (memq 'queued kinds))
        ;; turn-header index < queued index
        (should (< (cl-position 'turn-header kinds)
                   (cl-position 'queued kinds)))
        (should (< (cl-position 'user kinds)
                   (cl-position 'queued kinds)))))))

;;;; Code-health fixes

(ert-deftest macp-test-update-tool-call-missing-id-logs ()
  (let ((warnings 0))
    (cl-letf (((symbol-function 'mutecipher-acp--log-warn)
               (lambda (&rest _) (cl-incf warnings))))
      (let ((session-id "sess-x"))
        (puthash session-id
                 (mutecipher-acp--make-session
                  :id session-id
                  :buffer (generate-new-buffer " *macp-tc-test*")
                  :agent "claude")
                 mutecipher-acp--sessions)
        (unwind-protect
            (progn
              (mutecipher-acp--update-tool-call session-id
                                                 (list :status "completed"))
              (should (= 1 warnings)))
          (when-let ((s (gethash session-id mutecipher-acp--sessions)))
            (let ((b (macp-session-buffer s)))
              (when (buffer-live-p b) (kill-buffer b))))
          (remhash session-id mutecipher-acp--sessions))))))

(ert-deftest macp-test-update-tool-call-unknown-status-logs ()
  (let ((warnings nil))
    (cl-letf (((symbol-function 'mutecipher-acp--log-warn)
               (lambda (_dir _agent text) (push text warnings))))
      (let* ((session-id "sess-y")
             (buf        (generate-new-buffer " *macp-tc-test*"))
             (session    (mutecipher-acp--make-session
                          :id session-id :buffer buf :agent "claude"))
             (tc         (make-macp-tool-call :call-id "tc-1"
                                              :name "search"
                                              :status 'pending))
             (node       nil))
        (puthash session-id session mutecipher-acp--sessions)
        (with-current-buffer buf
          (mutecipher-acp-session-mode)
          (let ((inhibit-read-only t))
            (setq node (ewoc-enter-last
                        mutecipher-acp--ewoc
                        (make-macp-node :kind 'tool-call :data tc))))
          (puthash "tc-1" node (macp-session-tool-call-index session)))
        (unwind-protect
            (progn
              (mutecipher-acp--update-tool-call
               session-id (list :toolCallId "tc-1" :status "frobulating"))
              (should (cl-some (lambda (s)
                                 (string-match-p "unknown status" s))
                               warnings))
              (should (eq 'pending (macp-tool-call-status tc))))
          (let ((kill-buffer-hook nil))
            (when (buffer-live-p buf) (kill-buffer buf)))
          (remhash session-id mutecipher-acp--sessions))))))

(ert-deftest macp-test-dispatch-parse-error-broadcasts-notice ()
  (let* ((session-id "sess-z")
         (buf        (generate-new-buffer " *macp-parse-test*"))
         (notices    0))
    (puthash session-id
             (mutecipher-acp--make-session
              :id session-id :buffer buf :agent "claude"
              :conn (mutecipher-acp--make-conn
                     :process nil
                     :pending (make-hash-table)
                     :notify-fn #'ignore))
             mutecipher-acp--sessions)
    (cl-letf (((symbol-function 'process-name) (lambda (_) "claude-test"))
              ((symbol-function 'mutecipher-acp--log-warn)
               (lambda (&rest _) nil))
              ((symbol-function 'mutecipher-acp--enter-notice)
               (lambda (&rest _) (cl-incf notices))))
      (unwind-protect
          (let ((conn (macp-session-conn
                       (gethash session-id mutecipher-acp--sessions))))
            (mutecipher-acp--dispatch conn "not-valid-json")
            (should (= 1 notices)))
        (let ((kill-buffer-hook nil))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (remhash session-id mutecipher-acp--sessions)))))

;;;; Persistence

(ert-deftest macp-test-persist-roundtrip-nodes ()
  (let* ((tc      (make-macp-tool-call
                   :call-id "tc-1" :name "Bash" :kind 'execute
                   :input "ls -la"
                   :locations [(:path "/tmp/x")]
                   :status 'done
                   :diffs '(("a" . "b"))
                   :rendered-diff-count 1
                   :cached-start-line 42
                   :cached-start-key '(1 . 2)))
         (nodes   (list (make-macp-node
                         :kind 'user
                         :data (make-macp-user :text "hello")
                         :uuid "n_aaaaaaaaaaaa")
                        (make-macp-node
                         :kind 'assistant
                         :data (make-macp-assistant :text "world")
                         :uuid "n_bbbbbbbbbbbb")
                        (make-macp-node
                         :kind 'tool-call
                         :data tc
                         :uuid "n_cccccccccccc")
                        (make-macp-node
                         :kind 'trailer
                         :data (make-macp-trailer :stop-reason 'end_turn)
                         :uuid "n_dddddddddddd")))
         (stripped (mapcar #'mutecipher-acp--strip-transient-from-node
                           nodes))
         (tmp      (make-temp-file "macp-persist-roundtrip-" nil ".eld")))
    (unwind-protect
        (progn
          (mutecipher-acp--persist-write-sexp
           tmp (list :schema-version
                     mutecipher-acp--persist-schema-version
                     :nodes stripped))
          (let* ((sexp     (mutecipher-acp--persist-read-sexp tmp))
                 (restored (plist-get sexp :nodes)))
            (should (equal stripped restored))
            (should (equal "n_aaaaaaaaaaaa"
                           (macp-node-uuid (nth 0 restored))))
            (should (equal "n_cccccccccccc"
                           (macp-node-uuid (nth 2 restored))))))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest macp-test-persist-schema-version-mismatch ()
  (let* ((dir (mutecipher-acp--persist-dir))
         (sid "test-skip-version")
         (path (expand-file-name (concat sid ".eld") dir))
         (messages nil))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (mutecipher-acp--persist-write-sexp
           path (list :schema-version 999
                      :session (list :id sid :agent "claude"
                                     :cwd "/tmp" :title nil
                                     :last-active 0)
                      :nodes nil))
          (let ((snaps (mutecipher-acp--load-disk-snapshots)))
            (should (null (assoc sid snaps)))
            (should (cl-some (lambda (m)
                               (string-match-p "schema" m))
                             messages))))
      (when (file-exists-p path) (delete-file path)))))

(ert-deftest macp-test-persist-index-entry-shape ()
  (let* ((modes [(:id "sonnet" :name "Claude Sonnet 4")
                 (:id "opus"   :name "Claude Opus 4")])
         (session (mutecipher-acp--make-session
                   :id "abc-123" :agent "claude" :cwd "/tmp/proj"
                   :title "demo" :available-modes modes
                   :current-mode-id "sonnet"
                   :last-active 1700000000.0))
         (entry (mutecipher-acp--session->index-entry session)))
    (should (equal "abc-123"           (plist-get entry :id)))
    (should (equal "claude"            (plist-get entry :agent)))
    (should (equal "/tmp/proj"         (plist-get entry :cwd)))
    (should (equal "demo"              (plist-get entry :title)))
    (should (equal 1700000000.0        (plist-get entry :last-active)))
    (should (equal "Claude Sonnet 4"   (plist-get entry :model))))
  ;; Falls back to mode-id string when not in available-modes.
  (let* ((session (mutecipher-acp--make-session
                   :id "abc-456" :agent "claude" :cwd "/tmp"
                   :available-modes [(:id "sonnet" :name "Claude Sonnet 4")]
                   :current-mode-id "haiku"))
         (entry (mutecipher-acp--session->index-entry session)))
    (should (equal "haiku" (plist-get entry :model)))))

(ert-deftest macp-test-persist-loading-flag-suppresses-save ()
  "While SESSION's `loading' is t, --save-session must not write
and must NOT clear persist-dirty (a post-load save fires later)."
  (let* ((tmp-dir (file-name-as-directory (make-temp-file "macp-test-" t)))
         (sid "loading-test")
         (path (expand-file-name (concat sid ".eld") tmp-dir))
         (session (mutecipher-acp--make-session
                   :id sid :agent "claude" :cwd "/tmp"
                   :loading t :persist-dirty t)))
    (cl-letf (((symbol-function 'mutecipher-acp--persist-dir)
               (lambda () tmp-dir)))
      (unwind-protect
          (progn
            (mutecipher-acp--save-session session)
            (should-not (file-exists-p path))
            (should (macp-session-persist-dirty session)))
        (delete-directory tmp-dir t)))))

(ert-deftest macp-test-persist-empty-ewoc-doesnt-clobber-existing ()
  "An empty EWOC must not overwrite a previously-saved transcript."
  (let* ((tmp-dir (file-name-as-directory (make-temp-file "macp-test-" t)))
         (sid "clobber-test")
         (path (expand-file-name (concat sid ".eld") tmp-dir))
         (buf  (generate-new-buffer " *macp-clobber-test*"))
         (session (mutecipher-acp--make-session
                   :id sid :agent "claude" :cwd "/tmp"
                   :buffer buf :persist-dirty t)))
    (cl-letf (((symbol-function 'mutecipher-acp--persist-dir)
               (lambda () tmp-dir)))
      (unwind-protect
          (progn
            (mutecipher-acp--persist-write-sexp
             path (list :schema-version
                        mutecipher-acp--persist-schema-version
                        :session (list :id sid :agent "claude"
                                       :cwd "/tmp")
                        :nodes (list (make-macp-node
                                      :kind 'user
                                      :data (make-macp-user :text "hi")
                                      :uuid "n_x"))))
            (should (file-exists-p path))
            (let ((before-size (nth 7 (file-attributes path))))
              (mutecipher-acp--save-session session)
              (should (file-exists-p path))
              (should (= before-size (nth 7 (file-attributes path)))))
            (should-not (macp-session-persist-dirty session)))
        (let ((kill-buffer-hook nil))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (delete-directory tmp-dir t)))))

(ert-deftest macp-test-persist-unsafe-id-clears-dirty ()
  "Unsafe session id makes --save-session clear dirty (stops sweeper)."
  (let ((session (mutecipher-acp--make-session
                  :id "../escape" :persist-dirty t)))
    (should-not (mutecipher-acp--session-file (macp-session-id session)))
    (mutecipher-acp--save-session session)
    (should-not (macp-session-persist-dirty session))))

(ert-deftest macp-test-persist-bump-vs-mark-dirty ()
  "mark-dirty sets dirty only; bump-last-active sets both.
Both run during loading — the WRITE is gated by --save-session,
not the dirty/bump primitives — so server-authoritative state
changes during replay still reach disk on the post-load save."
  (let ((s (mutecipher-acp--make-session :id "x")))
    (mutecipher-acp--mark-dirty s)
    (should      (macp-session-persist-dirty s))
    (should-not  (macp-session-last-active   s))
    (setf (macp-session-persist-dirty s) nil)
    (mutecipher-acp--bump-last-active s)
    (should      (macp-session-persist-dirty s))
    (should      (numberp (macp-session-last-active s))))
  ;; Loading does NOT suppress dirty/bump anymore.
  (let ((s (mutecipher-acp--make-session :id "y" :loading t)))
    (mutecipher-acp--mark-dirty s)
    (should (macp-session-persist-dirty s))
    (mutecipher-acp--bump-last-active s)
    (should (numberp (macp-session-last-active s)))))

(ert-deftest macp-test-persist-save-session-clears-dirty-on-error ()
  "A signaling --save-session must clear persist-dirty so the idle
sweeper doesn't burn CPU spam-logging the same failure forever."
  (let* ((tmp-dir (file-name-as-directory (make-temp-file "macp-test-" t)))
         (sid     "err-test")
         (buf     (generate-new-buffer " *macp-err-test*"))
         (session (mutecipher-acp--make-session
                   :id sid :agent "claude" :cwd "/tmp"
                   :buffer buf :persist-dirty t)))
    (cl-letf (((symbol-function 'mutecipher-acp--persist-dir)
               (lambda () tmp-dir))
              ;; Force --collect-session-nodes to return non-empty so
              ;; we reach the write path...
              ((symbol-function 'mutecipher-acp--collect-session-nodes)
               (lambda (_) (list (make-macp-node :kind 'user :uuid "n_x"))))
              ;; ...then make the write itself blow up.
              ((symbol-function 'mutecipher-acp--persist-write-sexp)
               (lambda (&rest _) (error "synthetic write failure")))
              ((symbol-function 'message) #'ignore))
      (unwind-protect
          (progn
            (mutecipher-acp--save-session session)
            (should-not (macp-session-persist-dirty session)))
        (let ((kill-buffer-hook nil))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (delete-directory tmp-dir t)))))

(ert-deftest macp-test-persist-save-index-schema-mismatch-recovers ()
  "When the existing `index.eld' has an unknown schema version,
--save-index must recover the disk-only entries via load-disk-snapshots
instead of silently dropping them."
  (let* ((tmp-dir   (file-name-as-directory (make-temp-file "macp-test-" t)))
         (orphan-id "orphan-from-future")
         (saved-tbl mutecipher-acp--sessions))
    (cl-letf (((symbol-function 'mutecipher-acp--persist-dir)
               (lambda () tmp-dir)))
      (unwind-protect
          (progn
            (setq mutecipher-acp--sessions (make-hash-table :test #'equal))
            ;; Plant a v1-format snapshot file for the orphan session.
            (mutecipher-acp--persist-write-sexp
             (expand-file-name (concat orphan-id ".eld") tmp-dir)
             (list :schema-version
                   mutecipher-acp--persist-schema-version
                   :session (list :id orphan-id :agent "claude"
                                  :cwd "/tmp/orphan" :title nil
                                  :last-active 50.0)
                   :nodes nil))
            ;; Plant a future-schema index file that our save would
            ;; otherwise reject + erase.
            (mutecipher-acp--persist-write-sexp
             (mutecipher-acp--index-file)
             (list :schema-version 999 :entries nil))
            ;; Save with no live sessions — must NOT drop the orphan.
            (mutecipher-acp--save-index)
            (let* ((sexp (mutecipher-acp--persist-read-sexp
                          (mutecipher-acp--index-file)))
                   (ids  (mapcar (lambda (e) (plist-get e :id))
                                 (plist-get sexp :entries))))
              (should (member orphan-id ids))))
        (setq mutecipher-acp--sessions saved-tbl)
        (delete-directory tmp-dir t)))))

(ert-deftest macp-test-persist-snapshot-includes-prompt-queue ()
  "Session snapshot must carry the `prompt-queue' list so resumed
sessions can replay queued user input via --enqueue-prompt."
  (let* ((session (mutecipher-acp--make-session
                   :id "q-test" :agent "claude" :cwd "/tmp"
                   :prompt-queue '("first" "second")))
         (snap    (mutecipher-acp--session-snapshot session)))
    (should (equal '("first" "second") (plist-get snap :prompt-queue)))))

(ert-deftest macp-test-persist-utf8-roundtrip ()
  "Multibyte content survives prin1+read via UTF-8 coding."
  (let* ((text "こんにちは 🎉 café")
         (node (make-macp-node
                :kind 'user
                :data (make-macp-user :text text)
                :uuid "n_utf8"))
         (tmp (make-temp-file "macp-utf8-" nil ".eld")))
    (unwind-protect
        (progn
          (mutecipher-acp--persist-write-sexp
           tmp (list :schema-version
                     mutecipher-acp--persist-schema-version
                     :nodes (list node)))
          (let* ((sexp (mutecipher-acp--persist-read-sexp tmp))
                 (got  (car (plist-get sexp :nodes))))
            (should (equal text (macp-user-text (macp-node-data got))))))
      (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest macp-test-persist-format-label-nil-on-missing-id ()
  "format-resume-label returns nil for an entry without a string `:id'."
  (should (null (mutecipher-acp--format-resume-label
                 (list :title "demo" :agent "claude"))))
  (should (null (mutecipher-acp--format-resume-label
                 (list :id nil :title "demo"))))
  (should (stringp (mutecipher-acp--format-resume-label
                    (list :id "abcd-1234" :title "demo"
                          :cwd "/tmp" :model "Sonnet"
                          :last-active (float-time))))))

(ert-deftest macp-test-persist-save-index-preserves-disk-only ()
  "save-index reads the existing index file and keeps entries not in --sessions."
  (let* ((tmp-dir   (file-name-as-directory (make-temp-file "macp-test-" t)))
         (kept-id   "kept-by-other-emacs")
         (live-id   "live-here")
         (saved-tbl mutecipher-acp--sessions))
    (cl-letf (((symbol-function 'mutecipher-acp--persist-dir)
               (lambda () tmp-dir)))
      (unwind-protect
          (progn
            (setq mutecipher-acp--sessions (make-hash-table :test #'equal))
            (mutecipher-acp--persist-write-sexp
             (mutecipher-acp--index-file)
             (list :schema-version
                   mutecipher-acp--persist-schema-version
                   :entries (list (list :id kept-id :agent "claude"
                                        :cwd "/tmp/a" :last-active 100.0))))
            (puthash live-id
                     (mutecipher-acp--make-session
                      :id live-id :agent "claude" :cwd "/tmp/b"
                      :last-active 200.0)
                     mutecipher-acp--sessions)
            (mutecipher-acp--save-index)
            (let* ((sexp (mutecipher-acp--persist-read-sexp
                          (mutecipher-acp--index-file)))
                   (ids  (mapcar (lambda (e) (plist-get e :id))
                                 (plist-get sexp :entries))))
              (should (member live-id ids))
              (should (member kept-id ids))))
        (setq mutecipher-acp--sessions saved-tbl)
        (delete-directory tmp-dir t)))))

(ert-deftest macp-test-persist-strips-tool-call-cache ()
  (let* ((tc (make-macp-tool-call
              :call-id "x" :name "Bash"
              :status 'done
              :cached-start-line 7
              :cached-start-key '(3 . 4)))
         (node (make-macp-node :kind 'tool-call :data tc :uuid "n_x"))
         (stripped (mutecipher-acp--strip-transient-from-node node))
         (sdata (macp-node-data stripped)))
    (should (null (macp-tool-call-cached-start-line sdata)))
    (should (null (macp-tool-call-cached-start-key  sdata)))
    ;; Other fields preserved.
    (should (equal "x"   (macp-tool-call-call-id sdata)))
    (should (equal "Bash" (macp-tool-call-name sdata)))
    (should (eq 'done    (macp-tool-call-status sdata)))
    ;; Original untouched.
    (should (equal 7 (macp-tool-call-cached-start-line tc)))))

;;;; Change-sets

(ert-deftest macp-test-file-change-defaults ()
  "macp-file-change accessors return the slot values they were built with."
  (let ((fc (make-macp-file-change
             :path "/tmp/foo" :pre-turn-content "old"
             :pre-turn-existed t :capture-status 'ok
             :status 'accepted :tool-call-ids '("c1"))))
    (should (equal "/tmp/foo" (macp-file-change-path fc)))
    (should (equal "old" (macp-file-change-pre-turn-content fc)))
    (should (eq t (macp-file-change-pre-turn-existed fc)))
    (should (eq 'ok (macp-file-change-capture-status fc)))
    (should (eq 'accepted (macp-file-change-status fc)))
    (should (equal '("c1") (macp-file-change-tool-call-ids fc)))))

(ert-deftest macp-test-change-set-files-alist ()
  "macp-change-set stores files as an alist that supports assoc lookup."
  (let* ((fc (make-macp-file-change :path "/tmp/a" :capture-status 'ok))
         (cs (make-macp-change-set :files (list (cons "/tmp/a" fc)))))
    (should (eq fc (cdr (assoc "/tmp/a" (macp-change-set-files cs)))))
    (should (null (assoc "/tmp/missing" (macp-change-set-files cs))))))

(ert-deftest macp-test-replace-unique-plain ()
  (should (equal "abXcd" (mutecipher-acp--replace-unique "Y" "X" "abYcd")))
  (should (null (mutecipher-acp--replace-unique "Z" "X" "abc")))
  (should (null (mutecipher-acp--replace-unique "" "X" "abc")))
  ;; Multi-match: ambiguous, refuses to guess.
  (should (null (mutecipher-acp--replace-unique "y" "X" "yby")))
  ;; Single-match works.
  (should (equal "Xb" (mutecipher-acp--replace-unique "y" "X" "yb"))))

(ert-deftest macp-test-reverse-apply-pairs-happy ()
  "Reverse-apply maps post-edit content back to pre-edit content."
  (let* ((post "hello brave new world")
         (pairs (list (cons "old" "brave new")))  ; old→new during edit
         (result (mutecipher-acp--reverse-apply-pairs post pairs)))
    (should (eq 'ok (cdr result)))
    (should (equal "hello old world" (car result)))))

(ert-deftest macp-test-reverse-apply-pairs-multi-hunk ()
  "Multiple hunks reverse in arrival order."
  (let* ((post "AAA new1 BBB new2 CCC")
         (pairs (list (cons "old1" "new1")
                      (cons "old2" "new2")))
         (result (mutecipher-acp--reverse-apply-pairs post pairs)))
    (should (eq 'ok (cdr result)))
    (should (equal "AAA old1 BBB old2 CCC" (car result)))))

(ert-deftest macp-test-reverse-apply-pairs-missing ()
  "Missing newText aborts with reverse-apply-failed and nil content."
  (let ((result (mutecipher-acp--reverse-apply-pairs
                 "no match here"
                 (list (cons "old" "absent")))))
    (should (eq 'reverse-apply-failed (cdr result)))
    (should (null (car result)))))

(ert-deftest macp-test-reverse-apply-pairs-empty-new-skipped ()
  "Pair with empty newText is a no-op (creation marker)."
  (let ((result (mutecipher-acp--reverse-apply-pairs
                 "whole file"
                 (list (cons "" "")))))
    (should (eq 'ok (cdr result)))
    (should (equal "whole file" (car result)))))

(defmacro macp-test--with-temp-file (var content &rest body)
  "Bind VAR to a temp file pre-populated with CONTENT, run BODY, then delete it."
  (declare (indent 2) (debug (symbolp form body)))
  `(let ((,var (make-temp-file "macp-cs-" nil ".txt")))
     (unwind-protect
         (progn
           (with-temp-file ,var
             (let ((coding-system-for-write 'utf-8))
               (insert ,content)))
           ,@body)
       (when (file-exists-p ,var) (delete-file ,var)))))

(ert-deftest macp-test-capture-snapshot-edit-single-hunk ()
  "Disk has post-edit content; snapshot reconstructs pre-edit content."
  (macp-test--with-temp-file path "hello brave new world"
    (let ((snap (mutecipher-acp--capture-snapshot
                 path (list (cons "old" "brave new")))))
      (should (eq 'ok          (plist-get snap :capture-status)))
      (should (eq t            (plist-get snap :pre-turn-existed)))
      (should (equal "hello old world"
                     (plist-get snap :pre-turn-content))))))

(ert-deftest macp-test-capture-snapshot-edit-multi-hunk ()
  (macp-test--with-temp-file path "AAA new1 BBB new2 CCC"
    (let ((snap (mutecipher-acp--capture-snapshot
                 path (list (cons "old1" "new1")
                            (cons "old2" "new2")))))
      (should (eq 'ok (plist-get snap :capture-status)))
      (should (equal "AAA old1 BBB old2 CCC"
                     (plist-get snap :pre-turn-content))))))

(ert-deftest macp-test-capture-snapshot-write-overwrite ()
  "Write that overwrites an existing file: oldText is full prior content."
  (macp-test--with-temp-file path "BRAND NEW CONTENT\n"
    (let ((snap (mutecipher-acp--capture-snapshot
                 path (list (cons "OLD CONTENT\n" "BRAND NEW CONTENT\n")))))
      (should (eq 'ok (plist-get snap :capture-status)))
      (should (eq t   (plist-get snap :pre-turn-existed)))
      (should (equal "OLD CONTENT\n" (plist-get snap :pre-turn-content))))))

(ert-deftest macp-test-capture-snapshot-write-create ()
  "Write that creates a new file: oldText empty, reverse yields empty content."
  (macp-test--with-temp-file path "FILE CREATED BY AGENT"
    (let ((snap (mutecipher-acp--capture-snapshot
                 path (list (cons "" "FILE CREATED BY AGENT")))))
      (should (eq 'ok  (plist-get snap :capture-status)))
      (should (eq nil  (plist-get snap :pre-turn-existed)))
      (should (null    (plist-get snap :pre-turn-content))))))

(ert-deftest macp-test-capture-snapshot-too-large ()
  (macp-test--with-temp-file path (make-string 4096 ?x)
    (let ((mutecipher-acp-change-set-max-bytes 16))
      (let ((snap (mutecipher-acp--capture-snapshot
                   path (list (cons "old" "new")))))
        (should (eq 'suppressed-too-large
                    (plist-get snap :capture-status)))
        (should (null (plist-get snap :pre-turn-content)))))))

(ert-deftest macp-test-capture-snapshot-reverse-apply-failed ()
  (macp-test--with-temp-file path "current content"
    (let ((snap (mutecipher-acp--capture-snapshot
                 path (list (cons "old" "absent-string")))))
      (should (eq 'reverse-apply-failed
                  (plist-get snap :capture-status)))
      (should (null (plist-get snap :pre-turn-content))))))

(ert-deftest macp-test-capture-snapshot-utf8 ()
  "Multibyte content snapshots correctly."
  (macp-test--with-temp-file path "こんにちは brave 🎉 world"
    (let ((snap (mutecipher-acp--capture-snapshot
                 path (list (cons "kind" "brave")))))
      (should (eq 'ok (plist-get snap :capture-status)))
      (should (equal "こんにちは kind 🎉 world"
                     (plist-get snap :pre-turn-content))))))

;;;; Change-set integration with session + turn

(defmacro macp-test--with-turn-session (var-session &rest body)
  "Like `macp-test--with-queue-session' but also opens a fresh turn.
Binds VAR-SESSION to the session, leaves a turn-header node at the
tail of the EWOC with `current-turn-node' pointing at it.  Stubs
RPC and persistence I/O."
  (declare (indent 1) (debug ((symbolp) body)))
  `(macp-test--with-queue-session ,var-session
     (mutecipher-acp--open-turn (macp-session-id ,var-session) "test prompt")
     ,@body))

(ert-deftest macp-test-change-set-lazy-alloc ()
  "First mutation allocates the turn's change-set; second reuses it."
  (macp-test--with-turn-session session
    (macp-test--with-temp-file path "hello new world"
      (let ((tc (make-macp-tool-call
                 :call-id "c1" :name "Edit" :kind "edit"
                 :locations (vector (list :path path)))))
        (let ((turn (macp-node-data
                     (ewoc-data (macp-session-current-turn-node session)))))
          (should (null (macp-turn-change-set turn)))
          (mutecipher-acp--maybe-capture-change-set
           session tc (list (cons "old" "new")))
          (should (macp-turn-change-set turn))
          (let ((cs (macp-turn-change-set turn)))
            (mutecipher-acp--maybe-capture-change-set
             session tc (list (cons "old" "new")))
            (should (eq cs (macp-turn-change-set turn)))))))))

(ert-deftest macp-test-change-set-captures-pre-turn-content ()
  (macp-test--with-turn-session session
    (macp-test--with-temp-file path "AAA brave new BBB"
      ;; file-truename canonicalizes (e.g. /tmp → /private/tmp on macOS),
      ;; so look up by the same form `--resolve-loc-path' produced.
      (let* ((tc (make-macp-tool-call
                  :call-id "c1" :name "Edit" :kind "edit"
                  :locations (vector (list :path path))))
             (canon (file-truename path)))
        (mutecipher-acp--maybe-capture-change-set
         session tc (list (cons "old" "brave new")))
        (let* ((turn (macp-node-data
                      (ewoc-data (macp-session-current-turn-node session))))
               (cs   (macp-turn-change-set turn))
               (fc   (cdr (assoc canon (macp-change-set-files cs)))))
          (should fc)
          (should (eq 'ok (macp-file-change-capture-status fc)))
          (should (equal "AAA old BBB"
                         (macp-file-change-pre-turn-content fc)))
          (should (equal '("c1") (macp-file-change-tool-call-ids fc))))))))

(ert-deftest macp-test-change-set-repeat-edits-preserve-baseline ()
  "Two chained edits to the same path: accumulated pairs reverse-apply
to the ORIGINAL pre-turn content (not the intermediate state)."
  (macp-test--with-turn-session session
    (macp-test--with-temp-file path "STAGE_TWO"
      ;; First call: disk reflects STAGE_ONE.
      (with-temp-file path
        (let ((coding-system-for-write 'utf-8-unix))
          (insert "STAGE_ONE")))
      (let ((tc1 (make-macp-tool-call
                  :call-id "c1" :locations (vector (list :path path)))))
        (mutecipher-acp--maybe-capture-change-set
         session tc1 (list (cons "ORIGINAL" "STAGE_ONE"))))
      ;; Second call: disk advanced to STAGE_TWO.
      (with-temp-file path
        (let ((coding-system-for-write 'utf-8-unix))
          (insert "STAGE_TWO")))
      (let ((tc2 (make-macp-tool-call
                  :call-id "c2" :locations (vector (list :path path)))))
        (mutecipher-acp--maybe-capture-change-set
         session tc2 (list (cons "STAGE_ONE" "STAGE_TWO"))))
      (let* ((turn (macp-node-data
                    (ewoc-data (macp-session-current-turn-node session))))
             (cs   (macp-turn-change-set turn))
             (canon (file-truename path))
             (fc   (cdr (assoc canon (macp-change-set-files cs)))))
        (should (equal "ORIGINAL" (macp-file-change-pre-turn-content fc)))
        (should (equal '("c1" "c2") (macp-file-change-tool-call-ids fc)))
        ;; Both pairs accumulated in chronological order on the fc.
        (should (equal '(("ORIGINAL" . "STAGE_ONE")
                         ("STAGE_ONE" . "STAGE_TWO"))
                       (macp-file-change-accumulated-pairs fc)))))))

(ert-deftest macp-test-change-set-no-path-skipped ()
  "Tool call with no resolvable location does not enter the change-set."
  (macp-test--with-turn-session session
    (let ((tc (make-macp-tool-call :call-id "c1" :name "Edit"
                                    :locations nil)))
      (mutecipher-acp--maybe-capture-change-set
       session tc (list (cons "old" "new")))
      (let* ((turn (macp-node-data
                    (ewoc-data (macp-session-current-turn-node session)))))
        (should (null (macp-turn-change-set turn)))))))

(ert-deftest macp-test-change-set-no-current-turn-skipped ()
  (macp-test--with-queue-session session
    (let ((tc (make-macp-tool-call
               :call-id "c1" :locations (vector (list :path "/tmp/x")))))
      ;; Should not signal, should not allocate anything.
      (mutecipher-acp--maybe-capture-change-set
       session tc (list (cons "old" "new"))))))

(ert-deftest macp-test-change-set-empty-pairs-skipped ()
  (macp-test--with-turn-session session
    (macp-test--with-temp-file path "anything"
      (let ((tc (make-macp-tool-call
                 :call-id "c1" :locations (vector (list :path path)))))
        (mutecipher-acp--maybe-capture-change-set session tc nil)
        (let ((turn (macp-node-data
                     (ewoc-data (macp-session-current-turn-node session)))))
          (should (null (macp-turn-change-set turn))))))))

;;;; Revert command

(ert-deftest macp-test-apply-file-revert-restores-edit ()
  (macp-test--with-temp-file path "POST_EDIT_CONTENT"
    (let ((fc (make-macp-file-change
               :path path :pre-turn-content "PRE_EDIT_CONTENT"
               :pre-turn-existed t :capture-status 'ok
               :status 'accepted)))
      (should (eq 'reverted (mutecipher-acp--apply-file-revert fc)))
      (should (eq 'reverted (macp-file-change-status fc)))
      (should (equal "PRE_EDIT_CONTENT"
                     (with-temp-buffer
                       (insert-file-contents path)
                       (buffer-string)))))))

(ert-deftest macp-test-apply-file-revert-deletes-created-file ()
  (let ((path (make-temp-file "macp-cs-create-" nil ".txt")))
    (with-temp-file path (insert "agent created me"))
    (unwind-protect
        (let ((fc (make-macp-file-change
                   :path path :pre-turn-content nil
                   :pre-turn-existed nil :capture-status 'ok
                   :status 'accepted)))
          (should (eq 'reverted (mutecipher-acp--apply-file-revert fc)))
          (should (eq 'reverted (macp-file-change-status fc)))
          (should-not (file-exists-p path)))
      (when (file-exists-p path) (delete-file path)))))

(ert-deftest macp-test-apply-file-revert-skips-non-ok ()
  (let ((fc (make-macp-file-change
             :path "/tmp/does-not-matter"
             :capture-status 'suppressed-too-large
             :status 'accepted)))
    (should (eq 'skipped (mutecipher-acp--apply-file-revert fc)))
    (should (eq 'accepted (macp-file-change-status fc))))
  (let ((fc (make-macp-file-change
             :path "/tmp/does-not-matter"
             :capture-status 'ok
             :status 'reverted)))
    (should (eq 'skipped (mutecipher-acp--apply-file-revert fc)))))

;;;; Persistence round-trip

(ert-deftest macp-test-persist-change-set-roundtrip ()
  "Turn node with a change-set survives prin1+read through the persist layer."
  (let* ((fc (make-macp-file-change
              :path "/tmp/foo.el"
              :pre-turn-content "old content"
              :pre-turn-existed t
              :capture-status 'ok
              :status 'accepted
              :tool-call-ids '("c1" "c2")))
         (cs   (make-macp-change-set :files (list (cons "/tmp/foo.el" fc))))
         (turn (make-macp-turn :id 3 :started-at 1.0 :ended-at 2.0
                               :stop-reason 'end_turn :change-set cs))
         (node (make-macp-node :kind 'turn-header :data turn :uuid "n_turn"))
         (tmp  (make-temp-file "macp-cs-rt-" nil ".eld")))
    (unwind-protect
        (progn
          (mutecipher-acp--persist-write-sexp
           tmp (list :schema-version
                     mutecipher-acp--persist-schema-version
                     :nodes (list node)))
          (let* ((sexp     (mutecipher-acp--persist-read-sexp tmp))
                 (got-node (car (plist-get sexp :nodes)))
                 (got-turn (macp-node-data got-node))
                 (got-cs   (macp-turn-change-set got-turn))
                 (got-fc   (cdr (assoc "/tmp/foo.el"
                                       (macp-change-set-files got-cs)))))
            (should (macp-change-set-p got-cs))
            (should got-fc)
            (should (equal "old content"
                           (macp-file-change-pre-turn-content got-fc)))
            (should (eq t (macp-file-change-pre-turn-existed got-fc)))
            (should (eq 'ok (macp-file-change-capture-status got-fc)))
            (should (eq 'accepted (macp-file-change-status got-fc)))
            (should (equal '("c1" "c2")
                           (macp-file-change-tool-call-ids got-fc)))))
      (when (file-exists-p tmp) (delete-file tmp)))))

;;;; Change-set — post-review fix coverage

(ert-deftest macp-test-reverse-apply-pairs-chained-multiedit ()
  "MultiEdit-style chained pairs (edit N+1's old == edit N's new) reverse
correctly only when iterated in REVERSE chronological order."
  (let* ((post "z")
         (pairs (list (cons "x" "y") (cons "y" "z")))
         (result (mutecipher-acp--reverse-apply-pairs post pairs)))
    (should (eq 'ok (cdr result)))
    (should (equal "x" (car result)))))

(ert-deftest macp-test-reverse-apply-pairs-deletion-fails ()
  "A pair with non-empty oldText and empty newText is a deletion that
can't be reversed without a position anchor; reverse-apply refuses."
  (let ((result (mutecipher-acp--reverse-apply-pairs
                 "post-deletion content"
                 (list (cons "removed paragraph\n" "")))))
    (should (eq 'reverse-apply-failed (cdr result)))
    (should (null (car result)))))

(ert-deftest macp-test-reverse-apply-pairs-multi-match-fails ()
  "If newText appears more than once in the current content, the pair is
ambiguous and reverse-apply refuses rather than guessing."
  (let ((result (mutecipher-acp--reverse-apply-pairs
                 "foo bar foo bar foo"
                 (list (cons "qux" "foo")))))
    (should (eq 'reverse-apply-failed (cdr result)))))

(ert-deftest macp-test-resolve-loc-path-normalizes ()
  "Relative paths, absolute paths with `/./', and symlinked paths all
canonicalize to the same key."
  (let* ((dir (file-name-as-directory (make-temp-file "macp-norm-" t)))
         (real (expand-file-name "foo.el" dir))
         (truedir (file-truename dir))
         (truepath (expand-file-name "foo.el" truedir)))
    (unwind-protect
        (progn
          (with-temp-file real (insert "content"))
          (let* ((tc-rel (make-macp-tool-call
                          :locations (vector (list :path "foo.el"))))
                 (tc-dotted (make-macp-tool-call
                              :locations
                              (vector (list :path
                                            (concat dir "./foo.el")))))
                 (tc-abs (make-macp-tool-call
                           :locations (vector (list :path real)))))
            (should (equal truepath
                           (mutecipher-acp--resolve-loc-path tc-rel dir)))
            (should (equal truepath
                           (mutecipher-acp--resolve-loc-path tc-dotted dir)))
            (should (equal truepath
                           (mutecipher-acp--resolve-loc-path tc-abs dir)))))
      (delete-directory dir t))))

(ert-deftest macp-test-capture-handles-disk-error-without-throwing ()
  "I/O errors during capture are logged, not propagated — the agent's
turn must not break because of a permission/read failure on one file."
  (macp-test--with-turn-session session
    (let* ((tc (make-macp-tool-call
                :call-id "c1"
                :locations (vector (list :path "/nonexistent/no/permission/foo.el")))))
      ;; insert-file-contents on a missing file signals — but the wrapper
      ;; must absorb it.  This call MUST NOT raise.
      (should-not
       (condition-case _err
           (progn (mutecipher-acp--maybe-capture-change-set
                   session tc (list (cons "old" "new")))
                  nil)
         (error t))))))

(ert-deftest macp-test-capture-retroactive-when-locations-arrive-late ()
  "When the first ingest has no resolvable path and a later update merges
locations with no new pairs, capture happens retroactively from
TC.diffs."
  (macp-test--with-turn-session session
    (macp-test--with-temp-file path "POST_EDIT"
      (let ((tc (make-macp-tool-call
                 :call-id "c1"
                 :locations nil
                 :diffs (list (cons "PRE_EDIT" "POST_EDIT")))))
        ;; First call: no path, would-be new-pairs supplied but path
        ;; resolution bails.  No capture.
        (mutecipher-acp--maybe-capture-change-set
         session tc (list (cons "PRE_EDIT" "POST_EDIT")))
        (let* ((turn (macp-node-data
                      (ewoc-data (macp-session-current-turn-node session)))))
          (should (null (macp-turn-change-set turn))))
        ;; Second call: locations now resolve; new-pairs nil (already
        ;; ingested) but tc.diffs has them.  Retroactive capture.
        (setf (macp-tool-call-locations tc)
              (vector (list :path path)))
        (mutecipher-acp--maybe-capture-change-set session tc nil)
        (let* ((turn (macp-node-data
                      (ewoc-data (macp-session-current-turn-node session))))
               (cs   (macp-turn-change-set turn))
               (canon (file-truename path))
               (fc   (cdr (assoc canon (macp-change-set-files cs)))))
          (should fc)
          (should (eq 'ok (macp-file-change-capture-status fc)))
          (should (equal "PRE_EDIT"
                         (macp-file-change-pre-turn-content fc))))))))

(ert-deftest macp-test-capture-retries-after-reverse-apply-failed ()
  "An initial capture that failed (e.g. pending status before the
mutation landed) retries on the next observation and can succeed.
Mirrors the production flow: `--ingest-tool-content' populates
`tc.diffs' on each delivery; the retry update arrives with no NEW pairs
(rendered-diff-count already covers them) so `new-pairs' is nil but
the prior pairs survive on the file-change."
  (macp-test--with-turn-session session
    (macp-test--with-temp-file path "PRE_EDIT"
      ;; First capture: disk still pre-edit (status='pending arrival).
      (let ((tc (make-macp-tool-call
                 :call-id "c1"
                 :locations (vector (list :path path))
                 :diffs (list (cons "PRE_EDIT" "POST_EDIT")))))
        (mutecipher-acp--maybe-capture-change-set
         session tc (list (cons "PRE_EDIT" "POST_EDIT"))))
      (let* ((turn (macp-node-data
                    (ewoc-data (macp-session-current-turn-node session))))
             (cs (macp-turn-change-set turn))
             (canon (file-truename path))
             (fc (cdr (assoc canon (macp-change-set-files cs)))))
        (should (eq 'reverse-apply-failed
                    (macp-file-change-capture-status fc))))
      ;; Disk advances to post-edit; retry update arrives with no new pairs.
      (with-temp-file path
        (let ((coding-system-for-write 'utf-8-unix))
          (insert "POST_EDIT")))
      (let ((tc (make-macp-tool-call
                 :call-id "c1"
                 :locations (vector (list :path path))
                 :diffs (list (cons "PRE_EDIT" "POST_EDIT")))))
        (mutecipher-acp--maybe-capture-change-set session tc nil))
      (let* ((turn (macp-node-data
                    (ewoc-data (macp-session-current-turn-node session))))
             (cs (macp-turn-change-set turn))
             (canon (file-truename path))
             (fc (cdr (assoc canon (macp-change-set-files cs)))))
        (should (eq 'ok (macp-file-change-capture-status fc)))
        (should (equal "PRE_EDIT"
                       (macp-file-change-pre-turn-content fc)))))))

(ert-deftest macp-test-refresh-deleted-file-marks-buffer-modified ()
  "When the file underlying a buffer was just deleted, the buffer is
marked modified (not killed) so the user can recover its contents."
  (let* ((path (make-temp-file "macp-refresh-" nil ".txt"))
         (canon (file-truename path)))
    (with-temp-file path (insert "content"))
    (let ((buf (find-file-noselect canon)))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (should-not (buffer-modified-p)))
            (delete-file path)
            (mutecipher-acp--refresh-visiting-buffers canon)
            (with-current-buffer buf
              (should (buffer-modified-p))))
        (let ((kill-buffer-query-functions nil))
          (when (buffer-live-p buf)
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))
        (when (file-exists-p path) (delete-file path))))))

(ert-deftest macp-test-later-turns-after-orders-correctly ()
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (mutecipher-acp--open-turn sid "first")
      (let ((t1 (macp-node-data
                 (ewoc-data (macp-session-current-turn-node session)))))
        (mutecipher-acp--close-turn sid 'end_turn)
        (mutecipher-acp--open-turn sid "second")
        (let ((t2 (macp-node-data
                   (ewoc-data (macp-session-current-turn-node session)))))
          (mutecipher-acp--close-turn sid 'end_turn)
          (mutecipher-acp--open-turn sid "third")
          (let ((t3 (macp-node-data
                     (ewoc-data (macp-session-current-turn-node session)))))
            ;; Turns after t1 are t2 and t3.
            (let ((later (mutecipher-acp--later-turns-after t1)))
              (should (equal (list t2 t3) later)))
            ;; Turns after t3 (the current/last) is empty.
            (should (null (mutecipher-acp--later-turns-after t3)))))))))

(ert-deftest macp-test-paths-touched-by-later-turns-flags-overlap ()
  "Cross-turn detection: if turn 2 touches path P that turn 1 also touched,
reverting turn 1 must flag P as a conflict."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (mutecipher-acp--open-turn sid "first")
      (let* ((t1 (macp-node-data
                  (ewoc-data (macp-session-current-turn-node session))))
             (cs1 (make-macp-change-set
                   :files (list
                           (cons "/canonical/foo.el"
                                 (make-macp-file-change
                                  :path "/canonical/foo.el"
                                  :capture-status 'ok
                                  :status 'accepted))))))
        (setf (macp-turn-change-set t1) cs1)
        (mutecipher-acp--close-turn sid 'end_turn)
        (mutecipher-acp--open-turn sid "second")
        (let* ((t2 (macp-node-data
                    (ewoc-data (macp-session-current-turn-node session))))
               (cs2 (make-macp-change-set
                     :files (list
                             (cons "/canonical/foo.el"
                                   (make-macp-file-change
                                    :path "/canonical/foo.el"
                                    :capture-status 'ok
                                    :status 'accepted))
                             (cons "/canonical/bar.el"
                                   (make-macp-file-change
                                    :path "/canonical/bar.el"
                                    :capture-status 'ok
                                    :status 'accepted))))))
          (setf (macp-turn-change-set t2) cs2)
          ;; Reverting t1's foo.el conflicts with t2's foo.el.
          (let ((conflicts (mutecipher-acp--paths-touched-by-later-turns
                            t1 '("/canonical/foo.el"))))
            (should (equal '("/canonical/foo.el") conflicts)))
          ;; A path only t1 touched (bar) wouldn't be in t1's target
          ;; list; if the caller passes only t1's paths, no conflict
          ;; with bar — and a path with only t2 has no LATER turns
          ;; against it.
          (let ((conflicts (mutecipher-acp--paths-touched-by-later-turns
                            t1 '("/canonical/bar.el"))))
            (should (equal '("/canonical/bar.el") conflicts)))
          ;; A path neither turn touched yields no conflict.
          (let ((conflicts (mutecipher-acp--paths-touched-by-later-turns
                            t1 '("/canonical/quux.el"))))
            (should (null conflicts))))))))

(ert-deftest macp-test-paths-touched-skips-already-reverted ()
  "Later turns whose file-change is already reverted don't count as conflicts."
  (macp-test--with-queue-session session
    (let ((sid (macp-session-id session)))
      (mutecipher-acp--open-turn sid "first")
      (let ((t1 (macp-node-data
                 (ewoc-data (macp-session-current-turn-node session)))))
        (setf (macp-turn-change-set t1) (make-macp-change-set))
        (mutecipher-acp--close-turn sid 'end_turn)
        (mutecipher-acp--open-turn sid "second")
        (let* ((t2 (macp-node-data
                    (ewoc-data (macp-session-current-turn-node session))))
               (cs2 (make-macp-change-set
                     :files (list
                             (cons "/canonical/foo.el"
                                   (make-macp-file-change
                                    :path "/canonical/foo.el"
                                    :capture-status 'ok
                                    :status 'reverted))))))
          (setf (macp-turn-change-set t2) cs2)
          (should (null (mutecipher-acp--paths-touched-by-later-turns
                         t1 '("/canonical/foo.el")))))))))

(ert-deftest macp-test-apply-file-revert-logs-narrow-errors ()
  "Narrowed condition-case: `file-error' returns `failed' and logs;
non-IO programmer errors (e.g. wrong-type-argument from a malformed fc)
are NOT swallowed."
  ;; File-error path: write to a directory that doesn't exist.
  (let ((fc (make-macp-file-change
             :path "/no/such/dir/file"
             :pre-turn-content "x"
             :pre-turn-existed t
             :capture-status 'ok
             :status 'accepted)))
    (should (eq 'failed (mutecipher-acp--apply-file-revert fc))))
  ;; Programmer-error path: a non-macp-file-change argument MUST raise
  ;; (the old `(error 'failed)' catchall would have hidden this).
  (should-error (mutecipher-acp--apply-file-revert "not-a-fc")
                :type 'wrong-type-argument))

(ert-deftest macp-test-buffers-visiting-uses-canonical-name ()
  "Buffer matching uses canonicalized file names, so `/tmp/x' and
`/private/tmp/x' (on macOS) resolve to the same set."
  (let* ((path (make-temp-file "macp-bv-" nil ".txt"))
         (canon (file-truename path)))
    (with-temp-file path (insert "x"))
    (let ((buf (find-file-noselect canon)))
      (unwind-protect
          (progn
            (should (memq buf (mutecipher-acp--buffers-visiting canon)))
            (should (memq buf (mutecipher-acp--buffers-visiting path))))
        (let ((kill-buffer-query-functions nil))
          (when (buffer-live-p buf) (kill-buffer buf)))
        (when (file-exists-p path) (delete-file path))))))

;;;; Tool-kind icon mapping (post-split)

(ert-deftest macp-test-tool-kind-icon-key-explicit-kinds ()
  "ACP `:kind' values map to dedicated icon-keys."
  (should (eq 'tool-edit        (mutecipher-acp--tool-kind-icon-key "edit")))
  (should (eq 'tool-write       (mutecipher-acp--tool-kind-icon-key "write")))
  (should (eq 'tool-bash        (mutecipher-acp--tool-kind-icon-key "execute")))
  (should (eq 'tool-read        (mutecipher-acp--tool-kind-icon-key "read")))
  (should (eq 'tool-grep        (mutecipher-acp--tool-kind-icon-key "search")))
  (should (eq 'tool-delete      (mutecipher-acp--tool-kind-icon-key "delete")))
  (should (eq 'tool-move        (mutecipher-acp--tool-kind-icon-key "move")))
  (should (eq 'tool-fetch       (mutecipher-acp--tool-kind-icon-key "fetch")))
  (should (eq 'tool-think       (mutecipher-acp--tool-kind-icon-key "think")))
  (should (eq 'tool-switch-mode (mutecipher-acp--tool-kind-icon-key "switch_mode"))))

(ert-deftest macp-test-tool-kind-icon-key-name-probe ()
  "When kind is missing or `other', the claudeCode tool name still steers the icon."
  (should (eq 'tool-todo        (mutecipher-acp--tool-kind-icon-key nil "TodoWrite")))
  (should (eq 'tool-task        (mutecipher-acp--tool-kind-icon-key "other" "Task")))
  (should (eq 'tool-fetch       (mutecipher-acp--tool-kind-icon-key nil "WebFetch")))
  (should (eq 'tool-fetch       (mutecipher-acp--tool-kind-icon-key nil "WebSearch")))
  (should (eq 'tool-edit        (mutecipher-acp--tool-kind-icon-key nil "NotebookEdit")))
  (should (eq 'tool-read        (mutecipher-acp--tool-kind-icon-key nil "NotebookRead")))
  (should (eq 'tool-grep        (mutecipher-acp--tool-kind-icon-key nil "Glob")))
  (should (eq 'tool-switch-mode (mutecipher-acp--tool-kind-icon-key nil "ExitPlanMode")))
  ;; Unknown name + unknown kind → tool-other (fallback never returns nil).
  (should (eq 'tool-other       (mutecipher-acp--tool-kind-icon-key nil "Mystery")))
  (should (eq 'tool-other       (mutecipher-acp--tool-kind-icon-key nil nil))))

;;;; Kind-aware input formatting

(ert-deftest macp-test-format-tool-input-move-renders-from-arrow-to ()
  (let ((s (mutecipher-acp--format-tool-input
            '(:source "/tmp/old.txt" :destination "/tmp/new.txt")
            nil "move")))
    (should s)
    (should (string-match-p " → " s))))

(ert-deftest macp-test-format-tool-input-switch-mode ()
  (should (equal "plan"
                 (mutecipher-acp--format-tool-input
                  '(:mode "plan") nil "switch_mode")))
  (should (equal "default → plan"
                 (mutecipher-acp--format-tool-input
                  '(:mode "plan" :previousMode "default")
                  nil "switch_mode"))))

(ert-deftest macp-test-format-tool-input-fetch-prefers-url ()
  "WebFetch's :prompt should not shadow the URL the user wants to see."
  (should (equal "https://example.test/page"
                 (mutecipher-acp--format-tool-input
                  '(:url "https://example.test/page"
                    :prompt "extract the title")
                  nil "fetch")))
  (should (equal "claude code mcp"
                 (mutecipher-acp--format-tool-input
                  '(:query "claude code mcp") nil "fetch"))))

;;;; Body-renderer registry

(ert-deftest macp-test-tool-body-renderer-registry-defaults ()
  "Tier-1 renderers are registered at module load, including the kind-keyed
fetch fallback that fires for agents without claudeCode toolName."
  (dolist (key '("TodoWrite" "Task" "WebFetch" "WebSearch" "fetch"))
    (should (functionp (alist-get key mutecipher-acp-tool-body-renderers
                                  nil nil #'equal)))))

(ert-deftest macp-test-lookup-tool-body-renderer-falls-back-to-kind ()
  "Lookup tries name first, then kind — an agent that ships `:kind \"fetch\"'
without `_meta.claudeCode.toolName' (so `name' is the title or kind itself)
still hits the fetch renderer."
  (let ((fetch-fn (alist-get "fetch" mutecipher-acp-tool-body-renderers
                             nil nil #'equal)))
    ;; Name-keyed hit.
    (should (eq fetch-fn
                (mutecipher-acp--lookup-tool-body-renderer
                 (make-macp-tool-call :name "WebFetch" :kind "fetch"))))
    ;; Name miss → kind hit.
    (should (eq fetch-fn
                (mutecipher-acp--lookup-tool-body-renderer
                 (make-macp-tool-call :name "Fetching..." :kind "fetch"))))
    ;; Neither matches → nil.
    (should (null
             (mutecipher-acp--lookup-tool-body-renderer
              (make-macp-tool-call :name "Unknown" :kind "other"))))))

(ert-deftest macp-test-tool-body-renderer-registry-override ()
  "`-register-tool-body-renderer' upserts under the same name."
  (let ((mutecipher-acp-tool-body-renderers
         (copy-sequence mutecipher-acp-tool-body-renderers)))
    (mutecipher-acp-register-tool-body-renderer "TestTool" #'ignore)
    (should (eq #'ignore
                (alist-get "TestTool" mutecipher-acp-tool-body-renderers
                           nil nil #'equal)))
    (mutecipher-acp-register-tool-body-renderer
     "TestTool" (lambda (_tc) (insert "x")))
    (should-not (eq #'ignore
                    (alist-get "TestTool" mutecipher-acp-tool-body-renderers
                               nil nil #'equal)))))

(ert-deftest macp-test-todo-item-icon-key-mapping ()
  (should (eq 'plan-done       (mutecipher-acp--todo-item-icon-key "completed")))
  (should (eq 'plan-inprogress (mutecipher-acp--todo-item-icon-key "in_progress")))
  (should (eq 'plan-pending    (mutecipher-acp--todo-item-icon-key "pending")))
  (should (eq 'plan-pending    (mutecipher-acp--todo-item-icon-key nil))))

;;;; Body renderer smoke (inserts something non-empty)

(defun macp-test--render-body (renderer tc)
  "Run RENDERER on TC in a temp buffer and return the resulting string."
  (with-temp-buffer
    (funcall renderer tc)
    (buffer-string)))

(ert-deftest macp-test-render-todo-body-uses-active-form-while-running ()
  (let* ((tc (make-macp-tool-call
              :name "TodoWrite"
              :raw-input
              '(:todos
                [(:content "Refactor X" :activeForm "Refactoring X"
                  :status "in_progress")
                 (:content "Write Y"    :activeForm "Writing Y"
                  :status "pending")
                 (:content "Ship Z"     :activeForm "Shipping Z"
                  :status "completed")])))
         (out (macp-test--render-body
               #'mutecipher-acp--render-todo-body tc)))
    ;; in_progress prefers `activeForm'.
    (should (string-match-p "Refactoring X" out))
    ;; pending uses plain content.
    (should (string-match-p "Write Y" out))
    ;; completed renders content (strike-through is a face, not text).
    (should (string-match-p "Ship Z" out))))

(ert-deftest macp-test-render-fetch-body-surfaces-url ()
  (cl-letf (((symbol-function 'mutecipher-acp--pp-default-tool-body) #'ignore))
    (let* ((tc (make-macp-tool-call
                :name "WebFetch"
                :raw-input '(:url "https://example.test/x" :prompt "extract")))
           (out (macp-test--render-body
                 #'mutecipher-acp--render-fetch-body tc)))
      (should (string-match-p "https://example.test/x" out))
      (should (string-match-p "url:" out)))))

;;;; Ingest preserves raw-input

(ert-deftest macp-test-tool-call-struct-has-raw-input-slot ()
  "Body renderers depend on the struct carrying the original :rawInput."
  (let ((tc (make-macp-tool-call :raw-input '(:url "https://x"))))
    (should (equal '(:url "https://x") (macp-tool-call-raw-input tc)))))

;;;; Render-side fixes for review findings

;;;; Density refactor — collapsed = one-liner, expanded = card chrome

(defun macp-test--pp-tool-call-to-string (tc collapsed)
  "Render TC through `--pp-tool-call' in a temp buffer and return the string.
Collapsed via a fresh `macp-node' wrapping TC."
  (with-temp-buffer
    (mutecipher-acp--pp-tool-call
     (make-macp-node :kind 'tool-call :data tc :collapsed collapsed))
    (buffer-string)))

(ert-deftest macp-test-pp-tool-call-collapsed-emits-no-chrome ()
  "Collapsed render must NOT contain any card chrome — that was the entire
point of the density refactor."
  (let ((out (macp-test--pp-tool-call-to-string
              (make-macp-tool-call :name "Grep" :kind "search" :status 'done)
              t)))
    (should-not (string-match-p "╭" out))
    (should-not (string-match-p "╰" out))
    (should-not (string-match-p "│" out))))

(ert-deftest macp-test-pp-tool-call-collapsed-is-single-line ()
  "Collapsed render must emit exactly one newline — one card, one line."
  (let ((out (macp-test--pp-tool-call-to-string
              (make-macp-tool-call :name "Read" :kind "read" :status 'done
                                   :raw-output "a\nb\nc")
              t)))
    (should (= 1 (cl-count ?\n out)))))

(ert-deftest macp-test-pp-tool-call-expanded-emits-chrome ()
  "Expanded render keeps the `╭'/`╰' chrome and emits it AFTER the
summary line — chrome wraps the body only, summary stays at the
gutter row that collapsed cards use."
  (let* ((tc (make-macp-tool-call :name "Read" :kind "read" :status 'done
                                  :raw-output "alpha\nbeta\n"))
         (out (macp-test--pp-tool-call-to-string tc nil))
         (top (string-match "╭" out))
         (bot (string-match "╰" out))
         (newline-before-top (and top
                                  (string-match "\n" out)
                                  (< (string-match "\n" out) top))))
    (should top)
    (should bot)
    (should (< top bot))
    ;; The summary line must be emitted before the top rule — there is
    ;; at least one `\n' between the start of the buffer and `╭'.
    (should newline-before-top)))

(ert-deftest macp-test-pp-tool-call-density-13-collapsed ()
  "13 consecutive collapsed renders must fit in 13 newlines (no spacer
between cards).  Pre-refactor this would have been ~52."
  (with-temp-buffer
    (dotimes (i 13)
      (mutecipher-acp--pp-tool-call
       (make-macp-node :kind 'tool-call
                       :collapsed t
                       :data (make-macp-tool-call :name (format "Tool%d" i)
                                                   :kind "read"
                                                   :status 'done))))
    (should (= 13 (cl-count ?\n (buffer-string))))))

(ert-deftest macp-test-pp-tool-call-running-stays-collapsed-one-line ()
  "Running tools render as a one-line spinner row.  The spinner timer
re-invalidates the node 10×/sec; a multi-line layout would thrash."
  (let* ((mutecipher-acp--spinner-tick 0)
         (out (macp-test--pp-tool-call-to-string
               (make-macp-tool-call :name "Bash" :kind "execute"
                                    :status 'running)
               t)))
    (should (= 1 (cl-count ?\n out)))
    ;; First frame of the spinner.
    (should (string-match-p (regexp-quote (aref mutecipher-acp-spinner-frames 0))
                            out))))

(ert-deftest macp-test-pp-tool-call-toggle-roundtrip ()
  "Collapsing, expanding, and re-collapsing must return identical buffer
state — the toggle path (UI command) depends on this idempotence."
  (let* ((tc (make-macp-tool-call :name "Read" :kind "read" :status 'done
                                  :raw-output "x"))
         (a (macp-test--pp-tool-call-to-string tc t))
         (_ (macp-test--pp-tool-call-to-string tc nil))
         (c (macp-test--pp-tool-call-to-string tc t)))
    (should (string-equal a c))))

(ert-deftest macp-test-pp-tool-call-line-renders-kind-icon ()
  "The card summary line must include a kind glyph (when a Nerd-Font icon
is available).  Pre-fix, the new kind icons were defined but never inserted."
  (when (and (fboundp 'mutecipher/icon-for-acp)
             (mutecipher/icon-for-acp 'tool-edit))
    (let ((tc (make-macp-tool-call :name "Edit"
                                   :kind "edit"
                                   :status 'done
                                   :input "foo.el")))
      (with-temp-buffer
        (mutecipher-acp--pp-tool-call-line tc)
        (should (string-match-p
                 (regexp-quote (mutecipher/icon-for-acp 'tool-edit))
                 (buffer-string)))))))

(ert-deftest macp-test-pp-tool-call-line-no-disclosure-glyph ()
  "Disclosure (▸/▾) has been removed in favour of the status-as-gutter
layout; render must not contain either glyph regardless of collapsed state."
  (let ((tc (make-macp-tool-call :name "Read" :kind "read" :status 'done)))
    (dolist (collapsed '(t nil))
      (let ((out (macp-test--pp-tool-call-to-string tc collapsed)))
        (should-not (string-match-p "▸" out))
        (should-not (string-match-p "▾" out))))))

(ert-deftest macp-test-pp-tool-call-line-status-at-column-zero ()
  "The status glyph must sit at column 0, matching the gutter column of
user/assistant role glyphs — no leading whitespace."
  (let* ((tc (make-macp-tool-call :name "T" :kind "read" :status 'done))
         (out (macp-test--pp-tool-call-to-string tc t))
         (first-char (aref out 0)))
    ;; First char is not whitespace.
    (should-not (memq first-char '(?\s ?\t)))
    ;; First char IS the status glyph (or its ASCII fallback "✓").
    (should (or (= first-char ?✓)
                (string-prefix-p
                 (or (and (fboundp 'mutecipher/icon-for-acp)
                          (mutecipher/icon-for-acp 'status-done))
                     "✓")
                 out)))))

;;;; Blank-line padding around non-tool message bodies

(ert-deftest macp-test-pp-inserts-blank-before-non-tool-after-tool ()
  "Tool → assistant transition gets exactly one blank line of padding.
The master `--pp' dispatcher calls `--ensure-blank-above' for non-tool
kinds so a tight tool-call sequence still ends with one blank line
before the next prose body."
  (with-temp-buffer
    (mutecipher-acp--pp
     (make-macp-node :kind 'tool-call :collapsed t
                     :data (make-macp-tool-call :name "T" :status 'done)))
    (mutecipher-acp--pp
     (make-macp-node :kind 'assistant
                     :data (make-macp-assistant :text "hi")))
    ;; After the tool's trailing \n, --ensure-blank-above adds another \n
    ;; before the assistant content.  So buffer contains "...T...\n\n..hi.."
    (should (string-match-p "T[^\n]*\n\n" (buffer-string)))))

(ert-deftest macp-test-pp-tool-to-tool-stays-tight ()
  "Adjacent tool-calls don't get a blank line between them — `--pp' skips
`--ensure-blank-above' for tool-call kinds."
  (with-temp-buffer
    (mutecipher-acp--pp
     (make-macp-node :kind 'tool-call :collapsed t
                     :data (make-macp-tool-call :name "T1" :status 'done)))
    (mutecipher-acp--pp
     (make-macp-node :kind 'tool-call :collapsed t
                     :data (make-macp-tool-call :name "T2" :status 'done)))
    (should-not (string-match-p "T1[^\n]*\n\n" (buffer-string)))))

(ert-deftest macp-test-ensure-blank-above-idempotent ()
  "Calling `--ensure-blank-above' twice in a row inserts at most one \\n.
Guards the case where a node is invalidated and re-rendered."
  (with-temp-buffer
    (insert "prev-content\n")
    (mutecipher-acp--ensure-blank-above)
    (mutecipher-acp--ensure-blank-above)
    (should (= 2 (cl-count ?\n (buffer-string))))))

(ert-deftest macp-test-ensure-blank-above-noop-at-bob ()
  "`--ensure-blank-above' must not insert at buffer-start — the first
node in a fresh buffer doesn't get a leading empty line."
  (with-temp-buffer
    (mutecipher-acp--ensure-blank-above)
    (should (string-empty-p (buffer-string)))))

(ert-deftest macp-test-ensure-blank-above-treats-nbsp-line-as-blank ()
  "A line containing only no-break spaces (U+00A0) is visually blank;
the predicate must not insert a redundant `\\n' on top of it."
  (with-temp-buffer
    (insert "  \n")
    (mutecipher-acp--ensure-blank-above)
    (should (= 1 (cl-count ?\n (buffer-string))))))

;;;; Post-fix coverage: turn-header / plan no longer double-blank

(ert-deftest macp-test-pp-turn-header-no-leading-newline ()
  "`--pp-turn-header' must NOT emit its own leading `\\n' — that role
moved to the dispatcher's `--ensure-blank-above'.  Pre-fix, turn 2+
got TWO blank lines above (ensure-blank + the printer's own \\n)."
  (with-temp-buffer
    (mutecipher-acp--pp-turn-header
     (make-macp-node :kind 'turn-header
                     :data (make-macp-turn :id 2 :started-at (float-time))))
    ;; Empty body + no change-set → nothing inserted.
    (should (string-empty-p (buffer-string)))))

(ert-deftest macp-test-pp-plan-no-leading-newline ()
  "`--pp-plan' must NOT emit its own leading `\\n' — pre-fix this
combined with the dispatcher's `--ensure-blank-above' to produce TWO
blank lines above every `[Plan]' header."
  (with-temp-buffer
    (mutecipher-acp--pp-plan
     (make-macp-node :kind 'plan
                     :data (make-macp-plan :entries
                                            [(:title "X" :status "pending")])))
    (let ((s (buffer-string)))
      ;; First char must be `[' (the header), not a newline.
      (should (eq (aref s 0) ?\[)))))

;;;; Post-fix coverage: expanded tool-calls don't visually abut

(ert-deftest macp-test-pp-tool-call-expanded-emits-trailing-blank ()
  "Expanded tool-call cards must end with `\\n\\n' so two adjacent
expanded cards don't visually merge.  Collapsed cards stay at single
`\\n' for tight stacking."
  (let* ((tc (make-macp-tool-call :name "T" :kind "read" :status 'done
                                  :raw-output "x"))
         (expanded  (macp-test--pp-tool-call-to-string tc nil))
         (collapsed (macp-test--pp-tool-call-to-string tc t)))
    (should (string-suffix-p "\n\n" expanded))
    (should (string-suffix-p "\n" collapsed))
    (should-not (string-suffix-p "\n\n" collapsed))))

;;;; Post-fix coverage: status glyph fallback for nil/unknown status

(ert-deftest macp-test-tool-status-glyph-nil-falls-back-to-pending ()
  "A tool-call with nil status renders the dim pending circle, NOT a
literal `?' — the status glyph sits at column 0 (the gutter) and a
stray `?' would be the most prominent character on the row."
  (let* ((out (mutecipher-acp--tool-status-glyph nil))
         (pending (mutecipher-acp--icon-or 'status-pending "○")))
    (should (equal out pending))
    (should-not (equal out "?"))))

;;;; Post-fix coverage: summary line has wrap-prefix for soft-wrap

(ert-deftest macp-test-pp-tool-call-line-has-wrap-prefix ()
  "Long tool inputs wrap to column 2 (`wrap-prefix') instead of
column 0, so the continuation aligns under the body rather than under
the gutter status glyph."
  (with-temp-buffer
    (mutecipher-acp--pp-tool-call-line
     (make-macp-tool-call :name "Edit" :kind "edit" :status 'done
                          :input "very/long/path/to/some/file.el"))
    (let ((wp (get-text-property (point-min) 'wrap-prefix)))
      (should (equal wp "  ")))))

;;;; Post-fix coverage: --pulse-node skips the leading blank

(ert-deftest macp-test-pulse-node-skips-leading-blank ()
  "`--pulse-node' must skip past any leading `\\n' so the flash region
matches the visible node body, not the inter-node gap."
  (skip-unless (fboundp 'pulse-momentary-highlight-region))
  (with-temp-buffer
    (let ((ewoc (ewoc-create (lambda (_) nil) "" "" t))
          (calls nil))
      (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
                 (lambda (beg end &rest _) (push (list beg end) calls))))
        ;; Two nodes; the second has a leading blank in its region.
        (ewoc-enter-last ewoc (make-macp-node :kind 'user
                                              :data (make-macp-user :text "a")))
        (let ((second
               (ewoc-enter-last ewoc
                                (make-macp-node :kind 'user
                                                :data (make-macp-user :text "b")))))
          (mutecipher-acp--pulse-node ewoc second))
        (let* ((call (car calls))
               (beg  (nth 0 call)))
          ;; First char of the pulsed region must NOT be a newline.
          (should-not (eq (char-after beg) ?\n)))))))

(ert-deftest macp-test-todo-renderer-emits-attachments ()
  "TodoWrite renderer must also emit diffs attached to the same tool-call,
not silently drop them when falling through the structured-todos path."
  (let ((tc (make-macp-tool-call
             :name "TodoWrite"
             :raw-input '(:todos
                          [(:content "X" :status "pending")])
             :diffs '(("old text\n" . "new text\n")))))
    (with-temp-buffer
      (mutecipher-acp--render-todo-body tc)
      ;; Checklist content present.
      (should (string-match-p "X" (buffer-string)))
      ;; Diff content present (the diff renderer emits +/- lines).
      (should (string-match-p "new text" (buffer-string))))))

(ert-deftest macp-test-task-renderer-emits-attachments ()
  "Task renderer must also emit diffs the subagent produced."
  (let ((tc (make-macp-tool-call
             :name "Task"
             :raw-input '(:subagent_type "explore" :prompt "find foo")
             :diffs '(("alpha\n" . "beta\n")))))
    (with-temp-buffer
      (mutecipher-acp--render-task-body tc)
      (should (string-match-p "explore" (buffer-string)))
      (should (string-match-p "beta" (buffer-string))))))

(ert-deftest macp-test-task-renderer-falls-back-when-empty ()
  "Task renderer with no structured fields and no output must NOT leave an
empty body — fall through to the default renderer so plan/diffs still show."
  (let ((tc (make-macp-tool-call
             :name "Task"
             :raw-input nil
             :raw-output nil
             :diffs '(("a\n" . "b\n")))))
    (with-temp-buffer
      (mutecipher-acp--render-task-body tc)
      (should (string-match-p "b" (buffer-string))))))

(ert-deftest macp-test-todo-renderer-handles-non-vector-todos ()
  "`:todos' arriving as a list (or `:json-false', a number, …) must not crash;
list todos render normally, non-sequence values fall back."
  ;; List form.
  (let ((tc (make-macp-tool-call
             :raw-input '(:todos ((:content "L1" :status "pending")
                                  (:content "L2" :status "completed"))))))
    (with-temp-buffer
      (mutecipher-acp--render-todo-body tc)
      (should (string-match-p "L1" (buffer-string)))
      (should (string-match-p "L2" (buffer-string)))))
  ;; `:json-false' — must fall back, not signal.
  (let ((tc (make-macp-tool-call :raw-input '(:todos :json-false))))
    (with-temp-buffer
      ;; Empty buffer is fine — the goal is no signal.
      (mutecipher-acp--render-todo-body tc)
      (should t))))

(ert-deftest macp-test-synthesize-locations-single-plist ()
  "A `:locations' arriving as a single plist must wrap into a 1-vector
rather than being apply-vectored into a broken `[:key val :key val]'."
  (let* ((update '(:locations (:path "/tmp/x" :line 42)))
         (locs   (mutecipher-acp--synthesize-locations update)))
    (should (vectorp locs))
    (should (= 1 (length locs)))
    ;; Downstream code does (plist-get (aref locs 0) :path); that must work.
    (should (equal "/tmp/x" (plist-get (aref locs 0) :path)))))

(ert-deftest macp-test-synthesize-locations-list-of-plists-still-works ()
  "A `:locations' arriving as a list of location plists must vectorize
each element separately, not be misread as a single plist."
  (let* ((update '(:locations ((:path "/a") (:path "/b"))))
         (locs   (mutecipher-acp--synthesize-locations update)))
    (should (= 2 (length locs)))
    (should (equal "/a" (plist-get (aref locs 0) :path)))
    (should (equal "/b" (plist-get (aref locs 1) :path)))))

(ert-deftest macp-test-probe-kind-notebook-editcell ()
  "`NotebookEditCell' must route to tool-edit, not tool-read."
  (should (eq 'tool-edit (mutecipher-acp--probe-kind-from-name "NotebookEditCell")))
  (should (eq 'tool-edit (mutecipher-acp--probe-kind-from-name "NotebookEdit")))
  (should (eq 'tool-read (mutecipher-acp--probe-kind-from-name "NotebookRead"))))

(ert-deftest macp-test-render-fetch-body-query-not-link-face ()
  "WebSearch `:query' should NOT carry the `link' face; URL should."
  (with-temp-buffer
    (mutecipher-acp--render-fetch-body
     (make-macp-tool-call :name "WebSearch" :raw-input '(:query "claude code")))
    (goto-char (point-min))
    (search-forward "claude code")
    (let ((face (get-text-property (1- (point)) 'face)))
      (should-not (eq face 'link))
      (should-not (and (listp face) (memq 'link face)))))
  (with-temp-buffer
    (mutecipher-acp--render-fetch-body
     (make-macp-tool-call :name "WebFetch"
                          :raw-input '(:url "https://example.test/x")))
    (goto-char (point-min))
    (search-forward "https://example.test/x")
    (let ((face (get-text-property (1- (point)) 'face)))
      (should (or (eq face 'link)
                  (and (listp face) (memq 'link face)))))))

(ert-deftest macp-test-update-preserves-original-raw-input ()
  "tool_call_update with a stripped `:rawInput' must not destroy the
structured payload the original tool_call carried."
  (let* ((session-id "test-sess")
         (buf (generate-new-buffer " *macp-update-test*"))
         (session (mutecipher-acp--make-session
                   :id session-id
                   :buffer buf
                   :tool-call-index (make-hash-table :test #'equal))))
    (unwind-protect
        (progn
          (puthash session-id session mutecipher-acp--sessions)
          ;; Plant a tool-call with the full rawInput.
          (let* ((tc (make-macp-tool-call
                      :call-id "c1" :name "TodoWrite" :status 'pending
                      :raw-input '(:todos [(:content "X" :status "pending")])))
                 (node-data (make-macp-node :kind 'tool-call :data tc)))
            ;; Wrap node-data in a fake ewoc node by using ewoc-data
            ;; via a real ewoc.  Simpler: stub the index directly with
            ;; a cons that satisfies ewoc-data through our access path
            ;; — but `--update-tool-call' calls `ewoc-data', so use a
            ;; real ewoc.
            (with-current-buffer buf
              (setq mutecipher-acp--session-id session-id)
              (setq mutecipher-acp--ewoc
                    (ewoc-create (lambda (_) nil) "" ""))
              (let ((node (ewoc-enter-last mutecipher-acp--ewoc node-data)))
                (puthash "c1" node (macp-session-tool-call-index session))))
            ;; Apply an update with a stripped rawInput.
            (mutecipher-acp--update-tool-call
             session-id
             (list :toolCallId "c1"
                   :status "completed"
                   :rawInput '(:status "completed")))
            ;; Original rawInput must survive — body renderer would
            ;; otherwise lose `:todos'.
            (should (equal '(:todos [(:content "X" :status "pending")])
                           (macp-tool-call-raw-input tc)))))
      (remhash session-id mutecipher-acp--sessions)
      (when (buffer-live-p buf)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf))))))

;;;; Tool-group: classification

(ert-deftest macp-test-read-only-p-kind-based ()
  (should (mutecipher-acp--tool-call-read-only-p
           (make-macp-tool-call :name "Read"    :kind "read")))
  (should (mutecipher-acp--tool-call-read-only-p
           (make-macp-tool-call :name "Grep"    :kind "search")))
  (should (mutecipher-acp--tool-call-read-only-p
           (make-macp-tool-call :name "WebFetch" :kind "fetch")))
  (should-not (mutecipher-acp--tool-call-read-only-p
               (make-macp-tool-call :name "Edit"  :kind "edit")))
  (should-not (mutecipher-acp--tool-call-read-only-p
               (make-macp-tool-call :name "Write" :kind "write")))
  (should-not (mutecipher-acp--tool-call-read-only-p
               (make-macp-tool-call :name "Bash"  :kind "execute"))))

(ert-deftest macp-test-read-only-p-name-fallback ()
  "Tools that ship `kind \"other\"` fall through to the name probe —
Glob / WebSearch / WebFetch must still count as read-only."
  (should (mutecipher-acp--tool-call-read-only-p
           (make-macp-tool-call :name "Glob"      :kind "other")))
  (should (mutecipher-acp--tool-call-read-only-p
           (make-macp-tool-call :name "WebSearch" :kind nil)))
  (should (mutecipher-acp--tool-call-read-only-p
           (make-macp-tool-call :name "WebFetch"  :kind "other")))
  (should-not (mutecipher-acp--tool-call-read-only-p
               (make-macp-tool-call :name "TodoWrite" :kind "other")))
  (should-not (mutecipher-acp--tool-call-read-only-p
               (make-macp-tool-call :name "Task"      :kind "other"))))

;;;; Tool-group: summary line

(ert-deftest macp-test-tool-group-summary-files-and-searches ()
  (let ((children
         (list (make-macp-tool-call :name "Read" :kind "read")
               (make-macp-tool-call :name "Read" :kind "read")
               (make-macp-tool-call :name "Grep" :kind "search"))))
    (should (equal "Explored 2 files, 1 search"
                   (mutecipher-acp--tool-group-summary children)))))

(ert-deftest macp-test-tool-group-summary-pluralization ()
  (should (equal "Explored 1 file"
                 (mutecipher-acp--tool-group-summary
                  (list (make-macp-tool-call :name "Read" :kind "read")))))
  (should (equal "Explored 6 files"
                 (mutecipher-acp--tool-group-summary
                  (cl-loop repeat 6 collect
                           (make-macp-tool-call :name "Read" :kind "read")))))
  (should (equal "Explored 1 search"
                 (mutecipher-acp--tool-group-summary
                  (list (make-macp-tool-call :name "Grep" :kind "search")))))
  (should (equal "Explored 3 searches"
                 (mutecipher-acp--tool-group-summary
                  (cl-loop repeat 3 collect
                           (make-macp-tool-call :name "Grep" :kind "search"))))))

(ert-deftest macp-test-tool-group-summary-fetches-count-as-searches ()
  "WebFetch + WebSearch share the `tool-fetch' icon-key — both should
land in the `searches' bucket, matching Cursor's screenshot wording
where queries and URL fetches collapse into the same count."
  (let ((children
         (list (make-macp-tool-call :name "WebFetch"  :kind "fetch")
               (make-macp-tool-call :name "WebSearch" :kind "fetch"))))
    (should (equal "Explored 2 searches"
                   (mutecipher-acp--tool-group-summary children)))))

;;;; Tool-group: fold logic

(defmacro macp-test--with-group-session (var-session &rest body)
  "Spin up an ACP session ready for tool-group integration tests.
VAR-SESSION is bound to the `macp-session' struct; the session
buffer + ewoc are set up so `--enter-tool-call' inserts real nodes.
Stubs persistence so .eld files don't leak into the user cache."
  (declare (indent 1) (debug ((symbolp) body)))
  `(let* ((buf (generate-new-buffer " *macp-group-test*"))
          (sid (format "test-group-sid-%s" (random)))
          (,var-session (mutecipher-acp--make-session
                          :id sid :buffer buf :agent "claude"
                          :cwd "/tmp"
                          :tool-call-index (make-hash-table :test #'equal))))
     (puthash sid ,var-session mutecipher-acp--sessions)
     (cl-letf (((symbol-function 'mutecipher-acp--save-session) #'ignore)
               ((symbol-function 'mutecipher-acp--save-index)   #'ignore))
       (unwind-protect
           (with-current-buffer buf
             (mutecipher-acp-session-mode)
             (setq mutecipher-acp--session-id sid)
             ,@body)
         (let ((kill-buffer-hook nil))
           (when (buffer-live-p buf) (kill-buffer buf)))
         (remhash sid mutecipher-acp--sessions)))))

(defun macp-test--node-kinds (session)
  "Return the ordered list of kind symbols for SESSION's transcript nodes.
Skips queued nodes so the predicate matches what `--enter-tool-call'
actually planted in this turn."
  (with-current-buffer (macp-session-buffer session)
    (mapcar #'macp-node-kind
            (ewoc-collect mutecipher-acp--ewoc
                          (lambda (d)
                            (not (eq (macp-node-kind d) 'queued)))))))

(defun macp-test--enter-tool (session-id id kind name)
  "Helper: drive `--enter-tool-call' with a synthesized tool_call UPDATE."
  (mutecipher-acp--enter-tool-call
   session-id
   (list :toolCallId id :kind kind :title name
         :_meta (list :claudeCode (list :toolName name))
         :rawInput (list :file_path (format "/tmp/%s" id)))))

(ert-deftest macp-test-tool-group-folds-three-adjacent-reads ()
  "Three consecutive read tool_calls should land inside a single
`tool-group' node with all three as children."
  (let ((mutecipher-acp-group-read-only-tool-calls t))
    (macp-test--with-group-session s
      (let ((sid (macp-session-id s)))
        (macp-test--enter-tool sid "r1" "read" "Read")
        (macp-test--enter-tool sid "r2" "read" "Read")
        (macp-test--enter-tool sid "r3" "read" "Read"))
      (should (equal '(tool-group) (macp-test--node-kinds s)))
      (let* ((nodes (with-current-buffer (macp-session-buffer s)
                      (ewoc-collect mutecipher-acp--ewoc #'identity)))
             (group (macp-node-data (car nodes))))
        (should (= 3 (length (macp-tool-group-children group))))
        (should (equal '("r1" "r2" "r3")
                       (mapcar #'macp-tool-call-call-id
                               (macp-tool-group-children group))))))))

(ert-deftest macp-test-tool-group-non-read-closes-group ()
  "Read → write → read produces group(1), tool-call, group(1).
The write closes the leading group; the trailing read opens a fresh one.
The first group's `closed' flag must flip to t — that's the signal a
later read won't re-fold into it."
  (let ((mutecipher-acp-group-read-only-tool-calls t))
    (macp-test--with-group-session s
      (let ((sid (macp-session-id s)))
        (macp-test--enter-tool sid "r1" "read"  "Read")
        (macp-test--enter-tool sid "w1" "write" "Write")
        (macp-test--enter-tool sid "r2" "read"  "Read"))
      (let ((nodes (with-current-buffer (macp-session-buffer s)
                     (ewoc-collect mutecipher-acp--ewoc #'identity))))
        (should (equal '(tool-group tool-call tool-group)
                       (mapcar #'macp-node-kind nodes)))
        ;; First group is closed; second is still open and tracked by
        ;; `current-tool-group' so a subsequent read would fold in.
        (should     (macp-tool-group-closed (macp-node-data (nth 0 nodes))))
        (should-not (macp-tool-group-closed (macp-node-data (nth 2 nodes))))
        (should (eq (nth 2 nodes)
                    (ewoc-data (macp-session-current-tool-group s))))))))

(ert-deftest macp-test-tool-group-defcustom-off-restores-legacy ()
  "With `mutecipher-acp-group-read-only-tool-calls' nil, reads insert
as stand-alone `tool-call' nodes — no group wrapping."
  (let ((mutecipher-acp-group-read-only-tool-calls nil))
    (macp-test--with-group-session s
      (let ((sid (macp-session-id s)))
        (macp-test--enter-tool sid "r1" "read" "Read")
        (macp-test--enter-tool sid "r2" "read" "Read"))
      (should (equal '(tool-call tool-call) (macp-test--node-kinds s))))))

(ert-deftest macp-test-tool-group-update-routes-into-children ()
  "tool_call_update for a grouped child must mutate that child's status
without losing the group node or its other children."
  (let ((mutecipher-acp-group-read-only-tool-calls t))
    (macp-test--with-group-session s
      (let ((sid (macp-session-id s)))
        (macp-test--enter-tool sid "r1" "read" "Read")
        (macp-test--enter-tool sid "r2" "read" "Read")
        (mutecipher-acp--update-tool-call
         sid (list :toolCallId "r2" :status "completed")))
      (let* ((nodes (with-current-buffer (macp-session-buffer s)
                      (ewoc-collect mutecipher-acp--ewoc #'identity)))
             (group (macp-node-data (car nodes)))
             (children (macp-tool-group-children group)))
        (should (= 2 (length children)))
        (should (eq 'pending (macp-tool-call-status (nth 0 children))))
        (should (eq 'done    (macp-tool-call-status (nth 1 children))))))))

(ert-deftest macp-test-tool-group-update-leaves-group-collapsed-flag-alone ()
  "Auto-collapse and pulse are per-card signals — they target a
stand-alone tool-call wrapper.  For a grouped child whose wrapper is
the GROUP node, flipping its `collapsed' flag on every child
completion would yank the user's view of still-running siblings.
The group's collapsed state must be user-driven."
  (let ((mutecipher-acp-group-read-only-tool-calls t))
    (macp-test--with-group-session s
      (let ((sid (macp-session-id s)))
        (macp-test--enter-tool sid "r1" "read" "Read")
        (macp-test--enter-tool sid "r2" "read" "Read")
        ;; User expands the group manually.
        (let ((wrapper (car (with-current-buffer (macp-session-buffer s)
                              (ewoc-collect mutecipher-acp--ewoc #'identity)))))
          (setf (macp-node-collapsed wrapper) nil))
        ;; First child reaches done — must NOT re-collapse the group
        ;; while r2 is still pending.
        (mutecipher-acp--update-tool-call
         sid (list :toolCallId "r1" :status "completed"))
        (let ((wrapper (car (with-current-buffer (macp-session-buffer s)
                              (ewoc-collect mutecipher-acp--ewoc #'identity)))))
          (should (eq 'tool-group (macp-node-kind wrapper)))
          (should-not (macp-node-collapsed wrapper)))))))

(ert-deftest macp-test-hydrate-restores-current-tool-group ()
  "An open trailing tool-group on disk (`closed' nil) should
re-populate `current-tool-group' on hydrate so a live read folds in
instead of opening a fresh card next to the persisted one.  A
previously-closed group earlier in the transcript must not be
restored."
  (let* ((buf (generate-new-buffer " *macp-hydrate-test*"))
         (sid (format "test-hydrate-sid-%s" (random)))
         (session (mutecipher-acp--make-session
                   :id sid :buffer buf :agent "claude" :cwd "/tmp"
                   :tool-call-index (make-hash-table :test #'equal)))
         (closed-group (make-macp-tool-group
                        :children (list (make-macp-tool-call
                                         :call-id "old" :name "Read"
                                         :kind "read" :status 'done))
                        :closed t))
         (open-group   (make-macp-tool-group
                        :children (list (make-macp-tool-call
                                         :call-id "live" :name "Read"
                                         :kind "read" :status 'done))
                        :closed nil))
         (nodes (list (make-macp-node :kind 'tool-group :data closed-group
                                      :collapsed t :uuid "n_a")
                      (make-macp-node :kind 'tool-group :data open-group
                                      :collapsed t :uuid "n_b")))
         (sexp (list :schema-version mutecipher-acp--persist-schema-version
                     :session nil
                     :nodes   nodes)))
    (unwind-protect
        (progn
          (puthash sid session mutecipher-acp--sessions)
          (with-current-buffer buf
            (mutecipher-acp-session-mode)
            (setq mutecipher-acp--session-id sid))
          (cl-letf (((symbol-function 'mutecipher-acp--persist-read-sexp)
                     (lambda (_path) sexp))
                    ((symbol-function 'mutecipher-acp--session-file)
                     (lambda (_id) "/tmp/stub.eld"))
                    ((symbol-function 'mutecipher-acp--save-session) #'ignore)
                    ((symbol-function 'mutecipher-acp--save-index)   #'ignore))
            (mutecipher-acp--hydrate-session-from-disk session))
          ;; Trailing open group must be restored, not the closed one.
          (should (macp-session-current-tool-group session))
          (let ((slot-node (macp-session-current-tool-group session)))
            (should (eq 'tool-group
                        (macp-node-kind (ewoc-data slot-node))))
            (should-not
             (macp-tool-group-closed
              (macp-node-data (ewoc-data slot-node))))))
      (remhash sid mutecipher-acp--sessions)
      (when (buffer-live-p buf)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf))))))

(ert-deftest macp-test-tool-group-status-aggregates ()
  "Aggregate status: pending if any pending and none running, running
if any running, error if every terminal and any failed, else done."
  (cl-flet ((mk (status)
              (make-macp-tool-call :name "Read" :kind "read" :status status)))
    (should (eq 'running (mutecipher-acp--tool-group-status
                          (list (mk 'running) (mk 'done)))))
    (should (eq 'pending (mutecipher-acp--tool-group-status
                          (list (mk 'pending) (mk 'done)))))
    (should (eq 'error   (mutecipher-acp--tool-group-status
                          (list (mk 'done) (mk 'error)))))
    (should (eq 'done    (mutecipher-acp--tool-group-status
                          (list (mk 'done) (mk 'done)))))))

(ert-deftest macp-test-tool-group-strip-transient-cleans-children ()
  "Persistence's `--strip-transient-from-node' must scrub cached
memoization slots inside grouped children (not just top-level tcs)."
  (let* ((tc (make-macp-tool-call :call-id "r1" :name "Read" :kind "read"
                                  :cached-start-line 99
                                  :cached-start-key '(0 . [])))
         (group (make-macp-tool-group :children (list tc)))
         (node (make-macp-node :kind 'tool-group :data group
                               :collapsed t :uuid "n_test"))
         (clean (mutecipher-acp--strip-transient-from-node node))
         (clean-tc (car (macp-tool-group-children (macp-node-data clean)))))
    (should (null (macp-tool-call-cached-start-line clean-tc)))
    (should (null (macp-tool-call-cached-start-key  clean-tc)))
    ;; Original struct stays unmutated — strip returns a copy.
    (should (eql 99 (macp-tool-call-cached-start-line tc)))))

(provide 'mutecipher-acp-tests)
;;; mutecipher-acp-tests.el ends here
