;;; ghostel-compile-test.el --- Tests for ghostel: compile -*- lexical-binding: t; -*-

;;; Commentary:

;; ghostel-compile: finalize, recompile, global/toggle mode, interactive form,
;; mode-line, jump-to-error, advice plumbing.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-compile-finalize-scans-errors ()
  "`ghostel-compile--finalize' parses errors in the scan region."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "pre-existing line\n")
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point)))
      (insert "/tmp/foo.c:10:5: error: bad thing\n")
      (insert "done\n"))
    (ghostel-compile--finalize buf 1 (current-time))
    (should (eq 1 ghostel-compile--last-exit))                ; exit recorded
    ;; The error line acquired `compilation-message' somewhere within it,
    ;; while the pre-existing (pre-scan-marker) line did not.
    (cl-flet ((region-has-prop-p (begin end prop)
                (save-excursion
                  (goto-char begin)
                  (let ((found nil))
                    (while (and (not found) (< (point) end))
                      (if (get-text-property (point) prop)
                          (setq found t)
                        (goto-char
                         (or (next-single-property-change
                              (point) prop nil end)
                             end))))
                    found))))
      (save-excursion
        (goto-char (point-min))
        (let ((err-bol (progn (search-forward "/tmp/foo.c") (line-beginning-position)))
              (err-eol (line-end-position)))
          (should (region-has-prop-p err-bol err-eol 'compilation-message))))
      (save-excursion
        (goto-char (point-min))
        (let ((pre-bol (progn (search-forward "pre-existing line")
                              (line-beginning-position)))
              (pre-eol (line-end-position)))
          (should-not (region-has-prop-p pre-bol pre-eol 'compilation-message)))))
    (should (eq buf next-error-last-buffer))))                ; next-error target set

(ert-deftest ghostel-test-compile-finalize-appends-footer ()
  "Finalize appends the plain-text footer matching `M-x compile' format.
The header is pre-rendered into the VT terminal by `--start' before
the process spawns, so finalize only has to append the footer and
parse errors below the scan marker.  This unit test simulates that
pre-rendered state by inserting the header directly into the buffer."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil))
      (insert "-*- mode: ghostel-compile -*-\n"
              "Compilation started at fake-time\n\n"
              "make -j4 test\n")
      (setq ghostel-compile--command "make -j4 test"
            ghostel-compile--start-time (time-subtract (current-time) 2)
            ghostel-compile--scan-marker (copy-marker (point)))
      (insert "output line\n")
      (ghostel-compile--finalize buf 0 (current-time))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; Pre-rendered header is still there, exactly once.
        (should (= 1 (cl-count-if (lambda (line)
                                    (string-match-p "-\\*- mode:" line))
                                  (split-string text "\n"))))
        (should (string-match-p "make -j4 test" text))
        (should (string-match-p "output line" text))
        ;; Footer was appended by finalize.
        (should (string-match-p "Compilation finished at" text))
        (should (string-match-p "duration " text))))))

(ert-deftest ghostel-test-compile-finalize-footer-on-failure ()
  "Non-zero exit produces an \"exited abnormally\" footer in buffer text."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil))
      (insert "boom\n")
      (setq ghostel-compile--command "false"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-min)))
      (ghostel-compile--finalize buf 2 (current-time))
      (should (string-match-p
               "exited abnormally with code 2"
               (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest ghostel-test-compile-finalize-trims-trailing-blank-rows ()
  "Regression: short commands leave a mostly-empty terminal grid.
The ghostel renderer commits ~24 grid rows regardless of how much
output the command produced, so `echo test' would otherwise end up
with the footer ~20 rows below the real output.  Finalize must
trim those trailing blank rows — ending the run with a single
blank separator line before the footer matches `M-x compile'."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil))
      (setq ghostel-compile--command "echo test"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max)))
      ;; Simulate what the grid commits: short output plus ~20
      ;; whitespace-only rows from unused terminal lines.
      (insert "test\n")
      (dotimes (_ 20) (insert "                                     \n"))
      (ghostel-compile--finalize buf 0 (current-time))
      ;; Between the real output line "test" and "Compilation
      ;; finished" there must be at most one blank line (i.e. at most
      ;; two newlines) — not the ~20 trailing grid rows we seeded.
      (goto-char (point-min))
      (re-search-forward "^test$")                              ; real output
      (let ((after-test (point)))
        (re-search-forward "Compilation finished at")
        (goto-char (match-beginning 0))
        (let ((gap (buffer-substring-no-properties after-test (point))))
          (should (<= (cl-count ?\n gap) 2)))))))

(ert-deftest ghostel-test-compile-finalize-colors-errors ()
  "After finalize, error lines carry `compilation-line-number' / error faces."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max)))
      (insert "/tmp/x.c:42:5: error: bad\n"))
    (ghostel-compile--finalize buf 1 (current-time))
    ;; Force font-lock to apply faces.  Older compile.el (Emacs
    ;; 28.x) relies on font-lock keywords to set
    ;; `compilation-line-number' / `compilation-error' faces, so
    ;; in batch mode (no `font-lock-mode' active) the digits stay
    ;; bare unless we explicitly fontify.  Modern compile.el
    ;; (Emacs 30+) puts the properties directly via
    ;; `compilation--put-prop' and doesn't need this — but
    ;; calling `font-lock-ensure' is harmless there.
    (font-lock-ensure (point-min) (point-max))
    ;; The file-name region should carry either a `compilation-message'
    ;; text property or `compilation-error' face via font-lock-face.
    ;; Scan the whole `/tmp/x.c' match instead of pinning a point,
    ;; since compile.el's exact boundaries differ across Emacs versions.
    (goto-char (point-min))
    (re-search-forward "\\(/tmp/x\\.c\\):")
    (let ((file-start (match-beginning 1))
          (file-end (match-end 1))
          (ok nil))
      (save-excursion
        (goto-char file-start)
        (while (and (not ok) (< (point) file-end))
          (when (or (get-text-property (point) 'compilation-message)
                    (memq 'compilation-error
                          (ensure-list (get-text-property
                                        (point) 'font-lock-face))))
            (setq ok t))
          (forward-char 1)))
      (should ok))
    ;; Find the `42' (line-number) digits and check any position in
    ;; that range carries `compilation-line-number' via font-lock-face.
    ;; The exact boundary compile.el uses for line-number face has
    ;; wobbled across Emacs versions (29.x vs master), so scan the
    ;; region instead of pinning a single position.
    (goto-char (point-min))
    (re-search-forward ":\\(42\\):")
    (let ((ln-start (match-beginning 1))
          (ln-end (match-end 1))
          (found nil))
      (save-excursion
        (goto-char ln-start)
        (while (and (not found) (< (point) ln-end))
          (let ((face (ensure-list (get-text-property (point) 'font-lock-face))))
            (when (memq 'compilation-line-number face)
              (setq found t)))
          (forward-char 1)))
      (should found))))

(ert-deftest ghostel-test-compile-finalize-preserves-face-props ()
  "Baked-in per-cell `face' text-properties must survive the mode transition.
The transition is from the live ghostel run into `ghostel-compile-view-mode'.
`compilation-mode' installs font-lock keywords for error highlighting,
and the default `font-lock-unfontify-region-function' strips every
`face' property — wiping the colour of the recorded output on the first
JIT-lock pass.  `ghostel-compile-view-mode' installs a buffer-local
`#'ignore' override to preserve those props."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max)))
      (insert (propertize "RED" 'face '(:foreground "#ff0000")))
      (insert " output\n/tmp/x.c:42:5: error: bad\n"))
    (ghostel-compile--finalize buf 1 (current-time))
    (font-lock-ensure (point-min) (point-max))
    ;; The ghostel-painted face on "RED" must still be present.
    (goto-char (point-min))
    (re-search-forward "RED")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should face)
      (should (equal "#ff0000" (plist-get face :foreground))))))

(ert-deftest ghostel-test-compile-finalize-does-not-double-count-errors ()
  "Regression: parsing must not count each error twice.

Using `compilation-parse-errors' directly does not advance
`compilation--parsed', so jit-lock would re-scan and double the
error count.  `compilation--ensure-parse' is the right entry point."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "/tmp/a.c:1:1: error: oops\n"
              "/tmp/b.c:2:2: error: oops\n")
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-min))))
    (ghostel-compile--finalize buf 1 (current-time))
    (should (= 2 compilation-num-errors-found))))             ; not 4

(ert-deftest ghostel-test-compile-finalize-does-not-kill-buffer ()
  "Regression: finalize must not let `ghostel--sentinel' kill the buffer.

Previously, teardown called `delete-process' with the ghostel sentinel
still attached; the sentinel would then invoke `kill-buffer' because
`ghostel-kill-buffer-on-exit' defaults to t.  The visible symptom is a
compile buffer that flashes open and disappears."
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf (generate-new-buffer " *ghostel-test-compile-live*"))
         (inhibit-message t)
         proc)
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq proc (start-process "gh-compile-dummy" buf
                                    "/bin/sh" "-c" "sleep 5"))
          (set-process-query-on-exit-flag proc nil)
          (set-process-sentinel proc #'ghostel--sentinel)
          (setq-local ghostel--process proc
                      ghostel-compile--command "sleep 5"
                      ghostel-compile--start-time (current-time)
                      ghostel-compile--scan-marker (copy-marker (point-max)))
          ;; Finalize with a real process attached: must NOT kill the
          ;; buffer AND must NOT insert the default sentinel's
          ;; "Process NAME killed: N" line into it.
          (ghostel-compile--finalize buf 0 (current-time))
          (should (buffer-live-p buf))                         ; buffer survived
          (should-not (process-live-p proc))                   ; process was stopped
          (should-not (string-match-p
                       "Process .*killed"
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))            ; no noise text
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-compile-view-mode-n-p-navigate-without-opening ()
  "`n'/`p' walk errors in the buffer without opening source files.
The user wants `n'/`p' to behave like `M-n'/`M-p' in `compilation-mode' —
move point through compile messages without auto-opening files in
another window.  RET/`compile-goto-error' is for opening."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      ;; Simulate the pre-rendered header, then errors below it —
      ;; matches the geometry the real flow leaves for `--finalize'.
      (insert "-*- mode: ghostel-compile -*-\n"
              "Compilation started at fake-time\n\n"
              "make\n")
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point)))
      (insert "/tmp/aa.c:1:1: error: first\n"
              "blah\n"
              "/tmp/bb.c:2:2: error: second\n"))
    (ghostel-compile--finalize buf 1 (current-time))
    ;; n/p should map to the navigation-only commands (no file open).
    (should (eq (lookup-key (current-local-map) "n")
                #'compilation-next-error))
    (should (eq (lookup-key (current-local-map) "p")
                #'compilation-previous-error))
    ;; Walking n twice must visit BOTH error lines, never opening files.
    (let ((opened nil))
      (cl-letf (((symbol-function 'compilation-find-file)
                 (lambda (&rest _) (setq opened t)
                   (current-buffer))))
        (goto-char (point-min))
        (compilation-next-error 1)
        (let ((p1 (point)))
          (should (save-excursion
                    (beginning-of-line)
                    (looking-at "/tmp/aa\\.c")))
          (compilation-next-error 1)
          (should (/= p1 (point)))                            ; point moved
          (should (save-excursion
                    (beginning-of-line)
                    (looking-at "/tmp/bb\\.c"))))
        (should-not opened)))))                              ; no file opened

(ert-deftest ghostel-test-compile-finalize-leaves-point-at-end ()
  "Regression: finalize must put point at `point-max', past the footer.
The \"Compilation finished at ..., duration ...\" line must be visible
when the window recenters to the bottom.  Point at the start of the
footer (or at the end of output before the footer) leaves the footer
scrolled below the window."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "line A\nline B\nline C\n")
      (goto-char (point-max))
      (setq ghostel-compile--command "true"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-min))))
    (ghostel-compile--finalize buf 0 (current-time))
    (should (= (point) (point-max)))                           ; past footer
    ;; And the footer text really is the last thing in the buffer.
    (should (string-match-p
             "Compilation finished at.*duration"
             (buffer-substring-no-properties
              (max (point-min) (- (point-max) 200))
              (point-max))))))

(ert-deftest ghostel-test-compile-finalize-switches-major-mode ()
  "With the default option, finalize switches to `ghostel-compile-view-mode'."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-compile--command "true"
          ghostel-compile--start-time (current-time)
          ghostel-compile--scan-marker (copy-marker (point-max)))
    (should (derived-mode-p 'ghostel-mode))                    ; starts as ghostel
    (ghostel-compile--finalize buf 0 (current-time))
    (should (derived-mode-p 'ghostel-compile-view-mode))        ; switched
    (should (derived-mode-p 'compilation-mode))                 ; inherits compile
    (should-not (derived-mode-p 'ghostel-mode))                 ; not ghostel anymore
    (should buffer-read-only)                                   ; read-only
    (should (eq next-error-function #'compilation-next-error-function))
    (should (equal "true" ghostel-compile--command))))          ; state preserved

(ert-deftest ghostel-test-compile-view-mode-recompile-key-binding ()
  "`g' in `ghostel-compile-view-mode-map' is bound to `ghostel-recompile'."
  (should (eq (lookup-key ghostel-compile-view-mode-map (kbd "g"))
              #'ghostel-recompile)))

(ert-deftest ghostel-test-compile-format-duration ()
  "Duration formatting matches `M-x compile's style."
  (should (equal "0.50 s"  (ghostel-compile--format-duration 0.5)))
  (should (equal "5.00 s"  (ghostel-compile--format-duration 5)))
  (should (equal "30.0 s"  (ghostel-compile--format-duration 30)))
  (should (equal "0:02:05" (ghostel-compile--format-duration 125)))
  (should (equal "1:01:05" (ghostel-compile--format-duration 3665))))

(ert-deftest ghostel-test-compile-status-message ()
  "Status message strings match `M-x compile' conventions."
  (should (equal "finished\n" (ghostel-compile--status-message 0)))
  (should (equal "exited abnormally with code 2\n"
                 (ghostel-compile--status-message 2)))
  (should (equal "finished\n" (ghostel-compile--status-message nil))))

(ert-deftest ghostel-test-compile-mode-line-running ()
  "`ghostel-compile--set-mode-line-running' sets `:run' with run face."
  (with-temp-buffer
    (ghostel-compile--set-mode-line-running)
    ;; Expect (:propertize ":run" face compilation-mode-line-run) as head.
    (let ((head (car mode-line-process)))
      (should (eq :propertize (car head)))
      (should (equal ":run" (cadr head)))
      (should (eq 'compilation-mode-line-run
                  (plist-get (cddr head) 'face))))))

(ert-deftest ghostel-test-compile-mode-line-exit ()
  "`ghostel-compile--set-mode-line-exit' uses exit/fail face for 0/non-zero."
  (with-temp-buffer
    (ghostel-compile--set-mode-line-exit 0)
    (let* ((first (car mode-line-process)))
      (should (string-match-p "exit \\[0\\]" first))
      (should (eq 'compilation-mode-line-exit
                  (get-text-property 0 'face first))))
    (ghostel-compile--set-mode-line-exit 1)
    (let* ((first (car mode-line-process)))
      (should (string-match-p "exit \\[1\\]" first))
      (should (eq 'compilation-mode-line-fail
                  (get-text-property 0 'face first))))))

(ert-deftest ghostel-test-compile-finish-hooks-fire ()
  "Both `ghostel-compile-finish-functions' and `compilation-finish-functions' run."
  (ghostel-test--with-compile-buffer buf
    (let* ((ghostel-compile-finished-major-mode nil)
           (g-calls nil)
           (c-calls nil)
           (ghostel-compile-finish-functions
            (list (lambda (b m) (push (cons b m) g-calls))))
           (compilation-finish-functions
            (list (lambda (b m) (push (cons b m) c-calls)))))
      (setq ghostel-compile--command "true"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max)))
      (ghostel-compile--finalize buf 0 (current-time))
      (should (equal 1 (length g-calls)))                     ; ghostel hook
      (should (eq buf (caar g-calls)))
      (should (equal "finished\n" (cdar g-calls)))
      (should (equal 1 (length c-calls)))                     ; compile hook
      (should (equal "finished\n" (cdar c-calls))))))

(ert-deftest ghostel-test-compile-auto-jump-to-first-error ()
  "With `compilation-auto-jump-to-first-error' set, jump after parsing."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil)
          (compilation-auto-jump-to-first-error t)
          (jumped nil))
      (cl-letf (((symbol-function 'first-error)
                 (lambda (&rest _) (setq jumped t))))
        (setq ghostel-compile--command "make"
              ghostel-compile--start-time (current-time)
              ghostel-compile--scan-marker (copy-marker (point-max)))
        (insert "/tmp/x.c:1:1: error: boom\n")
        (ghostel-compile--finalize buf 1 (current-time))
        (should jumped)))))                                    ; first-error called

(ert-deftest ghostel-test-compile-recompile-uses-original-directory ()
  "`ghostel-recompile' must pass the original `default-directory' to --start.

The user's report: run `ghostel-compile' in /A, switch to a buffer
in /B, switch back, press `g'.  The saved per-buffer directory must
be what `--start' receives."
  (let ((dir-at-call nil)
        (buf (generate-new-buffer " *ghostel-test-recompile-dir*"))
        (inhibit-message t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Simulate the post-finalize state of a previous run.
          (setq ghostel-compile--command "make"
                ghostel-compile--directory "/some/project/")
          (cl-letf (((symbol-function 'ghostel-compile--start)
                     (lambda (_cmd _name dir &optional _fm _i)
                       (setq dir-at-call dir))))
            ;; Recompile from a buffer whose default-directory is somewhere else.
            (let ((default-directory "/elsewhere/"))
              (ghostel-recompile))
            (should (equal "/some/project/" dir-at-call))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-compile-recompile-reuses-current-buffer ()
  "`ghostel-recompile' from a ghostel-compile buffer re-runs into it.

When the user presses `g' in `*compilation*' (via global-mode) or
any buffer whose `ghostel-compile--command' is set locally, the
rerun must target the SAME buffer — not the default
`ghostel-compile-buffer-name' — so the existing window isn't
displaced by a new one."
  (let ((name-at-call nil)
        (buf (generate-new-buffer "*some-specific-name*"))
        (inhibit-message t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel-compile--command "make"
                ghostel-compile--directory "/proj/")
          (cl-letf (((symbol-function 'ghostel-compile--start)
                     (lambda (_cmd name _dir &optional _fm _i)
                       (setq name-at-call name))))
            (ghostel-recompile))
          ;; Buffer-name of the CURRENT buffer, not `ghostel-compile-buffer-name'.
          (should (equal "*some-specific-name*" name-at-call)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-compile-recompile-edit-command-prefix-arg ()
  "`ghostel-recompile' with a prefix arg prompts for the command to run.
When EDIT-COMMAND is non-nil it must prompt for the command and run the
edited version, matching the behaviour of \\[recompile]."
  (let ((buf (generate-new-buffer " *ghostel-test-recompile-edit*"))
        (inhibit-message t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel-compile--command "make old"
                ghostel-compile--directory "/some/project/")
          (let ((cmd-at-call nil)
                (prompt-default nil))
            (cl-letf (((symbol-function 'ghostel-compile--start)
                       (lambda (cmd _name _dir &optional _fm _i)
                         (setq cmd-at-call cmd)))
                      ((symbol-function 'read-shell-command)
                       (lambda (_prompt default &rest _)
                         (setq prompt-default default)
                         "make new")))
              ;; With edit-command t: user is prompted, runs edited cmd.
              (ghostel-recompile t)
              (should (equal "make old" prompt-default))        ; default was the last cmd
              (should (equal "make new" cmd-at-call)))           ; chosen cmd is used
            ;; Without the prefix: no prompt, runs the last cmd verbatim.
            (setq cmd-at-call nil prompt-default nil)
            (cl-letf (((symbol-function 'ghostel-compile--start)
                       (lambda (cmd _name _dir &optional _fm _i)
                         (setq cmd-at-call cmd)))
                      ((symbol-function 'read-shell-command)
                       (lambda (&rest _) (setq prompt-default t) "never")))
              (ghostel-recompile)
              (should-not prompt-default)                        ; no prompt
              (should (equal "make old" cmd-at-call)))))         ; last cmd re-run
      (kill-buffer buf))))

(ert-deftest ghostel-test-compile-finalize-pins-default-directory ()
  "Finalize must pin `default-directory' to the captured value.
Even if the shell drifted via OSC 7 or the user customized things,
the resulting `view-mode' buffer should report its compile directory
so `ghostel-recompile' (and other tooling) can rely on it."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-compile--command "make"
          ghostel-compile--directory "/pinned/dir/"
          ghostel-compile--start-time (current-time)
          ghostel-compile--scan-marker (copy-marker (point-max)))
    (setq default-directory "/drifted/somewhere/")
    (ghostel-compile--finalize buf 0 (current-time))
    (should (equal "/pinned/dir/" default-directory))         ; pinned back
    (should (equal "/pinned/dir/" ghostel-compile--directory))))

(ert-deftest ghostel-test-compile-recompile-without-history ()
  "`ghostel-recompile' errors cleanly when nothing has been compiled."
  (let ((compile-command ""))
    (when-let* ((buf (get-buffer ghostel-compile-buffer-name)))
      (kill-buffer buf))
    (should-error (ghostel-recompile) :type 'user-error)))

(ert-deftest ghostel-test-compile-uses-compile-command ()
  "`ghostel-compile' persists the run command to `compile-command'."
  (let ((compile-command "make old"))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) nil))
              ((symbol-function 'save-some-buffers)
               (lambda (&rest _) nil)))
      (ghostel-compile "make new")
      (should (equal "make new" compile-command)))))         ; persisted

(ert-deftest ghostel-test-compile-interactive-uses-compile-history ()
  "`ghostel-compile's prompt uses `compile-history' as the history list."
  (let ((captured nil)
        (compile-history '("old-cmd"))
        (compile-command "make default")
        (compilation-read-command t))
    (cl-letf (((symbol-function 'read-shell-command)
               (lambda (_prompt _default hist-sym &rest _)
                 (setq captured hist-sym)
                 "chosen-cmd"))
              ((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) nil))
              ((symbol-function 'save-some-buffers)
               (lambda (&rest _) nil)))
      (call-interactively #'ghostel-compile)
      ;; History symbol should be (or directly reference) `compile-history'.
      (should (or (eq captured 'compile-history)
                  (and (consp captured)
                       (eq (car captured) 'compile-history)))))))

(ert-deftest ghostel-test-compile-respects-compilation-read-command ()
  "When option `compilation-read-command' is nil, use `compile-command' silently."
  (let ((prompted nil)
        (captured-cmd nil)
        (compile-command "make -C /tmp silent")
        (compilation-read-command nil))
    (cl-letf (((symbol-function 'read-shell-command)
               (lambda (&rest _) (setq prompted t) "never"))
              ((symbol-function 'ghostel-compile--start)
               (lambda (cmd &rest _) (setq captured-cmd cmd) nil))
              ((symbol-function 'save-some-buffers)
               (lambda (&rest _) nil)))
      (call-interactively #'ghostel-compile)
      (should-not prompted)                                    ; no prompt
      (should (equal "make -C /tmp silent" captured-cmd)))))   ; used as-is

(ert-deftest ghostel-test-compile-prepare-buffer-no-window-side-effects ()
  "`ghostel-compile--prepare-buffer' must not touch the caller's window state.
Specifically, it must not change the selected window or mutate its
`window-prev-buffers' history while creating the buffer."
  (let* ((name "*ghostel-test-create*")
         (origin (generate-new-buffer " *ghostel-test-origin*"))
         (saved (current-window-configuration)))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer origin)
          (with-current-buffer origin
            (setq-local default-directory "/tmp/"))
          (let ((start-window (selected-window))
                (start-prev (mapcar #'car (window-prev-buffers)))
                created)
            (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                      ((symbol-function 'ghostel--new)
                       (lambda (&rest _) 'fake-term))
                      ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                      ((symbol-function 'ghostel--apply-palette) #'ignore)
                      ((symbol-function 'ghostel--start-process) #'ignore))
              (setq created (ghostel-compile--prepare-buffer name "/tmp/")))
            ;; Buffer was created, named, and initialized.
            (should (buffer-live-p created))
            (should (equal (buffer-name created) name))
            (should (with-current-buffer created
                      (derived-mode-p 'ghostel-mode)))
            ;; Caller-supplied `default-directory' was carried into it.
            (should (equal (buffer-local-value 'default-directory created)
                           "/tmp/"))
            ;; Caller's window and buffer are unchanged.
            (should (eq (selected-window) start-window))
            (should (eq (window-buffer start-window) origin))
            ;; The compile buffer was never popped into the caller's
            ;; window — so it does NOT appear in `window-prev-buffers'.
            (should-not (memq created
                              (mapcar #'car (window-prev-buffers start-window))))
            (should (equal start-prev
                           (mapcar #'car (window-prev-buffers start-window))))))
      (when (get-buffer "*ghostel-test-create*")
        (let ((kill-buffer-query-functions nil))
          (kill-buffer "*ghostel-test-create*")))
      (when (buffer-live-p origin) (kill-buffer origin))
      (set-window-configuration saved))))

(ert-deftest ghostel-test-compile-finalize-is-idempotent ()
  "Calling `ghostel-compile--finalize' twice must not double-insert."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil))
      (insert "output\n")
      (setq ghostel-compile--command "true"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-min))))
    (ghostel-compile--finalize buf 0 (current-time))
    (let ((after-first (buffer-string)))
      ;; Second call is a no-op thanks to `--finalized'.
      (ghostel-compile--finalize buf 0 (current-time))
      (should (equal after-first (buffer-string))))))

(ert-deftest ghostel-test-compile-global-mode-toggles-advice ()
  "Enabling and disabling `ghostel-compile-global-mode' adds/removes the advice."
  (let ((ghostel-compile-global-mode nil))
    (unwind-protect
        (progn
          (ghostel-compile-global-mode 1)
          (should (advice-member-p
                   #'ghostel-compile--compilation-start-advice
                   'compilation-start))
          (ghostel-compile-global-mode -1)
          (should-not (advice-member-p
                       #'ghostel-compile--compilation-start-advice
                       'compilation-start)))
      (ghostel-compile-global-mode -1))))

(ert-deftest ghostel-test-compile-global-mode-falls-through-for-grep ()
  "`grep-mode' must fall through to the stock `compilation-start'."
  (let ((orig-called nil)
        (ghostel-called nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) (setq ghostel-called t) nil)))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (setq orig-called t) nil)
       "grep foo" 'grep-mode nil nil nil))
    (should orig-called)                                        ; stock path ran
    (should-not ghostel-called)))                              ; ours did not

(ert-deftest ghostel-test-compile-global-mode-routes-to-ghostel-start ()
  "For supported modes, the advice routes COMMAND through `ghostel-compile--start'.
The default route — MODE nil or `compilation-mode' — must use the
read-only variant (interactive=nil)."
  (let ((captured nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (cmd name dir &optional _finished-mode interactive
                            &rest _)
                 (setq captured (list cmd name dir interactive))
                 (generate-new-buffer " *ghostel-test-advice*"))))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (error "Stock path should not run"))
       "make test" nil nil nil nil))
    (should (equal "make test" (nth 0 captured)))              ; command preserved
    ;; Default buffer name for `compilation-mode' is "*compilation*".
    (should (string-match-p "compilation" (nth 1 captured)))
    ;; Read-only by default — no prefix, no MODE=t.
    (should-not (nth 3 captured))))

(ert-deftest ghostel-test-compile-global-mode-threads-subclass-mode ()
  "A custom compile-mode subclass passed as MODE is forwarded to finalize.

The advice must pass a non-`compilation-mode' MODE through to
`ghostel-compile--start' as its FINISHED-MODE argument so the
subclass (with its error-regexp, font-lock keywords, etc.) is the
major mode the buffer ends up in after finalize — and *not*
override with the default `ghostel-compile-view-mode'."
  (let ((captured-finished nil)
        (captured-interactive 'unset))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (_cmd _name _dir &optional finished-mode interactive
                             &rest _)
                 (setq captured-finished finished-mode
                       captured-interactive interactive)
                 nil)))
      ;; Custom mode → threaded through; still read-only (interactive=nil).
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (error "Stock path should not run"))
       "make" 'my-custom-compile-mode nil nil nil)
      (should (eq 'my-custom-compile-mode captured-finished))
      (should-not captured-interactive)
      ;; Plain `compilation-mode' → nil (default view-mode kicks in).
      (setq captured-finished :unchanged
            captured-interactive 'unset)
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (error "Stock path should not run"))
       "make" 'compilation-mode nil nil nil)
      (should-not captured-finished)
      (should-not captured-interactive))))

(ert-deftest ghostel-test-compile-global-mode-falls-through-on-continue ()
  "Non-nil CONTINUE must fall through: `--start' recreates the buffer."
  (let ((orig-called nil)
        (ghostel-called nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) (setq ghostel-called t) nil)))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (setq orig-called t) nil)
       "make" 'compilation-mode nil nil t))         ; continue=t
    (should orig-called)
    (should-not ghostel-called)))

(ert-deftest ghostel-test-compile-global-mode-routes-mode-t-to-interactive ()
  "MODE=t routes to a writable ghostel terminal, not stock comint.
This is the user-facing target for `\\[universal-argument] \\[compile]':
the caller is asking for an interactive buffer, and we honour that
by spawning a ghostel terminal (so a real TTY is still available)
instead of falling through to `comint-mode'."
  (let ((captured-interactive 'unset)
        (captured-name nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (_cmd name _dir &optional _fm interactive &rest _)
                 (setq captured-interactive interactive
                       captured-name name)
                 (generate-new-buffer " *ghostel-test-mode-t*"))))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (error "Stock comint path should not run"))
       "make" t nil nil nil))
    (should (eq t captured-interactive))                         ; interactive variant
    ;; Stock `compilation-start' uses "compilation" as name-of-mode for MODE=t;
    ;; we mirror that for buffer-name parity.
    (should (string-match-p "compilation" captured-name))))

(ert-deftest ghostel-test-compile-global-mode-excluded-custom-mode ()
  "A custom mode added to `ghostel-compile-global-mode-excluded-modes' falls through."
  (let ((orig-called nil)
        (ghostel-compile-global-mode-excluded-modes '(my-fake-grep-mode)))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) (error "Ghostel path should not run"))))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (setq orig-called t) nil)
       "whatever" 'my-fake-grep-mode nil nil nil))
    (should orig-called)))

(ert-deftest ghostel-test-compile-interactive-form-no-prefix ()
  "`M-x ghostel-compile' with no prefix arg → INTERACTIVE=nil (read-only run)."
  (let ((captured-interactive 'unset)
        (compile-command "make")
        (compilation-read-command nil)
        (current-prefix-arg nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (_cmd _name _dir &optional _fm interactive)
                 (setq captured-interactive interactive)))
              ((symbol-function 'save-some-buffers) (lambda (&rest _) nil)))
      (call-interactively #'ghostel-compile)
      (should-not captured-interactive))))

(ert-deftest ghostel-test-compile-interactive-form-c-u ()
  "\\[universal-argument] \\[ghostel-compile] → INTERACTIVE=t (writable terminal)."
  (let ((captured-interactive 'unset)
        (compile-command "make")
        (current-prefix-arg '(4)))                               ; C-u
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (_cmd _name _dir &optional _fm interactive)
                 (setq captured-interactive interactive)))
              ((symbol-function 'read-shell-command)
               (lambda (_p default &rest _) default))           ; auto-accept
              ((symbol-function 'save-some-buffers) (lambda (&rest _) nil)))
      (call-interactively #'ghostel-compile)
      (should (eq t captured-interactive)))))

(ert-deftest ghostel-test-compile-interactive-form-numeric-prefix ()
  "Numeric prefix prompts but does NOT switch to interactive mode.
Mirrors stock \\[compile] where the `consp' check on
`current-prefix-arg' is the gate for the interactive (comint)
variant — a numeric prefix like `C-3' is `consp'-false."
  (let ((captured-interactive 'unset)
        (prompted nil)
        (compile-command "make")
        (current-prefix-arg 3))                                   ; numeric prefix
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (_cmd _name _dir &optional _fm interactive)
                 (setq captured-interactive interactive)))
              ((symbol-function 'read-shell-command)
               (lambda (_p default &rest _) (setq prompted t) default))
              ((symbol-function 'save-some-buffers) (lambda (&rest _) nil)))
      (call-interactively #'ghostel-compile)
      (should prompted)                                           ; prompt happened
      (should-not captured-interactive))))                        ; still read-only

(ert-deftest ghostel-test-compile-recompile-preserves-interactive-mode ()
  "`ghostel-recompile' must reuse the launch mode of the source buffer.
A buffer launched with INTERACTIVE=t reruns interactively; one
launched read-only reruns read-only."
  (let ((captured-interactive 'unset)
        (inhibit-message t))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (_cmd _name _dir &optional _fm interactive)
                 (setq captured-interactive interactive))))
      ;; Source buffer launched interactively.
      (let ((buf (generate-new-buffer " *ghostel-test-recompile-int*")))
        (unwind-protect
            (with-current-buffer buf
              (ghostel-mode)
              (setq ghostel-compile--command "make"
                    ghostel-compile--directory "/tmp/"
                    ghostel-compile--interactive t)
              (ghostel-recompile)
              (should (eq t captured-interactive)))
          (kill-buffer buf)))
      ;; Source buffer launched read-only.
      (setq captured-interactive 'unset)
      (let ((buf (generate-new-buffer " *ghostel-test-recompile-ro*")))
        (unwind-protect
            (with-current-buffer buf
              (ghostel-mode)
              (setq ghostel-compile--command "make"
                    ghostel-compile--directory "/tmp/"
                    ghostel-compile--interactive nil)
              (ghostel-recompile)
              (should-not captured-interactive))
          (kill-buffer buf))))))

(ert-deftest ghostel-test-compile-readonly-buffer-during-run ()
  "Default (read-only) run: buffer is locked, compile keys are bound.

The buffer is in `ghostel-mode' (so the renderer keeps working) but
`buffer-read-only' is set and the local map is the compile-style
`ghostel-compile-view-mode-map' — `g' reruns, `n'/`p' walk errors,
attempts to mutate the buffer signal `buffer-read-only'."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-readonly-compile*")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        ;; INTERACTIVE arg omitted → defaults to nil (read-only).
        (let ((buf (ghostel-compile--start "sleep 30" buf-name
                                           default-directory)))
          (with-current-buffer buf
            (ghostel-test--wait-for
             ghostel--process
             (lambda () (eq 'run (process-status ghostel--process))))
            ;; Major mode is still ghostel-mode (renderer prerequisite).
            (should (eq major-mode 'ghostel-mode))
            ;; Buffer is read-only.
            (should buffer-read-only)
            ;; Local map is the compile-style one.
            (should (eq (current-local-map) ghostel-compile-view-mode-map))
            ;; `g' is bound to ghostel-recompile (not to ghostel's
            ;; self-insert), `n'/`p' walk errors.
            (should (eq (key-binding "g") #'ghostel-recompile))
            (should (eq (key-binding "n") #'compilation-next-error))
            (should (eq (key-binding "p") #'compilation-previous-error))
            ;; Plain letters do NOT route to the process — `a' is not
            ;; bound to ghostel's self-insert in the compile keymap,
            ;; so a keystroke wouldn't make it to the PTY.
            (should-not (eq (key-binding "a") #'ghostel--self-insert))
            ;; A mutation attempt is rejected with `buffer-read-only'.
            (should-error (barf-if-buffer-read-only)
                          :type 'buffer-read-only)
            ;; Kill the sleep process so the test doesn't leak.
            (let ((p ghostel--process))
              (when (process-live-p p)
                (set-process-sentinel p #'ignore)
                (set-process-filter p #'ignore)
                (setq compilation-in-progress
                      (delq p compilation-in-progress))
                (delete-process p)))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-finalize-preserves-interactive-mode ()
  "Finalize must carry `ghostel-compile--interactive' across the mode switch.
The variable is buffer-local and `funcall target-mode' wipes
locals, so finalize has to save and restore it — otherwise
`ghostel-recompile' from the finished buffer would lose the launch
mode."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-compile--command "make"
          ghostel-compile--start-time (current-time)
          ghostel-compile--scan-marker (copy-marker (point-max))
          ghostel-compile--directory "/tmp/"
          ghostel-compile--interactive t)
    (ghostel-compile--finalize buf 0 (current-time))
    (should (eq t ghostel-compile--interactive)))
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-compile--command "make"
          ghostel-compile--start-time (current-time)
          ghostel-compile--scan-marker (copy-marker (point-max))
          ghostel-compile--directory "/tmp/"
          ghostel-compile--interactive nil)
    (ghostel-compile--finalize buf 0 (current-time))
    (should-not ghostel-compile--interactive)))

(ert-deftest ghostel-test-compile-recompile-after-finalize-preserves-mode ()
  "End-to-end: finalize → `g' must recompile in the launched mode.
The earlier per-step tests cover the variable across each
transition; this one chains them — finalize the buffer (which
performs `funcall target-mode' under the hood, the operation that
wipes buffer-locals), then call `ghostel-recompile' and assert the
INTERACTIVE arg `--start' receives matches the original launch."
  (let ((captured-interactive 'unset)
        (inhibit-message t))
    ;; Finalized buffer originally launched read-only.
    (ghostel-test--with-compile-buffer buf
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max))
            ghostel-compile--directory "/tmp/"
            ghostel-compile--interactive nil)
      (ghostel-compile--finalize buf 0 (current-time))
      ;; Buffer is now in `ghostel-compile-view-mode' — `funcall target-mode'
      ;; just ran.  Press `g' from inside it.
      (cl-letf (((symbol-function 'ghostel-compile--start)
                 (lambda (_cmd _name _dir &optional _fm interactive &rest _)
                   (setq captured-interactive interactive))))
        (ghostel-recompile))
      (should-not captured-interactive))
    ;; And originally launched interactively.
    (setq captured-interactive 'unset)
    (ghostel-test--with-compile-buffer buf
      (setq ghostel-compile--command "htop"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max))
            ghostel-compile--directory "/tmp/"
            ghostel-compile--interactive t)
      (ghostel-compile--finalize buf 0 (current-time))
      (cl-letf (((symbol-function 'ghostel-compile--start)
                 (lambda (_cmd _name _dir &optional _fm interactive &rest _)
                   (setq captured-interactive interactive))))
        (ghostel-recompile))
      (should (eq t captured-interactive)))))

(ert-deftest ghostel-test-compile-sets-compilation-arguments ()
  "`--start' must populate `compilation-arguments' for `revert-buffer'.
Direct callers (no tuple passed) get the launch mode in the MODE
slot so a revert routes through the global-mode advice and lands
on the same variant.  The advice passes its own tuple verbatim, so
custom MODE / NAME-FUNCTION / HIGHLIGHT-REGEXP survive a revert."
  :tags '(native)
  ;; Direct call without a tuple → synthesized default.
  (let ((buf-name "*ghostel-test-compargs-direct*")
        (inhibit-message t)
        (save-some-buffers-default-predicate (lambda () nil))
        (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf-name)))
    (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel--new) (lambda (&rest _) 'fake))
              ((symbol-function 'ghostel--apply-palette) #'ignore)
              ((symbol-function 'ghostel--set-size) #'ignore)
              (ghostel--cursor-pos (cons 0 0))
              ((symbol-function 'ghostel-compile--render-header-live)
               #'ignore)
              ((symbol-function 'ghostel-compile--spawn)
               (lambda (_cmd buf _h _w)
                 (let ((p (start-process "ghostel-test-args" buf
                                         "sleep" "100")))
                   (set-process-sentinel p #'ignore)
                   (set-process-query-on-exit-flag p nil)
                   (with-current-buffer buf (setq ghostel--process p))
                   p))))
      (unwind-protect
          (let ((buf (ghostel-compile--start "make" buf-name "/tmp/" nil nil)))
            (with-current-buffer buf
              ;; Default tuple records nil in MODE (read-only run).
              (should (equal '("make" nil nil nil) compilation-arguments))
              (should (eq #'compilation-revert-buffer revert-buffer-function))
              (let ((p ghostel--process))
                (when (process-live-p p)
                  (setq compilation-in-progress
                        (delq p compilation-in-progress))
                  (delete-process p)))))
        (when (get-buffer buf-name)
          (let ((kill-buffer-query-functions nil)) (kill-buffer buf-name))))))
  ;; Caller-supplied tuple wins.
  (let ((buf-name "*ghostel-test-compargs-tuple*")
        (inhibit-message t)
        (save-some-buffers-default-predicate (lambda () nil))
        (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf-name)))
    (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel--new) (lambda (&rest _) 'fake))
              ((symbol-function 'ghostel--apply-palette) #'ignore)
              ((symbol-function 'ghostel--set-size) #'ignore)
              (ghostel--cursor-pos (cons 0 0))
              ((symbol-function 'ghostel-compile--render-header-live)
               #'ignore)
              ((symbol-function 'ghostel-compile--spawn)
               (lambda (_cmd buf _h _w)
                 (let ((p (start-process "ghostel-test-args2" buf
                                         "sleep" "100")))
                   (set-process-sentinel p #'ignore)
                   (set-process-query-on-exit-flag p nil)
                   (with-current-buffer buf (setq ghostel--process p))
                   p))))
      (unwind-protect
          (let* ((tuple '("make" my-mode my-namer "rgxp"))
                 (buf (ghostel-compile--start "make" buf-name "/tmp/"
                                              nil nil tuple)))
            (with-current-buffer buf
              (should (equal tuple compilation-arguments))
              (let ((p ghostel--process))
                (when (process-live-p p)
                  (setq compilation-in-progress
                        (delq p compilation-in-progress))
                  (delete-process p)))))
        (when (get-buffer buf-name)
          (let ((kill-buffer-query-functions nil)) (kill-buffer buf-name)))))))

(ert-deftest ghostel-test-compile-toggle-mode-keymap-bindings ()
  "`ghostel-compile-toggle-mode-map' binds the switch commands.
`switch-to-readonly' has two bindings — the second mirrors
`ghostel-mode's copy-mode key, since both are navigable/frozen
states."
  (should (eq #'ghostel-compile-switch-to-interactive
              (lookup-key ghostel-compile-toggle-mode-map (kbd "C-c C-j"))))
  (should (eq #'ghostel-compile-switch-to-readonly
              (lookup-key ghostel-compile-toggle-mode-map (kbd "C-c C-e"))))
  (should (eq #'ghostel-compile-switch-to-readonly
              (lookup-key ghostel-compile-toggle-mode-map (kbd "C-c C-t")))))

(ert-deftest ghostel-test-compile-switch-errors-without-process ()
  "Both switch commands error in a buffer without a live process.
Post-finalize the keys remain bound but the commands refuse to act
— the user is told to recompile with `g' instead."
  (let ((buf (generate-new-buffer " *ghostel-test-switch-no-proc*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel-compile--command "make"
                ghostel--process nil)
          (should-error (ghostel-compile-switch-to-interactive)
                        :type 'user-error)
          (should-error (ghostel-compile-switch-to-readonly)
                        :type 'user-error))
      (kill-buffer buf))))

(ert-deftest ghostel-test-compile-switch-errors-in-non-compile-buffer ()
  "Both switch commands error in a `ghostel-mode' buffer with no compile state."
  (let ((buf (generate-new-buffer " *ghostel-test-switch-non-compile*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; No `ghostel-compile--command' — not a compile buffer.
          (should-error (ghostel-compile-switch-to-interactive)
                        :type 'user-error)
          (should-error (ghostel-compile-switch-to-readonly)
                        :type 'user-error))
      (kill-buffer buf))))

(ert-deftest ghostel-test-compile-mode-line-running-reflects-interactive ()
  "`--set-mode-line-running' shows `:run' read-only / `:run/i' interactive."
  (with-temp-buffer
    (let ((ghostel-compile--interactive nil))
      (ghostel-compile--set-mode-line-running)
      (should (equal ":run" (cadr (car mode-line-process)))))
    (let ((ghostel-compile--interactive t))
      (ghostel-compile--set-mode-line-running)
      (should (equal ":run/i" (cadr (car mode-line-process)))))))

(ert-deftest ghostel-test-compile-switch-flips-state ()
  "End-to-end: spawn a long sleep read-only, switch to interactive and back.

After `\\[ghostel-compile-switch-to-interactive]' the buffer must
become writable, the local map must drop the compile-style one for
`ghostel-mode-map', and `mode-line-process' must show `:run/i'.
After `\\[ghostel-compile-switch-to-readonly]' the buffer must lock
back, install `ghostel-compile-view-mode-map', and the mode-line
must read `:run' again."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-toggle-flip*")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf-name)))
    (unwind-protect
        ;; Default (read-only) launch.
        (let ((buf (ghostel-compile--start "sleep 30" buf-name
                                           default-directory)))
          (with-current-buffer buf
            (ghostel-test--wait-for
             ghostel--process
             (lambda () (eq 'run (process-status ghostel--process))))
            ;; Initial state: read-only.
            (should (eq (current-local-map) ghostel-compile-view-mode-map))
            (should buffer-read-only)
            (should-not ghostel-compile--interactive)
            (should (equal ":run" (cadr (car mode-line-process))))
            ;; Switch to interactive.
            (ghostel-compile-switch-to-interactive)
            (should ghostel-compile--interactive)
            (should-not buffer-read-only)
            (should (eq (current-local-map) ghostel-mode-map))
            (should (equal ":run/i" (cadr (car mode-line-process))))
            ;; No-op when already interactive.
            (ghostel-compile-switch-to-interactive)
            (should ghostel-compile--interactive)        ; unchanged
            ;; Switch back to read-only.
            (ghostel-compile-switch-to-readonly)
            (should-not ghostel-compile--interactive)
            (should buffer-read-only)
            (should (eq (current-local-map) ghostel-compile-view-mode-map))
            (should (equal ":run" (cadr (car mode-line-process))))
            ;; No-op when already read-only.
            (ghostel-compile-switch-to-readonly)
            (should-not ghostel-compile--interactive)    ; unchanged
            ;; Cleanup.
            (let ((p ghostel--process))
              (when (process-live-p p)
                (set-process-sentinel p #'ignore)
                (set-process-filter p #'ignore)
                (setq compilation-in-progress
                      (delq p compilation-in-progress))
                (delete-process p)))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-toggle-mode-active-during-run ()
  "`ghostel-compile-toggle-mode' is auto-enabled in compile buffers.
The minor-mode keymap takes precedence over the local map and the
major-mode map, so `\\[ghostel-compile-switch-to-interactive]' /
`\\[ghostel-compile-switch-to-readonly]' work in both run states."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-toggle-mode-active*")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf-name)))
    (unwind-protect
        (let ((buf (ghostel-compile--start "sleep 30" buf-name
                                           default-directory)))
          (with-current-buffer buf
            (ghostel-test--wait-for
             ghostel--process
             (lambda () (eq 'run (process-status ghostel--process))))
            ;; Read-only state: minor-mode binding wins over view-mode-map.
            (should ghostel-compile-toggle-mode)
            (should (eq (key-binding (kbd "C-c C-j"))
                        #'ghostel-compile-switch-to-interactive))
            (should (eq (key-binding (kbd "C-c C-e"))
                        #'ghostel-compile-switch-to-readonly))
            ;; Switch and re-check: keys still bound (minor-mode wins
            ;; over `ghostel-mode-map' too).
            (ghostel-compile-switch-to-interactive)
            (should ghostel-compile-toggle-mode)
            (should (eq (key-binding (kbd "C-c C-j"))
                        #'ghostel-compile-switch-to-interactive))
            (should (eq (key-binding (kbd "C-c C-e"))
                        #'ghostel-compile-switch-to-readonly))
            ;; Cleanup.
            (let ((p ghostel--process))
              (when (process-live-p p)
                (set-process-sentinel p #'ignore)
                (set-process-filter p #'ignore)
                (setq compilation-in-progress
                      (delq p compilation-in-progress))
                (delete-process p)))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-toggle-mode-active-post-finalize ()
  "After finalize, the toggle mode survives into `ghostel-compile-view-mode'.
The keys remain bound; the commands error gracefully because there
is no live process."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-compile--command "make"
          ghostel-compile--start-time (current-time)
          ghostel-compile--scan-marker (copy-marker (point-max))
          ghostel-compile--directory "/tmp/")
    (ghostel-compile--finalize buf 0 (current-time))
    ;; View-mode is now the major mode; the toggle minor mode must be on.
    (should ghostel-compile-toggle-mode)
    (should (eq (key-binding (kbd "C-c C-j"))
                #'ghostel-compile-switch-to-interactive))
    ;; And the command rejects the call because there's no process.
    (should-error (ghostel-compile-switch-to-interactive)
                  :type 'user-error)))

(ert-deftest ghostel-test-compile-allows-interactive-input-during-run ()
  "Regression: when launched interactively, the buffer must accept input.

When `ghostel-compile--start' is called with INTERACTIVE non-nil
\(via \\[universal-argument] \\[ghostel-compile], or
`compilation-start' with MODE=t under `ghostel-compile-global-mode'),
the live buffer must remain writable: `compilation-minor-mode' must
not be enabled on it, and the local map must keep `ghostel-mode's
self-insert so letters like `q', `a', `g' reach the process (this
is what makes `htop', `less', read prompts etc. work).  And
`--spawn' must set `ghostel--process' so `ghostel--self-insert' has
a process to send keystrokes to.

Run a small interactive echo loop, verify both conditions, then
send bytes through the process to confirm they land in the buffer."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-interactive-compile*")
         (script (concat "printf '%s\\n' ghostel-ready; "
                         "while IFS= read -r line; do "
                         "printf '%s\\n' \"$line\"; "
                         "[ \"$line\" = ghosttel-ping ] && exit 0; "
                         "done; exit 1"))
         (shell-file-name "/bin/sh")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (let ((buf (ghostel-compile--start script buf-name
                                           default-directory nil t))) ; interactive=t
          (with-current-buffer buf
            ;; Wait until the command has actually started and is blocked
            ;; reading from the PTY.  Waiting for a program-emitted marker
            ;; is less racy on busy CI hosts than polling process status
            ;; immediately after `make-process' returns.
            (ghostel-test--wait-for
             ghostel--process
             (lambda ()
               (string-match-p "ghostel-ready"
                               (ghostel--copy-all-text ghostel--term))))
            ;; The live buffer must be plain `ghostel-mode' — no compile
            ;; minor mode stealing keys.
            (should (eq major-mode 'ghostel-mode))
            (should-not (bound-and-true-p compilation-minor-mode))
            ;; Buffer is writable in interactive mode.
            (should-not buffer-read-only)
            ;; Plain letters route through ghostel-mode's self-insert,
            ;; not through compilation-mode's navigation commands.
            (should (eq (key-binding "q") #'ghostel--self-insert))
            (should (eq (key-binding "a") #'ghostel--self-insert))
            ;; `ghostel--process' is populated, so `ghostel--self-insert'
            ;; has a process to send to.
            (should (process-live-p ghostel--process))
            ;; Round-trip: send a line, expect the echo-loop to print it.
            (process-send-string ghostel--process "ghosttel-ping\n")
            (ghostel-test--wait-for
             ghostel--process
             (lambda ()
               (string-match-p "ghosttel-ping"
                               (ghostel--copy-all-text ghostel--term))))
            (ghostel-test--wait-for
             ghostel--process
             (lambda () ghostel-compile--finalized) 10)))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-multiline-end-to-end ()
  "A multi-line shell paragraph must run intact under `ghostel-compile'.
The paragraph must land in the buffer unmangled and the run must
report the real exit status.

This is the end-to-end proof for the core PR change: the old design
typed the command into a live shell and each embedded newline was
parsed as a RET press, mangling multi-line scripts.  The new design
spawns `sh -c COMMAND' directly, so the shell parses the paragraph
normally."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-multiline-compile*")
         (shell-file-name "/bin/sh")
         (script "for i in 1 2 3; do\n  echo line-$i\ndone\nexit 7")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil)))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (let ((buf (ghostel-compile--start script buf-name
                                           default-directory)))
          (with-current-buffer buf
            (ghostel-test--wait-for
             ghostel--process
             (lambda () ghostel-compile--finalized)
             10)
            (should (equal 7 ghostel-compile--last-exit))
            (let ((text (buffer-substring-no-properties
                         (point-min) (point-max))))
              (should (string-match-p "line-1" text))
              (should (string-match-p "line-2" text))
              (should (string-match-p "line-3" text))
              (should (string-match-p "exited abnormally with code 7" text)))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-reconciles-vt-size-to-outwin ()
  "`ghostel-compile--start' must resize the VT to the output window.

`prepare-buffer' sizes the VT from the selected window (the only
dimensions available before `display-buffer').  If the compile
buffer ends up in a smaller window, the PTY's `set-process-window-size'
agrees with the output window but the VT still thinks it has the
width of the selected window, so early output wraps at the wrong column.
`--start' must call `ghostel--set-size' with the output-window
dimensions *before* rendering the header, and `--spawn' must receive
the same dimensions so PTY and VT always agree."
  (let* ((buf-name "*ghostel-test-compile-size*")
         (set-size-calls nil)
         (spawn-calls nil)
         (call-order nil)
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (cl-letf* (((symbol-function 'ghostel--load-module) #'ignore)
                   ((symbol-function 'ghostel--new)
                    (lambda (&rest _) 'fake-term))
                   ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                   ((symbol-function 'ghostel--apply-palette) #'ignore)
                   ((symbol-function 'ghostel--set-size)
                    (lambda (_term rows cols)
                      (push 'set-size call-order)
                      (push (list rows cols) set-size-calls)))
                   ((symbol-function 'ghostel-compile--render-header-live)
                    (lambda (&rest _) (push 'render-header call-order)))
                   (ghostel--cursor-pos (cons 0 0))
                   ((symbol-function 'ghostel-compile--spawn)
                    (lambda (_cmd buf h w)
                      (push 'spawn call-order)
                      (push (list h w) spawn-calls)
                      (let ((p (start-process "ghostel-test-size-fake"
                                              buf "sleep" "100")))
                        (set-process-sentinel p #'ignore)
                        (set-process-query-on-exit-flag p nil)
                        (with-current-buffer buf
                          (setq ghostel--process p))
                        p))))
          (let ((buf (ghostel-compile--start "true" buf-name
                                             default-directory)))
            (with-current-buffer buf
              ;; The reconcile call happened.
              (should set-size-calls)
              ;; Reconcile must precede the header render *and* the spawn —
              ;; otherwise the header / early command output wraps at the
              ;; pre-reconcile column.  `call-order' is LIFO, so chronological
              ;; order is the reverse.
              (let ((chronological (reverse call-order)))
                (should (equal chronological
                               '(set-size render-header spawn))))
              ;; Final VT size equals what was handed to the process.
              (let ((vt-size (car set-size-calls))
                    (pty-size (car spawn-calls)))
                (should (equal vt-size pty-size)))
              ;; `ghostel--term-rows' tracks the final reconciled height.
              (should (= (car (car set-size-calls)) ghostel--term-rows))
              ;; Clean up the fake process.
              (let ((p ghostel--process))
                (when (process-live-p p)
                  (setq compilation-in-progress
                        (delq p compilation-in-progress))
                  (delete-process p))))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-reconciles-skips-when-no-outwin ()
  "If `display-buffer' returns nil, reconcile is skipped safely.
`allow-no-window' permits `display-buffer' to choose not to show the
buffer at all.  The `(when (and outwin ...))' guard in `--start' must
gate the `ghostel--set-size' call so we don't crash or pass bogus
dimensions when no output window exists."
  (let* ((buf-name "*ghostel-test-compile-no-outwin*")
         (set-size-called nil)
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (cl-letf* (((symbol-function 'ghostel--load-module) #'ignore)
                   ((symbol-function 'ghostel--new)
                    (lambda (&rest _) 'fake-term))
                   ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                   ((symbol-function 'ghostel--apply-palette) #'ignore)
                   ((symbol-function 'display-buffer) (lambda (&rest _) nil))
                   ((symbol-function 'ghostel--set-size)
                    (lambda (&rest _) (setq set-size-called t)))
                   ((symbol-function 'ghostel-compile--render-header-live)
                    #'ignore)
                   (ghostel--cursor-pos (cons 0 0))
                   ((symbol-function 'ghostel-compile--spawn)
                    (lambda (_cmd buf _h _w)
                      (let ((p (start-process "ghostel-test-nowin-fake"
                                              buf "sleep" "100")))
                        (set-process-sentinel p #'ignore)
                        (set-process-query-on-exit-flag p nil)
                        (with-current-buffer buf
                          (setq ghostel--process p))
                        p))))
          (let ((buf (ghostel-compile--start "true" buf-name
                                             default-directory)))
            (should (buffer-live-p buf))
            (should-not set-size-called)
            (with-current-buffer buf
              (let ((p ghostel--process))
                (when (process-live-p p)
                  (setq compilation-in-progress
                        (delq p compilation-in-progress))
                  (delete-process p))))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-kill-compilation-finds-live-buffer ()
  "`kill-compilation' must locate a live ghostel-compile buffer.

During the run the buffer stays in `ghostel-mode' so keystrokes reach
the process, which means `compilation-mode' never runs.  `kill-compilation'
calls `compilation-find-buffer' -> `compilation-buffer-internal-p',
which is `(local-variable-p 'compilation-locs)'.  `prepare-buffer' must
declare that variable buffer-locally so the live buffer qualifies."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-kill-compilation*")
         (command "printf '%s\\n' GHOSTEL_KILL_READY; exec sleep 30")
         (shell-file-name "/bin/sh")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (let ((buf (ghostel-compile--start command buf-name
                                           default-directory)))
          (with-current-buffer buf
            (ghostel-test--wait-for
             ghostel--process
             (lambda ()
               (string-match-p "GHOSTEL_KILL_READY"
                               (ghostel--copy-all-text ghostel--term))))
            ;; The live buffer passes `compilation-buffer-p' — which is
            ;; the gate `kill-compilation' uses.
            (should (compilation-buffer-p buf))
            ;; From inside the buffer, `compilation-find-buffer' returns it.
            (should (eq (compilation-find-buffer) buf))
            ;; Also findable from an arbitrary buffer, via `next-error-find-
            ;; buffer' — that's how `kill-compilation' reaches us when the
            ;; user invokes it from elsewhere.
            (should (with-temp-buffer (eq (compilation-find-buffer) buf)))
            ;; And the buffer has a live process `kill-compilation' would
            ;; deliver SIGINT to.
            (should (process-live-p (get-buffer-process buf)))
            ;; End-to-end: invoke `kill-compilation' from inside the buffer
            ;; and wait for the process to die via SIGINT.  The command has
            ;; exec'd `sleep', so SIGINT terminates it, the sentinel finalizes,
            ;; and `--last-exit' reflects a non-zero status.
            (kill-compilation)
            (ghostel-test--wait-for
             ghostel--process
             (lambda () ghostel-compile--finalized) 10)
            (should ghostel-compile--finalized)
            (should (numberp ghostel-compile--last-exit))
            (should-not (zerop ghostel-compile--last-exit))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-prepare-buffer-sets-dir-before-mode ()
  "`default-directory' must be set before `ghostel-mode' in prepare-buffer.
The mode's `hack-dir-local-variables' call must resolve dir-locals
against the target directory.  If the order flips, per-project
`ghostel-environment' overrides silently miss for compile.  Also
pins that `default-directory' survives the mode switch — if somebody
drops the `permanent-local' property upstream this test catches it."
  (let ((captured-default-directory nil)
        (target "/tmp/"))
    (cl-letf (((symbol-function 'hack-dir-local-variables)
               (lambda ()
                 (setq captured-default-directory default-directory)))
              ((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel--new) (lambda (&rest _) 'fake-term))
              ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
              ((symbol-function 'ghostel--apply-palette) #'ignore))
      (let ((buf (ghostel-compile--prepare-buffer
                  " *ghostel-prepare-test*" target)))
        (unwind-protect
            (progn
              (should (equal captured-default-directory target))
              (with-current-buffer buf
                (should (equal default-directory target))))
          (kill-buffer buf))))))

(ert-deftest ghostel-test-compile-spawn-disables-adaptive-read-buffering ()
  "`ghostel-compile--spawn' must disable adaptive read buffering.
It must also raise `read-process-output-max'.  Same reason as
`ghostel--spawn-pty' (issue #85)."
  :tags '(native)
  (let ((captured-adaptive 'unset)
        (captured-max nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-adaptive process-adaptive-read-buffering
                       captured-max read-process-output-max)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (let ((proc (ghostel-compile--spawn "true" (current-buffer) 24 80)))
          (unwind-protect
              (progn
                (should (null captured-adaptive))
                (should (>= captured-max (* 1024 1024))))
            (when (process-live-p proc)
              (delete-process proc))))))))

(provide 'ghostel-compile-test)
;;; ghostel-compile-test.el ends here
