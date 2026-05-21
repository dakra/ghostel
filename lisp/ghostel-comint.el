;;; ghostel-comint.el --- Comint + ghostel anchored renderer -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A `ghostel-comint-mode' (derived from `comint-mode') that delegates
;; input editing, history, and major-mode integration to comint and
;; output rendering to ghostel.  Each user-submitted command gets its
;; own short-lived anchored ghostel terminal sitting at the
;; `process-mark', so ANSI colours, CR overwrite, OSC titles / cwd,
;; OSC 133 prompts, and progress bars all work natively without comint
;; trying to layer its own (often conflicting) interpretation on top.
;;
;; When the next command starts the previous terminal is retired:
;; its marker pair is removed from `ghostel--anchored-terminals' so
;; the renderer can no longer touch it, and the bytes it produced
;; stay in the buffer as inert content.  `M-x isearch' finds content
;; from arbitrarily-old commands; `M-p' / `M-n' walk input history.
;;
;; Two retirement triggers run in tandem: OSC 133 D (command end, when
;; the shell has integration installed) flips the active terminal to
;; inert immediately, and `comint-input-sender' retires on every
;; submit as a fallback for shells without OSC 133.
;;
;; If a running command switches the terminal into the alternate
;; screen (apps like `less', `vim', `htop' do this with `smcup'),
;; further rendering through that terminal is paused: the output
;; would corrupt the buffer because the anchored region has no
;; "save-and-restore" semantics for alt-screen contents.  A one-line
;; warning is inserted and bytes continue to flow into libghostty
;; (so the app's state stays consistent for when its `rmcup' triggers
;; the next prompt), but the renderer no longer mirrors them into the
;; buffer.  Inline `less' / `vim' / `htop' inside the comint buffer
;; is therefore explicitly out of scope; use \\[ghostel] for those.
;;
;; Also out of scope for v1: kitty graphics inline, TRAMP / remote
;; processes, custom `comint-prompt-regexp' font-locking inside the
;; anchored region.
;;
;; Entry point:
;;
;;   M-x ghostel-comint

;;; Code:

(require 'ghostel)
(require 'comint)

(declare-function ghostel--alt-screen-p "ghostel-module" (term))
(declare-function ghostel--new-anchored "ghostel-module"
                  (start end rows cols &optional max-scrollback))
(declare-function ghostel--redraw "ghostel-module" (term &optional full))
(declare-function ghostel--set-size "ghostel-module"
                  (term rows cols &optional cell-w cell-h))
(declare-function ghostel--write-input "ghostel-module" (term data))


;;; Customization

(defgroup ghostel-comint nil
  "Run comint programs with ghostel anchored rendering."
  :group 'ghostel)

(defcustom ghostel-comint-program nil
  "Default program for `ghostel-comint'.
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
The default 0 keeps the active grid tight — only the most recent
rows of the currently-running command's output are visible inside
its anchored region.  Once the user submits the next command, the
final-frame state of the previous command stays as inert buffer
text outside any anchored region and is no longer subject to
libghostty's scrollback eviction.

Set to a positive byte count (e.g. (* 64 1024)) to let scrolled-off
rows of the running command materialize into the region — useful
when a single command produces thousands of lines you want to walk
back through while it's still running.  Once it finishes, behaviour
is the same either way."
  :type 'integer)

(defcustom ghostel-comint-default-rows 24
  "Fallback row count when no window displays the comint buffer.
When a window is displaying the buffer, that window's row count is
used instead."
  :type 'integer)

(defcustom ghostel-comint-default-cols 80
  "Fallback column count when no window displays the comint buffer.
When a window is displaying the buffer, that window's column count
is used instead."
  :type 'integer)

(defcustom ghostel-comint-stty-flags
  (concat ghostel--default-stty " -echo")
  "`stty' flags for the comint PTY.
Layers `-echo' on top of `ghostel--default-stty' so the kernel
discipline doesn't echo back the bytes comint sends: the user's
typed input is already visible as a comint input field, and a
duplicate echo would land in the next anchored region."
  :type 'string)


;;; Buffer-local state

(defvar-local ghostel-comint--term nil
  "Currently-active anchored terminal for this comint buffer.
Allocated lazily on the first output chunk and retired (`remhash'-ed
out of `ghostel--anchored-terminals') either on OSC 133 D
\(command end) or when the user submits the next command.")

(defvar-local ghostel-comint--rendering-paused nil
  "Non-nil when alt-screen entry has paused renderer mirroring.
Bytes continue to flow into the live terminal so its VT state stays
consistent, but `ghostel-comint--output-filter' stops redrawing
until the next command starts (which resets this flag along with
allocating a fresh terminal).")

(defvar-local ghostel-comint--cols 80
  "Last column width sized into the anchored terminal.
Maintained by `ghostel-comint--adjust-window-size'.")

(defvar-local ghostel-comint--rows 24
  "Last row count sized into the anchored terminal.
Maintained by `ghostel-comint--adjust-window-size'.")


;;; Size helpers

(defun ghostel-comint--window-size (buffer)
  "Return (HEIGHT . WIDTH) sized to a window showing BUFFER.
Searches any frame for a window displaying BUFFER and reads its
dimensions.  Falls back to `ghostel-comint-default-rows' /
`ghostel-comint-default-cols' when no window is displaying the
buffer."
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
Removes its marker pair from `ghostel--anchored-terminals' so the
renderer can no longer write to the region.  The bytes it produced
stay in the buffer as inert text.  Safe to call when no terminal is
active."
  (when (and ghostel-comint--term
             (hash-table-p ghostel--anchored-terminals))
    (remhash ghostel-comint--term ghostel--anchored-terminals))
  (setq ghostel-comint--term nil
        ghostel-comint--rendering-paused nil))

(defun ghostel-comint--make-terminal (proc)
  "Create a fresh anchored terminal at PROC's `process-mark'.
Inserts an empty marker-bounded region (a single newline) at the
`process-mark', constructs the terminal sized to the displaying
window's rows × cols, and advances the `process-mark' so subsequent
comint output insertions land inside the new region."
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
      ;; Stamp the seed newline with `field=output' so comint's field
      ;; navigation (C-a, M-a, M-e) crosses it like normal output.
      (insert (propertize "\n"
                          'field 'output
                          'front-sticky '(field
                                          inhibit-line-move-field-capture)
                          'inhibit-line-move-field-capture t))
      (setq end (point)))
    (setq ghostel-comint--cols cols
          ghostel-comint--rows rows
          term (ghostel--new-anchored start end rows cols
                                      ghostel-comint-max-scrollback)
          ghostel-comint--term term
          ghostel-comint--rendering-paused nil)
    (set-marker pmark end)
    term))

(defun ghostel-comint--ensure-terminal (proc)
  "Return the active anchored terminal for PROC, creating one if needed."
  (or ghostel-comint--term
      (ghostel-comint--make-terminal proc)))


;;; Window resize / SIGWINCH

(defun ghostel-comint--adjust-window-size (process windows)
  "Resize the active anchored terminal and PTY to match the window.
PROCESS is the comint process, WINDOWS the list of windows displaying
its buffer.  Returns a (WIDTH . HEIGHT) cons cell so Emacs follows up
with `set-process-window-size' (SIGWINCH), keeping the kernel PTY
size aligned with the rendered grid."
  (let* ((default-fn (default-value 'window-adjust-process-window-size-function))
         (adjust-fn (if (and (functionp default-fn)
                             (not (eq default-fn
                                      #'ghostel-comint--adjust-window-size)))
                        default-fn
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
              (ghostel--redraw ghostel-comint--term t)))))))
    size))


;;; Output filter integration

(defun ghostel-comint--output-filter (_string)
  "Reroute just-inserted PTY output through the active ghostel terminal.
Runs from `comint-output-filter-functions' AFTER comint has inserted
raw bytes between `comint-last-output-start' and the `process-mark'.
We capture those bytes, delete the raw region, feed them through the
anchored terminal's VT parser, and run a redraw — comint's hook
machinery (history, prompt detection, scroll) sees only the
rendered output."
  (let ((proc (get-buffer-process (current-buffer))))
    (when proc
      (let* ((pmark (process-mark proc))
             (beg (marker-position comint-last-output-start))
             (end (marker-position pmark)))
        (when (and beg end (> end beg))
          (let ((raw (buffer-substring-no-properties beg end))
                (inhibit-read-only t))
            (delete-region beg end)
            (let ((term (ghostel-comint--ensure-terminal proc)))
              (ghostel--write-input term raw)
              ;; Check for alt-screen takeover before rendering.  If the
              ;; running command flipped into the alternate screen, the
              ;; anchored region can't represent it correctly (no save /
              ;; restore semantics across `smcup' / `rmcup'); pause the
              ;; mirror and warn so the user knows what's going on.
              (cond
               (ghostel-comint--rendering-paused
                ;; Already paused — VT state stays consistent but we
                ;; don't redraw.  The next command's input-sender will
                ;; allocate a fresh terminal.
                nil)
               ((ghostel--alt-screen-p term)
                (setq ghostel-comint--rendering-paused t)
                (let ((pair (gethash term ghostel--anchored-terminals)))
                  (when pair
                    (save-excursion
                      (goto-char (marker-position (cdr pair)))
                      (insert
                       (propertize
                        "\n[ghostel-comint: app entered alt-screen; \
output rendering paused — use M-x ghostel for full-screen apps]\n"
                        'face 'warning
                        'field 'output))))))
               (t
                (ghostel--redraw term t)
                (let* ((pair (gethash term ghostel--anchored-terminals))
                       (start-marker (and pair (car pair)))
                       (end-marker (and pair (cdr pair))))
                  (when (and start-marker end-marker)
                    (let ((rend (marker-position end-marker)))
                      ;; Advance the process-mark past the rendered
                      ;; region so the NEXT comint filter call sees
                      ;; only its own freshly-inserted bytes.
                      (set-marker pmark rend)
                      (set-marker comint-last-output-start rend)
                      (unless comint-use-prompt-regexp
                        (comint--mark-as-output
                         (marker-position start-marker) rend))))))))))))))


;;; Input handling

(defun ghostel-comint--input-sender (proc input)
  "Send INPUT to PROC, retiring the previous anchored terminal first.
Each fresh command gets its own anchored terminal placed at the
`process-mark', which sits just below the user's typed input line.
Retiring the previous terminal converts its rendered output into
inert buffer text.

This is the fallback retirement path; the OSC 133 D handler
\(`ghostel-comint--on-command-finish') retires earlier when the
shell has integration installed."
  (ghostel-comint--retire-terminal)
  (ghostel-comint--make-terminal proc)
  (comint-simple-send proc input))


;;; OSC 133 command-finish hook

(defun ghostel-comint--on-command-finish (buffer _exit)
  "Retire the active anchored terminal on OSC 133 D in BUFFER.
Hung off `ghostel-command-finish-functions' for `ghostel-comint-mode'
buffers only.  Lets the renderer hand off the rendered region to
inert state the moment the shell signals the command finished,
rather than waiting for the user to submit the next one."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'ghostel-comint-mode)
        (ghostel-comint--retire-terminal)))))


;;; Process spawning

(defun ghostel-comint--spawn (buffer program program-args)
  "Spawn PROGRAM with PROGRAM-ARGS in BUFFER under a PTY for comint.
Hooks `comint-output-filter' as the process filter so comint's
machinery (history, prompt detection) runs as usual, and installs
`ghostel-comint--sentinel' + an `adjust-window-size-function'
process property so SIGWINCH is delivered on window resize.

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
            ghostel-comint--rows height)
      (set-marker (process-mark proc) (point-max)))
    proc))


;;; Process sentinel

(defun ghostel-comint--sentinel (process event)
  "Sentinel for the ghostel-comint PROCESS reacting to EVENT.
Retires the active anchored terminal BEFORE inserting the exit
notice, so the notice lands as inert buffer text past the now-
detached end-marker rather than INSIDE the renderer's writable
span (where the end-marker's insertion-type t would silently
extend the region and the next redraw would clobber the notice)."
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
  "Kill-buffer / mode-disable cleanup hook.
Retires the live anchored terminal so its markers can be GC'd."
  (ghostel-comint--retire-terminal))


;;; Major mode

(define-derived-mode ghostel-comint-mode comint-mode "GhComint"
  "Major mode for a comint buffer with ghostel anchored rendering.

Input editing (RET to submit, M-p / M-n history, completion, ...) is
comint's job, exactly as in `\\[shell]'.  Output from the PTY is
rerouted through a per-command anchored ghostel terminal so ANSI
colours, CR overwrite, OSC titles and cwd, OSC 133 prompts, and
progress bars work natively.

Each user-submitted command gets its own short-lived anchored
terminal; on OSC 133 D (command end) or when the next command is
submitted, the previous terminal is retired and its rendered output
stays in the buffer as inert text.

\\{ghostel-comint-mode-map}"
  :group 'ghostel-comint
  ;; Let the VT parser inside ghostel handle CR / BS / etc; comint's
  ;; text-level CR handler would race with the renderer.
  (setq-local comint-inhibit-carriage-motion t)
  ;; The PTY is `stty -echo'.  Disable comint's synchronous wait-and-
  ;; strip echo cancellation — nothing to wait for, and the wait can
  ;; deadlock with our synchronous redraw on slow outputs.
  (setq-local comint-process-echoes nil)
  ;; `comint-truncate-buffer' deletes from `point-min' with no
  ;; awareness of anchored markers.  A truncate crossing a live
  ;; region's start-marker silently corrupts subsequent redraws.
  (setq-local comint-buffer-maximum-size nil)
  ;; ansi-color-process-output would double-paint colours over text
  ;; that already carries `face' text-properties from the renderer.
  ;; Strip `comint-truncate-buffer' for the rationale above.
  (setq-local comint-output-filter-functions
              (cons #'ghostel-comint--output-filter
                    (seq-remove (lambda (f)
                                  (memq f '(ansi-color-process-output
                                            comint-truncate-buffer)))
                                comint-output-filter-functions)))
  (setq-local comint-input-sender #'ghostel-comint--input-sender)
  ;; The anchored region grows as output renders; window-point needs
  ;; to track end-of-buffer so the user sees fresh output.
  (setq-local window-point-insertion-type t)
  (add-hook 'ghostel-command-finish-functions
            #'ghostel-comint--on-command-finish nil t)
  (add-hook 'kill-buffer-hook #'ghostel-comint--cleanup nil t)
  (add-hook 'change-major-mode-hook #'ghostel-comint--cleanup nil t))


;;; Entry point

(defun ghostel-comint--read-program ()
  "Read a program path to launch.
Defaults to `ghostel-comint-program', or to `ghostel-shell' / $SHELL
when that's nil."
  (or ghostel-comint-program
      (and (stringp ghostel-shell) ghostel-shell)
      (getenv "SHELL")
      "/bin/sh"))

;;;###autoload
(defun ghostel-comint (&optional program)
  "Run PROGRAM in a comint buffer with ghostel rendering layered on top.
With no argument, launches `ghostel-comint-program' (or `ghostel-shell',
or $SHELL).  With a prefix argument, prompts for the program."
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
