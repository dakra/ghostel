;;; ghostel-tmux.el --- tmux control mode integration for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Connects to an external tmux session via control mode (`tmux -CC') and
;; materializes its panes into native ghostel buffers.  Each tmux pane is
;; rendered through a real ghostel terminal instance, so all of ghostel's
;; navigation, scrollback, copy-mode, theme-sync and evil integration apply
;; unchanged.
;;
;; Two entry points:
;;
;;   M-x ghostel-tmux-attach   -- attach to a running tmux session, materialize
;;                                all panes, and route input/output live.
;;   M-x ghostel-tmux-capture  -- one-shot snapshot of a single pane's
;;                                scrollback into a fresh buffer; no live
;;                                connection is established.
;;
;; The integration is implemented purely in Elisp: `tmux -CC' runs as a
;; dedicated Emacs subprocess whose output IS the control-mode protocol
;; stream, parsed line-by-line by a process filter.  Pane data is fed
;; into the existing native VT engine via `ghostel--write-vt', and
;; outbound keystrokes are routed through `ghostel--pty-out-function'
;; to the control-mode channel as `send-keys -H' commands.

;;; Code:

(require 'ghostel)
(require 'cl-lib)
(require 'subr-x)
(require 'tab-line)

(declare-function ghostel--write-vt "ghostel-module" (term data))


;; Customization

(defgroup ghostel-tmux nil
  "Tmux control mode integration for ghostel."
  :group 'ghostel
  :prefix "ghostel-tmux-")

(defcustom ghostel-tmux-program "tmux"
  "The tmux executable to invoke for control mode."
  :type 'string
  :group 'ghostel-tmux)

(defvar ghostel-tmux-prefix-map)  ; Forward declaration for the defcustom :set function.

(defcustom ghostel-tmux-prefix-key "C-t"
  "Key sequence used as the tmux prefix in pane buffers.
A `kbd'-style string (e.g. \"\\`C-t'\", \"\\`C-b'\").  Changing this
rebinds the prefix in `ghostel-tmux-pane-mode-map', so existing pane
buffers pick up the change immediately."
  :type 'string
  :group 'ghostel-tmux
  :set (lambda (sym val)
         (let ((old (and (boundp sym) (symbol-value sym))))
           (set-default sym val)
           (when (boundp 'ghostel-tmux-pane-mode-map)
             (when (and old (not (equal old val)))
               (define-key ghostel-tmux-pane-mode-map (kbd old) nil)
               (define-key ghostel-tmux-prefix-map (kbd old) nil))
             (ghostel-tmux--install-prefix-key val)))))

(defcustom ghostel-tmux-default-rows 40
  "Default row count when creating pane terminals before resize."
  :type 'integer
  :group 'ghostel-tmux)

(defcustom ghostel-tmux-default-cols 120
  "Default column count when creating pane terminals before resize."
  :type 'integer
  :group 'ghostel-tmux)

(defcustom ghostel-tmux-history-lines 10000
  "Maximum scrollback lines requested via `capture-pane' on attach."
  :type 'integer
  :group 'ghostel-tmux)

(defcustom ghostel-tmux-buffer-name-function
  #'ghostel-tmux--default-buffer-name
  "Function returning a pane buffer name.
Called with three arguments: SESSION-NAME (string), WINDOW-NAME (string
or nil) and PANE-ID (integer).  Must return a string."
  :type 'function
  :group 'ghostel-tmux)


;; Internal state — controller buffer

;; The "controller" is a hidden buffer that owns the tmux -CC subprocess.
;; It holds all parser state and dispatches notifications to pane buffers.

(defvar-local ghostel-tmux--controller-process nil
  "The tmux -CC subprocess hosted in this controller buffer.")

(defvar-local ghostel-tmux--parser-state 'preamble
  "Wire-format parser state.
One of: preamble, idle, notification, block.")

(defvar-local ghostel-tmux--line-buffer ""
  "Partial line accumulator across `process-filter' chunks.")

(defvar-local ghostel-tmux--block-lines nil
  "Reversed list of lines accumulated for the in-flight block payload.")

(defvar-local ghostel-tmux--block-tag nil
  "When inside a `%begin'/`%end' block, the parsed (TIME CMD FLAGS) tuple.
Currently only used by the parser to track that a block is open;
inspected for reset on terminator parsing.")

(defvar-local ghostel-tmux--command-queue nil
  "FIFO of pending tmux commands, each (CMD-STRING . CONTINUATION).
CONTINUATION is called with one argument BLOCK-OUTPUT (string) when the
matching `%end' arrives; or with nil when an `%error' is received.")

(defvar-local ghostel-tmux--command-in-flight nil
  "The (CMD-STRING . CONTINUATION) currently awaiting a block reply.")

(defvar-local ghostel-tmux--session-id nil
  "Numeric tmux session id this controller is attached to.")

(defvar-local ghostel-tmux--session-name nil
  "Human-readable tmux session name.")

(defvar-local ghostel-tmux--tmux-version nil
  "Version string reported by `display-message #{version}'.")

(defvar-local ghostel-tmux--panes nil
  "Hash table mapping integer pane-id (e.g. %3 -> 3) to its buffer.")

(defvar-local ghostel-tmux--windows nil
  "Hash table mapping integer window-id to plist (:name :panes :layout).")

(defvar-local ghostel-tmux--window-order nil
  "List of integer window-ids in display order.")

(defvar-local ghostel-tmux--active-pane-id nil
  "Pane id of the tmux-side active pane, or nil before known.")

(defvar-local ghostel-tmux--pending-follow-wid nil
  "Window id whose active pane we should follow once it materializes.
Set by `--on-session-window-changed' when tmux moves the session
to a window we haven't yet populated (typical for `new-window':
`%session-window-changed' fires before `%window-add'+list-windows
materialize the pane buffers).  Consumed by `--on-layout-change'.")

(defvar-local ghostel-tmux--viewer-buffer nil
  "Most-recently-displayed pane buffer, used to focus user actions.")

(defvar-local ghostel-tmux--exit-reason nil
  "Reason string from `%exit', for diagnostics.")

(defvar ghostel-tmux--in-write-vt nil
  "Non-nil while feeding tmux `%output' bytes into a pane's VT engine.
Any `ghostel--pty-out-function' callbacks the engine produces in
response — OSC color-query replies, DA reports, cursor-position
reports — are suppressed while this is set.  Without that, a query
from an inner program (e.g. `bat' asking for terminal colors) would
round-trip through `send-keys', and by the time tmux delivered the
reply to the pane's stdin the program had usually exited; the bytes
then leaked into the next shell prompt as if typed.")


;; Internal state — pane buffer

(defvar-local ghostel-tmux--controller-buffer nil
  "Pointer back to the controller buffer hosting the tmux process.")

(defvar-local ghostel-tmux--pane-id nil
  "Integer tmux pane id (e.g. 3 for %3) for this buffer.")

(defvar-local ghostel-tmux--window-id nil
  "Integer tmux window id this pane belongs to.")

(defvar-local ghostel-tmux--pane-name nil
  "Optional human label for this pane (window-name or index).")

(defvar-local ghostel-tmux--initialized nil
  "Non-nil once the initial capture-pane backfill has completed.
%output notifications received before this flag is set are dropped:
their effect is already contained in the `visible' capture snapshot.")

(defvar-local ghostel-tmux--bootstrap-pending nil
  "Non-nil while this pane's capture-pane backfill commands are queued.
Guards `ghostel-tmux--on-layout-change' against queuing a second
backfill pair when another `%layout-change' arrives before the first
pair's replies; a duplicate pair would render the pane's scrollback
twice.")


;; Octal escape decoding

;; tmux's `%output' payload escapes 0x00-0x1F (and DEL) as 3-digit octal
;; "\NNN" — for example ESC arrives as the four ASCII bytes "\033", CR as
;; "\015", LF as "\012".  We must decode these back to raw bytes before
;; feeding them to the VT engine.

(defconst ghostel-tmux--octal-rx
  "\\\\\\([0-7][0-7][0-7]\\)"
  "Match a single 3-digit octal escape `\\NNN' on tmux's wire.")

(defun ghostel-tmux--decode-output (data)
  "Return DATA with tmux octal `\\NNN' escapes decoded to raw bytes.
The result is a unibyte string suitable for `ghostel--write-vt'.
Escapes >= \\200 must decode via `unibyte-string': `string' would
produce a multibyte Latin-1 character whose binary encoding is its
two-byte internal form, not the single raw byte."
  (let ((decoded
         (replace-regexp-in-string
          ghostel-tmux--octal-rx
          (lambda (m)
            (unibyte-string (string-to-number (match-string 1 m) 8)))
          data t t)))
    (encode-coding-string decoded 'binary)))


;; Layout string parser

;; Layout grammar (ghostty/src/terminal/tmux/layout.zig):
;;
;;   layout    := CHECKSUM ',' node
;;   node      := WIDTHxHEIGHT,X,Y(content)
;;   content   := ',' PANE_ID                      ; leaf
;;              | '{' node (',' node)* '}'         ; horizontal split
;;              | '[' node (',' node)* ']'         ; vertical split
;;
;; We don't model splits visually (single window, tab-line for switching)
;; so we only extract a flat list of (PANE-ID . (W H X Y)) leaves.

(defun ghostel-tmux--parse-layout (layout)
  "Parse a tmux LAYOUT string and return a list of pane records.
Each record is (PANE-ID WIDTH HEIGHT X Y).  The leading 4-char checksum
and its comma are ignored."
  (when (and layout (> (length layout) 5))
    (let ((idx 5)                         ; skip "XXXX,"
          (panes nil))
      (cl-labels
          ((expect (ch)
             (unless (and (< idx (length layout))
                          (eq (aref layout idx) ch))
               (error "Tmux layout: expected %c at %d in %s" ch idx layout))
             (cl-incf idx))
           (read-int ()
             (let ((start idx))
               (while (and (< idx (length layout))
                           (let ((c (aref layout idx)))
                             (and (>= c ?0) (<= c ?9))))
                 (cl-incf idx))
               (when (= start idx)
                 (error "Tmux layout: expected integer at %d in %s"
                        idx layout))
               (string-to-number (substring layout start idx))))
           (parse-node ()
             (let* ((w (read-int))
                    (_ (expect ?x))
                    (h (read-int))
                    (_ (expect ?,))
                    (x (read-int))
                    (_ (expect ?,))
                    (y (read-int))
                    (next (and (< idx (length layout)) (aref layout idx))))
               (cond
                ((eq next ?,)
                 (cl-incf idx)
                 (let ((pid (read-int)))
                   (push (list pid w h x y) panes)))
                ((or (eq next ?\{) (eq next ?\[))
                 (let ((closer (if (eq next ?\{) ?\} ?\])))
                   (cl-incf idx)
                   (parse-node)
                   (while (and (< idx (length layout))
                               (eq (aref layout idx) ?,))
                     (cl-incf idx)
                     (parse-node))
                   (expect closer)))
                (t
                 (error "Tmux layout: unexpected %s at %d in %s"
                        (and next (string next)) idx layout))))))
        (parse-node)
        (nreverse panes)))))


;; Wire-format parser

;; tmux -CC emits a stream framed line-by-line.  States:
;;
;;   preamble     -- before the DCS `\eP1000p'.  Drop bytes until we see it
;;                   (or until we see the first `%' if the DCS was lost).
;;   idle         -- between notifications.  Protocol lines begin with `%'
;;                   (or `\e\\' to end DCS); bare lines are dropped — tmux
;;                   delivers async `run-shell' output as bare lines outside
;;                   any block.
;;   notification -- accumulating a single `%foo ...' line.
;;   block        -- between `%begin' and `%end'/`%error'.  Lines are
;;                   accumulated verbatim until a terminator line matches.

(defconst ghostel-tmux--block-terminator-rx
  "\\`%\\(end\\|error\\) \\([0-9]+\\) \\([0-9]+\\) \\([0-9]+\\)\\'"
  "Pattern matching a `%end TIME CMD FLAGS' or `%error ...' terminator.")

(defvar ghostel-tmux--in-feed nil
  "Non-nil while `ghostel-tmux--feed-bytes' is dispatching protocol lines.
Controller sends triggered from inside the feed (command
continuations, layout-driven resizes) are deferred to a timer by
`ghostel-tmux--pump-command-queue': a blocking process write can
re-enter process filters and deliver protocol bytes out of order.")

(defun ghostel-tmux--feed-bytes (string)
  "Feed STRING (process output) to the parser in the current buffer.
Splits on newlines, dispatches per-line via the state machine."
  (setq ghostel-tmux--line-buffer
        (concat ghostel-tmux--line-buffer string))
  ;; Strip the DCS preamble `\eP1000p' if we haven't seen it yet.
  (when (eq ghostel-tmux--parser-state 'preamble)
    (let ((p (string-match-p "\eP1000p" ghostel-tmux--line-buffer)))
      (when p
        (setq ghostel-tmux--line-buffer
              (substring ghostel-tmux--line-buffer (+ p 7)))
        (setq ghostel-tmux--parser-state 'idle))))
  (when (eq ghostel-tmux--parser-state 'preamble)
    ;; Some tmux configurations may not send the DCS; if we ever see a
    ;; `%' at line-start, switch to idle.  Anything before that `%' is
    ;; dispatched as idle lines, where non-protocol lines are dropped.
    (when (string-match-p "^%" ghostel-tmux--line-buffer)
      (setq ghostel-tmux--parser-state 'idle)))
  (when (memq ghostel-tmux--parser-state '(idle notification block))
    (let ((idx 0)
          (ghostel-tmux--in-feed t))
      ;; `ghostel-tmux--handle-line' may reset
      ;; `ghostel-tmux--line-buffer' under our feet — re-check the
      ;; buffer length before every match so a stale IDX can't index
      ;; past the emptied accumulator.
      (while (and (<= idx (length ghostel-tmux--line-buffer))
                  (string-match "\r?\n" ghostel-tmux--line-buffer idx))
        (let ((line (substring ghostel-tmux--line-buffer
                               idx (match-beginning 0))))
          (setq idx (match-end 0))
          (ghostel-tmux--handle-line line)))
      (setq ghostel-tmux--line-buffer
            (if (<= idx (length ghostel-tmux--line-buffer))
                (substring ghostel-tmux--line-buffer idx)
              "")))))

(defun ghostel-tmux--handle-line (line)
  "Dispatch a single LINE (no trailing CRLF) through the state machine."
  (pcase ghostel-tmux--parser-state
    ('idle (ghostel-tmux--handle-idle-line line))
    ('block (ghostel-tmux--handle-block-line line))
    ('notification
     ;; Single-line notification mode is handled inline in the idle state.
     (setq ghostel-tmux--parser-state 'idle)
     (ghostel-tmux--handle-idle-line line))
    (_ nil)))

(defun ghostel-tmux--handle-idle-line (line)
  "Parse a single notification LINE while in idle state."
  (cond
   ((string-empty-p line) nil)
   ((string-prefix-p "\e\\" line) nil)   ; DCS ST closer; ignore
   ((not (eq (aref line 0) ?%))
    ;; Bare non-protocol line.  tmux legitimately emits these: async
    ;; `run-shell' output arrives as bare lines outside any
    ;; %begin/%end block.  Drop and keep parsing.
    nil)
   (t
    (cond
     ((string-match
       "\\`%begin \\([0-9]+\\) \\([0-9]+\\) \\([0-9]+\\)\\'"
       line)
      (setq ghostel-tmux--parser-state 'block
            ghostel-tmux--block-lines nil
            ghostel-tmux--block-tag
            (list :time (match-string 1 line)
                  :cmd (match-string 2 line)
                  :flags (match-string 3 line))))
     (t (ghostel-tmux--dispatch-notification line))))))

(defun ghostel-tmux--handle-block-line (line)
  "Inside a block, check LINE against the terminator and otherwise accumulate.
A terminator only counts when its TIME and CMD fields match the
opening `%begin' tag — block payload can legitimately contain lines
that look like `%end N N N' (e.g. a captured pane that was itself
showing a control-mode transcript)."
  (if (and (string-match ghostel-tmux--block-terminator-rx line)
           (let ((tag ghostel-tmux--block-tag))
             (or (null tag)
                 (and (equal (match-string 2 line) (plist-get tag :time))
                      (equal (match-string 3 line) (plist-get tag :cmd))))))
      (let* ((kind (match-string 1 line))
             (payload (mapconcat #'identity
                                 (nreverse ghostel-tmux--block-lines)
                                 "\n"))
             (cmd ghostel-tmux--command-in-flight))
        (setq ghostel-tmux--block-lines nil
              ghostel-tmux--block-tag nil
              ghostel-tmux--parser-state 'idle
              ghostel-tmux--command-in-flight nil)
        (when cmd
          (let ((cont (cdr cmd)))
            (when cont
              (condition-case err
                  (funcall cont (and (equal kind "end") payload))
                (error
                 (message "Ghostel-tmux: Command continuation error: %s"
                          (error-message-string err)))))))
        (ghostel-tmux--pump-command-queue))
    (push line ghostel-tmux--block-lines)))

(defun ghostel-tmux--seal-pane-buffer (pane-buf)
  "Seal PANE-BUF as a read-only snapshot with no output routing."
  (when (buffer-live-p pane-buf)
    (with-current-buffer pane-buf
      (setq ghostel--pty-out-function nil
            buffer-read-only t))))

(defun ghostel-tmux--seal-panes (controller)
  "Seal every pane buffer belonging to CONTROLLER read-only.
CONTROLLER may already be a killed buffer; its pane table is gone
then, so panes are found by scanning `buffer-list' for pane buffers
whose back-pointer matches."
  (if (buffer-live-p controller)
      (with-current-buffer controller
        (when ghostel-tmux--panes
          (maphash (lambda (_pid buf) (ghostel-tmux--seal-pane-buffer buf))
                   ghostel-tmux--panes)))
    (dolist (buf (buffer-list))
      (when (and (buffer-local-value 'ghostel-tmux-pane-mode buf)
                 (eq (buffer-local-value 'ghostel-tmux--controller-buffer buf)
                     controller))
        (ghostel-tmux--seal-pane-buffer buf)))))

;;;###autoload
(defun ghostel-tmux-reset ()
  "Reset the tmux session this buffer belongs to.
Kills the dedicated `tmux -CC' subprocess and seals its pane buffers
read-only.  Works from a pane buffer as well as the controller; use
as an escape hatch when you no longer want tmux integration here."
  (interactive)
  (let ((controller (or ghostel-tmux--controller-buffer
                        (and (derived-mode-p 'ghostel-tmux-control-mode)
                             (current-buffer)))))
    (if (buffer-live-p controller)
        (with-current-buffer controller
          (when (and ghostel-tmux--controller-process
                     (process-live-p ghostel-tmux--controller-process))
            (delete-process ghostel-tmux--controller-process))
          (ghostel-tmux--seal-panes controller)
          (message "Ghostel-tmux: Session reset; pane buffers sealed"))
      (message "Ghostel-tmux: No tmux state in this buffer"))))


;; Notification dispatch

(defun ghostel-tmux--dispatch-notification (line)
  "Dispatch a single notification LINE in idle state."
  (cond
   ((string-match "\\`%output %\\([0-9]+\\) \\(.*\\)\\'" line)
    (let ((pid (string-to-number (match-string 1 line)))
          (data (match-string 2 line)))
      (ghostel-tmux--on-output pid data)))
   ((string-match "\\`%session-changed \\$\\([0-9]+\\) \\(.+\\)\\'" line)
    (ghostel-tmux--on-session-changed
     (string-to-number (match-string 1 line))
     (match-string 2 line)))
   ((string-match "\\`%session-window-changed \\$\\([0-9]+\\) @\\([0-9]+\\)\\'"
                  line)
    (ghostel-tmux--on-session-window-changed
     (string-to-number (match-string 1 line))
     (string-to-number (match-string 2 line))))
   ;; tmux >= 2.5 prefixes the new name with the session id; older
   ;; versions emit the name alone.
   ((string-match "\\`%session-renamed \\(?:\\$[0-9]+ \\)?\\(.+\\)\\'" line)
    (ghostel-tmux--on-session-renamed (match-string 1 line)))
   ((string= "%sessions-changed" line)
    nil)                                   ; treat as advisory
   ((string-match "\\`%window-add @\\([0-9]+\\)\\'" line)
    (ghostel-tmux--on-window-add
     (string-to-number (match-string 1 line))))
   ((string-match "\\`%\\(?:unlinked-\\)?window-close @\\([0-9]+\\)\\'" line)
    ;; tmux 3.6 emits `%unlinked-window-close @WID' for the client whose
    ;; session no longer contains the window — which is the only client
    ;; in the single-attach case — so the pane buffers stay orphaned
    ;; unless we treat both forms as the close signal.
    (ghostel-tmux--on-window-close
     (string-to-number (match-string 1 line))))
   ((string-match "\\`%window-renamed @\\([0-9]+\\) \\(.*\\)\\'" line)
    (ghostel-tmux--on-window-renamed
     (string-to-number (match-string 1 line))
     (match-string 2 line)))
   ((string-match
     "\\`%window-pane-changed @\\([0-9]+\\) %\\([0-9]+\\)\\'" line)
    (ghostel-tmux--on-window-pane-changed
     (string-to-number (match-string 1 line))
     (string-to-number (match-string 2 line))))
   ((string-match
     ;; tmux 3.6 always emits 4 fields:
     ;;   %layout-change @WID LAYOUT VISIBLE_LAYOUT RAW_FLAGS
     ;; but `#{window_raw_flags}' can expand to "" for a window with no
     ;; printable flags, producing a trailing space we must tolerate.
     ;; Older tmux only emits the LAYOUT field.
     "\\`%layout-change @\\([0-9]+\\) \\([^ ]+\\)\\(?: [^ ]*\\)\\{0,3\\} *\\'"
     line)
    (ghostel-tmux--on-layout-change
     (string-to-number (match-string 1 line))
     (match-string 2 line)))
   ((string-match "\\`%exit\\(?: \\(.*\\)\\)?\\'" line)
    (ghostel-tmux--on-exit (match-string 1 line)))
   (t
    ;; Unknown notification — log and continue.
    nil)))


;; Controller output channel

;; A controller owns a plain `tmux -CC' subprocess whose stdin accepts
;; commands directly.  `ghostel-tmux--controller-send' is the low-level
;; transport; every command must reach it through
;; `ghostel-tmux--queue-command'.  tmux control mode emits a
;; `%begin'/`%end' reply block for every command line in wire order, so
;; a command sent outside the FIFO queue while another is in flight
;; shifts the block-to-continuation pairing by one for the rest of the
;; session.

(defun ghostel-tmux--controller-live-p ()
  "Return non-nil when the current controller buffer can reach tmux."
  (and ghostel-tmux--controller-process
       (process-live-p ghostel-tmux--controller-process)))

(defun ghostel-tmux--controller-send (data)
  "Send DATA (raw command bytes) to tmux from the current controller buffer."
  (when (ghostel-tmux--controller-live-p)
    (process-send-string ghostel-tmux--controller-process data)))


;; Command queue

(defun ghostel-tmux--queue-command (cmd &optional cont)
  "Queue CMD (a tmux command string, no trailing newline) for the controller.
CONT, if given, is called with the block payload (or nil on error)."
  (setq ghostel-tmux--command-queue
        (nconc ghostel-tmux--command-queue (list (cons cmd cont))))
  (ghostel-tmux--pump-command-queue))

(defvar-local ghostel-tmux--pump-scheduled nil
  "Non-nil while a deferred command-queue pump timer is pending.")

(defun ghostel-tmux--pump-command-queue ()
  "Send the next queued command if no command is in flight.
Inside a feed (see `ghostel-tmux--in-feed') the send is deferred to a
timer instead: writing to the controller can block, and a blocking
process write re-enters process filters mid-parse."
  (when (and (not ghostel-tmux--command-in-flight)
             ghostel-tmux--command-queue)
    (if ghostel-tmux--in-feed
        (unless ghostel-tmux--pump-scheduled
          (setq ghostel-tmux--pump-scheduled t)
          (run-at-time 0 nil #'ghostel-tmux--pump-deferred (current-buffer)))
      (when (ghostel-tmux--controller-live-p)
        (let ((cmd (pop ghostel-tmux--command-queue)))
          (setq ghostel-tmux--command-in-flight cmd)
          (ghostel-tmux--controller-send (concat (car cmd) "\n")))))))

(defun ghostel-tmux--pump-deferred (buffer)
  "Run the command-queue pump in controller BUFFER, outside any feed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ghostel-tmux--pump-scheduled nil)
      (ghostel-tmux--pump-command-queue))))


;; Pane buffer management

(defun ghostel-tmux--default-buffer-name (session-name window-name pane-id)
  "Build a default pane buffer name from SESSION-NAME, WINDOW-NAME, PANE-ID.
A nil WINDOW-NAME (we haven't been told yet) is rendered as
`<unnamed>' so the buffer name doesn't look like a glob pattern."
  (format "*ghostel-tmux:%s:%s%%%d*"
          (or session-name "session")
          (or window-name "<unnamed>")
          pane-id))

(defun ghostel-tmux--get-or-create-pane (controller pane-id window-id
                                                    &optional window-name)
  "Return the pane buffer for PANE-ID under CONTROLLER, creating if needed."
  (with-current-buffer controller
    (let ((existing (gethash pane-id ghostel-tmux--panes)))
      (cond
       ((and existing (buffer-live-p existing))
        (with-current-buffer existing
          (setq ghostel-tmux--window-id window-id)
          (when window-name
            (setq ghostel-tmux--pane-name window-name)))
        existing)
       (t
        (let* ((session-name ghostel-tmux--session-name)
               (name (funcall ghostel-tmux-buffer-name-function
                              (or session-name "?")
                              window-name
                              pane-id))
               (buf (generate-new-buffer name)))
          (puthash pane-id buf ghostel-tmux--panes)
          (ghostel--init-buffer buf ghostel-tmux-default-rows
                                ghostel-tmux-default-cols)
          (with-current-buffer buf
            (ghostel-tmux-pane-mode 1)
            (setq ghostel-tmux--controller-buffer controller
                  ghostel-tmux--pane-id pane-id
                  ghostel-tmux--window-id window-id
                  ghostel-tmux--pane-name window-name
                  ghostel--term-rows ghostel-tmux-default-rows
                  ghostel--term-cols ghostel-tmux-default-cols
                  ghostel--pty-out-function
                  (apply-partially #'ghostel-tmux--send-bytes-from-pane
                                   controller pane-id)))
          buf))))))

(defun ghostel-tmux--remove-pane (controller pane-id)
  "Drop pane PANE-ID from CONTROLLER and kill its buffer."
  (with-current-buffer controller
    (let ((buf (gethash pane-id ghostel-tmux--panes)))
      (when buf
        (remhash pane-id ghostel-tmux--panes)
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (setq ghostel--pty-out-function nil))
          (kill-buffer buf))))))

(defun ghostel-tmux--pane-list (controller)
  "Return the live pane buffers under CONTROLLER, in window+pane order."
  (with-current-buffer controller
    (let ((result nil))
      (dolist (wid (or ghostel-tmux--window-order
                       (and ghostel-tmux--windows
                            (hash-table-keys ghostel-tmux--windows))))
        (maphash (lambda (_pid buf)
                   (when (and (buffer-live-p buf)
                              (eq (buffer-local-value
                                   'ghostel-tmux--window-id buf)
                                  wid))
                     (push buf result)))
                 ghostel-tmux--panes))
      (nreverse result))))


;; Notification handlers

(defun ghostel-tmux--on-output (pane-id data)
  "Handle `%output %PANE-ID DATA' in the controller buffer.
Output arriving before the pane's capture-pane backfill completes is
dropped: the `visible' capture is taken after tmux emitted those
notifications, so their effect is already part of the snapshot and
replaying them would duplicate it."
  (let ((buf (gethash pane-id ghostel-tmux--panes)))
    (when (buffer-live-p buf)
      (let ((decoded (ghostel-tmux--decode-output data)))
        (with-current-buffer buf
          (when ghostel-tmux--initialized
            ;; Native callbacks dispatched while parsing (e.g. OSC 52;e)
            ;; may select another buffer; keep the follow-up
            ;; buffer-local work anchored to this pane buffer.
            (let ((ghostel-tmux--in-write-vt t))
              (save-current-buffer
                (ghostel--write-vt ghostel--term decoded)))
            (ghostel--invalidate)))))))

(defun ghostel-tmux--on-session-changed (sid name)
  "Handle `%session-changed $SID NAME'."
  (let ((first (null ghostel-tmux--session-id))
        (changed (or (not (equal ghostel-tmux--session-id sid))
                     (not (equal ghostel-tmux--session-name name)))))
    (setq ghostel-tmux--session-id sid
          ghostel-tmux--session-name name)
    (cond
     (first
      (ghostel-tmux--initial-bootstrap))
     (changed
      ;; Switching sessions resets pane state.  Wipe and reload.
      (ghostel-tmux--wipe-panes)
      (ghostel-tmux--bootstrap-windows)))))

(defun ghostel-tmux--on-window-add (wid)
  "Handle `%window-add @WID': fetch its layout and create panes."
  (unless (gethash wid ghostel-tmux--windows)
    (puthash wid (list :name nil :layout nil) ghostel-tmux--windows)
    (unless (memq wid ghostel-tmux--window-order)
      (setq ghostel-tmux--window-order
            (append ghostel-tmux--window-order (list wid)))))
  (ghostel-tmux--queue-command
   (format "list-windows -F \"#{window_id}\\t#{window_name}\\t#{window_layout}\" -t @%d"
           wid)
   (lambda (output)
     (when output
       (ghostel-tmux--receive-window-rows output)))))

(defun ghostel-tmux--on-window-close (wid)
  "Handle `%window-close @WID': drop the window and its panes."
  (let ((win (gethash wid ghostel-tmux--windows)))
    (when win
      (let ((panes (plist-get win :panes)))
        (dolist (pid panes)
          (ghostel-tmux--remove-pane (current-buffer) pid))))
    (remhash wid ghostel-tmux--windows))
  (setq ghostel-tmux--window-order
        (delq wid ghostel-tmux--window-order)))

(defun ghostel-tmux--on-session-renamed (name)
  "Handle `%session-renamed': the session is now called NAME.
Updates the session label used for naming and renames existing pane
buffers so they don't keep the stale session name."
  (setq ghostel-tmux--session-name name)
  (when ghostel-tmux--windows
    (maphash
     (lambda (_wid win)
       (let ((window-name (plist-get win :name)))
         (dolist (pid (plist-get win :panes))
           (let ((buf (and ghostel-tmux--panes
                           (gethash pid ghostel-tmux--panes))))
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (rename-buffer (funcall ghostel-tmux-buffer-name-function
                                         name window-name pid)
                                t)
                 (force-mode-line-update)))))))
     ghostel-tmux--windows))
  (ghostel-tmux--refresh-tab-line))

(defun ghostel-tmux--on-window-renamed (wid name)
  "Handle `%window-renamed @WID NAME'."
  (let ((win (gethash wid ghostel-tmux--windows))
        (session-name ghostel-tmux--session-name))
    (when win
      (puthash wid (plist-put win :name name) ghostel-tmux--windows)
      (dolist (pid (plist-get win :panes))
        (let ((buf (gethash pid ghostel-tmux--panes)))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (setq ghostel-tmux--pane-name name)
              (rename-buffer (funcall ghostel-tmux-buffer-name-function
                                      session-name
                                      name pid)
                             t)
              (force-mode-line-update)))))))
  (ghostel-tmux--refresh-tab-line))

(defun ghostel-tmux--follow-active-pane (new-pid)
  "Redirect any Emacs window showing a sibling pane to NEW-PID.
Tmux's active pane is the source of truth — every Emacs-side pane
switch happens here in response to a `%window-pane-changed'
notification (or to a deferred re-trigger from `--on-layout-change'
when the notification raced ahead of the pane buffer's creation)."
  (let* ((new-buf (and new-pid ghostel-tmux--panes
                       (gethash new-pid ghostel-tmux--panes)))
         (controller (current-buffer)))
    (when (buffer-live-p new-buf)
      (setq ghostel-tmux--viewer-buffer new-buf)
      (let (pane-bufs target-window)
        (maphash (lambda (_pid buf) (push buf pane-bufs))
                 ghostel-tmux--panes)
        (walk-windows
         (lambda (window)
           (when (and (not target-window)
                      (memq (window-buffer window) pane-bufs)
                      (not (eq (window-buffer window) new-buf)))
             (setq target-window window)))
         'no-minibuffer 'visible)
        (when target-window
          (with-current-buffer controller
            (ghostel-tmux--display-pane-in-window new-buf target-window)))))))

(defun ghostel-tmux--on-window-pane-changed (wid pid)
  "Handle `%window-pane-changed @WID %PID': record and follow.
Fires when tmux's active pane changes *within* a window (e.g.
`select-pane', `C-t o', kill-pane auto-survivor pick).  Switching
between windows is signalled by `%session-window-changed' and
handled separately.  We also remember each window's active pane
so `--on-session-window-changed' can restore it on cycle-window."
  (setq ghostel-tmux--active-pane-id pid)
  (let ((entry (and wid (gethash wid ghostel-tmux--windows))))
    (when entry
      (puthash wid (plist-put entry :active-pane pid)
               ghostel-tmux--windows)))
  (ghostel-tmux--follow-active-pane pid))

(defun ghostel-tmux--on-session-window-changed (sid wid)
  "Handle `%session-window-changed $SID @WID': follow the new window.
Fires when tmux's active window in the session changes (`C-t c',
`C-t n', `C-t 0'..`9', external `select-window').  Tmux does NOT
emit `%window-pane-changed' for these events — the per-window
active pane is preserved, so the active-pane id doesn't change in
tmux's view; only the *session*'s current window does.

If the target window already has materialized panes, follow the
recorded active pane (or the first pane).  Otherwise mark the
window for deferred follow — `--on-layout-change' picks it up."
  (ignore sid)
  (let* ((entry (gethash wid ghostel-tmux--windows))
         (panes (and entry (plist-get entry :panes)))
         (recorded (and entry (plist-get entry :active-pane)))
         (target (or (and recorded (memq recorded panes) recorded)
                     (car panes)))
         (buf (and target (gethash target ghostel-tmux--panes))))
    (cond
     ((buffer-live-p buf)
      (setq ghostel-tmux--active-pane-id target)
      (ghostel-tmux--follow-active-pane target))
     (t
      (setq ghostel-tmux--pending-follow-wid wid)))))

(defun ghostel-tmux--on-layout-change (wid layout)
  "Handle `%layout-change @WID LAYOUT' — reconcile panes."
  (let* ((panes (ghostel-tmux--parse-layout layout))
         (pane-ids (mapcar #'car panes))
         (existing (gethash wid ghostel-tmux--windows))
         (old-ids (and existing (plist-get existing :panes)))
         (controller (current-buffer))
         (window-name (and existing (plist-get existing :name))))
    (let ((entry (or existing (list :name window-name))))
      (setq entry (plist-put entry :panes pane-ids))
      (setq entry (plist-put entry :layout layout))
      (puthash wid entry ghostel-tmux--windows))
    (unless (memq wid ghostel-tmux--window-order)
      (setq ghostel-tmux--window-order
            (append ghostel-tmux--window-order (list wid))))
    (dolist (pid old-ids)
      (unless (memq pid pane-ids)
        (ghostel-tmux--remove-pane controller pid)))
    (dolist (rec panes)
      (let* ((pid (nth 0 rec))
             (w (nth 1 rec))
             (h (nth 2 rec))
             (buf (ghostel-tmux--get-or-create-pane
                   controller pid wid window-name)))
        (with-current-buffer buf
          ;; Apply tmux's layout geometry to panes that are NOT visible
          ;; in any Emacs window.  For visible panes, the Emacs window
          ;; size is authoritative (`--apply-pane-size' has already set
          ;; it and sent `refresh-client -C'); applying tmux's layout
          ;; here would fight the zoom-induced full-screen rendering and
          ;; the user would see content at half size after every split.
          (when (and ghostel--term
                     (null (get-buffer-window-list buf nil 'visible))
                     (or (not (eql ghostel--term-cols w))
                         (not (eql ghostel--term-rows h))))
            (ghostel--set-size-with-cell-dims ghostel--term h w)
            (setq ghostel--term-cols w
                  ghostel--term-rows h))
          (unless (or ghostel-tmux--initialized
                      ghostel-tmux--bootstrap-pending)
            (setq ghostel-tmux--bootstrap-pending t)
            (ghostel-tmux--bootstrap-pane controller pid)))))
    ;; Deferred follow: `%session-window-changed' fired for this WID
    ;; before its panes existed (typical for new-window — the
    ;; session-window-changed arrives before window-add + list-windows
    ;; materialize the layout).  Now that buffers exist, follow.
    (when (and pane-ids (eql ghostel-tmux--pending-follow-wid wid))
      (setq ghostel-tmux--pending-follow-wid nil)
      (let ((target (car pane-ids)))
        (setq ghostel-tmux--active-pane-id target)
        (ghostel-tmux--follow-active-pane target)))
    ;; Also catch the within-window race: `%window-pane-changed'
    ;; arrived before `%layout-change' created the pane buffer.
    (when (and ghostel-tmux--active-pane-id
               (memq ghostel-tmux--active-pane-id pane-ids))
      (ghostel-tmux--follow-active-pane ghostel-tmux--active-pane-id))
    (ghostel-tmux--refresh-tab-line)))

(defun ghostel-tmux--on-exit (reason)
  "Handle `%exit' from tmux, recording REASON if given."
  (setq ghostel-tmux--exit-reason (or reason ""))
  (message "Ghostel-tmux: tmux exited%s"
           (if (and reason (not (string-empty-p reason)))
               (format ": %s" reason)
             "")))


;; Bootstrap sequence

(defun ghostel-tmux--initial-bootstrap ()
  "Initial command sequence after `%session-changed' arrives."
  (ghostel-tmux--queue-command
   "display-message -p \"#{version}\""
   (lambda (output)
     (when output
       (setq ghostel-tmux--tmux-version (string-trim output)))))
  (ghostel-tmux--bootstrap-windows))

(defun ghostel-tmux--bootstrap-windows ()
  "Fetch the current session's window list and seed pane buffers."
  (ghostel-tmux--queue-command
   "list-windows -F \"#{window_id}\\t#{window_name}\\t#{window_layout}\""
   (lambda (output)
     (when output
       (ghostel-tmux--receive-window-rows output)))))

(defun ghostel-tmux--receive-window-rows (output)
  "Parse `list-windows' OUTPUT and create/update windows + panes.
Each row is `@WID<TAB>WINDOW-NAME<TAB>LAYOUT'.  Using TAB as the
delimiter (rather than space) lets us round-trip window names that
contain spaces — common with tmux's automatic-rename feature."
  (dolist (line (split-string output "\n" t))
    (when (string-match
           "\\`@\\([0-9]+\\)\t\\(.*\\)\t\\(.+\\)\\'" line)
      (let* ((wid (string-to-number (match-string 1 line)))
             (name (match-string 2 line))
             (layout (match-string 3 line)))
        (let ((existing (or (gethash wid ghostel-tmux--windows) nil)))
          (puthash wid (plist-put (or existing nil) :name name)
                   ghostel-tmux--windows))
        (unless (memq wid ghostel-tmux--window-order)
          (setq ghostel-tmux--window-order
                (append ghostel-tmux--window-order (list wid))))
        (ghostel-tmux--on-layout-change wid layout)))))

(defun ghostel-tmux--bootstrap-pane (controller pane-id)
  "Issue capture-pane on CONTROLLER to backfill PANE-ID's scrollback."
  (with-current-buffer controller
    (ghostel-tmux--queue-command
     (format "capture-pane -peJ -t %%%d -S -%d -E -1"
             pane-id ghostel-tmux-history-lines)
     (apply-partially #'ghostel-tmux--receive-pane-history
                      controller pane-id 'history))
    (ghostel-tmux--queue-command
     (format "capture-pane -peJ -t %%%d" pane-id)
     (apply-partially #'ghostel-tmux--receive-pane-history
                      controller pane-id 'visible))))

(defun ghostel-tmux--receive-pane-history (controller pane-id kind output)
  "Apply captured OUTPUT to PANE-ID's terminal under CONTROLLER.
KIND is `history' (scrollback) or `visible' (current screen).
OUTPUT is fed raw: unlike `%output' payloads, %begin/%end block
payloads are NOT octal-escaped by tmux, so a literal `\\033' in pane
content must stay four characters of text."
  (let ((buf (with-current-buffer controller
               (gethash pane-id ghostel-tmux--panes))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when output
          (let* (;; Captured output uses bare LF; the VT engine
                 ;; auto-normalizes to CRLF.
                 (data (if (eq kind 'history)
                           (concat output "\n")
                         output))
                 (ghostel-tmux--in-write-vt t))
            ;; save-current-buffer: native callbacks may select another
            ;; buffer mid-parse; the state updates below must land here.
            (save-current-buffer
              (ghostel--write-vt ghostel--term data))))
        (when (eq kind 'visible)
          (setq ghostel-tmux--initialized t
                ghostel-tmux--bootstrap-pending nil)
          (ghostel--invalidate))))))

(defun ghostel-tmux--wipe-panes ()
  "Drop all pane buffers and reset window state."
  (let ((controller (current-buffer)))
    (when ghostel-tmux--panes
      (maphash (lambda (pid _buf)
                 (ghostel-tmux--remove-pane controller pid))
               ghostel-tmux--panes))
    (clrhash ghostel-tmux--panes)
    (when ghostel-tmux--windows
      (clrhash ghostel-tmux--windows))
    (setq ghostel-tmux--window-order nil
          ghostel-tmux--active-pane-id nil
          ghostel-tmux--viewer-buffer nil)))


;; Outbound: route encoded keystrokes to tmux send-keys -H

(defun ghostel-tmux--bytes-to-hex (data)
  "Return DATA encoded as space-separated 2-digit hex tokens.
DATA may be multibyte (e.g. a UTF-8 paste from the kill ring); it is
encoded to its UTF-8 byte representation before hex-encoding."
  (let* ((unibytes (if (multibyte-string-p data)
                       (encode-coding-string data 'utf-8)
                     data)))
    (mapconcat (lambda (b) (format "%02x" b)) unibytes " ")))

(defconst ghostel-tmux--send-keys-chunk-bytes 512
  "Maximum number of source bytes per `send-keys -H' command.
The PTY between Emacs and the tmux controller has a finite line
buffer; large pastes must be split.  At 3 chars/byte plus the
`send-keys -t %%N -H ' header, 512 source bytes ≈ 1.6 KB per line,
well under the typical 4 KB line discipline limit.")

(defun ghostel-tmux--send-bytes-from-pane (controller pane-id data)
  "Send DATA bytes to tmux PANE-ID via CONTROLLER as `send-keys -H'.
Splits long DATA into multiple `send-keys' commands so a single line
never exceeds the controller PTY's input buffer (which would silently
truncate large pastes).  Each chunk goes through the command queue —
see the controller-output-channel commentary for why nothing may
bypass it.

Bytes generated as a side-effect of feeding `%output' (terminal
responses to OSC/DA/cursor queries) are dropped — see
`ghostel-tmux--in-write-vt' for why."
  (when (and data (> (length data) 0)
             (buffer-live-p controller)
             (not ghostel-tmux--in-write-vt))
    (let ((unibytes (if (multibyte-string-p data)
                        (encode-coding-string data 'utf-8)
                      data)))
      (with-current-buffer controller
        (when (ghostel-tmux--controller-live-p)
          (let ((i 0)
                (n (length unibytes))
                (chunk ghostel-tmux--send-keys-chunk-bytes))
            (while (< i n)
              (let* ((end (min n (+ i chunk)))
                     (slice (substring unibytes i end))
                     (hex (mapconcat (lambda (b) (format "%02x" b))
                                     slice " ")))
                (ghostel-tmux--queue-command
                 (format "send-keys -t %%%d -H %s" pane-id hex))
                (setq i end)))))))))


;; Process filter / sentinel

(defun ghostel-tmux--filter (proc string)
  "Process filter for the tmux -CC subprocess PROC; STRING is fresh output."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (ghostel-tmux--feed-bytes string)))))

(defun ghostel-tmux--sentinel (proc event)
  "Sentinel for the tmux -CC subprocess.  PROC ended with EVENT.
When the controller dies — whether cleanly or because tmux got killed
externally — seal each pane buffer so users' keystrokes don't silently
no-op against a dead process.  Panes are sealed even when the
controller buffer itself was killed before the process died."
  (unless (process-live-p proc)
    (let ((buf (process-buffer proc)))
      (ghostel-tmux--seal-panes buf)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (ghostel-tmux--refresh-tab-line)))
      (message "Ghostel-tmux: %s" (string-trim event)))))


;; Modes

(defun ghostel-tmux--cmd (command)
  "Run tmux command-mode COMMAND through the active controller.
Routed through `ghostel-tmux--queue-command' so a `%error' reply from
tmux is captured and surfaced to the user instead of being eaten by
whichever block happens to be in flight at the time."
  (let ((controller (or ghostel-tmux--controller-buffer
                        (and (derived-mode-p 'ghostel-tmux-control-mode)
                             (current-buffer)))))
    (unless (buffer-live-p controller)
      (user-error "Ghostel-tmux: No active controller"))
    (with-current-buffer controller
      (unless (ghostel-tmux--controller-live-p)
        (user-error "Ghostel-tmux: Controller is not connected"))
      (ghostel-tmux--queue-command
       command
       (lambda (output)
         (when (null output)
           ;; tmux replied with `%error' — surface to the user.
           (message "Ghostel-tmux: command failed: %s" command)))))))

(defun ghostel-tmux--prefix-target ()
  "Return a `-t' target spec for the current pane buffer's tmux pane."
  (when ghostel-tmux--pane-id
    (format "%%%d" ghostel-tmux--pane-id)))

(defun ghostel-tmux--session-target ()
  "Return `$SID' for the controller of the current pane buffer, or nil.
Used for `-t' on session/window-level commands (`next-window',
`new-window', …) where a pane target like `%3' is not accepted."
  (let ((controller ghostel-tmux--controller-buffer))
    (and (buffer-live-p controller)
         (with-current-buffer controller
           (and ghostel-tmux--session-id
                (format "$%d" ghostel-tmux--session-id))))))

(defun ghostel-tmux--window-target ()
  "Return `@WID' for the current pane's window, or nil."
  (when ghostel-tmux--window-id
    (format "@%d" ghostel-tmux--window-id)))

(defmacro ghostel-tmux--define-prefix-cmd (slug key tmux-cmd-fn doc)
  "Bind KEY in `ghostel-tmux-prefix-map' to a tmux command builder.
SLUG is appended to the generated function name.  TMUX-CMD-FN is
called with the pane target (e.g. \"%3\") and must return the tmux
command string to send.  DOC is the docstring."
  (let ((sym (intern (format "ghostel-tmux--prefix-%s" slug))))
    `(progn
       (defun ,sym ()
         ,doc
         (interactive)
         (ghostel-tmux--cmd
          (funcall ,tmux-cmd-fn (ghostel-tmux--prefix-target))))
       (define-key ghostel-tmux-prefix-map (kbd ,key) #',sym))))

(defvar ghostel-tmux-prefix-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap entered after the tmux prefix key.
The prefix key itself is `ghostel-tmux-prefix-key' (default `C-t').
Mirrors common tmux prefix bindings so that the muscle memory works
inside ghostel pane buffers.  The bindings are translated into tmux
control-mode commands sent over the active controller.")

(ghostel-tmux--define-prefix-cmd split-h "\""
  (lambda (target) (format "split-window -v -t %s" target))
  "Split the current pane horizontally (new pane below).")

(ghostel-tmux--define-prefix-cmd split-v "%"
  (lambda (target) (format "split-window -h -t %s" target))
  "Split the current pane vertically (new pane right).")

(ghostel-tmux--define-prefix-cmd new-window "c"
  (lambda (_target)
    (let ((sess (ghostel-tmux--session-target)))
      (if sess
          (format "new-window -t %s" sess)
        "new-window")))
  "Create a new tmux window.")

(ghostel-tmux--define-prefix-cmd kill-pane "x"
  (lambda (target) (format "kill-pane -t %s" target))
  "Kill the current pane.")

(ghostel-tmux--define-prefix-cmd kill-window "&"
  (lambda (_target)
    (let ((win (ghostel-tmux--window-target)))
      (if win
          (format "kill-window -t %s" win)
        "kill-window")))
  "Kill the current window.")

(defun ghostel-tmux--cycle-window (direction)
  "Ask tmux to make the next/previous window active.
DIRECTION is +1 (next) or -1 (previous).  The visible switch
happens reactively via `%window-pane-changed' → `--on-window-pane-changed'
once tmux acks the `select-window'."
  (let ((controller ghostel-tmux--controller-buffer)
        (cur-wid ghostel-tmux--window-id))
    (unless (and controller (buffer-live-p controller) cur-wid)
      (user-error "Ghostel-tmux: No controller/window context"))
    (let* ((order (with-current-buffer controller
                    ghostel-tmux--window-order))
           (idx (cl-position cur-wid order)))
      (when (and idx (> (length order) 1))
        (let ((next-wid (nth (mod (+ idx direction) (length order))
                             order)))
          (ghostel-tmux--cmd (format "select-window -t @%d" next-wid)))))))

(defun ghostel-tmux--prefix-next-window ()
  "Switch to the next tmux window and display its active pane."
  (interactive)
  (ghostel-tmux--cycle-window 1))
(define-key ghostel-tmux-prefix-map (kbd "n") #'ghostel-tmux--prefix-next-window)

(defun ghostel-tmux--prefix-prev-window ()
  "Switch to the previous tmux window and display its active pane."
  (interactive)
  (ghostel-tmux--cycle-window -1))
(define-key ghostel-tmux-prefix-map (kbd "p") #'ghostel-tmux--prefix-prev-window)

(ghostel-tmux--define-prefix-cmd next-pane "o"
  (lambda (_target) "select-pane -t :.+")
  "Cycle to the next pane in the current window.")

(ghostel-tmux--define-prefix-cmd rename-window ","
  (lambda (_target)
    (let ((name (read-string "rename window to: "))
          (win (ghostel-tmux--window-target)))
      (if win
          (format "rename-window -t %s %s" win
                  (shell-quote-argument name))
        (format "rename-window %s" (shell-quote-argument name)))))
  "Rename the current tmux window.")

(ghostel-tmux--define-prefix-cmd rename-session "$"
  (lambda (_target)
    (let ((name (read-string "rename session to: ")))
      (format "rename-session %s" (shell-quote-argument name))))
  "Rename the current tmux session.")

(ghostel-tmux--define-prefix-cmd zoom "z"
  (lambda (target) (format "resize-pane -Z -t %s" target))
  "Toggle zoom on the current pane.")

(ghostel-tmux--define-prefix-cmd cmd ":"
  (lambda (_target)
    (read-string "tmux command: "))
  "Prompt for an arbitrary tmux command and send it.")

;; Number keys: select tmux window N in the current session.  We pin
;; the target to `$SID:N' so multi-session controllers don't switch
;; the wrong session's window.
(dotimes (n 10)
  (let ((key (number-to-string n))
        (idx n))
    (define-key ghostel-tmux-prefix-map (kbd key)
      (let ((fn (intern (format "ghostel-tmux--prefix-window-%d" idx))))
        (defalias fn
          (lambda ()
            (interactive)
            (let* ((controller ghostel-tmux--controller-buffer)
                   (sid (and (buffer-live-p controller)
                             (with-current-buffer controller
                               ghostel-tmux--session-id))))
              (ghostel-tmux--cmd
               (if sid
                   (format "select-window -t $%d:%d" sid idx)
                 (format "select-window -t :%d" idx)))))
          (format "Switch to window %d in the current tmux session." idx))
        fn))))

;; `<prefix> d': detach (matches tmux's default).
(define-key ghostel-tmux-prefix-map (kbd "d") #'ghostel-tmux-detach)

;; `<prefix> ?': describe the prefix map.
(define-key ghostel-tmux-prefix-map (kbd "?")
            (lambda ()
              (interactive)
              (describe-keymap 'ghostel-tmux-prefix-map)))

(defun ghostel-tmux--prefix-self-insert ()
  "Send the tmux prefix key itself to the underlying program.
Bound under `ghostel-tmux-prefix-map' as `<prefix> <prefix>', matching
tmux's convention.  Only meaningful when `ghostel-tmux-prefix-key'
resolves to a single control byte (`C-<letter>')."
  (interactive)
  (let* ((seq (kbd ghostel-tmux-prefix-key))
         (byte (and (= (length seq) 1)
                    (let ((e (aref seq 0)))
                      (and (integerp e) (<= 0 e 31) e)))))
    (if byte
        (ghostel--send-string (string byte))
      (message "Ghostel-tmux: %S is not a control byte; cannot send raw"
               ghostel-tmux-prefix-key))))

(defvar ghostel-tmux-pane-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-n") #'ghostel-tmux-next-pane)
    (define-key map (kbd "C-c C-p") #'ghostel-tmux-prev-pane)
    (define-key map (kbd "C-c C-s") #'ghostel-tmux-switch-pane)
    (define-key map (kbd "C-c C-d") #'ghostel-tmux-detach)
    map)
  "Keymap for `ghostel-tmux-pane-mode'.
Sits above the local input-mode map via the standard minor-mode
dispatch, so the tmux prefix and `C-c' navigation compose with
ghostel's semi-char, line, and emacs-mode input maps without
replacing their bindings.  In char mode the emulation-alist
\(`ghostel-char-mode-map') sits above minor-mode keymaps, so the
prefix is intentionally inert and the underlying program receives
the keystroke raw.")

(defun ghostel-tmux--install-prefix-key (key)
  "Install KEY as the tmux prefix in `ghostel-tmux-pane-mode-map'.
Also binds `<prefix> <prefix>' in the prefix sub-map to send the
prefix byte raw to the underlying program."
  (define-key ghostel-tmux-pane-mode-map (kbd key) ghostel-tmux-prefix-map)
  (define-key ghostel-tmux-prefix-map (kbd key)
              #'ghostel-tmux--prefix-self-insert))

(ghostel-tmux--install-prefix-key ghostel-tmux-prefix-key)

(define-minor-mode ghostel-tmux-pane-mode
  "Minor mode making this ghostel buffer act as a tmux pane.
Activated when the controller materializes a pane buffer.  Composes
with the active ghostel input mode (semi-char, line, or
emacs-mode) — the tmux prefix and `C-c' navigation are added
without replacing the terminal's key bindings.  In char mode the
prefix is intentionally inert so a TUI program inside the pane
receives the keystroke raw."
  :lighter " Tmux"
  :keymap ghostel-tmux-pane-mode-map
  (cond
   (ghostel-tmux-pane-mode
    (setq tab-line-tabs-function #'ghostel-tmux--tab-line-tabs)
    (tab-line-mode 1)
    (add-hook 'kill-buffer-hook #'ghostel-tmux--pane-killed nil t)
    (add-hook 'window-size-change-functions
              #'ghostel-tmux--window-resized nil t)
    ;; tab-line click and any other plain `switch-to-buffer' path
    ;; won't go through `--display-pane-in-window'; this hook makes
    ;; sure the pane terminal is sized whenever its buffer becomes a
    ;; window's content.
    (add-hook 'window-buffer-change-functions
              #'ghostel-tmux--on-window-buffer-change nil t))
   (t
    (tab-line-mode -1)
    (remove-hook 'kill-buffer-hook #'ghostel-tmux--pane-killed t)
    (remove-hook 'window-size-change-functions
                 #'ghostel-tmux--window-resized t)
    (remove-hook 'window-buffer-change-functions
                 #'ghostel-tmux--on-window-buffer-change t))))

(defun ghostel-tmux--refresh-tab-line ()
  "Refresh `tab-line-mode' display in every pane buffer of this controller.
Called when the pane set changes (window-add, layout-change,
window-renamed, window-close, sentinel)."
  (when ghostel-tmux--panes
    (maphash (lambda (_pid buf)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (force-mode-line-update t))))
             ghostel-tmux--panes)))

(define-derived-mode ghostel-tmux-control-mode special-mode "Ghostel-tmux-ctl"
  "Hidden buffer hosting the tmux -CC subprocess."
  (buffer-disable-undo)
  (setq buffer-read-only t
        ghostel-tmux--panes (make-hash-table)
        ghostel-tmux--windows (make-hash-table))
  ;; Killing the hidden controller buffer must not leave a zombie
  ;; tmux -CC subprocess (its output would be dropped while pane
  ;; buffers still look live); the sentinel then seals the panes.
  (add-hook 'kill-buffer-hook #'ghostel-tmux--controller-killed nil t))

(defun ghostel-tmux--controller-killed ()
  "Tear down the tmux -CC subprocess when its controller buffer dies."
  (when (and ghostel-tmux--controller-process
             (process-live-p ghostel-tmux--controller-process))
    (delete-process ghostel-tmux--controller-process)))

(defun ghostel-tmux--pane-killed ()
  "When a pane buffer dies, evict it from the controller."
  (let ((controller ghostel-tmux--controller-buffer)
        (pid ghostel-tmux--pane-id))
    (when (and pid (buffer-live-p controller))
      (with-current-buffer controller
        (when ghostel-tmux--panes
          (remhash pid ghostel-tmux--panes))))))


;; Sizing

(defun ghostel-tmux--smallest-window-size (buf)
  "Return (COLS . ROWS) of the smallest live window showing BUF, or nil.
When the same pane buffer is displayed in multiple Emacs windows of
different sizes, we have to pick a single terminal grid; choose the
smallest so content fits everywhere instead of overflowing the smaller
window."
  (let (best-cols best-rows)
    (dolist (window (get-buffer-window-list buf nil t))
      (let ((c (window-max-chars-per-line window))
            (r (window-text-height window)))
        (when (and (integerp c) (integerp r) (> c 0) (> r 0))
          (when (or (null best-cols) (< c best-cols))
            (setq best-cols c))
          (when (or (null best-rows) (< r best-rows))
            (setq best-rows r)))))
    (when (and best-cols best-rows)
      (cons best-cols best-rows))))

(defun ghostel-tmux--window-resized (window)
  "Recompute pane size when WINDOW showing this pane buffer resizes.
Registered buffer-locally on `window-size-change-functions', which passes the
changed window and makes the buffer current.  Uses the smallest displaying
window's dimensions so the pane fits in every window showing it."
  (when (and (window-live-p window)
             ghostel-tmux--controller-buffer
             (buffer-live-p ghostel-tmux--controller-buffer))
    (let ((dims (ghostel-tmux--smallest-window-size (current-buffer))))
      (when dims
        (let ((cols (car dims))
              (rows (cdr dims)))
          (when (or (not (eql cols ghostel--term-cols))
                    (not (eql rows ghostel--term-rows)))
            (setq ghostel--term-cols cols
                  ghostel--term-rows rows)
            (when ghostel--term
              (ghostel--set-size-with-cell-dims ghostel--term rows cols))
            (with-current-buffer ghostel-tmux--controller-buffer
              (ghostel-tmux--queue-command
               (format "refresh-client -C %d,%d" cols rows)))))))))


;; Tab line

(defun ghostel-tmux--tab-line-tabs ()
  "Return tabs (sibling pane buffers) for `tab-line-mode' in this buffer."
  (when (buffer-live-p ghostel-tmux--controller-buffer)
    (ghostel-tmux--pane-list ghostel-tmux--controller-buffer)))


;; Public commands

(defun ghostel-tmux--read-session ()
  "Prompt for a tmux session name; returns the chosen name as a string.
tmux's stderr is discarded and a non-zero exit (typically: no server
running) is treated as no sessions, so error text is never mistaken
for a session name."
  (let* ((status nil)
         (output (with-output-to-string
                   (with-current-buffer standard-output
                     (setq status
                           (process-file ghostel-tmux-program nil
                                         (list t nil) nil
                                         "list-sessions" "-F"
                                         "#{session_name}")))))
         (sessions (and (eql status 0) (split-string output "\n" t)))
         (default (car sessions)))
    (cond
     ((null sessions)
      (user-error "Ghostel-tmux: No tmux sessions found"))
     ((= (length sessions) 1) (car sessions))
     (t (completing-read "tmux session: " sessions nil t nil nil default)))))

(defun ghostel-tmux--spawn-controller (session tmux-args)
  "Spawn a tmux -CC subprocess as a controller buffer.
SESSION is the user-visible session label.  TMUX-ARGS is the list
of arguments after \"tmux -CC\".  Returns the controller buffer."
  (let ((control-buf (generate-new-buffer
                      (format " *ghostel-tmux-control:%s*" session))))
    (with-current-buffer control-buf
      (ghostel-tmux-control-mode)
      (let* ((proc (make-process
                    :name (format "ghostel-tmux-%s" session)
                    :buffer control-buf
                    :command (cons ghostel-tmux-program (cons "-CC" tmux-args))
                    :coding 'binary
                    :connection-type 'pty
                    :noquery t
                    :filter #'ghostel-tmux--filter
                    :sentinel #'ghostel-tmux--sentinel)))
        (set-process-query-on-exit-flag proc nil)
        (setq ghostel-tmux--controller-process proc
              ghostel-tmux--session-name session)))
    control-buf))

(defun ghostel-tmux--apply-pane-size (pane-buf window)
  "Resize PANE-BUF's terminal to fit WINDOW and tell tmux about the size.
Splitting and tab-line switches both hit this path, so a pane that
was created at default geometry gets corrected the moment it becomes
visible in an Emacs window.  When tmux's window has more than one
pane, the active pane is also zoomed so it occupies the full client
size — without that, splitting (`C-b \"' / `C-b %%') leaves the user
looking at half a pane in a full-height Emacs window."
  (when (and (window-live-p window) (buffer-live-p pane-buf))
    (with-current-buffer pane-buf
      (let ((cols (window-max-chars-per-line window))
            (rows (window-text-height window))
            (pane-id ghostel-tmux--pane-id)
            (window-id ghostel-tmux--window-id)
            (controller ghostel-tmux--controller-buffer))
        (when (and (integerp cols) (integerp rows)
                   (> cols 0) (> rows 0))
          (when (or (not (eql cols ghostel--term-cols))
                    (not (eql rows ghostel--term-rows)))
            (setq ghostel--term-cols cols
                  ghostel--term-rows rows)
            (when ghostel--term
              (ghostel--set-size-with-cell-dims ghostel--term rows cols)))
          (when (buffer-live-p controller)
            (with-current-buffer controller
              (when (ghostel-tmux--controller-live-p)
                (ghostel-tmux--queue-command
                 (format "refresh-client -C %d,%d" cols rows))
                (ghostel-tmux--ensure-pane-zoomed window-id pane-id)))))))))

(defun ghostel-tmux--ensure-pane-zoomed (window-id pane-id)
  "Ask tmux to make PANE-ID active and zoomed in window WINDOW-ID.
Single-pane windows are skipped (zoom is a no-op there).  For
multi-pane windows we select the target pane, then via `if-shell -F'
zoom it only when the window isn't already zoomed — this avoids
toggling off an existing zoom when the same pane is already active
and zoomed.  Queued as two separate commands: tmux emits one reply
block per command, so a `;'-joined sequence on one line would produce
two blocks for a single queue entry and desync reply pairing."
  (when (and pane-id window-id
             (ghostel-tmux--controller-live-p))
    (let ((win (gethash window-id ghostel-tmux--windows)))
      (when (and win (> (length (plist-get win :panes)) 1))
        (ghostel-tmux--queue-command
         (format "select-pane -t %%%d" pane-id))
        (ghostel-tmux--queue-command
         (format
          "if-shell -F '#{!=:#{window_zoomed_flag},1}' 'resize-pane -Z -t %%%d'"
          pane-id))))))

(defun ghostel-tmux--display-pane-in-window (pane-buf window)
  "Display PANE-BUF in WINDOW and resize its terminal to fit."
  (when (and (window-live-p window) (buffer-live-p pane-buf))
    (with-selected-window window
      (switch-to-buffer pane-buf))
    (ghostel-tmux--apply-pane-size pane-buf window)))

(defun ghostel-tmux--on-window-buffer-change (window)
  "Resize the pane terminal when this buffer becomes WINDOW's content.
Hook for `window-buffer-change-functions': covers tab-line clicks and
any other path that swaps the buffer into a window without going
through `ghostel-tmux--display-pane-in-window'."
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer))
             (buffer-live-p ghostel-tmux--controller-buffer))
    (ghostel-tmux--apply-pane-size (current-buffer) window)))

(defun ghostel-tmux--wait-for-pane (control-buf timeout)
  "Block up to TIMEOUT seconds for CONTROL-BUF to materialize a pane.
Switches the selected window to the first pane buffer when one appears."
  (let ((target-window (selected-window))
        (deadline (+ (float-time) timeout)))
    (catch 'done
      (while (< (float-time) deadline)
        (let ((panes (ghostel-tmux--pane-list control-buf)))
          (when panes
            (ghostel-tmux--display-pane-in-window (car panes) target-window)
            (throw 'done t)))
        (accept-process-output
         (with-current-buffer control-buf
           ghostel-tmux--controller-process)
         0.1)))))

;;;###autoload
(defun ghostel-tmux-attach (session)
  "Attach to the tmux SESSION via control mode and materialize its panes."
  (interactive (list (ghostel-tmux--read-session)))
  (let ((buf (ghostel-tmux--spawn-controller
              session (list "attach-session" "-t" session))))
    (ghostel-tmux--wait-for-pane buf 5.0)))

;;;###autoload
(defun ghostel-tmux-new (session)
  "Create or attach to tmux SESSION via control mode.
Uses `tmux -CC new-session -As' which creates the session if it does
not exist, or attaches to an existing one with the same name."
  (interactive (list (read-string "tmux session name: " "main")))
  (let ((buf (ghostel-tmux--spawn-controller
              session (list "new-session" "-As" session))))
    (ghostel-tmux--wait-for-pane buf 5.0)))

;;;###autoload
(defun ghostel-tmux-detach ()
  "Detach the current tmux session.
Kills the dedicated control-mode subprocess; pane buffers remain
visible as read-only snapshots."
  (interactive)
  (let ((controller (or ghostel-tmux--controller-buffer
                        (and (derived-mode-p 'ghostel-tmux-control-mode)
                             (current-buffer)))))
    (unless (buffer-live-p controller)
      (user-error "Ghostel-tmux: No active controller for this buffer"))
    (with-current-buffer controller
      (when (ghostel-tmux--controller-live-p)
        (ghostel-tmux--queue-command "detach-client")
        ;; Give tmux a brief moment to acknowledge the detach (and, if
        ;; another command was in flight, for the queue to reach it) so
        ;; its reply isn't lost to the upcoming `delete-process'.
        (when (process-live-p ghostel-tmux--controller-process)
          (accept-process-output ghostel-tmux--controller-process 0.2)))
      (when ghostel-tmux--controller-process
        (delete-process ghostel-tmux--controller-process))
      (ghostel-tmux--seal-panes controller))))

;;;###autoload
(defun ghostel-tmux-next-pane ()
  "Switch to the next tmux pane in this session."
  (interactive)
  (ghostel-tmux--cycle-pane 1))

;;;###autoload
(defun ghostel-tmux-prev-pane ()
  "Switch to the previous tmux pane in this session."
  (interactive)
  (ghostel-tmux--cycle-pane -1))

(defun ghostel-tmux--cycle-pane (direction)
  "Ask tmux to make the next pane in DIRECTION (+1 or -1) active.
The visible switch happens reactively via `%window-pane-changed'."
  (let* ((controller ghostel-tmux--controller-buffer)
         (panes (and (buffer-live-p controller)
                     (ghostel-tmux--pane-list controller)))
         (here (current-buffer))
         (idx (cl-position here panes :test #'eq))
         (target (cond
                  ((null panes)
                   (user-error "Ghostel-tmux: No sibling panes"))
                  ((null idx) (car panes))
                  (t (nth (mod (+ idx direction) (length panes)) panes))))
         (pid (with-current-buffer target ghostel-tmux--pane-id)))
    (when (and controller (buffer-live-p controller) pid)
      (ghostel-tmux--cmd (format "select-pane -t %%%d" pid)))))

;;;###autoload
(defun ghostel-tmux-switch-pane ()
  "Switch to a sibling pane via `completing-read'.
Sends `select-pane' to tmux; the visible switch arrives via
`%window-pane-changed'."
  (interactive)
  (let* ((controller ghostel-tmux--controller-buffer)
         (panes (and (buffer-live-p controller)
                     (ghostel-tmux--pane-list controller)))
         (choices (mapcar (lambda (b) (cons (buffer-name b) b)) panes))
         (pick (completing-read "Pane: " choices nil t))
         (pid (with-current-buffer (cdr (assoc pick choices))
                ghostel-tmux--pane-id)))
    (when (and controller (buffer-live-p controller) pid)
      (ghostel-tmux--cmd (format "select-pane -t %%%d" pid)))))


;; One-shot snapshot of a single pane (no live connection)

;;;###autoload
(defun ghostel-tmux-capture (target)
  "Capture TARGET pane (e.g. \"session:window.pane\") into a fresh ghostel buffer.
The buffer renders the captured bytes through a VT engine but is not
connected to a live tmux session."
  (interactive
   (list (read-string "tmux target (e.g. mysession:0.0 or %3): "
                      (or (and (boundp 'ghostel-tmux--pane-id)
                               ghostel-tmux--pane-id
                               (format "%%%d" ghostel-tmux--pane-id))
                          ""))))
  (let* ((status nil)
         (output
          (with-output-to-string
            (with-current-buffer standard-output
              (setq status
                    (process-file ghostel-tmux-program nil
                                  (list t nil) nil
                                  "capture-pane" "-peJ"
                                  "-S" (number-to-string
                                        (- ghostel-tmux-history-lines))
                                  "-t" target))))))
    (unless (eql status 0)
      (user-error "Ghostel-tmux: capture-pane failed for %s" target))
    (when (string-empty-p output)
      (user-error "Ghostel-tmux: Empty capture for %s" target))
    (let ((buf (generate-new-buffer
                (format "*ghostel-tmux-capture:%s*" target))))
      (ghostel--init-buffer buf ghostel-tmux-default-rows
                            ghostel-tmux-default-cols)
      (with-current-buffer buf
        (ghostel-tmux-pane-mode 1)
        (setq ghostel--term-rows ghostel-tmux-default-rows
              ghostel--term-cols ghostel-tmux-default-cols
              ;; Swallow query replies (OSC/DA) — there is no live pane
              ;; to answer to.
              ghostel--pty-out-function #'ignore)
        (ghostel--write-vt ghostel--term output)
        (setq ghostel-tmux--initialized t)
        (ghostel--invalidate))
      (pop-to-buffer buf))))

(provide 'ghostel-tmux)

;;; ghostel-tmux.el ends here
