# evil-ghostel

[Evil-mode](https://github.com/emacs-evil/evil) integration for the
[ghostel](https://github.com/dakra/ghostel) terminal emulator, modeled on
`evil-collection-vterm`.

Install from [MELPA](https://melpa.org/#/evil-ghostel):

```emacs-lisp
(use-package evil-ghostel
  :after (ghostel evil)
  :hook (ghostel-mode . evil-ghostel-mode))
```

When `evil-ghostel-mode` is active, ghostel buffers start in insert state,
ESC enters normal state, normal-state motions work over the rendered
terminal, and the editing operators (`d`, `c`, `x`, `r`, `p`, `u`, …) drive
the shell's line editor over the PTY. See the
[manual](https://dakra.github.io/ghostel/#evil-mode) for the full list.

## ESC in fullscreen apps

In alt-screen apps — vim, less, and fullscreen TUIs like Claude Code
(`/tui fullscreen`) — insert-state ESC is by default routed to the app
instead of switching to normal state, so the app keeps its ESC key. This
means you stay in insert state while such an app runs: a leader key like
`SPC` goes to the terminal too. Regular Emacs bindings (`M-x`, `C-x …`,
`C-c …`) still work.

To get ESC back for evil, toggle the per-buffer routing with `C-c C-r`
(`evil-ghostel-toggle-send-escape`): from `auto` it switches to whichever
mode differs from auto's current effect (`evil` while an alt-screen app
runs, `terminal` otherwise), and from an explicit mode back to `auto`;
numeric prefixes 1/2/3 set auto/terminal/evil directly. The default comes
from the `evil-ghostel-escape` option (`auto`, `terminal`, or `evil`).

To switch to normal state just once — without changing the routing — use
`C-c ESC` (`evil-force-normal-state`). This binding uses the `<escape>`
function key, so it works on GUI frames and, on a tty, in terminals
speaking the kitty keyboard protocol with
[kkp.el](https://github.com/benjaminor/kkp) enabled; `M-x
evil-force-normal-state` works everywhere.
