;;; ghostel-spawn-test.el --- Tests for ghostel: process spawning -*- lexical-binding: t; -*-

;;; Commentary:

;; Local shell resolution, login wrapping, PTY process startup, resize signaling,
;; and pre-spawn hook environment injection.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-test--with-spawn-capture (capture &rest body)
  "Bind CAPTURE to the (PROGRAM . ARGS) cons passed to `ghostel--spawn-pty'.
Stubs out `ghostel--spawn-pty' so no real process is spawned.  BODY
runs with the stub in place."
  (declare (indent 1))
  `(let (,capture)
     (cl-letf (((symbol-function 'ghostel--spawn-pty)
                (lambda (program args &rest _)
                  (setq ,capture (cons program args))
                  nil)))
       ,@body)))

(defmacro ghostel-test--with-spawn-process-capture (capture &rest body)
  "Run BODY while capturing the inputs at the PTY spawn boundary.
CAPTURE is set to a plist with the shell command, `process-environment',
buffering bindings, current buffer, and `default-directory' observed at
`ghostel--spawn-process' \(the single dispatcher over the native/Emacs
spawners).  The dispatcher is stubbed, so no process is spawned.

This captures what `ghostel--spawn-pty' builds, which is identical for
both backends, so there is no need to exercise the PTY matrix here."
  (declare (indent 1))
  `(let (,capture)
     (cl-letf (((symbol-function 'ghostel--spawn-process)
                (lambda (shell-command remote-p)
                  (setq ,capture
                        (list :command (copy-tree shell-command)
                              :env (copy-sequence process-environment)
                              :adaptive process-adaptive-read-buffering
                              :read-max read-process-output-max
                              :remote-p remote-p
                              :buffer (current-buffer)
                              :default-directory default-directory))
                  nil)))
       ,@body)
     (should ,capture)))

(defconst ghostel-test--pty-winsize-script
  (string-join
   '("import os, signal, sys, time"
     "fd = sys.stdout.fileno()"
     "def report(tag):"
     "    sz = os.get_terminal_size(fd)"
     "    sys.stdout.write('GHOSTEL_WINSIZE_%s:%d,%d\\r\\n' % (tag, sz.lines, sz.columns))"
     "    sys.stdout.flush()"
     "signal.signal(signal.SIGWINCH, lambda *_: report('WINCH'))"
     "report('INIT')"
     "deadline = time.time() + 10"
     "while time.time() < deadline:"
     "    time.sleep(0.05)")
   "\n")
  "Python code that reports its PTY window size as the child of a ghostel term.
Writes `GHOSTEL_WINSIZE_INIT:ROWS,COLS' at startup and
`GHOSTEL_WINSIZE_WINCH:ROWS,COLS' on every SIGWINCH, so tests can assert
the dimensions the child actually sees on each PTY backend.")

(defun ghostel-test--latest-winsize (tag)
  "Return the most recent (ROWS . COLS) reported for TAG, or nil.
Scans the terminal text for the last `GHOSTEL_WINSIZE_TAG:R,C' marker
written by `ghostel-test--pty-winsize-script'."
  (let ((text (or (ghostel--copy-all-text ghostel--term) ""))
        (re (format "GHOSTEL_WINSIZE_%s:\\([0-9]+\\),\\([0-9]+\\)" tag))
        (start 0)
        last)
    (while (string-match re text start)
      (setq last (cons (string-to-number (match-string 1 text))
                       (string-to-number (match-string 2 text)))
            start (match-end 0)))
    last))

(ert-deftest ghostel-test-get-shell-local ()
  "Test that local shell resolution returns `ghostel-shell'."
  (let ((default-directory "/tmp/")
        (ghostel-shell "/bin/zsh"))
    (should (equal "/bin/zsh" (ghostel--get-shell)))))

(ert-deftest ghostel-test-shell-program-and-args-string ()
  "String SPEC splits into (PROGRAM . nil)."
  (should (equal '("/bin/zsh") (ghostel--shell-program-and-args "/bin/zsh"))))

(ert-deftest ghostel-test-shell-program-and-args-list ()
  "List SPEC splits into (PROGRAM . ARGS)."
  (let ((split (ghostel--shell-program-and-args '("/bin/zsh" "--login" "-i"))))
    (should (equal "/bin/zsh" (car split)))
    (should (equal '("--login" "-i") (cdr split)))))

(ert-deftest ghostel-test-shell-program-and-args-invalid ()
  "Invalid SPEC signals an error."
  (should-error (ghostel--shell-program-and-args 42))
  (should-error (ghostel--shell-program-and-args nil))
  (should-error (ghostel--shell-program-and-args '()))
  (should-error (ghostel--shell-program-and-args '(nil "foo"))))

(ert-deftest ghostel-test-get-shell-local-returns-program-from-list ()
  "When `ghostel-shell' is a list, `ghostel--get-shell' returns just the program."
  (let ((default-directory "/tmp/")
        (ghostel-shell '("/bin/zsh" "--login")))
    (should (equal "/bin/zsh" (ghostel--get-shell)))))

(ert-deftest ghostel-test-macos-login-wrap-basic ()
  "Login wrap produces /usr/bin/login + bash shim with exec -l <prog>."
  (cl-letf (((symbol-function 'user-login-name) (lambda (&optional _) "alice"))
            ((symbol-function 'file-exists-p) (lambda (_) nil)))
    (let* ((wrap (ghostel--macos-login-wrap "/bin/zsh" nil))
           (program (car wrap))
           (args (cdr wrap)))
      (should (equal "/usr/bin/login" program))
      ;; No -q without hushlogin.
      (should-not (member "-q" args))
      (should (equal "-flp" (nth 0 args)))
      (should (equal "alice" (nth 1 args)))
      (should (equal "/bin/bash" (nth 2 args)))
      (should (equal "--noprofile" (nth 3 args)))
      (should (equal "--norc" (nth 4 args)))
      (should (equal "-c" (nth 5 args)))
      ;; exec -l <quoted-program>; no extra args.
      (should (equal "exec -l /bin/zsh" (nth 6 args))))))

(ert-deftest ghostel-test-macos-login-wrap-hushlogin ()
  "When ~/.hushlogin exists, -q is prepended."
  (let ((hush-path (expand-file-name "~/.hushlogin")))
    (cl-letf (((symbol-function 'user-login-name) (lambda (&optional _) "alice"))
              ((symbol-function 'file-exists-p)
               (lambda (p) (equal p hush-path))))
      (let* ((wrap (ghostel--macos-login-wrap "/bin/zsh" nil))
             (args (cdr wrap)))
        (should (equal "-q" (nth 0 args)))
        (should (equal "-flp" (nth 1 args)))
        (should (equal "alice" (nth 2 args)))))))

(ert-deftest ghostel-test-macos-login-wrap-extra-args ()
  "Extra ARGS are shell-quoted into the `exec -l' command string."
  (cl-letf (((symbol-function 'user-login-name) (lambda (&optional _) "alice"))
            ((symbol-function 'file-exists-p) (lambda (_) nil)))
    (let* ((wrap (ghostel--macos-login-wrap "/bin/bash" '("--login" "--posix")))
           (cmd (nth 6 (cdr wrap))))
      (should (equal "exec -l /bin/bash --login --posix" cmd)))))

(ert-deftest ghostel-test-start-process-darwin-login-wrap ()
  "On darwin with `ghostel-macos-login-shell', wrap shell via `/usr/bin/login'."
  (cl-letf (((symbol-function 'user-login-name) (lambda (&optional _) "alice"))
            ((symbol-function 'file-exists-p) (lambda (_) nil)))
    (ghostel-test--with-spawn-capture spawn
      (with-temp-buffer
        (setq-local ghostel--term-rows 24
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/zsh")
               (ghostel-shell-integration nil)
               (ghostel-macos-login-shell t)
               (system-type 'darwin)
               (default-directory "/tmp/"))
          (ghostel--start-process)
          (should (equal "/usr/bin/login" (car spawn)))
          (let ((args (cdr spawn)))
            (should-not (member "-q" args))
            (should (equal '("-flp" "alice"
                             "/bin/bash" "--noprofile" "--norc"
                             "-c" "exec -l /bin/zsh")
                           args))))))))

(ert-deftest ghostel-test-start-process-darwin-login-wrap-opt-out ()
  "Setting `ghostel-macos-login-shell' to nil disables the wrap on darwin."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell "/bin/zsh")
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (system-type 'darwin)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (should (equal "/bin/zsh" (car spawn)))
        (should (null (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-non-darwin-no-login-wrap ()
  "Login wrap is not applied on non-Darwin platforms even when opted in."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell "/bin/zsh")
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell t)
             (system-type 'gnu/linux)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (should (equal "/bin/zsh" (car spawn)))
        (should (null (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-list-shell-passes-args ()
  "When `ghostel-shell' is a list, extra args reach `ghostel--spawn-pty'."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell '("/bin/zsh" "--login"))
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (system-type 'gnu/linux)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (should (equal "/bin/zsh" (car spawn)))
        (should (equal '("--login") (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-list-shell-combines-with-integration ()
  "List shell args combine with bash integration's `--posix' arg."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell '("/bin/bash" "--login"))
             (ghostel-shell-integration t)
             (ghostel-macos-login-shell nil)
             (system-type 'gnu/linux)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (should (equal "/bin/bash" (car spawn)))
        ;; Extra args precede integration args.
        (should (equal '("--login" "--posix") (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-darwin-login-wrap-with-integration ()
  "Wrap + list shell + bash integration: all three layers compose correctly."
  (cl-letf (((symbol-function 'user-login-name) (lambda (&optional _) "alice"))
            ((symbol-function 'file-exists-p) (lambda (_) nil)))
    (ghostel-test--with-spawn-capture spawn
      (with-temp-buffer
        (setq-local ghostel--term-rows 24
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell '("/bin/bash" "--login"))
               (ghostel-shell-integration t)
               (ghostel-macos-login-shell t)
               (system-type 'darwin)
               (default-directory "/tmp/"))
          (ghostel--start-process)
          (should (equal "/usr/bin/login" (car spawn)))
          (should (equal '("-flp" "alice"
                           "/bin/bash" "--noprofile" "--norc"
                           "-c" "exec -l /bin/bash --login --posix")
                         (cdr spawn))))))))

(ert-deftest ghostel-test-start-process-sets-size-via-stty-not-env ()
  "Initial terminal size must be baked into the `stty' wrapper, not env vars.
Setting `LINES'/`COLUMNS' env vars freezes ncurses apps like htop at
start-up size and breaks live resize."
  (ghostel-test--with-spawn-process-capture capture
    (with-temp-buffer
      (setq-local ghostel--term-rows 43
                  ghostel--term-cols 137)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell "/bin/sh")
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (let ((cmd (plist-get capture :command))
              (env (plist-get capture :env)))
          (should (equal '("/bin/sh" "-c") (seq-take cmd 2)))
          (should (string-match-p "stty .* rows 43 columns 137"
                                  (nth 2 cmd)))
          (should (string-match-p "-ixon" (nth 2 cmd)))
          (should-not (seq-some (lambda (s) (string-prefix-p "LINES=" s))
                                env))
          (should-not (seq-some (lambda (s) (string-prefix-p "COLUMNS=" s))
                                env))
          (should (member "TERM=xterm-ghostty" env))
          (should (member "TERM_PROGRAM=ghostty" env))
          ;; Match by regex so version bumps don't break the test — the
          ;; contract is "exported and parseable as semver", not a literal string.
          (should (seq-some (lambda (s)
                              (string-match-p
                               "\\`TERM_PROGRAM_VERSION=[0-9]+\\.[0-9]+\\.[0-9]+\\'"
                               s))
                            env))
          (should (seq-some (lambda (s) (string-prefix-p "TERMINFO=" s))
                            env))
          (should (member "COLORTERM=truecolor" env)))))))

(ert-deftest ghostel-test-start-process-local-bash-integration-keeps-early-echo ()
  "Local bash integration must keep `stty echo' in the wrapper.
Old bash versions can initialize readline before the ENV-injected
integration script runs, so input echo must be enabled before exec.
`sane' in `ghostel--default-stty' is what guarantees echo here."
  (ghostel-test--with-spawn-process-capture capture
    (with-temp-buffer
      (setq-local ghostel--term-rows 25
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell "/bin/bash")
             (ghostel-shell-integration t)
             ;; Pin the wrap off so the assertion targets the un-nested local
             ;; bash invocation.  Login-wrap behavior is covered by its own
             ;; dedicated tests.
             (ghostel-macos-login-shell nil)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (let ((cmd (plist-get capture :command))
              (env (plist-get capture :env)))
          (should (equal '("/bin/sh" "-c") (seq-take cmd 2)))
          (should (string-match-p
                   (concat "stty " (regexp-quote ghostel--default-stty))
                   (nth 2 cmd)))
          (should (string-match-p "\\bsane\\b" (nth 2 cmd)))
          (should (string-match-p "exec /bin/bash --posix" (nth 2 cmd)))
          (should (member "GHOSTEL_BASH_INJECT=1" env))
          (should (seq-some (lambda (s) (string-prefix-p "ENV=" s))
                            env)))))))

(ert-deftest ghostel-test-spawn-pty-disables-adaptive-read-buffering ()
  "`ghostel--spawn-pty' must disable adaptive read buffering.
It must also raise `read-process-output-max'.  Before Emacs 31 the
former defaulted to t and throttled bursty TUI redraws."
  (ghostel-test--with-spawn-process-capture capture
    (with-temp-buffer
      (ghostel--spawn-pty "/bin/sh" nil 24 80 "-ixon" nil nil)
      (should (null (plist-get capture :adaptive)))
      (should (>= (plist-get capture :read-max) (* 1024 1024))))))

(ert-deftest ghostel-test-spawn-initial-winsize-reaches-child ()
  "The child PTY is sized to the terminal dimensions at spawn.
On the native path the PTY is opened at the term's rows/cols; on the
Emacs path `ghostel--spawn-via-emacs' calls `set-process-window-size'.
Either way the child must read those dimensions, so this drives a real
child through both backends and asserts the size it sees."
  :tags '(native)
  (let ((python (executable-find "python3")))
    (skip-unless python)
    (ghostel-test--with-pty-matrix backend
      (ghostel-test--with-exec-buffer
          (buf proc python (list "-c" ghostel-test--pty-winsize-script))
        ;; ghostel-exec sizes an undisplayed buffer's term to 80x24.
        (let ((got (ghostel-test--wait-until
                    (lambda () (ghostel-test--latest-winsize "INIT")) proc 6)))
          (should (equal (cons ghostel--term-rows ghostel--term-cols) got)))))))

(ert-deftest ghostel-test-resize-redraw-delivers-new-winsize-to-child ()
  "Resize + redraw delivers SIGWINCH carrying the NEW size to the child.
`ghostel--set-size' stages a pending resize that `ghostel--redraw'
commits; committing resizes the PTY (native `pty.resize') or calls
`set-process-window-size' (Emacs), both of which raise SIGWINCH on the
child's process group.  The child must then read the new dimensions,
not the old ones — verified on both PTY backends."
  :tags '(native)
  (let ((python (executable-find "python3")))
    (skip-unless python)
    (ghostel-test--with-pty-matrix backend
      (ghostel-test--with-exec-buffer
          (buf proc python (list "-c" ghostel-test--pty-winsize-script))
        ;; Confirm the child is up and reading the initial 80x24.
        (should (equal '(24 . 80)
                       (ghostel-test--wait-until
                        (lambda () (ghostel-test--latest-winsize "INIT")) proc 6)))
        ;; Stage a new size and commit it with a redraw, which fires SIGWINCH.
        (ghostel--set-size-with-cell-dims ghostel--term 30 100)
        (ghostel--redraw ghostel--term t)
        ;; The child's SIGWINCH handler must report the new size, not the old.
        (should (ghostel-test--wait-until
                 (lambda () (equal '(30 . 100)
                                   (ghostel-test--latest-winsize "WINCH")))
                 proc 6))))))

(ert-deftest ghostel-test-pre-spawn-hook-injects-into-process-environment ()
  "Hook `setenv' calls reach the spawned process via `process-environment'.
`ghostel-pre-spawn-hook' fires with `process-environment' dynamically
bound to the about-to-be-spawned env, so hook functions that call
`setenv' inject entries the child process actually inherits.

Contract relied on by integrations like with-editor: drive a real
`/bin/sh' through `ghostel--start-process', have the hook `setenv' a
sentinel value, and verify the value reached `make-process'.  Also
verifies the hook fires in the spawning buffer with `default-directory'
intact (with-editor's `with-editor--setup' reads `default-directory')."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (let (captured-buffer
          captured-default-directory)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell '("/bin/sh" "-c" "env; printf GHOSTEL_ENV_DONE"))
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (ghostel-kill-buffer-on-exit nil)
             (default-directory "/tmp/")
             (ghostel-pre-spawn-hook
              (list (lambda ()
                      (setq captured-buffer (current-buffer))
                      (setq captured-default-directory default-directory)
                      (setenv "GHOSTEL_PRE_SPAWN_TEST" "ok"))))
             (text (ghostel-test--with-terminal-buffer (buf term 24 80 1000)
                     (let ((test-buffer (current-buffer))
                           (proc (ghostel--start-process)))
                       (ghostel-test--wait-for-text "GHOSTEL_ENV_DONE" proc 5)
                       (should (eq captured-buffer test-buffer))
                       (ghostel-test--terminal-text)))))
        (should (equal captured-default-directory "/tmp/"))
        (should (ghostel-test--terminal-text-line-p
                 "GHOSTEL_PRE_SPAWN_TEST=ok" text))))))

(provide 'ghostel-spawn-test)
;;; ghostel-spawn-test.el ends here
