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
