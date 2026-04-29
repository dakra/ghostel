;;; ghostel.el --- Terminal emulator powered by libghostty -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.20.0
;; Keywords: terminals
;; Package-Requires: ((emacs "28.1"))
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
;;   M-x ghostel          Open a new terminal
;;   M-x ghostel-project  Open a terminal in the current project root
;;   M-x ghostel-other    Switch to next terminal or create one
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
(require 'project)
(require 'text-property-search)
(require 'tramp)
(require 'url-parse)
(require 'face-remap)


;;; Customization

(defgroup ghostel nil
  "Terminal emulator powered by libghostty."
  :group 'terminals
  :prefix "ghostel-")

(defcustom ghostel-shell (or (getenv "SHELL") "/bin/sh")
  "Shell program to run in the terminal."
  :type 'string)

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
- TERM is always reset by TRAMP to `tramp-terminal-type' (see
  `tramp-handle-make-process'); overrides in `ghostel-environment'
  do not win remotely.
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

(defcustom ghostel-set-title-function #'ghostel--set-title-default
  "Function called when the terminal reports a new title (OSC 2).
Called with one argument, the title string, in the ghostel buffer.
Set to nil to disable title tracking entirely.
The default, `ghostel--set-title-default', renames the buffer to
\"*ghostel: TITLE*\" unless the user has renamed it manually."
  :type '(choice (const :tag "Disabled" nil) function))

(defcustom ghostel-kill-buffer-on-exit t
  "Kill the buffer when the shell process exits."
  :type 'boolean)

(defcustom ghostel-exit-functions nil
  "Hook run when the terminal process exits.
Each function is called with two arguments: the buffer and the
exit event string."
  :type 'hook)

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
  :type 'hook)

(defcustom ghostel-command-start-functions nil
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

(defcustom ghostel-eval-cmds '(("find-file" find-file)
                               ("find-file-other-window" find-file-other-window)
                               ("dired" dired)
                               ("dired-other-window" dired-other-window)
                               ("message" message))
  "Whitelisted Emacs functions callable from the terminal via OSC 51.
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

(defcustom ghostel-notification-function #'ghostel-default-notify
  "Function called for OSC 9 / OSC 777 desktop notifications.
Called with two string arguments: TITLE and BODY.  Title is empty
for iTerm2-style OSC 9 notifications, which only carry a body.
Set to nil to ignore notifications.

The handler is invoked asynchronously via `run-at-time', with the
originating ghostel buffer as `current-buffer', so it may block or
spawn processes freely without stalling the terminal."
  :type '(choice (const :tag "Disabled" nil) function))

(defcustom ghostel-progress-function #'ghostel-default-progress
  "Function called for ConEmu OSC 9;4 progress reports.
Called with two arguments: STATE (one of the symbols `remove',
`set', `error', `indeterminate', `pause') and PROGRESS (an integer
0-100, or nil when not reported).  Set to nil to ignore progress
reports.

The handler runs synchronously on the VT-parser callpath because
progress updates are expected to feed the mode line or similar
cheap UI.  A slow handler here will stall terminal output — defer
expensive work via `run-at-time' on your own if you need it."
  :type '(choice (const :tag "Disabled" nil) function))

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

(defcustom ghostel-module-auto-install 'ask
  "What to do when the native module is missing at load time.
\\=`ask'      — prompt with a choice to download, compile, or skip (default).
\\=`download' — download a pre-built binary from GitHub releases.
\\=`compile'  — build from source via `ghostel-module-compile'.
nil         — do nothing; the user must install the module manually."
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
  '("C-c" "C-x" "C-u" "C-h" "M-x" "M-o" "M-:" "C-\\")
  "Key sequences that should not be sent to the terminal.
These keys pass through to Emacs instead."
  :type '(repeat string))

(defcustom ghostel-ignore-cursor-change nil
  "When non-nil, ignore terminal requests to change cursor shape or visibility.
Useful when editor-owned cursor behavior should take precedence over
terminal-driven cursor changes.  Copy mode restores `cursor-type' to its
default value."
  :type 'boolean)

(defcustom ghostel-scroll-on-input t
  "Automatically scroll to the bottom when typing in the terminal.
When non-nil, any character typed while the viewport is scrolled
into the scrollback will first jump to the bottom of the terminal
before sending the input."
  :type 'boolean)


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

(defcustom ghostel-github-release-url
  "https://github.com/dakra/ghostel/releases"
  "Base URL for Ghostel GitHub releases.
Customize this when downloading pre-built modules from a fork or mirror."
  :type 'string)

(defconst ghostel--minimum-module-version "0.20.0"
  "Minimum native module version required by this Elisp version.
Bump this only when the Elisp code requires a newer native module
\(e.g. new Zig-exported function or changed calling convention).")


;; Declare native module functions for the byte compiler

(declare-function ghostel--cursor-position "ghostel-module")
(declare-function ghostel--encode-key "ghostel-module")
(declare-function ghostel--focus-event "ghostel-module")
(declare-function ghostel--mode-enabled "ghostel-module")
(declare-function ghostel--alt-screen-p "ghostel-module")
(declare-function ghostel--copy-all-text "ghostel-module")
(declare-function ghostel--module-version "ghostel-module")
(declare-function ghostel--mouse-event "ghostel-module")
(declare-function ghostel--new "ghostel-module")
(declare-function ghostel--redraw "ghostel-module" (term &optional full))
(declare-function ghostel--set-default-colors "ghostel-module")
(declare-function ghostel--set-palette "ghostel-module")
(declare-function ghostel--set-size "ghostel-module" (term rows cols &optional cell-w cell-h))
(declare-function ghostel--write-input "ghostel-module")
(declare-function ghostel--native-uri-at "ghostel-module")


;;; Automatic download and compilation of native module

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

(defun ghostel--download-module (dir &optional version latest-release)
  "Download a pre-built module into DIR.
When VERSION is non-nil, download that release tag.
When LATEST-RELEASE is non-nil, use the latest release asset URL.
Returns non-nil on success."
  (condition-case err
      (let* ((requested-version (unless latest-release
                                  (or version ghostel--minimum-module-version)))
             (url (ghostel--module-download-url requested-version)))
        (when url
          (unless (string-prefix-p "https://" url)
            (error "Refusing non-HTTPS download URL: %s" url))
          (let ((dest (expand-file-name
                       (concat "ghostel-module" module-file-suffix) dir)))
            (message "ghostel: downloading native module from %s..." url)
            (when (ghostel--download-file url dest)
              (message "ghostel: native module downloaded successfully")
              t))))
    (error
     (message "ghostel: download failed: %s" (error-message-string err))
     nil)))

(defun ghostel--compile-module (dir)
  "Compile the native module from source in DIR.
Runs synchronously and returns non-nil on success."
  (let ((default-directory dir))
    (message "ghostel: compiling native module with zig build (this may take a moment)...")
    (condition-case err
        (let ((ret (process-file "zig" nil "*ghostel-build*" nil
                                 "build" "-Doptimize=ReleaseFast" "-Dcpu=baseline")))
          (if (eq ret 0)
              (progn (message "ghostel: native module compiled successfully") t)
            (display-warning 'ghostel
                             "Module compilation failed.  See *ghostel-build* buffer for details.")
            nil))
      (file-missing
       (display-warning 'ghostel
                        (format "zig executable not found while compiling in %s" dir))
       nil)
      (error
       (display-warning 'ghostel (error-message-string err))
       nil))))

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
  "Download URL to DEST.  Return non-nil on success."
  (condition-case nil
      (let ((url-request-method "GET")
            (url-show-status nil))
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
                          (write-region start (point-max) dest nil 'silent)
                          (set-file-modes dest #o755)
                          t)))))
              (when (buffer-live-p buf)
                (kill-buffer buf))))))
    (error nil)))

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

(defun ghostel-download-module (&optional prompt-for-version)
  "Interactively download the pre-built native module for this platform.
With PROMPT-FOR-VERSION, prompt for a release tag to download.
Leaving the prompt empty downloads the latest release."
  (interactive "P")
  (let* ((dir (ghostel--resource-root))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir))
         (version (when prompt-for-version
                    (ghostel--read-module-download-version)))
         (latest-release (and prompt-for-version (null version))))
    (when (and (file-exists-p mod)
               (not (yes-or-no-p "Module already exists.  Re-download? ")))
      (user-error "Cancelled"))
    (if (ghostel--download-module dir version latest-release)
        (progn
          (module-load mod)
          (message "ghostel: module loaded successfully"))
      (user-error "Download failed.  Try M-x ghostel-module-compile to build from source"))))

(defun ghostel-module-compile ()
  "Compile the ghostel native module by running zig build.
The output is shown in a *ghostel-build* compilation buffer."
  (interactive)
  (let ((default-directory (ghostel--resource-root)))
    (compile "zig build -Doptimize=ReleaseFast -Dcpu=baseline" t)))


(defun ghostel--check-module-version (dir)
  "Check if the loaded module is older than required.
When the module version is below `ghostel--minimum-module-version',
offer to update using `ghostel-module-auto-install'.
DIR is the module directory."
  (let ((mod-ver (and (fboundp 'ghostel--module-version)
                      (ghostel--module-version))))
    (when (or (null mod-ver)
              (version< mod-ver ghostel--minimum-module-version))
      (display-warning 'ghostel
                       (format "Module version %s is older than required %s"
                               (or mod-ver "unknown")
                               ghostel--minimum-module-version))
      (unless noninteractive
        (ghostel--ensure-module dir)))))

(defun ghostel--load-module (&optional prompt-user)
  "Ensure the ghostel native module is loaded.
When the module file is missing, trigger `ghostel-module-auto-install'.
When PROMPT-USER is non-nil (called from an interactive command like
`ghostel'), failures signal `user-error' so the calling flow aborts.
Otherwise (load time), failures `display-warning' instead so the user
can still compile ghostel, read docs, and so on.

The guard also honours `ghostel--new' being already `fboundp', which
covers the pure-Elisp test path where `cl-letf' stubs the native
entry points so tests run without the module present."
  (unless (or (featurep 'ghostel-module)
              (fboundp 'ghostel--new))
    (let* ((dir (ghostel--resource-root))
           (mod (expand-file-name
                 (concat "ghostel-module" module-file-suffix) dir)))
      (unless (or (file-exists-p mod) noninteractive)
        (ghostel--ensure-module dir))
      (cond
       ((file-exists-p mod)
        (condition-case err
            (progn
              (module-load mod)
              (ghostel--check-module-version dir))
          (error
           (if prompt-user
               (user-error "Failed to load ghostel native module: %s"
                           (error-message-string err))
             (display-warning
              'ghostel
              (format "Failed to load native module: %s\nTry M-x ghostel-module-compile to rebuild"
                      (error-message-string err)))))))
       (prompt-user
        (user-error "Ghostel native module not found: %s.  Run M-x ghostel-download-module or M-x ghostel-module-compile"
                    mod))
       (t
        (display-warning
         'ghostel
         (concat "Native module not found: " mod
                 "\nRun M-x ghostel-download-module or M-x ghostel-module-compile")))))))

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

(defvar-local ghostel--deferred-crop-size nil
  "Pending (HEIGHT . WIDTH) from a deferred minibuffer-shrink crop.
Set by the CROP branch of `ghostel--window-adjust-process-window-size'
when the minibuffer shrinks the ghostel window — we suppress SIGWINCH
for transient minibuffer flashes with a quiet terminal but record the
size so it can be committed if anything would render at the wrong
geometry.  Committed by `ghostel--commit-deferred-crop' when output
arrives, and cleared without committing when the window grows back to
or beyond `ghostel--term-rows' before output arrives.

Without this, `ghostel--term-rows' stays at the original (pre-crop)
size for the duration of the minibuffer.  When the minibuffer closes
and the window grows back, `ghostel--window-adjust-process-window-size'
sees `eql height ghostel--term-rows' and hits the \"no change\" branch,
skipping the resize-aware redraw — `ghostel--window-anchored-p' then
runs without `ghostel--redraw-resize-active', `keep-point-visible'
drift can be misclassified as user scrollback, and the auto-follow
predicate latches off (issue #191).")

(defvar-local ghostel--copy-mode-active nil
  "Non-nil when copy mode is active.")

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

(defvar ghostel--redraw-resize-active nil
  "Dynamically bound to t inside a resize-triggered `ghostel--delayed-redraw'.
Read by `ghostel--window-anchored-p' so the redraw keeps auto-following
windows anchored even when Emacs redisplay drifted `window-start' below
the anchor between redraws (e.g. via `keep-point-visible' when the
minibuffer shrinks the window).  Not set for output-driven redraws,
clear-scrollback, copy-exit, or snap-to-input — those either reset
`ghostel--scroll-positions' or set `ghostel--snap-requested', both of
which already produce the intended anchoring.")

(defvar-local ghostel--snap-requested nil
  "When non-nil, the next redraw should anchor `window-start' to the viewport.
Set by `ghostel--snap-to-input' on user-initiated input (typing, paste,
yank, drop) and cleared by `ghostel--delayed-redraw' after the anchor
runs.  When nil, a redraw preserves the existing `window-start' if the
user has scrolled into the scrollback, so live output and Emacs commands
do not yank the view back to the prompt.")

(defvar-local ghostel--windows-needing-snap nil
  "List of windows that must anchor to the viewport on the next redraw.
Populated by `ghostel--reshow-snap' when a window starts displaying
this buffer, and cleared by `ghostel--delayed-redraw' after the anchor
runs.  Per-window (rather than buffer-local like `ghostel--snap-requested')
so opening a second window on a ghostel buffer does not yank peers the
user has scrolled back for reading history (issue #177).")

(defvar-local ghostel--last-anchor-position nil
  "Buffer position where the anchor last set `window-start'.
Used by `ghostel--delayed-redraw' to tell windows that are following
the viewport (window-start at or past this anchor) from windows the
user has scrolled into the scrollback (window-start below this anchor).
Robust across redraws that shift viewport-start without the user
scrolling — e.g. live output that grows the buffer, or a window resize
that changes `ghostel--term-rows'.")

(defvar-local ghostel--scroll-positions nil
  "Alist of (WINDOW . (WS-KEY WP-KEY WP-COL)) for scrolled windows.
Each entry is a window viewing this buffer that is currently in the
scrollback (not following the viewport).  WS-KEY and WP-KEY are
multi-line content keys (see `ghostel--line-key') at `window-start'
and `window-point' respectively; WP-COL is the column of
`window-point' within its line.  Content-based (rather than byte
positions or line numbers) so lookups survive the native redraw's
buffer reshuffles (eraseBuffer + re-insert, scrollback eviction,
viewport rewrite) while libghostty's logical content is preserved.

The alist is rebuilt each redraw.  The pre-redraw pass in
`ghostel--delayed-redraw' uses a heuristic to distinguish Emacs
clamping `window-start' to `point-min' (restore from saved key) from a
legitimate user scroll to a different valid position (refresh saved
key to match).  The heuristic misfires if Emacs moves `window-start'
to a non-`point-min' non-saved position (e.g. programmatic
`recenter', `follow-mode', window split layouts); in that case the
saved key is refreshed to the new content and the original scroll
intent is lost.  That's an accepted tradeoff for avoiding a
`post-command-hook' that would fire on every keystroke.")

(defvar-local ghostel--has-wide-chars nil
  "Set by the native renderer when wide characters are present.
Cleared before each redraw; checked afterwards to decide whether
pixel-based trailing-space compensation is needed.")

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
Set at buffer creation to the value of `ghostel-buffer-name' (or its
numbered variant) before any title-tracking renames.  Used so that
`ghostel' and `ghostel-project' can reuse an existing buffer even after
`ghostel--set-title-default' has renamed it.")

(defvar-local ghostel--prompt-positions nil
  "List of prompt positions as (buffer-line . exit-status) pairs.
Used for prompt navigation and optional re-application after full redraws.")

(defvar-local ghostel--scroll-intercept-active nil
  "Non-nil when ghostel's scroll-event intercept is active.
Used as the activation key in `emulation-mode-map-alists'.")



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

(defvar ghostel--scroll-intercept-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-4]    #'ghostel--scroll-intercept-up)
    (define-key map [mouse-5]    #'ghostel--scroll-intercept-down)
    (define-key map [wheel-up]   #'ghostel--scroll-intercept-up)
    (define-key map [wheel-down] #'ghostel--scroll-intercept-down)
    map)
  "Keymap for `emulation-mode-map-alists' to intercept scroll events.
Active only in ghostel buffers where `ghostel--scroll-intercept-active'
is non-nil.")

(defvar ghostel--emulation-alist
  `((ghostel--scroll-intercept-active . ,ghostel--scroll-intercept-map))
  "Alist for `emulation-mode-map-alists'.")

(unless (memq 'ghostel--emulation-alist emulation-mode-map-alists)
  (push 'ghostel--emulation-alist emulation-mode-map-alists))



;;; Keymap

(defvar ghostel-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Self-insert characters
    (define-key map [remap self-insert-command] #'ghostel--self-insert)
    ;; Special keys — routed through the ghostty key encoder which
    ;; respects terminal modes and handles all modifier combinations.
    ;; Use angle-bracket forms so modifier prefixes compose correctly.
    (dolist (key '("<return>" "<tab>" "<backspace>" "<escape>"
                   "<up>" "<down>" "<right>" "<left>"
                   "<home>" "<end>" "<prior>" "<next>"
                   "<deletechar>" "<insert>"
                   "<f1>" "<f2>" "<f3>" "<f4>" "<f5>" "<f6>"
                   "<f7>" "<f8>" "<f9>" "<f10>" "<f11>" "<f12>"))
      (define-key map (kbd key) #'ghostel--send-event)
      (dolist (mod '("S-" "C-" "M-" "C-S-" "M-S-" "C-M-"))
        (ignore-errors
          (define-key map (kbd (concat mod key)) #'ghostel--send-event))))
    ;; Bare aliases for unmodified keys (RET=\r, TAB=\t, DEL=\x7f)
    (define-key map (kbd "RET") #'ghostel--send-event)
    (define-key map (kbd "TAB") #'ghostel--send-event)
    (define-key map (kbd "DEL") #'ghostel--send-event)
    ;; Emacs reports S-TAB as <backtab>
    (define-key map (kbd "<backtab>") #'ghostel--send-event)
    ;; Control keys — bind all C-<letter> to send ASCII control codes,
    ;; except keys in ghostel-keymap-exceptions and special cases.
    ;; C-i = TAB and C-m = RET are equivalent to <tab>/<return> (bound above).
    (let ((skip '(?i ?m ?y)))  ; i=TAB, m=RET already bound; y=ghostel-yank below
      (dolist (c (number-sequence ?a ?z))
        (let ((key-str (format "C-%c" c)))
          (unless (or (member key-str ghostel-keymap-exceptions)
                      (memq c skip))
            (define-key map (kbd key-str)
                        (let ((code (- c 96)))
                          (lambda () (interactive)
                            (ghostel--send-string (string code)))))))))
    ;; Meta keys — bind all M-<letter> so they reach the terminal
    ;; instead of running Emacs commands like forward-word.
    (dolist (c (number-sequence ?a ?z))
      (let ((key-str (format "M-%c" c)))
        (unless (member key-str ghostel-keymap-exceptions)
          (define-key map (kbd key-str) #'ghostel--send-event))))
    ;; M-DEL: TTY Emacs delivers Alt-Backspace as ESC + 0x7f, which
    ;; resolves to ?\M-\d.  The `M-<backspace>' form above only covers
    ;; the `[M-backspace]' symbol path; without this binding, TTY
    ;; Alt-Backspace falls through to global `backward-kill-word'.
    (define-key map (kbd "M-DEL") #'ghostel--send-event)
    ;; C-@ (NUL, same as C-SPC) — used by programs like Emacs-in-terminal
    (define-key map (kbd "C-@")
                (lambda () (interactive) (ghostel--send-string "\x00")))
    ;; C-y: yank from Emacs kill ring into the terminal
    (define-key map (kbd "C-y")       #'ghostel-yank)
    (when (eq system-type 'darwin)
      (define-key map (kbd "s-v")     #'ghostel-yank))
    ;; Clipboard media keys
    (define-key map (kbd "<XF86Paste>") #'ghostel-yank)
    (define-key map (kbd "<XF86Copy>")  #'kill-ring-save)
    (define-key map (kbd "M-y")       #'ghostel-yank-pop)
    ;; Bracketed paste from the host terminal (TTY Emacs): forward the
    ;; paste payload to the subprocess instead of letting the default
    ;; `xterm-paste' insert it into the (renderer-owned) buffer.
    (define-key map [xterm-paste]     #'ghostel-xterm-paste)
    ;; Terminal control via C-c prefix (pass through to Emacs, then handled here)
    (define-key map (kbd "C-c C-c")   #'ghostel-send-C-c)
    (define-key map (kbd "C-c C-z")   #'ghostel-send-C-z)
    (define-key map (kbd "C-c C-\\")  #'ghostel-send-C-backslash)
    (define-key map (kbd "C-c C-d")   #'ghostel-send-C-d)
    (define-key map (kbd "C-g")       #'ghostel-send-C-g)
    (define-key map (kbd "C-c C-t")   #'ghostel-copy-mode)
    (define-key map (kbd "C-c M-w")   #'ghostel-copy-all)
    (define-key map (kbd "C-c C-y")   #'ghostel-paste)
    (define-key map (kbd "C-c C-l")   #'ghostel-clear-scrollback)
    (define-key map (kbd "C-c C-q")   #'ghostel-send-next-key)
    ;; Hyperlink navigation (OSC 8, auto-detected URLs, file:line refs)
    (define-key map (kbd "C-c C-n")   #'ghostel-next-hyperlink)
    (define-key map (kbd "C-c C-p")   #'ghostel-previous-hyperlink)
    ;; Prompt navigation (OSC 133)
    (define-key map (kbd "C-c M-n")   #'ghostel-next-prompt)
    (define-key map (kbd "C-c M-p")   #'ghostel-previous-prompt)
    ;; Mouse click events (for terminal mouse tracking)
    (define-key map (kbd "<down-mouse-1>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-1>")       #'ghostel--mouse-release)
    (define-key map (kbd "<down-mouse-2>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-2>")       #'ghostel--mouse-release)
    (define-key map (kbd "<down-mouse-3>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-3>")       #'ghostel--mouse-release)
    (define-key map (kbd "<drag-mouse-1>")  #'ghostel--mouse-drag)
    (define-key map (kbd "<drag-mouse-2>")  #'ghostel--mouse-drag)
    (define-key map (kbd "<drag-mouse-3>")  #'ghostel--mouse-drag)
    ;; Drag and drop
    (define-key map [drag-n-drop]           #'ghostel--drop)
    map)
  "Keymap for `ghostel-mode'.")


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
     ;; Meta + single letter → ESC + char
     ((and (= (length key-name) 1)
           (<= ?a (aref key-name 0)) (<= (aref key-name 0) ?z)
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
Resets the terminal engine's viewport out of scrollback and sets
`ghostel--snap-requested' so the delayed redraw anchors
`window-start' to the viewport (and clears any pixel vscroll left
by `pixel-scroll-precision-mode' or similar scrollers).  No-op
when `ghostel-scroll-on-input' is nil.  Call from any path where
the user's action implies \"show me the prompt\" — typed input,
paste, yank, drop."
  (when (and ghostel-scroll-on-input ghostel--term)
    (setq ghostel--snap-requested t)
    (setq ghostel--force-next-redraw t)))

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
  (when ghostel--copy-mode-active
    (ghostel-copy-mode-exit))
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
    ;; Flush pending process output first so it doesn't recreate
    ;; scrollback after the clear.
    (ghostel--flush-pending-output)
    ;; CSI H = home, CSI 2 J = erase screen, CSI 3 J = erase scrollback.
    (ghostel--write-input ghostel--term "\e[H\e[2J\e[3J")
    (setq ghostel--force-next-redraw t)
    ;; Scrollback is gone; any recorded scroll position no longer
    ;; refers to real content.  Reset so the next redraw anchors
    ;; fresh to the new (empty) viewport.  No need to set
    ;; `ghostel--snap-requested' here: nilling
    ;; `--last-anchor-position' makes `ghostel--window-anchored-p'
    ;; treat every window as anchored on the next redraw via its
    ;; bootstrap branch.  (`ghostel-copy-mode-exit' uses the snap
    ;; flag instead because it preserves `--last-anchor-position'.)
    (setq ghostel--scroll-positions nil)
    (setq ghostel--last-anchor-position nil)
    (ghostel--invalidate)
    ;; Send form-feed to the shell so it redraws its prompt.
    (when (and ghostel--process (process-live-p ghostel--process))
      (process-send-string ghostel--process "\f"))))

(defun ghostel-clear ()
  "Clear the visible screen, preserving scrollback history."
  (interactive)
  (when ghostel--term
    ;; Flush pending process output first so it renders before the clear.
    (ghostel--flush-pending-output)
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
             (not ghostel--copy-mode-active))
    (let* ((posn (event-start event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            0  ; press
                            button
                            row col
                            (ghostel--mouse-mods event)))))

(defun ghostel-copy-mode-end-of-buffer ()
  "Move to the bottom of the buffer (current viewport) in copy mode."
  (interactive)
  (goto-char (point-max))
  (skip-chars-backward " \t\n"))

(defun ghostel-copy-mode-end-of-line ()
  "Move to the last non-whitespace character on the line."
  (interactive)
  (end-of-line)
  (skip-chars-backward " \t"))

(defun ghostel-copy-mode-recenter ()
  "Recenter the current line in the window."
  (interactive)
  (recenter))


;;; Mouse input

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
                            (ghostel--mouse-mods event)))))

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
  "Handle mouse drag EVENT as motion for terminal mouse tracking."
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-end event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            2  ; motion
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))


;;; Copy mode

(defvar ghostel-copy-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Normal letter keys exit copy mode and send the key to the terminal
    (define-key map [remap self-insert-command] #'ghostel-copy-mode-exit-and-send)
    (define-key map (kbd "C-c C-t") #'ghostel-copy-mode-exit)
    (define-key map (kbd "C-g") #'ghostel-copy-mode-exit)
    (define-key map (kbd "M-w") #'ghostel-copy-mode-copy)
    (define-key map (kbd "C-w") #'ghostel-copy-mode-copy)
    ;; Hyperlink navigation works in copy mode too
    (define-key map (kbd "C-c C-n") #'ghostel-next-hyperlink)
    (define-key map (kbd "C-c C-p") #'ghostel-previous-hyperlink)
    ;; Prompt navigation works in copy mode too
    (define-key map (kbd "C-c M-n") #'ghostel-next-prompt)
    (define-key map (kbd "C-c M-p") #'ghostel-previous-prompt)
    (define-key map (kbd "M->")     #'ghostel-copy-mode-end-of-buffer)
    (define-key map (kbd "C-e")     #'ghostel-copy-mode-end-of-line)
    (define-key map (kbd "C-l")     #'ghostel-copy-mode-recenter)
    (define-key map (kbd "C-c C-l") #'ghostel-copy-mode-exit-and-clear)
    (define-key map [xterm-paste]   #'ghostel-xterm-paste)
    map)
  "Keymap for `ghostel-copy-mode'.
Standard Emacs navigation works.
Set mark, navigate to select, then \\[ghostel-copy-mode-copy] to copy.")

(defvar-local ghostel--saved-local-map nil
  "Saved keymap before entering copy mode.")

(defvar-local ghostel--saved-cursor-type nil
  "Saved `cursor-type' before entering copy mode.")

(defvar-local ghostel--saved-hl-line-mode nil
  "Non-nil if line highlighting was active when `ghostel-mode' suppressed it.
Covers both `global-hl-line-mode' and buffer-local `hl-line-mode'.")

(defun ghostel-copy-mode ()
  "Enter copy mode for selecting and copying terminal text.
Live terminal output is paused; standard Emacs navigation, search,
and marking work across the full scrollback that is already rendered
in the buffer."
  (interactive)
  (if ghostel--copy-mode-active
      (ghostel-copy-mode-exit)
    (setq ghostel--copy-mode-active t)
    (when ghostel--redraw-timer
      (cancel-timer ghostel--redraw-timer)
      (setq ghostel--redraw-timer nil))
    ;; Ensure cursor is visible for navigation
    (setq ghostel--saved-cursor-type cursor-type)
    (setq cursor-type (default-value 'cursor-type))
    (setq ghostel--saved-local-map (current-local-map))
    (use-local-map ghostel-copy-mode-map)
    (when ghostel--saved-hl-line-mode
      (hl-line-mode 1))
    (setq buffer-read-only t)
    (setq mode-line-process ":Copy")
    (force-mode-line-update)
    (message "Copy mode: Press any key to exit")))

(defun ghostel-copy-mode-exit ()
  "Exit copy mode and return to terminal mode."
  (interactive)
  (setq quit-flag nil)
  (when ghostel--copy-mode-active
    (setq ghostel--copy-mode-active nil)
    (setq cursor-type ghostel--saved-cursor-type)
    (deactivate-mark)
    (use-local-map ghostel--saved-local-map)
    (when ghostel--saved-hl-line-mode
      (hl-line-mode -1))
    (setq buffer-read-only nil)
    (setq mode-line-process nil)
    (force-mode-line-update)
    ;; Jump out of any scrollback position so the redraw is allowed to
    ;; position point at the terminal cursor (otherwise
    ;; `ghostel--delayed-redraw' would preserve our scrollback marker).
    (goto-char (point-max))
    ;; Drop stale scroll-state that was frozen while delayed-redraw was
    ;; short-circuited during copy mode, and let the next redraw snap
    ;; fresh to the viewport.  `force-next-redraw' is required so the
    ;; snap fires even when DEC 2026 synchronized output is active.
    (setq ghostel--scroll-positions nil)
    (setq ghostel--snap-requested t)
    (setq ghostel--force-next-redraw t)
    (ghostel--invalidate)
    (message "Copy mode exited")))

(defun ghostel-copy-mode-exit-and-clear ()
  "Exit copy mode and clear the scrollback."
  (interactive)
  (ghostel-copy-mode-exit)
  (ghostel-clear-scrollback))

(defun ghostel-copy-mode-exit-and-send ()
  "Exit copy mode and send the key that triggered exit to the terminal."
  (interactive)
  (ghostel-copy-mode-exit)
  (when ghostel--term
    (ghostel--self-insert)))

(defun ghostel--filter-soft-wraps (text)
  "Remove newlines from TEXT that were inserted by soft line wrapping.
These are newlines with the `ghostel-wrap' text property."
  (let ((result "")
        (pos 0)
        (len (length text)))
    (while (< pos len)
      (if (and (eq (aref text pos) ?\n)
               (get-text-property pos 'ghostel-wrap text))
          (setq pos (1+ pos))
        (setq result (concat result (substring text pos (1+ pos)))
              pos (1+ pos))))
    result))

(defun ghostel--clean-copy-text (text)
  "Clean TEXT for copying: remove soft-wrap newlines, strip trailing whitespace."
  (let* ((unwrapped (ghostel--filter-soft-wraps text))
         (lines (split-string unwrapped "\n"))
         (trimmed (mapcar (lambda (line) (string-trim-right line)) lines)))
    (mapconcat #'identity trimmed "\n")))

(defun ghostel-copy-mode-copy ()
  "Copy the selected region and exit copy mode.
Soft-wrapped newlines are removed and trailing whitespace is
stripped so the copied text matches the original terminal content."
  (interactive)
  (when (use-region-p)
    (let ((text (ghostel--clean-copy-text
                 (buffer-substring (region-beginning) (region-end)))))
      (kill-new text)
      (message "Copied to kill ring")))
  (ghostel-copy-mode-exit))

(defun ghostel-copy-all ()
  "Copy the entire scrollback buffer to the kill ring."
  (interactive)
  (when ghostel--term
    (let ((text (ghostel--copy-all-text ghostel--term)))
      (when (and text (> (length text) 0))
        (kill-new text)
        (message "Copied %d characters to kill ring" (length text))))))


;;; Hyperlinks (OSC 8)

(defvar ghostel-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'ghostel-open-link-at-click)
    (define-key map [mouse-2] #'ghostel-open-link-at-click)
    (define-key map (kbd "RET") #'ghostel-open-link-at-point)
    map)
  "Keymap for clickable hyperlinks in ghostel buffers.")

(defun ghostel--native-link-help-echo (window _ pos)
  "Return the native OSC8 URI for the link at POS in WINDOW.
Used as the `help-echo' handler for OSC8 hyperlinks; retrieves the
URI from libghostty."
  (with-current-buffer (window-buffer window)
    (ghostel--native-uri-at-pos pos)))

(defun ghostel--native-uri-at-pos (pos)
  "Return the native OSC8 hyperlink URI at POS."
  (save-excursion
    (goto-char pos)
    (let* ((line (line-number-at-pos nil t))
           (total (line-number-at-pos (point-max) t))
           (row-from-bottom (- total line))
           (col (current-column)))
      (ghostel--native-uri-at ghostel--term row-from-bottom col))))

(defun ghostel--uri-at-pos (pos)
  "Return the URI at POS.
If the `help-echo' property is a string, return it; otherwise fetch
the native OSC8 URI at that position."
  (let ((help-echo (get-text-property pos 'help-echo)))
    (if (stringp help-echo)
        help-echo
      (ghostel--native-uri-at-pos pos))))

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

(defun ghostel--find-next-link (from)
  "Return start position of the first hyperlink after FROM, or nil.
A hyperlink is any region with a non-nil `help-echo' property —
covers OSC 8 links, auto-detected URLs, and `fileref:' references."
  (save-excursion
    (goto-char from)
    (when-let* ((match (text-property-search-forward
                        'help-echo nil (lambda (_ v) v) t)))
      (prop-match-beginning match))))

(defun ghostel--find-previous-link (from)
  "Return start position of the first hyperlink before FROM, or nil."
  (save-excursion
    (goto-char from)
    (when-let* ((match (text-property-search-backward
                        'help-echo nil (lambda (_ v) v) t)))
      (prop-match-beginning match))))

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
  (unless ghostel--copy-mode-active
    (ghostel-copy-mode))
  (dotimes (_ (or n 1))
    (ghostel--goto-hyperlink 'next)))

(defun ghostel-previous-hyperlink (&optional n)
  "Enter copy mode and move point to the Nth previous hyperlink.
Wraps to `point-max' when no link is found before point."
  (interactive "p")
  (unless ghostel--copy-mode-active
    (ghostel-copy-mode))
  (dotimes (_ (or n 1))
    (ghostel--goto-hyperlink 'previous)))

(defun ghostel--detect-urls (&optional begin end)
  "Scan a buffer region for plain-text URLs and file:line references.
BEGIN and END default to `point-min' and `point-max' respectively.
Skips regions that already have a `help-echo' property (e.g. from OSC 8).
Bounding the scan keeps streaming output from re-scanning the entire
materialized scrollback on every redraw.
Binds `inhibit-read-only' so the scan can attach text properties even
when called from the deferred-detection timer outside the redraw scope."
  (let ((begin (or begin (point-min)))
        (end (or end (point-max)))
        (inhibit-read-only t))
    (save-excursion
      ;; Pass 1: http(s) URLs
      (when ghostel-enable-url-detection
        (goto-char begin)
        (while (re-search-forward
                "https?://[^ \t\n\r\"<>]*[^ \t\n\r\"<>.,;:!?)>]"
                end t)
          (let ((beg (match-beginning 0))
                (mend (match-end 0)))
            (unless (get-text-property beg 'help-echo)
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
              (unless (get-text-property beg 'help-echo)
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


(defun ghostel--compensate-wide-chars ()
  "Shrink trailing spaces on lines where wide-char glyphs cause pixel overflow.
Emoji glyphs often render wider than `char-width' times `frame-char-width'
pixels, making the display engine treat the line as wider than the window
even though `string-width' equals the terminal column count.  For each
overflowing line we replace the trailing whitespace with a single stretch
glyph of exactly the remaining pixel width."
  (let ((win (get-buffer-window)))
    (when (and win (display-graphic-p))
      (let ((win-w (window-body-width win t))
            (inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((bol (line-beginning-position))
                   (eol (line-end-position))
                   (spaces-start (save-excursion
                                   (goto-char eol)
                                   (skip-chars-backward " " bol)
                                   (point)))
                   (avail (- eol spaces-start)))
              (when (> avail 0)
                ;; Strip stale compensation so pixel measurement is accurate.
                (remove-text-properties spaces-start eol '(display nil))
                (let* ((content-pw (car (window-text-pixel-size win bol spaces-start)))
                       (remaining (max 0 (- win-w content-pw)))
                       (natural-pw (* avail (frame-char-width (window-frame win)))))
                  ;; Only compensate when we would shrink the trailing spaces;
                  ;; never widen them as that could introduce truncation on
                  ;; lines that fit naturally.
                  (when (< remaining natural-pw)
                    (put-text-property spaces-start eol 'display
                                       `(space :width (,remaining)))))))
            (forward-line 1)))))))


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
TYPE is a single character string: A, B, C, or D.
PARAM is the exit status string for type D, or nil.
Note: the `ghostel-prompt' text property is applied by the native
render loop (which queries libghostty's per-row semantic state),
not here.  This handler only tracks prompt positions and exit status."
  (pcase type
    ("A"
     ;; Prompt start — record line number.
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

(defun ghostel--prompt-input-start ()
  "From the start of a prompt line, move past the prompt marker to user input.
Skips to end of line, then backs up past trailing whitespace to find
the last non-whitespace+whitespace boundary (e.g. after `$ ' or `# ')."
  (let ((bol (point)))
    (end-of-line)
    (skip-chars-backward " \t" bol)       ; skip trailing padding
    (skip-chars-backward "^ \t" bol)      ; skip last word (user input)
    (when (> (point) bol)
      (skip-chars-backward " \t" bol)     ; skip space before user input
      (skip-chars-forward " \t"           ; move forward past that space
                          (line-end-position)))
    ;; If we landed on the last visible char (no command follows),
    ;; step past it and the trailing space (e.g. "# " → past both).
    (when (looking-at-p "\\S-\\s-*$")
      (forward-char 2))))

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
      ;; If inside a prompt, first skip backward past it.
      (when (or (get-text-property pos 'ghostel-prompt)
                (and (= pos (point-max))
                     (> pos (point-min))
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
  "Enter copy mode and move to the Nth next prompt."
  (interactive "p")
  (unless ghostel--copy-mode-active
    (ghostel-copy-mode))
  (ghostel--navigate-next-prompt n))

(defun ghostel-previous-prompt (&optional n)
  "Enter copy mode and move to the Nth previous prompt."
  (interactive "p")
  (unless ghostel--copy-mode-active
    (ghostel-copy-mode))
  (ghostel--navigate-previous-prompt n))


;;; Callbacks from native module

(defun ghostel--osc51-eval (str)
  "Handle an OSC 51;E command from the terminal.
STR is the payload after the E sub-command.
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
Updates `mode-line-process' to show the current STATE and
PROGRESS (an integer 0-100 or nil).  STATE is one of the symbols
`remove', `set', `error', `indeterminate', `pause'."
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
           ;; Unknown state: keep the current mode-line value rather
           ;; than silently clearing it, so a future Zig-side state is
           ;; visible-but-stale instead of disappearing.
           (_              mode-line-process))))
    (unless (equal new-val mode-line-process)
      (setq mode-line-process new-val)
      (force-mode-line-update))))

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

(defun ghostel--set-buffer-face (fg bg)
  "Set the buffer's default face to FG foreground and BG background.
This ensures terminal text is visible regardless of the Emacs theme."
  (when ghostel--face-cookie
    (face-remap-remove-relative ghostel--face-cookie))
  (setq ghostel--face-cookie
        (face-remap-add-relative 'default
                                 :foreground fg
                                 :background bg)))

(defun ghostel--set-title-default (title)
  "Update the buffer name with TITLE from the terminal.
Only acts when the buffer has not been manually renamed by the user."
  (when (or (null ghostel--managed-buffer-name)
            (equal (buffer-name) ghostel--managed-buffer-name))
    (let ((new-name (format "*ghostel: %s*" title)))
      (rename-buffer new-name t)
      ;; Keep the actual name because `rename-buffer' may uniquify it.
      (setq ghostel--managed-buffer-name (buffer-name)))))

(defun ghostel--set-title (title)
  "Dispatch TITLE changes to `ghostel-set-title-function'."
  (when ghostel-set-title-function
    (funcall ghostel-set-title-function title)))

(defun ghostel--set-cursor-style (style visible)
  "Set the cursor style based on terminal state.
STYLE is one of: 0=bar, 1=block, 2=underline, 3=hollow-block.
VISIBLE is t or nil.
Skipped when copy mode is active because copy mode manages its own
cursor, or when `ghostel-ignore-cursor-change' is non-nil."
  (unless (or ghostel--copy-mode-active
              ghostel-ignore-cursor-change)
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
                  list-buffers-directory default-directory)))))))


;;; Palette

(defface ghostel-default
  '((t :inherit default))
  "Base face used to derive ghostel terminal default fg/bg colors.
Customize this to give ghostel buffers different default colors than
the rest of Emacs (e.g. a dark terminal inside a light Emacs)."
  :group 'ghostel)

(defun ghostel--face-hex-color (face attr)
  "Extract hex color string from FACE's ATTR (:foreground or :background).
Falls back to \"#000000\" if the color cannot be resolved."
  (or (let ((color (face-attribute face attr nil 'default)))
        (when (and (stringp color) (not (string= color "unspecified")))
          (let ((rgb (color-values color)))
            (if rgb
                (apply #'format "#%02x%02x%02x"
                       (mapcar (lambda (c) (ash c -8)) rgb))
              ;; Batch mode: color-values returns nil without a display.
              ;; If the color is already "#RRGGBB", use it directly.
              (and (string-prefix-p "#" color) (= (length color) 7)
                   color)))))
      "#000000"))

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


;;; Theme synchronization

(defun ghostel-sync-theme ()
  "Re-apply terminal color palette in all ghostel buffers.
Call this after changing the Emacs theme so terminals match."
  (interactive)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'ghostel-mode) ghostel--term)
        (ghostel--apply-palette ghostel--term)
        (when (not ghostel--copy-mode-active)
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term)
            (ghostel--schedule-link-detection)))))))

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

(defvar-local ghostel--pending-output nil
  "Accumulated output chunks waiting to be fed to the terminal.
When non-nil, a list of unibyte strings (in reverse order) that
will be concatenated and passed to `ghostel--write-input' at the
next redraw.  Batching writes reduces per-call overhead in the
VT parser.")


;;; Process management

(defun ghostel--filter (process output)
  "Process filter: feed PTY output to the terminal.
PROCESS is the shell process, OUTPUT is the raw byte string.
Output is accumulated and fed to the terminal in a single batch
when the redraw timer fires, reducing per-call VT parser overhead.

For interactive echo (small output arriving shortly after a keystroke),
the redraw is performed immediately to minimize typing latency."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when ghostel--term
        ;; If a minibuffer-triggered crop is still pending, commit it
        ;; before this output renders.  Keeps `ghostel--term-rows' in
        ;; sync with reality so a later minibuffer-close doesn't hit
        ;; the no-change branch and skip the resize-aware redraw.
        (ghostel--commit-deferred-crop)
        ;; Accumulate output for batched write-input at redraw time.
        (push output ghostel--pending-output)
        ;; Respond to OSC 4/10/11 color queries immediately: programs like
        ;; `duf' read stdin with a tight timeout and give up if the reply
        ;; waits for the redraw timer.  Flushing runs the extractor in the
        ;; native module, which writes the reply back through the PTY
        ;; before this filter returns.
        (when (string-match-p
               "\e\\]\\(?:4;[0-9]+;\\?\\|10;\\?\\|11;\\?\\)" output)
          (ghostel--flush-pending-output))
        ;; Immediate redraw for interactive echo: small output arriving
        ;; within `ghostel-immediate-redraw-interval' of last keystroke.
        (if (and (> ghostel-immediate-redraw-threshold 0)
                 ghostel--last-send-time
                 (<= (length output) ghostel-immediate-redraw-threshold)
                 (< (float-time (time-subtract (current-time)
                                               ghostel--last-send-time))
                    ghostel-immediate-redraw-interval))
            (progn
              ;; Cancel pending timer — we're drawing now.
              (when ghostel--redraw-timer
                (cancel-timer ghostel--redraw-timer)
                (setq ghostel--redraw-timer nil))
              (ghostel--delayed-redraw (current-buffer)))
          ;; Bulk output: batch and schedule as before.
          (ghostel--invalidate))))))

(defun ghostel--sentinel (process event)
  "Process sentinel: clean up when shell exits.
PROCESS is the shell process, EVENT describes the state change."
  (let ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        ;; Flush any pending output before cleanup.
        (when ghostel--term
          (ghostel--flush-pending-output))
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

(defun ghostel--get-shell ()
  "Get the shell to run, respecting TRAMP remote connections.
When `default-directory' is a remote TRAMP path, consult
`ghostel-tramp-shells' for the appropriate shell."
  (if (file-remote-p default-directory)
      (with-parsed-tramp-file-name default-directory nil
        (or (ghostel--tramp-get-shell method)
            (ghostel--tramp-get-shell t)
            (with-connection-local-variables shell-file-name)
            ghostel-shell))
    ghostel-shell))

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
                   :stty "erase '^?' iutf8 -ixon echo" :temp-files (list temp))))
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
                   :args nil :stty "erase '^?' iutf8 -ixon"
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
                   :stty "erase '^?' iutf8 -ixon" :temp-files (list temp)))))))
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
  ;; before the program reads its terminal attributes:
  ;;  - erase '^?': Emacs PTYs leave VERASE undefined, but
  ;;    shells like fish check VERASE at startup to decide
  ;;    whether \x7f means backspace.
  ;;  - iutf8: kernel-level UTF-8 awareness so backspace
  ;;    correctly erases multi-byte characters.
  ;;  - -ixon: disable XON/XOFF flow control so C-q and C-s
  ;;    pass through to the application instead of being
  ;;    swallowed by the PTY line discipline.
  ;;  - echo (bash-only): readline buffers its own echo, so
  ;;    we need PTY-level echo early in startup.  Old bash
  ;;    versions (notably macOS /bin/bash 3.2) may initialize
  ;;    readline before ENV-sourced integration runs.
  ;; The clear-screen hides the stty output.  exec replaces
  ;; the wrapper so only the target program remains.
  (let* ((shell-command
          (list "/bin/sh" "-c"
                (concat "stty " stty-flags
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
           (cons "INSIDE_EMACS=ghostel" (ghostel--terminal-env))
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
         (read-process-output-max (max read-process-output-max (* 1024 1024)))
         (proc (make-process
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
    (set-process-query-on-exit-flag proc nil)
    (process-put proc 'adjust-window-size-function
                 #'ghostel--window-adjust-process-window-size)
    proc))

(defun ghostel--start-process ()
  "Start the shell process with a PTY.
When `default-directory' is a remote TRAMP path, spawn the shell
on the remote host."
  ;; Read dims from the buffer-locals set by `ghostel--init-buffer'
  ;; (the only caller).  Recomputing from `(window-body-height)' here
  ;; would query the *selected* window, which can differ from the
  ;; buffer's window when the buffer is shown in a popup that didn't
  ;; get selected — leaving the PTY and the libghostty terminal sized
  ;; against different windows (issue #192).
  (let* ((height (max 1 ghostel--term-rows))
         (width (max 1 ghostel--term-cols))
         (remote-p (file-remote-p default-directory))
         (shell (ghostel--get-shell))
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
         (shell-args (cond
                      (remote-integration
                       (plist-get remote-integration :args))
                      ((and (eq shell-type 'bash) integration-env)
                       (list "--posix"))
                      (t nil)))
         (stty-flags (cond
                      (remote-integration
                       (plist-get remote-integration :stty))
                      ((eq shell-type 'bash)
                       "erase '^?' iutf8 -ixon echo")
                      (t "erase '^?' iutf8 -ixon")))
         (extra-env (append
                     (unless remote-p
                       (list (format "EMACS_GHOSTEL_PATH=%s" ghostel-dir)))
                     integration-env))
         (proc (ghostel--spawn-pty shell shell-args height width
                                   stty-flags extra-env remote-p)))
    (when remote-integration
      (ghostel--cleanup-temp-paths
       (plist-get remote-integration :temp-files)
       (plist-get remote-integration :temp-dirs)))
    proc))


;;; Rendering

(defvar-local ghostel--last-output-time nil
  "Time of the last process output, for adaptive frame rate.")

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
                            #'ghostel--delayed-redraw
                            (current-buffer))))))

(defconst ghostel--line-context-lines 3
  "Number of lines (including the target) used as a disambiguation key.
`ghostel--line-key' captures this many consecutive lines starting at a
position; `ghostel--find-line-pos' searches for the exact multi-line
block to locate that position after the buffer has been rewritten.
Larger values better disambiguate repeated content (blank lines,
identical prompts) at the cost of wider comparisons.")

(defun ghostel--line-key (pos)
  "Return a disambiguation key for the line containing POS.
The key is a list of consecutive line strings starting with the line
at POS, of length up to `ghostel--line-context-lines'.  Passed to
`ghostel--find-line-pos' to re-locate POS after the buffer has been
rewritten.  Multiple scrollback lines may share identical text (blank
lines, repeated prompts), but a short run of consecutive lines is
far more likely to be unique."
  (save-excursion
    (goto-char pos)
    (let ((lines nil)
          (n ghostel--line-context-lines))
      (while (and (> n 0) (not (eobp)))
        (push (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))
              lines)
        (forward-line 1)
        (setq n (1- n)))
      (nreverse lines))))

(defun ghostel--find-line-pos (key &optional col)
  "Find the beginning-of-line position matching KEY.
KEY is a list of consecutive line strings produced by
`ghostel--line-key'.  Returns the position of the first match of the
full multi-line block, or nil if no match.  With COL, returns the
position COL columns into the first matched line."
  (when (and key (listp key) (stringp (car key)))
    (let ((pattern
           (concat "^" (mapconcat #'regexp-quote key "\n") "$")))
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward pattern nil t)
          (let ((found (match-beginning 0)))
            (if col
                (save-excursion
                  (goto-char found)
                  (move-to-column col)
                  (point))
              found)))))))

(defun ghostel--flush-pending-output ()
  "Feed any accumulated output to the terminal in a single batch."
  (when ghostel--pending-output
    (let ((combined (apply #'concat (nreverse ghostel--pending-output))))
      (setq ghostel--pending-output nil)
      ;; An OSC 51;E callback dispatched synchronously from the native
      ;; parser (e.g. `find-file-other-window') can change the current
      ;; buffer via `select-window'.  Isolate that so callers keep
      ;; reading buffer-locals — notably `ghostel--term' — from the
      ;; ghostel buffer after this returns.
      (save-current-buffer
        (ghostel--write-input ghostel--term combined)))))

(defun ghostel--viewport-start ()
  "Position of the first line of the terminal viewport, or nil if rows<=0."
  (let ((tr (or ghostel--term-rows 0)))
    (when (> tr 0)
      (save-excursion
        (goto-char (point-max))
        (forward-line (- tr))
        (line-beginning-position)))))

(defun ghostel--active-preedit-overlay ()
  "Return the active GUI preedit overlay in the current buffer, if any.
GTK/PGTK input methods display uncommitted text with `x-preedit-overlay'
or `pgtk-preedit-overlay'.  Those overlays are anchored at point, so a
terminal redraw that moves point can make the candidate window jump."
  (cl-loop for sym in '(x-preedit-overlay pgtk-preedit-overlay)
           for ov = (and (boundp sym) (symbol-value sym))
           for text = (and (overlayp ov) (overlay-get ov 'before-string))
           when (and text
                     (eq (overlay-buffer ov) (current-buffer))
                     (stringp text)
                     (> (length text) 0))
           return ov))

(defun ghostel--preedit-window (overlay)
  "Return the window associated with preedit OVERLAY, if it is usable."
  (let ((win (overlay-get overlay 'window)))
    (cond
     ((and (window-live-p win)
           (eq (window-buffer win) (current-buffer)))
      win)
     ((eq (window-buffer (selected-window)) (current-buffer))
      (selected-window)))))

(defun ghostel--capture-preedit-state ()
  "Capture active GUI preedit position before a redraw rewrites the buffer."
  (when-let* ((overlay (ghostel--active-preedit-overlay)))
    (let* ((pos (overlay-start overlay))
           (viewport-start (ghostel--viewport-start))
           (line (and viewport-start
                      (>= pos viewport-start)
                      (- (line-number-at-pos pos)
                         (line-number-at-pos viewport-start))))
           (column (save-excursion
                     (goto-char pos)
                     (current-column))))
      (list :overlay overlay
            :window (ghostel--preedit-window overlay)
            :position pos
            :viewport-line line
            :column column))))

(defun ghostel--restore-preedit-state (state viewport-start)
  "Restore preedit overlay STATE after redraw.
VIEWPORT-START is the post-redraw viewport-start position.
Returns the buffer position that should be used as the composing
window's point, or nil when the saved overlay is no longer live."
  (let ((overlay (plist-get state :overlay)))
    (when (and (overlayp overlay)
               (eq (overlay-buffer overlay) (current-buffer)))
      (let* ((line (plist-get state :viewport-line))
             (column (plist-get state :column))
             (pos (if (and viewport-start line)
                      (save-excursion
                        (goto-char viewport-start)
                        (forward-line
                         (min line (max 0 (1- (or ghostel--term-rows 1)))))
                        (move-to-column column)
                        (point))
                    (min (plist-get state :position) (point-max)))))
        (move-overlay overlay pos pos (current-buffer))
        pos))))

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

(defsubst ghostel--window-anchored-p (win)
  "Non-nil if WIN is auto-following the viewport.
A window counts as anchored when `ghostel--snap-requested' is set
\(the user just typed), when WIN is in `ghostel--windows-needing-snap'
\(WIN just gained this buffer), when no anchor has been recorded yet
\(first redraw), or when its `window-start' is at or past the prior
anchor.  During a resize-triggered redraw, a window absent from
`ghostel--scroll-positions' also counts as anchored: the prior redraw
left it following the viewport, so a drifted `window-start' below the
anchor is Emacs redisplay (e.g. `keep-point-visible' when the
minibuffer shrinks the window), not a user scroll."
  (let ((anchor ghostel--last-anchor-position))
    (or ghostel--snap-requested
        (memq win ghostel--windows-needing-snap)
        (null anchor)
        (>= (window-start win) anchor)
        (and ghostel--redraw-resize-active
             (not (assq win ghostel--scroll-positions))))))

(defun ghostel--capture-window-state (win)
  "Return (WIN WS-KEY WP-KEY WP-COL) for WIN.
Used to snapshot a non-anchored window's scroll position so it can
be restored after the native redraw rewrites the buffer."
  (let ((wp (window-point win)))
    (list win
          (ghostel--line-key (window-start win))
          (ghostel--line-key wp)
          (save-excursion (goto-char wp) (current-column)))))

(defun ghostel--position-mangled-p (pos saved-key)
  "Return non-nil when POS looks like Emacs clamped it to `point-min'.
The mangling signature is: POS is `point-min' and SAVED-KEY does not
match the content currently at `point-min' (i.e. the saved content
lived elsewhere).  Other cases — SAVED-KEY still matches POS (fast
path), or POS is at some other valid line (legitimate user scroll)
— return nil; the post-redraw capture records them."
  (and (= pos (point-min))
       (not (equal saved-key (ghostel--line-key pos)))))

(defun ghostel--reconcile-saved-position (win entry)
  "Restore WIN's ws/wp from ENTRY when Emacs has clamped them to point-min.
ENTRY is an alist entry of the form (WIN . (WS-KEY WP-KEY WP-COL)).
For ws and wp independently: when the live position looks mangled
\(see `ghostel--position-mangled-p'), search for the saved content
and move the window back.  Other position changes are left alone —
the post-redraw capture rebuilds `ghostel--scroll-positions' from
each window's live state, so refreshing the saved key here would
be a dead write."
  (let ((data (cdr entry)))
    (when (ghostel--position-mangled-p (window-start win) (nth 0 data))
      (let ((p (ghostel--find-line-pos (nth 0 data))))
        (when p (set-window-start win p t))))
    (when (ghostel--position-mangled-p (window-point win) (nth 1 data))
      (let ((p (ghostel--find-line-pos (nth 1 data) (nth 2 data))))
        (when p (set-window-point win p))))))

(defun ghostel--correct-mangled-scroll-positions (buffer)
  "Apply the mangling heuristic to every saved scroll position on BUFFER.
Emacs redisplay between our redraws can clamp `window-start' to
`point-min' (typically after a minibuffer-triggered window resize);
this pass detects and corrects that before the native redraw runs,
so the classification below sees the user's real scroll state.
No-op when `ghostel--snap-requested' (user input overrides)."
  (unless ghostel--snap-requested
    (dolist (entry ghostel--scroll-positions)
      (let ((win (car entry)))
        (when (and (window-live-p win)
                   (eq (window-buffer win) buffer))
          (ghostel--reconcile-saved-position win entry))))))

(defun ghostel--anchor-window (win vs pt)
  "Pin WIN to viewport-start VS and sync its point to PT.
Also resets pixel vscroll (pixel-scroll-precision-mode may leave a
partial offset that would clip the top line after a redraw)."
  (set-window-start win vs t)
  (set-window-vscroll win 0 t)
  (set-window-point win pt))

(defun ghostel--restore-scrollback-window (win state)
  "Restore WIN to ws/wp recorded in STATE and push STATE to scroll-positions.
Only searches when the native redraw actually moved ws/wp off the
captured line (fast path otherwise).  STATE is (WIN WS-KEY WP-KEY
WP-COL) as produced by `ghostel--capture-window-state', or nil if
WIN appeared after the pre-redraw capture (e.g. shown in a new
frame mid-redraw) — in which case this is a no-op."
  (when state
    (let ((ws-key (nth 1 state))
          (wp-key (nth 2 state))
          (wp-col (nth 3 state)))
      (unless (equal ws-key (ghostel--line-key (window-start win)))
        (let ((new (ghostel--find-line-pos ws-key)))
          (when new (set-window-start win new t))))
      (unless (equal wp-key (ghostel--line-key (window-point win)))
        (let ((new (ghostel--find-line-pos wp-key wp-col)))
          (when new (set-window-point win new))))
      (push (cons win (list ws-key wp-key wp-col))
            ghostel--scroll-positions))))

(defun ghostel--delayed-redraw (buffer)
  "Perform the actual redraw in BUFFER.
Flushes pending PTY output, corrects any Emacs-side window-start
mangling, runs the native redraw, then restores scroll state for
windows that were reading scrollback and anchors windows that were
following the viewport.

When a GUI input method is composing preedit text in BUFFER, leaves
buffer point on the preedit anchor instead of the terminal cursor so
the candidate window does not jump while text is streaming in."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ghostel--redraw-timer nil)
      (when (and ghostel--term (not ghostel--copy-mode-active))
        (ghostel--flush-pending-output)
        ;; Skip during synchronized output unless forced by scroll/resize.
        (unless (and (not ghostel--force-next-redraw)
                     (ghostel--mode-enabled ghostel--term 2026))
          (setq ghostel--force-next-redraw nil)
          (setq ghostel--has-wide-chars nil)
          (ghostel--correct-mangled-scroll-positions buffer)
          (let* ((preedit-state (ghostel--capture-preedit-state))
                 (preedit-window (plist-get preedit-state :window))
                 (all-windows (get-buffer-window-list buffer nil t))
                 (anchored (cl-remove-if-not #'ghostel--window-anchored-p
                                             all-windows))
                 (non-anchored-states
                  (mapcar #'ghostel--capture-window-state
                          (cl-remove-if #'ghostel--window-anchored-p
                                        all-windows)))
                 (inhibit-read-only t)
                 (inhibit-redisplay t)
                 (inhibit-modification-hooks t))
            (ghostel--redraw ghostel--term ghostel-full-redraw)
            (when ghostel--has-wide-chars
              (ghostel--compensate-wide-chars))
            (let* ((pt (point))
                   (vs (ghostel--viewport-start))
                   (preedit-point
                    (and preedit-state
                         (ghostel--restore-preedit-state
                          preedit-state vs))))
              (setq ghostel--scroll-positions nil)
              (dolist (win all-windows)
                (if (and vs (memq win anchored))
                    (let ((preedit-win-p
                           (and preedit-point
                                preedit-window
                                (eq win preedit-window))))
                      (ghostel--anchor-window
                       win vs
                       (if preedit-win-p preedit-point pt)))
                  (ghostel--restore-scrollback-window
                   win (assq win non-anchored-states))))
              (when preedit-point
                (goto-char preedit-point))
              (when vs
                (setq ghostel--last-anchor-position vs))
              (ghostel--schedule-link-detection vs (point-max))))
          (setq ghostel--snap-requested nil)
          (setq ghostel--windows-needing-snap nil))))))


(defun ghostel-force-redraw ()
  "Force a full terminal redraw (for debugging)."
  (interactive)
  (when ghostel--term
    (setq ghostel--has-wide-chars nil)
    (let ((inhibit-read-only t))
      (ghostel--redraw ghostel--term ghostel-full-redraw))
    (when ghostel--has-wide-chars
      (ghostel--compensate-wide-chars))
    (ghostel--schedule-link-detection)))


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
           ;; No change — skip entirely.  Window has grown back to (or never
           ;; left) `ghostel--term-rows', so any deferred crop is moot.
           ((and (eql height ghostel--term-rows)
                 (eql width ghostel--term-cols))
            (setq ghostel--deferred-crop-size nil)
            (setq size nil))
           ;; Crop: minibuffer is active, only height shrank, width unchanged, and the
           ;; terminal is on the primary screen.  Defer the resize so no SIGWINCH is sent
           ;; — the Emacs window naturally hides the bottom rows, just like a normal
           ;; buffer.  Alt-screen apps (vim, htop) own the full viewport and must be told
           ;; the real size to re-layout, so they take the normal-resize path.  If the
           ;; user switches focus into the ghostel window while the minibuffer is still
           ;; open, `ghostel--commit-cropped-size' commits the smaller size then.  If
           ;; output arrives, `ghostel--commit-deferred-crop' commits before the next
           ;; render so geometry matches reality.
           ((and (> (minibuffer-depth) 0)
                 (eql width ghostel--term-cols)
                 (< height ghostel--term-rows)
                 (not (ghostel--alt-screen-p ghostel--term)))
            (setq ghostel--deferred-crop-size (cons height width))
            (setq size nil))
           ;; Real resize — update the terminal model and redraw.  Any deferred
           ;; crop is superseded by this size.
           (t
            (setq ghostel--deferred-crop-size nil)
            (ghostel--set-size-with-cell-dims
             ghostel--term (max 1 height) (max 1 width))
            (setq ghostel--term-rows height)
            (setq ghostel--term-cols width)
            (setq ghostel--force-next-redraw t)
            ;; Redraw synchronously so the buffer is updated before
            ;; Emacs displays the stale content at the new window size.
            (when ghostel--redraw-timer
              (cancel-timer ghostel--redraw-timer)
              (setq ghostel--redraw-timer nil))
            ;; `ghostel--redraw-resize-active' lets `ghostel--window-anchored-p'
            ;; treat Emacs-induced `window-start' drift (from `keep-point-visible'
            ;; when a minibuffer-triggered resize shrinks the body) as drift,
            ;; not as a user scroll.
            (let ((ghostel--redraw-resize-active t))
              (ghostel--delayed-redraw buffer)))))))
    ;; Return size — Emacs calls set-process-window-size (SIGWINCH)
    ;; after this function returns.  nil suppresses the call.
    size))

(defun ghostel--commit-deferred-crop ()
  "Commit a pending `ghostel--deferred-crop-size', if any.
Sends SIGWINCH to bring the PTY in sync with the cropped Emacs window
and runs a synchronous resize-aware redraw so `window-anchored-p'
treats any `keep-point-visible' drift across the size change as drift,
not user scrollback (issue #191).  No-op when nothing is pending."
  (when (and ghostel--deferred-crop-size
             ghostel--term ghostel--process
             (process-live-p ghostel--process))
    (let ((height (car ghostel--deferred-crop-size))
          (width (cdr ghostel--deferred-crop-size)))
      (setq ghostel--deferred-crop-size nil)
      (ghostel--set-size-with-cell-dims
       ghostel--term (max 1 height) (max 1 width))
      (setq ghostel--term-rows height
            ghostel--term-cols width
            ghostel--force-next-redraw t)
      (set-process-window-size ghostel--process
                               (max 1 height) (max 1 width))
      (when ghostel--redraw-timer
        (cancel-timer ghostel--redraw-timer)
        (setq ghostel--redraw-timer nil))
      (let ((ghostel--redraw-resize-active t))
        (ghostel--delayed-redraw (current-buffer))))))

(defun ghostel--reshow-snap (window)
  "Mark WINDOW for viewport-snap on the next redraw.
Intended for buffer-local `window-buffer-change-functions'.  Fires
whenever this buffer becomes WINDOW's buffer: both on the classic
hide-then-show transition and when an additional window opens on
the same buffer (`split-window', `display-buffer', etc.).  While
the buffer is hidden `ghostel--last-anchor-position' keeps advancing
with each redraw, so the pre-show `window-start' that Emacs restores
falls behind the anchor and is misclassified as scrollback (issue
#177).  Recording WINDOW (rather than setting a buffer-level flag)
forces the next redraw to anchor only that window, leaving peer
windows the user may have scrolled back undisturbed.
`ghostel--invalidate' schedules the redraw even when no new PTY
output is arriving."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             ghostel--term)
    (cl-pushnew window ghostel--windows-needing-snap)
    (ghostel--invalidate)))

(defun ghostel--commit-cropped-size (window)
  "Commit WINDOW's size if the user focused into a cropped ghostel window.
When the minibuffer opens, `ghostel--window-adjust-process-window-size'
skips the resize so the PTY keeps its original row count and the bottom
rows are just hidden.  But if the user switches focus into the ghostel
window while the minibuffer is still up, they are now actively using
the smaller viewport — commit the size so the shell/app knows its real
dimensions.

Intended for buffer-local `window-selection-change-functions'.  When
registered buffer-locally, Emacs calls this with WINDOW and makes its
buffer current; we only commit when WINDOW has become the selected
window (not when it has just been deselected)."
  (when (and (> (minibuffer-depth) 0)
             (window-live-p window)
             (eq window (frame-selected-window (window-frame window)))
             ghostel--term
             ghostel--process
             (process-live-p ghostel--process))
    (let ((height (with-selected-window window
                    (floor (window-screen-lines))))
          (width (window-max-chars-per-line window))
          (buf (current-buffer)))
      (unless (and (eql height ghostel--term-rows)
                   (eql width ghostel--term-cols))
        (setq ghostel--deferred-crop-size nil)
        (ghostel--set-size-with-cell-dims
         ghostel--term (max 1 height) (max 1 width))
        (setq ghostel--term-rows height
              ghostel--term-cols width
              ghostel--force-next-redraw t)
        (set-process-window-size ghostel--process
                                 (max 1 height) (max 1 width))
        (when ghostel--redraw-timer
          (cancel-timer ghostel--redraw-timer)
          (setq ghostel--redraw-timer nil))
        (let ((ghostel--redraw-resize-active t))
          (ghostel--delayed-redraw buf))))))

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
  (add-function :after after-focus-change-function #'ghostel--focus-change)
  (add-hook 'window-selection-change-functions #'ghostel--focus-change)
  (add-hook 'window-buffer-change-functions #'ghostel--focus-change)
  ;; Buffer-local so it only fires for windows showing this buffer, and
  ;; receives WINDOW directly (rather than FRAME as the default binding).
  (add-hook 'window-selection-change-functions
            #'ghostel--commit-cropped-size nil t)
  (add-hook 'window-buffer-change-functions
            #'ghostel--reshow-snap nil t)
  (ghostel--suppress-interfering-modes)
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

(defun ghostel--prepare-buffer (buffer &optional identity)
  "Put BUFFER into `ghostel-mode' and record its terminal identity.
IDENTITY, if given, is stored as `ghostel--buffer-identity' so the
buffer can be found again after title-tracking renames it."
  (with-current-buffer buffer
    (unless (derived-mode-p 'ghostel-mode)
      (ghostel-mode)
      (setq ghostel--managed-buffer-name (buffer-name))
      (setq ghostel--buffer-identity (or identity (buffer-name))))))

(defun ghostel--init-buffer (buffer &optional identity)
  "Initialize BUFFER as a ghostel terminal if no terminal handle exists yet.
Terminal dimensions come from BUFFER's displayed window when one
exists, otherwise from the selected window.  Height uses
`window-screen-lines' (the metric the standard
`adjust-window-size-function' path also uses), not
`window-body-height'.  The former divides the window's pixel height
by the buffer's `default-line-height', which respects
`face-remapping-alist' and `:height' on the default face; the latter
divides by frame char height.  When a theme remaps default —
`nano-light' / `nano-dark' do this — the two metrics disagree, and
using `window-body-height' would size the terminal to N rows only to
have the standard adjust-fn immediately resize to N-K, sending a
startup SIGWINCH that some TUI apps (Claude Code's /tui fullscreen)
handle imperfectly (issue #192).
IDENTITY, if given, is stored as `ghostel--buffer-identity' so the
buffer can be found again after title-tracking renames it."
  (with-current-buffer buffer
    (unless ghostel--term
      (ghostel--prepare-buffer buffer identity)
      (let* ((w (or (get-buffer-window buffer t) (selected-window)))
             (height (max 1 (if (window-live-p w)
                                (with-selected-window w
                                  (floor (window-screen-lines)))
                              24)))
             (width  (max 1 (if (window-live-p w)
                                (window-max-chars-per-line w)
                              80))))
        (setq ghostel--term
              (ghostel--new height width ghostel-max-scrollback ghostel-kitty-graphics-storage-limit (ghostel--kitty-mediums-bits)))
        (setq ghostel--term-rows height)
        (setq ghostel--term-cols width)
        ;; Seed libghostty's cell dimensions before the shell starts —
        ;; otherwise kitty graphics placements arriving in the very first
        ;; output (e.g. timg's transmit-and-place) compute grid_rows=0
        ;; and the terminal advances the cursor zero rows, leaving the
        ;; next prompt on top of the image.
        (ghostel--set-size-with-cell-dims ghostel--term height width)
        (ghostel--apply-palette ghostel--term))
      (ghostel--start-process))))

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
         (buffer (if fresh
                     (generate-new-buffer ghostel-buffer-name)
                   (or (ghostel--find-buffer-by-identity identity)
                       (get-buffer-create identity)))))
    (unless (with-current-buffer buffer (derived-mode-p 'ghostel-mode))
      (ghostel--prepare-buffer buffer identity))
    (pop-to-buffer buffer (append display-buffer--same-window-action
                                  '((category . comint))))
    (ghostel--init-buffer buffer identity)
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
  (let ((window (get-buffer-window buffer t)))
    (with-current-buffer buffer
      (ghostel--prepare-buffer buffer nil)
      ;; Use `window-screen-lines' (not `window-body-height') so the
      ;; height matches the unit `window-adjust-process-window-size-smallest'
      ;; uses — see `ghostel--init-buffer' for why.
      (let* ((height (if window
                         (max 1 (with-selected-window window
                                  (floor (window-screen-lines))))
                       24))
             (width (if window
                        (max 1 (window-max-chars-per-line window))
                      80))
             (remote-p (file-remote-p default-directory)))
        (setq ghostel--term
              (ghostel--new height width ghostel-max-scrollback ghostel-kitty-graphics-storage-limit (ghostel--kitty-mediums-bits)))
        (setq ghostel--term-rows height)
        (setq ghostel--term-cols width)
        ;; Seed libghostty's cell dimensions before the program starts —
        ;; see the matching call in `ghostel--ensure-buffer-state'.
        (ghostel--set-size-with-cell-dims ghostel--term height width)
        (ghostel--apply-palette ghostel--term)
        (ghostel--spawn-pty program args height width
                            "erase '^?' iutf8 -ixon echo" nil remote-p)))))

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

(provide 'ghostel)

;;; ghostel.el ends here
