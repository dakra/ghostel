;;; evil-ghostel.el --- Evil-mode integration for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.43.0
;; Package-Requires: ((emacs "28.1") (evil "1.0") (ghostel "0.42.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Evil-mode integration for the ghostel terminal emulator, modeled on
;; `evil-collection-vterm'.
;;
;; Like vterm's, the surface area is tiny.  Basic motions (h l w b e $ 0)
;; stay vanilla Evil, so point moves freely over the rendered row.  Only
;; the commands that drive the shell's line editor are customized:
;; operators (d c x s r and line variants) clamp their range to
;; [input-start, input-end] and apply it over the PTY (arrows, backspaces,
;; bracketed paste); i a I A drive the shell cursor to point; ^ jumps past
;; the prompt; j / G stay on the live prompt; p / P paste; u sends
;; readline undo.
;;
;; Outside semi-char input mode (`line' / `copy' / `emacs' / `char' modes,
;; or an alt-screen TUI) every command falls through to `evil-*'.
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
Setting via Customize, `setopt', or `customize-set-variable' applies the
change immediately through `evil-set-initial-state'."
  :type '(choice (const :tag "Emacs" emacs)
                 (const :tag "Insert" insert)
                 (const :tag "Normal" normal)
                 (symbol :tag "Other state"))
  :set (lambda (sym val)
         (set-default-toplevel-value sym val)
         (evil-set-initial-state 'ghostel-mode val)))

(defcustom evil-ghostel-escape 'auto
  "Where insert-state ESC is routed in ghostel buffers.

`auto'     - to the terminal in alt-screen mode (DECSET 1049: vim, less,
             htop, …); otherwise evil's binding switches to normal state.
`terminal' - always send ESC to the terminal.
`evil'     - always run evil's binding.

Sets the initial value of the buffer-local routing mode; change it per
buffer with \\[evil-ghostel-toggle-send-escape]."
  :type '(choice (const :tag "Auto (alt-screen heuristic)" auto)
                 (const :tag "Always to terminal" terminal)
                 (const :tag "Always to evil" evil)))

(defcustom evil-ghostel-sync-render-max-iterations 10
  "Iteration cap for waiting on terminal output to settle.
Each iteration waits up to 50 ms, bounding the total wait at ~500 ms."
  :type 'integer)

;; Apply at load: a plain `setq' before load skips the `:set' above.
(evil-set-initial-state 'ghostel-mode evil-ghostel-initial-state)


;; Guard predicates

(defun evil-ghostel--active-p ()
  "Return non-nil when evil-ghostel PTY routing should intercept.
True in `semi-char' input mode and outside alt-screen — the only state in
which `evil-ghostel-*' commands send PTY keys rather than running `evil-*'."
  (and evil-ghostel-mode
       ghostel--term
       (not (ghostel--mode-enabled ghostel--term 1049))
       (eq ghostel--input-mode 'semi-char)))

(defun evil-ghostel--ctrl-passthrough-active-p ()
  "Return non-nil when insert-state Ctrl keys should reach the terminal.
Active even in alt-screen, unlike `evil-ghostel--active-p', so a TUI's
readline-style Ctrl keys are not eaten by evil."
  (and evil-ghostel-mode
       ghostel--term
       (eq ghostel--input-mode 'semi-char)))

(defun evil-ghostel--line-mode-active-p ()
  "Return non-nil when line mode editing is in effect.
Then shell input is plain buffer text between `ghostel--line-input-start'
and `ghostel--line-input-end', so evil's operators apply directly."
  (and evil-ghostel-mode
       (eq ghostel--input-mode 'line)
       (markerp ghostel--line-input-start)
       (markerp ghostel--line-input-end)))


;; Cursor synchronization

(defun evil-ghostel--scrollback-lines ()
  "Return the count of scrollback lines above the viewport."
  (max 0 (- (count-lines (point-min) (point-max)) ghostel--term-rows)))

(defun evil-ghostel--reset-cursor-point ()
  "Move Emacs point to the terminal cursor.
`ghostel--cursor-pos' is viewport-relative; its row is offset by scrollback."
  (when (and ghostel--term ghostel--term-rows ghostel--cursor-pos)
    (goto-char (point-min))
    (forward-line (+ (evil-ghostel--scrollback-lines) (cdr ghostel--cursor-pos)))
    (move-to-column (car ghostel--cursor-pos))))

(defun evil-ghostel--point-viewport-row ()
  "Return the viewport row of point, 0-indexed, or nil.
Comparable to `ghostel--cursor-pos''s row."
  (when ghostel--term-rows
    (- (line-number-at-pos (point) t) 1 (evil-ghostel--scrollback-lines))))

(defun evil-ghostel--following-window-p ()
  "Return non-nil when the buffer's window follows the live output.
No window showing the buffer counts as following."
  (let ((win (get-buffer-window (current-buffer) t)))
    (or (null win) (ghostel--window-anchored-p win))))

;; Redraw: preserve Evil point/visual semantics.  Point follows the
;; cursor in insert/emacs state; in normal/motion state it follows
;; exactly while parked at the cursor, and row-wise (keeping the user's
;; column) while elsewhere on the cursor's row.  Off that row point
;; stays put.  Visual markers are restored around the redraw.

(defun evil-ghostel--around-redraw (orig-fn term &optional full force-sync)
  "Apply Evil point/visual handling around `ghostel--redraw'.
ORIG-FN is the advised function (TERM, FULL, FORCE-SYNC).  Skipped in
alt-screen (1049) and when the native renderer defers synchronized output."
  (if (and evil-ghostel-mode
           (not (ghostel--mode-enabled term 1049)))
      (let* ((visual-p (eq evil-state 'visual))
             ;; Sampled pre-render (window check included): only then does
             ;; point on the cursor's row mean the user has not left the
             ;; prompt; the render advances the cursor and a burst
             ;; un-anchors the window.
             (on-row (and (memq evil-state '(normal motion))
                          (eq ghostel--input-mode 'semi-char)
                          ghostel--cursor-char-pos
                          (= (line-beginning-position)
                             (save-excursion
                               (goto-char ghostel--cursor-char-pos)
                               (line-beginning-position)))
                          (evil-ghostel--following-window-p)))
             (tracked (and on-row (= (point) ghostel--cursor-char-pos)))
             (saved-col (and on-row (not tracked) (current-column)))
             (saved-vb (and visual-p (bound-and-true-p evil-visual-beginning)
                            (marker-position evil-visual-beginning)))
             (saved-ve (and visual-p (bound-and-true-p evil-visual-end)
                            (marker-position evil-visual-end)))
             (rendered (funcall orig-fn term full force-sync)))
        (when rendered
          (cond
           ;; Exact target; column geometry can diverge on wide glyphs.
           (tracked
            (when ghostel--cursor-char-pos
              (goto-char ghostel--cursor-char-pos)))
           ;; Roamed within the cursor's row: follow the row, keep the column.
           (saved-col
            (when ghostel--cursor-char-pos
              (goto-char ghostel--cursor-char-pos)
              (move-to-column saved-col)))
           ;; Don't drag point to the cursor while the user reads scrollback;
           ;; redisplay would yank the viewport back to the bottom each frame.
           ((and (memq evil-state '(insert emacs))
                 (evil-ghostel--following-window-p))
            (evil-ghostel--reset-cursor-point)))
          (when visual-p
            (let ((pmax (point-max)))
              (when saved-vb
                (set-marker evil-visual-beginning (min saved-vb pmax)))
              (when saved-ve
                (set-marker evil-visual-end (min saved-ve pmax))))))
        rendered)
    (funcall orig-fn term full force-sync)))

(defun evil-ghostel--anchor-inhibit (_window force)
  "Veto ghostel's redraw anchor while point roams off the live cursor.
A `ghostel-inhibit-anchor-functions' entry: returns non-nil in a motion-capable
evil state with point off the cursor, unless FORCE."
  (and (not force)
       (evil-ghostel--active-p)
       (memq evil-state '(normal visual operator motion))
       ghostel--cursor-char-pos
       (/= (point) ghostel--cursor-char-pos)))

;; Cursor style: let evil control cursor shape

(defun evil-ghostel--override-cursor-style (orig-fn)
  "Let evil control cursor shape instead of the terminal.
ORIG-FN is the advised setter (STYLE, VISIBLE); deferred to in alt-screen."
  (if (and evil-ghostel-mode
           ghostel--term
           (not (ghostel--mode-enabled ghostel--term 1049)))
      ;; Evil owns the cursor now; end any terminal-driven blink that a
      ;; full-screen app left running before we exited the alt-screen.
      (progn (ghostel--cursor-blink-stop)
             (evil-refresh-cursor))
    (funcall orig-fn)))


;; Evil state hooks

(defun evil-ghostel--insert-state-entry ()
  "Drive the terminal cursor to point on insert/emacs entry (safety net).
On a different row, snap point back to the cursor instead — up/down arrows
would be read as shell history navigation."
  (when (and (derived-mode-p 'ghostel-mode)
             (evil-ghostel--active-p))
    (let ((trow (cdr ghostel--cursor-pos))
          (erow (or (evil-ghostel--point-viewport-row) 0)))
      (if (= erow trow)
          (evil-ghostel-goto-input-position (point))
        (evil-ghostel--reset-cursor-point)))))

(defun evil-ghostel--escape-stay ()
  "Disable `evil-move-cursor-back': moving back on ESC desyncs point."
  (setq-local evil-move-cursor-back nil))


;; Input region: boundaries on the cursor row.  ghostel core provides the
;; prompt boundary (`ghostel-input-start-point'); we add the right edge.

(defun evil-ghostel--fg-color (pos)
  "Return the foreground color string of the cell at POS, or nil.
The renderer stores each cell's color as a `face' plist `:foreground'."
  (let ((face (get-text-property pos 'face)))
    (cond ((and (consp face) (plist-member face :foreground))
           (plist-get face :foreground))
          ((facep face) (face-foreground face nil t)))))

(defun evil-ghostel--greyed-out-p (color)
  "Non-nil when COLOR (a hex string) is a dim, desaturated suggestion grey.
Dim plus low-saturation is what separates a suggestion from a saturated
syntax-highlight color (a cyan argument, a red invalid command)."
  (let ((rgb (and (stringp color) (ignore-errors (color-values color)))))
    (when rgb                              ; color-values channels are 0-65535
      (let ((mx (apply #'max rgb))
            (mn (apply #'min rgb)))
        (and (< mx 49152)                  ; dim: not bright
             (< (- mx mn) 13107))))))      ; grey: low saturation

(defun evil-ghostel--suggestion-p (cursor region-end)
  "Non-nil when [CURSOR, REGION-END) looks like an autosuggestion.
That is a single greyed-out color run to the region end, past typed input.
Keys on `evil-ghostel--greyed-out-p', not luminance or color difference,
which misfire under syntax highlighting (see comments below)."
  (and (evil-ghostel--input-start)            ; typed input precedes the cursor
       (< cursor region-end)                  ; a trailing run exists
       (let ((typed (evil-ghostel--fg-color (1- cursor)))
             (trail (evil-ghostel--fg-color cursor)))
         (and trail
              (not (equal trail typed))       ; trailing color differs from typed
              (evil-ghostel--greyed-out-p trail) ; …and is a greyed-out color
              ;; …uniform all the way to the end of the region:
              (>= (or (next-single-property-change cursor 'face nil region-end)
                      region-end)
                  region-end)))))

(defun evil-ghostel--input-end ()
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
               (evil-ghostel--suggestion-p cursor region-end))
          cursor)
         (region-end)
         ;; No `ghostel-input' region: strip renderer padding back from
         ;; EOL, but never past the live cursor — on an empty prompt that
         ;; would strip the prompt's trailing space and land A / $ / the
         ;; operator clamp inside the prompt.
         (t (goto-char eol)
            (skip-chars-backward " \t" bol)
            (max (point) cursor)))))))

(defun evil-ghostel--input-start ()
  "Return the prompt boundary on the cursor row, or nil if undetected.
Unlike `ghostel-input-start-point', returns nil (not the cursor) when no
prompt is recognized, so an operator's BEG stays unclamped rather than
collapsing the range — vterm's behaviour for shells without prompt tracking."
  (let ((s (ghostel-input-start-point)))
    (and s ghostel--cursor-char-pos (< s ghostel--cursor-char-pos) s)))

(defun evil-ghostel--clamp (beg end)
  "Clamp BEG..END to the editable input region; return a (BEG . END) cons.
BEG is raised to `evil-ghostel--input-start', END lowered to
`evil-ghostel--input-end', so motion overshoot (e.g. `dw' on the last
word) can't over-delete past the live input.  END is never below BEG."
  (let* ((start (evil-ghostel--input-start))
         (input-end (evil-ghostel--input-end))
         (beg (or beg (point)))
         (end (or end beg))
         (b (if start (max beg start) beg))
         (e (if input-end (min end input-end) end)))
    (cons b (max b e))))


;; PTY-driven input editing.  Drive the shell's line editor (readline /
;; zle / prompt_toolkit) with arrow keys, backspaces, and bracketed paste
;; over the PTY.  Only meaningful in semi-char input mode.

(defun evil-ghostel--sync-render ()
  "Drain pending PTY output so cursor state reflects the latest echo.
Loops `accept-process-output' (capped by
`evil-ghostel-sync-render-max-iterations'), then flushes any deferred redraw."
  (when (and ghostel--process (process-live-p ghostel--process))
    (let ((iter 0))
      (while (and (< iter evil-ghostel-sync-render-max-iterations)
                  (accept-process-output ghostel--process 0.05 nil t))
        (setq iter (1+ iter))))
    (when ghostel--redraw-timer
      (ghostel--redraw-now (current-buffer)))))

(defun evil-ghostel-goto-input-position (pos)
  "Drive the terminal cursor and Emacs point to buffer position POS.
On the cursor row a rightward target is clamped to `evil-ghostel--input-end',
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
        (setq pos (min pos (or (evil-ghostel--input-end) pos))))
      (let ((dx (- (save-excursion (goto-char pos) (current-column)) start-col)))
        (cond ((> dy 0) (dotimes (_ dy) (ghostel--send-encoded "down" "")))
              ((< dy 0) (dotimes (_ (abs dy)) (ghostel--send-encoded "up" ""))))
        (cond ((> dx 0) (dotimes (_ dx) (ghostel--send-encoded "right" "")))
              ((< dx 0) (dotimes (_ (abs dx)) (ghostel--send-encoded "left" ""))))
        (when (or (/= dx 0) (/= dy 0))
          (evil-ghostel--sync-render))
        (goto-char pos)
        t))))

(defun evil-ghostel-delete-input-region (beg end)
  "Delete BEG..END from input by backspacing over the PTY; return the count.
Soft-wrap newlines are skipped (renderer artifacts).  Leaves point at BEG;
the delete lands when the shell echoes it.  Semi-char only."
  (let ((count (length (ghostel--filter-soft-wraps (buffer-substring beg end)))))
    (when (> count 0)
      (evil-ghostel-goto-input-position end)
      (dotimes (_ count)
        (ghostel--send-encoded "backspace" ""))
      ;; Keep cursor state current for commands that continue editing.
      (evil-ghostel--sync-render)
      (goto-char beg))
    count))

(defun evil-ghostel-replace-input-region (beg end string)
  "Replace the BEG..END range with STRING via the terminal PTY.
Deletes the range with `evil-ghostel-delete-input-region', then pastes
STRING through bracketed paste.  Only meaningful in `semi-char' mode."
  (let ((deleted (evil-ghostel-delete-input-region beg end)))
    (when (and (> deleted 0) string (not (string-empty-p string)))
      (ghostel--paste-text string))
    deleted))


;; Motions (the few that must be prompt-aware)

(evil-define-motion evil-ghostel-first-non-blank ()
  "Move to the first input character after the prompt."
  :type exclusive
  (if (or (evil-ghostel--active-p)
          (evil-ghostel--line-mode-active-p))
      (ghostel-beginning-of-input-or-line)
    (evil-first-non-blank)))

(evil-define-motion evil-ghostel-end-of-line (count)
  "Move to the last character of typed input on the cursor row.
Like `evil-end-of-line' but stops before a trailing autosuggestion,
right-aligned prompt, or padding (ghostel paints the whole row, so vanilla
$ would walk into non-typed cells).  Off the cursor row, unchanged."
  :type inclusive
  (let ((input-end (and (evil-ghostel--active-p)
                        (ghostel-point-on-cursor-row-p)
                        (evil-ghostel--input-end))))
    (evil-end-of-line count)
    (when (and input-end (>= (point) input-end)
               (ghostel-point-on-cursor-row-p)
               (> input-end (line-beginning-position)))
      (goto-char (1- input-end)))))

(evil-define-motion evil-ghostel-next-line (count)
  "Move COUNT lines down, but not past the terminal cursor's row."
  :type line
  (if (not (evil-ghostel--active-p))
      (evil-next-line count)
    (let ((cursor-line (and ghostel--cursor-pos
                            (save-excursion
                              (evil-ghostel--reset-cursor-point)
                              (1- (line-number-at-pos (point) t)))))
          (col (current-column)))
      (condition-case _err
          (evil-next-line count)
        ((beginning-of-buffer end-of-buffer) nil))
      (when (and cursor-line
                 (> (1- (line-number-at-pos (point) t)) cursor-line))
        (goto-char (point-min))
        (forward-line cursor-line)
        (move-to-column col)))))

(evil-define-motion evil-ghostel-goto-cursor (count)
  "Move point to the live terminal cursor, or `evil-goto-line' when inactive."
  ;; A motion, not a plain command: `:keep-visual t' stops evil's line-visual
  ;; expand/contract from reverting the jumped point.
  :type line
  :jump t
  (if (evil-ghostel--active-p)
      (evil-ghostel--reset-cursor-point)
    (evil-goto-line count)))


;; Insert / Append

(defun evil-ghostel-insert ()
  "Enter insert state at point, driving the shell cursor to match."
  (interactive)
  (cond
   ((not (evil-ghostel--active-p))
    (call-interactively #'evil-insert))
   ((not (ghostel-point-on-cursor-row-p))
    (when-let* ((target (ghostel-input-start-point)))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))
   (t
    (let* ((input-end (evil-ghostel--input-end))
           (target (if input-end (min (point) input-end) (point))))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))))

(defun evil-ghostel-insert-line ()
  "Move to the start of input on the current line, then enter insert."
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
  "Append after point, driving the shell cursor to match."
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
              (let ((input-end (evil-ghostel--input-end)))
                (min (1+ (point)) (or input-end (1+ (point))))))))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))))

(defun evil-ghostel-append-line ()
  "Move to the end of input on the current line, then enter insert."
  (interactive)
  (cond
   ((evil-ghostel--active-p)
    (when-let* ((target (evil-ghostel--input-end)))
      (evil-ghostel-goto-input-position target))
    (evil-insert-state 1))
   ((evil-ghostel--line-mode-active-p)
    (goto-char (marker-position ghostel--line-input-end))
    (evil-insert-state 1))
   (t (call-interactively #'evil-append-line))))


;; Delete

(evil-define-operator evil-ghostel-delete
  (beg end type register yank-handler)
  "Delete BEG..END through the terminal when editing live input.
Ranges are limited to the current input, including per-row handling for
block deletes.  Covers d, dd, x, and X."
  (interactive "<R><x><y>")
  (if (not (evil-ghostel--active-p))
      (evil-delete beg end type register yank-handler)
    (let* ((clamped (evil-ghostel--clamp beg end))
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
       (t (evil-ghostel-delete-input-region beg end))))))

(evil-define-operator evil-ghostel-delete-line
  (beg end type register yank-handler)
  "Delete from point through end of line, PTY-routed in semi-char.
In visual state the range is expanded linewise (like `evil-delete-line');
otherwise routes through `evil-ghostel-delete' with END at line end.
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
PTY-routed in semi-char, else `evil-change'.  `evil-ghostel-insert'
drives the cursor itself, so empty ranges need no extra sync.
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

;; Mark our change operator as a change so `cw' / `cW' stop at the end of
;; the word (vim's quirk) like `ce' / `cE', instead of eating the trailing
;; space like `dw'.
(add-to-list 'evil-change-commands 'evil-ghostel-change)


;; Replace

(evil-define-operator evil-ghostel-replace (beg end type char)
  "Replace BEG..END with CHAR via the PTY.  Covers r.
Reads CHAR with `evil-read-key' like `evil-replace', then deletes the
clamped range and pastes the replacement so the count matches."
  :motion evil-forward-char
  (interactive "<R>"
               (unwind-protect
                   (let ((evil-force-cursor 'replace))
                     (evil-refresh-cursor)
                     (list (evil-read-key)))
                 (evil-refresh-cursor)))
  (if (not (evil-ghostel--active-p))
      (evil-replace beg end type char)
    (when char
      (let* ((clamped (evil-ghostel--clamp beg end))
             (b (car clamped))
             (e (cdr clamped))
             (count (length (ghostel--filter-soft-wraps (buffer-substring b e)))))
        (when (> count 0)
          (evil-ghostel-replace-input-region b e (make-string count char)))))))


;; Paste

(defun evil-ghostel--do-paste (count register advance)
  "Bracketed-paste the register/kill text COUNT times at the cursor.
REGISTER selects the source register (nil = latest kill).  With ADVANCE,
send one right arrow first so the paste lands after the cursor cell —
unless at end-of-input, where a right arrow would accept a suggestion."
  (let ((text (if register (evil-get-register register) (current-kill 0)))
        (n (prefix-numeric-value count)))
    (when text
      (evil-ghostel-goto-input-position (point))
      (when advance
        (let ((ie (evil-ghostel--input-end)))
          (unless (and ie (>= (point) ie))
            (ghostel--send-encoded "right" ""))))
      (dotimes (_ n)
        (ghostel--paste-text text)))))

(defun evil-ghostel-paste-after (&optional count register yank-handler)
  "Paste after the cursor via bracketed paste COUNT times from REGISTER.
YANK-HANDLER is used by Evil outside live terminal input.  Covers p."
  (interactive "P")
  (if (evil-ghostel--active-p)
      (evil-ghostel--do-paste count register t)
    (evil-paste-after count register yank-handler)))

(defun evil-ghostel-paste-before (&optional count register yank-handler)
  "Paste before the cursor via bracketed paste COUNT times from REGISTER.
YANK-HANDLER is used by Evil outside live terminal input.  Covers P."
  (interactive "P")
  (if (evil-ghostel--active-p)
      (evil-ghostel--do-paste count register nil)
    (evil-paste-before count register yank-handler)))


;; Undo / Redo

(defun evil-ghostel-undo (count)
  "Send Ctrl-_ (readline undo) COUNT times.  Covers u."
  (interactive "p")
  (if (not (evil-ghostel--active-p))
      (evil-undo count)
    (dotimes (_ (or count 1))
      (ghostel--send-encoded "_" "ctrl"))))

(defun evil-ghostel-redo (count)
  "Run Evil redo COUNT times when not editing live terminal input."
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
These have standard readline/zle bindings that evil's insert-state commands
would otherwise shadow.  Mirrors vterm's set but leaves `C-z' to evil,
keeping `evil-emacs-state' reachable.")

(defun evil-ghostel--fallback-key (keys)
  "Run KEYS's binding from the local map, else evil's insert-state map.
Lets line mode's own bindings win over evil's insert-state defaults when
PTY passthrough is inactive.  KEYS is a key vector."
  (let* ((local (current-local-map))
         (cmd (or (and local (lookup-key local keys))
                  (lookup-key evil-insert-state-map keys))))
    (when (commandp cmd)
      (call-interactively cmd))))

(defun evil-ghostel--passthrough-ctrl (key)
  "Send Ctrl+KEY to the terminal PTY, else fall back to evil's binding.
Off semi-char the local map wins first, so line mode's own \\`C-a' →
`ghostel-beginning-of-input-or-line' beats evil's default."
  (if (evil-ghostel--ctrl-passthrough-active-p)
      (ghostel--send-encoded key "ctrl")
    (evil-ghostel--fallback-key (kbd (concat "C-" key)))))

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
  "Forward-delete in the terminal in semi-char, else fall back to evil.
Evil binds the delete key to `delete-char', which would edit buffer text
rather than forward-delete in the shell."
  (interactive)
  (if (evil-ghostel--ctrl-passthrough-active-p)
      (ghostel--send-encoded "delete" "")
    (evil-ghostel--fallback-key (kbd "<delete>"))))

(evil-define-key* 'insert evil-ghostel-mode-map
                  (kbd "<delete>") #'evil-ghostel--passthrough-delete)

;; Editing operators in normal + visual.  Bindings remap the evil-* command
;; (not literal keys) so user remappings flow through to our PTY variants.
;; Basic motions (h l w b e $ 0) stay vanilla Evil; the operators clamp
;; their range via `evil-ghostel--clamp', trimming overshoot at the operator.
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
                  [remap evil-append-line]          #'evil-ghostel-append-line
                  [remap evil-next-line]            #'evil-ghostel-next-line
                  [remap evil-goto-line]            #'evil-ghostel-goto-cursor
                  "[["                              #'ghostel-previous-prompt
                  "]]"                              #'ghostel-next-prompt)

;; `^' and `$' are the input-aware edges of the line, reachable in every
;; state that can take a motion so `d^' / `d$' and visual `^' / `$' stop
;; at the input boundaries too.  Other basic motions stay vanilla Evil.
(evil-define-key* '(normal visual operator motion) evil-ghostel-mode-map
                  [remap evil-first-non-blank]      #'evil-ghostel-first-non-blank
                  [remap evil-end-of-line]          #'evil-ghostel-end-of-line)


;; ESC routing: terminal vs evil

(defvar-local evil-ghostel--escape-mode nil
  "Buffer-local override for ESC routing.
Initialized from `evil-ghostel-escape' when the minor mode turns on.
Valid values: `auto', `terminal', `evil'.")

(defconst evil-ghostel--escape-modes '(auto terminal evil)
  "Cycle order for `evil-ghostel-toggle-send-escape'.")

(defun evil-ghostel--escape ()
  "Dispatch insert-state ESC based on `evil-ghostel--escape-mode'.
Terminal-bound ESC runs through `ghostel--on-user-input'.  Falling back to
evil uses `evil-force-normal-state' when the `evil-insert-state-map'
binding is missing or a chord prefix (e.g. `evil-escape''s `jk'), so the
keystroke is never dropped."
  (interactive)
  (let* ((mode evil-ghostel--escape-mode)
         (to-terminal (or (eq mode 'terminal)
                          (and (eq mode 'auto)
                               ghostel--term
                               (ghostel--mode-enabled ghostel--term 1049)))))
    (if to-terminal
        (progn
          (ghostel--on-user-input)
          (ghostel--send-encoded "escape" ""))
      (let ((cmd (lookup-key evil-insert-state-map (kbd "<escape>"))))
        (call-interactively (if (commandp cmd) cmd #'evil-force-normal-state))))))

(defun evil-ghostel-toggle-send-escape (&optional arg)
  "Cycle or set the ESC routing mode for the current buffer.
Without ARG, cycle `auto' → `terminal' → `evil'.  With numeric prefix 1/2/3
set `auto'/`terminal'/`evil'; other prefixes signal a `user-error'.  The
mode is buffer-local; see `evil-ghostel-escape' for the default."
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
  "Return non-nil if any buffer but EXCEPT-BUFFER has `evil-ghostel-mode' on.
Decides whether the global advice can be removed on the last disable."
  (catch 'found
    (dolist (b (buffer-list))
      (when (and (not (eq b except-buffer))
                 (buffer-local-value 'evil-ghostel-mode b))
        (throw 'found t)))))

;;;###autoload
(define-minor-mode evil-ghostel-mode
  "Minor mode for Evil integration in ghostel terminal buffers.
Binds Evil operators to terminal-aware variants and keeps point aligned
with the terminal cursor across Evil state transitions.

Enabling installs global advice while any buffer has the mode enabled."
  :lighter nil
  :keymap evil-ghostel-mode-map
  (if evil-ghostel-mode
      (progn
        (setq evil-ghostel--escape-mode evil-ghostel-escape)
        (evil-ghostel--escape-stay)
        ;; Evil owns selection here (visual state + the visual operators), so
        ;; opt this buffer out of ghostel's keyboard-mark->copy-mode switch:
        ;; otherwise `v' activates the mark and `ghostel--mark-activated' flips
        ;; the buffer to copy mode before Evil's terminal-aware operators run.
        ;; Mouse selection stays governed by `ghostel-mouse-drag-input-mode',
        ;; so it still picks its own mode.
        (setq-local ghostel-mark-activation-input-mode nil)
        (add-hook 'evil-insert-state-entry-hook
                  #'evil-ghostel--insert-state-entry nil t)
        ;; Reuse the insert-state sync when entering emacs-state — both
        ;; states expect point to follow the terminal cursor.
        (add-hook 'evil-emacs-state-entry-hook
                  #'evil-ghostel--insert-state-entry nil t)
        ;; Let normal/visual/operator/motion-state navigation roam point off
        ;; the live cursor without the per-redraw anchor snapping it back.
        (add-hook 'ghostel-inhibit-anchor-functions
                  #'evil-ghostel--anchor-inhibit nil t)
        (advice-add 'ghostel--redraw :around #'evil-ghostel--around-redraw)
        (advice-add 'ghostel--apply-cursor-style :around
                    #'evil-ghostel--override-cursor-style)
        (evil-refresh-cursor))
    (remove-hook 'evil-insert-state-entry-hook
                 #'evil-ghostel--insert-state-entry t)
    (remove-hook 'evil-emacs-state-entry-hook
                 #'evil-ghostel--insert-state-entry t)
    (remove-hook 'ghostel-inhibit-anchor-functions
                 #'evil-ghostel--anchor-inhibit t)
    (kill-local-variable 'ghostel-mark-activation-input-mode)
    (unless (evil-ghostel--any-active-elsewhere-p (current-buffer))
      (advice-remove 'ghostel--redraw #'evil-ghostel--around-redraw)
      (advice-remove 'ghostel--apply-cursor-style
                     #'evil-ghostel--override-cursor-style))))

(provide 'evil-ghostel)
;;; evil-ghostel.el ends here
