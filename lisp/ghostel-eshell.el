;;; ghostel-eshell.el --- Eshell integration for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run Eshell "visual" commands (programs in `eshell-visual-commands',
;; `eshell-visual-subcommands', and `eshell-visual-options' — e.g. vim,
;; htop, less, top) inside a dedicated ghostel buffer.  Eshell's default
;; implementation uses `term-mode' via `eshell-exec-visual'; this mode
;; overrides that to dispatch through `ghostel-exec' so full-screen
;; TUIs get a real terminal emulator.
;;
;; `ghostel-eshell-mode' is the in-buffer alternative: it runs every
;; interactive external Eshell command in a terminal region inside the
;; Eshell buffer itself, so output interleaves with the prompts and the
;; final screen is frozen into ordinary buffer text.  It supersedes
;; `ghostel-eshell-visual-command-mode' while enabled.
;;
;; Enable with:
;;
;;   (add-hook 'eshell-load-hook #'ghostel-eshell-visual-command-mode)
;;   ;; or, for in-buffer terminals:
;;   (add-hook 'eshell-load-hook #'ghostel-eshell-mode)
;;
;; Running ad-hoc commands in a ghostel buffer without adding them to
;; `eshell-visual-commands' is also supported via the `ghostel' eshell
;; built-in:
;;
;;   ~ $ ghostel nethack
;;
;; Add a shorter alias in your init.el if you like:
;;
;;   (defalias 'eshell/v 'eshell/ghostel)    ;; then:  ~ $ v nethack

;;; Code:

(require 'cl-lib)
(require 'ghostel)
(require 'ghostel-embedded)

(defvar eshell-interpreter-alist)
(defvar eshell-destroy-buffer-when-process-dies)

(declare-function eshell-find-interpreter "esh-ext"
                  (file args &optional no-examine-p))
(declare-function eshell-stringify-list "esh-util" (args))
(declare-function eshell-exec-visual "em-term" (&rest args))
(declare-function eshell-gather-process-output "esh-proc" (command args))
(declare-function eshell-interactive-output-p "esh-io"
                  (&optional index handles))

(defvar eshell-current-subjob-p)
(defvar eshell-last-input-end)
(defvar eshell-last-output-start)
(defvar eshell-last-output-end)

(defcustom ghostel-eshell-track-title nil
  "Whether to let visual-command buffers rename themselves via OSC titles.
When nil (the default), the visual-command buffer keeps its initial
name (e.g. \"*vim*\") for the duration of the program.  When non-nil,
OSC 0/2 title escapes rename the buffer via `ghostel-buffer-name-by-title'."
  :type 'boolean
  :group 'ghostel)

(defun ghostel-eshell--visual-exit (buffer _event)
  "Post-exit cleanup for a visual-command BUFFER.
Deferred via `run-at-time' so ghostel's sentinel runs first.  No-op if
the buffer was killed \(i.e. `ghostel-kill-buffer-on-exit' was non-nil).
Otherwise snaps point and all windows showing BUFFER to `point-max' and
binds `q' to dismiss the buffer."
  (run-at-time
   0 nil
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (goto-char (point-max))
         ;; Bind `q' in a fresh buffer-local map to not mutate the shared
         ;; `ghostel-semi-char-mode-map' and leak into other buffers.
         (let ((map (make-sparse-keymap)))
           (set-keymap-parent map (current-local-map))
           (keymap-set map "q" #'kill-current-buffer)
           (use-local-map map))
         (dolist (win (get-buffer-window-list buffer nil t))
           (set-window-point win (point-max))))))))

(defun ghostel-eshell--exec-visual (&rest args)
  "Replacement for `eshell-exec-visual' that dispatches to ghostel.
ARGS are the program name followed by its arguments, as passed by
eshell."
  (require 'esh-ext)
  (require 'esh-util)
  (save-current-buffer
    (let* ((eshell-interpreter-alist nil)
           (interp (eshell-find-interpreter (car args) (cdr args)))
           (program (car interp))
           (prog-args (flatten-tree
                       (eshell-stringify-list
                        (append (cdr interp) (cdr args)))))
           (buf (generate-new-buffer
                 (concat "*" (file-name-nondirectory program) "*")))
           (kill-on-exit
            (bound-and-true-p eshell-destroy-buffer-when-process-dies)))
      (switch-to-buffer buf)
      ;; A child that exits while TRAMP is still inside `make-process'
      ;; reaches the sentinel before the buffer-local below is set.
      (let ((ghostel-kill-buffer-on-exit kill-on-exit))
        (ghostel-exec buf program prog-args
                      `((kind . eshell) (command . (,program . ,prog-args)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq-local ghostel-kill-buffer-on-exit kill-on-exit)
          (setq-local ghostel-buffer-name-function
                      (and ghostel-eshell-track-title
                           #'ghostel-buffer-name-by-title))
          (add-hook 'ghostel-exit-functions
                    #'ghostel-eshell--visual-exit nil t)
          (unless (process-live-p ghostel--process)
            (ghostel-eshell--visual-exit buf nil))))
      nil)))

;;;###autoload
(defun eshell/ghostel (&rest args)
  "Run ARGS as a visual command in a dedicated ghostel buffer.
This is an eshell built-in; type `ghostel PROGRAM ...' at the
eshell prompt to launch any program in a ghostel terminal buffer
without adding it to `eshell-visual-commands'.  Dispatches through
`eshell-exec-visual', so when `ghostel-eshell-visual-command-mode'
is enabled the program runs under ghostel; otherwise it falls
back to eshell's default `term-mode' visual handling."
  (apply #'eshell-exec-visual args))

;;;###autoload
(define-minor-mode ghostel-eshell-visual-command-mode
  "Run Eshell visual commands (vim, htop, less, ...) in ghostel buffers.
When enabled, `eshell-exec-visual' is overridden to launch the
program in a dedicated ghostel terminal buffer.  When the program
exits, the buffer stays on `[Process exited]' so any remaining
output is visible; press `q' to dismiss it.  Set
`eshell-destroy-buffer-when-process-dies' to non-nil to kill the
buffer automatically on exit instead."
  :global t
  :group 'ghostel
  (if ghostel-eshell-visual-command-mode
      (advice-add 'eshell-exec-visual :override
                  #'ghostel-eshell--exec-visual)
    (advice-remove 'eshell-exec-visual
                   #'ghostel-eshell--exec-visual)))

;;; In-buffer terminal mode

(define-minor-mode ghostel--eshell-local-mode
  "Enable in-buffer terminal emulation in this Eshell buffer.
This is internal state for `ghostel-eshell-mode'; enable that global
mode instead."
  :lighter nil
  (if ghostel--eshell-local-mode
      (progn
        (add-hook 'window-size-change-functions
                  #'ghostel--eshell-window-size-change nil t)
        (add-hook 'ghostel-embedded-redraw-hook
                  #'ghostel--eshell-adjust-screen nil t)
        (add-hook 'kill-buffer-hook #'ghostel--eshell-cleanup nil t))
    (remove-hook 'window-size-change-functions
                 #'ghostel--eshell-window-size-change t)
    (remove-hook 'ghostel-embedded-redraw-hook
                 #'ghostel--eshell-adjust-screen t)
    (remove-hook 'kill-buffer-hook #'ghostel--eshell-cleanup t)))

(defun ghostel--eshell-embed-p ()
  "Return non-nil when the current Eshell command can run in a terminal.
Checks everything but the `stty' fallback, so callers that merely
classify a command do not prompt.

A pipeline element is excluded: its standard input is a pipe rather
than the terminal, so an embedded terminal could not drive it, and
writing to that pipe from the process filter can deadlock the
pipeline (Eshell's writer blocks and re-enters the producer's filter
recursively)."
  (and (bound-and-true-p ghostel--eshell-local-mode)
       (not (file-remote-p default-directory))
       (not (bound-and-true-p eshell-current-subjob-p))
       (not (bound-and-true-p eshell-in-pipeline-p))
       (eshell-interactive-output-p)))

(defun ghostel--eshell-visual-command-p (orig command args)
  "Treat visual commands as ordinary external commands in Eshell.
ORIG is the original `eshell-visual-command-p', called with COMMAND and
ARGS.  When the command can run in an embedded terminal, returning nil
routes it through the normal external-command path, where
`ghostel-eshell-mode' attaches a terminal instead of opening a separate
buffer.  Commands that cannot be embedded — a pipeline element, a
subjob, a remote command, or with the local mode off — keep Eshell's
visual handling, because a pipeline element's stdin is a pipe and an
embedded terminal cannot interact with it.  A pipeline element also
gets a hint, since Eshell's visual handling discards the piped input."
  (if (ghostel--eshell-embed-p)
      nil
    (let ((visual (funcall orig command args)))
      (when (and visual
                 (bound-and-true-p ghostel--eshell-local-mode)
                 (bound-and-true-p eshell-in-pipeline-p))
        (message "Piped input is dropped for visual command `%s'; redirect the output to a file and open the file instead"
                 command))
      visual)))

(defcustom ghostel-eshell-lighter-prefix
  (let ((char ?\))
    (if (and (char-displayable-p char)
             ;; `char-displayable-p' says the character is in principle
             ;; displayable; `internal-char-font' says a font can actually
             ;; render it.
             (fboundp 'internal-char-font)
             (internal-char-font nil char))
        (concat "(" (string char) " tty)")
      "G-eshell"))
  "Prefix for the `ghostel-eshell-mode' mode-line lighter.
The default is chosen once, when ghostel-eshell loads, in the frame
selected at that time; customize it to force a selection."
  :type '(choice (const :tag "(<Ghost> tty)" "( tty)")
                 (const :tag "Letter G" "G-eshell")
                 (const :tag "xiǎo yōu líng (little ghost)" "小幽灵")
                 (string :tag "Or enter a custom string"))
  :group 'ghostel)

;;;###autoload
(define-minor-mode ghostel-eshell-mode
  "Run interactive external commands in the Eshell buffer itself.
When enabled, Eshell's interactive external commands — including visual
programs such as vim, htop and less — run in a ghostel terminal embedded
in the Eshell buffer.  Their output interleaves with the normal Eshell
prompts, and the final screen is frozen into ordinary buffer text when
the program exits.

Visual commands no longer open a separate buffer, so this mode supersedes
`ghostel-eshell-visual-command-mode' while it is enabled.  Commands whose
output is piped, redirected or run as a subjob keep using Eshell's normal
output path, as do commands in remote buffers.

Add it to `eshell-load-hook'."
  :global t
  :group 'ghostel
  :lighter (ghostel--eshell-local-mode
            ((:eval (format " %s" ghostel-eshell-lighter-prefix))
             (:eval (ghostel--eshell-lighter))))
  (cond
   (ghostel-eshell-mode
    (require 'esh-mode)
    (require 'esh-proc)
    (require 'esh-var)
    (require 'esh-cmd)
    (require 'em-term)
    (advice-add 'eshell-visual-command-p :around
                #'ghostel--eshell-visual-command-p)
    (advice-add 'eshell-gather-process-output :around
                #'ghostel--eshell-gather-process-output)
    (add-hook 'eshell-mode-hook #'ghostel--eshell-local-mode)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'eshell-mode)
          (ghostel--eshell-local-mode 1)))))
   (t
    (advice-remove 'eshell-visual-command-p
                   #'ghostel--eshell-visual-command-p)
    (advice-remove 'eshell-gather-process-output
                   #'ghostel--eshell-gather-process-output)
    (remove-hook 'eshell-mode-hook #'ghostel--eshell-local-mode)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'eshell-mode)
          (ghostel--eshell-local-mode -1)))))))

;;; In-buffer process attachment

(defconst ghostel--eshell-lighter-maps
  (let (maps)
    (dolist (entry '((semi-char ghostel-embedded-char-mode
                                ghostel-embedded-emacs-mode)
                     (char ghostel-embedded-semi-char-mode
                           ghostel-embedded-emacs-mode)
                     (emacs ghostel-embedded-semi-char-mode
                            ghostel-embedded-char-mode)))
      (let ((map (make-sparse-keymap)))
        (define-key map [mode-line mouse-1] (nth 1 entry))
        (define-key map [mode-line mouse-3] (nth 2 entry))
        (push (cons (car entry) map) maps)))
    (nreverse maps))
  "Clickable keymaps for the `ghostel-eshell-mode' lighter, by input mode.
A left click switches to the first command in the entry, a right click to
the second.  They are built once so a mode-line redraw, which calls
`ghostel--eshell-lighter' through `:eval', allocates nothing.")

(defun ghostel--eshell-lighter ()
  "Return the in-buffer terminal's input-mode tag, or nil.
Shown in the mode line while `ghostel-eshell-mode' is active and a
terminal is running in the current buffer.  Clicking the tag switches
input mode."
  (when (ghostel--embedded-live-p ghostel--embedded-session)
    (let* ((mode (or (ghostel-embedded-input-mode ghostel--embedded-session)
                     'semi-char))
           (help (pcase mode
                   ('semi-char
                    "mouse-1: Switch to char mode, mouse-3: Switch to emacs mode")
                   ('char
                    "mouse-1: Switch to semi-char mode, mouse-3: Switch to emacs mode")
                   (_
                    "mouse-1: Switch to semi-char mode, mouse-3: Switch to char mode"))))
      `("["
        (:propertize ,(symbol-name mode)
                     help-echo ,help
                     mouse-face mode-line-highlight
                     local-map ,(cdr (assq mode ghostel--eshell-lighter-maps)))
        "]"))))

(defcustom ghostel-eshell-fallback-if-stty-unavailable 'ask
  "How to handle a missing `stty' for in-buffer Eshell terminals.
`stty' is needed to give the PTY the terminal region's size before the
program starts.  `ask' prompts before giving up the terminal; t falls
back to Eshell's normal output silently; nil uses the terminal anyway,
which can leave the program with a wrong window size."
  :type '(choice (const :tag "Ask" ask)
                 (const :tag "Fall back to normal Eshell output" t)
                 (const :tag "Use the terminal anyway" nil))
  :group 'ghostel)

(defvar ghostel--eshell-stty-available :unknown
  "Cached result of looking `stty' up in the variable `exec-path'.")

(defun ghostel--eshell-stty-available-p ()
  "Return non-nil when `stty' can size the PTY before the program runs."
  (when (eq ghostel--eshell-stty-available :unknown)
    (setq ghostel--eshell-stty-available
          (and (executable-find "stty") t)))
  ghostel--eshell-stty-available)

(defun ghostel--eshell-stty-ok-p ()
  "Return non-nil when the `stty' requirement for a terminal is met.
Honors `ghostel-eshell-fallback-if-stty-unavailable' when `stty' is
missing."
  (or (ghostel--eshell-stty-available-p)
      (pcase ghostel-eshell-fallback-if-stty-unavailable
        ('t nil)
        ('nil t)
        (_ (not (y-or-n-p
                 "ghostel: `stty' not found; disable the in-buffer terminal for this command? "))))))

(defun ghostel--eshell-use-terminal-p ()
  "Return non-nil when the current Eshell command should run in a terminal.
Skips subjobs, pipeline elements, commands whose output is not
interactive output, remote buffers and the missing-`stty' fallback."
  (and (ghostel--eshell-embed-p)
       (ghostel--eshell-stty-ok-p)))

(defun ghostel--eshell-terminal-size (&optional window position full)
  "Return (ROWS . COLS) for an in-buffer terminal in the current buffer.
ROWS fills the part of WINDOW below POSITION, the region start, so a
program can use all remaining space while the prompt stays visible.
When FULL is non-nil, ROWS fills the whole window, which full-screen TUI
programs expect.  POSITION defaults to the live session's region start.
COLS is the window's line width."
  (let* ((window (or window
                     (get-buffer-window (current-buffer) t)
                     (selected-window)))
         (position (or position
                       (and (ghostel--embedded-live-p
                             ghostel--embedded-session)
                            (marker-position
                             (ghostel-embedded-start
                              ghostel--embedded-session)))))
         (cols (if (window-live-p window)
                   (max 1 (window-max-chars-per-line window))
                 80))
         (rows (if (window-live-p window)
                   (with-selected-window window
                     (let* ((total (max 1 (floor (window-screen-lines))))
                            (used (if (and (not full)
                                           position
                                           (pos-visible-in-window-p
                                            position window))
                                      (max 0 (- (line-number-at-pos position)
                                                (line-number-at-pos
                                                 (window-start))))
                                    0)))
                       (if full total (max 1 (- total used)))))
                 24)))
    (cons rows cols)))

(defun ghostel--eshell-window-size-change (window)
  "Resize the in-buffer terminal when WINDOW changes size.
WINDOW is the argument `window-size-change-functions' passes for the
buffer it belongs to."
  (when (and (window-live-p window)
             (buffer-live-p (window-buffer window)))
    (with-current-buffer (window-buffer window)
      (when (ghostel--embedded-live-p ghostel--embedded-session)
        (let* ((session ghostel--embedded-session)
               (full (ghostel-embedded-alt-screen-p session))
               (size (ghostel--eshell-terminal-size window nil full)))
          (ghostel--embedded-resize session (car size) (cdr size)))))))

(defun ghostel--eshell-adjust-screen (session)
  "Resize SESSION when it enters or leaves the alternate screen.
A full-screen TUI gets the whole window; on exit the terminal returns to
the space below the prompt, restoring the previous layout."
  (when (ghostel--embedded-live-p session)
    (let ((alt (ghostel--alt-screen-p (ghostel-embedded-term session))))
      (unless (eq alt (ghostel-embedded-alt-screen-p session))
        (setf (ghostel-embedded-alt-screen-p session) alt)
        (let ((size (ghostel--eshell-terminal-size nil nil alt)))
          (ghostel--embedded-resize session (car size) (cdr size) t))))))

(defun ghostel--eshell-attach-process (process &optional size)
  "Attach an embedded terminal to PROCESS in its Eshell buffer.
SIZE is the terminal's (ROWS . COLS) and defaults to the current window
size.  The region starts at the end of the buffer, on a fresh line.
Returns the new session."
  (with-current-buffer (process-buffer process)
    ;; A leftover session would still own the renderer's buffer-local
    ;; state; freeze it before starting the next command.
    (when (ghostel--embedded-live-p ghostel--embedded-session)
      (ghostel--embedded-finish ghostel--embedded-session))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (let* ((size (or size (ghostel--eshell-terminal-size nil (point))))
           (session (ghostel--embedded-start (current-buffer)
                                             (point)
                                             (car size) (cdr size))))
      (ghostel--embedded-attach-process session process)
      (ghostel--embedded-activate-input session)
      (process-put process 'ghostel--eshell-session session)
      (process-put process 'ghostel--eshell-invocation-directory
                   default-directory)
      (process-put process 'ghostel--eshell-original-filter
                   (process-filter process))
      (process-put process 'ghostel--eshell-original-sentinel
                   (process-sentinel process))
      ;; Raw binary I/O, matching `ghostel' proper: the filter must see
      ;; undecoded bytes.  With Eshell's decoding, a truncated multibyte
      ;; sequence (e.g. a box-drawing glyph cut off by C-c C-c) arrives as a
      ;; multibyte string holding a raw byte, which the module's string
      ;; extraction rejects with `ExtractStringFailed'.
      (set-process-coding-system process 'binary 'binary)
      (set-process-filter process #'ghostel--eshell-filter)
      (set-process-sentinel process #'ghostel--eshell-sentinel)
      session)))

(defun ghostel--eshell-filter (process output)
  "Render OUTPUT from PROCESS in its embedded terminal.
The raw bytes never reach the Eshell buffer: the terminal owns the
region and materializes them as text itself."
  (let ((session (process-get process 'ghostel--eshell-session)))
    (when session
      (ghostel--embedded-feed session output))))

(defun ghostel--eshell-sentinel (process event)
  "Freeze PROCESS's embedded terminal and hand control back to Eshell.
EVENT is the process state-change description passed to sentinels.
The frozen region becomes ordinary buffer text, Eshell's output markers
move past it, the original filter/sentinel are restored and chained, and
`default-directory' returns to the command's invocation directory."
  (let ((session (process-get process 'ghostel--eshell-session))
        (original (process-get process 'ghostel--eshell-original-sentinel))
        (original-filter (process-get process 'ghostel--eshell-original-filter))
        (directory (process-get process 'ghostel--eshell-invocation-directory))
        pos)
    (when (buffer-live-p (process-buffer process))
      (with-current-buffer (process-buffer process)
        (when session
          (ghostel--embedded-finish session)
          (setq pos (ghostel--eshell-region-end session))
          (when pos
            (ghostel--eshell-resync-output pos)
            (when (markerp (process-mark process))
              (set-marker (process-mark process) pos))))
        (when (and directory (file-directory-p directory))
          (setq default-directory directory))
        (when original-filter
          (set-process-filter process original-filter))))
    (when original
      (set-process-sentinel process original)
      (funcall original process event))
    ;; After a signal (e.g. "interrupt") Eshell inserts a message and can
    ;; move its markers such that `eshell-delete-output' would try to
    ;; delete the read-only prompt.  Re-point `eshell-last-input-end' at
    ;; the frozen region's start and `eshell-last-output-start' at its end
    ;; so the delete stays confined to the terminal's rows.
    (when (and session pos (buffer-live-p (process-buffer process)))
      (with-current-buffer (process-buffer process)
        (let ((start (marker-position (ghostel-embedded-start session))))
          (when (and start (boundp 'eshell-last-input-end)
                     (markerp eshell-last-input-end))
            (set-marker eshell-last-input-end start))
          (when (and (boundp 'eshell-last-output-start)
                     (markerp eshell-last-output-start))
            (set-marker eshell-last-output-start pos)))))))

(defun ghostel--eshell-region-end (session)
  "Return the buffer position just past SESSION's frozen region, or nil."
  (let ((end (ghostel-embedded-end session)))
    (and (markerp end) (marker-position end))))

(defun ghostel--eshell-resync-output (pos)
  "Move Eshell's output bookkeeping markers to POS.
Runs after an embedded terminal froze at POS so the next prompt is
inserted after the terminal's text and Eshell's output filters keep
working on subsequent commands.  `eshell-last-input-end' is deliberately
left alone: `eshell-delete-output' uses it as the start of the last
output, so it must stay where Eshell put it at input time."
  (dolist (variable '(eshell-last-output-start
                      eshell-last-output-end))
    (when (and (boundp variable)
               (markerp (symbol-value variable)))
      (set-marker (symbol-value variable) pos))))

(defun ghostel--eshell-cleanup ()
  "Freeze any embedded terminal in the current buffer.
Used by `kill-buffer-hook'; `ghostel--embedded-finish' is idempotent."
  (when (ghostel--embedded-live-p ghostel--embedded-session)
    (ghostel--embedded-finish ghostel--embedded-session)))

(defun ghostel--eshell-process-environment ()
  "Return `process-environment' with the ghostel terminal variables set.
The let-binding only covers the process being spawned, so other Eshell
commands keep their normal environment."
  (let ((terminfo (ghostel--terminfo-directory)))
    (append (list (concat "TERM=" ghostel-term))
            (when terminfo (list (concat "TERMINFO=" terminfo)))
            process-environment)))

(defun ghostel--eshell-stty-prefix (rows cols)
  "Return an argv prefix that sizes the PTY to ROWS x COLS.
The prefix runs `stty' in a shell, shifts its sentinel argument away and
then replaces the shell with the real command via `exec', so the program
sees a correctly sized terminal in its very first query."
  (list "/usr/bin/env" "sh" "-c"
        (format (concat "stty -nl echo rows %d columns %d sane 2>/dev/null ; "
                        "if [ $1 = .. ]; then shift; fi; exec \"$@\"")
                rows cols)
        ".."))

(defun ghostel--eshell-gather-process-output (orig command args)
  "Run COMMAND with ARGS in an embedded terminal when appropriate.
ORIG is `eshell-gather-process-output'.  Only interactive external
commands in local Eshell buffers get a terminal; everything else keeps
Eshell's normal output path.  The spawned command is wrapped so `stty'
gives the PTY the region's size before it starts, TERM and TERMINFO are
exported for that one process, and a one-shot `eshell-exec-hook' entry
attaches the terminal once Eshell has created the process."
  (if (not (ghostel--eshell-use-terminal-p))
      (funcall orig command args)
    (let* ((size (ghostel--eshell-terminal-size))
           (prefix (ghostel--eshell-stty-prefix (car size) (cdr size)))
           (process-environment (ghostel--eshell-process-environment))
           (hook (lambda (process)
                   (ghostel--eshell-attach-process process size))))
      (add-hook 'eshell-exec-hook hook 99)
      (unwind-protect
          (if (>= emacs-major-version 29)
              ;; Emacs 29+ routes external commands through `make-process'.
              (let ((original (symbol-function #'make-process))
                    (expected (cons (file-local-name (expand-file-name command))
                                    args)))
                (cl-letf (((symbol-function #'make-process)
                           (lambda (&rest plist)
                             (when (equal (plist-get plist :command) expected)
                               (setf (plist-get plist :command)
                                     (append prefix (plist-get plist :command))))
                             (apply original plist))))
                  (funcall orig command args)))
            ;; Emacs 28 spawns through `start-file-process'.
            (let ((original (symbol-function #'start-file-process)))
              (cl-letf (((symbol-function #'start-file-process)
                         (lambda (name buffer &rest argv)
                           (apply original name buffer
                                  (append prefix argv)))))
                (funcall orig command args))))
        (remove-hook 'eshell-exec-hook hook)))))

(provide 'ghostel-eshell)
;;; ghostel-eshell.el ends here
