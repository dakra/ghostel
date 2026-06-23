# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Emacs bookmark support for ghostel buffers: `bookmark-set` (`C-x r m`) records
  a terminal's working directory and name, and `bookmark-jump` (`C-x r b`)
  reopens it — reusing a live ghostel buffer of that name or starting a fresh
  shell in the bookmarked directory. The new `ghostel-bookmark-check-dir`
  (default `t`) controls whether the directory is restored (`cd`'d into a reused
  buffer that has since moved elsewhere).
  Fixes [#447](https://github.com/dakra/ghostel/issues/447).

### Fixed
- Emoji and other glyphs scaled into the monospace grid now grow and shrink with
  `text-scale-adjust` instead of staying pinned to the base font size.

## [0.37.0] — 2026-06-21

### Added
- `ghostel-initial-input-mode` lets new `ghostel` terminals start in
  semi-char, char, or line mode; line mode is entered automatically after the
  first prompt is detected.

### Changed
- Pasting now uses libghostty's paste encoder, matching terminal state for
  bracketed paste, newline normalization, and filtering unsafe control bytes.

### Fixed
- Resizing a terminal while the cursor is not on the bottom row no longer leaves
  the rendered buffer out of sync.

### Internal
- Line-mode-specific code was split into `lisp/ghostel-line-mode.el`.
- Renderer resize invalidation was simplified, and the renderer now owns native
  terminal row/column bookkeeping when resizes are committed.
- Hypothesis driver coverage was fixed.

## [0.36.0] — 2026-06-21

### Added
- `isearch` and minibuffer navigation (`consult-line`, etc.) in semi-char mode
  now switch to a read-only mode when they leave you parked in the scrollback,
  mirroring a mouse click — so the next redraw no longer yanks point back to
  the prompt.  The target mode is picked by the new
  `ghostel-point-leave-input-mode` defcustom (`copy` default, `emacs`, or nil
  to disable).  Wired into `isearch-mode-end-hook` and `minibuffer-exit-hook`;
  for other jump packages (avy, flash, …) add the new command
  `ghostel-maybe-leave-input` to their after-jump hook or as `:after` advice.
  Mouse selection and region activation keep their independent
  `ghostel-mouse-drag-input-mode` / `ghostel-mark-activation-input-mode` knobs.
- Blinking cursor support. A terminal app that requests a blinking cursor
  (DECSCUSR `CSI 5/3/1 SP q`, i.e. mode 12) now blinks the cursor in the Emacs
  buffer instead of rendering it steady. Works for the bar, block, and
  underline shapes. Yields to the global `blink-cursor-mode` when that is
  enabled (no double-blink); graphical frames only.

### Changed
- Programs launched by Ghostel are now resolved through Emacs's `exec-path`
  (bare names) and `default-directory` (names with a directory component)
  before being spawned, instead of relying on the child inheriting `PATH`.
  The resolved binary now matches what other Emacs commands (`executable-find`,
  `M-x compile`, …) would find, and remote TRAMP buffers are unaffected.
- Internal libghostty VT-parser warnings no longer leak to the module's
  stderr in release builds. In a terminal Emacs (`emacs -nw`) that stderr is
  the controlling tty, so the warnings were painted onto the screen outside
  Emacs's redisplay and lingered — e.g. `unimplemented mode: 9001` left a
  stale line near the mode line after running lazygit (#425). Such logs are
  now available only via `M-x ghostel-debug-start` (`*ghostel-debug*`);
  debug builds keep console output as before.

### Internal
- Cursor style (shape) is now driven from Elisp rather than the Zig renderer,
  unifying cursor control with the new blink support.
- The forked child now writes via `posix.write` instead of a Zig buffered
  writer, keeping the post-fork / pre-exec path async-signal-safe.

## [0.35.4] — 2026-06-19

### Fixed
- Native PTY startup now opens the replica with `NOCTTY`, avoiding crashes when
  launching terminals from Emacs daemon mode.

## [0.35.3] — 2026-06-18

### Added
- Documentation now has a short README landing page plus a full README.org
  manual, with generated Info/HTML targets and GitHub Pages publishing.

### Fixed
- Native PTY processing now tolerates benign re-entrant calls back into the
  module while calling Emacs, avoiding crashes from incidental module access.

## [0.35.2] — 2026-06-18

### Fixed
- Native PTY startup now configures the terminal directly instead of shelling out
  through `stty`, avoiding `ghostel-exec` resize issues while preserving UTF-8
  erase handling and direct `C-q`/`C-s` delivery to the child process.

## [0.35.1] — 2026-06-18

### Fixed
- FreeBSD native PTY builds now include `<sys/wait.h>`, exposing `WEXITSTATUS`
  during Zig C translation so the `x86_64-freebsd` release artifact builds.

### Internal
- The native CI build matrix now includes `x86_64-freebsd`, matching the
  release artifact matrix.

## [0.35.0] — 2026-06-18

### Added
- Local Ghostel buffers now use the native PTY backend by default via
  `ghostel-use-native-pty`.  The native reader consumes PTY output outside
  Emacs's process filter path while remote TRAMP buffers continue to use Emacs
  processes.
- Hyperlinks now support Eldoc, showing link metadata at point.
- Activating the mark in semi-char mode (`C-SPC` / `set-mark-command`,
  expand-region variants, `C-x h`, or any other region-activating command)
  now switches to a read-only mode, mirroring mouse selection, so streaming
  output cannot clobber a keyboard-driven region.  Implemented via a
  buffer-local `activate-mark-hook`, so it works for whatever command the
  user has bound — no specific keys are intercepted.  The target mode is
  picked by the new `ghostel-mark-activation-input-mode` defcustom (`copy`
  default, `emacs`, or nil to keep the old stay-in-semi-char behavior).
  Mouse selection still follows `ghostel-mouse-drag-input-mode`
  independently.

### Changed
- `evil-ghostel` now uses Evil operators, motions, and command remaps instead
  of broad advice around core Evil commands.  Normal/visual editing keeps its
  PTY-driven behavior while avoiding the previous advice lifecycle hazards, and
  Evil buffers opt out of Ghostel's keyboard-mark-to-copy-mode switch so visual
  state owns selection.

### Fixed
- ZSH shell integration now reports gethostname(2) in its OSC 7 directory update
  (matching the bash and fish integrations and Emacs `system-name`), instead of
  zsh's `$HOST`, which is canonicalized to the fully qualified domain name when a
  DNS search domain is configured.  Previously the FQDN disagreed with
  `system-name` (the short hostname), so the local shell was misclassified as
  remote and switched on TRAMP (#417).
- Fish shell integration now caches the hostname once at load instead of forking
  the `hostname` command on every prompt, matching the bash and zsh integrations.
- Char mode now captures GUI `C-SPC` and forwards it to the terminal as NUL;
  previously only the TTY `C-@` representation was bound, so a GUI
  Ctrl+Space in char mode fell through to the global `set-mark-command`.
- CJK and other fallback glyphs now claim cell space correctly, and fallback
  glyph scaling is clamped independently for ascent and descent.  This prevents
  rows from growing or shrinking when tall glyphs (for example status-line
  symbols) blink in and out.
- `evil-ghostel` now forwards `<delete>` correctly inside alt-screen TUIs;
  previously it could edit the rendered buffer locally and then reappear on the
  next redraw.
- Read-only/copy-mode exits and minibuffer-close reanchoring no longer try to
  anchor stale windows or non-live/frozen Ghostel terminals.
- A left-click that only focuses a Ghostel window — bringing the frame to the
  foreground from another application or Emacs frame, or selecting an unfocused
  window in the current frame — is now treated as a pure focus click and never
  enters copy mode (#403).  It snaps point to the live cursor and stays in
  semi-char.  This closes every path that previously froze such a click:
  - The refocus click is detected from the focus-in event itself rather than a
    tracked focus transition, so it keeps working when the window system's focus
    state is stale — notably on macOS (NS), where a dropped focus-out can leave
    `frame-focus-state' stuck reporting focus and previously made every refocus
    click enter copy mode after a while.
  - A tiny involuntary pointer movement that makes Emacs report the click as
    `drag-mouse-1' instead of `mouse-1' selects nothing, so the micro-drag is
    handled like a plain single click rather than a region drag.
  - Selecting a previously-unselected window leaves an empty region active, whose
    activation the command loop finalized after the press handler returned;
    `ghostel--mark-activated' now ignores mark activations that originate from the
    mouse handlers (gating on `this-command'), so that deferred activation no
    longer freezes the buffer.  Mouse selection stays governed by
    `ghostel-mouse-drag-input-mode' alone.

### Internal
- Benchmark and dape helper tooling were updated, and PTY lifecycle coverage now
  exercises both Emacs and native backends.

## [0.34.0] — 2026-06-08

### Added
- `ghostel-ime-mode`, an opt-in buffer-local minor mode that forwards text
  committed by Emacs Lisp input methods — Quail-style methods such as Korean
  Hangul, and Japanese/Chinese — to the PTY, so characters committed by a
  direct `self-insert-command` reach the shell instead of being erased on the
  next redraw.  Enable with `:hook (ghostel-mode . ghostel-ime-mode)`.  Core
  gains a generic `ghostel-inhibit-redraw-functions` hook to defer redraws
  mid-composition.
- Undo now works on the input line during line-mode; renderer and internal
  line-mode buffer mutations are shielded from the undo list.

### Changed
- A plain single left-click in an already-selected window now switches input
  mode per `ghostel-mouse-drag-input-mode` (default `copy`), restoring
  click-to-copy.  A click that focuses a previously-unselected window stays a
  pure focus click and snaps point to the live cursor.  Set
  `ghostel-mouse-drag-input-mode` to nil for standard click-sets-point.
- Line-mode can now be entered at an OSC 133 shell prompt on the alternate
  screen (for example a prompt inside tmux/screen); `C-u C-c C-l` forces entry,
  otherwise line-mode arms and advertises the override.
- `C-]`, `C-/`, and their `C-M-` variants are now forwarded to the shell in
  semi-char/char mode (readline character-search and undo) instead of being
  captured by Emacs (#380).
- Read-only mode now exits immediately on explicit input.

### Fixed
- Bare LF on the primary screen now preserves the cursor column instead of
  being normalized to CRLF.  The emulator no longer synthesizes a carriage
  return: cooked-mode `\n` is turned into CRLF by the PTY's ONLCR (enabled by
  `stty sane` in the spawn wrapper), and raw-mode applications that emit a bare
  LF mean a column-preserving linefeed.  This fixes inline TUIs (bubbletea /
  lipgloss apps such as the Antigravity `agy` CLI) whose banners position with
  column-preserving LF plus relative cursor-back, which previously collapsed to
  the left margin (#388).
- ghostel buffers now redraw immediately when shown, avoiding a stale display.
- Viewport anchoring no longer breaks when the mode-line is disabled in a GUI
  buffer; the "still anchored" threshold is now measured from the window body
  instead of the whole window (#373).
- Window pixel anchoring falls back to line-count anchoring on GUI Emacs 28,
  where the Emacs 29 cons `FROM` argument to `window-text-pixel-size` is
  unsupported and previously broke the anchor.
- `q` no longer leaks `kill-current-buffer` into the shared semi-char keymap
  after an eshell visual command exits (#372).
- `compilation-finish-functions` now run before ghostel's final mode switch, so
  buffer-local continuation state installed by those hooks survives.
- Corrected the `ghostel-eval-cmds` defcustom type.

### Internal
- Added glyph metrics caching and switched window pixel anchoring to accurate
  text metrics.

## [0.33.0] — 2026-06-04

### Changed
- OSC 7 directory reports now only update the buffer directory when the
  reported directory actually changes, avoiding redundant directory-change
  work.

### Fixed
- Updated libghostty, fixing rendering of emoji such as the pilot emoji.
- Immediate redraws now clear pending redraw timer bookkeeping, avoiding stale
  delayed-redraw state.

### Internal
- Kitty graphics Elisp was split into `ghostel-kitty.el`.
- Native module internals were simplified: CRLF patching moved into the handler
  path, Emacs API helper/registration code was refactored, and `sys.zig` was
  removed.
- Flaky compile and shell tests were hardened.

## [0.32.0] — 2026-06-02

### Added
- `ARCHITECTURE.md` now documents Ghostel's design and its architectural
  trade-offs against other Emacs terminal packages.

### Changed
- Automatic buffer renaming now goes through `ghostel-buffer-name-function`,
  a side-effect-free function called for both OSC 2 title changes and OSC 7
  directory reports.  It receives the terminal title and returns the buffer
  name to use, or nil to leave it unchanged; Ghostel performs the rename,
  buffer-name uniquification, and the "don't clobber a manually renamed
  buffer" guard.  `ghostel-set-title-function` remains as an obsolete alias.
- `ghostel-mode` word boundaries now match Ghostty's terminal selection
  defaults, so double-click selection, word motion, Evil text objects, and
  word search treat paths, hostnames, and similar terminal text as single
  words.  The new `ghostel-word-boundary-string` custom option can be changed
  live.
- Rendering now writes directly to the terminal buffer instead of maintaining
  an Elisp side buffer, substantially improving throughput.

### Fixed
- Mouse drags in alt-screen applications with mouse tracking enabled (for
  example vim with `:set mouse=a`) now stream motion events live instead of
  updating only on release.  The final drag event is sent as a release, which
  also fixes button-release reporting for basic mouse tracking.
  Fixes [#349](https://github.com/dakra/ghostel/issues/349).
- Multi-codepoint/composed characters now select the correct glyph when
  computing display metrics.
- Point, mark, and window-start/scroll positions are preserved by the native
  renderer across redraws and resizes.

### Internal
- OSC 8 link handling now stores URIs directly in text properties and compares
  link IDs in the renderer, reducing duplicated state between libghostty and
  the materialized buffer.
- Renderer state restoration moved into Zig and the Elisp redraw path was
  simplified around the new invariants.
- Link, glyph, scroll, shell-integration, and buffer-renaming tests were
  expanded/reorganized.
- `make package-lint` now provisions its own dependencies in an isolated
  package directory, so it can run standalone outside CI.
- Development tooling now uses `lldb-dap` for dape debugging.

## [0.31.0] — 2026-05-28

### Added
- The `:Char` / `:Line` / `:Copy` / `:Emacs` input-mode lighter in
  `mode-line-process` now has a `help-echo` tooltip (reflecting the
  user's bindings and the live `ghostel-readonly-fast-exit` setting),
  a `mode-line-highlight` mouse-face, and a `mouse-1` binding that
  exits the mode (back to semi-char for char/line; back to the
  pre-readonly mode for copy/emacs).
  Closes [#329](https://github.com/dakra/ghostel/issues/329).

### Changed
- Copy and Emacs modes are now symmetric mode toggles.  Under the
  default `ghostel-readonly-fast-exit`, `C-c C-e` and `C-c C-t` were
  repurposed as exit shortcuts, so the eat-style mode-switch matrix
  did not work from those modes (e.g. `C-c C-e` in copy mode exited
  to semi-char instead of switching to Emacs mode).  `C-c C-e` now
  toggles Emacs mode and `C-c C-t` toggles copy mode from every
  read-only mode; the fast-exit affordances (`q`, `C-g`,
  self-insert) are unchanged.
  Fixes [#342](https://github.com/dakra/ghostel/issues/342).
- `ghostel-keymap-exceptions` now takes effect when customized after
  the package has loaded.  The semi-char keymap was populated once at
  load time, so `use-package :config` + `add-to-list` had no effect;
  a `:set` handler now rebuilds the keymap in place (preserving the
  keymap object's identity so buffer-local references stay valid).
  Related [#327](https://github.com/dakra/ghostel/issues/327).

### Fixed
- Evil insert-state Ctrl passthrough stays active in alt-screen apps
  (vim, less, htop).  It used `evil-ghostel--active-p`, which
  intentionally returns nil under DECSET 1049, so `C-u` fell back to
  Evil's insert binding and deleted buffer text instead of reaching
  the terminal.  A narrower passthrough predicate remains active in
  semi-char mode during alt-screen sessions.
- Reading large output (e.g. `rg` over a big tree in `emacs -nw`) no
  longer pops the debugger for users with `debug-on-error` set.
  `extractStringAlloc` now probes the required size with a NULL
  buffer before copying instead of optimistically reusing the
  existing buffer, which raised `memory-buffer-too-small` on every
  chunk past the previous high-water mark.
  Fixes [#338](https://github.com/dakra/ghostel/issues/338).
- Mouse double/triple-click now selects the word/line and the
  selection is protected.  `ghostel-mouse-release-or-set-point`
  forwards PROMOTE-TO-REGION to `mouse-set-point` so the
  word/line selection from the down-event survives, and a
  multi-click in semi-char mode switches to the input mode configured
  by `ghostel-mouse-drag-input-mode` so a redraw can't extend the
  highlight to the cursor.
  Fixes [#337](https://github.com/dakra/ghostel/issues/337).
- Alt-screen rendering corrected: the alt screen is now treated
  separately from the primary screen (it has scrollback that must not
  be rendered), and a resize on a no-scrollback screen forces a full
  rebuild.
- Cursor-line padding is now rendered precisely.
- `M->` in emacs and copy modes stays in isearch during motion.
  `ghostel-readonly-end-of-buffer` lacked an `isearch-motion`
  property, so with `isearch-allow-motion` on it exited search and
  jumped to point-max instead of moving to the last match like the
  global `end-of-buffer`.
  Fixes [#327](https://github.com/dakra/ghostel/issues/327).

### Internal
- Buffer terminal initialization centralized; `ghostel--init-buffer`
  no longer clears title/identity bookkeeping, so OSC 2 sequences
  cannot auto-rename a user-renamed buffer on re-init.
- Property-based renderer testing expanded: resizing operations and a
  dape test-running helper for the Hypothesis suite, alt-screen
  regression tests, more tests routed through
  `ghostel-test--with-terminal-buffer`, and redraw invalidation logic
  factored out into its own path.
- `extractString` / `extractStringAlloc` now return errors instead of
  null, and avoid a debug-mode free of a wrong-length slice.

## [0.30.0] — 2026-05-25

### Changed
- **Breaking:** `ghostel_cmd` (shell helper) now emits `OSC 52;e`
  instead of `OSC 51;E`.  Libghostty parses OSC 51 into an action
  the standard handler ignores, so the elisp-eval extension never
  reached ghostel's callback through normal action dispatch — the
  old code worked around this with a post-write byte scanner.  The
  extension now rides on OSC 52 with a reserved `kind` byte (`e`),
  which libghostty dispatches directly to ghostel's handler.
  Scripts that hand-roll the legacy `\e]51;E…\e\\` sequence will
  silently no-op; update to `\e]52;e;…\e\\` or call the bundled
  `ghostel_cmd` helper.  The post-write byte scanner is gone; the
  OSC 52 path is parsed by libghostty and now reassembles payloads
  split across read boundaries (slow producers, SSH).
- Rendering now tracks scroll position and row eviction via
  libghostty's pin/page primitives instead of the previous
  heuristic.  The old method had corner cases that triggered
  unnecessary full rebuilds; the new path keeps incremental
  updates correct across scrollback growth and eviction.

### Fixed
- `ghostel-next-hyperlink` / `ghostel-previous-hyperlink` now
  dedupe by OSC 8 `id=`, so a single logical URL split across
  multiple cell runs (e.g. a URL wrapped across rows inside an
  ASCII box) is visited once instead of once per chunk.  As a
  side effect, two adjacent cells pointing to different OSC 8
  hyperlinks no longer merge into a single style run that
  clobbered the second link's text properties.
  Fixes [#125](https://github.com/dakra/ghostel/issues/125).
- `M-<punct>` and `M-<digit>` keys (e.g. `M-.`, `M-/`, `M-;`,
  `M-1`) no longer drop silently when libghostty's encoder
  returns no output.  The raw fallback in
  `ghostel--raw-key-sequence` previously only covered meta +
  lowercase a–z; it now emits ESC + char for the full printable
  ASCII range, matching legacy alt encoding (zsh/readline
  `M-.` → insert-last-word, etc.).
- Scrollback eviction no longer drops rows incorrectly when the
  active pin lands at the top of the screen — found via
  property-based testing.  Related viewport rendering paths were
  hardened against over/underflow.

### Internal
- Property-based renderer testing via Hypothesis
  (`test/hypothesis/`), with CI replay of captured failure cases
  as regression tests.
- Renderer hardening: debug assertions on `rows_in_buffer`,
  over/underflow guards, consolidated renderer tests, CSI 3J
  same-count refill regression test, fix for the debug
  finalizer setup.
- Emacs function registration refactored to be declarative with
  the function body next to its metadata, and `link_id` folded
  into `CellProps` so OSC 8 metadata lives in one place.
- `EMACSFLAGS` now forwarded into the Hypothesis driver and
  small development utilities added under `tools/`.

## [0.29.0] — 2026-05-23

### Added
- `ghostel-comint-mode` (and `global-ghostel-comint-mode`)
  replaces `ansi-color-process-output` with a full libghostty VT
  parser as a comint preoutput filter.  Handles truecolor /
  256-color SGR, italic / faint / strikethrough / overline, curly /
  dotted / dashed / double underline (including colon-separator
  forms), underline colour, OSC 8 hyperlinks (reusing
  `ghostel-link-map` so clicks dispatch by URI scheme), OSC 7
  working-directory reports, and silently consumes DCS / APC / SS3
  without leaking bytes.  Unstyled runs inherit the comint
  buffer's default face; inverse is emitted as `:inverse-video t`.
  When `font-lock-mode` is on, the filter swaps `face` for
  `font-lock-face` to survive font-lock's unfontify pass.
  Ref [#278](https://github.com/dakra/ghostel/issues/278).
- `ghostel-glyph-scale-floor` buffer-local defcustom (number,
  0.0–1.0, default 0.0) clamps the computed glyph scale from
  below.  At 0.0 the existing strict-grid behaviour is unchanged;
  at 1.0 CJK and other fallback glyphs render at natural font
  size at the cost of slightly taller rows.  Being buffer-local,
  different ghostel buffers can use different settings.
  Closes [#298](https://github.com/dakra/ghostel/issues/298).
- Semi-char mode now forwards `M-<digit>`, `M-<punct>`, and
  `M-<uppercase>` (plus `M-SPC`) to the terminal.  Previously the
  `M-` loop only covered `?a..?z`, so `M-.`, `M-1`, `M-/`, `M-;`,
  etc. fell through to Emacs global commands instead of reaching
  the shell.  CSI/SS3 escape-sequence prefixes (`M-[`, `M-O`) are
  still left to TTY input decoding.
  Fixes [#314](https://github.com/dakra/ghostel/issues/314).

### Fixed
- `ghostel--filter-soft-wraps` was O(n²) due to one-character-at-
  a-time string concatenation, causing multi-second freezes when
  copying large selections (e.g. full scrollback) with `M-w` in
  copy mode.  Replaced with a chunk-collection approach.
- Skip rows-only resize while a minibuffer is active.  Fish (and
  other shells with `fish_handle_reflow` on) repaints its prompt
  on every SIGWINCH; a `consult-buffer` / `M-x` cycle grew then
  shrank the body of the window showing the ghostel buffer,
  producing two prompt repaints in quick succession.  The deferral
  hits the no-change branch after the minibuffer closes.  Col
  changes and non-minibuffer vertical resizes still propagate so
  `$LINES` stays accurate.
  Fixes [#268](https://github.com/dakra/ghostel/issues/268).
- CRLF normalization is now skipped on the alternate screen.  Apps
  like tmux, vim, and less emit VT-correct sequences where a bare
  `\n` means LF; normalizing them to `\r\n` corrupted their
  layout.  Detection covers all three alt-screen entry modes
  (DECSET 47 / 1047 / 1049).
- Default-styled text is no longer invisible on the Linux
  framebuffer TTY.  `ghostel--face-hex-color` only recognised the
  literal `"unspecified"` string as unset, so on a TTY frame where
  the default face reports `"unspecified-fg"` / `"unspecified-bg"`
  it fell through to a `"#000000"` fallback for both attributes,
  collapsing fg and bg to black-on-black.  All three sentinel
  strings are now recognised; the last-resort fallback splits into
  white for `:foreground` and black for `:background`.
  Fixes [#297](https://github.com/dakra/ghostel/issues/297).

### Changed
- Removed `ghostel-readonly-recenter` — no longer needed now that
  scrollback is materialized into the buffer.
  Fixes [#310](https://github.com/dakra/ghostel/issues/310).

### Internal
- Switched the Zig module from libghostty-vt's C API to the Zig
  API.  OSC actions are now routed through a custom
  `GhostelHandler` that wraps libghostty's standard terminal
  handler and overrides the OSC arms (semantic_prompt,
  color_operation, report_pwd, clipboard_contents,
  show_desktop_notification, progress_report).  This deletes ~395
  lines of parallel byte-scanning code in `module.zig` in favour
  of reading ghostty's parsed Command values directly.  Only
  OSC 51 still uses a bespoke scan since it is ghostel's
  elisp-eval extension.
- Style-to-face translation extracted into `src/style_face.zig`
  and shared between the renderer and the `ghostel-comint` stream
  filter so they stay in sync.
- Debug builds use `DebugAllocator` for corruption and leak
  detection; allocator is deinit'd on atexit and the false-positive
  leak check was tightened.  Allocators are now injected via
  Zig's best-practice pattern: terminal stores `alloc` at init,
  `Renderer`/`RowContent` accept `alloc` parameters (unmanaged
  pattern), and `module.zig` has a single top-level `alloc`
  binding instead of scattered `c_allocator` references.
- Zig refactors: `Terminal` renamed to `GhostelTerm` to avoid
  confusion with ghostty's `Terminal` type; `Renderer` stores
  `gt.Terminal`; the `force_full` argument is replaced by setting
  the render state dirty; debug-mode userptr freeing is
  generalized beyond `GhostelTerm`; Zig log output also goes to
  stderr.

### Added
- Multi-terminal navigation commands: `ghostel-next`,
  `ghostel-previous`, `ghostel-list-buffers`, plus project-scoped
  variants `ghostel-project-next`, `ghostel-project-previous`, and
  `ghostel-project-list-buffers` for cycling and picking among
  ghostel buffers.  Project membership is configurable via the new
  `ghostel-project-buffer-scope` defcustom.

### Changed
- Font metrics are now cached during redraw, avoiding repeated
  font-attribute lookups per frame.

### Internal
- Tests run in parallel via per-file Make targets, with stamps
  under `.build/tests/`.  Recommended invocation:
  `make -j$(nproc) all` (or `-j$(sysctl -n hw.ncpu)` on macOS).
  Wall-clock improvements on a warm cache: `test` 12.5s → 6.6s,
  `test-native` 11.2s → 7.8s, `all` 10.4s → 8.4s.  New
  `EMACSFLAGS` variable lets callers inject load paths.
- The monolithic `ghostel-test.el` was split into 16
  per-topic `ghostel-*-test.el` files plus a shared
  `ghostel-test-helpers.el`.  Native-only tests carry
  `:tags '(native)`; the runner selects via `(tag native)` /
  `(not (tag native))` instead of a hand-maintained whitelist.
- A review pass over the split fixed ~30 tests that were passing
  for the wrong reasons (tautological assertions, mocks of the
  function under test, references to symbols that no longer exist).

## [0.27.0] — 2026-05-18

### Added
- `ghostel-query-before-killing` defcustom controls whether Emacs
  asks for confirmation before killing a live ghostel buffer or
  exiting Emacs while one is running.  Defaults to `auto`: quiet
  at the shell prompt, queries while a command is running (via
  OSC 133 C/D markers).  Set to `t` for always-on confirmation,
  `nil` to restore the previous never-query behavior.
  Closes [#288](https://github.com/dakra/ghostel/issues/288).
- `ghostel-macos-login-shell` defcustom (default `t` on Darwin)
  wraps the shell via `/usr/bin/login -flp $USER` so `~/.zprofile`
  and `~/.bash_profile` are sourced, matching Terminal.app and
  Ghostty.  Skipped for TRAMP, non-Darwin, and `ghostel-exec`.
  `ghostel-shell` now also accepts a list form (program + args)
  so users can pass extra flags like `'("/bin/zsh" "--login")` on
  any platform.
  Fixes [#285](https://github.com/dakra/ghostel/issues/285).
- `ghostel-prompt-regexp` defcustom provides a prompt-detection
  fallback for `ghostel-input-start-point` and
  `ghostel-beginning-of-input-or-line` when OSC 133 shell
  integration isn't available (raw zsh, Python REPL, sqlite3,
  ssh into unprovisioned hosts).  Default recognizes `$ # % > >>>`
  and themed prompts (`λ ❯ ➜ →`).  OSC 133 still wins when
  present.
- Public cursor-state API for integrations:
  `ghostel-input-start-point`, `ghostel-cursor-point`, and
  `ghostel-point-on-cursor-row-p`.  Pure state reads — safe to
  call from any input mode.

### Fixed
- Bash's OSC 7 cwd report now uses the real kernel hostname via
  `${var@P}` on `\H` (bash 4.4+) instead of `$HOSTNAME`.  Toolbox
  and container runtimes export `$HOSTNAME` with a value that
  disagrees with `gethostname(2)`, so Emacs's `(system-name)` saw
  a mismatch and TRAMP fired on every `cd`.  Falls back to
  `$HOSTNAME` on bash <4.4.
  Fixes [#276](https://github.com/dakra/ghostel/issues/276).
- OSC 7 is now emitted *after* any user-supplied `PROMPT_COMMAND`
  / `precmd_functions` entries, so competing emitters (e.g.
  Fedora's `/etc/profile.d/vte.sh`) can no longer overwrite
  ghostel's cwd report and cause buffers to be misclassified as
  remote.
- Auto-composition is now disabled on TTY frames to fix the
  off-by-one column drift caused by emoji + VS-16 grapheme
  clusters (e.g. 🗂️) — Emacs's `char-width` reports 1 while
  VS-16-honoring terminals paint 2 columns, desyncing the TTY
  screen cache.  GUI frames are untouched.
  Fixes [#274](https://github.com/dakra/ghostel/issues/274).
- Glyphs that occupy a narrow cell but have an empty cell after
  them are now promoted to wide on render, so emoji and other
  ambiguous-width sequences land in the right column even when
  upstream width tables disagree with the terminal.

### Changed
- Internal Zig refactor of `adjustGlyphs` and `putTextProperty`;
  no user-visible change beyond the width promotion above.
- Removed dead debug entry points (`fnDebugState`, `fnDebugFeed`)
  and unused render state fields.

## [0.26.0] — 2026-05-13

### Added
- `ghostel-bold-color` defcustom mirrors Ghostty 1.2.0's
  `bold-color`: bold text with palette colors 0-7 is mapped to
  the 8-15 bright slot when set to `bright` (the default), or
  rendered in a fixed face/color when set to a color spec.
  Existing terminals pick up the change live.

### Changed
- `S-<insert>` is bound to `ghostel-yank`, matching the
  conventional alternative-paste binding in browsers, terminal
  emulators, and file managers.  In the same pass, semi-char and
  read-only maps layer `<remap> <yank>` so any key Emacs binds to
  yank globally — `s-v` on macOS plus user rebinds — routes
  through `ghostel-yank` without per-key entries.  `C-y` stays
  explicitly bound so user rebinds of the global yank key cannot
  break ghostel paste; line mode keeps Emacs's regular yank so
  paste lands in the input region.
  Closes [#263](https://github.com/dakra/ghostel/issues/263).
- `ghostel-readonly-RET-or-exit-and-send` now honours
  `ghostel-readonly-fast-exit` when point is on a hyperlink:
  read-only mode exits first (capturing the URL beforehand, since
  exit moves point and `file://` / `fileref:` links switch
  buffers), then the link is opened.  Previously RET on a
  hyperlink left the buffer in copy mode.

### Fixed
- Exiting read-only modes (copy, Emacs) no longer flickers.
  The viewport snap-back to the live terminal cursor used to
  schedule an async redraw; in the gap, Emacs would observe
  point at `point-max` and recenter, only for the timer to
  anchor the window back a few ms later.  The redraw is now
  synchronous, so the window is anchored to the active viewport
  before redisplay runs.
  Fixes [#269](https://github.com/dakra/ghostel/issues/269).
- Upgrading the elisp package ahead of the native module no
  longer requires two restarts.  build.zig writes a
  `ghostel-module.version` sidecar next to the binary, and
  `ghostel--load-module` consults it before `module-load` and
  refuses to map a stale `.so` — so a fresh install loads in the
  same Emacs process.  The interactive version check also runs
  unconditionally on existing installs without a sidecar, so
  `M-x ghostel` surfaces the install prompt instead of only
  warning.
  Fixes [#256](https://github.com/dakra/ghostel/issues/256).

## [0.25.0] — 2026-05-11

### Added
- `ghostel-mouse-drag-input-mode` defcustom: a bare left click in
  semi-char mode no longer freezes the buffer into copy mode on
  press — it only focuses the window and sets point, matching
  standard Emacs behavior.  A drag switches input mode on release
  so streaming output cannot clobber the selection; the target
  mode is `copy` (default; freezes redraws, selection is
  rock-solid), `emacs` (terminal keeps streaming, buffer becomes
  read-only), or `nil` (stay in semi-char; scrollback selections
  still survive, selections over live-redrawn rows can be lost).
  Closes [#257](https://github.com/dakra/ghostel/issues/257).
- `ghostel-module-directory` defcustom selects where the compiled
  native module lives.  Defaults to the package directory (current
  behavior).  Set it to a path outside the package manager's tree
  (e.g. elpaca's `repos/` dir, which gets deleted on rebuild) to
  keep the artifact stable across rebuilds.
  `M-x ghostel-module-compile` builds in the resource root and
  moves the artifact into the configured directory.
- `ghostel-password-prompt-debounce` defcustom (default 0.2s).
  Ghostel's canonical+!echo heuristic is checked on every redraw
  (sub-100ms), so short-lived termios flips that ghostty's 200ms
  poller silently misses became user-visible `read-passwd` popups
  in ghostel.  The rising edge is now debounced: the source chain
  only runs if the heuristic still reports password mode at the
  deadline.  Sub-debounce flickers leave nothing behind except a
  brief mode-line indicator flash, matching ghostty's transient
  lock-icon UX.

### Changed
- `ghostel-download-module` and `M-x ghostel-module-compile` now
  write to a sibling temp file and `rename-file` it into place.
  Renaming swaps the directory entry to a fresh inode, so any
  Emacs still holding the previous file mmap'd retains a valid
  mapping — updating the native module is safe under a running
  Emacs and no longer risks crashes on the next code-resolution.
  Fixes [#247](https://github.com/dakra/ghostel/issues/247).
- Native module internals: function-registration table reworked
  for readability and alphabetical ordering; error/logging
  helpers unified; ergonomic variadic `Env.f("fn", .{…})` replaces
  the per-arity `callN` family; remaining legacy interop usage
  removed.  No user-visible API changes, but the Elisp/native
  pairing changes — the bundled `ghostel-module-version` is bumped
  and `ghostel--minimum-module-version` is now `0.25.0`.  Use
  `M-x ghostel-download-module` after updating ghostel.el.

### Fixed
- An open `read-passwd` minibuffer that ghostel opened auto-cancels
  on the falling edge of the heuristic.  When the foreground
  program exits (e.g. the user kills sudo with `C-c C-c` sending
  Ctrl+C), the prompt now disappears with it instead of waiting
  for the user to dismiss it.  Three gates ensure ghostel only
  aborts its own minibuffer (active-flag, minibuffer depth, and
  the minibuffer-buffer identity captured at open time), so
  unrelated concurrent minibuffers are never closed.

## [0.24.0] — 2026-05-10

### Added
- OSC 133 imenu integration: each shell prompt with OSC 133
  `A`/`B`/`C` markers becomes an imenu entry of the form
  `<cwd>  <command>`, with the target landing on the prompt
  prefix's start.  Composes with `consult-imenu`, `imenu-list`,
  evil's `]m`/`[m`, etc.  The cwd is captured at command-start
  (OSC 133 `C`) and tracked chronologically, so prompts issued
  before a `cd` keep the correct directory in their imenu label.
  Selecting an entry leaves line and copy modes untouched; only
  semi-char and char modes switch to Emacs mode so point can move.
- `ghostel-readonly-fake-cursor`: shows a thin hint cursor at the
  live terminal-cursor position when point has moved away in copy
  or Emacs mode, so the next-output spot stays visible while the
  user reads scrollback.  Faces `ghostel-fake-cursor` (hollow) and
  `ghostel-fake-cursor-box` (solid) are user-customisable; the
  hollow box uses `:line-width (-1 . -1)` to stay inside the
  character cell and not reflow the line.  Updates are driven by
  `pre-redisplay-functions` installed buffer-locally on read-only
  entry — no `post-command-hook` overhead.
- Click-to-focus in semi-char mode no longer drops the press when
  no app is tracking the mouse.  Left mouse-1 falls back to
  `mouse-drag-region` / `mouse-set-point` / `mouse-set-region`
  when no DEC mouse-tracking mode (1000/1002/1003) is active, so
  click-set-point and drag-to-select work in any input mode.
  (Refined further in 0.25.0 by `ghostel-mouse-drag-input-mode`.)
- `ghostel-detect-password-prompts` — defcustom (default t) gating
  the entire password-prompt detector.  `ghostel-compile` binds it
  to nil buffer-locally because compile buffers run with
  `stty -echo` to avoid double-echoing the command, which puts the
  pty into the exact `canonical+!echo` state the libghostty
  heuristic matches — leaving detection on would pop a
  `read-passwd` minibuffer at the start of every compile.
- `M-x ghostel-debug-password-events-show` — view the last 32
  password-prompt rising edges with the detection arm that fired
  (`zig` or `regex`), the cursor row text, and the buffer's
  remote-shell state.  Capture is enabled by
  `M-x ghostel-debug-start`; the events buffer survives
  `ghostel-debug-stop`.

### Changed
- `ghostel-password-prompt-regex` now defaults to
  `comint-password-prompt-regexp` (the same regex `M-x shell`,
  `M-x term`, and eshell use).  The previous default
  (`[Pp]ass\(?:word\|phrase\)[^:]*:[ \t]*\'`) was too permissive
  and caused the false-positive class fixed below.  Users who
  want to extend the regex should prefer customizing
  `comint-password-prompt-regexp` itself (BEFORE loading ghostel)
  so other Emacs facilities benefit from the same change.
- `ghostel--password-prompt-detected-p` now returns nil or a
  symbol (`zig` or `regex`) identifying which arm fired.
  Truthiness is unchanged for callers that treat the return
  value as a boolean.
- Wide-char / emoji rendering is now handled in the native module
  rather than by an elisp pixel-compensation pass.  The renderer
  reports glyph adjustments directly, so emoji-heavy output no
  longer trips the `string-width` vs. pixel-width divergence that
  used to overflow the window.  Eliminates the `ghostel--has-wide-chars`
  / `ghostel--compensate-wide-chars` round-trip on every redraw.
- Native module switched to strict Zig error handling: bare
  `catch {}` swallow sites in color, PWD-update, and render-state
  paths now log to `*Messages*` (or signal) with the unified
  `ghostel: [function] failed: [error]` pattern.  Cursor tracking
  no longer goes through accessor methods that clobbered render
  state; the renderer publishes cursor position as buffer-local
  variables matching what was rendered, which removes a class of
  subtle bugs.

### Fixed
- Spurious `read-passwd` minibuffer prompts when the terminal
  cursor row happened to end in `Password:` / `passphrase:` —
  typing `echo Password:` at a local shell prompt would pop a
  password prompt because the regex fallback ran unconditionally
  whenever the libghostty heuristic returned nil, and the regex
  itself was anchored only at end-of-line.  The fallback regex
  now defaults to `comint-password-prompt-regexp` (structurally
  anchored at start-of-line or after curated trigger words), and
  the fallback only runs when `ghostel--remote-shell-p` indicates
  a remote shell — local raw-mode TUIs (vim, less, htop) don't
  risk false positives from coincidental cursor-row content.
  Fixes [#244](https://github.com/dakra/ghostel/issues/244).
- `consult-line`, `consult-imenu`, and other `goto-char` jumps in
  line mode no longer snap back to the live cursor.  The
  minibuffer that consult opens resizes the ghostel window twice
  (open + close); each resize forced a redraw whose anchored-window
  predicate ignored `window-point`, so the closing resize
  re-anchored the window and yanked point back to the live cursor.
  The predicate now also checks `window-point` against the anchor.
- Several evil-ghostel operator and motion bugs in multi-line TUI
  input and single-line shell prompts:
  `dd` / `cc` on a non-cursor row of a multi-line input (pi,
  ipython, prompt_toolkit) now deletes the line at point instead
  of the last line; `cw` lands at the start of the deleted range,
  not at column 0; `dw` on a single trailing space treats it as
  content in single-line ranges; `0` / `^` skip the shell prompt
  prefix on prompt rows and fall through to the original motion
  on scrollback / output rows; `^` / `$` / `0` followed by `i`
  preserves the navigated column across scrollback; column
  navigation in normal state survives idle redraws on the
  cursor's line; `evil-replace`'s paste count matches its delete
  count when trailing whitespace is stripped.  Underneath: cursor
  delta math now subtracts scrollback before comparing buffer to
  viewport rows, and a new `evil-ghostel--shadow-cursor` models
  the pending terminal cursor between PTY-bound key emits and
  their echo back through the redraw.
  Fixes [#218](https://github.com/dakra/ghostel/issues/218).
- `<mouse-2>` in semi-char or copy mode no longer drops the click
  when no app is tracking the mouse.  Middle-click now feeds
  `gui-get-primary-selection` to `ghostel--paste-text` (bracketed
  paste at the live prompt) when no tracking mode is on, matching
  the standard X primary-selection paste on Linux.  In copy /
  Emacs mode with `ghostel-readonly-fast-exit` on, the click
  exits to the prior input mode first so the paste lands at the
  prompt; with fast-exit off it pastes in place, mirroring
  `ghostel-yank` / `C-y`.
- RET in copy mode no longer dies in `text-read-only` after
  `ghostel-mouse-press-or-copy-mode` flipped the buffer into copy
  mode on a focus click.  RET now exits read-only mode (when
  `ghostel-readonly-fast-exit` is on) and forwards a CR via the
  encoder; hyperlinks under point still call
  `ghostel-open-link-at-point` as before.  `C-c C-l` was renamed
  to `C-c M-l` so the parent map's `ghostel-line-mode` binding is
  no longer shadowed.
  Fixes [#251](https://github.com/dakra/ghostel/issues/251).

## [0.23.0] — 2026-05-08

### Added
- Eat-style input modes.  Five modes replace the old semi-char /
  copy duality: `semi-char` (terminal-focused default), `char`
  (send-everything, including most Emacs prefixes), `emacs` (live
  but read-only — buffer keeps streaming while `isearch`, `occur`,
  `M-x`, mark + `M-w` all work over the same vocabulary that reads
  any Emacs buffer), `copy` (frozen, point-based navigation), and
  `line` (shell-style local edit, send whole lines on RET, with
  filename / env / executable / pcomplete / `bash-completion`-backed
  TAB completion, history ring on `M-p` / `M-n`, `C-c C-c` interrupt,
  and `C-d` EOF on empty input).  Mode switches live in a slim base
  map so they work from every live mode: `C-c C-j` semi-char,
  `C-c M-d` char, `C-c C-e` emacs, `C-c C-t` copy, `C-c C-l` line,
  `M-RET` escape from char mode.  Prompt navigation (`C-c M-n` /
  `C-c M-p`) auto-enters Emacs mode so the terminal keeps running
  while the user jumps between prompts.  Line mode discovers the
  prompt via the terminal cursor (new
  `ghostel--cursor-row-char-offset` Zig binding that walks the
  cursor row's cells so wide / box-drawing glyphs map correctly),
  refined by OSC 133 markers when present, so it works in REPLs
  and shells without integration loaded.  README gains an "Input
  modes" section and `evil-ghostel` now gates on semi-char
  specifically.  Closes
  [#40](https://github.com/dakra/ghostel/issues/40).
- `ghostel-compile` is now read-only by default, mirroring
  `M-x compile`: `g` reruns, `n` / `p` walk errors, RET jumps,
  `C-c C-c` jumps, `C-c C-k` interrupts.  `C-u M-x ghostel-compile`
  opens a writable ghostel terminal (the previous default); useful
  for `htop`, `less`, `read -p`, test prompts.  Two new commands
  flip a buffer between states mid-run without restarting:
  `ghostel-compile-switch-to-interactive` (`C-c C-j`) and
  `ghostel-compile-switch-to-readonly` (`C-c C-e`).
  `mode-line-process` shows `:run` / `:run/i` so the current
  state is visible at a glance.  `ghostel-recompile` and
  `M-x revert-buffer` both preserve the launch mode of the source
  buffer; `next-error` / `M-g n` / `M-g p` work mid-run in either
  variant.  `ghostel-compile-global-mode` advice now routes
  `compilation-start CMD t` to a writable ghostel terminal —
  callers asking for the comint variant still get a real TTY,
  just rendered by ghostel.
- Password prompt detection.  When `sudo`, `ssh`, `gpg`, `passwd`,
  etc. ask for a password ghostel pops up `read-passwd` and sends
  the answer through the PTY — the keystrokes never flow through
  Emacs's normal key pipeline, so the password does not land in
  `view-lossage`, the recent-keys ring, or any keyboard-macro
  recording.  Detection mirrors libghostty's heuristic (the slave
  tty is in canonical mode with echo off) via a tiny `tcgetattr`
  Zig binding, with a regex fallback on the cursor row when the
  local tty's echo state can't be observed (remote ssh, programs
  that don't toggle echo).  Mode-line shows ` 🔒Password` while a
  prompt is open, the wire copy of the password is `clear-string`'d
  immediately after the send, and wrong-password retries auto-detect
  via cursor movement.  Customize `ghostel-password-prompt-functions`
  — a chain of `(ROW) -> string-or-nil` sources tried in order — to
  plug in `auth-source` (or Keepass / pass / etc); the
  defcustom docstring includes a TRAMP-aware
  `auth-source-pick-first-password` example.  PR
  [#241](https://github.com/dakra/ghostel/pull/241).
- `ghostel-debug-ghostel`, a wrapper around `M-x ghostel` that
  installs self-removing advice on `ghostel--spawn-pty` and
  `ghostel--start-process` to capture program / args / geometry /
  stty-flags / extra-env / process-environment, the wrapper
  command list passed to `make-process` (caught via `cl-letf*`
  on `make-process` so TRAMP's file handler can't rewrite it
  before capture), per-phase spawn timings, the first ~16 KB of
  PTY output as a `(timestamp . chunk)` event log, and the first
  ~64 sends.  `ghostel-debug-info` renders the capture on a
  single chronological timeline (sends and PTY output
  interleaved) and grows a TRAMP section with `tramp-version`,
  `tramp-terminal-type`, the resolved `tramp-direct-async-process`,
  multi-hop length, and the local-vs-toplevel TERM divergence
  diagnostic that surfaces when `tramp-local-environment-variable-p`
  would silently strip the pushed TERM.
  `C-u M-x ghostel-debug-info` on a remote buffer additionally
  runs a single-round-trip remote probe (`infocmp`,
  `xterm-ghostty` / `xterm-256color` terminfo,
  `~/.local/share/ghostel/terminfo` paths, `/bin/sh` identity,
  remote `bash --version`, `$INPUTRC`, and the first 80 lines of
  `~/.inputrc`).  All capture lives in `ghostel-debug.el` —
  plain `M-x ghostel` sessions are unaffected.
- Local "Key encoding (legacy mode)" section in
  `ghostel-debug-info` that probes a fresh terminal for the
  chords commonly cited in inputrc reports (`C-Backspace`,
  `M-f`, `C-M-f`, `C-M-v`, …) and shows the resulting bytes,
  mirroring `ghostel--send-encoded`'s encoder + raw fallback so
  the output matches what a real keystroke produces.
- `repeat-mode` support for prompt and link navigation:
  `C-c C-n C-n C-n` cycles hyperlinks, `C-c M-n M-n M-n` cycles
  prompts (bare `n` / `p` work after releasing the modifier).
  Internally, eight keymaps in `ghostel.el` are converted from
  `let` / `define-key` blocks to `defvar-keymap`; `compat
  30.1.0.1` is added to `Package-Requires` so `defvar-keymap` is
  available on Emacs 28.

### Changed
- `C-M-<letter>` chords (`C-M-f`, `C-M-v`, …) are now bound in
  `ghostel-mode-map` and routed through libghostty's encoder so
  readline `.inputrc` rules like `"\e\C-f": dump-functions`
  actually fire.  Without the binding, Emacs's `forward-sexp` /
  `scroll-down-command` ran instead of reaching the shell.
  Fixes [#239](https://github.com/dakra/ghostel/issues/239).
- Remote spawns now apply `stty sane` as a baseline (matching
  vterm) instead of the prior per-spawn flag list that omitted
  `echo` on the remote path without `ghostel-tramp-shell-integration`.
  Any upstream that left the PTY with echo cleared (TRAMP env
  stripping, custom remote `/etc/bashrc`, old bash readline) no
  longer produces silent input on the remote shell.  All five
  spawn paths share a single `ghostel--default-stty` constant.
  Fixes [#224](https://github.com/dakra/ghostel/issues/224)
  (third iteration).
- `ghostel--set-buffer-face` now caches the last `(FG . BG)` pair
  and short-circuits the `face-remap` round-trip when the colors
  haven't changed.  The render path called this on every dirty
  redraw, and `face-remap-remove-relative` /
  `face-remap-add-relative` each call `force-mode-line-update`
  internally — measured at ~960 FMLU per 5s with two visible
  buffers running spinners, dropping to ~50 after the cache.  The
  visible symptom was the minibuffer flickering and `C-g` / RET
  taking several attempts to land while output was streaming.

### Fixed
- `ghostel-next-prompt` / `ghostel-previous-prompt` now land
  correctly with the realistic two-property `ghostel-prompt` /
  `ghostel-input` row layout.  `ghostel--prompt-input-start`
  used `skip-chars` heuristics that jumped past the last char +
  newline for any input ending in a single-char arg (e.g.
  `echo b`) and landed on the last word for multi-word commands;
  previous-prompt failed to recognize point inside a
  `ghostel-input` region or at the start of input as "still on
  the current prompt" and snapped back to the same prompt
  instead of the prior one.
- `C-g` in semi-char and char input modes now reaches
  `ghostel-send-C-g` rather than the raw `^G` lambda installed
  by `ghostel--define-terminal-keys`.  The terminal-key loop ran
  on the per-mode child maps and shadowed the parent's `C-g`
  binding, re-introducing
  [#200](https://github.com/dakra/ghostel/issues/200) —
  `deactivate-mark` and the `quit-flag` clear were skipped.
  The loop now skips `?g`, and char mode binds it explicitly.
- `ghostel-readonly-copy` (`M-w` / `C-w`) and the copy-mode
  branch of `ghostel-xterm-paste` now honour
  `ghostel-readonly-fast-exit nil` instead of unconditionally
  exiting copy/Emacs mode on those keys.
- `ghostel-readonly-copy` deactivates the mark like
  `kill-ring-save` does, so `M-w` / `C-w` no longer leaves the
  region highlighted when `ghostel-readonly-fast-exit` is nil.
  Closes [#238](https://github.com/dakra/ghostel/issues/238).
- RET on a `ghostel--detect-urls`-linkified cell no longer
  hijacks the keystroke away from the PTY in the default
  terminal mode.  RET is dropped from `ghostel-link-map`
  (text-property keymaps outrank even
  `emulation-mode-map-alists`) and bound on
  `ghostel-copy-mode-map` instead, so click is still a real
  click in any mode but RET routes to the local map.  Link
  detection on the cursor's own row is now skipped regardless
  of OSC 133 state, so REPLs and shells without integration
  loaded (Gemini CLI, raw bash, …) no longer linkify the typed
  command.
- In evil normal state, output that grew scrollback no longer
  leaves point above the new prompt.  The around-redraw advice
  used to restore point by buffer position; it now tracks the
  buffer line where the previous redraw placed point at the
  terminal cursor and lets the renderer's new placement stand
  when the user has not navigated.  Closes
  [#228](https://github.com/dakra/ghostel/issues/228).
- `ghostel-debug-info` no longer raises `void-variable` on
  Emacs 28/29.  `tramp-direct-async-process` was added in Emacs
  30.1's bundled TRAMP; the variable read is guarded with
  `boundp` and a forward `defvar` quiets
  `byte-compile-error-on-warn` in CI.

## [0.22.1] — 2026-05-04

### Fixed
- Loading `ghostel.el` no longer prompts to download or compile the
  native module under any circumstances.  Previously `ghostel.el`
  consulted `ghostel-module-auto-install` at load time and could open
  an interactive `read-char-choice` prompt — this hung Emacs 31
  `user-lisp/` auto-byte-compile and similar harnesses where a user
  `(setq ghostel-module-auto-install nil)` had not yet been
  evaluated.  Module installation now happens only on an explicit
  user action: `M-x ghostel`, `M-x ghostel-download-module`, or
  `M-x ghostel-module-compile`.  When the module is missing at load
  time the package issues a `display-warning` instead.
  Closes [#231](https://github.com/dakra/ghostel/issues/231).
- No-echo on remote shells launched from a TRAMP `default-directory`
  (`ghostel-tramp-shell-integration nil`).  The previous fix
  rebound `tramp-terminal-type`, which only takes effect on the
  generic `tramp-handle-make-process` path; the ssh-method path
  (`tramp-sh-handle-make-process`) ignores it.  In addition, when
  the local default-toplevel `process-environment` already has
  `TERM=xterm-ghostty` (e.g. Emacs launched from ghostty),
  `tramp-local-environment-variable-p` strips ghostel's pushed
  TERM as "ambient", and the remote shell inherits TERM=dumb from
  TRAMP's connection shell — disabling readline/ZLE/fish line
  editing.

  The per-spawn `/bin/sh -c` wrapper now sets TERM itself on the
  remote, after probing for `xterm-ghostty` terminfo via
  `infocmp`.  Single path covers auto-integration (TERMINFO
  pushed), manual install (system or `~/.terminfo`), and the
  bare case (fall back to `xterm-256color` so echo works).  The
  bogus local TERMINFO path is no longer pushed to the remote.
  Closes [#224](https://github.com/dakra/ghostel/issues/224)
  again.

### Added
- Manual remote-integration setups can now drop the bundled
  `xterm-ghostty` terminfo at `~/.local/share/ghostel/terminfo/`
  alongside the shell scripts (`scp -r etc/terminfo/{x,78}` from
  the local package).  TRAMP-spawned remote shells detect it and
  prepend the directory to `TERMINFO_DIRS` automatically — no
  `tic`, no touching `~/.terminfo`.  README "Option 2: Manual
  setup" updated with the one-shot install recipe.

## [0.22.0] — 2026-05-04

### Added
- `ghostel-pre-spawn-hook`, run inside `ghostel--spawn-pty` just
  before `make-process` with `process-environment` dynamically
  bound to the about-to-be-spawned env.  Hook functions can
  `setenv` to inject entries the child inherits.  Intended for
  integrations like with-editor — with a `with-editor-setup-environment`
  exposed upstream, users can wire Magit's `EDITOR` plumbing into
  ghostel buffers via
  `(add-hook 'ghostel-pre-spawn-hook
            #'with-editor-setup-environment)`.  Fires for both
  `ghostel`/`ghostel-project` and `ghostel-exec` spawns;
  `ghostel-compile` has its own `make-process` and is not covered.
- `evil-ghostel-escape` controls how ESC is routed in evil insert
  state: `auto` (default) inspects DECSET 1049 to send ESC to the
  terminal in alt-screen apps (vim, less, htop, …) and otherwise
  fall back to `evil-normal-state`; explicit `terminal` and `evil`
  values force one or the other.  A toggle command with numeric
  prefix support is also bound.  The terminal-bound ESC snaps to
  the live viewport like every other typed key; the evil-bound
  fallback lands on `evil-force-normal-state` when the user's
  `<escape>` binding is missing or a chord prefix
  ([#215](https://github.com/dakra/ghostel/issues/215)).
- `make bench-e2e` (and a `--e2e` flag on `run-bench.sh`) measures
  whole-pipeline throughput by installing each backend's production
  filter+sentinel on a `cat` subprocess and waiting for full
  quiescence, so the wall clock reflects what users actually feel
  (including ghostel's `delayed-redraw` link detection / anchoring,
  vterm's regex split + decode loop, and eat's deferred queue).
  Composes with `--quick`, `--size`, `--iterations`, and the
  backend-skip flags.

### Changed
- The Zig native module has been broadly refactored ("Zigify
  everything"): libghostty calls are wrapped to be return-value
  oriented rather than out-pointer oriented, errors propagate via
  Zig's `try`/`catch` and error unions instead of C error codes,
  optional absence is distinguished from real errors, and
  per-error logging/handling is consistent across the module
  ([#217](https://github.com/dakra/ghostel/pull/217)).  This is
  internal — no user-visible API changes — but bumps the minimum
  required native module version, so update both ghostel.el and
  the prebuilt `.so`/`.dylib` together.
- Render code is reorganised around a single property-run
  abstraction (prompt cells, input cells, and ordinary content all
  flow through the same path), and uses a new internal
  `FixedArrayList` to cut per-row allocation overhead.  Adds an
  Emacs↔Zig logging/debugging layer used during the refactor and
  available for future native-module work.

### Fixed
- Launching `M-x ghostel` from a TRAMP `default-directory` (e.g.
  after `find-file /ssh:host:`) now produces a usable remote shell.
  Previously TRAMP's `make-process' handler reset TERM to
  `tramp-terminal-type' (default `"dumb"'), which caused
  bash/readline, zsh/ZLE, and fish to disable interactive line
  editing on the remote: typed characters didn't echo, although
  Enter still submitted the line.  Ghostel now rebinds
  `tramp-terminal-type' for its remote spawns to `xterm-256color'
  (or `xterm-ghostty' when `ghostel-tramp-shell-integration' has
  pushed the bundled terminfo), restoring echo and line editing
  ([#224](https://github.com/dakra/ghostel/issues/224)).
- Shell integration survives prompt themes and rcfile assignments
  that overwrite `PROMPT`/`PS1`/`fish_prompt` after ghostel sourced
  its bootstrap.  The OSC 133 A/B markers are now (re)installed
  every prompt cycle — modeled on ghostty's own zsh/bash/fish
  integrations — so powerlevel10k, agnoster, Pure, oh-my-zsh /
  prezto add-zle-hook chains, bash `PROMPT_COMMAND` reassignments,
  and fish themes loaded via `conf.d/` no longer strip the
  prompt-range markers.  Without those markers, the file-path link
  detector linkified user-typed cells and the link keymap's RET
  binding shadowed the normal terminal RET in tty Emacs — pressing
  RET on a typed `cd some/path` opened the link instead of
  executing the command
  ([#199](https://github.com/dakra/ghostel/issues/199)).
- New terminals no longer briefly flash with libghostty's default
  colors before ghostel applies the Emacs theme.  A regression
  test guards against the flicker reappearing
  ([#219](https://github.com/dakra/ghostel/pull/219)).
- `ghostel-keymap-exceptions` now also excludes special keys
  (`<return>`, `<tab>`, `<f1>`, …, including their `S-`/`C-`/`M-`/
  `C-S-`/`M-S-`/`C-M-` variants).  The special-keys binding loop
  in `ghostel-mode-map` was missing the exceptions check that the
  `C-<letter>` and `M-<letter>` loops had, so users could not
  exclude e.g. `C-<return>` or `C-M-<down>`
  ([#210](https://github.com/dakra/ghostel/issues/210)).
- `ghostel-download-module` no longer segfaults when the module
  is already loaded.  Calling `module-load` on a path whose shared
  library is mapped into the running Emacs makes dyld/ld.so return
  the existing handle and resolve `emacs_module_init` via `dlsym`
  on the stale image.  Ghostel now skips the second `module-load`
  when the module is already `featurep`'d and tells the user to
  restart Emacs to pick up the new version
  ([#78](https://github.com/dakra/ghostel/issues/78)).

## [0.21.0] — 2026-05-01

### Added
- `ghostel-spinner-progress`, a built-in handler for
  `ghostel-progress-function` that animates `mode-line-process` via
  [spinner.el](https://github.com/Malabarba/spinner.el) during
  indeterminate progress (e.g. while Claude Code is working) and
  shows percentage text for determinate states.  spinner.el is a
  soft dependency: when it is on the `load-path` at ghostel load
  time, `ghostel-progress-function` defaults to this handler;
  otherwise the existing `ghostel-default-progress` text indicator
  is used.  New `ghostel-spinner-type` defcustom (default
  `progress-bar`) selects the spinner style.

### Changed
- Resize redraw work now scales with the resized axis.  Column
  changes still trigger a full scrollback rebuild (cell wrapping
  depends on width), but row-only changes only re-render the
  visible area and defer until after the next redraw, eliminating
  noticeable lag when only the height changes
  ([24f6653](https://github.com/dakra/ghostel/commit/24f6653)).

### Fixed
- Claude Code's progress reports now update `mode-line-process` in
  ghostel buffers.  Claude Code gates OSC 9;4 progress emission on
  `TERM_PROGRAM_VERSION` parsing as semver `>= 1.2.0`; ghostel
  advertised `TERM_PROGRAM=ghostty` without the version, so the
  gate failed and progress was silently dropped.  Ghostel now also
  exports `TERM_PROGRAM_VERSION` matching the vendored libghostty
  pin, satisfying Claude Code's check and any other consumer that
  applies the same probe.
- Plain-text URL/file detection no longer linkifies the cell the
  user is typing into.  In tty Emacs, `RET` on a linkified cell
  resolved to `ghostel-open-link-at-point` (text-property keymap
  overrides `ghostel-mode-map`), so pressing return at a path the
  shell echoed — e.g. `cd src/main.rs` — opened the file instead
  of running the command.  The renderer now marks OSC 133 B..C
  cells as `ghostel-input` and `ghostel--detect-urls` skips the
  prompt prefix unconditionally and the active input line.  The
  bundled bash/zsh/fish integrations are updated to emit 133;A and
  133;B from inside the prompt itself rather than back-to-back
  before prompt expansion, so libghostty sees a non-empty PROMPT
  range
  ([c145c5e](https://github.com/dakra/ghostel/commit/c145c5e),
  closes #199).
- OSC 51;E callbacks dispatch synchronously from the process
  filter rather than waiting for the next redraw timer tick.
  Callers like `b4 prep --edit-cover` write the OSC and continue,
  cleaning up their tempdir before deferred elisp could `find-file`
  the path; deferred dispatch produced
  `Setting current directory: No such file or directory`.
  Matches vterm's behavior.  OSC 51;A (directory tracking) is left
  deferred since it has no such race
  ([3f8846c](https://github.com/dakra/ghostel/commit/3f8846c),
  fixes #209).

## [0.20.1] — 2026-04-29

### Changed
- Style-run break detection during render uses a cheap
  `CellStyleKey` rather than a full `CellStyle` comparison, cutting
  per-cell overhead on large dirty regions
  ([81f1258](https://github.com/dakra/ghostel/commit/81f1258)).
- libghostty can now be built with optimization settings independent
  from the ghostel module itself, so debug ghostel builds no longer
  drag libghostty into debug mode
  ([5baea2d](https://github.com/dakra/ghostel/commit/5baea2d)).

## [0.20.0] — 2026-04-29

### Added
- Kitty graphics protocol support — render images inline in the
  ghostel buffer for both traditional non-virtual placements
  (timg, kitty +kitten icat, applications using direct kitty
  graphics) and unicode-placeholder placements (yazi, modern image
  previewers).  All decoding, storage, and protocol parsing flow
  through libghostty's kitty graphics C API; ghostel queries the
  placement iterator each redraw and applies image overlays in
  Emacs.  Non-PNG pixel data (RGBA / RGB / GrayAlpha / Gray) is
  converted to PPM (P6) for Emacs's built-in image renderer; PNGs
  go through libghostty's PNG-decode hook backed by vendored
  stb_image.  Per-row slicing (`:ascent 'center` plus a
  `line-height` clamp on the trailing newline) keeps image rows
  flush even when the placeholder line's `line-pixel-height` is
  pulled above `frame-char-height` by a fallback font or nerd-font
  icon on the same line
  ([57ef5a7](https://github.com/dakra/ghostel/commit/57ef5a7)).
- `ghostel-cell-pixel-scale` controls the physical:logical pixel
  ratio reported to apps that probe XTWINOPS CSI 14/16/18 t.
  Apps like timg and yazi expect cell dimensions in *physical*
  pixels (what standalone Ghostty advertises via the OS window
  server's backing scale factor), but Emacs only exposes logical
  pixels — reporting them unscaled makes apps either fall back to
  half-blocks (timg) or fill many more cells than expected with
  upscaled, blocky output (yazi).  The `auto` default derives a
  float scale from display DPI (`display-pixel-width` /
  `display-mm-width` compared to the 96 DPI reference); a numeric
  override is available for pixel-perfect parity with standalone
  Ghostty
  ([57ef5a7](https://github.com/dakra/ghostel/commit/57ef5a7)).
- File detection recognises tilde-prefixed paths
  (`~/file.el:42`) — `~` is added to the leading character class
  and leading anchor of `ghostel-file-detection-path-regex`
  ([abae518](https://github.com/dakra/ghostel/commit/abae518)).

### Changed
- `OPT_SIZE` (XTWINOPS CSI 14/16/18 t) is now answered by ghostel,
  alongside the existing `OPT_DEVICE_ATTRIBUTES` reply.  Image-
  rendering tools probe these queries to detect kitty graphics
  support and pick image dimensions; without a response timg fell
  back to half-block rendering even when `TERM_PROGRAM=ghostty`.
  Cell pixel dimensions are stored on the Terminal struct and
  updated on every resize, and `ghostel--set-size` is seeded once
  between `ghostel--new` and the process spawn so the very first
  output (e.g. timg's transmit-and-place) reports authoritative
  values rather than zero
  ([57ef5a7](https://github.com/dakra/ghostel/commit/57ef5a7)).

### Fixed
- `ghostel-exec` uses the universal 80×24 default when BUFFER is
  not displayed in any window, instead of sizing the PTY from
  `(selected-window)`.  The selected window had nothing to do with
  where the agent buffer would eventually be shown — programs
  ending up in a different window had to rely on SIGWINCH to
  recover, and TUIs that latch initial dimensions at startup
  rendered against the wrong size.  Matches eat's behaviour; the
  displayed-buffer path is unchanged
  ([a8bf9ae](https://github.com/dakra/ghostel/commit/a8bf9ae)).

## [0.19.0] — 2026-04-29

### Added
- `ghostel-debug-keypress` arms a one-shot capture of the next
  keystroke in the current ghostel buffer and renders a paste-ready
  diagnostic (raw event, resolved keymap binding, every byte sent,
  active DEC mode flags, coalesce-buffer state) into
  `*ghostel-debug-keypress*` — enough to distinguish kitty CSI-u from
  legacy encoding without any new native binding
  ([07b8438](https://github.com/dakra/ghostel/commit/07b8438)).
- `ghostel-debug-info` gains an `Environment` block (env vars passed
  to the spawned shell — `TERM`, `COLORTERM`, `TERMINFO`,
  `TERM_PROGRAM`, `INSIDE_EMACS`, `ghostel-environment` overrides,
  and pass-through `LANG`/`LC_*`), a `Size sync` block (Emacs window
  body rows vs `ghostel--term-rows` vs Emacs's recorded
  `old-body-pixel-height`, with explicit verdicts for in-sync /
  chrome-absorbed-but-unreconciled / pending-redisplay), and a
  `Rendering` block (default face, resolved font with
  fallback/remap detection, `line-spacing` broken into
  buffer-local / default-value / frame-parameter,
  `face-remapping-alist`).  The buffer is now read-only
  (`special-mode`, `q` to quit), module-file lookup works in the
  dev / `package-vc` layout, and customized defcustoms are
  auto-detected by comparing against `standard-value`
  ([0b19011](https://github.com/dakra/ghostel/commit/0b19011),
  [d717732](https://github.com/dakra/ghostel/commit/d717732),
  [ea594fc](https://github.com/dakra/ghostel/commit/ea594fc),
  [e8eb2f8](https://github.com/dakra/ghostel/commit/e8eb2f8)).
- FreeBSD release artifact built via Zig cross-compile from the
  Linux CI runner, using the same matrix-driven `-Dtarget=...`
  pattern as `aarch64-linux-gnu`
  ([81abb18](https://github.com/dakra/ghostel/commit/81abb18)).
- `list-buffers-directory` is set to the buffer's `default-directory`
  in `ghostel-mode` and `ghostel-compile-view-mode`, and is updated
  by OSC 7 directory tracking — so `buffer-menu` / `ibuffer` (and
  any consumer that reads the variable) can categorise ghostel
  terminals by working directory.  Mirrors `shell-mode`'s convention
  ([75fe69f](https://github.com/dakra/ghostel/commit/75fe69f)).
- `tui-partial` benchmark renders the static screen once, then
  updates only the bottom row per iteration — the workload that
  status bars and prompt redraws actually produce.  Exposes that
  ghostel's per-row dirty-bit branch is 8–13× faster than full mode
  at 24×80 and 40×120
  ([6a4a069](https://github.com/dakra/ghostel/commit/6a4a069)).

### Changed
- Native rendering rewritten.  Each pass parks the libghostty
  terminal at `max_offset - 1`, which lets us track scrollback
  correctly across the libghostty cap by detecting eviction from
  the parked offset, identify scrollback-clear (`CSI 3J` et al.)
  reliably via the `offset+len==total` snap-back signal without
  per-byte VT scanning, use libghostty dirty flags directly to
  identify stale lines (fixes the case where promoted scrollback
  rows could carry outdated content), and evict old scrollback rows
  from the Emacs buffer in lockstep with libghostty's ring-buffer
  wrap.  OSC 8 hyperlink handling switches from storing URI strings
  on every run to a lazy `help-echo` lookup via
  `ghostel--native-uri-at`.  The Emacs buffer now always carries a
  trailing newline so line-math is uniform across the codebase
  ([8e3135f](https://github.com/dakra/ghostel/commit/8e3135f)).
- PTY size is now captured against the buffer's window via
  `window-screen-lines`, not the selected window via
  `window-body-height`.  When a theme remaps the buffer's default
  face — e.g. `nano-light`/`nano-dark` bumping it ~7% — the two
  metrics disagree and the previous capture spawned the PTY too
  tall, then issued a startup SIGWINCH that some TUIs (Claude
  Code's `/tui` fullscreen) mishandle.  Updates every spawn /
  commit / reconcile site (`ghostel--init-buffer`, `ghostel-exec`,
  `ghostel--commit-cropped-size`, `ghostel-compile`).  Closes
  [#192](https://github.com/dakra/ghostel/issues/192)
  ([23cdc7c](https://github.com/dakra/ghostel/commit/23cdc7c),
  [ce966eb](https://github.com/dakra/ghostel/commit/ce966eb)).
- Terminal size is reconciled via `window-buffer-change-functions`
  (event-driven) instead of a 50 ms idle timer.  When a ghostel
  buffer migrates to a window of a different size (popup dismissed,
  `+popup/raise`, etc.) no Emacs-visible window-size-change event
  fires — only the buffer-to-window mapping changed — so the
  existing `adjust-window-size-function` machinery did not run.
  The hook covers the buffer's whole lifetime cleanly
  ([387c275](https://github.com/dakra/ghostel/commit/387c275),
  [b9c12ca](https://github.com/dakra/ghostel/commit/b9c12ca)).
- README's manual `~/.bashrc` / `~/.zshrc` /
  `~/.config/fish/config.fish` source gate now uses a prefix match
  (`${INSIDE_EMACS%%,*}`, fish-anchored regex) so TRAMP-rewritten
  `INSIDE_EMACS=ghostel,tramp:VER` matches.  The remote-host gate
  adds a `TERM=xterm-ghostty` fallback because plain `ssh` cannot
  propagate `INSIDE_EMACS` without `AcceptEnv` configured
  server-side.  Also updates the source-comment header in
  `etc/shell/ghostel.{bash,zsh,fish}` and adds a TRAMP canary test
  on `tramp-inside-emacs`
  ([d3ecac0](https://github.com/dakra/ghostel/commit/d3ecac0)).
- `package-lint`, `checkdoc`, and `docquotes` (a regex check for
  back/front-quoted non-symbols, widened from melpazoid's `[A-Z]+`
  to `[A-Z_]+` so identifiers like `INSIDE_EMACS` aren't skipped)
  now run in CI as a single Emacs 29.4 lint job; `evil-ghostel.el`
  is byte-compiled and linted alongside `lisp/`
  ([5d73106](https://github.com/dakra/ghostel/commit/5d73106),
  [5321d1b](https://github.com/dakra/ghostel/commit/5321d1b)).

### Fixed
- Coalesced single-byte input is drained before every direct PTY
  write from Zig (key encoder, mouse encoder, OSC 4/10/11 replies,
  focus events, VT write-back).  Encoded keystrokes could otherwise
  overtake preceding self-insert bytes
  ([0b37dae](https://github.com/dakra/ghostel/commit/0b37dae)).
- `C-g` in a ghostel buffer now also deactivates the active region,
  matching the side effect users expect from `keyboard-quit` (the
  `inhibit-quit` binding routes `C-g` through the keymap to
  `ghostel-send-C-g`, which previously only sent SIGINT).  Closes
  [#200](https://github.com/dakra/ghostel/issues/200)
  ([14b4e85](https://github.com/dakra/ghostel/commit/14b4e85),
  [7631ea9](https://github.com/dakra/ghostel/commit/7631ea9)).
- IME preedit anchor stays stable during redraw — the cursor row
  no longer drifts while typing into an active preedit window
  ([90f1f71](https://github.com/dakra/ghostel/commit/90f1f71)).
- Evil state transitions no longer wipe + rebuild the buffer once
  any scrollback exists.  A `defer` in `fnCursorPosition` /
  `fnDebugState` / `fnDebugFeed` was scoped to an inner
  `if (term.getScrollbar()) |sb| { … }` block, so the
  viewport-restore fired before the `SCROLL_BOTTOM` call below it.
  Each call left libghostty parked at the bottom
  (`offset+len==total`), which the next redraw mistook for a
  scrollback-clear signal.  Hoisted the defer to function scope.
  Folded in: a heap-fallback `defer ... .free(buf)` in `fnUriAt`
  was scoped to the inner alloc block and freed before
  `makeString` read through the alias — hoisted, plus a `SUCCESS`
  check on `ghostty_grid_ref_hyperlink_uri` so error returns no
  longer stringify uninitialised data
  ([8e3135f](https://github.com/dakra/ghostel/commit/8e3135f)).

## [0.18.1] — 2026-04-25

### Added
- `ghostel-plain-link-detection-delay` user option (default 0.1s)
  controls how long ghostel waits after a redraw before scanning for
  plain-text URLs and file paths.  Set to 0 to restore the previous
  synchronous behavior
  ([671d3ee](https://github.com/dakra/ghostel/commit/671d3ee)).

### Changed
- Plain-text link detection is now deferred off the redraw path and
  coalesced via a single timer, so bursts of redraws collapse into one
  scan instead of running detection on every dirty redraw.  Native
  OSC-8 hyperlink spans continue to be handled inside the renderer.
  The process sentinel cancels the pending detection timer so it
  cannot fire against a buffer that is about to be killed
  ([671d3ee](https://github.com/dakra/ghostel/commit/671d3ee)).
- Scrollback rotation detection now snapshots the first scrollback
  row directly (`std.mem.eql` over all `term.cols` cells) instead of
  hashing the first 16 cells with FNV-1a.  Removes a small collision
  probability and the arbitrary 16-cell sample that could miss
  rotation when two rows shared the same opening cells; the
  cached-read optimisation that skips the end-of-redraw round trip is
  preserved
  ([4b1a0ba](https://github.com/dakra/ghostel/commit/4b1a0ba)).

## [0.18.0] — 2026-04-24

### Breaking
- Repository layout reorganized.  Elisp sources now live under `lisp/`
  (the `ghostel` package) and `extensions/` (independent `evil-ghostel`
  package); vendored headers moved from `include/` to `vendor/`; the
  bundled compiled terminfo moved from `terminfo/` to `etc/terminfo/`;
  shell-integration assets restructured into `etc/shell/ghostel.{bash,
  fish,zsh}` (user-sourced rc files) and `etc/shell/bootstrap/` (env-
  hook shims for local auto-injection)
  ([266e3e9](https://github.com/dakra/ghostel/commit/266e3e9)).
- Users who source ghostel's shell rc files manually from their own
  shell configuration must update the path: `etc/ghostel.{bash,zsh,
  fish}` → `etc/shell/ghostel.{bash,zsh,fish}`.
- `evil-ghostel` is now published as a separate MELPA package.  Users
  who relied on installing `ghostel` alone and getting evil integration
  for free must now install `evil-ghostel` separately.  In return,
  `package-vc-install ghostel` no longer pulls `evil` in as a
  transitive dependency of the single-repo scan.
- Removed the `ghostel-evil` compatibility shim that was deprecated in
  0.13.0.  Replace any `(require 'ghostel-evil)` with `(require
  'evil-ghostel)` and any `ghostel-evil-mode` calls with
  `evil-ghostel-mode`.

### Added
- `ghostel-environment` user option (mirrors `vterm-environment`):
  list of `KEY=VALUE` strings prepended to `process-environment`
  before spawning the shell.  Honors `.dir-locals.el` via
  `hack-dir-local-variables`, propagates to TRAMP remote shells, and
  applies to both shell spawns and `ghostel-compile` spawns.  User
  entries take precedence over ghostel's own `TERM`/`INSIDE_EMACS`.
  Closes [#176](https://github.com/dakra/ghostel/issues/176)
  ([87c99e5](https://github.com/dakra/ghostel/commit/87c99e5)).
- `ghostel-default` face (inherits `default`) as the per-buffer
  customization point for terminal foreground/background, allowing
  e.g. a dark terminal inside a light Emacs without resorting to
  `defadvice`.  Closes
  [#178](https://github.com/dakra/ghostel/issues/178)
  ([7c3fa5b](https://github.com/dakra/ghostel/commit/7c3fa5b)).

### Changed
- `ghostel` and `ghostel-project` now explicitly return the buffer
  they create or switch to, so callers can use the buffer
  programmatically without relying on `pop-to-buffer` side effects.
  Closes [#185](https://github.com/dakra/ghostel/issues/185)
  ([fdfb68f](https://github.com/dakra/ghostel/commit/fdfb68f)).
- ANSI color faces now inherit from `ansi-color-*` instead of
  `term-color-*`.  Themes (notably modus) deliberately remap
  `term-color-black` / `term-color-white` to bright palette entries
  to keep them distinct from `term.el`'s buffer face — that
  accommodation made e.g. htop's status bar render gray-on-green and
  unreadable.  `ansi-color-*` is the canonical ANSI face family
  since Emacs 28.1 and themes customize it to the proper palette.
  Closes [#175](https://github.com/dakra/ghostel/issues/175)
  ([a27f2fa](https://github.com/dakra/ghostel/commit/a27f2fa)).

### Fixed
- Scrollback no longer leaves stale rows after `CSI 3J`
  (clear-scrollback) followed by enough new output to restore the
  same scrollback depth.  A unified `rebuild_pending` flag now
  tracks all scrollback-validity signals (resize, CSI 3J, rotation
  hash mismatch); the surgical-trim fallback that misbehaved on
  reflow is replaced with a single full-erase path.  Closes
  [#160](https://github.com/dakra/ghostel/issues/160)
  ([f5524ef](https://github.com/dakra/ghostel/commit/f5524ef)).
- A ghostel buffer that received output while hidden no longer
  shows a stale pre-hide screen on re-show.  A per-window snap list
  populated via `window-buffer-change-functions` forces the next
  redraw to anchor to the latest output.  Closes
  [#177](https://github.com/dakra/ghostel/issues/177)
  ([63e008f](https://github.com/dakra/ghostel/commit/63e008f)).
- The first ghostel buffer in a session now respects
  `display-buffer-alist`.  Fixes
  [#179](https://github.com/dakra/ghostel/issues/179)
  ([d33052d](https://github.com/dakra/ghostel/commit/d33052d)).
- `ghostel` and `ghostel-project` reuse an existing terminal buffer
  even after `ghostel--set-title-default` has renamed it.  Buffers
  now carry a sticky `ghostel--buffer-identity` set at creation
  time, and lookup matches on identity rather than current buffer
  name.  Fixes
  [#168](https://github.com/dakra/ghostel/issues/168)
  ([465030e](https://github.com/dakra/ghostel/commit/465030e)).
- Bind `[xterm-paste]` to a ghostel-aware handler so clipboard
  pastes delivered by the host terminal (TTY Emacs with bracketed
  paste) reach the inferior shell instead of being inserted into
  the renderer-owned buffer and wiped on the next redraw.  Fixes
  [#172](https://github.com/dakra/ghostel/issues/172)
  ([5546b97](https://github.com/dakra/ghostel/commit/5546b97)).
- Meta-modified keys (`M-x`, `M-DEL`, …) now reach the terminal in
  TTY Emacs.  TTY Emacs delivers `M-<key>` as an ESC prefix that
  consumes the meta modifier before the binding fires; the dispatch
  path now detects the `esc-map` lookup via
  `this-command-keys-vector` and re-injects meta.  Follow-up to
  [43220db](https://github.com/dakra/ghostel/commit/43220db); fixes
  [#48](https://github.com/dakra/ghostel/issues/48)
  ([c42451e](https://github.com/dakra/ghostel/commit/c42451e)).
- Fish auto-inject now installs `xterm-ghostty` terminfo on remote
  hosts via the `ssh` wrapper (parity with bash/zsh), and no longer
  leaks fish's internal vendor-conf `xdg_data_dirs` (with `/fish`
  appended) into `XDG_DATA_DIRS` for every spawned subprocess.  The
  vendor-conf shim now chains to `etc/ghostel.fish` instead of
  carrying a drifting inline copy
  ([d9fd009](https://github.com/dakra/ghostel/commit/d9fd009)).
- `package-vc-install` on Emacs 30.x no longer fails byte-compiling
  `test/`, `bench/`, and `extensions/`.  A `.elpaignore` scopes
  recompilation to the package's lisp directory via
  `byte-compile-ignore-files`.  Emacs 31 fixed this upstream
  ([573acd97](https://cgit.git.savannah.gnu.org/cgit/emacs.git/commit/?id=573acd97e54ceead6d11b330909ffb8e744247cc));
  the `.elpaignore` covers the un-backported case
  ([bcba725](https://github.com/dakra/ghostel/commit/bcba725)).

## [0.17.0] — 2026-04-21

### Added
- `evil-ghostel-initial-state` defcustom controls the initial evil state
  in ghostel buffers (default `insert`). Replaces a hard-coded
  `evil-set-initial-state` call that fired on every ghostel buffer
  creation and silently clobbered user overrides. `:set` re-applies the
  value on change, and the `setq-before-require` path is honoured on
  load
  ([5fcbb19](https://github.com/dakra/ghostel/commit/5fcbb19)).

### Changed
- Replaced `ghostel-enable-title-tracking` (boolean) with
  `ghostel-set-title-function`.  The new option holds the function
  invoked on OSC 2 title changes; set to nil to disable title tracking,
  or to a custom function to fully override the rename behaviour
  ([5bd67f1](https://github.com/dakra/ghostel/commit/5bd67f1)).

### Fixed
- `mark` now survives native redraws. The full-redraw path
  (`eraseBuffer`) previously snapped every marker to `point-min`, and
  the partial-redraw path drifted markers asymmetrically by
  insertion-type — so `C-SPC`-set marks or normal-state region commands
  lost their anchor on every frame
  ([4816ece](https://github.com/dakra/ghostel/commit/4816ece)).
- Evil visual selections no longer stretch to a multi-row phantom
  region in a buffer that is streaming output. The `around-redraw`
  advice now saves and restores `evil-visual-beginning` /
  `evil-visual-end` while in visual state, in addition to `point`
  ([606ec4d](https://github.com/dakra/ghostel/commit/606ec4d)).
- Removed the `evil-ghostel` normal-state-entry hook that corrupted
  point after operator commands — `yy`, `v..y`, and `v..<escape>` could
  discard the motion and land point on the TUI cursor row. Evil's own
  operator/visual machinery places point correctly without the extra
  snap
  ([b955dbb](https://github.com/dakra/ghostel/commit/b955dbb)).

## [0.16.3] — 2026-04-20

### Fixed
- Block cursor no longer drifts up a row when a TUI parks it on an
  empty last row via absolute positioning (CUP). The `window-point`
  clamp from 0.16.1 is broadened via a new
  `ghostel--cursor-on-empty-row-p` native predicate so the clamp fires
  on both pending-wrap and empty-trailing-row conditions. Closes
  [#157](https://github.com/dakra/ghostel/issues/157)
  ([d4fdc8e](https://github.com/dakra/ghostel/commit/d4fdc8e)).
- The bundled `ssh` wrapper in `ghostel.bash` / `ghostel.zsh` no longer
  fails with a parse error when the user has `alias ssh=…` set before
  sourcing the integration. Uses `function ssh { … }` form to sidestep
  alias expansion. Fixes
  [#155](https://github.com/dakra/ghostel/issues/155)
  ([44aaf67](https://github.com/dakra/ghostel/commit/44aaf67)).

## [0.16.2] — 2026-04-20

### Added
- Bundled `xterm-ghostty` terminfo under `terminfo/` (both Linux and
  macOS hashed-dir layouts). Terminal sessions now set
  `TERM=xterm-ghostty` + `TERMINFO=<bundled>` + `TERM_PROGRAM=ghostty`
  so TUI apps that consult terminfo see ghostel's real capabilities —
  most notably DEC 2026 (`Sync`), which Claude Code needs to avoid
  cascading unsynchronised redraws on `M-x` with large scrollback.
  TRAMP pushes terminfo to a remote temp dir over the existing
  connection; outbound `ssh` from a local buffer is shadowed with a
  wrapper that installs terminfo on the remote via `tic` on first use
  (cached per-host under `$XDG_CACHE_HOME/ghostel/`, invalidated on
  libghostty bumps).  New options: `ghostel-term`,
  `ghostel-ssh-install-terminfo`, `M-x ghostel-ssh-clear-terminfo-cache`
  ([2c92f68](https://github.com/dakra/ghostel/commit/2c92f68)).

### Fixed
- Minibuffer activation (M-x, vertico, consult) no longer repaints the
  shell prompt or forces full TUI redraws. Shrinks caused by the
  minibuffer stealing window space are treated as viewport crops
  instead of real resizes, suppressing the spurious SIGWINCH. Apps on
  the alternate screen (vim, htop, less, Claude Code) still receive
  SIGWINCH because they own the full viewport; selecting the ghostel
  window while the minibuffer is open commits the cropped size
  ([3e8d9c7](https://github.com/dakra/ghostel/commit/3e8d9c7)).
- `ghostel-compile` header and early output no longer wrap at the
  wrong column when the compile buffer lands in a smaller window than
  the selected one.  The VT is now reconciled to the output window's
  dimensions before rendering the header and before spawning the
  process
  ([dcbbf1d](https://github.com/dakra/ghostel/commit/dcbbf1d)).
- `M-x kill-compilation` now finds and terminates a live
  `ghostel-compile` run. `compilation-locs` is declared buffer-locally
  during the run so `compilation-buffer-internal-p` recognises the
  buffer
  ([dcbbf1d](https://github.com/dakra/ghostel/commit/dcbbf1d)).

## [0.16.1] — 2026-04-20

### Fixed
- Block cursor no longer draws on top of the last character while the
  user is typing at a shell prompt. The `window-point` clamp introduced
  in 0.16.0 is narrowed to fire only when libghostty reports the cursor
  in pending-wrap state, exposed via a new
  `ghostel--cursor-pending-wrap-p` native function. Fixes
  [#146](https://github.com/dakra/ghostel/issues/146)
  ([ad8536e](https://github.com/dakra/ghostel/commit/ad8536e)).

## [0.16.0] — 2026-04-19

### Added
- Desktop notifications via OSC 9 (iTerm2) and OSC 777 (rxvt `notify`),
  plus ConEmu OSC 9;4 progress reports. Notifications route through
  `ghostel-notification-function` (default uses `notifications-notify`
  with a `message` fallback, dispatched via `run-at-time` so a slow
  DBus broker can't stall the VT parser); progress routes through
  `ghostel-progress-function` (default shows `[42%]` / `[...]` /
  `[err]` / `[paused]` in the mode line). OSC 9;9 CWD reports are
  handled the same way as OSC 7. Closes
  [#141](https://github.com/dakra/ghostel/issues/141)
  ([4f7b1cd](https://github.com/dakra/ghostel/commit/4f7b1cd)).
- `ghostel-compile-global-mode`: opt-in global minor mode that advises
  `compilation-start` so every caller (`compile`, `recompile`,
  `project-compile`, ...) automatically runs in a ghostel buffer.
  Falls through to the stock implementation for `grep-mode`, comint,
  and `continue=non-nil`; excluded set is customisable via
  `ghostel-compile-global-mode-excluded-modes`
  ([e7164ec](https://github.com/dakra/ghostel/commit/e7164ec)).
- `ghostel-send-string` and `ghostel-send-key` public API for external
  packages (agent integrations, custom keymaps) to drive a ghostel
  buffer without reaching into `ghostel--` internals. The old internal
  `ghostel--send-key` is kept as an obsolete alias; the raw-byte
  primitive is now `ghostel--send-string`
  ([5453c22](https://github.com/dakra/ghostel/commit/5453c22)).
- `<XF86Paste>` and `<XF86Copy>` media keys are now bound to
  `ghostel-yank` and `kill-ring-save`. Previously they fell through to
  the global commands and got overpainted by the next redraw
  ([65932e6](https://github.com/dakra/ghostel/commit/65932e6)).

### Changed
- `ghostel-compile` no longer types its command into an interactive
  shell. Each invocation spawns `shell-file-name -c COMMAND` directly
  via `make-process` through a PTY owned by the ghostel renderer.
  Multi-line scripts with embedded newlines now pass through verbatim
  (the old type-into-shell path interpreted each newline as RET), exit
  status comes from the process sentinel, and shell integration is no
  longer required. The banner is written to the VT before spawn so it
  appears live; interactive programs like `htop`, `less`, and `read`
  prompts keep working because the buffer stays in `ghostel-mode`
  during the run
  ([e7164ec](https://github.com/dakra/ghostel/commit/e7164ec)).
- `ghostel-recompile` now re-runs into the current buffer when it
  holds a local `ghostel-compile--command`, so pressing `g` in a
  `*compilation*` buffer produced by `ghostel-compile-global-mode`
  reuses the buffer and window instead of opening a second one
  ([e7164ec](https://github.com/dakra/ghostel/commit/e7164ec)).
- `ghostel-compile` opens its buffer in a non-selected window, matching
  `M-x compile` exactly.  Respects `display-buffer-alist`, keeps focus
  on the caller, and `quit-window` disposes of the window the way users
  expect. Closes [#122](https://github.com/dakra/ghostel/issues/122)
  ([9846c64](https://github.com/dakra/ghostel/commit/9846c64)).
- `evil-ghostel` point now tracks the terminal cursor in
  `evil-emacs-state`, not just `insert-state` — emacs-state is evil's
  vanilla-Emacs escape hatch and should behave like a normal terminal
  ([f05e0db](https://github.com/dakra/ghostel/commit/f05e0db)).
- Large TUI redraws (Claude Code, post-resize frames) now stream in a
  single filter call. `process-adaptive-read-buffering` is disabled and
  `read-process-output-max` raised to at least 1 MB for ghostel PTYs;
  pre-Emacs 31 this collapses a 570 KB post-resize frame from ~9 filter
  calls to 1 — a ~15-second cascading repaint becomes instant. Mirrors
  what vterm does for the same reason. Fixes
  [#85](https://github.com/dakra/ghostel/issues/85)
  ([bcf2f0c](https://github.com/dakra/ghostel/commit/bcf2f0c)).

### Fixed
- Child programs that enable focus reporting (Claude Code, btop, vim)
  now see focus-out when the user selects a different window inside
  Emacs, not only when the whole frame blurs. Adds hooks on
  `window-selection-change-functions` and
  `window-buffer-change-functions` in addition to frame focus. Closes
  [#140](https://github.com/dakra/ghostel/issues/140)
  ([ddaefbc](https://github.com/dakra/ghostel/commit/ddaefbc)).
- Process sentinel no longer removes the focus-reporting hook
  globally on exit, which had broken focus reports for every other
  live ghostel buffer
  ([ddaefbc](https://github.com/dakra/ghostel/commit/ddaefbc)).
- TUI cursor no longer disappears on the last viewport row when it
  lands in pending-wrap state. Clamps `window-point` back by one when
  `pt` equals `point-max` so Emacs redisplay stops shifting
  `window-start` up by a row to "make it visible." Closes
  [#138](https://github.com/dakra/ghostel/issues/138)
  ([17fc791](https://github.com/dakra/ghostel/commit/17fc791)).
- Viewport no longer snaps to the prompt when the minibuffer opens
  (and the ghostel window shrinks) in a scrolled-up TUI. During a
  resize-triggered redraw, windows that were auto-following before
  the resize are treated as still anchored rather than as a user
  scroll. Closes [#127](https://github.com/dakra/ghostel/issues/127)
  ([aa4912d](https://github.com/dakra/ghostel/commit/aa4912d)).
- Per-cell face properties (colours from SGR sequences) now survive
  when `font-lock-mode` is force-enabled in a ghostel buffer — e.g.
  Doom Emacs sets `font-lock-defaults` globally, which reactivates
  font-lock after `ghostel-mode`'s `(font-lock-mode -1)`. A
  buffer-local `font-lock-unfontify-region-function` neutralises the
  unfontify pass in both `ghostel-mode` and `ghostel-compile-view-mode`
  ([28f5071](https://github.com/dakra/ghostel/commit/28f5071)).
- `evil-ghostel`: entering normal state in a buffer with any
  scrollback no longer snaps point to row N of the scrollback region
  instead of row N of the visible viewport — the row offset now
  accounts for scrollback line count
  ([69d4b0d](https://github.com/dakra/ghostel/commit/69d4b0d)).

## [0.15.0] — 2026-04-17

### Added
- `ghostel-compile` and `ghostel-recompile`: `M-x compile`-style
  workflow backed by a real PTY, so commands that need a terminal
  (colour output, progress bars, curses tools) work normally. Finished
  buffers support `next-error` navigation and share `compile-command` /
  `compile-history` with `M-x compile`; `g` recompiles in the original
  directory, `C-u g` prompts to edit the command
  ([5280db2](https://github.com/dakra/ghostel/commit/5280db2),
  [d72751e](https://github.com/dakra/ghostel/commit/d72751e)).
- `ghostel-eshell-visual-command-mode`: overrides `eshell-exec-visual`
  so TUI programs invoked from eshell (vim, htop, less, top) run in a
  dedicated ghostel buffer instead of the default `term-mode`
  fallback. Adds `ghostel-exec` as the public primitive for running an
  arbitrary program in a ghostel buffer and an `eshell/ghostel` builtin
  ([8df9fc7](https://github.com/dakra/ghostel/commit/8df9fc7)).
- `ghostel-next-hyperlink` / `ghostel-previous-hyperlink` navigate OSC
  8 hyperlinks, auto-detected URLs, and file:line references via `C-c
  C-n` / `C-c C-p`; prompt navigation moves to `C-c M-n` / `C-c M-p`
  ([895e55b](https://github.com/dakra/ghostel/commit/895e55b)).
- `ghostel-debug-info` command collects Emacs version, system info,
  native module version (with mismatch warning), terminal state, and
  settings into `*ghostel-debug*` for pasting into bug reports. Resize
  and redraw events are now logged when `ghostel-debug-start` is active
  ([b5d7b4d](https://github.com/dakra/ghostel/commit/b5d7b4d)).
- `ghostel-ignore-cursor-change` option ignores terminal requests that
  change cursor shape or visibility; useful when editor-owned cursor
  behaviour should take precedence
  ([c901c02](https://github.com/dakra/ghostel/commit/c901c02)).
- `M-y` with no preceding yank now opens a `completing-read` browser
  over the kill ring (works with consult/vertico) instead of signalling
  an error
  ([e1e1896](https://github.com/dakra/ghostel/commit/e1e1896)).

### Changed
- `C-g` is now sent to the terminal instead of triggering
  `keyboard-quit`; in copy mode it still exits copy mode
  ([057fb1f](https://github.com/dakra/ghostel/commit/057fb1f)).
- Linkified file paths in terminal output now also match bare relative
  paths (e.g. `src/foo.rs:43:4`), paths wrapped in punctuation (Python
  tracebacks, backticks, brackets), and an optional `:column` after the
  line number. Configurable via `ghostel-file-detection-regex`. Closes
  [#107](https://github.com/dakra/ghostel/issues/107)
  ([ed17efb](https://github.com/dakra/ghostel/commit/ed17efb)).
- Module auto-download now works on systems that report `amd64`/`arm64`
  in `system-configuration`
  ([27dcec0](https://github.com/dakra/ghostel/commit/27dcec0)).
- OSC dispatch rewritten to scan each PTY write once instead of five
  times. A single `OscIterator` yields `(code, payload, terminator)`
  and one `dispatchPostWriteOscs` handles codes 7/51/52/133 in
  document order. Engine micro-benchmarks improve ~20–28% on bulk
  input
  ([819098f](https://github.com/dakra/ghostel/commit/819098f),
  [1729f24](https://github.com/dakra/ghostel/commit/1729f24)).
- CRLF normalisation is now zero-allocation and zero-copy. The old
  path allocated up to 131 KB of scratch (with heap fallback and a
  silent-truncation failure mode) and walked the input twice; the new
  path streams raw segments into libghostty's VT parser and emits
  `\r\n` inline at each bare `\n`. State is persisted across calls so
  a CRLF pair split between two writes isn't double-normalised
  ([42092e7](https://github.com/dakra/ghostel/commit/42092e7),
  [1729f24](https://github.com/dakra/ghostel/commit/1729f24)).
- Module loader unified into a single helper. Load-time and
  interactive-command paths no longer diverge in guard checks,
  directory resolution, or failure mode
  ([bbe1c41](https://github.com/dakra/ghostel/commit/bbe1c41)).
- `evil-ghostel` now included in `make checkdoc`
  ([0a9faa1](https://github.com/dakra/ghostel/commit/0a9faa1)).

### Fixed
- Top line no longer renders clipped after a terminal redraw when
  `pixel-scroll-precision-mode` had left a partial pixel offset. Closes
  [#105](https://github.com/dakra/ghostel/issues/105)
  ([bfb6e7c](https://github.com/dakra/ghostel/commit/bfb6e7c)).
- Scroll position preserved across window resizes (M-x, vertico
  open/close, window splits). A pre-redraw classifier tags windows as
  auto-follow vs. user-scrolled via multi-line content keys that
  survive scrollback eviction, full-redraw erase, and viewport
  rewrite — so scrolling up to read history and pressing `M-x` no
  longer yanks the view back to the prompt. Also eliminates a 1-row
  per-keystroke flicker seen in Claude Code's TUI. Closes
  [#115](https://github.com/dakra/ghostel/issues/115)
  ([2efecf2](https://github.com/dakra/ghostel/commit/2efecf2)).
- Backspace now works in terminal mode (`emacs -nw`). The event
  arrives as integer 127 and is now normalised to `"backspace"` at
  the Emacs-event boundary before key-name dispatch. Fixes
  [#114](https://github.com/dakra/ghostel/issues/114)
  ([c5b38d5](https://github.com/dakra/ghostel/commit/c5b38d5)).
- Typing or pasting while point is in scrollback (after mouse wheel,
  M-v, pixel-scroll) now jumps the viewport to the terminal prompt as
  intended. Fixes
  [#113](https://github.com/dakra/ghostel/issues/113)
  ([31bdc9c](https://github.com/dakra/ghostel/commit/31bdc9c)).
- Wheel events on an unselected ghostel window no longer hang Emacs.
  The scroll intercept was running in the selected window's buffer
  instead of the event window's, so the re-dispatched event hit the
  intercept again — infinite loop, recoverable only via `C-g`. Fixes
  [#119](https://github.com/dakra/ghostel/issues/119)
  ([305eacd](https://github.com/dakra/ghostel/commit/305eacd)).
- `ghostel-compile` no longer leaves ~24 blank rows between the output
  and the footer on short commands. Trailing blank grid rows from the
  VT render are trimmed on finalise. Fixes
  [#111](https://github.com/dakra/ghostel/issues/111)
  ([60ab84f](https://github.com/dakra/ghostel/commit/60ab84f)).
- OSC iterator no longer cannibalises the next OSC's bytes when a
  preceding OSC is missing its terminator — a new `\e]` introducer
  now ends the current payload
  ([1729f24](https://github.com/dakra/ghostel/commit/1729f24)).

## [0.14.0] — 2026-04-13

### Added
- `C-c C-l` binding in copy mode ([156a714](https://github.com/dakra/ghostel/commit/156a714)).

### Changed
- Decouple module downloads from package version ([36a1ad5](https://github.com/dakra/ghostel/commit/36a1ad5)).
- Disable XON/XOFF flow control so `C-q` and `C-s` reach the shell ([a8a3034](https://github.com/dakra/ghostel/commit/a8a3034)).
- Speed up test suite with early-return polling and parallel execution ([2d3bda7](https://github.com/dakra/ghostel/commit/2d3bda7)).
- Wheel events now fall through to third-party scroll packages
  (ultra-scroll, `pixel-scroll-precision-mode`, `mwheel`) when terminal
  mouse tracking is inactive. Fixes
  [#97](https://github.com/dakra/ghostel/issues/97)
  ([3b6c980](https://github.com/dakra/ghostel/commit/3b6c980)).

### Removed
- Dead scroll commands ([156a714](https://github.com/dakra/ghostel/commit/156a714)).

### Fixed
- Blank first page of scrollback after initial output burst ([f01de74](https://github.com/dakra/ghostel/commit/f01de74)).
- Keystrokes are now visible from the first character in bash sessions
  (previously invisible on old bash, notably macOS `/bin/bash` 3.2).
  Fixes [#101](https://github.com/dakra/ghostel/issues/101)
  ([51705bd](https://github.com/dakra/ghostel/commit/51705bd)).

## [0.13.0] — 2026-04-13

### Added
- VT log callback ([a3d043a](https://github.com/dakra/ghostel/commit/a3d043a)).

### Changed
- Build with Zig and vendored Emacs header ([4ca5770](https://github.com/dakra/ghostel/commit/4ca5770)).
- Use env vars for Emacs header override ([cdcfa76](https://github.com/dakra/ghostel/commit/cdcfa76)).
- Replace ghostty git submodule with Zig URL dependency ([b32308c](https://github.com/dakra/ghostel/commit/b32308c)).
- Use `_get_multi` for render state queries ([a3d043a](https://github.com/dakra/ghostel/commit/a3d043a)).
- Remove `zig build check` step and clean up stale references ([f19409e](https://github.com/dakra/ghostel/commit/f19409e)).

### Fixed
- musl cross-compilation; release builds now pass `-Dcpu=baseline` ([3e0776d](https://github.com/dakra/ghostel/commit/3e0776d)).

## [0.12.2] — 2026-04-12

### Changed
- Rename `ghostel-evil` to `evil-ghostel` ([1c37fef](https://github.com/dakra/ghostel/commit/1c37fef)).

### Fixed
- Blank screen after idle when buffer gets out of sync ([0f60388](https://github.com/dakra/ghostel/commit/0f60388)).

## [0.12.1] — 2026-04-12

### Fixed
- Cursor lands on the correct character for box-drawing and other glyphs
  where Emacs' width calculation disagrees with the terminal (seen on
  CJK/pgtk). Fixes [#86](https://github.com/dakra/ghostel/issues/86)
  ([fcb8d3b](https://github.com/dakra/ghostel/commit/fcb8d3b)).

## [0.12.0] — 2026-04-12

### Added
- `ghostel-enable-title-tracking` defcustom ([0102ad9](https://github.com/dakra/ghostel/commit/0102ad9)).

### Changed
- Defer buffer erasure on resize to eliminate blank flash ([5966043](https://github.com/dakra/ghostel/commit/5966043)).
- Redraw synchronously on resize and anchor `window-start` ([6728ffc](https://github.com/dakra/ghostel/commit/6728ffc)).

### Fixed
- Stale horizontal scroll after window resize ([cc48ae3](https://github.com/dakra/ghostel/commit/cc48ae3)).

## [0.11.0] — 2026-04-11

### Added
- Materialize libghostty scrollback into the Emacs buffer (vterm parity) ([34645e2](https://github.com/dakra/ghostel/commit/34645e2)).
- Detect cap rotation via first-row hash to keep scrollback fresh ([9ed2a76](https://github.com/dakra/ghostel/commit/9ed2a76)).

### Changed
- Always insert trailing newline in `insertScrollbackRange` ([d3acea1](https://github.com/dakra/ghostel/commit/d3acea1)).
- Trim trailing blank cells when rendering rows ([b3e86b5](https://github.com/dakra/ghostel/commit/b3e86b5)).
- Update benchmark numbers after trailing-whitespace trim ([1a31d37](https://github.com/dakra/ghostel/commit/1a31d37)).

### Fixed
- OSC 51;E eval no longer crashes the process filter when the executed
  command switches buffers, signals an error, or deselects the ghostel
  window. Fixes [#82](https://github.com/dakra/ghostel/issues/82)
  ([20cce42](https://github.com/dakra/ghostel/commit/20cce42)).

## [0.10.1] — 2026-04-11

### Added
- Configurable TRAMP method for OSC 7 directory tracking ([1159a5b](https://github.com/dakra/ghostel/commit/1159a5b)).

### Changed
- Pass `-Dcpu=baseline` for native x86_64 builds ([11df11b](https://github.com/dakra/ghostel/commit/11df11b)).
- Harden Claude review workflow for fork PRs ([f16d7b8](https://github.com/dakra/ghostel/commit/f16d7b8)).

## [0.10.0] — 2026-04-11

### Added
- `evil-mode` integration: normal-mode navigation works in terminal
  buffers with the cursor kept in sync on state transitions. Closes
  [#52](https://github.com/dakra/ghostel/issues/52)
  ([21d8439](https://github.com/dakra/ghostel/commit/21d8439)).
- OSC 4/10/11 color query responses ([c57f281](https://github.com/dakra/ghostel/commit/c57f281), fixes [#75](https://github.com/dakra/ghostel/issues/75)).
- SIGWINCH delivery tests for PTY resize ([500d978](https://github.com/dakra/ghostel/commit/500d978)).

### Changed
- Use per-process property for window resize handler ([dc102eb](https://github.com/dakra/ghostel/commit/dc102eb)).
- Track `.elc` files as proper Make targets ([144c9ba](https://github.com/dakra/ghostel/commit/144c9ba)).
- Use `executable-find` to locate bash in SIGWINCH tests ([ae06f8e](https://github.com/dakra/ghostel/commit/ae06f8e)).

### Fixed
- Remote zsh temp directory leak during session startup ([519f063](https://github.com/dakra/ghostel/commit/519f063)).
- ncurses apps (htop, etc.) now redraw at the correct size after a
  window resize instead of being frozen at their start-up dimensions.
  Fixes [#67](https://github.com/dakra/ghostel/issues/67)
  ([83d90f7](https://github.com/dakra/ghostel/commit/83d90f7)).
- SIGWINCH baseline tests on Linux by using bash explicitly ([e5582d5](https://github.com/dakra/ghostel/commit/e5582d5)).
- `wrong-number-of-arguments` in `ghostel-evil--around-delete` ([79a6b86](https://github.com/dakra/ghostel/commit/79a6b86)).

## [0.9.0] — 2026-04-09

### Added
- TRAMP integration for remote shell spawning and directory tracking ([512a4db](https://github.com/dakra/ghostel/commit/512a4db)).
- Scroll wheel inside TUI apps with mouse tracking (htop, less, etc.)
  is now forwarded to the application; it still scrolls the viewport
  when mouse tracking is off. Fixes
  [#60](https://github.com/dakra/ghostel/issues/60)
  ([a46c784](https://github.com/dakra/ghostel/commit/a46c784)).

### Fixed
- `ghostel-send-next-key` now works with prefix keys (`C-x`, `C-h`) and
  Meta-modified keys (`M-x`). Fixes
  [#62](https://github.com/dakra/ghostel/issues/62)
  ([f9e7fc0](https://github.com/dakra/ghostel/commit/f9e7fc0)).
- `claude-code-review` workflow write permissions ([63f5550](https://github.com/dakra/ghostel/commit/63f5550)).
- Wide-char pixel overflow compensation for emoji ([4c191c3](https://github.com/dakra/ghostel/commit/4c191c3)).
- Cursor visibility preserved in copy mode during redraws ([5d7be51](https://github.com/dakra/ghostel/commit/5d7be51)).

## [0.8.0] — 2026-04-08

### Added
- `ghostel-project` function ([560776f](https://github.com/dakra/ghostel/commit/560776f)).
- `ghostel-scroll-on-input` to jump to bottom on typing ([cabb939](https://github.com/dakra/ghostel/commit/cabb939)).
- `ghostel--cursor-position` to query terminal cursor location ([e3852d8](https://github.com/dakra/ghostel/commit/e3852d8)).
- `ghostel-copy-mode-recenter` (`C-l`) for copy mode ([6075b64](https://github.com/dakra/ghostel/commit/6075b64)).
- Full scrollback copy mode and copy-all command ([d07f509](https://github.com/dakra/ghostel/commit/d07f509)).
- `ghostel-copy-mode-auto-load-scrollback` option ([fc7fc94](https://github.com/dakra/ghostel/commit/fc7fc94)).

### Changed
- Bump minimum Emacs version for CI test to 28.2 ([cd3031d](https://github.com/dakra/ghostel/commit/cd3031d)).
- Preserve manual ghostel buffer renames ([c6eb801](https://github.com/dakra/ghostel/commit/c6eb801)).
- Rework how ghostel buffers are created ([cd7c043](https://github.com/dakra/ghostel/commit/cd7c043)).
- Ignore byte-compiled elisp files ([cfb0112](https://github.com/dakra/ghostel/commit/cfb0112)).
- Move `ghostel--suppress-interfering-modes` call inside `ghostel-mode` ([59b6928](https://github.com/dakra/ghostel/commit/59b6928)).
- Display lint errors when checking locally ([628ecae](https://github.com/dakra/ghostel/commit/628ecae)).
- Terminal buffers now respect `display-buffer-alist` rules (e.g.
  `(derived-mode . ghostel-mode)`). Fixes
  [#56](https://github.com/dakra/ghostel/issues/56)
  ([85b3e5f](https://github.com/dakra/ghostel/commit/85b3e5f)).
- Preserve column position when scrolling in copy mode ([0e7f904](https://github.com/dakra/ghostel/commit/0e7f904)).

### Fixed
- Lint warnings (and add test) ([20586fd](https://github.com/dakra/ghostel/commit/20586fd)).
- Meta key combinations not forwarded to terminal ([43220db](https://github.com/dakra/ghostel/commit/43220db)).

## [0.7.1] — 2026-04-06

### Added
- Prebuilt binaries for x86_64-macos and aarch64-linux (in addition to
  the existing x86_64-linux and aarch64-macos). Closes
  [#43](https://github.com/dakra/ghostel/issues/43)
  ([d04afa6](https://github.com/dakra/ghostel/commit/d04afa6)).
- MELPA installation instructions and source build notes ([c1d0daf](https://github.com/dakra/ghostel/commit/c1d0daf)).

### Changed
- Address MELPA review feedback ([416cf7a](https://github.com/dakra/ghostel/commit/416cf7a)).

### Fixed
- Build on musl-based distros (Alpine Linux) ([204164f](https://github.com/dakra/ghostel/commit/204164f)).
- Scrollback defaults treated as bytes and not lines ([21abb3d](https://github.com/dakra/ghostel/commit/21abb3d)).
- Module download URL when installed from MELPA ([cb74461](https://github.com/dakra/ghostel/commit/cb74461)).
- Mouse scroll when `pixel-scroll-precision-mode` is enabled ([067af25](https://github.com/dakra/ghostel/commit/067af25)).
- `ghostel-test-package-version` failure with stale `.elc` ([beb72d5](https://github.com/dakra/ghostel/commit/beb72d5)).

## [0.7.0] — 2026-04-05

### Changed
- Use `grid_ref` API for hyperlink detection instead of HTML formatter ([23aa22a](https://github.com/dakra/ghostel/commit/23aa22a)).
- Optimize release binaries: strip symbols and enable dead-code elimination ([f6f3ba3](https://github.com/dakra/ghostel/commit/f6f3ba3)).

## [0.6.0] — 2026-04-05

### Changed
- Change ghostty submodule from ssh to https ([607beae](https://github.com/dakra/ghostel/commit/607beae)).

### Fixed
- `C-t` and other control keys not being sent to the terminal ([d4ac858](https://github.com/dakra/ghostel/commit/d4ac858)).

## [0.5] — 2026-04-05

### Added
- Bind `s-v` (Cmd-V) to `ghostel-yank` on macOS ([4e43d38](https://github.com/dakra/ghostel/commit/4e43d38)).

### Changed
- Improve typing responsiveness with immediate redraw and input coalescing ([a30b53a](https://github.com/dakra/ghostel/commit/a30b53a)).

### Fixed
- Clicking ghostel buffer not switching window focus ([d030cbb](https://github.com/dakra/ghostel/commit/d030cbb)).
- `struct_timespec` opaque type error on some Linux systems ([5e1660b](https://github.com/dakra/ghostel/commit/5e1660b)).
- Dim/faint text (SGR 2) is now rendered by dimming the foreground
  colour (previously used `:weight light`, which most monospace fonts
  ignore). Closes [#27](https://github.com/dakra/ghostel/issues/27)
  ([a644834](https://github.com/dakra/ghostel/commit/a644834)).
- Backspace not working in fish shell ([36433fd](https://github.com/dakra/ghostel/commit/36433fd)).

## [0.4] — 2026-04-04

### Added
- Claude Code GitHub Actions workflows ([23b7caa](https://github.com/dakra/ghostel/commit/23b7caa)).
- Prompt to install native module when `ghostel` command is called ([57c6352](https://github.com/dakra/ghostel/commit/57c6352)).

### Changed
- Set default terminal fg/bg from Emacs theme colors ([e66a57d](https://github.com/dakra/ghostel/commit/e66a57d)).

## [0.3] — 2026-04-04

### Added
- Module version check to detect stale native modules ([be5c399](https://github.com/dakra/ghostel/commit/be5c399)).
- Shrink terminal when tall glyphs push content off-screen ([d913076](https://github.com/dakra/ghostel/commit/d913076)).

### Changed
- Compensate for wide-char pixel overflow by hiding trailing spaces ([e87d820](https://github.com/dakra/ghostel/commit/e87d820)).
- Skip wide-character spacer cells to fix emoji line overflow ([40b23e1](https://github.com/dakra/ghostel/commit/40b23e1)).
- Skip wide-char compensation when no wide characters are present ([691a752](https://github.com/dakra/ghostel/commit/691a752)).
- Revert overflow detection — keep only viewport pinning ([d335346](https://github.com/dakra/ghostel/commit/d335346)).
- Fix melpazoid warning ([ff6dc1b](https://github.com/dakra/ghostel/commit/ff6dc1b)).

### Removed
- `ghostel--pin-window-start` (caused emoji clipping) ([f029fbf](https://github.com/dakra/ghostel/commit/f029fbf)).

### Fixed
- Drag-and-drop by extracting drop data from correct event position ([794b5c8](https://github.com/dakra/ghostel/commit/794b5c8)).

## [0.2] — 2026-04-02

### Added
- Automatic theme color synchronization ([eb545fa](https://github.com/dakra/ghostel/commit/eb545fa)).
- ERT test for `ghostel-sync-theme` ([9668724](https://github.com/dakra/ghostel/commit/9668724)).
- Performance benchmark suite comparing ghostel, vterm, and eat ([a184e34](https://github.com/dakra/ghostel/commit/a184e34)).
- Emacs built-in `term` added to benchmark suite; README performance section ([2c86fb5](https://github.com/dakra/ghostel/commit/2c86fb5)).
- Ghostel vs. vterm comparison section in README ([3c71314](https://github.com/dakra/ghostel/commit/3c71314)).
- OSC 51 elisp eval from shell ([b3094b7](https://github.com/dakra/ghostel/commit/b3094b7)).
- Table of contents in README ([ece4a52](https://github.com/dakra/ghostel/commit/ece4a52)).
- `ghostel-full-redraw` option and force `window-start` pin ([1f299df](https://github.com/dakra/ghostel/commit/1f299df)).
- Multi-version byte-compile job; warnings treated as errors ([97258ef](https://github.com/dakra/ghostel/commit/97258ef)).
- Makefile ([835d878](https://github.com/dakra/ghostel/commit/835d878)).

### Changed
- Migrate test suite from custom framework to ERT ([bb986a2](https://github.com/dakra/ghostel/commit/bb986a2)).
- Build with `ReleaseFast` for production performance ([7393e64](https://github.com/dakra/ghostel/commit/7393e64)).
- Replace manual lint CI with melpazoid ([ede8f76](https://github.com/dakra/ghostel/commit/ede8f76)).
- Remove `Package-Requires` from secondary file ([c47662c](https://github.com/dakra/ghostel/commit/c47662c)).
- Fix melpazoid lint warnings ([9e0f076](https://github.com/dakra/ghostel/commit/9e0f076)).
- Filter libghostty info log spam from benchmark output ([ae0e9b9](https://github.com/dakra/ghostel/commit/ae0e9b9)).
- Overhaul README: installation, features, configuration ([1649771](https://github.com/dakra/ghostel/commit/1649771)).
- Exit copy mode on normal key press ([2ee9d3b](https://github.com/dakra/ghostel/commit/2ee9d3b)).
- Show cursor in copy-mode even when terminal app hid it ([c78b290](https://github.com/dakra/ghostel/commit/c78b290)).
- Suppress `hl-line-mode` in terminal buffer to prevent prompt flicker ([a9a07f1](https://github.com/dakra/ghostel/commit/a9a07f1)).
- Byte-compile warnings treated as errors in CI ([56ef155](https://github.com/dakra/ghostel/commit/56ef155)).

### Fixed
- Bottom lines cut off when TUI apps fill the screen ([f276f2d](https://github.com/dakra/ghostel/commit/f276f2d)).
- `extractString` silently dropping data >= 64KB ([1f88bed](https://github.com/dakra/ghostel/commit/1f88bed)).
- Missing `errdefer` for `mouse_encoder` in `Terminal.init` ([04ca152](https://github.com/dakra/ghostel/commit/04ca152)).
- Heap fallback for HTML formatter buffer in `scanHyperlinks` ([08e2649](https://github.com/dakra/ghostel/commit/08e2649)).
- `ghostel-dir` falling back to `default-directory` in `start-process` ([6d45a0d](https://github.com/dakra/ghostel/commit/6d45a0d)).
- Missing double-quote escaping in zsh `ghostel_cmd` ([d398fec](https://github.com/dakra/ghostel/commit/d398fec)).
- Copy-mode `M->` landing at bottom-right and exit not scrolling back ([4a9eb59](https://github.com/dakra/ghostel/commit/4a9eb59)).
- `ghostel-clear` and `ghostel-clear-scrollback` ([6ac0ba2](https://github.com/dakra/ghostel/commit/6ac0ba2)).

## [0.1] — 2026-03-31

Initial tagged release.

### Added
- Initial skeleton: Emacs terminal module powered by libghostty-vt ([d0e0ee3](https://github.com/dakra/ghostel/commit/d0e0ee3)).
- Styled rendering with colors, bold, italic, underline, etc. ([150e9e2](https://github.com/dakra/ghostel/commit/150e9e2)).
- Key encoding via `GhosttyKeyEncoder` ([a8ad51b](https://github.com/dakra/ghostel/commit/a8ad51b)).
- Scrollback, cursor style, and resize improvements ([f23290e](https://github.com/dakra/ghostel/commit/f23290e)).
- Mouse input, paste, copy mode, directory tracking ([de8d2c7](https://github.com/dakra/ghostel/commit/de8d2c7)).
- Test suite (61 tests) ([6be06f7](https://github.com/dakra/ghostel/commit/6be06f7)).
- Incremental redraw using `DIRTY_PARTIAL` ([c8024ed](https://github.com/dakra/ghostel/commit/c8024ed)).
- Focus event support gated by DEC mode 1004 ([3855df9](https://github.com/dakra/ghostel/commit/3855df9)).
- ANSI 16-color palette customization ([b42321f](https://github.com/dakra/ghostel/commit/b42321f)).
- Use face inheritance for ANSI color palette ([e75f897](https://github.com/dakra/ghostel/commit/e75f897)).
- `INSIDE_EMACS=ghostel` in shell environment ([a496249](https://github.com/dakra/ghostel/commit/a496249)).
- `ghostel-kill-buffer-on-exit` option ([6d31a99](https://github.com/dakra/ghostel/commit/6d31a99)).
- Shell integration scripts for bash, zsh, and fish ([eddc7d8](https://github.com/dakra/ghostel/commit/eddc7d8)).
- Auto-inject shell integration without requiring .bashrc changes ([593af8e](https://github.com/dakra/ghostel/commit/593af8e)).
- Clear scrollback and clear screen commands ([f8c9a80](https://github.com/dakra/ghostel/commit/f8c9a80)).
- `ghostel-send-next-key` escape hatch ([aa9207b](https://github.com/dakra/ghostel/commit/aa9207b)).
- `ghostel-yank` and `ghostel-yank-pop` for kill-ring cycling ([6eaa60b](https://github.com/dakra/ghostel/commit/6eaa60b)).
- `ghostel-exit-functions` hook ([0b5de44](https://github.com/dakra/ghostel/commit/0b5de44)).
- OSC 52 clipboard support ([a7eb78a](https://github.com/dakra/ghostel/commit/a7eb78a)).
- OSC 8 hyperlink support with click-to-open ([58f92e3](https://github.com/dakra/ghostel/commit/58f92e3)).
- OSC 133 semantic prompt markers for prompt navigation ([052c3d7](https://github.com/dakra/ghostel/commit/052c3d7)).
- URL auto-detection and `file://` link support ([b0d143c](https://github.com/dakra/ghostel/commit/b0d143c)).
- Detect file:line references and open them in Emacs on click ([454b794](https://github.com/dakra/ghostel/commit/454b794)).
- Separate defcustom for file:line detection ([457977b](https://github.com/dakra/ghostel/commit/457977b)).
- Bracketed paste conditional on terminal mode 2004 ([e209445](https://github.com/dakra/ghostel/commit/e209445)).
- Cache frequently-used Emacs symbols as global refs ([7103a56](https://github.com/dakra/ghostel/commit/7103a56)).
- Synchronized output support and debounced resize ([0a2eb85](https://github.com/dakra/ghostel/commit/0a2eb85)).
- Keyboard scrolling in copy mode ([83b7f44](https://github.com/dakra/ghostel/commit/83b7f44)).
- `M-<` / `M->` to jump to top/bottom of scrollback in copy mode ([ea4353f](https://github.com/dakra/ghostel/commit/ea4353f)).
- `C-e` in copy mode to stop at last non-whitespace character ([c2328dc](https://github.com/dakra/ghostel/commit/c2328dc)).
- Preserve column position during `C-n`/`C-p` in copy mode ([7a04588](https://github.com/dakra/ghostel/commit/7a04588)).
- Strip trailing whitespace from copied text in copy mode ([7d0de0f](https://github.com/dakra/ghostel/commit/7d0de0f)).
- Filter soft-wrapped newlines in copy mode ([f384746](https://github.com/dakra/ghostel/commit/f384746)).
- `ghostel-module-compile` command ([d75d9d1](https://github.com/dakra/ghostel/commit/d75d9d1)).
- Cross-platform build support and module auto-download ([a734e8e](https://github.com/dakra/ghostel/commit/a734e8e)).
- Rework module installation with interactive choice and defcustom ([f95fd8a](https://github.com/dakra/ghostel/commit/f95fd8a)).
- Full native build in CI and add release workflow ([20bf1f6](https://github.com/dakra/ghostel/commit/20bf1f6)).
- GitHub Actions CI with linting and tests ([3a190e3](https://github.com/dakra/ghostel/commit/3a190e3)).
- Improve code quality, adaptive redraw, and CI coverage ([ebe6f8b](https://github.com/dakra/ghostel/commit/ebe6f8b)).
- GPL3 license and expanded commentary section ([1d676df](https://github.com/dakra/ghostel/commit/1d676df)).
- README with build instructions, features, and configuration ([c43bf6a](https://github.com/dakra/ghostel/commit/c43bf6a)).

[0.19.0]: https://github.com/dakra/ghostel/compare/v0.18.1...v0.19.0
[0.18.1]: https://github.com/dakra/ghostel/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/dakra/ghostel/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/dakra/ghostel/compare/v0.16.3...v0.17.0
[0.16.3]: https://github.com/dakra/ghostel/compare/v0.16.2...v0.16.3
[0.16.2]: https://github.com/dakra/ghostel/compare/v0.16.1...v0.16.2
[0.16.1]: https://github.com/dakra/ghostel/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/dakra/ghostel/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/dakra/ghostel/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/dakra/ghostel/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/dakra/ghostel/compare/v0.12.2...v0.13.0
[0.12.2]: https://github.com/dakra/ghostel/compare/v0.12.1...v0.12.2
[0.12.1]: https://github.com/dakra/ghostel/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/dakra/ghostel/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/dakra/ghostel/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/dakra/ghostel/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/dakra/ghostel/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/dakra/ghostel/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/dakra/ghostel/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/dakra/ghostel/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/dakra/ghostel/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/dakra/ghostel/compare/v0.5...v0.6.0
[0.5]: https://github.com/dakra/ghostel/compare/v0.4...v0.5
[0.4]: https://github.com/dakra/ghostel/compare/v0.3...v0.4
[0.3]: https://github.com/dakra/ghostel/compare/v0.2...v0.3
[0.2]: https://github.com/dakra/ghostel/compare/v0.1...v0.2
[0.1]: https://github.com/dakra/ghostel/releases/tag/v0.1
