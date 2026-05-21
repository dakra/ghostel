;;; evil-ghostel.el --- Evil-mode integration for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.28.0
;; Package-Requires: ((emacs "28.1") (evil "1.0") (ghostel "0.8.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Provides evil-mode compatibility for the ghostel terminal emulator.
;; Defines `evil-ghostel-*' commands (operators, motions, insert/append
;; variants) and binds them via `evil-ghostel-mode-map' for normal and
;; visual states.  Each command clamps its range to the live input
;; region and drives the shell's readline via PTY arrow keys and
;; backspaces, so motion-overshoot (e.g. `cw' at end-of-input) cannot
;; over-delete past the cursor.
;;
;; Outside `semi-char' input mode the commands fall through to vanilla
;; `evil-*' so line/copy/emacs modes (which edit buffer text directly)
;; behave like ordinary evil buffers.
;;
;; Enable by adding to your init:
;;
;;   (use-package evil-ghostel
;;     :after (ghostel evil)
;;     :hook (ghostel-mode . evil-ghostel-mode))

;;; Code:

(require 'evil)
(require 'ghostel)

(declare-function ghostel--mode-enabled "ghostel-module")

(defvar evil-ghostel-mode)


;; Customization

(defgroup evil-ghostel nil
  "Evil-mode integration for ghostel."
  :group 'ghostel
  :prefix "evil-ghostel-")

(defcustom evil-ghostel-initial-state 'insert
  "Initial evil state for new `ghostel-mode' buffers.
Setting this option via `customize-set-variable', `setopt', or the
Customize UI calls `evil-set-initial-state' so the change takes effect
immediately.  Users who prefer the raw API can call
`evil-set-initial-state' directly from their config — the registry is
last-writer-wins."
  :type '(choice (const :tag "Emacs" emacs)
                 (const :tag "Insert" insert)
                 (const :tag "Normal" normal)
                 (symbol :tag "Other state"))
  :set (lambda (sym val)
         (set-default-toplevel-value sym val)
         (evil-set-initial-state 'ghostel-mode val)))

(defcustom evil-ghostel-escape 'auto
  "Where insert-state ESC is routed in ghostel buffers.

`auto'      — when the inner app is in alt-screen mode (DECSET 1049,
              used by vim, less, htop, nvim, etc.) ESC is sent to the
              terminal; otherwise evil's binding runs and switches to
              normal state.
`terminal'  — always send ESC to the terminal.
`evil'      — always run evil's binding (ESC stays with evil).

Sets the initial value of the buffer-local state.  Use
\\[evil-ghostel-toggle-send-escape] to change it for the current buffer."
  :type '(choice (const :tag "Auto (alt-screen heuristic)" auto)
                 (const :tag "Always to terminal" terminal)
                 (const :tag "Always to evil" evil)))

(defcustom evil-ghostel-right-prompt-gap 6
  "Minimum whitespace run that separates input from a right-aligned prompt.
`evil-ghostel--cursor-row-end-point' uses this when it cannot find an
OSC 133;B `ghostel-input' anchor on the cursor row.  Walking backward
from EOL, a whitespace run of at least this many columns is treated
as the separator between user input (on the left) and a right-aligned
prompt or status indicator (on the right) — for example fish's
`fish_right_prompt' content like `main *'.  Content right of the gap
is excluded from `$' / `y$' / clamped operator ranges so the right
prompt is never edited as if it were typed input.

Set to a very large number (e.g. 999) to disable the heuristic.
Lower values catch tighter right-prompt gaps but risk false positives
on regular input that contains long runs of spaces (e.g. tabular
output piped to a column-aligned `read').  The default 6 matches
fish's typical padding while staying conservative on normal input."
  :type 'integer)

;; Apply the current value at load.  Covers the case where the user set
;; the variable with plain `setq' before loading the package — in that
;; path `defcustom' preserves the value without invoking `:set'.
(evil-set-initial-state 'ghostel-mode evil-ghostel-initial-state)


;; Guard predicates

(defun evil-ghostel--active-p ()
  "Return non-nil when evil-ghostel PTY routing should intercept.
True in `semi-char' input mode and outside alt-screen — the only
combination where `evil-ghostel-*' commands send PTY keys instead
of falling through to vanilla `evil-*'."
  (and evil-ghostel-mode
       ghostel--term
       (not (ghostel--mode-enabled ghostel--term 1049))
       (eq ghostel--input-mode 'semi-char)))

(defun evil-ghostel--line-mode-active-p ()
  "Return non-nil when line mode editing is in effect.
Line mode buffers shell input as plain buffer text inside
`[ghostel--line-input-start, ghostel--line-input-end]'.  evil's
default editing operators (operating on buffer text) are exactly
right there, so PTY-routing intercepts must stand down."
  (and evil-ghostel-mode
       (eq ghostel--input-mode 'line)
       (markerp ghostel--line-input-start)
       (markerp ghostel--line-input-end)))


;; Cursor synchronization

(defun evil-ghostel--reset-cursor-point ()
  "Move Emacs point to the terminal cursor position.
`ghostel--cursor-pos' holds the viewport-relative (COL . ROW), so
the row must be offset by the scrollback line count.  Mirrors the
placement math the native module performs in `src/render.zig'."
  (when (and ghostel--term ghostel--term-rows)
    (let ((pos ghostel--cursor-pos))
      (when pos
        (let ((scrollback (max 0 (- (count-lines (point-min) (point-max))
                                    ghostel--term-rows))))
          (goto-char (point-min))
          (forward-line (+ scrollback (cdr pos)))
          (move-to-column (car pos)))))))

(defun evil-ghostel--cursor-buffer-line ()
  "Return the 0-indexed buffer line of the terminal cursor, or nil.
Translates `ghostel--cursor-pos' (viewport-relative row) into a
buffer line by adding the scrollback line count.  Mirrors the
placement math the native module performs in `src/render.zig'."
  (when (and ghostel--term ghostel--term-rows)
    (let ((pos ghostel--cursor-pos))
      (when pos
        (let ((scrollback (max 0 (- (count-lines (point-min) (point-max))
                                    ghostel--term-rows))))
          (+ scrollback (cdr pos)))))))

(defun evil-ghostel--point-viewport-row ()
  "Return the viewport row of point, 0-indexed, or nil.
Subtracts the scrollback line count from the buffer line so the
result is comparable to `ghostel--cursor-pos''s row."
  (when ghostel--term-rows
    (let ((scrollback (max 0 (- (count-lines (point-min) (point-max))
                                ghostel--term-rows))))
      (- (line-number-at-pos (point) t) 1 scrollback))))

(defun evil-ghostel--point-on-cursor-line-p ()
  "Return non-nil when point is on the buffer line of the terminal cursor.
Reflects current state (libghostty cursor + Emacs buffer); only
meaningful after a redraw has synchronized the two.  Inside
`evil-ghostel--around-redraw' the libghostty cursor has already
advanced past output that the buffer hasn't rendered yet, so this
helper is unsafe there — use `evil-ghostel--last-cursor-line' instead."
  (let ((cursor-line (evil-ghostel--cursor-buffer-line)))
    (when cursor-line
      (= (- (line-number-at-pos (point) t) 1) cursor-line))))

(defvar-local evil-ghostel--last-cursor-line nil
  "Buffer line where the previous redraw placed the terminal cursor.
Used by `evil-ghostel--around-redraw' to recognize the case where the
user is parked at the live prompt and the prompt scrolls during the
redraw — only then does the renderer's cursor placement win across
the redraw, so column-only navigation (`^', `$', `0', and the like)
survives redraws that *don't* scroll the prompt.")


;; Redraw: preserve point and evil visual markers across the native call

(defun evil-ghostel--around-redraw (orig-fn term &optional full)
  "Preserve point and evil visual markers across the native redraw call.
Native `ghostel--redraw' in `src/render.zig' rewrites the viewport
region, moving every marker in the buffer.  `point' (non-terminal
states) and the evil-specific visual range markers are restored here;
`mark' is preserved by the native module itself and needs no handling
at this layer.

  - `point' in non-terminal states.  In `insert' and `emacs' point
    intentionally follows the TUI cursor.  In `normal' (and other
    non-visual non-terminal states) point follows the cursor too when
    the user was parked at the prompt position (line *and* column)
    before the redraw — the renderer leaves point at the new cursor
    and we keep it there so the prompt isn't left behind by output.
    Otherwise the saved buffer position is restored so scrollback
    navigation, and column-only motions like `^'/`$', are undisturbed.
  - `evil-visual-beginning' and `evil-visual-end' in `visual' state.

ORIG-FN is the advised `ghostel--redraw' called with TERM and FULL.
Skipped when the terminal is in alt-screen mode (1049); apps there
own the screen and drive their own redraw cycle."
  (if (and evil-ghostel-mode
           (not (ghostel--mode-enabled term 1049)))
      (let* ((preserve-point (not (memq evil-state '(insert emacs))))
             (visual-p (eq evil-state 'visual))
             (saved-point (and preserve-point (point)))
             ;; Pre-redraw, was the user parked on the cursor's
             ;; buffer line?  If yes *and* the redraw moves the
             ;; cursor onto a new line (output scrolled the prompt),
             ;; we let the renderer's placement win so the user
             ;; isn't stranded above the live prompt — that's the
             ;; intent of `evil-ghostel-test-around-redraw-snaps-
             ;; point-on-prompt-line'.  When the cursor stays on the
             ;; same line, we restore saved-point so single-line
             ;; column navigation (`^', `$', `0') isn't undone by an
             ;; incidental redraw.
             (pre-line (and preserve-point (not visual-p)
                            (- (line-number-at-pos (point) t) 1)))
             (was-on-prompt-line (and pre-line
                                      evil-ghostel--last-cursor-line
                                      (= pre-line
                                         evil-ghostel--last-cursor-line)))
             (saved-vb (and visual-p (bound-and-true-p evil-visual-beginning)
                            (marker-position evil-visual-beginning)))
             (saved-ve (and visual-p (bound-and-true-p evil-visual-end)
                            (marker-position evil-visual-end))))
        (funcall orig-fn term full)
        (let* ((post-cursor-line (evil-ghostel--cursor-buffer-line))
               (prompt-moved (and was-on-prompt-line
                                  post-cursor-line
                                  (not (= post-cursor-line pre-line)))))
          (when (and preserve-point (not prompt-moved))
            (goto-char (min saved-point (point-max))))
          (when visual-p
            (let ((pmax (point-max)))
              (when saved-vb
                (set-marker evil-visual-beginning (min saved-vb pmax)))
              (when saved-ve
                (set-marker evil-visual-end (min saved-ve pmax)))))
          ;; Record where the renderer placed the cursor so the next
          ;; redraw can detect whether the user is still at the
          ;; prompt line.
          (setq evil-ghostel--last-cursor-line post-cursor-line)))
    (funcall orig-fn term full)))


;; Cursor style: let evil control cursor shape

(defun evil-ghostel--override-cursor-style (orig-fn style visible)
  "Let evil control cursor shape instead of the terminal.
ORIG-FN is the advised setter called with STYLE and VISIBLE.
In alt-screen mode, defer to the terminal's cursor style."
  (if (and evil-ghostel-mode
           ghostel--term
           (not (ghostel--mode-enabled ghostel--term 1049)))
      (evil-refresh-cursor)
    (funcall orig-fn style visible)))


;; Evil state hooks

(defun evil-ghostel--insert-state-entry ()
  "Sync terminal cursor to Emacs point on insert/emacs state entry.
Safety net for transitions that did not route through the
`evil-ghostel-*' commands (which already drive the shell cursor to
their target via `evil-ghostel-goto-input-position').  Skipped
outside semi-char: in line mode point and the terminal cursor are
intentionally decoupled (the user is editing buffer text, not
driving the shell cursor); in copy/Emacs/char modes the sync would
either fight a read-only buffer or be redundant.

When point is on a different row from the terminal cursor, snap
back to the terminal cursor instead of sending up/down arrows
which the shell would interpret as history navigation."
  (when (and (derived-mode-p 'ghostel-mode)
             (evil-ghostel--active-p))
    (let* ((tpos ghostel--cursor-pos)
           (trow (cdr tpos))
           ;; `tpos' is viewport-relative; convert point's buffer
           ;; line to a viewport row before comparing — otherwise
           ;; in any session with scrollback the rows compare as
           ;; unequal even when point is on the cursor's row, and
           ;; we drop into `reset-cursor-point' which snaps point
           ;; back to the terminal cursor (silently undoing the
           ;; user's `^', `$', `0' navigation).
           (erow (or (evil-ghostel--point-viewport-row) 0)))
      (if (= erow trow)
          (evil-ghostel-goto-input-position (point))
        (evil-ghostel--reset-cursor-point)))))

(defun evil-ghostel--escape-stay ()
  "Disable `evil-move-cursor-back' in ghostel buffers.
Moving the cursor back on ESC desynchronizes point from the terminal cursor."
  (setq-local evil-move-cursor-back nil))


;; PTY-driven input editing
;;
;; Drive the running shell's line editor (readline / zle / prompt_toolkit)
;; by sending arrow keys + backspace + bracketed paste through the PTY.
;; Assumes a cooperative line editor — in raw-mode TUIs (vim, less, htop)
;; the keys are interpreted by the inner program, not used for editing,
;; and these helpers will return nil or silently no-op.  Only meaningful
;; in `semi-char' input mode.

(defun evil-ghostel--input-end-via-property ()
  "Return position right after the first `ghostel-input' region on the row.
Returns the *first* region (not the rightmost) so a later region from
fish's right-prompt cells — which libghostty's per-cell semantic
heuristic also tags SEMANTIC_INPUT, despite no 133;B emission — is
ignored.  The typed-input region is always the first one because the
prompt prefix cells (which precede it) carry `ghostel-prompt' rather
than `ghostel-input'.

For bash / zsh with proper 133;B integration, typed input is a single
contiguous region anyway (cells between 133;B and 133;C all carry
SEMANTIC_INPUT, including any whitespace inside the input), so the
first-region answer equals the rightmost-cell answer.

Returns nil when no `ghostel-input' cells are found on the row."
  (when ghostel--cursor-char-pos
    (save-excursion
      (goto-char ghostel--cursor-char-pos)
      (let* ((bol (line-beginning-position))
             (eol (line-end-position))
             (region-start (text-property-any bol eol 'ghostel-input t)))
        (when region-start
          (next-single-property-change region-start 'ghostel-input nil eol))))))

(defun evil-ghostel--input-end-via-gap ()
  "Return the position just after typed input on the cursor row, heuristically.
Strips trailing whitespace from EOL, then walks backward looking for
a whitespace run of `evil-ghostel-right-prompt-gap' or more columns;
when one is found, treats content right of the gap as a right-aligned
prompt and returns the position just before the gap.  Without such a
gap, returns the position right after the last non-whitespace
character on the row.

Used as the fallback when `evil-ghostel--input-end-via-property'
returns nil — most importantly for fish (whose right prompt is drawn
as ordinary cells without OSC 133;B markers)."
  (when ghostel--cursor-char-pos
    (save-excursion
      (goto-char ghostel--cursor-char-pos)
      (let* ((bol (line-beginning-position))
             (eol (line-end-position))
             (gap evil-ghostel-right-prompt-gap)
             (scan eol)
             (result nil))
        (goto-char eol)
        (skip-chars-backward " \t" bol)
        (setq scan (point))
        (while (and (> scan bol) (not result))
          (if (not (memq (char-before scan) '(?\s ?\t)))
              (setq scan (1- scan))
            (let ((ws-end scan))
              (while (and (> scan bol)
                          (memq (char-before scan) '(?\s ?\t)))
                (setq scan (1- scan)))
              (when (>= (- ws-end scan) gap)
                (setq result scan)))))
        (or result
            (save-excursion
              (goto-char eol)
              (skip-chars-backward " \t" bol)
              (point)))))))

(defun evil-ghostel--cursor-row-end-point ()
  "Return the position just after typed input on the cursor row.
Prefers `evil-ghostel--input-end-via-property' (the end of the first
contiguous `ghostel-input' region — the typed input).  Falls back
to `evil-ghostel--input-end-via-gap' when no `ghostel-input' cells
are present on the row (shell session without OSC 133 integration).

Returns nil when no cursor row is known.  Used by `$', `y$', the
forward-motion clamps, and the operator range clamp to keep ranges
from extending into renderer-emitted padding or a right-aligned
prompt (fish `fish_right_prompt', zsh-autosuggest hint, RPROMPT)."
  (or (evil-ghostel--input-end-via-property)
      (evil-ghostel--input-end-via-gap)))

(defun evil-ghostel-point-in-input-p (&optional pos)
  "Return non-nil when POS (default `point') is in the editable input region.
POS must be on the cursor's row AND between `ghostel-input-start-point'
and `evil-ghostel--cursor-row-end-point' (inclusive).  Modeled on
`vterm-cursor-in-command-buffer-p'.  Returns nil when no terminal
cursor is available."
  (when (ghostel-point-on-cursor-row-p pos)
    (let ((p (or pos (point)))
          (start (ghostel-input-start-point))
          (row-end (evil-ghostel--cursor-row-end-point)))
      (and start row-end (>= p start) (<= p row-end)))))

(defun evil-ghostel--input-start-from-prop ()
  "Return input start derived from the cursor row's `ghostel-prompt' prop, or nil.
Distinct from `ghostel-input-start-point' in that the property
fallback to `ghostel--cursor-char-pos' is omitted — callers that
need a *reliable* prompt-anchored boundary (e.g. clamping) get nil
when no OSC 133 prop is available rather than mistaking the live
cursor for the input's left edge."
  (let ((cursor-pos ghostel--cursor-char-pos))
    (when cursor-pos
      (let* ((row-start (save-excursion
                          (goto-char cursor-pos)
                          (line-beginning-position)))
             (pos cursor-pos))
        (while (and (> pos row-start)
                    (not (get-text-property (1- pos) 'ghostel-prompt)))
          (setq pos (1- pos)))
        (and (> pos row-start)
             (get-text-property (1- pos) 'ghostel-prompt)
             pos)))))

(defun evil-ghostel--clamp-to-input (region)
  "Clamp REGION (a (BEG . END) cons) to the input region.
Returns a new cons.

When both endpoints sit on the cursor's row, END is clamped to
`evil-ghostel--cursor-row-end-point' (past-end of typed input).  BEG
is clamped to the OSC 133 prompt prefix when that's available;
without the prop, the start of input is unknown and BEG is left
alone (so operators in zsh / bash without shell integration don't
get their ranges collapsed to nothing).

When the range starts on the cursor's row but END walks off it
\(forward-word overshoot at end-of-input, e.g. `dw' on the last
word), END is clamped to `evil-ghostel--cursor-row-end-point' —
backspaces can't reach into renderer-painted cells anyway, and
over-deleting would erase real input.

Other off-row ranges (scrollback selections, multi-row TUI prompts
above the cursor) pass through unchanged."
  (let* ((beg (car region))
         (end (cdr region))
         (start (evil-ghostel--input-start-from-prop))
         (row-end (evil-ghostel--cursor-row-end-point))
         (beg-on-row (ghostel-point-on-cursor-row-p beg))
         (end-on-row (ghostel-point-on-cursor-row-p end)))
    (cond
     ((and beg-on-row end-on-row row-end)
      (cons (if start (max start (min row-end beg)) beg)
            (max (or start beg) (min row-end end))))
     ((and beg-on-row (not end-on-row) row-end (> end row-end))
      (cons (if start (max start beg) beg) row-end))
     (t region))))

(defun evil-ghostel--meaningful-input-length (text)
  "Length of TEXT, stripping per-line trailing whitespace in multi-line ranges.
Heuristic for TUIs that draw a fixed-width input box wider than
the user's typed text (e.g. prompt_toolkit-based REPLs that fill
each input row out to the box's right border).  The trailing
spaces end up in the buffer because the terminal explicitly wrote
them, but they are not characters in the TUI's input model.

Only applied when TEXT spans more than one buffer line.  In a
single-line range trailing whitespace is treated as real user
input and counted, so single-word deletions don't leave a stray
character behind."
  (if (string-match-p "\n" text)
      (length (replace-regexp-in-string "[ \t]+\\(\n\\|\\'\\)" "\\1" text))
    (length text)))

(defcustom evil-ghostel-sync-render-max-iterations 10
  "Maximum iterations of the drain loop in `evil-ghostel--sync-render'.
Each iteration waits up to 50 ms for output; the cap of 10
bounds total wait at ~500 ms so a runaway shell can't hang the
caller (e.g. `cc' / `cw' invoking `delete-input-region')."
  :type 'integer
  :group 'evil-ghostel)

(defun evil-ghostel--sync-render ()
  "Drain pending PTY output so cursor state reflects the latest echo.
Loops on `accept-process-output' (with `just-this-one' set so
other subprocesses are not advanced) until output stops arriving
or `evil-ghostel-sync-render-max-iterations' is reached; then, if
the filter deferred the redraw to its timer (the bulk-output
branch in `ghostel--filter' fires when output exceeds
`ghostel-immediate-redraw-threshold' or arrives outside
`ghostel-immediate-redraw-interval'), cancels the timer and
runs `ghostel--delayed-redraw' synchronously.

The forced redraw is what updates `ghostel--cursor-pos' /
`ghostel--cursor-char-pos'; without it, callers reading those
right after a >256-byte echo (e.g. `delete-input-region' sending
100 backspaces, then `evil-ghostel-insert' computing arrow
deltas) see stale state.

Used by `evil-ghostel-goto-input-position' and
`evil-ghostel-delete-input-region'."
  (when (and ghostel--process (process-live-p ghostel--process))
    (let ((iter 0))
      (while (and (< iter evil-ghostel-sync-render-max-iterations)
                  (accept-process-output ghostel--process 0.05 nil t))
        (setq iter (1+ iter))))
    (when (or ghostel--pending-output ghostel--redraw-timer)
      (when ghostel--redraw-timer
        (cancel-timer ghostel--redraw-timer)
        (setq ghostel--redraw-timer nil))
      (ghostel--delayed-redraw (current-buffer)))))

(defun evil-ghostel-goto-input-position (pos)
  "Move the terminal cursor and Emacs point to buffer position POS.
Returns t when the cursor reached POS, nil otherwise.

Sends |dy| up/down + |dx| left/right arrow keys to drive the
shell's readline (or equivalent) cursor toward POS.  POS must be
on, above, or below the terminal cursor's row; horizontal moves
beyond the input's edges are clamped by the shell.  On success,
drains the echo synchronously and snaps Emacs `point' to the
terminal cursor's new buffer position, so the cursor and point
agree after the call (analogous to vterm's `vterm-goto-char').

Detects two pathological echoes from inner programs and aborts the
move (returning nil) after attempting recovery:
- `^[[C' literal in the buffer (inner program does not interpret
  arrow keys): each right-arrow echoes as 4 visible characters;
  send three backspaces per arrow sent to clean up.
- Cursor jumped past POS on right-arrow moves (bash autosuggest's
  accept-on-right-arrow): send `C-_' to undo via readline.

Only meaningful in `semi-char' input mode."
  (when (and ghostel--term ghostel--cursor-pos)
    (let* ((start-char-pos ghostel--cursor-char-pos)
           (start-cursor ghostel--cursor-pos)
           (start-col (car start-cursor))
           (start-row-vp (cdr start-cursor))
           (target-col (save-excursion (goto-char pos) (current-column)))
           (target-row-vp (or (ghostel--viewport-row-at pos) start-row-vp))
           (dy (- target-row-vp start-row-vp))
           (dx (- target-col start-col))
           (right-arrow-drained nil)
           (reached
            (progn
              (cond ((> dy 0) (dotimes (_ dy) (ghostel--send-encoded "down" "")))
                    ((< dy 0) (dotimes (_ (abs dy)) (ghostel--send-encoded "up" ""))))
              (cond ((> dx 0) (dotimes (_ dx) (ghostel--send-encoded "right" "")))
                    ((< dx 0) (dotimes (_ (abs dx)) (ghostel--send-encoded "left" ""))))
              ;; Verify landing only when there's reason to suspect a pathology
              ;; (right-arrow moves can trigger literal-echo or autosuggest).
              ;; Echo detection requires `ghostel--cursor-char-pos' (the
              ;; rendered baseline) — when that's nil, treat the bulk send as
              ;; success and let the post-success drain below settle point.
              (if (or (<= dx 0) (null start-char-pos))
                  t
                (setq right-arrow-drained t)
                (evil-ghostel--sync-render)
                (let ((post-cur ghostel--cursor-char-pos))
                  (cond
                   ;; Landed where expected — success.
                   ((and post-cur (= post-cur pos)) t)
                   ;; Literal-echo pattern: cursor advanced exactly 4×dx
                   ;; from start, and the buffer ends with "^[[C".  Echo
                   ;; size is 4 (caret, [, [, C) per arrow; send 3 backspaces
                   ;; per arrow to undo, matching vterm's recovery.
                   ((and post-cur (zerop dy)
                         (= post-cur (+ start-char-pos (* 4 dx)))
                         (save-excursion
                           (goto-char post-cur)
                           (looking-back (regexp-quote "^[[C") (min 4 post-cur))))
                    (dotimes (_ (* 3 dx)) (ghostel--send-encoded "backspace" ""))
                    nil)
                   ;; Cursor jumped past target — bash autosuggest accepted.
                   ((and post-cur (> post-cur pos))
                    (ghostel--send-encoded "_" "ctrl")
                    nil)
                   ;; Anything else: didn't reach target, no recovery.
                   (t nil)))))))
      (when reached
        ;; Drain so `ghostel--cursor-pos' reflects the move before
        ;; returning — but skip the drain when the right-arrow branch
        ;; already drained, or when no arrows were sent at all.  Drop
        ;; point at the requested target directly; on success the
        ;; terminal cursor reached POS, so POS is where point belongs
        ;; (no dependency on the post-drain `ghostel--cursor-char-pos').
        (when (and (not right-arrow-drained)
                   (or (/= dx 0) (/= dy 0)))
          (evil-ghostel--sync-render))
        (goto-char pos))
      reached)))

(defun evil-ghostel-delete-input-region (beg end)
  "Delete the BEG..END buffer range from input via the terminal PTY.
Moves the terminal cursor to END, then sends one backspace per
meaningful character (per `evil-ghostel--meaningful-input-length' —
see its docstring for the trailing-whitespace heuristic in
multi-line ranges).  Leaves Emacs `point' at BEG so subsequent
commands (insert state entry, change → insert) see the cursor's new
buffer position rather than the pre-delete END.  Returns the number
of backspaces sent.

The buffer is not modified directly; the deletion takes effect once
the shell echoes the backspaces and the next redraw repaints the
input region.  Only meaningful in `semi-char' input mode."
  (let ((count (evil-ghostel--meaningful-input-length
                (buffer-substring-no-properties beg end))))
    (when (> count 0)
      (evil-ghostel-goto-input-position end)
      (dotimes (_ count)
        (ghostel--send-encoded "backspace" ""))
      ;; Drain so `ghostel--cursor-pos' reflects the post-backspace
      ;; cursor position before any caller (e.g. `evil-ghostel-insert'
      ;; for `cc' / `cw') reads it and computes an arrow target from it.
      (evil-ghostel--sync-render)
      (goto-char beg))
    count))

(defun evil-ghostel-replace-input-region (beg end string)
  "Replace the BEG..END range with STRING via the terminal PTY.
Deletes the range with `evil-ghostel-delete-input-region' then
pastes STRING through bracketed paste.  Only meaningful in
`semi-char' input mode."
  (let ((deleted (evil-ghostel-delete-input-region beg end)))
    (when (and (> deleted 0) string (not (string-empty-p string)))
      (ghostel--paste-text string))
    deleted))


;; Motions

(evil-define-motion evil-ghostel-beginning-of-line ()
                    "Move point to the start of input on a prompt row.
On a row carrying the `ghostel-prompt' text property (OSC 133) or
inside line mode's input markers, jump past the prompt prefix to
the first input character.  Otherwise fall through to
`evil-beginning-of-line' so column-0 navigation in scrollback and
non-prompt rows behaves as in vanilla evil."
                    :type exclusive
                    (if (or (evil-ghostel--active-p)
                            (evil-ghostel--line-mode-active-p))
                        (ghostel-beginning-of-input-or-line)
                      (evil-beginning-of-line)))

(evil-define-motion evil-ghostel-first-non-blank ()
  "Move point to the first non-blank character after the prompt.
On a prompt row, jumps past the prompt prefix; otherwise falls
through to `evil-first-non-blank'."
  :type exclusive
  (if (or (evil-ghostel--active-p)
          (evil-ghostel--line-mode-active-p))
      (ghostel-beginning-of-input-or-line)
    (evil-first-non-blank)))

(defun evil-ghostel--clamp-forward-motion (motion-fn count)
  "Run MOTION-FN with COUNT, then clamp point to the cursor row's input.
Used by forward word motions in normal state so they stop at
`evil-ghostel--cursor-row-end-point' instead of scanning into the blank
renderer rows below the live prompt.

Swallows `end-of-buffer'/`beginning-of-buffer' signals (vanilla
evil raises these on motion overshoot) and treats them as \"stop
where you are\" so the user doesn't get a noisy error every time
they `w' off the end of input."
  (let* ((active (and (evil-ghostel--active-p)
                      (ghostel-point-on-cursor-row-p)))
         (row-end (and active (evil-ghostel--cursor-row-end-point))))
    (condition-case _err
        (funcall motion-fn count)
      ((beginning-of-buffer end-of-buffer) nil))
    (when (and row-end (> (point) row-end))
      (goto-char row-end))))

(defun evil-ghostel--clamp-motion (motion-fn count)
  "Run MOTION-FN with COUNT, then clamp point to the cursor row's input.
Like `evil-ghostel--clamp-forward-motion' but also clamps the left
side to `ghostel-input-start-point' so backward / horizontal /
end-of-line motions (`h', `l', `$') cannot walk into the prompt
prefix or into renderer cells past end-of-input.

The lower-bound clamp only applies when point ended up on the
cursor row — if a backward motion left the row (e.g. `h' with
`evil-cross-lines' set), we don't teleport it back."
  (let* ((active (and (evil-ghostel--active-p)
                      (ghostel-point-on-cursor-row-p)))
         (row-end (and active (evil-ghostel--cursor-row-end-point)))
         (row-start (and active (ghostel-input-start-point))))
    (condition-case _err
        (funcall motion-fn count)
      ((beginning-of-buffer end-of-buffer
        beginning-of-line end-of-line) nil))
    (when (and row-end (> (point) row-end))
      (goto-char row-end))
    (when (and row-start (< (point) row-start)
               (ghostel-point-on-cursor-row-p))
      (goto-char row-start))))

(evil-define-motion evil-ghostel-forward-word-begin (count)
  "Forward to the start of the next word, clamped to the input row.
On the cursor row, never walks past `evil-ghostel--cursor-row-end-point' —
empty renderer rows below the prompt aren't treated as continuing
text.  Off the cursor row, falls through to `evil-forward-word-begin'.

Bound in normal state only; operator-pending state (e.g. `dw') uses
vanilla evil and lets `evil-ghostel--clamp-to-input' constrain the range."
  :type exclusive
  (evil-ghostel--clamp-forward-motion #'evil-forward-word-begin count))

(evil-define-motion evil-ghostel-forward-WORD-begin (count)
  "Forward to the start of the next WORD, clamped to the input row.
See `evil-ghostel-forward-word-begin' for the clamp semantics."
  :type exclusive
  (evil-ghostel--clamp-forward-motion #'evil-forward-WORD-begin count))

(evil-define-motion evil-ghostel-forward-word-end (count)
  "Forward to the end of the next word, clamped to the input row.
See `evil-ghostel-forward-word-begin' for the clamp semantics."
  :type inclusive
  (evil-ghostel--clamp-forward-motion #'evil-forward-word-end count))

(evil-define-motion evil-ghostel-forward-WORD-end (count)
                    "Forward to the end of the next WORD, clamped to the input row.
See `evil-ghostel-forward-word-begin' for the clamp semantics."
                    :type inclusive
                    (evil-ghostel--clamp-forward-motion #'evil-forward-WORD-end count))

(evil-define-motion evil-ghostel-forward-char (count)
  "Move forward COUNT characters, clamped to the input row.
On the cursor row, never walks past `evil-ghostel--cursor-row-end-point' —
trailing renderer cells (stale glyphs from prior input, RPROMPT padding,
zsh-autosuggest hints) are not treated as text.  Off the cursor row,
falls through to `evil-forward-char'."
  :type exclusive
  (evil-ghostel--clamp-motion #'evil-forward-char count))

(evil-define-motion evil-ghostel-backward-char (count)
  "Move backward COUNT characters, clamped to the input row.
On the cursor row, never walks past `ghostel-input-start-point' so
the prompt prefix can't be entered.  Off the cursor row, falls
through to `evil-backward-char'."
  :type exclusive
  (evil-ghostel--clamp-motion #'evil-backward-char count))

(evil-define-motion evil-ghostel-end-of-line (count)
  "Move to end of line, clamped to the input row.
On the cursor row, stops at `evil-ghostel--cursor-row-end-point' so `$'
lands on the last typed character — not on trailing renderer cells.
Off the cursor row, falls through to `evil-end-of-line'."
  :type inclusive
  (evil-ghostel--clamp-motion #'evil-end-of-line count))

(evil-define-motion evil-ghostel-next-line (count)
  "Move COUNT lines down, but not past the terminal cursor's row.
Prevents `j' from leaving the user stranded on empty renderer rows
below the live prompt.  Falls through to `evil-next-line' outside
semi-char."
  :type line
  (if (not (evil-ghostel--active-p))
      (evil-next-line count)
    (let ((cursor-line (evil-ghostel--cursor-buffer-line))
          (col (current-column)))
      (condition-case _err
          (evil-next-line count)
        ((beginning-of-buffer end-of-buffer) nil))
      (when (and cursor-line
                 (> (- (line-number-at-pos (point) t) 1) cursor-line))
        (goto-char (point-min))
        (forward-line cursor-line)
        (move-to-column col)))))

(defun evil-ghostel-goto-cursor ()
  "Move point to the live terminal cursor.
Replaces `evil-goto-line' (typically the G key) in ghostel buffers — the natural
\"go to the prompt\" gesture in a terminal.  Outside semi-char,
falls through to `evil-goto-line'."
  (interactive)
  (if (not (evil-ghostel--active-p))
      (call-interactively #'evil-goto-line)
    (evil-ghostel--reset-cursor-point)))


;; Insert / Append

(defun evil-ghostel-insert ()
  "Enter insert state at point, driving the shell cursor to match.
On a non-cursor row (e.g. parked in scrollback), snap to
`ghostel-input-start-point' first so typed characters land at the
live prompt rather than overwriting scrollback.  On the cursor
row, drive the shell cursor to point via
`evil-ghostel-goto-input-position', clamped to
`evil-ghostel--cursor-row-end-point' so `i' pressed on padding /
RPROMPT cells past typed input doesn't send arrows the shell will
silently clamp (which would desync Emacs `point' from the live
cursor).  Outside semi-char, falls through to vanilla
`evil-insert'."
  (interactive)
  (cond
   ((not (evil-ghostel--active-p))
    (call-interactively #'evil-insert))
   ((not (ghostel-point-on-cursor-row-p))
    (when-let* ((target (ghostel-input-start-point)))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))
   (t
    (let* ((row-end (evil-ghostel--cursor-row-end-point))
           (target (if row-end (min (point) row-end) (point))))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))))

(defun evil-ghostel-insert-line ()
  "Move to the start of the current input line, then enter insert state.
In semi-char, drives the shell cursor to `ghostel-input-start-point'
via arrow keys — analogous to vterm's `vterm-goto-char' shape, and
deterministic regardless of the shell's `bindkey -v' / vi-mode
configuration.  In line mode, jumps point to
`ghostel--line-input-start'.  Outside ghostel, runs vanilla
`evil-insert-line'."
  (interactive)
  (cond
   ((evil-ghostel--active-p)
    (when-let* ((target (ghostel-input-start-point)))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))
   ((evil-ghostel--line-mode-active-p)
    (goto-char (marker-position ghostel--line-input-start))
    (evil-insert-state 1))
   (t (call-interactively #'evil-insert-line))))

(defun evil-ghostel-append ()
  "Append after point, driving the shell cursor to match.
On the cursor row the target is one cell right of point, clamped
to `evil-ghostel--cursor-row-end-point' so the cursor can't advance
onto renderer padding (RPROMPT, zsh-autosuggest hint, stale glyphs).
When point sits at or past the live cursor AND the cell at the
cursor is blank/eol, the target stays at point — vim's `a' advance
would otherwise visually park on a non-input cell.  Off the cursor
row, snaps to `ghostel-input-start-point' first.  Outside semi-char,
falls through to vanilla `evil-append'."
  (interactive)
  (cond
   ((not (evil-ghostel--active-p))
    (call-interactively #'evil-append))
   ((not (ghostel-point-on-cursor-row-p))
    (when-let* ((target (ghostel-input-start-point)))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))
   (t
    (let* ((cur (ghostel-cursor-point))
           (target
            (if (and cur (>= (point) cur)
                     (save-excursion
                       (goto-char cur)
                       (or (eolp) (looking-at-p "[ \t]"))))
                (point)
              (let ((row-end (evil-ghostel--cursor-row-end-point)))
                (min (1+ (point)) (or row-end (1+ (point))))))))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))))

(defun evil-ghostel-append-line ()
  "Move to the end of the current input line, then enter insert state.
Symmetric to `evil-ghostel-insert-line': drives the shell cursor
to `evil-ghostel--cursor-row-end-point' (end of typed input on the
cursor row) via arrow keys.  Line mode jumps to
`ghostel--line-input-end'."
  (interactive)
  (cond
   ((evil-ghostel--active-p)
    (when-let* ((target (evil-ghostel--cursor-row-end-point)))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))
   ((evil-ghostel--line-mode-active-p)
    (goto-char (marker-position ghostel--line-input-end))
    (evil-insert-state 1))
   (t (call-interactively #'evil-append-line))))


;; Delete

(evil-define-operator evil-ghostel-delete
                      (beg end type register yank-handler)
                      "Delete BEG..END via the PTY (semi-char) or fall through to `evil-delete'.
The range is first clamped to the editable input region by
`evil-ghostel--clamp-to-input', so motion overshoot (e.g. `cw' walking
past end-of-input) cannot over-delete past the live cursor.

For line-type deletes on the cursor row, uses readline's Ctrl-e
Ctrl-u shortcut to clear the input area in a single round-trip.
Block-type deletes apply `evil-ghostel-delete-input-region' per block
row.  All other ranges go through `evil-ghostel-delete-input-region'.

Covers d, dd, x, X."
                      (interactive "<R><x><y>")
                      (if (not (evil-ghostel--active-p))
                          (evil-delete beg end type register yank-handler)
                        (let* ((clamped (evil-ghostel--clamp-to-input (cons beg end)))
                               (beg (car clamped))
                               (end (cdr clamped)))
                          (unless register
                            (let ((text (filter-buffer-substring beg end)))
                              (unless (string-match-p "\n" text)
                                (evil-set-register ?- text))))
                          (let ((evil-was-yanked-without-register nil))
                            (evil-yank beg end type register yank-handler))
                          (cond
                           ((eq type 'block)
                            (evil-apply-on-block #'evil-ghostel-delete-input-region beg end nil))
                           ;; Line-type on the cursor row goes through the same
                           ;; `delete-input-region' path as every other delete —
                           ;; vterm-collection's shape.  `beg' / `end' are already
                           ;; clamped to [input-start, row-end] by `clamp-to-input'
                           ;; above, so the backspace count equals the typed-input
                           ;; length; `delete-input-region' then leaves point at
                           ;; `beg' (= input-start), so a subsequent
                           ;; `evil-ghostel-insert' (for cc / S / visual-c)
                           ;; finds point already where it needs to be.
                           (t (evil-ghostel-delete-input-region beg end))))))

(evil-define-operator evil-ghostel-delete-line
  (beg end type register yank-handler)
  "Delete from point through end of line, PTY-routed in semi-char.
In visual state, the range is first expanded to a linewise range
matching vanilla `evil-delete-line'.  Otherwise routes through
`evil-ghostel-delete' with END extended to the end of the cursor's
line.

Covers D."
  :motion nil
  :keep-visual t
  (interactive "<R><x><y>")
  (if (not (evil-ghostel--active-p))
      (evil-delete-line beg end type register yank-handler)
    (let* ((beg (or beg (point)))
           (end (or end beg))
           (line-end (save-excursion (goto-char beg) (line-end-position))))
      (when (evil-visual-state-p)
        (unless (memq type '(line screen-line block))
          (let ((range (evil-expand beg end 'line)))
            (setq beg (evil-range-beginning range)
                  end (evil-range-end range)
                  type (evil-type range))))
        (evil-exit-visual-state))
      (cond
       ((eq type 'block)
        (evil-ghostel-delete beg end 'block register yank-handler))
       ((memq type '(line screen-line))
        (evil-ghostel-delete beg end type register yank-handler))
       (t
        (evil-ghostel-delete beg line-end type register yank-handler))))))

(evil-define-operator evil-ghostel-delete-char (beg end type register)
  "Delete the current character.  PTY-routed in semi-char."
  :motion evil-forward-char
  (interactive "<R><x>")
  (evil-ghostel-delete beg end type register))

(evil-define-operator evil-ghostel-delete-backward-char (beg end type register)
  "Delete the previous character.  PTY-routed in semi-char."
  :motion evil-backward-char
  (interactive "<R><x>")
  (evil-ghostel-delete beg end type register))


;; Change

(evil-define-operator evil-ghostel-change
  (beg end type register yank-handler delete-func)
  "Change BEG..END via the PTY then enter insert state.
PTY-routed in semi-char; falls through to `evil-change' otherwise.
`evil-ghostel-insert' drives the shell cursor to point itself, so
empty-range cases (e.g. C at end-of-line on a non-cursor row) need
no extra synchronization here.

Covers c, cc, s."
  (interactive "<R><x><y>")
  (if (not (evil-ghostel--active-p))
      (evil-change beg end type register yank-handler delete-func)
    (evil-ghostel-delete beg end type register yank-handler)
    (evil-ghostel-insert)))

(evil-define-operator evil-ghostel-change-line
  (beg end type register yank-handler)
  "Change from point through end of line.  PTY-routed in semi-char.

Covers C."
  :motion evil-end-of-line-or-visual-line
  (interactive "<R><x><y>")
  (if (not (evil-ghostel--active-p))
      (evil-change-line beg end type register yank-handler)
    (evil-ghostel-delete-line beg end type register yank-handler)
    (evil-ghostel-insert)))

(evil-define-operator evil-ghostel-substitute (beg end type register)
  "Substitute the next character.  Covers s."
  :motion evil-forward-char
  (interactive "<R><x>")
  (evil-ghostel-change beg end type register))

(evil-define-operator evil-ghostel-substitute-line
  (beg end register yank-handler)
  "Substitute the current line.  Covers S."
  :motion evil-line-or-visual-line
  :type line
  (interactive "<r><x>")
  (evil-ghostel-change beg end 'line register yank-handler))


;; Replace

(evil-define-operator evil-ghostel-replace (beg end type char)
  "Replace BEG..END with CHAR via the PTY.  Covers r.
Reads CHAR via the `<c>' interactive code, then issues a
delete-then-paste sequence so the replacement count matches the
deletion count (trailing whitespace stripped by
`evil-ghostel--meaningful-input-length' in multi-line ranges does not
get re-added by the paste)."
  :motion evil-forward-char
  (interactive "<R><c>")
  (if (not (evil-ghostel--active-p))
      (evil-replace beg end type char)
    (when char
      (let* ((clamped (evil-ghostel--clamp-to-input (cons beg end)))
             (b (car clamped))
             (e (cdr clamped))
             (count (evil-ghostel--meaningful-input-length
                     (buffer-substring-no-properties b e))))
        (when (> count 0)
          (evil-ghostel-replace-input-region b e (make-string count char)))))))


;; Paste

(defun evil-ghostel-paste-after (&optional count register yank-handler)
  "Paste after the cursor via bracketed paste.  Covers p.
COUNT pastes the register / kill ring entry that many times.
REGISTER selects a specific register; YANK-HANDLER is forwarded to
`evil-paste-after' in the fall-through path."
  (interactive "*P")
  (if (not (evil-ghostel--active-p))
      (evil-paste-after count register yank-handler)
    (let ((text (if register
                    (evil-get-register register)
                  (current-kill 0)))
          (n (prefix-numeric-value count)))
      (when text
        (evil-ghostel-goto-input-position (point))
        (ghostel--send-encoded "right" "")
        (dotimes (_ n)
          (ghostel--paste-text text))))))

(defun evil-ghostel-paste-before (&optional count register yank-handler)
  "Paste before the cursor via bracketed paste.  Covers P.
COUNT pastes the register / kill ring entry that many times.
REGISTER selects a specific register; YANK-HANDLER is forwarded to
`evil-paste-before' in the fall-through path."
  (interactive "*P")
  (if (not (evil-ghostel--active-p))
      (evil-paste-before count register yank-handler)
    (let ((text (if register
                    (evil-get-register register)
                  (current-kill 0)))
          (n (prefix-numeric-value count)))
      (when text
        (evil-ghostel-goto-input-position (point))
        (dotimes (_ n)
          (ghostel--paste-text text))))))


;; Undo / Redo

(defun evil-ghostel-undo (count)
  "Send Ctrl-_ (readline undo) COUNT times.  Covers u.
Falls through to `evil-undo' outside semi-char."
  (interactive "p")
  (if (not (evil-ghostel--active-p))
      (evil-undo count)
    (dotimes (_ (or count 1))
      (ghostel--send-encoded "_" "ctrl"))))

(defun evil-ghostel-redo (count)
  "Redo is not supported in the terminal.
COUNT is forwarded to `evil-redo' in the fall-through path."
  (interactive "p")
  (if (not (evil-ghostel--active-p))
      (evil-redo count)
    (message "Redo not supported in terminal")))


;; Keymap and insert-state Ctrl passthrough

(defvar evil-ghostel-mode-map (make-sparse-keymap)
  "Keymap for `evil-ghostel-mode'.
Bindings for normal/visual editing commands and insert-state Ctrl
passthrough are installed via `evil-define-key*'.")

(defconst evil-ghostel--ctrl-passthrough-keys
  '("a" "b" "d" "e" "f" "k" "l" "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "y")
  "Ctrl+key combinations to pass through to the terminal in insert state.
These keys all have standard readline/zle bindings (C-a beginning-of-line,
C-d EOF, C-e end-of-line, C-k kill-line, C-l clear-screen, etc.) that would
otherwise be intercepted by evil's insert-state commands.  Mirrors vterm's
passthrough set with one exception: `C-z' is intentionally left to evil
so `evil-emacs-state' (the default `evil-toggle-key' binding) remains
reachable as an escape hatch.")

(defun evil-ghostel--passthrough-ctrl (key)
  "Send Ctrl+KEY to the terminal PTY, or fall back to evil's binding.
Used for insert-state Ctrl keys that have readline/zle equivalents.
Outside semi-char the local map is consulted first so line mode's
own bindings (e.g. \\`C-a' → `ghostel-beginning-of-input-or-line',
\\`C-d' → `ghostel-line-mode-delete-char-or-eof') win over evil's
defaults; without that, the minor-mode aux map containing this
passthrough would shadow line mode's local-map binding."
  (if (evil-ghostel--active-p)
      (ghostel--send-encoded key "ctrl")
    (let* ((vec (kbd (concat "C-" key)))
           (local (current-local-map))
           (cmd (or (and local (lookup-key local vec))
                    (lookup-key evil-insert-state-map vec))))
      (when (commandp cmd)
        (call-interactively cmd)))))

(dolist (key evil-ghostel--ctrl-passthrough-keys)
  (let ((k key))
    (evil-define-key* 'insert evil-ghostel-mode-map
                      (kbd (concat "C-" k))
                      (defalias (intern (format "evil-ghostel--passthrough-ctrl-%s" k))
                        (lambda ()
                          (interactive)
                          (evil-ghostel--passthrough-ctrl k))
                        (format "Send C-%s to the terminal or fall back to evil." k)))))

(defun evil-ghostel--passthrough-delete ()
  "Send `<delete>' to the terminal PTY in semi-char, else fall back to evil.
Evil's insert-state map binds `<delete>' to `delete-char', which would
edit buffer text rather than forward-delete in the shell.  In line mode,
falls through to whatever the local map binds (e.g. `delete-char')."
  (interactive)
  (if (evil-ghostel--active-p)
      (ghostel--send-encoded "delete" "")
    (let* ((vec (kbd "<delete>"))
           (local (current-local-map))
           (cmd (or (and local (lookup-key local vec))
                    (lookup-key evil-insert-state-map vec))))
      (when (commandp cmd)
        (call-interactively cmd)))))

(evil-define-key* 'insert evil-ghostel-mode-map
                  (kbd "<delete>") #'evil-ghostel--passthrough-delete)

;; Editing operators and insert/append commands in normal + visual.
;;
;; Bindings use `[remap evil-FOO]' rather than literal keys so user
;; remappings of the underlying evil commands flow through to our
;; PTY-routed variants.  A user with `(define-key evil-normal-state-map
;; "x" #'some-cmd)' won't have their binding clobbered — the remap only
;; fires when evil would have dispatched to `evil-delete-char' etc.
(evil-define-key* '(normal visual) evil-ghostel-mode-map
                  [remap evil-delete]               #'evil-ghostel-delete
                  [remap evil-delete-line]          #'evil-ghostel-delete-line
                  [remap evil-delete-char]          #'evil-ghostel-delete-char
                  [remap evil-delete-backward-char] #'evil-ghostel-delete-backward-char
                  [remap evil-change]               #'evil-ghostel-change
                  [remap evil-change-line]          #'evil-ghostel-change-line
                  [remap evil-substitute]           #'evil-ghostel-substitute
                  [remap evil-change-whole-line]    #'evil-ghostel-substitute-line
                  [remap evil-replace]              #'evil-ghostel-replace
                  [remap evil-paste-after]          #'evil-ghostel-paste-after
                  [remap evil-paste-before]         #'evil-ghostel-paste-before
                  [remap evil-undo]                 #'evil-ghostel-undo
                  [remap evil-redo]                 #'evil-ghostel-redo)

;; Insert/append are normal-only (visual has its own behaviour for `i').
(evil-define-key* 'normal evil-ghostel-mode-map
                  [remap evil-insert]               #'evil-ghostel-insert
                  [remap evil-insert-line]          #'evil-ghostel-insert-line
                  [remap evil-append]               #'evil-ghostel-append
                  [remap evil-append-line]          #'evil-ghostel-append-line)

;; Motion clamps and j / G overrides are normal-only — operator-pending
;; state uses vanilla evil so motions can overshoot freely and the
;; operator's `evil-ghostel--clamp-to-input' trims the range.  Without this
;; scoping the clamp here would suppress overshoot before the operator sees it,
;; which broke `cw' in the noctuid regression that the rewrite avoided.
(evil-define-key* 'normal evil-ghostel-mode-map
                  [remap evil-forward-word-begin]   #'evil-ghostel-forward-word-begin
                  [remap evil-forward-WORD-begin]   #'evil-ghostel-forward-WORD-begin
                  [remap evil-forward-word-end]     #'evil-ghostel-forward-word-end
                  [remap evil-forward-WORD-end]     #'evil-ghostel-forward-WORD-end
                  [remap evil-forward-char]         #'evil-ghostel-forward-char
                  [remap evil-backward-char]        #'evil-ghostel-backward-char
                  [remap evil-end-of-line]          #'evil-ghostel-end-of-line
                  [remap evil-next-line]            #'evil-ghostel-next-line
                  [remap evil-goto-line]            #'evil-ghostel-goto-cursor
                  "[["                              #'ghostel-previous-prompt
                  "]]"                              #'ghostel-next-prompt)

;; Motions also reachable in operator-pending so `d0' / `d^' work.
(evil-define-key* '(normal visual operator motion) evil-ghostel-mode-map
                  [remap evil-beginning-of-line]    #'evil-ghostel-beginning-of-line
                  [remap evil-first-non-blank]      #'evil-ghostel-first-non-blank)


;; ESC routing: terminal vs evil

(defvar-local evil-ghostel--escape-mode nil
  "Buffer-local override for ESC routing.
Initialized from `evil-ghostel-escape' when the minor mode turns on.
Valid values: `auto', `terminal', `evil'.")

(defconst evil-ghostel--escape-modes '(auto terminal evil)
  "Cycle order for `evil-ghostel-toggle-send-escape'.")

(defun evil-ghostel--escape ()
  "Dispatch insert-state ESC based on `evil-ghostel--escape-mode'.
Terminal-bound ESC is snapped to the live viewport like every other
typed key in `ghostel-mode-map'.  When falling back to evil and the
user's `evil-insert-state-map' binding is missing or a chord prefix
\(e.g. `evil-escape''s `jk'), use `evil-force-normal-state' so the
keystroke is never silently dropped."
  (interactive)
  (let* ((mode evil-ghostel--escape-mode)
         (to-terminal (or (eq mode 'terminal)
                          (and (eq mode 'auto)
                               ghostel--term
                               (ghostel--mode-enabled ghostel--term 1049)))))
    (if to-terminal
        (progn
          (ghostel--snap-to-input)
          (ghostel--send-encoded "escape" ""))
      (let ((cmd (lookup-key evil-insert-state-map (kbd "<escape>"))))
        (call-interactively (if (commandp cmd) cmd #'evil-force-normal-state))))))

(defun evil-ghostel-toggle-send-escape (&optional arg)
  "Cycle or set the ESC routing mode for the current buffer.
Without ARG, cycle through `auto' → `terminal' → `evil' → `auto'.
With numeric prefix 1, set to `auto'; 2 to `terminal'; 3 to `evil'.
Other numeric prefixes signal a `user-error'.

The mode is buffer-local; see `evil-ghostel-escape' for the default."
  (interactive "P")
  (let ((target
         (if arg
             (let ((n (prefix-numeric-value arg)))
               (or (nth (1- n) evil-ghostel--escape-modes)
                   (user-error
                    "Invalid prefix %d; use 1 (auto), 2 (terminal), or 3 (evil)"
                    n)))
           (let ((next (cdr (memq evil-ghostel--escape-mode
                                  evil-ghostel--escape-modes))))
             (or (car next) (car evil-ghostel--escape-modes))))))
    (setq evil-ghostel--escape-mode target)
    (message "evil-ghostel ESC mode: %s" target)))

(evil-define-key* 'insert evil-ghostel-mode-map
                  (kbd "<escape>") #'evil-ghostel--escape)


;; Minor mode

(defun evil-ghostel--any-active-elsewhere-p (except-buffer)
  "Return non-nil if any buffer other than EXCEPT-BUFFER has the mode on.
Used to decide whether the global advice on `ghostel--redraw' and
`ghostel--set-cursor-style' can be removed when EXCEPT-BUFFER
disables `evil-ghostel-mode'."
  (catch 'found
    (dolist (b (buffer-list))
      (when (and (not (eq b except-buffer))
                 (buffer-local-value 'evil-ghostel-mode b))
        (throw 'found t)))))

;;;###autoload
(define-minor-mode evil-ghostel-mode
  "Minor mode for evil integration in ghostel terminal buffers.
Binds `evil-ghostel-*' operators / motions / commands in `evil-ghostel-mode-map'
and syncs the terminal cursor with Emacs point during evil state transitions.

The mode advises two global functions, `ghostel--redraw' and
`ghostel--set-cursor-style', to preserve point and override the
cursor style for evil state.  Because advice is global but the
mode is buffer-local, the advice is installed on first enable
and removed only when the *last* `evil-ghostel-mode' buffer
disables — otherwise toggling the mode off in one buffer would
silently strip the wrapper from every other ghostel buffer."
  :lighter nil
  :keymap evil-ghostel-mode-map
  (if evil-ghostel-mode
      (progn
        (setq evil-ghostel--escape-mode evil-ghostel-escape)
        (evil-ghostel--escape-stay)
        (add-hook 'evil-insert-state-entry-hook
                  #'evil-ghostel--insert-state-entry nil t)
        ;; Reuse the insert-state sync when entering emacs-state — both
        ;; states expect point to follow the terminal cursor.
        (add-hook 'evil-emacs-state-entry-hook
                  #'evil-ghostel--insert-state-entry nil t)
        ;; `advice-add' is idempotent on (symbol, fn) pairs, so calling
        ;; it on every enable is safe and avoids a separate install flag.
        (advice-add 'ghostel--redraw :around #'evil-ghostel--around-redraw)
        (advice-add 'ghostel--set-cursor-style :around
                    #'evil-ghostel--override-cursor-style)
        (evil-refresh-cursor))
    (remove-hook 'evil-insert-state-entry-hook
                 #'evil-ghostel--insert-state-entry t)
    (remove-hook 'evil-emacs-state-entry-hook
                 #'evil-ghostel--insert-state-entry t)
    (unless (evil-ghostel--any-active-elsewhere-p (current-buffer))
      (advice-remove 'ghostel--redraw #'evil-ghostel--around-redraw)
      (advice-remove 'ghostel--set-cursor-style
                     #'evil-ghostel--override-cursor-style))))

(provide 'evil-ghostel)
;;; evil-ghostel.el ends here
