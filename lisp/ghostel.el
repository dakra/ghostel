;;; ghostel.el --- Terminal emulator powered by libghostty -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.32.0
;; Keywords: terminals
;; Package-Requires: ((emacs "28.1") (compat "30.1.0.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Ghostel is an Emacs terminal emulator powered by libghostty-vt, the
;; terminal emulation library extracted from the Ghostty project.  A
;; native Zig dynamic module handles VT parsing, terminal state, and
;; rendering, while this Elisp layer manages the shell process, keymap,
;; buffer, and user-facing commands.
;;
;; Usage:
;;
;;   M-x ghostel               Open a new terminal
;;   M-x ghostel-project       Open a terminal in the current project root
;;   M-x ghostel-other         Switch to next terminal or create one
;;   M-x ghostel-next / ghostel-previous
;;                             Cycle through all ghostel buffers
;;   M-x ghostel-list-buffers  Pick a ghostel buffer to switch to
;;   M-x ghostel-project-next / ghostel-project-previous /
;;       ghostel-project-list-buffers
;;                             Same, scoped to the current project
;;
;; Key bindings in the terminal buffer:
;;
;;   Most keys are sent directly to the shell.  Keys in
;;   `ghostel-keymap-exceptions' (C-c, C-x, M-x, etc.) pass through
;;   to Emacs.  Terminal control and navigation use a C-c prefix:
;;
;;   C-c C-c   Interrupt          C-c C-z   Suspend
;;   C-c C-d   EOF                C-c C-\   Quit
;;   C-c C-t   Copy mode          C-c C-y   Paste
;;   C-c C-l   Clear scrollback   C-c C-q   Send next key literally
;;   C-c M-w   Copy scrollback    C-y / M-y Yank / yank-pop
;;   C-c C-n / C-c C-p            Next/previous hyperlink
;;   C-c M-n / C-c M-p            Next/previous prompt (OSC 133)
;;
;; Copy mode (C-c C-t) freezes the display and enables standard Emacs
;; navigation.  Set mark with C-SPC, select text, then M-w to copy.
;;
;; Shell integration:
;;
;;   Directory tracking (OSC 7), prompt navigation (OSC 133), and the
;;   `ghostel_cmd' helper are auto-injected for bash, zsh, and fish —
;;   no shell rc changes needed.  Controlled by `ghostel-shell-integration'
;;   (default t); set it to nil to source etc/shell/ghostel.{bash,zsh,fish}
;;   manually instead.
;;
;; Native module:
;;
;;   A pre-built binary is downloaded automatically on first use.  To
;;   build from source instead (requires Zig 0.15.2+), run zig build
;;   from the project root, or M-x ghostel-module-compile.  M-x
;;   ghostel-download-module re-fetches the pre-built binary.
;;
;; See also: evil-ghostel.el (evil-mode integration), ghostel-compile.el
;; (TTY-backed M-x compile replacement), ghostel-eshell.el (eshell
;; visual-command integration).  TRAMP paths as `default-directory'
;; spawn remote shells; see README.md for details.

;;; Code:

(require 'ansi-color)
(require 'cl-lib)
(require 'comint)
(require 'compat)
(require 'project)
(require 'shell)
(require 'text-property-search)
(require 'tramp)
(require 'url-parse)
(require 'face-remap)

(declare-function bash-completion-capf-nonexclusive "bash-completion")
(declare-function bash-completion-require-process "bash-completion")


;;; Customization

(defgroup ghostel nil
  "Terminal emulator powered by libghostty."
  :group 'terminals
  :prefix "ghostel-")

(defcustom ghostel-shell (or (getenv "SHELL") "/bin/sh")
  "Shell program to run in the terminal.

Either a string (just the executable path) or a list whose first
element is the executable path and whose remaining elements are
arguments passed to that executable.  For example:

  (setq ghostel-shell \\='(\"/bin/zsh\" \"--login\"))

On macOS, ghostel additionally wraps the shell via `login(1)' by
default so the shell starts as a login shell (matching Apple's
Terminal.app and Ghostty), which sources `~/.zprofile' /
`~/.bash_profile' as users expect.  See `ghostel-macos-login-shell'."
  :type '(choice (string :tag "Executable path")
                 (repeat :tag "Executable + arguments" string)))

(defcustom ghostel-term "xterm-ghostty"
  "Value of the TERM environment variable for ghostel processes.

The default \"xterm-ghostty\" advertises ghostel's capability set via
the bundled terminfo entry: synchronized output (DEC 2026), Kitty
keyboard protocol, true color, colored underlines, focus reporting,
and more.  Apps that key off these capabilities — Claude Code, modern
TUIs, neovim, tmux — will use their fast paths.  Notably,
synchronized output eliminates choppy partial-redraw effects when
Claude Code or similar TUIs repaint over a large scrollback.

OSC 52 clipboard is supported (`ghostel-enable-osc52', off by
default) but intentionally NOT advertised in the bundled terminfo,
to avoid silent yank drops when the option is disabled.

Set to \"xterm-256color\" to fall back to a generic terminal.  When
`ghostel-term' is not \"xterm-ghostty\", the bundled terminfo and
`TERM_PROGRAM=ghostty' are not advertised, so nothing claims to be
Ghostty.  This is also the right setting if outbound `ssh' from a
ghostel buffer trips up on remote hosts that lack the xterm-ghostty
terminfo entry."
  :type '(choice (const :tag "Ghostty (recommended)" "xterm-ghostty")
                 (const :tag "Generic xterm-256color" "xterm-256color")
                 (string :tag "Other")))

(defcustom ghostel-environment nil
  "Extra environment variables for ghostel shell processes.

A list of \"KEY=VALUE\" strings, prepended to `process-environment'
before spawning the shell.  A bare \"KEY\" (no `=') unsets the variable.

For local spawns, entries here take precedence over ghostel's own
variables (TERM, INSIDE_EMACS, EMACS_GHOSTEL_PATH,
shell-integration vars), so a user who sets TERM here wins — which
will also disable ghostel's shell integration if the chosen TERM
breaks its assumptions.

Also honored via `dir-locals.el' for per-project overrides.

TRAMP caveats:
- Entries with `=' are propagated to the remote shell.
- TERM/TERMINFO/TERM_PROGRAM/TERM_PROGRAM_VERSION/COLORTERM here
  are ignored for remote spawns and overridden unconditionally by
  the per-spawn `/bin/sh -c' wrapper after `infocmp'-probing the
  remote for `xterm-ghostty' terminfo.  TRAMP's
  `tramp-local-environment-variable-p' filter strips env entries
  that match the local default top-level `process-environment',
  so pushing TERM via env was unreliable; the wrapper exports
  these from inside the remote shell instead, where the filter
  doesn't reach.  Customize `ghostel-term' (locally, or per-host
  via dir-locals or `connection-local-set-profile-variables') to
  change what gets advertised; on a customized branch the wrapper
  exports `TERM=$ghostel-term' only — no `TERM_PROGRAM*' ghostty
  advertisement.  Every other entry in this list still propagates.
- INSIDE_EMACS is rewritten by TRAMP via `tramp-inside-emacs',
  which appends `,tramp:VER' to whatever value is in scope.  For
  ghostel that means the remote shell sees `ghostel,tramp:VER'
  rather than the bare `ghostel' set locally — the leading
  `ghostel' segment is preserved.
- Bare \"KEY\" unset works for TRAMP-sh methods (`ssh', `sudo', ...)
  which emit `unset KEY' in the remote wrapper, but is dropped by
  the generic handler used by `adb' and `sshfs'.

Example: \\='(\"LANG=en_US.UTF-8\" \"CC=clang\")"
  :type '(repeat string))

(defun ghostel--safe-environment-p (value)
  "Return non-nil if VALUE is a valid `ghostel-environment' list.
Used to gate dir-locals application — only a list of strings is
accepted without prompting."
  (and (listp value)
       (seq-every-p #'stringp value)))

(put 'ghostel-environment 'safe-local-variable #'ghostel--safe-environment-p)

(defcustom ghostel-ssh-install-terminfo 'auto
  "Install xterm-ghostty terminfo on remote hosts as needed.
Affects both `M-x ghostel' from a TRAMP `default-directory' (push
over the existing TRAMP connection) and outbound `ssh' from a
local ghostel buffer (install via `tic' on first connection,
cached in `~/.cache/ghostel/ssh-terminfo-cache').

Values: `auto' (default; enabled when
`ghostel-tramp-shell-integration' is non-nil), t, nil.  Always
disabled when `ghostel-term' is not \"xterm-ghostty\".  See the
README for the full design and per-call escape hatch."
  :type '(choice
          (const :tag "Auto (follow `ghostel-tramp-shell-integration')" auto)
          (const :tag "Always" t)
          (const :tag "Never" nil)))

(defcustom ghostel-tramp-shells
  '(("ssh" login-shell)
    ("scp" login-shell)
    ("docker" "/bin/sh"))
  "Shell to use for remote TRAMP connections, per method.
Each entry is (TRAMP-METHOD SHELL [FALLBACK]).  TRAMP-METHOD is a
method string such as \"ssh\" or \"docker\", or t as a catch-all default.

SHELL is either a path string like \"/bin/bash\" or the symbol
`login-shell' to auto-detect the remote user's login shell via
`getent passwd'.  FALLBACK, when present, is used when login-shell
detection fails."
  :type '(alist :key-type (choice string (const t))
                :value-type
                (list (choice string (const login-shell))
                      (choice (const :tag "No fallback" nil) string))))

(defcustom ghostel-max-scrollback (* 5 1024 1024)  ; 5MB
  "Maximum scrollback size in bytes.
5 MB holds roughly 5,000 rows on a typical 80-column terminal
\(fewer on wider terminals — the cost scales with column count).

The full scrollback is materialized into the Emacs buffer so that
`isearch', `consult-line', and other buffer-based commands work
across history.  Each materialized row also lives in the Emacs
buffer with text properties for color/style/links, so the
practical Emacs heap cost is roughly equal to the libghostty
allocation, and large values noticeably slow down sustained
high-throughput output (e.g. `cat huge.log')."
  :type 'integer)

(defcustom ghostel-cell-pixel-scale 'auto
  "Physical-to-logical pixel ratio for cell-size reporting.

Used when answering XTWINOPS queries (CSI 14/16 t) and when telling
libghostty's kitty graphics protocol the cell dimensions.  Image
tools — timg, yazi, tmux passthrough — query the terminal for cell
pixel size to compute placement dimensions; if the value reported is
smaller than what the standalone Ghostty terminal would report, they
either fall back to half-block rendering (timg) or fill more cells
than expected with upscaled, blocky output (yazi).

`auto' computes the display DPI from `display-mm-width' and
`display-pixel-width' and uses DPI/96 directly as a float.  Standard
~96 DPI displays resolve to ~1.0; HiDPI displays (~150 DPI) resolve
to ~1.5; ~192 DPI displays to ~2.0.  If the display's physical size
isn't reported (some multi-monitor setups, virtual displays), falls
back to 1.

This is a heuristic — Emacs has no portable API for the OS-level
backing scale factor, so exact parity with standalone Ghostty
\(which measures cell size in real physical pixels via the window
server) requires setting an explicit number here.  Useful overrides:
the exact `physical_cell_w / frame-char-width' ratio (e.g. 2.28) for
pixel-perfect parity with standalone Ghostty's image rendering, or
1 to opt out of HiDPI-aware reporting altogether.

Note that `image-scaling-factor' is *not* a useful signal here:
Emacs's `auto' resolves it from `frame-char-width' (a font-width
heuristic for image-vs-text scaling), not from the display's DPI
or backing scale factor."
  :type '(choice (const :tag "Auto-detect from display DPI" auto)
                 (number :tag "Explicit ratio")))

(defcustom ghostel-glyph-scale-floor 0.0
  "Minimum scale for glyphs whose font metrics don't fit the cell.
0.0 (default) preserves strict grid alignment.  1.0 disables
shrinking entirely so CJK and other fallback glyphs render at
natural size, potentially making rows slightly taller and cells slightly wider."
  :type '(float 0.0 1.0)
  :local t)

(defcustom ghostel-kitty-graphics-storage-limit (* 320 1024 1024)  ; 320 MiB
  "Kitty graphics image storage cap, in bytes, per terminal.

Caps how much memory libghostty's kitty-graphics image store can
hold per ghostel buffer.  Each transmitted image (PNG bytes or raw
pixels) counts; libghostty evicts the oldest image when a new
transmission would exceed this limit.

Set to 0 to disable kitty graphics entirely — image transmissions
are then ignored and no storage is allocated.  Useful on low-memory
systems or for terminals you know won't display images."
  :type 'integer)

(defcustom ghostel-kitty-graphics-mediums nil
  "Image-loading mediums to enable for the Kitty graphics protocol.

The kitty protocol supports four ways for a program to ship image
data to the terminal:
- direct: base64-encoded inline (always enabled, what timg / yazi use)
- file: program names a local file, terminal reads it
- temp-file: program names a temp file, terminal reads and unlinks it
- shared-mem: program names a POSIX shared-memory region

The non-direct mediums let a *remote* program (over SSH, tmux
passthrough, etc.) instruct ghostel to read arbitrary paths or shared
memory regions on the local machine — a privilege-escalation surface.
The default is nil (none enabled), keeping ghostel safe in remote
sessions while still supporting timg, yazi, and other tools that ship
data inline.  Enable individual mediums by adding `file', `temp-file',
or `shared-mem' to the list, e.g. `(file)' for trusted local-only use."
  :type '(set (const :tag "Local file medium" file)
              (const :tag "Temp-file medium" temp-file)
              (const :tag "Shared-memory medium" shared-mem)))

(defcustom ghostel-timer-delay 0.033
  "Delay in seconds before redrawing after output (roughly 30fps).
When `ghostel-adaptive-fps' is non-nil, this serves as the base
delay between frames during sustained output."
  :type 'number)

(defcustom ghostel-adaptive-fps t
  "Use adaptive frame rate for terminal redraw.
When non-nil, use a shorter initial delay for responsive interactive
feedback and stop the timer entirely when idle.  When nil, use the
fixed `ghostel-timer-delay' unconditionally."
  :type 'boolean)

(defcustom ghostel-immediate-redraw-threshold 256
  "Maximum bytes of output to trigger an immediate redraw.
When output arrives within `ghostel-immediate-redraw-interval'
seconds of the last keystroke and is smaller than this threshold,
redraw immediately instead of waiting for the timer.  This
eliminates the 16-33ms timer delay for interactive typing echo.
Set to 0 to disable immediate redraws."
  :type 'integer)

(defcustom ghostel-immediate-redraw-interval 0.05
  "Maximum seconds since last keystroke for immediate redraw.
Output arriving within this interval of a `ghostel--send-string'
call is considered interactive echo and redrawn immediately
when the output size is below `ghostel-immediate-redraw-threshold'."
  :type 'number)

(defcustom ghostel-input-coalesce-delay 0.003
  "Delay in seconds to coalesce rapid keystrokes before sending.
When non-zero, keystrokes are buffered for up to this many seconds
and sent as a single write to the PTY.  This reduces per-key
syscall overhead during fast typing.  Set to 0 to disable."
  :type 'number)

(defcustom ghostel-full-redraw nil
  "When non-nil, always perform full redraws instead of incremental updates.
Full redraws are more robust with TUI apps like Claude Code that do
aggressive partial screen updates, but may use more CPU."
  :type 'boolean)

(defcustom ghostel-buffer-name "*ghostel*"
  "Default buffer name for ghostel terminals."
  :type 'string)

(defcustom ghostel-project-buffer-scope 'both
  "How `ghostel-project-next', `-previous', and `-list-buffers' scope buffers.
Controls which ghostel buffers are considered part of the current
project:
- `default-directory': match each buffer's `default-directory'
  against the current project root.  Follows shell `cd'.
  A terminal that walked out of the project is excluded; a plain
  `ghostel' buffer that cd'd into the project is included.
- `identity': match each buffer's `ghostel--buffer-identity'
  against the value `project-prefixed-buffer-name' would produce
  for the current project.  Stable across `cd', but only finds
  buffers originally created via `ghostel-project'.
- `both' (default): union of the two - `default-directory' first,
  then identity-matched buffers not already covered."
  :type '(choice (const :tag "Match by buffer default-directory" default-directory)
                 (const :tag "Match by creation-time project identity" identity)
                 (const :tag "Both (union)" both)))

;; Declared before the referent `ghostel-buffer-name-function' per the
;; byte-compiler: the alias should precede the variable it points at.
(define-obsolete-variable-alias 'ghostel-set-title-function
  'ghostel-buffer-name-function "0.32.0")

(defcustom ghostel-buffer-name-function #'ghostel-buffer-name-by-title
  "Function returning the ghostel buffer name, or nil to leave it unchanged.
Called in the ghostel buffer with one argument, the terminal TITLE (the
OSC 2 string; may be nil or empty), on both a title change and a `cd' \(OSC 7).
Read `default-directory' for the current directory.
Renames the buffer to the returned string, declining after a manual rename.
Set to nil to disable renaming entirely."
  :type '(choice (const :tag "Disabled" nil)
                 (function-item :tag "By title — *ghostel: TITLE*"
                                ghostel-buffer-name-by-title)
                 (function-item :tag "By directory — *ghostel: DIR*"
                                ghostel-buffer-name-by-directory)
                 (function :tag "Custom function")))

(defcustom ghostel-kill-buffer-on-exit t
  "Kill the buffer when the shell process exits."
  :type 'boolean)

(defcustom ghostel-query-before-killing 'auto
  "Whether to confirm before killing a live ghostel buffer or exiting Emacs.

The value controls the process query-on-exit flag (see
`set-process-query-on-exit-flag'), which Emacs honours both when
killing the buffer and when exiting Emacs while the buffer is live.

t      Always query while the shell process is alive.
nil    Never query.
auto   Query only while a shell command is running.  Requires OSC 133 shell
       integration: at a prompt the flag is nil, and it flips to t between
       the OSC 133 C (command start) and D (command finish) markers."
  :type '(choice (const :tag "Always" t)
                 (const :tag "Never" nil)
                 (const :tag "While a command is running" auto)))

(defcustom ghostel-exit-functions nil
  "Hook run when the terminal process exits.
Each function is called with two arguments: the buffer and the
exit event string."
  :type 'hook)

(defcustom ghostel-command-finish-functions
  '(ghostel--query-before-killing-on-cmd-finish)
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
  :type 'hook)

(defcustom ghostel-command-start-functions
  '(ghostel--query-before-killing-on-cmd-start)
  "Hook run when a shell command starts running (OSC 133 C marker).
Each function is called with one argument: the buffer.

Requires shell integration; this fires from the shell's
preexec/DEBUG hook just before the user's command runs.  Useful
for distinguishing a real command's lifecycle from prompt
redraws (which emit D markers without a preceding C).

Errors in hook functions are demoted to messages via
`with-demoted-errors' (re-signalled when `debug-on-error' is
non-nil so the debugger can fire)."
  :type 'hook)

(defcustom ghostel-pre-spawn-hook nil
  "Hook run inside `ghostel--spawn-pty' just before `make-process'.
Each function is called with no arguments in the buffer that will
host the new process.  `process-environment' is dynamically bound
to the env that will be passed to the child, so hook functions can
inject or override entries with `setenv' and the spawned process
inherits them.

Use this hook for one-time pre-spawn setup; see `ghostel-environment'
for static env entries that don't depend on runtime state."
  :type 'hook)

(defcustom ghostel-eval-cmds '(("find-file" find-file)
                               ("find-file-other-window" find-file-other-window)
                               ("dired" dired)
                               ("dired-other-window" dired-other-window)
                               ("message" message))
  "Whitelisted Emacs functions callable from the terminal via OSC 52;e.
Each entry is (NAME FUNCTION) where NAME is the string sent from
the shell and FUNCTION is the Elisp function to invoke.
All arguments are passed as strings."
  :type '(alist :key-type string :value-type function))

(defcustom ghostel-enable-osc52 nil
  "Allow terminal applications to set the clipboard via OSC 52.
When non-nil, programs running in the terminal can copy text to the
Emacs kill ring and system clipboard using OSC 52 escape sequences.
This is useful for remote SSH sessions where the application cannot
access the local clipboard directly.

Disabled by default for security: a malicious escape sequence in
command output could silently overwrite your clipboard."
  :type 'boolean)

(defcustom ghostel-password-prompt-regex comint-password-prompt-regexp
  "Regex matched against the cursor row to detect a password prompt.
Used when the libghostty heuristic (canonical mode + echo off via
`ghostel--pty-password-input-p') can't decide on its own - that is, when
the local pty's termios was unreadable, or when `ghostel--remote-shell-p'
indicates a remote shell whose echo state isn't reflected on the local pty."
  :type 'regexp)

(defcustom ghostel-password-prompt-functions
  '(ghostel--default-password-source)
  "Sources tried in order to obtain a password when one is needed.
Each function is called with one argument — ROW, the trimmed text
of the cursor's row at the moment the prompt was detected, or
nil when the row text isn't available.  Called inside the ghostel
buffer when `ghostel--password-mode-p' transitions from nil to t.
Should return a string (the password) or nil to defer to the next
function.  The first non-nil return wins; ghostel sends that
string + carriage return to the subprocess and clears the wire
copy.  Beware: returning an empty string \"\" is treated as a
hit (sudo will see it as a wrong password and re-prompt) — guard
your sources to return nil on miss; never default a miss to \"\".

The default `ghostel--default-password-source' reads with
`read-passwd' and so always returns (unless the user
`keyboard-quit's, which propagates).

To plug in `auth-source' (or keepass, pass, etc) prepend a function that
returns the looked-up secret on hit, nil on miss; the default acts as
the fallback.  `default-directory' carries the TRAMP remote host when
ghostel was spawned through TRAMP, so the same handler works for `sudo'
on the local box and on a remote one:

  (defun my-ghostel-auth-source (row)
    (let* ((user (and row
                      (string-match
                       \"\\\\[sudo\\\\] .+ for \\\\([^:]+\\\\):\" row)
                      (match-string 1 row)))
           (host (or (file-remote-p default-directory \\='host)
                     (system-name))))
      (and user
           (auth-source-pick-first-password :host host :user user))))

  (add-hook \\='ghostel-password-prompt-functions #\\='my-ghostel-auth-source)"
  :type 'hook)

(defcustom ghostel-detect-password-prompts t
  "Whether ghostel watches for password prompts and pops `read-passwd'.
When non-nil (the default), the libghostty heuristic and cursor-row
regex run after each redraw and `read-passwd' is invoked on a rising
edge.  See `ghostel--detect-password-prompt'."
  :type 'boolean)

(defcustom ghostel-password-prompt-debounce 0.2
  "Seconds to wait after a rising edge before opening `read-passwd'.
When the canonical+!echo heuristic first fires, ghostel waits this
long and re-checks before invoking `ghostel-password-prompt-functions'.
Sub-debounce flips (e.g. shell quirks that flap echo briefly) never
reach the user - matching ghostty's natural 200 ms termios polling
cadence.  Set to 0 to open the prompt immediately."
  :type 'number)

(defcustom ghostel-notification-function #'ghostel-default-notify
  "Function called for OSC 9 / OSC 777 desktop notifications.
Called with two string arguments: TITLE and BODY.  Title is empty
for iTerm2-style OSC 9 notifications, which only carry a body.
Set to nil to ignore notifications.

The handler is invoked asynchronously via `run-at-time', with the
originating ghostel buffer as `current-buffer', so it may block or
spawn processes freely without stalling the terminal."
  :type '(choice (const :tag "Disabled" nil) function))

(defcustom ghostel-progress-function
  (if (locate-library "spinner")
      #'ghostel-spinner-progress
    #'ghostel-default-progress)
  "Function called for ConEmu OSC 9;4 progress reports.
Called with two arguments: STATE (one of the symbols `remove',
`set', `error', `indeterminate', `pause') and PROGRESS (an integer
0-100, or nil when not reported).  Set to nil to ignore progress
reports.

When spinner.el is on the `load-path' at ghostel load time, the
default is `ghostel-spinner-progress' (which animates the mode
line during indeterminate progress).  Otherwise it is
`ghostel-default-progress' (a plain text indicator).

The handler runs synchronously on the VT-parser callpath because
progress updates are expected to feed the mode line or similar
cheap UI.  A slow handler here will stall terminal output — defer
expensive work via `run-at-time' on your own if you need it."
  :type '(choice (const :tag "Disabled" nil) function))

(defcustom ghostel-spinner-type 'progress-bar
  "Spinner style used by `ghostel-spinner-progress'.
Passed to `spinner-create' as its first argument; see
`spinner-types' in spinner.el for the full list (e.g.
`progress-bar', `horizontal-moving', `vertical-breathing').
Only consulted when `ghostel-progress-function' is
`ghostel-spinner-progress'."
  :type 'symbol)

(defcustom ghostel-enable-url-detection t
  "Automatically detect and linkify URLs in terminal output.
When non-nil, plain-text URLs (http:// and https://) are made
clickable even if the program did not use OSC 8 hyperlink escapes."
  :type 'boolean)

(defcustom ghostel-enable-file-detection t
  "Automatically detect and linkify file:line references in terminal output.
When non-nil, patterns like /path/to/file.el:42 are made clickable,
opening the file at the given line in another window.  Automatically
disabled when `default-directory' is a TRAMP path, because each
candidate would require a remote `file-exists-p' round-trip per
redraw."
  :type 'boolean)

(defcustom ghostel-plain-link-detection-delay 0.1
  "Delay in seconds before redraw-triggered plain-text link detection runs.
Redraws queue URL/file detection through
`ghostel--schedule-link-detection' so multiple updates can be
coalesced into a single scan.  Set to 0 to scan immediately after each
redraw.  Native OSC-8 hyperlinks remain applied during redraw."
  :type 'number)

(defcustom ghostel-file-detection-path-regex
  "[~[:alnum:]_.-]*/[^] \t\n\r:\"<>(){}[`']+"
  "Regex matching the PATH portion of a file:line[:col] reference.
This is the middle of the full detection pattern; ghostel wraps it
with a fixed leading path-boundary anchor (line start or any
non-path character) and a fixed `:LINE[:COL]' tail, so any match
is guaranteed to end in `:DIGITS'.

The matched path is resolved against `default-directory'; linkification
only applies when that file exists.  The default matches absolute
paths, explicit `./' paths, tilde-prefixed paths like `~/file.el',
and bare relative paths containing at least one `/' (e.g. compiler
output like `src/main.rs').  Paths embedded in punctuation like
`(/home/user/index.js:17:5)' are supported via the fixed anchor.

Performance: each match triggers a filesystem check on every redraw.
Broadening this pattern (for example to match bare `file.go' without
a `/') will cause `file-exists-p' to be called for every matching
token, which can be expensive on slow or network filesystems (NFS,
FUSE).  The default uses non-backtracking character classes so the
per-redraw scan stays cheap."
  :type 'regexp)

(defconst ghostel--file-detection-leading-anchor
  "\\(?:^\\|[^[:alnum:]_./~-]\\)"
  "Fixed anchor placed before `ghostel-file-detection-path-regex'.")

(defconst ghostel--file-detection-tail
  "\\(?::[0-9]+\\(?::[0-9]+\\)?\\)?"
  "Fixed optional `:LINE[:COL]' tail.
When absent, the match is linkified as a bare file/directory
reference opened at its start.")

(defcustom ghostel-module-directory nil
  "Directory holding the ghostel native module.
When nil (the default), the module is read from and written to the
ghostel package directory.  Set this to a path outside your package
manager's tree (for example, \"~/.config/emacs/ghostel/\") so that
rebuilds or re-installs by the package manager do not delete or
overwrite the module file while Emacs has it loaded."
  :type '(choice (const :tag "Use package directory" nil)
                 (directory :tag "Custom directory")))

(defcustom ghostel-module-auto-install 'ask
  "What to do when the native module is missing at first interactive use.
This setting is consulted only when the user invokes an interactive
entry point such as `\\[ghostel]', not when `ghostel.el' is loaded
or byte-compiled - loading the file never prompts or downloads.
\\=`ask'      - prompt with a choice to download, compile, or skip (default).
\\=`download' - download a pre-built binary from GitHub releases.
\\=`compile'  - build from source via `ghostel-module-compile'.
nil        - do nothing; the user must install the module manually."
  :type '(choice (const :tag "Ask interactively" ask)
                 (const :tag "Download pre-built binary" download)
                 (const :tag "Compile from source" compile)
                 (const :tag "Do nothing" nil)))

(defcustom ghostel-shell-integration t
  "Automatically inject shell integration on startup.
When non-nil, ghostel modifies the shell invocation to automatically
load shell integration scripts without requiring changes to the user's
shell configuration files.  Supports bash, zsh, and fish."
  :type 'boolean)

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
  :type 'boolean)

(defcustom ghostel-tramp-shell-integration nil
  "Inject shell integration for remote TRAMP sessions.
When non-nil, ghostel writes integration scripts to a temporary
file on the remote host and configures the shell to source them.
Set to t for all supported shells, or a list of symbols
\(e.g. \\='(bash zsh)) for specific shells only."
  :type '(choice (const :tag "Disabled" nil)
                 (const :tag "All shells" t)
                 (repeat :tag "Specific shells"
                         (choice (const bash) (const zsh) (const fish)))))

(defcustom ghostel-tramp-default-method nil
  "TRAMP method for constructing remote paths from OSC 7 directory reports.
When directory tracking (OSC 7) reports a hostname that does not match
the local machine and `default-directory' has no existing remote prefix,
this method is used to build the TRAMP path (e.g. \"/ssh:host:/path\").
When nil, falls back to `tramp-default-method'."
  :type '(choice (const :tag "Use tramp-default-method" nil)
                 string))

(defcustom ghostel-keymap-exceptions
  '("C-c" "C-x" "C-u" "C-h" "M-x" "M-:" "C-\\")
  "Key sequences that should not be sent to the terminal.
These keys pass through to Emacs instead."
  :type '(repeat string)
  :initialize #'custom-initialize-default
  :set (lambda (sym newval)
         (set-default sym newval)
         (ghostel--rebuild-semi-char-keymap)))

(defcustom ghostel-ignore-cursor-change nil
  "When non-nil, ignore terminal requests to change cursor shape or visibility.
Useful when editor-owned cursor behavior should take precedence over
terminal-driven cursor changes.  Copy mode restores `cursor-type' to its
default value."
  :type 'boolean)

;; Forward declaration for the `ghostel-readonly-fast-exit' :set function.
(defvar ghostel--input-mode)

(defcustom ghostel-readonly-fast-exit t
  "When non-nil, copy and Emacs modes exit on `q', `C-g', or any self-insert key.
The triggering character is forwarded to the terminal when exiting
returns to a mode that accepts terminal input (semi-char or char).

When nil, exit only via an explicit input-mode switch
\(`ghostel-semi-char-mode', `ghostel-char-mode', etc.).  Standard
self-inserting keys still hit the read-only barrier and produce
the usual \"Buffer is read-only\" signal.

Toggling this through `customize-variable' or `setopt' rebinds
the local map in every buffer currently in copy or Emacs mode, so
the change takes effect immediately.  Plain `setq' bypasses the custom setter
and affected buffers will pick up the new value on the next mode transition."
  :type 'boolean
  :initialize #'custom-initialize-default
  :set (lambda (sym newval)
         (set-default sym newval)
         (dolist (buf (buffer-list))
           (with-current-buffer buf
             (when (memq ghostel--input-mode '(copy emacs))
               (use-local-map (ghostel--readonly-keymap)))))))

(defcustom ghostel-readonly-fake-cursor t
  "When non-nil, draw a hint cursor at the live terminal position.
Active in copy and Emacs modes whenever point is somewhere other than
the live terminal cursor - the hint shows where new output will land.

The hint's shape follows `cursor-in-non-selected-windows':
hollow and box render as their respective faces; nil hides the
hint; t derives the shape from the saved `cursor-type' (box
variants render as hollow); bar and hbar fall back to hollow.
Customize the faces `ghostel-fake-cursor' and
`ghostel-fake-cursor-box' to tune the appearance."
  :type 'boolean)

(defcustom ghostel-mouse-drag-input-mode 'copy
  "Input mode to switch to after a left-button drag or multi-click selects text.

- `copy' (default): enter `ghostel-copy-mode'.  Pauses redraws -
  the selection is stable and the buffer is read-only.
- `emacs': enter `ghostel-emacs-mode'.  Terminal output keeps
  streaming; the buffer is read-only.  Pick this when you do not
  want the terminal to pause for a selection.
- nil: stay in semi-char.  Best-effort - the selection could get
  clobbered by the next redraw, and `M-w' is not bound here.

Has no effect when a DEC mouse-tracking mode (1000/1002/1003) is
active (the press is forwarded to the program) or when the buffer
is not in semi-char-mode when the drag completes."
  :type '(choice (const :tag "Copy mode (default)" copy)
                 (const :tag "Emacs mode"          emacs)
                 (const :tag "Do not switch"       nil)))

(defcustom ghostel-word-boundary-string " \t\"'`|:;,()[]{}<>$│"
  "Characters that terminate words in ghostel buffers.

Mirrors Ghostty's `selection-word-chars' default.  Characters not listed
here are word constituents, so double-click selects whole hostnames
\(`api.example.com') and paths (`~/src/foo/bar.txt').

The value is realized into `ghostel-mode-syntax-table', which drives mouse
word selection and word-based motion/search.
Use `setopt' or `customize-set-variable' so the table is rebuilt."
  :type 'string
  :initialize #'custom-initialize-default
  :set (lambda (sym newval)
         (set-default sym newval)
         (when (boundp 'ghostel-mode-syntax-table)
           (ghostel--rebuild-mode-syntax-table))))

(defvar ghostel-mode-syntax-table (make-syntax-table)
  "Syntax table for `ghostel-mode'.")

(defun ghostel--rebuild-mode-syntax-table ()
  "Realize `ghostel-word-boundary-string' into `ghostel-mode-syntax-table'.

Mutates the table in place, so live ghostel buffers keep their
buffer-local syntax-table reference and see customization changes.

Printable ASCII starts as word syntax; configured boundaries become plain
punctuation.  Keeping boundaries as `.' (not paren/string syntax) prevents
double-click selection from invoking `forward-sexp'.
Whitespace keeps whitespace syntax."
  (cl-loop for ch from ?! to ?~
           do (modify-syntax-entry ch "w" ghostel-mode-syntax-table))
  (dolist (ch (string-to-list ghostel-word-boundary-string))
    (unless (memq ch '(?\s ?\t ?\n ?\r ?\f ?\v))
      (modify-syntax-entry ch "." ghostel-mode-syntax-table))))

(ghostel--rebuild-mode-syntax-table)

(defcustom ghostel-scroll-on-input t
  "Automatically scroll to the bottom when typing in the terminal.
When non-nil, any character typed while the viewport is scrolled
into the scrollback will first jump to the bottom of the terminal
before sending the input."
  :type 'boolean)

(defcustom ghostel-github-release-url
  "https://github.com/dakra/ghostel/releases"
  "Base URL for Ghostel GitHub releases.
Customize this when downloading pre-built modules from a fork or mirror."
  :type 'string)

(defcustom ghostel-line-mode-history-size 200
  "Maximum number of lines kept in `ghostel--line-mode-history'."
  :type 'integer)

(defcustom ghostel-line-mode-completion-at-point-functions
  '(comint-completion-at-point)
  "Capfs activated for \\=`TAB\\=' in `ghostel-line-mode'.
Each function is called inside a `save-restriction' narrowed to the
editable input region, so it sees only the user's typed text — not
the prompt or the surrounding scrollback.

The default `comint-completion-at-point' dispatches through
`comint-dynamic-complete-functions' (set up via
`shell-completion-vars'), which gives filename completion, env-var
completion, command completion from \\=`PATH\\=', `pcomplete'
integration, and history expansion."
  :type '(repeat function))

(defcustom ghostel-line-mode-use-bash-completion 'auto
  "Whether to layer bash programmable completion onto line-mode \\=`TAB\\='.
When non-nil, `bash-completion-capf-nonexclusive' is prepended to
`ghostel-line-mode-completion-at-point-functions' at completion
time.  The capf is non-exclusive, so when bash returns no
candidates the standard comint stack still runs.

- `auto' (default): enable when the `bash-completion' package
  loads cleanly; do nothing when it isn't installed.
- t: require it; signal an error if it is missing.
- nil: never use it.

The bash-completion package spawns a hidden bash subprocess that
sources the user's startup files, so registrations like
\"complete -F _git git\" become available — TAB after \"git
checkout \" lists branch names, etc."
  :type '(choice (const :tag "Auto-detect" auto)
                 (const :tag "Always (require)" t)
                 (const :tag "Never" nil)))

(defcustom ghostel-line-mode-bash-completion-prespawn nil
  "When non-nil, eagerly start the bash-completion subprocess on line-mode entry.
Off by default — the first \\=`TAB\\=' inside line mode pays the
~500ms-1s cost of spawning the hidden bash process and sourcing
the user's startup files; subsequent completions are fast.  Set
this to t to amortise that cost at line-mode entry time so the
first completion feels instant.

Has no effect when `ghostel-line-mode-use-bash-completion' is nil
or when the `bash-completion' package is not installed."
  :type 'boolean)

(defcustom ghostel-prompt-regexp
  "^[^#$%>λ❯→➜\n]*[#$%>λ❯→➜]+ *"
  "Regexp matching a prompt prefix at the beginning of a line.
Consulted as a fallback by `ghostel-input-start-point' and
`ghostel-beginning-of-input-or-line' when the row has no
`ghostel-prompt' text property (i.e. no OSC 133 shell integration).

The default recognizes:
- Standard shell prompts: `$ ', `# ', `% ', `> '
- Python and similar REPLs: `>>> '
- Themed prompts: `λ ', `❯ ' (Starship/Pure/Powerlevel10k),
  `➜ ' (oh-my-zsh robbyrussell), `→ '

The negated character class `[^#$%>λ❯→➜\\n]*' forces the match to
stop at the *first* prompt character on the line, so command lines
echoed into scrollback (e.g. `$ echo $foo') are detected by their
leading prompt prefix rather than a `$' deeper in the line.

Trade-off: any line that *starts* with one of these characters is
treated as a prompt line.  Diff output (`> excluded'), markdown
headings (`# Heading'), and lines like `5 > 3' will yield false
positives for column-aware motions.  OSC 133 integration is the
robust fix - see the README's shell-integration section.

Customize this variable to add or replace prompt characters for
prompts the default doesn't catch (e.g., `▶ ', `» ', `🦀 ').  Set
to nil to disable the regex fallback entirely (OSC 133 only)."
  :type '(choice (const :tag "Disable" nil)
                 (regexp :tag "Regexp")))


;;; ANSI color faces

(defface ghostel-color-black
  '((t :inherit ansi-color-black))
  "Face used to render black color code.")

(defface ghostel-color-red
  '((t :inherit ansi-color-red))
  "Face used to render red color code.")

(defface ghostel-color-green
  '((t :inherit ansi-color-green))
  "Face used to render green color code.")

(defface ghostel-color-yellow
  '((t :inherit ansi-color-yellow))
  "Face used to render yellow color code.")

(defface ghostel-color-blue
  '((t :inherit ansi-color-blue))
  "Face used to render blue color code.")

(defface ghostel-color-magenta
  '((t :inherit ansi-color-magenta))
  "Face used to render magenta color code.")

(defface ghostel-color-cyan
  '((t :inherit ansi-color-cyan))
  "Face used to render cyan color code.")

(defface ghostel-color-white
  '((t :inherit ansi-color-white))
  "Face used to render white color code.")

(defface ghostel-color-bright-black
  '((t :inherit ansi-color-bright-black))
  "Face used to render bright black color code.")

(defface ghostel-color-bright-red
  '((t :inherit ansi-color-bright-red))
  "Face used to render bright red color code.")

(defface ghostel-color-bright-green
  '((t :inherit ansi-color-bright-green))
  "Face used to render bright green color code.")

(defface ghostel-color-bright-yellow
  '((t :inherit ansi-color-bright-yellow))
  "Face used to render bright yellow color code.")

(defface ghostel-color-bright-blue
  '((t :inherit ansi-color-bright-blue))
  "Face used to render bright blue color code.")

(defface ghostel-color-bright-magenta
  '((t :inherit ansi-color-bright-magenta))
  "Face used to render bright magenta color code.")

(defface ghostel-color-bright-cyan
  '((t :inherit ansi-color-bright-cyan))
  "Face used to render bright cyan color code.")

(defface ghostel-color-bright-white
  '((t :inherit ansi-color-bright-white))
  "Face used to render bright white color code.")

(defface ghostel-fake-cursor
  '((t :box (:line-width (-1 . -1))))
  "Face for the hollow hint cursor drawn in copy and Emacs modes.")

(defface ghostel-fake-cursor-box
  '((t :inherit cursor))
  "Face for the solid hint cursor drawn for box-style cursors.
Used when `cursor-in-non-selected-windows' resolves to box.")

(defvar ghostel-color-palette
  [ghostel-color-black
   ghostel-color-red
   ghostel-color-green
   ghostel-color-yellow
   ghostel-color-blue
   ghostel-color-magenta
   ghostel-color-cyan
   ghostel-color-white
   ghostel-color-bright-black
   ghostel-color-bright-red
   ghostel-color-bright-green
   ghostel-color-bright-yellow
   ghostel-color-bright-blue
   ghostel-color-bright-magenta
   ghostel-color-bright-cyan
   ghostel-color-bright-white]
  "Color palette for the terminal (vector of 16 face names).")


;; Declare native module functions for the byte compiler

(declare-function ghostel--encode-key "ghostel-module")
(declare-function ghostel--focus-event "ghostel-module")
(declare-function ghostel--mode-enabled "ghostel-module")
(declare-function ghostel--alt-screen-p "ghostel-module")
(declare-function ghostel--copy-all-text "ghostel-module")
(declare-function ghostel--module-version "ghostel-module")
(declare-function ghostel--mouse-event "ghostel-module")
(declare-function ghostel--new "ghostel-module")
(declare-function ghostel--get-title "ghostel-module" (term))
(declare-function ghostel--redraw "ghostel-module" (term &optional full))
(declare-function ghostel--set-bold-config "ghostel-module")
(declare-function ghostel--set-default-colors "ghostel-module")
(declare-function ghostel--set-palette "ghostel-module")
(declare-function ghostel--set-size "ghostel-module" (term rows cols &optional cell-w cell-h))
(declare-function ghostel--write-input "ghostel-module")
(declare-function ghostel--pty-password-input-p "ghostel-module" (path))

(declare-function spinner-create "spinner")
(declare-function spinner-start "spinner")
(declare-function spinner-stop "spinner")


;;; Automatic download and compilation of native module

(defconst ghostel--minimum-module-version "0.32.0"
  "Minimum native module version required by this Elisp version.
Bump this only when the Elisp code requires a newer native module
\(e.g. new Zig-exported function or changed calling convention).")

(defun ghostel--module-platform-tag ()
  "Return platform tag for the current system, e.g. \"x86_64-linux\".
Returns nil if the platform is not recognized."
  (let* ((raw-arch (car (split-string system-configuration "-")))
         (arch (pcase raw-arch
                 ("amd64" "x86_64")
                 ("arm64" "aarch64")
                 (_ raw-arch)))
         (os (cond
              ((eq system-type 'darwin) "macos")
              ((eq system-type 'gnu/linux) "linux")
              (t nil))))
    (when os
      (format "%s-%s" arch os))))

(defun ghostel--module-asset-name ()
  "Return the expected release asset file name for the current platform."
  (let ((tag (ghostel--module-platform-tag)))
    (when tag
      (format "ghostel-module-%s%s" tag module-file-suffix))))

(defun ghostel--module-download-url (&optional version)
  "Return the download URL for the current platform's pre-built module.
When VERSION is nil, use the latest release download URL."
  (let ((asset-name (ghostel--module-asset-name)))
    (when asset-name
      (if version
          (format "%s/download/v%s/%s"
                  ghostel-github-release-url version asset-name)
        (format "%s/latest/download/%s"
                ghostel-github-release-url asset-name)))))

(defun ghostel--release-version-from-url (url)
  "Return the release version embedded in URL, or nil.
GitHub's `/releases/latest/download/<asset>' redirect resolves to
`/releases/download/v<X.Y.Z>/<asset>'; extract the X.Y.Z segment."
  (when (and url
             (string-match "/releases/download/v\\([0-9]+\\.[0-9]+\\.[0-9]+\\)/"
                           url))
    (match-string 1 url)))

(defun ghostel--download-module (dir &optional version latest-release)
  "Download a pre-built module into DIR.
When VERSION is non-nil, download that release tag.
When LATEST-RELEASE is non-nil, use the latest release asset URL.
On success, also writes the sidecar version file alongside the module.
Returns non-nil on success."
  (condition-case err
      (let* ((requested-version (unless latest-release
                                  (or version ghostel--minimum-module-version)))
             (url (ghostel--module-download-url requested-version)))
        (when url
          (unless (string-prefix-p "https://" url)
            (error "Refusing non-HTTPS download URL: %s" url))
          (make-directory dir t)
          (let ((dest (expand-file-name
                       (concat "ghostel-module" module-file-suffix) dir))
                (sidecar (ghostel--module-sidecar-path dir)))
            ;; Drop any pre-existing sidecar so that, if the download or the
            ;; subsequent sidecar write fails partway, the loader sees `absent'
            ;; rather than `stale' (refuse to map a fresh module).
            (when (file-exists-p sidecar)
              (delete-file sidecar))
            (message "ghostel: downloading native module from %s..." url)
            (when-let* ((final-url (ghostel--download-file url dest)))
              ;; Resolve the version that was actually fetched.  For an
              ;; explicit version we trust the request; for `latest' we
              ;; parse the URL the server redirected us to.  If parsing
              ;; fails we fall back to the minimum so the sidecar still
              ;; reflects a safe lower bound.
              (let ((resolved (or requested-version
                                  (ghostel--release-version-from-url final-url)
                                  ghostel--minimum-module-version)))
                (ghostel--write-module-sidecar-version dir resolved))
              (message "ghostel: native module downloaded successfully")
              t))))
    (error
     (message "ghostel: download failed: %s" (error-message-string err))
     nil)))

(defun ghostel--compile-module (dest-dir)
  "Compile the native module from source and install it in DEST-DIR.
The build runs in `ghostel--resource-root' (which holds build.zig);
on success the produced module and its sidecar are moved into DEST-DIR."
  (let* ((source-dir (ghostel--resource-root))
         (default-directory source-dir))
    (message "ghostel: compiling native module with zig build (this may take a moment)...")
    (condition-case err
        (let ((ret (process-file "zig" nil "*ghostel-build*" nil
                                 "build" "-Doptimize=ReleaseFast" "-Dcpu=baseline")))
          (if (not (eq ret 0))
              (display-warning 'ghostel
                               "Module compilation failed.  See *ghostel-build* buffer for details.")
            (let* ((file-name (concat "ghostel-module" module-file-suffix))
                   (built (expand-file-name file-name source-dir))
                   (final (expand-file-name file-name dest-dir)))
              (cond
               ((not (file-exists-p built))
                (display-warning 'ghostel
                                 (format "Build succeeded but module not produced at %s"
                                         built)))
               ((equal built final)
                (message "ghostel: native module compiled successfully"))
               (t
                (ghostel--install-module-pair
                 built final
                 (expand-file-name "ghostel-module.version" source-dir)
                 (expand-file-name "ghostel-module.version" dest-dir))
                (message "ghostel: native module compiled successfully"))))))
      (file-missing
       (display-warning 'ghostel
                        (format "zig executable not found while compiling in %s" source-dir)))
      (error
       (display-warning 'ghostel (error-message-string err))))))

(defun ghostel--ensure-module (dir)
  "Ensure the native module exists in DIR.
Behavior is controlled by `ghostel-module-auto-install'."
  (let ((action ghostel-module-auto-install))
    (when (eq action 'ask)
      (setq action (ghostel--ask-install-action dir)))
    (pcase action
      ('download (ghostel--download-module dir))
      ('compile  (ghostel--compile-module dir))
      (_         nil))))

(defun ghostel--read-module-download-version ()
  "Prompt for a release tag to download, or nil for the latest release."
  (let ((version (read-string
                  (format "Ghostel module version (>= %s, empty for latest): "
                          ghostel--minimum-module-version))))
    (unless (string= version "")
      (when (version< version ghostel--minimum-module-version)
        (user-error "Version %s is older than minimum supported version %s"
                    version ghostel--minimum-module-version))
      version)))

(defun ghostel--ask-install-action (_dir)
  "Prompt the user to choose how to install the missing native module.
Returns \\='download, \\='compile, or nil."
  (let* ((url (or (ghostel--module-download-url ghostel--minimum-module-version)
                  "GitHub releases"))
         (choice (read-char-choice
                  (format "Ghostel native module not found.

  [d] Download pre-built binary from:
      %s
  [c] Compile from source via build.sh
  [s] Skip — install manually later

Choice: " url)
                  '(?d ?c ?s))))
    (pcase choice
      (?d 'download)
      (?c 'compile)
      (?s nil))))

(defun ghostel--download-file (url dest)
  "Download URL to DEST atomically.  Return the final URL on success, else nil.
The returned URL reflects any HTTP redirects followed during the
fetch, which lets callers resolve a `latest' alias to the actual
release tag.  Writes to a sibling temp file in the same directory
and renames it into place once the download succeeds.  Renaming
swaps the directory entry to a new inode, so any process (notably
a running Emacs) that has the previous DEST file mmap'd keeps a
valid mapping to the old file content.  Writing to DEST directly
would truncate the existing inode and corrupt that mapping."
  (let* ((url-request-method "GET")
         (url-show-status nil)
         (tmp (make-temp-name (concat dest ".tmp.")))
         (final-url nil))
    (unwind-protect
        (let ((buf (url-retrieve-synchronously url t t 30)))
          (when buf
            (unwind-protect
                (with-current-buffer buf
                  (set-buffer-multibyte nil)
                  (goto-char (point-min))
                  (when (re-search-forward "^HTTP/[0-9.]+ 200" nil t)
                    (when (re-search-forward "\r?\n\r?\n" nil t)
                      (let ((coding-system-for-write 'binary)
                            (start (point)))
                        (when (< start (point-max))
                          (write-region start (point-max) tmp nil 'silent)
                          (set-file-modes tmp #o755)
                          (rename-file tmp dest t)
                          ;; `url-current-object' tracks the URL of the
                          ;; final response after redirect-following, so
                          ;; latest-asset URLs resolve to /download/vX.Y.Z/.
                          (setq final-url
                                (or (and (boundp 'url-current-object)
                                         url-current-object
                                         (url-recreate-url url-current-object))
                                    url)))))))
              (when (buffer-live-p buf)
                (kill-buffer buf)))))
      (unless final-url
        (when (file-exists-p tmp)
          (ignore-errors (delete-file tmp)))))
    final-url))

(defun ghostel--package-directory ()
  "Return the directory ghostel is loaded from, or nil."
  (let ((src (or (locate-library "ghostel")
                 load-file-name buffer-file-name)))
    (and src (file-name-directory src))))

(defun ghostel--resource-root ()
  "Return the root directory holding shipped resources (etc/, vendor/).
Prefers whichever layout is actually on disk:
- dev / `package-vc-install': ghostel.el lives under `lisp/', so the
  resource root is the parent of the Lisp directory.
- MELPA-style flat install: `:files' flattens sources into the
  package root, so the resource root equals the Lisp directory.
Falls back to the Lisp directory itself when neither layout is
detectable (e.g. a standalone ghostel.el on `load-path' without the
shipped resources), so callers always get a sensible
`default-directory' to work in."
  (when-let* ((lisp-dir (ghostel--package-directory)))
    (or (and (file-directory-p (expand-file-name "etc" lisp-dir)) lisp-dir)
        (let ((parent (file-name-as-directory
                       (expand-file-name ".." lisp-dir))))
          (and (file-directory-p (expand-file-name "etc" parent)) parent))
        lisp-dir)))

(defun ghostel--module-directory ()
  "Return the absolute directory where the native module lives.
Honours `ghostel-module-directory' when set, otherwise falls back to
the shipped resource root."
  (when-let* ((dir (or ghostel-module-directory
                       (ghostel--resource-root))))
    (file-name-as-directory (expand-file-name dir))))

(defun ghostel--module-sidecar-path (dir)
  "Return the path of the module version sidecar inside DIR.
The sidecar is a one-line file holding the version string of the
neighbouring native module.  It is written by `build.zig' at compile
time and by `ghostel--download-module' after a successful download,
so the loader can check the on-disk version without `module-load'."
  (expand-file-name "ghostel-module.version" dir))

(defun ghostel--read-module-sidecar-version (dir)
  "Return the version string recorded in DIR's sidecar, or nil.
A missing or empty file returns nil; the result is otherwise trimmed."
  (let ((path (ghostel--module-sidecar-path dir)))
    (when (file-readable-p path)
      (let ((s (with-temp-buffer
                 (insert-file-contents path)
                 (string-trim (buffer-string)))))
        (and (not (string-empty-p s)) s)))))

(defun ghostel--write-module-sidecar-version (dir version)
  "Write VERSION to DIR's sidecar atomically."
  (make-directory dir t)
  (let* ((dest (ghostel--module-sidecar-path dir))
         (tmp (make-temp-name (concat dest ".tmp."))))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (concat version "\n") nil tmp nil 'silent)
          (rename-file tmp dest t)
          (setq tmp nil))
      (when (and tmp (file-exists-p tmp))
        (ignore-errors (delete-file tmp))))))

(defun ghostel--install-module-pair (built-mod final-mod
                                               built-sidecar final-sidecar)
  "Move BUILT-MOD and BUILT-SIDECAR into FINAL-MOD and FINAL-SIDECAR.
The destination sidecar is removed before the module is moved, so every
failure path ends in `sidecar absent' rather than `sidecar stale'.
The loader treats the former as backward-compat (load and run a live
version check); the latter as `refuse to map', which would leave the
user stuck with a fresh module they cannot load."
  (make-directory (file-name-directory final-mod) t)
  (when (file-exists-p final-sidecar)
    (delete-file final-sidecar))
  (rename-file built-mod final-mod t)
  (when (file-exists-p built-sidecar)
    (rename-file built-sidecar final-sidecar t)))

(defun ghostel-download-module (&optional prompt-for-version)
  "Interactively download the pre-built native module for this platform.
With PROMPT-FOR-VERSION, prompt for a release tag to download.
Leaving the prompt empty downloads the latest release."
  (interactive "P")
  (let* ((dir (ghostel--module-directory))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir))
         (version (when prompt-for-version
                    (ghostel--read-module-download-version)))
         (latest-release (and prompt-for-version (null version))))
    (when (and (file-exists-p mod)
               (not (yes-or-no-p "Module already exists.  Re-download? ")))
      (user-error "Cancelled"))
    (if (ghostel--download-module dir version latest-release)
        (if (featurep 'ghostel-module)
            (message "ghostel: module downloaded.  Restart Emacs to load the new version")
          (module-load mod)
          (message "ghostel: module loaded successfully"))
      (user-error "Download failed.  Try M-x ghostel-module-compile to build from source"))))

(defun ghostel--install-built-module-on-finish (compile-buf source-dir dest-dir)
  "Move the built module from SOURCE-DIR into DEST-DIR when COMPILE-BUF finishes.
Registers a one-shot `compilation-finish-functions' handler that
filters on COMPILE-BUF and removes itself on first match.  Used so the
interactive `ghostel-module-compile' honours `ghostel-module-directory'.
The sidecar version file written by `build.zig' is moved alongside the
module."
  (let* ((file-name (concat "ghostel-module" module-file-suffix))
         (sidecar "ghostel-module.version")
         handler)
    (setq handler
          (lambda (buf status)
            (when (eq buf compile-buf)
              (remove-hook 'compilation-finish-functions handler)
              (when (string-match-p "finished" status)
                (let ((built (expand-file-name file-name source-dir))
                      (final (expand-file-name file-name dest-dir))
                      (built-sidecar (expand-file-name sidecar source-dir))
                      (final-sidecar (expand-file-name sidecar dest-dir)))
                  (when (file-exists-p built)
                    (condition-case err
                        (progn
                          (ghostel--install-module-pair
                           built final built-sidecar final-sidecar)
                          (message "ghostel: module installed at %s" final))
                      (error
                       (display-warning
                        'ghostel
                        (format "Build succeeded but installing into %s failed: %s"
                                dest-dir (error-message-string err)))))))))))
    (add-hook 'compilation-finish-functions handler)))

(defun ghostel-module-compile ()
  "Compile the ghostel native module by running zig build.
The output is shown in a `*compilation*' buffer.  When
`ghostel-module-directory' points outside the package tree, the
produced module is moved into that directory once the build
finishes."
  (interactive)
  (let* ((source-dir (ghostel--resource-root))
         (dest-dir (ghostel--module-directory))
         (default-directory source-dir)
         (compile-buf (compile "zig build -Doptimize=ReleaseFast -Dcpu=baseline" t)))
    (unless (equal (file-name-as-directory (expand-file-name source-dir))
                   (file-name-as-directory (expand-file-name dest-dir)))
      (ghostel--install-built-module-on-finish compile-buf source-dir dest-dir))))


(defun ghostel--check-module-version (dir &optional prompt-user)
  "Check if the loaded module is older than required.
When the module version is below `ghostel--minimum-module-version',
warn unconditionally and, when PROMPT-USER is non-nil, offer to
update using `ghostel-module-auto-install'.  DIR is the module
directory.  At load time PROMPT-USER is nil so a stale module never
triggers an interactive prompt."
  (let ((mod-ver (and (fboundp 'ghostel--module-version)
                      (ghostel--module-version))))
    (when (or (null mod-ver)
              (version< mod-ver ghostel--minimum-module-version))
      (display-warning 'ghostel
                       (format "Module version %s is older than required %s"
                               (or mod-ver "unknown")
                               ghostel--minimum-module-version))
      (when prompt-user
        (ghostel--ensure-module dir)))))

(defun ghostel--load-module (&optional prompt-user)
  "Ensure the ghostel native module is loaded.
When PROMPT-USER is non-nil (called from an interactive command like
`ghostel'), missing or stale modules trigger
`ghostel-module-auto-install' and load failures signal `user-error'
so the calling flow aborts.  Otherwise (load time, including
byte-compilation and Emacs 31's `user-lisp/' auto-compile), this
function never prompts, downloads, or compiles - it only loads an
existing module file and warns if one is missing or stale.  Module
installation only happens on an explicit user action: `M-x ghostel',
`M-x ghostel-download-module', or `M-x ghostel-module-compile'.

Before calling `module-load' the sidecar file
`ghostel-module.version' (written by `build.zig' and the downloader)
is consulted.  When the sidecar reports a version older than
`ghostel--minimum-module-version' the .so is NOT mapped into this
process — that lets the freshly installed module be loaded in
place after a subsequent `ghostel--ensure-module' call, avoiding an
extra restart.

The guard also honours `ghostel--new' being already `fboundp', which
covers the pure-Elisp test path where `cl-letf' stubs the native
entry points so tests run without the module present."
  (let* ((dir (ghostel--module-directory))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir))
         (sidecar-ver (ghostel--read-module-sidecar-version dir)))
    (unless (or (featurep 'ghostel-module)
                (fboundp 'ghostel--new))
      (cond
       ;; Sidecar tells us the on-disk module is too old.  Refuse to map
       ;; it so a subsequent install can `module-load' the fresh file in
       ;; this same Emacs process.
       ((and sidecar-ver
             (version< sidecar-ver ghostel--minimum-module-version))
        (display-warning
         'ghostel
         (format "Module version %s on disk is older than required %s"
                 sidecar-ver ghostel--minimum-module-version))
        (when prompt-user
          (ghostel--ensure-module dir)
          (let ((new-ver (ghostel--read-module-sidecar-version dir)))
            (when (and (file-exists-p mod)
                       new-ver
                       (not (version< new-ver
                                      ghostel--minimum-module-version)))
              (condition-case err
                  (module-load mod)
                (error
                 (user-error "Failed to load ghostel native module: %s"
                             (error-message-string err))))))))
       ;; Module file missing.
       ((not (file-exists-p mod))
        (cond
         (prompt-user
          (ghostel--ensure-module dir)
          (when (file-exists-p mod)
            (condition-case err
                (module-load mod)
              (error
               (user-error "Failed to load ghostel native module: %s"
                           (error-message-string err))))))
         (t
          (display-warning
           'ghostel
           (concat "Native module not found: " mod
                   "\nRun M-x ghostel-download-module or M-x ghostel-module-compile")))))
       ;; File exists and the sidecar (when present) is fresh.  Load it.
       ;; When the sidecar is absent (existing installs predating it),
       ;; fall back to a live version check post-load.  We skip the live
       ;; check here when PROMPT-USER is non-nil; the tail below runs it
       ;; instead, avoiding a double prompt.
       (t
        (condition-case err
            (progn
              (module-load mod)
              (unless prompt-user
                (ghostel--check-module-version dir nil)))
          (error
           (if prompt-user
               (user-error "Failed to load ghostel native module: %s"
                           (error-message-string err))
             (display-warning
              'ghostel
              (format "Failed to load native module: %s\nTry M-x ghostel-module-compile to rebuild"
                      (error-message-string err)))))))))
    ;; Surface the version check at every interactive entry point — not
    ;; just when this call loaded the module.  Otherwise a stale .so
    ;; mapped in by an earlier load (e.g. sidecar absent at startup) is
    ;; silently kept and the user only ever sees the bare warning.
    (when (and prompt-user (featurep 'ghostel-module))
      (ghostel--check-module-version dir t))))

;; Load the native module now so the rest of this file (declare-function,
;; feature consumers) sees it.  Failure is non-fatal at load time.
(ghostel--load-module)


;;; Internal variables

(defvar-local ghostel--term nil
  "Handle to the native terminal instance.")

(defvar-local ghostel--term-rows nil
  "Row count of the native terminal, for viewport/scrollback arithmetic.
Updated whenever the terminal is created or resized.")

(defvar-local ghostel--term-cols nil
  "Column count of the native terminal.
Updated whenever the terminal is created or resized.")

(defcustom ghostel-bold-color nil
  "Configure how bold text is colored.

If nil (default), bold text uses the same color as normal text.

If `bright', bold text uses the bright version of the current
foreground color (ANSI colors 0-7 map to 8-15).

If a string (hex color like \"#RRGGBB\"), bold text with the default
foreground color uses this specific color.  Bold text with a palette
color (0-7) will use the bright version (8-15).

Matches Ghostty 1.2.0's `bold-color' configuration."
  :type '(choice (const :tag "None" nil)
                 (const :tag "Bright" bright)
                 (string :tag "Fixed color (#RRGGBB)"
                         :match (lambda (_widget val)
                                  (and (stringp val)
                                       (string-match-p
                                        "\\`#[0-9A-Fa-f]\\{6\\}\\'" val)))))
  :group 'ghostel
  :set (lambda (sym val)
         (set-default sym val)
         (dolist (buf (buffer-list))
           (with-current-buffer buf
             (when (and (derived-mode-p 'ghostel-mode) ghostel--term)
               (ghostel--apply-bold-config ghostel--term)
               (let ((inhibit-read-only t))
                 (ghostel--redraw ghostel--term t)))))))

(defvar-local ghostel--cursor-pos nil
  "The terminal cursor as (COL . ROW) in viewport-relative coordinates.")

(defvar-local ghostel--cursor-char-pos nil
  "The position of the terminal cursor in the buffer.")

(defvar-local ghostel--rendered-font nil
  "The font last used for rendering. Internally used by native code.")

(defvar ghostel--query-font-cache nil
  "Dynamically bound cache for `query-font' during one native redraw.")

(defvar-local ghostel--input-mode 'semi-char
  "Current input mode.
One of `semi-char', `char', `copy', `emacs', or `line'.  See
`ghostel-semi-char-mode', `ghostel-char-mode', `ghostel-copy-mode',
`ghostel-emacs-mode', and `ghostel-line-mode'.")

(defvar-local ghostel--process nil
  "The shell process.")

(defvar-local ghostel--redraw-timer nil
  "Timer for delayed redraw.")

(defvar-local ghostel--plain-link-detection-timer nil
  "Timer for delayed redraw-triggered plain-text link detection.")

(defvar-local ghostel--plain-link-detection-begin nil
  "Queued start bound for redraw-triggered plain-text link detection.")

(defvar-local ghostel--plain-link-detection-end nil
  "Queued end bound for redraw-triggered plain-text link detection.")

(defvar-local ghostel--force-next-redraw nil
  "When non-nil, redraw regardless of synchronized output mode.")

(defvar-local ghostel--kitty-active nil
  "Non-nil when kitty image overlays are present in the buffer.")

(defvar-local ghostel--kitty-last-error nil
  "Last error raised inside a kitty display callback, or nil.
Captured here instead of being lost to a fleeting message so it can be
inspected when image rendering misbehaves.")

(defvar-local ghostel--last-send-time nil
  "Time of the last `ghostel--send-string' call, for immediate-redraw detection.")

(defvar-local ghostel--input-buffer nil
  "Accumulated keystrokes waiting to be flushed to the PTY.")

(defvar-local ghostel--input-timer nil
  "Timer for flushing coalesced input.")

(defvar-local ghostel--last-directory nil
  "Last known working directory from OSC 7, used for dedup.")

(defvar-local ghostel--managed-buffer-name nil
  "Last buffer name managed by Ghostel title tracking.
Nil means title tracking has not claimed the buffer yet.  Clearing this
variable re-enables automatic renaming for the next title update.")

(defvar-local ghostel--buffer-identity nil
  "Canonical buffer name used to find this buffer on subsequent `ghostel' calls.
Set at buffer creation to the value of `ghostel-buffer-name' (or its numbered
variant) before any title-tracking renames.  Used so that `ghostel' can reuse
an existing buffer even after `ghostel--set-title' has renamed it.")

(defvar-local ghostel--prompt-positions nil
  "List of prompt positions as (buffer-line . exit-status) pairs.
Used for prompt navigation and optional re-application after full redraws.")

(defvar-local ghostel--scroll-intercept-active nil
  "Non-nil when ghostel's scroll-event intercept is active.
Used as the activation key in `emulation-mode-map-alists'.")

(defvar-local ghostel--spinner-active nil
  "Non-nil when this buffer has a spinner started by `ghostel-spinner-progress'.
The spinner object itself lives in spinner.el's buffer-local
`spinner-current'; this flag is what ghostel inspects to keep
`ghostel-spinner-progress' idempotent and to give the sentinel
something to gate teardown on.")


;;; Scroll intercept via emulation-mode-map-alists
;;
;; We need highest-priority interception of wheel events so that terminal
;; mouse tracking (vim, htop, etc.) receives scroll events.  When mouse
;; tracking is off, we fall through to whatever scroll package the user
;; has configured (ultra-scroll, pixel-scroll-precision-mode, etc.).

(defun ghostel--scroll-intercept-up (event)
  "Intercept wheel-up EVENT for terminal mouse tracking.
If the terminal is tracking mouse events, forward as button 4.
Otherwise, re-dispatch EVENT through the normal event loop so the
user's scroll package handles it."
  (interactive "e")
  ;; Wheel events on an unselected window are dispatched with
  ;; `current-buffer' set to the selected window's buffer.  Run the
  ;; intercept in the event's own buffer so buffer-local state
  ;; (`ghostel--term', `ghostel--scroll-intercept-active', the
  ;; `pre-command-hook' re-enable) lands in the ghostel buffer.
  (with-current-buffer (window-buffer (posn-window (event-start event)))
    (unless (ghostel--forward-scroll-event event 4)
      (ghostel--redispatch-scroll-event event))))

(defun ghostel--scroll-intercept-down (event)
  "Intercept wheel-down EVENT for terminal mouse tracking.
If the terminal is tracking mouse events, forward as button 5.
Otherwise, re-dispatch EVENT through the normal event loop so the
user's scroll package handles it."
  (interactive "e")
  (with-current-buffer (window-buffer (posn-window (event-start event)))
    (unless (ghostel--forward-scroll-event event 5)
      (ghostel--redispatch-scroll-event event))))

(defun ghostel--redispatch-scroll-event (event)
  "Re-dispatch scroll EVENT through the event loop without our intercept.
Temporarily disables the emulation-map intercept and pushes the event
back as unread input.  The next key-lookup therefore skips our map and
finds the user's scroll handler.  A `pre-command-hook' re-enables the
intercept before that handler runs, so subsequent events are intercepted
again."
  (setq ghostel--scroll-intercept-active nil)
  (push event unread-command-events)
  ;; pre-command-hook fires *after* key lookup but *before* the command,
  ;; so the re-dispatched event is looked up with our intercept disabled
  ;; and the intercept is back on before the next event after that.
  (add-hook 'pre-command-hook #'ghostel--reenable-scroll-intercept nil t))

(defun ghostel--reenable-scroll-intercept ()
  "Re-enable the scroll-event intercept after a re-dispatched event."
  (setq ghostel--scroll-intercept-active t)
  (remove-hook 'pre-command-hook #'ghostel--reenable-scroll-intercept t))

(defvar-keymap ghostel--scroll-intercept-map
  :doc "Keymap for `emulation-mode-map-alists' to intercept scroll events.
Active only in ghostel buffers where `ghostel--scroll-intercept-active'
is non-nil."
  "<mouse-4>"    #'ghostel--scroll-intercept-up
  "<mouse-5>"    #'ghostel--scroll-intercept-down
  "<wheel-up>"   #'ghostel--scroll-intercept-up
  "<wheel-down>" #'ghostel--scroll-intercept-down)

(defvar ghostel--emulation-alist
  `((ghostel--scroll-intercept-active . ,ghostel--scroll-intercept-map))
  "Alist for `emulation-mode-map-alists'.")

(unless (memq 'ghostel--emulation-alist emulation-mode-map-alists)
  (push 'ghostel--emulation-alist emulation-mode-map-alists))



;;; Input mode predicates

(defsubst ghostel--buffer-editable-p ()
  "Non-nil when typed keys are forwarded to the terminal.
True in semi-char and char modes.  In Emacs, copy, and line modes
the buffer is either read-only or consumes keys locally."
  (memq ghostel--input-mode '(semi-char char)))

(defsubst ghostel--terminal-live-p ()
  "Non-nil when live output is propagated into the Emacs buffer.
False only in copy mode, which freezes the terminal entirely.
Line mode keeps redrawing — the snapshot/restore path in
`ghostel--redraw-now' preserves the user's in-progress input
across the rewrite."
  (not (eq ghostel--input-mode 'copy)))

(defsubst ghostel--terminal-frozen-p ()
  "Non-nil when the terminal is frozen (copy mode)."
  (eq ghostel--input-mode 'copy))


;;; Keymap

(defun ghostel--define-terminal-keys (map &optional no-exceptions)
  "Populate MAP with terminal key-sending bindings.
When NO-EXCEPTIONS is non-nil, also bind the keys in
`ghostel-keymap-exceptions' (used by char mode)."
  ;; Self-insert characters
  (define-key map [remap self-insert-command] #'ghostel--self-insert)
  ;; Special keys — routed through the ghostty key encoder which
  ;; respects terminal modes and handles all modifier combinations.
  ;; Use angle-bracket forms so modifier prefixes compose correctly.
  ;; Skip keys in `ghostel-keymap-exceptions' unless NO-EXCEPTIONS is
  ;; non-nil (char mode binds everything).
  (dolist (key '("<return>" "<tab>" "<backspace>" "<escape>"
                 "<up>" "<down>" "<right>" "<left>"
                 "<home>" "<end>" "<prior>" "<next>"
                 "<deletechar>" "<insert>"
                 "<f1>" "<f2>" "<f3>" "<f4>" "<f5>" "<f6>"
                 "<f7>" "<f8>" "<f9>" "<f10>" "<f11>" "<f12>"))
    (when (or no-exceptions (not (member key ghostel-keymap-exceptions)))
      (define-key map (kbd key) #'ghostel--send-event))
    (dolist (mod '("S-" "C-" "M-" "C-S-" "M-S-" "C-M-"))
      (let ((key-str (concat mod key)))
        (when (or no-exceptions
                  (not (member key-str ghostel-keymap-exceptions)))
          (ignore-errors
            (define-key map (kbd key-str) #'ghostel--send-event))))))
  ;; Bare aliases for unmodified keys (RET=\r, TAB=\t, DEL=\x7f)
  (define-key map (kbd "RET") #'ghostel--send-event)
  (define-key map (kbd "TAB") #'ghostel--send-event)
  (define-key map (kbd "DEL") #'ghostel--send-event)
  ;; Emacs reports S-TAB as <backtab>
  (define-key map (kbd "<backtab>") #'ghostel--send-event)
  ;; Control keys - bind all C-<letter> to send ASCII control codes.
  ;; C-i = TAB and C-m = RET are equivalent to <tab>/<return> (bound above).
  ;; C-y is reserved for ghostel-yank in semi-char mode.
  ;; C-g is always handled by `ghostel-send-C-g' so the mark and
  ;; `quit-flag' are cleared in addition to forwarding BEL.
  (let ((skip (if no-exceptions '(?i ?m ?g) '(?i ?m ?y ?g))))
    (dolist (c (number-sequence ?a ?z))
      (let ((key-str (format "C-%c" c)))
        (unless (or (memq c skip)
                    (and (not no-exceptions)
                         (member key-str ghostel-keymap-exceptions)))
          (define-key map (kbd key-str)
                      (let ((code (- c 96)))
                        (lambda () (interactive)
                          (ghostel--send-string (string code)))))))))
  ;; Meta keys - bind M-<printable ASCII> so the full set reaches the terminal.
  ;; Skip ?\[ and ?O: those are escape-sequence prefixes (CSI / SS3)
  ;; used by Emacs input decoding for arrow/function keys in TTY mode.
  (dolist (c (number-sequence ?! ?~))
    (unless (memq c '(?\[ ?O))
      (let ((key-str (format "M-%c" c)))
        (when (or no-exceptions
                  (not (member key-str ghostel-keymap-exceptions)))
          (ignore-errors
            (define-key map (kbd key-str) #'ghostel--send-event))))))
  ;; M-SPC: `(format "M-%c" ?\s)' yields "M- ", which `kbd' rejects.
  (let ((key-str "M-SPC"))
    (when (or no-exceptions
              (not (member key-str ghostel-keymap-exceptions)))
      (define-key map (kbd key-str) #'ghostel--send-event)))
  ;; Control-Meta keys - C-M-<letter> only; C-M-<punct>/<digit> aren't
  ;; widely supported by terminal apps.
  (dolist (c (number-sequence ?a ?z))
    (let ((key-str (format "C-M-%c" c)))
      (when (or no-exceptions
                (not (member key-str ghostel-keymap-exceptions)))
        (define-key map (kbd key-str) #'ghostel--send-event))))
  ;; M-DEL: TTY Emacs delivers Alt-Backspace as ESC + 0x7f, which
  ;; resolves to ?\M-\d.  The `M-<backspace>' form above only covers
  ;; the `[M-backspace]' symbol path; without this binding, TTY
  ;; Alt-Backspace falls through to global `backward-kill-word'.
  (define-key map (kbd "M-DEL") #'ghostel--send-event)
  ;; C-@ (NUL, same as C-SPC) — used by programs like Emacs-in-terminal
  (define-key map (kbd "C-@")
              (lambda () (interactive) (ghostel--send-string "\x00")))
  ;; Char mode extras: also bind non-letter exception keys so nothing
  ;; gets stolen by Emacs while a TUI app runs.
  (when no-exceptions
    (define-key map (kbd "C-\\")
                (lambda () (interactive) (ghostel--send-string "\x1c")))
    (define-key map (kbd "M-:") #'ghostel--send-event)))

(defvar-keymap ghostel-mode-map
  :doc "Base keymap for `ghostel-mode'.
Contains the \\`C-c' prefix commands available in every input mode.
Input modes (`ghostel-semi-char-mode-map', `ghostel-char-mode-map',
`ghostel-readonly-mode-map', `ghostel-readonly-fast-exit-mode-map',
`ghostel-line-mode-map') inherit or extend this map."
  ;; Clipboard media keys — useful in any mode.
  "<XF86Paste>"      #'ghostel-yank
  "<XF86Copy>"       #'kill-ring-save
  ;; Bracketed paste from the host terminal (TTY Emacs): forward the
  ;; paste payload to the subprocess instead of letting the default
  ;; `xterm-paste' insert it into the (renderer-owned) buffer.
  "<xterm-paste>"    #'ghostel-xterm-paste
  ;; Terminal control via C-c prefix
  "C-c C-c"          #'ghostel-send-C-c
  "C-c C-z"          #'ghostel-send-C-z
  "C-c C-\\"         #'ghostel-send-C-backslash
  "C-c C-d"          #'ghostel-send-C-d
  "C-g"              #'ghostel-send-C-g
  "C-c C-t"          #'ghostel-copy-mode
  "C-c M-w"          #'ghostel-copy-all
  "C-c C-y"          #'ghostel-paste
  "C-c M-l"          #'ghostel-clear-scrollback
  "C-c C-q"          #'ghostel-send-next-key
  ;; Hyperlink navigation (OSC 8, auto-detected URLs, file:line refs)
  "C-c C-n"          #'ghostel-next-hyperlink
  "C-c C-p"          #'ghostel-previous-hyperlink
  ;; Prompt navigation (OSC 133) — `ghostel-next-prompt' and
  ;; `ghostel-previous-prompt' switch to Emacs mode so the terminal
  ;; keeps running while the user jumps between prompts.
  "C-c M-n"          #'ghostel-next-prompt
  "C-c M-p"          #'ghostel-previous-prompt
  ;; Input mode switching (eat.el conventions)
  "C-c C-e"          #'ghostel-emacs-mode
  "C-c C-j"          #'ghostel-semi-char-mode
  "C-c M-d"          #'ghostel-char-mode
  "C-c C-l"          #'ghostel-line-mode
  ;; Mouse click events
  "<down-mouse-1>"   #'ghostel-mouse-press-or-copy-mode
  "<mouse-1>"        #'ghostel-mouse-release-or-set-point
  "<drag-mouse-1>"   #'ghostel-mouse-drag-or-set-region
  "<down-mouse-2>"   #'ghostel-mouse-down-2-or-noop
  "<mouse-2>"        #'ghostel-mouse-paste-primary-or-release
  "<down-mouse-3>"   #'ghostel--mouse-press
  "<mouse-3>"        #'ghostel--mouse-release
  "<drag-mouse-2>"   #'ghostel--mouse-drag
  "<drag-mouse-3>"   #'ghostel--mouse-drag
  ;; Drag and drop
  "<drag-n-drop>"    #'ghostel--drop)

(defvar-keymap ghostel-hyperlink-repeat-map
  :doc "Repeat map for `ghostel-next-hyperlink' / `ghostel-previous-hyperlink'.
Active after either command when `repeat-mode' is enabled, so a
bare \\`n'/\\`p' or \\`C-n'/\\`C-p' keeps navigating."
  :repeat t
  "n"   #'ghostel-next-hyperlink
  "p"   #'ghostel-previous-hyperlink
  "C-n" #'ghostel-next-hyperlink
  "C-p" #'ghostel-previous-hyperlink)

(defvar-keymap ghostel-prompt-repeat-map
  :doc "Repeat map for `ghostel-next-prompt' / `ghostel-previous-prompt'.
Active after either command when `repeat-mode' is enabled, so a
bare \\`n'/\\`p' or \\`M-n'/\\`M-p' keeps navigating."
  :repeat t
  "n"   #'ghostel-next-prompt
  "p"   #'ghostel-previous-prompt
  "M-n" #'ghostel-next-prompt
  "M-p" #'ghostel-previous-prompt)

(defvar-keymap ghostel-semi-char-mode-map
  :doc "Keymap for semi-char mode (the default input mode).
Most keys are sent to the terminal.  Keys in
`ghostel-keymap-exceptions' pass through to Emacs.  Inherits the
\\`C-c' prefix from `ghostel-mode-map'.

Populated by `ghostel--rebuild-semi-char-keymap'.")

(defun ghostel--rebuild-semi-char-keymap ()
  "Rebuild `ghostel-semi-char-mode-map' from `ghostel-keymap-exceptions'.
Mutates the existing keymap object in place so any buffer-local
reference to it picks up the new bindings."
  (let ((fresh (make-sparse-keymap)))
    (set-keymap-parent fresh ghostel-mode-map)
    (ghostel--define-terminal-keys fresh)
    ;; Yank bindings layer on top of the helper's defaults so the
    ;; kill ring wins over `ghostel--send-event' for `M-y',
    ;; `S-<insert>', etc.
    (define-keymap :keymap fresh
      "C-y"            #'ghostel-yank
      "S-<insert>"     #'ghostel-yank
      "<remap> <yank>" #'ghostel-yank
      "M-y"            #'ghostel-yank-pop)
    (setcdr ghostel-semi-char-mode-map (cdr fresh))))

(ghostel--rebuild-semi-char-keymap)

;; No parent — char mode captures everything, including C-c.
(defvar-keymap ghostel-char-mode-map
  :doc "Keymap for char mode.
All keys are sent to the terminal.
\\<ghostel-char-mode-map>Only \\[ghostel-semi-char-mode] exits
back to semi-char mode.")
(ghostel--define-terminal-keys ghostel-char-mode-map 'no-exceptions)
;; Explicit bindings layered on top of the helper's defaults.
(define-keymap :keymap ghostel-char-mode-map
  ;; Bind `ghostel-send-C-g' so quit-flag and the mark get cleared.
  "C-g"              #'ghostel-send-C-g
  ;; Mouse click/drag for terminal mouse tracking (no parent to
  ;; inherit from; scroll wheel is handled by the emulation alist).
  "<down-mouse-1>"   #'ghostel--mouse-press
  "<mouse-1>"        #'ghostel--mouse-release
  "<down-mouse-2>"   #'ghostel--mouse-press
  "<mouse-2>"        #'ghostel--mouse-release
  "<down-mouse-3>"   #'ghostel--mouse-press
  "<mouse-3>"        #'ghostel--mouse-release
  "<drag-mouse-1>"   #'ghostel--mouse-drag
  "<drag-mouse-2>"   #'ghostel--mouse-drag
  "<drag-mouse-3>"   #'ghostel--mouse-drag
  ;; Sole escape hatch: exit char mode.  Graphical Emacs sends
  ;; M-RET as the `<M-return>' symbol, terminal Emacs as the
  ;; `\M-\r' character, and C-M-m is a synonym; bind all three
  ;; so the user doesn't need to care which their setup uses.
  "M-RET"            #'ghostel-semi-char-mode
  "M-<return>"       #'ghostel-semi-char-mode
  "C-M-m"            #'ghostel-semi-char-mode)

(defvar-keymap ghostel-readonly-mode-map
  :doc "Keymap shared by `ghostel-copy-mode' and `ghostel-emacs-mode'.
The buffer is read-only in both modes; the only difference between
them is whether live terminal output keeps streaming (Emacs mode)
or is paused (copy mode).  Self-insert, RET, TAB, DEL and friends
are NOT bound here — Emacs's standard `text-read-only' barrier
keeps stray keystrokes from reaching the shell.  Pasting via
\\[ghostel-yank] is allowed as an explicit input action; it
forwards via bracketed paste and snaps point back to the live
cursor.

When `ghostel-readonly-fast-exit' is non-nil, the additional
bindings in `ghostel-readonly-fast-exit-mode-map' are layered on
top so that \\`q', \\`C-g', or any self-insert key exits."
  :parent ghostel-mode-map
  "C-a"            #'ghostel-beginning-of-input-or-line
  "C-y"            #'ghostel-yank
  "<remap> <yank>" #'ghostel-yank
  "M-w"            #'ghostel-readonly-copy
  "C-w"            #'ghostel-readonly-copy
  "M->"            #'ghostel-readonly-end-of-buffer
  "C-e"            #'ghostel-readonly-end-of-line
  "RET"            #'ghostel-open-link-at-point
  "<return>"       #'ghostel-open-link-at-point)

(defvar-keymap ghostel-readonly-fast-exit-mode-map
  :doc "Keymap layered on `ghostel-readonly-mode-map' when fast exit is on.
See `ghostel-readonly-fast-exit'."
  :parent ghostel-readonly-mode-map
  ;; Normal letter keys exit and send the key to the terminal.
  "<remap> <self-insert-command>" #'ghostel-readonly-exit-and-send
  ;; RET / <return> follow self-insert: open link at point if there
  ;; is one, otherwise exit and send a CR to the terminal.  Without
  ;; fast-exit, the parent map's `ghostel-open-link-at-point' wins.
  "RET"                           #'ghostel-readonly-RET-or-exit-and-send
  "<return>"                      #'ghostel-readonly-RET-or-exit-and-send
  "C-c M-l"                       #'ghostel-readonly-exit-and-clear
  "q"                             #'ghostel-readonly-exit
  "C-g"                           #'ghostel-readonly-exit)

;; Char mode must override minor-mode keymaps.  Without this, a user
;; config that binds, say, \\`C-c' as a prefix in a global minor mode
;; steals the key before it reaches `ghostel-char-mode-map'.  Pushing
;; an entry into `emulation-mode-map-alists' moves char mode's
;; keymap ahead of `minor-mode-map-alist' in the lookup order, so a
;; direct binding in `ghostel-char-mode-map' wins against any
;; minor-mode prefix.

(defvar-local ghostel--char-mode-override-active nil
  "Non-nil in buffers where char mode is active.
Drives the `emulation-mode-map-alists' entry that makes
`ghostel-char-mode-map' override minor-mode keymaps.")

(defvar ghostel--char-mode-override-alist
  `((ghostel--char-mode-override-active . ,ghostel-char-mode-map))
  "Alist entry registered in `emulation-mode-map-alists' for char mode.")

(add-to-list 'emulation-mode-map-alists 'ghostel--char-mode-override-alist)


;;; Key sending

(defun ghostel-send-next-key ()
  "Read the next key event and send it to the terminal.
This is an escape hatch for sending keys that are normally
intercepted by Emacs (e.g., interrupt or prefix keys).
Uses `read-event' so that prefix keys return immediately instead
of waiting for a continuation keystroke."
  (interactive)
  (let ((event (read-event "Send key: ")))
    (cond
     ;; Control character (C-@=0, C-a=1 through C-_=31)
     ((and (integerp event) (<= event 31))
      (ghostel--send-string (string event)))
     ;; ASCII (32-127)
     ((and (integerp event) (<= event 127))
      (ghostel--send-string (string event)))
     ;; Non-ASCII character without modifier bits — send as UTF-8
     ((and (integerp event) (< event #x400000))
      (ghostel--send-string (encode-coding-string (string event) 'utf-8)))
     ;; Modified key (M-x, C-M-a, etc.) or function key — use encoder
     (t
      (let* ((base (event-basic-type event))
             (mods (event-modifiers event))
             (key-name (cond
                        ((eq base 'backtab) "tab")
                        ((integerp base)
                         (and (< base 128) (string base)))
                        ((eq base 'deletechar) "delete")
                        ((and base (symbolp base)) (symbol-name base))
                        ((and (null base) (symbolp event))
                         (replace-regexp-in-string
                          "\\`\\(?:[CMSHs]-\\)*" "" (symbol-name event)))
                        (t nil)))
             (mods (if (eq base 'backtab) (cons 'shift mods) mods))
             (mod-str (mapconcat
                       #'identity
                       (delq nil
                             (mapcar
                              (lambda (m)
                                (pcase m
                                  ('shift "shift") ('control "ctrl")
                                  ('meta "meta") ('alt "alt")
                                  ('hyper "hyper") ('super "super")))
                              mods))
                       ",")))
        (if key-name
            (ghostel--send-encoded key-name mod-str)
          (message "ghostel: unrecognized key %S" event)))))))

(defun ghostel--send-string (string)
  "Send STRING as raw bytes to the terminal process.
Records the send time for immediate-redraw detection and optionally
coalesces rapid keystrokes when `ghostel-input-coalesce-delay' > 0."
  (when (and ghostel--process (process-live-p ghostel--process))
    (setq ghostel--last-send-time (current-time))
    (if (and (> ghostel-input-coalesce-delay 0)
             (= (length string) 1))
        ;; Coalesce single-char keystrokes
        (progn
          (push string ghostel--input-buffer)
          (unless ghostel--input-timer
            (setq ghostel--input-timer
                  (run-with-timer ghostel-input-coalesce-delay nil
                                  #'ghostel--flush-input (current-buffer)))))
      ;; Multi-byte or coalescing disabled: send immediately
      (when ghostel--input-timer
        (cancel-timer ghostel--input-timer)
        (setq ghostel--input-timer nil)
        ;; Flush any buffered input first
        (when ghostel--input-buffer
          (process-send-string ghostel--process
                               (apply #'concat (nreverse ghostel--input-buffer)))
          (setq ghostel--input-buffer nil)))
      (process-send-string ghostel--process string))))

(define-obsolete-function-alias 'ghostel--send-key
  #'ghostel--send-string "0.16.0")

(defun ghostel--flush-input (buffer)
  "Flush coalesced input in BUFFER to the PTY.
Safe to call synchronously as well as from the coalesce timer:
cancelling an already-fired timer is a no-op."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when ghostel--input-timer
        (cancel-timer ghostel--input-timer)
        (setq ghostel--input-timer nil))
      (when (and ghostel--input-buffer ghostel--process
                 (process-live-p ghostel--process))
        (process-send-string ghostel--process
                             (apply #'concat (nreverse ghostel--input-buffer)))
        (setq ghostel--input-buffer nil)))))

(defun ghostel--send-encoded (key-name mods &optional utf8)
  "Encode KEY-NAME with MODS via the terminal's key encoder and send.
KEY-NAME is a string like \"a\", \"return\", \"up\".
MODS is a string like \"ctrl\", \"shift,ctrl\", or \"\".
UTF8 is optional text generated by the key.
Falls back to raw escape sequences if the encoder doesn't produce output."
  (when ghostel--term
    (if (ghostel--encode-key ghostel--term key-name mods utf8)
        ;; Encoder sent via ghostel--flush-output; record send time for
        ;; immediate-redraw detection (ghostel--flush-output doesn't do this).
        (setq ghostel--last-send-time (current-time))
      (let ((seq (ghostel--raw-key-sequence key-name mods)))
        (when seq (ghostel--send-string seq))))))

(defun ghostel--raw-key-sequence (key-name mods)
  "Build a raw escape sequence for KEY-NAME with MODS.
Returns the sequence string, or nil for unknown keys."
  (let ((mod-num (ghostel--modifier-number mods)))
    (cond
     ;; Ctrl + single letter
     ((and (= (length key-name) 1)
           (<= ?a (aref key-name 0)) (<= (aref key-name 0) ?z)
           (> (logand mod-num 4) 0))        ; ctrl bit
      (string (- (aref key-name 0) 96)))    ; ctrl-a=1, ctrl-z=26
     ;; Meta + printable ASCII → ESC + char (legacy alt encoding)
     ((and (= (length key-name) 1)
           (let ((c (aref key-name 0)))
             (and (>= c 32) (<= c 126)))
           (> (logand mod-num 2) 0))        ; alt/meta bit
      (format "\e%c" (aref key-name 0)))
     ;; Simple special keys (CSI u encoding for modified variants)
     ((string= key-name "backspace") (if (> mod-num 0) (format "\e[127;%du" (1+ mod-num)) "\x7f"))
     ((string= key-name "return")    (if (> mod-num 0) (format "\e[13;%du" (1+ mod-num)) "\r"))
     ((string= key-name "tab")       (if (> mod-num 0) (format "\e[9;%du" (1+ mod-num)) "\t"))
     ((string= key-name "escape")    (if (> mod-num 0) (format "\e[27;%du" (1+ mod-num)) "\e"))
     ((string= key-name "space")     (if (> mod-num 0) (format "\e[32;%du" (1+ mod-num)) " "))
     ;; Cursor keys
     ((string= key-name "up")    (ghostel--csi-letter "A" mod-num))
     ((string= key-name "down")  (ghostel--csi-letter "B" mod-num))
     ((string= key-name "right") (ghostel--csi-letter "C" mod-num))
     ((string= key-name "left")  (ghostel--csi-letter "D" mod-num))
     ((string= key-name "home")  (ghostel--csi-letter "H" mod-num))
     ((string= key-name "end")   (ghostel--csi-letter "F" mod-num))
     ;; Tilde keys
     ((string= key-name "insert") (ghostel--csi-tilde 2 mod-num))
     ((string= key-name "delete") (ghostel--csi-tilde 3 mod-num))
     ((string= key-name "prior")  (ghostel--csi-tilde 5 mod-num))
     ((string= key-name "next")   (ghostel--csi-tilde 6 mod-num))
     ;; Function keys (F1-F4 use SS3, F5-F12 use tilde)
     ((string= key-name "f1")  (if (> mod-num 0) (format "\e[1;%dP" (1+ mod-num)) "\eOP"))
     ((string= key-name "f2")  (if (> mod-num 0) (format "\e[1;%dQ" (1+ mod-num)) "\eOQ"))
     ((string= key-name "f3")  (if (> mod-num 0) (format "\e[1;%dR" (1+ mod-num)) "\eOR"))
     ((string= key-name "f4")  (if (> mod-num 0) (format "\e[1;%dS" (1+ mod-num)) "\eOS"))
     ((string= key-name "f5")  (ghostel--csi-tilde 15 mod-num))
     ((string= key-name "f6")  (ghostel--csi-tilde 17 mod-num))
     ((string= key-name "f7")  (ghostel--csi-tilde 18 mod-num))
     ((string= key-name "f8")  (ghostel--csi-tilde 19 mod-num))
     ((string= key-name "f9")  (ghostel--csi-tilde 20 mod-num))
     ((string= key-name "f10") (ghostel--csi-tilde 21 mod-num))
     ((string= key-name "f11") (ghostel--csi-tilde 23 mod-num))
     ((string= key-name "f12") (ghostel--csi-tilde 24 mod-num))
     (t nil))))

(defun ghostel--modifier-number (mods)
  "Convert MODS string to a bitmask: shift=1, alt=2, ctrl=4."
  (let ((n 0))
    (when (string-match-p "shift" mods) (setq n (logior n 1)))
    (when (string-match-p "alt\\|meta" mods) (setq n (logior n 2)))
    (when (string-match-p "ctrl\\|control" mods) (setq n (logior n 4)))
    n))

(defun ghostel--csi-letter (letter mod-num)
  "Format CSI cursor-key sequence for LETTER with MOD-NUM modifier."
  (if (> mod-num 0)
      (format "\e[1;%d%s" (1+ mod-num) letter)
    (format "\e[%s" letter)))

(defun ghostel--csi-tilde (param mod-num)
  "Format CSI tilde sequence for PARAM with MOD-NUM modifier."
  (if (> mod-num 0)
      (format "\e[%d;%d~" param (1+ mod-num))
    (format "\e[%d~" param)))

(defun ghostel--snap-to-input ()
  "Return the window to the live viewport on user input.
Uses `ghostel--anchor-window'.

Fires regardless of input mode: in semi-char/char/line modes
each typed key calls this before forwarding; in Emacs mode
typing is disabled but explicit paste (`\\`C-y'') still routes
through `ghostel--paste-text' which calls this before sending.
Pure-navigation commands do not call this, so reading scrollback
without sending anything to the shell preserves point."
  (when (and ghostel-scroll-on-input ghostel--term)
    (ghostel--anchor-window)))

(defun ghostel--self-insert ()
  "Send the last typed character to the terminal."
  (interactive)
  (ghostel--snap-to-input)
  (let* ((keys (this-command-keys))
         (char (aref keys (1- (length keys))))
         (str (if (and (characterp char) (< char 128))
                  (string char)
                (encode-coding-string (string char) 'utf-8))))
    (ghostel--send-string str)))

(defun ghostel--send-event ()
  "Send the current key event to the terminal via the key encoder.
Extracts the base key name and modifiers from `last-command-event'
and routes through the ghostty key encoder, which respects terminal
modes (application cursor keys, Kitty keyboard protocol, etc.).

In TTY Emacs, `M-<key>' arrives as two events (ESC then <key>) via
`esc-map'; `last-command-event' is just <key> and has no meta bit.
Detect that case via `this-command-keys-vector' and re-inject meta."
  (interactive)
  (ghostel--snap-to-input)
  (let* ((event last-command-event)
         (keys (this-command-keys-vector))
         (via-esc (and (> (length keys) 1) (eq (aref keys 0) 27)))
         (base (event-basic-type event))
         (mods (event-modifiers event))
         (mods (if (and via-esc (not (memq 'meta mods)))
                   (cons 'meta mods)
                 mods))
         (key-name (cond
                    ;; backtab is Emacs's name for S-TAB
                    ((eq base 'backtab) "tab")
                    ;; Terminal mode sends ASCII 127 for the backspace key
                    ((and (integerp base) (= base 127)) "backspace")
                    ;; Integer base (character key)
                    ((integerp base)
                     (and (< base 128) (string base)))
                    ((eq base 'deletechar) "delete")
                    ;; Normal function key symbol
                    ((and base (symbolp base)) (symbol-name base))
                    ;; Modified return/tab/backspace/escape: event-basic-type
                    ;; returns nil but modifiers are extracted correctly.
                    ;; Strip modifier prefixes from the symbol name.
                    ((and (null base) (symbolp event))
                     (replace-regexp-in-string
                      "\\`\\(?:[CMSHs]-\\)*" "" (symbol-name event)))
                    (t nil)))
         ;; backtab needs shift added back since it's baked into the name
         (mods (if (eq base 'backtab) (cons 'shift mods) mods))
         (mod-str (mapconcat
                   (lambda (m)
                     (pcase m
                       ('shift "shift") ('control "ctrl")
                       ('meta "meta") ('hyper "hyper")
                       ('super "super") (_ nil)))
                   mods ",")))
    (when key-name
      (ghostel--send-encoded key-name mod-str))))


;;; Public input API

(defun ghostel-send-string (string)
  "Send STRING to the terminal process in the current ghostel buffer.
Signals a `user-error' when called outside a ghostel buffer.  STRING
is passed through unchanged, including any embedded control
characters; callers are responsible for UTF-8 encoding if needed."
  (unless (derived-mode-p 'ghostel-mode)
    (user-error "Must be called from a ghostel buffer"))
  (ghostel--send-string string))

(defun ghostel-send-key (key-name &optional mods)
  "Send KEY-NAME with optional MODS to the terminal's key encoder.
KEY-NAME is a string like \"a\", \"return\", or \"up\".  MODS is a
comma-separated modifier string like \"ctrl\" or \"shift,ctrl\", or
nil for no modifiers.  The encoder respects the terminal's current
mode (application cursor keys, Kitty keyboard protocol, etc.).

Signals a `user-error' when called outside a ghostel buffer."
  (unless (derived-mode-p 'ghostel-mode)
    (user-error "Must be called from a ghostel buffer"))
  (ghostel--send-encoded key-name (or mods "")))

(defun ghostel-paste-string (string)
  "Send STRING to the terminal using bracketed paste.
Signals a `user-error' when called outside a ghostel buffer.

Unlike `ghostel-send-string', this wraps STRING in bracketed paste
markers (ESC [200~ / ESC [201~) when the terminal supports bracketed
paste mode (mode 2004), so the shell treats the input as an atomic
paste rather than character-by-character typed keystrokes."
  (unless (derived-mode-p 'ghostel-mode)
    (user-error "Must be called from a ghostel buffer"))
  (ghostel--paste-text string))


;;; Terminal control commands (C-c prefix)

(defun ghostel-send-C-c ()
  "Send interrupt signal to the terminal."
  (interactive)
  (ghostel--send-encoded "c" "ctrl"))

(defun ghostel-send-C-z ()
  "Send suspend signal to the terminal."
  (interactive)
  (ghostel--send-encoded "z" "ctrl"))

(defun ghostel-send-C-backslash ()
  "Send C-\\ (quit) to the terminal."
  (interactive)
  (ghostel--send-string "\x1c"))

(defun ghostel-send-C-d ()
  "Send EOF to the terminal."
  (interactive)
  (ghostel--send-encoded "d" "ctrl"))

(defun ghostel-send-C-g ()
  "Send \\`C-g' to the terminal.
Clears `quit-flag' which Emacs sets when \\`C-g' is pressed with
`inhibit-quit' non-nil, and deactivates the mark so the region
overlay clears the way \\`keyboard-quit' would in other buffers."
  (interactive)
  (setq quit-flag nil)
  (deactivate-mark)
  (ghostel--send-string (string 7)))


;;; Paste / yank

(defvar-local ghostel--yank-index 0
  "Current kill ring index for `ghostel-yank-pop'.")

(defun ghostel--bracketed-paste-p ()
  "Return non-nil if the terminal has bracketed paste mode (2004) enabled."
  (and ghostel--term
       (ghostel--mode-enabled ghostel--term 2004)))

(defun ghostel--paste-text (text)
  "Send TEXT to the terminal, using bracketed paste if the terminal wants it."
  (when (and text ghostel--process (process-live-p ghostel--process))
    (ghostel--snap-to-input)
    (process-send-string ghostel--process
                         (if (ghostel--bracketed-paste-p)
                             (concat "\e[200~" text "\e[201~")
                           text))))

(defun ghostel-paste ()
  "Paste text from the Emacs kill ring into the terminal.
Uses bracketed paste mode so that shells can distinguish
pasted text from typed input."
  (interactive)
  (ghostel--paste-text (current-kill 0)))

(defun ghostel-yank ()
  "Yank the most recent kill into the terminal.
Use `ghostel-yank-pop' afterwards to cycle through older kills."
  (interactive)
  (setq ghostel--yank-index 0)
  (ghostel--paste-text (current-kill 0))
  (setq this-command 'ghostel-yank))

(defun ghostel-yank-pop ()
  "Replace the just-yanked text with the next kill ring entry.
After `ghostel-yank' or `ghostel-yank-pop', cycles through the
kill ring by erasing the previous paste and inserting the next entry.
Otherwise, opens a `completing-read' browser over `kill-ring' and
pastes the selected entry into the terminal."
  (interactive)
  (if (memq last-command '(ghostel-yank ghostel-yank-pop))
      (let* ((prev-text (current-kill ghostel--yank-index t))
             (prev-len (length prev-text)))
        (setq ghostel--yank-index (1+ ghostel--yank-index))
        ;; Erase previous paste: send backspaces
        (when (and ghostel--process (process-live-p ghostel--process))
          (process-send-string ghostel--process
                               (make-string prev-len ?\x7f)))
        ;; Paste the next entry
        (ghostel--paste-text (current-kill ghostel--yank-index t))
        (setq this-command 'ghostel-yank-pop))
    ;; No preceding yank: browse kill ring and paste selection
    (when-let* ((text (completing-read "Paste from kill ring: "
                                       kill-ring nil t)))
      (ghostel--paste-text text))))

(defun ghostel-xterm-paste (event)
  "Forward an xterm-paste EVENT to the terminal via bracketed paste.
The default `xterm-paste' command inserts into the current buffer,
which is wrong for ghostel: the terminal renderer owns the buffer
and wipes the inserted text on the next redraw, so the shell
never sees it.  This handler extracts the pasted text from EVENT
and pushes it to the subprocess through `ghostel--paste-text'
instead.  When `xterm-store-paste-on-kill-ring' is non-nil (the
stock default), the text is also pushed onto the kill ring for
parity with `xterm-paste'."
  (interactive "e")
  (unless (eq (car-safe event) 'xterm-paste)
    (error "This command must be bound to an xterm-paste event"))
  (when (and (eq ghostel--input-mode 'copy)
             ghostel-readonly-fast-exit)
    (ghostel-readonly-exit))
  (when-let* ((text (nth 1 event)))
    (when (bound-and-true-p xterm-store-paste-on-kill-ring)
      (kill-new text))
    (ghostel--paste-text text)))


;;; Drag and drop

(defun ghostel--drop (event)
  "Handle a drag-and-drop EVENT into the terminal.
Dropped files insert their path (shell-quoted); dropped text is
pasted using bracketed paste."
  (interactive "e")
  (when (and ghostel--process (process-live-p ghostel--process))
    ;; On macOS (NS port) the event structure is:
    ;;   (drag-n-drop POSN (TYPE OPERATIONS . OBJECTS))
    ;; where (nth 2 event) carries the drop data, not the position.
    (let ((arg (nth 2 event)))
      (when (and arg (not (eq arg 'lambda)))
        (let ((type (car arg))
              (objects (cddr arg)))
          (if (eq type 'file)
              (ghostel--send-string
               (mapconcat #'shell-quote-argument objects " "))
            (ghostel--paste-text
             (mapconcat #'identity objects "\n"))))))))


;;; Scrollback / clearing

(defun ghostel-clear-scrollback ()
  "Clear the screen and scrollback buffer."
  (interactive)
  (when ghostel--term
    ;; CSI H = home, CSI 2 J = erase screen, CSI 3 J = erase scrollback.
    (ghostel--write-input ghostel--term "\e[H\e[2J\e[3J")
    (setq ghostel--force-next-redraw t)
    (ghostel--invalidate)
    ;; Send form-feed to the shell so it redraws its prompt.
    (when (and ghostel--process (process-live-p ghostel--process))
      (process-send-string ghostel--process "\f"))))

(defun ghostel-clear ()
  "Clear the visible screen, preserving scrollback history."
  (interactive)
  (when ghostel--term
    (ghostel--write-input ghostel--term "\e[H\e[2J")
    (setq ghostel--force-next-redraw t)
    (ghostel--invalidate)
    ;; Send form-feed to the shell so it redraws its prompt.
    (when (and ghostel--process (process-live-p ghostel--process))
      (process-send-string ghostel--process "\f"))))

(defun ghostel--forward-scroll-event (event button)
  "Try to forward a scroll EVENT as mouse BUTTON to the terminal.
Return non-nil if the event was forwarded (mouse tracking is active)."
  (when (and event ghostel--term ghostel--process
             (process-live-p ghostel--process)
             (ghostel--buffer-editable-p))
    (let* ((posn (event-start event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            0  ; press
                            button
                            row col
                            (ghostel--mouse-mods event)))))

(defun ghostel-readonly-end-of-buffer ()
  "Move to the bottom of the buffer (current viewport) in read-only mode."
  (interactive)
  (goto-char (point-max))
  (skip-chars-backward " \t\n"))

;; Let isearch treat this as the buffer-end motion command.
(put 'ghostel-readonly-end-of-buffer 'isearch-motion
     (cons (lambda () (goto-char (point-max)) (recenter -1 t)) 'backward))

(defun ghostel-readonly-end-of-line ()
  "Move to the last non-whitespace character on the line."
  (interactive)
  (end-of-line)
  (skip-chars-backward " \t"))


;;; Mouse input

(defvar-local ghostel--mouse-drag-button nil
  "Button number held during an in-progress mouse-tracking drag.
Nil when no drag is in progress.")

(defvar-local ghostel--mouse-drag-last-cell nil
  "Last (ROW . COL) forwarded as a motion event during a drag.
Used by `ghostel--mouse-drag-motion' to suppress duplicate motion
events for the same cell: libghostty is not given a `last_cell' to
deduplicate against, so without this every `mouse-movement' event
\(many per cell) would re-encode and spam the PTY.")

(defvar ghostel--mouse-drag-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-movement] #'ghostel--mouse-drag-motion)
    ;; Movement events that land on a non-text area arrive with a
    ;; prefix (e.g. [mode-line mouse-movement]).  Route those prefixes
    ;; back through this same map so a drag straying over the
    ;; mode-line/fringe/margin still resolves to the motion handler and
    ;; does not prematurely tear the drag down.
    (dolist (prefix '( mode-line header-line tab-line vertical-line
                       left-fringe right-fringe left-margin right-margin
                       right-divider bottom-divider))
      (define-key map (vector prefix) map))
    map)
  "Transient keymap active while a mouse-tracking drag is in progress.
Installed by `ghostel--mouse-begin-drag-tracking'; routes
`mouse-movement' events to `ghostel--mouse-drag-motion' so the
running program receives a live motion stream during the drag.")

(defun ghostel--mouse-button-number (event)
  "Return the ghostty mouse button number for EVENT."
  (pcase (event-basic-type event)
    ('mouse-1 1)
    ('mouse-2 3)
    ('mouse-3 2)
    (_ 0)))

(defun ghostel--mouse-mods (event)
  "Return ghostty modifier bitmask for mouse EVENT."
  (let ((mods (event-modifiers event))
        (result 0))
    (when (memq 'shift mods) (setq result (logior result 1)))
    (when (memq 'control mods) (setq result (logior result 4)))
    (when (memq 'meta mods) (setq result (logior result 2)))
    result))

(defun ghostel--mouse-press (event)
  "Handle mouse button press EVENT for terminal mouse tracking."
  (interactive "e")
  (select-window (posn-window (event-start event)))
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-start event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            0  ; press
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event))
      ;; Emacs only emits `mouse-movement' events while `track-mouse'is non-nil,
      ;; and coalesces a drag into a single `drag-mouse-N' event at release.
      ;; To give the running program a live motion stream during the drag,
      ;; start tracking now (only when a DEC mouse-tracking mode is on,
      ;; so char mode does not arm it for a program that ignores mouse input).
      (when (ghostel--mouse-tracking-active-p)
        (ghostel--mouse-begin-drag-tracking event)))))

(defun ghostel--mouse-begin-drag-tracking (event)
  "Arm live motion forwarding for a drag started by EVENT.
Records the held button, enables Emacs motion events by setting the variable
`track-mouse', and installs `ghostel--mouse-drag-map' as a transient map so
each intermediate `mouse-movement' event is forwarded to the terminal by
`ghostel--mouse-drag-motion'.  The map stays active until the next non-motion
command (the button release, which `keep-pred' detects)."
  (setq ghostel--mouse-drag-button (ghostel--mouse-button-number event)
        ghostel--mouse-drag-last-cell nil)
  (let ((old-track-mouse track-mouse)
        (buffer (current-buffer)))
    (setq track-mouse 'dragging)
    (set-transient-map
     ghostel--mouse-drag-map
     (lambda () (eq this-command 'ghostel--mouse-drag-motion))
     (lambda ()
       (with-current-buffer buffer
         (setq track-mouse old-track-mouse
               ghostel--mouse-drag-button nil
               ghostel--mouse-drag-last-cell nil))))))

(defun ghostel--mouse-drag-motion (event)
  "Forward mouse-movement EVENT as a motion event during a drag.
Bound in `ghostel--mouse-drag-map' while a drag is in progress.
Labels the motion with the button recorded at press time
\(`mouse-movement' events carry no button) and skips events that stay
within the same cell so the PTY is not flooded with redundant motion."
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process)
             ghostel--mouse-drag-button)
    (let* ((posn (event-start event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (unless (equal (cons row col) ghostel--mouse-drag-last-cell)
        (setq ghostel--mouse-drag-last-cell (cons row col))
        (ghostel--mouse-event ghostel--term
                              2  ; motion
                              ghostel--mouse-drag-button
                              row col
                              (ghostel--mouse-mods event))))))

(defun ghostel--mouse-release (event)
  "Handle mouse button release EVENT for terminal mouse tracking."
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-end event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            1  ; release
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))

(defun ghostel--mouse-drag (event)
  "Handle drag-end EVENT as a button release for terminal mouse tracking.
A `drag-mouse-N' event is only delivered at the *end* of a drag, so it marks
the button release.  Live motion during the drag is streamed separately by
`ghostel--mouse-drag-motion'; this handler's job is to complete the protocol
with a release at the final position.  (Sending a release rather than a motion
also matters for DEC mode 1000, which reports releases but never motion.)"
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-end event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            1  ; release
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))

(defun ghostel--mouse-tracking-active-p ()
  "Non-nil if libghostty has any DEC mouse-tracking mode set.
Checks modes 1000 (normal), 1002 (button-event), and 1003
\(any-event) - the modes a running program enables when it wants
to consume mouse input."
  (and ghostel--term
       (or (ghostel--mode-enabled ghostel--term 1000)
           (ghostel--mode-enabled ghostel--term 1002)
           (ghostel--mode-enabled ghostel--term 1003))))

(defun ghostel-mouse-press-or-copy-mode (event)
  "Forward EVENT to the terminal, or hand off to `mouse-drag-region'.
When a DEC mouse-tracking mode (1000/1002/1003) is enabled, behaves
like `ghostel--mouse-press' and forwards the press to the running
program.  Otherwise hands EVENT off to `mouse-drag-region' so Emacs's
standard click-to-set-point and drag-to-select work.  Copy mode is
not entered here - a pure click should only focus the window and
move point.  When the press grows into a drag,
`ghostel-mouse-drag-or-set-region' enters copy mode after the region
is set so subsequent terminal output cannot clobber the selection."
  (interactive "e")
  (select-window (posn-window (event-start event)))
  (if (ghostel--mouse-tracking-active-p)
      (ghostel--mouse-press event)
    (mouse-drag-region event)))

(defun ghostel-mouse-release-or-set-point (event &optional promote-to-region)
  "Forward EVENT to the terminal, or hand off to `mouse-set-point'.
Companion to `ghostel-mouse-press-or-copy-mode' for the left-button
release event.  With tracking off, defers to Emacs's standard
click handler so the release of a non-drag click sets point normally.
PROMOTE-TO-REGION is passed through to `mouse-set-point' so that
double-click and triple-click events keep the word/line selection."
  (interactive "e\np")
  (if (ghostel--mouse-tracking-active-p)
      (ghostel--mouse-release event)
    (mouse-set-point event promote-to-region)
    (when (and (eq ghostel--input-mode 'semi-char)
               (> (event-click-count event) 1))
      (pcase ghostel-mouse-drag-input-mode
        ('copy  (ghostel-copy-mode))
        ('emacs (ghostel-emacs-mode))))))

(defun ghostel-mouse-drag-or-set-region (event)
  "Forward EVENT to the terminal, or hand off to `mouse-set-region'.
Companion to `ghostel-mouse-press-or-copy-mode' for the left-button
drag event.  With tracking off, defers to Emacs's standard drag
handler so the selection survives release; without this,
`mouse-drag-track's exit hook deactivates the mark and our
intercept keeps `mouse-set-region' from re-establishing the region.
When the buffer is in semi-char mode, switches input mode once the
region is set to mode configured in `ghostel-mouse-drag-input-mode'."
  (interactive "e")
  (if (ghostel--mouse-tracking-active-p)
      (ghostel--mouse-drag event)
    (mouse-set-region event)
    (when (eq ghostel--input-mode 'semi-char)
      (pcase ghostel-mouse-drag-input-mode
        ('copy  (ghostel-copy-mode))
        ('emacs (ghostel-emacs-mode))))))

(defun ghostel-mouse-down-2-or-noop (event)
  "Forward EVENT to the terminal when a mouse-tracking mode is on.
Otherwise no-op so the matching release handler can paste the
primary selection without a stray press byte being sent first."
  (interactive "e")
  (when (ghostel--mouse-tracking-active-p)
    (ghostel--mouse-press event)))

(defun ghostel-mouse-paste-primary-or-release (event)
  "Forward EVENT to the terminal, or paste the primary selection.
Selects the click's window first so a middle-click into an
unfocused ghostel window pastes into that terminal, not whichever
buffer happened to be current.  With a DEC mouse-tracking mode
active, behaves like `ghostel--mouse-release'.  Otherwise pastes
the X primary selection at the live cursor via `ghostel--paste-text',
which uses bracketed paste when the terminal has DEC 2004 enabled.
When in copy or Emacs mode and `ghostel-readonly-fast-exit' is
non-nil, exits to the prior input mode first so the paste lands at
the prompt."
  (interactive "e")
  (select-window (posn-window (event-start event)))
  (if (ghostel--mouse-tracking-active-p)
      (ghostel--mouse-release event)
    (let ((text (gui-get-primary-selection)))
      (when (and text (not (string-empty-p text)))
        (when (and (memq ghostel--input-mode '(copy emacs))
                   ghostel-readonly-fast-exit)
          (ghostel-readonly-exit))
        (ghostel--paste-text text)))))


;;; Input modes — state helpers

(defvar-local ghostel--saved-cursor-type nil
  "Saved `cursor-type' before entering a read-only mode.")

(defvar-local ghostel--saved-hl-line-mode nil
  "Non-nil if line highlighting was active when `ghostel-mode' suppressed it.
Covers both `global-hl-line-mode' and buffer-local `hl-line-mode'.")

(defvar-local ghostel--line-mode-paused nil
  "Snapshot plist captured when alt-screen forced line mode to pause.
Nil when not paused.  Set by `ghostel--line-mode-pause' (auto-pause
when an alt-screen TUI starts) and by `ghostel--line-mode-defer-entry'
\(when the user invokes `ghostel-line-mode' while a TUI is already
running); consumed by `ghostel--line-mode-try-resume' once alt-screen
has gone off and a prompt is locatable.  Cleared when the user
manually switches input modes so a later alt-screen exit does not
surprise them by force-resuming line mode.")

(defvar ghostel--password-mode-p)         ; forward decls; defined below.
(defvar ghostel--password-handled-cursor) ;

(defvar-local ghostel--mode-line-tag nil
  "Current input-mode label rendered in `mode-line-process'.
String like \":Char\" / \":Line\" / \":Copy\" / \":Emacs\", or
nil for semi-char.  Composed with `ghostel--mode-line-progress'
\(and the spinner construct, when active) by
`ghostel--mode-line-refresh' so OSC 9;4 progress updates do not
clobber the input-mode label.")

(defvar-local ghostel--mode-line-progress nil
  "Current OSC 9;4 progress indicator for `mode-line-process'.
Set by `ghostel-default-progress' / `ghostel-spinner-progress'.
Composed with `ghostel--mode-line-tag' (and the spinner
construct, when active) by `ghostel--mode-line-refresh'.")

(defun ghostel--mode-line-tag-mouse-exit (event)
  "Mouse-1 handler on the input-mode mode-line tag.
EVENT is the mouse event that triggered the click.  Read-only modes return
to the pre-readonly mode; char and line modes return to semi-char."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (pcase ghostel--input-mode
      ((or 'copy 'emacs) (ghostel-readonly-exit))
      ((or 'char 'line)  (ghostel-semi-char-mode)))))

(defvar ghostel--mode-line-tag-mouse-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'ghostel--mode-line-tag-mouse-exit)
    map)
  "Keymap attached to the input-mode tag in `mode-line-process'.")

(defun ghostel--mode-line-tag-help-echo-text (mode)
  "Return current help-echo text for the input MODE mode-line tag.
MODE is one of `char', `line', `copy', `emacs'."
  (substitute-command-keys
   (pcase mode
     ('char
      "Ghostel char-mode: \\<ghostel-char-mode-map>\\[ghostel-semi-char-mode] or mouse-1 to exit")
     ('line
      "Ghostel line-mode: \\<ghostel-line-mode-map>\\[ghostel-semi-char-mode] or mouse-1 to exit")
     ((or 'copy 'emacs)
      (let ((name (if (eq mode 'copy) "copy" "emacs"))
            (exit (if ghostel-readonly-fast-exit
                      "\\`q' / \\`C-g' / mouse-1 to exit"
                    "\\<ghostel-mode-map>\\[ghostel-semi-char-mode] or mouse-1 to exit")))
        (format "Ghostel %s-mode: %s" name exit))))))

(defun ghostel--mode-line-tag-make (mode label)
  "Return LABEL propertized as a clickable mode-line tag for MODE."
  (propertize label
              'help-echo (lambda (&rest _)
                           (ghostel--mode-line-tag-help-echo-text mode))
              'mouse-face 'mode-line-highlight
              'local-map ghostel--mode-line-tag-mouse-map))

(defun ghostel--mode-line-refresh ()
  "Recompute `mode-line-process' from tag + spinner + progress.
Composes `ghostel--mode-line-tag', the spinner construct (when
`ghostel--spinner-active' is non-nil), and
`ghostel--mode-line-progress' so the input-mode label stays
visible while a progress indicator or spinner is active.  When
only one component is active the value is that component
directly (so callers and tests that expect a plain string keep
working); otherwise it is a list mode-line construct.

Skips `setq' and `force-mode-line-update' when the composed value
is unchanged — `ghostel-default-progress' calls this once per
OSC 9;4 packet, and same-value packets must not fire FMLU."
  (let* ((parts (delq nil
                      (list ghostel--mode-line-tag
                            (and ghostel--spinner-active
                                 'spinner--mode-line-construct)
                            ghostel--mode-line-progress
                            (and ghostel--password-mode-p
                                 (propertize " 🔒Password" 'face 'warning)))))
         (new-val (pcase parts
                    ('() nil)
                    (`(,only) only)
                    (_ parts))))
    (unless (equal new-val mode-line-process)
      (setq mode-line-process new-val)
      (force-mode-line-update))))

(defun ghostel--enter-readonly-state ()
  "Common setup when entering a read-only mode (copy or Emacs).
Saves the cursor style, re-enables `hl-line-mode' if it was
suppressed, and sets the buffer read-only.  Does NOT cancel the
redraw timer — that is the caller's job when freezing."
  (setq ghostel--saved-cursor-type cursor-type)
  (setq cursor-type (default-value 'cursor-type))
  (when ghostel--saved-hl-line-mode
    (hl-line-mode 1))
  (setq buffer-read-only t)
  (add-hook 'pre-redisplay-functions #'ghostel--fake-cursor-update nil t))

(defun ghostel--leave-readonly-state ()
  "Common teardown when leaving a read-only mode.
Restores the cursor style, deactivates the mark, disables
`hl-line-mode' again, and clears `buffer-read-only'."
  (remove-hook 'pre-redisplay-functions #'ghostel--fake-cursor-update t)
  (ghostel--fake-cursor-clear)
  (setq cursor-type ghostel--saved-cursor-type)
  (deactivate-mark)
  (when ghostel--saved-hl-line-mode
    (hl-line-mode -1))
  (setq buffer-read-only nil))

(defun ghostel--freeze-terminal ()
  "Cancel the redraw timer so new output stops updating the buffer."
  (when ghostel--redraw-timer
    (cancel-timer ghostel--redraw-timer)
    (setq ghostel--redraw-timer nil)))

(defvar-local ghostel--fake-cursor-overlay nil
  "Overlay rendering the hint cursor in copy and Emacs modes.
See `ghostel-readonly-fake-cursor'.")

(defun ghostel--fake-cursor-style ()
  "Resolve `cursor-in-non-selected-windows' to `hollow', `box', or nil.
Honours the variable's full range: nil returns nil; t derives
from `ghostel--saved-cursor-type' with box variants becoming
hollow; hollow and box pass through; bar and hbar fall back to
hollow."
  (pcase cursor-in-non-selected-windows
    ('nil nil)
    ('t (pcase ghostel--saved-cursor-type
          ('nil nil)
          (_ 'hollow)))
    ('hollow 'hollow)
    ((or 'box `(box . ,_)) 'box)
    (_ 'hollow)))

(defun ghostel--fake-cursor-clear ()
  "Delete the hint cursor overlay if any."
  (when ghostel--fake-cursor-overlay
    (delete-overlay ghostel--fake-cursor-overlay)
    (setq ghostel--fake-cursor-overlay nil)))

(defun ghostel--fake-cursor-update (&optional _window)
  "Refresh the hint cursor overlay.
Draws an overlay at the live terminal cursor position when in
copy or Emacs mode, point is somewhere other than the live cursor,
and `ghostel-readonly-fake-cursor' is non-nil with a non-nil
resolved style.  Otherwise clears the overlay.

Accepts an optional unused WINDOW argument so it can serve as a
`pre-redisplay-functions' entry."
  (let ((style (and ghostel-readonly-fake-cursor
                    (memq ghostel--input-mode '(copy emacs))
                    (ghostel--fake-cursor-style)))
        (pos ghostel--cursor-char-pos))
    (cond
     ((or (null style) (null pos) (= pos (point)))
      (ghostel--fake-cursor-clear))
     (t
      (let* ((face (if (eq style 'box)
                       'ghostel-fake-cursor-box
                     'ghostel-fake-cursor))
             (eol (or (= pos (point-max))
                      (= pos (save-excursion
                               (goto-char pos)
                               (line-end-position)))))
             (ov (or ghostel--fake-cursor-overlay
                     (let ((new (make-overlay 1 1 nil t nil)))
                       (overlay-put new 'priority 100)
                       (setq ghostel--fake-cursor-overlay new)))))
        (cond
         (eol
          (move-overlay ov pos pos)
          (overlay-put ov 'face nil)
          (overlay-put ov 'after-string
                       (propertize " " 'face face)))
         (t
          (move-overlay ov pos (1+ pos))
          (overlay-put ov 'after-string nil)
          (overlay-put ov 'face face))))))))


;;; Input mode switching commands

(defun ghostel-semi-char-mode ()
  "Switch to semi-char mode — the default terminal input mode.
Most keys are sent to the terminal; keys in
`ghostel-keymap-exceptions' pass through to Emacs."
  (interactive)
  (setq ghostel--line-mode-paused nil)
  (unless (eq ghostel--input-mode 'semi-char)
    (pcase ghostel--input-mode
      ('copy  (ghostel--leave-readonly-state))
      ('emacs (ghostel--leave-readonly-state))
      ('line  (ghostel--line-mode-teardown)))
    (setq ghostel--char-mode-override-active nil)
    (setq ghostel--input-mode 'semi-char)
    (use-local-map ghostel-semi-char-mode-map)
    (setq ghostel--mode-line-tag nil)
    (ghostel--mode-line-refresh)
    (when ghostel--term
      ;; Snap the window to the live viewport so the user lands back
      ;; at the prompt after exiting copy/emacs/line.
      (ghostel--anchor-window)
      (setq ghostel--force-next-redraw t)
      (goto-char (point-max))
      (ghostel--invalidate))))

(defun ghostel-char-mode ()
  "Switch to char mode — send all keys to the terminal.
Even keys listed in `ghostel-keymap-exceptions' (\\`C-c', \\`C-x',
\\`C-h', \\`M-x', …) are sent to the terminal.
\\<ghostel-char-mode-map>The only way to exit is
\\[ghostel-semi-char-mode]."
  (interactive)
  ;; Manual mode switch — see `ghostel-semi-char-mode' for why.
  (setq ghostel--line-mode-paused nil)
  (unless (eq ghostel--input-mode 'char)
    (pcase ghostel--input-mode
      ('copy  (ghostel--leave-readonly-state))
      ('emacs (ghostel--leave-readonly-state))
      ('line  (ghostel--line-mode-teardown)))
    (setq ghostel--input-mode 'char)
    ;; Route char mode through `emulation-mode-map-alists' so it
    ;; overrides minor-mode keymaps (without this, a minor mode that
    ;; binds a prefix like \\`C-c' would steal those keys before
    ;; `ghostel-char-mode-map' got a chance).
    (setq ghostel--char-mode-override-active t)
    (use-local-map ghostel-char-mode-map)
    (setq ghostel--mode-line-tag (ghostel--mode-line-tag-make 'char ":Char"))
    (ghostel--mode-line-refresh)
    (when ghostel--term
      (ghostel--anchor-window)
      (setq ghostel--force-next-redraw t)
      (goto-char (point-max))
      (ghostel--invalidate))
    (message "Char mode (%s to exit)"
             (substitute-command-keys
              "\\<ghostel-char-mode-map>\\[ghostel-semi-char-mode]"))))

(defvar-local ghostel--pre-readonly-mode nil
  "Input mode to restore when exiting a read-only mode.
Set on every entry to copy or Emacs mode and cleared on exit.
Tracks the mode the user was in immediately before the most
recent read-only entry, so Emacs → copy → exit returns to Emacs
mode and copy → Emacs → exit returns to copy.")

(defun ghostel--readonly-keymap ()
  "Return the keymap to use for the current read-only mode."
  (if ghostel-readonly-fast-exit
      ghostel-readonly-fast-exit-mode-map
    ghostel-readonly-mode-map))

(defun ghostel--enter-readonly (mode freeze label entry-message)
  "Enter or transition between read-only modes.
MODE is `copy' or `emacs'.  FREEZE non-nil pauses live terminal
output (copy mode); nil keeps it streaming (Emacs mode).  LABEL is
the `mode-line-process' tag.  ENTRY-MESSAGE is shown on entry from
a non-read-only mode."
  ;; Manual mode switch — see `ghostel-semi-char-mode' for why.
  (setq ghostel--line-mode-paused nil)
  (let ((from ghostel--input-mode))
    ;; Track the mode we just left so a later exit returns to it.
    ;; Line mode is stateful and not safely resumable — fall back
    ;; to semi-char when exiting copy or Emacs in that case.
    (setq ghostel--pre-readonly-mode
          (pcase from
            ('line 'semi-char)
            (m m)))
    (cond
     ;; Toggle between the two read-only modes — buffer is already
     ;; read-only, just adjust the freeze state, mode-line, and keymap.
     ((memq from '(copy emacs)) nil)
     ;; First entry from a non-read-only mode.
     (t
      (pcase from
        ('line (ghostel--line-mode-teardown)
               (ghostel--enter-readonly-state))
        (_     (ghostel--enter-readonly-state)))
      (setq ghostel--char-mode-override-active nil)
      (message "%s" entry-message)))
    (if freeze
        (ghostel--freeze-terminal)
      ;; Live mode: the redraw timer must be running so output keeps
      ;; flowing.  `--invalidate' restarts it if a previous freeze
      ;; cancelled it.
      (when ghostel--term
        (ghostel--invalidate)))
    (setq ghostel--input-mode mode)
    (use-local-map (ghostel--readonly-keymap))
    (setq ghostel--mode-line-tag (ghostel--mode-line-tag-make mode label))
    (ghostel--mode-line-refresh)
    (ghostel--fake-cursor-update)))

(defun ghostel-emacs-mode ()
  "Toggle Emacs mode — read-only buffer with the terminal still running.
The terminal keeps running and scrollback keeps growing.  The
buffer is read-only, so standard Emacs commands like `isearch',
`occur', `M-x', `C-SPC' / `M-w', and regular navigation all work
unmodified over the entire materialised scrollback.  When already
in Emacs mode this exits back to the previous mode (mirroring
`ghostel-copy-mode'); otherwise exit with an explicit mode-switch
command (`\\[ghostel-semi-char-mode]'), or \\`q'/\\`C-g'/any
self-insert key when `ghostel-readonly-fast-exit' is non-nil."
  (interactive)
  (if (eq ghostel--input-mode 'emacs)
      (ghostel-readonly-exit)
    (ghostel--enter-readonly
     'emacs nil ":Emacs"
     (format "Emacs mode: terminal live, %s to exit"
             (substitute-command-keys "\\[ghostel-semi-char-mode]")))))

(defun ghostel-copy-mode ()
  "Enter copy mode for selecting and copying terminal text.
Freezes the terminal (live output is paused) and makes the buffer
read-only.  Standard Emacs navigation, search, and marking work
across the full scrollback.  When `ghostel-readonly-fast-exit' is
non-nil press \\`q' or \\[ghostel-readonly-exit] to exit; exiting
returns to whichever input mode was active before."
  (interactive)
  (if (eq ghostel--input-mode 'copy)
      (ghostel-readonly-exit)
    (ghostel--enter-readonly 'copy t ":Copy"
                             "Copy mode: Press any key to exit")))

(defun ghostel-readonly-exit ()
  "Exit copy or Emacs mode and return to the mode active before entry."
  (interactive)
  (setq quit-flag nil)
  (when (memq ghostel--input-mode '(copy emacs))
    (let ((target (or ghostel--pre-readonly-mode 'semi-char)))
      (setq ghostel--pre-readonly-mode nil)
      ;; Return to the live viewport before reenabling terminal input.
      (goto-char (point-max))
      ;; Force the anchor even when DEC 2026 synchronized output is active.
      (ghostel--anchor-window)
      (setq ghostel--force-next-redraw t)
      (pcase target
        ('char  (ghostel-char-mode))
        ('emacs (ghostel-emacs-mode))
        (_      (ghostel-semi-char-mode)))
      (ghostel-force-redraw))
    (message "Read-only mode exited")))

(defun ghostel-readonly-exit-and-clear ()
  "Exit read-only mode and clear the scrollback."
  (interactive)
  (ghostel-readonly-exit)
  (ghostel-clear-scrollback))

(defun ghostel-readonly-exit-and-send ()
  "Exit read-only mode and send the triggering key to the terminal.
Only forwards the key when the mode we are returning to actually
accepts terminal input (semi-char or char)."
  (interactive)
  (let ((target (or ghostel--pre-readonly-mode 'semi-char)))
    (ghostel-readonly-exit)
    (when (and ghostel--term (memq target '(semi-char char)))
      (ghostel--self-insert))))

(defun ghostel-readonly-RET-or-exit-and-send ()
  "Open the link at point, or exit read-only mode and send RET.
Bound to RET / `<return>' in `ghostel-readonly-fast-exit-mode-map'
so RET behaves like other input keys when fast exit is on: a press
at a hyperlink opens the link and exits read-only mode, while a
press anywhere else exits and forwards a CR to the terminal."
  (interactive)
  (if-let* ((url (ghostel--uri-at-pos (point))))
      ;; Capture URL before exiting: `ghostel-readonly-exit' moves
      ;; point to `point-max', and opening a file:// or fileref:
      ;; link switches the current buffer.
      (progn
        (ghostel-readonly-exit)
        (ghostel--open-link url))
    (let ((target (or ghostel--pre-readonly-mode 'semi-char)))
      (ghostel-readonly-exit)
      (when (and ghostel--term (memq target '(semi-char char)))
        (ghostel--send-encoded "return" "")))))

(defun ghostel--filter-soft-wraps (text)
  "Remove newlines from TEXT that were inserted by soft line wrapping.
These are newlines with the `ghostel-wrap' text property."
  (let ((chunks nil)
        (chunk-start 0)
        (pos 0)
        (len (length text)))
    (while (< pos len)
      (when (and (eq (aref text pos) ?\n)
                 (get-text-property pos 'ghostel-wrap text))
        (when (< chunk-start pos)
          (push (substring text chunk-start pos) chunks))
        (setq chunk-start (1+ pos)))
      (setq pos (1+ pos)))
    (when (< chunk-start len)
      (push (substring text chunk-start len) chunks))
    (string-join (nreverse chunks))))

(defun ghostel--clean-copy-text (text)
  "Clean TEXT for copying: remove soft-wrap newlines, strip trailing whitespace."
  (let* ((unwrapped (ghostel--filter-soft-wraps text))
         (lines (split-string unwrapped "\n"))
         (trimmed (mapcar (lambda (line) (string-trim-right line)) lines)))
    (mapconcat #'identity trimmed "\n")))

(defun ghostel-readonly-copy ()
  "Copy the selected region.
Soft-wrapped newlines are removed and trailing whitespace is
stripped so the copied text matches the original terminal content.
When `ghostel-readonly-fast-exit' is non-nil, also exits read-only mode."
  (interactive)
  (when (use-region-p)
    (let ((text (ghostel--clean-copy-text
                 (buffer-substring (region-beginning) (region-end)))))
      (kill-new text)
      (setq deactivate-mark t)  ; matching `kill-ring-save'
      (message "Copied to kill ring")))
  (when ghostel-readonly-fast-exit
    (ghostel-readonly-exit)))


;;; Line mode

(defvar-local ghostel--line-input-start nil
  "Marker pointing at the start of the user's in-progress input line.
Nil when line mode is not active.  Text between this marker and
`ghostel--line-input-end' is the editable input line.")

(defvar-local ghostel--line-input-end nil
  "Marker pointing right after the last character of the in-progress input.
Has insertion-type t so a self-insert at this position causes the
marker to advance with the new character.  Bounding the input by an
explicit marker (rather than `point-max') keeps content past the
prompt — e.g. a status bar drawn below the prompt row — out of the
snapshot read and out of the renderer's clobber path.")

(defvar-local ghostel--line-mode-history nil
  "History ring of inputs submitted via `ghostel-line-mode-send'.
Most recent first.")

(defvar-local ghostel--line-mode-history-index nil
  "Current index into `ghostel--line-mode-history' while browsing history.
Nil when not browsing.")

(defvar-local ghostel--line-mode-saved-full-redraw nil
  "Saved `ghostel-full-redraw' state from before line mode entry.
Cons (BUFFER-LOCAL-P . VALUE).  Restored by
`ghostel--line-mode-teardown' so toggling the mode does not
permanently override the user's setting.")

(defvar-local ghostel--line-mode-saved-cursor-type nil
  "Saved `cursor-type' from before line mode entry, as a singleton list.
A list (VALUE) when saved, nil when not — distinguishes \"not
saved\" from \"saved nil\" (the value the terminal asks for after
a CSI ?25l).  Line mode forces `cursor-type' to the editor's
default so point stays visible while the user navigates and
edits, and `ghostel--line-mode-teardown' restores VALUE so any
terminal-driven cursor visibility resumes on exit.")

(defvar-local ghostel--line-mode-adopted-count nil
  "Characters of pre-existing input the shell's readline still holds.
Set on line-mode entry to the length of input adopted from the
renderer (chars typed via the PTY in a previous mode).  Cleared to
0 by `ghostel--line-mode-clear-shell-readline' after sending that
many backspaces to erase them — keeps a subsequent send from
duplicating the prefix when the shell echoes our line back.")

(defun ghostel--regex-prompt-end (pos)
  "Return position past the prompt prefix on POS's line, or nil.
Matches `ghostel-prompt-regexp' anchored at BOL of POS's line.
Returns nil when the regexp is nil or doesn't match."
  (when ghostel-prompt-regexp
    (save-excursion
      (goto-char pos)
      (let ((bol (line-beginning-position))
            (eol (line-end-position)))
        (goto-char bol)
        (when (looking-at ghostel-prompt-regexp)
          (let ((end (match-end 0)))
            (and (<= end eol) end)))))))

(defun ghostel-input-start-point ()
  "Return the buffer position where the current input begins.
The cursor's buffer position is the source of truth — whatever the
terminal has written sits before it, and user input goes after.
When `ghostel--cursor-char-pos' is nil (no live terminal, or
cursor not yet positioned), fall back to the rightmost
`ghostel-prompt' text-property character.  When the cursor IS
available and the cursor's row carries `ghostel-prompt' characters
\(OSC 133 shell integration), return the position right after the
last contiguous `ghostel-prompt' char on that row.  Without the
prop, consult `ghostel-prompt-regexp' as a fallback; if neither
detects a prompt, return the cursor position itself.  Returns nil
when nothing can locate a position (no cursor and no detection)."

  (let ((cursor-pos ghostel--cursor-char-pos))
    (cond
     (cursor-pos
      (let* ((row-start (save-excursion
                          (goto-char cursor-pos)
                          (line-beginning-position)))
             (pos cursor-pos))
        ;; Walk back from the cursor on its row, looking for the
        ;; rightmost `ghostel-prompt' character.  The first prompt
        ;; char we hit (scanning right-to-left) is the end of the
        ;; prompt prefix - so its position+1, which is the current
        ;; `pos' when we stop, is the input boundary.
        (while (and (> pos row-start)
                    (not (get-text-property (1- pos) 'ghostel-prompt)))
          (setq pos (1- pos)))
        (cond
         ((and (> pos row-start)
               (get-text-property (1- pos) 'ghostel-prompt))
          pos)
         ;; No OSC 133 prop - try the regex fallback.
         ((ghostel--regex-prompt-end cursor-pos))
         ;; Neither prop nor regex - the cursor itself is the boundary
         (t cursor-pos))))
     (t
      ;; No live terminal - fall back to the OSC 133 walk-back so the helper
      ;; stays useful in unit tests that exercise prompt markers in isolation.
      (let ((pos (point-max))
            (pmin (point-min)))
        (while (and (> pos pmin)
                    (not (get-text-property (1- pos) 'ghostel-prompt)))
          (setq pos (1- pos)))
        (when (and (> pos pmin)
                   (get-text-property (1- pos) 'ghostel-prompt))
          pos))))))

(defvar-keymap ghostel-line-mode-map
  :doc "Keymap for `ghostel-line-mode'.
Editing commands work on the input region;
\\<ghostel-line-mode-map>\\[ghostel-line-mode-send-or-open-link]
sends the whole line to the shell at once, or follows the link at
point when one is there.  \\[ghostel-line-mode-newline] inserts a
literal newline in the input for multi-line prompts."
  :parent ghostel-mode-map
  "RET"        #'ghostel-line-mode-send-or-open-link
  "<return>"   #'ghostel-line-mode-send-or-open-link
  ;; Shift-Enter inserts a literal newline in the input
  "S-RET"      #'ghostel-line-mode-newline
  "S-<return>" #'ghostel-line-mode-newline
  "C-c C-c"    #'ghostel-line-mode-interrupt
  "C-d"        #'ghostel-line-mode-delete-char-or-eof
  "M-p"        #'ghostel-line-mode-history-previous
  "M-n"        #'ghostel-line-mode-history-next
  "C-a"        #'ghostel-beginning-of-input-or-line
  "TAB"        #'ghostel-line-mode-complete-at-point
  "<tab>"      #'ghostel-line-mode-complete-at-point
  "<remap> <self-insert-command>" #'ghostel-line-mode-self-insert)

(defun ghostel-line-mode-send-or-open-link ()
  "Open the hyperlink at point, or send the input line if there is none."
  (interactive)
  (let ((url (ghostel--uri-at-pos (point))))
    (if url
        (ghostel--open-link url)
      (ghostel-line-mode-send))))

(defun ghostel-line-mode-self-insert (&optional n)
  "Self-insert N times, snapping point back to the input region first.
When point sits in the read-only scrollback portion of a line-mode
buffer, jump to the end of the in-progress input
\(`ghostel--line-input-end') and self-insert there.  When point is
already inside `[ghostel--line-input-start, ghostel--line-input-end]'
this is just `self-insert-command'.

The prefix argument N is forwarded to `self-insert-command' so
\\[universal-argument] still works as expected."
  (interactive "p")
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end   (and (markerp ghostel--line-input-end)
                    (marker-position ghostel--line-input-end))))
    (when (and start end (or (< (point) start) (> (point) end)))
      (deactivate-mark)
      (goto-char end)))
  (self-insert-command (or n 1)))

(defun ghostel-line-mode-newline ()
  "Insert a literal newline in the line-mode input region.
Discoverable shortcut for `\\[quoted-insert]' followed by a newline: lets
you compose multi-line prompts in apps that distinguish submit (Enter)
from newline (Shift-Enter).  The newline goes through to the running app
verbatim when `ghostel-line-mode-send' ships the input.

Snaps point to the end of the input region first when point is in the
read-only scrollback portion, mirroring `ghostel-line-mode-self-insert'."
  (interactive)
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end   (and (markerp ghostel--line-input-end)
                    (marker-position ghostel--line-input-end))))
    (when (and start end (or (< (point) start) (> (point) end)))
      (deactivate-mark)
      (goto-char end)))
  (insert "\n"))

(defun ghostel--line-mode-alt-screen-p ()
  "Return non-nil if libghostty is on its alternate screen.
Checks DEC private modes 1049 and 1047 (the modern alt-screen
modes used by less, htop, vim, etc.)."
  (and ghostel--term
       (or (ghostel--mode-enabled ghostel--term 1049)
           (ghostel--mode-enabled ghostel--term 1047))))

(defun ghostel--line-mode-apply-readonly (marker-pos)
  "Mark `[point-min, MARKER-POS)' read-only with the rear-nonsticky trick.
The non-sticky flag lands on the last protected character so
insertion at MARKER-POS itself stays legal while edits inside the
region still signal `text-read-only'.  Setting `rear-nonsticky' to
t also stops typed input from inheriting the prompt char's `face'
\(and any other rendered-style properties libghostty painted on
it) — without this, text typed after a colored prompt picks up
the prompt's color until RET."
  (let ((inhibit-read-only t))
    (put-text-property (point-min) marker-pos 'read-only t)
    (when (> marker-pos (point-min))
      (put-text-property (1- marker-pos) marker-pos
                         'rear-nonsticky t))))

(defun ghostel--line-mode-input-end-pos (start)
  "Return the position right after the contiguous `ghostel-input' span at START.
Returns START itself when there is no `ghostel-input' span there —
the common case at a fresh prompt where libghostty has not seen
any input bytes yet, so the renderer hasn't painted the property."
  (if (get-text-property start 'ghostel-input)
      (or (next-single-property-change start 'ghostel-input nil (point-max))
          (point-max))
    start))

(defun ghostel--line-mode-trim-trailing-blank (start)
  "Delete `[START, point-max)' if the region is pure whitespace.
Used in line-mode entry/restore to scrub the renderer's trailing
blank rows past the input region while leaving any non-blank
content (a status bar drawn below the prompt, a multi-line UI from
the shell, etc.) intact."
  (when (string-match-p "\\`[[:space:]]*\\'"
                        (buffer-substring-no-properties start (point-max)))
    (let ((inhibit-read-only t))
      (delete-region start (point-max)))))

(defun ghostel--line-mode-snapshot ()
  "Capture in-progress input plus point/mark offsets and clear the input region.
Returns a plist (:input STR :point-offset N-or-nil :mark-offset N-or-nil)
suitable for `ghostel--line-mode-restore', or nil when there is no
live input marker.  The input region is bounded by
`ghostel--line-input-start' and `ghostel--line-input-end' (not
`point-max') so any content drawn past the input — e.g. a status
bar below the prompt — stays untouched."
  (let ((start-pos (and (markerp ghostel--line-input-start)
                        (marker-position ghostel--line-input-start)))
        (end-pos (and (markerp ghostel--line-input-end)
                      (marker-position ghostel--line-input-end))))
    (when (and start-pos end-pos)
      (let* ((point-offset (and (>= (point) start-pos)
                                (<= (point) end-pos)
                                (- (point) start-pos)))
             (mark-pos (and mark-active (mark)))
             (mark-offset (and mark-pos
                               (>= mark-pos start-pos)
                               (<= mark-pos end-pos)
                               (- mark-pos start-pos)))
             (input (buffer-substring-no-properties start-pos end-pos)))
        (let ((inhibit-read-only t))
          (delete-region start-pos end-pos))
        (list :input input
              :point-offset point-offset
              :mark-offset mark-offset)))))

(defun ghostel--line-mode-restore (snapshot)
  "Re-insert SNAPSHOT'd input after the new prompt and restore point/mark.
Returns non-nil on success.  Returns nil when the prompt cannot be
located (shell integration dropped out, or the prompt scrolled off
because of async output during composition); callers fall back to
forwarding the pending input raw.

Trims pure-whitespace tails past the input but preserves any
non-blank content the renderer wrote past the prompt row (e.g. a
status bar)."
  (when snapshot
    (let ((prompt-end (ghostel-input-start-point)))
      (when prompt-end
        (let ((inhibit-read-only t)
              (input (plist-get snapshot :input)))
          (ghostel--line-mode-trim-trailing-blank prompt-end)
          (when (markerp ghostel--line-input-start)
            (set-marker ghostel--line-input-start nil))
          (when (markerp ghostel--line-input-end)
            (set-marker ghostel--line-input-end nil))
          (setq ghostel--line-input-start (copy-marker prompt-end nil))
          (set-marker-insertion-type ghostel--line-input-start nil)
          (setq ghostel--line-input-end (copy-marker prompt-end t))
          (set-marker-insertion-type ghostel--line-input-end t)
          (when (and input (> (length input) 0))
            (goto-char (marker-position ghostel--line-input-start))
            ;; Insertion advances `ghostel--line-input-end' (insertion
            ;; type t) so end-marker tracks the tail of the input.
            (insert input))
          (let ((start-pos (marker-position ghostel--line-input-start))
                (end-pos (marker-position ghostel--line-input-end)))
            (ghostel--line-mode-apply-readonly start-pos)
            ;; Mark the line-mode input region with `ghostel-input' so
            ;; `ghostel--detect-urls-skip-p' skips it on the cursor's
            ;; line — without this, a path the user typed locally
            ;; (e.g. `cd src/main.rs') would get linkified and RET
            ;; would open the file instead of running
            ;; `ghostel-line-mode-send'.
            (when (< start-pos end-pos)
              (put-text-property start-pos end-pos 'ghostel-input t))
            (let ((po (plist-get snapshot :point-offset))
                  (mo (plist-get snapshot :mark-offset)))
              (when po
                (goto-char (+ start-pos po)))
              (when mo
                (set-mark (+ start-pos mo))))))
        t))))

(defun ghostel--line-mode-enter ()
  "Set up line mode in the current buffer.
Internal helper used by the interactive `ghostel-line-mode' entry
path and the auto-resume path in
`ghostel--line-mode-try-resume'.  Returns t on success, nil when
the prompt cannot be located (no cursor and no OSC 133 marker —
e.g. the prompt has not been redrawn yet after an alt-screen
exit).  Caller decides whether \"no prompt\" is a user-error or a
deferred retry.

Assumes `ghostel--term' is non-nil and the buffer is not already
in line mode (the interactive entry validates these)."
  (let ((prompt-end (ghostel-input-start-point))
        (was-frozen (eq ghostel--input-mode 'copy)))
    (when prompt-end
      (pcase ghostel--input-mode
        ('copy  (ghostel--leave-readonly-state))
        ('emacs (ghostel--leave-readonly-state)))
      ;; Copy mode froze the redraw timer; line mode is live, so the
      ;; timer must be running again before we exit this function or
      ;; the prompt sits there with no scheduled redraw until the next
      ;; PTY byte arrives.  `ghostel--invalidate' is idempotent, so the
      ;; emacs/semi-char paths (timer already live) are unaffected.
      (when (and was-frozen ghostel--term)
        (ghostel--invalidate))
      ;; Save `cursor-type' and force the editor's default for the
      ;; duration of line mode.  The user moves point freely here, so
      ;; the cursor must be visible regardless of any CSI ?25l the
      ;; running terminal app issued in semi-char/char mode.
      ;; `ghostel--set-cursor-style' is a no-op in line mode, so
      ;; further terminal requests are ignored until teardown.
      (setq ghostel--line-mode-saved-cursor-type (list cursor-type))
      (setq cursor-type (default-value 'cursor-type))
      ;; Force full redraws while line mode is active so the
      ;; snapshot/restore path always rebuilds the prompt row
      ;; (otherwise dirty-row diff could skip it and the input would
      ;; be re-inserted at a stale marker position).  Restore the
      ;; previous setting on teardown.
      (setq ghostel--line-mode-saved-full-redraw
            (cons (local-variable-p 'ghostel-full-redraw)
                  ghostel-full-redraw))
      (setq-local ghostel-full-redraw t)
      ;; If the user already typed something at this prompt via the
      ;; PTY (e.g. before switching from semi-char to line mode), the
      ;; renderer painted those cells with `ghostel-input'.  Adopt
      ;; the span as the initial line-mode input so the user does not
      ;; lose their typing.
      (let ((input-end (ghostel--line-mode-input-end-pos prompt-end)))
        ;; Trim only PURE-whitespace tails past the input.  Status
        ;; bars / multi-line UI drawn below the prompt row stay put.
        (ghostel--line-mode-trim-trailing-blank input-end)
        (setq ghostel--line-input-start (copy-marker prompt-end nil))
        (set-marker-insertion-type ghostel--line-input-start nil)
        (setq ghostel--line-input-end (copy-marker input-end t))
        (set-marker-insertion-type ghostel--line-input-end t)
        ;; Remember how many chars the shell's readline currently
        ;; holds for us — we'll erase them via backspaces before the
        ;; next PTY write so the shell doesn't append our line to its
        ;; existing input and echo a duplicated prefix.
        (setq ghostel--line-mode-adopted-count (- input-end prompt-end)))
      (setq ghostel--line-mode-history-index nil)
      (setq ghostel--char-mode-override-active nil)
      (setq ghostel--input-mode 'line)
      (use-local-map ghostel-line-mode-map)
      (setq ghostel--mode-line-tag (ghostel--mode-line-tag-make 'line ":Line"))
      (ghostel--mode-line-refresh)
      ;; Protect everything before the input marker with a read-only
      ;; text property so commands that would modify the buffer
      ;; (self-insert, delete-char, yank, …) signal `text-read-only'
      ;; when point is in the scrollback / previous output region.
      ;; The redraw path binds `inhibit-read-only' so it is
      ;; unaffected.
      (ghostel--line-mode-apply-readonly
       (marker-position ghostel--line-input-start))
      ;; Make sure the adopted input carries `ghostel-input' (the
      ;; renderer should have applied it for PTY-typed cells; reapply
      ;; for consistency, and so URL detection skips the region even
      ;; if the property was missed for some cells).
      (let ((start-pos (marker-position ghostel--line-input-start))
            (end-pos (marker-position ghostel--line-input-end)))
        (when (< start-pos end-pos)
          (let ((inhibit-read-only t))
            (put-text-property start-pos end-pos 'ghostel-input t))))
      ;; Place point at end of (any adopted) input so the user
      ;; continues typing where the shell left them.
      (goto-char (marker-position ghostel--line-input-end))
      (ghostel--line-mode-maybe-prespawn-bash-completion)
      t)))

(defun ghostel-line-mode ()
  "Switch to line mode — edit input locally, send to shell on RET.
The user types into an editable region between the last prompt
and `point-max'.  Full Emacs editing (yank, `kill-word',
transpose, etc.) works.  Pressing \\[ghostel-line-mode-send]
sends the entire line to the shell in one write; bash echoes and
executes it normally.

The terminal stays live: output streaming in around the prompt
keeps rendering, and the snapshot/restore path in
`ghostel--redraw-now' preserves the user's in-progress input
across each redraw cycle.  After RET, line mode stays active so
the user just keeps editing at the next prompt.

\\<ghostel-line-mode-map>\\[ghostel-line-mode-complete-at-point]
runs `completion-at-point' against the input region — filenames,
env vars, executables on \\=`PATH\\=', and whatever \\=`pcomplete\\='
extensions are loaded.  Install the `bash-completion' package and
set `ghostel-line-mode-use-bash-completion' to layer real bash
programmable completion (git subcommands, ssh hosts, …) on top.

Uses the terminal cursor as the input-area boundary, so REPLs
without OSC 133 (python3, irb, sqlite3, …) work too.  When OSC
133 markers are present on the cursor's row, the prompt prefix is
recognised and the input boundary lands right after it.

While a fullscreen TUI is on the alt screen, line mode cannot
edit (the TUI needs every keystroke raw); calling this command
during an alt-screen session arms a deferred-activation sentinel
instead, and line mode resumes automatically when the TUI exits."
  (interactive)
  (unless ghostel--term
    (user-error "No terminal in this buffer"))
  (cond
   ((eq ghostel--input-mode 'line))
   ((ghostel--line-mode-alt-screen-p)
    (ghostel--line-mode-defer-entry))
   ((ghostel--line-mode-enter)
    (message "Line mode: RET sends the whole line; C-c C-j to exit"))
   (t
    (user-error "Line mode could not locate the cursor or a prompt"))))

(defun ghostel--line-mode-input-text ()
  "Return the current in-progress input text, or an empty string.
Bounded by the start and end markers, not `point-max', so content
past the input region (status bar, etc.) is never read."
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end (and (markerp ghostel--line-input-end)
                  (marker-position ghostel--line-input-end))))
    (if (and start end (< start end))
        (buffer-substring-no-properties start end)
      "")))

(defun ghostel--line-mode-delete-input ()
  "Delete the current in-progress input from the buffer.
Removes only the region between the start and end markers; content
past the end marker (status bar, etc.) stays put."
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end (and (markerp ghostel--line-input-end)
                  (marker-position ghostel--line-input-end))))
    (when (and start end (< start end))
      (let ((inhibit-read-only t))
        (delete-region start end)))))

(defun ghostel--line-mode-clear-shell-readline ()
  "Erase the adopted prefix from the shell's readline buffer.
On line-mode entry we adopt any pre-existing input (chars the user
already typed via the PTY) into the editable buffer, but the shell
still holds those bytes in its own line-discipline / readline
buffer.  Before our next write to the PTY, send that many
backspaces so the upcoming line lands on an empty prompt — without
this the shell concatenates and echoes a duplicated line.

Backspaces work under any cooked-mode line discipline (bash, fish,
zsh, vi-mode readline, python REPL); a readline-only kill like
`C-u' would not.  Resets `ghostel--line-mode-adopted-count' to 0."
  (when (and ghostel--line-mode-adopted-count
             (> ghostel--line-mode-adopted-count 0)
             ghostel--term
             ghostel--process
             (process-live-p ghostel--process))
    (dotimes (_ ghostel--line-mode-adopted-count)
      (ghostel--send-encoded "backspace" "")))
  (setq ghostel--line-mode-adopted-count 0))

(defun ghostel--line-mode-teardown (&optional pause)
  "Clean up line-mode state and hand any pending input back to the shell.
Any in-progress input is forwarded to the PTY raw (no newline) so
the user can continue editing it at the shell's own prompt after
the mode switch instead of losing what they typed.  Callers that
have already handled the input themselves (like
`ghostel-line-mode-send' and `ghostel-line-mode-interrupt') delete
it from the buffer before calling this, so no double-send happens.

Restores `ghostel-full-redraw' to the value captured on entry, and
forces a final redraw so the buffer truncation done at entry is
re-materialized from libghostty.

When PAUSE is non-nil, skip forwarding pending input to the PTY,
skip the readline-clearing backspaces (the alt-screen TUI would
receive them), and skip the trailing redraw — used by
`ghostel--line-mode-pause' which has already snapshotted the input
and is running inside `ghostel--redraw-now'."
  (unless pause
    (let ((input (ghostel--line-mode-input-text)))
      ;; Erase the adopted prefix from the shell's readline before
      ;; handing back our (possibly edited) version, so the shell ends
      ;; up holding exactly INPUT instead of "<adopted>INPUT".
      (ghostel--line-mode-clear-shell-readline)
      (when (and (> (length input) 0)
                 ghostel--process
                 (process-live-p ghostel--process))
        (process-send-string ghostel--process input))))
  (ghostel--line-mode-delete-input)
  ;; Drop the `read-only' and `rear-nonsticky' properties that
  ;; protected the scrollback region during line mode so the buffer
  ;; is editable again.
  (let ((inhibit-read-only t))
    (remove-text-properties (point-min) (point-max)
                            '(read-only nil rear-nonsticky nil)))
  (when (markerp ghostel--line-input-start)
    (set-marker ghostel--line-input-start nil))
  (when (markerp ghostel--line-input-end)
    (set-marker ghostel--line-input-end nil))
  (setq ghostel--line-input-start nil)
  (setq ghostel--line-input-end nil)
  (setq ghostel--line-mode-history-index nil)
  (setq ghostel--line-mode-adopted-count nil)
  (when ghostel--line-mode-saved-full-redraw
    (if (car ghostel--line-mode-saved-full-redraw)
        (setq-local ghostel-full-redraw
                    (cdr ghostel--line-mode-saved-full-redraw))
      (kill-local-variable 'ghostel-full-redraw))
    (setq ghostel--line-mode-saved-full-redraw nil))
  (when ghostel--line-mode-saved-cursor-type
    (setq cursor-type (car ghostel--line-mode-saved-cursor-type))
    (setq ghostel--line-mode-saved-cursor-type nil))
  (unless pause
    (when ghostel--term
      (let ((inhibit-read-only t))
        (ghostel--redraw ghostel--term t)))))

(defun ghostel--line-mode-pause ()
  "Snapshot in-progress input, tear down line mode, switch to semi-char.
Called by `ghostel--line-mode-pre-redraw' on a 1049/1047 transition
into the alt screen.  Stashes the snapshot in
`ghostel--line-mode-paused' so a later alt-screen-off cycle can
re-enter line mode at the new prompt with the user's typing
restored."
  (let ((snapshot (or (ghostel--line-mode-snapshot)
                      (list :input "" :point-offset nil :mark-offset nil))))
    (ghostel--line-mode-teardown 'pause)
    (setq ghostel--char-mode-override-active nil)
    (setq ghostel--input-mode 'semi-char)
    (use-local-map ghostel-semi-char-mode-map)
    (setq ghostel--mode-line-tag nil)
    (ghostel--mode-line-refresh)
    (setq ghostel--line-mode-paused snapshot)))

(defun ghostel--line-mode-try-resume ()
  "Re-enter line mode and restore the paused snapshot, if possible.
Called by `ghostel--line-mode-post-redraw' on a 1049/1047 exit.
If `ghostel-input-start-point' cannot locate a prompt
yet (the renderer has not painted the post-TUI buffer yet), the
paused snapshot is left in place so the next redraw can retry."
  (when (ghostel-input-start-point)
    (let ((snapshot ghostel--line-mode-paused))
      (setq ghostel--line-mode-paused nil)
      (when (ghostel--line-mode-enter)
        (ghostel--line-mode-restore snapshot)
        t))))

(defun ghostel--line-mode-defer-entry ()
  "Arm auto-pause so line mode activates when the alt-screen TUI exits.
Called by interactive `ghostel-line-mode' when an alt-screen TUI is
already running.  Stashes an empty snapshot so the alt-screen-off
transition picks it up and enters line mode for real.  Preserves
any existing paused snapshot (the user re-arming should not clobber
input captured by an earlier auto-pause)."
  (unless ghostel--line-mode-paused
    (setq ghostel--line-mode-paused
          (list :input "" :point-offset nil :mark-offset nil)))
  (message "Line mode armed — will activate when the TUI exits"))

(defun ghostel--line-mode-pre-redraw ()
  "Pause line mode if alt-screen is on while in line mode.
Runs at the top of `ghostel--redraw-now' after process output has
already been fed to the terminal, but before the renderer paints.
Pausing here lets us snapshot the
in-progress input before libghostty's grid (which does not contain
it) drives the renderer over the buffer.  After pausing,
`ghostel--input-mode' is no longer `line', so subsequent calls
fall through — there is no need for an explicit transition cache."
  (when (and (eq ghostel--input-mode 'line)
             (ghostel--line-mode-alt-screen-p))
    (ghostel--line-mode-pause)))

(defun ghostel--line-mode-post-redraw ()
  "Resume line mode if alt-screen is off and a paused snapshot is armed.
Runs at the bottom of `ghostel--redraw-now' (after the renderer
paints) so `ghostel-input-start-point' sees the
post-TUI buffer state.  Re-attempts every redraw cycle until a
prompt is locatable — covers the case where the shell prints its
new prompt one or more redraws after libghostty leaves the alt
screen."
  (when (and ghostel--line-mode-paused
             (not (ghostel--line-mode-alt-screen-p)))
    (ghostel--line-mode-try-resume)))

(defun ghostel-line-mode-send ()
  "Send the current in-progress input line to the shell.
Reads the text between the line-input marker and `point-max',
deletes it locally, sends the input to the PTY as a single write,
then submits via an encoded `return' keypress so the running app
sees Enter the same way semi-char mode would have produced it.

The encoded Return matters for TUI apps that distinguish a
literal newline (Shift-Enter) from a submit (e.g. claude-code,
pi).  They expect CR or a kitty-keyboard-protocol-encoded Enter,
not a raw \\n; bash readline accepts CR as `accept-line' too, so
the same code path works for shells.

Stays in line mode: the next redraw cycle picks up the shell's
echo and command output, and the snapshot/restore path moves the
input marker to wherever the new prompt lands."
  (interactive)
  (unless (eq ghostel--input-mode 'line)
    (user-error "Not in line mode"))
  (let ((input (ghostel--line-mode-input-text)))
    (ghostel--line-mode-delete-input)
    (when (and (> (length input) 0)
               (or (null ghostel--line-mode-history)
                   (not (string= input (car ghostel--line-mode-history)))))
      (push input ghostel--line-mode-history)
      (when (> (length ghostel--line-mode-history)
               ghostel-line-mode-history-size)
        (setcdr (nthcdr (1- ghostel-line-mode-history-size)
                        ghostel--line-mode-history)
                nil)))
    (setq ghostel--line-mode-history-index nil)
    ;; Erase any prefix the shell already had in its readline buffer
    ;; (adopted on line-mode entry) before sending — otherwise the
    ;; shell would concatenate ours after that prefix and echo a
    ;; duplicated line.
    (ghostel--line-mode-clear-shell-readline)
    (when (and ghostel--process (process-live-p ghostel--process))
      (when (> (length input) 0)
        (process-send-string ghostel--process input))
      (ghostel--send-encoded "return" ""))))

(defun ghostel-line-mode-interrupt ()
  "Discard local input and send SIGINT (\\`C-c') to the shell.
Stays in line mode; the next redraw cycle picks up the shell's
new prompt and the snapshot/restore path repositions the input
marker."
  (interactive)
  (ghostel--line-mode-delete-input)
  (setq ghostel--line-mode-history-index nil)
  ;; C-c discards readline's input buffer shell-side, so any adopted
  ;; prefix is gone — just zero our count, no backspaces needed.
  (setq ghostel--line-mode-adopted-count 0)
  (when (and ghostel--process (process-live-p ghostel--process))
    (process-send-string ghostel--process "\C-c")))

(defun ghostel-line-mode-delete-char-or-eof ()
  "Delete the next char, or send EOF at an empty input."
  (interactive)
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end (and (markerp ghostel--line-input-end)
                  (marker-position ghostel--line-input-end))))
    (if (and start end (= start end) (= (point) start))
        (when (and ghostel--process (process-live-p ghostel--process))
          (process-send-string ghostel--process "\C-d"))
      (delete-char 1))))

(defun ghostel-beginning-of-input-or-line ()
  "Move point to the start of input on a prompt row, else `beginning-of-line'.
On a line that carries the `ghostel-prompt' text property over its
leading characters, point moves to the position right after the
last contiguous prompt character — i.e. where the user's input
begins on that prompt row.  In line mode the active input marker
\(`ghostel--line-input-start') wins over the property scan so an
empty fresh prompt still goes to the marker position.

Without the property (no OSC 133 shell integration), consult
`ghostel-prompt-regexp' so the command still finds the prompt
prefix on lines from raw shells, Python REPL, and similar.

On any other line — scrollback, output, a prompt-continuation row
that has no content past the prefix — falls through to
`move-beginning-of-line', so navigating up into history and
pressing \\`C-a' gives the standard column-0 behaviour."
  (interactive "^")
  (let* ((bol (line-beginning-position))
         (eol (line-end-position))
         ;; Line-mode marker target — only meaningful when the
         ;; marker is on the current line.
         (line-mode-target
          (and (eq ghostel--input-mode 'line)
               (markerp ghostel--line-input-start)
               (let ((m (marker-position ghostel--line-input-start)))
                 (and m (>= m bol) (<= m eol) m))))
         ;; Text-property fallback: walk forward from BOL while
         ;; chars carry `ghostel-prompt'.  Only treat as input-start
         ;; when there is real content past the prefix; an
         ;; all-prompt line (multi-line prompt continuation) goes to
         ;; BOL instead of jumping to EOL.
         (prop-target
          (unless line-mode-target
            (save-excursion
              (goto-char bol)
              (let ((pos bol))
                (while (and (< pos eol)
                            (get-text-property pos 'ghostel-prompt))
                  (setq pos (1+ pos)))
                (and (> pos bol) (< pos eol) pos)))))
         ;; Regex fallback for shells/REPLs without OSC 133.
         (regex-target
          (unless (or line-mode-target prop-target)
            (ghostel--regex-prompt-end bol))))
    (cond
     (line-mode-target (goto-char line-mode-target))
     (prop-target      (goto-char prop-target))
     (regex-target     (goto-char regex-target))
     (t                (move-beginning-of-line 1)))))



;; Public cursor-state queries

(defun ghostel-cursor-point ()
  "Return the buffer position of the terminal cursor.
This is the live editing position — wherever readline / zle /
prompt_toolkit currently has the cursor — which can sit *inside*
the typed input when the user moved it back with arrow keys, not
necessarily at the end of typed content.

Returns nil when no terminal cursor is available."
  ghostel--cursor-char-pos)

(defun ghostel--viewport-row-at (pos)
  "Return the 0-indexed viewport row of POS, or nil.
Counts newlines from `ghostel--viewport-start' to POS's line.
Returns nil when POS sits above the viewport (i.e. in scrollback)."
  (when-let* ((vp-start (ghostel--viewport-start)))
    (when (>= pos vp-start)
      (save-excursion
        (goto-char pos)
        (forward-line 0)
        (count-lines vp-start (point))))))

(defun ghostel-point-on-cursor-row-p (&optional pos)
  "Return non-nil when POS (default `point') is on the cursor's row.
Compares POS's buffer line to the terminal cursor's row (after
adjusting for scrollback).  Returns nil when no terminal cursor is
available."
  (when (and ghostel--term ghostel--cursor-pos)
    (let* ((p (or pos (point)))
           (trow (cdr ghostel--cursor-pos))
           (prow (ghostel--viewport-row-at p)))
      (and prow (= prow trow)))))


(defun ghostel--line-mode-replace-input (text)
  "Replace the current in-progress input with TEXT."
  (ghostel--line-mode-delete-input)
  (when (and ghostel--line-input-start
             (marker-position ghostel--line-input-start))
    (goto-char (marker-position ghostel--line-input-start))
    ;; Insertion advances `ghostel--line-input-end' (insertion type
    ;; t), so the end marker tracks the new input's tail.
    (insert text)
    (when (markerp ghostel--line-input-end)
      (goto-char (marker-position ghostel--line-input-end)))))

(defun ghostel-line-mode-history-previous ()
  "Replace the input with the previous entry from history."
  (interactive)
  (when ghostel--line-mode-history
    (let* ((len (length ghostel--line-mode-history))
           (idx (if ghostel--line-mode-history-index
                    (min (1- len) (1+ ghostel--line-mode-history-index))
                  0)))
      (setq ghostel--line-mode-history-index idx)
      (ghostel--line-mode-replace-input
       (nth idx ghostel--line-mode-history)))))

(defun ghostel-line-mode-history-next ()
  "Replace the input with the next entry from history."
  (interactive)
  (cond
   ((null ghostel--line-mode-history-index)
    (ghostel--line-mode-replace-input ""))
   ((zerop ghostel--line-mode-history-index)
    (setq ghostel--line-mode-history-index nil)
    (ghostel--line-mode-replace-input ""))
   (t
    (setq ghostel--line-mode-history-index
          (1- ghostel--line-mode-history-index))
    (ghostel--line-mode-replace-input
     (nth ghostel--line-mode-history-index ghostel--line-mode-history)))))

(defun ghostel--line-mode-bash-completion-available-p ()
  "Return non-nil when bash-completion should be used for line-mode TAB.
Honours `ghostel-line-mode-use-bash-completion': loads the package
when set to t, attempts a soft load when set to `auto', returns nil
otherwise."
  (pcase ghostel-line-mode-use-bash-completion
    ('nil nil)
    ('auto (require 'bash-completion nil 'noerror))
    (_ (require 'bash-completion))))

(defun ghostel--line-mode-effective-capfs ()
  "Return the capf list used by `ghostel-line-mode-complete-at-point'.
Starts from `ghostel-line-mode-completion-at-point-functions' and
prepends `bash-completion-capf-nonexclusive' when bash-completion
integration is enabled and available."
  (let ((funs (copy-sequence
               ghostel-line-mode-completion-at-point-functions)))
    (when (and (ghostel--line-mode-bash-completion-available-p)
               (not (memq #'bash-completion-capf-nonexclusive funs)))
      (push #'bash-completion-capf-nonexclusive funs))
    funs))

(defun ghostel--line-mode-maybe-prespawn-bash-completion ()
  "Spawn the bash-completion subprocess eagerly when configured.
Honours `ghostel-line-mode-bash-completion-prespawn'.  No-op when
the option is nil, when bash-completion is unavailable, or when
the subprocess is already running (the bash-completion entry
point is idempotent)."
  (when (and ghostel-line-mode-bash-completion-prespawn
             (ghostel--line-mode-bash-completion-available-p)
             (fboundp 'bash-completion-require-process))
    (ignore-errors (bash-completion-require-process))))

(defun ghostel-line-mode-complete-at-point ()
  "Complete the input at point against the line-mode capf stack.
Narrows to `[ghostel--line-input-start, ghostel--line-input-end)'
before delegating to `completion-at-point' so that comint/shell
completion functions parse only the user's typed input — the
prompt and surrounding scrollback are invisible to them.

When point sits in the read-only scrollback, snaps to the input
end first (mirrors `ghostel-line-mode-self-insert').

Refreshes `comint-file-name-prefix' from `default-directory' on
each call so completions follow OSC 7 / TRAMP directory tracking
when it flips between local and remote.

The capf list comes from `ghostel--line-mode-effective-capfs',
which combines `ghostel-line-mode-completion-at-point-functions'
with optional `bash-completion' integration controlled by
`ghostel-line-mode-use-bash-completion'."
  (interactive)
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end   (and (markerp ghostel--line-input-end)
                    (marker-position ghostel--line-input-end))))
    (cond
     ((not (and start end))
      ;; No live input markers — nothing to complete against.
      (user-error "Line mode: no input region to complete"))
     ((or (< (point) start) (> (point) end))
      (deactivate-mark)
      (goto-char end)
      (ghostel-line-mode-complete-at-point))
     (t
      ;; Refresh in case directory tracking flipped between
      ;; local/remote since `shell-completion-vars' first ran.
      (setq-local comint-file-name-prefix
                  (or (file-remote-p default-directory) ""))
      (save-restriction
        (narrow-to-region start end)
        (let ((completion-at-point-functions
               (ghostel--line-mode-effective-capfs)))
          (completion-at-point)))))))


(defun ghostel-copy-all ()
  "Copy the entire scrollback buffer to the kill ring."
  (interactive)
  (when ghostel--term
    (let ((text (ghostel--copy-all-text ghostel--term)))
      (when (and text (> (length text) 0))
        (kill-new text)
        (message "Copied %d characters to kill ring" (length text))))))


;;; Hyperlinks (OSC 8)

(defvar-keymap ghostel-link-map
  :doc "Keymap for clickable hyperlinks in ghostel buffers.
Mouse clicks on a linkified cell open the link in any input mode.

RET not bound here so a misdetected link inside a typed command in
semi-char/char mode never hijacks the key away from the PTY."
  "<mouse-1>" #'ghostel-open-link-at-click
  "<mouse-2>" #'ghostel-open-link-at-click)

(defun ghostel--uri-at-pos (pos)
  "Return the URI string stored in POS's `help-echo', or nil."
  (let ((uri (get-text-property pos 'help-echo)))
    (and (stringp uri) uri)))

(defun ghostel--open-link (url)
  "Open URL, dispatching by scheme.
file:// URIs open in Emacs; http(s) and other schemes use `browse-url'.
fileref: URIs (from auto-detected file[:line[:col]] patterns) open
the file at the given position in another window.  A fileref without
a line suffix opens at the start of the file or directory."
  (when (and url (stringp url))
    (cond
     ((string-match "\\`fileref:\\(.*?\\)\\(?::\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\)?\\'" url)
      (let ((file (match-string 1 url))
            (line (and (match-string 2 url)
                       (string-to-number (match-string 2 url))))
            (col (and (match-string 3 url)
                      (string-to-number (match-string 3 url)))))
        (when (file-exists-p file)
          (find-file-other-window file)
          (when line
            (goto-char (point-min))
            (forward-line (1- (max 1 line)))
            (when col (move-to-column (max 0 (1- col))))))))
     ((string-match "\\`file://\\(?:localhost\\)?\\(/.*\\)" url)
      (find-file (url-unhex-string (match-string 1 url))))
     ((string-match-p "\\`[a-z]+://" url)
      (browse-url url)))))

(defun ghostel-open-link-at-click (event)
  "Open the hyperlink at the mouse click EVENT position."
  (interactive "e")
  (ghostel--open-link (ghostel--uri-at-pos (posn-point (event-start event)))))

(defun ghostel-open-link-at-point ()
  "Open the hyperlink at point."
  (interactive)
  (ghostel--open-link (ghostel--uri-at-pos (point))))

(defun ghostel--find-link-1 (direction from)
  "Return the start of the next/previous hyperlink from FROM, or nil.
DIRECTION is `next' or `previous'.

Treats runs sharing a `ghostel-link-id' as one logical link: if FROM is
inside such a run, other runs with that id are skipped; for `previous',
the result is walked back to the earliest same-id run so a wrapped URL
lands at its start, not its last chunk."
  (let ((search-fn (if (eq direction 'next)
                       #'text-property-search-forward
                     #'text-property-search-backward))
        (skip-id (get-text-property from 'ghostel-link-id)))
    (save-excursion
      (goto-char from)
      (catch 'found
        (while-let ((match (funcall search-fn 'help-echo nil
                                    (lambda (_ v) v) t)))
          (let* ((pos (prop-match-beginning match))
                 (id (get-text-property pos 'ghostel-link-id)))
            (unless (and skip-id (equal skip-id id))
              (when (and (eq direction 'previous) id)
                (catch 'walked
                  (while-let ((earlier (text-property-search-backward
                                        'help-echo nil
                                        (lambda (_ v) v) t)))
                    (let ((earlier-pos (prop-match-beginning earlier)))
                      (if (equal id (get-text-property
                                     earlier-pos 'ghostel-link-id))
                          (setq pos earlier-pos)
                        (throw 'walked nil))))))
              (throw 'found pos))))))))

(defun ghostel--find-next-link (from)
  "Return start position of the first hyperlink after FROM, or nil.
A hyperlink is any region with a non-nil `help-echo' property.
Covers OSC 8 links, auto-detected URLs, and `fileref:' references."
  (ghostel--find-link-1 'next from))

(defun ghostel--find-previous-link (from)
  "Return start position of the first hyperlink before FROM, or nil."
  (ghostel--find-link-1 'previous from))

(defun ghostel--goto-hyperlink (direction)
  "Jump to the next/previous hyperlink.  DIRECTION is `next' or `previous'.
Wraps around when no link is found in the requested direction.
Signals `user-error' if the buffer has no hyperlinks at all."
  (let* ((search (if (eq direction 'next)
                     #'ghostel--find-next-link
                   #'ghostel--find-previous-link))
         (target (funcall search (point))))
    (unless target
      (let ((wrap-from (if (eq direction 'next) (point-min) (point-max))))
        (setq target (funcall search wrap-from))
        (when target (message "Wrapped"))))
    (if target
        (goto-char target)
      (user-error "No hyperlinks in buffer"))))

(defun ghostel-next-hyperlink (&optional n)
  "Enter copy mode and move point to the Nth next hyperlink.
A hyperlink is any OSC 8 link, auto-detected URL, or `file:line'
reference in the buffer.  Wraps to `point-min' when no link is found
after point.  Press RET to follow the link at point."
  (interactive "p")
  (unless (eq ghostel--input-mode 'copy)
    (ghostel-copy-mode))
  (dotimes (_ (or n 1))
    (ghostel--goto-hyperlink 'next)))

(defun ghostel-previous-hyperlink (&optional n)
  "Enter copy mode and move point to the Nth previous hyperlink.
Wraps to `point-max' when no link is found before point."
  (interactive "p")
  (unless (eq ghostel--input-mode 'copy)
    (ghostel-copy-mode))
  (dotimes (_ (or n 1))
    (ghostel--goto-hyperlink 'previous)))

(defun ghostel--detect-urls-skip-p (pos active-bounds)
  "Return non-nil if link detection should leave POS alone.
Skips spans already linkified (any `help-echo'), the shell's prompt
decoration (`ghostel-prompt') and the cursor's current line.
ACTIVE-BOUNDS is a (BOL . EOL) cons covering the cursor's line."
  (or (get-text-property pos 'help-echo)
      (get-text-property pos 'ghostel-prompt)
      (and active-bounds
           (>= pos (car active-bounds))
           (<= pos (cdr active-bounds)))))

(defun ghostel--detect-urls (&optional begin end)
  "Scan a buffer region for plain-text URLs and file:line references.
BEGIN and END default to `point-min' and `point-max' respectively.
Skips regions that already have a `help-echo' property (e.g. from OSC 8)
and the user's active input on the current prompt line.
Bounding the scan keeps streaming output from re-scanning the entire
materialized scrollback on every redraw.
Binds `inhibit-read-only' so the scan can attach text properties even
when called from the deferred-detection timer outside the redraw scope."
  (let* ((begin (or begin (point-min)))
         (end (or end (point-max)))
         (inhibit-read-only t)
         ;; `ghostel--cursor-char-pos' is the live terminal cursor after a redraw;
         ;; its line is the prompt the user is currently editing.  Capture as
         ;; buffer-position bounds so the per-match skip check is O(1).
         (active-pos (or ghostel--cursor-char-pos (point)))
         (active-bounds (save-excursion
                          (goto-char active-pos)
                          (cons (line-beginning-position)
                                (line-end-position)))))
    (save-excursion
      ;; Pass 1: http(s) URLs
      (when ghostel-enable-url-detection
        (goto-char begin)
        (while (re-search-forward
                "https?://[^ \t\n\r\"<>]*[^ \t\n\r\"<>.,;:!?)>]"
                end t)
          (let ((beg (match-beginning 0))
                (mend (match-end 0)))
            (unless (ghostel--detect-urls-skip-p beg active-bounds)
              (let ((url (match-string-no-properties 0)))
                (put-text-property beg mend 'help-echo url)
                (put-text-property beg mend 'mouse-face 'highlight)
                (put-text-property beg mend 'keymap ghostel-link-map))))))
      ;; Pass 2: file:line[:col] references (e.g. "./foo.el:42",
      ;; "/tmp/bar.rs:10", or bare relative paths like "src/main.rs:42:4"
      ;; from compiler output).  The full regex is assembled from fixed anchor
      ;; + user-tunable path + fixed `:LINE[:COL]' tail so group 1 (path) and
      ;; group 2 (line[:col]) are always present — no nil-guarding needed in
      ;; the hot loop.  A small hash memoizes `file-exists-p' so repeated paths
      ;; in a redraw (common in multi-line compiler diagnostics) don't re-stat.
      ;; Skip entirely over TRAMP: every candidate would `expand-file-name' to
      ;; a remote path and `file-exists-p' would do a network round-trip on
      ;; every redraw, stalling the timer on high-latency links.
      (when (and ghostel-enable-file-detection
                 (not (file-remote-p default-directory)))
        (goto-char begin)
        (let ((full-regex (concat ghostel--file-detection-leading-anchor
                                  "\\(" ghostel-file-detection-path-regex "\\)"
                                  "\\(" ghostel--file-detection-tail "\\)"))
              (seen (make-hash-table :test 'equal)))
          (while (re-search-forward full-regex end t)
            (let ((beg (match-beginning 1))
                  (mend (match-end 2)))
              (unless (ghostel--detect-urls-skip-p beg active-bounds)
                (let* ((path (match-string-no-properties 1))
                       (loc (match-string-no-properties 2))
                       (abs-path (expand-file-name path))
                       (cached (gethash abs-path seen 'unset))
                       (exists (if (eq cached 'unset)
                                   (puthash abs-path (file-exists-p abs-path) seen)
                                 cached)))
                  (when exists
                    (put-text-property beg mend 'help-echo
                                       (if (> (length loc) 0)
                                           (concat "fileref:" abs-path ":"
                                                   (substring loc 1))
                                         (concat "fileref:" abs-path)))
                    (put-text-property beg mend 'mouse-face 'highlight)
                    (put-text-property beg mend 'keymap ghostel-link-map)))))))))))

(defun ghostel--run-queued-plain-link-detection (buffer)
  "Run any queued redraw-triggered plain-text link detection for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((begin ghostel--plain-link-detection-begin)
            (end ghostel--plain-link-detection-end))
        (setq ghostel--plain-link-detection-timer nil
              ghostel--plain-link-detection-begin nil
              ghostel--plain-link-detection-end nil)
        (when (and begin end (<= begin end))
          (ghostel--detect-urls begin end))))))

(defun ghostel--queue-plain-link-detection (begin end)
  "Coalesce redraw-triggered plain-text link detection for BEGIN..END."
  (when (and begin end (<= begin end))
    (setq ghostel--plain-link-detection-begin
          (if ghostel--plain-link-detection-begin
              (min ghostel--plain-link-detection-begin begin)
            begin)
          ghostel--plain-link-detection-end
          (if ghostel--plain-link-detection-end
              (max ghostel--plain-link-detection-end end)
            end))
    (unless ghostel--plain-link-detection-timer
      (if (<= ghostel-plain-link-detection-delay 0)
          (ghostel--run-queued-plain-link-detection (current-buffer))
        (setq ghostel--plain-link-detection-timer
              (run-with-timer ghostel-plain-link-detection-delay nil
                              #'ghostel--run-queued-plain-link-detection
                              (current-buffer)))))))


;;; Kitty graphics protocol

(defun ghostel--kitty-mediums-bits ()
  "Encode `ghostel-kitty-graphics-mediums' as a bitfield for the module."
  (let ((bits 0)
        (mediums ghostel-kitty-graphics-mediums))
    (when (memq 'file mediums) (setq bits (logior bits 1)))
    (when (memq 'temp-file mediums) (setq bits (logior bits 2)))
    (when (memq 'shared-mem mediums) (setq bits (logior bits 4)))
    bits))

(define-error 'ghostel-kitty-unsupported-source-rect
              "Kitty graphics atlas-style source rect not supported"
              'error)

(defun ghostel--kitty-check-source-rect (src-x src-y src-w src-h pixel-w pixel-h)
  "Signal `ghostel-kitty-unsupported-source-rect' for non-default crops.
SRC-X / SRC-Y / SRC-W / SRC-H are the requested source-rect crop in image
pixels; PIXEL-W / PIXEL-H are the rendered pixel dimensions.  All zeros
means the whole image (the common case from timg/yazi).

Atlas-style placements (sub-region of the source image) aren't supported
because Emacs's image system can't crop pre-scale; refuse explicitly so
mis-rendering is visible as an error instead of silent."
  (when (or (> src-x 0) (> src-y 0)
            (and (> src-w 0) (/= src-w pixel-w))
            (and (> src-h 0) (/= src-h pixel-h)))
    (signal 'ghostel-kitty-unsupported-source-rect
            (list src-x src-y src-w src-h pixel-w pixel-h))))

(defun ghostel--kitty-apply-row-slice (row cw ch img
                                            vp-col-clamped visible-cols
                                            slice-x slice-w)
  "Apply one row of the sliced image at point.
ROW is the slice index (0-based) into the image's grid of cells.
CW / CH are the cell pixel dimensions.  IMG is the Emacs image object.
VP-COL-CLAMPED is the placement's column origin clamped to >= 0;
VISIBLE-COLS is how many columns of that row are on-screen; SLICE-X is
the slice's x-origin in image pixels (non-zero only when the placement
is partially scrolled off the left); SLICE-W is the fallback slice
width when the buffer line is shorter than the placement.

Decides between the text-property and overlay paths based on whether
the buffer line is long enough to hold the placement's column range."
  (let* ((line-pos (point))
         (line-end-pos (line-end-position))
         (start (min (+ line-pos vp-col-clamped) line-end-pos))
         (end (min (+ line-pos vp-col-clamped visible-cols) line-end-pos))
         ;; The slice's pixel width must match the cell-range width Emacs
         ;; gives us; otherwise the display engine renders the slice at
         ;; its declared size and either overlaps subsequent cells or
         ;; truncates.  This bites when `vp-col + g-cols' exceeds the
         ;; terminal width (line-end-pos clamps `end` shorter than the
         ;; slice the placement asked for) and shows up as a ghosted
         ;; copy of the image bleeding to the right.
         (range-cols (- end start))
         (clamped-slice-w (* range-cols cw))
         (slice (list 'slice slice-x (* row ch)
                      (if (> range-cols 0) clamped-slice-w slice-w)
                      ch))
         (spec (list slice img)))
    (cond
     ;; Range is empty (line shorter than vp-col) — use an overlay so we
     ;; don't eat the newline.
     ((<= end start)
      (let ((ov (make-overlay start start)))
        (overlay-put ov 'before-string (propertize " " 'display spec))
        (overlay-put ov 'ghostel-kitty t)))
     ;; Line has enough text — use text property.
     (t
      (add-text-properties start end
                           (list 'display spec 'ghostel-kitty t))))
    (when (< line-end-pos (point-max))
      (add-text-properties line-end-pos (1+ line-end-pos)
                           (list 'line-height ch 'ghostel-kitty t)))
    (setq ghostel--kitty-active t)))

(defun ghostel--kitty-display-image (data is-png abs-row vp-col grid-cols grid-rows pixel-w pixel-h
                                          src-x src-y src-w src-h)
  "Display a kitty graphics image placement in the buffer.
Called from the native module during redraw for each visible placement.
DATA is a unibyte string (PNG or PPM).
IS-PNG is non-nil for PNG, nil for PPM.
ABS-ROW is the absolute buffer row (0-indexed from `point-min'),
already accounting for materialized scrollback (the C side adds
`scrollback_in_buffer' to libghostty's viewport-relative row before
passing it here).  Without that pre-shift, an image at viewport row 0
would render at the top of the scrollback, jumping into the past as
soon as anything scrolled.  May be negative when the image's top is
above the buffer's first line (rare — only when libghostty's scrollback
got trimmed below the placement's anchor).
VP-COL is the column (may be negative — image partially off the left).
GRID-COLS and GRID-ROWS are the cell dimensions.
PIXEL-W and PIXEL-H are the rendered pixel dimensions.
SRC-X / SRC-Y / SRC-W / SRC-H are the source-rect crop in image pixels;
all zero means the whole image (the common case from timg/yazi).

The image is sized to fill its grid cells and then sliced per row, with
each slice applied on its own buffer line.  Slicing — rather than a
single multi-line `display' property — is required for the image to
actually occupy each cell row (otherwise Emacs draws the image once at
the first character of the range and the remaining rows show the
underlying text or stay blank).  Mirrors the virtual-placeholder path's
`:ascent \\='center' and `line-height' clamping so slices tile flush
across rows.

Falls back to PIXEL-W/PIXEL-H when GRID-COLS/GRID-ROWS arrive as 0 —
libghostty hasn't computed the cell layout yet on the first redraw
after a placement (a subsequent layout change would fix it, but the
user shouldn't have to trigger one)."
  (when (display-graphic-p)
    (condition-case err
        (progn
          (ghostel--kitty-check-source-rect src-x src-y src-w src-h pixel-w pixel-h)
          (let* ((cw (frame-char-width))
                 (ch (frame-char-height))
                 (g-cols (if (> grid-cols 0) grid-cols
                           (max 1 (/ (+ pixel-w cw -1) cw))))
                 (g-rows (if (> grid-rows 0) grid-rows
                           (max 1 (/ (+ pixel-h ch -1) ch))))
                 (img (create-image data (if is-png 'png 'pbm) t
                                    :width (* g-cols cw)
                                    :height (* g-rows ch)
                                    :ascent 'center))
                 (skip (max 0 abs-row))
                 (start-row (max 0 (- abs-row)))
                 ;; Clamp negative vp-col (image partially scrolled off
                 ;; the left edge): start the buffer range at column 0
                 ;; and skip the off-screen pixel columns inside the
                 ;; slice.
                 (vp-col-clamped (max 0 vp-col))
                 (start-col (max 0 (- vp-col)))
                 (slice-x (* start-col cw))
                 (visible-cols (max 0 (- g-cols start-col)))
                 (slice-w (* visible-cols cw)))
            (when (> visible-cols 0)
              (save-excursion
                (goto-char (point-min))
                (when (zerop (forward-line skip))
                  ;; Skip rows already in materialized scrollback — they
                  ;; got their overlays in an earlier emit and
                  ;; `kitty-clear' preserves scrollback overlays.
                  ;; Re-applying here would stack a second overlay on
                  ;; every scrolled-in row.
                  (let ((row start-row)
                        (more t)
                        (vp-start (or (ghostel--viewport-start) (point-min))))
                    (while (and more (< row g-rows))
                      (when (>= (point) vp-start)
                        (ghostel--kitty-apply-row-slice
                         row cw ch img
                         vp-col-clamped visible-cols slice-x slice-w))
                      (setq row (1+ row))
                      (unless (zerop (forward-line 1))
                        (setq more nil)))))))))
      (error
       (setq ghostel--kitty-last-error err)
       (message "ghostel: kitty image error: %S" err)))))

(defun ghostel--kitty-display-virtual (data is-png)
  "Display a virtual kitty graphics placement (unicode placeholders).
Searches the buffer for U+10EEEE placeholder characters and overlays
per-row image slices on the placeholder regions of each line.
DATA is a unibyte string (PNG or PPM).  IS-PNG is non-nil for PNG."
  (when (display-graphic-p)
    (condition-case err
        (let ((placeholder (string #x10EEEE))
              (cw (frame-char-width))
              (ch (frame-char-height))
              grid-cols grid-rows img)
          (save-excursion
            ;; First pass: measure the grid by walking the buffer line by
            ;; line and counting placeholders.  Tracks the *maximum* count
            ;; across rows so a short first row doesn't undersize the
            ;; image.  Avoids `line-number-at-pos' in the search loop —
            ;; that's O(buffer size) per call and was the dominant cost
            ;; for large yazi previews.
            (goto-char (point-min))
            (let ((max-line-cols 0)
                  (total-rows 0))
              (while (not (eobp))
                (let ((eol (line-end-position))
                      (this-row 0))
                  (save-excursion
                    (while (search-forward placeholder eol t)
                      (setq this-row (1+ this-row))))
                  (when (> this-row 0)
                    (setq total-rows (1+ total-rows))
                    (when (> this-row max-line-cols)
                      (setq max-line-cols this-row))))
                (forward-line 1))
              (setq grid-cols (max 1 max-line-cols))
              (setq grid-rows (max 1 total-rows)))
            ;; Create the image sized to the full grid.  `:ascent center'
            ;; aligns each slice around the line's vertical center so it
            ;; tiles flush with adjacent slices regardless of the line's
            ;; baseline (the default `:ascent 50' splits the slice across
            ;; the baseline, leaving visible offsets between rows).
            (setq img (create-image data (if is-png 'png 'pbm) t
                                    :width (* grid-cols cw)
                                    :height (* grid-rows ch)
                                    :ascent 'center))
            ;; Second pass: apply per-row slices on placeholder regions.
            ;; Walks line by line — `line-end-position' is O(1) with no
            ;; full-buffer scan per placeholder.
            (goto-char (point-min))
            (let ((row 0))
              (while (not (eobp))
                (let* ((eol (line-end-position))
                       (line-start (save-excursion
                                     (search-forward placeholder eol t))))
                  (when line-start
                    (let ((line-end eol))
                      (setq line-start (1- line-start))
                      (when (> line-end line-start)
                        (add-text-properties
                         line-start line-end
                         (list 'display (list (list 'slice 0 (* row ch)
                                                    (* grid-cols cw) ch)
                                              img)
                               'ghostel-kitty t))
                        ;; Clamp the placeholder line to `ch' so the slice
                        ;; tiles flush and the file-list column on the same
                        ;; line doesn't grow taller than non-image lines.
                        ;; The U+10EEEE fallback font and any Nerd Font
                        ;; icons would otherwise pull line height above
                        ;; `frame-char-height', leaving gaps below the
                        ;; slice and above the next line's content.
                        (when (< line-end (point-max))
                          (add-text-properties line-end (1+ line-end)
                                               (list 'line-height ch
                                                     'ghostel-kitty t)))
                        (setq ghostel--kitty-active t)))
                    (setq row (1+ row))))
                (forward-line 1)))))
      (error
       (setq ghostel--kitty-last-error err)
       (message "ghostel: kitty virtual image error: %S" err)))))

(defun ghostel--kitty-clear ()
  "Remove kitty image overlays and per-line clamps from the viewport.
Both display paths tag the regions/overlays with the `ghostel-kitty'
property so this strips only kitty-applied `display' and `line-height',
leaving other consumers of `display' (e.g. wide-char compensation)
alone.

Only the viewport region is cleared — overlays on rows that have
already been promoted to materialized scrollback are preserved so
images stay visible after they scroll past the live viewport.
libghostty stops reporting placements once they're fully out of the
viewport (`viewport_visible' goes false), so wiping scrollback would
leave nothing to re-emit and the image would vanish from history."
  (when ghostel--kitty-active
    (let* ((inhibit-read-only t)
           (vp-start (or (ghostel--viewport-start) (point-min)))
           (end (point-max))
           (pos vp-start))
      (dolist (ov (overlays-in pos end))
        (when (and (overlay-get ov 'ghostel-kitty)
                   (>= (overlay-start ov) pos))
          (delete-overlay ov)))
      (while (< pos end)
        (let ((next (next-single-property-change pos 'ghostel-kitty nil end)))
          (when (get-text-property pos 'ghostel-kitty)
            (remove-text-properties
             pos next '(display nil line-height nil ghostel-kitty nil)))
          (setq pos next)))
      ;; Drop any image fragment left over by scrollback eviction (see
      ;; `ghostel--kitty-strip-orphan-top').
      (ghostel--kitty-strip-orphan-top)
      ;; Sticky-flag hygiene: once we've stripped the viewport, anything
      ;; remaining must be in scrollback.  If there's nothing left at all,
      ;; clear the flag so future redraws skip the buffer scan entirely.
      (unless (ghostel--kitty-any-remaining-p (point-min) vp-start)
        (setq ghostel--kitty-active nil)))))

(defun ghostel--kitty-slice-y-at (pos)
  "Return the slice y-offset of a kitty image at POS, or nil if absent.
Looks at both the buffer text-property `display' and at any
`ghostel-kitty'-tagged overlay's `before-string' display property."
  (let ((display
         (or (get-text-property pos 'display)
             (cl-loop for ov in (overlays-at pos)
                      when (overlay-get ov 'ghostel-kitty)
                      thereis
                      (let ((bs (overlay-get ov 'before-string)))
                        (and bs (get-text-property 0 'display bs)))))))
    ;; Display spec is `((slice X Y W H) IMAGE)'.
    (when (and (consp display)
               (consp (car display))
               (eq (car (car display)) 'slice)
               (numberp (nth 2 (car display))))
      (nth 2 (car display)))))

(defun ghostel--kitty-strip-orphan-top ()
  "Strip kitty image debris left at point-min by scrollback eviction.

Two distinct artifacts both surface here:

1. Collapsed overlays.  `delete-region' clamps overlays inside the
   deleted range to its start instead of deleting them, so an evicted
   row's zero-width kitty overlays all snap onto the new point-min and
   stack there (dozens for a tall image).  Detected by counting
   zero-width kitty overlays per start-position — more than one at the
   same position is never legitimate (the placement loop emits at most
   one overlay per row).

2. Orphan text-property slices.  When eviction straddles an image, the
   surviving rows keep their `display' slices into a now-incomplete
   image.  Detected by a slice y-offset > 0 at point-min (y=0 would
   mean the row IS the image's top, so it's an intact image's first
   row, not an orphan)."
  (let ((inhibit-read-only t))
    ;; (1) Eviction-collapsed overlay stacks.
    (let ((counts (make-hash-table)))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (overlay-get ov 'ghostel-kitty)
                   (= (overlay-start ov) (overlay-end ov)))
          (let ((pos (overlay-start ov)))
            (puthash pos (1+ (gethash pos counts 0)) counts))))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (overlay-get ov 'ghostel-kitty)
                   (= (overlay-start ov) (overlay-end ov))
                   (> (gethash (overlay-start ov) counts 0) 1))
          (delete-overlay ov))))
    ;; (2) Orphan text-property slices at point-min.
    (let ((slice-y (ghostel--kitty-slice-y-at (point-min))))
      (when (and slice-y (> slice-y 0))
        (let ((start (point-min))
              (end (save-excursion
                     (goto-char (point-min))
                     (while (and (< (point) (point-max))
                                 (or (get-text-property (point) 'ghostel-kitty)
                                     (cl-some
                                      (lambda (ov) (overlay-get ov 'ghostel-kitty))
                                      (overlays-at (point)))))
                       (forward-line 1))
                     (point))))
          (when (> end start)
            (remove-text-properties
             start end '(display nil line-height nil ghostel-kitty nil))
            (dolist (ov (overlays-in start end))
              (when (overlay-get ov 'ghostel-kitty)
                (delete-overlay ov)))))))))

(defun ghostel--kitty-any-remaining-p (start end)
  "Non-nil if any kitty-tagged overlay or text property exists in [START, END)."
  (catch 'found
    (dolist (ov (overlays-in start end))
      (when (overlay-get ov 'ghostel-kitty)
        (throw 'found t)))
    (let ((pos start))
      (while (< pos end)
        (when (get-text-property pos 'ghostel-kitty)
          (throw 'found t))
        (setq pos (next-single-property-change pos 'ghostel-kitty nil end))))
    nil))


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
                               (current-buffer)))
    ("D"
     ;; Command finished — store exit status on the most recent entry
     ;; and notify `ghostel-command-finish-functions'.
     (let ((exit (and param (string-to-number param))))
       (when (and ghostel--prompt-positions param)
         (setcdr (car ghostel--prompt-positions) exit))
       (ghostel--run-hook-safely 'ghostel-command-finish-functions
                                 (current-buffer) exit)))))

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

(defun ghostel--query-before-killing-on-cmd-start (buf)
  "Flip the process query-on-exit flag on for BUF while a command runs.
Active only when `ghostel-query-before-killing' is `auto'.
Hung off `ghostel-command-start-functions'."
  (when (eq ghostel-query-before-killing 'auto)
    (let ((proc (buffer-local-value 'ghostel--process buf)))
      (when (process-live-p proc)
        (set-process-query-on-exit-flag proc t)))))

(defun ghostel--query-before-killing-on-cmd-finish (buf _exit)
  "Clear the process query-on-exit flag on BUF when the command finishes.
Active only when `ghostel-query-before-killing' is `auto'.
Hung off `ghostel-command-finish-functions'."
  (when (eq ghostel-query-before-killing 'auto)
    (let ((proc (buffer-local-value 'ghostel--process buf)))
      (when (process-live-p proc)
        (set-process-query-on-exit-flag proc nil)))))

(defun ghostel--prompt-input-start ()
  "From the start of a `ghostel-prompt' region, move past the prefix.
If `ghostel-input' begins on the same line, point lands at its
start; otherwise point lands just past the prompt-prefix region —
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
  "Enter Emacs mode and move to the Nth next prompt.
Emacs mode keeps the terminal running, so you can navigate between
prompts while output continues streaming in."
  (interactive "p")
  (unless (memq ghostel--input-mode '(emacs copy))
    (ghostel-emacs-mode))
  (ghostel--navigate-next-prompt n))

(defun ghostel-previous-prompt (&optional n)
  "Enter Emacs mode and move to the Nth previous prompt.
Emacs mode keeps the terminal running, so you can navigate between
prompts while output continues streaming in."
  (interactive "p")
  (unless (memq ghostel--input-mode '(emacs copy))
    (ghostel-emacs-mode))
  (ghostel--navigate-previous-prompt n))


;;; OSC 133 imenu integration

;; Each OSC 133 prompt becomes an imenu entry.  Label is
;; "<cwd>  <command>"; target is the prompt prefix's start.
;; Composes with `consult-imenu', `imenu-list', evil's `]m'/`[m'.
;;
;; The cwd is captured at OSC 133 'C' (command-start) and pushed
;; onto `ghostel--imenu-cwds', a chronological list (newest-first).
;; Reading `default-directory' lazily at index time would
;; mis-attribute every prior prompt to the *current* cwd after a
;; `cd'.
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
Pushed at command-start time, so newest-first.  Aligned by order
to the `ghostel-prompt' regions in the buffer when the index is
built.")

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
Switches to Emacs mode first in semi-char/char modes so navigation
stays in scrollback while the terminal continues running.  Line mode
is preserved.  Mirrors the landing position used by
`ghostel-next-prompt'."
  (unless (memq ghostel--input-mode '(emacs line copy))
    (ghostel-emacs-mode))
  (when (or (< position (point-min)) (> position (point-max)))
    (widen))
  (goto-char position)
  (ghostel--prompt-input-start))

(defun ghostel-imenu-setup ()
  "Wire OSC 133 prompts as imenu entries in the current buffer.
Sets `imenu-create-index-function' and `imenu-default-goto-function',
and registers the cwd-stamping hook on
`ghostel-command-start-functions'."
  (setq-local imenu-create-index-function #'ghostel--imenu-create-index)
  (setq-local imenu-default-goto-function #'ghostel--imenu-goto)
  (add-hook 'ghostel-command-start-functions
            #'ghostel--imenu-stamp-cwd nil t))



;;; Password prompt detection

;; Mirrors libghostty's heuristic (canonical mode + echo off, see
;; ghostty/src/termio/Exec.zig) so password input from sudo/ssh/gpg/etc is read
;; through `read-passwd' instead of streamed through Emacs's key handling (where
;; it would land in `view-lossage' and the recent-keys ring).  Falls back to a
;; regex match on the cursor row for cases where the local tty's echo state
;; can't be observed — remote ssh sessions, programs that don't toggle echo.

(defvar-local ghostel--password-mode-p nil
  "Non-nil while a password prompt is currently active.
Set by `ghostel--detect-password-prompt' on the rising edge and
cleared by the handler when the password is submitted (or
aborted).  Used to render the mode-line indicator and to keep
the rising-edge detector from running its hook twice for one
prompt.")

(defvar-local ghostel--password-handled-cursor nil
  "Cursor (COL . ROW) where the most recent password handler returned.
Detection is suppressed while the cursor still sits on this row.
This bridges the race window between the user submitting a
password and the foreground program restoring echo (sudo, ssh,
gpg are all canonical+!echo for tens of milliseconds after they
read), which would otherwise look like a fresh rising edge.
Cleared automatically when the falling edge is observed (echo
restored) or when the cursor moves to a different row — both
naturally re-arm the detector for follow-on prompts (a second
`sudo' in a script, a wrong-password retry that prints `Sorry,
try again.' on a new row).")

(defvar-local ghostel--password-prompt-active nil
  "Non-nil while the `ghostel-password-prompt-functions' chain is running.
Set around the hook chain in `ghostel--prompt-password' and cleared
in its unwind.  Note: \"active\" means the source chain is executing,
not that a minibuffer is necessarily open - a source may complete
without opening one (e.g. `auth-source' returning a cached secret).
The falling-edge handler uses this together with
`ghostel--password-prompt-outer-depth' and the minibuffer-identity
gate in `ghostel--cancel-password-prompt' to abort only our own
minibuffer.")

(defvar-local ghostel--password-prompt-outer-depth nil
  "Value of `minibuffer-depth' captured when our prompt opened.
`ghostel--cancel-password-prompt' aborts the active minibuffer only
when the current depth is `(1+ outer-depth)' - i.e. our `read-passwd'
is the innermost recursive edit.  This keeps the cancel from
clobbering an unrelated minibuffer (e.g. an `M-x' the user opened
before the false-positive rising edge fired).")

(defvar-local ghostel--password-confirm-timer nil
  "Pending debounce timer for `ghostel-password-prompt-debounce'.
Scheduled by `ghostel--detect-password-prompt' on the rising edge;
cancelled on the falling edge or before re-scheduling.  The timer
body (`ghostel--confirm-and-prompt') re-runs the heuristic before calling
`ghostel--prompt-password' so short-lived flips never reach the user.")

(defvar-local ghostel--password-prompt-mb-buffer nil
  "Minibuffer buffer of our currently-open `read-passwd' prompt, or nil.
Captured by a `minibuffer-with-setup-hook' wrapped around the
`ghostel-password-prompt-functions' chain, but only for minibuffers entered
from this ghostel buffer's window - so an unrelated minibuffer that happens
to open while our source is mid-IO doesn't poison the capture.")

(defun ghostel--remote-shell-p ()
  "Return non-nil when the foreground shell is on a remote host.
Trusts TRAMP `default-directory': ghostel's OSC 7 handler
\(`ghostel--update-directory') converts a remote shell's directory report
into a TRAMP path on `default-directory', so a non-nil `file-remote-p'
covers both TRAMP-spawned buffers and OSC-7-emitting remote shells."
  (and default-directory
       (file-remote-p default-directory)
       t))

(defun ghostel--cursor-row-text ()
  "Return the text of the row containing the terminal cursor, or nil.
The text is taken from the buffer (post-redraw), without text
properties, with trailing whitespace trimmed.  Returns nil for
the empty row so callers can pass the result through `or' to a
default."
  (when ghostel--term
    (let ((pos ghostel--cursor-pos)
          (vp-start (ghostel--viewport-start)))
      (when (and pos vp-start)
        (save-excursion
          (goto-char vp-start)
          (forward-line (cdr pos))
          (let ((line (string-trim-right
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))))
            (and (not (string-empty-p line)) line)))))))

(defun ghostel--probe-password-tty ()
  "Return non-nil if the foreground tty is in canonical mode with echo off.
Wraps `ghostel--pty-password-input-p' in the live-process / tty-name
guards so the rest of the detector doesn't have to repeat them, and so
tests can stub this single point without arranging a real subprocess."
  (when-let* (((processp ghostel--process))
              ((process-live-p ghostel--process))
              (tty (process-tty-name ghostel--process)))
    (ghostel--pty-password-input-p tty)))

(defun ghostel--password-prompt-detected-p ()
  "Return non-nil if the foreground program looks like it's reading a password.
Two arms:

  - libghostty heuristic (`ghostel--probe-password-tty'): the local
    pty is in canonical mode with echo off.  Catches local sudo, ssh's
    own password prompt, gpg, etc.

  - cursor-row regex (`ghostel-password-prompt-regex', defaulting to
    `comint-password-prompt-regexp').  Used only when the libghostty
    heuristic returns nil AND `ghostel--remote-shell-p' indicates a
    remote shell - the case where the local pty is in raw mode for ssh
    forwarding and the remote pty's canonical+!echo isn't visible locally.

Returns nil on miss, or a symbol naming the arm on hit (`zig' or`regex')."
  (cond
   ((ghostel--probe-password-tty) 'zig)
   ((and (ghostel--remote-shell-p)
         (ghostel--password-regex-matches-cursor-row-p))
    'regex)))

(defun ghostel--password-regex-matches-cursor-row-p ()
  "Return non-nil if the cursor row looks like a password prompt.
Matches `ghostel-password-prompt-regex' against the cursor row.
Matching is case-insensitive, mirroring `comint-watch-for-password-prompt'."
  (when-let* ((row (ghostel--cursor-row-text))
              (case-fold-search t))
    (string-match-p ghostel-password-prompt-regex row)))

(defun ghostel--cancel-password-confirm-timer ()
  "Cancel the pending `ghostel--password-confirm-timer', if any."
  (when ghostel--password-confirm-timer
    (cancel-timer ghostel--password-confirm-timer)
    (setq ghostel--password-confirm-timer nil)))

(defun ghostel--cancel-password-prompt ()
  "Abort our in-flight `read-passwd' minibuffer, if it is the innermost ours.
Two gates make sure we abort only a minibuffer we opened:

  - Depth: current `minibuffer-depth' must be `outer+1', i.e. exactly
    one minibuffer-level (ours) opened since our prompt began.
  - Minibuffer identity: `(active-minibuffer-window)''s buffer must
    equal `ghostel--password-prompt-mb-buffer', captured by the
    setup hook when our `read-passwd' was entered.  This is robust
    to the user switching focus out of the minibuffer (which makes
    `minibuffer-selected-window' return nil) and to cross-buffer
    races where an unrelated minibuffer (e.g. `M-x' in another
    buffer) is at the matching depth."
  (when (and ghostel--password-prompt-active
             ghostel--password-prompt-outer-depth
             (= (minibuffer-depth)
                (1+ ghostel--password-prompt-outer-depth))
             ghostel--password-prompt-mb-buffer
             (let ((amw (active-minibuffer-window)))
               (and amw (eq (window-buffer amw)
                            ghostel--password-prompt-mb-buffer))))
    (abort-recursive-edit)))

(defun ghostel--confirm-and-prompt (buf)
  "Re-check the password heuristic in BUF and open `ghostel--prompt-password'.
Body of the `ghostel-password-prompt-debounce' timer scheduled on
the rising edge by `ghostel--detect-password-prompt'.  Re-running
`ghostel--password-prompt-detected-p' here is what filters sub-debounce
flickers — they cleared `ghostel--password-mode-p' on the falling
edge, so we no-op."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq ghostel--password-confirm-timer nil)
      (when (and ghostel--password-mode-p
                 (ghostel--password-prompt-detected-p))
        (ghostel--prompt-password)))))

(defun ghostel--detect-password-prompt ()
  "Update `ghostel--password-mode-p' and arm the confirm timer.
Called from `ghostel--redraw-now' once the buffer reflects the
latest output.  No-op when `ghostel-detect-password-prompts' is nil
\(e.g. ghostel-compile buffers, which run the pty in `canonical+!echo'
on purpose).  Suppresses re-fires while the cursor is still on the
row where the previous handler returned (see
`ghostel--password-handled-cursor').

A rising edge schedules `ghostel--confirm-and-prompt' after
`ghostel-password-prompt-debounce' seconds; the falling edge cancels
that timer and, if our `read-passwd' has already opened, aborts it
via `ghostel--cancel-password-prompt'.  Net effect: short-lived
canonical+!echo flips trigger nothing more than a brief mode-line
indicator flash, mirroring ghostty's transient lock-icon behavior."
  (when ghostel-detect-password-prompts
    (let ((now (ghostel--password-prompt-detected-p))
          (cursor ghostel--cursor-pos))
      (cond
       ;; Echo back on — clear all state so a future prompt re-arms.
       ((not now)
        (ghostel--cancel-password-confirm-timer)
        (ghostel--cancel-password-prompt)
        (when (or ghostel--password-mode-p ghostel--password-handled-cursor)
          (setq ghostel--password-mode-p nil
                ghostel--password-handled-cursor nil)
          (ghostel--mode-line-refresh)))
       ;; Already showing the indicator (handler is in flight).
       (ghostel--password-mode-p nil)
       ;; Just-handled prompt — wait for the cursor to move off the row.
       ((and ghostel--password-handled-cursor
             cursor
             (equal cursor ghostel--password-handled-cursor))
        nil)
       ;; Rising edge: a fresh prompt or a retry on a new row.
       (t
        (setq ghostel--password-mode-p t
              ghostel--password-handled-cursor nil)
        (ghostel--mode-line-refresh)
        ;; Defer so the prompt minibuffer doesn't open from inside the
        ;; process filter — opening it there blocks further PTY output
        ;; until the user submits.  The debounce additionally gates the
        ;; open on a re-check after `ghostel-password-prompt-debounce'.
        (ghostel--cancel-password-confirm-timer)
        (setq ghostel--password-confirm-timer
              (run-at-time ghostel-password-prompt-debounce nil
                           #'ghostel--confirm-and-prompt
                           (current-buffer))))))))

(defun ghostel--default-password-source (row)
  "Default password source: prompt with `read-passwd'.
ROW is the cursor row text (used as the prompt label); falls back
to \"Password:\" when nil.  Always returns a string (or signals
quit on `keyboard-quit'), so this source - at the tail of
`ghostel-password-prompt-functions' - acts as the fallback once
any prepended sources have returned nil."
  (read-passwd (concat (or row "Password:") " ")))

(defun ghostel--prompt-password ()
  "Run `ghostel-password-prompt-functions' until one returns a password.
The cursor row text is captured once and passed to each source,
so handlers that match against the prompt don't each pay for a
separate buffer scan.  Sends the result + carriage return to the
subprocess, clears the string, and arms the post-submission
suppression so the detector doesn't re-fire while the foreground
program restores echo.  State cleanup runs even when a source
signals quit (`keyboard-quit' during `read-passwd'), so the
indicator and suppression always reach a sane state."
  (let* ((pwd nil)
         (row (ghostel--cursor-row-text))
         (origin (current-buffer)))
    (setq ghostel--password-prompt-outer-depth (minibuffer-depth)
          ghostel--password-prompt-active t
          ghostel--password-prompt-mb-buffer nil)
    (unwind-protect
        (minibuffer-with-setup-hook
            (lambda ()
              ;; Runs in the minibuffer buffer during setup; `current-buffer' is
              ;; the new minibuffer and `selected-window' is its window.
              ;; Only capture when the minibuffer was entered from ORIGIN - an
              ;; unrelated minibuffer opened concurrently has a different parent
              ;; window and must not poison our captured buffer.
              (let ((sw (minibuffer-selected-window))
                    (mb (current-buffer)))
                (when (and sw (eq (window-buffer sw) origin))
                  (with-current-buffer origin
                    (setq ghostel--password-prompt-mb-buffer mb)))))
          (setq pwd (run-hook-with-args-until-success
                     'ghostel-password-prompt-functions
                     row)))
      (setq ghostel--password-prompt-active nil
            ghostel--password-prompt-outer-depth nil
            ghostel--password-prompt-mb-buffer nil)
      ;; The (concat pwd "\r") wire copy is freshly allocated and owned by us,
      ;; so `clear-string' it after the send.  Nested `unwind-protect' so the
      ;; wire is cleared even if `process-send-string' errors (e.g. process died
      ;; between `process-live-p' and the send).
      ;;
      ;; Deliberately do NOT clear PWD itself: an `auth-source' backend that
      ;; returns the secret as a string may share that string with the
      ;; auth-source cache (the :secret in the cached plist).  Clearing it would
      ;; zero the cache in place and break later lookups.  The default
      ;; `ghostel--default-password-source' uses `read-passwd' which returns a new
      ;; string; that one lives until GC.  Sources whose backend hands out shared
      ;; strings should `copy-sequence' before returning if they want clearing.
      (when pwd
        (let ((wire (concat pwd "\r")))
          (unwind-protect
              (when (and (processp ghostel--process)
                         (process-live-p ghostel--process))
                (process-send-string ghostel--process wire))
            (clear-string wire))))
      (setq ghostel--password-handled-cursor ghostel--cursor-pos)
      (setq ghostel--password-mode-p nil)
      (ghostel--mode-line-refresh))))


;;; Callbacks from native module

(defun ghostel--osc52-eval (str)
  "Handle an OSC 52 elisp-eval payload from the terminal.
STR is the raw payload from OSC 52 with kind \\='e\\='.
Parses the command and arguments, looks up the command in
`ghostel-eval-cmds', and calls it if whitelisted."
  (let* ((parts (split-string-and-unquote str))
         (command (car parts))
         (args (cdr parts))
         (entry (assoc command ghostel-eval-cmds)))
    (if entry
        ;; Catch errors from the dispatched function: this callback runs
        ;; synchronously inside the native VT parser, so any unhandled
        ;; error propagates back up through `ghostel--write-input' and
        ;; crashes the process filter / redraw timer.
        (condition-case err
            (apply (cadr entry) args)
          (error
           (message "ghostel: error calling %s: %s"
                    command (error-message-string err))))
      (message "ghostel: unknown eval command %S (add to `ghostel-eval-cmds' to allow)"
               command))))

(defun ghostel--osc52-handle (_selection base64-data)
  "Handle an OSC 52 clipboard set request.
SELECTION is the target (e.g. \"c\" for clipboard).
BASE64-DATA is the base64-encoded text.
Only acts when `ghostel-enable-osc52' is non-nil."
  (when ghostel-enable-osc52
    (let ((text (ignore-errors (base64-decode-string base64-data))))
      (when (and text (> (length text) 0))
        (kill-new text)
        (when (fboundp 'gui-set-selection)
          (gui-set-selection 'CLIPBOARD text))))))

(defun ghostel-default-notify (title body)
  "Default handler for OSC 9 / OSC 777 notifications.
Uses the `alert' package (https://github.com/jwiegley/alert) when
available - it picks a sensible backend per platform (osascript on
macOS, libnotify on Linux, Growl, terminal-notifier, etc.).  Falls
back to `message' when alert isn't installed.  TITLE is the
notification summary; when empty (iTerm2-style OSC 9) the buffer
name is used.  BODY is the notification text.

Runs deferred off the VT-parser callpath by
`ghostel--handle-notification' with the originating ghostel buffer
current, so `buffer-name' here gives the terminal buffer's name."
  (let ((summary (if (or (null title) (string-empty-p title))
                     (buffer-name)
                   title)))
    (if (and (require 'alert nil t) (fboundp 'alert))
        (alert body :title summary)
      (message "%s: %s" summary body))))

(defun ghostel-default-progress (state progress)
  "Default handler for OSC 9;4 ConEmu progress reports.
Updates `ghostel--mode-line-progress' (and refreshes
`mode-line-process') to show the current STATE and PROGRESS (an
integer 0-100 or nil).  STATE is one of the symbols `remove',
`set', `error', `indeterminate', `pause'.  The input-mode tag in
`ghostel--mode-line-tag' is composed alongside, so progress
updates do not clobber labels like \":Char\" or \":Line\"."
  (let ((new-val
         (pcase state
           ('remove        nil)
           ('set           (format " [%d%%]" (or progress 0)))
           ('indeterminate " [...]")
           ('error         (propertize (if progress
                                           (format " [err %d%%]" progress)
                                         " [err]")
                                       'face 'error))
           ('pause         (if progress
                               (format " [paused %d%%]" progress)
                             " [paused]"))
           ;; Unknown state: keep the current progress value rather
           ;; than silently clearing it, so a future Zig-side state is
           ;; visible-but-stale instead of disappearing.
           (_              ghostel--mode-line-progress))))
    (unless (equal new-val ghostel--mode-line-progress)
      (setq ghostel--mode-line-progress new-val)
      (ghostel--mode-line-refresh))))

(defun ghostel--spinner-stop ()
  "Stop this buffer's progress spinner, if any.
Safe to call when no spinner is running.  Errors from spinner.el
\(e.g. on a half-torn-down buffer) are swallowed — this is
teardown.  Refreshes `mode-line-process' so the spinner construct
no longer renders alongside the input-mode tag."
  (when ghostel--spinner-active
    (ignore-errors (spinner-stop))
    (setq ghostel--spinner-active nil)
    (ghostel--mode-line-refresh)))

(defun ghostel-spinner-progress (state progress)
  "Spinner-driven handler for OSC 9;4 ConEmu progress reports.
Animates `mode-line-process' via spinner.el during indeterminate
progress; falls back to a static text indicator (matching
`ghostel-default-progress') for `set', `error', `pause', and `remove'.
STATE is one of those symbols; PROGRESS is an integer 0-100 or nil.

Requires spinner.el to be available; signals a `user-error' on
the first call if it is not.  The spinner style is controlled by
`ghostel-spinner-type'.  The input-mode tag (`:Char', `:Line',
…) is preserved across spinner transitions via
`ghostel--mode-line-refresh'."
  (unless (require 'spinner nil t)
    (user-error
     "Cannot run `ghostel-spinner-progress' without spinner.el — install it \
from MELPA or set `ghostel-progress-function' to #'ghostel-default-progress"))
  (if (eq state 'indeterminate)
      ;; Indeterminate: install spinner.el's mode-line construct.
      ;; Clear any prior determinate text first so the spinner shows
      ;; alone, not appended to a stale " [50%]".
      (unless ghostel--spinner-active
        (setq ghostel--mode-line-progress nil
              ghostel--spinner-active t)
        ;; spinner-start mutates `mode-line-process' directly; the
        ;; refresh below overwrites it with the composed value so the
        ;; input-mode tag stays visible alongside the spinner.
        (spinner-start ghostel-spinner-type)
        (ghostel--mode-line-refresh))
    ;; Any other state: stop the spinner and let the text indicator
    ;; take over.  `ghostel--spinner-stop' refreshes the mode-line so
    ;; the spinner construct disappears even if the new progress text
    ;; happens to equal the old one.
    (ghostel--spinner-stop)
    (ghostel-default-progress state progress)))

(defun ghostel--handle-notification (title body)
  "Dispatch TITLE and BODY to `ghostel-notification-function'.
Called synchronously from the native VT parser; the user handler
is invoked off the callpath via `run-at-time' so a slow backend
\(DBus, osascript, etc.) can't stall terminal output.  The
originating ghostel buffer is made current for the handler, so
`buffer-name' etc. report the terminal buffer and not whatever was
current when the timer happened to fire.  Errors in the handler
are caught and logged — an unhandled error in a timer callback
does not crash the process filter, but it does produce a backtrace
in batch runs."
  (when ghostel-notification-function
    (let ((buf (current-buffer))
          (fn ghostel-notification-function))
      (run-at-time
       0 nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             ;; Only `error' is caught here — `quit' (C-g) is allowed
             ;; to propagate so a user can interrupt a hung handler.
             ;; Emacs' timer machinery swallows a propagated quit.
             (condition-case err
                 (funcall fn title body)
               (error
                (message "ghostel: notification handler error: %s"
                         (error-message-string err)))))))))))

(defun ghostel--osc-progress (state-str progress)
  "Dispatch ConEmu OSC 9;4 progress to `ghostel-progress-function'.
STATE-STR is the state name as a string (sent from the native
module); it is converted to a known symbol via an explicit allowlist
to avoid polluting the obarray if a future Zig-side typo sneaks in.
Unknown state strings are silently dropped.
PROGRESS is an integer 0-100 or nil."
  (when ghostel-progress-function
    (let ((state-sym (pcase state-str
                       ("remove"        'remove)
                       ("set"           'set)
                       ("error"         'error)
                       ("indeterminate" 'indeterminate)
                       ("pause"         'pause))))
      (when state-sym
        (condition-case err
            (funcall ghostel-progress-function state-sym progress)
          (error
           (message "ghostel: progress handler error: %s"
                    (error-message-string err))))))))

(defun ghostel--flush-output (data)
  "Write DATA to the PTY, draining any pending coalesced input first.
This is the single ordering boundary for every direct PTY write from the
Zig side (key/mouse encoders, OSC query responses, focus events, VT
write-back).  Flushing the coalesce buffer here keeps encoded bytes from
overtaking preceding single-byte self-insert input."
  (when (and ghostel--process (process-live-p ghostel--process))
    (ghostel--flush-input (current-buffer))
    (process-send-string ghostel--process data)))

(defvar-local ghostel--face-cookie nil
  "Cookie from `face-remap-add-relative' for the terminal default face.")

(defvar-local ghostel--face-cookie-fg-bg nil
  "Cached (FG . BG) pair backing `ghostel--face-cookie'.
The native render path calls `ghostel--set-buffer-face' on every
dirty redraw, even when the default colors have not changed.
`face-remap-remove-relative' / `-add-relative' both call
`force-mode-line-update' internally, so the unconditional remap
generated a hundreds-of-Hz FMLU storm that starved the minibuffer
of redisplay slots.  Comparing against this cache short-circuits
the no-op case.")

(defun ghostel--set-buffer-face (fg bg)
  "Set the buffer's default face to FG foreground and BG background.
This ensures terminal text is visible regardless of the Emacs theme.
No-op when FG/BG match the cached values from the previous call."
  (let ((pair (cons fg bg)))
    (unless (equal pair ghostel--face-cookie-fg-bg)
      (when ghostel--face-cookie
        (face-remap-remove-relative ghostel--face-cookie))
      (setq ghostel--face-cookie
            (face-remap-add-relative 'default
                                     :foreground fg
                                     :background bg))
      (setq ghostel--face-cookie-fg-bg pair))))

(defun ghostel-buffer-name-by-title (title)
  "Return \"*ghostel: TITLE*\", or nil when TITLE is nil or empty.
A `ghostel-buffer-name-function' that names the buffer after the title."
  (and title (not (string= "" title))
       (format "*ghostel: %s*" title)))

(defun ghostel-buffer-name-by-directory (_title)
  "Return \"*ghostel: DIR*\" from `default-directory', abbreviated.
Ignores the title; a `ghostel-buffer-name-function' that names by directory."
  (format "*ghostel: %s*"
          (abbreviate-file-name (directory-file-name default-directory))))

(defun ghostel--rename-managed (new-name)
  "Rename the current buffer to NEW-NAME for Ghostel name tracking.
Declines after a manual rename; a nil or unchanged NEW-NAME is a no-op."
  (when (and new-name
             (or (null ghostel--managed-buffer-name)
                 (equal (buffer-name) ghostel--managed-buffer-name))
             (not (equal new-name (buffer-name))))
    (rename-buffer new-name t)
    (setq ghostel--managed-buffer-name (buffer-name))))

(defun ghostel--set-title (title)
  "Rename the buffer from a terminal TITLE report (OSC 2).
Maps TITLE through `ghostel-buffer-name-function' and renames via
`ghostel--rename-managed', which declines after a manual rename."
  (when ghostel-buffer-name-function
    (ghostel--rename-managed (funcall ghostel-buffer-name-function title))))

(defun ghostel--set-cursor-style (style visible)
  "Set the cursor style based on terminal state.
STYLE is one of: 0=bar, 1=block, 2=underline, 3=hollow-block.
VISIBLE is t or nil.
Skipped in read-only input modes (copy, Emacs, line) where the
user-facing cursor is managed by Emacs for navigation, or when
`ghostel-ignore-cursor-change' is non-nil."
  (when (and (ghostel--buffer-editable-p)
             (not ghostel-ignore-cursor-change))
    (setq cursor-type
          (if visible
              (pcase style
                (0 '(bar . 2))       ; bar
                (1 'box)             ; block
                (2 '(hbar . 2))      ; underline
                (3 'hollow)          ; hollow block
                (_ 'box))
            nil))))

(defun ghostel--update-directory (dir)
  "Update `default-directory' from terminal's OSC 7 report.
DIR may be a file:// URL or a plain path.  When the hostname in a
file:// URL does not match the local machine, construct a TRAMP path."
  (when (and dir (not (equal dir ghostel--last-directory)))
    (setq ghostel--last-directory dir)
    (let (path)
      (if (string-prefix-p "file://" dir)
          (let* ((url (url-generic-parse-url dir))
                 (host (url-host url))
                 (filename (url-filename url)))
            (if (ghostel--local-host-p host)
                (setq path filename)
              ;; Remote host — construct a TRAMP path.
              ;; Reuse the full remote prefix from default-directory
              ;; when available (preserves multi-hop, method, user).
              (let ((prefix (file-remote-p default-directory)))
                (setq path (if prefix
                               (concat prefix filename)
                             (format "/%s:%s:%s"
                                     (or ghostel-tramp-default-method
                                         tramp-default-method)
                                     host filename))))))
        (setq path dir))
      (when (and path (not (string= path "")))
        (if (file-remote-p path)
            ;; Trust the shell's report; skip file-directory-p to avoid
            ;; synchronous TRAMP connections on every cd.
            (setq default-directory (file-name-as-directory path)
                  list-buffers-directory default-directory)
          (when (file-directory-p path)
            (setq default-directory (file-name-as-directory path)
                  list-buffers-directory default-directory))))
      (when ghostel-buffer-name-function
        (let ((title (and ghostel--term (ghostel--get-title ghostel--term))))
          (ghostel--rename-managed
           (funcall ghostel-buffer-name-function title)))))))


;;; Palette

(defface ghostel-default
  '((t :inherit default))
  "Base face used to derive ghostel terminal default fg/bg colors.
Customize this to give ghostel buffers different default colors than
the rest of Emacs (e.g. a dark terminal inside a light Emacs)."
  :group 'ghostel)

(defun ghostel--face-hex-color (face attr)
  "Extract hex color string from FACE's ATTR (:foreground or :background).
Falls back to white (for :foreground) or black (for :background)."
  (or (let ((color (face-attribute face attr nil 'default)))
        (when (and (stringp color)
                   (not (member color '("unspecified"
                                        "unspecified-fg"
                                        "unspecified-bg"))))
          (let ((rgb (color-values color)))
            (if rgb
                (apply #'format "#%02x%02x%02x"
                       (mapcar (lambda (c) (ash c -8)) rgb))
              ;; Batch mode / TTY: color-values returns nil without a
              ;; display.  If the color is already "#RRGGBB", use it.
              (and (string-prefix-p "#" color) (= (length color) 7)
                   color)))))
      (if (eq attr :foreground) "#ffffff" "#000000")))

(defun ghostel--apply-palette (term)
  "Apply colors from `ghostel-color-palette' faces and default fg/bg to TERM."
  (when term
    (ghostel--set-default-colors
     term
     (ghostel--face-hex-color 'ghostel-default :foreground)
     (ghostel--face-hex-color 'ghostel-default :background))
    (when ghostel-color-palette
      (let ((colors
             (mapconcat
              (lambda (face)
                (ghostel--face-hex-color face :foreground))
              ghostel-color-palette
              "")))
        (ghostel--set-palette term colors)))))

(defun ghostel--apply-bold-config (term)
  "Apply `ghostel-bold-color' to terminal handle TERM."
  (when (user-ptrp term)
    (ghostel--load-module)
    (ghostel--set-bold-config
     term (if (eq ghostel-bold-color 'bright)
              'bright
            ghostel-bold-color))))


;;; Theme synchronization

(defun ghostel-sync-theme ()
  "Re-apply terminal color palette in all ghostel buffers.
Call this after changing the Emacs theme so terminals match."
  (interactive)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'ghostel-mode) ghostel--term)
        (ghostel--apply-palette ghostel--term)
        (ghostel--apply-bold-config ghostel--term)
        (when (ghostel--terminal-live-p)
          (setq ghostel--force-next-redraw t)
          (ghostel--redraw-now buf))))))

(defun ghostel--on-theme-change (&rest _args)
  "Hook function to sync terminal colors after theme change."
  (ghostel-sync-theme))

(if (boundp 'enable-theme-functions)
    ;; Emacs 29+
    (add-hook 'enable-theme-functions #'ghostel--on-theme-change)
  ;; Emacs < 29 fallback
  (advice-add 'load-theme :after #'ghostel--on-theme-change))


;;; Focus events

(defvar-local ghostel--focus-state nil
  "Last focus state actually reported to the terminal for this buffer.
Non-nil means a focus-in event was delivered.  Only updated when
`ghostel--focus-event' actually emits (mode 1004 enabled), so that
enabling 1004 after a focus change still lets the next event fire.")

(defun ghostel--buffer-focused-p (buf)
  "Return non-nil if BUF is logically focused.
BUF is focused when it is displayed in the selected window of a
frame whose focus state is t (i.e. the frame has keyboard focus
and the buffer is the active selection within it)."
  (seq-some (lambda (win)
              (let ((frame (window-frame win)))
                (and (eq (frame-focus-state frame) t)
                     (eq win (frame-selected-window frame)))))
            (get-buffer-window-list buf nil t)))

(defun ghostel--focus-change (&rest _)
  "Update focus state for every live ghostel buffer.
Called from `after-focus-change-function',
`window-selection-change-functions', and
`window-buffer-change-functions'.  Sends a focus event only when
the buffer's logical focus state transitions; `ghostel--focus-event'
further gates on terminal mode 1004."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (derived-mode-p 'ghostel-mode)
                   ghostel--term
                   ghostel--process
                   (process-live-p ghostel--process))
          (let ((focused (and (ghostel--buffer-focused-p buf) t)))
            (unless (eq focused ghostel--focus-state)
              (when (ghostel--focus-event ghostel--term focused)
                (setq ghostel--focus-state focused)))))))))


;;; Process management

(defun ghostel--filter (process output)
  "Process filter: feed PTY output to the terminal.
PROCESS is the shell process, OUTPUT is the raw byte string.
Output is fed to the terminal immediately; rendering is scheduled
separately so the terminal may run ahead of the materialized buffer.

For interactive echo (small output arriving shortly after a keystroke),
the redraw is performed immediately to minimize typing latency."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when ghostel--term
        ;; Native callbacks dispatched while parsing output (for example OSC 52;e)
        ;; may select another buffer.  Keep the rest of the filter's buffer-local
        ;; reads anchored to this ghostel buffer.
        (save-current-buffer
          (ghostel--write-input ghostel--term output))

        ;; Immediate redraw for interactive echo: small output arriving
        ;; within `ghostel-immediate-redraw-interval' of last keystroke.
        (if (and (> ghostel-immediate-redraw-threshold 0)
                 ghostel--last-send-time
                 (<= (length output) ghostel-immediate-redraw-threshold)
                 (< (float-time (time-subtract (current-time)
                                               ghostel--last-send-time))
                    ghostel-immediate-redraw-interval))
            (ghostel--redraw-now (current-buffer))
          ;; Bulk output: schedule a later redraw.
          (ghostel--invalidate))))))

(defun ghostel--sentinel (process event)
  "Process sentinel: clean up when shell exits.
PROCESS is the shell process, EVENT describes the state change."
  (let ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when ghostel--redraw-timer
          (cancel-timer ghostel--redraw-timer)
          (setq ghostel--redraw-timer nil))
        (when ghostel--input-timer
          (cancel-timer ghostel--input-timer)
          (setq ghostel--input-timer nil))
        (when ghostel--plain-link-detection-timer
          (cancel-timer ghostel--plain-link-detection-timer)
          (setq ghostel--plain-link-detection-timer nil
                ghostel--plain-link-detection-begin nil
                ghostel--plain-link-detection-end nil))
        (ghostel--cancel-password-confirm-timer)
        (ghostel--spinner-stop)
        (remove-hook 'pre-redisplay-functions #'ghostel--fake-cursor-update t)
        (ghostel--fake-cursor-clear)
        (run-hook-with-args 'ghostel-exit-functions buf event)
        (if ghostel-kill-buffer-on-exit
            (kill-buffer buf)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert "\n[Process exited]\n")))))))

(defun ghostel--detect-shell (shell)
  "Return shell type symbol (bash, zsh, fish) from SHELL path, or nil."
  (let ((base (file-name-nondirectory shell)))
    (cond
     ((string-match-p "bash" base) 'bash)
     ((string-match-p "zsh" base) 'zsh)
     ((string-match-p "fish" base) 'fish))))

(defun ghostel--local-host-p (host)
  "Return non-nil if HOST refers to the local machine."
  (or (null host)
      (string= host "")
      (eq t (compare-strings host nil nil "localhost" nil nil t))
      (eq t (compare-strings host nil nil (system-name) nil nil t))
      (eq t (compare-strings
             host nil nil
             (car (split-string (system-name) "\\.")) nil nil t))))

(defun ghostel--tramp-get-shell (method)
  "Get the shell for TRAMP METHOD from `ghostel-tramp-shells'.
METHOD is a TRAMP method string or t for the default."
  (let* ((specs (cdr (assoc method ghostel-tramp-shells)))
         (first (car specs))
         (second (cadr specs)))
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

(defun ghostel--shell-program-and-args (spec)
  "Split a `ghostel-shell'-style SPEC into (PROGRAM . ARGS).
SPEC may be a string (just the program path) or a list whose first
element is the program path and the remaining elements are arguments."
  (cond
   ((stringp spec) (cons spec nil))
   ((and (consp spec) (stringp (car spec)))
    (cons (car spec) (cdr spec)))
   (t (error "Invalid ghostel-shell value: %S" spec))))

(defun ghostel--get-shell ()
  "Get the shell program to run, respecting TRAMP remote connections.
When `default-directory' is a remote TRAMP path, consult
`ghostel-tramp-shells' for the appropriate shell.  Returns the
executable path as a string.  When `ghostel-shell' is a list,
only its first element (the program) is returned; use
`ghostel--resolve-shell-spec' to also obtain the extra arguments."
  (let ((value
         (if (file-remote-p default-directory)
             (with-parsed-tramp-file-name default-directory nil
               (or (ghostel--tramp-get-shell method)
                   (ghostel--tramp-get-shell t)
                   (with-connection-local-variables shell-file-name)
                   ghostel-shell))
           ghostel-shell)))
    (car (ghostel--shell-program-and-args value))))

(defun ghostel--resolve-shell-spec ()
  "Return (PROGRAM . EXTRA-ARGS) for the shell to spawn.
For local sessions, splits `ghostel-shell' (string or list).
For remote (TRAMP) sessions, defers to `ghostel--get-shell',
which always returns a string — no extra args."
  (if (file-remote-p default-directory)
      (cons (ghostel--get-shell) nil)
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
such as a per-session `.zshenv', are cleaned up as well."
  (dolist (f files)
    (ignore-errors (delete-file f)))
  (dolist (d dirs)
    (ignore-errors (delete-directory d t))))

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

(defconst ghostel--default-stty "-nl sane iutf8 -ixon erase '^?'"
  "Baseline stty flags applied before exec'ing the spawned program.
`sane' resets line discipline to known-good defaults — including
echo, canonical mode, and signal handling - which defends against
upstreams that leave the PTY in an unexpected state by the time the
spawned shell starts (TRAMP env stripping, custom remote /etc/bashrc, old
bash readline init order).  The explicit flags layer on top of `sane':
- `iutf8': kernel UTF-8 awareness so backspace erases multi-byte
  characters correctly.  `sane' may clear it on some implementations,
  so set it explicitly afterwards.
- `-ixon': disable XON/XOFF flow control so the XON/XOFF characters
  pass through to the application instead of being swallowed by the
  PTY line discipline.
- `erase ^?': Emacs PTYs leave VERASE undefined, but shells like
  fish check VERASE at startup to decide whether the DEL byte
  means backspace.")

(defun ghostel--setup-remote-integration (shell-type)
  "Set up shell integration on the remote host for SHELL-TYPE.
Reads the local integration script, writes it (with any necessary
preamble) to a temporary file on the remote host.  When the bundled
terminfo is available locally, also pushes it to a remote temp dir
over the same TRAMP connection and adds `TERMINFO=...' to the env.
Returns a plist (:env :args :stty :temp-files :temp-dirs) for
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
             (ghostel--write-remote-file temp
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
                   :stty ghostel--default-stty :temp-files (list temp))))
          ;; Zsh: ZDOTDIR replaces .zshenv search, so we restore it,
          ;; source the user's .zshenv, then load integration.
          ('zsh
           (let* ((temp-dir (make-temp-file
                             (concat remote-prefix "ghostel-") t))
                  (temp-zshenv (concat (file-name-as-directory temp-dir)
                                       ".zshenv"))
                  (remote-dir (file-remote-p temp-dir 'localname)))
             (ghostel--write-remote-file temp-zshenv
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
                   :args nil :stty ghostel--default-stty
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
                   :stty ghostel--default-stty :temp-files (list temp)))))))
        (if tinfo
            (ghostel--merge-integration-plists base tinfo)
          base))
    (error
     (message "ghostel: remote shell integration failed: %s"
              (error-message-string err))
     nil)))

(defvar ghostel--terminfo-warned nil
  "Non-nil after a warning about missing bundled terminfo has been issued.
Suppresses repeat warnings on every spawn.")

(defun ghostel--terminfo-directory ()
  "Return absolute path to bundled `etc/terminfo/' directory if usable.
Usable means a compiled xterm-ghostty entry exists in either the
macOS hashed-dir layout (78/xterm-ghostty) or the Linux layout
\(x/xterm-ghostty).  Returns nil if missing."
  (let* ((root (ghostel--resource-root))
         (dir (and root (expand-file-name "etc/terminfo" root))))
    (and dir
         (file-directory-p dir)
         (or (file-readable-p (expand-file-name "78/xterm-ghostty" dir))
             (file-readable-p (expand-file-name "x/xterm-ghostty" dir)))
         dir)))

(defun ghostel--ssh-install-enabled-p ()
  "Return non-nil if remote terminfo install is enabled.
Honors `ghostel-ssh-install-terminfo'.  Always nil when
`ghostel-term' isn't \"xterm-ghostty\" — there's no point installing
ghostty terminfo on remotes when we're not even claiming it locally."
  (and (equal ghostel-term "xterm-ghostty")
       (pcase ghostel-ssh-install-terminfo
         ('auto (and ghostel-tramp-shell-integration t))
         ('nil  nil)
         (_     t))))

(defun ghostel-ssh-clear-terminfo-cache ()
  "Delete the outbound-ssh terminfo install cache file.
The bundled bash/zsh/fish wrappers cache per-host install outcomes
in `~/.cache/ghostel/ssh-terminfo-cache' (XDG-aware).  Cache keys
include a hash of the local terminfo, so libghostty bumps invalidate
the local entries automatically — but not stale entries from before
a remote out-of-band update.  Run this command after such an update
\(or whenever you suspect the cache is wrong) to force re-probe."
  (interactive)
  (let* ((dir (or (getenv "XDG_CACHE_HOME")
                  (expand-file-name ".cache" "~")))
         (cache (expand-file-name "ghostel/ssh-terminfo-cache" dir)))
    (if (file-exists-p cache)
        (progn (delete-file cache)
               (message "ghostel: cleared %s" cache))
      (message "ghostel: no cache at %s" cache))))

(defun ghostel--terminal-env ()
  "Return list of TERM-related env-var strings for ghostel processes.
Honors `ghostel-term' and `ghostel-ssh-install-terminfo'.  When
\"xterm-ghostty\" is requested but the bundled terminfo isn't readable,
falls back to xterm-256color and warns once per session.  The SSH
install env var is only exported when the resolved TERM is actually
xterm-ghostty — falling back to xterm-256color must not advertise a
wrapper that would re-claim ghostty over ssh."
  (let* ((env (cond
               ((not (equal ghostel-term "xterm-ghostty"))
                (list (concat "TERM=" ghostel-term) "COLORTERM=truecolor"))
               (t
                (let ((tinfo (ghostel--terminfo-directory)))
                  (cond
                   (tinfo
                    (list "TERM=xterm-ghostty"
                          (concat "TERMINFO=" tinfo)
                          "TERM_PROGRAM=ghostty"
                          "TERM_PROGRAM_VERSION=1.3.2"
                          "COLORTERM=truecolor"))
                   (t
                    (unless ghostel--terminfo-warned
                      (setq ghostel--terminfo-warned t)
                      (display-warning
                       'ghostel
                       (format
                        "Bundled terminfo not found in %s; falling back to TERM=xterm-256color.  \
Apps like Claude Code may exhibit choppy redraws.  Reinstall ghostel \
to restore the terminfo/ directory, or customize `ghostel-term' to silence."
                        (or (ghostel--package-directory) "<unknown>"))
                       :warning))
                    (list "TERM=xterm-256color" "COLORTERM=truecolor"))))))))
    (if (and (member "TERM=xterm-ghostty" env)
             (ghostel--ssh-install-enabled-p))
        (append env (list "GHOSTEL_SSH_INSTALL_TERMINFO=1"))
      env)))

(defun ghostel--remote-term-preamble ()
  "Return a `/bin/sh' snippet that sets TERM for a remote spawn wrapper.
Designed to run *on the remote*, inside the per-spawn `/bin/sh -c'
wrapper, so the choice happens after TRAMP env propagation.  This
sidesteps `tramp-local-environment-variable-p', which strips
`TERM=' entries that match the local default top-level
`process-environment' — leaving the remote shell to inherit
TERM=dumb from TRAMP's connection shell, and disabling
readline/ZLE/fish line editing on the remote (issue #224).

When `ghostel-term' is the default \"xterm-ghostty\", the snippet:
1. Prepends ~/.local/share/ghostel/terminfo to TERMINFO_DIRS when
   that directory holds the bundled entry.  This lets manual
   setups co-locate terminfo with the shell-integration scripts
   (see README, \"Option 2: Manual setup\") in one place — no
   `tic', no touching ~/.terminfo.
2. Probes via `infocmp xterm-ghostty'.  The probe honors all of
   ncurses' standard lookup paths (the prepended dir, $TERMINFO,
   ~/.terminfo, $TERMINFO_DIRS, and the compiled defaults), so
   it succeeds whenever the entry is reachable any way — bundled,
   system-installed, or pushed via `ghostel-tramp-shell-integration'.
   On success, advertise ghostty; on failure, fall back to
   \"xterm-256color\" (universally available) so echo keeps working.

When `ghostel-term' was customized to anything else, honor it
verbatim.  `COLORTERM=truecolor' is exported unconditionally."
  (cond
   ((equal ghostel-term "xterm-ghostty")
    (concat
     ;; Pick up a co-located bundle if the user dropped one alongside
     ;; the shell integration scripts.  Tilde expands in assignment
     ;; context per POSIX; ${TERMINFO_DIRS:+:$TERMINFO_DIRS} preserves
     ;; any prior search list.
     "if [ -e ~/.local/share/ghostel/terminfo/x/xterm-ghostty ] "
     "|| [ -e ~/.local/share/ghostel/terminfo/78/xterm-ghostty ]; "
     "then export TERMINFO_DIRS=~/.local/share/ghostel/terminfo"
     "${TERMINFO_DIRS:+:$TERMINFO_DIRS}; "
     "fi; "
     "TERM=xterm-256color; "
     "if infocmp xterm-ghostty >/dev/null 2>&1; then "
     "TERM=xterm-ghostty; "
     "TERM_PROGRAM=ghostty; TERM_PROGRAM_VERSION=1.3.2; "
     "export TERM_PROGRAM TERM_PROGRAM_VERSION; "
     "fi; "
     "COLORTERM=truecolor; export TERM COLORTERM; "))
   (t
    (concat "TERM=" (shell-quote-argument ghostel-term)
            "; COLORTERM=truecolor; export TERM COLORTERM; "))))

(defun ghostel--spawn-pty (program program-args height width stty-flags
                                   extra-env &optional remote-p)
  "Spawn PROGRAM with PROGRAM-ARGS as a PTY-backed process in the current buffer.

Wraps PROGRAM in `/bin/sh -c' so that `stty' can configure the PTY
\(with STTY-FLAGS plus rows=HEIGHT columns=WIDTH) and the screen is
cleared before PROGRAM is exec'd.  EXTRA-ENV is prepended to
`process-environment'.  Non-nil REMOTE-P spawns the process via the
TRAMP file handler (for remote shells).

Installs `ghostel--filter' and `ghostel--sentinel', sets binary I/O,
matches the PTY window size, and stores the process in
`ghostel--process'.  Returns the process."
  ;; Wrap the program in /bin/sh -c so we can configure the PTY
  ;; before the program reads its terminal attributes.  See
  ;; `ghostel--default-stty' for the default flag set and rationale;
  ;; STTY-FLAGS is whatever the caller picked (typically that default
  ;; or a remote-integration variant).  The clear-screen hides the
  ;; stty output.  exec replaces the wrapper so only the target
  ;; program remains.
  (let* ((shell-command
          (list "/bin/sh" "-c"
                (concat
                 ;; Remote spawns: pick TERM via an on-remote probe
                 (and remote-p (ghostel--remote-term-preamble))
                 "stty " stty-flags
                 (format " rows %d columns %d" height width)
                 " 2>/dev/null; "
                 "printf '\\033[H\\033[2J'; exec "
                 (shell-quote-argument program)
                 (and program-args
                      (concat " "
                              (mapconcat #'shell-quote-argument
                                         program-args " "))))))
         (process-environment
          (append
           ghostel-environment
           (cons "INSIDE_EMACS=ghostel"
                 ;; The remote wrapper sets TERM/TERMINFO/COLORTERM/
                 ;; TERM_PROGRAM* itself; keeping the local entries
                 ;; here would also push the local TERMINFO path,
                 ;; which is meaningless on the remote and (per
                 ;; terminfo(5)) makes ncurses ignore system entries.
                 (if remote-p '() (ghostel--terminal-env)))
           extra-env
           process-environment))
         ;; Large TUI redraws (Claude Code, pi on resize) can emit
         ;; hundreds of KB in one write.  Before Emacs 31,
         ;; `process-adaptive-read-buffering' defaults to t and
         ;; throttles the filter to ~40 KB/s for bursty processes,
         ;; making resize feel like a slow cascade.
         ;; Also raise the per-read cap so one filter call can
         ;; consume a full redraw frame.  Both are captured at
         ;; `make-process' time, so they must be let-bound here.
         (process-adaptive-read-buffering nil)
         (read-process-output-max (max read-process-output-max (* 1024 1024))))
    ;; Pre-spawn hook: runs while `process-environment' is dynamically
    ;; bound to the about-to-be-spawned env, so hook functions can
    ;; `setenv' to inject/override entries that the child inherits.
    ;; See `ghostel-pre-spawn-hook'.
    (run-hooks 'ghostel-pre-spawn-hook)
    (let ((proc (make-process
                 :name "ghostel"
                 :buffer (current-buffer)
                 :command shell-command
                 :connection-type 'pty
                 :file-handler remote-p
                 :filter #'ghostel--filter
                 :sentinel #'ghostel--sentinel)))
      (setq ghostel--process proc)
      ;; Raw binary I/O — no encoding/decoding by Emacs
      (set-process-coding-system proc 'binary 'binary)
      ;; Set the PTY's actual window size (ioctl TIOCSWINSZ) so that
      ;; the program's line editor (readline/ZLE) can render properly.
      (set-process-window-size proc height width)
      ;; For `auto', start nil — we spawn at a fresh prompt.  The
      ;; OSC 133 C/D handlers flip the flag while a command runs.
      (set-process-query-on-exit-flag
       proc (if (eq ghostel-query-before-killing 'auto)
                nil
              ghostel-query-before-killing))
      (process-put proc 'adjust-window-size-function
                   #'ghostel--window-adjust-process-window-size)
      proc)))

(defun ghostel--start-process ()
  "Start the shell process with a PTY.
When `default-directory' is a remote TRAMP path, spawn the shell
on the remote host."
  ;; Read dims from the buffer-locals set by `ghostel--init-buffer'.
  ;; Recomputing from `(window-body-height)' here
  ;; would query the *selected* window, which can differ from the
  ;; buffer's window when the buffer is shown in a popup that didn't
  ;; get selected — leaving the PTY and the libghostty terminal sized
  ;; against different windows (issue #192).
  (let* ((height (max 1 ghostel--term-rows))
         (width (max 1 ghostel--term-cols))
         (remote-p (file-remote-p default-directory))
         (shell-spec (ghostel--resolve-shell-spec))
         (shell (car shell-spec))
         (extra-shell-args (cdr shell-spec))
         (ghostel-dir (ghostel--resource-root))
         ;; Detect shell type when integration is enabled.
         ;; For remote, also check ghostel-tramp-shell-integration.
         (shell-type (and ghostel-shell-integration
                          (or (not remote-p)
                              (let ((st (ghostel--detect-shell shell)))
                                (and st
                                     (or (eq ghostel-tramp-shell-integration t)
                                         (and (listp ghostel-tramp-shell-integration)
                                              (memq st ghostel-tramp-shell-integration)))
                                     st)))
                          (ghostel--detect-shell shell)))
         ;; For remote sessions, set up integration via temp files.
         (remote-integration
          (when (and remote-p shell-type)
            (ghostel--setup-remote-integration shell-type)))
         (integration-env
          (if remote-integration
              (plist-get remote-integration :env)
            (and (not remote-p)
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
                        env)))
                   ('zsh
                    (let ((zsh-dir (expand-file-name
                                    "etc/shell/bootstrap/zsh" ghostel-dir)))
                      (when (file-directory-p zsh-dir)
                        (let ((env nil)
                              (old-zdotdir (getenv "ZDOTDIR")))
                          (when old-zdotdir
                            (push (format "GHOSTEL_ZSH_ZDOTDIR=%s" old-zdotdir) env))
                          (push (format "ZDOTDIR=%s" zsh-dir) env)
                          env))))
                   ('fish
                    (let ((integ-dir (expand-file-name
                                      "etc/shell/bootstrap" ghostel-dir)))
                      (when (file-directory-p integ-dir)
                        (let ((xdg (or (getenv "XDG_DATA_DIRS")
                                       "/usr/local/share:/usr/share")))
                          (list
                           (format "XDG_DATA_DIRS=%s:%s" integ-dir xdg)
                           (format "GHOSTEL_SHELL_INTEGRATION_XDG_DIR=%s"
                                   integ-dir))))))))))
         (integration-args (cond
                            (remote-integration
                             (plist-get remote-integration :args))
                            ((and (eq shell-type 'bash) integration-env)
                             (list "--posix"))
                            (t nil)))
         (shell-args (append extra-shell-args integration-args))
         (stty-flags (if remote-integration
                         (plist-get remote-integration :stty)
                       ghostel--default-stty))
         (extra-env (append
                     (unless remote-p
                       (list (format "EMACS_GHOSTEL_PATH=%s" ghostel-dir)))
                     integration-env))
         ;; On macOS, wrap with `/usr/bin/login' so the shell starts as a login shell.
         ;; See `ghostel-macos-login-shell' for the rationale.
         ;; Skipped for remote spawns - login(1) is a local-session concept.
         (spawn-spec (if (and ghostel-macos-login-shell
                              (not remote-p)
                              (eq system-type 'darwin))
                         (ghostel--macos-login-wrap shell shell-args)
                       (cons shell shell-args)))
         (spawn-program (car spawn-spec))
         (spawn-args (cdr spawn-spec))
         (proc (ghostel--spawn-pty spawn-program spawn-args height width
                                   stty-flags extra-env remote-p)))
    (when remote-integration
      (ghostel--cleanup-temp-paths
       (plist-get remote-integration :temp-files)
       (plist-get remote-integration :temp-dirs)))
    proc))


;;; Rendering

(defvar-local ghostel--last-output-time nil
  "Time of the last process output, for adaptive frame rate.")

(defun ghostel--get-render-window (buffer)
  "Return a live window showing BUFFER.
Used as the reference window for determining graphics properties when
rendering, such as fonts and glyph sizes.  Prefer graphical windows over
terminal windows."
  (let ((wins (get-buffer-window-list buffer nil t)))
    (or (cl-find-if (lambda (w) (display-graphic-p (window-frame w)))
                    wins)
        (car wins))))

(defun ghostel--invalidate ()
  "Schedule a redraw after a short delay.
With `ghostel-adaptive-fps', use a shorter delay for the first
frame after idle to improve interactive responsiveness."
  (unless ghostel--redraw-timer
    (let ((delay (if (and ghostel-adaptive-fps ghostel--last-output-time)
                     (let ((idle-secs (float-time
                                       (time-subtract (current-time)
                                                      ghostel--last-output-time))))
                       ;; If idle for more than 100ms, use a short delay
                       ;; for snappy first-frame response.
                       (if (> idle-secs 0.1)
                           (min 0.016 ghostel-timer-delay)
                         ghostel-timer-delay))
                   ghostel-timer-delay)))
      (setq ghostel--last-output-time (current-time))
      (setq ghostel--redraw-timer
            (run-with-timer delay nil
                            #'ghostel--redraw-now
                            (current-buffer))))))

(defun ghostel--query-font-cached (font)
  "Return `query-font' metrics for FONT, caching during native redraw.
When `ghostel--query-font-cache' is nil, call `query-font' directly."
  (if ghostel--query-font-cache
      (or (gethash font ghostel--query-font-cache)
          (puthash font (query-font font) ghostel--query-font-cache))
    (query-font font)))

(defun ghostel--viewport-start ()
  "Position of the first line of the terminal viewport, or nil if rows<=0."
  (let ((tr (or ghostel--term-rows 0)))
    (when (> tr 0)
      (save-excursion
        (goto-char (point-max))
        (forward-line (- tr))
        (line-beginning-position)))))

(defun ghostel--schedule-link-detection (&optional begin end)
  "Schedule deferred plain-text link detection over BEGIN..END.
BEGIN defaults to the current viewport start (or `point-min' if the
buffer has no viewport yet).  END defaults to `point-max'.  Covers
plain-text URL and file:line detection; native OSC-8 hyperlink spans
remain handled inside the renderer."
  (when (or ghostel-enable-url-detection ghostel-enable-file-detection)
    (ghostel--queue-plain-link-detection
     (or begin (ghostel--viewport-start) (point-min))
     (or end (point-max)))))

(defun ghostel--window-anchored-p (window &optional pixel-height)
  "Non-nil if WINDOW is auto-following the new output.
When PIXEL-HEIGHT is non-nil, that value is used for calculation rather than
`(window-pixel-height)'."
  (with-current-buffer (window-buffer window)
    (when-let* (((derived-mode-p 'ghostel-mode))
                ((not (eq ghostel--input-mode 'emacs)))
                (dlh (default-line-height))
                (pixel-height (or pixel-height (window-pixel-height window)))
                (line-count (/ (float pixel-height) (float dlh)))
                (ws (window-start window))
                (ws-lines-to-end (count-lines ws (point-max))))
      (<= ws-lines-to-end line-count))))

(defconst ghostel--set-window-vscroll-preserve-supported-p
  (let ((max-args (cdr (subr-arity (symbol-function 'set-window-vscroll)))))
    (or (eq max-args 'many)
        (and (integerp max-args) (>= max-args 4))))
  "Non-nil if `set-window-vscroll' accepts PRESERVE-VSCROLL-P.")

(defun ghostel--set-window-vscroll (window vscroll &optional pixels-p preserve-vscroll-p)
  "Call `set-window-vscroll' compatibly across Emacs versions.
Arguments will be WINDOW, VSCROLL, PIXELS-P and also PRESERVE-VSCROLL-P if
supported."
  (if ghostel--set-window-vscroll-preserve-supported-p
      (apply #'set-window-vscroll window vscroll pixels-p
             (list preserve-vscroll-p))
    (set-window-vscroll window vscroll pixels-p)))

(defun ghostel--anchor-window (&optional window)
  "Scroll WINDOW so that the last row is aligned to the bottom of the window.
In graphics mode, the bottom line is anchored to the bottom of the window using
vscroll if there are more rows than can fit into the window."
  (when-let* ((window (or window (selected-window)))
              (buffer (window-buffer window)))
    (with-selected-window window
      (with-current-buffer buffer
        (let ((lines (window-screen-lines)))
          (goto-char (point-max))
          (forward-line (- (floor lines)))
          (if (and (> (point) (point-min))
                   (display-graphic-p (window-frame window)))
              (progn
                (forward-line -1)
                (set-window-start window (point))
                (let ((pixels (round (* (- 1.0 (- lines (floor lines)))
                                        (default-line-height)))))
                  (ghostel--set-window-vscroll window pixels t t)))
            (set-window-start window (point))
            (ghostel--set-window-vscroll window 0 t t)))
        (set-window-point window (or ghostel--cursor-char-pos
                                     (point-max)))))))

(defun ghostel--redraw-now (buffer)
  "Perform the actual redraw in BUFFER.
Flushes pending PTY output and runs the native renderer.  The
renderer preserves buffer positions while applying terminal
mutations; this function anchors windows that were following the
live viewport."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when ghostel--redraw-timer
        (cancel-timer ghostel--redraw-timer)
        (setq ghostel--redraw-timer nil))
      (when (and ghostel--term (ghostel--terminal-live-p))
        ;; Skip during synchronized output unless forced by scroll/resize.
        (unless (and (not ghostel--force-next-redraw)
                     (ghostel--mode-enabled ghostel--term 2026))
          ;; Pause line mode if alt-screen just turned on — must run
          ;; before the line-snapshot block so that snapshot sees the
          ;; post-pause input mode and skips its own capture.
          (ghostel--line-mode-pre-redraw)
          (setq ghostel--force-next-redraw nil)
          (when-let* ((render-win (ghostel--get-render-window buffer)))
            (let* ((all-windows (get-buffer-window-list buffer nil t))
                   (anchored (cl-remove-if-not #'ghostel--window-anchored-p
                                               all-windows))
                   ;; In line mode the user's in-progress input lives
                   ;; in the buffer past the prompt and is not in
                   ;; libghostty's grid; the renderer would otherwise
                   ;; clobber it.  Snapshot the input region (and clear
                   ;; it from the buffer) before the redraw, then
                   ;; restore it after.
                   (line-snapshot (and (eq ghostel--input-mode 'line)
                                       (ghostel--line-mode-snapshot)))
                   (inhibit-read-only t)
                   (inhibit-redisplay t)
                   (inhibit-modification-hooks t)
                   ;; Raise GC threshold to defer GC during redraw.
                   (gc-cons-threshold (min most-positive-fixnum
                                           (* gc-cons-threshold 3)))
                   (ghostel--query-font-cache (make-hash-table :test 'eq)))
              (with-selected-window render-win
                (ghostel--redraw ghostel--term ghostel-full-redraw))

              (dolist (win anchored) (ghostel--anchor-window win))

              (let* ((line-restored
                      (and line-snapshot
                           (ghostel--line-mode-restore line-snapshot))))
                ;; Restore failed (prompt scrolled off / shell
                ;; integration dropped out): the input was already
                ;; deleted from the buffer in snapshot — forward it raw
                ;; so the user does not lose what they typed.
                (when (and line-snapshot (not line-restored))
                  (let ((input (plist-get line-snapshot :input)))
                    (when (and input (> (length input) 0)
                               ghostel--process
                               (process-live-p ghostel--process))
                      (process-send-string ghostel--process input))
                    (message "ghostel: line-mode prompt lost; input forwarded raw")))

                (ghostel--schedule-link-detection (ghostel--viewport-start)
                                                  (point-max)))
              ;; Resume line mode if alt-screen just turned off, and
              ;; update the alt-screen-prev cache for the next cycle.
              (ghostel--line-mode-post-redraw))))
        (ghostel--detect-password-prompt)))))

(defun ghostel-force-redraw ()
  "Force a full terminal redraw on the next display cycle.
Cancels any pending redraw timer and schedules an immediate one.
Requires the buffer to be visible in a window; has no effect otherwise."
  (interactive)
  (ghostel--redraw-now (current-buffer)))


;;; Window resize

(defun ghostel--cell-pixel-scale ()
  "Return the active cell pixel-size scaling factor as a positive number.
May be a float - callers are expected to round when converting to a
pixel count."
  (cond
   ((numberp ghostel-cell-pixel-scale)
    (max 1 ghostel-cell-pixel-scale))
   (t (or (ghostel--detect-cell-pixel-scale) 1))))

(defun ghostel--detect-cell-pixel-scale ()
  "Compute cell pixel-size scale from display DPI, or nil if unknown.
Returns a positive number: ratio of the display's DPI to the 96 DPI
reference, kept as a float so non-integer scales (1.5x displays) flow
through correctly.  Returns nil when the display's physical size isn't
reported (some multi-monitor setups), letting the caller fall back."
  (when (display-graphic-p)
    ;; Pass the selected frame so multi-monitor setups resolve to the
    ;; display actually showing the ghostel buffer rather than the
    ;; primary display.
    (let* ((frame (selected-frame))
           (mm-w (display-mm-width frame))
           (px-w (display-pixel-width frame))
           (mm-per-inch 25.4)
           (reference-dpi 96.0))
      (when (and (numberp mm-w) (> mm-w 0)
                 (numberp px-w) (> px-w 0))
        (let ((dpi (/ (* px-w mm-per-inch) mm-w)))
          (max 1.0 (/ dpi reference-dpi)))))))

(defun ghostel--reported-cell-width ()
  "Return cell width to report to libghostty, in physical pixels."
  (round (* (frame-char-width) (ghostel--cell-pixel-scale))))

(defun ghostel--reported-cell-height ()
  "Return cell height to report to libghostty, in physical pixels."
  (round (* (frame-char-height) (ghostel--cell-pixel-scale))))

(defun ghostel--set-size-with-cell-dims (term rows cols)
  "Resize TERM to ROWS×COLS, including the reported cell pixel dimensions.
Convenience wrapper to keep the five resize sites consistent."
  (ghostel--set-size term rows cols
                     (ghostel--reported-cell-width)
                     (ghostel--reported-cell-height)))

(defun ghostel--window-adjust-process-window-size (process windows)
  "Resize the terminal to match the new Emacs window dimensions.
PROCESS is the shell process, WINDOWS is the list of windows."
  (let* ((adjust-fn (default-value 'window-adjust-process-window-size-function))
         (adjust-fn (if (and (functionp adjust-fn)
                             (not (eq adjust-fn
                                      #'ghostel--window-adjust-process-window-size)))
                        adjust-fn
                      #'window-adjust-process-window-size-smallest))
         (size (funcall adjust-fn process windows))
         (width (car size))
         (height (cdr size))
         (buffer (process-buffer process)))
    (when (and size (buffer-live-p buffer))
      (with-current-buffer buffer
        (when ghostel--term
          (cond
           ;; No change — skip entirely.
           ((and (eql height ghostel--term-rows)
                 (eql width ghostel--term-cols))
            (setq size nil))
           ;; Don't resize on minibuffer-induced rows-only change.
           ;; E.g. fish clears and re-emits its prompt on every SIGWINCH;
           ;; a `consult-buffer'/`M-x' cycle that grows then shrinks the body
           ;; would otherwise produce two prompt repaints in quick succession.
           ;; Skip the deferral on the alt screen TUIs.
           ((and (active-minibuffer-window)
                 (eql width ghostel--term-cols)
                 (not (ghostel--alt-screen-p ghostel--term)))
            (setq size nil))
           ;; Real resize — update the terminal model and redraw.
           (t
            (ghostel--set-size-with-cell-dims
             ghostel--term (max 1 height) (max 1 width))
            (setq ghostel--term-rows height)
            (setq ghostel--term-cols width)
            (setq ghostel--force-next-redraw t)
            ;; Redraw synchronously so the buffer is updated before
            ;; Emacs displays the stale content at the new window size.
            (ghostel--redraw-now buffer))))))
    ;; Return size — Emacs calls set-process-window-size (SIGWINCH)
    ;; after this function returns.  nil suppresses the call.
    size))

(defun ghostel--sync-tty-composition (window)
  "Sync `auto-composition-mode' with WINDOW's frame for ghostel buffers.
On a TTY frame, set the buffer-local value to the frame's `tty-type'
so composition is inhibited there (works around TTY column drift on
VS-16 emoji clusters, see debbugs#81052).
On a GUI frame, leave the value alone: it is either t (mode-init default;
composition stays on) or a string from a prior TTY display (string never
matches a GUI's nil `tty-type', so composition still stays on for the GUI
and the TTY display that needs it off keeps working in parallel)."
  (when (windowp window)
    (when-let* ((tt (tty-type (window-frame window))))
      (unless (equal auto-composition-mode tt)
        (setq-local auto-composition-mode tt)))))

(defun ghostel--window-buffer-change (window)
  "Anchor window and force redraw when buffer gets displayed in WINDOW."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (ghostel--anchor-window window)
    (ghostel--invalidate)))

(defun ghostel--anchor-on-resize (window)
  "Scroll WINDOW to the active area if it was already anchored.
If WINDOW was already anchored at the active area before resizing, WINDOW will
scroll to active area to keep it focused even during resize."
  (with-current-buffer (window-buffer window)
    (when (ghostel--window-anchored-p window
                                      (window-old-pixel-height window))
      (ghostel--anchor-window window))))

(defun ghostel--minibuffer-exit ()
  "Schedule anchoring of all the currently anchored Ghostel windows.
The minibuffer when used with packages such as Vertico can cause a resize of
a Ghostel window making it lose its anchoring."
  (when-let* ((anchored (cl-delete-if-not #'ghostel--window-anchored-p
                                          (window-list))))
    (run-at-time 0 nil
                 (lambda ()
                   (dolist (win anchored) (ghostel--anchor-window win))))))


;;; Major mode

(define-derived-mode ghostel-mode fundamental-mode "Ghostel"
  "Major mode for Ghostel terminal emulator."
  (hack-dir-local-variables)
  (when-let* ((cell (assq 'ghostel-environment dir-local-variables-alist))
              (value (cdr cell))
              ((ghostel--safe-environment-p value)))
    (setq-local ghostel-environment value))
  (buffer-disable-undo)
  (font-lock-mode -1)
  ;; `font-lock-mode' can still be re-enabled by user configuration that
  ;; forces `font-lock-defaults' globally (e.g. Doom Emacs).  When active,
  ;; JIT-lock calls `font-lock-unfontify-region' on every redraw, which
  ;; strips the per-cell `face' text-properties the native module writes.
  ;; Neutralise the unfontify pass so face props survive regardless of
  ;; whether font-lock ends up on.  `ghostel-mode' has no keywords, so
  ;; skipping unfontify has no other effect.
  (setq-local font-lock-unfontify-region-function #'ignore)
  (setq buffer-read-only nil)
  (setq-local scroll-margin 0)
  (setq-local auto-hscroll-mode nil)
  (setq-local hscroll-margin 0)
  (setq-local truncate-lines t)
  (setq-local scroll-conservatively 101)
  (setq-local line-spacing 0)
  (setq-local list-buffers-directory (expand-file-name default-directory)) ; expose cwd to buffer-menu/ibuffer
  ;; Set up the comint/shell completion plumbing once per buffer so
  ;; `ghostel-line-mode-complete-at-point' has the right
  ;; `comint-dynamic-complete-functions', `comint-file-name-chars',
  ;; etc. ready when the user enters line mode.  The plumbing is
  ;; cheap and harmless outside line mode (the capf is added to
  ;; `completion-at-point-functions' but no one calls it).
  (shell-completion-vars)
  (setq ghostel--input-mode 'semi-char)
  (use-local-map ghostel-semi-char-mode-map)
  (add-function :after after-focus-change-function #'ghostel--focus-change)
  (add-hook 'window-selection-change-functions #'ghostel--focus-change)
  (add-hook 'window-buffer-change-functions #'ghostel--focus-change)
  (add-hook 'window-buffer-change-functions #'ghostel--window-buffer-change nil t)
  (add-hook 'window-buffer-change-functions #'ghostel--sync-tty-composition nil t)
  (add-hook 'window-size-change-functions #'ghostel--anchor-on-resize nil t)
  (add-hook 'minibuffer-exit-hook #'ghostel--minibuffer-exit)
  (ghostel--suppress-interfering-modes)
  (ghostel-imenu-setup)
  (setq ghostel--scroll-intercept-active t)
  ;; Let C-g reach the keymap instead of triggering keyboard-quit.
  ;; When inhibit-quit is non-nil, C-g sets quit-flag and delivers
  ;; the character through normal input dispatch.
  (setq-local inhibit-quit t))

(defun ghostel--suppress-interfering-modes ()
  "Disable global minor modes that interfere with ghostel.
Suppresses `global-hl-line-mode' (and buffer-local `hl-line-mode') to
prevent redraw flicker."
  ;; global-hl-line-mode: opt this buffer out by setting the variable
  ;; buffer-locally to nil (as documented in the hl-line.el commentary).
  (when (bound-and-true-p global-hl-line-mode)
    (setq ghostel--saved-hl-line-mode t)
    (setq-local global-hl-line-mode nil)
    (when (fboundp 'global-hl-line-unhighlight)
      (global-hl-line-unhighlight)))
  ;; Buffer-local hl-line-mode
  (when (bound-and-true-p hl-line-mode)
    (setq ghostel--saved-hl-line-mode t)
    (hl-line-mode -1)))


;;; Entry point

(defun ghostel--init-buffer (buffer &optional rows cols)
  "Initialize BUFFER as a ghostel terminal.
This is the invariant boundary between an Emacs buffer and its native
terminal handle: BUFFER is made empty, renderer-coupled buffer-local
state is reset, and the newly created terminal is attached immediately
as BUFFER's buffer-local `ghostel--term'.  It intentionally does not
reset unrelated buffer-local state such as title/identity bookkeeping.

Optional ROWS and COLS override size detection.  Otherwise terminal
dimensions come from BUFFER's displayed window when one exists,
otherwise from the selected window.  Height uses `window-screen-lines',
the metric the standard `adjust-window-size-function' path also uses,
not `window-body-height'.  The former divides the window's pixel height
by the buffer's `default-line-height', which respects
`face-remapping-alist' and `:height' on the default face; the latter
divides by frame char height.  When a theme remaps default —
`nano-light' / `nano-dark' do this — the two metrics disagree, and
using `window-body-height' would size the terminal to N rows only to
have the standard adjust-fn immediately resize to N-K, sending a
startup SIGWINCH that some TUI apps (Claude Code's /tui fullscreen)
handle imperfectly (issue #192).

This function does not start a process; callers decide what program to
spawn after initialization."
  (unless (buffer-live-p buffer)
    (user-error "Cannot initialize dead buffer as ghostel terminal"))
  (unless (eq (null rows) (null cols))
    (user-error "ROWS and COLS must be provided together"))
  (with-current-buffer buffer
    (when (and ghostel--process (process-live-p ghostel--process))
      (user-error "Buffer %s already has a running ghostel process"
                  (buffer-name buffer)))
    (unless (derived-mode-p 'ghostel-mode)
      (ghostel-mode))
    (when ghostel--redraw-timer
      (cancel-timer ghostel--redraw-timer))
    (when ghostel--plain-link-detection-timer
      (cancel-timer ghostel--plain-link-detection-timer))
    (let ((inhibit-read-only t))
      (erase-buffer))
    (setq ghostel--term nil
          ghostel--term-rows nil
          ghostel--term-cols nil
          ghostel--process nil
          ghostel--redraw-timer nil
          ghostel--plain-link-detection-timer nil
          ghostel--plain-link-detection-begin nil
          ghostel--plain-link-detection-end nil
          ghostel--force-next-redraw nil
          ghostel--cursor-pos nil
          ghostel--cursor-char-pos nil
          ghostel--rendered-font nil)
    (let* ((w (or (get-buffer-window buffer t) (selected-window)))
           (height (max 1 (or rows
                              (if (window-live-p w)
                                  (with-selected-window w
                                    (floor (window-screen-lines)))
                                24))))
           (width  (max 1 (or cols
                              (if (window-live-p w)
                                  (window-max-chars-per-line w)
                                80)))))
      (setq ghostel--term
            (ghostel--new height width
                          ghostel-max-scrollback
                          ghostel-kitty-graphics-storage-limit
                          (ghostel--kitty-mediums-bits)))
      (setq ghostel--term-rows height)
      (setq ghostel--term-cols width)
      ;; Seed libghostty's cell dimensions before the process starts —
      ;; otherwise kitty graphics placements arriving in the very first
      ;; output (e.g. timg's transmit-and-place) compute grid_rows=0
      ;; and the terminal advances the cursor zero rows, leaving the
      ;; next prompt on top of the image.
      (ghostel--set-size-with-cell-dims ghostel--term height width)
      (ghostel--apply-palette ghostel--term)
      (ghostel--apply-bold-config ghostel--term))
    buffer))

(defun ghostel--create (name &optional display-action rows cols)
  "Create a fresh ghostel buffer NAME and initialize its terminal.
DISPLAY-ACTION, when non-nil, is passed to `pop-to-buffer' before
terminal creation so size detection observes the window that will
display the terminal.  Optional ROWS and COLS are passed through to
`ghostel--init-buffer'."
  (let ((buffer (generate-new-buffer name)))
    (condition-case err
        (progn
          ;; Put the buffer in `ghostel-mode' before display so
          ;; `display-buffer-alist' rules can match on `derived-mode-p'.
          (with-current-buffer buffer
            (ghostel-mode))
          (when display-action
            (pop-to-buffer buffer display-action))
          (ghostel--init-buffer buffer rows cols)
          buffer)
      (error
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (signal (car err) (cdr err))))))

(defun ghostel--find-buffer-by-identity (identity)
  "Return the live ghostel buffer whose identity equals IDENTITY, or nil.
Identity is the `ghostel-buffer-name' (or numbered variant) recorded at
buffer creation time — see `ghostel--buffer-identity'."
  (seq-find (lambda (b)
              (and (buffer-live-p b)
                   (equal (buffer-local-value 'ghostel--buffer-identity b)
                          identity)))
            (buffer-list)))

;;;###autoload
(defun ghostel (&optional arg)
  "Start a new Ghostel terminal.  If the buffer already exists, switch to it.
With a non-numeric prefix arg, create a new buffer.
With a numeric prefix ARG, switch to the buffer with that number or
create it if it doesn't exist yet.
The name of the buffer is determined by the value of `ghostel-buffer-name'.
Returns the buffer."
  (interactive "P")
  (ghostel--load-module t)
  (let* ((fresh (and arg (not (numberp arg))))
         (identity (cond (fresh nil)
                         ((numberp arg)
                          (format "%s<%d>" ghostel-buffer-name arg))
                         (t ghostel-buffer-name)))
         (display-action (append display-buffer--same-window-action
                                 '((category . comint))))
         (existing (and (not fresh)
                        (ghostel--find-buffer-by-identity identity)))
         (buffer (or existing
                     (ghostel--create (or identity ghostel-buffer-name)
                                      display-action))))
    (if existing
        (progn
          (unless (buffer-local-value 'ghostel--term existing)
            (user-error "Ghostel buffer %s has no terminal"
                        (buffer-name existing)))
          (pop-to-buffer existing display-action))
      (with-current-buffer buffer
        (setq ghostel--managed-buffer-name (buffer-name))
        (setq ghostel--buffer-identity (or identity (buffer-name)))
        (ghostel--start-process)))
    buffer))

(defun ghostel-exec (buffer program &optional args)
  "Run PROGRAM with ARGS as a ghostel terminal in BUFFER.

BUFFER is switched into `ghostel-mode' (if not already) and a new
terminal is created sized to the window displaying BUFFER, or
80x24 if BUFFER is not currently displayed.  No shell integration
is applied — PROGRAM is exec'd directly via `ghostel--spawn-pty'.
PROGRAM is shell-quoted before it is passed to `/bin/sh -c', so
shell metacharacters are not interpreted; pass extra tokens via
ARGS, a list of strings.  Returns the process.

Signals `user-error' if BUFFER already has a live ghostel process."
  (ghostel--load-module t)
  (when (and (buffer-local-value 'ghostel--process buffer)
             (process-live-p (buffer-local-value 'ghostel--process buffer)))
    (user-error "Buffer %s already has a running ghostel process"
                (buffer-name buffer)))
  (let* ((window (get-buffer-window buffer t))
         ;; Use `window-screen-lines' (not `window-body-height') so the
         ;; height matches the unit `window-adjust-process-window-size-smallest'
         ;; uses — see `ghostel--init-buffer' for why.
         (height (if window
                     (max 1 (with-selected-window window
                              (floor (window-screen-lines))))
                   24))
         (width (if window
                    (max 1 (window-max-chars-per-line window))
                  80)))
    (with-current-buffer buffer
      (ghostel--init-buffer buffer height width)
      (let ((remote-p (file-remote-p default-directory)))
        (ghostel--spawn-pty program args ghostel--term-rows ghostel--term-cols
                            ghostel--default-stty nil remote-p)))))

;;;###autoload
(defun ghostel-project (&optional arg)
  "Start a new Ghostel terminal in the current project's root.
The buffer name is prefixed with the project name.
If a buffer already exists for this project, switch to it.
Otherwise create a new Ghostel buffer.  ARG is passed through to
`ghostel' and accepts the same universal argument conventions.
To add this to `project-switch-commands':
  (add-to-list \\='project-switch-commands \\='(ghostel-project \"Ghostel\") t)
Returns the buffer."
  (interactive "P")
  (let ((default-directory (project-root (project-current t)))
        (ghostel-buffer-name (project-prefixed-buffer-name
                              (string-trim ghostel-buffer-name "*" "*"))))
    (ghostel arg)))

(defun ghostel-other ()
  "Switch to the next ghostel terminal buffer, or create one."
  (interactive)
  (let* ((bufs (cl-remove-if-not
                (lambda (b)
                  (with-current-buffer b
                    (derived-mode-p 'ghostel-mode)))
                (buffer-list)))
         (current (current-buffer))
         (others (cl-remove current bufs)))
    (if others
        (pop-to-buffer (car others) (append display-buffer--same-window-action
                                            '((category . comint))))
      (ghostel))))

(defun ghostel--all-buffers ()
  "Return all live `ghostel-mode' buffers, sorted alphabetically by name.
Sorted (not `buffer-list' order) so cycle commands advance through
the same sequence regardless of recent buffer-switch history."
  (sort (cl-remove-if-not
         (lambda (b) (with-current-buffer b (derived-mode-p 'ghostel-mode)))
         (buffer-list))
        (lambda (a b) (string< (buffer-name a) (buffer-name b)))))

(defun ghostel--project-buffers ()
  "Return ghostel buffers belonging to the current project, sorted by name.
Scoping is controlled by `ghostel-project-buffer-scope'.  Signals
`user-error' if there is no current project.

Buffers whose `default-directory' is remote are skipped in the
`default-directory' scope branch — querying `project-current'
against a TRAMP path would walk the remote filesystem
synchronously on every cycle."
  (let* ((proj (project-current t))
         (root (project-root proj))
         (identity-prefix
          (let ((ghostel-buffer-name
                 (project-prefixed-buffer-name
                  (string-trim ghostel-buffer-name "*" "*"))))
            ghostel-buffer-name))
         (scope ghostel-project-buffer-scope)
         (all (ghostel--all-buffers))
         (by-dir
          (and (memq scope '(default-directory both))
               (cl-remove-if-not
                (lambda (b)
                  (let ((bd (buffer-local-value 'default-directory b)))
                    (and bd
                         (not (file-remote-p bd))
                         (ignore-errors
                           (let ((bp (project-current nil bd)))
                             (and bp (equal (project-root bp) root)))))))
                all)))
         (by-id
          (and (memq scope '(identity both))
               (cl-remove-if-not
                (lambda (b)
                  (equal (buffer-local-value 'ghostel--buffer-identity b)
                         identity-prefix))
                all))))
    (sort (cl-delete-duplicates (append by-dir by-id) :test #'eq)
          (lambda (a b) (string< (buffer-name a) (buffer-name b))))))

(defun ghostel--cycle (bufs direction empty-msg single-msg)
  "Pop to the BUFS entry DIRECTION steps from current; wraps around.
DIRECTION is +1 or -1.  Signals `user-error' with EMPTY-MSG when
BUFS is empty.  Shows SINGLE-MSG when BUFS contains only the
current buffer.  If the current buffer is not in BUFS, jump to
the first or last entry depending on DIRECTION."
  (cond
   ((null bufs)
    (user-error "%s" empty-msg))
   ((and (= (length bufs) 1) (eq (car bufs) (current-buffer)))
    (message "%s" single-msg))
   (t
    (let* ((current (current-buffer))
           (idx (cl-position current bufs))
           (n (length bufs))
           (next (cond
                  ((null idx) (if (> direction 0) (car bufs) (car (last bufs))))
                  (t (nth (mod (+ idx direction) n) bufs)))))
      (pop-to-buffer next (append display-buffer--same-window-action
                                  '((category . comint))))))))

;;;###autoload
(defun ghostel-next ()
  "Switch to the next ghostel buffer (sorted by name, wraps around)."
  (interactive)
  (ghostel--cycle (ghostel--all-buffers) +1
                  "No ghostel buffers"
                  "Only one ghostel buffer"))

;;;###autoload
(defun ghostel-previous ()
  "Switch to the previous ghostel buffer (sorted by name, wraps around)."
  (interactive)
  (ghostel--cycle (ghostel--all-buffers) -1
                  "No ghostel buffers"
                  "Only one ghostel buffer"))

;;;###autoload
(defun ghostel-project-next ()
  "Switch to the next ghostel buffer in the current project (wraps around).
Project membership is determined by `ghostel-project-buffer-scope'."
  (interactive)
  (ghostel--cycle (ghostel--project-buffers) +1
                  "No ghostel buffers in this project"
                  "Only one ghostel buffer in this project"))

;;;###autoload
(defun ghostel-project-previous ()
  "Switch to the previous ghostel buffer in the current project (wraps around).
Project membership is determined by `ghostel-project-buffer-scope'."
  (interactive)
  (ghostel--cycle (ghostel--project-buffers) -1
                  "No ghostel buffers in this project"
                  "Only one ghostel buffer in this project"))

(defun ghostel--read-buffer (prompt bufs)
  "Prompt with PROMPT for one of BUFS via `read-buffer'.
Default candidate is the buffer `ghostel-next' would land on, so RET
matches the forward-cycle direction.  Returns the chosen buffer or
signals `user-error' if BUFS is empty."
  (when (null bufs)
    (user-error "No ghostel buffers"))
  (let* ((names (mapcar #'buffer-name bufs))
         (current (current-buffer))
         (idx (cl-position current bufs))
         (default (cond
                   ((null idx) (car names))
                   (t (nth (mod (1+ idx) (length bufs)) names))))
         (chosen (read-buffer prompt default t
                              (lambda (cand)
                                (let ((name (if (consp cand) (car cand) cand)))
                                  (member name names))))))
    (get-buffer chosen)))

;;;###autoload
(defun ghostel-list-buffers ()
  "Pick a ghostel buffer to switch to via `read-buffer'."
  (interactive)
  (pop-to-buffer (ghostel--read-buffer "Ghostel buffer: " (ghostel--all-buffers))
                 (append display-buffer--same-window-action
                         '((category . comint)))))

;;;###autoload
(defun ghostel-project-list-buffers ()
  "Pick a ghostel buffer in the current project via `read-buffer'.
Project membership is determined by `ghostel-project-buffer-scope'."
  (interactive)
  (pop-to-buffer (ghostel--read-buffer "Project ghostel buffer: "
                                       (ghostel--project-buffers))
                 (append display-buffer--same-window-action
                         '((category . comint)))))

(provide 'ghostel)

;;; ghostel.el ends here
