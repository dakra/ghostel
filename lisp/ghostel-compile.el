;;; ghostel-compile.el --- Compilation integration for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run `compile'-style shell commands inside a ghostel terminal
;; buffer.  Unlike \\[compile] (which runs commands through comint),
;; `ghostel-compile' runs them in a real TTY via ghostel so programs
;; that detect a terminal (progress bars, colours, curses tools)
;; behave as they would in an interactive shell.
;;
;; Each `ghostel-compile' invocation spawns a fresh process via
;; `shell-file-name -c COMMAND' through a PTY rendered by ghostel — no
;; interactive shell sits between the command and the user.  Multi-line
;; scripts are passed verbatim to the shell.  No OSC 133 / shell
;; integration is required; completion is detected by the process
;; sentinel, which delivers the real exit status.
;;
;; The buffer mimics `compilation-mode': a "Compilation started at"
;; header, a "Compilation finished at ..., duration ..." footer, and
;; the same `mode-line-process' run/exit faces.
;;
;; By default the buffer is read-only and behaves like a
;; `compilation-mode' buffer from the start: `g' reruns, `n'/`p'
;; walk errors, RET jumps to the source.  Pass a prefix arg
;; (\\[universal-argument] \\[ghostel-compile]) to launch the buffer
;; in interactive mode instead - keystrokes reach the running
;; process so programs like `htop', `less', or test prompts work.
;;
;; When the command finishes, the renderer is torn down and the
;; buffer's major mode is switched to `ghostel-compile-view-mode'
;; (derived from `compilation-mode').  At that point the buffer is a
;; regular, read-only Emacs buffer with standard error highlighting
;; and `next-error' navigation.  It will not return to an interactive
;; ghostel terminal — a recompile (`g', `M-x ghostel-recompile')
;; discards it and starts fresh in the original `default-directory'.
;; When invoked from inside the compile buffer, recompile preserves
;; the launch mode (compilation-style vs interactive input); when invoked
;; from an unrelated buffer it falls back to the global default
;; (compilation-style).
;;
;; Enable `ghostel-compile-global-mode' to route `compile',
;; `recompile', `project-compile', ... through ghostel.
;; `MODE=t' (the comint variant — \\[universal-argument] \\[compile])
;; becomes an interactive ghostel terminal instead of comint.
;; `grep-mode' falls through to the stock implementation.
;;
;; Standard `compile' options honoured:
;;   `compile-command' / `compile-history' (shared with \\[compile])
;;   `compilation-read-command'
;;   `compilation-ask-about-save'
;;   `compilation-auto-jump-to-first-error'
;;   `compilation-finish-functions' (runs alongside
;;     `ghostel-compile-finish-functions')
;;   `compilation-scroll-output' (effectively always on)
;;
;; Keys in the finished buffer:
;;   g           — ghostel-recompile
;;   n / p       — compilation-next-error / -previous-error (no auto-open)
;;   RET         — compile-goto-error (open the source)
;;   M-g n / M-g p — standard `next-error' / `previous-error'

;;; Code:

(require 'ghostel)
(require 'compile)

(declare-function ghostel--set-size "ghostel-module")
(declare-function ghostel--write-vt "ghostel-module")


;;; Customization

(defgroup ghostel-compile nil
  "Run `compile'-style commands in a ghostel terminal."
  :group 'ghostel)

(defcustom ghostel-compile-buffer-name "*ghostel-compile*"
  "Buffer name used by `ghostel-compile'."
  :type 'string)

(defcustom ghostel-compile-finished-major-mode 'ghostel-compile-view-mode
  "Major mode to switch to after a `ghostel-compile' run finishes.

The default `ghostel-compile-view-mode' derives from `compilation-mode',
making the buffer a regular read-only Emacs buffer with `next-error'
navigation and colored error text.

Set to nil to skip the major-mode switch and leave the buffer in
`ghostel-mode'.  Either way, finalization always tears down the live
process and ghostel rendering — the buffer never returns to an
interactive terminal."
  :type '(choice (const :tag "Compilation view (default)" ghostel-compile-view-mode)
                 (const :tag "Don't switch" nil)
                 (function :tag "Custom major mode")))

(defcustom ghostel-compile-debug nil
  "When non-nil, log `ghostel-compile' lifecycle events to *Messages*.
Useful for diagnosing wrong exit codes or missed events."
  :type 'boolean)

(defcustom ghostel-compile-finish-functions nil
  "Functions to call when a `ghostel-compile' command finishes.
Each function receives two arguments: the compilation buffer and a
status message string (e.g. \"finished\\n\" or
\"exited abnormally with code 2\\n\"), matching the convention of
`compilation-finish-functions'.

`compilation-finish-functions' is also run with the same arguments."
  :type 'hook)


;;; Internal variables

(defvar-local ghostel-compile--command nil
  "The command most recently launched by `ghostel-compile' here.")

(defvar-local ghostel-compile--scan-marker nil
  "Marker at the buffer position where the current command's output began.")

(defvar-local ghostel-compile--last-exit nil
  "Exit status of the most recent `ghostel-compile' command.")

(defvar-local ghostel-compile--start-time nil
  "`current-time' when the most recent command was launched.")

(defvar-local ghostel-compile--directory nil
  "`default-directory' captured at `ghostel-compile' invocation time.
Used by `ghostel-recompile' so the command re-runs in the same
directory regardless of where the user is when they press `g'.")

(defvar-local ghostel-compile--finalized nil
  "Non-nil once the sentinel has finalized this run.
Second-chance guard: if the sentinel fires twice (process exit
followed by teardown) we only run the heavy finalize path once.")

(defvar-local ghostel-compile--view-mode-override nil
  "Buffer-local override for `ghostel-compile-finished-major-mode'.
Set by the `compilation-start' advice when a caller passes a
compile-mode subclass (e.g. a custom grep-mode-like mode) so that
error-regexp and font-lock customisations the subclass installs
survive into the `ghostel-compile-view-mode' buffer after finalize.
Nil means finalize falls back to the global
`ghostel-compile-finished-major-mode'.")

(defvar-local ghostel-compile--interactive nil
  "Non-nil if this run was launched with interactive input.
Nil means the buffer uses compilation-style navigation from the start;
non-nil means the buffer behaves like an interactive ghostel terminal
during the run (keystrokes are forwarded to the PTY).  The buffer
itself remains renderer-owned and read-only in both cases.
`ghostel-recompile' reads this flag from the source buffer so a
recompile preserves the launch mode.")

(defvar ghostel-compile-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map compilation-mode-map)
    ;; `n'/`p' navigate within the compile buffer only (no auto-open).
    ;; RET / mouse-2 still jump to the source like in `compilation-mode'.
    (define-key map "n" #'compilation-next-error)
    (define-key map "p" #'compilation-previous-error)
    (define-key map "g" #'ghostel-recompile)
    map)
  "Keymap for `ghostel-compile-view-mode'.
Inherits from `compilation-mode-map'; rebinds `n'/`p' to
`compilation-next-error' / `compilation-previous-error' so they
just move point through errors without opening the source file
in another window.  `g' runs `ghostel-recompile' instead of
`recompile'.  RET still opens the error like in `compilation-mode'.")


;;; Helpers

(define-derived-mode ghostel-compile-view-mode
  compilation-mode "Compilation"
  "Major mode for a finished `ghostel-compile' buffer.

A regular, read-only Emacs buffer.  `g' re-runs the command via
`ghostel-recompile', `n'/`p' walk errors in the buffer (without opening
files), RET jumps to the source.  The live process and ghostel rendering
have been torn down; the buffer will not return to a ghostel terminal.

`ghostel-compile-view-mode-map' is also installed as the buffer's
local map *during* a read-only run (before the run finishes), so
the same keys work while the command is still executing."
  :group 'ghostel-compile
  ;; Make sure our keymap actually parents `compilation-mode-map' even
  ;; if it was created earlier — `define-derived-mode' won't reset an
  ;; already-set parent.
  (set-keymap-parent ghostel-compile-view-mode-map compilation-mode-map)
  (setq-local next-error-function #'compilation-next-error-function)
  ;; Re-enable the live toggle minor mode so `C-c C-j' / `C-c C-e'
  ;; remain bound on the finished buffer (they error with a clean
  ;; "No live process" message — better UX than the keys silently
  ;; disappearing post-finalize).
  (ghostel-compile-toggle-mode 1)
  ;; Make sure point lands at the top after a successful recompile (and
  ;; that future input doesn't inherit ghostel's terminal-style behaviour).
  (setq-local window-point-insertion-type nil)
  ;; The buffer text inherited from the ghostel run carries per-cell `face'
  ;; text-properties written by the native module.  `compilation-mode'
  ;; installs font-lock keywords for error highlighting, and the default
  ;; unfontify function strips every `face' prop — wiping the colour from
  ;; the recorded output on the first JIT-lock pass.  Neutralise unfontify:
  ;; compilation-mode's keywords are applied once via `font-lock-ensure'
  ;; on a finalised, static buffer and don't need to be cleaned up.
  (setq-local font-lock-unfontify-region-function #'ignore)
  ;; Show the URI at point in eldoc.
  (add-hook 'eldoc-documentation-functions #'ghostel--eldoc-link nil t)
  ;; Expose cwd to buffer-menu/ibuffer
  (setq-local list-buffers-directory (expand-file-name default-directory)))

(defun ghostel-compile--format-duration (seconds)
  "Format SECONDS (float) as a compilation-style duration string.
Matches the format used by `M-x compile'."
  (cond
   ((< seconds 10) (format "%.2f s" seconds))
   ((< seconds 60) (format "%.1f s" seconds))
   (t              (format-seconds "%h:%02m:%02s" seconds))))

(defun ghostel-compile--status-message (exit)
  "Return the compilation-style status message string for EXIT status."
  (cond
   ((and (numberp exit) (= exit 0)) "finished\n")
   ((numberp exit) (format "exited abnormally with code %d\n" exit))
   (t              "finished\n")))

(defun ghostel-compile--header-text (command start-time)
  "Return the header string for COMMAND started at START-TIME.
Plain text, matching the `M-x compile' header format — including
the `default-directory' file-local spec, so reloading the buffer
restores its compilation directory."
  (format "-*- mode: ghostel-compile; default-directory: %s -*-\n\
Compilation started at %s\n\n%s\n"
          (prin1-to-string (abbreviate-file-name default-directory))
          (substring (current-time-string start-time) 0 19)
          command))

(defun ghostel-compile--footer-text (exit start-time end-time)
  "Return the footer string for EXIT between START-TIME and END-TIME.
Plain text, matching the `M-x compile' footer format."
  (let* ((duration (float-time (time-subtract end-time start-time)))
         (ts (substring (current-time-string end-time) 0 19))
         (status-word (cond
                       ((and (numberp exit) (= exit 0)) "finished")
                       ((numberp exit)
                        (format "exited abnormally with code %d" exit))
                       (t "finished"))))
    (format "Compilation %s at %s, duration %s\n"
            status-word ts (ghostel-compile--format-duration duration))))

(defun ghostel-compile--set-mode-line-running ()
  "Set `mode-line-process' to the running indicator.
Reads `ghostel-compile--interactive' so the indicator reflects the
*current* run state — `:run' for read-only, `:run/i' for
interactive.  The toggle commands call this to refresh the marker
when the user switches state mid-run."
  (let ((label (if ghostel-compile--interactive ":run/i" ":run")))
    (setq mode-line-process
          (list (list :propertize label 'face 'compilation-mode-line-run)
                'compilation-mode-line-errors)))
  (force-mode-line-update))

(defun ghostel-compile--set-mode-line-exit (exit)
  "Set `mode-line-process' to reflect the terminal EXIT status."
  (let* ((ok (and (numberp exit) (= exit 0)))
         (face (if ok 'compilation-mode-line-exit 'compilation-mode-line-fail))
         (text (format ":exit [%s]" (if (numberp exit) exit "?"))))
    (setq mode-line-process
          (list (propertize text 'face face)
                'compilation-mode-line-errors))
    (force-mode-line-update)))

(defun ghostel-compile--auto-jump (buffer)
  "Jump to the first error in BUFFER if `compilation-auto-jump-to-first-error'."
  (when (and compilation-auto-jump-to-first-error
             (buffer-live-p buffer))
    (with-current-buffer buffer
      (let ((next-error-last-buffer buffer))
        (condition-case _
            (first-error)
          (error nil))))))

(defun ghostel-compile--teardown-terminal ()
  "Tear down the live process and ghostel renderer in the current buffer.
Replaces the sentinel and filter with no-ops before deleting the
process so the default sentinel can't write \"Process NAME killed\"
into our buffer."
  (when (and (bound-and-true-p ghostel--process)
             (process-live-p ghostel--process))
    (set-process-sentinel ghostel--process #'ignore)
    (set-process-filter ghostel--process #'ignore)
    (set-process-query-on-exit-flag ghostel--process nil)
    (delete-process ghostel--process)
    (setq ghostel--process nil))
  (when (bound-and-true-p ghostel--redraw-timer)
    (cancel-timer ghostel--redraw-timer)
    (setq ghostel--redraw-timer nil)))

(defun ghostel-compile--trim-trailing-blanks (start)
  "Delete trailing whitespace-only content in START..(point-max).
The ghostel renderer commits the full terminal grid to the buffer,
so a short command (`echo test') leaves ~24 rows of trailing
spaces and newlines that would otherwise wedge the footer far
below the real output.  Find the last non-whitespace position in
the scan region and delete everything after it, leaving a single
trailing newline so the footer's leading `\\n' produces a blank
separator line — matching `M-x compile's output format."
  (save-excursion
    (goto-char (point-max))
    (skip-chars-backward " \t\n" start)
    (when (not (eobp))
      (delete-region (point) (point-max))
      (insert "\n"))))

(defun ghostel-compile--render-header-live (header)
  "Feed HEADER to the ghostel terminal and commit the render synchronously.
The buffer-side effect is that HEADER becomes part of the terminal
scrollback immediately — the user sees the compilation banner while
the command is running, matching `M-x compile's behaviour.

Newlines in HEADER are rewritten as CRLF so the VT parser returns
to column 0 at the start of each line; a bare LF only advances the
cursor one row and would stack the lines diagonally."
  (when (and ghostel--term (> (length header) 0))
    (let ((crlf (replace-regexp-in-string "\n" "\r\n" header t t)))
      (ghostel--write-vt ghostel--term crlf))
    (when ghostel--redraw-timer
      (cancel-timer ghostel--redraw-timer)
      (setq ghostel--redraw-timer nil))
    (ghostel--redraw-now (current-buffer))))

(defun ghostel-compile--finalize (buffer exit end-time)
  "Insert header/footer, parse errors, switch major mode for BUFFER.
EXIT is the command exit status; END-TIME its completion time.
Safe to call more than once — second and later calls are no-ops
thanks to `ghostel-compile--finalized'.

Switches the buffer's major mode to
`ghostel-compile-finished-major-mode' (by default
`ghostel-compile-view-mode') so the buffer becomes a regular,
read-only Emacs buffer that can never transition back to
interactive terminal mode.

Header and footer are inserted as plain buffer text (matching
`M-x compile') rather than overlays, so cursor motion behaves the
same as in any compilation buffer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless ghostel-compile--finalized
        (setq ghostel-compile--finalized t)
        (let* ((start (and ghostel-compile--scan-marker
                           (marker-position ghostel-compile--scan-marker)))
               (start-time ghostel-compile--start-time)
               (command ghostel-compile--command)
               (directory ghostel-compile--directory)
               (footer (ghostel-compile--footer-text exit start-time end-time))
               (msg (ghostel-compile--status-message exit))
               (inhibit-read-only t))
          (setq ghostel-compile--last-exit exit)
          (when ghostel-compile-debug
            (message "ghostel-compile: finalizing exit=%S buffer=%S"
                     exit (buffer-name buffer)))
          (when start
            (ghostel-compile--trim-trailing-blanks start))
          (ghostel-compile--teardown-terminal)
          ;; Run standard compilation finish hooks before switching major mode:
          ;; callers may install buffer-local hooks or continuation state, and
          ;; `funcall' below kills those locals as part of the mode change.
          (run-hook-with-args 'compilation-finish-functions buffer msg)
          ;; Switch major mode now that the process is dead.  Preserve state
          ;; that `kill-all-local-variables' would otherwise wipe.  A
          ;; per-buffer override (set by the `compilation-start' advice
          ;; when the caller passes a custom compile-mode subclass) wins
          ;; over the global default — so error-regexp and font-lock
          ;; customisations the subclass installs survive into the
          ;; finished buffer.
          (let* ((saved-command command)
                 (saved-start-time start-time)
                 (saved-directory directory)
                 (saved-interactive ghostel-compile--interactive)
                 (saved-compilation-arguments-local
                  (local-variable-p 'compilation-arguments))
                 (saved-compilation-arguments
                  (and saved-compilation-arguments-local
                       compilation-arguments))
                 (target-mode (or ghostel-compile--view-mode-override
                                  ghostel-compile-finished-major-mode)))
            (when target-mode
              (funcall target-mode))
            (setq-local ghostel-compile--command saved-command
                        ghostel-compile--directory saved-directory
                        ghostel-compile--start-time saved-start-time
                        ghostel-compile--last-exit exit
                        ghostel-compile--interactive saved-interactive
                        ghostel-compile--finalized t)
            ;; Preserve `compilation-arguments' so `revert-buffer' on
            ;; the finished buffer still reproduces the same run.
            (when saved-compilation-arguments
              (setq-local compilation-arguments saved-compilation-arguments))
            ;; Pin the buffer's `default-directory' to the directory the
            ;; user invoked `ghostel-compile' from, so it doesn't drift if
            ;; the command happened to `cd' elsewhere during the run.
            (when saved-directory
              (setq default-directory saved-directory)))
          ;; The header was rendered into the VT terminal pre-spawn, so
          ;; it is already buffer text above `scan-marker'.  Append the
          ;; footer and parse errors over the run's own output.
          (let* ((inhibit-read-only t)
                 (parse-start (copy-marker (or start (point-min)))))
            (save-excursion
              (goto-char (point-max))
              ;; Start the footer on a fresh line, then leave a blank
              ;; separator line between the last output and the footer
              ;; — matches the `\n\nCompilation finished ...' format
              ;; `M-x compile' uses.
              (unless (or (bobp) (bolp))
                (insert "\n"))
              (insert "\n" footer))
            (save-excursion
              (save-restriction
                (widen)
                (setq-local compilation--parsed (copy-marker parse-start))
                (condition-case err
                    (compilation--ensure-parse (point-max))
                  (error
                   (message "ghostel-compile: error scanning output: %s"
                            (error-message-string err)))))))
          (goto-char (point-max))
          (dolist (win (get-buffer-window-list buffer nil t))
            (set-window-point win (point-max))
            (with-selected-window win (recenter -1))))
        (ghostel-compile--set-mode-line-exit exit)
        (setq next-error-last-buffer buffer)
        (ghostel-compile--auto-jump buffer)
        (run-hook-with-args 'ghostel-compile-finish-functions
                            buffer (ghostel-compile--status-message exit))))))


;;; Spawning

(defun ghostel-compile--sentinel (process _event)
  "Sentinel for the compile PROCESS: finalize the buffer on exit."
  (when (memq (process-status process) '(exit signal))
    (let ((buffer (process-buffer process))
          (exit (process-exit-status process)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when ghostel-compile-debug
            (message "ghostel-compile: sentinel exit=%S status=%S"
                     exit (process-status process)))
          ;; Cancel any scheduled redraw and commit the current terminal state
		  ;; to the buffer synchronously.  Without this, a short-lived
          ;; command (`echo`, `false`, `exit 7`) finishes before the
          ;; ~16 ms redraw timer fires and its output is lost when
          ;; `--teardown-terminal' destroys the renderer.
          (when ghostel--term
            (when ghostel--redraw-timer
              (cancel-timer ghostel--redraw-timer)
              (setq ghostel--redraw-timer nil))
            (ghostel--redraw-now buffer))
          (setq compilation-in-progress
                (delq process compilation-in-progress))
          (when (fboundp 'compilation--update-in-progress-mode-line)
            (compilation--update-in-progress-mode-line))
          (ghostel-compile--finalize buffer exit (current-time)))))))

(defconst ghostel-compile--stty-flags
  (concat ghostel--default-stty " -echo")
  "`stty' flags for the compile PTY.
Layers `-echo' on top of `ghostel--default-stty' so we don't render
an echoed copy of the command (which users already see in the
header).  `sane' in the baseline turns echo on; the trailing
`-echo' overrides it.")

(defun ghostel-compile--spawn (command buffer height width)
  "Spawn COMMAND in BUFFER via a PTY sized HEIGHT rows by WIDTH columns.
Installs `ghostel--filter' and `ghostel-compile--sentinel'.  Returns
the process.

COMMAND is passed verbatim to `shell-file-name' via
`shell-command-switch', so multi-line scripts and shell
metacharacters are handled the same way `M-x compile' handles
them.  `/bin/sh' is used only to set PTY attributes (stty) before
exec'ing the user's shell.

For remote (TRAMP) `default-directory's, `shell-file-name' and
`shell-command-switch' are resolved via `with-connection-local-variables'
so the remote host's shell is used (not whatever zsh/bash path the
local machine happens to have)."
  (let* ((remote-p (file-remote-p default-directory))
         (shell (if remote-p
                    (with-connection-local-variables shell-file-name)
                  shell-file-name))
         (switch (if remote-p
                     (with-connection-local-variables shell-command-switch)
                   shell-command-switch))
         (wrapper
          (list "/bin/sh" "-c"
                (concat
                 "stty " ghostel-compile--stty-flags
                 (format " rows %d columns %d" height width)
                 " 2>/dev/null; "
                 "exec "
                 (shell-quote-argument shell) " "
                 (shell-quote-argument switch) " "
                 (shell-quote-argument command))))
         (process-environment
          (append compilation-environment
                  ghostel-environment
                  (list (format "INSIDE_EMACS=%s,compile" emacs-version))
                  (ghostel--terminal-env)
                  ;; Defeat pagers (git grep, etc.).
                  (list "PAGER=")
                  (copy-sequence process-environment)))
         ;; See `ghostel--spawn-pty' for why these are set.
         (process-adaptive-read-buffering nil)
         (read-process-output-max (max read-process-output-max (* 1024 1024)))
         (proc (make-process
                :name "ghostel-compile"
                :buffer buffer
                :command wrapper
                :connection-type 'pty
                :file-handler remote-p
                :filter #'ghostel--filter
                :sentinel #'ghostel-compile--sentinel)))
    ;; Store the process on the buffer so `ghostel--self-insert'
    ;; (and other ghostel-mode key handlers) can send keystrokes to
    ;; it — that's how users interact with long-running programs
    ;; (`htop', `less', test prompts, ...) during the compile.
    (with-current-buffer buffer
      (setq ghostel--process proc))
    (set-process-coding-system proc 'binary 'binary)
    (set-process-window-size proc height width)
    (when compilation-always-kill
      (set-process-query-on-exit-flag proc nil))
    (process-put proc 'adjust-window-size-function nil)
    proc))


;;; Buffer management

(defun ghostel-compile--prepare-buffer (name dir &optional interactive)
  "Return the ghostel buffer named NAME, reset for a fresh run from DIR.
If a buffer with NAME already exists, the run is prepared in place
— the buffer is erased and the terminal rebuilt, but the buffer
object is preserved.  This keeps any window already displaying the
buffer stable across recompiles (so `g' in a compile buffer reuses
its window, matching `M-x recompile').

If the existing buffer has a live process, prompt via `yes-or-no-p'
before killing it, unless `compilation-always-kill' is non-nil or
the process does not query on exit.

Creates the terminal directly — no interactive shell is spawned —
so there is no remote-integration round-trip on TRAMP buffers.

When INTERACTIVE is non-nil the buffer keeps the regular
`ghostel-semi-char-mode-map' so keystrokes reach the running process —
the same UX a user gets from \\[universal-argument]
\\[ghostel-compile] or from `compilation-start' under
`ghostel-compile-global-mode' with `MODE=t'.  When INTERACTIVE is
nil (the default) the local map is set to
`ghostel-compile-view-mode-map' so it behaves like a
`compilation-mode' buffer.  Either way the major mode stays
`ghostel-mode' during the run so the renderer, redraw timer, and
resize hooks
\(all gated on `derived-mode-p \\='ghostel-mode\\=') keep working;
the rendered buffer remains read-only in both cases."
  (let ((existing (get-buffer name)))
    (when existing
      (with-current-buffer existing
        (let ((proc (bound-and-true-p ghostel--process)))
          (when (process-live-p proc)
            (if (or (eq (process-query-on-exit-flag proc) nil)
                    compilation-always-kill
                    (yes-or-no-p
                     (format "A %s process is running; kill it? "
                             (buffer-name existing))))
                (condition-case nil
                    (progn
                      ;; Our sentinel is what removes the process from
                      ;; `compilation-in-progress'; we're about to
                      ;; suppress it (replacing with `#'ignore'), so
                      ;; do that bookkeeping ourselves now to avoid
                      ;; leaking a dead entry.
                      (setq compilation-in-progress
                            (delq proc compilation-in-progress))
                      (set-process-sentinel proc #'ignore)
                      (set-process-filter proc #'ignore)
                      (interrupt-process proc)
                      (sit-for 0.1)
                      (delete-process proc))
                  (error nil))
              (error "Cannot have two processes in `%s' at once"
                     (buffer-name existing))))
          (setq ghostel--process nil))
        (when (bound-and-true-p ghostel--redraw-timer)
          (cancel-timer ghostel--redraw-timer)
          (setq ghostel--redraw-timer nil)))))
  (ghostel--load-module t)
  (let* ((buffer (get-buffer-create name))
         (win (or (get-buffer-window buffer t) (selected-window)))
         (height (if (window-live-p win)
                     (with-selected-window win (floor (window-screen-lines)))
                   24))
         (width  (if (window-live-p win) (window-max-chars-per-line win) 80)))
    (with-current-buffer buffer
      ;; Set `default-directory' before `ghostel-mode' so the mode's
      ;; `hack-dir-local-variables' call resolves dir-locals against
      ;; the target directory, not whatever the buffer inherited at
      ;; `get-buffer-create' time.
      (setq-local default-directory dir)
      ;; Reset to `ghostel-mode' unconditionally — on a recompile the
      ;; buffer is in `ghostel-compile-view-mode' (derived from
      ;; `compilation-mode', *not* `ghostel-mode'), so the previous
      ;; `(unless derived-mode-p ghostel-mode) (ghostel-mode))' guard
      ;; also fired, but also made state-reset implicit; make it
      ;; explicit here so this helper doesn't have two code paths.
      (ghostel-mode)
      ;; Wire up `next-error' so `\\[next-error]' / `M-g n' work as soon
      ;; as errors land, including in the interactive variant.
      (setq-local next-error-function #'compilation-next-error-function)

      ;; In compilation-style mode, swap only the local keymap.  Major mode stays
      ;; `ghostel-mode'
      ;; so the renderer/timer/resize hooks (which all gate on `derived-mode-p
      ;; \\='ghostel-mode\\=') keep working; only input handling changes.
      (unless interactive
        (use-local-map ghostel-compile-view-mode-map)
        (setq buffer-read-only t))
      ;; Enable the live toggle (`C-c C-j' / `C-c C-e') in compile
      ;; buffers, regardless of which run mode they're in.  The
      ;; minor-mode keymap takes precedence over the major-mode map
      ;; and the buffer-local map, so the keys work in both states.
      (ghostel-compile-toggle-mode 1)
      ;; Disable buffer-name tracking so a compile command's title or
      ;; directory report can't rename the buffer mid-run.
      (setq-local ghostel-buffer-name-function nil)
      ;; Disable password-prompt detection: `ghostel-compile--stty-flags'
      ;; runs the pty in `canonical+!echo' so the compile command isn't
      ;; double-echoed, but that's exactly the state libghostty's
      ;; password heuristic looks for - leaving detection on would pop
      ;; a `read-passwd' minibuffer at the start of every compile.
      (setq-local ghostel-detect-password-prompts nil)
      ;; Compile reruns reuse the same Emacs buffer.  Route the reset
      ;; and terminal creation through the shared initializer so buffer
      ;; and terminal state stay paired.
      (ghostel--init-buffer buffer height width)
      ;; `kill-compilation' locates our buffer via `compilation-find-buffer',
      ;; which requires `compilation-locs' to be buffer-local (see
      ;; `compilation-buffer-internal-p').  During the run we stay in
      ;; `ghostel-mode' so keystrokes reach the process, so `compilation-mode'
      ;; hasn't installed that variable yet — declare it locally now, with
      ;; the same hash-table shape `compilation-mode' uses so any code that
      ;; reads the value (future or third-party) doesn't trip on nil.
      ;; Finalize switches to `ghostel-compile-view-mode', which derives from
      ;; `compilation-mode' and will reset `compilation-locs' properly.
      (setq-local compilation-locs
                  (make-hash-table :test 'equal :weakness 'value)))
    buffer))


;;; Entry points

(defun ghostel-compile--start (command buffer-name dir
                                       &optional finished-mode interactive
                                       compilation-args)
  "Run COMMAND in BUFFER-NAME from DIR and return the buffer.
Creates or resets the buffer, spawns COMMAND via `shell-file-name',
and displays the buffer.  Used by both `ghostel-compile' and the
`compilation-start' advice installed by `ghostel-compile-global-mode'.

FINISHED-MODE, when non-nil, is the major mode to switch the
buffer into after finalize (overriding
`ghostel-compile-finished-major-mode').  The advice uses this to
honour custom compile-mode subclasses the caller passed to
`compilation-start'.

INTERACTIVE, when non-nil, runs COMMAND with terminal input forwarding.

COMPILATION-ARGS, when non-nil, is the list `(COMMAND MODE
NAME-FUNCTION HIGHLIGHT-REGEXP)' that gets stored as
`compilation-arguments' on the buffer so `\\[revert-buffer]' (and
any other code that walks `compilation-arguments') re-runs via
`compilation-start' with the original mode/name-function preserved."
  (unless (and command (not (string-blank-p command)))
    (user-error "Empty compile command"))
  (save-some-buffers (not compilation-ask-about-save)
                     compilation-save-buffers-predicate)
  (let* ((buffer (ghostel-compile--prepare-buffer buffer-name dir interactive))
         (outwin (display-buffer buffer '(nil (allow-no-window . t))))
         (start-time (current-time)))
    (with-current-buffer buffer
      ;; The buffer's major mode stays `ghostel-mode' during the run
      ;; (so the renderer/timer/resize hooks keep firing).  When
      ;; INTERACTIVE is non-nil, keystrokes reach the process for
      ;; programs like `htop', `less', or read prompts; otherwise the
      ;; buffer uses `compilation-mode'-style keys via
      ;; `ghostel-compile-view-mode-map' (see `--prepare-buffer').
      ;; Compile-mode error parsing kicks in at finalize when the
      ;; buffer is switched to `ghostel-compile-view-mode'.
      (setq ghostel-compile--command command
            ghostel-compile--directory dir
            ghostel-compile--start-time start-time
            ghostel-compile--last-exit nil
            ghostel-compile--finalized nil
            ghostel-compile--view-mode-override finished-mode
            ghostel-compile--interactive interactive)
      ;; Preserve the launch mode for `revert-buffer' and code that reads
      ;; `compilation-arguments'.
      (setq-local compilation-arguments
                  (or compilation-args
                      (list command (and interactive t) nil nil)))
      (setq-local revert-buffer-function #'compilation-revert-buffer)
      ;; `prepare-buffer' sized the VT from the selected window (no
      ;; display-buffer had happened yet).  `display-buffer' above may
      ;; have placed the buffer in a smaller window — reconcile the VT
      ;; to the output window *before* rendering the header, otherwise
      ;; the header and the command's early output wrap at the wrong
      ;; column and look garbled until the user's first resize triggers
      ;; `ghostel--adjust-size'.
      (when (and outwin ghostel--term)
        (let ((oh (max 1 (with-selected-window outwin
                           (floor (window-screen-lines)))))
              (ow (max 1 (window-max-chars-per-line outwin))))
          (ghostel--set-size ghostel--term oh ow)))
      ;; Render the compilation header into the terminal before spawning
      ;; the command, so the user sees the "Compilation started at ..."
      ;; banner *during* the run rather than only when it finishes (the
      ;; same behaviour `M-x compile' has).  Bytes are written as CRLF
      ;; so the VT parser lands on column 0 after each line.
      (ghostel-compile--render-header-live
       (ghostel-compile--header-text command start-time))
      ;; Place the scan marker at the buffer position right after the
      ;; header — NOT at `point-max' — because the VT renderer pads
      ;; the grid out to `ghostel--term-rows' lines, so `point-max'
      ;; sits well below the command's first output row.  Anchoring
      ;; here makes `--trim-trailing-blanks' correctly strip padding
      ;; between the last output line and the footer.
      ;;
      ;; The VT cursor's row after the render is where output will go;
      ;; use it directly (via `ghostel--cursor-pos') rather than
      ;; counting source newlines in the header text — a long command
      ;; line that wraps in the terminal would desynchronise otherwise.
      (setq ghostel-compile--scan-marker
            (save-excursion
              (goto-char (point-min))
              (forward-line (cdr ghostel--cursor-pos))
              (copy-marker (point))))
      (ghostel-compile--set-mode-line-running)
      ;; Match the VT size computed above (or fall back to the selected
      ;; window's own dimensions when `display-buffer' didn't surface a
      ;; window, e.g. `allow-no-window').  Use `window-max-chars-per-line'
      ;; as the canonical width measure, matching `ghostel--spawn-pty'.
      (let* ((height (max 1 (if outwin
                                (with-selected-window outwin
                                  (floor (window-screen-lines)))
                              (floor (window-screen-lines)))))
             (width (max 1 (if outwin
                               (window-max-chars-per-line outwin)
                             (window-max-chars-per-line))))
             (proc (ghostel-compile--spawn command buffer height width)))
        ;; Match stock `compilation-start' ordering: hook fires before
        ;; `compilation-in-progress' is updated, so hook functions can
        ;; install filter-hooks / error-regexps before the next
        ;; redisplay tick processes any output.
        (run-hook-with-args 'compilation-start-hook proc)
        (push proc compilation-in-progress)
        (when (fboundp 'compilation--update-in-progress-mode-line)
          (compilation--update-in-progress-mode-line))
        (setq next-error-last-buffer buffer)))
    buffer))

;;;###autoload
(defun ghostel-compile (command &optional interactive)
  "Run COMMAND in a ghostel terminal with compilation integration.

Like \\[compile], but uses a ghostel buffer so programs that require
a real TTY work correctly.  The buffer gets a compilation-mode-like
header and footer, and when the command finishes the major mode is
switched to `ghostel-compile-finished-major-mode' (by default
`ghostel-compile-view-mode', derived from `compilation-mode').
Error locations become available through `next-error'.

COMMAND is passed verbatim to `shell-file-name -c', so multi-line
scripts work exactly as in \\[shell-command].  No shell-integration
setup is required — the process sentinel reports the real exit
status.

If optional second arg INTERACTIVE is non-nil the buffer forwards
keystrokes to the terminal during the run.
Otherwise (the default) the buffer behaves like a `compilation-mode'
buffer with `g' reruns, `n'/`p' walk errors, etc.

Interactively, prompts for the command if option
`compilation-read-command' is non-nil, otherwise uses
`compile-command'.  With prefix arg, always prompts.

Output always scrolls as it arrives (equivalent to
`compilation-scroll-output' being non-nil).  `compilation-ask-about-save'
and `compilation-auto-jump-to-first-error' are honoured.  The command
default and history are shared with \\[compile] via `compile-command'
and `compile-history'."
  (interactive
   (list
    (let ((default (eval compile-command t)))
      (if (or compilation-read-command current-prefix-arg)
          (read-shell-command "Ghostel compile: " default
                              (if (equal (car compile-history) default)
                                  '(compile-history . 1)
                                'compile-history))
        default))
    (consp current-prefix-arg)))
  (unless (equal command (eval compile-command t))
    (setq compile-command command))
  (ghostel-compile--start command ghostel-compile-buffer-name
                          default-directory nil interactive))

(defun ghostel-recompile (&optional edit-command)
  "Re-run the last `ghostel-compile' command in its original directory.
If EDIT-COMMAND is non-nil, prompt for the command so the user can
edit it before running — interactively this is triggered by a
prefix arg, matching the convention of \\[recompile].

When invoked from a ghostel-compile buffer (any buffer with a
local `ghostel-compile--command'), re-runs into THAT buffer — the
window showing it stays put.  This matches `M-x recompile' in a
`*compilation*' buffer.  Otherwise falls back to
`ghostel-compile-buffer-name', and ultimately to `compile-command'
with the current `default-directory' when no prior run exists.

The launch mode (compilation-style vs interactive input) is preserved from the
source buffer's `ghostel-compile--interactive' flag, so a buffer
launched with \\[universal-argument] reruns interactively."
  (interactive "P")
  (let* ((source (cond
                  ((local-variable-p 'ghostel-compile--command)
                   (current-buffer))
                  ((get-buffer ghostel-compile-buffer-name))))
         (cmd (or (and (buffer-live-p source)
                       (buffer-local-value 'ghostel-compile--command source))
                  (eval compile-command t)))
         (dir (or (and (buffer-live-p source)
                       (buffer-local-value 'ghostel-compile--directory source))
                  default-directory))
         (name (if (buffer-live-p source)
                   (buffer-name source)
                 ghostel-compile-buffer-name))
         (launched-interactive (and (buffer-live-p source)
                                    (buffer-local-value
                                     'ghostel-compile--interactive source))))
    (unless (and cmd (not (string-blank-p cmd)))
      (user-error "No previous `ghostel-compile' command to re-run"))
    (when edit-command
      (setq cmd (read-shell-command
                 "Ghostel compile: " cmd
                 (if (equal (car compile-history) cmd)
                     '(compile-history . 1)
                   'compile-history)))
      (unless (equal cmd (eval compile-command t))
        (setq compile-command cmd)))
    (ghostel-compile--start cmd name dir nil launched-interactive)))


;;; Live toggle: switch between compilation-style and interactive input

(defun ghostel-compile--assert-live-run ()
  "Signal a `user-error' unless the current buffer has a live compile run.
Both toggle commands need a live process: switching is meaningful
only while the command is still running.  Post-finalize there is
nothing to send keystrokes to, and a non-compile buffer has no
`ghostel-compile--command' to begin with."
  (unless (and (derived-mode-p 'ghostel-mode)
               (local-variable-p 'ghostel-compile--command))
    (user-error "Not in a `ghostel-compile' buffer"))
  (unless (and (boundp 'ghostel--process) (process-live-p ghostel--process))
    (user-error "No live process - recompile with `g' instead")))

(defun ghostel-compile-switch-to-interactive ()
  "Switch the current `ghostel-compile' run to interactive mode.
`ghostel-semi-char-mode-map' is restored so keystrokes reach the running
process — useful when the command turned out to need input (a
`read -p', a `git push' password prompt, an `htop'-style program).
The renderer-owned buffer remains read-only.  No-op if the buffer
is already interactive.

Bound to \\[ghostel-compile-switch-to-interactive] in
`ghostel-compile-toggle-mode' (active in compile buffers)."
  (interactive)
  (ghostel-compile--assert-live-run)
  (if ghostel-compile--interactive
      (message "ghostel-compile: already interactive")
    (setq ghostel-compile--interactive t)
    (use-local-map ghostel-semi-char-mode-map)
    (setq buffer-read-only t)
    ;; Place point at the VT cursor so the user's first keystroke
    ;; lands at the prompt, not at wherever they happened to be
    ;; navigating in the read-only buffer.
    (when ghostel--term
      (let ((rc ghostel--cursor-pos))
        (goto-char (point-min))
        (forward-line (cdr rc))
        (move-to-column (car rc))))
    (ghostel-compile--set-mode-line-running)
    (when ghostel-compile-debug
      (message "ghostel-compile: switched to interactive"))))

(defun ghostel-compile-switch-to-compilation-style ()
  "Switch the current `ghostel-compile' run to compilation-mode-style navigation.
Restores `ghostel-compile-view-mode-map' as the local map, so `g'
reruns, `n'/`p' walk errors, RET jumps — the normal
`compilation-mode' UX — even while the command keeps running.
Subsequent recompiles will preserve this state.  No-op if the buffer
already uses compilation-style input.

Bound to \\[ghostel-compile-switch-to-compilation-style] in
`ghostel-compile-toggle-mode' (active in compile buffers)."
  (interactive)
  (ghostel-compile--assert-live-run)
  (if (not ghostel-compile--interactive)
      (message "ghostel-compile: already compilation-style")
    (setq ghostel-compile--interactive nil)
    (use-local-map ghostel-compile-view-mode-map)
    (setq buffer-read-only t)
    (ghostel-compile--set-mode-line-running)
    (when ghostel-compile-debug
      (message "ghostel-compile: switched to compilation-style"))))

(define-obsolete-function-alias 'ghostel-compile-switch-to-readonly
  #'ghostel-compile-switch-to-compilation-style "0.38.0")

(defvar ghostel-compile-toggle-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-j") #'ghostel-compile-switch-to-interactive)
    (define-key m (kbd "C-c C-e") #'ghostel-compile-switch-to-compilation-style)
    ;; Mirror `ghostel-mode's `C-c C-t' (= enter copy-mode, the
    ;; navigable freeze).  Compilation-style navigation is the closest
    ;; analogue, so binding it to the same key carries the muscle
    ;; memory across.
    (define-key m (kbd "C-c C-t") #'ghostel-compile-switch-to-compilation-style)
    m)
  "Keymap for `ghostel-compile-toggle-mode'.
\\<ghostel-compile-toggle-mode-map>\\[ghostel-compile-switch-to-interactive] switches to interactive
input; \\[ghostel-compile-switch-to-compilation-style] switches back to
compilation-mode-style navigation.  The latter is also bound to the same
key `ghostel-mode' uses for entering copy-mode, so muscle memory
carries across.  The minor-mode keymap takes precedence over both
the terminal-input and `ghostel-compile-view-mode-map' local maps,
so the keys work regardless of which run state the buffer is in.")

(define-minor-mode ghostel-compile-toggle-mode
  "Minor mode providing live mode-switching for `ghostel-compile' buffers.
Auto-enabled in `ghostel-compile' buffers (both during the run and
post-finalize).  Off elsewhere — regular `ghostel' terminals don't
get these bindings.

\\{ghostel-compile-toggle-mode-map}"
  :lighter nil
  :keymap ghostel-compile-toggle-mode-map)


;;; ghostel-compile-global-mode — opt-in: advise compilation-start

(defcustom ghostel-compile-global-mode-excluded-modes '(grep-mode)
  "Modes for which `ghostel-compile-global-mode' falls through to stock `compile'.
`grep-mode' is excluded by default because it has its own output
parsing and window-management conventions that don't fit a TTY.
Add your own compile-mode subclass to this list if you need to
opt a specific caller out."
  :type '(repeat symbol))

(defun ghostel-compile--compilation-start-advice
    (orig-fn command &optional mode name-function highlight-regexp continue)
  "Around advice for `compilation-start': route COMMAND through ghostel.
Falls back to ORIG-FN (with COMMAND, MODE, NAME-FUNCTION,
HIGHLIGHT-REGEXP, CONTINUE unchanged) when:

- MODE is in `ghostel-compile-global-mode-excluded-modes' — e.g.
  `grep-mode' by default.
- CONTINUE is non-nil — the caller wants to append to an existing
  compilation buffer; each `ghostel-compile' run replaces its
  buffer from scratch, so we can't honour that.

Otherwise routes COMMAND through `ghostel-compile--start':

- MODE is nil or `compilation-mode' - read-only ghostel buffer
- MODE is t - `compilation-start's request for an interactive
  comint buffer.  We honour the *interactive* part by forwarding
  terminal input (so programs that want a TTY still work) instead
  of falling through to `comint-mode'.
- MODE is a `compilation-mode' subclass — read-only ghostel
  buffer; finalize switches to that subclass so its error-regexp,
  font-lock keywords, and keymap are honoured.

NAME-FUNCTION drives the buffer name and HIGHLIGHT-REGEXP the
error highlighting in all cases."
  (cond
   ((or continue (memq mode ghostel-compile-global-mode-excluded-modes))
    (funcall orig-fn command mode name-function highlight-regexp continue))
   ((eq mode t)
    ;; MODE=t means interactive comint-style compilation.
    (let* ((buf-name (compilation-buffer-name "compilation" t name-function))
           (buffer (ghostel-compile--start
                    command buf-name default-directory nil t
                    (list command mode name-function highlight-regexp))))
      (when highlight-regexp
        (with-current-buffer buffer
          (setq-local compilation-highlight-regexp highlight-regexp)))
      buffer))
   (t
    (let* ((actual-mode (or mode 'compilation-mode))
           (name-of-mode
            (replace-regexp-in-string "-mode\\'" ""
                                      (symbol-name actual-mode)))
           (buf-name (compilation-buffer-name
                      name-of-mode actual-mode name-function))
           ;; Pass a custom compile-mode subclass through so finalize
           ;; can switch to it (honouring its error-regexp,
           ;; font-lock keywords, keymap, etc.).  For plain
           ;; `compilation-mode' we use nil so the default
           ;; `ghostel-compile-finished-major-mode'
           ;; (= `ghostel-compile-view-mode') kicks in, which derives
           ;; from `compilation-mode' and adds our own keybindings.
           (finished-mode (unless (eq actual-mode 'compilation-mode)
                            actual-mode))
           (buffer (ghostel-compile--start
                    command buf-name default-directory
                    finished-mode nil
                    (list command mode name-function highlight-regexp))))
      (when highlight-regexp
        (with-current-buffer buffer
          (setq-local compilation-highlight-regexp highlight-regexp)))
      buffer))))

;;;###autoload
(define-minor-mode ghostel-compile-global-mode
  "Global minor mode: route all `compile'-style calls through ghostel.

When enabled, advises `compilation-start' so that \\[compile],
\\[recompile], \\[project-compile], and every other caller that
goes through `compilation-start' runs in a ghostel terminal —
giving you a real TTY for progress bars, colours, and curses tools
without having to switch commands.

The default routing is read-only: a plain \\[compile] (or any caller
passing `MODE=nil' / `MODE=compilation-mode') yields a read-only buffer
that behaves like a `compilation-mode' buffer.  Callers asking for the
comint variant \(\\[universal-argument] \\[compile], i.e. `MODE=t') are
routed to an interactive ghostel terminal throughout the run, so
programs like `htop' or test prompts work - instead of falling
through to `comint-mode'.  Note: this means `compilation-shell-minor-mode'
is *not* enabled in the interactive variant - its keymap would shadow
`ghostel-mode's input handlers and break key forwarding to the PTY.
Custom `compilation-mode' subclasses yield a read-only buffer that
finalizes into the subclass.

Modes in `ghostel-compile-global-mode-excluded-modes' (by default,
`grep-mode') still use the stock implementation, since their output
parsers and window-management conventions don't fit a live TTY."
  :global t
  :group 'ghostel-compile
  (if ghostel-compile-global-mode
      (advice-add 'compilation-start :around
                  #'ghostel-compile--compilation-start-advice)
    (advice-remove 'compilation-start
                   #'ghostel-compile--compilation-start-advice)))


(provide 'ghostel-compile)

;;; ghostel-compile.el ends here
