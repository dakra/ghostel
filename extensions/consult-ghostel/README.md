# consult-ghostel

[Consult](https://github.com/minad/consult) integration for the
[ghostel](https://github.com/dakra/ghostel) terminal emulator.

`M-x consult-ghostel` and `M-x consult-ghostel-project` pick a ghostel
terminal (all / project-scoped) with live preview: moving through the
candidate list previews each terminal in the target window, the way
`consult-buffer` does. Candidates are ordered for switching
(recently-used first, current buffer last) and annotated with the
terminal title, and submitting a name that matches no buffer creates a
new terminal with that name. With a prefix argument they behave like
`ghostel` / `ghostel-project` instead (`C-u` creates a new terminal); a
`New` group inside the picker offers the same default-named creation.
When
[marginalia](https://github.com/minad/marginalia) is installed, the
title is prepended to marginalia's buffer annotations instead, in every
buffer prompt.

Install from [MELPA](https://melpa.org/#/consult-ghostel):

```emacs-lisp
(use-package consult-ghostel
  :after (ghostel consult)
  :demand t
  :bind (("C-x m" . consult-ghostel)
         :map project-prefix-map
         ("m" . consult-ghostel-project)
         :map ghostel-semi-char-mode-map
         ("C-c h" . consult-ghostel-history)))
```

`M-x consult-ghostel-history` picks from the shell's own command history
and types the selection into the terminal: the typed input before the
cursor pre-fills the minibuffer and is replaced by the selection, which
stays editable at the prompt. The history is retrieved per shell via
`ghostel-shell-history-commands` (bash, zsh, fish, and nushell work out
of the box; remote terminals query the remote host; history managers
like [atuin](https://atuin.sh) plug in through the same alist).

Loading the package also registers hidden sources in the regular
`consult-buffer` lists: ghostel buffers stay in the default *Buffer*
view only, until the `g` narrow key summons them exclusively.  To opt
out:

```emacs-lisp
(setq consult-buffer-sources
      (delq 'consult-ghostel-source-hidden consult-buffer-sources))
```

The `g` narrow key (or any other source property) can be changed with
`consult-customize`, e.g.
`(consult-customize consult-ghostel-source-hidden :narrow ?t)`.

Loading the package also makes `consult-line` match across soft line
wraps in ghostel buffers: rows joined by wrap newlines become one search
candidate, so a path or command that wrapped mid-word is still found.
It also adds a `Ghostel` group to `consult-bookmark`, so the `g` narrow
key restricts the candidates to ghostel bookmarks.

See [the manual](https://dakra.github.io/ghostel/#consult-integration)
for details.
