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
                (lambda (&rest _) nil)))
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

(provide 'mutecipher-acp-tests)
;;; mutecipher-acp-tests.el ends here
