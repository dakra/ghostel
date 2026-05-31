# Ghostel

Emacs terminal emulator powered by [libghostty-vt](https://ghostty.org/) — the
same VT engine that drives the Ghostty terminal.

Ghostel is inspired by
[emacs-libvterm](https://github.com/akermu/emacs-libvterm): a native dynamic
module handles terminal state and rendering, while Elisp manages the shell
process, keymap, and buffer.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Building from source](#building-from-source)
- [Shell Integration](#shell-integration)
- [Key Bindings](#key-bindings)
- [Features](#features)
  - [TRAMP (Remote Terminals)](#tramp-remote-terminals)
- [Configuration](#configuration)
- [Commands](#commands)
  - [Compilation mode](#compilation-mode)
  - [Eshell integration](#eshell-integration)
  - [Comint integration](#comint-integration)
- [Running Tests](#running-tests)
- [Performance](#performance)
- [Ghostel vs vterm](#ghostel-vs-vterm)
- [Architecture](#architecture)
- [License](#license)

## Requirements

- Emacs 28.1+ with dynamic module support
- macOS, Linux or FreeBSD

The native module is **automatically downloaded** on first use.  Pre-built
binaries are available for:

- `aarch64-macos` (Apple Silicon)
- `x86_64-macos` (Intel Mac)
- `x86_64-linux`
- `aarch64-linux`
- `x86_64-freebsd`

If you prefer to build from source or need a different platform, you'll also need
[Zig](https://ziglang.org/) 0.15.2 (see [Building from source](#building-from-source)).

## Installation

### MELPA

```elisp
(use-package ghostel
  :ensure t)
```

### use-package with vc (Emacs 30+)

```elisp
(use-package ghostel
  :vc (:url "https://github.com/dakra/ghostel"
       :lisp-dir "lisp"
       :rev :newest))
```

NOTE: `:lisp-dir "lisp"` is only required on Emacs <31.1

### use-package with load-path

```elisp
(use-package ghostel
  :load-path "/path/to/ghostel")
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/ghostel")
(require 'ghostel)
```

Then `M-x ghostel` to open a terminal.

### Native module

When the native module is missing, Ghostel will offer to **download a
pre-built binary** or **compile from source** (controlled by
`ghostel-module-auto-install`, default `ask`).  You can also trigger these
manually:

- `M-x ghostel-download-module` — download the minimum supported pre-built binary
- `C-u M-x ghostel-download-module` — choose a specific release tag (leave blank for latest)
- `M-x ghostel-module-compile` — build from source via `zig build`

## Building from source

Building is only needed if you don't want to use the pre-built binaries.
Ghostel vendors a generated `vendor/emacs-module.h`, so normal builds do not
require local Emacs headers.  If you want to override the vendored header, set
`EMACS_INCLUDE_DIR` to a directory containing `emacs-module.h`, or set
`EMACS_BIN_DIR` to an Emacs `bin/` directory and Ghostel will look for
`../include` and `../share/emacs/include`.

```sh
git clone https://github.com/dakra/ghostel.git
cd ghostel

# Build everything (fetches ghostty automatically via Zig package manager)
zig build -Doptimize=ReleaseFast
```

To override the vendored Emacs header, set `EMACS_INCLUDE_DIR` to a
directory containing `emacs-module.h`, or set `EMACS_BIN_DIR` to an
Emacs `bin/` directory.

To build against a local ghostty checkout, temporarily point the
dependency at your local path:

```sh
zig fetch --save=ghostty /path/to/ghostty
zig build -Doptimize=ReleaseFast
```

### Building from source (MELPA install)

When installed from MELPA, `M-x ghostel-module-compile` builds the native
module from source using `zig build`.  Zig's package manager fetches the
ghostty dependency automatically.

Alternatively, download a **pre-built binary** via `M-x ghostel-download-module`
(or `C-u M-x ghostel-download-module` to pick a specific release).

The compiled `xterm-ghostty` terminfo entry ships pre-built in
`etc/terminfo/` and is identical to what `tic` would produce locally —
no build step needed, and the file format is portable across BSD
and ncurses systems.  Maintainers regenerate it via `make
regen-terminfo` after bumping libghostty.

## Shell Integration

Shell integration (directory tracking via OSC 7, prompt navigation via OSC 133,
etc.) is **automatic** for bash, zsh, and fish.  No changes to your shell
configuration files are needed.

This is controlled by `ghostel-shell-integration` (default `t`).  Set it to
`nil` to disable auto-injection and source the scripts manually instead:

<details>
<summary>Manual shell integration</summary>

**bash** — add to `~/.bashrc`:
```bash
[[ "${INSIDE_EMACS%%,*}" = 'ghostel' ]] && source "$EMACS_GHOSTEL_PATH/etc/shell/ghostel.bash"
```

**zsh** — add to `~/.zshrc`:
```zsh
[[ "${${INSIDE_EMACS-}%%,*}" = 'ghostel' ]] && source "$EMACS_GHOSTEL_PATH/etc/shell/ghostel.zsh"
```

**fish** — add to `~/.config/fish/config.fish`:
```fish
string match -qr '^ghostel(,|$)' -- "$INSIDE_EMACS"; and source "$EMACS_GHOSTEL_PATH/etc/shell/ghostel.fish"
```
</details>

## Input modes

Ghostel offers five eat.el-style input modes.  You enter a ghostel
buffer in **semi-char mode**; switch modes with the key bindings below
and watch `mode-line-process` for the current mode indicator.

| Mode        | Indicator | Terminal | Buffer      | Purpose                                       |
|-------------|-----------|----------|-------------|-----------------------------------------------|
| semi-char   | *(none)*  | live     | editable    | default — type to terminal, `C-c` reserved    |
| char        | `:Char`   | live     | editable    | TUI apps — *all* keys go to the terminal      |
| Emacs       | `:Emacs`  | live     | read-only   | search/read while the terminal keeps running  |
| copy        | `:Copy`   | frozen   | read-only   | precise text selection without scroll churn   |
| line        | `:Line`   | live     | editable    | compose input with Emacs keys, send on `RET`  |

### Mode-switch keybindings (available from every mode except char mode)

| Key       | Action                                    |
|-----------|-------------------------------------------|
| `C-c C-j` | Switch to semi-char mode (universal exit) |
| `C-c M-d` | Switch to char mode                       |
| `C-c C-e` | Switch to Emacs mode                      |
| `C-c C-t` | Toggle copy mode                          |
| `C-c C-l` | Switch to line mode                       |
| `M-RET`   | Char mode only: return to semi-char       |

### Semi-char mode (default)

Most keys are sent to the terminal.  Keys in
`ghostel-keymap-exceptions` (default: `C-c`, `C-x`, `C-u`, `C-h`,
`M-x`, `M-:`, `C-\`) pass through to Emacs.

| Key         | Action                                 |
|-------------|----------------------------------------|
| Most keys   | Sent directly to the terminal          |
| `C-c C-c`   | Send interrupt (C-c)                   |
| `C-c C-z`   | Send suspend (C-z)                     |
| `C-c C-d`   | Send EOF (C-d)                         |
| `C-c C-\`   | Send quit (C-\)                        |
| `C-c M-w`   | Copy entire scrollback to kill ring    |
| `C-y`       | Yank from kill ring (bracketed paste)  |
| `M-y`       | Yank-pop (cycle through kill ring)     |
| `C-c C-y`   | Paste from kill ring                   |
| `C-c M-l`   | Clear scrollback                       |
| `C-c C-n`   | Jump to next hyperlink                 |
| `C-c C-p`   | Jump to previous hyperlink             |
| `C-c M-n`   | Enter Emacs mode and jump to next prompt |
| `C-c M-p`   | Enter Emacs mode and jump to previous prompt |
| `C-c C-q`   | Send next key literally (escape hatch) |
| Mouse wheel | Scroll through scrollback              |

### Char mode

Entered with `C-c M-d`.  **All** keys (including
`ghostel-keymap-exceptions`) are sent to the terminal.  Useful for TUI
apps that want to bind `C-x`, `M-x`, `C-h`, etc. themselves.  `M-RET`
(or `C-M-m`) is the sole escape hatch.

### Emacs mode

Entered with `C-c C-e`.  **The terminal keeps running**, the buffer is
read-only, and standard Emacs bindings fall through to the global map.
`isearch-forward`, `occur`, `M-x`, `C-SPC` + `M-w`, arrow keys, wheel
scroll — all work unmodified.  The terminal keeps producing output and
the buffer keeps growing, but your point stays where you navigated it
(the delayed-redraw path preserves point in Emacs mode).

**Typed keys do not reach the shell** — Emacs mode is a "look but
don't touch" view.  Self-insert, `RET`, `TAB`, `DEL` fall through to
the read-only buffer and trigger `text-read-only`, so a stray
keystroke can't accidentally land at the prompt.  Switch to semi-char
mode (`C-c C-j`) when you want to type to the shell.  `C-y` is the
exception: it pastes via bracketed paste as a deliberate action and
snaps point back to the live cursor.

`C-c C-e` toggles Emacs mode off again (returning to the mode you came
from), and `C-c C-t` switches to copy mode to freeze the output.

Use this for searching through scrollback while a build is running,
filtering streaming logs with `M-x occur`, marking and copying across
the visible history, or running any buffer-based command over the
terminal's output without having to freeze it.

### Copy mode

Entered with `C-c C-t`.  The terminal is **frozen** — no live output
updates the buffer until you exit.  Use this when you want to select
text precisely without the terminal scrolling underneath your cursor.
The aggressive copy-mode keymap exits on self-insert, so typing a
letter sends it to the terminal and returns to semi-char mode.

`C-c C-t` toggles copy mode off again, and `C-c C-e` switches to Emacs
mode — read-only but live, so output resumes — without going through
semi-char.

| Key           | Action                           |
|---------------|----------------------------------|
| `C-SPC`       | Set mark                         |
| `M-w` / `C-w` | Copy selection and exit          |
| `C-n` / `C-p` | Move line                        |
| `M-v` / `C-v` | Scroll page up / down            |
| `M-<` / `M->` | Jump to top / bottom of buffer   |
| `C-c C-n`     | Jump to next hyperlink           |
| `C-c C-p`     | Jump to previous hyperlink       |
| `C-c M-n`     | Jump to next prompt              |
| `C-c M-p`     | Jump to previous prompt          |
| `C-l`         | Recenter viewport                |
| `q`           | Exit without copying             |
| `a`–`z`       | Exit and send key to terminal    |

Soft-wrapped newlines are automatically stripped from copied text.

### Mouse selection

Click-and-drag inside a ghostel buffer creates a region.  On release,
`ghostel-mouse-drag-or-set-region` switches input mode so streaming
terminal output cannot clobber the selection — the target is picked
by `ghostel-mouse-drag-input-mode` (default `'copy`):

- `'copy` — enter copy mode.  Redraws pause; the selection is
  stable regardless of where it sits.
- `'emacs` — enter Emacs mode.  The terminal keeps streaming and the
  buffer becomes read-only; selections wholly in scrollback survive,
  selections over rows the live program rewrites can still be lost.
- `nil` — stay in semi-char.  Same selection-survival guarantees as
  `'emacs`, but `M-w` is forwarded to the shell so it cannot copy
  the region — pick this only if you copy via primary selection or
  the GUI menu.

A pure click without a drag only focuses the window and sets point —
no mode switch.  When a TUI has DEC mouse-tracking enabled
(1000/1002/1003 — htop, lazygit, etc.) the click is forwarded to the
program and none of the above applies.

### Line mode

Entered with `C-c C-l`.  Line mode buffers the user's input locally in
Emacs — **no keystrokes are forwarded to the shell** while composing.
Full Emacs editing (`M-b`, `M-DEL`, `C-y` yank, `transpose-words`,
etc.) works on the input region.  Pressing `RET` sends the whole line
to the shell in one write; bash receives it atomically, echoes and
executes it.

The terminal stays live: output keeps streaming and the buffer keeps
re-rendering while you compose.  A snapshot/restore step in the
delayed-redraw path captures the in-progress input before each redraw
and re-inserts it at the new prompt-end afterwards, so async output
or a fresh prompt arriving mid-edit does not clobber what you typed.
After `RET`, line mode stays active — the next prompt is found on the
following redraw cycle and the input marker moves there.

Line mode uses the terminal cursor as the input-area boundary, so
REPLs without shell integration (python3, irb, sqlite3, …) work too.
When OSC 133 prompt markers are present on the cursor's row, the
prompt prefix is recognised and the input boundary lands right after
it.

Line mode and fullscreen TUIs (vim, less, htop, …) cannot share the
same keystroke stream — the TUI needs every key forwarded raw, while
line mode buffers them locally.  Ghostel handles this transparently:
when an alt-screen TUI starts, line mode pauses (any in-progress
input is stashed) and the buffer drops to semi-char so the TUI gets
its keys.  When the TUI exits, line mode resumes at the new prompt
and the stashed input is reinstated.  Pressing `C-c C-l` while a TUI
is already running arms the same auto-resume so line mode activates
when the TUI exits.  An explicit mode switch (`C-c C-j`,
`ghostel-char-mode`, etc.) cancels the armed auto-resume.

| Key         | Action                                   |
|-------------|------------------------------------------|
| *(letters)* | Edit local input (never sent char-by-char) |
| `RET`       | Send the whole line to the shell, stay in line mode |
| `C-c C-c`   | Discard input and send SIGINT, stay in line mode    |
| `C-d`       | Delete char, or send EOF at empty input  |
| `M-p` / `M-n` | History ring: previous / next entry    |
| `C-a`       | Beginning of input on the prompt row, else `beginning-of-line` |
| `C-c C-j`   | Exit to semi-char mode (discards input)  |

### Scrollback search outside copy mode

The full scrollback is always rendered into the buffer as styled text,
so `isearch`, `consult-line`, `occur`, `M-x flush-lines`, `C-x h` to
select all, and any other buffer-based command work across the full
history in **any** mode that has a read-only buffer (Emacs or copy).

## Features

### Terminal Emulation
- Full VT terminal emulation via libghostty-vt
- 256-color and RGB (24-bit true color) support
- **`TERM=xterm-ghostty` with bundled terminfo** — apps that consult terminfo for capabilities (Claude Code, neovim, tmux, modern TUIs) discover synchronized output (DEC 2026), Kitty keyboard protocol, true color, colored underlines, focus reporting, etc., and use their fast paths.  Synchronized output in particular eliminates the choppy partial-redraw effect when Claude Code repaints over a large scrollback.  OSC 52 (clipboard) is supported but intentionally not advertised in the bundled terminfo — see Clipboard below.  Override via `ghostel-term`.
- **OSC 4 / 10 / 11 color queries** — TUI programs can query the current palette, foreground, and background colors, so tools like `duf`, `btop`, `delta`, and anything else using `termenv` auto-detect the right light/dark theme from the Emacs face colors
- **OSC 9 / OSC 777** — desktop notifications and ConEmu progress reports (percentage shown in the mode line; see [Notifications and Progress](#notifications-and-progress))
- Text attributes: bold, italic, faint, underline (single/double/curly/dotted/dashed with color), strikethrough, inverse
- Cursor styles: block, bar, underline, hollow block
- Alternate screen buffer (for TUI apps like htop, vim, etc.)
- Scrollback buffer (configurable, default 5 MB (~5,000 lines), materialized into the Emacs buffer so `isearch`/`consult-line` work over history)

### Links and File Detection
- **OSC 8 hyperlinks** — clickable URLs emitted by terminal programs (click or `RET` to open)
- **Plain-text URL detection** — automatically linkifies `http://` and `https://` URLs even without OSC 8 (toggle with `ghostel-enable-url-detection`)
- **File path detection** — patterns like `/path/to/file.el:42` become clickable, opening the file at the given line (toggle with `ghostel-enable-file-detection`)

### Clipboard
- **OSC 52 clipboard** — terminal programs can set the Emacs kill ring and system clipboard (opt-in via `ghostel-enable-osc52`, useful for remote SSH sessions).  Note: the bundled `xterm-ghostty` terminfo intentionally **does not** advertise the `Ms` capability, so apps don't auto-discover it.  This avoids silent clipboard drops when `ghostel-enable-osc52` is at its default `nil`.  If you enable OSC 52 and want apps (neovim, tmux) to auto-detect, install upstream Ghostty's terminfo on the same path or override `TERMINFO`.
- **Bracketed paste** — yank from kill ring sends text as a bracketed paste so shells handle it correctly

### Input
- Full keyboard input with Ghostty key encoder (respects terminal modes, Kitty keyboard protocol)
- Mouse tracking (press, release, drag) via SGR mouse protocol — TUI apps receive full mouse input
- Focus events gated by DEC mode 1004
- Drag-and-drop (file paths and text)

### Password prompt detection
- When `sudo`, `ssh`, `gpg`, `passwd`, etc. ask for a password, ghostel pops up `read-passwd` and sends the answer through the PTY — keystrokes never flow through Emacs's normal key pipeline, so the password does **not** land in `view-lossage`, the recent-keys ring, or any keyboard-macro recording.
- Detection mirrors libghostty's heuristic — the slave tty is in canonical mode with echo off — via a tiny `tcgetattr` Zig binding. On a local pty whose foreground program flips `!ECHO` (sudo, ssh's own password prompt, gpg, …), only the libghostty signal fires. The cursor-row regex fallback runs only when the foreground shell is on a remote host (`ghostel--remote-shell-p`, which trusts the TRAMP `default-directory` ghostel keeps in sync via OSC 7), so local raw-mode TUIs like vim or less don't risk false positives from coincidental cursor-row content. The fallback regex defaults to `comint-password-prompt-regexp` — the same regex `M-x shell` and `M-x term` use — so structural anchoring (start-of-line or curated trigger word) keeps `$ echo Password:` and similar shell-typed lines from triggering. See `ghostel-debug-start` / `ghostel-debug-password-events-show` for diagnostics.
- Mode-line shows ` 🔒Password` while a prompt is open. Wrong-password retries auto-detect (cursor moves to the new prompt row). The wire copy of the password is `clear-string`'d immediately after the send so it doesn't sit in the heap.
- Extensible via `ghostel-password-prompt-functions` — a chain of `(ROW) -> string-or-nil` sources tried in order. Default reads with `read-passwd`; users prepend their own (auth-source / Keepass / pass / etc) and the default acts as the fallback. The defcustom docstring includes a TRAMP-aware `auth-source-pick-first-password` example.

### Shell Integration
- Automatic injection for bash, zsh, and fish — no shell RC edits needed
- **OSC 7** — directory tracking (`default-directory` follows the shell's cwd, TRAMP-aware for remote hosts)
- **OSC 133** — semantic prompt markers, enabling prompt-to-prompt navigation with `C-c M-n` / `C-c M-p`
- **OSC 2** — title tracking (buffer is renamed from the terminal title)
- **OSC 52;e** — call whitelisted Emacs functions from shell scripts (see [Calling Elisp from the Shell](#calling-elisp-from-the-shell))
- **OSC 52** — clipboard support (opt-in, for remote sessions)
- `INSIDE_EMACS` and `EMACS_GHOSTEL_PATH` environment variables

### TRAMP (Remote Terminals)

When `default-directory` is a TRAMP path (e.g. `/ssh:host:/home/user/`),
`M-x ghostel` spawns a shell on the remote host via TRAMP's process
machinery.  The `ghostel-tramp-shells` variable controls which shell to
use per TRAMP method:

```elisp
;; Default configuration
(setq ghostel-tramp-shells
      '(("ssh" login-shell)          ; auto-detect via getent
        ("scp" login-shell)
        ("docker" "/bin/sh")))       ; fixed shell for containers
```

Each entry is `(METHOD SHELL [FALLBACK])`.  `SHELL` can be a path like
`"/bin/bash"` or the symbol `login-shell` to auto-detect the remote user's
login shell via `getent passwd`.  `FALLBACK` is used when detection fails.

OSC 7 directory tracking is TRAMP-aware: when the shell reports a remote
hostname, `default-directory` is set to the corresponding TRAMP path,
reusing the existing TRAMP prefix (method, user, multi-hop) when available.
When no prefix exists, the method defaults to `tramp-default-method`; set
`ghostel-tramp-default-method` to override it for ghostel specifically
(e.g. `"scp"`, or `"rpc"` with [emacs-tramp-rpc](https://github.com/ArthurHeymans/emacs-tramp-rpc)).

#### Remote Shell Integration

By default, shell integration scripts are not injected for remote
sessions.  There are two ways to enable it:

**Option 1: Automatic injection** (recommended for convenience)

Set `ghostel-tramp-shell-integration` to `t` to have ghostel
automatically transfer integration scripts to the remote host:

```elisp
(setq ghostel-tramp-shell-integration t)
```

This creates small temporary files on the remote host (cleaned up when
the terminal exits).  You can also enable it for specific shells only:

```elisp
(setq ghostel-tramp-shell-integration '(bash zsh))
```

**Option 2: Manual setup** (recommended for permanent remote hosts)

Copy the integration scripts from ghostel's `etc/shell/` directory to
each remote host (e.g. `~/.local/share/ghostel/`) and source them from
your shell configuration.  Optionally co-locate the bundled
`xterm-ghostty` terminfo there too — the wrapper that launches a
TRAMP-spawned remote shell prepends
`~/.local/share/ghostel/terminfo` to the terminfo search path, so
ghostty-aware apps (Claude Code, neovim, tmux, …) get their fast
paths without needing `tic` or `~/.terminfo` (see "Manual install
\(no auto-machinery)" below for that alternative).  From a local
shell:

```bash
ssh REMOTE 'mkdir -p ~/.local/share/ghostel/terminfo'
scp "$EMACS_GHOSTEL_PATH"/etc/shell/ghostel.{bash,zsh,fish} REMOTE:.local/share/ghostel/
scp -r "$EMACS_GHOSTEL_PATH"/etc/terminfo/{x,78} REMOTE:.local/share/ghostel/terminfo/
```

(`$EMACS_GHOSTEL_PATH` is set inside ghostel buffers; outside, substitute
the install path of the ghostel package.  The terminfo `scp` is
optional — without it, TRAMP-spawned remote shells fall back to
`TERM=xterm-256color`, which still has working echo and basic
colors but no ghostty-specific fast paths.)

Then add the appropriate gate to the remote shell config:

**bash** — add to `~/.bashrc` on the remote host:
```bash
if [[ "${INSIDE_EMACS%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
    source ~/.local/share/ghostel/ghostel.bash
fi
```

**zsh** — add to `~/.zshrc` on the remote host:
```zsh
if [[ "${${INSIDE_EMACS-}%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
    source ~/.local/share/ghostel/ghostel.zsh
fi
```

**fish** — add to `~/.config/fish/config.fish` on the remote host:
```fish
if string match -qr '^ghostel(,|$)' -- "$INSIDE_EMACS"; or test "$TERM" = 'xterm-ghostty'
    source ~/.local/share/ghostel/ghostel.fish
end
```

The two-clause gate covers both ways a remote ghostel shell can be
reached:
- **TRAMP-launched ghostel** (`M-x ghostel` from a `/ssh:host:` path)
  rewrites `INSIDE_EMACS` to `ghostel,tramp:VER` on the remote.  The
  `${INSIDE_EMACS%%,*}` prefix match catches it.
- **Plain `ssh REMOTE` from a local ghostel buffer** can't propagate
  `INSIDE_EMACS` over ssh — `SetEnv` requires server-side `AcceptEnv`
  to take effect.  Instead, the gate falls back on `TERM`, which the
  SSH protocol *does* propagate natively.  Ghostel sets
  `TERM=xterm-ghostty` in the local PTY shell environment (controlled
  by `ghostel-term`, default `xterm-ghostty`), so any `ssh` spawned
  from inside the buffer inherits and forwards that value.

False positives — situations where the second clause matches but the
session isn't actually ghostel — include any `ssh` from a non-ghostel
ghostty terminal, nested ssh hops carrying the same `TERM` through,
and anyone who manually exports `TERM=xterm-ghostty`.  Sourcing the
integration in those cases is harmless (`OSC 7` / `OSC 133` work in
plain ghostty too; `ghostel_cmd` becomes a no-op without ghostel on
the other end).

If you customize `ghostel-term` to something other than
`xterm-ghostty`, the second clause won't match.  Drop it and rely on
TRAMP-launched ghostel for remote integration, or replace it with a
match against your customized `TERM`.  The wrapper-driven downgrade
to `xterm-256color` (when `ghostel-ssh-install-terminfo`'s cache
marks a host as skip, or `tic` install fails) also breaks the
fallback for that host — a rare edge case, manageable by clearing
the cache via `M-x ghostel-ssh-clear-terminfo-cache` once you've
fixed the underlying terminfo install.

The integration scripts provide directory tracking (OSC 7), prompt
navigation (OSC 133), and `ghostel_cmd` for calling Elisp from the shell.

#### Remote `xterm-ghostty` terminfo

Ghostel sets `TERM=xterm-ghostty` so apps inside the buffer get the
full capability set (synchronized output, Kitty keyboard, etc.).
That same `TERM` value gets inherited by anything spawned inside
the buffer — including `ssh REMOTE` and `M-x ghostel` from a TRAMP
`default-directory`.  Remote hosts without the `xterm-ghostty`
entry will then print `Error opening terminal: xterm-ghostty`.

`ghostel-ssh-install-terminfo` (default `auto`) handles both cases.
`auto` is enabled when `ghostel-tramp-shell-integration` is on, so
turning on remote integration also turns on terminfo install — one
switch.

##### TRAMP-launched ghostel

`M-x ghostel` from a TRAMP path (`/ssh:host:/path/`) spawns the
shell on the remote.  Ghostel pushes the bundled compiled terminfo
to a remote temp dir over the existing TRAMP connection (no extra
ssh round-trip), sets `TERMINFO=<that dir>` in the remote shell's
env, and cleans up on exit.  Both Linux (`x/`, `g/`) and macOS
(`78/`, `67/`) layouts are written so any ncurses or BSD libcurses
finds it.  Nothing persists on the remote.

##### Outbound `ssh` from a local ghostel buffer

The bundled bash/zsh/fish integration shadows `ssh` with a function
that:

1. Resolves the canonical target via `ssh -G` (normalises ssh_config
   aliases).
2. Looks up the target in `~/.cache/ghostel/ssh-terminfo-cache`.
   The cache key includes a hash of the local terminfo, so libghostty
   bumps automatically invalidate it.  Cache hit → connect with the
   remembered `TERM`.
3. On miss, runs a single setup ssh that probes whether the entry
   already exists on the remote, and if not, installs it via
   `tic -x -` into `~/.terminfo/`.  Records `ok` (use
   `xterm-ghostty`) or `skip` (use `xterm-256color`) in the cache.
4. Runs the user's actual ssh with the resolved `TERM`.

The setup ssh is one extra connection per new host.  Without
ControlMaster you'll see two auth prompts the first time.  Strongly
recommended:

```ssh-config
# ~/.ssh/config
Host *
    ControlMaster auto
    ControlPath   ~/.ssh/cm-%r@%h:%p
    ControlPersist 60s
```

With this, the setup connection and the real connection share a
single auth.  Subsequent connections within `ControlPersist` are
free.

The cache key includes a hash of the **local** terminfo, so
libghostty bumps automatically invalidate the cache.  It does NOT
notice when a remote's terminfo changes out-of-band (system update,
manual `tic`).  Run `M-x ghostel-ssh-clear-terminfo-cache` to force
re-probe.

Verified working from macOS to Linux remotes.  Mixed macOS-to-macOS
or BSD targets inherit `tic`'s native hashed-dir layout
(`~/.terminfo/<hex>/`); `infocmp` reads the same path so they pair
correctly.

Skip-install heuristics:
- `ssh HOST cmd` (user passes a remote command): wrapper skips
  install for that call to avoid clashing with the user's command.
  Connects with cached `TERM` if known, otherwise `xterm-256color`.
  The next interactive `ssh HOST` triggers install.
- `ssh -V`, `ssh -h`, etc. (no host resolved): pass through.
- No `infocmp` locally: pass through.

Per-call escape: prefix with `GHOSTEL_SSH_KEEP_TERM=1` to bypass
the wrapper entirely.

##### Manual install (no auto-machinery)

If you'd rather not have ghostel touch remote hosts (and don't want
the auto-cache), set `(setq ghostel-ssh-install-terminfo nil)` and
install the entry yourself once per host.

Pipe the local entry across:
```bash
infocmp -x xterm-ghostty | ssh REMOTE 'mkdir -p ~/.terminfo && tic -x -'
```

Or copy the bundled compiled binary from the package directory:
```bash
ssh REMOTE 'mkdir -p ~/.terminfo/x'
scp <package-dir>/etc/terminfo/x/xterm-ghostty REMOTE:~/.terminfo/x/
# Ghostty also looks in 78/ on macOS:
ssh REMOTE 'uname' | grep -q Darwin && {
    ssh REMOTE 'mkdir -p ~/.terminfo/78'
    scp <package-dir>/etc/terminfo/78/xterm-ghostty REMOTE:~/.terminfo/78/
}
```

After this, every shell on the remote sees `xterm-ghostty` and
ghostel's outbound ssh wrapper is unnecessary.

##### Drop the Ghostty advertisement entirely

Set `(setq ghostel-term "xterm-256color")` to drop `TERM=xterm-ghostty`
locally.  No advertisement, no terminfo gymnastics, no synchronized
output fast-path either.

### Rendering
- Incremental redraw — only dirty rows are re-rendered
- Timer-based batched updates with adaptive frame rate
- **Immediate redraw** for interactive typing echo — small PTY output arriving shortly after a keystroke bypasses the timer, eliminating 16–33ms of latency per keypress
- **Input coalescing** — rapid keystrokes are batched into a single PTY write to reduce syscall overhead
- Cursor position updates even without cell changes
- Theme-aware color palette (syncs with Emacs theme via `ghostel-sync-theme`)

### Inline Images (Kitty Graphics Protocol)

Ghostel renders inline images using the [Kitty graphics
protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) via libghostty.
Supports both placement modes used by real-world tools:

- **Traditional placements** — `timg`, `kitty +kitten icat`, and any tool that
  emits direct kitty graphics commands.
- **Unicode-placeholder placements** (U+10EEEE) — used by `yazi` and other
  modern image previewers to anchor images to the buffer's text grid.

Pixel data is rendered through Emacs's built-in image support: PNG payloads
are decoded by a vendored stb_image, and raw RGB/RGBA/Gray/GrayAlpha
transmissions are converted to PPM in the native module — no external
ImageMagick dependency.

XTWINOPS size queries (CSI 14 / 16 / 18 t) are answered so apps can detect
graphics support and pick image dimensions; without that, `timg` falls back
to half-block rendering even when `TERM_PROGRAM=ghostty`.

Cell pixel sizes are reported as physical pixels via
`ghostel-cell-pixel-scale` (default `auto`, derived from display DPI).
On most displays this approximates standalone Ghostty's output; for
pixel-perfect parity (especially on Linux Wayland with fractional scaling
or non-standard DPI), set an explicit number.

#### Limitations

- **Alpha is dropped, not composited.** All formats — raw RGBA,
  GrayAlpha, and PNG — go through an RGBA→PPM conversion that strips
  the alpha channel (PNGs are decoded to RGBA by libghostty's PNG hook
  at transmit time, then follow the same path).  Transparent pixels
  render as whatever the underlying color value happens to be (most
  decoders emit black).  Acceptable for thumbnails and screenshots;
  not ideal for icons with semi-transparent edges.
- **Source-rect cropping is not supported.** Atlas-style placements
  that specify a sub-region of the source image (`x=`, `y=`, `w=`, `h=`
  in the kitty protocol) are refused with an explicit error rather
  than silently mis-rendering.  Full-image placements — what timg,
  yazi, and `kitty +kitten icat` use — are unaffected.
- **Multiple simultaneous virtual placements share rendering.**
  Unicode-placeholder placements that coexist in the same buffer are
  rendered as a single image; the most recent transmission wins.
  `yazi`'s preview pane uses one image at a time, so this hasn't been
  a problem in practice.
- **Non-direct mediums are off by default** for safety.  Only the
  inline (base64) medium is enabled; file / temp-file / shared-memory
  mediums are opt-in via `ghostel-kitty-graphics-mediums`.  See its
  docstring for the privilege-escalation reasoning.

### Calling Elisp from the Shell

Shell scripts running inside ghostel can call whitelisted Elisp functions
via the `ghostel_cmd` helper (provided by the shell integration scripts):

```sh
ghostel_cmd find-file "/path/to/file"
ghostel_cmd message "Hello from the shell"
```

This uses an OSC 52 escape sequence with a reserved `kind` byte
(`\e]52;e;<payload>\e\\`) — a ghostel-private extension.
Only functions listed in `ghostel-eval-cmds` are allowed.

Default whitelisted commands:

`find-file`, `find-file-other-window`, `dired`, `dired-other-window`, `message`.

Add your own with:

```elisp
(add-to-list 'ghostel-eval-cmds '("magit-status-setup-buffer" magit-status-setup-buffer))
```

Example shell aliases (add to your `.bashrc` / `.zshrc`):

```sh
if [[ "${INSIDE_EMACS%%,*}" = 'ghostel' ]]; then
    # Open a file in Emacs from the terminal
    e()   { ghostel_cmd find-file-other-window "$@"; }

    # Open dired in another window, defaulting to the current directory
    dow() { ghostel_cmd dired-other-window "${1:-$PWD}"; }

    # Open magit for the current directory
    gst() { ghostel_cmd magit-status-setup-buffer "$(pwd)"; }
fi
```

### Notifications and Progress

Ghostel recognises two notification protocols used by terminal programs:

- **OSC 9** (iTerm2 form): `ESC ] 9 ; BODY ST` — body only.
- **OSC 777** (rxvt `notify`): `ESC ] 777 ; notify ; TITLE ; BODY ST` — title + body.

Both route to `ghostel-notification-function` with `(TITLE BODY)`.  The
default handler, `ghostel-default-notify`, uses the
[alert](https://github.com/jwiegley/alert) package when installed — it
picks a sensible backend per platform (`osascript` on macOS, libnotify
on Linux, Growl, terminal-notifier, etc.) and is configurable via
`alert-default-style`.  Install it from MELPA with `M-x package-install
RET alert RET`.

When `alert` isn't available, ghostel falls back to `message`, which
only appears in the echo area.  Set `ghostel-notification-function` to
nil to silence notifications entirely, or to your own function to route
them elsewhere.

ConEmu's **OSC 9;4** progress protocol is also recognised: build tools,
AI agents like Claude Code, and other long-running commands emit it to
report completion percentage.  Ghostel dispatches these to
`ghostel-progress-function` with `(STATE PROGRESS)` where STATE is one of
`remove`, `set`, `error`, `indeterminate`, `pause` and PROGRESS is an
integer 0-100 or nil.

Two built-in handlers are available:

- `ghostel-default-progress` — plain text in `mode-line-process`:
  `[42%]`, `[...]`, `[err 73%]`, `[paused 25%]`, or cleared on
  `remove`.  Zero dependencies.
- `ghostel-spinner-progress` — animates `mode-line-process` via
  [spinner.el](https://github.com/Malabarba/spinner.el) during
  `indeterminate` (e.g. while Claude Code is working) and falls back
  to the same text indicator for the other states.

`ghostel-progress-function` defaults to `ghostel-spinner-progress` when
spinner.el is on the `load-path` at ghostel load time, otherwise to
`ghostel-default-progress`.  Pin a specific handler explicitly:

```elisp
;; Pin to spinner (errors with a hint if spinner.el isn't installed):
(setq ghostel-progress-function #'ghostel-spinner-progress)
;; Or stay on the plain text indicator:
(setq ghostel-progress-function #'ghostel-default-progress)
;; Pick a different spinner style — see `spinner-types' in spinner.el:
(setq ghostel-spinner-type 'horizontal-moving)
```

### Color Palette

The 16 ANSI colors are defined as Emacs faces inheriting from `term-color-*`:

```
ghostel-color-black         ghostel-color-bright-black
ghostel-color-red           ghostel-color-bright-red
ghostel-color-green         ghostel-color-bright-green
ghostel-color-yellow        ghostel-color-bright-yellow
ghostel-color-blue          ghostel-color-bright-blue
ghostel-color-magenta       ghostel-color-bright-magenta
ghostel-color-cyan          ghostel-color-bright-cyan
ghostel-color-white         ghostel-color-bright-white
```

Themes that customize `term-color-*` faces automatically apply. Customize
individual faces with `M-x customize-face`.

Default foreground/background are read from the `ghostel-default` face,
which inherits from `default`. Customize it to give ghostel terminals
different default colors than the rest of Emacs (e.g. a dark terminal
inside a light Emacs):

```elisp
(set-face-attribute 'ghostel-default nil
                    :foreground "#cdd6f4"
                    :background "#1e1e2e")
```

## Configuration

| Variable                         | Default              | Description                                              |
|----------------------------------|----------------------|----------------------------------------------------------|
| `ghostel-module-auto-install`    | `ask`                | What to do when native module is missing (`ask`, `download`, `compile`, `nil`) |
| `ghostel-shell`                  | `$SHELL`             | Shell program to run                                     |
| `ghostel-term`                   | `"xterm-ghostty"`    | Value of `TERM` for spawned processes.  Default uses the bundled terminfo so apps can detect ghostel's full capability set.  Set to `"xterm-256color"` to fall back (drops `TERMINFO` and `TERM_PROGRAM=ghostty` too) |
| `ghostel-environment`            | `nil`                | Extra env vars for spawned processes (list of `"KEY=VALUE"` strings). |
| `ghostel-ssh-install-terminfo`   | `auto`               | Install `xterm-ghostty` terminfo on remote hosts as needed.  `auto` follows `ghostel-tramp-shell-integration`.  Affects both TRAMP-launched ghostel (push terminfo over the existing TRAMP connection) and outbound `ssh` from a local buffer (install via `tic` on first connection, cache in `~/.cache/ghostel/ssh-terminfo-cache`).  Per-call ssh override: `GHOSTEL_SSH_KEEP_TERM=1` |
| `ghostel-tramp-shells`           | `(see below)`        | Shell to use per TRAMP method (with login-shell detection) |
| `ghostel-shell-integration`      | `t`                  | Auto-inject shell integration                            |
| `ghostel-tramp-default-method`   | `nil`                | TRAMP method for new remote paths from OSC 7 (nil uses `tramp-default-method`) |
| `ghostel-tramp-shell-integration` | `nil`               | Auto-inject shell integration for remote TRAMP sessions  |
| `ghostel-buffer-name`            | `"*ghostel*"`        | Default buffer name                                      |
| `ghostel-project-buffer-scope`   | `both`               | How `ghostel-project-{next,previous,list-buffers}` decide project membership: `default-directory`, `identity`, or `both` |
| `ghostel-max-scrollback`         | `5MB`                | Maximum scrollback size in bytes (materialized into the Emacs buffer; ~5,000 rows on 80-col terminals) |
| `ghostel-timer-delay`            | `0.033`              | Base redraw delay in seconds (~30fps)                    |
| `ghostel-adaptive-fps`           | `t`                  | Adaptive frame rate (shorter delay after idle, stop timer when idle) |
| `ghostel-immediate-redraw-threshold` | `256`            | Max output bytes to trigger immediate redraw (0 to disable) |
| `ghostel-immediate-redraw-interval`  | `0.05`           | Max seconds since last keystroke for immediate redraw    |
| `ghostel-input-coalesce-delay`   | `0.003`              | Seconds to buffer rapid keystrokes before sending (0 to disable) |
| `ghostel-full-redraw`            | `nil`                | Always do full redraws instead of incremental updates    |
| `ghostel-cell-pixel-scale`       | `auto`               | Physical:logical pixel ratio for cell-size reporting (kitty graphics, XTWINOPS).  `auto` derives from display DPI |
| `ghostel-kitty-graphics-storage-limit` | `320 MiB`      | Per-terminal cap on kitty graphics image storage.  Set to 0 to disable kitty graphics entirely (image transmissions are ignored, no storage allocated) |
| `ghostel-kitty-graphics-mediums` | `nil`                | Opt-in image-loading mediums beyond the always-enabled inline base64.  A subset of `(file temp-file shared-mem)`.  Default `nil` keeps SSH sessions safe — the non-direct mediums let a remote program instruct ghostel to read arbitrary local paths or shared memory |
| `ghostel-kill-buffer-on-exit`    | `t`                  | Kill buffer when shell exits                             |
| `ghostel-eval-cmds`              | `(see above)`        | Whitelisted functions for OSC 52;e eval                  |
| `ghostel-enable-osc52`           | `nil`                | Allow apps to set clipboard via OSC 52                   |
| `ghostel-notification-function`  | `ghostel-default-notify` | Handler for OSC 9 / OSC 777 desktop notifications (nil disables) |
| `ghostel-progress-function`      | `ghostel-default-progress` | Handler for OSC 9;4 ConEmu progress reports (nil disables) |
| `ghostel-enable-url-detection`   | `t`                  | Linkify plain-text URLs in terminal output               |
| `ghostel-enable-file-detection`  | `t`                  | Linkify file:line references in terminal output          |
| `ghostel-ignore-cursor-change`   | `nil`                | Ignore terminal-driven cursor shape/visibility changes   |
| `ghostel-keymap-exceptions`      | `("C-c" "C-x" ...)`  | Keys passed through to Emacs                             |
| `ghostel-exit-functions`         | `nil`                | Hook run when the shell process exits                    |

## Evil-mode

Ghostel includes optional `evil-mode` support via `evil-ghostel.el`.
It synchronizes the terminal cursor with Emacs point during evil state
transitions so that normal-mode navigation (`hjkl` etc.) works
correctly.

`evil-ghostel` is distributed as an independent MELPA package that
depends on `ghostel`.  Install it alongside ghostel:

```elisp
(use-package evil-ghostel
  :ensure t
  :after (ghostel evil)
  :hook (ghostel-mode . evil-ghostel-mode))
```

Or from source (Emacs 30+); `:lisp-dir` points package-vc at this
extension's subdirectory inside the ghostel monorepo:

```elisp
(use-package evil-ghostel
  :vc (:url "https://github.com/dakra/ghostel"
       :lisp-dir "extensions/evil-ghostel"
       :rev :newest)
  :after (ghostel evil)
  :hook (ghostel-mode . evil-ghostel-mode))
```

When `evil-ghostel-mode` is active:

- Ghostel starts in **insert state** (terminal input works normally)
- Pressing **ESC** enters normal state and snaps point to the terminal cursor
- Normal-mode navigation (`h`, `j`, `k`, `l`, `w`, `b`, `e`, `0`, `$`, ...) works as expected
- **Insert/append** (`i`, `a`, `I`, `A`) sync the terminal cursor to point before entering insert state
- **Delete** (`d`, `dw`, `dd`, `D`, `x`, `X`) yanks text to the kill ring and deletes via the shell
- **Change** (`c`, `cw`, `cc`, `C`, `s`, `S`) deletes then enters insert state
- **Replace** (`r`) replaces the character under the cursor
- **Paste** (`p`, `P`) pastes from the kill ring via bracketed paste
- **Undo** (`u`) sends readline undo (`Ctrl+_`)
- Cursor shape follows evil state (block for normal, bar for insert)
- Alt-screen programs (vim, less, htop) are unaffected

## Commands

| Command                        | Description                                  |
|--------------------------------|----------------------------------------------|
| `M-x ghostel`                  | Open a new terminal (create new buffer with prefix arg) |
| `M-x ghostel-project`          | Open a terminal in the current project root (create new buffer with prefix arg)  |
| `M-x ghostel-other`            | Switch to next terminal or create one        |
| `M-x ghostel-next`             | Cycle to next ghostel buffer (sorted by name, wraps) |
| `M-x ghostel-previous`         | Cycle to previous ghostel buffer             |
| `M-x ghostel-list-buffers`     | Pick a ghostel buffer via `read-buffer`      |
| `M-x ghostel-project-next`     | Cycle to next ghostel buffer in current project |
| `M-x ghostel-project-previous` | Cycle to previous ghostel buffer in current project |
| `M-x ghostel-project-list-buffers` | Pick a project-scoped ghostel buffer     |
| `M-x ghostel-clear`            | Clear screen and scrollback                  |
| `M-x ghostel-clear-scrollback` | Clear scrollback only                        |
| `M-x ghostel-semi-char-mode`   | Switch to semi-char input mode (default)     |
| `M-x ghostel-char-mode`        | Switch to char input mode                    |
| `M-x ghostel-emacs-mode`       | Switch to Emacs input mode (read-only, live) |
| `M-x ghostel-copy-mode`        | Enter copy mode (frozen)                     |
| `M-x ghostel-line-mode`        | Switch to line input mode                    |
| `M-x ghostel-copy-all`         | Copy entire scrollback to kill ring          |
| `M-x ghostel-paste`            | Paste from kill ring                         |
| `M-x ghostel-send-next-key`    | Send next key literally                      |
| `M-x ghostel-next-prompt`      | Jump to next shell prompt                    |
| `M-x ghostel-previous-prompt`  | Jump to previous shell prompt                |
| `M-x ghostel-next-hyperlink`   | Jump to next hyperlink (OSC 8, URL, file ref) |
| `M-x ghostel-previous-hyperlink` | Jump to previous hyperlink                 |
| `M-x ghostel-force-redraw`     | Force a full terminal redraw                 |
| `M-x ghostel-debug-typing-latency` | Measure per-keystroke typing latency     |
| `M-x ghostel-sync-theme`       | Re-sync color palette after theme change     |
| `M-x ghostel-ssh-clear-terminfo-cache` | Clear outbound-ssh terminfo install cache (force re-probe) |
| `M-x ghostel-download-module`  | Download pre-built native module             |
| `M-x ghostel-module-compile`   | Compile native module from source            |

### Sending input from Lisp

For packages that need to inject input into a running ghostel buffer
(agent integrations, custom keymaps, Swerty-style bindings, …) two
public functions are provided:

```elisp
(ghostel-send-string "ls -la\n")      ; send raw bytes, newline included
(ghostel-send-key "return")           ; send a named key through the encoder
(ghostel-send-key "a" "ctrl")         ; C-a — respects the current terminal mode
(ghostel-send-key "up" "shift,ctrl")  ; modifiers are comma-separated
```

Both operate on the current buffer; wrap in `with-current-buffer`
when driving another ghostel buffer.  Calling either outside a
ghostel buffer signals a `user-error`.

### Project integration

`ghostel-project` opens a terminal in the current project's root directory
with a project-prefixed buffer name.  To make it available from
`project-switch-project` (`C-x p p`):

```elisp
(add-to-list 'project-switch-commands '(ghostel-project "Ghostel") t)
```

### Compilation mode

`ghostel-compile` runs a shell command in a ghostel buffer and presents
the result like `M-x compile` — `compilation-mode`-style header,
footer, error highlighting, and `next-error` navigation — but backed by
a real TTY so programs that probe `isatty(3)` (coloured output, progress
bars, curses tools) behave as they do in a normal shell.

Each invocation spawns a fresh process via
`shell-file-name -c COMMAND` through a PTY owned by the ghostel
renderer — no interactive shell sits between the command and the
user, so multi-line shell scripts are passed through verbatim and
no shell-integration setup is required.  The process sentinel
delivers the real exit status.

`ghostel-compile` inherits the same `TERM=xterm-ghostty` and
`TERMINFO=...` env as `M-x ghostel`, so build output gets
synchronized output, true color, etc.  If a test runner or build
tool gets confused by the unfamiliar `TERM`, set
`(setq ghostel-term "xterm-256color")`.

```elisp
(require 'ghostel-compile)

(global-set-key (kbd "C-c c") #'ghostel-compile)
```

Commands:

| Command                       | Description                                                                |
|-------------------------------|----------------------------------------------------------------------------|
| `M-x ghostel-compile`         | Run a command in a read-only ghostel buffer (uses `compile-command`)       |
| `C-u M-x ghostel-compile`     | Prompt for the command and run it in an *interactive* (writable) buffer    |
| `M-x ghostel-recompile`       | Re-run the last command in its original directory (preserves launch mode)  |
| `M-x ghostel-compile-global-mode` | Route *all* `compile`-style calls through ghostel (opt-in)             |

What a run looks like — the buffer text matches `M-x compile`:

```
-*- mode: ghostel-compile -*-
Compilation started at Wed Apr 15 08:30:11

make -j4 test

...command output (live, with full TTY)...

Compilation finished at Wed Apr 15 08:30:19, duration 8.20 s
```

By default the buffer is **read-only and navigable from the start** —
just like a `M-x compile` buffer.  `g` reruns, `n`/`p` walk errors
(parsed once the run finishes), `RET` jumps to the source.
Keystrokes do *not* reach the running process, so the
"compile-mode" UX (read coloured output, kill with `C-c C-c`) is
available even mid-run.

Pass a prefix arg (`C-u M-x ghostel-compile`, mirroring
`C-u M-x compile`) to launch in **interactive** mode instead — the
buffer stays writable for the duration of the run, so programs like
`htop`, `less`, test runners that prompt for input, or anything that
wants live keystrokes work.  `ghostel-recompile` (`g`) preserves
whichever mode the buffer was launched in.

When the command finishes, the live process and ghostel renderer are
torn down and the buffer's major mode is switched to
`ghostel-compile-view-mode` (derived from `compilation-mode`).  The
buffer becomes a regular, read-only Emacs buffer with compile-mode's
coloured error / line-number faces; the buffer never returns to an
interactive ghostel terminal — a recompile discards it and starts
fresh in the original directory.  `mode-line-process` shows
`:run` while the command is running and `:exit [N]` afterwards, using
the same faces `M-x compile` uses.  In an interactive run the marker
reads `:run/i` instead of `:run` so you can see at a glance that the
buffer accepts keystrokes.

#### Live mode switching

Sometimes a command turns out to need input — a `read -p`, a `git
push` password prompt, a test runner asking `y/n`, or you'd like
to attach to `htop` mid-run.  Two keys switch the buffer's state
without restarting the process:

| Key                   | Action                                          |
|-----------------------|-------------------------------------------------|
| `C-c C-j`             | Switch to interactive (writable terminal)       |
| `C-c C-e` / `C-c C-t` | Switch back to read-only / compile-mode-style   |

(`C-c C-t` mirrors `ghostel-mode`'s key for entering copy-mode —
the read-only/navigable state in a regular ghostel terminal — so
the same muscle memory works in compile buffers.)

Both keys are bound by `ghostel-compile-toggle-mode`, a small
buffer-local minor mode auto-enabled in compile buffers (so the
keys don't show up in regular `M-x ghostel` terminals).  They work
in either run state — the minor-mode keymap takes precedence, so
your keystrokes are intercepted before they reach the PTY.

Subsequent recompiles preserve whichever state you last switched
to.  After the run finishes the keys remain bound; calling them
on a finished buffer is a no-op with a "recompile with `g`
instead" message.

#### Keybindings (in `ghostel-compile-view-mode`, also active during a read-only run)

| Key             | Action                                                  |
|-----------------|---------------------------------------------------------|
| `g`             | Re-run via `ghostel-recompile`                          |
| `n` / `p`       | Move point to next / previous error (no auto-open)      |
| `RET` / `mouse-2` | Jump to the source of the error under point           |
| `M-g n` / `M-g p` | Standard `next-error` / `previous-error`              |
| `C-c C-c`       | `compile-goto-error` (same as RET)                      |
| `C-c C-k`       | `kill-compilation` — interrupt the running process      |
| `C-c C-j` / `C-c C-e` / `C-c C-t` | Switch to interactive / read-only (see above) |

These standard `compile` options are honoured:

- **`compile-command` / `compile-history`** — shared with `M-x compile`.
  The prompt defaults to `compile-command`, the chosen command is
  written back, and the history list is `compile-history`, so recent
  commands round-trip between the two commands.
- **`compilation-read-command`** — when nil, `ghostel-compile` runs
  `compile-command` silently; pass any prefix arg to force the
  prompt.  The universal prefix (`C-u`) additionally switches the
  buffer into interactive (writable) mode, mirroring
  `C-u M-x compile`.
- **`compilation-ask-about-save`** — modified buffers are offered for
  saving before launching.
- **`compilation-auto-jump-to-first-error`** — jumps to the first error
  after parsing.
- **`compilation-finish-functions`** — runs with `(buffer msg)` just
  like with `M-x compile`.
- Output scrolling is always on (terminal behaviour — equivalent to
  `compilation-scroll-output` non-nil).

`ghostel-recompile` runs in the directory the original `ghostel-compile`
was invoked from, regardless of which buffer you're in when you press `g`.

#### Make `compile` / `recompile` / `project-compile` use ghostel

Enable `ghostel-compile-global-mode` to advise `compilation-start`
so every caller that goes through it — `M-x compile`,
`M-x recompile`, `M-x project-compile`, and any third-party command
that uses `compilation-start` under the hood — runs in a ghostel
buffer automatically.

```elisp
(require 'ghostel-compile)
(ghostel-compile-global-mode 1)
```

How calls are routed:

- Plain `M-x compile` (or any caller passing `MODE=nil`,
  `compilation-mode`, or a `compilation-mode` subclass) → **read-only**
  ghostel buffer (the compile-style default).  A subclass is
  honoured: its error-regexp, font-lock keywords, and keymap take
  effect when the buffer is finalized.
- `C-u M-x compile` (i.e. `compilation-start COMMAND t`, the comint
  variant) → **interactive** ghostel buffer instead of stock
  `comint-mode`.  You still get a real TTY for the command, just
  with the writable behaviour the caller asked for.
- `grep-mode` falls through to the stock `compilation-start`
  implementation, because its output parsing and window-management
  conventions don't fit a live TTY.  Extend
  `ghostel-compile-global-mode-excluded-modes` to opt other modes out.

Ghostel-specific customisation:

| Option                                       | Effect                                                                                                             |
|----------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `ghostel-compile-buffer-name`                | Buffer name (default `*ghostel-compile*`)                                                                          |
| `ghostel-compile-finished-major-mode`        | Major mode to switch to after each run (default `ghostel-compile-view-mode`; set to nil to stay in `ghostel-mode`) |
| `ghostel-compile-finish-functions`           | Ghostel-specific finish hook (runs alongside `compilation-finish-functions`)                                       |
| `ghostel-compile-global-mode-excluded-modes` | Modes for which the global advice falls through to stock `compile` (default `(grep-mode)`)                         |
| `ghostel-compile-debug`                      | Log lifecycle events to `*Messages*` (default `nil`)                                                               |

#### Hooks for your own integrations

Outside of a compile buffer, two hooks let you react to *any* shell
command in *any* ghostel buffer:

- `ghostel-command-start-functions` — called with `(BUFFER)` when the
  shell emits OSC 133 `C` (a command starts running).
- `ghostel-command-finish-functions` — called with `(BUFFER EXIT-STATUS)`
  when the shell emits OSC 133 `D` (a command finishes).

Errors raised by individual hook functions are caught and logged so
one bad consumer can't break the rest.

### Eshell integration

`ghostel-eshell-visual-command-mode` makes eshell run "visual" commands
— programs in `eshell-visual-commands`, `eshell-visual-subcommands`,
and `eshell-visual-options` (vim, htop, less, top, `git log`'s pager,
…) — inside a dedicated ghostel buffer instead of the default
`term-mode` fallback, so they get a real terminal emulator.

```elisp
(require 'ghostel-eshell)
(add-hook 'eshell-load-hook #'ghostel-eshell-visual-command-mode)
```

When the program exits, the buffer stays on `[Process exited]` so
you can read any remaining output (window point snaps to the end so
it's visible without scrolling).  Press `q` to dismiss the dead
buffer.  Set `eshell-destroy-buffer-when-process-dies` to `t` to
kill the buffer automatically on exit instead.

To run an ad-hoc command in a ghostel buffer without editing
`eshell-visual-commands`, use the `ghostel` eshell built-in:

```
~ $ ghostel nethack
```

Add a shorter alias if you like:

```elisp
(defalias 'eshell/v 'eshell/ghostel)    ;; then:  ~ $ v nethack
```

Customisation:

| Option                       | Effect                                                                                                                    |
|------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `ghostel-eshell-track-title` | When non-nil, let programs rename the visual-command buffer via OSC title escapes.  Default `nil` (keeps `*vim*` stable). |

The public primitive behind the mode is `ghostel-exec BUFFER PROGRAM
&optional ARGS`, which launches an arbitrary program in a ghostel
buffer with no shell integration applied.  Useful for building your
own integrations.

### Comint integration

`ghostel-comint-mode` replaces comint's built-in
`ansi-color-process-output` with a stream filter that runs every
chunk of process output through libghostty-vt's VT parser.  In
`M-x shell` (and any other comint-derived buffer — REPLs, etc.)
output renders with the same SGR fidelity a real ghostel terminal
would give it, plus OSC 8 hyperlinks and OSC 7 directory tracking.

```elisp
(require 'ghostel-comint)
(add-hook 'shell-mode-hook #'ghostel-comint-mode)
```

Or, to enable it for every comint-derived buffer at once:

```elisp
(ghostel-comint-global-mode 1)
```

What you get over the stock filter (and xterm-color):

| Feature                                                   | Stock `ansi-color` | xterm-color | `ghostel-comint` |
|-----------------------------------------------------------|--------------------|-------------|------------------|
| ANSI 8 / bright / 256 / truecolor                         | ✓                  | ✓           | ✓                |
| Italic, bold, faint, strike-through, overline, inverse    | partial            | ✓           | ✓                |
| Curly / double / dotted / dashed underline (`\e[4:3m`, …) |                    |             | ✓                |
| Underline color (`\e[58;...m`)                            |                    |             | ✓                |
| OSC 8 hyperlinks (`gh`, `git`, `ls --hyperlink=auto`)     |                    |             | ✓                |
| OSC 7 working-directory updates                           |                    |             | ✓                |
| DCS / APC / SS3 sequences consumed cleanly                |                    |             | ✓                |

It's still a stream filter — *not* a full terminal.  Cursor-positioning
escapes, alt-screen entry (`\e[?1049h`), and full-screen redraws are
silently dropped: programs like `htop` or `less` won't render
correctly under it.  Use `M-x ghostel` (a real terminal) for those.

CR / BS / TAB pass through unchanged so comint's own
`comint-carriage-motion` filter continues to handle progress bars,
`read -s` prompts, etc.

For best performance, xterm-color's advice to disable font-locking in
shell buffers applies here too — see the docstring of
`ghostel-comint-mode`.

## Running Tests

Tests use ERT.  The Makefile provides convenient targets:

```sh
make test        # pure Elisp tests (no native module required)
make all         # build + test + lint
make bench-quick # quick benchmark sanity check
```

You can also run tests directly:

```sh
# Pure Elisp tests (no native module required)
emacs --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run-elisp

# Full test suite (requires built native module)
emacs --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run
```

## Performance

Ghostel includes a benchmark suite comparing throughput against other Emacs
terminal emulators: [vterm](https://github.com/akermu/emacs-libvterm) (native
module), [eat](https://codeberg.org/akib/emacs-eat) (pure Elisp), and Emacs
built-in `term`.

The primary benchmark streams 1 MB of data through a real process pipe,
matching actual terminal usage.  All backends are configured with ~1,000
lines of scrollback (matching vterm's default).  Results on Apple M4 Max,
Emacs 31.0.50:

| Backend              | Plain ASCII | URL-heavy |
|----------------------|------------:|----------:|
| ghostel              |    81 MB/s  |  77 MB/s  |
| ghostel (no detect)  |    78 MB/s  |  75 MB/s  |
| vterm                |    34 MB/s  |  28 MB/s  |
| eat                  |   4.9 MB/s  | 3.8 MB/s  |
| term                 |   5.8 MB/s  | 4.9 MB/s  |

Ghostel scans terminal output for URLs and file paths, making them clickable.
Detection runs on a coalesced timer outside the redraw hot path, so enabling
it costs essentially nothing on the streaming throughput — the "no detect"
row shows what you get with `ghostel-enable-url-detection` and
`ghostel-enable-file-detection` set to nil.  The other emulators do not have
this feature.

### Typing latency

Interactive keystrokes are optimized separately from bulk throughput.  When
you type a character, the PTY echo is detected and rendered immediately
(bypassing the 33ms redraw timer), so the character appears on screen with
minimal delay.  Use `M-x ghostel-debug-typing-latency` to measure the
end-to-end latency on your system — it reports per-keystroke PTY, render,
and total latency with min/median/p99/max statistics.

Run the benchmarks yourself:

```sh
bench/run-bench.sh              # full suite (throughput)
bench/run-bench.sh --quick      # quick sanity check
```

The typing latency benchmark can be run from Elisp:

```elisp
(require 'ghostel-debug)
M-x ghostel-debug-typing-latency    ; interactive measurement
```

## Ghostel vs vterm

Both ghostel and [vterm](https://github.com/akermu/emacs-libvterm) are native
module terminal emulators for Emacs.  Ghostel uses
[libghostty-vt](https://ghostty.org/) (Zig) as its VT engine; vterm uses
[libvterm](https://www.leonerd.org.uk/code/libvterm/) (C), the same library
powering Neovim's built-in terminal.

### Feature comparison

| Feature                       | ghostel  | vterm    |
|-------------------------------|----------|----------|
| True color (24-bit)           | ✅       | ✅       |
| OSC 4/10/11 color queries     | ✅       | ❌       |
| Bold / italic / faint         | ✅       | ✅       |
| Underline styles (5 types)    | ✅       | ❌       |
| Underline color               | ✅       | ❌       |
| Strikethrough                 | ✅       | ✅       |
| Cursor styles                 | 4 types  | 3 types  |
| OSC 8 hyperlinks              | ✅       | ❌       |
| Plain-text URL/file detection | ✅       | ❌       |
| OSC 9 / 777 notifications     | ✅       | ❌       |
| OSC 9;4 progress reports      | ✅       | ❌       |
| Kitty graphics protocol       | ✅       | ❌       |
| Kitty keyboard protocol       | ✅       | ❌       |
| Mouse passthrough (SGR)       | ✅       | ❌       |
| Bracketed paste               | ✅       | ✅       |
| Alternate screen              | ✅       | ✅       |
| Shell integration auto-inject | ✅       | ❌       |
| Prompt navigation (OSC 133)   | ✅       | ✅       |
| Elisp eval from shell         | ✅       | ✅       |
| TRAMP remote terminals        | ✅       | ✅       |
| OSC 52 clipboard              | ✅       | ✅       |
| Copy mode                     | ✅       | ✅       |
| Char mode (runtime toggle)    | ✅       | ❌       |
| Line mode (local editing)     | ✅       | ❌       |
| Emacs mode (read-only, live)  | ✅       | ❌       |
| Drag-and-drop                 | ✅       | ❌       |
| Password prompt detection     | ✅       | ❌       |
| Auto module download          | ✅       | ❌       |
| Scrollback default            | ~5,000   | 1,000    |
| PTY throughput (plain ASCII)  | 81 MB/s  | 34 MB/s  |
| Default redraw rate           | ~30 fps   | ~10 fps |

### Key differences

**Terminal engine.**  libghostty-vt comes from
[Ghostty](https://ghostty.org/), a modern GPU-accelerated terminal, and
supports Kitty keyboard/mouse protocols, rich underline styles, and OSC 8
hyperlinks.  libvterm targets VT220/xterm emulation and is more conservative
in protocol support.

**Mouse handling.**  Ghostel encodes mouse events (press, release, drag) and
passes them through to the terminal via SGR mouse protocol.  TUI apps like
htop or lazygit receive full mouse input.  vterm intercepts mouse clicks for
Emacs point movement and does not forward them to the terminal.

**Input modes.**  Ghostel offers five eat.el-style input modes (semi-char,
char, Emacs, copy, line) selected from a single base keymap; see the
[Input modes](#input-modes) section above.  vterm's default mode is
roughly equivalent to ghostel's semi-char (a similar set of reserved
prefixes via `vterm-keymap-exceptions`), and `vterm-copy-mode` lines up
with our copy mode — both freeze incoming output (vterm via XOFF flow
control, ghostel by cancelling the redraw timer).  Three of ghostel's
modes have no vterm equivalent: **line mode** buffers input locally so
full Emacs editing (`M-b`, `M-DEL`, yank, `transpose-words`, history
ring) works on the in-progress line and `RET` sends it atomically;
**Emacs mode** keeps the terminal streaming live but locks the buffer
read-only, so `isearch`, `occur`, `M-x flush-lines`, and the rest of
Emacs's vocabulary work over the live log without freezing it; **char
mode** is a runtime toggle that bypasses the keymap exceptions and
forwards every key (including `C-c`, `C-x`, `M-x`) to the terminal — vterm
requires editing `vterm-keymap-exceptions` and reloading the buffer to
get the same effect.

**Rendering.**  Both use text properties (not overlays) and batch consecutive
cells with identical styles.  Ghostel's engine provides three-level dirty
tracking (none / partial / full) with per-row granularity.  vterm uses
damage-rectangle callbacks and redraws entire invalidated rows.  Ghostel
defaults to ~30 fps redraw; vterm defaults to ~10 fps.

**Shell integration.**  Ghostel auto-injects shell integration scripts for
bash, zsh, and fish — no shell RC changes needed.  vterm requires manually
sourcing scripts in your shell configuration.  Both support Elisp eval from
the shell and TRAMP-aware remote directory tracking.

**Password prompts.**  Ghostel detects when the foreground program is reading
a password (`sudo`, `ssh`, `gpg`, …) and prompts via `read-passwd`, sending
the answer down the PTY without routing keystrokes through Emacs's normal
key pipeline.  vterm has no such interception: each character of your
password is a regular keypress, so it ends up in `view-lossage`, the
recent-keys ring, and anything else that observes the key pipeline (e.g.
keyboard macros being recorded).  Ghostel's hook also lets you plug in
`auth-source` to satisfy known prompts without typing — see
[Password prompt detection](#password-prompt-detection) above.

**Performance.**  In PTY throughput benchmarks (1 MB streamed through `cat`,
both backends configured with ~1,000 lines of scrollback), ghostel is
roughly 2.4x faster than vterm on plain ASCII data (81 vs 34 MB/s).  On
URL-heavy output ghostel pulls further ahead of vterm (77 vs 28 MB/s);
plain-text link detection is deferred to a coalesced post-redraw timer,
so enabling it has essentially no cost on the streaming path.  See the
[Performance](#performance) section above for full numbers and how to run
the benchmark suite yourself.

**Installation.**  Ghostel can automatically download a pre-built native
module or compile from source with [Zig](https://ziglang.org/).  vterm uses
CMake with a single C dependency (libvterm) and can auto-compile on first
load from Elisp.

For a detailed architectural comparison, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Architecture

```
ghostel.el          Elisp: keymap, process management, mode, commands
src/module.zig      Entry point: emacs_module_init, function registration
src/terminal.zig    Terminal struct wrapping ghostty handles
src/Renderer.zig    RenderState -> Emacs buffer with styled text
src/input.zig       Key and mouse encoding via ghostty encoders
src/emacs.zig       Zig wrapper for the Emacs module C API
```

## License

GPL-3.0-or-later
