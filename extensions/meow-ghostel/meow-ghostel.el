;;; meow-ghostel.el --- Meow integration for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (meow "1.5.0") (ghostel "0.40.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Meow integration for the ghostel terminal emulator.
;;
;; The ghostel buffer is a read-only render of the terminal grid, so
;; meow's editing commands cannot modify it directly.  Instead, the
;; selection-based editing commands (kill, change, replace, yank, …)
;; clamp their range to [input-start, input-end] and apply it over the
;; PTY: arrow keys, backspaces, and bracketed paste drive the shell's
;; own line editor (readline / zle / fish).  Selection motions stay
;; vanilla meow — point and region move freely over the rendered rows.
;;
;; In INSERT state keystrokes fall through meow's (nearly empty) insert
;; keymap to ghostel's semi-char map and reach the PTY unmodified, so no
;; passthrough layer is needed.
;;
;; Outside semi-char input mode (`line' / `copy' / `emacs' / `char'
;; modes, or an alt-screen TUI) every command falls through to `meow-*'.
;;
;; Meow ships no default keybindings, so all commands are installed via
;; `[remap meow-*]' bindings and buffer-local `meow--kbd-*' overrides;
;; they route through whatever layout your `meow-setup' defines.  Bind
;; `ghostel-previous-prompt' / `ghostel-next-prompt' yourself if you
;; want prompt navigation.
;;
;; BEACON state is unsupported in ghostel buffers (its commands edit the
;; buffer directly and hit the read-only guard).
;;
;; Enable by adding to your init:
;;
;;   (use-package meow-ghostel
;;     :after (ghostel meow)
;;     :hook (ghostel-mode . meow-ghostel-mode))

;;; Code:

(require 'subr-x)
(require 'meow)
(require 'ghostel)

(declare-function ghostel--mode-enabled "ghostel-module")

(defvar meow-ghostel-mode)


;; Customization

(defgroup meow-ghostel nil
  "Meow integration for ghostel."
  :group 'ghostel
  :prefix "meow-ghostel-")

(defcustom meow-ghostel-initial-state 'insert
  "Initial meow state for new `ghostel-mode' buffers.
Setting via Customize, `setopt', or `customize-set-variable' applies the
change immediately through `meow-mode-state-list'.  This option owns the
`ghostel-mode' entry in that list."
  :type '(choice (const :tag "Insert" insert)
                 (const :tag "Normal" normal)
                 (const :tag "Motion" motion)
                 (symbol :tag "Other state"))
  :set (lambda (sym val)
         (set-default-toplevel-value sym val)
         (setf (alist-get 'ghostel-mode meow-mode-state-list) val)))

(defcustom meow-ghostel-escape 'auto
  "Where insert-state ESC is routed in ghostel buffers.

`auto'     - to the terminal in alt-screen mode (DECSET 1049: vim, less,
             htop, …); otherwise meow's binding switches to normal state.
`terminal' - always send ESC to the terminal.
`meow'     - always run meow's binding.

Sets the initial value of the buffer-local routing mode; change it per
buffer with \\[meow-ghostel-toggle-send-escape]."
  :type '(choice (const :tag "Auto (alt-screen heuristic)" auto)
                 (const :tag "Always to terminal" terminal)
                 (const :tag "Always to meow" meow)))

(defcustom meow-ghostel-sync-render-max-iterations 10
  "Iteration cap for waiting on terminal output to settle.
Each iteration waits up to 50 ms, bounding the total wait at ~500 ms."
  :type 'integer)

;; Apply at load: a plain `setq' before load skips the `:set' above.
(setf (alist-get 'ghostel-mode meow-mode-state-list)
      meow-ghostel-initial-state)


;; Guard predicates

(defun meow-ghostel--active-p ()
  "Return non-nil when meow-ghostel PTY routing should intercept.
True in `semi-char' input mode and outside alt-screen — the only state in
which `meow-ghostel-*' commands send PTY keys rather than running `meow-*'."
  (and meow-ghostel-mode
       ghostel--term
       (not (ghostel--mode-enabled ghostel--term 1049))
       (eq ghostel--input-mode 'semi-char)))

(defun meow-ghostel--line-mode-active-p ()
  "Return non-nil when line mode editing is in effect.
Then shell input is plain buffer text between `ghostel--line-input-start'
and `ghostel--line-input-end', so meow's commands apply directly."
  (and meow-ghostel-mode
       (eq ghostel--input-mode 'line)
       (markerp ghostel--line-input-start)
       (markerp ghostel--line-input-end)))


;; Cursor synchronization

(defun meow-ghostel--scrollback-lines ()
  "Return the count of scrollback lines above the viewport."
  (max 0 (- (count-lines (point-min) (point-max)) ghostel--term-rows)))

(defun meow-ghostel--reset-cursor-point ()
  "Move Emacs point to the terminal cursor.
`ghostel--cursor-pos' is viewport-relative; its row is offset by scrollback."
  (when (and ghostel--term ghostel--term-rows ghostel--cursor-pos)
    (goto-char (point-min))
    (forward-line (+ (meow-ghostel--scrollback-lines) (cdr ghostel--cursor-pos)))
    (move-to-column (car ghostel--cursor-pos))))

(defun meow-ghostel--point-viewport-row ()
  "Return the viewport row of point, 0-indexed, or nil.
Comparable to `ghostel--cursor-pos''s row."
  (when ghostel--term-rows
    (- (line-number-at-pos (point) t) 1 (meow-ghostel--scrollback-lines))))

;; Redraw: preserve meow point/selection semantics.  ghostel repaints the
;; viewport on each redraw without snapping point to the cursor; right
;; for normal state.  Point follows the cursor only in insert state
;; (where typed chars land there); an active selection is restored around
;; the repaint.

(defun meow-ghostel--around-redraw (orig-fn term &optional full)
  "Apply meow point/selection handling around `ghostel--redraw'.
ORIG-FN is the advised function (TERM, FULL).  Skipped in alt-screen (1049)."
  (if (and meow-ghostel-mode
           (not (ghostel--mode-enabled term 1049)))
      (let* ((region-p (region-active-p))
             (saved-mark (and region-p (mark t))))
        ;; The repaint's buffer edits set `deactivate-mark'; without
        ;; binding it, streaming output would drop an active selection
        ;; at the end of the current command.
        (let ((deactivate-mark nil))
          (funcall orig-fn term full))
        ;; Don't drag point to the cursor while the user reads scrollback;
        ;; redisplay would yank the viewport back to the bottom each frame.
        ;; (No window showing the buffer → treat as following.)
        (when (and (meow-insert-mode-p)
                   (let ((win (get-buffer-window (current-buffer) t)))
                     (or (null win) (ghostel--window-anchored-p win))))
          (meow-ghostel--reset-cursor-point))
        (when saved-mark
          (set-marker (mark-marker) (min saved-mark (point-max)))))
    (funcall orig-fn term full)))

(defun meow-ghostel--anchor-inhibit (_window force)
  "Veto ghostel's redraw anchor while point roams off the live cursor.
A `ghostel-inhibit-anchor-functions' entry: returns non-nil outside
insert state with point off the cursor, unless FORCE."
  (and (not force)
       (meow-ghostel--active-p)
       (not (meow-insert-mode-p))
       ghostel--cursor-char-pos
       (/= (point) ghostel--cursor-char-pos)))

;; Cursor style: let meow control cursor shape

(defun meow-ghostel--override-cursor-style (orig-fn)
  "Let meow control cursor shape instead of the terminal.
ORIG-FN is the advised setter (STYLE, VISIBLE); deferred to in alt-screen."
  (if (and meow-ghostel-mode
           ghostel--term
           (not (ghostel--mode-enabled ghostel--term 1049)))
      ;; Meow owns the cursor now; end any terminal-driven blink that a
      ;; full-screen app left running before we exited the alt-screen.
      (progn (ghostel--cursor-blink-stop)
             (meow--update-cursor))
    (funcall orig-fn)))


;; Meow state hooks

(defun meow-ghostel--insert-enter ()
  "Drive the terminal cursor to point on insert entry (safety net).
On a different row, snap point back to the cursor instead — up/down arrows
would be read as shell history navigation."
  (when (and (derived-mode-p 'ghostel-mode)
             (meow-ghostel--active-p))
    (let ((trow (cdr ghostel--cursor-pos))
          (erow (or (meow-ghostel--point-viewport-row) 0)))
      (if (equal erow trow)
          (meow-ghostel-goto-input-position (point))
        (meow-ghostel--reset-cursor-point)))))


;; Input region: boundaries on the cursor row.  ghostel core provides the
;; prompt boundary (`ghostel-input-start-point'); we add the right edge.

(defun meow-ghostel--fg-color (pos)
  "Return the foreground color string of the cell at POS, or nil.
The renderer stores each cell's color as a `face' plist `:foreground'."
  (let ((face (get-text-property pos 'face)))
    (cond ((and (consp face) (plist-member face :foreground))
           (plist-get face :foreground))
          ((facep face) (face-foreground face nil t)))))

(defun meow-ghostel--greyed-out-p (color)
  "Non-nil when COLOR (a hex string) is a dim, desaturated suggestion grey.
Dim plus low-saturation is what separates a suggestion from a saturated
syntax-highlight color (a cyan argument, a red invalid command)."
  (let ((rgb (and (stringp color) (ignore-errors (color-values color)))))
    (when rgb                              ; color-values channels are 0-65535
      (let ((mx (apply #'max rgb))
            (mn (apply #'min rgb)))
        (and (< mx 49152)                  ; dim: not bright
             (< (- mx mn) 13107))))))      ; grey: low saturation

(defun meow-ghostel--suggestion-p (cursor region-end)
  "Non-nil when [CURSOR, REGION-END) looks like an autosuggestion.
That is a single greyed-out color run to the region end, past typed input.
Keys on `meow-ghostel--greyed-out-p', not luminance or color difference,
which misfire under syntax highlighting."
  (and (meow-ghostel--input-start)            ; typed input precedes the cursor
       (< cursor region-end)                  ; a trailing run exists
       (let ((typed (meow-ghostel--fg-color (1- cursor)))
             (trail (meow-ghostel--fg-color cursor)))
         (and trail
              (not (equal trail typed))       ; trailing color differs from typed
              (meow-ghostel--greyed-out-p trail) ; …and is a greyed-out color
              ;; …uniform all the way to the end of the region:
              (>= (or (next-single-property-change cursor 'face nil region-end)
                      region-end)
                  region-end)))))

(defun meow-ghostel--input-end ()
  "Return the position just after typed input on the cursor row, or nil.
Prefers the first `ghostel-input' region (OSC 133), else end-of-line minus
padding; a trailing autosuggestion is excluded (boundary at the cursor)."
  (when ghostel--cursor-char-pos
    (save-excursion
      (goto-char ghostel--cursor-char-pos)
      (let* ((bol (line-beginning-position))
             (eol (line-end-position))
             (region-start (text-property-any bol eol 'ghostel-input t))
             (region-end (and region-start
                              (next-single-property-change
                               region-start 'ghostel-input nil eol)))
             (cursor ghostel--cursor-char-pos))
        (cond
         ((and region-end (< cursor region-end)
               (meow-ghostel--suggestion-p cursor region-end))
          cursor)
         (region-end)
         ;; No `ghostel-input' region: strip renderer padding back from
         ;; EOL, but never past the live cursor — on an empty prompt that
         ;; would strip the prompt's trailing space and land the operator
         ;; clamp inside the prompt.
         (t (goto-char eol)
            (skip-chars-backward " \t" bol)
            (max (point) cursor)))))))

(defun meow-ghostel--input-start ()
  "Return the prompt boundary on the cursor row, or nil if undetected.
Unlike `ghostel-input-start-point', returns nil (not the cursor) when no
prompt is recognized, so a command's BEG stays unclamped rather than
collapsing the range — vterm's behaviour for shells without prompt tracking."
  (let ((s (ghostel-input-start-point)))
    (and s ghostel--cursor-char-pos (< s ghostel--cursor-char-pos) s)))

(defun meow-ghostel--clamp (beg end)
  "Clamp BEG..END to the editable input region; return a (BEG . END) cons.
BEG is raised to `meow-ghostel--input-start', END lowered to
`meow-ghostel--input-end', so selection overshoot (a word selection on the
last word) can't over-delete past the live input.  END is never below BEG."
  (let* ((start (meow-ghostel--input-start))
         (input-end (meow-ghostel--input-end))
         (beg (or beg (point)))
         (end (or end beg))
         (b (if start (max beg start) beg))
         (e (if input-end (min end input-end) end)))
    (cons b (max b e))))


;; PTY-driven input editing.  Drive the shell's line editor (readline/zle/fish)
;; with arrow keys, backspaces, and bracketed paste over the PTY.
;; Only meaningful in semi-char input mode.

(defun meow-ghostel--sync-render ()
  "Drain pending PTY output so cursor state reflects the latest echo.
Loops `accept-process-output' (capped by
`meow-ghostel-sync-render-max-iterations'), then flushes any deferred redraw."
  (when (and ghostel--process (process-live-p ghostel--process))
    (let ((iter 0))
      (while (and (< iter meow-ghostel-sync-render-max-iterations)
                  (accept-process-output ghostel--process 0.05 nil t))
        (setq iter (1+ iter))))
    (when ghostel--redraw-timer
      (ghostel--redraw-now (current-buffer)))))

(defun meow-ghostel-goto-input-position (pos)
  "Drive the terminal cursor and Emacs point to buffer position POS.
On the cursor row a rightward target is clamped to `meow-ghostel--input-end',
so the move never right-arrows across a trailing autosuggestion, which the
shell would accept (zsh-autosuggestions / fish).  Only meaningful in
semi-char mode.  Returns non-nil when it ran."
  (when (and ghostel--term ghostel--cursor-pos)
    (let* ((start-col (car ghostel--cursor-pos))
           (start-row-vp (cdr ghostel--cursor-pos))
           (target-row-vp (or (ghostel--viewport-row-at pos) start-row-vp))
           (dy (- target-row-vp start-row-vp)))
      ;; Clamp only a rightward, same-row target: at end-of-input a right
      ;; arrow accepts the greyed suggestion.
      ;; `input-end' excludes it, so stopping there means we never accept.
      (when (and (zerop dy)
                 ghostel--cursor-char-pos
                 (> pos ghostel--cursor-char-pos))
        (setq pos (min pos (or (meow-ghostel--input-end) pos))))
      (let ((dx (- (save-excursion (goto-char pos) (current-column)) start-col)))
        (cond ((> dy 0) (dotimes (_ dy) (ghostel--send-encoded "down" "")))
              ((< dy 0) (dotimes (_ (abs dy)) (ghostel--send-encoded "up" ""))))
        (cond ((> dx 0) (dotimes (_ dx) (ghostel--send-encoded "right" "")))
              ((< dx 0) (dotimes (_ (abs dx)) (ghostel--send-encoded "left" ""))))
        (when (or (/= dx 0) (/= dy 0))
          (meow-ghostel--sync-render))
        (goto-char pos)
        t))))

(defun meow-ghostel-delete-input-region (beg end)
  "Delete BEG..END from input by backspacing over the PTY; return the count.
Soft-wrap newlines are skipped (renderer artifacts).  Leaves point at BEG;
the delete lands when the shell echoes it.  Semi-char only."
  (let ((count (length (ghostel--filter-soft-wraps (buffer-substring beg end)))))
    (when (> count 0)
      (meow-ghostel-goto-input-position end)
      (dotimes (_ count)
        (ghostel--send-encoded "backspace" ""))
      ;; Keep cursor state current for commands that continue editing.
      (meow-ghostel--sync-render)
      (goto-char beg))
    count))

(defun meow-ghostel-replace-input-region (beg end string)
  "Replace the BEG..END range with STRING via the terminal PTY.
Deletes the range with `meow-ghostel-delete-input-region', then pastes
STRING through bracketed paste.  Only meaningful in `semi-char' mode."
  (let ((deleted (meow-ghostel-delete-input-region beg end)))
    (when (and (> deleted 0) string (not (string-empty-p string)))
      (ghostel--paste-text string))
    deleted))


;; Selection fallback: meow looks up `this-command' in
;; `meow-selection-command-fallback', but under a remap `this-command' is
;; the meow-ghostel variant, missing the alist.  Look up the original
;; command instead, and route the fallback back through `command-remapping'
;; so it hits our PTY variants too.

(defun meow-ghostel--selection-fallback (command)
  "Run COMMAND's `meow-selection-command-fallback' entry, or signal.
The fallback is dispatched through `command-remapping'."
  (if-let* ((fallback (alist-get command meow-selection-command-fallback)))
      (call-interactively (or (command-remapping fallback) fallback))
    (error "No selection")))


;; Motions (kbd-macro override targets; the rest stay vanilla meow)

(defun meow-ghostel-next-line (&optional count)
  "Move COUNT lines down, but not past the terminal cursor's row.
Installed as the buffer-local `meow--kbd-forward-line' target."
  (interactive "p")
  (if (not (meow-ghostel--active-p))
      (with-suppressed-warnings ((interactive-only next-line))
        (next-line count))
    (let ((cursor-line (and ghostel--cursor-pos
                            (save-excursion
                              (meow-ghostel--reset-cursor-point)
                              (1- (line-number-at-pos (point) t)))))
          (col (current-column)))
      (condition-case _err
          (with-suppressed-warnings ((interactive-only next-line))
            (next-line count))
        ((beginning-of-buffer end-of-buffer) nil))
      (when (and cursor-line
                 (> (1- (line-number-at-pos (point) t)) cursor-line))
        (goto-char (point-min))
        (forward-line cursor-line)
        (move-to-column col)))))

(defun meow-ghostel-back-to-indentation ()
  "Move to the first input character after the prompt.
Installed as the buffer-local `meow--kbd-back-to-indentation' target."
  (interactive)
  (if (or (meow-ghostel--active-p)
          (meow-ghostel--line-mode-active-p))
      (ghostel-beginning-of-input-or-line)
    (back-to-indentation)))


;; Insert / Append / Open

(defun meow-ghostel-insert ()
  "Enter insert state at the selection start, driving the shell cursor."
  (interactive)
  (if (or (not (meow-ghostel--active-p)) meow--temp-normal)
      (call-interactively #'meow-insert)
    (meow--direction-backward)
    (meow--cancel-selection)
    (if (ghostel-point-on-cursor-row-p)
        (let* ((input-end (meow-ghostel--input-end))
               (target (if input-end (min (point) input-end) (point))))
          (meow-ghostel-goto-input-position target))
      (when-let* ((target (ghostel-input-start-point)))
        (meow-ghostel-goto-input-position target)))
    (meow--switch-state 'insert)
    (setq-local meow--insert-pos (point))))

(defun meow-ghostel-append ()
  "Enter insert state at the selection end, driving the shell cursor."
  (interactive)
  (if (or (not (meow-ghostel--active-p)) meow--temp-normal)
      (call-interactively #'meow-append)
    (if (region-active-p)
        (progn
          (meow--direction-forward)
          (meow--cancel-selection)
          (let ((input-end (meow-ghostel--input-end)))
            (meow-ghostel-goto-input-position
             (if input-end (min (point) input-end) (point)))))
      (cond
       ((not (ghostel-point-on-cursor-row-p))
        (when-let* ((target (ghostel-input-start-point)))
          (meow-ghostel-goto-input-position target)))
       ;; No selection: honor `meow-use-cursor-position-hack' (advance one
       ;; cell like vim's `a'), but never onto RPROMPT padding and never
       ;; past input-end, where a right arrow accepts a suggestion.
       ((and meow-use-cursor-position-hack (< (point) (point-max)))
        (let* ((cur (ghostel-cursor-point))
               (target
                (if (and cur (>= (point) cur)
                         (save-excursion
                           (goto-char cur)
                           (or (eolp) (looking-at-p "[ \t]"))))
                    (point)
                  (let ((input-end (meow-ghostel--input-end)))
                    (min (1+ (point)) (or input-end (1+ (point))))))))
          (meow-ghostel-goto-input-position target)))
       (t
        (let ((input-end (meow-ghostel--input-end)))
          (meow-ghostel-goto-input-position
           (if input-end (min (point) input-end) (point)))))))
    (meow--switch-state 'insert)
    (setq-local meow--insert-pos (point))))

(defun meow-ghostel-open-below ()
  "Enter insert state at the end of input.
Never runs vanilla `meow-open-below' in semi-char: its RET keyboard
macro would execute the current command line."
  (interactive)
  (cond
   ((and (meow-ghostel--active-p) (not meow--temp-normal))
    (meow--cancel-selection)
    (when-let* ((target (meow-ghostel--input-end)))
      (meow-ghostel-goto-input-position target))
    (meow--switch-state 'insert)
    (setq-local meow--insert-pos (point)))
   ((meow-ghostel--line-mode-active-p)
    (goto-char (marker-position ghostel--line-input-end))
    (meow--switch-state 'insert)
    (setq-local meow--insert-pos (point)))
   (t (call-interactively #'meow-open-below))))

(defun meow-ghostel-open-above ()
  "Enter insert state at the start of input.
Never runs vanilla `meow-open-above' in semi-char: `newline' would
signal on the read-only buffer."
  (interactive)
  (cond
   ((and (meow-ghostel--active-p) (not meow--temp-normal))
    (meow--cancel-selection)
    (when-let* ((target (ghostel-input-start-point)))
      (meow-ghostel-goto-input-position target))
    (meow--switch-state 'insert)
    (setq-local meow--insert-pos (point)))
   ((meow-ghostel--line-mode-active-p)
    (goto-char (marker-position ghostel--line-input-start))
    (meow--switch-state 'insert)
    (setq-local meow--insert-pos (point)))
   (t (call-interactively #'meow-open-above))))


;; Kill / Delete

(defun meow-ghostel-kill ()
  "Kill the selection through the terminal when editing live input.
The range is clamped to the current input; the killed text still lands
on the kill ring.  Join-type selections are treated as plain regions."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-kill)
    (if (not (region-active-p))
        (meow-ghostel--selection-fallback 'meow-kill)
      (let* ((clamped (meow-ghostel--clamp (region-beginning) (region-end)))
             (beg (car clamped))
             (end (cdr clamped))
             (text (ghostel--filter-soft-wraps
                    (filter-buffer-substring beg end))))
        (meow--cancel-selection)
        (unless (string-empty-p text)
          (let ((select-enable-clipboard meow-use-clipboard))
            (kill-new text)))
        (meow-ghostel-delete-input-region beg end)))))

(defun meow-ghostel-kill-append ()
  "Kill the selection through the terminal, appending to the latest kill."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-kill-append)
    (if (not (region-active-p))
        (meow-ghostel--selection-fallback 'meow-kill-append)
      (let* ((clamped (meow-ghostel--clamp (region-beginning) (region-end)))
             (beg (car clamped))
             (end (cdr clamped))
             (text (ghostel--filter-soft-wraps
                    (filter-buffer-substring beg end))))
        (meow--cancel-selection)
        (unless (string-empty-p text)
          (let ((select-enable-clipboard meow-use-clipboard))
            (kill-append (meow--prepare-string-for-kill-append text) nil)))
        (meow-ghostel-delete-input-region beg end)))))

(defun meow-ghostel-kill-whole-line ()
  "Kill the whole input line through the terminal."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-kill-whole-line)
    (let* ((clamped (meow-ghostel--clamp (line-beginning-position)
                                         (line-end-position)))
           (beg (car clamped))
           (end (cdr clamped))
           (text (ghostel--filter-soft-wraps
                  (filter-buffer-substring beg end))))
      (unless (string-empty-p text)
        (let ((select-enable-clipboard meow-use-clipboard))
          (kill-new text)))
      (meow-ghostel-delete-input-region beg end))))

(defun meow-ghostel-C-k ()
  "Kill from point to the end of input through the terminal.
Vanilla `meow-C-k' would send a raw C-k, which kills at the terminal
cursor rather than at point."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-C-k)
    (let* ((end (or (meow-ghostel--input-end) (line-end-position)))
           (beg (min (point) end))
           (text (ghostel--filter-soft-wraps
                  (filter-buffer-substring beg end))))
      (unless (string-empty-p text)
        (let ((select-enable-clipboard meow-use-clipboard))
          (kill-new text)))
      (meow-ghostel-delete-input-region beg end))))

(defun meow-ghostel-C-d ()
  "Forward-delete the character at point through the terminal.
Vanilla `meow-C-d' would send a raw C-d at the terminal cursor — on an
empty input line that is EOF and exits the shell."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-C-d)
    (when (meow-ghostel-goto-input-position (point))
      (ghostel--send-encoded "delete" "")
      (meow-ghostel--sync-render))))

(defun meow-ghostel-backspace ()
  "Backward-delete one character through the terminal."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-backspace)
    (when (meow-ghostel-goto-input-position (point))
      (ghostel--send-encoded "backspace" "")
      (meow-ghostel--sync-render))))


;; Change

(defun meow-ghostel-change ()
  "Change the selection through the terminal, then enter insert state.
Like `meow-change', the deleted text is not saved to the kill ring."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-change)
    (if (not (region-active-p))
        (meow-ghostel--selection-fallback 'meow-change)
      (let* ((clamped (meow-ghostel--clamp (region-beginning) (region-end)))
             (beg (car clamped))
             (end (cdr clamped)))
        (meow--cancel-selection)
        (meow-ghostel-delete-input-region beg end)
        (meow--switch-state 'insert)
        (setq-local meow--insert-pos (point))))))

(defun meow-ghostel-change-char ()
  "Delete the character at point through the terminal, then insert state."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-change-char)
    (when (meow-ghostel-goto-input-position (point))
      (ghostel--send-encoded "delete" "")
      (meow-ghostel--sync-render))
    (meow--switch-state 'insert)
    (setq-local meow--insert-pos (point))))

(defun meow-ghostel-change-save ()
  "Kill the selection through the terminal, then enter insert state."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-change-save)
    (when (region-active-p)
      (meow-ghostel-kill)
      (meow--switch-state 'insert)
      (setq-local meow--insert-pos (point)))))


;; Replace

(defun meow-ghostel-replace ()
  "Replace the selection with the current kill through the terminal."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-replace)
    (if (not (region-active-p))
        (meow-ghostel--selection-fallback 'meow-replace)
      (when-let* ((s (let ((select-enable-clipboard meow-use-clipboard))
                       (string-trim-right (current-kill 0 t) "\n"))))
        (let* ((clamped (meow-ghostel--clamp (region-beginning) (region-end)))
               (beg (car clamped))
               (end (cdr clamped)))
          (meow--cancel-selection)
          (meow-ghostel-replace-input-region beg end s))))))

(defun meow-ghostel-replace-char ()
  "Replace the character at point with the current kill via the terminal."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-replace-char)
    (when (< (point) (point-max))
      (when-let* ((s (let ((select-enable-clipboard meow-use-clipboard))
                       (string-trim-right (current-kill 0 t) "\n"))))
        (meow-ghostel-replace-input-region (point) (1+ (point)) s)))))


;; Yank

(defun meow-ghostel-yank ()
  "Paste the current kill at point via bracketed paste.
Vanilla `meow-yank' resolves C-y through the local map to `ghostel-yank',
which pastes at the terminal cursor rather than at point."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-yank)
    (when-let* ((text (let ((select-enable-clipboard meow-use-clipboard))
                        (current-kill 0))))
      (meow-ghostel-goto-input-position (point))
      (ghostel--paste-text text))))

(defun meow-ghostel-yank-pop ()
  "Signal that yank-pop is unsupported on live terminal input.
The pasted text is echoed by the shell, so the previous paste cannot be
swapped out the way `yank-pop' edits a buffer."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-yank-pop)
    (user-error "Yank-pop not supported in terminal; kill and paste instead")))


;; Undo

(defun meow-ghostel-undo ()
  "Cancel the selection and send Ctrl-_ (readline undo)."
  (interactive)
  (if (not (meow-ghostel--active-p))
      (call-interactively #'meow-undo)
    (when (region-active-p)
      (meow--cancel-selection))
    (ghostel--send-encoded "_" "ctrl")))


;; Buffer-edit indirection: `meow--delete-region' / `meow--insert' route
;; through these buffer-local function variables.  They carry the
;; commands not covered by remaps — notably `meow-kill-thing' (and its
;; word/symbol wrappers), whose `kill-region' signals on the read-only
;; buffer and falls back to `meow--delete-region'.

(defun meow-ghostel--delete-region (start end)
  "Delete START..END, PTY-routed in semi-char.
Installed buffer-locally as `meow--delete-region-function'."
  (if (meow-ghostel--active-p)
      (let ((clamped (meow-ghostel--clamp start end)))
        (meow-ghostel-delete-input-region (car clamped) (cdr clamped)))
    (delete-region start end)))

(defun meow-ghostel--insert (&rest args)
  "Insert ARGS at point, PTY-routed in semi-char.
Installed buffer-locally as `meow--insert-function'."
  (if (meow-ghostel--active-p)
      (let ((text (mapconcat (lambda (x) (if (stringp x) x (char-to-string x)))
                             args "")))
        (unless (string-empty-p text)
          (meow-ghostel-goto-input-position (point))
          (ghostel--paste-text text)))
    (apply #'insert args)))


;; ESC routing: terminal vs meow

(defvar-local meow-ghostel--escape-mode nil
  "Buffer-local override for ESC routing.
Initialized from `meow-ghostel-escape' when the minor mode turns on.
Valid values: `auto', `terminal', `meow'.")

(defconst meow-ghostel--escape-modes '(auto terminal meow)
  "Cycle order for `meow-ghostel-toggle-send-escape'.")

(defun meow-ghostel-escape ()
  "Dispatch insert-state ESC based on `meow-ghostel--escape-mode'.
Terminal-bound ESC runs through `ghostel--on-user-input'; otherwise
`meow-insert-exit' runs (called directly, so no remap recursion)."
  (interactive)
  (let* ((mode meow-ghostel--escape-mode)
         (to-terminal (or (eq mode 'terminal)
                          (and (eq mode 'auto)
                               ghostel--term
                               (ghostel--mode-enabled ghostel--term 1049)))))
    (if to-terminal
        (progn
          (ghostel--on-user-input)
          (ghostel--send-encoded "escape" ""))
      (meow-insert-exit))))

(defun meow-ghostel-toggle-send-escape (&optional arg)
  "Cycle or set the ESC routing mode for the current buffer.
Without ARG, cycle `auto' → `terminal' → `meow'.  With numeric prefix 1/2/3
set `auto'/`terminal'/`meow'; other prefixes signal a `user-error'.  The
mode is buffer-local; see `meow-ghostel-escape' for the default."
  (interactive "P")
  (let ((target
         (if arg
             (let ((n (prefix-numeric-value arg)))
               (or (nth (1- n) meow-ghostel--escape-modes)
                   (user-error
                    "Invalid prefix %d; use 1 (auto), 2 (terminal), or 3 (meow)"
                    n)))
           (let ((next (cdr (memq meow-ghostel--escape-mode
                                  meow-ghostel--escape-modes))))
             (or (car next) (car meow-ghostel--escape-modes))))))
    (setq meow-ghostel--escape-mode target)
    (message "meow-ghostel ESC mode: %s" target)))


;; Keymap.  Only `[remap meow-*]' bindings, never literal keys: meow has
;; no default layout, so remaps route whatever keys the user's
;; `meow-setup' picked through the PTY variants.  This is an ordinary
;; minor-mode map — command remapping is looked up across all active
;; keymaps, and meow's emulation-mode maps bind no `[remap meow-*]'
;; entries, so these apply even though those maps have higher priority.

(defvar meow-ghostel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap meow-insert]          #'meow-ghostel-insert)
    (define-key map [remap meow-append]          #'meow-ghostel-append)
    (define-key map [remap meow-open-below]      #'meow-ghostel-open-below)
    (define-key map [remap meow-open-above]      #'meow-ghostel-open-above)
    (define-key map [remap meow-kill]            #'meow-ghostel-kill)
    (define-key map [remap meow-kill-append]     #'meow-ghostel-kill-append)
    (define-key map [remap meow-kill-whole-line] #'meow-ghostel-kill-whole-line)
    (define-key map [remap meow-C-k]             #'meow-ghostel-C-k)
    (define-key map [remap meow-C-d]             #'meow-ghostel-C-d)
    (define-key map [remap meow-backspace]       #'meow-ghostel-backspace)
    ;; Aliases remap separately: a key bound to the alias symbol
    ;; (e.g. qwerty `d' -> `meow-delete') only matches a remap of that
    ;; same symbol, not of the alias target.
    (define-key map [remap meow-delete]          #'meow-ghostel-C-d)
    (define-key map [remap meow-c-d]             #'meow-ghostel-C-d)
    (define-key map [remap meow-c-k]             #'meow-ghostel-C-k)
    (define-key map [remap meow-backward-delete] #'meow-ghostel-backspace)
    (define-key map [remap meow-change]          #'meow-ghostel-change)
    (define-key map [remap meow-change-char]     #'meow-ghostel-change-char)
    (define-key map [remap meow-change-save]     #'meow-ghostel-change-save)
    (define-key map [remap meow-replace]         #'meow-ghostel-replace)
    (define-key map [remap meow-replace-char]    #'meow-ghostel-replace-char)
    (define-key map [remap meow-yank]            #'meow-ghostel-yank)
    (define-key map [remap meow-yank-pop]        #'meow-ghostel-yank-pop)
    (define-key map [remap meow-undo]            #'meow-ghostel-undo)
    (define-key map [remap meow-insert-exit]     #'meow-ghostel-escape)
    map)
  "Keymap for `meow-ghostel-mode'.
Contains only `[remap meow-*]' bindings; see the commentary.")


;; Minor mode

(defun meow-ghostel--any-active-elsewhere-p (except-buffer)
  "Return non-nil if any buffer but EXCEPT-BUFFER has `meow-ghostel-mode' on.
Decides whether the global advice can be removed on the last disable."
  (catch 'found
    (dolist (b (buffer-list))
      (when (and (not (eq b except-buffer))
                 (buffer-local-value 'meow-ghostel-mode b))
        (throw 'found t)))))

(defconst meow-ghostel--kbd-overrides
  ;; ghostel's semi-char map binds C-<letter> and M-<printable> to PTY
  ;; senders, so meow's kbd-macro commands would resolve to those and
  ;; type bytes into the shell (`meow-save' would send M-w, `meow-next'
  ;; would browse shell history).  Function symbols bypass the key
  ;; lookup entirely; `meow--execute-kbd-macro' calls them directly.
  '((meow--kbd-backward-char       . backward-char)
    (meow--kbd-forward-char        . forward-char)
    (meow--kbd-backward-line       . previous-line)
    (meow--kbd-forward-line        . meow-ghostel-next-line)
    (meow--kbd-back-to-indentation . meow-ghostel-back-to-indentation)
    (meow--kbd-scoll-up            . scroll-up-command)
    (meow--kbd-scoll-down          . scroll-down-command)
    (meow--kbd-kill-ring-save      . kill-ring-save)
    (meow--kbd-kill-region         . kill-region)
    (meow--kbd-yank                . yank)
    (meow--kbd-yank-pop            . yank-pop)
    (meow--kbd-delete-char         . delete-char)
    (meow--kbd-kill-line           . kill-line)
    (meow--kbd-kill-whole-line     . kill-whole-line)
    (meow--kbd-undo                . undo))
  "Buffer-local `meow--kbd-*' overrides installed by `meow-ghostel-mode'.
Each entry is (VARIABLE . COMMAND).")

;;;###autoload
(define-minor-mode meow-ghostel-mode
  "Minor mode for meow integration in ghostel terminal buffers.
Routes meow's editing commands through the terminal PTY and keeps point
aligned with the terminal cursor across meow state transitions.

Enabling installs global advice while any buffer has the mode enabled."
  :lighter nil
  :keymap meow-ghostel-mode-map
  (if meow-ghostel-mode
      (progn
        (setq meow-ghostel--escape-mode meow-ghostel-escape)
        ;; Meow owns selection here (every selection command activates the
        ;; mark), so opt this buffer out of ghostel's keyboard-mark →
        ;; copy-mode switch: otherwise the first `meow-mark-word' flips the
        ;; buffer to copy mode before the PTY-aware commands can run.
        ;; Mouse selection stays governed by `ghostel-mouse-drag-input-mode'.
        (setq-local ghostel-mark-activation-input-mode nil)
        (dolist (override meow-ghostel--kbd-overrides)
          (set (make-local-variable (car override)) (cdr override)))
        (setq-local meow--delete-region-function #'meow-ghostel--delete-region
                    meow--insert-function #'meow-ghostel--insert)
        (add-hook 'meow-insert-enter-hook
                  #'meow-ghostel--insert-enter nil t)
        ;; Let normal-state navigation roam point off the live cursor
        ;; without the per-redraw anchor snapping it back.
        (add-hook 'ghostel-inhibit-anchor-functions
                  #'meow-ghostel--anchor-inhibit nil t)
        (advice-add 'ghostel--redraw :around #'meow-ghostel--around-redraw)
        (advice-add 'ghostel--apply-cursor-style :around
                    #'meow-ghostel--override-cursor-style)
        (meow--update-cursor))
    (remove-hook 'meow-insert-enter-hook
                 #'meow-ghostel--insert-enter t)
    (remove-hook 'ghostel-inhibit-anchor-functions
                 #'meow-ghostel--anchor-inhibit t)
    (kill-local-variable 'ghostel-mark-activation-input-mode)
    (dolist (override meow-ghostel--kbd-overrides)
      (kill-local-variable (car override)))
    (kill-local-variable 'meow--delete-region-function)
    (kill-local-variable 'meow--insert-function)
    (unless (meow-ghostel--any-active-elsewhere-p (current-buffer))
      (advice-remove 'ghostel--redraw #'meow-ghostel--around-redraw)
      (advice-remove 'ghostel--apply-cursor-style
                     #'meow-ghostel--override-cursor-style))))

(provide 'meow-ghostel)
;;; meow-ghostel.el ends here
