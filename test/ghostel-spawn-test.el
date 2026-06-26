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
CAPTURE is set to a plist with the spawned :program and :args,
:remote-p, the `process-environment', the buffering bindings, the
current :buffer, and `default-directory' observed at
`ghostel--spawn-process' \(the single dispatcher over the native/Emacs
spawners).  The dispatcher is stubbed, so no process is spawned.

The dispatcher sees the same program/args/env for both backends — only
how they reach the PTY differs (native execs directly; the Emacs path
wraps them in `/bin/sh -c', see
`ghostel-test-spawn-via-emacs-builds-stty-wrapper') — so there is no
need to exercise the PTY matrix here."
  (declare (indent 1))
  `(let (,capture)
     (cl-letf (((symbol-function 'ghostel--spawn-process)
                (lambda (program program-args remote-p)
                  (setq ,capture
                        (list :program program
                              :args (copy-tree program-args)
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

(defconst ghostel-test--pty-read-dc1-script
  (string-join
   '("import sys"
     ;; Announce readiness only after the PTY is configured (the Emacs
     ;; path runs `stty -ixon' before exec'ing us), so the test knows
     ;; when it is safe to send C-q without racing the flag setup.
     "sys.stdout.write('GHOSTEL_READY\\r\\n')"
     "sys.stdout.flush()"
     "line = sys.stdin.buffer.readline()"
     "tag = 'DC1' if b'\\x11' in line else 'NONE'"
     "sys.stdout.write('GHOSTEL_GOTBYTE:%s\\r\\n' % tag)"
     "sys.stdout.flush()")
   "\n")
  "Python code that reads one cooked-mode line from its PTY and reports it.
Writes `GHOSTEL_READY' once its PTY is set up, then `GHOSTEL_GOTBYTE:DC1'
if the line it reads contained a DC1 byte (0x11) or
`GHOSTEL_GOTBYTE:NONE' otherwise.  With XON/XOFF flow control (`ixon')
enabled, the line discipline swallows DC1 before the child sees it, so
this distinguishes a PTY that honors `-ixon' from one that does not.")

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

;;; Remote shell spec resolution (issue #444)

(ert-deftest ghostel-test-default-remote-shell-args-recognized ()
  "Recognized remote shells default to login+interactive args."
  (should (equal '("-l" "-i") (ghostel--default-remote-shell-args "/bin/zsh")))
  (should (equal '("-l" "-i") (ghostel--default-remote-shell-args "/bin/bash")))
  (should (equal '("-l" "-i") (ghostel--default-remote-shell-args "/usr/bin/fish")))
  ;; NixOS-style path: detection keys off the basename.
  (should (equal '("-l" "-i")
                 (ghostel--default-remote-shell-args
                  "/run/current-system/sw/bin/zsh"))))

(ert-deftest ghostel-test-default-remote-shell-args-unrecognized ()
  "Unrecognized remote shells get no default args (they may reject -l)."
  (should-not (ghostel--default-remote-shell-args "/bin/sh"))
  (should-not (ghostel--default-remote-shell-args "/bin/dash")))

(ert-deftest ghostel-test-default-remote-shell-args-integration ()
  "With integration active, bash drops `-l'; zsh/fish keep login+interactive."
  ;; Bash: `-l' would make login bash ignore integration's `--rcfile'.
  (should (equal '("-i") (ghostel--default-remote-shell-args "/bin/bash" t)))
  ;; Zsh and fish compose cleanly with `-l -i'.
  (should (equal '("-l" "-i") (ghostel--default-remote-shell-args "/usr/bin/zsh" t)))
  (should (equal '("-l" "-i") (ghostel--default-remote-shell-args "/usr/bin/fish" t)))
  ;; Unrecognized shells still get nothing.
  (should-not (ghostel--default-remote-shell-args "/bin/sh" t)))

(ert-deftest ghostel-test-tramp-shell-spec-explicit-args ()
  "Explicit args after the fallback slot are returned in the spec."
  (let ((ghostel-tramp-shells '(("ssh" "/bin/zsh" nil "-i" "-l"))))
    (should (equal '("/bin/zsh" "-i" "-l") (ghostel--tramp-shell-spec "ssh")))))

(ert-deftest ghostel-test-tramp-shell-spec-no-args ()
  "An entry without an args slot yields no extra args."
  (let ((ghostel-tramp-shells '(("docker" "/bin/sh"))))
    (should (equal '("/bin/sh") (ghostel--tramp-shell-spec "docker"))))
  (let ((ghostel-tramp-shells '(("ssh" "/bin/zsh"))))
    (should (equal '("/bin/zsh") (ghostel--tramp-shell-spec "ssh")))))

(ert-deftest ghostel-test-tramp-shell-spec-unknown-method ()
  "An unknown method resolves to nil."
  (let ((ghostel-tramp-shells '(("ssh" "/bin/zsh"))))
    (should-not (ghostel--tramp-shell-spec "docker"))))

(ert-deftest ghostel-test-tramp-shell-spec-login-shell-fallback-args ()
  "Login-shell detection failure falls back, preserving explicit args."
  (cl-letf (((symbol-function 'process-file-shell-command)
             (lambda (&rest _) 1)))     ; simulate getent failure
    (let ((ghostel-tramp-shells '(("ssh" login-shell "/bin/sh" "-i"))))
      (should (equal '("/bin/sh" "-i") (ghostel--tramp-shell-spec "ssh"))))))

(ert-deftest ghostel-test-resolve-shell-spec-remote-default-no-args ()
  "Remote resolve returns the program alone when no explicit args are configured.
The type-aware default is applied later, at spawn time."
  (let ((default-directory "/ssh:host:/home/u/")
        (ghostel-tramp-shells '(("ssh" "/bin/zsh"))))
    (should (equal '("/bin/zsh") (ghostel--resolve-shell-spec)))))

(ert-deftest ghostel-test-start-process-remote-adds-login-interactive ()
  "A recognized remote shell is started login+interactive by default."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-tramp-shells '(("ssh" "/bin/zsh")))
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (default-directory "/ssh:host:/home/u/"))
        (ghostel--start-process)
        (should (equal "/bin/zsh" (car spawn)))
        (should (equal '("-l" "-i") (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-remote-unrecognized-no-args ()
  "An unrecognized remote shell gets no auto args."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-tramp-shells '(("ssh" "/bin/sh")))
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (default-directory "/ssh:host:/home/u/"))
        (ghostel--start-process)
        (should (equal "/bin/sh" (car spawn)))
        (should-not (cdr spawn))))))

(ert-deftest ghostel-test-start-process-remote-explicit-args-override ()
  "Explicit per-method args replace the type-aware default."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-tramp-shells '(("ssh" "/bin/zsh" nil "-i")))
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (default-directory "/ssh:host:/home/u/"))
        (ghostel--start-process)
        (should (equal "/bin/zsh" (car spawn)))
        (should (equal '("-i") (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-remote-bash-integration-interactive-no-login ()
  "Bash integration: shell is made interactive (`-i') but not login.
A login bash ignores the `--rcfile' the bash integration relies on, so
`-l' must be omitted; `-i' is still added so the rcfile (and the user's
`~/.bashrc') loads on TRAMP methods where the remote stdin isn't a tty."
  (cl-letf (((symbol-function 'ghostel--setup-remote-integration)
             (lambda (_type)
               (list :env nil :args '("--rcfile" "/tmp/ghostel.bash")
                     :temp-files nil :temp-dirs nil))))
    (ghostel-test--with-spawn-capture spawn
      (with-temp-buffer
        (setq-local ghostel--term-rows 24
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-tramp-shells '(("ssh" "/bin/bash")))
               (ghostel-shell-integration t)
               (ghostel-tramp-shell-integration t)
               (ghostel-macos-login-shell nil)
               (default-directory "/ssh:host:/home/u/"))
          (ghostel--start-process)
          (should (equal "/bin/bash" (car spawn)))
          ;; Bash rejects long options that follow short ones, so the
          ;; integration's `--rcfile' must precede the `-i' default.
          (should (equal '("--rcfile" "/tmp/ghostel.bash" "-i") (cdr spawn)))
          (should-not (member "-l" (cdr spawn))))))))

(ert-deftest ghostel-test-start-process-remote-zsh-integration-login-interactive ()
  "Zsh integration: the shell still starts login+interactive (`-l -i').
`-l -i' composes cleanly with the ZDOTDIR-based zsh integration, so the
user's `.zprofile'/`.zshrc' load alongside it."
  (cl-letf (((symbol-function 'ghostel--setup-remote-integration)
             (lambda (_type)
               (list :env '("ZDOTDIR=/tmp/ghostel-zdot") :args nil
                     :temp-files nil :temp-dirs nil))))
    (ghostel-test--with-spawn-capture spawn
      (with-temp-buffer
        (setq-local ghostel--term-rows 24
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-tramp-shells '(("ssh" "/usr/bin/zsh")))
               (ghostel-shell-integration t)
               (ghostel-tramp-shell-integration t)
               (ghostel-macos-login-shell nil)
               (default-directory "/ssh:host:/home/u/"))
          (ghostel--start-process)
          (should (equal "/usr/bin/zsh" (car spawn)))
          (should (equal '("-l" "-i") (cdr spawn))))))))

(ert-deftest ghostel-test-start-process-remote-defers-temp-cleanup ()
  "Remote integration temp paths are cleaned on buffer-kill, not at spawn.
Deleting them at spawn time would race the just-spawned async remote
shell, which has not yet read its bootstrap (ZDOTDIR/.zshenv etc.); the
pushed terminfo dir is needed for the whole session besides."
  (let (cleaned)
    (cl-letf (((symbol-function 'ghostel--setup-remote-integration)
               (lambda (_type)
                 (list :env nil :args nil
                       :temp-files '("/tmp/ghostel-x.zsh")
                       :temp-dirs '("/tmp/ghostel-zdot"))))
              ((symbol-function 'ghostel--cleanup-temp-paths)
               (lambda (files dirs) (setq cleaned (list files dirs))))
              ((symbol-function 'ghostel--spawn-pty) (lambda (&rest _) nil)))
      (let ((buf (generate-new-buffer " *ghostel-test-defer*")))
        (unwind-protect
            (progn
              (with-current-buffer buf
                (setq-local ghostel--term-rows 24
                            ghostel--term-cols 80)
                (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
                       (ghostel-tramp-shells '(("ssh" "/usr/bin/zsh")))
                       (ghostel-shell-integration t)
                       (ghostel-tramp-shell-integration t)
                       (ghostel-macos-login-shell nil)
                       (default-directory "/ssh:host:/home/u/"))
                  (ghostel--start-process)))
              ;; Not deleted at spawn time.
              (should-not cleaned)
              ;; Buffer-kill triggers the deferred cleanup with the paths.
              (kill-buffer buf)
              (should (equal cleaned
                             '(("/tmp/ghostel-x.zsh") ("/tmp/ghostel-zdot")))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

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
        ;; Integration args precede extra args.
        (should (equal '("--posix" "--login") (cdr spawn)))))))

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
                           "-c" "exec -l /bin/bash --posix --login")
                         (cdr spawn))))))))

(ert-deftest ghostel-test-start-process-local-bash-integration-adds-env ()
  "Local bash integration adds `--posix' and ENV injection for bash."
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
        (let ((env (plist-get capture :env)))
          (should (equal "/bin/bash" (plist-get capture :program)))
          (should (equal '("--posix") (plist-get capture :args)))
          (should (member "GHOSTEL_BASH_INJECT=1" env))
          (should (seq-some (lambda (s) (string-prefix-p "ENV=" s))
                            env)))))))

(ert-deftest ghostel-test-spawn-pty-disables-adaptive-read-buffering ()
  "`ghostel--spawn-pty' must disable adaptive read buffering.
It must also raise `read-process-output-max'.  Before Emacs 31 the
former defaulted to t and throttled bursty TUI redraws."
  (ghostel-test--with-spawn-process-capture capture
    (with-temp-buffer
      (ghostel--spawn-pty "/bin/sh" nil nil nil)
      (should (null (plist-get capture :adaptive)))
      (should (>= (plist-get capture :read-max) (* 1024 1024))))))

(ert-deftest ghostel-test-spawn-emacs-pty-enables-input-echo ()
  "The Emacs PTY path enables input echo before PROGRAM reads."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (let ((ghostel-use-native-pty nil))
    (ghostel-test--with-terminal-buffer (buf term 8 80 200)
      (let ((proc (ghostel--spawn-pty
                   "/bin/sh"
                   '("-c" "printf 'GHOSTEL_ECHO_READY\r\n'; IFS= read -r _line; printf 'GHOSTEL_ECHO_DONE\r\n'")
                   nil nil)))
        (ghostel-test--wait-for-text "GHOSTEL_ECHO_READY" proc 5)
        (ghostel--write-pty ghostel--term "GHOSTEL_ECHO_TOKEN\r")
        (ghostel-test--wait-for-text "GHOSTEL_ECHO_DONE" proc 5)
        (should (string-match-p "GHOSTEL_ECHO_TOKEN"
                                (ghostel-test--terminal-text)))))))

(ert-deftest ghostel-test-spawn-process-resolves-bare-program-from-exec-path ()
  "A bare local PROGRAM resolves via variable `exec-path' before backend dispatch.
This deliberately makes variable `exec-path' and the child PATH disagree: the
probe program exists only on variable `exec-path', not in `process-environment'."
  :tags '(native)
  (let* ((dir (file-name-as-directory (make-temp-file "ghostel-path-" t)))
         (exec-dir (directory-file-name dir))
         (program-name "ghostel-path-probe")
         (program-path (expand-file-name program-name dir)))
    (unwind-protect
        (progn
          (with-temp-file program-path
            (insert "#!/bin/sh\nprintf 'GHOSTEL_PATH_PROBE:%s\\n' \"$0\"\n"))
          (set-file-modes program-path #o755)
          (ghostel-test--with-pty-matrix backend
            (let* ((child-path (string-join '("/usr/bin" "/bin")
                                             path-separator))
                   (process-environment `(,(format "PATH=%s" child-path) "HOME=/tmp"))
                   (exec-path (list exec-dir "/usr/bin" "/bin"))
                   (ghostel-kill-buffer-on-exit nil)
                   (default-directory "/tmp/"))
              (should-not (member exec-dir
                                  (split-string (getenv "PATH") path-separator t)))
              (let ((found (executable-find program-name)))
                (should found)
                (should (file-equal-p program-path found)))
              (ghostel-test--with-terminal-buffer (buf term 24 80 1000)
                (let ((proc (ghostel--spawn-process program-name nil nil)))
                  (ghostel-test--wait-for-text "GHOSTEL_PATH_PROBE:" proc 3)
                  (should (ghostel-test--terminal-text-line-p
                           (format "GHOSTEL_PATH_PROBE:%s" program-path))))))))
      (delete-directory dir t))))

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

(ert-deftest ghostel-test-spawn-ixon-disabled-c-q-reaches-child ()
  "DC1 (0x11) reaches the child instead of being eaten by XON/XOFF flow control.
With `ixon' enabled (the PTY default) the line discipline swallows
DC1 and DC3; ghostel disables it — natively in C
\(`PtyProcess'), and via `-ixon' in the Emacs-path `stty' wrapper — so
the direct key binding and send-next-key can deliver these bytes.
Driven through both PTY backends."
  :tags '(native)
  (let ((python (executable-find "python3")))
    (skip-unless python)
    (ghostel-test--with-pty-matrix backend
      (ghostel-test--with-exec-buffer
          (buf proc python (list "-c" ghostel-test--pty-read-dc1-script))
        ;; Wait until the child has configured its PTY and is reading,
        ;; so `-ixon' is in effect before C-q arrives (otherwise the
        ;; byte races the Emacs-path `stty' and is eaten while IXON is
        ;; still on).
        (should (ghostel-test--wait-for-text "GHOSTEL_READY" proc 6))
        ;; Send C-q (DC1, 0x11) then Enter to flush the cooked-mode line.
        (ghostel--write-pty ghostel--term (string ?\C-q ?\r))
        (let ((report (ghostel-test--wait-until
                       (lambda ()
                         (let ((txt (ghostel-test--terminal-text)))
                           (and (string-match-p "GHOSTEL_GOTBYTE:" txt) txt)))
                       proc 6)))
          (should (string-match-p "GHOSTEL_GOTBYTE:DC1" report)))))))

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
        (ghostel-test--redraw ghostel--term t)
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

(ert-deftest ghostel-test-child-cwd-follows-default-directory-with-tilde ()
  "Child process starts in `default-directory', including abbreviated home paths."
  :tags '(native)
  (let* ((home-dir (file-name-as-directory (expand-file-name "~")))
         (test-dir (file-name-directory
                    (or (locate-library "ghostel-spawn-test")
                        buffer-file-name
                        default-directory)))
         (tmpdir (file-name-as-directory
                  (make-temp-file (expand-file-name "ghostel-cwd-test-"
                                                     test-dir)
                                  t)))
         (default-directory (abbreviate-file-name tmpdir))
         (expected-cwd (directory-file-name (file-truename tmpdir))))
    (unwind-protect
        (progn
          (should (string-prefix-p "~/" default-directory))
          (ghostel-test--with-pty-matrix backend
            (let* ((process-environment
                    `(,(format "HOME=%s" (directory-file-name home-dir))
                      "PATH=/usr/bin:/bin"))
                   (ghostel-shell
                    '("/bin/sh" "-c"
                      "printf 'GHOSTEL_CWD:%s\\n' \"$(pwd -P)\"; printf GHOSTEL_CWD_DONE"))
                   (ghostel-shell-integration nil)
                   (ghostel-macos-login-shell nil)
                   (ghostel-kill-buffer-on-exit nil)
                   (text (ghostel-test--start-process-and-wait-for-text
                          "GHOSTEL_CWD_DONE")))
              (should (ghostel-test--terminal-text-line-p
                       (format "GHOSTEL_CWD:%s" expected-cwd)
                       text)))))
      (delete-directory tmpdir t))))

(provide 'ghostel-spawn-test)
;;; ghostel-spawn-test.el ends here
