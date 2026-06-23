;;; ghostel-shell-test.el --- Tests for ghostel: shell -*- lexical-binding: t; -*-

;;; Commentary:

;; Shell integration: bash/zsh/fish OSC 7, OSC 133 prompt detection, password
;; prompts, prompt navigation, imenu, command-finish/start hooks,
;; query-before-killing.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-test--with-cat-process (var &rest body)
  "Spawn a long-lived `cat' process bound to VAR, run BODY, then clean up.
The process is killed and the temp buffer destroyed on exit so the
query-before-killing tests don't leak processes between runs."
  (declare (indent 1))
  `(let* ((buf (generate-new-buffer " *ghostel-test-query-cat*"))
          (,var (make-process :name "ghostel-test-cat"
                              :buffer buf
                              :command '("cat")
                              :connection-type 'pipe
                              :noquery nil)))
     (unwind-protect (progn ,@body)
       (when (process-live-p ,var)
         (delete-process ,var))
       (kill-buffer buf))))

(defun ghostel-test--insert-prompt (prefix &optional input)
  "Insert PREFIX + optional INPUT + newline with renderer properties.
`ghostel-prompt' is set on PREFIX, `ghostel-input' on INPUT (or
nothing if INPUT is nil — empty current prompt)."
  (let ((p-start (point)))
    (insert prefix)
    (put-text-property p-start (point) 'ghostel-prompt t)
    (when input
      (let ((i-start (point)))
        (insert input)
        (put-text-property i-start (point) 'ghostel-input t))))
  (insert "\n"))

(defun ghostel-test--insert-prompts-with-cwds (specs)
  "Insert prompts per SPECS and push cwds in chronological order.
Each SPEC is (PREFIX INPUT CWD).  Cwds are pushed in order so the
newest-first list aligns with the buffer-order regions."
  (dolist (spec specs)
    (pcase-let ((`(,prefix ,input ,cwd) spec))
      (ghostel-test--insert-prompt prefix input)
      (push cwd ghostel--imenu-cwds))))

(defun ghostel-test--rendered-terminal-text ()
  "Redraw the current ghostel terminal and return its text."
  (let ((inhibit-read-only t))
    (ghostel--redraw ghostel--term t))
  (ghostel-test--terminal-text))

(ert-deftest ghostel-test-shell-integration ()
  "Test shell process command output and PTY echo."
  :tags '(native)
  (skip-unless (executable-find "zsh"))
  (ghostel-test--with-pty-matrix backend
				 (let* ((prompt "GHOSTEL_TEST_PROMPT>")
					(prompt-regexp (regexp-quote prompt))
					(process-environment
					 (append (list "TERM=xterm-256color" "COLUMNS=80" "LINES=24"
						       (concat "PROMPT=" prompt)
						       (concat "PS1=" prompt))
						 process-environment)))
				   (ghostel-test--with-exec-buffer (buf proc "/bin/zsh" '("-fi"))
								   ;; Wait for shell init.
								   (ghostel-test--wait-until
								    (lambda ()
								      (string-match-p prompt-regexp
										      (ghostel-test--rendered-terminal-text)))
								    proc 10)
								   (should (process-live-p proc))

								   ;; Run a command and wait until the shell has printed the next
								   ;; prompt.  Matching only the command output races with the shell
								   ;; becoming ready for the following interactive input.  The quoted
								   ;; empty string keeps the echoed command from containing the exact
								   ;; output token.
								   (ghostel--write-pty ghostel--term "print -r -- GHOSTEL_''TEST_OK\n")
								   (ghostel-test--wait-until
								    (lambda ()
								      (string-match-p
								       (concat "GHOSTEL_TEST_OK\\(?:.\\|\n\\)*" prompt-regexp)
								       (ghostel-test--rendered-terminal-text)))
								    proc 10)
								   (should (string-match-p "GHOSTEL_TEST_OK"
											   (ghostel-test--rendered-terminal-text)))))))

(ert-deftest ghostel-test-da-response ()
  "Test that the terminal responds to DA1 queries."
  :tags '(native)
  (let ((python (executable-find "python3")))
    (skip-unless python)
    (ghostel-test--with-pty-matrix backend
				   (ghostel-test--with-exec-buffer
				    (buf proc python
					 (list "-c"
					       ghostel-test--pty-reply-probe-script
					       "0.15"
					       (ghostel-test--hex-encode-string "\e[c")))
				    (should (equal "1b5b3f36323b323263"
						   (ghostel-test--wait-for-pty-reply 0 proc 6)))))))

(ert-deftest ghostel-test-fish-backspace ()
  "Test backspace works with fish shell."
  :tags '(:fish native)
  (skip-unless (executable-find "fish"))
  (ghostel-test--with-pty-matrix backend
				 (let ((process-environment
					(append (list "TERM=xterm-256color"
						      "COLORTERM=truecolor"
						      "COLUMNS=80" "LINES=24")
						process-environment)))
				   (ghostel-test--with-exec-buffer
				    (buf proc "/bin/sh"
					 '("-c" "stty erase '^?' 2>/dev/null; exec fish --no-config --private"))
				    (should (process-live-p proc))

				    ;; Send a real command before testing line editing.  The initial
				    ;; output may be a terminal query or startup redraw; waiting for
				    ;; command output proves fish's reader is accepting input.  Private
				    ;; mode keeps history/autosuggestions from repainting `abc' after
				    ;; it has been backspaced to `ab'.
				    (ghostel--write-pty ghostel--term
							"printf '%s%s\\n' GHOSTEL_FISH _READY\n")
				    (ghostel-test--wait-until
				     (lambda ()
				       (string-match-p "GHOSTEL_FISH_READY"
						       (ghostel-test--rendered-terminal-text)))
				     proc 10)

				    ;; Type "abc" then backspace.
				    (ghostel--write-pty ghostel--term "abc")
				    (ghostel-test--wait-until
				     (lambda ()
				       (string-match-p "abc" (ghostel-test--rendered-terminal-text)))
				     proc 5)
				    (should (string-match-p "abc" (ghostel-test--rendered-terminal-text)))

				    ;; Send backspace (\x7f) and verify it works.
				    (ghostel--write-pty ghostel--term "\x7f")
				    (ghostel-test--wait-until
				     (lambda ()
				       (let ((state (ghostel-test--rendered-terminal-text)))
					 (and (string-match-p "ab" state)
					      (not (string-match-p "abc" state)))))
				     proc 5)
				    (let ((state (ghostel-test--rendered-terminal-text)))
				      (should (string-match-p "ab" state))
				      (should-not (string-match-p "abc" state)))))))

(ert-deftest ghostel-test-fish-auto-inject-loads-integration ()
  "Fish auto-inject shim chains to ghostel.fish and cleans XDG_DATA_DIRS."
  :tags '(:fish)
  (skip-unless (executable-find "fish"))
  (let* ((ghostel-dir (or (ghostel--resource-root)
                          (file-name-directory
                           (or (locate-library "ghostel")
                               load-file-name
                               buffer-file-name))))
         (integ-dir (directory-file-name
                     (expand-file-name "etc/shell/bootstrap" ghostel-dir)))
         ;; Isolate from the dev's fish config: a user `function ssh' or
         ;; pre-defined ghostel-like helpers would otherwise satisfy the
         ;; assertions even if our shim didn't chain to etc/shell/ghostel.fish.
         ;; Pointing HOME and XDG_CONFIG_HOME at an empty temp dir skips
         ;; config.fish, conf.d/, and functions/ autoload without
         ;; disturbing XDG_DATA_DIRS (so vendor_conf.d still loads).
         (fish-home (make-temp-file "ghostel-test-fish-home-" t)))
    (unwind-protect
        (let* ((probe (concat
                       "functions -q __ghostel_osc7; and echo osc7=yes; or echo osc7=no\n"
                       "functions -q ghostel_cmd; and echo cmd=yes; or echo cmd=no\n"
                       "functions -q ssh; and echo ssh=yes; or echo ssh=no\n"
                       "echo xdg=$XDG_DATA_DIRS\n"))
               (process-environment
                (append (list (format "HOME=%s" fish-home)
                              (format "XDG_CONFIG_HOME=%s" fish-home)
                              (format "EMACS_GHOSTEL_PATH=%s" ghostel-dir)
                              "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                              (format "XDG_DATA_DIRS=%s:/usr/local/share:/usr/share"
                                      integ-dir)
                              (format "GHOSTEL_SHELL_INTEGRATION_XDG_DIR=%s"
                                      integ-dir))
                        process-environment))
               ;; `call-process' inherits `default-directory' as the cwd.
               ;; Avoid a path with tildes — `~' would expand against the
               ;; overridden HOME above and point at a missing subdir.
               (default-directory fish-home)
               (output (with-temp-buffer
                         (call-process "fish" nil (current-buffer) nil
                                       "-i" "-c" probe)
                         (buffer-string))))
          ;; Shim must chain to etc/shell/ghostel.fish so the integration loads.
          (should (string-match-p "^osc7=yes$" output))
          (should (string-match-p "^cmd=yes$" output))
          ;; GHOSTEL_SSH_INSTALL_TERMINFO=1 must reach etc/shell/ghostel.fish so
          ;; the ssh install-and-cache wrapper is defined.
          (should (string-match-p "^ssh=yes$" output))
          ;; XDG cleanup must strip the injected integration dir without
          ;; leaking fish's internal `/fish'-suffixed form.
          (should (string-match "^xdg=\\(.*\\)$" output))
          (should-not (string-match-p (regexp-quote integ-dir)
                                      (match-string 1 output))))
      (delete-directory fish-home t))))

(ert-deftest ghostel-test-update-directory ()
  "Test OSC 7 directory tracking helper."
  (let* ((ghostel--last-directory nil)
         (dir (file-name-as-directory default-directory))
         (url-path (replace-regexp-in-string "\\\\" "/"
                                             (directory-file-name dir)))
         (file-url (concat "file://"
                           (if (string-match-p "\\`[[:alpha:]]:/" url-path)
                               "/"
                             "")
                           url-path))
         (default-directory default-directory)
         list-buffers-directory)
    (ghostel--update-directory dir)
    (should (equal dir default-directory))                 ; plain path
    (should (equal dir list-buffers-directory))            ; mirrored
    (ghostel--update-directory file-url)
    (should (equal dir default-directory))                 ; file URL
    (should (equal dir list-buffers-directory))            ; mirrored
    ;; Dedup: same path shouldn't re-trigger
    (let ((old ghostel--last-directory))
      (ghostel--update-directory file-url)
      (should (equal old ghostel--last-directory)))))       ; dedup

(ert-deftest ghostel-test-list-buffers-directory ()
  "Test that `ghostel-mode' exposes cwd via `list-buffers-directory'."
  (let ((default-directory (file-name-as-directory
                            (expand-file-name temporary-file-directory))))
    (with-temp-buffer
      (ghostel-mode)
      (should (equal list-buffers-directory default-directory)))))

(ert-deftest ghostel-test-compile-view-list-buffers-directory ()
  "Test that `ghostel-compile-view-mode' exposes cwd via `list-buffers-directory'."
  (let ((default-directory (file-name-as-directory
                            (expand-file-name temporary-file-directory))))
    (with-temp-buffer
      (ghostel-compile-view-mode)
      (should (equal list-buffers-directory default-directory)))))

(ert-deftest ghostel-test-bash-osc7-ignores-env-hostname ()
  "Bash OSC 7 must report gethostname(2), not $HOSTNAME (#276).

Toolbox/container runtimes export HOSTNAME with a value that
disagrees with the kernel hostname.  Emacs function `system-name'
reads gethostname(2); if bash's integration emits $HOSTNAME the
local-host comparison in `ghostel--update-directory' fails and
the buffer is misclassified as remote, switching on TRAMP."
  :tags '(native)
  (skip-unless (executable-find "bash"))
  ;; The test exercises the bash 4.4+ ${var@P} path.  On bash <4.4
  ;; (notably macOS /bin/bash 3.2) the integration deliberately falls
  ;; back to $HOSTNAME - pre-#276 behavior, no regression for those
  ;; users - so the assertion below would not hold and the test would
  ;; be testing the wrong invariant.
  (let ((ver (with-temp-buffer
               (call-process "bash" nil t nil "-c"
                             "printf '%s.%s' \"$BASH_VERSINFO\" \"${BASH_VERSINFO[1]}\"")
               (buffer-string))))
    (skip-unless
     (and (string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)\\'" ver)
          (let ((major (string-to-number (match-string 1 ver)))
                (minor (string-to-number (match-string 2 ver))))
            (or (> major 4) (and (= major 4) (>= minor 4)))))))
  (let* ((root (or (ghostel--resource-root)
                   (file-name-directory (locate-library "ghostel"))))
         (shell-bash (expand-file-name "etc/shell/ghostel.bash" root)))
    (skip-unless (file-exists-p shell-bash))
    (let* ((fake "ghostel-test-fake-host-zzz")
           (process-environment
            (append (list (format "HOSTNAME=%s" fake)
                          "INSIDE_EMACS=ghostel")
                    process-environment))
           (probe (format "cd /; source %s; __ghostel_osc7"
                          shell-bash))
           (output (with-temp-buffer
                     (call-process "bash" nil (current-buffer) nil
                                   "--noprofile" "--norc" "-c" probe)
                     (buffer-string))))
      ;; Probe emits: \e]7;file://HOST/\a
      (should (string-match "\e\\]7;file://\\([^/]*\\)/" output))
      (let ((emitted (match-string 1 output)))
        ;; Polluted $HOSTNAME must not appear in the OSC 7 host.
        (should-not (equal emitted fake))
        ;; Whatever bash emits must pass the same locality check the elisp side
        ;; applies in `ghostel--update-directory'.  Asserting the predicate
        ;; (not strict equality with `system-name') is deliberate: on hosts
        ;; where (system-name) is an FQDN but \H is the short form (or vice
        ;; versa) the two strings differ, yet `ghostel--local-host-p' accepts
        ;; either via its split- on-`.' fallback - which is exactly the
        ;; production behavior we care about.
        (should (ghostel--local-host-p emitted))))))

(ert-deftest ghostel-test-bash-osc7-wins-race-vs-prompt-command ()
  "Bash `__ghostel_osc7' must fire last so it wins the OSC 7 race.

When a system/user rcfile registers a PROMPT_COMMAND that emits its
own OSC 7 (e.g. Fedora's /etc/profile.d/vte.sh emits one via
__vte_prompt_command using $HOSTNAME), libghostty stores whichever
OSC 7 fires last per prompt cycle.  If ours fires first, the
competing emitter overwrites our value and downstream classification
\(local vs TRAMP) is wrong - which is exactly the #276 follow-up bug.

The probe pre-registers a competing PROMPT_COMMAND that emits an OSC
7 with a bogus host, then sources ghostel.bash (which captures the
existing PROMPT_COMMAND), then manually invokes
`__ghostel_wrapped_prompt_command'.  The last OSC 7 in the captured
output must be ours, not the competing one."
  :tags '(native)
  (skip-unless (executable-find "bash"))
  (let* ((root (or (ghostel--resource-root)
                   (file-name-directory (locate-library "ghostel"))))
         (shell-bash (expand-file-name "etc/shell/ghostel.bash" root)))
    (skip-unless (file-exists-p shell-bash))
    (let* ((probe
            (concat
             "PROMPT_COMMAND='printf \"\\e]7;file://competing-host/path\\a\"';"
             (format " source %s;" shell-bash)
             " __ghostel_wrapped_prompt_command"))
           (process-environment
            (append '("INSIDE_EMACS=ghostel") process-environment))
           (output (with-temp-buffer
                     (call-process "bash" nil (current-buffer) nil
                                   "--noprofile" "--norc" "-c" probe)
                     (buffer-string)))
           (osc7s nil)
           (start 0))
      (while (string-match "\e\\]7;\\([^\a]*\\)\a" output start)
        (push (match-string 1 output) osc7s)
        (setq start (match-end 0)))
      (setq osc7s (nreverse osc7s))
      ;; Sanity: both emitters fired - otherwise the race isn't exercised.
      (should (>= (length osc7s) 2))
      (should (cl-some (lambda (s) (string-match-p "competing-host" s))
                       osc7s))
      ;; The LAST OSC 7 must be ours, not the competing one - libghostty
      ;; stores whichever fires last per cycle.
      (should-not (string-match-p "competing-host" (car (last osc7s)))))))

(ert-deftest ghostel-test-zsh-osc7-wins-race-vs-precmd ()
  "Zsh `__ghostel_osc7' must run last among precmd_functions emitters.

A user/system rcfile may register a precmd_function that emits OSC 7
\(e.g. distro VTE-integration hooks).  Whichever runs last per cycle
is the cwd report Ghostel records.  Mirrors the bash race test."
  :tags '(native)
  (skip-unless (executable-find "zsh"))
  (let* ((root (or (ghostel--resource-root)
                   (file-name-directory (locate-library "ghostel"))))
         (shell-zsh (expand-file-name "etc/shell/ghostel.zsh" root)))
    (skip-unless (file-exists-p shell-zsh))
    (let* ((probe
            (concat
             "_competing_osc7() { "
             "printf '\\e]7;file://competing-host/path\\a' "
             "}; "
             "precmd_functions=(_competing_osc7); "
             (format "source %s; " shell-zsh)
             "for f in $precmd_functions; do $f; done"))
           (process-environment
            (append '("INSIDE_EMACS=ghostel") process-environment))
           (output (with-temp-buffer
                     (call-process "zsh" nil (current-buffer) nil
                                   "-f" "-c" probe)
                     (buffer-string)))
           (osc7s nil)
           (start 0))
      (while (string-match "\e\\]7;\\([^\a]*\\)\a" output start)
        (push (match-string 1 output) osc7s)
        (setq start (match-end 0)))
      (setq osc7s (nreverse osc7s))
      ;; Sanity: both emitters fired - otherwise the race isn't exercised.
      (should (>= (length osc7s) 2))
      (should (cl-some (lambda (s) (string-match-p "competing-host" s))
                       osc7s))
      ;; The LAST OSC 7 must be ours.
      (should-not (string-match-p "competing-host" (car (last osc7s)))))))

(ert-deftest ghostel-test-zsh-osc7-uses-gethostname-not-fqdn ()
  "Zsh OSC 7 must report gethostname(2), not the canonicalized $HOST (#417).

zsh canonicalizes $HOST to the FQDN when a DNS search domain is set, which
disagrees with gethostname(2) (Emacs function `system-name').  The integration
must instead report the `hostname' command's value so the local-host comparison
in `ghostel--update-directory' succeeds and the buffer is not misclassified as
remote.  The probe pollutes $HOST with an FQDN (as zsh's canonicalization
would) and puts a fake `hostname' on PATH; the integration must emit the fake
`hostname' value, not the polluted $HOST.  Mirrors the bash sibling test
`ghostel-test-bash-osc7-ignores-env-hostname'."
  :tags '(native)
  (skip-unless (executable-find "zsh"))
  (let* ((root (or (ghostel--resource-root)
                   (file-name-directory (locate-library "ghostel"))))
         (shell-zsh (expand-file-name "etc/shell/ghostel.zsh" root)))
    (skip-unless (file-exists-p shell-zsh))
    (let ((bindir (make-temp-file "ghostel-fakebin" t))
          (fake "ghostel-test-real-host")
          (fqdn "ghostel-test-real-host.example.com"))
      (unwind-protect
          (let ((script (expand-file-name "hostname" bindir)))
            (with-temp-file script
              (insert "#!/bin/sh\nprintf '%s\\n' " fake "\n"))
            (set-file-modes script #o755)
            (let* ((process-environment
                    (append (list (concat "PATH=" bindir ":" (getenv "PATH"))
                                  "INSIDE_EMACS=ghostel")
                            process-environment))
                   ;; Pollute $HOST with the FQDN, as zsh does when a DNS
                   ;; search domain is set — the integration must ignore it.
                   (probe (format "cd /; HOST=%s; source %s; __ghostel_osc7"
                                  fqdn shell-zsh))
                   (output (with-temp-buffer
                             (call-process "zsh" nil (current-buffer) nil
                                           "-f" "-c" probe)
                             (buffer-string))))
              ;; Probe emits: \e]7;file://HOST/\a
              (should (string-match "\e\\]7;file://\\([^/]*\\)/" output))
              (let ((emitted (match-string 1 output)))
                ;; Reports gethostname(2) (the fake `hostname'), …
                (should (equal emitted fake))
                ;; … not the canonicalized $HOST FQDN.
                (should-not (equal emitted fqdn)))))
        (delete-directory bindir t)))))

(ert-deftest ghostel-test-zsh-line-init-fallback-no-fresh-line ()
  "Use 133;P (not 133;A) in the `zle-line-init' fallback emit.
When ghostel's PROMPT-wrap is bypassed (e.g. a theme like
powerlevel10k overrides PROMPT after our precmd), the
`zle-line-init' fallback in `etc/shell/ghostel.zsh' fires
post-prompt-draw to emit OSC 133 markers directly.  It must use
133;P, NOT 133;A — libghostty's fresh-line behavior on 133;A would
CR+LF the cursor onto a blank row below the prompt char (#230).

The test sources ghostel.zsh in a real zsh subprocess, removes the
PROMPT-wrap function from `precmd_functions' to simulate the wrap
being overwritten, sets a multi-line PROMPT, and verifies the
cursor lands at the end of the prompt char rather than one row
below it."
  :tags '(native)
  (skip-unless (executable-find "zsh"))
  (let* ((root (or (ghostel--resource-root)
                   (file-name-directory (locate-library "ghostel"))))
         (shell-zsh (expand-file-name "etc/shell/ghostel.zsh" root)))
    (skip-unless (file-exists-p shell-zsh))
    (ghostel-test--with-pty-matrix backend
				   (ghostel-test--with-terminal-buffer (buf term 8 80 200)
								       (setq-local ghostel-detect-password-prompts nil)
								       (let ((proc (ghostel--spawn-pty "/bin/zsh" '("-fi") nil nil)))
									 ;; Wait for the initial default prompt to reach the terminal.
									 (ghostel-test--wait-until
									  (lambda ()
									    (not (string-empty-p (ghostel-test--rendered-terminal-text))))
									  proc 10)
									 ;; Source ghostel.zsh (registers precmd hooks + the
									 ;; zle-line-init widget).  Then strip the wrap function
									 ;; from `precmd_functions' so PROMPT is left untouched
									 ;; — this exercises the fallback path the same way
									 ;; powerlevel10k's `_p9k_precmd' override does in the
									 ;; wild.  Set a multi-line PROMPT so the regression is
									 ;; visible: cursor must land beside `final-> ', not on
									 ;; the row below it.
									 (ghostel--write-pty
									  ghostel--term
									  (concat
									   "source " (shell-quote-argument shell-zsh) "\n"
									   "precmd_functions=(${precmd_functions:#__ghostel_ensure_prompt_wrap})\n"
									   "PROMPT=$'top-line\\nfinal-> '\n"
									   "\n"))
									 ;; Poll the asserted state directly: redraw on each tick
									 ;; and stop once the cursor row starts with "final-> ".
									 ;; Earlier attempts raced on slow CI: byte-pattern waits
									 ;; matched the echoed PROMPT assignment before zsh had
									 ;; rendered the new prompt, and a `(point-min)' anchor
									 ;; mapped the viewport-row index onto the wrong buffer
									 ;; line once scrollback formed.  Anchor on
									 ;; `ghostel--viewport-start' so the row mapping survives
									 ;; scrollback.
									 (ghostel-test--wait-until
									  (lambda ()
									    (let ((inhibit-read-only t))
									      (ghostel--redraw ghostel--term t))
									    (let ((pos ghostel--cursor-pos)
										  (vp-start (ghostel--viewport-start)))
									      (and pos vp-start
										   (save-excursion
										     (goto-char vp-start)
										     (forward-line (cdr pos))
										     (string-match-p
										      "^[[:blank:]]*final-> "
										      (buffer-substring-no-properties
										       (line-beginning-position)
										       (line-end-position)))))))
									  proc 15)
									 (let* ((pos ghostel--cursor-pos)
										(col (car pos))
										(row (cdr pos))
										(vp-start (ghostel--viewport-start)))
									   ;; Cursor is on the same row as `final-> ', not below it.
									   (should (>= col 8))
									   (save-excursion
									     (goto-char vp-start)
									     (forward-line row)
									     (should
									      (string-match-p
									       "^[[:blank:]]*final-> "
									       (buffer-substring-no-properties
										(line-beginning-position)
										(line-end-position)))))))))))
(ert-deftest ghostel-test-zsh-prompt-cells-tagged-with-self-reorder-theme ()
  "Tag prompt cells when a self-reordering theme overrides PROMPT.
Prompt themes that re-assert their position at the END of
`precmd_functions' on every run (powerlevel10k's `_p9k_precmd',
and similar) win the snapshot-iteration race and overwrite PROMPT
after `__ghostel_ensure_prompt_wrap' has wrapped it.  Net: rendered
PROMPT lacks our inline markers each cycle.

Mirroring ghostty's zsh integration, when our wrap detects it isn't
last in `precmd_functions' it self-reorders for next cycle AND
emits 133;A via `printf' once per cycle as a fallback.  That printf
fires BEFORE the theme overwrites PROMPT and BEFORE zsh draws it,
so libghostty's cursor enters `.prompt' state before any prompt
cell is written — and prompt cells get `ghostel-prompt' tagged even
though our PROMPT wrap didn't stick.

This test registers a fake-p10k precmd that self-reorders to end
and overrides PROMPT each cycle, runs a few prompt cycles, and
checks that the most recent prompt's `top-line' row carries the
`ghostel-prompt' text property."
  :tags '(native)
  (skip-unless (executable-find "zsh"))
  (let* ((root (or (ghostel--resource-root)
                   (file-name-directory (locate-library "ghostel"))))
         (shell-zsh (expand-file-name "etc/shell/ghostel.zsh" root)))
    (skip-unless (file-exists-p shell-zsh))
    (ghostel-test--with-pty-matrix backend
				   (ghostel-test--with-terminal-buffer (buf term 8 80 200)
								       (setq-local ghostel-detect-password-prompts nil)
								       (let ((proc (ghostel--spawn-pty "/bin/zsh" '("-fi") nil nil)))
									 (ghostel-test--wait-until
									  (lambda ()
									    (not (string-empty-p (ghostel-test--rendered-terminal-text))))
									  proc 10)
									 ;; Source ghostel.zsh + register a fake p10k that both
									 ;; overrides PROMPT AND self-reorders to end each cycle
									 ;; (this is what `_p9k_precmd' does).  Then trigger several
									 ;; cycles and probe PROMPT.
									 (ghostel--write-pty
									  ghostel--term
									  (concat
									   "source " (shell-quote-argument shell-zsh) "\n"
									   "fake_theme() {\n"
									   "  PROMPT=$'top-line\\nfinal-> '\n"
									   "  precmd_functions=(${precmd_functions:#fake_theme})\n"
									   "  precmd_functions+=(fake_theme)\n"
									   "}\n"
									   "precmd_functions+=(fake_theme)\n"
									   ;; Trigger several prompt cycles so the rearrange settles.
									   ;; Cycle 1 has the bug; cycle 2+ should have the wrap
									   ;; inline in PROMPT.
									   "true\n"
									   "true\n"
									   "true\n"
									   ;; Print a sentinel after the last prompt cycle so the
									   ;; test can find a stable anchor in the rendered buffer to
									   ;; look back from.
									   "print -r -- 'PROBE_DONE'\n"))
									 (ghostel-test--wait-until
									  (lambda ()
									    (string-match-p "PROBE_DONE"
											    (ghostel-test--rendered-terminal-text)))
									  proc 15)
									 (sleep-for 0.2)
									 (let ((inhibit-read-only t))
									   (ghostel--redraw ghostel--term t))
									 ;; After the rearrange settles, the WRAP fires INLINE with
									 ;; PROMPT expansion (cycle 2+) — so 133;A fires before the
									 ;; prompt content is drawn.  libghostty sets `.prompt'
									 ;; semantic on subsequent cells, and the renderer maps that
									 ;; to `ghostel-prompt' text property.  The most recent
									 ;; prompt's `top-line' row must carry that property.
									 ;;
									 ;; Without the rearrange the fallback fires AFTER the prompt
									 ;; is drawn, so prompt cells are written before the marker —
									 ;; they DON'T get tagged.
									 (save-excursion
									   (goto-char (point-max))
									   (should (search-backward "top-line" nil t))
									   (should (get-text-property (point) 'ghostel-prompt))))))))
(ert-deftest ghostel-test-pty-password-input-p-tracks-noecho ()
  "Password-mode probing tracks canonical no-echo state."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
				 (ghostel-test--with-exec-buffer
				  (buf proc "/bin/sh"
				       '("-c" "stty -echo; printf GHOSTEL_NOECHO_READY; sleep 5"))
				  (ghostel-test--wait-for-text "GHOSTEL_NOECHO_READY" proc 5)
				  (when (and (eq backend 'emacs-pty)
					     (not (process-tty-name ghostel--process)))
				    (ert-skip "Emacs PTY process has no tty name in this environment"))
				  (ghostel-test--wait-until
				   (lambda () (ghostel--pty-password-input-p ghostel--term))
				   proc 5))
				 (ghostel-test--with-exec-buffer
				  (buf proc "/bin/sh"
				       '("-c" "stty echo; printf GHOSTEL_ECHO_READY; sleep 5"))
				  (ghostel-test--wait-for-text "GHOSTEL_ECHO_READY" proc 5)
				  (should-not (ghostel--pty-password-input-p ghostel--term)))))

(ert-deftest ghostel-test-password-detect-regex-fallback ()
  "Regex fallback fires when heuristic returns nil and we're in a remote shell.
Feeds a `[sudo] password for ...:' prompt into the terminal, asserts
`ghostel--password-prompt-detected-p' returns non-nil with the heuristic
stubbed nil and `ghostel--remote-shell-p' stubbed t."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-regex*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (ghostel--write-vt ghostel--term "[sudo] password for alice: ")
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term t))
          (cl-letf (((symbol-function 'ghostel--pty-password-input-p)
                     (lambda (_term) nil))
                    ((symbol-function 'ghostel--remote-shell-p)
                     (lambda () t)))
            (should (eq (ghostel--password-prompt-detected-p) 'regex))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-password-detect-regex-no-false-positive ()
  "Cursor row that doesn't match the regex returns nil from the fallback."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-no-match*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (ghostel--write-vt ghostel--term "$ ls -la")
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term t))
          (cl-letf (((symbol-function 'ghostel--pty-password-input-p)
                     (lambda (_term) nil))
                    ((symbol-function 'ghostel--remote-shell-p)
                     (lambda () t)))
            (should-not (ghostel--password-prompt-detected-p))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-password-detect-skips-regex-on-local ()
  "Regex fallback is suppressed when the heuristic returns nil locally.
Local pty with echo on (the common idle state) must not trigger the
regex fallback even when the cursor row happens to end in `Password:'.
This is the core fix for spurious `read-passwd' prompts: typing `echo
Password:' at a local shell prompt should be inert."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-skips*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          ;; A row that DOES match the regex.
          (ghostel--write-vt ghostel--term "[sudo] password for alice: ")
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term t))
          (cl-letf (((symbol-function 'ghostel--pty-password-input-p)
                     (lambda (_term) nil))
                    ((symbol-function 'ghostel--remote-shell-p)
                     (lambda () nil)))
            (should-not (ghostel--password-prompt-detected-p))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-password-detect-rejects-shell-typed-input ()
  "Cursor rows that look like a typed shell command are rejected.
The default regex (`comint-password-prompt-regexp') anchors structurally:
the password word must appear at the start of the row or after a curated
trigger word (`Enter', `[sudo]', `doas', etc.).  A row like
`daniel@host:~/work$ echo Password:' has neither anchor, so it does NOT
match — even though it ends in `Password:' — and a spurious
`read-passwd' prompt is avoided.  Stubs `ghostel--remote-shell-p' to t
so the regex arm is even reachable."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-shellctx*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (ghostel--write-vt ghostel--term
                             "daniel@host:~/work$ echo Password:")
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term t))
          (cl-letf (((symbol-function 'ghostel--pty-password-input-p)
                     (lambda (_term) nil))
                    ((symbol-function 'ghostel--remote-shell-p)
                     (lambda () t)))
            (should-not (ghostel--password-prompt-detected-p))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-password-detect-source-symbols ()
  "`ghostel--password-prompt-detected-p' reports which arm fired.
Returning a symbol (`zig' or `regex') instead of a bare t lets
diagnostic tooling (e.g. `ghostel-debug-start') record exactly which
detection arm misfired when investigating a spurious prompt."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-source*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (ghostel--write-vt ghostel--term "[sudo] password for alice: ")
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term t))
          (cl-letf (((symbol-function 'ghostel--pty-password-input-p)
                     (lambda (_term) t)))
            (should (eq (ghostel--password-prompt-detected-p) 'zig)))
          (cl-letf (((symbol-function 'ghostel--pty-password-input-p)
                     (lambda (_term) nil))
                    ((symbol-function 'ghostel--remote-shell-p)
                     (lambda () t)))
            (should (eq (ghostel--password-prompt-detected-p) 'regex))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-prompt-password-sends-via-subprocess ()
  "Send the source's return value to the subprocess with a CR.
Plain RET on a tty produces CR, so we send the password followed
by CR and clear state.  Regression check: must NOT send via
`ghostel--write-vt' (the local VT parser) — that path echoes
the password into the terminal buffer and never
reaches the real subprocess."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-dispatch*"))
        (sent nil)
        (vt-input nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (setq ghostel--process 'fake-proc)
          (setq ghostel--password-mode-p t)
          (let ((ghostel-password-prompt-functions
                 (list (lambda (_row) "hunter2"))))
            (cl-letf (((symbol-function 'processp) (lambda (_p) t))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term data) (push (copy-sequence data) sent)))
                      ((symbol-function 'ghostel--write-vt)
                       (lambda (_term data) (push data vt-input))))
              (ghostel--prompt-password)))
          (should (equal sent '("hunter2\r")))
          (should-not vt-input)
          (should-not ghostel--password-mode-p))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-prompt-password-clears-wire-copy ()
  "Clear the freshly allocated wire copy after the send.
The password+CR string is `clear-string'd so the secret doesn't sit
in the heap until the next GC.  Captures the actual reference — not
a copy — and asserts every byte is zero after
`ghostel--prompt-password' returns."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-clear*"))
        (wire-ref nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (setq ghostel--process 'fake-proc)
          (setq ghostel--password-mode-p t)
          (let ((ghostel-password-prompt-functions
                 (list (lambda (_row) "hunter2"))))
            (cl-letf (((symbol-function 'processp) (lambda (_p) t))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term data) (setq wire-ref data))))
              (ghostel--prompt-password)))
          (should wire-ref)
          (should (= 8 (length wire-ref)))               ; "hunter2\r" length
          (should (cl-every #'zerop (string-to-list wire-ref))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-prompt-password-tries-sources-in-order ()
  "First source returning non-nil wins; later sources don't run.
Sources returning nil are skipped so a chain like \"auth-source first,
read-passwd as fallback\" works without each handler reimplementing
the fallback logic."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-chain*"))
        (sent nil)
        (chain nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (setq ghostel--process 'fake-proc)
          (setq ghostel--password-mode-p t)
          (let ((ghostel-password-prompt-functions
                 (list (lambda (_row) (push 'first chain) nil)
                       (lambda (_row) (push 'second chain) "from-second")
                       (lambda (_row) (push 'third chain) "should-not-run"))))
            (cl-letf (((symbol-function 'processp) (lambda (_p) t))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term data) (push (copy-sequence data) sent))))
              (ghostel--prompt-password)))
          (should (equal sent '("from-second\r")))
          (should (equal chain '(second first))))  ; reversed push order
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-prompt-password-resets-state-on-quit ()
  "Reset state when all sources return nil or a source quits.
The indicator clears and the cursor-suppression arms — same as
a successful submission."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-quit*"))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (setq ghostel--process 'fake-proc)
          (setq ghostel--password-mode-p t)
          (ghostel--redraw ghostel--term)
          (let ((ghostel-password-prompt-functions
                 (list (lambda (_row) nil) (lambda (_row) nil))))
            (cl-letf (((symbol-function 'ghostel--write-pty)
                       (lambda (_term data) (push (copy-sequence data) sent))))
              (ghostel--prompt-password)))
          (should-not sent)
          (should-not ghostel--password-mode-p)
          (should ghostel--password-handled-cursor))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-detect-password-prompt-fires-once-per-edge ()
  "Hook fires on rising edge only; falling edge clears state.
`ghostel-password-prompt-debounce' is set to 0 so the confirm timer
fires on the next event-loop tick — the test is about edge logic,
not the debounce window itself (covered separately)."
  :tags '(native)
  (let* ((buf (generate-new-buffer " *ghostel-test-pwd-edge*"))
         (calls 0)
         (now nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (ghostel--redraw ghostel--term)
          (let ((ghostel-password-prompt-functions
                 (list (lambda (_row) (cl-incf calls) nil)))
                (ghostel-password-prompt-debounce 0))
            (cl-letf (((symbol-function 'ghostel--password-prompt-detected-p)
                       (lambda () now)))
              (setq now t)
              (ghostel--detect-password-prompt)
              (should ghostel--password-mode-p)
              (sleep-for 0.05)
              (should (= 1 calls))
              ;; Re-detect while indicator already on → no extra fire.
              (ghostel--detect-password-prompt)
              (sleep-for 0.05)
              (should (= 1 calls))
              ;; Falling edge clears state.
              (setq now nil)
              (ghostel--detect-password-prompt)
              (should-not ghostel--password-mode-p)
              (sleep-for 0.05)
              (should (= 1 calls)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-detect-suppresses-while-on-handled-row ()
  "Suppress re-fire while the cursor stays on the just-handled row.
Regression: sudo (and friends) hold the tty in canonical+!echo for
tens of milliseconds after read() returns; the next PTY chunk would
otherwise look like a fresh rising edge and pop a second
`read-passwd' minibuffer.  Debounce is set to 0 so the confirm
timer fires on the next event-loop tick — this test is about the
handled-row suppression, not the debounce window."
  :tags '(native)
  (let* ((buf (generate-new-buffer " *ghostel-test-pwd-suppress*"))
         (calls 0))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (let ((ghostel-password-prompt-functions
                 (list (lambda (_row) (cl-incf calls) nil)))
                (ghostel-password-prompt-debounce 0))
            (cl-letf (((symbol-function 'ghostel--password-prompt-detected-p)
                       (lambda () t))
                      (ghostel--cursor-pos '(0 . 2)))
              ;; Initial rising edge fires once.
              (ghostel--detect-password-prompt)
              (sleep-for 0.05)
              (should (= 1 calls))
              ;; Simulate the handler returning on the same row.
              (setq ghostel--password-mode-p nil
                    ghostel--password-handled-cursor '(0 . 2))
              ;; Detector ticks while echo is still off and cursor unchanged
              ;; → must NOT fire again.
              (ghostel--detect-password-prompt)
              (ghostel--detect-password-prompt)
              (sleep-for 0.05)
              (should (= 1 calls))
              (should-not ghostel--password-mode-p))
            ;; Cursor moves to a new row (sudo's `Sorry, try again.' or
            ;; the next program's prompt).  Detector must re-fire.
            (cl-letf (((symbol-function 'ghostel--password-prompt-detected-p)
                       (lambda () t))
                      (ghostel--cursor-pos '(0 . 4)))
              (ghostel--detect-password-prompt)
              (sleep-for 0.05)
              (should (= 2 calls)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-password-debounce-defers-source-call ()
  "Rising edge schedules a confirm timer; source is NOT called synchronously.
The source runs only after the debounce elapses and the heuristic
is re-confirmed (mirrors ghostty's ~200 ms termios polling cadence)."
  :tags '(native)
  (let* ((buf (generate-new-buffer " *ghostel-test-pwd-debounce-defer*"))
         (calls 0))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (ghostel--redraw ghostel--term)
          (let ((ghostel-password-prompt-functions
                 (list (lambda (_row) (cl-incf calls) "x")))
                (ghostel-password-prompt-debounce 0.1))
            (cl-letf (((symbol-function 'ghostel--password-prompt-detected-p)
                       (lambda () t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term _data) nil)))
              (ghostel--detect-password-prompt)
              (should ghostel--password-mode-p)
              (should ghostel--password-confirm-timer)
              (should (= 0 calls))
              (sleep-for 0.25)
              (should (= 1 calls))
              (should-not ghostel--password-confirm-timer))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-password-debounce-cancels-on-sub-debounce-flicker ()
  "Sub-debounce flicker cancels the confirm timer; source is never called.
This is the false-positive defense that mirrors ghostty's natural
undersampling — a canonical+!echo flip shorter than the debounce
window never reaches the user."
  :tags '(native)
  (let* ((buf (generate-new-buffer " *ghostel-test-pwd-debounce-flicker*"))
         (calls 0)
         (now t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 1000))
          (setq ghostel--term-rows 5)
          (ghostel--redraw ghostel--term)
          (let ((ghostel-password-prompt-functions
                 (list (lambda (_row) (cl-incf calls) "x")))
                (ghostel-password-prompt-debounce 0.5))
            (cl-letf (((symbol-function 'ghostel--password-prompt-detected-p)
                       (lambda () now)))
              (ghostel--detect-password-prompt)
              (should ghostel--password-confirm-timer)
              (should ghostel--password-mode-p)
              ;; Falling edge before timer fires.
              (setq now nil)
              (ghostel--detect-password-prompt)
              (should-not ghostel--password-confirm-timer)
              (should-not ghostel--password-mode-p)
              (sleep-for 0.6)
              (should (= 0 calls)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-cancel-password-prompt-depth-gate ()
  "`ghostel--cancel-password-prompt' aborts only when depth is outer+1.
Other depths (no minibuffer, equal to outer, or deeper) are no-ops
so unrelated minibuffers (e.g. `M-x' the user opened before the
rising edge) survive.  The minibuffer-identity gate is satisfied
by stubbing `active-minibuffer-window' + `window-buffer' to return
the same buffer we set as `ghostel--password-prompt-mb-buffer'."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-cancel-gate*"))
        (mb-buf (generate-new-buffer " *ghostel-test-pwd-mb*"))
        (aborted 0)
        (depth 0))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (cl-letf (((symbol-function 'minibuffer-depth) (lambda () depth))
                    ((symbol-function 'active-minibuffer-window)
                     (lambda () 'fake-window))
                    ((symbol-function 'window-buffer)
                     (lambda (_w) mb-buf))
                    ((symbol-function 'abort-recursive-edit)
                     (lambda () (cl-incf aborted))))
            (setq ghostel--password-prompt-mb-buffer mb-buf)
            ;; Flag off → no abort regardless of depth.
            (setq ghostel--password-prompt-active nil
                  ghostel--password-prompt-outer-depth 0
                  depth 1)
            (ghostel--cancel-password-prompt)
            (should (= 0 aborted))
            ;; Flag on, depth == outer (prompt not yet opened) → no abort.
            (setq ghostel--password-prompt-active t
                  ghostel--password-prompt-outer-depth 1
                  depth 1)
            (ghostel--cancel-password-prompt)
            (should (= 0 aborted))
            ;; Flag on, depth == outer+1 → our minibuffer is innermost; abort.
            (setq depth 2)
            (ghostel--cancel-password-prompt)
            (should (= 1 aborted))
            ;; Flag on, depth > outer+1 (something stacked on top) → no abort.
            (setq depth 3)
            (ghostel--cancel-password-prompt)
            (should (= 1 aborted))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (buffer-live-p mb-buf) (kill-buffer mb-buf)))))

(ert-deftest ghostel-test-cancel-password-prompt-mb-identity-gate ()
  "Identity gate blocks abort when the active minibuffer isn't ours.
Stub setup: depth=1, outer=0 (so depth gate passes).  The cancel
fires only when `(window-buffer (active-minibuffer-window))' equals
`ghostel--password-prompt-mb-buffer' — i.e. the active minibuffer
is the one our setup hook captured.  Covers two failure modes:
  - Captured nil (our chain ran but never opened a minibuffer);
  - Active minibuffer is some other buffer (cross-buffer race or
    nested minibuffer that pushed us off the innermost slot)."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-mb-gate*"))
        (our-mb (generate-new-buffer " *ghostel-test-pwd-our-mb*"))
        (other-mb (generate-new-buffer " *ghostel-test-pwd-other-mb*"))
        (aborted 0)
        (active-mb-buf nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (cl-letf (((symbol-function 'minibuffer-depth) (lambda () 1))
                    ((symbol-function 'active-minibuffer-window)
                     (lambda () (and active-mb-buf 'fake-window)))
                    ((symbol-function 'window-buffer)
                     (lambda (_w) active-mb-buf))
                    ((symbol-function 'abort-recursive-edit)
                     (lambda () (cl-incf aborted))))
            (setq ghostel--password-prompt-active t
                  ghostel--password-prompt-outer-depth 0)
            ;; Captured nil → never abort.
            (setq ghostel--password-prompt-mb-buffer nil
                  active-mb-buf our-mb)
            (ghostel--cancel-password-prompt)
            (should (= 0 aborted))
            ;; Captured but active minibuffer is a different buffer → no abort.
            (setq ghostel--password-prompt-mb-buffer our-mb
                  active-mb-buf other-mb)
            (ghostel--cancel-password-prompt)
            (should (= 0 aborted))
            ;; Captured matches active minibuffer → abort.
            (setq active-mb-buf our-mb)
            (ghostel--cancel-password-prompt)
            (should (= 1 aborted))
            ;; No active minibuffer at all → no abort.
            (setq active-mb-buf nil)
            (ghostel--cancel-password-prompt)
            (should (= 1 aborted))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (buffer-live-p our-mb) (kill-buffer our-mb))
      (when (buffer-live-p other-mb) (kill-buffer other-mb)))))

(ert-deftest ghostel-test-prompt-password-mb-buffer-capture ()
  "Setup hook in `ghostel--prompt-password' captures the right minibuffer.
The lambda installed by `minibuffer-with-setup-hook' must set
`ghostel--password-prompt-mb-buffer' only when the minibuffer was
entered from the origin buffer's window — an unrelated minibuffer
opened concurrently (cross-buffer race) must not poison the
capture.  Drives `minibuffer-setup-hook' directly from a stubbed
source so the hook fires under controlled conditions without
involving a real `read-passwd' call, and snapshots
`ghostel--password-prompt-mb-buffer' before the unwind clears it."
  :tags '(native)
  (let ((origin (generate-new-buffer " *ghostel-test-pwd-capture-origin*"))
        (mb (generate-new-buffer " *ghostel-test-pwd-capture-mb*"))
        (other (generate-new-buffer " *ghostel-test-pwd-capture-other*"))
        (snapshot 'sentinel))
    (unwind-protect
        (with-current-buffer origin
          (ghostel-mode)
          (setq ghostel--process 'fake-proc)
          (cl-letf (((symbol-function 'processp) (lambda (_p) t))
                    ((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'ghostel--write-pty) (lambda (_term _data) nil)))
            ;; Case 1: minibuffer entered from ORIGIN → capture.
            (let ((ghostel-password-prompt-functions
                   (list (lambda (_row)
                           (with-current-buffer mb
                             (cl-letf (((symbol-function 'minibuffer-selected-window)
                                        (lambda () 'fake-win))
                                       ((symbol-function 'window-buffer)
                                        (lambda (_w) origin)))
                               (run-hooks 'minibuffer-setup-hook)))
                           (setq snapshot ghostel--password-prompt-mb-buffer)
                           "x"))))
              (ghostel--prompt-password))
            (should (eq snapshot mb))
            ;; Case 2: minibuffer entered from a different buffer → no capture.
            (setq snapshot 'sentinel)
            (let ((ghostel-password-prompt-functions
                   (list (lambda (_row)
                           (with-current-buffer mb
                             (cl-letf (((symbol-function 'minibuffer-selected-window)
                                        (lambda () 'fake-win))
                                       ((symbol-function 'window-buffer)
                                        (lambda (_w) other)))
                               (run-hooks 'minibuffer-setup-hook)))
                           (setq snapshot ghostel--password-prompt-mb-buffer)
                           "x"))))
              (ghostel--prompt-password))
            (should-not snapshot)))
      (when (buffer-live-p origin) (kill-buffer origin))
      (when (buffer-live-p mb) (kill-buffer mb))
      (when (buffer-live-p other) (kill-buffer other)))))

(ert-deftest ghostel-test-password-detect-aborts-on-falling-edge ()
  "Falling edge with prompt active and right depth calls `abort-recursive-edit'.
Routes through `ghostel--cancel-password-prompt' from the falling-edge
branch of `ghostel--detect-password-prompt'.  Identity gate is
satisfied by setting `ghostel--password-prompt-mb-buffer' and
stubbing `active-minibuffer-window' / `window-buffer' to return it."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pwd-falling-abort*"))
        (mb-buf (generate-new-buffer " *ghostel-test-pwd-falling-mb*"))
        (aborted 0))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (cl-letf (((symbol-function 'ghostel--password-prompt-detected-p)
                     (lambda () nil))
                    ((symbol-function 'minibuffer-depth) (lambda () 1))
                    ((symbol-function 'active-minibuffer-window)
                     (lambda () 'fake-window))
                    ((symbol-function 'window-buffer)
                     (lambda (_w) mb-buf))
                    ((symbol-function 'abort-recursive-edit)
                     (lambda () (cl-incf aborted))))
            (setq ghostel--password-prompt-active t
                  ghostel--password-prompt-outer-depth 0
                  ghostel--password-prompt-mb-buffer mb-buf)
            (ghostel--detect-password-prompt)
            (should (= 1 aborted))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (buffer-live-p mb-buf) (kill-buffer mb-buf)))))

(ert-deftest ghostel-test-query-before-killing-auto-prompts-while-command-runs ()
  "`auto' asks before killing a live buffer while a command is running."
  (ghostel-test--with-cat-process
   proc
   (with-current-buffer (process-buffer proc)
     (let ((ghostel--process proc)
           (ghostel-query-before-killing 'auto)
           (ghostel--command-running t)
           asked)
       (cl-letf (((symbol-function 'yes-or-no-p)
                  (lambda (prompt) (setq asked prompt) nil)))
         (should-not (ghostel--kill-buffer-query))
         (should (string-match-p "has a running process" asked)))))))

(ert-deftest ghostel-test-query-before-killing-auto-allows-at-prompt ()
  "`auto' does not ask before killing a live buffer at a prompt."
  (ghostel-test--with-cat-process
   proc
   (with-current-buffer (process-buffer proc)
     (let ((ghostel--process proc)
           (ghostel-query-before-killing 'auto)
           (ghostel--command-running nil))
       (cl-letf (((symbol-function 'yes-or-no-p)
                  (lambda (_) (ert-fail "unexpected prompt"))))
         (should (ghostel--kill-buffer-query)))))))

(ert-deftest ghostel-test-query-before-killing-nil-is-noop ()
  "When set to nil, killing a live buffer is allowed without asking."
  (ghostel-test--with-cat-process
   proc
   (with-current-buffer (process-buffer proc)
     (let ((ghostel--process proc)
           (ghostel-query-before-killing nil)
           (ghostel--command-running t))
       (cl-letf (((symbol-function 'yes-or-no-p)
                  (lambda (_) (ert-fail "unexpected prompt"))))
         (should (ghostel--kill-buffer-query)))))))

(ert-deftest ghostel-test-query-before-killing-t-always-prompts ()
  "When set to t, killing a live buffer asks even at a prompt."
  (ghostel-test--with-cat-process
   proc
   (with-current-buffer (process-buffer proc)
     (let ((ghostel--process proc)
           (ghostel-query-before-killing t)
           (ghostel--command-running nil)
           asked)
       (cl-letf (((symbol-function 'yes-or-no-p)
                  (lambda (prompt) (setq asked prompt) t)))
         (should (ghostel--kill-buffer-query))
         (should (string-match-p "has a running process" asked)))))))

(ert-deftest ghostel-test-query-before-killing-handles-dead-process ()
  "Dead processes may be killed without asking."
  (ghostel-test--with-cat-process
   proc
   (with-current-buffer (process-buffer proc)
     (delete-process proc)
     (let ((ghostel--process proc)
           (ghostel-query-before-killing 'auto)
           (ghostel--command-running t))
       (cl-letf (((symbol-function 'yes-or-no-p)
                  (lambda (_) (ert-fail "unexpected prompt"))))
         (should (ghostel--kill-buffer-query)))))))

(ert-deftest ghostel-test-prompt-navigation ()
  "Test next/previous prompt navigation.
Mirrors the renderer's two-property layout: `ghostel-prompt' on the
prefix only, `ghostel-input' on the user-typed command."
  (with-temp-buffer
    (ghostel-test--insert-prompt "$ " "cmd1")
    (insert "output1\n")
    ;; Multi-word command: navigation must land on the first word,
    ;; not the last (the old skip-chars logic skipped the last word
    ;; backward and incorrectly treated it as the input start).
    (ghostel-test--insert-prompt "$ " "echo bb cc")
    (insert "bb cc\n")
    ;; Single-char trailing arg: the old `(forward-char 2)` jumped
    ;; past the input's last char AND the newline, landing on the
    ;; OUTPUT line below.  Must land on `e' of `echo'.
    (ghostel-test--insert-prompt "$ " "echo b")
    (insert "b\n")
    ;; Empty current prompt — no `ghostel-input' after the prefix.
    (ghostel-test--insert-prompt "$ ")

    ;; Forward navigation from beginning of buffer.
    (goto-char (point-min))
    (ghostel--navigate-next-prompt 1)
    (should (looking-at "echo bb cc"))         ; multi-word: lands on first word

    (ghostel--navigate-next-prompt 1)
    (should (looking-at "echo b$"))            ; single-char arg: stays on input line

    (ghostel--navigate-next-prompt 1)
    (should (eolp))                            ; empty prompt: cursor right after `$ '

    ;; Backward navigation from end of buffer.
    (goto-char (point-max))
    (ghostel--navigate-previous-prompt 1)
    (should (eolp))                            ; previous from EoB → empty current prompt

    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "echo b$"))            ; single-char arg

    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "echo bb cc"))         ; multi-word

    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "cmd1"))               ; first prompt

    ;; From inside a prompt, previous should skip to the prior prompt.
    (goto-char (point-min))
    (ghostel--navigate-next-prompt 2)          ; on `echo b' input
    (forward-char 2)                           ; inside the input
    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "echo bb cc"))))

(ert-deftest ghostel-test-imenu-empty-buffer ()
  "Empty buffer yields an empty imenu index."
  (with-temp-buffer
    (should (null (ghostel--imenu-create-index)))))

(ert-deftest ghostel-test-imenu-single-prompt ()
  "Single prompt+command produces one entry; label = command (no cwd stamped)."
  (with-temp-buffer
    (ghostel-test--insert-prompt "$ " "make build")
    (let ((index (ghostel--imenu-create-index)))
      (should (equal 1 (length index)))
      (should (equal "make build" (caar index)))
      (should (= 1 (cdar index))))))             ; pos at point-min

(ert-deftest ghostel-test-imenu-skips-empty-commands ()
  "Prompts with no typed command are skipped."
  (with-temp-buffer
    (ghostel-test--insert-prompt "$ ")            ; empty
    (ghostel-test--insert-prompt "$ " "ls")
    (ghostel-test--insert-prompt "$ ")            ; empty
    (let ((index (ghostel--imenu-create-index)))
      (should (equal 1 (length index)))
      (should (equal "ls" (caar index))))))

(ert-deftest ghostel-test-imenu-cwd-attribution ()
  "Each entry's label uses its OWN recorded cwd, not the buffer's current one."
  (with-temp-buffer
    (ghostel-test--insert-prompts-with-cwds
     '(("$ " "make" "/foo/")
       ("$ " "test" "/bar/")))
    (let* ((index (ghostel--imenu-create-index))
           (labels (mapcar #'car index)))
      (should (equal 2 (length index)))
      ;; abbreviate-file-name on /foo/ yields "/foo" after directory-file-name.
      (should (string-match-p "\\`/foo  make\\'" (nth 0 labels)))
      (should (string-match-p "\\`/bar  test\\'" (nth 1 labels))))))

(ert-deftest ghostel-test-imenu-multi-line-command ()
  "Label uses only the first line of a multi-line command."
  (with-temp-buffer
    (ghostel-test--insert-prompt "$ " "echo a\nbb\ncc")
    (let ((index (ghostel--imenu-create-index)))
      (should (equal 1 (length index)))
      (should (equal "echo a" (caar index))))))

(ert-deftest ghostel-test-imenu-truncates-long-command ()
  "Labels longer than 80 columns are truncated."
  (with-temp-buffer
    (ghostel-test--insert-prompt "$ " (make-string 200 ?x))
    (let* ((index (ghostel--imenu-create-index))
           (label (caar index)))
      (should (<= (string-width label) 80)))))

(ert-deftest ghostel-test-imenu-stamp-cwd-hook ()
  "Stamping at OSC 133 \\='C\\=' records the current cwd against the prompt."
  (with-temp-buffer
    (ghostel-test--insert-prompt "$ " "make")
    (let ((default-directory "/tmp/work/"))
      (ghostel--imenu-stamp-cwd (current-buffer)))
    (let* ((index (ghostel--imenu-create-index))
           (label (caar index)))
      (should (equal 1 (length index)))
      (should (string-match-p "\\`/tmp/work  make\\'" label)))))

(ert-deftest ghostel-test-imenu-survives-buffer-rebuild ()
  "Cwd attribution survives an `eraseBuffer'-style rebuild (resize/force-full).
Prompts are rebuilt at new buffer positions but in the same order;
the chronological cwds list must re-align without loss."
  (with-temp-buffer
    (ghostel-test--insert-prompts-with-cwds
     '(("$ " "make" "/foo/")
       ("$ " "test" "/bar/")))
    ;; Simulate `eraseBuffer' wiping everything, then the renderer
    ;; rebuilding the same prompts at fresh buffer positions (e.g. with
    ;; an extra padding line after a row reflow).
    (erase-buffer)
    (insert "\n")                                ; reflow padding
    (ghostel-test--insert-prompt "$ " "make")
    (ghostel-test--insert-prompt "$ " "test")
    (let* ((index (ghostel--imenu-create-index))
           (labels (mapcar #'car index)))
      (should (equal 2 (length index)))
      (should (string-match-p "\\`/foo  make\\'" (nth 0 labels)))
      (should (string-match-p "\\`/bar  test\\'" (nth 1 labels))))))

(ert-deftest ghostel-test-imenu-eviction-drops-oldest-cwds ()
  "When prompts are evicted from the top, the oldest cwds are dropped.
Otherwise the surviving prompts would be mis-attributed to the
evicted prompts' cwds."
  (with-temp-buffer
    (ghostel-test--insert-prompts-with-cwds
     '(("$ " "old1" "/evicted1/")
       ("$ " "old2" "/evicted2/")
       ("$ " "live" "/live/")))
    ;; Evict the two oldest prompts (rows 1 and 2).
    (goto-char (point-min))
    (forward-line 2)
    (delete-region (point-min) (point))
    (let* ((index (ghostel--imenu-create-index))
           (labels (mapcar #'car index)))
      (should (equal 1 (length index)))
      (should (string-match-p "\\`/live  live\\'" (car labels)))
      ;; The cwds list must be trimmed to match.
      (should (equal 1 (length ghostel--imenu-cwds)))
      (should (equal "/live/" (car ghostel--imenu-cwds))))))

(ert-deftest ghostel-test-imenu-active-prompt-no-cwd-yet ()
  "An active prompt (no \\='C\\=' fired yet) gets no cwd; older prompts unaffected."
  (with-temp-buffer
    (ghostel-test--insert-prompts-with-cwds
     '(("$ " "make" "/foo/")))
    (ghostel-test--insert-prompt "$ ")            ; active prompt, empty input
    ;; Push a typed in-progress command without firing C yet.
    (let* ((index (ghostel--imenu-create-index))
           (labels (mapcar #'car index)))
      (should (equal 1 (length index)))           ; active prompt has empty cmd, skipped
      (should (string-match-p "\\`/foo  make\\'" (car labels))))))

(ert-deftest ghostel-test-imenu-goto-lands-at-input-start ()
  "Goto lands point past the prompt prefix, on the typed command.
Mirrors `ghostel-next-prompt': the index entry points at the
prompt-prefix start (column 0), but goto must advance past the
prefix so point sits where the user would type."
  (with-temp-buffer
    (ghostel-test--insert-prompt "$ " "make build")
    (setq-local ghostel--input-mode 'emacs)
    (ghostel--imenu-goto "make build" 1)
    ;; "$ " is 2 chars; point should land at the start of "make build" (pos 3).
    (should (= (point) 3))
    (should (looking-at "make build"))))

(ert-deftest ghostel-test-imenu-goto-switches-to-emacs-mode ()
  "Selecting an imenu entry from semi-char mode switches to Emacs mode.
Without the switch, the renderer would yank point back to the
live cursor on the next redraw and the jump would be invisible."
  (let ((emacs-mode-called nil))
    (with-temp-buffer
      (ghostel-test--insert-prompt "$ " "make")
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t)
                   (setq ghostel--input-mode 'emacs))))
        (ghostel--imenu-goto "make" 1))
      (should emacs-mode-called))))

(ert-deftest ghostel-test-imenu-goto-preserves-line-mode ()
  "Line mode is preserved across an imenu jump.
Mode is not switched to Emacs; `set-window-start' pins the
window to the target's line so the next redraw's anchored
predicate (`ghostel.el' line 5520) sees the window as
scrolled-back."
  (let ((emacs-mode-called nil))
    (with-temp-buffer
      (ghostel-test--insert-prompt "$ " "make")
      (setq-local ghostel--input-mode 'line)
      (cl-letf (((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel--imenu-goto "make" 1))
      (should-not emacs-mode-called)
      (should (eq ghostel--input-mode 'line)))))

(ert-deftest ghostel-test-imenu-goto-skips-mode-switch-in-emacs ()
  "When already in Emacs mode, goto does not re-enter Emacs mode."
  (let ((emacs-mode-called nil))
    (with-temp-buffer
      (ghostel-test--insert-prompt "$ " "make")
      (setq-local ghostel--input-mode 'emacs)
      (cl-letf (((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel--imenu-goto "make" 1))
      (should-not emacs-mode-called))))

(ert-deftest ghostel-test-imenu-goto-skips-mode-switch-in-copy ()
  "When already in copy mode, goto does not switch to Emacs mode."
  (let ((emacs-mode-called nil))
    (with-temp-buffer
      (ghostel-test--insert-prompt "$ " "make")
      (setq-local ghostel--input-mode 'copy)
      (cl-letf (((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel--imenu-goto "make" 1))
      (should-not emacs-mode-called))))

(ert-deftest ghostel-test-input-start-point-osc133-on-cursor-row ()
  "When `ghostel-prompt' covers the cursor row's prefix, use its end.
This is the canonical bash-with-shell-integration path: `$ '
carries `ghostel-prompt', cursor sits right after it (or after
input already typed at the prompt)."
  (let ((buf (generate-new-buffer " *ghostel-test-line-osc133*")))
    (unwind-protect
        (with-current-buffer buf
          (insert (propertize "$ " 'ghostel-prompt t))
          (insert "ls -la")
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (let ((ghostel--cursor-char-pos 8))
            ;; Prompt prefix ends at position 3 (after "$ ").
            (should (= (ghostel-input-start-point) 3))))
      (kill-buffer buf))))


(ert-deftest ghostel-test-local-host-p ()
  "Test local hostname detection."
  (should (ghostel--local-host-p nil))
  (should (ghostel--local-host-p ""))
  (should (ghostel--local-host-p "localhost"))
  (should (ghostel--local-host-p (system-name)))
  (should (ghostel--local-host-p (car (split-string (system-name) "\\."))))
  (should-not (ghostel--local-host-p "remote-server.example.com")))


(provide 'ghostel-shell-test)
;;; ghostel-shell-test.el ends here
