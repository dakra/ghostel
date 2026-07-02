# evil-ghostel shell operator/motion matrix (elate)

Reusable [`elate`](https://github.com/dakra/elate) scenarios that drive a live `ghostel`
+ `evil-ghostel` session and assert that Evil editing over the PTY works, across shells.
([`elate`](https://github.com/dakra/elate) is a CLI for spawning and driving sandboxed,
observable Emacs sessions.) Each op types a command,
applies an Evil edit, executes the edited line, and asserts its output — so the
shell/REPL itself proves the edit landed. This is the distilled, re-runnable form of
the parallel bash/zsh/fish/python3 sessions from the evil-ghostel rewrite
(`plans/evil-rewrite-plan.md`).

## Files

- `lib/evil-ghostel-setup.el` — shared startup: puts `evil`/`ghostel`/`evil-ghostel`
  on the load-path (self-locating), enables the modes, disables
  `ghostel-macos-login-shell`. `evil` resolves from `../evil` or `$ELATE_EVIL_DIR`.
- `matrix/shells.json` — **one templated scenario driven once per shell** (`bash, zsh,
  fish, nu`; they share the `echo`-style editing flow). 26 ops: motions/edits `i a A I x
  X dw 2dw cw c dd cc D C s S r 3r u . ~`, visual `v e d`, paste `p P`, and insert-mode
  Ctrl passthrough `C-w C-u C-a/C-e`. `{{shell}}`/`{{echo}}`/`{{setup}}` fill the shell
  specifics; `{{u_expect}}`/`{{P_expect}}` flip the nu-only known failures to `xfail`.
- `matrix/python3.json` — the REPL, kept separate because it has no `echo` and its
  operator tokens don't word-split cleanly (word-heavy/passthrough ops omitted). 12 ops.
- `matrix/boundary-<shell>-ghostel.json` — the input-region boundary suite (autosuggestion,
  right prompt, syntax-highlight tail, multi-line) on bash/zsh/fish/nu; see the boundary-suite
  section below.

## Running (elate 0.11.0+)

The shells share three co-varying template holes (`shell`/`echo`/`setup`), which
`elate matrix --param` can't express (its axes cross as an independent Cartesian
product), so drive one shell per `elate run --keep-going` and read the per-group grid
from the JSON. `--keep-going` makes every op report; a successful run auto-purges its
throwaway sandbox.

```sh
S=test/elate/matrix/shells.json
elate run --keep-going --format json --set shell=/opt/homebrew/bin/bash --set echo=echo --set setup= "$S"
elate run --keep-going --format json --set shell=/bin/zsh               --set echo=echo --set setup= "$S"
elate run --keep-going --format json --set shell=/opt/homebrew/bin/fish --set echo=echo \
  --set 'setup=function fish_prompt; echo -n "> "; end; function fish_right_prompt; end' "$S"
elate run --keep-going --format json --set shell=/opt/homebrew/bin/nu   --set echo=e \
  --set 'setup=def e [...rest] { $rest | str join " " }' --set u_expect=fail --set P_expect=fail "$S"

elate run --keep-going --format json test/elate/matrix/python3.json
```

Each run's JSON carries a `groups[]` array (`name` + `status` = `PASS`/`FAIL`/`XFAIL`/
`XPASS`); pivot those into an op × shell grid. `--format junit`/`tap` are available for
CI. The run exits non-zero on any genuine `FAIL` or `XPASS` (`xfail` is non-gating).

The `setup` step is a no-op for bash/zsh (`--set setup=`); fish needs a short
`fish_prompt` (its long default overflows `ghostel-prompt-regexp`, breaking input-start
detection) and nu needs an `e` echo-helper (nu's `echo` doesn't join its args).

## Input-region boundary suite (autosuggestion / right-prompt / syntax-tail)

The 26-op `shells.json` matrix runs on bash, which has no autosuggestion, right prompt, or
syntax highlighting, so it never exercises `evil-ghostel--input-end` -- the color-based
detection that stops Evil rightward motions/operators at the *typed* input end instead of
walking into shell-rendered ghost text. `matrix/boundary-<shell>-ghostel.json` targets
exactly those live conditions, on fish (native), zsh (zsh-autosuggestions), and nu
(reedline history hint):

- **A autosuggestion** -- seed history, type a prefix, assert the faint ` world` ghost is
  *live on the current line* (not just scrollback), then `$ a X` / `A X`; the executed
  command must be `helloX` (the ghost must not be accepted).
- **B right prompt** -- with `[RP]` painted at the right edge, `A X` and `^ D` must ignore it.
- **D syntax-highlight tail** (fish, nu) -- a saturated colored argument must not be mistaken
  for a suggestion, so `D` / `C` reach the real end.
- **M multi-line** (all) -- an open quote + ENTER builds a genuine two-row input (a real
  continuation line, not a soft-wrap); it must build (M1) and append (`A X`) at the true
  input end and execute (M2).  Universal, so it is the one condition bash can exercise.  M2
  is skipped for nu: `A X` appends a bareword after the closing quote, which bash/fish
  word-concatenate but nu's parser rejects -- ghostel places the edit correctly, it just
  isn't valid nu, so there is nothing to assert.

```sh
for s in bash-ghostel zsh-ghostel fish-ghostel nu-ghostel; do
  elate run --keep-going --format json test/elate/matrix/boundary-$s.json; done
```

Result (Emacs 32) -- **ghostel handles every live case**:

| condition        | bash | zsh | fish | nu  |
|------------------|:----:|:---:|:----:|:---:|
| A autosuggestion | n/a  | ok  |  ok  | ok  |
| B right prompt   | n/a  | ok  |  ok  | ok  |
| D syntax tail    | n/a  | n/a |  ok  | ok  |
| M multi-line     |  ok  | ok  |  ok  | ok¹ |

¹ nu runs M1 (build + execute) only; M2 (append) is skipped -- see the M bullet above.

The A cells matter because `evil-ghostel--input-end` is **load-bearing**, not decorative:
ghostel routes Evil motions as PTY keystrokes, and a rightward key at the input end makes
fish *accept* the autosuggestion. The color-based detection (luminance + color-difference
of the trailing run) is what stops the motion at the typed end. Stubbed permissive, `$ a X`
yields `hello worlXd` -- the ghost is accepted and edited inside, the exact #493-class bug.
It is also shell-agnostic: it handles fish's whole-suggestion accept, zsh's per-char
partial-accept, and nu's reedline hint alike, because it reads the grey color, not a
cursor-motion delta.

Soft-wrapped *single*-line input (one logical line wider than the window) is still not
automated: narrow-width output wraps too, so the shell-as-oracle assertion can't anchor
across the soft-wrap newline; that stays covered by ERT
(`...end-of-line-excludes-autosuggestion`, `...replace-count-excludes-soft-wraps`).

## Known xfails (flagged, not fixed — confirmed live on elate 0.11.0)

- **`u` (undo) on `nu` and `python3`** — `evil-ghostel-undo` sends `C-_` (readline/zle
  undo); reedline and PyREPL don't bind it.
- **`P` (paste-before) on `nu`** — reedline pastes nothing on paste-before (`p`
  paste-after works).
- **`~` (toggle-case) on all shells** — evil-ghostel doesn't remap `~`, so vanilla Evil
  runs against the read-only `*ghostel*` render buffer and the keystroke itself signals
  `Buffer is read-only` (the op errors outright, not just "reverts on redraw").

Each is marked `expect: "fail"` so a regression elsewhere still shows red and a future
fix shows **XPASS**. Everything else passed on bash/zsh/fish/nu (incl. `a X s S p`,
dot-repeat, and the `C-w`/`C-u`/`C-a`/`C-e` insert passthrough); python3 covers the
subset that maps cleanly to REPL expressions (`i a A I x 2dw dd cc r a X s` + `u` xfail).

## meow-ghostel matrix

The same live harness exists for `meow-ghostel` (meow's documented qwerty layout):

- `lib/meow-ghostel-setup.el` — shared startup: `meow` resolves from `ELATE_MEOW_DIR`,
  `../meow`, or `$XDG_CACHE_HOME/meow`; defines the qwerty `meow-setup`, enables
  `meow-global-mode` + `meow-ghostel-mode`.
- `matrix/meow-shells.json` — templated per-shell command matrix. Meow is
  selection-first, so word ops select backward from the input end with `b`
  (back-word) before `s`/`c`/`r`; `x s`/`x c` are the line kill/change; `s` with no
  selection exercises the C-k fallback; plus a keypad smoke (`SPC` in normal state)
  and insert-state Ctrl passthrough groups. `{{u_expect}}` flips the
  nu-only undo xfail (meow has no paste-before, so there is no `P` group).
  Unlike evil-ghostel, meow-ghostel adds no insert-state passthrough layer, so
  `C-u` follows `ghostel-keymap-exceptions` (Emacs `universal-argument`, not
  shell kill-line) — the passthrough group uses `C-a` + `C-k` instead.
- `matrix/meow-python3.json` — the REPL subset.
- `matrix/meow-boundary-<shell>-ghostel.json` — the boundary suite; `x a` (select
  line + append) exercises the autosuggestion clamp through the region-end path,
  `A` (open-below) through the input-end target, `x s` must not eat `[RP]`.

```sh
S=test/elate/matrix/meow-shells.json
elate run --keep-going --format json --set shell=/opt/homebrew/bin/bash --set echo=echo --set setup= "$S"
elate run --keep-going --format json --set shell=/bin/zsh               --set echo=echo --set setup= "$S"
elate run --keep-going --format json --set shell=/opt/homebrew/bin/fish --set echo=echo \
  --set 'setup=function fish_prompt; echo -n "> "; end; function fish_right_prompt; end' "$S"
elate run --keep-going --format json --set shell=/opt/homebrew/bin/nu   --set echo=e \
  --set 'setup=def e [...rest] { $rest | str join " " }' --set u_expect=fail "$S"

elate run --keep-going --format json test/elate/matrix/meow-python3.json
for s in bash zsh fish nu; do
  elate run --keep-going --format json test/elate/matrix/meow-boundary-$s-ghostel.json; done
```

## Overrides

- `ELATE_GHOSTEL_SHELL` — overrides `ghostel-shell` (setup reads it).
- `ELATE_EVIL_DIR` — absolute path to the `evil` checkout (default: `../evil`, then
  `$XDG_CACHE_HOME/evil`).
- `ELATE_MEOW_DIR` — absolute path to the `meow` checkout (default: `../meow`, then
  `$XDG_CACHE_HOME/meow`).
