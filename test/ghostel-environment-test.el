;;; ghostel-environment-test.el --- Tests for ghostel: environment -*- lexical-binding: t; -*-

;;; Commentary:

;; Terminal environment assembly, Ghostty terminfo advertisement, SSH install
;; toggles, dir-locals safety, and user-specified environment precedence.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-start-process-respects-ghostel-term-opt-out ()
  "Setting `ghostel-term' to xterm-256color drops the Ghostty advertisement.
TERMINFO and TERM_PROGRAM must not leak through when the user opts
out — otherwise outbound `ssh' (or any consumer of those vars) would
falsely conclude that ghostty is the controlling terminal."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (let* ((process-environment (ghostel-test--base-process-environment))
           (ghostel-shell (ghostel-test--env-done-command))
           (ghostel-shell-integration nil)
           (ghostel-macos-login-shell nil)
           (ghostel-kill-buffer-on-exit nil)
           (ghostel-term "xterm-256color")
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test--start-process-and-wait-for-text
                  "GHOSTEL_ENV_DONE" 25 80 5)))
      (should (ghostel-test--terminal-text-line-p "TERM=xterm-256color" text))
      (should (ghostel-test--terminal-text-line-p "COLORTERM=truecolor" text))
      (should-not (ghostel-test--terminal-text-line-prefix-p "TERMINFO=" text))
      (should-not (ghostel-test--terminal-text-line-p "TERM_PROGRAM=ghostty" text))
      (should-not (ghostel-test--terminal-text-line-prefix-p
                   "TERM_PROGRAM_VERSION=" text)))))

(ert-deftest ghostel-test-start-process-ssh-install-exports-env ()
  "`ghostel-ssh-install-terminfo' must export GHOSTEL_SSH_INSTALL_TERMINFO=1.
The bundled bash/zsh/fish integration scripts gate the outbound
`ssh' install-and-cache wrapper on this env var, so the elisp custom
is the single source of truth.

The `auto' default follows `ghostel-tramp-shell-integration': enabled
when that's non-nil, off otherwise.  Setting it to t forces on,
setting it to nil forces off."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (let* ((process-environment (ghostel-test--base-process-environment))
           (ghostel-shell (ghostel-test--env-done-command))
           (ghostel-shell-integration nil)
           (ghostel-macos-login-shell nil)
           (ghostel-kill-buffer-on-exit nil)
           (default-directory (ghostel-test--temp-directory)))
      ;; auto + tramp-shell-integration nil → not exported.
      (let* ((ghostel-ssh-install-terminfo 'auto)
             (ghostel-tramp-shell-integration nil)
             (text (ghostel-test--start-process-and-wait-for-text
                    "GHOSTEL_ENV_DONE" 25 80 5)))
        (should-not (ghostel-test--terminal-text-line-p
                     "GHOSTEL_SSH_INSTALL_TERMINFO=1" text)))
      ;; auto + tramp-shell-integration t → exported.
      (let* ((ghostel-ssh-install-terminfo 'auto)
             (ghostel-tramp-shell-integration t)
             (text (ghostel-test--start-process-and-wait-for-text
                    "GHOSTEL_ENV_DONE" 25 80 5)))
        (should (ghostel-test--terminal-text-line-p
                 "GHOSTEL_SSH_INSTALL_TERMINFO=1" text)))
      ;; Forced on.
      (let* ((ghostel-ssh-install-terminfo t)
             (ghostel-tramp-shell-integration nil)
             (text (ghostel-test--start-process-and-wait-for-text
                    "GHOSTEL_ENV_DONE" 25 80 5)))
        (should (ghostel-test--terminal-text-line-p
                 "GHOSTEL_SSH_INSTALL_TERMINFO=1" text)))
      ;; Forced off (overrides tramp-shell-integration).
      (let* ((ghostel-ssh-install-terminfo nil)
             (ghostel-tramp-shell-integration t)
             (text (ghostel-test--start-process-and-wait-for-text
                    "GHOSTEL_ENV_DONE" 25 80 5)))
        (should-not (ghostel-test--terminal-text-line-p
                     "GHOSTEL_SSH_INSTALL_TERMINFO=1" text)))
      ;; Local TERM opt-out (`ghostel-term' /= xterm-ghostty)
      ;; suppresses the SSH-install advertisement even when forced
      ;; on — otherwise outbound ssh would falsely claim ghostty
      ;; while the local buffer is plain xterm-256color.
      (let* ((ghostel-term "xterm-256color")
             (ghostel-ssh-install-terminfo t)
             (ghostel-tramp-shell-integration t)
             (text (ghostel-test--start-process-and-wait-for-text
                    "GHOSTEL_ENV_DONE" 25 80 5)))
        (should-not (ghostel-test--terminal-text-line-p
                     "GHOSTEL_SSH_INSTALL_TERMINFO=1" text)))
      ;; Bundled terminfo missing (e.g. broken install): the env
      ;; helper falls back to TERM=xterm-256color *and* must
      ;; suppress GHOSTEL_SSH_INSTALL_TERMINFO so the wrapper
      ;; doesn't try to advertise xterm-ghostty over ssh.
      (cl-letf (((symbol-function #'ghostel--terminfo-directory)
                 (lambda () nil))
                ;; Suppress the one-shot fallback warning during
                ;; the test so it doesn't pollute output.
                (ghostel--terminfo-warned t))
        (let* ((ghostel-term "xterm-ghostty")
               (ghostel-ssh-install-terminfo t)
               (ghostel-tramp-shell-integration t)
               (text (ghostel-test--start-process-and-wait-for-text
                      "GHOSTEL_ENV_DONE" 25 80 5)))
          (should (ghostel-test--terminal-text-line-p "TERM=xterm-256color" text))
          (should-not (ghostel-test--terminal-text-line-p
                       "GHOSTEL_SSH_INSTALL_TERMINFO=1" text)))))))

(ert-deftest ghostel-test-environment-precedes-internal-env ()
  "`ghostel-environment' entries must come before ghostel's own env vars.
When a user sets TERM via `ghostel-environment', it must win over the
internal `TERM=xterm-ghostty' so a `process-environment' lookup (which
returns the first match) resolves to the user's value."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (let* ((process-environment (ghostel-test--base-process-environment))
           (ghostel-shell (ghostel-test--env-done-command))
           (ghostel-shell-integration nil)
           (ghostel-macos-login-shell nil)
           (ghostel-kill-buffer-on-exit nil)
           (ghostel-environment '("TERM=dumb" "MY_VAR=42"))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test--start-process-and-wait-for-text
                  "GHOSTEL_ENV_DONE" 25 80 5)))
      (should (ghostel-test--terminal-text-line-p "MY_VAR=42" text))
      (should (ghostel-test--terminal-text-line-p "TERM=dumb" text))
      (should-not (ghostel-test--terminal-text-line-p
                   "TERM=xterm-ghostty" text)))))

(ert-deftest ghostel-test-spawn-env-injects-logical-pwd ()
  "Local spawns carry a PWD entry naming the logical `default-directory'.
Shells keep an inherited PWD that names the cwd (same inode) and
otherwise reset it from getcwd(), which resolves symlinks — with a
stale or missing PWD, a shell started in a symlinked directory shows
the physical path in its prompt and OSC 7.  The injected entry must
override a stale inherited PWD, while a user PWD in
`ghostel-environment' must win over the injected one."
  :tags '(posix)
  (let* ((captured nil)
         (ghostel-shell "/bin/sh")
         (ghostel-shell-integration nil)
         (ghostel-macos-login-shell nil)
         (default-directory (ghostel-test--temp-directory))
         (process-environment (cons "PWD=/ghostel/stale"
                                    process-environment))
         (ghostel-pre-spawn-hook
          (list (lambda () (setq captured (getenv "PWD"))))))
    (cl-letf (((symbol-function 'ghostel--spawn-process)
               (lambda (&rest _) nil)))
      (ghostel--start-process)
      (should (equal captured
                     (directory-file-name
                      (expand-file-name default-directory))))
      (let ((ghostel-environment '("PWD=/ghostel/user-override")))
        (ghostel--start-process))
      (should (equal captured "/ghostel/user-override")))))

(ert-deftest ghostel-test-logical-pwd-env ()
  "No PWD entry for remote spawns or on Windows."
  (let ((system-type 'gnu/linux))
    (should-not (ghostel--logical-pwd-env t)))
  (let ((system-type 'windows-nt))
    (should-not (ghostel--logical-pwd-env nil))))

(ert-deftest ghostel-test-spawn-symlinked-dir-child-sees-logical-pwd ()
  "A child spawned in a symlinked directory sees the logical path in PWD.
End-to-end over both PTY backends: the injected PWD overrides a stale
inherited one, survives the spawn and the shell's same-inode
validation, and an OSC 7 report built from the child's $PWD keeps
`default-directory' on the logical path instead of the
getcwd()-resolved physical one."
  :tags '(native posix)
  (ghostel-test--with-pty-matrix backend
    (let* ((target (make-temp-file "ghostel-pwd-target" t))
           (link (make-temp-name
                  (expand-file-name "ghostel-pwd-link"
                                    (ghostel-test--temp-directory)))))
      (unwind-protect
          (progn
            (make-symbolic-link target link)
            (let* ((process-environment
                    (cons "PWD=/ghostel/stale-physical"
                          (ghostel-test--base-process-environment)))
                   (ghostel-shell
                    '("/bin/sh" "-c"
                      "printf '\\033]7;file://%s\\033\\\\' \"$PWD\"; \
env; printf GHOSTEL_ENV_DONE"))
                   (ghostel-shell-integration nil)
                   (ghostel-macos-login-shell nil)
                   (ghostel-kill-buffer-on-exit nil)
                   (default-directory (file-name-as-directory link)))
              (ghostel-test--with-terminal-buffer (buf _term 25 200 1000)
                (let ((proc (ghostel--start-process)))
                  ;; Sentinel: the buffer inherits the link path at
                  ;; creation, so the OSC 7 wait below would otherwise be
                  ;; satisfied before any report arrives.  Safe to set
                  ;; here — filters only run inside
                  ;; `accept-process-output', so no output has been
                  ;; processed yet.
                  (setq default-directory "/")
                  (ghostel-test--wait-for-text "GHOSTEL_ENV_DONE" proc 5)
                  (should (ghostel-test--terminal-text-line-p
                           (format "PWD=%s" link)))
                  ;; OSC events can trail the text on the native backend.
                  (ghostel-test--wait-until
                   (lambda () (equal default-directory
                                     (file-name-as-directory link)))
                   proc 5)))))
        (ignore-errors (delete-file link))
        (ignore-errors (delete-directory target t))))))

(ert-deftest ghostel-test-compile-spawn-env-injects-logical-pwd ()
  "`ghostel-compile--spawn' children also get the logical PWD entry."
  (let ((captured 'unset)
        (buf (generate-new-buffer " *ghostel-compile-pwd*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((default-directory (ghostel-test--temp-directory))
                (process-environment (cons "PWD=/ghostel/stale"
                                           process-environment)))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _)
                         (setq captured (getenv "PWD"))
                         (ghostel-test--dummy-process "compile-pwd" nil)))
                      ((symbol-function 'set-process-window-size) #'ignore))
              (ghostel-compile--spawn "true" buf 24 80))
            (should (equal captured
                           (directory-file-name
                            (expand-file-name default-directory))))))
      (let ((proc (buffer-local-value 'ghostel--process buf)))
        (when (processp proc) (delete-process proc)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-environment-honors-dir-locals ()
  "End-to-end: a real `.dir-locals.el' populates `ghostel-environment'.
Covers the whole pipeline (`hack-dir-local-variables' reading the
file, the safety gate, and buffer-local assignment) — not just the
final `setq-local'."
  (let* ((dir (file-name-as-directory (make-temp-file "ghostel-dl-" t)))
         (dl  (expand-file-name ".dir-locals.el" dir))
         (buf (generate-new-buffer " *ghostel-dl-test*")))
    (unwind-protect
        (progn
          (with-temp-file dl
            (insert
             "((ghostel-mode . ((ghostel-environment . (\"FOO=1\" \"BAR=2\")))))"))
          (with-current-buffer buf
            (setq-local default-directory dir)
            (ghostel-mode)
            (should (local-variable-p 'ghostel-environment))
            (should (equal ghostel-environment '("FOO=1" "BAR=2")))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-environment-rejects-unsafe-dir-locals ()
  "An unsafe `ghostel-environment' value in dir-locals must be rejected.
Guards against a malicious `.dir-locals.el' that tries to smuggle a
non-list/non-string value past the usual `safe-local-variable-p'
machinery."
  (let ((buf (generate-new-buffer " *ghostel-unsafe-test*")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'hack-dir-local-variables)
                     (lambda ()
                       (setq-local dir-local-variables-alist
                                   '((ghostel-environment . "not-a-list"))))))
            (ghostel-mode))
          (should-not (local-variable-p 'ghostel-environment)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-terminfo-directory-finds-bundled ()
  "`ghostel--terminfo-directory' must locate the bundled compiled entries.
The package ships compiled terminfo for both macOS (78/) and Linux (x/)
layouts; if neither is present after install, the lookup must return
nil so the fallback warning fires."
  (let ((dir (ghostel--terminfo-directory)))
    (should dir)
    (should (file-directory-p dir))
    (should (or (file-readable-p (expand-file-name "78/xterm-ghostty" dir))
                (file-readable-p (expand-file-name "x/xterm-ghostty" dir))))))

(provide 'ghostel-environment-test)
;;; ghostel-environment-test.el ends here
