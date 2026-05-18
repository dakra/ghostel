# ghostel-comint plan

Goal: a `ghostel-comint-mode` (derived from `comint-mode`) where comint owns
input editing, history, and major-mode integration, while ghostel renders
output through an anchored terminal so ANSI / CR / OSC / cursor-motion work
natively.

First real consumer of `ghostel--new-anchored`.

## Design choices

### 1. Per-command anchored terminal (not persistent)

I'll create a fresh anchored terminal at the moment `comint-input-sender`
fires (i.e. when the user submits a command). Markers wrap an initially-empty
region inserted at the process-mark; the renderer fills it from that point on.

When the *next* command is submitted, the previous terminal's marker pair is
`remhash`-ed out of `ghostel--anchored-terminals`; the buffer text it
produced stays put as inert characters that comint never re-touches.

Reasons:

- Inert prior output: matches the comeat model and is what the task spec
  wants — older commands become regular buffer text that comint can fontify
  as input/output fields and that `isearch` can search.
- Simpler scrollback semantics: each command owns a small region of the
  scrollback budget; we don't have to reason about ghostel's libghostty
  scrollback growing without bound across an interactive session.
- Cleaner alt-screen exit path later: alt-screen entry is per-command in
  practice (you don't enter `less` *between* commands), so a per-command
  terminal is the natural unit for any future "alt-screen takes over the
  region" handling.

Tradeoff: rendering history (cursor-up across previous outputs) is lost the
moment a command finishes. Acceptable for v1; any program that needs persistent
in-buffer drawing across multiple commands should use full `M-x ghostel`.

### 2. comint-output-filter integration

I'll add `ghostel-comint--output-filter` to `comint-output-filter-functions`.
That hook runs AFTER comint has inserted the raw PTY bytes between
`comint-last-output-start` and `(process-mark proc)`. Inside the hook:

1. Capture the inserted region as a string: `(buffer-substring beg pmark)`.
2. Delete the region (`inhibit-read-only` bound).
3. Feed the bytes to the current anchored terminal via
   `ghostel--write-input`.
4. Call `ghostel--redraw TERM t` (full redraw — the region is small and
   per-command, so this is cheap).
5. Move `(process-mark proc)` to the new end-marker position so comint
   places the next chunk of output / input at the right spot.

I will also remove `ansi-color-process-output` from the local
`comint-output-filter-functions`, because ghostel already paints faces
on every cell. (Comeat does the same.)

`comint-inhibit-carriage-motion` is set to t — ghostel's VT parser handles
CR/BS/etc; comint's text-level CR handler would race with us.

### 3. Input via `comint-input-sender`

Override `comint-input-sender` per-buffer with `ghostel-comint--input-sender`.
That gives us one well-defined hook point that fires when the user submits
input:

- Tear down the previous anchored terminal (`remhash` its entry).
- Insert a small placeholder (just a `\n`) at point and create a fresh
  anchored terminal that owns the region starting just below the user's input
  line, all the way to point-max.
- Pass the input through to the PTY via `comint-simple-send`.

Reasons to use the sender (rather than just creating a terminal on every
output chunk):

- Multiple output chunks belong to the *same* command — they should share
  one anchored region.
- We know exactly when a command begins; that's the cleanest place to retire
  the previous one.

### 4. Marker lifecycle

| Event                         | Action                                              |
|-------------------------------|-----------------------------------------------------|
| Buffer set up                 | Hash table lazy-inits on first `ghostel--new-anchored` call. No terminal yet. |
| First `comint-output-filter`  | Bytes from shell startup (prompt+initial banner) arrive before any user input. Bootstrap a terminal at the process-mark and route through it. |
| User submits input            | Retire current terminal (`remhash`); create a fresh one just below the input line. |
| Buffer killed                 | Markers are GC'd with the buffer; hash entry tied to user-pointer (also GC'd). Cancel timers/process via `kill-buffer-hook` for safety. |
| Process exits                 | Sentinel runs; nothing special needed — the live terminal stays in place, its region becomes inert when no further output arrives. |

### 5. MAX-SCROLLBACK: 0 (bounded)

Per-command terminals are short-lived. The active grid sized to the window's
columns × ~24 rows is enough for any single command's transient display.
`MAX-SCROLLBACK = 0` keeps the region tight against the grid; lines that
scroll off vanish from the region (libghostty drops them), but that's fine —
the *previous* command's already-rendered output is preserved separately as
inert buffer text outside any anchored region.

Tradeoff: a single command producing 10k lines (e.g. `find /`) won't have all
10k visible inside the ghostel-managed region while still running. The most
recent N rows are visible (N = window height). Once the command finishes and
the next input is submitted, that command's region becomes inert at the
final-frame state. For "I want all the output preserved across the run",
the user wants `M-x ghostel-compile` (existing) or `M-x ghostel`.

I'll keep the parameter accessible via `ghostel-comint-max-scrollback` so
power users can flip to "preserve everything from the live command" without
my recompiling.

### 6. Read-only handling

`comint-prompt-read-only` is opt-in upstream. I'll set it locally to nil for
the v1 — making the prompt read-only adds enough complication
(`comint-update-fence`, `read-only` text property on the rendered terminal
region) that I'd rather get a working prototype out first. The user can
opt back in if they want; if it breaks rendering, they'll find out fast.

Inside the output-filter hook we always bind `inhibit-read-only`, so the
terminal's deletes and rewrites work even if downstream config flips it on.

### 7. Echo handling

Two layers of defence:

- **stty -echo at PTY config time**: the wrapper command applies
  `-echo` so the kernel discipline doesn't echo the bytes comint sent.
  This is what `ghostel-compile` already does (`ghostel-compile--stty-flags`).
- **`comint-process-echoes nil`**: avoid the synchronous wait-and-strip
  in `comint-send-input`. With `-echo` set on the PTY there's nothing
  to wait for, and the wait can deadlock if it interleaves with our
  redraw.

With both in place, the shell itself does its own line editing (readline /
ZLE) on the typed bytes that comint sends, and only that text is echoed
back — which we want, because that's the prompt line.

But: the user-typed text is *already in the buffer* (comint inserted it when
they typed it). When the shell echoes "ls\n" back, our output filter would
re-insert "ls\n" rendered through ghostel just below the input. Two ways out:

1. Run the shell with `-echo` (kernel-level off) AND `+echo` from the shell
   side (readline still echoes for line-editing purposes). The shell will
   produce its own echo only for line-edit display purposes — which is fine
   because that becomes part of the prompt line that ghostel paints.

2. Have `ghostel-comint--input-sender` send `input + "\r"` and let the shell
   echo from inside readline. Comint's already-inserted "ls" stays as a
   field; what comes back from the shell is its own prompt-line update.

I'll combine: set `-echo` on the kernel, send `input + "\n"` via
`comint-simple-send`, AND set `comint-process-echoes nil`. The shell sees
the input arrive with no terminal-echo prefix; its readline echoes for its
own display purposes but that gets rendered into the anchored region as
part of the next prompt line. Comint's pre-existing typed line stays put
in the buffer as the editable input field above the anchored region.

If echo doubling still happens with specific shells, we can add a
`ghostel-comint--ignored-prefix` strip like comeat does, but I want to see
if it's needed before adding it.

### 8. Mode derivation

`define-derived-mode ghostel-comint-mode comint-mode "GhComint"`. This gets
us comint's keymap, hooks, mode-line, history ring, and field handling for
free. The mode's body:

- registers the output-filter,
- registers the input-sender,
- sets `comint-inhibit-carriage-motion`, `comint-process-echoes` locally,
- arranges `kill-buffer-hook` cleanup.

Minor-mode-on-top was tempting but loses you `comint-mode`'s setup of the
keymap, syntax-table, and input-ring scaffolding that's done in the
major-mode body itself.

## Implementation tasks

1. `lisp/ghostel-comint.el` skeleton: file header, `defgroup`,
   `defcustom`s (`ghostel-comint-program`, `ghostel-comint-buffer-name`,
   `ghostel-comint-max-scrollback`).
2. `ghostel-comint-mode` major-mode derived from `comint-mode`. Set
   local config, install output-filter, install input-sender.
3. `ghostel-comint--spawn`: spawn the shell via `start-file-process`-style
   plumbing, similar to `ghostel-compile--spawn` but configured to talk to
   `comint-output-filter` (so we re-use comint's filter installation in
   `comint-exec`). Use ghostel's `--terminal-env` and a `-echo` stty.
4. `ghostel-comint` interactive command: prompt for program, create buffer,
   run `ghostel-comint-mode`, spawn process.
5. `ghostel-comint--ensure-terminal`: lazily allocate the current anchored
   terminal at the process-mark.
6. `ghostel-comint--retire-terminal`: remhash the current terminal and
   nil-out the local reference.
7. `ghostel-comint--input-sender`: retire previous, send input.
8. `ghostel-comint--output-filter`: grab the just-inserted bytes, route
   them through the active terminal, advance the process-mark.
9. `kill-buffer-hook` cleanup: nothing dramatic — comint's standard
   sentinel already kills the process; we just clear our local timers and
   the terminal hash table.
10. Tests in `test/ghostel-test.el`.
11. Manual `make -j4 all`.

## Test plan

All tests use small synchronous shell commands (`echo ...`, `printf ...`,
`/bin/sh -c '...'`) so we don't depend on the user's interactive shell
features. They run under `ghostel-test--wait-for` polling.

1. **`ghostel-comint-test-basic-echo`** — start `/bin/sh`, send `echo hello`,
   wait for the rendered output, assert that `hello` appears in the buffer.
2. **`ghostel-comint-test-ansi-color`** — send
   `printf '\e[31mred\e[0m\n'`, wait, assert a `face` text-property landed
   on the `red` span.
3. **`ghostel-comint-test-cr-overwrite`** — send
   `printf 'hello\rwor\n'`, wait, assert the buffer shows `worlo` (the CR
   moved the cursor to col 0, then `wor` overwrote `hel`).
4. **`ghostel-comint-test-multi-command-persistence`** — run two commands
   (`echo first`, `echo second`); after the second has rendered, the first
   command's output is still present in the buffer.
5. **`ghostel-comint-test-input-history`** — submit `echo one`, then
   `comint-previous-input 1` from a fresh empty input; the input line now
   contains `echo one`.
6. **`ghostel-comint-test-cleanup-on-kill`** — start the mode, run a command,
   kill the buffer while output is still arriving; no error, no leaked
   processes (verify via `process-list`).

The first four exercise the renderer integration directly. The last two
are about the comint half being intact.

## Open questions

1. **Multiline input + the input-sender boundary**. The user could type
   a heredoc / continued line; my plan creates a fresh terminal per
   `comint-input-sender` invocation, which fires on each `RET`. If a
   user sends `cat <<EOF` and continues across lines, the *first* line's
   sender invocation creates a terminal, the second sender invocation
   creates a second one, but the shell hasn't started actually producing
   command output yet. This is probably fine (the regions are empty)
   but I haven't pressure-tested it.
2. **`comint-input-ring-file-name` etc.** — should the mode adopt
   the user's `~/.bash_history` or maintain its own ring? Punted to "use
   comint's defaults for now"; users can `setq-local` if they care.
3. **OSC 7 / 133 callbacks**. The ghostel callbacks for cwd-tracking and
   prompt-marking are wired up against `ghostel-mode` infrastructure. Do
   they fire correctly inside a `comint-mode`-derived buffer? I'll find
   out during testing; if not, that's a follow-up.
4. **Window resize**. Comint and ghostel both want to react to
   `window-size-change-functions`. The active anchored terminal owns
   only a sub-region; the natural width is the window's, but the height
   doesn't really make sense (the user scrolled past previous outputs).
   For v1 I'll size at window-width × min(window-height, 24).

## Out of scope (explicit)

- Alt-screen entry (`less`, `vim`, `htop` inside the comint buffer) —
  the anchored renderer prototype documents this as undefined.
- Kitty graphics inline.
- Major-mode derivation (e.g. wiring `sql-interactive-mode` to derive from
  `ghostel-comint-mode` instead of `comint-mode`) — that's a separate
  feature once this one is solid.
- TRAMP / remote process support.
- `comint-prompt-regexp` font-locking inside the anchored region.
- Cursor display inside the anchored region (the renderer skips
  cursor-style in anchored mode by design; the user's editing cursor
  sits in the input area, which is what they care about).

## Post-review decisions

After v1 landed, review feedback flagged several issues that have now been
fixed.  Notes here document the choices for future maintainers:

- **`comint-buffer-maximum-size` compatibility (review item #5).** Disabled
  locally in `ghostel-comint-mode` and `comint-truncate-buffer` is stripped
  from the local `comint-output-filter-functions`.  The truncate cuts from
  `point-min` with no awareness of anchored markers; crossing a start-marker
  silently corrupts subsequent redraws.  The "advise/guard" alternative was
  more invasive (would need every-truncate-callsite marker-walking) and
  brittle.  Users who want bounded buffers should wrap truncation with their
  own marker-aware logic.
- **Grid sizing (review items #2, #4, #7, #9).** Single source of truth via
  `ghostel-comint--window-size`: rows × cols are taken from the displaying
  window's `window-screen-lines` × `window-max-chars-per-line`, falling back
  to `ghostel-comint-default-rows` / `-default-cols` when no window is
  displaying the buffer.  An `adjust-window-size-function` process property
  keeps the kernel PTY size and the active anchored terminal in lockstep on
  resize.  `ghostel-comint--rows` / `--cols` are now live state read by the
  resize hook; they used to be set-but-unused.
- **Sentinel (review item #1).** A dedicated sentinel retires the active
  terminal _before_ inserting the exit notice, so the notice lands as inert
  text past the now-detached end-marker rather than INSIDE the renderer's
  writable span where the next redraw would clobber it.
- **`ghostel--process` wiring (review item #3).** The spawn path now sets
  the buffer-local `ghostel--process` so terminal-originated writes (DA1/2/3,
  XTWINOPS, OSC 51, mouse, focus) make it back through
  `ghostel--flush-output`.  Apps that probe the terminal at startup no
  longer hang waiting for a reply.
