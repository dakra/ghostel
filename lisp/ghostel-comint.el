;;; ghostel-comint.el --- libghostty rendering for comint buffers -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A global minor mode that transparently routes every comint-derived
;; subprocess's PTY output through libghostty's anchored renderer.  Once
;; `ghostel-comint-mode' is enabled (off by default), existing comint
;; commands like \\[shell], \\[run-python], \\[sql-postgres], \\[ielm],
;; and `cider-repl' just work — with full ANSI colour, CR overwrite
;; (progress bars), OSC 7 working-directory tracking, OSC 8 hyperlinks,
;; OSC 133 semantic prompts, and unicode-width awareness.
;;
;; Comint owns input editing, history, prompt regex, fields, completion,
;; and the process filter; ghostel owns output rendering.  We hook into
;; comint via three documented surfaces:
;;
;;   * `comint-mode-hook' to bump TERM in `process-environment' and set
;;     a few comint variables (`comint-inhibit-carriage-motion', etc.).
;;   * `comint-exec-hook' to wrap `comint-input-sender' and install the
;;     window-resize plumbing once the subprocess is alive.
;;   * `comint-output-filter-functions' (first in the buffer-local list)
;;     to deflect raw PTY bytes into libghostty before any other hook
;;     can paint them.
;;
;; Each "exchange" — the window from one user-submitted input to the
;; next — gets its own short-lived anchored ghostel terminal anchored
;; at `process-mark'.  On the next submit, the previous terminal is
;; retired (its rendered bytes become inert text in the buffer) and a
;; fresh terminal is allocated.  OSC 133 D retires earlier when the
;; shell has prompt integration installed.
;;
;; If a running command flips into the alternate screen (apps like
;; `less', `vim', `htop' do this via smcup), rendering is paused — the
;; anchored region has no save/restore semantics for alt-screen
;; contents.  Use \\[ghostel] for inline TUIs; this mode is for
;; long-form ANSI output in shells and REPLs.
;;
;; To enable, drop one line in init.el:
;;
;;   (ghostel-comint-mode 1)
;;
;; To opt a major mode out (because its own filters or sender conflict),
;; add it to `ghostel-comint-excluded-modes'.

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
  "Libghostty-backed output rendering for comint subprocesses."
  :group 'ghostel)

(defcustom ghostel-comint-excluded-modes nil
  "Major modes (derived from `comint-mode') that opt out of `ghostel-comint-mode'.
Add modes here whose own output processing collides with ours — for
instance REPL modes that hand-roll prompt detection, ANSI colouring,
or `comint-output-filter-functions' surgery.  Buffers entering one
of these modes get no TERM bump, no output filter, and behave as
vanilla comint."
  :type '(repeat symbol))

(defcustom ghostel-comint-rows 1
  "Active-grid height (in rows) of each per-exchange anchored terminal.
Defaults to 1 — the active area is just \"the line currently being
written\".  Completed lines roll into libghostty's scrollback and the
anchored renderer materializes them as inert buffer text above the
active row, so the buffer grows naturally line by line and there is
no fixed-height padding below the prompt.

Multi-line in-place updates (a 3-row spinner that redraws itself, an
ANSI-art progress display) need more rows to work; bump this to 4–8
if you regularly use such tools.  Full-screen TUIs (vim, htop) are
out of scope for `ghostel-comint-mode' regardless of grid size — use
\\[ghostel] for those."
  :type 'integer)

(defcustom ghostel-comint-cols 80
  "Fallback column count when no window is displaying the comint buffer.
A window-derived column count is used whenever one is available."
  :type 'integer)

(defcustom ghostel-comint-max-scrollback (* 64 1024)
  "Maximum scrollback (bytes) per per-exchange anchored terminal.
Active-grid rows that scroll off the top of the grid land in
libghostty's scrollback, which the anchored renderer materializes as
inert text in the buffer.  Setting this too small causes long-running
commands to silently lose early output; setting it large is harmless
because the scrollback is freed when the exchange's terminal is
retired (next user input)."
  :type 'integer)


;;; Buffer-local state

(defvar-local ghostel-comint--active nil
  "Non-nil when this comint buffer is owned by `ghostel-comint-mode'.
Set by `ghostel-comint--setup' when the buffer enters `comint-mode'
with the global mode enabled and the buffer's major mode is not in
`ghostel-comint-excluded-modes'.  `ghostel-comint--install' bails
when this is nil so excluded buffers stay vanilla.")

(defvar-local ghostel-comint--term nil
  "Currently-active anchored terminal for this comint buffer.
Allocated lazily on the first output chunk after each user submit;
retired either on OSC 133 D or on the next submit, whichever comes
first.")

(defvar-local ghostel-comint--rendering-paused nil
  "Non-nil when alt-screen entry has paused renderer mirroring.
Bytes still flow into libghostty so its VT state stays consistent,
but the renderer no longer mirrors them into the buffer until the
next exchange starts.")

(defvar-local ghostel-comint--rows nil
  "Last row count sized into the anchored terminal.
Initialized from `ghostel-comint-rows' in `ghostel-comint--setup'.")

(defvar-local ghostel-comint--cols nil
  "Last column width sized into the anchored terminal.
Initialized from a window-derived value (or `ghostel-comint-cols')
in `ghostel-comint--setup'.")

(defvar-local ghostel-comint--orig-input-sender nil
  "Original `comint-input-sender' captured at install time.
Restored by the input-sender wrap when delegating to the underlying
sender for the actual byte transmission to the PTY.")


;;; Size helpers

(defun ghostel-comint--window-size (buffer)
  "Return (HEIGHT . WIDTH) for BUFFER's per-exchange anchored terminal.
HEIGHT is fixed at `ghostel-comint-rows' — the active grid is small
on purpose, with scrollback handling line history.  WIDTH comes from
a window displaying the buffer, falling back to `ghostel-comint-cols'
when none does."
  (let* ((win (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (height (max 1 ghostel-comint-rows))
         (width (max 20 (if (window-live-p win)
                            (window-max-chars-per-line win)
                          ghostel-comint-cols))))
    (cons height width)))


;;; Terminal lifecycle

(defun ghostel-comint--retire-terminal ()
  "Retire the active anchored terminal in the current buffer, if any.
Removes its marker pair from `ghostel--anchored-terminals' so the
renderer can no longer write to its region.  Already-rendered text
stays in the buffer as inert content.  Safe to call when no
terminal is active."
  (when (and ghostel-comint--term
             (hash-table-p ghostel--anchored-terminals))
    (remhash ghostel-comint--term ghostel--anchored-terminals))
  (setq ghostel-comint--term nil
        ghostel-comint--rendering-paused nil))

(defun ghostel-comint--make-terminal (proc)
  "Create a fresh anchored terminal at PROC's `process-mark'.
Stamps an empty seed newline at the mark so the renderer has a
character to write into, then sizes the terminal to the displaying
window."
  (let* ((size (ghostel-comint--window-size (current-buffer)))
         (rows (car size))
         (cols (cdr size))
         (pmark (process-mark proc))
         (start (marker-position pmark))
         (inhibit-read-only t)
         end term)
    (save-excursion
      (goto-char start)
      ;; The renderer needs at least one character between the start and
      ;; end markers.  Tag the seed newline with field=output so comint
      ;; field navigation (C-a, M-a, M-e) crosses it like normal output.
      (insert (propertize "\n"
                          'field 'output
                          'front-sticky '(field
                                          inhibit-line-move-field-capture)
                          'inhibit-line-move-field-capture t))
      (setq end (point)))
    (setq ghostel-comint--rows rows
          ghostel-comint--cols cols
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
  "Resize PROCESS's terminal and PTY to match the windows in WINDOWS.
Returns (WIDTH . HEIGHT) so Emacs follows up with
`set-process-window-size' (SIGWINCH)."
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
Runs first in the buffer-local `comint-output-filter-functions' list,
so the bytes comint inserted between `comint-last-output-start' and
`process-mark' are still raw.  We capture them, delete the raw region,
feed them through the anchored terminal's VT parser, redraw, advance
`process-mark' past the rendered region, and trim trailing empty
rows.  Subsequent filter functions see the cleanly-rendered region."
  (when ghostel-comint--active
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
                (cond
                 (ghostel-comint--rendering-paused
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
                      ;; Anchor `process-mark' at the libghostty cursor,
                      ;; NOT at the region's end-marker.  The renderer
                      ;; emits a trailing newline at the end of every row
                      ;; it materializes, so end-marker sits PAST the
                      ;; visible cursor.  If we leave pmark there:
                      ;;
                      ;;   (a) `comint-output-filter' restores point to
                      ;;       `saved-point' (the libghostty cursor)
                      ;;       after running filters, so the user types
                      ;;       BEFORE pmark.  Each typed char is then an
                      ;;       insertion-before-marker, advancing pmark
                      ;;       along with point.  On submit `(point) <
                      ;;       pmark', which triggers
                      ;;       `comint-get-old-input' — that returns the
                      ;;       whole visible line including the prompt
                      ;;       text.  Bash then receives the prompt
                      ;;       characters as a command and errors out
                      ;;       (e.g. \"~/.emacs.d λ ls\" → bash tries
                      ;;       to exec \"~/.emacs.d\").
                      ;;
                      ;;   (b) Even when point manages to track pmark,
                      ;;       the user's input lands on a NEW LINE
                      ;;       below the prompt, which is wrong UX for
                      ;;       a shell.
                      ;;
                      ;; Anchoring pmark at the cursor (insertion-type
                      ;; nil) means typed chars insert AT pmark and
                      ;; pmark stays put; `(point) >= pmark' so the
                      ;; direct buffer-substring path runs and the
                      ;; input string is just what the user typed.
                      (let ((cursor-pos (or ghostel--cursor-char-pos
                                            (marker-position end-marker))))
                        (set-marker pmark cursor-pos)
                        (set-marker comint-last-output-start cursor-pos)
                        (unless comint-use-prompt-regexp
                          (comint--mark-as-output
                           (marker-position start-marker)
                           cursor-pos)))))))))))))))


;;; Input handling

(defun ghostel-comint--input-sender-wrapper (proc input)
  "Send INPUT to PROC, rotating the anchored terminal first.
Retires the current anchored terminal, allocates a fresh one anchored
at the post-input `process-mark', then delegates to the original
sender (captured in `ghostel-comint--orig-input-sender' at install
time, so mode-specific senders — e.g. SQL semicolon appenders —
keep working)."
  (ghostel-comint--retire-terminal)
  (ghostel-comint--make-terminal proc)
  (funcall (or ghostel-comint--orig-input-sender #'comint-simple-send)
           proc input))


;;; OSC 133 command-finish hook

(defun ghostel-comint--on-command-finish (buffer _exit)
  "Retire the active anchored terminal on OSC 133 D in BUFFER.
Lets the renderer hand off the rendered region to inert state the
moment the shell signals the command finished, rather than waiting
for the user to submit the next one."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when ghostel-comint--active
        (ghostel-comint--retire-terminal)))))


;;; Cleanup

(defun ghostel-comint--cleanup ()
  "Retire the live anchored terminal so its markers can be GC'd.
Called from `kill-buffer-hook' and `change-major-mode-hook'."
  (ghostel-comint--retire-terminal))


;;; Per-buffer setup

;; Forward declaration: the global mode is defined further down; the
;; setup function below reads its toggle variable.
(defvar ghostel-comint-mode)

(defun ghostel-comint--should-handle-p ()
  "Return non-nil when the current buffer should be rendered by ghostel."
  (and ghostel-comint-mode
       (derived-mode-p 'comint-mode)
       (not (apply #'derived-mode-p ghostel-comint-excluded-modes))
       ;; Don't layer over `ghostel-mode' (which is a comint relative).
       (not (derived-mode-p 'ghostel-mode))))

(defun ghostel-comint--setup ()
  "Per-buffer setup hung off `comint-mode-hook'.
Idempotent: this runs on every `comint-mode' entry, including the
RE-entry triggered by `shell-mode' (and any other `comint-mode'
descendant) calling `kill-all-local-variables' on top of an
already-set-up buffer.  `comint-output-filter-functions' has its
`permanent-local' property set, so our hook survives that wipe and
we must `remq' before consing to avoid duplicating ourselves; the
`comint-input-sender' wrap doesn't survive and we have to re-install
it from this hook each time, NOT from `comint-exec-hook' (which only
fires once per process spawn)."
  (when (ghostel-comint--should-handle-p)
    (ghostel--load-module t)
    (setq ghostel-comint--active t
          ghostel-comint--rows (max 1 ghostel-comint-rows)
          ghostel-comint--cols ghostel-comint-cols)
    ;; Let libghostty handle CR / BS / etc.  Comint's text-level CR
    ;; handler would race with the renderer.
    (setq-local comint-inhibit-carriage-motion t)
    ;; The kernel discipline echo gets stripped by the shell's `stty
    ;; -echo' (which most shells run from their startup), but if a
    ;; subprocess re-enables echo, comint's synchronous echo-strip can
    ;; deadlock with our synchronous redraw.  Disable comint's strip;
    ;; libghostty handles whatever the PTY produces.
    (setq-local comint-process-echoes nil)
    ;; `comint-truncate-buffer' would delete from `point-min' with no
    ;; awareness of our anchored markers.  Disable buffer truncation
    ;; in ghostel-comint buffers.
    (setq-local comint-buffer-maximum-size nil)
    ;; `comint-send-input' normally does `(goto-char (field-end))'
    ;; before slicing the input out of the buffer, on the assumption
    ;; that the input is the whole "no-field" tail of the buffer.  Our
    ;; renderer materializes a trailing newline after each row of
    ;; libghostty's grid (RowContent.build always appends `\\n'), so
    ;; `field-end' walks past that newline to point-max — and the
    ;; resulting `buffer-substring' captures the newline as part of the
    ;; input, which then lands in the input ring with a stray trailing
    ;; `\\n'.  We always set `process-mark' to the libghostty cursor
    ;; position (see the output filter), so the "extract from pmark to
    ;; point" path is exactly what we want; skipping the field-end
    ;; goto avoids the spurious newline.
    (setq-local comint-eol-on-send nil)
    ;; Anchored region grows as output renders; window-point needs to
    ;; track end-of-buffer so the user sees fresh output.
    (setq-local window-point-insertion-type t)
    ;; libghostty owns SGR; ansi-color would double-paint on top of
    ;; the face properties we apply during render.  Strip it for this
    ;; buffer only.
    ;; Cons our output filter at the front of the list, removing any
    ;; pre-existing copy (the list survives `kill-all-local-variables'
    ;; via its permanent-local property) and stripping ansi-color (we
    ;; do our own SGR rendering and double-painting would clobber it).
    (setq-local comint-output-filter-functions
                (cons #'ghostel-comint--output-filter
                      (remq 'ansi-color-process-output
                            (remq #'ghostel-comint--output-filter
                                  comint-output-filter-functions))))
    ;; Wrap `comint-input-sender' so each user submission retires the
    ;; current anchored terminal and creates a fresh one — see the
    ;; wrapper's docstring.  Done HERE (not in `--install') so the wrap
    ;; gets reinstalled when `shell-mode' (or any other comint child)
    ;; calls `kill-all-local-variables' on top of an already-set-up
    ;; buffer.  We don't preserve the underlying sender across resets
    ;; because the reset typically reverts the buffer's sender to the
    ;; default `comint-simple-send' anyway; mode-specific senders that
    ;; want to participate would have to be set up after our setup
    ;; runs.
    (unless (eq comint-input-sender #'ghostel-comint--input-sender-wrapper)
      (setq ghostel-comint--orig-input-sender comint-input-sender)
      (setq-local comint-input-sender #'ghostel-comint--input-sender-wrapper))
    ;; Bump TERM for the about-to-be-spawned process.  `comint-exec-1'
    ;; constructs the child's environment by prepending
    ;; `comint-term-environment' (which emits TERM=`comint-terminfo-terminal')
    ;; in front of `process-environment'.  Since env lookups return the
    ;; first match, our `setq-local' on `process-environment' alone would
    ;; lose to the front-of-list TERM=dumb from comint.  Override the
    ;; terminfo terminal so comint itself emits the right TERM, then
    ;; append the rest (TERMINFO, TERM_PROGRAM, etc.) via process-environment.
    (setq-local comint-terminfo-terminal
                (if (equal ghostel-term "xterm-ghostty") "xterm-ghostty"
                  ghostel-term))
    (setq-local process-environment
                (append ghostel-environment
                        (ghostel--terminal-env)
                        process-environment))
    (add-hook 'ghostel-command-finish-functions
              #'ghostel-comint--on-command-finish nil t)
    (add-hook 'kill-buffer-hook #'ghostel-comint--cleanup nil t)
    (add-hook 'change-major-mode-hook #'ghostel-comint--cleanup nil t)))

(defun ghostel-comint--install ()
  "Per-process install hung off `comint-exec-hook'.
Runs once per process spawn, after the subprocess is alive — the
right moment to install the `adjust-window-size-function' process
property and seed the PTY size.  The `comint-input-sender' wrap is
NOT installed here — `--setup' does it, so the wrap survives
`shell-mode''s `kill-all-local-variables'."
  (when ghostel-comint--active
    (let ((proc (get-buffer-process (current-buffer))))
      (when proc
        (process-put proc 'adjust-window-size-function
                     #'ghostel-comint--adjust-window-size)
        (let* ((size (ghostel-comint--window-size (current-buffer)))
               (height (car size))
               (width (cdr size)))
          (setq ghostel-comint--rows height
                ghostel-comint--cols width)
          (set-process-window-size proc height width))))))


;;; Global minor mode — the only user-facing API

;;;###autoload
(define-minor-mode ghostel-comint-mode
  "Route comint subprocess output through ghostel's libghostty renderer.

When enabled, every newly-entered comint buffer (\\[shell],
\\[run-python], \\[sql-product-interactive], \\[ielm], cider-repl,
…) bumps TERM to `xterm-ghostty', installs an output filter that
parses PTY bytes through libghostty, and renders into a per-exchange
anchored region.  Input editing, history, prompt regex, fields,
and the process filter stay comint's.

When disabled, comint behaves exactly as it did before.  Already-
running comint buffers are unaffected by toggling — only buffers
entering `comint-mode' after the toggle pick up (or drop) the
integration.  Restart a buffer (kill + relaunch) to apply a change
to it.

Modes listed in `ghostel-comint-excluded-modes' are skipped.

This is the comint analogue of `ghostel-compile-global-mode' for
`compilation-mode' buffers, and the libghostty-powered counterpart
to `coterm-mode' (with which it is incompatible — don't enable
both)."
  :global t
  :group 'ghostel-comint
  (if ghostel-comint-mode
      (progn
        (add-hook 'comint-mode-hook #'ghostel-comint--setup)
        (add-hook 'comint-exec-hook #'ghostel-comint--install))
    (remove-hook 'comint-mode-hook #'ghostel-comint--setup)
    (remove-hook 'comint-exec-hook #'ghostel-comint--install)))


(provide 'ghostel-comint)

;;; ghostel-comint.el ends here
