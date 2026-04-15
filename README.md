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
- [Running Tests](#running-tests)
- [Performance](#performance)
- [Ghostel vs vterm](#ghostel-vs-vterm)
- [Architecture](#architecture)
- [License](#license)

## Requirements

- Emacs 27.1+ with dynamic module support
- macOS or Linux

The native module is **automatically downloaded** on first use.  Pre-built
binaries are available for:

- `aarch64-macos` (Apple Silicon)
- `x86_64-macos` (Intel Mac)
- `x86_64-linux`
- `aarch64-linux`

If you prefer to build from source or need a different platform, you'll also need
[Zig](https://ziglang.org/) 0.15.2+ (see [Building from source](#building-from-source)).

## Installation

### MELPA

```elisp
(use-package ghostel
  :ensure t)
```

### use-package with vc (Emacs 30+)

```elisp
(use-package ghostel
  :vc (:url "https://github.com/dakra/ghostel" :rev :newest))
```

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
Ghostel vendors a generated `include/emacs-module.h`, so normal builds do not
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
[[ "$INSIDE_EMACS" = 'ghostel' ]] && source "$EMACS_GHOSTEL_PATH/etc/ghostel.bash"
```

**zsh** — add to `~/.zshrc`:
```zsh
[[ "$INSIDE_EMACS" = 'ghostel' ]] && source "$EMACS_GHOSTEL_PATH/etc/ghostel.zsh"
```

**fish** — add to `~/.config/fish/config.fish`:
```fish
test "$INSIDE_EMACS" = 'ghostel'; and source "$EMACS_GHOSTEL_PATH/etc/ghostel.fish"
```
</details>

## Key Bindings

### Terminal mode

| Key         | Action                                 |
|-------------|----------------------------------------|
| Most keys   | Sent directly to the terminal          |
| `C-c C-c`   | Send interrupt (C-c)                   |
| `C-c C-z`   | Send suspend (C-z)                     |
| `C-c C-d`   | Send EOF (C-d)                         |
| `C-c C-\`   | Send quit (C-\)                        |
| `C-c C-t`   | Enter copy mode                        |
| `C-c M-w`   | Copy entire scrollback to kill ring    |
| `C-y`       | Yank from kill ring (bracketed paste)  |
| `M-y`       | Yank-pop (cycle through kill ring)     |
| `C-c C-y`   | Paste from kill ring                   |
| `C-c C-l`   | Clear scrollback                       |
| `C-c C-n`   | Jump to next prompt                    |
| `C-c C-p`   | Jump to previous prompt                |
| `C-c C-q`   | Send next key literally (escape hatch) |
| Mouse wheel | Scroll through scrollback              |

Keys listed in `ghostel-keymap-exceptions` (default: `C-c`, `C-x`, `C-u`,
`C-h`, `C-g`, `M-x`, `M-o`, `M-:`, `C-\`) pass through to Emacs.

### Copy mode

Enter with `C-c C-t`. Standard Emacs navigation works.
Normal letter keys exit copy mode and send the key to the terminal.

| Key           | Action                           |
|---------------|----------------------------------|
| `C-SPC`       | Set mark                         |
| `M-w` / `C-w` | Copy selection and exit          |
| `C-n` / `C-p` | Move line (scrolls at edges)     |
| `M-v` / `C-v` | Scroll page up / down            |
| `M-<` / `M->` | Jump to top / bottom of buffer   |
| `C-c C-n`     | Jump to next prompt              |
| `C-c C-p`     | Jump to previous prompt          |
| `C-l`         | Recenter viewport                |
| `C-c C-t`     | Exit without copying             |
| `a`–`z`       | Exit and send key to terminal    |

Soft-wrapped newlines are automatically stripped from copied text.

The full scrollback is always rendered into the buffer as styled text,
so `isearch`, `consult-line`, `occur`, `M-x flush-lines`, `C-x h` to
select all, and any other buffer-based command work across the full
history — even outside copy mode.

## Features

### Terminal Emulation
- Full VT terminal emulation via libghostty-vt
- 256-color and RGB (24-bit true color) support
- **OSC 4 / 10 / 11 color queries** — TUI programs can query the current palette, foreground, and background colors, so tools like `duf`, `btop`, `delta`, and anything else using `termenv` auto-detect the right light/dark theme from the Emacs face colors
- Text attributes: bold, italic, faint, underline (single/double/curly/dotted/dashed with color), strikethrough, inverse
- Cursor styles: block, bar, underline, hollow block
- Alternate screen buffer (for TUI apps like htop, vim, etc.)
- Scrollback buffer (configurable, default 5 MB (~5,000 lines), materialized into the Emacs buffer so `isearch`/`consult-line` work over history)

### Links and File Detection
- **OSC 8 hyperlinks** — clickable URLs emitted by terminal programs (click or `RET` to open)
- **Plain-text URL detection** — automatically linkifies `http://` and `https://` URLs even without OSC 8 (toggle with `ghostel-enable-url-detection`)
- **File path detection** — patterns like `/path/to/file.el:42` become clickable, opening the file at the given line (toggle with `ghostel-enable-file-detection`)

### Clipboard
- **OSC 52 clipboard** — terminal programs can set the Emacs kill ring and system clipboard (opt-in via `ghostel-enable-osc52`, useful for remote SSH sessions)
- **Bracketed paste** — yank from kill ring sends text as a bracketed paste so shells handle it correctly

### Input
- Full keyboard input with Ghostty key encoder (respects terminal modes, Kitty keyboard protocol)
- Mouse tracking (press, release, drag) via SGR mouse protocol — TUI apps receive full mouse input
- Focus events gated by DEC mode 1004
- Drag-and-drop (file paths and text)

### Shell Integration
- Automatic injection for bash, zsh, and fish — no shell RC edits needed
- **OSC 7** — directory tracking (`default-directory` follows the shell's cwd, TRAMP-aware for remote hosts)
- **OSC 133** — semantic prompt markers, enabling prompt-to-prompt navigation with `C-c C-n` / `C-c C-p`
- **OSC 2** — title tracking (buffer is renamed from the terminal title)
- **OSC 51** — call whitelisted Emacs functions from shell scripts (see [Calling Elisp from the Shell](#calling-elisp-from-the-shell))
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

Copy the integration scripts from ghostel's `etc/` directory to each
remote host (e.g. `~/.local/share/ghostel/`) and source them from
your shell configuration:

**bash** — add to `~/.bashrc` on the remote host:
```bash
[[ "$INSIDE_EMACS" = 'ghostel' ]] && source ~/.local/share/ghostel/ghostel.bash
```

**zsh** — add to `~/.zshrc` on the remote host:
```zsh
[[ "$INSIDE_EMACS" = 'ghostel' ]] && source ~/.local/share/ghostel/ghostel.zsh
```

**fish** — add to `~/.config/fish/config.fish` on the remote host:
```fish
test "$INSIDE_EMACS" = 'ghostel'; and source ~/.local/share/ghostel/ghostel.fish
```

The integration scripts provide directory tracking (OSC 7), prompt
navigation (OSC 133), and `ghostel_cmd` for calling Elisp from the shell.

### Rendering
- Incremental redraw — only dirty rows are re-rendered
- Timer-based batched updates with adaptive frame rate
- **Immediate redraw** for interactive typing echo — small PTY output arriving shortly after a keystroke bypasses the timer, eliminating 16–33ms of latency per keypress
- **Input coalescing** — rapid keystrokes are batched into a single PTY write to reduce syscall overhead
- Cursor position updates even without cell changes
- Theme-aware color palette (syncs with Emacs theme via `ghostel-sync-theme`)

### Calling Elisp from the Shell

Shell scripts running inside ghostel can call whitelisted Elisp functions
via the `ghostel_cmd` helper (provided by the shell integration scripts):

```sh
ghostel_cmd find-file "/path/to/file"
ghostel_cmd message "Hello from the shell"
```

This uses OSC 51 escape sequences (the same protocol as vterm).  Only
functions listed in `ghostel-eval-cmds` are allowed.

Default whitelisted commands:

`find-file`, `find-file-other-window`, `dired`, `dired-other-window`, `message`.

Add your own with:

```elisp
(add-to-list 'ghostel-eval-cmds '("magit-status-setup-buffer" magit-status-setup-buffer))
```

Example shell aliases (add to your `.bashrc` / `.zshrc`):

```sh
if [[ "$INSIDE_EMACS" = 'ghostel' ]]; then
    # Open a file in Emacs from the terminal
    e()   { ghostel_cmd find-file-other-window "$@"; }

    # Open dired in another window, defaulting to the current directory
    dow() { ghostel_cmd dired-other-window "${1:-$PWD}"; }

    # Open magit for the current directory
    gst() { ghostel_cmd magit-status-setup-buffer "$(pwd)"; }
fi
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

## Configuration

| Variable                         | Default              | Description                                              |
|----------------------------------|----------------------|----------------------------------------------------------|
| `ghostel-module-auto-install`    | `ask`                | What to do when native module is missing (`ask`, `download`, `compile`, `nil`) |
| `ghostel-shell`                  | `$SHELL`             | Shell program to run                                     |
| `ghostel-tramp-shells`           | `(see below)`        | Shell to use per TRAMP method (with login-shell detection) |
| `ghostel-shell-integration`      | `t`                  | Auto-inject shell integration                            |
| `ghostel-tramp-default-method`   | `nil`                | TRAMP method for new remote paths from OSC 7 (nil uses `tramp-default-method`) |
| `ghostel-tramp-shell-integration` | `nil`               | Auto-inject shell integration for remote TRAMP sessions  |
| `ghostel-buffer-name`            | `"*ghostel*"`        | Default buffer name                                      |
| `ghostel-max-scrollback`         | `5MB`                | Maximum scrollback size in bytes (materialized into the Emacs buffer; ~5,000 rows on 80-col terminals) |
| `ghostel-timer-delay`            | `0.033`              | Base redraw delay in seconds (~30fps)                    |
| `ghostel-adaptive-fps`           | `t`                  | Adaptive frame rate (shorter delay after idle, stop timer when idle) |
| `ghostel-immediate-redraw-threshold` | `256`            | Max output bytes to trigger immediate redraw (0 to disable) |
| `ghostel-immediate-redraw-interval`  | `0.05`           | Max seconds since last keystroke for immediate redraw    |
| `ghostel-input-coalesce-delay`   | `0.003`              | Seconds to buffer rapid keystrokes before sending (0 to disable) |
| `ghostel-full-redraw`            | `nil`                | Always do full redraws instead of incremental updates    |
| `ghostel-kill-buffer-on-exit`    | `t`                  | Kill buffer when shell exits                             |
| `ghostel-eval-cmds`              | `(see above)`        | Whitelisted functions for OSC 51 eval                    |
| `ghostel-enable-osc52`           | `nil`                | Allow apps to set clipboard via OSC 52                   |
| `ghostel-enable-url-detection`   | `t`                  | Linkify plain-text URLs in terminal output               |
| `ghostel-enable-file-detection`  | `t`                  | Linkify file:line references in terminal output          |
| `ghostel-ignore-cursor-change`   | `nil`                | Ignore terminal-driven cursor shape/visibility changes   |
| `ghostel-keymap-exceptions`      | `("C-c" "C-x" ...)` | Keys passed through to Emacs                             |
| `ghostel-exit-functions`         | `nil`                | Hook run when the shell process exits                    |

## Evil-mode

Ghostel includes optional `evil-mode` support via `evil-ghostel.el`.
It synchronizes the terminal cursor with Emacs point during evil state
transitions so that normal-mode navigation (`hjkl` etc.) works
correctly.

To enable:

```elisp
(use-package evil-ghostel
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
| `M-x ghostel-clear`            | Clear screen and scrollback                  |
| `M-x ghostel-clear-scrollback` | Clear scrollback only                        |
| `M-x ghostel-copy-mode`        | Enter copy mode                              |
| `M-x ghostel-copy-all`         | Copy entire scrollback to kill ring          |
| `M-x ghostel-paste`            | Paste from kill ring                         |
| `M-x ghostel-send-next-key`    | Send next key literally                      |
| `M-x ghostel-next-prompt`      | Jump to next shell prompt                    |
| `M-x ghostel-previous-prompt`  | Jump to previous shell prompt                |
| `M-x ghostel-force-redraw`     | Force a full terminal redraw                 |
| `M-x ghostel-debug-typing-latency` | Measure per-keystroke typing latency     |
| `M-x ghostel-sync-theme`       | Re-sync color palette after theme change     |
| `M-x ghostel-download-module`  | Download pre-built native module             |
| `M-x ghostel-module-compile`   | Compile native module from source            |

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

```elisp
(require 'ghostel-compile)

(global-set-key (kbd "C-c c") #'ghostel-compile)
```

Commands:

| Command                 | Description                                         |
|-------------------------|-----------------------------------------------------|
| `M-x ghostel-compile`   | Prompt for a command and run it (uses `compile-command`) |
| `M-x ghostel-recompile` | Re-run the last command in its original directory   |

What a run looks like — the buffer text matches `M-x compile`:

```
-*- mode: ghostel-compile -*-
Compilation started at Wed Apr 15 08:30:11

make -j4 test

...command output (live, with full TTY)...

Compilation finished at Wed Apr 15 08:30:19, duration 8.20 s
```

When the command finishes, the live shell and ghostel renderer are torn
down and the buffer's major mode is switched to `ghostel-compile-view-mode`
(derived from `compilation-mode`).  The buffer becomes a regular,
read-only Emacs buffer with compile-mode's coloured error / line-number
faces; the buffer never returns to an interactive ghostel terminal —
a recompile discards it and starts fresh in the original directory.
Point stays at the end of the output (where the renderer left it) so
you see the latest output and the footer rather than jumping to the
top.  `mode-line-process` shows `:run` while the command is running
and `:exit [N]` afterwards, using the same faces `M-x compile` uses.

Keybindings (in `ghostel-compile-view-mode`):

| Key             | Action                                                  |
|-----------------|---------------------------------------------------------|
| `g`             | Re-run via `ghostel-recompile`                          |
| `n` / `p`       | Move point to next / previous error (no auto-open)      |
| `RET` / `mouse-2` | Jump to the source of the error under point           |
| `M-g n` / `M-g p` | Standard `next-error` / `previous-error`              |
| `C-c C-c`       | `compile-goto-error` (same as RET)                      |

These standard `compile` options are honoured:

- **`compile-command` / `compile-history`** — shared with `M-x compile`.
  The prompt defaults to `compile-command`, the chosen command is
  written back, and the history list is `compile-history`, so recent
  commands round-trip between the two commands.
- **`compilation-read-command`** — when nil, `ghostel-compile` runs
  `compile-command` silently; pass a prefix arg to force the prompt.
- **`compilation-ask-about-save`** — modified buffers are offered for
  saving before launching.
- **`compilation-auto-jump-to-first-error`** — jumps to the first error
  after parsing.
- **`compilation-finish-functions`** — runs with `(buffer msg)` just
  like with `M-x compile`.
- Output scrolling is always on (terminal behaviour — equivalent to
  `compilation-scroll-output` non-nil).

`ghostel-recompile` runs in the directory the original `ghostel-compile`
was invoked from, regardless of which buffer you're in when you press
`g`.

Ghostel-specific customisation:

| Option                                | Effect                                                                                                          |
|---------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| `ghostel-compile-buffer-name`         | Buffer name (default `*ghostel-compile*`)                                                                        |
| `ghostel-compile-finished-major-mode` | Major mode to switch to after each run (default `ghostel-compile-view-mode`; set to nil to stay in `ghostel-mode`) |
| `ghostel-compile-hide-prompts`        | Hide surrounding shell prompts (default `t`)                                                                     |
| `ghostel-compile-clear-buffer`        | Clear the buffer before each run (default `t`)                                                                   |
| `ghostel-compile-finish-functions`    | Ghostel-specific finish hook (runs alongside `compilation-finish-functions`)                                     |
| `ghostel-compile-debug`               | Log every OSC 133 C/D event to `*Messages*` (default `nil`)                                                      |

Completion is detected via the OSC 133 `D;<exit>` semantic prompt
marker, so shell integration (`ghostel-shell-integration`, enabled by
default) must be active.

#### Hooks for your own integrations

Outside of a compile buffer, two hooks let you react to *any* shell
command in *any* ghostel buffer:

- `ghostel-command-start-functions` — called with `(BUFFER)` when the
  shell emits OSC 133 `C` (a command starts running).
- `ghostel-command-finish-functions` — called with `(BUFFER EXIT-STATUS)`
  when the shell emits OSC 133 `D` (a command finishes).

Errors raised by individual hook functions are caught and logged so
one bad consumer can't break the rest.

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

The primary benchmark streams 5 MB of data through a real process pipe,
matching actual terminal usage.  All backends are configured with ~1,000
lines of scrollback (matching vterm's default).  Results on Apple M4 Max,
Emacs 31.0.50:

| Backend              | Plain ASCII | URL-heavy |
|----------------------|------------:|----------:|
| ghostel              |    65 MB/s  |  42 MB/s  |
| ghostel (no detect)  |    64 MB/s  |  65 MB/s  |
| vterm                |    29 MB/s  |  24 MB/s  |
| eat                  |   3.9 MB/s  | 3.0 MB/s  |
| term                 |   4.8 MB/s  | 4.1 MB/s  |

Ghostel scans terminal output for URLs and file paths, making them clickable.
The "no detect" row shows throughput with this detection disabled
(`ghostel-enable-url-detection` / `ghostel-enable-file-detection`).  The other
emulators do not have this feature, so their numbers are comparable to the "no
detect" row.

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

| Feature                       | ghostel   | vterm   |
|-------------------------------|-----------|---------|
| True color (24-bit)           | Yes       | Yes     |
| OSC 4/10/11 color queries     | Yes       | No      |
| Bold / italic / faint         | Yes       | Yes     |
| Underline styles (5 types)    | Yes       | No      |
| Underline color               | Yes       | No      |
| Strikethrough                 | Yes       | Yes     |
| Cursor styles                 | 4 types   | 3 types |
| OSC 8 hyperlinks              | Yes       | No      |
| Plain-text URL/file detection | Yes       | No      |
| Kitty keyboard protocol       | Yes       | No      |
| Mouse passthrough (SGR)       | Yes       | No      |
| Bracketed paste               | Yes       | Yes     |
| Alternate screen              | Yes       | Yes     |
| Shell integration auto-inject | Yes       | No      |
| Prompt navigation (OSC 133)   | Yes       | Yes     |
| Elisp eval from shell         | Yes       | Yes     |
| TRAMP remote terminals        | Yes       | Yes     |
| OSC 52 clipboard              | Yes       | Yes     |
| Copy mode                     | Yes       | Yes     |
| Drag-and-drop                 | Yes       | No      |
| Auto module download          | Yes       | No      |
| Scrollback default            | ~5,000    | 1,000   |
| PTY throughput (plain ASCII)  | 65 MB/s   | 29 MB/s |
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

**Rendering.**  Both use text properties (not overlays) and batch consecutive
cells with identical styles.  Ghostel's engine provides three-level dirty
tracking (none / partial / full) with per-row granularity.  vterm uses
damage-rectangle callbacks and redraws entire invalidated rows.  Ghostel
defaults to ~30 fps redraw; vterm defaults to ~10 fps.

**Shell integration.**  Ghostel auto-injects shell integration scripts for
bash, zsh, and fish — no shell RC changes needed.  vterm requires manually
sourcing scripts in your shell configuration.  Both support Elisp eval from
the shell and TRAMP-aware remote directory tracking.

**Performance.**  In PTY throughput benchmarks (5 MB streamed through `cat`,
both backends configured with ~1,000 lines of scrollback), ghostel is
roughly 2x faster than vterm on plain ASCII data (65 vs 29 MB/s).  On
URL-heavy output ghostel still comes out ahead of vterm (42 vs 24 MB/s);
with link detection disabled ghostel reaches 65 MB/s regardless of input.
See the [Performance](#performance) section above for full numbers and how
to run the benchmark suite yourself.

**Installation.**  Ghostel can automatically download a pre-built native
module or compile from source with [Zig](https://ziglang.org/).  vterm uses
CMake with a single C dependency (libvterm) and can auto-compile on first
load from Elisp.

For a detailed architectural comparison, see [design.org](design.org).

## Architecture

```
ghostel.el          Elisp: keymap, process management, mode, commands
src/module.zig      Entry point: emacs_module_init, function registration
src/terminal.zig    Terminal struct wrapping ghostty handles
src/render.zig      RenderState -> Emacs buffer with styled text
src/input.zig       Key and mouse encoding via ghostty encoders
src/emacs.zig       Zig wrapper for the Emacs module C API
src/ghostty.zig     Re-exports and constants for the ghostty C API
```

## License

GPL-3.0-or-later
