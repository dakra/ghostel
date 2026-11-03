;;; ghostel-embedded.el --- Run a terminal inside a region of a host buffer -*- lexical-binding: t; -*-

;; Author: Agnes Li <agnes.li@mf.me>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An embedded terminal renders into a marker-delimited region of a host
;; buffer instead of owning the whole buffer.  The host keeps its major
;; mode and owns everything outside the region; the terminal owns the rows
;; between its start and end markers and freezes them into ordinary text
;; once the session finishes.
;;
;; This is the shared layer behind in-buffer Eshell support.  One live
;; embedded session per host buffer is supported, because the native
;; renderer keeps renderer-owned state in buffer-local variables.
;;
;; The host is responsible for the process: feed its output with
;; `ghostel--embedded-feed', send user input with the embedded send
;; commands, and call `ghostel--embedded-finish' when the program exits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ghostel)

(declare-function ghostel--alt-screen-p "ghostel-module")
(declare-function ghostel--encode-key "ghostel-module")
(declare-function ghostel--encode-paste "ghostel-module" (term data))
(declare-function ghostel--mouse-event "ghostel-module")
(declare-function ghostel--mouse-tracking-p "ghostel-module")
(declare-function ghostel--new "ghostel-module")
(declare-function ghostel--redraw "ghostel-module"
                  (term &optional full force-sync))
(declare-function ghostel--kill-native-process "ghostel-module" (term))
(declare-function ghostel--set-region "ghostel-module" (term start end))
(declare-function ghostel--write-pty "ghostel-module")
(declare-function ghostel--write-vt "ghostel-module")

(defvar-local ghostel--embedded-session nil
  "Live embedded terminal session in this buffer, if any.")

(cl-defstruct (ghostel-embedded (:constructor ghostel-embedded--make))
  "State for one terminal embedded in a host buffer.
BUFFER is the host buffer, TERM the native terminal handle, and PROCESS
the Emacs-side handle for the child: the Emacs PTY process, or the event
pipe when NATIVE-P is non-nil and a native PTY reader drives the child.
START and END
are the region's markers; START does not move when text is inserted at
it, END follows text appended to the terminal.  ROWS and COLS are the
terminal grid size.  REDRAW-TIMER and PENDING-REDRAW coalesce output
into frames.  SAVED-MAP, SAVED-TERM, SAVED-PROCESS, SAVED-INPUT-MODE and
SAVED-POINT hold the host buffer state from before input activation, so
finishing can restore it.  INPUT-ACTIVE is non-nil while that state has
been saved.  INPUT-MODE is the current input mode (`semi-char', `char'
or `emacs').  ALT-SCREEN-P is non-nil while the terminal is on its
alternate screen."
  buffer
  term
  process
  start
  end
  rows
  cols
  redraw-timer
  pending-redraw
  saved-map
  saved-term
  saved-process
  saved-input-mode
  saved-point
  input-active
  (input-mode 'semi-char)
  (alt-screen-p nil)
  (native-p nil))

(defun ghostel--embedded-live-p (session)
  "Return non-nil when SESSION still has a terminal to render."
  (and (ghostel-embedded-p session)
       (ghostel-embedded-term session)
       (buffer-live-p (ghostel-embedded-buffer session))))

(defvar-local ghostel--embedded-cursor-overlay nil
  "Overlay drawing an embedded terminal's cursor in this buffer.")

(defvar-local ghostel-embedded-redraw-hook nil
  "Hook run after an embedded terminal renders a frame.
Called with the session; the host buffer is current.  The host installs
handlers here to react to render-derived state such as alternate-screen
transitions.")

(defun ghostel--embedded-region-bounds (session)
  "Return SESSION's region as (START . END), or nil when unavailable."
  (let ((start (ghostel-embedded-start session))
        (end (ghostel-embedded-end session)))
    (when (and (markerp start)
               (markerp end)
               (buffer-live-p (marker-buffer start)))
      (let ((beg (marker-position start))
            (fin (marker-position end)))
        (when (and beg fin) (cons beg fin))))))

(defun ghostel--embedded-apply-region-props (session)
  "Make SESSION's freshly rendered rows read-only.
`buffer-read-only' is deliberately left alone: the host buffer stays
editable and only the terminal's own rows are protected.

Only the range the renderer just rewrote (`ghostel--repainted-region')
is re-propertized: re-applying over the whole region every frame would
cost O(scrollback) per frame and destroy throughput on large outputs.
Rows that scrolled out of the viewport keep the property applied when
they were rendered.  A `keymap' text property is deliberately not set:
it would replace the input-mode keymap for every key pressed inside the
region, so terminal keys would fall through to the global map."
  (let* ((bounds (ghostel--embedded-region-bounds session))
         (repainted (and (boundp 'ghostel--repainted-region)
                         ghostel--repainted-region))
         (beg (car bounds))
         (end (cdr bounds)))
    (when repainted
      (setq beg (max beg (car repainted))
            end (min end (cdr repainted))))
    (when (and beg end (< beg end))
      (with-silent-modifications
        (put-text-property beg end 'read-only t)))))

(defun ghostel--embedded-remove-region-props (session)
  "Remove the live-region properties from SESSION's region.
`inhibit-read-only' is bound explicitly so removing the `read-only'
property from the terminal's rows can never signal `text-read-only',
regardless of how `with-silent-modifications' is implemented."
  (let ((bounds (ghostel--embedded-region-bounds session)))
    (when (and bounds (< (car bounds) (cdr bounds)))
      (let ((inhibit-read-only t))
        (with-silent-modifications
          (remove-text-properties (car bounds) (cdr bounds)
                                  '(read-only nil keymap nil pointer nil)))))))

(defun ghostel--embedded-clear-cursor ()
  "Remove the embedded terminal cursor overlay from this buffer."
  (when ghostel--embedded-cursor-overlay
    (delete-overlay ghostel--embedded-cursor-overlay)
    (setq ghostel--embedded-cursor-overlay nil)))

(defun ghostel--embedded-update-cursor (session)
  "Draw SESSION's terminal cursor at `ghostel--cursor-char-pos'.
The renderer publishes that buffer position while walking the cursor
row, so it is only refreshed on frames that repaint that row."
  (when (ghostel--embedded-live-p session)
    (with-current-buffer (ghostel-embedded-buffer session)
      (let* ((bounds (ghostel--embedded-region-bounds session))
             (pos ghostel--cursor-char-pos))
        (if (and bounds pos
                 (>= pos (car bounds))
                 (<= pos (cdr bounds))
                 ;; When point tracks the terminal cursor (semi-char and
                 ;; char modes) the real cursor already shows it; the
                 ;; overlay is only for emacs mode where point roams.
                 (not (= pos (point))))
            (let* ((eol (or (= pos (point-max))
                            (= pos (cdr bounds))
                            (eq (char-after pos) ?\n)))
                   (ov (or ghostel--embedded-cursor-overlay
                           (let ((new (make-overlay pos pos nil t nil)))
                             (overlay-put new 'priority 100)
                             (setq ghostel--embedded-cursor-overlay new)))))
              (if eol
                  (progn
                    (move-overlay ov pos pos)
                    (overlay-put ov 'face nil)
                    (overlay-put ov 'after-string
                                 (propertize " " 'face 'ghostel-fake-cursor)))
                (move-overlay ov pos (1+ pos))
                (overlay-put ov 'after-string nil)
                (overlay-put ov 'face 'ghostel-fake-cursor)))
          (ghostel--embedded-clear-cursor))))))

(defun ghostel--embedded-mouse-tracking-p (session)
  "Return non-nil when SESSION's terminal asked for mouse tracking."
  (and (ghostel--embedded-live-p session)
       (ghostel--mouse-tracking-p (ghostel-embedded-term session))))

(defun ghostel--embedded-mouse-cell (posn)
  "Return (COL . ROW) of POSN inside the embedded region, or nil.
ROW is relative to the region's first row, which is what the terminal
mouse encoder expects."
  (let* ((window (posn-window posn))
         (xy (posn-x-y posn))
         (pos (posn-point posn)))
    (when (and (window-live-p window) (integer-or-marker-p pos) xy)
      (with-current-buffer (window-buffer window)
        (let ((bounds (and ghostel--embedded-session
                           (ghostel--embedded-region-bounds
                            ghostel--embedded-session))))
          (when (and bounds
                     (>= pos (car bounds))
                     (<= pos (cdr bounds)))
            (cons (with-selected-window window
                    (/ (car xy) (default-font-width)))
                  (- (line-number-at-pos pos)
                     (line-number-at-pos (car bounds))))))))))

(defun ghostel--embedded-mouse-send (event action)
  "Send mouse EVENT to the embedded terminal with ACTION.
ACTION is 0 for press, 1 for release, as expected by the terminal."
  (let* ((posn (if (= action 1) (event-end event) (event-start event)))
         (session ghostel--embedded-session)
         (cell (ghostel--embedded-mouse-cell posn)))
    (if (and cell session (ghostel--embedded-mouse-tracking-p session))
        (ghostel--embedded-send-mouse session action
                                      (ghostel--mouse-button-number event)
                                      (cdr cell) (car cell)
                                      (ghostel--mouse-mods event))
      ;; The program is not reading mouse events: keep Emacs's own
      ;; click behaviour on the read-only terminal rows.
      (when (and (= action 0) (posn-window posn))
        (mouse-set-point event)))))

(defun ghostel-embedded-mouse-press (event)
  "Forward mouse press EVENT to the embedded terminal.
When the terminal does not track the mouse, move point like a normal
Emacs click instead."
  (interactive "e")
  (ghostel--embedded-mouse-send event 0))

(defun ghostel-embedded-mouse-release (event)
  "Forward mouse release EVENT to the embedded terminal."
  (interactive "e")
  (ghostel--embedded-mouse-send event 1))

(defun ghostel-embedded-mouse-drag (event)
  "Forward drag-end EVENT as a button release to the embedded terminal."
  (interactive "e")
  (ghostel--embedded-mouse-send event 1))

(defun ghostel-embedded-mouse-wheel (event)
  "Forward wheel EVENT to the embedded terminal as a button 4/5 press.
Falls back to Emacs scrolling when the terminal does not track the mouse."
  (interactive "e")
  (let* ((posn (event-start event))
         (session ghostel--embedded-session)
         (cell (ghostel--embedded-mouse-cell posn))
         (button (if (memq (event-basic-type event) '(wheel-up mouse-4)) 4 5)))
    (if (and cell session (ghostel--embedded-mouse-tracking-p session))
        (ghostel--embedded-send-mouse session 0 button
                                      (cdr cell) (car cell)
                                      (ghostel--mouse-mods event))
      (ignore-errors (mwheel-scroll event)))))

(defun ghostel--embedded-start (buffer &optional position rows cols)
  "Start an embedded terminal in BUFFER.
POSITION is where the region starts; it defaults to `point-max' and must
be the beginning of a line.  ROWS and COLS default to 24 and 80.  Returns
the new `ghostel-embedded' session.  Signals a `user-error' when BUFFER
already has a live embedded session or is dead."
  (unless (buffer-live-p buffer)
    (user-error "Cannot start an embedded terminal in a dead buffer"))
  (ghostel--load-module t)
  (with-current-buffer buffer
    (when (ghostel--embedded-live-p ghostel--embedded-session)
      (user-error "Buffer %s already has an embedded terminal"
                  (buffer-name buffer)))
    (let* ((position (or position (point-max)))
           (start (copy-marker position nil))
           (end (copy-marker position t))
           (rows (max 1 (or rows 24)))
           (cols (max 1 (or cols 80)))
           ;; No kitty graphics: an embedded region has no stable image
           ;; anchors and the host buffer may already have overlays.
           (term (ghostel--new rows cols ghostel-max-scrollback 0)))
      (ghostel--set-region term start end)
      (ghostel--set-size-with-cell-dims term rows cols)
      (ghostel--apply-palette term)
      (ghostel--apply-bold-config term)
      (let ((session (ghostel-embedded--make
                      :buffer buffer
                      :term term
                      :start start
                      :end end
                      :rows rows
                      :cols cols)))
        (setq ghostel--embedded-session session)
        (setq-local ghostel--resize-request-function
                    'ghostel--embedded-resize-request)
        session))))

(defun ghostel--embedded-feed (session output)
  "Hand OUTPUT, a string of terminal bytes, to SESSION's terminal.
Rendering is scheduled separately so bursts of output produce one frame."
  (when (ghostel--embedded-live-p session)
    (cond
     ((not (stringp output))
      ;; A process filter should always hand us a string; if it does not,
      ;; dropping it here beats feeding a non-string to `ghostel--write-vt',
      ;; whose string extraction would signal `ExtractStringFailed'.
      (warn "Dropped non-string process output from Ghostel-eshell (%s)"
            (type-of output)))
     ((> (length output) 0)
      (with-current-buffer (ghostel-embedded-buffer session)
        (ghostel--write-vt (ghostel-embedded-term session) output))
      (ghostel--embedded-invalidate session)))))

(defun ghostel--embedded-cancel-timer (session)
  "Cancel SESSION's pending redraw timer and clear its pending flag."
  (when-let* ((timer (ghostel-embedded-redraw-timer session)))
    (cancel-timer timer)
    (setf (ghostel-embedded-redraw-timer session) nil))
  (setf (ghostel-embedded-pending-redraw session) nil))

(defun ghostel--embedded-schedule-redraw (session)
  "Schedule a redraw of SESSION unless one is already pending."
  (unless (ghostel-embedded-redraw-timer session)
    (setf (ghostel-embedded-pending-redraw session) t)
    (setf (ghostel-embedded-redraw-timer session)
          (run-at-time
           ghostel-timer-delay nil
           (lambda ()
             (when (ghostel--embedded-live-p session)
               (with-current-buffer (ghostel-embedded-buffer session)
                 (setf (ghostel-embedded-redraw-timer session) nil)
                 (ghostel--embedded-redraw-now session))))))))

(defun ghostel--embedded-invalidate (session)
  "Schedule a redraw for output that reached SESSION's terminal."
  (when (ghostel--embedded-live-p session)
    (ghostel--embedded-schedule-redraw session)))

(defun ghostel--embedded-should-follow-p (session)
  "Return non-nil when SESSION's point should track the terminal cursor.
True in semi-char and char modes; false in Emacs mode where the user
roams freely while the terminal keeps running."
  (memq (ghostel-embedded-input-mode session) '(semi-char char)))

(defun ghostel--embedded-follow (session)
  "Scroll windows showing SESSION's buffer to the terminal cursor.
Moves point and each window's point to the terminal cursor.  On the
alternate screen the window starts at the region's first row, so a
full-window TUI fills the window.  Otherwise the window scrolls only
when the cursor leaves the view: a prompt with room below it stays where
it is, as in a plain Eshell buffer."
  (when (ghostel--embedded-live-p session)
    (with-current-buffer (ghostel-embedded-buffer session)
      (let ((cursor ghostel--cursor-char-pos)
            (start (marker-position (ghostel-embedded-start session)))
            (alt (ghostel-embedded-alt-screen-p session)))
        (when (and cursor start)
          (goto-char cursor)
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (with-selected-window window
              (set-window-point window cursor)
              (if alt
                  ;; A full-window TUI: show its first row at the top.
                  (set-window-start window start)
                ;; Scroll only when the cursor is outside the window.
                ;; Unconditional recentering pulled the region's first
                ;; row to the window bottom, so pressing RET moved the
                ;; prompt down even when there was space below it.
                (let ((win-start (window-start window))
                      (win-end (window-end window t)))
                  (unless (and win-end
                               (<= win-start cursor)
                               (<= cursor win-end))
                    (recenter -1)))))))))))

(defun ghostel--embedded-redraw-now (session &optional force)
  "Render SESSION's terminal into its region now.
With FORCE non-nil, repaint even while the program holds synchronized
output (mode 2026) open.  Returns non-nil when a frame was rendered;
keeps a retry scheduled when the renderer declined."
  (when (ghostel--embedded-live-p session)
    (with-current-buffer (ghostel-embedded-buffer session)
      (ghostel--embedded-cancel-timer session)
      (let* ((inhibit-read-only t)
             (inhibit-modification-hooks t)
             (window (get-buffer-window (current-buffer) t))
             (term (ghostel-embedded-term session))
             (rendered
              (if (and window (window-live-p window))
                  ;; Glyph metrics and `font-at' need the window that
                  ;; displays the host buffer.
                  (with-selected-window window
                    (ghostel--redraw term nil force))
                (ghostel--redraw term nil force))))
        (when rendered
          ;; The renderer rewrites the region every frame, so the
          ;; read-only barrier is reapplied here.  The redraw hook runs
          ;; before the scroll step because it may resize the terminal on
          ;; an alternate-screen transition, and the final positioning
          ;; must use the updated screen state.
          (ghostel--embedded-apply-region-props session)
          (run-hook-with-args 'ghostel-embedded-redraw-hook session)
          (when (ghostel--embedded-should-follow-p session)
            (ghostel--embedded-follow session))
          (ghostel--embedded-update-cursor session))
        (unless rendered
          (ghostel--embedded-schedule-redraw session))
        rendered))))

(defun ghostel--embedded-resize (session rows cols &optional force)
  "Resize SESSION's terminal to ROWS x COLS and redraw it.
Also resize the attached Emacs PTY.  With FORCE non-nil, commit the size
even when it did not change."
  (when (ghostel--embedded-live-p session)
    (with-current-buffer (ghostel-embedded-buffer session)
      (let ((rows (max 1 rows))
            (cols (max 1 cols)))
        (unless (and (not force)
                     (eql rows (ghostel-embedded-rows session))
                     (eql cols (ghostel-embedded-cols session)))
          (setf (ghostel-embedded-rows session) rows
                (ghostel-embedded-cols session) cols)
          (ghostel--set-size-with-cell-dims (ghostel-embedded-term session)
                                            rows cols)
          ;; A native PTY is resized by the renderer on the next redraw;
          ;; only an Emacs-owned PTY needs `set-process-window-size'.
          (when-let* ((process (ghostel-embedded-process session)))
            (when (and (not (ghostel-embedded-native-p session))
                       (process-live-p process))
              (set-process-window-size process rows cols)))
          ;; A resize only takes effect on the next redraw and may
          ;; invalidate every row, so render it synchronously.
          (ghostel--embedded-redraw-now session t))))))

(defun ghostel--embedded-resize-request (rows cols)
  "Honour a text-area resize request for the current embedded terminal.
ROWS or COLS zero keeps the current value for that dimension.  The
request is clamped to the host window, so a program asking for the
whole window gets it without exceeding the window; a full-screen
program that does not use the alternate screen can then fill it."
  (let ((session (bound-and-true-p ghostel--embedded-session)))
    (when (ghostel--embedded-live-p session)
      (let* ((window (get-buffer-window (ghostel-embedded-buffer session) t))
             (rows (if (> rows 0) rows (ghostel-embedded-rows session)))
             (cols (if (> cols 0) cols (ghostel-embedded-cols session)))
             (max-rows (if (window-live-p window)
                           (with-selected-window window
                             (floor (window-screen-lines)))
                         rows))
             (max-cols (if (window-live-p window)
                           (window-max-chars-per-line window)
                         cols))
             (rows (max 1 (min rows max-rows)))
             (cols (max 1 (min cols max-cols))))
        (unless (and (= rows (ghostel-embedded-rows session))
                     (= cols (ghostel-embedded-cols session)))
          (ghostel--embedded-resize session rows cols))))))

(defmacro ghostel--embedded-with-process (session &rest body)
  "Run BODY in SESSION's host buffer with its PTY bound for the encoder.
The native key encoder writes through the buffer-local `ghostel--process'."
  (declare (indent 1) (debug t))
  `(when (ghostel--embedded-live-p ,session)
     (with-current-buffer (ghostel-embedded-buffer ,session)
       (let ((ghostel--process (ghostel-embedded-process ,session)))
         ,@body))))

(defun ghostel--embedded-send-string (session string)
  "Send STRING to SESSION's PTY unchanged.
Callers are responsible for UTF-8 encoding and control characters; this
bypasses the terminal key encoder.  A native PTY is written by the
module; an Emacs-owned PTY through `process-send-string'."
  (if (ghostel-embedded-native-p session)
      (ghostel--write-pty (ghostel-embedded-term session) string)
    (ghostel--embedded-with-process session
      (when (process-live-p ghostel--process)
        (process-send-string ghostel--process string)))))

(defun ghostel--embedded-send-key (session key-name &optional mods utf8)
  "Send KEY-NAME with MODS through SESSION's terminal key encoder.
KEY-NAME is a string like \"a\", \"return\", or \"up\".  MODS is a
comma-separated modifier string such as \"ctrl\", or nil.  UTF8 is the
text the key produced, when it differs from KEY-NAME.  Returns the bytes
written, or nil when the encoder produced no output."
  (ghostel--embedded-with-process session
    (ghostel--encode-key (ghostel-embedded-term session)
                         key-name (or mods "") utf8)))

(defun ghostel--embedded-send-paste (session string)
  "Send STRING to SESSION's PTY using the terminal's bracketed paste mode."
  (ghostel--embedded-with-process session
    (ghostel--encode-paste (ghostel-embedded-term session) string)))

(defun ghostel--embedded-send-mouse (session action button row col mods)
  "Send a mouse event to SESSION's terminal.
ACTION, BUTTON, ROW, COL and MODS are passed to the native mouse encoder."
  (ghostel--embedded-with-process session
    (ghostel--mouse-event (ghostel-embedded-term session)
                          action button row col mods)))

(defun ghostel--embedded-attach-process (session process &optional native)
  "Attach PROCESS to SESSION.
PROCESS is an Emacs PTY process, or the event pipe for a native child
when NATIVE is non-nil.  When input is already active, also point the
encoder at PROCESS."
  (setf (ghostel-embedded-process session) process
        (ghostel-embedded-native-p session) (and native t))
  (when (ghostel-embedded-input-active session)
    (with-current-buffer (ghostel-embedded-buffer session)
      (setq ghostel--process process)))
  session)

(defun ghostel--embedded--send-control (char)
  "Send control character CHAR to the current buffer's embedded terminal."
  (when (ghostel--embedded-live-p ghostel--embedded-session)
    (ghostel--send-string (string char))))

(defun ghostel-embedded-send-C-c ()
  "Send `C-c' to the embedded terminal, interrupting its foreground program."
  (interactive)
  (ghostel--embedded--send-control ?\C-c))

(defun ghostel-embedded-send-C-d ()
  "Send `C-d' (end of file) to the embedded terminal."
  (interactive)
  (ghostel--embedded--send-control ?\C-d))

(defun ghostel-embedded-send-C-backslash ()
  "Send C-\\ (quit) to the embedded terminal."
  (interactive)
  (ghostel--embedded--send-control ?\C-\\))

(defun ghostel-embedded-yank ()
  "Paste the most recent kill into the embedded terminal."
  (interactive)
  (when (ghostel--embedded-live-p ghostel--embedded-session)
    (ghostel--paste-text (current-kill 0))))

(defun ghostel-embedded-kill-process ()
  "Kill the embedded terminal's process.
The process sentinel freezes the region and restores the host state."
  (interactive)
  (let ((session ghostel--embedded-session))
    (when (ghostel--embedded-live-p session)
      (let ((process (ghostel-embedded-process session)))
        (when (process-live-p process)
          (kill-process process))))))

(defun ghostel-embedded-yank-pop ()
  "Browse the kill ring and paste the selected entry into the terminal."
  (interactive)
  (when (ghostel--embedded-live-p ghostel--embedded-session)
    (let ((text (read-from-kill-ring "Paste from kill ring: ")))
      (unless (string-empty-p text)
        (ghostel--paste-text text)))))

(defun ghostel-embedded-xterm-paste (event)
  "Forward xterm-paste EVENT to the current buffer's embedded terminal."
  (interactive "e")
  (unless (eq (car-safe event) 'xterm-paste)
    (error "This command must be bound to an xterm-paste event"))
  (when-let* ((text (nth 1 event)))
    (when (ghostel--embedded-live-p ghostel--embedded-session)
      (when (bound-and-true-p xterm-store-paste-on-kill-ring)
        (kill-new text))
      (ghostel--paste-text text))))

(defvar-keymap ghostel-embedded-semi-char-map
  :doc "Keymap for input while an embedded terminal is live.
Most keys go to the terminal through the standard ghostel input
commands, which use the host buffer's session terminal.  Copy and line
modes are not available because the host buffer keeps its own major
mode; the terminal interrupt, EOF, quit and kill keys are bound
directly.")

(ghostel--define-terminal-keys ghostel-embedded-semi-char-map)

(define-keymap :keymap ghostel-embedded-semi-char-map
  "C-c C-c"       #'ghostel-embedded-send-C-c
  "C-c C-d"       #'ghostel-embedded-send-C-d
  "C-c C-\\"      #'ghostel-embedded-send-C-backslash
  "C-c C-k"       #'ghostel-embedded-kill-process
  "C-c C-j"       #'ghostel-embedded-semi-char-mode
  "C-c C-e"       #'ghostel-embedded-emacs-mode
  "C-c M-d"       #'ghostel-embedded-char-mode
  "C-y"           #'ghostel-embedded-yank
  "M-y"           #'ghostel-embedded-yank-pop
  "S-<insert>"    #'ghostel-embedded-yank
  "<xterm-paste>" #'ghostel-embedded-xterm-paste
  "<down-mouse-1>" #'ghostel-embedded-mouse-press
  "<mouse-1>"      #'ghostel-embedded-mouse-release
  "<drag-mouse-1>" #'ghostel-embedded-mouse-drag
  "<down-mouse-2>" #'ghostel-embedded-mouse-press
  "<mouse-2>"      #'ghostel-embedded-mouse-release
  "<drag-mouse-2>" #'ghostel-embedded-mouse-drag
  "<down-mouse-3>" #'ghostel-embedded-mouse-press
  "<mouse-3>"      #'ghostel-embedded-mouse-release
  "<drag-mouse-3>" #'ghostel-embedded-mouse-drag
  "<wheel-up>"     #'ghostel-embedded-mouse-wheel
  "<wheel-down>"   #'ghostel-embedded-mouse-wheel
  "<mouse-4>"      #'ghostel-embedded-mouse-wheel
  "<mouse-5>"      #'ghostel-embedded-mouse-wheel)

(defvar-keymap ghostel-embedded-char-map
  :doc "Keymap for char input mode of an embedded terminal.
Every key reaches the terminal; \\[ghostel-embedded-semi-char-mode]
returns to semi-char mode.")

(ghostel--define-terminal-keys ghostel-embedded-char-map 'no-exceptions)

(define-keymap :keymap ghostel-embedded-char-map
  "M-RET"      #'ghostel-embedded-semi-char-mode
  "M-<return>" #'ghostel-embedded-semi-char-mode
  "C-M-m"      #'ghostel-embedded-semi-char-mode
  "<down-mouse-1>" #'ghostel-embedded-mouse-press
  "<mouse-1>"      #'ghostel-embedded-mouse-release
  "<drag-mouse-1>" #'ghostel-embedded-mouse-drag
  "<down-mouse-2>" #'ghostel-embedded-mouse-press
  "<mouse-2>"      #'ghostel-embedded-mouse-release
  "<drag-mouse-2>" #'ghostel-embedded-mouse-drag
  "<down-mouse-3>" #'ghostel-embedded-mouse-press
  "<mouse-3>"      #'ghostel-embedded-mouse-release
  "<drag-mouse-3>" #'ghostel-embedded-mouse-drag
  "<wheel-up>"     #'ghostel-embedded-mouse-wheel
  "<wheel-down>"   #'ghostel-embedded-mouse-wheel
  "<mouse-4>"      #'ghostel-embedded-mouse-wheel
  "<mouse-5>"      #'ghostel-embedded-mouse-wheel)

(defvar-local ghostel--embedded-semi-char-active nil
  "Non-nil while this buffer's embedded terminal is in semi-char mode.
Gates `ghostel-embedded-semi-char-map' in `emulation-mode-map-alists' so
it beats the host's minor-mode maps, which otherwise capture keys such
as the arrow keys in Eshell.")

(defvar-local ghostel--embedded-char-active nil
  "Non-nil while this buffer's embedded terminal is in char mode.
Gates `ghostel-embedded-char-map' in `emulation-mode-map-alists'.")

(defvar ghostel--embedded-override-alist
  `((ghostel--embedded-semi-char-active . ,ghostel-embedded-semi-char-map)
    (ghostel--embedded-char-active . ,ghostel-embedded-char-map))
  "Alist for `emulation-mode-map-alists'.
Minor-mode maps outrank a buffer's local map, so the embedded terminal's
input maps must live here to take precedence over the host's minor modes.")

(add-to-list 'emulation-mode-map-alists 'ghostel--embedded-override-alist)

(defun ghostel--embedded-emacs-mode-map (session)
  "Return SESSION's host keymap plus terminal switch bindings.
Used in Emacs mode: the host's own keymap is active for navigation and
copying, with \\[ghostel-embedded-semi-char-mode] and
\\[ghostel-embedded-char-mode] bound on top."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (ghostel-embedded-saved-map session))
    (define-key map (kbd "C-c C-j") #'ghostel-embedded-semi-char-mode)
    (define-key map (kbd "C-c M-d") #'ghostel-embedded-char-mode)
    map))

(defun ghostel-embedded-semi-char-mode ()
  "Switch the current buffer's embedded terminal to semi-char mode.
Most keys reach the terminal; Emacs prefixes stay available."
  (interactive)
  (ghostel--embedded-set-input-mode 'semi-char))

(defun ghostel-embedded-char-mode ()
  "Switch the current buffer's embedded terminal to char mode.
Every key reaches the terminal; \\[ghostel-embedded-semi-char-mode]
returns to semi-char mode."
  (interactive)
  (ghostel--embedded-set-input-mode 'char))

(defun ghostel-embedded-emacs-mode ()
  "Switch the current buffer's embedded terminal to Emacs mode.
The host keymap returns so you can navigate and copy while the terminal
keeps running; \\[ghostel-embedded-semi-char-mode] returns to that mode."
  (interactive)
  (ghostel--embedded-set-input-mode 'emacs))

(defun ghostel--embedded-set-input-mode (mode)
  "Set the current buffer's embedded terminal to input MODE.
MODE is `semi-char', `char' or `emacs'."
  (let ((session ghostel--embedded-session))
    (unless (ghostel--embedded-live-p session)
      (user-error "No embedded terminal in this buffer"))
    (setf (ghostel-embedded-input-mode session) mode)
    (ghostel--embedded-refresh-input-map session)))

(defun ghostel--embedded-refresh-input-map (session)
  "Update SESSION's host buffer keymap and point for its input mode."
  (with-current-buffer (ghostel-embedded-buffer session)
    (setq ghostel--embedded-semi-char-active nil
          ghostel--embedded-char-active nil)
    (pcase (ghostel-embedded-input-mode session)
      ('semi-char
       (setq ghostel--embedded-semi-char-active t)
       (use-local-map ghostel-embedded-semi-char-map)
       (ghostel--embedded-follow session))
      ('char
       (setq ghostel--embedded-char-active t)
       (use-local-map ghostel-embedded-char-map)
       (ghostel--embedded-follow session))
      ('emacs
       (use-local-map (ghostel--embedded-emacs-mode-map session))
       (ghostel--embedded-update-cursor session)))))

(defun ghostel--embedded-activate-input (session)
  "Install SESSION's input state in its host buffer.
Binds `ghostel--term', `ghostel--process' and `ghostel--input-mode' so
the standard ghostel input commands reach SESSION's terminal, and
switches the buffer to `ghostel-embedded-semi-char-map'.  Attach the
process first: the key encoder writes through the bound PTY."
  (with-current-buffer (ghostel-embedded-buffer session)
    (unless (ghostel-embedded-input-active session)
      (setf (ghostel-embedded-input-active session) t
            (ghostel-embedded-saved-map session) (current-local-map)
            (ghostel-embedded-saved-term session) ghostel--term
            (ghostel-embedded-saved-process session) ghostel--process
            (ghostel-embedded-saved-input-mode session) ghostel--input-mode
            (ghostel-embedded-saved-point session) (point-marker)))
    (setq ghostel--term (ghostel-embedded-term session)
          ghostel--process (ghostel-embedded-process session)
          ghostel--input-mode 'semi-char
          ghostel--embedded-semi-char-active t
          ghostel--embedded-char-active nil)
    (use-local-map ghostel-embedded-semi-char-map))
  session)

(defun ghostel--embedded-deactivate-input (session)
  "Restore SESSION's host buffer keymap and terminal input state."
  (when (and (ghostel-embedded-p session)
             (buffer-live-p (ghostel-embedded-buffer session)))
    (with-current-buffer (ghostel-embedded-buffer session)
      (when (ghostel-embedded-input-active session)
        (use-local-map (ghostel-embedded-saved-map session))
        (setq ghostel--term (ghostel-embedded-saved-term session)
              ghostel--process (ghostel-embedded-saved-process session)
              ghostel--input-mode (ghostel-embedded-saved-input-mode session)
              ghostel--embedded-semi-char-active nil
              ghostel--embedded-char-active nil)
        (setf (ghostel-embedded-input-active session) nil
              (ghostel-embedded-saved-map session) nil
              (ghostel-embedded-saved-term session) nil
              (ghostel-embedded-saved-process session) nil
              (ghostel-embedded-saved-input-mode session) nil))))
  session)

(defun ghostel--embedded-trim-trailing-blank-lines (session)
  "Delete the trailing blank rows of SESSION's frozen region.
Keeps the last row that has content together with its newline.  An
all-blank region is emptied."
  (let ((bounds (ghostel--embedded-region-bounds session)))
    (when (and bounds (< (car bounds) (cdr bounds)))
      (let ((end (cdr bounds))
            (pos (car bounds))
            (last-used (car bounds))
            (inhibit-read-only t))
        (while (< pos end)
          (let* ((line-end (save-excursion
                             (goto-char pos)
                             (line-end-position)))
                 (blank (string-match-p
                         "\\`[ \t]*\\'"
                         (buffer-substring-no-properties pos line-end))))
            (unless blank
              ;; Keep the newline that terminates the last content row.
              (setq last-used (min (1+ line-end) end)))
            (setq pos (min (1+ line-end) end))))
        (when (< last-used end)
          (delete-region last-used end))))))

(defun ghostel--embedded-ensure-trailing-newline (session)
  "Ensure SESSION's non-empty frozen region ends with a newline."
  (let ((bounds (ghostel--embedded-region-bounds session)))
    (when (and bounds (< (car bounds) (cdr bounds)))
      (with-silent-modifications
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (cdr bounds))
            (unless (eq (char-before) ?\n)
              (insert "\n"))))))))

(defun ghostel--embedded-finish (session)
  "Freeze SESSION's terminal content into ordinary host-buffer text.
Discards any alternate screen the program left active, draws the final
frame, trims trailing blank rows, removes the live-region presentation,
restores the host keymap, and drops the terminal handle so the native
object can be collected.  In a terminal input mode point ends at the end
of the frozen region, where the host's next prompt appears; in Emacs
mode it stays where the user left it.  Safe to call more than once.
Returns SESSION."
  (when (ghostel-embedded-p session)
    (when (ghostel--embedded-live-p session)
      (with-current-buffer (ghostel-embedded-buffer session)
        (ghostel--embedded-cancel-timer session)
        ;; The final frame and the alt-screen reset are best-effort: even if
        ;; the native renderer signals (e.g. on a glyph it cannot shape), the
        ;; cleanup below must still run so the region becomes ordinary
        ;; editable text and the terminal handle is released.
        (condition-case nil
            (let ((term (ghostel-embedded-term session))
                  (inhibit-read-only t)
                  (inhibit-modification-hooks t))
              ;; Freeze the normal screen: an alternate-screen frame belongs
              ;; to the program, not to the host buffer's history.  DECSTR and
              ;; mode 2026 reset match what the full-buffer sentinel does.
              (when (ghostel--alt-screen-p term)
                (ghostel--write-vt term "\e[?1049l"))
              (ghostel--write-vt term "\e[!p\e[?2026l")
              (ghostel--redraw term nil t))
          (error nil))
        (ghostel--embedded-clear-cursor)
        (ghostel--embedded-remove-region-props session)
        (setq-local ghostel--resize-request-function nil)
        (ghostel--embedded-trim-trailing-blank-lines session)
        (ghostel--embedded-ensure-trailing-newline session)
        (ghostel--embedded-deactivate-input session)
        (let ((saved (ghostel-embedded-saved-point session)))
          ;; Terminal modes land at the end of the frozen region so the
          ;; host's next prompt is ready for input; Emacs mode keeps the
          ;; user's placement.
          (unless (eq (ghostel-embedded-input-mode session) 'emacs)
            (let ((end (marker-position (ghostel-embedded-end session))))
              (when end (goto-char end))))
          (when (markerp saved) (set-marker saved nil))
          (setf (ghostel-embedded-saved-point session) nil))
        ;; A native child outlives the Emacs process abstraction: request
        ;; its reader to stop.  The host detaches the event pipe when the
        ;; buffer goes away, so the original sentinel still sees a live
        ;; process buffer and can finish Eshell's bookkeeping.
        (when (ghostel-embedded-native-p session)
          (when-let* ((term (ghostel-embedded-term session)))
            (ignore-errors (ghostel--kill-native-process term))))
        (ghostel--set-region (ghostel-embedded-term session) nil nil)
        (setf (ghostel-embedded-term session) nil)
        (when (eq ghostel--embedded-session session)
          (setq ghostel--embedded-session nil))))
    session))

(provide 'ghostel-embedded)
;;; ghostel-embedded.el ends here
