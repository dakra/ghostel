;;; evil-ghostel.el --- Evil-mode integration for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.23.0
;; Package-Requires: ((emacs "28.1") (evil "1.0") (ghostel "0.8.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Provides evil-mode compatibility for the ghostel terminal emulator.
;; Synchronizes the terminal cursor with Emacs point during evil state
;; transitions so that normal-mode navigation works correctly.
;;
;; Enable by adding to your init:
;;
;;   (use-package evil-ghostel
;;     :after (ghostel evil)
;;     :hook (ghostel-mode . evil-ghostel-mode))

;;; Code:

(require 'evil)
(require 'ghostel)

(declare-function ghostel--cursor-position "ghostel-module")
(declare-function ghostel--mode-enabled "ghostel-module")

(defvar evil-ghostel-mode)

;; ---------------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------------

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

;; Apply the current value at load.  Covers the case where the user set
;; the variable with plain `setq' before loading the package — in that
;; path `defcustom' preserves the value without invoking `:set'.
(evil-set-initial-state 'ghostel-mode evil-ghostel-initial-state)

;; ---------------------------------------------------------------------------
;; Guard predicate
;; ---------------------------------------------------------------------------

(defun evil-ghostel--active-p ()
  "Return non-nil when evil-ghostel editing should intercept."
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

;; ---------------------------------------------------------------------------
;; Cursor synchronization
;; ---------------------------------------------------------------------------

(defun evil-ghostel--reset-cursor-point ()
  "Move Emacs point to the terminal cursor position.
`ghostel--cursor-position' returns row relative to the viewport
\(the last `ghostel--term-rows' lines of the buffer), so the row
must be offset by the scrollback line count.  Mirrors the
placement math the native module performs in `src/render.zig'."
  (when (and ghostel--term ghostel--term-rows)
    (let ((pos (ghostel--cursor-position ghostel--term)))
      (when pos
        (let ((scrollback (max 0 (- (count-lines (point-min) (point-max))
                                    ghostel--term-rows))))
          (goto-char (point-min))
          (forward-line (+ scrollback (cdr pos)))
          (move-to-column (car pos)))))))

(defun evil-ghostel--cursor-buffer-line ()
  "Return the 0-indexed buffer line of the terminal cursor, or nil.
Translates `ghostel--cursor-position' (viewport-relative row) into a
buffer line by adding the scrollback line count.  Mirrors the
placement math the native module performs in `src/render.zig'."
  (when (and ghostel--term ghostel--term-rows)
    (let ((pos (ghostel--cursor-position ghostel--term)))
      (when pos
        (let ((scrollback (max 0 (- (count-lines (point-min) (point-max))
                                    ghostel--term-rows))))
          (+ scrollback (cdr pos)))))))

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
Used by `evil-ghostel--around-redraw' to decide whether the user has
navigated point since the last redraw.  When point is still on this
line, the user is parked at the live prompt and the renderer's new
cursor placement should win across the redraw.")

(defun evil-ghostel--cursor-to-point ()
  "Move the terminal cursor to Emacs point by sending arrow keys."
  (when ghostel--term
    (let* ((tpos (ghostel--cursor-position ghostel--term))
           (tcol (car tpos))
           (trow (cdr tpos))
           (ecol (current-column))
           (erow (- (line-number-at-pos (point) t) 1))
           (dy (- erow trow))
           (dx (- ecol tcol)))
      (cond ((> dy 0) (dotimes (_ dy) (ghostel--send-encoded "down" "")))
            ((< dy 0) (dotimes (_ (abs dy)) (ghostel--send-encoded "up" ""))))
      (cond ((> dx 0) (dotimes (_ dx) (ghostel--send-encoded "right" "")))
            ((< dx 0) (dotimes (_ (abs dx)) (ghostel--send-encoded "left" "")))))))

;; ---------------------------------------------------------------------------
;; Redraw: preserve point and evil visual markers across the native call
;; ---------------------------------------------------------------------------

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
    the user was parked on the prompt line before the redraw - the
    renderer leaves point at the new cursor and we keep it there.
    Otherwise the saved buffer position is restored so scrollback
    navigation is undisturbed.
  - `evil-visual-beginning' and `evil-visual-end' in `visual' state.

ORIG-FN is the advised `ghostel--redraw' called with TERM and FULL.
Skipped when the terminal is in alt-screen mode (1049); apps there
own the screen and drive their own redraw cycle."
  (if (and evil-ghostel-mode
           (not (ghostel--mode-enabled term 1049)))
      (let* ((preserve-point (not (memq evil-state '(insert emacs))))
             (visual-p (eq evil-state 'visual))
             (saved-point (and preserve-point (point)))
             ;; If point is still on the line where the previous redraw
             ;; placed the terminal cursor, the user has not navigated
             ;; since — they are parked on the live prompt and the new
             ;; cursor placement should win.  We can't reuse
             ;; `evil-ghostel--point-on-cursor-line-p' here because the
             ;; libghostty cursor has already advanced past output that
             ;; the buffer hasn't rendered yet; comparing against the
             ;; recorded last-cursor-line avoids that skew.  Skipped in
             ;; visual state to keep selection markers stable.
             (on-prompt-line (and preserve-point
                                  (not visual-p)
                                  evil-ghostel--last-cursor-line
                                  (= (- (line-number-at-pos (point) t) 1)
                                     evil-ghostel--last-cursor-line)))
             (saved-vb (and visual-p (bound-and-true-p evil-visual-beginning)
                            (marker-position evil-visual-beginning)))
             (saved-ve (and visual-p (bound-and-true-p evil-visual-end)
                            (marker-position evil-visual-end))))
        (funcall orig-fn term full)
        (when (and preserve-point (not on-prompt-line))
          (goto-char (min saved-point (point-max))))
        (when visual-p
          (let ((pmax (point-max)))
            (when saved-vb
              (set-marker evil-visual-beginning (min saved-vb pmax)))
            (when saved-ve
              (set-marker evil-visual-end (min saved-ve pmax)))))
        ;; Record where the renderer placed the cursor so the next
        ;; redraw can detect whether the user has navigated away.
        (setq evil-ghostel--last-cursor-line
              (evil-ghostel--cursor-buffer-line)))
    (funcall orig-fn term full)))

;; ---------------------------------------------------------------------------
;; Cursor style: let evil control cursor shape
;; ---------------------------------------------------------------------------

(defun evil-ghostel--override-cursor-style (orig-fn style visible)
  "Let evil control cursor shape instead of the terminal.
ORIG-FN is the advised setter called with STYLE and VISIBLE.
In alt-screen mode, defer to the terminal's cursor style."
  (if (and evil-ghostel-mode
           ghostel--term
           (not (ghostel--mode-enabled ghostel--term 1049)))
      (evil-refresh-cursor)
    (funcall orig-fn style visible)))

;; ---------------------------------------------------------------------------
;; Evil state hooks
;; ---------------------------------------------------------------------------

(defvar evil-ghostel--sync-inhibit nil
  "When non-nil, skip arrow-key sync in the insert-state-entry hook.
Set by the I/A advice which send Home/End directly.")

(defun evil-ghostel--insert-state-entry ()
  "Sync terminal cursor to Emacs point when entering `emacs-state'.
Skipped when `evil-ghostel--sync-inhibit' is set (by I/A advice
which already sent Ctrl-a/Ctrl-e).  Also skipped outside semi-char:
in line mode point and the terminal cursor are intentionally
decoupled (the user is editing buffer text, not driving the shell
cursor); in copy/Emacs/char modes the sync would either fight a
read-only buffer or be redundant.
When point is on a different row from the terminal cursor, snap
back to the terminal cursor instead of sending up/down arrows
which the shell would interpret as history navigation."
  (when (derived-mode-p 'ghostel-mode)
    (if evil-ghostel--sync-inhibit
        (setq evil-ghostel--sync-inhibit nil)
      (when (evil-ghostel--active-p)
        (let* ((tpos (ghostel--cursor-position ghostel--term))
               (trow (cdr tpos))
               (erow (- (line-number-at-pos (point) t) 1)))
          (if (= erow trow)
              (evil-ghostel--cursor-to-point)
            (evil-ghostel--reset-cursor-point)))))))

(defun evil-ghostel--escape-stay ()
  "Disable `evil-move-cursor-back' in ghostel buffers.
Moving the cursor back on ESC desynchronizes point from the terminal
cursor."
  (setq-local evil-move-cursor-back nil))

;; ---------------------------------------------------------------------------
;; Advice for evil insert-line / append-line
;; ---------------------------------------------------------------------------

(defun evil-ghostel--around-insert-line (orig-fn &rest args)
  "Route `evil-insert-line' according to the current input mode.
ORIG-FN is the advised `evil-insert-line' called with ARGS.
In semi-char, send Ctrl-a so the shell moves its readline cursor
to the start of input — `orig-fn' then enters insert state and the
buffer cursor is repositioned by the next redraw.
In line mode, the input region is plain buffer text bounded by
`ghostel--line-input-start' / `--line-input-end'; jump point there
and enter insert state directly (`back-to-indentation' would land
on the prompt, which is read-only).
Outside ghostel, run unchanged."
  (cond
   ((evil-ghostel--active-p)
    (ghostel--send-encoded "a" "ctrl")
    (setq evil-ghostel--sync-inhibit t)
    (apply orig-fn args))
   ((evil-ghostel--line-mode-active-p)
    (goto-char (marker-position ghostel--line-input-start))
    (setq evil-ghostel--sync-inhibit t)
    (evil-insert-state 1))
   (t (apply orig-fn args))))

(defun evil-ghostel--around-append-line (orig-fn &rest args)
  "Route `evil-append-line' according to the current input mode.
ORIG-FN is the advised `evil-append-line' called with ARGS.
Symmetric to `evil-ghostel--around-insert-line': Ctrl-e in
semi-char, jump to `--line-input-end' in line mode, otherwise
unchanged."
  (cond
   ((evil-ghostel--active-p)
    (ghostel--send-encoded "e" "ctrl")
    (setq evil-ghostel--sync-inhibit t)
    (apply orig-fn args))
   ((evil-ghostel--line-mode-active-p)
    (goto-char (marker-position ghostel--line-input-end))
    (setq evil-ghostel--sync-inhibit t)
    (evil-insert-state 1))
   (t (apply orig-fn args))))

;; ---------------------------------------------------------------------------
;; Editing primitives
;; ---------------------------------------------------------------------------

(defun evil-ghostel--delete-region (beg end)
  "Delete text between BEG and END via the terminal PTY.
Moves terminal cursor to END, then sends backspace keys.
Uses backspace rather than forward-delete because the Delete key
escape sequence is not bound in all shell configurations."
  (let ((count (- end beg)))
    (when (> count 0)
      (goto-char end)
      (evil-ghostel--cursor-to-point)
      (dotimes (_ count)
        (ghostel--send-encoded "backspace" ""))
      (goto-char beg))))

;; ---------------------------------------------------------------------------
;; Advice for evil editing operators
;; ---------------------------------------------------------------------------

(defun evil-ghostel--around-delete
    (orig-fn beg end &optional type register yank-handler)
  "Intercept `evil-delete' in ghostel buffers.
ORIG-FN is the advised `evil-delete' called with BEG, END, TYPE,
REGISTER, and YANK-HANDLER.
Yanks text to REGISTER, then deletes via PTY.
Covers d, dd, D, x, X."
  (if (evil-ghostel--active-p)
      (progn
        (unless register
          (let ((text (filter-buffer-substring beg end)))
            (unless (string-match-p "\n" text)
              (evil-set-register ?- text))))
        (let ((evil-was-yanked-without-register nil))
          (evil-yank beg end type register yank-handler))
        (if (eq type 'line)
            ;; For line-type (dd): clear the input line
            (progn
              (ghostel--send-encoded "e" "ctrl")
              (ghostel--send-encoded "u" "ctrl"))
          (evil-ghostel--delete-region beg end)))
    (funcall orig-fn beg end type register yank-handler)))

(defun evil-ghostel--around-change
    (orig-fn beg end type register yank-handler &optional delete-func)
  "Intercept `evil-change' in ghostel buffers.
ORIG-FN is the advised `evil-change' called with BEG, END, TYPE,
REGISTER, YANK-HANDLER, and DELETE-FUNC.
Deletes via PTY, then enters insert state.
Covers c, cc, C, s, S."
  (if (evil-ghostel--active-p)
      (progn
        (let ((evil-was-yanked-without-register nil))
          (evil-yank beg end type register yank-handler))
        (if (eq type 'line)
            (progn
              (ghostel--send-encoded "e" "ctrl")
              (ghostel--send-encoded "u" "ctrl"))
          (evil-ghostel--delete-region beg end))
        (setq evil-ghostel--sync-inhibit t)
        (evil-insert 1))
    (funcall orig-fn beg end type register yank-handler delete-func)))

(defun evil-ghostel--around-replace (orig-fn beg end type char)
  "Intercept `evil-replace' in ghostel buffers.
ORIG-FN is the advised `evil-replace' called with BEG, END, TYPE,
and CHAR.
Deletes the range, then inserts replacement characters."
  (if (evil-ghostel--active-p)
      (when char
        (let ((count (- end beg)))
          (evil-ghostel--delete-region beg end)
          (ghostel--paste-text (make-string count char))))
    (funcall orig-fn beg end type char)))

(defun evil-ghostel--around-paste-after
    (orig-fn count &optional register yank-handler)
  "Intercept `evil-paste-after' in ghostel buffers.
ORIG-FN is the advised `evil-paste-after' called with COUNT,
REGISTER, and YANK-HANDLER.
Pastes from REGISTER via the terminal PTY."
  (if (evil-ghostel--active-p)
      (let ((text (if register
                      (evil-get-register register)
                    (current-kill 0)))
            (count (prefix-numeric-value count)))
        (when text
          (evil-ghostel--cursor-to-point)
          (ghostel--send-encoded "right" "")
          (dotimes (_ count)
            (ghostel--paste-text text))))
    (funcall orig-fn count register yank-handler)))

(defun evil-ghostel--around-paste-before
    (orig-fn count &optional register yank-handler)
  "Intercept `evil-paste-before' in ghostel buffers.
ORIG-FN is the advised `evil-paste-before' called with COUNT,
REGISTER, and YANK-HANDLER.
Pastes from REGISTER via the terminal PTY."
  (if (evil-ghostel--active-p)
      (let ((text (if register
                      (evil-get-register register)
                    (current-kill 0)))
            (count (prefix-numeric-value count)))
        (when text
          (evil-ghostel--cursor-to-point)
          (dotimes (_ count)
            (ghostel--paste-text text))))
    (funcall orig-fn count register yank-handler)))

;; ---------------------------------------------------------------------------
;; Insert-state Ctrl key passthrough
;; ---------------------------------------------------------------------------

(defvar evil-ghostel-mode-map (make-sparse-keymap)
  "Keymap for `evil-ghostel-mode'.
Insert-state Ctrl key bindings are set up via `evil-define-key*'.")

(defconst evil-ghostel--ctrl-passthrough-keys
  '("a" "d" "e" "k" "n" "p" "r" "t" "u" "w" "y")
  "Ctrl+key combinations to pass through to the terminal in insert state.
These keys all have standard readline/zle bindings (C-a beginning-of-line,
C-d EOF, C-e end-of-line, C-k kill-line, etc.) that would otherwise be
intercepted by evil's insert-state commands.")

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

(defun evil-ghostel--around-undo (orig-fn count)
  "Intercept `evil-undo' in ghostel buffers.
ORIG-FN is the advised `evil-undo' called with COUNT.
Sends Ctrl+_ (readline undo) COUNT times."
  (if (evil-ghostel--active-p)
      (dotimes (_ (or count 1))
        (ghostel--send-encoded "_" "ctrl"))
    (funcall orig-fn count)))

(defun evil-ghostel--around-redo (orig-fn count)
  "Intercept `evil-redo' in ghostel buffers.
ORIG-FN is the advised `evil-redo' called with COUNT."
  (if (evil-ghostel--active-p)
      (message "Redo not supported in terminal")
    (funcall orig-fn count)))

;; ---------------------------------------------------------------------------
;; ESC routing: terminal vs evil
;; ---------------------------------------------------------------------------

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

;; ---------------------------------------------------------------------------
;; Minor mode
;; ---------------------------------------------------------------------------

;;;###autoload
(define-minor-mode evil-ghostel-mode
  "Minor mode for evil integration in ghostel terminal buffers.
Synchronizes the terminal cursor with Emacs point during evil
state transitions."
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
        (advice-add 'evil-insert-line :around #'evil-ghostel--around-insert-line)
        (advice-add 'evil-append-line :around #'evil-ghostel--around-append-line)
        (advice-add 'evil-delete :around #'evil-ghostel--around-delete)
        (advice-add 'evil-change :around #'evil-ghostel--around-change)
        (advice-add 'evil-replace :around #'evil-ghostel--around-replace)
        (advice-add 'evil-paste-after :around #'evil-ghostel--around-paste-after)
        (advice-add 'evil-paste-before :around #'evil-ghostel--around-paste-before)
        (advice-add 'evil-undo :around #'evil-ghostel--around-undo)
        (advice-add 'evil-redo :around #'evil-ghostel--around-redo)
        (advice-add 'ghostel--redraw :around #'evil-ghostel--around-redraw)
        (advice-add 'ghostel--set-cursor-style :around
                    #'evil-ghostel--override-cursor-style)
        (evil-refresh-cursor))
    (remove-hook 'evil-insert-state-entry-hook
                 #'evil-ghostel--insert-state-entry t)
    (remove-hook 'evil-emacs-state-entry-hook
                 #'evil-ghostel--insert-state-entry t)
    (advice-remove 'evil-insert-line #'evil-ghostel--around-insert-line)
    (advice-remove 'evil-append-line #'evil-ghostel--around-append-line)
    (advice-remove 'evil-delete #'evil-ghostel--around-delete)
    (advice-remove 'evil-change #'evil-ghostel--around-change)
    (advice-remove 'evil-replace #'evil-ghostel--around-replace)
    (advice-remove 'evil-paste-after #'evil-ghostel--around-paste-after)
    (advice-remove 'evil-paste-before #'evil-ghostel--around-paste-before)
    (advice-remove 'evil-undo #'evil-ghostel--around-undo)
    (advice-remove 'evil-redo #'evil-ghostel--around-redo)
    (advice-remove 'ghostel--redraw #'evil-ghostel--around-redraw)
    (advice-remove 'ghostel--set-cursor-style
                   #'evil-ghostel--override-cursor-style)))

(provide 'evil-ghostel)
;;; evil-ghostel.el ends here
