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
  fish, nu`; they share the `echo`-style editing flow). 28 ops: motions/edits `i a A I x
  X dw 2dw cw c dd cc D C s S r 3r u . ~`, insert entry from inside the prompt `0 i`
  `0 a` (point must land on the input start), visual `v e d`, paste `p P`, and insert-mode
  Ctrl passthrough `C-w C-u C-a/C-e`. `{{shell}}`/`{{echo}}`/`{{setup}}` fill the shell
  specifics; `{{u_expect}}` flips the nu-only known failure to `xfail`.
  Plus 4 word-boundary ops (`ciw-path b-dw-path ciW-path opt-out`); see the
  word-boundary section below.
- `matrix/python3.json` — the REPL, kept separate because it has no `echo` and its
  operator tokens don't word-split cleanly (word-heavy/passthrough ops omitted). 13 ops.
- `matrix/boundary-<shell>-ghostel.json` — the input-region boundary suite (autosuggestion,
  right prompt, syntax-highlight tail, multi-line) on bash/zsh/fish/nu; see the boundary-suite
  section below.
- `matrix/tracking-ghostel.json` — normal-state point tracking across streamed output
  (#228 / #454); see the point-tracking section below.
- `matrix/word-boundaries-ghostel.json` — double-click selection under evil-ghostel's
  Vim-style syntax table, on bash; see the word-boundary section below.
- `matrix/readonly-evil-ghostel.json` / `matrix/readonly-ghostel.json` — copy and Emacs
  mode entry and exit, with and without evil; see the read-only section below.

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
  --set 'setup=def e [...rest] { $rest | str join " " }' --set u_expect=fail "$S"

elate run --keep-going --format json test/elate/matrix/python3.json
```

Each run's JSON carries a `groups[]` array (`name` + `status` = `PASS`/`FAIL`/`XFAIL`/
`XPASS`); pivot those into an op × shell grid. `--format junit`/`tap` are available for
CI. The run exits non-zero on any genuine `FAIL` or `XPASS` (`xfail` is non-gating).

The `setup` step is a no-op for bash/zsh (`--set setup=`); fish needs a short
`fish_prompt` (its long default overflows `ghostel-prompt-regexp`, breaking input-start
detection) and nu needs an `e` echo-helper (nu's `echo` doesn't join its args).

## Input-region boundary suite (autosuggestion / right-prompt / syntax-tail)

The 28-op `shells.json` matrix runs on bash, which has no autosuggestion, right prompt, or
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

## Point-tracking suite (normal state vs streamed output)

The operator matrix edits at a quiet prompt and never exercises redraw-time point
placement, so it stayed green through the #228 tracking regression.
`matrix/tracking-ghostel.json` covers that surface directly (shell-agnostic point
handling, driven on zsh):

```sh
elate run --keep-going --format json test/elate/matrix/tracking-ghostel.json
```

- **parked-stream / parked-burst** — point parked at the live cursor in normal state
  must follow it across a line-at-a-time stream and across a single-frame burst (the
  burst un-anchors the window until point snaps, so it catches post-render guard skew).
- **roamed-burst** — point moved off the cursor's row (`k k k`) must stay put (#454).
- **re-engage** — after roaming, `i` re-parks point; tracking must engage again.
- **esc-clamp** — an ESC processed before the RET echo renders sits at the typed text's
  EOL, where evil's normal-state EOL adjust parks point at cursor-1 on the cursor's row;
  row-wise tracking must still carry point to the new prompt.
- **row-roam** — `0` on the prompt row, then a background burst: point rides the
  cursor's row at its own column, never snapped onto the cursor.

The parked groups send ESC only after a short idle inside a `sleep 2` prefix so it
lands exactly on the cursor (the esc-clamp group covers the atomic RET+ESC timing).

## Word-boundary suite (Vim-style `iskeyword` vs ghostel's path-aware table)

`evil-ghostel-mode` installs `evil-ghostel-syntax-table`, so `w`/`b`/`ciw` stop at path
components instead of spanning `a/BAD/c.txt` as one word.  The other ops edit plain
alphanumeric words, identical under either table; these four target the difference
(shell as oracle, all four shells):

- **ciw-path** -- `^ w w w c i w` on `a/BAD/c.txt` reaches and replaces `BAD` only
  (`a/m27ok/c.txt`).  Under ghostel's own table `^ w w` leaves the token entirely.
- **b-dw-path** -- `$ b d w` on `m28ok/DELME` removes just `DELME` (`m28ok/`).
- **ciW-path** -- `ciW` on `BAD/BAD.BAD` still replaces the whole whitespace-delimited token.
- **opt-out** -- `(customize-set-variable 'evil-ghostel-word-boundaries nil)` restores
  `ghostel-mode-syntax-table` in the live buffer (asserted), so `ciw` takes the whole path;
  the option is reset to its standard value afterwards.

`matrix/word-boundaries-ghostel.json` pins the documented mouse tradeoff on rendered
output with real double-clicks (`mouse: double` at a fixed line/column, layout asserted
first): mode on selects `BAD`, `(evil-ghostel-mode -1)` selects `a/BAD/c.txt`, re-enabling
selects `BAD` again.

```sh
elate run --keep-going --format json test/elate/matrix/word-boundaries-ghostel.json
```

## Read-only mode suites (copy / Emacs mode, with and without evil)

`matrix/readonly-evil-ghostel.json` and `matrix/readonly-ghostel.json` drive copy and
Emacs mode on zsh, with the shell's output as the oracle.  Every group starts from
semi-char (and insert state under evil), so one failure does not cascade.

- **evil** -- `prompt-nav` (`[[` stays semi-char, `G a` types at the prompt; #715),
  `copy-insert` (`i` off the cursor row lands on the cursor), `nested-insert`
  (Emacs -> copy -> `i` leaves read-only mode), `column-keep` (`b i X` in copy mode
  edits at point), `clamp` (`0 i` from copy mode stops at the input start),
  `emacs-state` (`C-z` keeps copy mode), `search` (normal-state `/` stays semi-char),
  `insert-isearch` (insert-state isearch enters copy mode in normal state, `k` browses),
  `copy-from-insert` (`C-c C-t` in insert state lands in normal state, `k k` stay in
  copy mode),
  `freeze-then-insert` (output during the freeze moves the cursor rows down).
- **plain** -- `fast-exit`, `nested-fast-exit` (a key typed in copy mode entered from
  Emacs mode is sent), `nested-q` (`q` leaves read-only mode entirely), `prompt-nav`
  (`C-c M-p`), `isearch`, `RET` (off a link: exit and run), `freeze` (held output
  renders on exit).

```sh
elate run --keep-going --format json test/elate/matrix/readonly-evil-ghostel.json
elate run --keep-going --format json test/elate/matrix/readonly-ghostel.json
```

## Kitty graphics and scrollback suites (plain ghostel, no evil)

`lib/ghostel-setup.el` is the evil-free counterpart of the setup file above and adds
the probes these scenarios assert on: `ghostel-elate--vt` feeds raw escape bytes to the
terminal through a file the shell cats (typing ESC at a readline prompt turns it into
meta keys), `ghostel-elate--kitty-cells` / `ghostel-elate--kitty-slices` list every
kitty image slice in the buffer (text-property and overlay paths) with its cell
geometry, and `ghostel-elate--has-line` is a whole-line regexp search.

- `matrix/kitty-ghostel.json` -- **GUI session** (image display is gated on
  `display-graphic-p`; assertions are structural, no screenshot). Groups: `pin-relative`
  (a pinned 4x2 root, a relative child at H=1/V=2, a child at H=-2 clipped to two
  visible columns with slice x=2, children at H=200 and V=100 not drawn), `delete`
  (`d=a`), `overlay` (rows shorter than the placement use the before-string overlay),
  `virtual` (U=1 on a U+10EEEE placeholder run; `d=i` removes it),
  `evict` (a placement whose rows left the scrollback limit does not reappear at the
  top of the viewport), `virtual-flood` (a 3-row virtual placement pushed into
  scrollback by 40 trailing lines in one feed stays fully tagged), `virtual-two-images`
  (two placeholder runs on one line resolve to their own image each), `source-rect`
  (a scale-to-fit placement naming its full size as the source rect renders every
  pixel; a sub-rect placement hands Emacs only the cropped pixels, checked on the
  slice's PPM `:data`).
- `matrix/scrollback-ghostel.json` -- TTY, 60x24. Retention is floored at ~2 standard
  pages regardless of `ghostel-max-scrollback` (ghostty clamps the byte limit up).
  Groups: `evict` (5000 rows: oldest gone, newest kept, buffer bounded),
  `region-scroll` (a DECSTBM region scroll keeps rows already in scrollback),
  `wrap-join` (a 90-char line wraps at 60 columns and rejoins after a resize to 100),
  `deccolm` (`CSI ? 3 h` / `l` clears the screen but keeps scrollback and the column
  count). Never runs `clear(1)`: it sends `CSI 3 J`, which erases scrollback.

```sh
elate run --keep-going --format json test/elate/matrix/kitty-ghostel.json
elate run --keep-going --format json test/elate/matrix/scrollback-ghostel.json
```

Protocol gotchas baked into the kitty scenario: `a=T` transmits *and* places an
implicit copy at the cursor (use `a=t` + `a=p`); `d=A` (capital) also frees the image
data, so later `a=p` for that id places nothing.

## Synchronized output and shell-integration suites (plain ghostel, TTY 80x24, bash)

- `matrix/sync-output-ghostel.json` -- DEC mode 2026. Groups: `reopen` (a frame closed
  and reopened within one write admits one redraw: content written after the reopen is
  visible while the mode stays open), `release` (`CSI ? 2026 l` lets output through and
  clears the mode), `resize-held` (a window resize committed while the mode is open
  leaves it open, and a later close+reopen frame still paints). The feeds carry no
  sentinel: an echo would be held inside the open frame. Window-size changes force their
  redraw, so a resize commits even while the mode is open.
- `matrix/shell-integration-ghostel.json` -- bash integration (auto-injected). Groups:
  `exit-code` (OSC 133 D codes reach `ghostel-command-finish-functions` as integers for
  `false`, `true`, `(exit 7)`), `clear-scrollback` (`clear` sends `CSI H CSI 2 J`, no
  `CSI 3 J`, so earlier output stays in the buffer).

```sh
elate run --keep-going --format json test/elate/matrix/sync-output-ghostel.json
elate run --keep-going --format json test/elate/matrix/shell-integration-ghostel.json
```

## Known xfails (flagged, not fixed — confirmed live on elate 0.11.0)

- **`u` (undo) on `nu` and `python3`** — `evil-ghostel-undo` sends `C-_` (readline/zle
  undo); reedline and PyREPL don't bind it.
- **`~` (toggle-case) on all shells** — evil-ghostel doesn't remap `~`, so vanilla Evil
  edits the `*ghostel*` render buffer; the next redraw repairs it and the typed input
  is unchanged.

Each is marked `expect: "fail"` so a regression elsewhere still shows red and a future
fix shows **XPASS**. Everything else passed on bash/zsh/fish/nu (incl. `a X s S p P`,
dot-repeat, and the `C-w`/`C-u`/`C-a`/`C-e` insert passthrough); python3 covers the
subset that maps cleanly to REPL expressions (`i a A I 0i x 2dw dd cc r a X s` + `u` xfail).

## Overrides

- `ELATE_GHOSTEL_SHELL` — overrides `ghostel-shell` (setup reads it).
- `ELATE_EVIL_DIR` — absolute path to the `evil` checkout (default: `../evil`, then
  `$XDG_CACHE_HOME/evil`).
