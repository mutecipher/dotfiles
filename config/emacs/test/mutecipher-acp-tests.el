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
  (should (= 3 (mutecipher-acp--tool-output-line-count "a\nb\nc"))))

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

(ert-deftest macp-test-auto-collapse-pending ()
  (let ((tc (make-macp-tool-call :status 'pending
                                 :raw-output (make-string 1000 ?a))))
    (should-not (mutecipher-acp--should-auto-collapse-p tc))))

(ert-deftest macp-test-auto-collapse-running ()
  (let ((tc (make-macp-tool-call :status 'running
                                 :raw-output "a\nb\nc\nd\n")))
    (should-not (mutecipher-acp--should-auto-collapse-p tc))))

(ert-deftest macp-test-auto-collapse-short-output ()
  (let ((tc (make-macp-tool-call :status 'done :raw-output "one line")))
    (should-not (mutecipher-acp--should-auto-collapse-p tc))))

(ert-deftest macp-test-auto-collapse-long-output ()
  (let ((tc (make-macp-tool-call :status 'done :raw-output "a\nb\nc\nd\ne")))
    (should (mutecipher-acp--should-auto-collapse-p tc))))

(ert-deftest macp-test-auto-collapse-with-diff ()
  (let ((tc (make-macp-tool-call :status 'done :raw-output ""
                                 :diffs '(("old" . "new")))))
    (should (mutecipher-acp--should-auto-collapse-p tc))))

(ert-deftest macp-test-auto-collapse-plan-body-opts-out ()
  (let ((tc (make-macp-tool-call :status 'done
                                 :raw-output "a\nb\nc\nd\ne"
                                 :plan-body "Markdown plan body")))
    (should-not (mutecipher-acp--should-auto-collapse-p tc))))

(ert-deftest macp-test-auto-collapse-error-with-diff ()
  (let ((tc (make-macp-tool-call :status 'error :raw-output ""
                                 :diffs '(("a" . "b")))))
    (should (mutecipher-acp--should-auto-collapse-p tc))))

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
    (cl-letf (((symbol-function 'mutecipher-acp--force-input-mode-line)
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

(provide 'mutecipher-acp-tests)
;;; mutecipher-acp-tests.el ends here
