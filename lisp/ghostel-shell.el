;;; ghostel-shell.el --- Shell awareness for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Everything ghostel knows about *the shell* running inside the
;; terminal, as opposed to the terminal emulator itself:
;;
;; - Shell detection and spawn-spec resolution, local and remote
;;   (`ghostel--detect-shell', `ghostel--resolve-shell-spec',
;;   `ghostel--macos-login-wrap').
;; - Shell-integration injection: local rc bootstrap env, remote
;;   (TRAMP) temp-file setup, and the remote terminfo push that rides
;;   along with it (`ghostel--setup-remote-integration').
;; - OSC 133 semantic-prompt state (`ghostel--osc133-marker', which
;;   the native module funcalls), prompt navigation, and imenu.
;; - Shell history retrieval (`ghostel-shell-history').
;;
;; `ghostel.el' requires this file eagerly (the native marker handler
;; must exist before any VT data is processed); its
;; `ghostel--start-process' orchestrates spawning and calls into this
;; module.  Core state and functions used here are only
;; forward-declared, so the require introduces no cycle.

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'imenu)
(require 'seq)
(require 'subr-x)
(require 'tramp)

(declare-function ghostel--ensure-ghostel-buffer "ghostel")
(declare-function ghostel--enter-readonly-input-mode "ghostel")
(declare-function ghostel--resource-root "ghostel-module-install")
(declare-function ghostel--ssh-install-enabled-p "ghostel")
(declare-function ghostel--terminfo-directory "ghostel")
(defvar ghostel-prompt-navigation-input-mode)
(defvar ghostel-shell)
(defvar ghostel--input-mode)


;;; Customization

(defcustom ghostel-shell-integration t
  "Automatically inject shell integration on startup.
When non-nil, ghostel modifies the shell invocation to automatically
load shell integration scripts without requiring changes to the user's
shell configuration files.  Supports bash, zsh, fish, and nushell."
  :type 'boolean
  :group 'ghostel)

(defcustom ghostel-tramp-shells
  '(("ssh" login-shell)
    ("sshx" login-shell)
    ("scp" login-shell)
    ("docker" "/bin/sh"))
  "Shell to use for remote TRAMP connections, per method.
Each entry is (TRAMP-METHOD SHELL [FALLBACK [ARG...]]).  TRAMP-METHOD is a
method string such as \"ssh\" or \"docker\", or t as a catch-all default.

SHELL is either a path string like \"/bin/bash\" or the symbol `login-shell'
to auto-detect the remote user's login shell via `getent passwd'.
FALLBACK, when present, is used when login-shell detection fails.

Any elements after FALLBACK are extra arguments passed to the shell.
When none are given, ghostel supplies a type-aware default: recognized shells
\(bash, zsh, fish, nushell) are started as login+interactive shells (`-l -i')
so they source the user's rc/profile files, mirroring an interactive `ssh host'
login.  Unrecognized shells (e.g. /bin/sh) get no args.
To override, list the arguments explicitly after FALLBACK,
e.g. (\"ssh\" login-shell nil \"-i\").

For bash, list long options (e.g. `--rcfile') before single-character
ones (e.g. `-i'); bash rejects long options that follow short ones."
  :type '(alist :key-type (choice string (const t))
                :value-type
                (list (choice :tag "Shell" string (const login-shell))
                      (choice :tag "Fallback" (const :tag "None" nil) string)
                      (repeat :inline t :tag "Extra arguments" string)))
  :group 'ghostel)

(defcustom ghostel-tramp-shell-integration nil
  "Inject shell integration for remote TRAMP sessions.
When non-nil, ghostel writes integration scripts to a temporary
file on the remote host and configures the shell to source them.
Set to t for all supported shells, or a list of symbols
\(e.g. \\='(bash zsh)) for specific shells only."
  :type '(choice (const :tag "Disabled" nil)
                 (const :tag "All shells" t)
                 (repeat :tag "Specific shells"
                         (choice (const bash)
                                 (const zsh)
                                 (const fish)
                                 (const nu))))
  :group 'ghostel)

(defcustom ghostel-macos-login-shell (eq system-type 'darwin)
  "Wrap shell invocations on macOS so the shell starts as a login shell.

When non-nil and `system-type' is `darwin', ghostel wraps the shell
spawned by `ghostel--start-process' with `/usr/bin/login -flp $USER'
followed by a tiny `/bin/bash --noprofile --norc -c \"exec -l <shell>
[args]\"' shim.  This mirrors Apple's Terminal.app and Ghostty so that
per-user login files (`~/.zprofile', `~/.bash_profile') are sourced as
users expect on macOS.

When `~/.hushlogin' exists, `-q' is passed to `login(1)' to suppress
its banner.  The wrap preserves the calling environment via `login -p',
so ghostel's shell-integration env (ZDOTDIR, ENV, XDG_DATA_DIRS,
EMACS_GHOSTEL_PATH, INSIDE_EMACS) reaches the final shell.  Note that
login(1) ALWAYS resets HOME, SHELL, LOGNAME, USER, and MAIL from the
passwd entry — overrides for these in `ghostel-environment' do not
survive the wrap.

This wrap is only applied for the interactive shell spawned by
`ghostel'.  It is not applied for `ghostel-exec' (the arbitrary-
command entry point), for remote (TRAMP) sessions, or on non-Darwin
platforms.  Set to nil to opt out and get a plain (non-login)
interactive shell."
  :type 'boolean
  :group 'ghostel)

(defcustom ghostel-shell-history-commands
  '((bash . "bash -ic 'history -r; fc -lnr 1'")
    (zsh  . "zsh -ic 'fc -R; fc -lnr 1'")
    (fish . "fish -c 'history -z'")
    (nu   . "nu -c 'history | get command | reverse | to text'"))
  "Command printing a shell's history, keyed by shell type.
Keys are shell type symbols (`bash', `zsh', `fish', `nu').  A string
value is run with \"/bin/sh -c\" through `process-file', so a remote
buffer queries the remote host; it must print one history entry per
line, newest first.  Output containing a NUL byte is split on NUL
instead, letting multi-line entries survive (e.g. fish's `history -z').
Entries are trimmed of surrounding whitespace.

A function value is called with no arguments in the terminal's buffer
and must return the list of entries itself, newest first.  History
managers replace the shell's entry, e.g.:

  (setf (alist-get \\='zsh ghostel-shell-history-commands)
        \"atuin history list --cmd-only --print0 --reverse false\")

Used by `ghostel-shell-history'."
  :type '(alist :key-type symbol
                :value-type (choice string function))
  :group 'ghostel)

(defcustom ghostel-command-finish-functions nil
  "Hook run when a shell command finishes (OSC 133 D marker).
Each function is called with two arguments: the buffer and the
exit status (an integer, or nil if the shell did not report one).

Requires the shell to emit OSC 133 semantic prompt markers.  Bash,
zsh, and fish shell integration bundled with ghostel emits these
markers automatically when `ghostel-shell-integration' is enabled.

The hook fires synchronously from the terminal parser, so consumers
that need a fully rendered buffer should defer their own work via
`run-at-time'.  Errors in hook functions are demoted to messages
via `with-demoted-errors', so a misbehaving hook does not break
the parser or stop later hooks — except when `debug-on-error' is
non-nil, in which case the error is re-signalled so the debugger
can fire (standard `with-demoted-errors' semantics)."
  :type 'hook
  :group 'ghostel)

(defcustom ghostel-command-start-functions nil
  "Hook run when a shell command starts running (OSC 133 C marker).
Each function is called with one argument: the buffer.

Requires shell integration; this fires from the shell's
preexec hook just before the user's command runs.  Useful
for distinguishing a real command's lifecycle from prompt
redraws (which emit D markers without a preceding C).

Errors in hook functions are demoted to messages via
`with-demoted-errors' (re-signalled when `debug-on-error' is
non-nil so the debugger can fire)."
  :type 'hook
  :group 'ghostel)


;;; Buffer-local state

(defvar-local ghostel--shell-program nil
  "Shell program resolved at spawn time by `ghostel--start-process'.
Nil for buffers running an arbitrary command (`ghostel-exec').")

(defvar-local ghostel--command-running nil
  "Non-nil between OSC 133 command-start and command-finish markers.")

(defvar-local ghostel--prompt-positions nil
  "List of prompt positions as (buffer-line . exit-status) pairs.
Used for prompt navigation and optional re-application after full redraws.")


;;; Shell detection & resolution

(defun ghostel--detect-shell (shell)
  "Return shell type symbol (bash, zsh, fish, nu) from SHELL path, or nil."
  (let ((base (file-name-nondirectory shell)))
    (cond
     ((string-match-p "bash" base) 'bash)
     ((string-match-p "zsh" base) 'zsh)
     ((string-match-p "fish" base) 'fish)
     ((member base '("nu" "nushell")) 'nu))))

(defun ghostel--tramp-shell-spec (method)
  "Return (PROGRAM . EXTRA-ARGS) for TRAMP METHOD from `ghostel-tramp-shells'.
METHOD is a TRAMP method string or t for the default.
PROGRAM is the shell path: either the configured string or, for the
`login-shell' symbol, the remote user's login shell auto-detected
via `getent passwd' \(falling back to the entry's FALLBACK).
EXTRA-ARGS are the optional arguments listed after the FALLBACK slot.
Returns nil when no program resolves for METHOD."
  (let* ((specs (cdr (assoc method ghostel-tramp-shells)))
         (first (car specs))
         (second (cadr specs))
         (args (cddr specs))
         (program
          (if (eq first 'login-shell)
              (let* ((entry (ignore-errors
                              (with-output-to-string
                                (with-current-buffer standard-output
                                  (unless (= 0 (process-file-shell-command
                                                "getent passwd $LOGNAME"
                                                nil (current-buffer) nil))
                                    (error "Unexpected return value"))
                                  (when (> (count-lines (point-min) (point-max)) 1)
                                    (error "Unexpected output"))))))
                     (shell (when entry
                              (nth 6 (split-string entry ":" nil "[ \t\n\r]+")))))
                (or shell second))
            first)))
    (and program (cons program args))))

(defun ghostel--shell-program-and-args (spec)
  "Split a `ghostel-shell'-style SPEC into (PROGRAM . ARGS).
SPEC may be a string (just the program path) or a list whose first
element is the program path and the remaining elements are arguments."
  (cond
   ((stringp spec) (cons spec nil))
   ((and (consp spec) (stringp (car spec)))
    (cons (car spec) (cdr spec)))
   (t (error "Invalid ghostel-shell value: %S" spec))))

(defun ghostel--default-remote-shell-args (program &optional integration)
  "Return default extra args for a remote shell PROGRAM.
Recognized shells (bash, zsh, fish, nushell) start login+interactive
\(`-l -i') so remote sessions source the user's rc/profile files;
unrecognized shells \(e.g. /bin/sh) get no args.  With INTEGRATION active,
bash uses `-i' only (a login bash ignores the integration's `--rcfile')."
  (pcase (ghostel--detect-shell program)
    ('bash (if integration '("-i") '("-l" "-i")))
    ((or 'zsh 'fish 'nu) '("-l" "-i"))
    (_ nil)))

(defun ghostel--resolve-shell-spec ()
  "Return (PROGRAM . EXTRA-ARGS) for the shell to spawn.
For local sessions, splits `ghostel-shell' (string or list).
For remote (TRAMP) sessions, resolves PROGRAM via `ghostel-tramp-shells'
\(see `ghostel--tramp-shell-spec') and returns any explicit per-method
EXTRA-ARGS configured there.  When no explicit args are configured the
caller supplies a type-aware default; see
`ghostel--default-remote-shell-args'."
  (if (file-remote-p default-directory)
      (with-parsed-tramp-file-name default-directory nil
        (let ((spec (or (ghostel--tramp-shell-spec method)
                        (ghostel--tramp-shell-spec t))))
          (cons (or (car spec)
                    (with-connection-local-variables shell-file-name)
                    (car (ghostel--shell-program-and-args ghostel-shell)))
                (cdr spec))))
    (ghostel--shell-program-and-args ghostel-shell)))

(defun ghostel--macos-login-wrap (program args)
  "Wrap PROGRAM/ARGS via `/usr/bin/login' to produce a macOS login shell.
Returns (LOGIN-PROGRAM . LOGIN-ARGS).  Mirrors Ghostty's wrap:

  /usr/bin/login [-q] -flp USER \\
    /bin/bash --noprofile --norc -c \"exec -l PROGRAM [args]\"

`-q' is added when `~/.hushlogin' exists so login(1) suppresses
its banner.  The bash builtin `exec -l' prepends `-' to argv[0]
of the final shell, which is what makes it a login shell.
PROGRAM and ARGS are shell-quoted into the `-c' command."
  (let* ((user (user-login-name))
         (hush (file-exists-p (expand-file-name "~/.hushlogin")))
         (quoted (mapconcat #'shell-quote-argument
                            (cons program args) " "))
         (cmd (concat "exec -l " quoted))
         ;; Quote from Ghostty source:
         ;; We use "bash" instead of other shells that ship with macOS because
         ;; as of macOS Sonoma, we found with a microbenchmark that bash can
         ;; exec into the desired command ~2x faster than zsh.
         (login-args (append (and hush '("-q"))
                             (list "-flp" user
                                   "/bin/bash" "--noprofile" "--norc"
                                   "-c" cmd))))
    (cons "/usr/bin/login" login-args)))


;;; Shell-integration injection

(defun ghostel--setup-local-integration (shell-type ghostel-dir)
  "Set up shell integration for a local SHELL-TYPE spawn.
GHOSTEL-DIR is the package resource root holding `etc/shell/'.
Returns a plist (:env :args) for `ghostel--start-process', or nil for
unrecognized shells or missing bootstrap assets.  Bash's `--posix'
arg makes it honor ENV; the inject script then restores normal mode
with `set +o posix'."
  (pcase shell-type
    ('bash
     (let ((inject-script (expand-file-name
                           "etc/shell/bootstrap/bash/inject.bash"
                           ghostel-dir))
           (env (list "GHOSTEL_BASH_INJECT=1")))
       (when (file-readable-p inject-script)
         (let ((old-env (getenv "ENV")))
           (when old-env
             (push (format "GHOSTEL_BASH_ENV=%s" old-env) env)))
         (push (format "ENV=%s" inject-script) env)
         (unless (getenv "HISTFILE")
           (push (format "HISTFILE=%s/.bash_history"
                         (expand-file-name "~"))
                 env)
           (push "GHOSTEL_BASH_UNEXPORT_HISTFILE=1" env))
         (list :env env :args (list "--posix")))))
    ('zsh
     (let ((zsh-dir (expand-file-name
                     "etc/shell/bootstrap/zsh" ghostel-dir)))
       (when (file-directory-p zsh-dir)
         (let ((env nil)
               (old-zdotdir (getenv "ZDOTDIR")))
           (when old-zdotdir
             (push (format "GHOSTEL_ZSH_ZDOTDIR=%s" old-zdotdir) env))
           (push (format "ZDOTDIR=%s" zsh-dir) env)
           (list :env env)))))
    ;; Fish and nushell both auto-load from XDG_DATA_DIRS
    ((or 'fish 'nu)
     (let ((integ-dir (expand-file-name
                       "etc/shell/bootstrap" ghostel-dir)))
       (when (file-directory-p integ-dir)
         (let ((xdg (or (getenv "XDG_DATA_DIRS")
                        "/usr/local/share:/usr/share")))
           (list :env
                 (list
                  (format "XDG_DATA_DIRS=%s:%s" integ-dir xdg)
                  (format "GHOSTEL_SHELL_INTEGRATION_XDG_DIR=%s"
                          integ-dir)))))))))

(defun ghostel--read-local-file (path)
  "Return the contents of local file PATH as a string."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun ghostel--write-remote-file (tramp-path content)
  "Write CONTENT to TRAMP-PATH on the remote host.
CONTENT may be a unibyte string (e.g. compiled terminfo bytes) or
a multibyte string (e.g. shell rc).  The temp buffer is set unibyte
when CONTENT is unibyte so byte values round-trip without depending
on an outer `coding-system-for-write' binding."
  (with-temp-buffer
    (when (not (multibyte-string-p content))
      (set-buffer-multibyte nil))
    (insert content)
    (write-region (point-min) (point-max) tramp-path nil 'silent)))

(defun ghostel--push-remote-terminfo (remote-prefix)
  "Push bundled compiled terminfo into a temp dir on the remote host.

REMOTE-PREFIX is the TRAMP prefix (e.g. \"/ssh:host:\").  Writes
both the Linux (x/) and macOS (78/) layouts so the remote ncurses
or BSD libcurses finds it regardless of OS.  Returns a plist
\(:env (...) :temp-dirs (...)) suitable for merging into the
remote-integration plist, or nil if the local terminfo isn't
available or the push fails."
  (let ((local-dir (ghostel--terminfo-directory)))
    (when local-dir
      (condition-case err
          (let* ((temp-dir (make-temp-file
                            (concat remote-prefix "ghostel-tinfo-") t))
                 (remote-dir (file-remote-p temp-dir 'localname))
                 (coding-system-for-write 'binary)
                 (coding-system-for-read 'binary))
            (dolist (sub '("x" "g" "78" "67"))
              (let ((src (expand-file-name
                          (pcase sub
                            ((or "x" "78") "xterm-ghostty")
                            ((or "g" "67") "ghostty"))
                          (expand-file-name sub local-dir))))
                (when (file-readable-p src)
                  (let ((bytes (with-temp-buffer
                                 (set-buffer-multibyte nil)
                                 (insert-file-contents-literally src)
                                 (buffer-string)))
                        (dest (concat (file-name-as-directory temp-dir)
                                      sub "/"
                                      (if (member sub '("x" "78"))
                                          "xterm-ghostty"
                                        "ghostty"))))
                    (make-directory (file-name-directory dest) t)
                    (ghostel--write-remote-file dest bytes)))))
            (list :env (list (format "TERMINFO=%s" remote-dir))
                  :temp-dirs (list temp-dir)))
        (error
         (message "ghostel: remote terminfo push failed: %s"
                  (error-message-string err))
         nil)))))

(defun ghostel--cleanup-temp-paths (files dirs)
  "Delete temporary FILES and DIRS created for remote shell integration.
Directories are removed recursively so any contents written into them,
such as a per-session `.zshenv', are cleaned up as well.
Binding `non-essential' keeps TRAMP from opening a new connection (and
possibly prompting for a password) just to delete temp files; when the
remote connection is already gone the paths are simply left behind."
  (let ((non-essential t))
    (dolist (f files)
      (ignore-errors (delete-file f)))
    (dolist (d dirs)
      (ignore-errors (delete-directory d t)))))

(defun ghostel--merge-integration-plists (base extra)
  "Merge EXTRA into BASE plist, appending list values for shared keys.
Used to fold the terminfo-push plist into a shell-rc plist so the
caller sees one combined :env / :temp-dirs / :temp-files."
  (let ((out (copy-sequence base)))
    (dolist (key '(:env :temp-files :temp-dirs))
      (let ((b (plist-get base key))
            (e (plist-get extra key)))
        (when (or b e)
          (setq out (plist-put out key (append b e))))))
    out))

(defun ghostel--setup-remote-integration (shell-type)
  "Set up shell integration on the remote host for SHELL-TYPE.
Reads the local integration script, writes it (with any necessary
preamble) to a temporary file on the remote host.  When the bundled
terminfo is available locally, also pushes it to a remote temp dir
over the same TRAMP connection and adds `TERMINFO=...' to the env.
Returns a plist (:env :args :temp-files :temp-dirs) for
`ghostel--start-process'.
Returns nil on failure."
  (condition-case err
      (let* ((remote-prefix (file-remote-p default-directory))
             (ghostel-dir (ghostel--resource-root))
             (ext (symbol-name shell-type))
             (integration (ghostel--read-local-file
                           (expand-file-name
                            (format "etc/shell/ghostel.%s" ext) ghostel-dir)))
             (tinfo (and (ghostel--ssh-install-enabled-p)
                         (ghostel--push-remote-terminfo remote-prefix)))
             (base (pcase shell-type
                     ;; Bash: --rcfile replaces normal rc loading, so we source
                     ;; startup files explicitly before the integration.
                     ('bash
                      (let* ((temp (make-temp-file
                                    (concat remote-prefix "ghostel-") nil ".bash"))
                             (path (file-remote-p temp 'localname)))
                        (ghostel--write-remote-file
                         temp
                         (concat
                          "# Source standard startup files\n"
                          "if shopt -q login_shell 2>/dev/null; then\n"
                          "  [ -r /etc/profile ] && . /etc/profile\n"
                          "  for __gf in ~/.bash_profile ~/.bash_login ~/.profile; do\n"
                          "    [ -r \"$__gf\" ] && { . \"$__gf\"; break; }; done\n"
                          "  unset __gf\n"
                          "else\n"
                          "  for __gf in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do\n"
                          "    [ -r \"$__gf\" ] && { . \"$__gf\"; break; }; done\n"
                          "  unset __gf\n"
                          "  [ -r ~/.bashrc ] && . ~/.bashrc\n"
                          "fi\n"
                          integration))
                        (list :env nil :args (list "--rcfile" path)
                              :temp-files (list temp))))
                     ;; Zsh: ZDOTDIR replaces .zshenv search, so we restore it,
                     ;; source the user's .zshenv, then load integration.
                     ('zsh
                      (let* ((temp-dir (make-temp-file
                                        (concat remote-prefix "ghostel-") t))
                             (temp-zshenv (concat (file-name-as-directory temp-dir)
                                                  ".zshenv"))
                             (remote-dir (file-remote-p temp-dir 'localname)))
                        (ghostel--write-remote-file
                         temp-zshenv
                         (concat
                          "if [[ -n \"${GHOSTEL_ZSH_ZDOTDIR+X}\" ]]; then\n"
                          "    'builtin' 'export' ZDOTDIR=\"$GHOSTEL_ZSH_ZDOTDIR\"\n"
                          "    'builtin' 'unset' 'GHOSTEL_ZSH_ZDOTDIR'\n"
                          "else\n"
                          "    'builtin' 'unset' 'ZDOTDIR'\n"
                          "fi\n"
                          "{\n"
                          "    'builtin' 'typeset' _ghostel_file="
                          "\"${ZDOTDIR-$HOME}/.zshenv\"\n"
                          "    [[ ! -r \"$_ghostel_file\" ]] || "
                          "'builtin' 'source' '--' \"$_ghostel_file\"\n"
                          "} always {\n"
                          "    if [[ -o 'interactive' ]]; then\n"
                          integration "\n"
                          "    fi\n"
                          "    'builtin' 'unset' '_ghostel_file'\n"
                          "}\n"))
                        (list :env (list (format "ZDOTDIR=%s" remote-dir))
                              :args nil
                              :temp-dirs (list temp-dir))))
                     ;; Fish: -C runs after config, so just source the script.
                     ('fish
                      (let* ((temp (make-temp-file
                                    (concat remote-prefix "ghostel-") nil ".fish"))
                             (path (file-remote-p temp 'localname)))
                        (ghostel--write-remote-file temp integration)
                        (list :env nil
                              :args (list "-C" (format "source %s"
                                                       (shell-quote-argument path)))
                              :temp-files (list temp))))
                     ;; Nushell: --execute runs after config (like fish's -C).
                     ;; nushell `source' needs a parse-time-constant path, so the
                     ;; literal remote temp path is embedded in the --execute arg.
                     ('nu
                      (let* ((temp (make-temp-file
                                    (concat remote-prefix "ghostel-") nil ".nu"))
                             (path (file-remote-p temp 'localname)))
                        (ghostel--write-remote-file temp integration)
                        (list :env nil
                              :args (list "--execute"
                                          (format "source %s"
                                                  (shell-quote-argument path)))
                              :temp-files (list temp)))))))
        (if tinfo
            (ghostel--merge-integration-plists base tinfo)
          base))
    (error
     (message "ghostel: remote shell integration failed: %s"
              (error-message-string err))
     nil)))


;;; Prompt navigation (OSC 133)

(defun ghostel--osc133-marker (type param)
  "Handle an OSC 133 semantic prompt marker from the Zig module.
TYPE is a single character string: A, B, C, D, or P.
PARAM is the exit status string for type D, or nil.
Note: the `ghostel-prompt' text property is applied by the native
render loop (which queries libghostty's per-row semantic state),
not here.  This handler only tracks prompt positions and exit status."
  (pcase type
    ((or "A" "P")
     ;; Prompt start — record line number.  P is the explicit
     ;; prompt-start marker (no fresh-line side effect); both mark
     ;; a navigable prompt position.
     (push (cons (count-lines (point-min) (point-max)) nil)
           ghostel--prompt-positions))
    ("C"
     ;; Command output start — notify `ghostel-command-start-functions'.
     (ghostel--run-hook-safely 'ghostel-command-start-functions
                               (current-buffer))
     (setq ghostel--command-running t))
    ("D"
     ;; Command finished — store exit status on the most recent entry
     ;; and notify `ghostel-command-finish-functions'.
     (let ((exit (and param (string-to-number param))))
       (when (and ghostel--prompt-positions param)
         (setcdr (car ghostel--prompt-positions) exit))
       (ghostel--run-hook-safely 'ghostel-command-finish-functions
                                 (current-buffer) exit))
     (setq ghostel--command-running nil))))

(defun ghostel--run-hook-safely (hook &rest args)
  "Run HOOK with ARGS, isolating errors per handler.
Each handler is wrapped in `with-demoted-errors' so a raising
handler logs and the remaining hooks still run.  As with the rest
of Emacs, `with-demoted-errors' re-signals when `debug-on-error'
is non-nil so the debugger fires for hook authors who want it."
  (run-hook-wrapped
   hook
   (lambda (fn)
     (with-demoted-errors "ghostel: error in hook: %S"
       (apply fn args))
     nil)))

(defun ghostel--prompt-input-start ()
  "From the start of a `ghostel-prompt' region, move past the prefix.
If `ghostel-input' begins on the same line, point lands at its
start; otherwise point lands just past the prompt-prefix region -
the natural position where the user would begin typing."
  (goto-char (or (next-single-property-change
                  (point) 'ghostel-prompt nil (line-end-position))
                 (line-end-position))))

(defun ghostel--navigate-next-prompt (&optional n)
  "Move point to the start of the Nth next prompt region."
  (let ((pos (point)))
    (dotimes (_ (or n 1))
      ;; First skip past the current prompt region if we're inside one.
      (let ((next (next-single-property-change pos 'ghostel-prompt)))
        (when next
          (if (get-text-property next 'ghostel-prompt)
              ;; Landed on the next prompt.
              (setq pos next)
            ;; In a gap — find the next prompt, or stay put.
            (let ((found (next-single-property-change next 'ghostel-prompt)))
              (when found
                (setq pos found)))))))
    (when (and pos (/= pos (point)))
      (goto-char pos)
      (ghostel--prompt-input-start))))

(defun ghostel--navigate-previous-prompt (&optional n)
  "Move point to the start of the Nth previous prompt region."
  (let ((pos (point)))
    (dotimes (_ (or n 1))
      ;; If inside or on a prompt, first skip backward past it.
      (when (or (get-text-property pos 'ghostel-input)
                (and (> pos (point-min))
                     (get-text-property (1- pos) 'ghostel-input)))
        (setq pos (or (previous-single-property-change pos 'ghostel-input)
                      (point-min))))
      (when (or (get-text-property pos 'ghostel-prompt)
                (and (> pos (point-min))
                     (get-text-property (1- pos) 'ghostel-prompt)))
        (setq pos (or (previous-single-property-change pos 'ghostel-prompt)
                      (point-min))))
      ;; Now search backward for the previous prompt.
      (let ((prev (previous-single-property-change pos 'ghostel-prompt)))
        (cond
         (prev
          (setq pos prev)
          ;; If we landed at the end of a prompt, step to its start.
          (when (get-text-property (max (1- pos) (point-min)) 'ghostel-prompt)
            (setq pos (or (previous-single-property-change pos 'ghostel-prompt)
                          (point-min)))))
         ;; No property change before pos, but a prompt may start at point-min.
         ((and (> pos (point-min))
               (get-text-property (point-min) 'ghostel-prompt))
          (setq pos (point-min))))))
    (when (and pos (/= pos (point)))
      (goto-char pos)
      (ghostel--prompt-input-start))))

(defun ghostel-next-prompt (&optional n)
  "Move to the Nth next prompt.
Enters the read-only mode picked by `ghostel-prompt-navigation-input-mode'."
  (interactive "p")
  (unless (memq ghostel--input-mode '(emacs copy))
    (ghostel--enter-readonly-input-mode ghostel-prompt-navigation-input-mode))
  (ghostel--navigate-next-prompt n))

(defun ghostel-previous-prompt (&optional n)
  "Move to the Nth previous prompt.
Enters the read-only mode picked by `ghostel-prompt-navigation-input-mode'."
  (interactive "p")
  (unless (memq ghostel--input-mode '(emacs copy))
    (ghostel--enter-readonly-input-mode ghostel-prompt-navigation-input-mode))
  (ghostel--navigate-previous-prompt n))


;;; OSC 133 imenu integration

;; Each OSC 133 prompt becomes an imenu entry.  Label is
;; "<cwd>  <command>"; target is the prompt prefix's start.
;; Composes with `consult-imenu', `imenu-list', evil's `]m'/`[m'.
;;
;; The cwd is captured at OSC 133 'C' (command-start) and pushed
;; onto `ghostel--imenu-cwds', a chronological list (newest-first).
;; Reading `default-directory' lazily at index time would
;; mis-attribute every prior prompt to the *current* cwd after a `cd'.
;;
;; Position-based tracking (text properties or markers) does not
;; survive: the renderer's per-row delete+reinsert wipes ad-hoc
;; text properties on dirty rows, and `eraseBuffer' (resize-cols,
;; force-full redraw, scrollback edge cases) collapses every marker
;; to `point-min'.  Pairing chronological cwds with the
;; `ghostel-prompt' regions in buffer order at index time is robust
;; to both: resize reflows the grid but preserves prompt order;
;; scrollback eviction is detected as (cwd-count > region-count)
;; and the oldest cwds are dropped to realign.

(defvar-local ghostel--imenu-cwds nil
  "Chronological list of cwds for prompts that have had OSC 133 \\='C\\=' fire.
Pushed at command-start time, so newest-first.  Aligned by order to
the `ghostel-prompt' regions in the buffer when the index is built.")

(defun ghostel--imenu-stamp-cwd (buffer)
  "Record BUFFER's `default-directory' for its most recent submitted command.
Hung off `ghostel-command-start-functions' (OSC 133 \\='C\\=')."
  (with-current-buffer buffer
    (push default-directory ghostel--imenu-cwds)))

(defun ghostel--imenu--collect-prompt-regions ()
  "Return a list of (START . PREFIX-END) for every `ghostel-prompt' region.
Ordered by buffer position (oldest first)."
  (let ((regions nil)
        (pos (point-min))
        (end (point-max)))
    (while (setq pos (text-property-any pos end 'ghostel-prompt t))
      (let ((rend (or (next-single-property-change pos 'ghostel-prompt nil end)
                      end)))
        (push (cons pos rend) regions)
        (setq pos rend)))
    (nreverse regions)))

(defun ghostel--imenu-create-index ()
  "Build an imenu alist of OSC 133 prompts in the current buffer.
Each entry's label is \"<cwd>  <command>\"; cwd is omitted when no
recorded entry aligns with the region (e.g. a still-active prompt
whose \\='C\\=' has not fired).  Empty-command prompts are
skipped.  Labels are truncated to 80 columns."
  (let* ((regions (ghostel--imenu--collect-prompt-regions))
         (cwds (reverse ghostel--imenu-cwds))    ; oldest first
         ;; Scrollback eviction removes prompts from the buffer top
         ;; but leaves cwds in the list.  Drop the oldest cwds so
         ;; the remaining list aligns with the current regions.
         (extra (max 0 (- (length cwds) (length regions))))
         (cwds (nthcdr extra cwds))
         ;; Trim the stored list opportunistically so it doesn't
         ;; grow unboundedly across long sessions.
         (_ (when (> extra 0)
              (setq ghostel--imenu-cwds
                    (seq-take ghostel--imenu-cwds (- (length ghostel--imenu-cwds)
                                                     extra)))))
         (index nil))
    (cl-loop for region in regions
             for cwd = (pop cwds)
             do (let* ((pos (car region))
                       (prompt-end (cdr region))
                       (cmd-end (save-excursion
                                  (goto-char prompt-end)
                                  (line-end-position)))
                       (cmd (string-trim
                             (buffer-substring-no-properties prompt-end cmd-end))))
                  (unless (string-empty-p cmd)
                    (let ((label (if cwd
                                     (format "%s  %s"
                                             (abbreviate-file-name
                                              (directory-file-name cwd))
                                             cmd)
                                   cmd)))
                      (push (cons (truncate-string-to-width label 80 nil nil t)
                                  pos)
                            index)))))
    (nreverse index)))

(defun ghostel--imenu-goto (_name position &rest _)
  "Jump to POSITION, then advance past the prompt prefix.
In semi-char/char modes, first enters the read-only mode picked by
`ghostel-prompt-navigation-input-mode'; line, copy, and Emacs modes
are preserved.  Mirrors the landing position used by
`ghostel-next-prompt'."
  (unless (memq ghostel--input-mode '(emacs line copy))
    (ghostel--enter-readonly-input-mode ghostel-prompt-navigation-input-mode))
  (when (or (< position (point-min)) (> position (point-max)))
    (widen))
  (goto-char position)
  (ghostel--prompt-input-start))

(defun ghostel-imenu-setup ()
  "Wire OSC 133 prompts as imenu entries in the current buffer.
Prompt labels include the command and, when known, the command's
working directory."
  (setq-local imenu-create-index-function #'ghostel--imenu-create-index)
  (setq-local imenu-default-goto-function #'ghostel--imenu-goto)
  (add-hook 'ghostel-command-start-functions
            #'ghostel--imenu-stamp-cwd nil t))


;;; Shell history

(defun ghostel--shell-history-run (command)
  "Run shell COMMAND via `process-file' and return its parsed entries.
Splits the output on NUL when present, else on newline; trims each
entry and drops blanks.  Signals `user-error' on a non-zero exit,
including the command's first stderr line."
  (let ((stderr-file (make-temp-file "ghostel-history")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (process-file "/bin/sh" nil (list t stderr-file) nil
                                      "-c" command)))
            (unless (eql status 0)
              (user-error "Shell history command failed (%s): %s" status
                          (with-temp-buffer
                            (insert-file-contents stderr-file)
                            (buffer-substring (point-min)
                                              (line-end-position)))))
            (let ((output (buffer-string)))
              (split-string output
                            (if (string-search "\0" output) "\0" "\n")
                            t "[ \t\r\n]+"))))
      (delete-file stderr-file))))

(defun ghostel-shell-history ()
  "Return the current buffer's shell history, newest first.
Runs the shell's entry from `ghostel-shell-history-commands' (which
see for the output contract).  Signals `user-error' when the buffer's
shell is unrecognized, no command is configured for it, the command
fails, or the history is empty."
  (ghostel--ensure-ghostel-buffer)
  (let ((shell-type (and ghostel--shell-program
                         (ghostel--detect-shell ghostel--shell-program))))
    (unless shell-type
      (user-error "Buffer has no recognized shell"))
    (let ((command (alist-get shell-type ghostel-shell-history-commands)))
      (unless command
        (user-error
         "No entry for `%s' in `ghostel-shell-history-commands'" shell-type))
      (or (if (functionp command)
              (funcall command)
            (ghostel--shell-history-run command))
          (user-error "History is empty")))))

(provide 'ghostel-shell)
;;; ghostel-shell.el ends here
