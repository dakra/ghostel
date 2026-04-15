;;; ghostel-compile.el --- Compilation integration for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; Keywords: processes, tools, convenience
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run `compile'-style shell commands inside a ghostel terminal
;; buffer.  Unlike \\[compile] (which runs commands through comint),
;; `ghostel-compile' runs them in a real TTY via ghostel so programs
;; that detect a terminal (progress bars, colours, curses tools)
;; behave as they would in an interactive shell.
;;
;; The buffer mimics `compilation-mode': a "Compilation started at"
;; header, a "Compilation finished at ..., duration ..." footer (with
;; the same plain-text format and duration formula `M-x compile'
;; uses), and surrounding shell prompts are hidden so only the
;; command's own output is visible.  `mode-line-process' reflects
;; run/exit state with the same faces `M-x compile' uses.
;;
;; When the command finishes, the live shell and ghostel renderer are
;; torn down and the buffer's major mode is switched to
;; `ghostel-compile-view-mode' (derived from `compilation-mode').  At
;; that point the buffer is a regular, read-only Emacs buffer with
;; standard error highlighting and `next-error' navigation.  It will
;; not return to an interactive ghostel terminal — a recompile (`g',
;; `M-x ghostel-recompile') discards it and starts fresh in the
;; original `default-directory'.
;;
;; Completion is detected via the OSC 133 D semantic prompt marker,
;; so shell integration (`ghostel-shell-integration') must be
;; enabled — bundled bash, zsh and fish scripts emit those markers
;; automatically.  `ghostel-compile-debug' logs every OSC 133 C/D
;; event and the finalize call to *Messages* for diagnostics.
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
shell and ghostel rendering — the buffer never returns to an
interactive terminal."
  :type '(choice (const :tag "Compilation view (default)" ghostel-compile-view-mode)
                 (const :tag "Don't switch" nil)
                 (function :tag "Custom major mode")))

(defcustom ghostel-compile-hide-prompts t
  "When non-nil, hide OSC 133 prompt regions inside the scan range.
The command echo line and the trailing prompt printed by the shell
are marked invisible so only the command's own output is shown,
similar to `M-x compile'."
  :type 'boolean)

(defcustom ghostel-compile-clear-buffer t
  "When non-nil, clear the buffer (screen and scrollback) before each run.
Mirrors `M-x compile's behaviour of starting each compilation with a
fresh buffer.  Set to nil to keep previous runs visible above the
new one."
  :type 'boolean)

(defcustom ghostel-compile-debug nil
  "When non-nil, log OSC 133 C/D events from `ghostel-compile' to *Messages*.
Useful for diagnosing wrong exit codes, missed events, or shell
integration mismatches."
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

(defvar-local ghostel-compile--running nil
  "State of the in-flight `ghostel-compile' command.
- nil      : no command in flight (or finalize already ran)
- `pending': command was sent, but no OSC 133 C marker seen yet
- `armed'  : C marker seen; the next D marker will trigger finalize
- `fired'  : a D was accepted, finalize is scheduled; later Ds ignored")

(defvar-local ghostel-compile--header-marker nil
  "Marker at the end of the inserted compilation header.")

(defvar-local ghostel-compile--footer-marker nil
  "Marker at the start of the inserted compilation footer.")

(defvar-local ghostel-compile--finalize-timer nil
  "Pending finalize timer scheduled by `ghostel-compile--on-finish'.
Set when the first D marker after C is accepted; subsequent D
markers within the deferred window are ignored (first-D-wins) so
the real command's exit isn't overwritten by a follow-up prompt's
D;0.  Cleared by `ghostel-compile--finalize' once it actually
runs, or by `ghostel-compile-mode' on disable.")

(defvar-local ghostel-compile--owns-compilation-minor-mode nil
  "Non-nil if `ghostel-compile-mode' enabled `compilation-minor-mode'.
Tracked so disabling our mode only turns off `compilation-minor-mode'
when we were the ones who turned it on — never when the user (or
some other minor mode) had it enabled independently.")

(defvar ghostel-compile-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ghostel-recompile)
    map)
  "Keymap for `ghostel-compile-mode'.
Shadows `compilation-minor-mode-map' bindings that clash.")

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


;;; Helper functions
(define-derived-mode ghostel-compile-view-mode
  compilation-mode "Compilation"
  "Major mode for a finished `ghostel-compile' buffer.

A regular, read-only Emacs buffer.  `g' re-runs the command via
`ghostel-recompile', `n'/`p' walk errors in the buffer (without
opening files), RET jumps to the source.  The live shell and
ghostel rendering have been torn down; the buffer will not return
to a ghostel terminal."
  :group 'ghostel-compile
  ;; Make sure our keymap actually parents `compilation-mode-map' even
  ;; if it was created earlier — `define-derived-mode' won't reset an
  ;; already-set parent.
  (set-keymap-parent ghostel-compile-view-mode-map compilation-mode-map)
  (setq-local next-error-function #'compilation-next-error-function)
  ;; Make sure point lands at the top after a successful recompile (and
  ;; that future input doesn't inherit ghostel's terminal-style behaviour).
  (setq-local window-point-insertion-type nil))

(defun ghostel-compile--format-duration (seconds)
  "Format SECONDS (float) as a compilation-style duration string.
Matches the format used by `M-x compile'."
  (cond
   ((< seconds 10) (format "%.2f s" seconds))
   ((< seconds 60) (format "%.1f s" seconds))
   (t              (format-seconds "%h:%02m:%02s" seconds))))

(defun ghostel-compile--status-message (exit)
  "Return the compile-style status message string for EXIT status."
  (cond
   ((and (numberp exit) (= exit 0)) "finished\n")
   ((numberp exit) (format "exited abnormally with code %d\n" exit))
   (t              "finished\n")))

(defun ghostel-compile--hide-prompts (start end)
  "Hide OSC 133 prompt regions and echoed command lines in START..END.
A buffer line is marked invisible (together with its trailing
newline) when either condition holds:

1. Any character on the line carries the `ghostel-prompt' text
   property — the OSC 133 A..B prompt region rendered by the
   native renderer.

2. The line ends with `ghostel-compile--command' — the shell's
   PTY-echo of what we typed.  The native renderer applies
   `ghostel-prompt' only to the prompt glyph itself (A..B), not
   to the echoed command that follows on the same row, so without
   this second check the user would see the header's command
   followed by a duplicated `~/dir λ <cmd>' line right below it."
  (save-excursion
    (let ((cmd ghostel-compile--command))
      (goto-char start)
      (while (< (point) end)
        (let* ((bol (line-beginning-position))
               (eol (min end (line-end-position)))
               (hide (or
                      ;; 1. Prompt property anywhere on this line?
                      (text-property-not-all bol eol
                                             'ghostel-prompt nil)
                      ;; 2. Line ends with the echoed command?
                      (and cmd (not (string-empty-p cmd))
                           (let ((tail-start
                                  (max bol (- eol (length cmd)))))
                             (string= cmd
                                      (buffer-substring-no-properties
                                       tail-start eol)))))))
          (when hide
            (add-text-properties bol eol '(invisible t))
            (when (and (< eol end) (eq (char-after eol) ?\n))
              (add-text-properties eol (1+ eol) '(invisible t)))))
        (forward-line 1)))))

(defun ghostel-compile--clear-markers ()
  "Reset header/footer markers."
  (when (markerp ghostel-compile--header-marker)
    (set-marker ghostel-compile--header-marker nil))
  (when (markerp ghostel-compile--footer-marker)
    (set-marker ghostel-compile--footer-marker nil))
  (setq ghostel-compile--header-marker nil
        ghostel-compile--footer-marker nil))

(defun ghostel-compile--header-text (command start-time)
  "Return the header string for COMMAND started at START-TIME.
Plain text, matching the `M-x compile' header format."
  (format "-*- mode: ghostel-compile -*-\nCompilation started at %s\n\n%s\n"
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
    (format "\nCompilation %s at %s, duration %s\n"
            status-word ts (ghostel-compile--format-duration duration))))

(defun ghostel-compile--set-mode-line-running ()
  "Set `mode-line-process' to the running indicator."
  (setq mode-line-process
        (list '(:propertize ":run" face compilation-mode-line-run)
              'compilation-mode-line-errors))
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
  "Tear down the live shell and ghostel renderer in the current buffer.
Replaces the sentinel and filter with no-ops before deleting the
process.  Passing nil to `set-process-sentinel' restores the
*default* sentinel, which writes \"Process NAME killed: N\" into
the process buffer — exactly what we don't want."
  (when (and (bound-and-true-p ghostel--process)
             (process-live-p ghostel--process))
    (set-process-sentinel ghostel--process #'ignore)
    (set-process-filter ghostel--process #'ignore)
    (set-process-query-on-exit-flag ghostel--process nil)
    (delete-process ghostel--process)
    (setq ghostel--process nil))
  (when (bound-and-true-p ghostel--redraw-timer)
    (cancel-timer ghostel--redraw-timer)
    (setq ghostel--redraw-timer nil))
  (when (bound-and-true-p ghostel--input-timer)
    (cancel-timer ghostel--input-timer)
    (setq ghostel--input-timer nil)))

(defun ghostel-compile--finalize (buffer exit end-time)
  "Insert header/footer, hide prompts, parse errors for BUFFER.
EXIT is the command exit status; END-TIME its completion time.
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
      (let* ((start (and ghostel-compile--scan-marker
                         (marker-position ghostel-compile--scan-marker)))
             (start-time ghostel-compile--start-time)
             (command ghostel-compile--command)
             (directory ghostel-compile--directory)
             (header (ghostel-compile--header-text command start-time))
             (footer (ghostel-compile--footer-text exit start-time end-time))
             (inhibit-read-only t))
        (setq ghostel-compile--last-exit exit
              ghostel-compile--running nil
              ghostel-compile--finalize-timer nil)
        (when ghostel-compile-debug
          (message "ghostel-compile: finalizing exit=%S buffer=%S"
                   exit (buffer-name buffer)))
        (when (and start ghostel-compile-hide-prompts)
          (ghostel-compile--hide-prompts start (point-max)))
        (ghostel-compile--clear-markers)
        (ghostel-compile--teardown-terminal)
        ;; Switch major mode now that the shell is dead.  Preserve state
        ;; that `kill-all-local-variables' would otherwise wipe.
        (let ((saved-command command)
              (saved-start-time start-time)
              (saved-directory directory))
          (when ghostel-compile-finished-major-mode
            (funcall ghostel-compile-finished-major-mode))
          (setq-local ghostel-compile--command saved-command
                      ghostel-compile--directory saved-directory
                      ghostel-compile--start-time saved-start-time
                      ghostel-compile--last-exit exit)
          ;; Pin the buffer's `default-directory' to the directory the
          ;; user invoked `ghostel-compile' from, so it doesn't drift if
          ;; the shell happened to `cd' elsewhere during the run.
          (when saved-directory
            (setq default-directory saved-directory)))
        ;; Anchor header at the start of THIS run's output, not at
        ;; point-min — when `ghostel-compile-clear-buffer' is nil and
        ;; older output remains in the buffer, the header should still
        ;; bracket the right region.  Track the resulting parse-start
        ;; so jit-lock doesn't pick up stale matches above the run.
        (let* ((inhibit-read-only t)
               (header-anchor (or start (point-min)))
               (parse-start (copy-marker header-anchor)))
          (save-excursion
            (goto-char header-anchor)
            (insert header)
            (setq ghostel-compile--header-marker (point-marker))
            (set-marker-insertion-type ghostel-compile--header-marker nil))
          ;; Append footer at end-of-buffer; ensure separation from output.
          (save-excursion
            (goto-char (point-max))
            (unless (or (= (point) (point-min)) (bolp))
              (insert "\n"))
            (setq ghostel-compile--footer-marker (point-marker))
            (set-marker-insertion-type ghostel-compile--footer-marker nil)
            (insert footer))
          ;; Parse only this run's output.  Seed `compilation--parsed'
          ;; at the start of the run so `compilation--ensure-parse'
          ;; (and any later jit-lock pass) skip everything above it —
          ;; otherwise old output left over by `--clear-buffer nil'
          ;; would leak into `next-error' and the error count.  Note:
          ;; `compilation-mode' initialises `compilation--parsed' to
          ;; -1 (not a marker), so we set the marker ourselves.
          (save-excursion
            (save-restriction
              (widen)
              (setq-local compilation--parsed (copy-marker parse-start))
              (condition-case err
                  (compilation--ensure-parse (point-max))
                (error
                 (message "ghostel-compile: error scanning output: %s"
                          (error-message-string err)))))))
        ;; Put point at `point-max' — past the footer — so the user
        ;; actually sees the "Compilation finished at ..., duration ..."
        ;; line instead of having it scroll below the window bottom.
        ;; Recenter each window on this buffer so that line is flush
        ;; with the bottom of the window.
        (goto-char (point-max))
        (dolist (win (get-buffer-window-list buffer nil t))
          (set-window-point win (point-max))
          (with-selected-window win (recenter -1))))
      (ghostel-compile--set-mode-line-exit exit)
      (setq next-error-last-buffer buffer)
      (ghostel-compile--auto-jump buffer)
      (let ((msg (ghostel-compile--status-message exit)))
        (run-hook-with-args 'compilation-finish-functions buffer msg)
        (run-hook-with-args 'ghostel-compile-finish-functions buffer msg)))))

(defun ghostel-compile--on-start (buffer)
  "Hook function: arm finalize gating for BUFFER on OSC 133 C marker.
A D marker is only treated as the user command's exit when a C
marker has been seen since `ghostel-compile' was invoked.  This
filters out spurious D markers from prompt redraws (e.g. shell
clear-screen handlers after we send `\\f' to refresh the display).

When we transition from `pending' to `armed', snap the scan
marker to the current `point-max'.  The scan marker must land
*after* any content the shell rendered in response to our clear
(the fresh prompt re-echo), which arrives asynchronously through
the process filter — not synchronously during `ghostel-compile'.
The C marker is emitted by the shell's preexec / DEBUG trap right
before the user's command starts producing output, so point-max
at that moment is exactly the boundary between \"pre-command
noise\" and the command's real output."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'ghostel-compile-mode buffer))
    (with-current-buffer buffer
      (when ghostel-compile-debug
        (message "ghostel-compile: OSC 133 C — running=%S"
                 ghostel-compile--running))
      (when (eq ghostel-compile--running 'pending)
        (setq ghostel-compile--running 'armed
              ghostel-compile--scan-marker (copy-marker (point-max)))))))

(defun ghostel-compile--on-finish (buffer exit)
  "Hook function: schedule finalize for BUFFER with EXIT status.

Runs deferred so any rendering from the same output batch settles
first.  Only acts when `ghostel-compile--running' is `armed' (i.e.
a C marker has been seen) — D markers from prompt redraws or other
shell activity that haven't been preceded by a C are ignored.

The first D after C wins.  Subsequent Ds before finalize actually
fires are ignored, so a follow-up prompt's D;0 cannot overwrite
the real command's exit status."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'ghostel-compile-mode buffer))
    (with-current-buffer buffer
      (when ghostel-compile-debug
        (message "ghostel-compile: OSC 133 D;%S — running=%S"
                 exit ghostel-compile--running))
      (when (eq ghostel-compile--running 'armed)
        (setq ghostel-compile--running 'fired
              ghostel-compile--finalize-timer
              (run-at-time 0.05 nil
                           #'ghostel-compile--finalize
                           buffer exit (current-time)))))))

(define-minor-mode ghostel-compile-mode
  "Minor mode that turns a ghostel buffer into a compilation buffer.

When enabled, an OSC 133 D marker triggers an error scan over the
command's output, a compilation-style header/footer is inserted,
surrounding prompts are hidden, and the buffer's major mode is
switched to `ghostel-compile-finished-major-mode' (by default
`ghostel-compile-view-mode' — derived from `compilation-mode').
Pressing \\<ghostel-compile-mode-map>\\[ghostel-recompile] re-runs
the last command."
  :lighter " gh-compile"
  :keymap ghostel-compile-mode-map
  (cond
   (ghostel-compile-mode
    (unless (derived-mode-p 'ghostel-mode)
      (setq ghostel-compile-mode nil)
      (user-error "`ghostel-compile-mode' can only be enabled in a ghostel buffer"))
    ;; Only adopt `compilation-minor-mode' if it isn't already on, and
    ;; remember whether we turned it on so we don't yank it from under
    ;; some other consumer when our mode is disabled.
    (setq ghostel-compile--owns-compilation-minor-mode
          (not (bound-and-true-p compilation-minor-mode)))
    (compilation-minor-mode 1)
    (setq-local next-error-function #'compilation-next-error-function)
    ;; Ensure our `g' binding wins over `compilation-minor-mode-map'.
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'ghostel-compile-mode ghostel-compile-mode-map)
                      (assq-delete-all
                       'ghostel-compile-mode
                       minor-mode-overriding-map-alist)))
    (add-hook 'ghostel-command-start-functions
              #'ghostel-compile--on-start nil t)
    (add-hook 'ghostel-command-finish-functions
              #'ghostel-compile--on-finish nil t))
   (t
    (setq-local minor-mode-overriding-map-alist
                (assq-delete-all
                 'ghostel-compile-mode
                 minor-mode-overriding-map-alist))
    (remove-hook 'ghostel-command-start-functions
                 #'ghostel-compile--on-start t)
    (remove-hook 'ghostel-command-finish-functions
                 #'ghostel-compile--on-finish t)
    ;; Cancel any pending finalize and reset the in-flight state so
    ;; turning the mode off mid-command doesn't leak `pending'/`armed'
    ;; into the next enable cycle.
    (when (timerp ghostel-compile--finalize-timer)
      (cancel-timer ghostel-compile--finalize-timer))
    (setq ghostel-compile--finalize-timer nil
          ghostel-compile--running nil)
    ;; Only turn off `compilation-minor-mode' (and the `next-error'
    ;; wiring that goes with it) if WE turned it on; otherwise the
    ;; user's pre-existing `compilation-minor-mode' would be left
    ;; with its `next-error-function' yanked out from under it.
    (when (and ghostel-compile--owns-compilation-minor-mode
               (bound-and-true-p compilation-minor-mode))
      (compilation-minor-mode -1)
      (kill-local-variable 'next-error-function))
    (setq ghostel-compile--owns-compilation-minor-mode nil))))

(defun ghostel-compile--get-or-create-buffer ()
  "Return a live ghostel-compile buffer, creating one if needed.
Uses the caller's `default-directory' as the new buffer's working
directory — captured before any buffer kill, so that
`ghostel-recompile' (which kills the previous `view-mode' buffer)
runs in the directory bound by its caller, not whatever buffer
happens to be current after the kill."
  (let ((existing (get-buffer ghostel-compile-buffer-name))
        (dir default-directory))
    (if (and existing
             (with-current-buffer existing
               (and (derived-mode-p 'ghostel-mode)
                    ghostel--process
                    (process-live-p ghostel--process))))
        existing
      (when existing
        (kill-buffer existing))
      (let ((ghostel-buffer-name ghostel-compile-buffer-name)
            (default-directory dir))
        (ghostel))
      (get-buffer ghostel-compile-buffer-name))))


;;; Public `ghostel-compile' entry point

;;;###autoload
(defun ghostel-compile (command)
  "Run COMMAND in a ghostel terminal with compilation integration.

Like \\[compile], but uses a ghostel buffer so programs that require
a real TTY work correctly.  The buffer gets a compilation-mode-like
header and footer, surrounding prompts are hidden, and when the
command finishes (detected via the OSC 133 D semantic prompt marker)
the major mode is switched to `ghostel-compile-finished-major-mode'
\(by default `ghostel-compile-view-mode', derived from
`compilation-mode').  Error locations become available through
`next-error'.

Output always scrolls as it arrives (equivalent to
`compilation-scroll-output' being non-nil).  `compilation-ask-about-save'
and `compilation-auto-jump-to-first-error' are honoured.  The command
default and history are shared with \\[compile] via `compile-command'
and `compile-history'.

Requires shell integration; see `ghostel-shell-integration'."
  (interactive
   (list
    (let ((default (eval compile-command t)))
      (if (or compilation-read-command current-prefix-arg)
          (read-shell-command "Ghostel compile: " default
                              (if (equal (car compile-history) default)
                                  '(compile-history . 1)
                                'compile-history))
        default))))
  (unless (equal command (eval compile-command t))
    (setq compile-command command))
  (save-some-buffers (not compilation-ask-about-save)
                     compilation-save-buffers-predicate)
  (let ((buffer (ghostel-compile--get-or-create-buffer)))
    (with-current-buffer buffer
      (when (bound-and-true-p ghostel--copy-mode-active)
        (ghostel-copy-mode-exit))
      (unless ghostel-compile-mode
        (ghostel-compile-mode 1))
      (ghostel-compile--clear-markers)
      (when ghostel-compile-clear-buffer
        (ghostel-clear-scrollback))
      ;; The scan marker is snapped by `ghostel-compile--on-start' when
      ;; the shell emits OSC 133 C — by then any async output from our
      ;; clear-scrollback's `\\f' (the re-echoed prompt) has already
      ;; landed, so the marker lands exactly at the command's own
      ;; output boundary instead of above that noise.
      (setq ghostel-compile--command command
            ghostel-compile--directory default-directory
            ghostel-compile--start-time (current-time)
            ghostel-compile--last-exit nil
            ghostel-compile--running 'pending
            ghostel-compile--scan-marker nil)
      (ghostel-compile--set-mode-line-running)
      (ghostel--flush-output (concat command "\n")))
    (pop-to-buffer buffer (append display-buffer--same-window-action
                                  '((category . comint))))))

(defun ghostel-recompile ()
  "Re-run the last `ghostel-compile' command in its original directory.
Falls back to `compile-command' (and the current `default-directory')
when no ghostel compile has run yet."
  (interactive)
  (let* ((buf (get-buffer ghostel-compile-buffer-name))
         (cmd (or (and (buffer-live-p buf)
                       (buffer-local-value 'ghostel-compile--command buf))
                  (eval compile-command t)))
         (dir (or (and (buffer-live-p buf)
                       (buffer-local-value 'ghostel-compile--directory buf))
                  default-directory)))
    (unless (and cmd (not (string-blank-p cmd)))
      (user-error "No previous `ghostel-compile' command to re-run"))
    (let ((default-directory dir))
      (ghostel-compile cmd))))

(provide 'ghostel-compile)

;;; ghostel-compile.el ends here
