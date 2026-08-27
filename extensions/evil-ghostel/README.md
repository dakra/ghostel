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

Cursor-driven commands follow the position reported by the terminal after
each key, keeping edits aligned around wide characters, grapheme clusters,
and soft wraps and stopping if the shell ignores a key.

## Word boundaries

Word motions use Vim-style word boundaries: `w`, `b`, `e`, `ciw` stop at
path components (`bar` in `~/src/foo/bar.txt`) instead of treating the
whole path as one word. The default of `evil-ghostel-word-boundaries`
matches Vim's default `iskeyword` — letters, digits, and `_` are word
constituents, all other punctuation is a boundary.

Tradeoff: the syntax table drives every syntax-based word command, not
only Evil's, so while `evil-ghostel-mode` is enabled double-click, `*`,
dabbrev, and line-mode `M-f`/`M-b` likewise see path components rather
than the whole path. Link clicking, `ghostel-find-file-at-point`,
and the whitespace-based WORD motions (`W`, `ciW`, …) are unaffected.

Set `evil-ghostel-word-boundaries` to `nil` to keep ghostel's path-aware
boundaries. While the Vim-style table is installed it takes precedence
for printable ASCII, so ghostel's `ghostel-word-boundary-string` only
affects non-ASCII characters in `evil-ghostel-mode` buffers.

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
