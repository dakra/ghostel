;;; ghostel-tramp-test.el --- Tests for ghostel: tramp -*- lexical-binding: t; -*-

;;; Commentary:

;; TRAMP integration and remote process environment plumbing.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-remote-term-preamble ()
  "`ghostel--remote-term-preamble' embeds an `infocmp' probe.
The probe runs *on the remote* (inside the per-spawn wrapper), so
TERM is decided after env propagation — sidestepping
`tramp-local-environment-variable-p', which would otherwise strip
`TERM=' entries that match the local default top-level
`process-environment' and leave the remote shell to inherit
TERM=dumb (issue #224).

A single probe path covers every case: auto-integration (TERMINFO=
already in env, points at the pushed terminfo dir),
manually-installed (system, `~/.terminfo', or co-located with the
shell-integration scripts under `~/.local/share/ghostel/terminfo'),
and absent (fall back to `xterm-256color' so echo works)."
  (let* ((ghostel-term "xterm-ghostty")
         (preamble (ghostel--remote-term-preamble)))
    ;; Default value for the case infocmp fails.
    (should (string-match-p "\\bTERM=xterm-256color;" preamble))
    ;; Probe and conditional upgrade.
    (should (string-match-p "infocmp xterm-ghostty" preamble))
    (should (string-match-p "\\bTERM=xterm-ghostty;" preamble))
    (should (string-match-p "TERM_PROGRAM=ghostty;" preamble))
    (should (string-match-p "TERM_PROGRAM_VERSION=" preamble))
    ;; Co-located bundle gets prepended to TERMINFO_DIRS — so a
    ;; user can `scp` the terminfo dir alongside the shell
    ;; scripts and the probe finds it without `tic` or
    ;; ~/.terminfo gymnastics.
    (should (string-match-p
             "~/\\.local/share/ghostel/terminfo/x/xterm-ghostty"
             preamble))
    (should (string-match-p
             "~/\\.local/share/ghostel/terminfo/78/xterm-ghostty"
             preamble))
    (should (string-match-p
             (regexp-quote
              "TERMINFO_DIRS=~/.local/share/ghostel/terminfo")
             preamble))
    ;; Existing TERMINFO_DIRS must be preserved (prepend, not
    ;; replace) so a system-configured search list still works.
    (should (string-match-p (regexp-quote "${TERMINFO_DIRS:+:$TERMINFO_DIRS}")
                            preamble))
    ;; Order is load-bearing: the TERMINFO_DIRS prepend must run
    ;; BEFORE the `infocmp' probe, otherwise ncurses won't find the
    ;; co-located bundle and the probe falls back to xterm-256color.
    (should (< (string-match (regexp-quote
                              "TERMINFO_DIRS=~/.local/share/ghostel/terminfo")
                             preamble)
               (string-match "infocmp xterm-ghostty" preamble)))
    ;; Always exported.
    (should (string-match-p "COLORTERM=truecolor" preamble))
    (should (string-match-p "export TERM COLORTERM" preamble)))
  ;; Customized `ghostel-term' is honored verbatim — no probe, no
  ;; ghostty advertisement, no TERMINFO_DIRS munging.
  (let* ((ghostel-term "xterm-256color")
         (preamble (ghostel--remote-term-preamble)))
    (should-not (string-match-p "infocmp" preamble))
    (should-not (string-match-p "TERM_PROGRAM=ghostty" preamble))
    (should-not (string-match-p "TERMINFO_DIRS" preamble))
    (should (string-match-p "TERM=xterm-256color" preamble))
    (should (string-match-p "COLORTERM=truecolor" preamble)))
  (let* ((ghostel-term "screen-256color")
         (preamble (ghostel--remote-term-preamble)))
    (should-not (string-match-p "infocmp" preamble))
    (should (string-match-p "TERM=screen-256color" preamble))))

(ert-deftest ghostel-test-spawn-pty-uses-remote-term-preamble ()
  "`ghostel--spawn-pty' embeds the remote preamble in the wrapper script.
The preamble runs on the remote, so TERM is set after TRAMP's
env propagation — sidestepping `tramp-local-environment-variable-p'
which would otherwise strip `TERM=' entries that match the local
default toplevel and leave the remote shell with TERM=dumb (#224).

Local spawns must not get the preamble; their TERM still rides in
`process-environment' via `ghostel--terminal-env'."
  (let ((ghostel-term "xterm-ghostty")
        (ghostel-use-native-pty nil)
        (ghostel-environment nil)
        captured-env
        captured-cmd)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq captured-env (copy-sequence process-environment)
                       captured-cmd (plist-get args :command))
                 'fake-proc))
              ((symbol-function 'process-id) (lambda (_proc) 12345))
              ((symbol-function 'set-process-coding-system) #'ignore)
              ((symbol-function 'set-process-window-size) #'ignore)
              ((symbol-function 'process-put) #'ignore))
      ;; Remote spawn → preamble in wrapper, TERM/TERMINFO not
      ;; added by ghostel.  Use a clean `process-environment' so
      ;; the assertion is about ghostel's contribution, not the
      ;; test runner's ambient env.
      (let ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp")))
        (ghostel--spawn-pty "/bin/sh" nil nil t)
        (let ((script (nth 2 captured-cmd)))
          (should (string-match-p "infocmp xterm-ghostty" script))
          (should (string-match-p "export TERM COLORTERM" script))
          ;; Ghostel must not push the local TERMINFO path —
          ;; it points at a dir the remote can't read and
          ;; (per terminfo(5)) suppresses system lookups.
          (should-not (seq-some
                       (lambda (s) (string-prefix-p "TERMINFO=" s))
                       captured-env))
          ;; TERM also stays out of env — wrapper handles it.
          (should-not (member "TERM=xterm-ghostty" captured-env))))
      ;; Local spawn → no preamble, env-driven TERM.
      (setq captured-env nil
            captured-cmd nil)
      (let ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp")))
        (ghostel--spawn-pty "/bin/sh" nil nil nil)
        (let ((script (nth 2 captured-cmd)))
          (should-not (string-match-p "infocmp" script))
          (should (member "TERM=xterm-ghostty" captured-env)))))))

(ert-deftest ghostel-test-tramp-inside-emacs-preserves-ghostel-prefix ()
  "TRAMP rewrites INSIDE_EMACS but must preserve the user-set prefix.
The README's manual remote-integration gate
  [[ \"${INSIDE_EMACS%%,*}\" = \\='ghostel\\=' ]]
relies on `tramp-inside-emacs' appending `,tramp:VER' to the
existing `INSIDE_EMACS' value rather than wholly overwriting it.
If TRAMP ever changes that contract, the gate silently stops
matching on TRAMP-launched ghostel remotes — this canary catches it."
  (require 'tramp)
  (let ((process-environment
         (cons "INSIDE_EMACS=ghostel" process-environment)))
    (let ((rewritten (tramp-inside-emacs)))
      (should (string-prefix-p "ghostel," rewritten))
      (should (string-match-p ",tramp:" rewritten)))))

(ert-deftest ghostel-test-update-directory-remote ()
  "Test TRAMP path construction from remote OSC 7."
  ;; Remote hostname -> TRAMP path using tramp-default-method fallback
  (let ((ghostel--last-directory nil)
        (default-directory "/tmp/")
        (ghostel-tramp-default-method nil)
        (tramp-default-method "ssh"))
    (ghostel--update-directory "file://remote-host/home/user")
    (should (equal "/ssh:remote-host:/home/user/" default-directory)))
  ;; ghostel-tramp-default-method takes precedence over tramp-default-method
  (let ((ghostel--last-directory nil)
        (default-directory "/tmp/")
        (ghostel-tramp-default-method "rsync")
        (tramp-default-method "ssh"))
    (ghostel--update-directory "file://remote-host/home/user")
    (should (equal "/rsync:remote-host:/home/user/" default-directory)))
  ;; Preserves method from existing TRAMP default-directory
  (let ((ghostel--last-directory nil)
        (default-directory "/scp:server:/"))
    (ghostel--update-directory "file://server/app")
    (should (equal "/scp:server:/app/" default-directory)))
  ;; Preserves user from existing TRAMP default-directory
  (let ((ghostel--last-directory nil)
        (default-directory "/ssh:dan@myhost:/tmp/"))
    (ghostel--update-directory "file://myhost/home/dan")
    (should (equal "/ssh:dan@myhost:/home/dan/" default-directory))))

(provide 'ghostel-tramp-test)
;;; ghostel-tramp-test.el ends here
