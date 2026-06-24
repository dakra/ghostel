# Ghostel

[![MELPA](https://melpa.org/packages/ghostel-badge.svg)](https://melpa.org/#/ghostel)
[![MELPA Stable](https://stable.melpa.org/packages/ghostel-badge.svg)](https://stable.melpa.org/#/ghostel)
[![CI](https://github.com/dakra/ghostel/actions/workflows/ci.yml/badge.svg)](https://github.com/dakra/ghostel/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/dakra/ghostel)](https://github.com/dakra/ghostel/releases)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](https://github.com/dakra/ghostel/blob/main/LICENSE)
[![VT engine: libghostty-vt](https://img.shields.io/badge/VT%20engine-libghostty--vt-c2a2ff.svg)](https://ghostty.org/)

**Ghostel** is a terminal emulator for Emacs powered by [libghostty-vt](https://ghostty.org/),
the VT engine behind the [Ghostty](https://ghostty.org/) terminal.

It aims to be featureful, fast, robust and correct.

Ghostel's features include synchronized output, true color, the Kitty keyboard
and graphics protocols, hyperlinks, desktop notifications, progress reports and a lot more.

Shell integration (directory tracking, prompt navigation) all works out of the
box for bash, zsh and fish.

Check the [documentation](https://dakra.github.io/ghostel/#features) for a full list of features or how it [compares](https://dakra.github.io/ghostel/#ghostel-vs-vterm) to [vterm](https://github.com/akermu/emacs-libvterm) or [eat](https://codeberg.org/akib/emacs-eat).

|  |  |
|:--:|:--:|
| ![btop running in a Ghostel buffer](assets/ghostel-btop.png) | ![yazi previewing an image inside a Ghostel buffer](assets/ghostel-yazi.png) |
| `btop`: true color and full TUI rendering | `yazi`: inline image preview via the Kitty graphics |

## Quick Start

**Requirements:** Emacs 28.1+ with dynamic module support, on macOS, Linux, or FreeBSD.
The native module is a prebuilt binary that **auto-downloads on first use**.
No toolchain or build step required.

Install from [MELPA](https://melpa.org/#/ghostel):

```emacs-lisp
(use-package ghostel
  :ensure t)
```

Then `M-x ghostel` to open a terminal. That's it.

See [installation](https://dakra.github.io/ghostel/#installation) for different
installation instructions.

## A fuller example

This example shows more features and how you can add custom keybindings
or custom functions that interact with the Ghostel buffer.

```emacs-lisp
(use-package ghostel
  :bind (("C-x m" . ghostel)
         :map ghostel-semi-char-mode-map
         ("C-s"  . consult-line)
         ("C-k"  . my/ghostel-send-C-k-and-kill)
         ;; ;; I'm used to go up/down the shell history with M-n/p from eshell
         ;; ;; Simulate this behavior in ghostel by sending C-p and C-n
         ("M-p" . (lambda () (interactive) (ghostel-send-key "p" "ctrl")))
         ("M-n" . (lambda () (interactive) (ghostel-send-key "n" "ctrl")))
         :map project-prefix-map
         ("m" . ghostel-project)
         ("M" . ghostel-project-list-buffers))
  :config
  (defun my/ghostel-send-C-k-and-kill ()
    "Send `C-k' to ghostel.
Like normal Emacs `C-k'.  Kill to end of line and put content in kill-ring."
    (interactive)
    (kill-ring-save (point) (line-end-position))
    (ghostel-send-key "k" "ctrl"))

  (add-to-list 'project-switch-commands '(ghostel-project "Ghostel") t)
  (add-to-list 'project-switch-commands '(ghostel-project-list-buffers "Ghostel buffers") t)
  (add-to-list 'ghostel-eval-cmds '("magit-status-setup-buffer" magit-status-setup-buffer)))
```

Now you can `C-x m` to open a Ghostel buffer, or
you can switch to a project (`C-x p p`) and then press `m` to open a Ghostel
buffer in this project.
In a project you can press `C-x p M` to get a list of Ghostel buffers running in
the current project that you can switch to.

## Extensions

These ship with the Ghostel package, no separate install necessary.
Just enable what you want:

Make `eshell-visual-commands` run in a Ghostel buffer.
```emacs-lisp
(use-package ghostel-eshell
  :hook (eshell-load . ghostel-eshell-visual-command-mode))
```

Run all `compile` commands in a Ghostel buffer.
```emacs-lisp
(use-package ghostel-compile
  :hook (after-init . ghostel-compile-global-mode))
```

Replace comint's built-in `ansi-color-process-output` with Ghostel's VT parser.
```emacs-lisp
(use-package ghostel-comint
  :hook (after-init . ghostel-comint-global-mode))
```

If you use an Emacs Lisp input method (e.g. Korean Hangul), add Ghostel support:
```emacs-lisp
(use-package ghostel-ime
  :hook (ghostel-mode . ghostel-ime-mode))
```

## Evil
If you're an evil user you can install the [evil-ghostel](https://melpa.org/#/evil-ghostel) extension:

```emacs-lisp
(use-package evil-ghostel
  :after (ghostel evil)
  :hook (ghostel-mode . evil-ghostel-mode))
```

## Shell integration

Directory tracking and prompt navigation are on by default for local bash, zsh or fish sessions.
See [shell integration](https://dakra.github.io/ghostel/#shell-integration) for tramp support and more.

To call Emacs functions from your shell you have to add them to the
`ghostel-eval-cmds` whitelist and then add something like this to your bashrc:

```bash
if [[ "$INSIDE_EMACS" = 'ghostel' ]]; then
    # Open a file in Emacs from the terminal
    e()   { ghostel_cmd find-file-other-window "$@"; }

    # Open dired in another window
    dow() { ghostel_cmd dired-other-window "$@"; }

    # Open magit for the current directory
    gst() { ghostel_cmd magit-status-setup-buffer "$(pwd)"; }
fi
```

## Input modes

Ghostel offers five eat.el-style [input modes](https://dakra.github.io/ghostel/#input-modes).

The default is **semi-char mode** (`C-c C-j`), which forwards almost all
keys to the terminal besides a few exceptions (e.g. `M-x`, `C-c`).

In **char mode** (`C-c M-d`), *all* keys go to the terminal. `M-RET` to exit.

**line mode** (`C-c C-l`) is similar to `M-x shell` in that Ghostel is like a
normal Emacs buffer and *no* key gets sent to the terminal.
Only after you finish typing a line and press enter, the whole line
is sent at once.

**emacs** (`C-c C-e`) and **copy mode** (`C-c C-t`) give you normal Emacs
navigation over the read-only terminal buffer so you can look around and copy
text. The difference between the two is that **copy mode** freezes the terminal,
so if you have continuous output nothing "scrolls away" while you try to select
something. **emacs mode** is *live* so new output keeps coming in while you
scroll/select.

Those read-only modes have by default `ghostel-readonly-fast-exit`
set to true, which automatically exits those modes on most keys
that you expect to be sent to the terminal.
This makes for seamless transitions, e.g. you have some output
running and see something you want to copy, you press `C-c C-t`
and enter `copy-mode` navigate like in a normal Emacs buffer
and select your text. When you copy something or type any
character you're automatically back in your normal ghostel
terminal session.
Similarly, some actions automatically activate **copy mode**,
like selecting with the mouse, navigating to hyperlinks (`C-c C-p`),
activating the mark.

## Documentation

- [Requirements](https://dakra.github.io/ghostel/#requirements)
- [Installation](https://dakra.github.io/ghostel/#installation)
- [Building from source](https://dakra.github.io/ghostel/#building-from-source)
- [Shell Integration](https://dakra.github.io/ghostel/#shell-integration)
- [Input modes](https://dakra.github.io/ghostel/#input-modes)
- [Features](https://dakra.github.io/ghostel/#features)
- [TRAMP (Remote Terminals)](https://dakra.github.io/ghostel/#tramp-remote-terminals)
- [Configuration](https://dakra.github.io/ghostel/#configuration)
- [Extensions](https://dakra.github.io/ghostel/#extensions)
  - [Evil](https://dakra.github.io/ghostel/#evil-mode)
  - [Compilation mode](https://dakra.github.io/ghostel/#compilation-mode)
  - [Eshell integration](https://dakra.github.io/ghostel/#eshell-integration)
  - [Comint integration](https://dakra.github.io/ghostel/#comint-integration)
  - [Emacs Lisp input methods](https://dakra.github.io/ghostel/#emacs-lisp-input-methods)
- [Commands](https://dakra.github.io/ghostel/#commands)
- [Running Tests](https://dakra.github.io/ghostel/#running-tests)
- [Performance](https://dakra.github.io/ghostel/#performance)
- [Ghostel vs vterm and eat](https://dakra.github.io/ghostel/#ghostel-vs-vterm)
- [Architecture](https://dakra.github.io/ghostel/#architecture)
- [Contributing](https://dakra.github.io/ghostel/#contributing)
- [Changelog](CHANGELOG.md)
- [License](https://dakra.github.io/ghostel/#license)
