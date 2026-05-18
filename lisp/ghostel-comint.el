;;; ghostel-comint.el --- Comint + ghostel anchored renderer -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run comint-style programs (shells, REPLs, SQL clients, ...) with
;; ghostel doing the ANSI / cursor-motion / OSC rendering.  Comint keeps
;; ownership of input editing, history, and major-mode integration; the
;; bytes the shell writes back through the PTY are rerouted through a
;; per-command anchored ghostel terminal so they render with full VT
;; semantics — CR overwrite, ANSI colours, OSC titles, OSC 7 cwd, OSC 133
;; prompts, progress bars, the lot.
;;
;; Each user-submitted command gets its own short-lived anchored terminal
;; sitting just below the input line.  When the next command is submitted
;; the previous terminal is retired (its marker pair is removed from
;; `ghostel--anchored-terminals') and its rendered output stays put in
;; the buffer as inert text that comint never re-touches.  `C-s isearch'
;; can find content from 50 commands ago; M-p / M-n step through input
;; history; everything else comint does just works.
;;
;; Entry point:
;;
;;   M-x ghostel-comint
;;
;; This is a prototype.  Things explicitly out of scope for v1: alt-screen
;; programs running inside the comint buffer (`vim', `less', `htop'),
;; kitty graphics, TRAMP / remote processes, custom `comint-prompt-regexp'
;; font-locking inside the anchored region.  Use \\[ghostel] (full-screen
;; ghostel) for those.

;;; Code:

(require 'ghostel)
(require 'comint)

(declare-function ghostel--new-anchored "ghostel-module"
                  (start end rows cols &optional max-scrollback))
(declare-function ghostel--redraw "ghostel-module" (term &optional full))
(declare-function ghostel--write-input "ghostel-module" (term data))
(declare-function ghostel--set-size "ghostel-module"
                  (term rows cols &optional cell-w cell-h))


;;; Customization

(defgroup ghostel-comint nil
  "Run comint programs with ghostel anchored rendering."
  :group 'ghostel)

(defcustom ghostel-comint-program nil
  "Default shell program for `ghostel-comint'.
When nil, falls back to `ghostel-shell' (which itself defaults to
$SHELL).  When non-nil, must be an absolute path to an executable."
  :type '(choice (const :tag "Use `ghostel-shell'" nil)
                 (string :tag "Program path")))

(defcustom ghostel-comint-program-args nil
  "Argument list passed to `ghostel-comint-program'."
  :type '(repeat string))

(defcustom ghostel-comint-buffer-name "*ghostel-comint*"
  "Default buffer name for `ghostel-comint'."
  :type 'string)

(defcustom ghostel-comint-max-scrollback 0
  "MAX-SCROLLBACK passed to each per-command anchored terminal.
The default 0 keeps the active grid bounded — only the most recent
rows of the currently-running command's output are visible inside
its anchored region.  Once the user submits the next command, the
final-frame state of the previous command stays as inert buffer
text and is no longer subject to libghostty's scrollback eviction.

Set to a positive byte count (e.g. (* 64 1024)) to let scrolled-off
rows of the running command materialize into the region — useful
when a single command produces thousands of lines you want to walk
back through *while it's still running*.  Once it finishes, behaviour
is the same either way."
  :type 'integer)

(defcustom ghostel-comint-default-rows 24
  "Fallback row count when no window is displaying the comint buffer.
When a window is displaying the buffer, the active grid uses that
window's row count instead.  Rows past the grid scroll off the
active region; with the default `ghostel-comint-max-scrollback'
of 0, they disappear from the region until the command finishes
\(at which point its final frame stays in the buffer as inert
text)."
  :type 'integer)

(defcustom ghostel-comint-default-cols 80
  "Fallback column count when no window is displaying the comint buffer.
When a window is displaying the buffer, that window's column count
is used instead."
  :type 'integer)

(defcustom ghostel-comint-stty-flags
  (concat ghostel--default-stty " -echo")
  "`stty' flags for the comint PTY.
Layers `-echo' on top of `ghostel--default-stty' so the kernel
discipline doesn't echo back the bytes comint sends — the user's
typed input is already visible as a comint input field, and a
duplicate echo would land in the next anchored region."
  :type 'string)


;;; Buffer-local state

(defvar-local ghostel-comint--term nil
  "Currently-active anchored terminal for this comint buffer.
Allocated lazily on the first output chunk and retired (`remhash'-ed
out of `ghostel--anchored-terminals') when the next user command is
submitted.")

(defvar-local ghostel-comint--cols 80
  "Last-known column width sized into the anchored terminal.
Kept in sync with the displaying window via the
`adjust-window-size-function' process property installed by
`ghostel-comint--spawn'.")

(defvar-local ghostel-comint--rows 24
  "Last-known row count sized into the anchored terminal.
Kept in sync with the displaying window via the
`adjust-window-size-function' process property installed by
`ghostel-comint--spawn'.")


;;; Size helpers

(defun ghostel-comint--window-size (buffer)
  "Return (HEIGHT . WIDTH) sized to a window showing BUFFER.
Searches any frame for a window displaying BUFFER and reads its
dimensions.  Falls back to `ghostel-comint-default-rows' /
`ghostel-comint-default-cols' if no window is displaying the
buffer (e.g. spawned via `emacsclient -e').  Always returns
sensible minimums."
  (let* ((win (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (height (max 4 (if (window-live-p win)
                            (with-selected-window win
                              (floor (window-screen-lines)))
                          ghostel-comint-default-rows)))
         (width (max 20 (if (window-live-p win)
                            (window-max-chars-per-line win)
                          ghostel-comint-default-cols))))
    (cons height width)))


;;; Terminal lifecycle

(defun ghostel-comint--retire-terminal ()
  "Retire the currently-active anchored terminal, if any.
Removes the terminal's marker pair from `ghostel--anchored-terminals'
so the markers can be GC'd, leaving the buffer text rendered by
that terminal in place as inert content.

Safe to call when no terminal is active — does nothing."
  (when (and ghostel-comint--term
             (hash-table-p ghostel--anchored-terminals))
    (remhash ghostel-comint--term ghostel--anchored-terminals))
  (setq ghostel-comint--term nil))

(defun ghostel-comint--make-terminal (proc)
  "Create a fresh anchored terminal at PROC's `process-mark'.
Inserts an empty region (just a newline) at the `process-mark' so the
renderer has a writable span between two markers, then constructs an
anchored terminal sized to the displaying window's rows × columns
\(or the configured fallbacks if no window is displaying the buffer).
Updates the `process-mark' to the end of the newly-created region so
subsequent comint output insertions land inside it."
  (let* ((size (ghostel-comint--window-size (current-buffer)))
         (rows (car size))
         (cols (cdr size))
         (pmark (process-mark proc))
         (start (marker-position pmark))
         (inhibit-read-only t)
         end term)
    (save-excursion
      (goto-char start)
      ;; The anchored renderer needs at least one character between
      ;; start and end so it has somewhere to write the first row.
      ;; A single newline gives us a region we can grow.  Stamp it
      ;; with `field=output' (matching comint's standard markup for
      ;; output text) so `C-a' / `M-a' / `M-e' field-navigation across
      ;; this newline behaves like normal output.
      (insert (propertize "\n" 'field 'output
                          'front-sticky '(field
                                          inhibit-line-move-field-capture)
                          'inhibit-line-move-field-capture t))
      (setq end (point)))
    (setq ghostel-comint--cols cols
          ghostel-comint--rows rows
          term (ghostel--new-anchored start end rows cols
                                      ghostel-comint-max-scrollback)
          ghostel-comint--term term)
    ;; Advance the process-mark past the newly-inserted region so the
    ;; next comint output filter call appends there (where our hook
    ;; will pull it back into the terminal).
    (set-marker pmark end)
    term))

(defun ghostel-comint--ensure-terminal (proc)
  "Return the active anchored terminal for PROC, creating one if needed."
  (or ghostel-comint--term
      (ghostel-comint--make-terminal proc)))


;;; Window resize / SIGWINCH

(defun ghostel-comint--adjust-window-size (process windows)
  "Resize the active anchored terminal and PTY to match the window.
PROCESS is the comint process; WINDOWS is the list of windows
displaying its buffer (passed by Emacs).  Mirrors what
`ghostel--window-adjust-process-window-size' does for `ghostel-mode'.

Returns a (WIDTH . HEIGHT) cons cell so Emacs follows up with a
`set-process-window-size' (SIGWINCH) call, keeping the kernel PTY
size in sync with the rendered grid."
  (let* ((adjust-fn (default-value 'window-adjust-process-window-size-function))
         (adjust-fn (if (and (functionp adjust-fn)
                             (not (eq adjust-fn
                                      #'ghostel-comint--adjust-window-size)))
                        adjust-fn
                      #'window-adjust-process-window-size-smallest))
         (size (funcall adjust-fn process windows))
         (width (car-safe size))
         (height (cdr-safe size))
         (buffer (process-buffer process)))
    (when (and size (buffer-live-p buffer))
      (with-current-buffer buffer
        (let ((height (max 1 height))
              (width (max 1 width)))
          (cond
           ;; No change — skip the terminal resize.
           ((and (eql height ghostel-comint--rows)
                 (eql width ghostel-comint--cols))
            (setq size nil))
           (t
            (setq ghostel-comint--rows height
                  ghostel-comint--cols width)
            (when (and ghostel-comint--term
                       (hash-table-p ghostel--anchored-terminals)
                       (gethash ghostel-comint--term
                                ghostel--anchored-terminals))
              (ghostel--set-size ghostel-comint--term height width)
              ;; Repaint at the new dims so the renderer's cursor
              ;; lands inside the new grid before the next write.
              (ghostel--redraw ghostel-comint--term t)))))))
    ;; Return size — Emacs follows up with `set-process-window-size'
    ;; (SIGWINCH).  nil suppresses that call.
    size))


;;; Output filter integration

(defun ghostel-comint--output-filter (_string)
  "Reroute the just-inserted PTY output through ghostel.
Runs from `comint-output-filter-functions' AFTER comint has inserted
the raw bytes between `comint-last-output-start' and the
`process-mark'.  We capture those bytes, delete the raw region, feed
the bytes to the active anchored terminal, run a synchronous redraw,
then advance the `process-mark' to the new region end so subsequent
insertions land just after the rendered output."
  (let* ((proc (get-buffer-process (current-buffer))))
    (when proc
      (let* ((pmark (process-mark proc))
             (beg (marker-position comint-last-output-start))
             (end (marker-position pmark)))
        (when (and beg end (> end beg))
          (let ((raw (buffer-substring-no-properties beg end))
                (inhibit-read-only t))
            (delete-region beg end)
            ;; Make sure we have a terminal before we feed it bytes.
            ;; The process-mark is wherever comint just put it (now at
            ;; BEG, since we just deleted [BEG, END)).
            (let ((term (ghostel-comint--ensure-terminal proc)))
              (ghostel--write-input term raw)
              (ghostel--redraw term t)
              ;; Advance the process-mark to the end of the anchored
              ;; region so the *next* output chunk lands there too
              ;; (and gets pulled back into the terminal by us on the
              ;; next filter invocation).  Mark the freshly-rendered
              ;; region as comint output so cursor-motion / field
              ;; handling treats it as output rather than input.
              (let* ((pair (gethash term ghostel--anchored-terminals))
                     (start-marker (and pair (car pair)))
                     (end-marker (and pair (cdr pair))))
                (when (and start-marker end-marker)
                  (let ((rend (marker-position end-marker)))
                    (set-marker pmark rend)
                    ;; Mirror what `comint-last-output-start' would have
                    ;; pointed at had comint inserted nothing — pinning
                    ;; it at the new pmark means the next filter call
                    ;; only sees its own freshly-inserted chunk.
                    (set-marker comint-last-output-start rend)
                    (unless comint-use-prompt-regexp
                      (comint--mark-as-output
                       (marker-position start-marker) rend))))))))))))


;;; Input handling

(defun ghostel-comint--input-sender (proc input)
  "Send INPUT to PROC, retiring the previous anchored terminal first.
Each fresh command gets its own anchored terminal placed below the
just-inserted input line.  Retiring the previous one converts that
command's rendered output into inert buffer text that comint never
re-touches.

Building a fresh terminal here — rather than reusing a persistent one
or building it lazily on first output — is what keeps the user's
typed input safe from the renderer.  At this point comint has
already inserted `INPUT\\n' above the `process-mark', so creating a
new terminal anchored at pmark places its writable region strictly
below the user's input."
  (ghostel-comint--retire-terminal)
  (ghostel-comint--make-terminal proc)
  ;; The shell sees the bytes with kernel `-echo' so it doesn't
  ;; double-echo; readline's own line-edit repaint lands in the
  ;; fresh anchored region as part of the next prompt.
  (comint-simple-send proc input))


;;; Process spawning

(defun ghostel-comint--spawn (buffer program program-args)
  "Spawn PROGRAM with PROGRAM-ARGS in BUFFER under a PTY for comint.
Wires up `comint-output-filter' as the process filter so comint's
hook machinery (history, prompt detection, scroll, ...) runs as
usual; our own `ghostel-comint--output-filter' on
`comint-output-filter-functions' takes over from there.

Installs `ghostel-comint--sentinel' for clean exit handling, an
`adjust-window-size-function' process property so SIGWINCH gets
delivered on resize, and sets the buffer-local `ghostel--process'
so terminal-originated writes (DA1/DA2/DA3 replies, XTWINOPS
size reports, OSC 51 clipboard, mouse and focus events) make it
back to the PTY via `ghostel--flush-output'.

Returns the process."
  (let* ((size (ghostel-comint--window-size buffer))
         (height (car size))
         (width (cdr size))
         (wrapper
          (list "/bin/sh" "-c"
                (concat
                 "stty " ghostel-comint-stty-flags
                 (format " rows %d columns %d" height width)
                 " 2>/dev/null; "
                 "exec "
                 (shell-quote-argument program)
                 (and program-args
                      (concat " "
                              (mapconcat #'shell-quote-argument
                                         program-args " "))))))
         (process-environment
          (append ghostel-environment
                  (list "INSIDE_EMACS=ghostel,comint")
                  (ghostel--terminal-env)
                  (list (format "COLUMNS=%d" width)
                        (format "LINES=%d" height))
                  process-environment))
         (process-adaptive-read-buffering nil)
         (read-process-output-max (max read-process-output-max
                                       (* 1024 1024)))
         (proc (make-process
                :name "ghostel-comint"
                :buffer buffer
                :command wrapper
                :connection-type 'pty
                :coding 'no-conversion
                :filter #'comint-output-filter
                :sentinel #'ghostel-comint--sentinel)))
    (set-process-coding-system proc 'binary 'binary)
    (set-process-window-size proc height width)
    (set-process-query-on-exit-flag proc nil)
    (process-put proc 'adjust-window-size-function
                 #'ghostel-comint--adjust-window-size)
    (with-current-buffer buffer
      (setq ghostel-comint--cols width
            ghostel-comint--rows height
            ;; Wire the buffer-local process pointer so the native
            ;; module's `writePtyCallback' (via `ghostel--flush-output')
            ;; can write terminal-originated bytes back to the PTY.
            ghostel--process proc)
      (set-marker (process-mark proc) (point-max)))
    proc))


;;; Process sentinel

(defun ghostel-comint--sentinel (process event)
  "Process sentinel for ghostel-comint subprocesses.
PROCESS is the comint subprocess, EVENT describes the state change.
Retires the active anchored terminal first, so the exit-notice
insert lands as inert buffer text rather than INSIDE the renderer's
region (where the end-marker's insertion-type t would silently
extend the writable span, and the next redraw would overwrite the
notice).  Mirrors the style of `ghostel--sentinel' in `ghostel.el'."
  (let ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (ghostel-comint--retire-terminal)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert (format "\nProcess %s %s"
                            (process-name process)
                            (string-trim-right event)))))))))


;;; Cleanup

(defun ghostel-comint--cleanup ()
  "Buffer-kill / mode-disable cleanup hook.
Tears down the live anchored terminal so its markers can be GC'd."
  (ghostel-comint--retire-terminal))


;;; Major mode

(define-derived-mode ghostel-comint-mode comint-mode "GhComint"
  "Major mode for a comint buffer with ghostel anchored rendering.

Input editing (RET to submit, M-p / M-n history, completion, ...) is
handled by comint exactly as in `\\[shell]'.  Output from the PTY
is rerouted through a per-command anchored ghostel terminal so ANSI
colours, CR overwrite, OSC titles and cwd, OSC 133 prompts, and
progress bars work natively.

Each user-submitted command gets its own short-lived anchored
terminal; when the next command is submitted, the previous one is
retired and its rendered output stays in the buffer as inert text.

\\{ghostel-comint-mode-map}"
  :group 'ghostel-comint
  ;; Comint owns CR / BS interpretation by default; turn that off so
  ;; the VT parser in our anchored terminal can do it instead.
  (setq-local comint-inhibit-carriage-motion t)
  ;; Disable comint's synchronous wait-and-strip echo cancellation —
  ;; the PTY is `stty -echo' so there's nothing to wait for, and the
  ;; wait can deadlock with our synchronous redraw on slow outputs.
  (setq-local comint-process-echoes nil)
  ;; `comint-truncate-buffer' deletes from `point-min' without any
  ;; awareness of anchored regions.  A truncate crossing a live
  ;; region's start-marker silently corrupts subsequent redraws.
  ;; Disable it locally — users who want bounded buffers can wrap
  ;; truncation with their own marker-aware logic.
  (setq-local comint-buffer-maximum-size nil)
  ;; ansi-color-process-output would double-paint colours over text
  ;; that already carries `face' text-properties from the renderer.
  ;; Strip `comint-truncate-buffer' too — see the rationale above.
  (setq-local comint-output-filter-functions
              (cons #'ghostel-comint--output-filter
                    (seq-remove (lambda (f)
                                  (memq f '(ansi-color-process-output
                                            comint-truncate-buffer)))
                                comint-output-filter-functions)))
  (setq-local comint-input-sender #'ghostel-comint--input-sender)
  ;; The anchored region grows on each redraw; window-point must
  ;; track end-of-buffer so the user sees fresh output.
  (setq-local window-point-insertion-type t)
  (add-hook 'kill-buffer-hook #'ghostel-comint--cleanup nil t)
  (add-hook 'change-major-mode-hook #'ghostel-comint--cleanup nil t))


;;; Entry point

(defun ghostel-comint--read-program ()
  "Read a shell program to launch.
Defaults to `ghostel-comint-program', or to `ghostel-shell' if that's
nil."
  (or ghostel-comint-program
      ghostel-shell
      (getenv "SHELL")
      "/bin/sh"))

;;;###autoload
(defun ghostel-comint (&optional program)
  "Run PROGRAM in a comint buffer with ghostel rendering layered on top.
With no argument, launches `ghostel-comint-program' (or `ghostel-shell',
or $SHELL).  With a prefix argument, prompts for the program.

The buffer uses `ghostel-comint-mode' (derived from `comint-mode'),
so input editing is comint's job — RET sends input,
\\<comint-mode-map>\\[comint-previous-input] / \\[comint-next-input]
walk history, etc.  Output is rerouted through a per-command anchored
ghostel terminal for ANSI / CR / OSC rendering."
  (interactive
   (list (if current-prefix-arg
             (read-shell-command "Program: "
                                 (ghostel-comint--read-program))
           (ghostel-comint--read-program))))
  (ghostel--load-module t)
  (let* ((program (or program (ghostel-comint--read-program)))
         (buffer (get-buffer-create ghostel-comint-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ghostel-comint-mode)
        (ghostel-comint-mode))
      ;; If a process is still live in this buffer, leave it alone —
      ;; the user explicitly relaunched, which usually means they
      ;; want to interrupt the current run.  Mimic `shell's behaviour:
      ;; reuse the buffer but spawn a fresh process.
      (let ((existing (get-buffer-process buffer)))
        (when (and existing (process-live-p existing))
          (when (yes-or-no-p (format "A %s process is running; restart it? "
                                     (process-name existing)))
            (set-process-query-on-exit-flag existing nil)
            (delete-process existing))))
      (when (get-buffer-process buffer)
        (error "Process already running in %s" (buffer-name buffer)))
      (goto-char (point-max))
      (ghostel-comint--retire-terminal)
      (ghostel-comint--spawn buffer program ghostel-comint-program-args))
    (pop-to-buffer buffer)
    buffer))

(provide 'ghostel-comint)

;;; ghostel-comint.el ends here
