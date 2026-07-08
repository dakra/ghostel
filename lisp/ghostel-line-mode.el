;;; ghostel-line-mode.el --- Line mode for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Line mode for ghostel: edit the current shell input line locally with
;; ordinary Emacs editing commands, then send it to the shell on RET.
;; Split out of ghostel.el and loaded from there via `require'.
;;
;; The mode keymap's parent (`ghostel-mode-map') is wired at runtime in
;; ghostel.el (see the `set-keymap-parent' call there), so this file has no
;; load-time dependency on core ghostel values and can be required early.

;;; Code:

(require 'comint)
(require 'compat)

(declare-function ghostel--cursor-blink-stop "ghostel")
(declare-function ghostel--ensure-ghostel-buffer "ghostel")
(declare-function ghostel--invalidate "ghostel")
(declare-function ghostel--leave-readonly-state "ghostel")
(declare-function ghostel--mode-enabled "ghostel-module")
(declare-function ghostel--mode-line-refresh "ghostel")
(declare-function ghostel--mode-line-tag-make "ghostel")
(declare-function ghostel--open-link "ghostel")
(declare-function ghostel--redraw "ghostel-module" (term &optional full))
(declare-function ghostel--regex-prompt-end "ghostel")
(declare-function ghostel--send-encoded "ghostel")
(declare-function ghostel--uri-at-pos "ghostel")
(declare-function ghostel--write-pty "ghostel-module")
(declare-function ghostel-beginning-of-input-or-line "ghostel")
(declare-function ghostel-input-start-point "ghostel")
(declare-function bash-completion-capf-nonexclusive "bash-completion")
(declare-function bash-completion-require-process "bash-completion")

(defvar ghostel--char-mode-override-active)
(defvar ghostel--cursor-char-pos)
(defvar ghostel--input-mode)
(defvar ghostel--mode-line-tag)
(defvar ghostel--term)
(defvar ghostel-semi-char-mode-map)


;;; Customization

(defcustom ghostel-line-mode-history-size 200
  "Maximum number of lines kept in `ghostel--line-mode-history'."
  :type 'integer
  :group 'ghostel)

(defcustom ghostel-line-mode-completion-at-point-functions
  '(comint-completion-at-point)
  "Capfs activated for \\=`TAB\\=' in `ghostel-line-mode'.
Each function is called inside a `save-restriction' narrowed to the
editable input region, so it sees only the user's typed text — not
the prompt or the surrounding scrollback.

The default `comint-completion-at-point' dispatches through
`comint-dynamic-complete-functions' (set up via
`shell-completion-vars'), which gives filename completion, env-var
completion, command completion from \\=`PATH\\=', `pcomplete'
integration, and history expansion."
  :type '(repeat function)
  :group 'ghostel)

(defcustom ghostel-line-mode-use-bash-completion 'auto
  "Whether to layer bash programmable completion onto line-mode \\=`TAB\\='.
When non-nil, `bash-completion-capf-nonexclusive' is prepended to
`ghostel-line-mode-completion-at-point-functions' at completion
time.  The capf is non-exclusive, so when bash returns no
candidates the standard comint stack still runs.

- `auto' (default): enable when the `bash-completion' package
  loads cleanly; do nothing when it isn't installed.
- t: require it; signal an error if it is missing.
- nil: never use it.

The bash-completion package spawns a hidden bash subprocess that
sources the user's startup files, so registrations like
\"complete -F _git git\" become available — TAB after \"git
checkout \" lists branch names, etc."
  :type '(choice (const :tag "Auto-detect" auto)
                 (const :tag "Always (require)" t)
                 (const :tag "Never" nil))
  :group 'ghostel)

(defcustom ghostel-line-mode-bash-completion-prespawn nil
  "When non-nil, eagerly start the bash-completion subprocess on line-mode entry.
Off by default — the first \\=`TAB\\=' inside line mode pays the
~500ms-1s cost of spawning the hidden bash process and sourcing
the user's startup files; subsequent completions are fast.  Set
this to t to amortise that cost at line-mode entry time so the
first completion feels instant.

Has no effect when `ghostel-line-mode-use-bash-completion' is nil
or when the `bash-completion' package is not installed."
  :type 'boolean
  :group 'ghostel)


;;; Internal state

(defvar-local ghostel--line-mode-paused nil
  "Sentinel plist marking line mode as paused, awaiting alt-screen exit.
Nil when not paused.  Set by `ghostel--line-mode-pause' (auto-pause
when an alt-screen TUI starts) and by `ghostel--line-mode-defer-entry'
\(when the user invokes `ghostel-line-mode' while a TUI is already
running); consumed by `ghostel--line-mode-try-resume' once alt-screen
has gone off and a prompt is locatable.  Cleared when the user
manually switches input modes so a later alt-screen exit does not
surprise them by force-resuming line mode.")

(defvar-local ghostel--line-input-start nil
  "Marker pointing at the start of the user's in-progress input line.
Nil when line mode is not active.  Text between this marker and
`ghostel--line-input-end' is the editable input line.")

(defvar-local ghostel--line-input-end nil
  "Marker pointing right after the last character of the in-progress input.
Has insertion-type t so a self-insert at this position causes the
marker to advance with the new character.  Bounding the input by an
explicit marker (rather than `point-max') keeps content past the
prompt — e.g. a status bar drawn below the prompt row — out of the
snapshot read and out of the renderer's clobber path.")

(defvar-local ghostel--line-mode-history nil
  "History ring of inputs submitted via `ghostel-line-mode-send'.
Most recent first.")

(defvar-local ghostel--line-mode-history-index nil
  "Current index into `ghostel--line-mode-history' while browsing history.
Nil when not browsing.")

(defvar-local ghostel--line-mode-saved-cursor-type nil
  "Saved `cursor-type' from before line mode entry, as a singleton list.
A list (VALUE) when saved, nil when not — distinguishes \"not
saved\" from \"saved nil\" (the value the terminal asks for after
a CSI ?25l).  Line mode forces `cursor-type' to the editor's
default so point stays visible while the user navigates and
edits, and `ghostel--line-mode-teardown' restores VALUE so any
terminal-driven cursor visibility resumes on exit.")

(defvar-local ghostel--line-mode-adopted-count nil
  "Characters of pre-existing input the shell's readline still holds.
Set on line-mode entry to the length of input adopted from the
renderer (chars typed via the PTY in a previous mode).  Cleared to
0 by `ghostel--line-mode-clear-shell-readline' after sending that
many backspaces to erase them — keeps a subsequent send from
duplicating the prefix when the shell echoes our line back.")

(defvar-local ghostel--line-mode-on-alt-screen nil
  "Non-nil when line mode was entered deliberately on the alt screen.
Set by `ghostel--line-mode-enter'; tells `ghostel--line-mode-pre-redraw'
not to auto-pause line mode merely because the alt screen is up.
Cleared by `ghostel--line-mode-teardown'.")

(defvar-local ghostel--pending-initial-line-mode nil
  "Non-nil to enter line mode at the first prompt of a fresh terminal.
Armed by `ghostel--apply-initial-input-mode' when
`ghostel-initial-input-mode' is `line'; consumed by
`ghostel--line-mode-maybe-enter-initial' once a prompt renders.")


;;; Keymap and commands

(defvar-keymap ghostel-line-mode-map
  :doc "Keymap for `ghostel-line-mode'.
Editing commands work on the input region;
\\<ghostel-line-mode-map>\\[ghostel-line-mode-send-or-open-link]
sends the whole line to the shell at once, or follows the link at
point when one is there.  \\[ghostel-line-mode-newline] inserts a
literal newline in the input for multi-line prompts."
  "RET"        #'ghostel-line-mode-send-or-open-link
  "<return>"   #'ghostel-line-mode-send-or-open-link
  ;; Shift-Enter inserts a literal newline in the input
  "S-RET"      #'ghostel-line-mode-newline
  "S-<return>" #'ghostel-line-mode-newline
  "C-c C-c"    #'ghostel-line-mode-interrupt
  "C-d"        #'ghostel-line-mode-delete-char-or-eof
  "M-p"        #'ghostel-line-mode-history-previous
  "M-n"        #'ghostel-line-mode-history-next
  "C-a"        #'ghostel-beginning-of-input-or-line
  "TAB"        #'ghostel-line-mode-complete-at-point
  "<tab>"      #'ghostel-line-mode-complete-at-point
  "<remap> <self-insert-command>" #'ghostel-line-mode-self-insert)

(defun ghostel-line-mode-send-or-open-link ()
  "Follow the link at point, or send the current line-mode input."
  (interactive)
  (let ((url (ghostel--uri-at-pos (point))))
    (if url
        (ghostel--open-link url)
      (ghostel-line-mode-send))))

(defun ghostel-line-mode-self-insert (&optional n)
  "Self-insert N times, snapping point back to the input region first.
When point is in read-only scrollback, insert at the end of the
in-progress input instead.  The prefix argument N is forwarded to
`self-insert-command' so \\[universal-argument] works as expected."
  (interactive "p")
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end   (and (markerp ghostel--line-input-end)
                    (marker-position ghostel--line-input-end))))
    (when (and start end (or (< (point) start) (> (point) end)))
      (deactivate-mark)
      (goto-char end)))
  (self-insert-command (or n 1)))

(defun ghostel-line-mode-newline ()
  "Insert a literal newline in the line-mode input region.
Discoverable shortcut for `\\[quoted-insert]' followed by a newline: lets
you compose multi-line prompts in apps that distinguish submit (Enter)
from newline (Shift-Enter).  The newline goes through to the running app
verbatim when `ghostel-line-mode-send' ships the input.

Snaps point to the end of the input region first when point is in the
read-only scrollback portion, mirroring `ghostel-line-mode-self-insert'."
  (interactive)
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end   (and (markerp ghostel--line-input-end)
                    (marker-position ghostel--line-input-end))))
    (when (and start end (or (< (point) start) (> (point) end)))
      (deactivate-mark)
      (goto-char end)))
  (insert "\n"))

(defun ghostel--line-mode-alt-screen-p ()
  "Return non-nil if libghostty is on its alternate screen.
Checks DEC private modes 1049 and 1047 (the modern alt-screen
modes used by less, htop, vim, etc.)."
  (and ghostel--term
       (or (ghostel--mode-enabled ghostel--term 1049)
           (ghostel--mode-enabled ghostel--term 1047))))

(defun ghostel--line-mode-prompt-on-screen-p ()
  "Return non-nil when a real OSC 133 prompt char sits on the cursor's row.
Only a `ghostel-prompt' property counts (no regex or cursor fallback),
so line mode can tell an inner shell prompt reached via tmux/screen passthrough
from a raw fullscreen TUI when deciding whether to enter on the alt screen."
  (when-let* ((cursor ghostel--cursor-char-pos)
              (bol (save-excursion (goto-char cursor)
                                   (line-beginning-position))))
    (and (text-property-not-all bol cursor 'ghostel-prompt nil) t)))

(defun ghostel--line-mode-apply-readonly (marker-pos)
  "Mark `[point-min, MARKER-POS)' read-only with the rear-nonsticky trick.
The non-sticky flag lands on the last protected character so
insertion at MARKER-POS itself stays legal while edits inside the
region still signal `text-read-only'.  Setting `rear-nonsticky' to
t also stops typed input from inheriting the prompt char's `face'
\(and any other rendered-style properties libghostty painted on
it) — without this, text typed after a colored prompt picks up
the prompt's color until RET."
  (let ((inhibit-read-only t))
    (put-text-property (point-min) marker-pos 'read-only t)
    (when (> marker-pos (point-min))
      (put-text-property (1- marker-pos) marker-pos
                         'rear-nonsticky t))))

(defun ghostel--line-mode-input-end-pos (start)
  "Return the position right after the contiguous `ghostel-input' span at START.
Returns START itself when there is no `ghostel-input' span there —
the common case at a fresh prompt where libghostty has not seen
any input bytes yet, so the renderer hasn't painted the property."
  (if (get-text-property start 'ghostel-input)
      (or (next-single-property-change start 'ghostel-input nil (point-max))
          (point-max))
    start))

(defun ghostel--line-mode-trim-trailing-blank (start)
  "Delete `[START, point-max)' if the region is pure whitespace.
Used in line-mode entry/restore to scrub the renderer's trailing
blank rows past the input region while leaving any non-blank
content (a status bar drawn below the prompt, a multi-line UI from
the shell, etc.) intact."
  (when (string-match-p "\\`[[:space:]]*\\'"
                        (buffer-substring-no-properties start (point-max)))
    (let ((inhibit-read-only t))
      (delete-region start (point-max)))))

(defun ghostel--line-mode-snapshot ()
  "Capture in-progress input plus point/mark offsets and clear the input region.
Returns a plist (:input STR :point-offset N-or-nil :mark-offset N-or-nil)
suitable for `ghostel--line-mode-restore', or nil when there is no
live input marker.  The input region is bounded by
`ghostel--line-input-start' and `ghostel--line-input-end' (not
`point-max') so any content drawn past the input — e.g. a status
bar below the prompt — stays untouched."
  (let ((start-pos (and (markerp ghostel--line-input-start)
                        (marker-position ghostel--line-input-start)))
        (end-pos (and (markerp ghostel--line-input-end)
                      (marker-position ghostel--line-input-end))))
    (when (and start-pos end-pos)
      (let* ((point-offset (and (>= (point) start-pos)
                                (<= (point) end-pos)
                                (- (point) start-pos)))
             (mark-pos (and mark-active (mark)))
             (mark-offset (and mark-pos
                               (>= mark-pos start-pos)
                               (<= mark-pos end-pos)
                               (- mark-pos start-pos)))
             (input (buffer-substring-no-properties start-pos end-pos)))
        ;; Disarm undo for the rest of the redraw pass: this delete, the
        ;; native redraw, and the re-insert in `ghostel--line-mode-restore'
        ;; are renderer bookkeeping, not user edits.  `restore' re-arms.
        (setq buffer-undo-list t)
        (let ((inhibit-read-only t))
          (delete-region start-pos end-pos))
        (list :input input
              :point-offset point-offset
              :mark-offset mark-offset)))))

(defun ghostel--line-mode-restore (snapshot)
  "Re-insert SNAPSHOT'd input after the new prompt and restore point/mark.
Returns non-nil on success.  Returns nil when the prompt cannot be
located (shell integration dropped out, or the prompt scrolled off
because of async output during composition); callers fall back to
forwarding the pending input raw.

Trims pure-whitespace tails past the input but preserves any
non-blank content the renderer wrote past the prompt row (e.g. a
status bar)."
  (when snapshot
    (let ((prompt-end (ghostel-input-start-point)))
      (when prompt-end
        ;; Keep the re-insert out of the undo list.
        (let ((inhibit-read-only t)
              (buffer-undo-list t)
              (input (plist-get snapshot :input)))
          (ghostel--line-mode-trim-trailing-blank prompt-end)
          (when (markerp ghostel--line-input-start)
            (set-marker ghostel--line-input-start nil))
          (when (markerp ghostel--line-input-end)
            (set-marker ghostel--line-input-end nil))
          (setq ghostel--line-input-start (copy-marker prompt-end nil))
          (set-marker-insertion-type ghostel--line-input-start nil)
          (setq ghostel--line-input-end (copy-marker prompt-end t))
          (set-marker-insertion-type ghostel--line-input-end t)
          (when (and input (> (length input) 0))
            (goto-char (marker-position ghostel--line-input-start))
            ;; Insertion advances `ghostel--line-input-end' (insertion
            ;; type t) so end-marker tracks the tail of the input.
            (insert input))
          (let ((start-pos (marker-position ghostel--line-input-start))
                (end-pos (marker-position ghostel--line-input-end)))
            (ghostel--line-mode-apply-readonly start-pos)
            ;; Mark the line-mode input region with `ghostel-input' so
            ;; `ghostel--detect-urls-skip-p' skips it on the cursor's
            ;; line — without this, a path the user typed locally
            ;; (e.g. `cd src/main.rs') would get linkified and RET
            ;; would open the file instead of running
            ;; `ghostel-line-mode-send'.
            (when (< start-pos end-pos)
              (put-text-property start-pos end-pos 'ghostel-input t))
            (let ((po (plist-get snapshot :point-offset))
                  (mo (plist-get snapshot :mark-offset)))
              (when po
                (goto-char (+ start-pos po)))
              (when mo
                (set-mark (+ start-pos mo))))))
        ;; Re-arm an empty history at the input's new location; the old
        ;; positions are stale now the redraw has moved it.
        (setq buffer-undo-list nil)
        t))))

(defun ghostel--line-mode-enter ()
  "Set up line mode in the current buffer.
Internal helper used by the interactive `ghostel-line-mode' entry
path and the auto-resume path in
`ghostel--line-mode-try-resume'.  Returns t on success, nil when
the prompt cannot be located (no cursor and no OSC 133 marker —
e.g. the prompt has not been redrawn yet after an alt-screen
exit).  Caller decides whether \"no prompt\" is a user-error or a
deferred retry.

Assumes `ghostel--term' is non-nil and the buffer is not already
in line mode (the interactive entry validates these)."
  (let ((prompt-end (ghostel-input-start-point))
        (was-frozen (eq ghostel--input-mode 'copy)))
    (when prompt-end
      (pcase ghostel--input-mode
        ('copy  (ghostel--leave-readonly-state))
        ('emacs (ghostel--leave-readonly-state)))
      ;; Line mode is the one user-editable ghostel state.  The rendered
      ;; scrollback is still protected below with read-only text properties.
      (setq buffer-read-only nil)
      ;; Copy mode froze the redraw timer; line mode is live, so the
      ;; timer must be running again before we exit this function or
      ;; the prompt sits there with no scheduled redraw until the next
      ;; PTY byte arrives.  `ghostel--invalidate' is idempotent, so the
      ;; emacs/semi-char paths (timer already live) are unaffected.
      (when (and was-frozen ghostel--term)
        (ghostel--invalidate))
      ;; Save `cursor-type' and force the editor's default for the
      ;; duration of line mode.  The user moves point freely here, so
      ;; the cursor must be visible regardless of any CSI ?25l the
      ;; running terminal app issued in semi-char/char mode.
      ;; `ghostel--apply-cursor-style' is a no-op in line mode, so
      ;; further terminal requests are ignored until teardown.
      (ghostel--cursor-blink-stop)
      (setq ghostel--line-mode-saved-cursor-type (list cursor-type))
      (setq cursor-type (default-value 'cursor-type))
      ;; If the user already typed something at this prompt via the
      ;; PTY (e.g. before switching from semi-char to line mode), the
      ;; renderer painted those cells with `ghostel-input'.  Adopt
      ;; the span as the initial line-mode input so the user does not
      ;; lose their typing.
      (let ((input-end (ghostel--line-mode-input-end-pos prompt-end)))
        ;; Trim only PURE-whitespace tails past the input.  Status
        ;; bars / multi-line UI drawn below the prompt row stay put.
        (ghostel--line-mode-trim-trailing-blank input-end)
        (setq ghostel--line-input-start (copy-marker prompt-end nil))
        (set-marker-insertion-type ghostel--line-input-start nil)
        (setq ghostel--line-input-end (copy-marker input-end t))
        (set-marker-insertion-type ghostel--line-input-end t)
        ;; Remember how many chars the shell's readline currently
        ;; holds for us — we'll erase them via backspaces before the
        ;; next PTY write so the shell doesn't append our line to its
        ;; existing input and echo a duplicated prefix.
        (setq ghostel--line-mode-adopted-count (- input-end prompt-end)))
      (setq ghostel--line-mode-history-index nil)
      (setq ghostel--char-mode-override-active nil)
      ;; A deliberate alt-screen entry must survive the next redraw's
      ;; auto-pause, and supersedes any armed sentinel.
      (setq ghostel--line-mode-on-alt-screen (ghostel--line-mode-alt-screen-p))
      (setq ghostel--line-mode-paused nil)
      (setq ghostel--input-mode 'line)
      (use-local-map ghostel-line-mode-map)
      (setq ghostel--mode-line-tag (ghostel--mode-line-tag-make 'line ":Line"))
      (ghostel--mode-line-refresh)
      ;; Protect everything before the input marker with a read-only
      ;; text property so commands that would modify the buffer
      ;; (self-insert, delete-char, yank, …) signal `text-read-only'
      ;; when point is in the scrollback / previous output region.
      ;; The redraw path binds `inhibit-read-only' so it is
      ;; unaffected.
      (ghostel--line-mode-apply-readonly
       (marker-position ghostel--line-input-start))
      ;; Make sure the adopted input carries `ghostel-input' (the
      ;; renderer should have applied it for PTY-typed cells; reapply
      ;; for consistency, and so URL detection skips the region even
      ;; if the property was missed for some cells).
      (let ((start-pos (marker-position ghostel--line-input-start))
            (end-pos (marker-position ghostel--line-input-end)))
        (when (< start-pos end-pos)
          (let ((inhibit-read-only t))
            (put-text-property start-pos end-pos 'ghostel-input t))))
      ;; Place point at end of (any adopted) input so the user
      ;; continues typing where the shell left them.
      (goto-char (marker-position ghostel--line-input-end))
      ;; Arm undo recording now that the entry plumbing is done, so the
      ;; user's first edit is the first thing recorded.
      (setq buffer-undo-list nil)
      (ghostel--line-mode-maybe-prespawn-bash-completion)
      t)))

(defun ghostel-line-mode (&optional force)
  "Switch to line mode — edit input locally, send to shell on RET.
The user types into an editable region between the last prompt and
`point-max'.  Full Emacs editing (yank, `kill-word', transpose,
etc.) works.  Pressing \\[ghostel-line-mode-send] sends the input
to the shell in one write.

Completion runs against the editable input and follows OSC 7 / TRAMP
directory tracking.  The terminal stays live while output streams
around the prompt.  After RET, line mode stays active for the next
prompt.

On the alt screen, line mode enters at a shell prompt whose OSC 133
markers reach Ghostel; over a raw TUI (vim, less) it arms and resumes
when the TUI exits.  A prefix arg FORCE forces immediate entry."
  (interactive "P")
  (ghostel--ensure-ghostel-buffer)
  (unless ghostel--term
    (user-error "No terminal in this buffer"))
  (cond
   ((eq ghostel--input-mode 'line))     ; already in line mode
   ;; Forced: trust the user, bypass the alt-screen gate.
   (force
    (if (ghostel--line-mode-enter)
        (message "Line mode: RET sends the whole line; C-c C-j to exit")
      (user-error "Line mode could not locate the cursor or a prompt")))
   ;; Alt screen with a real prompt on the cursor row (inner shell) — enter.
   ((and (ghostel--line-mode-alt-screen-p)
         (ghostel--line-mode-prompt-on-screen-p)
         (ghostel--line-mode-enter))
    (message "Line mode: RET sends the whole line; C-c C-j to exit"))
   ;; Alt screen, no detectable prompt (raw TUI) — arm instead.
   ((ghostel--line-mode-alt-screen-p)
    (ghostel--line-mode-defer-entry))
   ;; Primary screen — normal entry.
   ((ghostel--line-mode-enter)
    (message "Line mode: RET sends the whole line; C-c C-j to exit"))
   (t
    (user-error "Line mode could not locate the cursor or a prompt"))))

(defun ghostel--line-mode-input-text ()
  "Return the current in-progress input text, or an empty string.
Bounded by the start and end markers, not `point-max', so content
past the input region (status bar, etc.) is never read."
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end (and (markerp ghostel--line-input-end)
                  (marker-position ghostel--line-input-end))))
    (if (and start end (< start end))
        (buffer-substring-no-properties start end)
      "")))

(defun ghostel--line-mode-delete-input ()
  "Delete the current in-progress input from the buffer.
Removes only the region between the start and end markers; content
past the end marker (status bar, etc.) stays put."
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end (and (markerp ghostel--line-input-end)
                  (marker-position ghostel--line-input-end))))
    (when (and start end (< start end))
      (let ((inhibit-read-only t))
        (delete-region start end)))))

(defun ghostel--line-mode-clear-shell-readline ()
  "Erase the adopted prefix from the shell's readline buffer.
On line-mode entry we adopt any pre-existing input (chars the user
already typed via the PTY) into the editable buffer, but the shell
still holds those bytes in its own line-discipline / readline
buffer.  Before our next write to the PTY, send that many
backspaces so the upcoming line lands on an empty prompt — without
this the shell concatenates and echoes a duplicated line.

Backspaces work under any cooked-mode line discipline (bash, fish,
zsh, vi-mode readline, python REPL); a readline-only kill like
`C-u' would not.  Resets `ghostel--line-mode-adopted-count' to 0."
  (when (and ghostel--line-mode-adopted-count
             (> ghostel--line-mode-adopted-count 0))
    (dotimes (_ ghostel--line-mode-adopted-count)
      (ghostel--send-encoded "backspace" "")))
  (setq ghostel--line-mode-adopted-count 0))

(defun ghostel--line-mode-teardown (&optional pause)
  "Clean up line-mode state and hand any pending input back to the shell.
Any in-progress input is forwarded to the PTY raw (no newline) so
the user can continue editing it at the shell's own prompt after
the mode switch instead of losing what they typed.  Callers that
have already handled the input themselves (like
`ghostel-line-mode-send' and `ghostel-line-mode-interrupt') delete
it from the buffer before calling this, so no double-send happens.

Forces a final redraw so the buffer truncation done at entry is
re-materialized from libghostty.

When PAUSE is non-nil, skip forwarding pending input to the PTY,
skip the readline-clearing backspaces (the alt-screen TUI would receive them),
and skip the trailing redraw; used by `ghostel--line-mode-pause',
which discards any type-ahead and runs inside `ghostel--redraw-now'."
  ;; Undo is off outside line mode; disable it before the teardown edits
  ;; below so none of them are recorded.
  (setq buffer-undo-list t)
  (unless pause
    (let ((input (ghostel--line-mode-input-text)))
      ;; Erase the adopted prefix from the shell's readline before
      ;; handing back our (possibly edited) version, so the shell ends
      ;; up holding exactly INPUT instead of "<adopted>INPUT".
      (ghostel--line-mode-clear-shell-readline)
      (when (> (length input) 0)
        (ghostel--write-pty ghostel--term input))))
  (ghostel--line-mode-delete-input)
  ;; Drop the `read-only' and `rear-nonsticky' properties that
  ;; protected the scrollback region during line mode; after this teardown
  ;; the whole ghostel buffer returns to the default renderer-owned lock.
  (let ((inhibit-read-only t))
    (remove-text-properties (point-min) (point-max)
                            '(read-only nil rear-nonsticky nil)))
  (setq buffer-read-only t)
  (when (markerp ghostel--line-input-start)
    (set-marker ghostel--line-input-start nil))
  (when (markerp ghostel--line-input-end)
    (set-marker ghostel--line-input-end nil))
  (setq ghostel--line-input-start nil)
  (setq ghostel--line-input-end nil)
  (setq ghostel--line-mode-history-index nil)
  (setq ghostel--line-mode-adopted-count nil)
  (setq ghostel--line-mode-on-alt-screen nil)
  (when ghostel--line-mode-saved-cursor-type
    (setq cursor-type (car ghostel--line-mode-saved-cursor-type))
    (setq ghostel--line-mode-saved-cursor-type nil))
  (unless pause
    (when ghostel--term
      (let ((inhibit-read-only t))
        (ghostel--redraw ghostel--term t)))))

(defun ghostel--line-mode-pause ()
  "Drop line mode to semi-char while a full-screen app holds the alt screen.
Called by `ghostel--line-mode-pre-redraw' on a 1049/1047 transition into
the alt screen.  Arms `ghostel--line-mode-paused' so the alt-screen-off cycle
re-enters line mode at the new prompt."
  (ghostel--line-mode-teardown 'pause)
  (setq ghostel--char-mode-override-active nil)
  (setq ghostel--input-mode 'semi-char)
  (use-local-map ghostel-semi-char-mode-map)
  (setq ghostel--mode-line-tag nil)
  (ghostel--mode-line-refresh)
  (setq ghostel--line-mode-paused
        (list :input "" :point-offset nil :mark-offset nil))
  (message "Line mode paused; resumes when the TUI exits (%s to force now)"
           (substitute-command-keys
            "\\<ghostel-mode-map>\\[universal-argument] \\[ghostel-line-mode]")))

(defun ghostel--line-mode-try-resume ()
  "Re-enter line mode and restore the paused snapshot, if possible.
Called by `ghostel--line-mode-post-redraw' on a 1049/1047 exit.
If `ghostel-input-start-point' cannot locate a prompt
yet (the renderer has not painted the post-TUI buffer yet), the
paused snapshot is left in place so the next redraw can retry."
  (when (ghostel-input-start-point)
    (let ((snapshot ghostel--line-mode-paused))
      (setq ghostel--line-mode-paused nil)
      (when (ghostel--line-mode-enter)
        (ghostel--line-mode-restore snapshot)
        t))))

(defun ghostel--line-mode-defer-entry ()
  "Arm auto-pause so line mode activates when the alt-screen TUI exits.
Called by interactive `ghostel-line-mode' when an alt-screen TUI is
already running.  Stashes an empty snapshot so the alt-screen-off
transition picks it up and enters line mode for real.  Preserves
any existing paused snapshot (the user re-arming should not clobber
input captured by an earlier auto-pause)."
  (unless ghostel--line-mode-paused
    (setq ghostel--line-mode-paused
          (list :input "" :point-offset nil :mark-offset nil)))
  (message "Line mode armed; will activate when the TUI exits (%s to force now)"
           (substitute-command-keys
            "\\<ghostel-mode-map>\\[universal-argument] \\[ghostel-line-mode]")))

(defun ghostel--line-mode-pre-redraw ()
  "Pause line mode when the alt screen comes up under it.
Runs atop `ghostel--redraw-now' before the renderer paints, so line
mode tears down before libghostty's grid (which lacks the input)
overwrites the buffer.  A deliberate alt-screen entry
\(`ghostel--line-mode-on-alt-screen') is exempt; the flag clears
once the alt screen goes away so a later TUI pauses normally."
  (when (eq ghostel--input-mode 'line)
    (if (ghostel--line-mode-alt-screen-p)
        (unless ghostel--line-mode-on-alt-screen
          (ghostel--line-mode-pause))
      ;; Back on the primary screen — re-arm the pause for the next TUI.
      (setq ghostel--line-mode-on-alt-screen nil))))

(defun ghostel--line-mode-post-redraw ()
  "Resume line mode if alt-screen is off and a paused snapshot is armed.
Runs at the bottom of `ghostel--redraw-now' (after the renderer
paints) so `ghostel-input-start-point' sees the
post-TUI buffer state.  Re-attempts every redraw cycle until a
prompt is locatable — covers the case where the shell prints its
new prompt one or more redraws after libghostty leaves the alt
screen.  Also drives the deferred startup entry when
`ghostel-initial-input-mode' is `line'."
  (when (and ghostel--line-mode-paused
             (not (ghostel--line-mode-alt-screen-p)))
    (ghostel--line-mode-try-resume))
  (ghostel--line-mode-maybe-enter-initial))

(defun ghostel--line-mode-startup-prompt-ready-p ()
  "Non-nil when the cursor row shows a real prompt (OSC 133 prop or regex).
Gates the deferred startup entry so line mode skips a blank pre-prompt screen.
Unlike `ghostel-input-start-point', the bare cursor does not count as a prompt."
  (when-let* ((cursor-pos ghostel--cursor-char-pos))
    (save-excursion
      (goto-char cursor-pos)
      (let ((row-start (line-beginning-position))
            (pos cursor-pos))
        (while (and (> pos row-start)
                    (not (get-text-property (1- pos) 'ghostel-prompt)))
          (setq pos (1- pos)))
        (or (and (> pos row-start)
                 (get-text-property (1- pos) 'ghostel-prompt))
            (ghostel--regex-prompt-end cursor-pos))))))

(defun ghostel--line-mode-maybe-enter-initial ()
  "Enter line mode once the first prompt renders, if armed at startup.
Armed by `ghostel-initial-input-mode' = `line'.  Runs each redraw cycle until a
prompt appears, then enters and disarms.  A manual mode switch during startup
wins: a non-semi-char buffer drops the flag without entering."
  (when ghostel--pending-initial-line-mode
    (cond
     ((not (eq ghostel--input-mode 'semi-char))
      (setq ghostel--pending-initial-line-mode nil))
     ((ghostel--line-mode-startup-prompt-ready-p)
      (setq ghostel--pending-initial-line-mode nil)
      (ghostel-line-mode)))))

(defun ghostel-line-mode-send ()
  "Send the current in-progress input line to the shell.
Deletes the local input, writes it to the PTY, then submits Return.

The encoded Return matters for TUI apps that distinguish a literal
newline (Shift-Enter) from submit (e.g. claude-code, pi).  Shells
accept the same CR as `accept-line'."
  (interactive)
  (unless (eq ghostel--input-mode 'line)
    (user-error "Not in line mode"))
  (let ((input (ghostel--line-mode-input-text)))
    (ghostel--line-mode-delete-input)
    (when (and (> (length input) 0)
               (or (null ghostel--line-mode-history)
                   (not (string= input (car ghostel--line-mode-history)))))
      (push input ghostel--line-mode-history)
      (when (> (length ghostel--line-mode-history)
               ghostel-line-mode-history-size)
        (setcdr (nthcdr (1- ghostel-line-mode-history-size)
                        ghostel--line-mode-history)
                nil)))
    (setq ghostel--line-mode-history-index nil)
    ;; Erase any prefix the shell already had in its readline buffer
    ;; (adopted on line-mode entry) before sending — otherwise the
    ;; shell would concatenate ours after that prefix and echo a
    ;; duplicated line.
    (ghostel--line-mode-clear-shell-readline)
    (when (> (length input) 0)
      (ghostel--write-pty ghostel--term input))
    (ghostel--send-encoded "return" "")
    ;; Drop this line's undo history so the next line starts clean.
    (setq buffer-undo-list nil)))

(defun ghostel-line-mode-interrupt ()
  "Discard local input and send SIGINT (\\`C-c') to the shell.
Stays in line mode for the next prompt."
  (interactive)
  (ghostel--line-mode-delete-input)
  (setq ghostel--line-mode-history-index nil)
  ;; C-c discards readline's input buffer shell-side, so any adopted
  ;; prefix is gone — just zero our count, no backspaces needed.
  (setq ghostel--line-mode-adopted-count 0)
  ;; The line is discarded; clear its undo history too (mirrors send).
  (setq buffer-undo-list nil)
  (ghostel--write-pty ghostel--term "\C-c"))

(defun ghostel-line-mode-delete-char-or-eof ()
  "Delete the next char, or send EOF at an empty input."
  (interactive)
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end (and (markerp ghostel--line-input-end)
                  (marker-position ghostel--line-input-end))))
    (if (and start end (= start end) (= (point) start))
        (ghostel--write-pty ghostel--term "\C-d")
      (delete-char 1))))

(defun ghostel--line-mode-replace-input (text)
  "Replace the current in-progress input with TEXT."
  (ghostel--line-mode-delete-input)
  (when (and ghostel--line-input-start
             (marker-position ghostel--line-input-start))
    (goto-char (marker-position ghostel--line-input-start))
    ;; Insertion advances `ghostel--line-input-end' (insertion type
    ;; t), so the end marker tracks the new input's tail.
    (insert text)
    (when (markerp ghostel--line-input-end)
      (goto-char (marker-position ghostel--line-input-end)))))

(defun ghostel-line-mode-history-previous ()
  "Replace the input with the previous entry from history."
  (interactive)
  (when ghostel--line-mode-history
    (let* ((len (length ghostel--line-mode-history))
           (idx (if ghostel--line-mode-history-index
                    (min (1- len) (1+ ghostel--line-mode-history-index))
                  0)))
      (setq ghostel--line-mode-history-index idx)
      (ghostel--line-mode-replace-input
       (nth idx ghostel--line-mode-history)))))

(defun ghostel-line-mode-history-next ()
  "Replace the input with the next entry from history."
  (interactive)
  (cond
   ((null ghostel--line-mode-history-index)
    (ghostel--line-mode-replace-input ""))
   ((zerop ghostel--line-mode-history-index)
    (setq ghostel--line-mode-history-index nil)
    (ghostel--line-mode-replace-input ""))
   (t
    (setq ghostel--line-mode-history-index
          (1- ghostel--line-mode-history-index))
    (ghostel--line-mode-replace-input
     (nth ghostel--line-mode-history-index ghostel--line-mode-history)))))

(defun ghostel--line-mode-bash-completion-available-p ()
  "Return non-nil when bash-completion should be used for line-mode TAB.
Honours `ghostel-line-mode-use-bash-completion': loads the package
when set to t, attempts a soft load when set to `auto', returns nil
otherwise."
  (pcase ghostel-line-mode-use-bash-completion
    ('nil nil)
    ('auto (require 'bash-completion nil 'noerror))
    (_ (require 'bash-completion))))

(defun ghostel--line-mode-effective-capfs ()
  "Return the capf list used by `ghostel-line-mode-complete-at-point'.
Starts from `ghostel-line-mode-completion-at-point-functions' and
prepends `bash-completion-capf-nonexclusive' when bash-completion
integration is enabled and available."
  (let ((funs (copy-sequence
               ghostel-line-mode-completion-at-point-functions)))
    (when (and (ghostel--line-mode-bash-completion-available-p)
               (not (memq #'bash-completion-capf-nonexclusive funs)))
      (push #'bash-completion-capf-nonexclusive funs))
    funs))

(defun ghostel--line-mode-maybe-prespawn-bash-completion ()
  "Spawn the bash-completion subprocess eagerly when configured.
Honours `ghostel-line-mode-bash-completion-prespawn'.  No-op when
the option is nil, when bash-completion is unavailable, or when
the subprocess is already running (the bash-completion entry
point is idempotent)."
  (when (and ghostel-line-mode-bash-completion-prespawn
             (ghostel--line-mode-bash-completion-available-p)
             (fboundp 'bash-completion-require-process))
    (ignore-errors (bash-completion-require-process))))

(defun ghostel-line-mode-complete-at-point ()
  "Complete the line-mode input at point.
Completion sees only the editable input, not the prompt or scrollback.
When point is in read-only scrollback, completion starts at the end of
the input instead."
  (interactive)
  (let ((start (and (markerp ghostel--line-input-start)
                    (marker-position ghostel--line-input-start)))
        (end   (and (markerp ghostel--line-input-end)
                    (marker-position ghostel--line-input-end))))
    (cond
     ((not (and start end))
      ;; No live input markers — nothing to complete against.
      (user-error "Line mode: no input region to complete"))
     ((or (< (point) start) (> (point) end))
      (deactivate-mark)
      (goto-char end)
      (ghostel-line-mode-complete-at-point))
     (t
      ;; Refresh in case directory tracking flipped between
      ;; local/remote since `shell-completion-vars' first ran.
      (setq-local comint-file-name-prefix
                  (or (file-remote-p default-directory) ""))
      (save-restriction
        (narrow-to-region start end)
        (let ((completion-at-point-functions
               (ghostel--line-mode-effective-capfs)))
          (completion-at-point)))))))

(provide 'ghostel-line-mode)
;;; ghostel-line-mode.el ends here
