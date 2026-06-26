;;; ghostel-debug.el --- Diagnostic logging for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Diagnostic logging for ghostel.  Use `ghostel-debug-start' to begin
;; logging filter calls, key sends, and encoded key events to the
;; *ghostel-debug* buffer.  Use `ghostel-debug-stop' to stop.

;;; Code:

(require 'cl-lib)
(require 'lisp-mnt)
(require 'ghostel)

(declare-function ghostel--alt-screen-p "ghostel-module")
(declare-function ghostel--mode-enabled "ghostel-module")
(declare-function ghostel--module-version "ghostel-module")
(declare-function ghostel--encode-key "ghostel-module")
(declare-function ghostel--new "ghostel-module")
(declare-function ghostel--raw-key-sequence "ghostel")
(declare-function ghostel--cursor-row-text "ghostel")
(declare-function ghostel--remote-shell-p "ghostel")
(declare-function ghostel--password-prompt-detected-p "ghostel")
(defvar ghostel--password-mode-p)

;; Forward declarations for TRAMP symbols read by `ghostel-debug-info'
;; that don't exist on every supported Emacs.  The actual reads are
;; guarded with `boundp'/`fboundp' at runtime; these `defvar's just
;; quiet the byte-compiler on Emacs 28/29 where TRAMP doesn't ship
;; them.  Bare `defvar' without a value is a forward declaration only
;; — it doesn't override TRAMP's real definition when present.
(defvar tramp-direct-async-process)

(defvar ghostel-debug--log-buffer nil
  "Buffer used for ghostel debug logging.")

(defvar-local ghostel-debug--spawn-capture nil
  "Spawn-time diagnostics for this ghostel buffer, or nil.
Populated by `ghostel-debug-ghostel'.  A plist with:
  :time, :default-directory, :remote-p
  :start-process-time — when `ghostel--start-process' was entered
                        (just before any TRAMP shell-detection round-trip)
  :program, :program-args, :cols, :rows, :extra-env
  :command          — the wrapper command ghostel passed to
                      `make-process' (the ((\"/bin/sh\" \"-c\" \"<wrapper>\"))
                      list).  Captured via `cl-letf*' on `make-process'
                      so it survives TRAMP's non-direct-async rewriting.
  :executed-command — what `process-command' returns on the resulting
                      process.  Equals :command on local + direct-async
                      spawns; differs (e.g. `(\"/bin/sh\" \"-i\")') on
                      TRAMP's legacy async path, which dispatches the
                      real wrapper via the connection shell and uses
                      a local bridge process for stdio.
  :process-environment — copy taken just before `make-process'
  :filter-events    — list of (TIMESTAMP . CHUNK) PTY-output events,
                      chronological, capped at `:filter-cap' total bytes
  :filter-cap       — soft cap (total bytes) for :filter-events
  :filter-bytes     — running total of bytes appended to :filter-events
  :filter-truncated — non-nil once cap reached and chunks dropped
  :send-keys        — list of (TIMESTAMP . STRING) sends, capped at `:send-cap'
  :send-cap         — soft cap (count) for :send-keys
  :send-truncated   — non-nil if more sends arrived after the cap
Read by `ghostel-debug-info'.  Filter events and sends share a
single chronological timeline in the report so `sent X, received
no echo for Ns' is visible at a glance.  Phase timestamps
\(`:start-process-time' → `:time' → first :filter-events entry)
isolate where time goes per spawn — elisp prep vs TRAMP/ssh
handshake vs remote shell startup.")

(defvar-local ghostel-debug--pending-start-process-time nil
  "Buffer-local stash for `ghostel--start-process' entry time.
Set by `ghostel-debug--capture-start-process' (around-advice) and
read by `ghostel-debug--capture-spawn-pty' when it builds the
spawn-capture plist.  Cleared once consumed.")

(defconst ghostel-debug--filter-cap (* 16 1024)
  "Soft cap (total bytes) on `ghostel-debug--spawn-capture' :filter-events.
Sized to comfortably cover an initial prompt plus a handful of
input/echo round-trips so post-spawn behavior (not just the prompt)
is visible in the timeline.")

(defconst ghostel-debug--send-cap 64
  "Soft cap (entries) on `ghostel-debug--spawn-capture' :send-keys.")

(defconst ghostel-debug--password-events-cap 32
  "Maximum number of password-detection rising-edge events kept in memory.
Older entries are dropped FIFO when the ring is full.")

(defvar ghostel-debug--password-events nil
  "Ring of recent password-prompt rising edges across all ghostel buffers.
Each entry is a plist:
  :time          (current-time)
  :buffer        ghostel buffer (may have been killed)
  :buffer-name   string snapshot
  :source        symbol — `zig', `regex-remote', `regex-unknown', or
                 nil if the underlying signal vanished by the time the
                 advice re-probed (still useful: indicates a transient)
  :cursor        (COL . ROW) at the moment of the fire, or nil
  :row-text      cursor row text, or nil
  :tty           value of `process-tty-name', or nil
  :default-dir   `default-directory' at fire time
  :remote-p      `ghostel--remote-shell-p' result

Populated by `ghostel-debug--log-password-edge', which is added as
:around advice on `ghostel--detect-password-prompt' by
`ghostel-debug-start' and removed by `ghostel-debug-stop'.  Inspect
with `ghostel-debug-password-events-show'.")

(defun ghostel-debug--log-password-edge (orig &rest args)
  "Around-advice on `ghostel--detect-password-prompt' that records rising edges.
Called only while `ghostel-debug-start' has installed it.  Wraps ORIG
\(the unadvised `ghostel--detect-password-prompt') with ARGS, observes
the `ghostel--password-mode-p' transition from nil to t, and on a fresh
rising edge pushes a snapshot onto `ghostel-debug--password-events'.

The source attribution (`zig' / `regex-remote' / `regex-unknown') is
recovered by re-running the probe after the call.  Termios may have
changed in the microseconds between the original detection and the
re-probe, so a nil source on a logged event means the rising edge
fired but the underlying signal vanished by the time we looked again
\(itself a useful clue when investigating spurious fires)."
  (let ((was-on ghostel--password-mode-p))
    (apply orig args)
    (when (and (not was-on) ghostel--password-mode-p)
      (let ((event (list :time (current-time)
                         :buffer (current-buffer)
                         :buffer-name (buffer-name)
                         :source (ghostel--password-prompt-detected-p)
                         :cursor ghostel--cursor-pos
                         :row-text (ghostel--cursor-row-text)
                         :tty (and ghostel--process
                                   (process-tty-name ghostel--process))
                         :default-dir default-directory
                         :remote-p (ghostel--remote-shell-p))))
        (push event ghostel-debug--password-events)
        (when (> (length ghostel-debug--password-events)
                 ghostel-debug--password-events-cap)
          (setq ghostel-debug--password-events
                (cl-subseq ghostel-debug--password-events
                           0 ghostel-debug--password-events-cap)))))))

;;;###autoload
(defun ghostel-debug-password-events-show ()
  "Display recent password-prompt rising edges.
Shows which detection arm fired, the cursor row text at the time,
and whether the buffer was in a remote shell.  Use this to diagnose
spurious `read-passwd' prompts."
  (interactive)
  (let ((out (get-buffer-create "*ghostel-debug-password*")))
    (with-current-buffer out
      (let ((inhibit-read-only t))
        (fundamental-mode)
        (erase-buffer)
        (insert "=== Recent password-prompt rising edges ===\n")
        (insert (format "(most recent first; cap = %d)\n\n"
                        ghostel-debug--password-events-cap))
        (if (null ghostel-debug--password-events)
            (insert "No events captured yet.\n")
          (dolist (ev ghostel-debug--password-events)
            (insert (format "[%s] buffer=%S source=%s\n"
                            (format-time-string "%F %T.%3N"
                                                (plist-get ev :time))
                            (plist-get ev :buffer-name)
                            (plist-get ev :source)))
            (insert (format "  cursor=%S  remote-p=%s  tty=%S\n"
                            (plist-get ev :cursor)
                            (if (plist-get ev :remote-p) "yes" "no")
                            (plist-get ev :tty)))
            (insert (format "  default-directory=%S\n"
                            (plist-get ev :default-dir)))
            (insert (format "  row-text=%S\n\n"
                            (plist-get ev :row-text)))))
        (goto-char (point-min)))
      (special-mode))
    (display-buffer out)
    (message "Password-event log in *ghostel-debug-password*")))

;;;###autoload
(defun ghostel-debug-start ()
  "Start logging ghostel events to *ghostel-debug* buffer.
Logs filter calls, key sends, resize events, redraw decisions
\(including DEC 2026 skip/force), and window scroll state."
  (interactive)
  (setq ghostel-debug--log-buffer (get-buffer-create "*ghostel-debug*"))
  (with-current-buffer ghostel-debug--log-buffer
    ;; `ghostel-debug-info' leaves the buffer in `special-mode' (read-only).
    ;; Reset to a writable state so logging advice can append freely.
    (fundamental-mode)
    (setq buffer-read-only nil)
    (erase-buffer)
    (insert "=== Ghostel Debug Log ===\n\n"))
  ;; Data path
  (advice-add 'ghostel--filter :before #'ghostel-debug--log-filter)
  (advice-add 'ghostel--send-string :before #'ghostel-debug--log-send)
  (advice-add 'ghostel--send-encoded :before #'ghostel-debug--log-encoded)
  ;; Render path
  (advice-add 'ghostel--redraw-now :around #'ghostel-debug--log-redraw)
  (advice-add 'ghostel--adjust-size :around #'ghostel-debug--log-resize)
  ;; Password-prompt rising edges (events stored in
  ;; `ghostel-debug--password-events', viewable via
  ;; `ghostel-debug-password-events-show').
  (advice-add 'ghostel--detect-password-prompt :around
              #'ghostel-debug--log-password-edge)
  (when (fboundp 'ghostel--enable-vt-log)
    (ghostel--enable-vt-log))
  (message "ghostel-debug: logging started, check *ghostel-debug* buffer"))

(defun ghostel-debug-stop ()
  "Stop logging."
  (interactive)
  (advice-remove 'ghostel--filter #'ghostel-debug--log-filter)
  (advice-remove 'ghostel--send-string #'ghostel-debug--log-send)
  (advice-remove 'ghostel--send-encoded #'ghostel-debug--log-encoded)
  (advice-remove 'ghostel--redraw-now #'ghostel-debug--log-redraw)
  (advice-remove 'ghostel--adjust-size #'ghostel-debug--log-resize)
  (advice-remove 'ghostel--detect-password-prompt
                 #'ghostel-debug--log-password-edge)
  (when (fboundp 'ghostel--disable-vt-log)
    (ghostel--disable-vt-log))
  ;; Logging is done — flip the buffer to read-only so the captured log
  ;; can't be edited by accident.  `ghostel-debug-start' resets the mode
  ;; before erasing.
  (when (buffer-live-p ghostel-debug--log-buffer)
    (with-current-buffer ghostel-debug--log-buffer
      (special-mode)))
  (message "ghostel-debug: logging stopped"))

(defun ghostel--debug-log-vt (level scope message)
  "Log a libghostty-vt internal message.
LEVEL is the severity (error/warning/info/debug).
SCOPE is the subsystem name.  MESSAGE is the log text.
Called from the native module's log callback."
  (when ghostel-debug--log-buffer
    (with-current-buffer ghostel-debug--log-buffer
      (goto-char (point-max))
      (insert (format "[%s] VT [%s](%s): %s\n"
                      (format-time-string "%T.%3N")
                      level scope message)))))

(defun ghostel-debug--log-filter (_proc output)
  "Log process filter call with OUTPUT length and preview.
_PROC is ignored."
  (when ghostel-debug--log-buffer
    (with-current-buffer ghostel-debug--log-buffer
      (goto-char (point-max))
      (insert (format "[%s] FILTER: %d bytes: %S\n"
                      (format-time-string "%T.%3N")
                      (length output)
                      (if (> (length output) 80)
                          (concat (substring output 0 80) "...")
                        output))))))

(defun ghostel-debug--log-send (key)
  "Log KEY sent to terminal."
  (when ghostel-debug--log-buffer
    (with-current-buffer ghostel-debug--log-buffer
      (goto-char (point-max))
      (insert (format "[%s] SEND-KEY: %S (bytes: %S)\n"
                      (format-time-string "%T.%3N")
                      key
                      (mapcar #'identity key))))))

(defun ghostel-debug--log-encoded (key-name mods &optional utf8)
  "Log encoded key event with KEY-NAME, MODS and optional UTF8."
  (when ghostel-debug--log-buffer
    (with-current-buffer ghostel-debug--log-buffer
      (goto-char (point-max))
      (insert (format "[%s] SEND-ENCODED: key=%S mods=%S utf8=%S\n"
                      (format-time-string "%T.%3N")
                      key-name mods utf8)))))

(defun ghostel-debug--snapshot (buffer)
  "Return a plist of redraw-relevant state for BUFFER, or nil.
Captures DEC 2026, force flag, buffer size, cursor positions,
computed viewport-start, and per-window ws/we/wp/body-height."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((pm (point-max))
             (cb (and (> pm 1) (char-before pm)))
             (wins (get-buffer-window-list buffer nil t)))
        (list :sync (and ghostel--term
                         (ghostel--mode-enabled ghostel--term 2026))
              :force ghostel--force-next-redraw
              :buf-size (buffer-size)
              :trailing-nl (eq cb ?\n)
              :point (point)
              :cursor ghostel--cursor-pos
              :cursor-char ghostel--cursor-char-pos
              :term-rows ghostel--term-rows
              :vs (ghostel--viewport-start)
              :wins (mapcar (lambda (w)
                              (list :w w
                                    :ws (window-start w)
                                    :we (window-end w t)
                                    :wp (window-point w)
                                    :body (window-body-height w)))
                            wins))))))

(defun ghostel-debug--fmt-wins (wins)
  "Format per-window entries WINS for the redraw log line."
  (mapconcat
   (lambda (w) (format "ws=%d we=%d wp=%d body=%d"
                       (plist-get w :ws) (plist-get w :we)
                       (plist-get w :wp) (plist-get w :body)))
   wins " | "))

(defun ghostel-debug--log-redraw (orig-fn buffer &optional force)
  "Log redraw decisions: skip vs execute, DEC 2026 state, timing.
ORIG-FN is `ghostel--redraw-now', BUFFER is the target buffer, FORCE is
its optional force-past-synchronized-output argument (forwarded)."
  (when ghostel-debug--log-buffer
    (let* ((before (ghostel-debug--snapshot buffer))
           ;; `force' set via the snapshotted buffer-local flag OR passed as
           ;; an argument both bypass the DEC 2026 skip in `ghostel--redraw-now'.
           (force-in (or (plist-get before :force) force))
           (t0 (current-time)))
      (funcall orig-fn buffer force)
      (let* ((elapsed (* 1000 (float-time (time-subtract (current-time) t0))))
             (after (ghostel-debug--snapshot buffer)))
        (with-current-buffer ghostel-debug--log-buffer
          (goto-char (point-max))
          (if (and (plist-get before :sync) (not force-in))
              (insert (format "[%s] REDRAW: SKIPPED (DEC2026 active, force=nil)\n"
                              (format-time-string "%T.%3N")))
            (insert (format "[%s] REDRAW: %.1fms force=%s→%s dec2026=%s buf=%d→%d trailNL=%s→%s pt=%d→%d cursor=%S→%S cursor-char=%S→%S rows=%s vs=%s→%s\n"
                            (format-time-string "%T.%3N")
                            elapsed
                            force-in (plist-get after :force)
                            (plist-get before :sync)
                            (plist-get before :buf-size) (plist-get after :buf-size)
                            (plist-get before :trailing-nl) (plist-get after :trailing-nl)
                            (plist-get before :point) (plist-get after :point)
                            (plist-get before :cursor) (plist-get after :cursor)
                            (plist-get before :cursor-char) (plist-get after :cursor-char)
                            (plist-get after :term-rows)
                            (plist-get before :vs) (plist-get after :vs)))
            (insert (format "           wins-before: %s\n"
                            (ghostel-debug--fmt-wins (plist-get before :wins))))
            (insert (format "           wins-after:  %s\n"
                            (ghostel-debug--fmt-wins (plist-get after :wins))))))))))

(defun ghostel-debug--log-resize (orig-fn window &optional force)
  "Log resize events with old/new dimensions and timing.
ORIG-FN is `ghostel--adjust-size'.  WINDOW and its optional FORCE
argument are passed through."
  (let* ((buffer (and (window-live-p window) (window-buffer window)))
         (old-rows (and (buffer-live-p buffer)
                        (buffer-local-value 'ghostel--term-rows buffer)))
         (old-cols (and (buffer-live-p buffer)
                        (buffer-local-value 'ghostel--term-cols buffer)))
         (t0 (current-time))
         (result (funcall orig-fn window force))
         (elapsed (* 1000 (float-time (time-subtract (current-time) t0))))
         (new-rows (and (buffer-live-p buffer)
                        (buffer-local-value 'ghostel--term-rows buffer)))
         (new-cols (and (buffer-live-p buffer)
                        (buffer-local-value 'ghostel--term-cols buffer))))
    (when ghostel-debug--log-buffer
      (with-current-buffer ghostel-debug--log-buffer
        (goto-char (point-max))
        (insert (format "[%s] RESIZE: %sx%s → %sx%s (%.1fms)\n"
                        (format-time-string "%T.%3N")
                        old-cols old-rows
                        new-cols new-rows
                        elapsed))))
    result))


;;; Typing latency measurement

(defvar ghostel-debug--latency-log nil
  "List of (SEND-TIME ECHO-TIME RENDER-TIME) entries for latency analysis.")

(defvar ghostel-debug--latency-send-time nil
  "High-resolution time of the last send-key during latency measurement.")

(defvar ghostel-debug--latency-active nil
  "Non-nil when typing latency measurement is active.")

(defun ghostel-debug-typing-latency (&optional count)
  "Measure per-keystroke typing latency.
Instruments the send→echo→render pipeline with high-resolution
timestamps and logs a summary after COUNT keystrokes (default 20).
Call this interactively in a ghostel buffer, then type normally.
Results are displayed in *ghostel-debug* when complete.

The latency breakdown shows:
- PTY latency: time from send-key to process filter receiving echo
- Render latency: time from echo receipt to redraw completion
- Total latency: end-to-end from keystroke to visible update"
  (interactive "p")
  (unless (derived-mode-p 'ghostel-mode)
    (user-error "Must be called from a ghostel buffer"))
  (let ((n (or count 20)))
    (setq ghostel-debug--latency-log nil)
    (setq ghostel-debug--latency-active n)
    (setq ghostel-debug--log-buffer (get-buffer-create "*ghostel-debug*"))
    (with-current-buffer ghostel-debug--log-buffer
      ;; Reset `special-mode' (set by `ghostel-debug-info') so subsequent
      ;; latency log inserts don't trip `buffer-read-only'.
      (fundamental-mode)
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert "=== Ghostel Typing Latency Measurement ===\n")
      (insert (format "Type %d characters to collect measurements...\n\n" n)))
    (advice-add 'ghostel--send-string :before #'ghostel-debug--latency-on-send)
    (advice-add 'ghostel--filter :before #'ghostel-debug--latency-on-echo)
    (advice-add 'ghostel--redraw-now :after #'ghostel-debug--latency-on-render)
    (message "ghostel-debug: type %d characters to measure latency" n)))

(defun ghostel-debug--latency-on-send (_key)
  "Record send time for latency measurement."
  (when ghostel-debug--latency-active
    (setq ghostel-debug--latency-send-time (current-time))))

(defun ghostel-debug--latency-on-echo (_proc _output)
  "Record echo-receipt time for latency measurement."
  (when (and ghostel-debug--latency-active ghostel-debug--latency-send-time)
    ;; Store echo time on the send-time entry (will be completed on render)
    (let ((echo-time (current-time)))
      ;; Push partial entry: (send-time echo-time nil)
      (push (list ghostel-debug--latency-send-time echo-time nil)
            ghostel-debug--latency-log)
      (setq ghostel-debug--latency-send-time nil))))

(defun ghostel-debug--latency-on-render (_buffer &rest _)
  "Record render-completion time and finalize latency entry.
Ignores `ghostel--redraw-now's optional force argument."
  (when ghostel-debug--latency-active
    (let ((render-time (current-time)))
      ;; Complete the most recent entry that has no render time
      (catch 'done
        (dolist (entry ghostel-debug--latency-log)
          (when (and (nth 1 entry) (null (nth 2 entry)))
            (setf (nth 2 entry) render-time)
            (cl-decf ghostel-debug--latency-active)
            (when (<= ghostel-debug--latency-active 0)
              (ghostel-debug--latency-report))
            (throw 'done nil)))))))

(defun ghostel-debug--latency-report ()
  "Generate and display the latency report."
  (advice-remove 'ghostel--send-string #'ghostel-debug--latency-on-send)
  (advice-remove 'ghostel--filter #'ghostel-debug--latency-on-echo)
  (advice-remove 'ghostel--redraw-now #'ghostel-debug--latency-on-render)
  (setq ghostel-debug--latency-active nil)
  (let* ((complete (cl-remove-if-not (lambda (e) (nth 2 e))
                                     ghostel-debug--latency-log))
         (pty-times (mapcar (lambda (e)
                              (* 1000 (float-time
                                       (time-subtract (nth 1 e) (nth 0 e)))))
                            complete))
         (render-times (mapcar (lambda (e)
                                 (* 1000 (float-time
                                          (time-subtract (nth 2 e) (nth 1 e)))))
                               complete))
         (total-times (mapcar (lambda (e)
                                (* 1000 (float-time
                                         (time-subtract (nth 2 e) (nth 0 e)))))
                              complete)))
    (when ghostel-debug--log-buffer
      (with-current-buffer ghostel-debug--log-buffer
        (goto-char (point-max))
        (insert (format "\n=== Results (%d samples) ===\n\n" (length complete)))
        (insert (format "%-20s %8s %8s %8s %8s\n"
                        "Phase" "Min" "Median" "P99" "Max"))
        (insert (make-string 56 ?-) "\n")
        (dolist (row `(("PTY latency" ,pty-times)
                       ("Render latency" ,render-times)
                       ("Total (end-to-end)" ,total-times)))
          (let* ((name (car row))
                 (vals (sort (cadr row) #'<))
                 (n (length vals)))
            (when (> n 0)
              (insert (format "%-20s %7.2fms %7.2fms %7.2fms %7.2fms\n"
                              name
                              (car vals)
                              (nth (/ n 2) vals)
                              (nth (min (1- n) (floor (* n 0.99))) vals)
                              (car (last vals)))))))
        (insert "\nPer-keystroke detail:\n")
        (dolist (e (reverse complete))
          (let ((pty (float-time (time-subtract (nth 1 e) (nth 0 e))))
                (rnd (float-time (time-subtract (nth 2 e) (nth 1 e))))
                (tot (float-time (time-subtract (nth 2 e) (nth 0 e)))))
            (insert (format "  pty=%.2fms render=%.2fms total=%.2fms\n"
                            (* 1000 pty) (* 1000 rnd) (* 1000 tot)))))
        (insert "\n")
        ;; Measurement is done — flip to read-only.
        (special-mode)))
    (message "ghostel-debug: latency report ready in *ghostel-debug*")))


;;; Glyph diagnostics

(defconst ghostel-debug--font-info-fields
  '((0 . "Name")
    (1 . "Filename")
    (2 . "Pixel size")
    (3 . "Size")
    (4 . "Ascent")
    (5 . "Descent")
    (6 . "Space width")
    (7 . "Average width")
    (8 . "Capability"))
  "Labels for the vector returned by `query-font'.")

(defconst ghostel-debug--glyph-fields
  '((0 . "From index")
    (1 . "To index")
    (2 . "Character")
    (3 . "Code")
    (4 . "Width")
    (5 . "Left bearing")
    (6 . "Right bearing")
    (7 . "Ascent")
    (8 . "Descent")
    (9 . "Adjustment"))
  "Labels for glyph vectors in a shaped glyph string.")

(defun ghostel-debug--vref (vector index)
  "Return VECTOR's element at INDEX, or nil when absent."
  (and (vectorp vector)
       (< index (length vector))
       (aref vector index)))

(defun ghostel-debug--prin1 (value)
  "Return VALUE formatted for diagnostic output."
  (let ((print-length nil)
        (print-level nil)
        (print-circle t))
    (prin1-to-string value)))

(defun ghostel-debug--insert-field (label value)
  "Insert diagnostic field LABEL with VALUE."
  (insert (format "%-20s %s\n" (concat label ":")
                  (ghostel-debug--prin1 value))))

(defun ghostel-debug--char-summary (char)
  "Return a compact description of CHAR."
  (if char
      (format "%S  U+%04X  width=%d column%s"
              (char-to-string char)
              char
              (char-width char)
              (if (= (char-width char) 1) "" "s"))
    "nil"))

(defun ghostel-debug--find-gstring (pos end window)
  "Return glyph-string information for text from POS to END in WINDOW.
The return value is a plist with :source, :gstring, :font, and
:composition keys, or :error when shaping failed before a glyph string
could be produced.  This mirrors the renderer's lookup order:
composition glyph string first, otherwise `font-at' +
`composition-get-gstring' + `font-shape-gstring'."
  (condition-case err
      (let* ((composition (find-composition pos end nil t))
             (composition-gstring (and composition (nth 2 composition))))
        (if (and composition-gstring (not (eq composition-gstring nil)))
            (let* ((header (ghostel-debug--vref composition-gstring 0))
                   (font (ghostel-debug--vref header 0)))
              (list :source 'composition
                    :gstring composition-gstring
                    :font font
                    :composition composition))
          (let ((font (font-at pos window)))
            (cond
             ((null font)
              (list :composition composition
                    :error "font-at returned nil"))
             (t
              (let* ((raw (composition-get-gstring pos end font nil))
                     (shaped (and raw (font-shape-gstring raw nil))))
                (if shaped
                    (list :source 'font-shape-gstring
                          :gstring shaped
                          :font font
                          :composition composition
                          :raw-gstring raw)
                  (list :font font
                        :composition composition
                        :raw-gstring raw
                        :error "font-shape-gstring returned nil"))))))))
    (error (list :error (error-message-string err)))))

(defun ghostel-debug--insert-font-info (font font-info)
  "Insert diagnostic output for FONT and FONT-INFO."
  (insert "--- Font ---\n")
  (ghostel-debug--insert-field "Font object" font)
  (cond
   ((not (vectorp font-info))
    (ghostel-debug--insert-field "query-font" font-info))
   (t
    (dolist (field ghostel-debug--font-info-fields)
      (ghostel-debug--insert-field (cdr field)
                                   (ghostel-debug--vref font-info
                                                        (car field))))
    (let ((ascent (ghostel-debug--vref font-info 4))
          (descent (ghostel-debug--vref font-info 5)))
      (when (and (numberp ascent) (numberp descent))
        (ghostel-debug--insert-field "Total height" (+ ascent descent))))
    (ghostel-debug--insert-field "Raw query-font" font-info))))

(defun ghostel-debug--insert-renderer-metrics (font-info gstring)
  "Insert the native renderer metric subset from FONT-INFO and GSTRING."
  (let* ((first-glyph (and (vectorp gstring)
                           (> (length gstring) 2)
                           (aref gstring 2)))
         (pixel-size (ghostel-debug--vref font-info 2))
         (ascent (ghostel-debug--vref font-info 4))
         (descent (ghostel-debug--vref font-info 5))
         (width (ghostel-debug--vref first-glyph 4)))
    (insert "--- Renderer metrics ---\n")
    (ghostel-debug--insert-field "Pixel size" pixel-size)
    (ghostel-debug--insert-field "Ascent" ascent)
    (ghostel-debug--insert-field "Descent" descent)
    (when (and (numberp ascent) (numberp descent))
      (ghostel-debug--insert-field "Total height" (+ ascent descent)))
    (ghostel-debug--insert-field "Width" width)
    (ghostel-debug--insert-field "Sources"
                                 "query-font[2,4,5] + first glyph[4]")
    (insert "\n")))

(defun ghostel-debug--insert-glyph (index glyph)
  "Insert diagnostic output for glyph vector GLYPH at INDEX."
  (insert (format "Glyph %d%s\n" index (if (= index 0) " (gstring element 2)" "")))
  (cond
   ((not (vectorp glyph))
    (ghostel-debug--insert-field "Value" glyph))
   (t
    (dolist (field ghostel-debug--glyph-fields)
      (let ((value (ghostel-debug--vref glyph (car field))))
        (ghostel-debug--insert-field
         (cdr field)
         (if (and (= (car field) 2) (characterp value))
             (ghostel-debug--char-summary value)
           value))))
    (let ((ascent (ghostel-debug--vref glyph 7))
          (descent (ghostel-debug--vref glyph 8)))
      (when (and (numberp ascent) (numberp descent))
        (ghostel-debug--insert-field "Total height" (+ ascent descent))))
    (ghostel-debug--insert-field "Raw glyph" glyph)))
  (insert "\n"))

;;;###autoload
(defun ghostel-debug-glyph-at-point ()
  "Display text, font, and shaped glyph diagnostics for the char at point.
The report mirrors the glyph lookup used by the native renderer: it
shows text properties at point, `query-font' metrics for the selected
font, and the shaped glyph vector metrics for the glyph string Emacs
will render."
  (interactive)
  (let* ((pos (point))
         (char (char-after pos))
         (end (and char (1+ pos)))
         (window (selected-window)))
    (unless char
      (user-error "No character at point"))
    (let* ((source-buffer (buffer-name))
           (text-properties (text-properties-at pos))
           (ginfo (ghostel-debug--find-gstring pos end window))
           (font (plist-get ginfo :font))
           (font-info (condition-case err
                          (and font (query-font font))
                        (error (list :error (error-message-string err)))))
           (gstring (plist-get ginfo :gstring))
           (out (get-buffer-create "*ghostel-debug-glyph*")))
      (with-current-buffer out
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "=== ghostel-debug-glyph-at-point ===\n\n")
          (insert "--- Character ---\n")
          (ghostel-debug--insert-field "Buffer" source-buffer)
          (ghostel-debug--insert-field "Position" pos)
          (ghostel-debug--insert-field "Character" (ghostel-debug--char-summary char))
          (ghostel-debug--insert-field "Text properties" text-properties)
          (insert "\n")
          (ghostel-debug--insert-font-info font font-info)
          (insert "\n")
          (ghostel-debug--insert-renderer-metrics font-info gstring)
          (insert "--- Glyph string ---\n")
          (ghostel-debug--insert-field "Source" (plist-get ginfo :source))
          (ghostel-debug--insert-field "Range" (cons pos end))
          (ghostel-debug--insert-field "Composition"
                                       (plist-get ginfo :composition))
          (when (plist-get ginfo :error)
            (ghostel-debug--insert-field "Error" (plist-get ginfo :error)))
          (ghostel-debug--insert-field "Header"
                                       (and (vectorp gstring)
                                            (ghostel-debug--vref gstring 0)))
          (ghostel-debug--insert-field "ID"
                                       (and (vectorp gstring)
                                            (ghostel-debug--vref gstring 1)))
          (ghostel-debug--insert-field "Raw gstring" gstring)
          (insert "\n--- Glyphs ---\n")
          (if (not (vectorp gstring))
              (insert "(no glyph string)\n")
            (cl-loop for i from 2 below (length gstring)
                     for glyph = (aref gstring i)
                     do (ghostel-debug--insert-glyph (- i 2) glyph)))
          (goto-char (point-min)))
        (special-mode))
      (display-buffer out)
      (message "Wrote *ghostel-debug-glyph* — paste into the issue"))))

;;; Environment diagnostics

;;;###autoload
(defun ghostel-debug-info (&optional with-remote-probes)
  "Display diagnostic info about the ghostel environment.
Collects Emacs version, system info, native module state, frame and
window geometry, terminal state, process info, and any non-default
ghostel settings into *ghostel-debug* for pasting into bug reports.

In a ghostel buffer with a TRAMP `default-directory', also prints a
TRAMP section (version, `tramp-terminal-type', direct-async path,
local-vs-toplevel TERM stripping diagnostics).

When the buffer was started via \\[ghostel-debug-ghostel], also prints
the spawn capture (wrapper script, `process-environment' as sent,
first PTY output bytes, first keystrokes).

With prefix arg WITH-REMOTE-PROBES, runs live probes against the
remote (`infocmp', terminfo path checks, `/bin/sh' identity, login
shell) — adds latency and requires a healthy TRAMP connection, so
omit it when the connection itself is the suspected fault."
  (interactive "P")
  (let ((out (get-buffer-create "*ghostel-debug*"))
        (ghostel-buf (when (derived-mode-p 'ghostel-mode) (current-buffer))))
    (with-current-buffer out
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "=== ghostel-debug-info ===\n\n")
        ;; System
        (insert "--- System ---\n")
        (insert (format "Emacs version:       %s\n" emacs-version))
        (insert (format "System type:         %s\n" system-type))
        (insert (format "System config:       %s\n" system-configuration))
        (insert (format "Window system:       %s\n" (or window-system "terminal")))
        (when (display-graphic-p)
          (insert (format "Display pixel size:  %sx%s\n"
                          (display-pixel-width) (display-pixel-height)))
          (insert (format "Char size:           %dx%d px\n"
                          (frame-char-width) (frame-char-height))))
        (insert (format "Native comp:         %s\n"
                        (if (and (fboundp 'native-comp-available-p)
                                 (native-comp-available-p))
                            "yes" "no")))
        ;; Ghostel
        (insert "\n--- Ghostel ---\n")
        (let* ((lib (locate-library "ghostel"))
               (root (ghostel--resource-root)))
          (insert (format "Package version:     %s\n"
                          (condition-case nil
                              (lm-version (locate-library "ghostel.el" t))
                            (error "Unknown"))))
          (insert (format "Min module version:  %s\n" ghostel--minimum-module-version))
          (insert (format "Library path:        %s\n" (or lib "not found")))
          (insert (format "Resource root:       %s\n" (or root "not found")))
          (let ((mod-loaded (fboundp 'ghostel--module-version)))
            (insert (format "Module loaded:       %s\n" (if mod-loaded "yes" "no")))
            (when mod-loaded
              (let ((mod-ver (ghostel--module-version)))
                (insert (format "Module version:      %s\n" mod-ver))
                (unless (string= mod-ver ghostel--minimum-module-version)
                  (insert (format "  *** VERSION MISMATCH: elisp expects >= %s, module is %s ***\n"
                                  ghostel--minimum-module-version mod-ver)))))
            (when root
              (let ((mod-file (expand-file-name
                               (concat "ghostel-module" module-file-suffix) root)))
                (if (file-exists-p mod-file)
                    (let ((attrs (file-attributes mod-file)))
                      (insert (format "Module file:         %s\n" mod-file))
                      (insert (format "Module size:         %s bytes\n"
                                      (file-attribute-size attrs)))
                      (insert (format "Module modified:     %s\n"
                                      (format-time-string
                                       "%F %T"
                                       (file-attribute-modification-time attrs)))))
                  (insert (format "Module file:         NOT FOUND in %s\n" root)))))))
        ;; Frame
        (insert "\n--- Frame ---\n")
        (let ((frame (or (and ghostel-buf
                              (window-live-p (get-buffer-window ghostel-buf))
                              (window-frame (get-buffer-window ghostel-buf)))
                         (selected-frame))))
          (insert (format "Frame size:          %dx%d (cols x rows)\n"
                          (frame-width frame) (frame-height frame)))
          (when (display-graphic-p frame)
            (insert (format "Frame pixel size:    %dx%d\n"
                            (frame-pixel-width frame) (frame-pixel-height frame))))
          (insert (format "Tab-bar lines:       %s%s\n"
                          (or (frame-parameter frame 'tab-bar-lines) 0)
                          (if (bound-and-true-p tab-bar-mode) " (tab-bar-mode on)" "")))
          (insert (format "Tool-bar lines:      %s%s\n"
                          (or (frame-parameter frame 'tool-bar-lines) 0)
                          (if (bound-and-true-p tool-bar-mode) " (tool-bar-mode on)" "")))
          (insert (format "Menu-bar lines:      %s%s\n"
                          (or (frame-parameter frame 'menu-bar-lines) 0)
                          (if (bound-and-true-p menu-bar-mode) " (menu-bar-mode on)" "")))
          (insert (format "Internal border:     %s px\n"
                          (or (frame-parameter frame 'internal-border-width) 0)))
          (insert (format "Background mode:     %s\n"
                          (frame-parameter frame 'background-mode)))
          (insert (format "Enabled themes:      %s\n"
                          (or custom-enabled-themes "(none)"))))
        ;; Environment — what ghostel hands the spawned shell.  For LOCAL
        ;; spawns, vars from `ghostel--terminal-env' (TERM, COLORTERM,
        ;; optionally TERMINFO and TERM_PROGRAM) are pushed via
        ;; `process-environment'.  For REMOTE spawns, those four are NOT
        ;; pushed — the on-remote `/bin/sh -c' preamble (visible in
        ;; Process → Command) sets them after probing the remote for
        ;; `xterm-ghostty' terminfo.  In both cases INSIDE_EMACS and
        ;; `ghostel-environment' user overrides are propagated.  LANG/LC_*
        ;; are pass-through from Emacs.  The terminfo-warned binding
        ;; suppresses the missing-terminfo warning so viewing the
        ;; diagnostic isn't itself a side effect.
        (insert "\n--- Environment ---\n")
        (let ((remote-buf (and ghostel-buf
                               (buffer-local-value 'default-directory
                                                   ghostel-buf)
                               (file-remote-p
                                (buffer-local-value 'default-directory
                                                    ghostel-buf)))))
          (cond
           (remote-buf
            (insert "Spawn env (set by ghostel, remote spawn):\n")
            (insert "  INSIDE_EMACS=ghostel\n")
            (dolist (entry (sort (copy-sequence ghostel-environment) #'string<))
              (insert (format "  %s\n" entry)))
            (insert "(TERM/TERMINFO/TERM_PROGRAM/COLORTERM not pushed for remote\n")
            (insert " spawns — set by the on-remote /bin/sh -c preamble; see\n")
            (insert " Process → Command, or run M-x ghostel-debug-ghostel and\n")
            (insert " inspect the captured wrapper script.)\n"))
           (t
            (insert "Spawn env (set by ghostel, local spawn):\n")
            (let* ((ghostel--terminfo-warned t)
                   (env (append (ghostel--terminal-env)
                                (list "INSIDE_EMACS=ghostel")
                                ghostel-environment)))
              (dolist (entry (sort (copy-sequence env) #'string<))
                (insert (format "  %s\n" entry))))))
          (insert "Pass-through (from Emacs):\n")
          (dolist (var '("LANG" "LC_ALL" "LC_CTYPE"))
            (insert (format "  %s=%s\n" var (or (getenv var) ""))))
          (insert "(user dotfiles may modify these at runtime)\n"))
        ;; Buffer / Process / Window / Terminal — only when in a ghostel buffer.
        ;; Capture buffer-local state into locals first, then insert in `out';
        ;; doing inserts inside `with-current-buffer ghostel-buf' would write
        ;; them to the wrong buffer.
        (if (not ghostel-buf)
            (insert "\n(not in a ghostel buffer — buffer/process/window/terminal sections skipped)\n")
          (let (buf-name maj-mode dir remote modes
                proc cmd shell shell-integ tramp-integ detected
                term term-rows term-cols force timer input-mode
                buf-size buf-lines pt dec2026 alt-scr
                dln-on dln-style spawn-capture)
            (with-current-buffer ghostel-buf
              (setq buf-name (buffer-name)
                    maj-mode major-mode
                    dir default-directory
                    remote (file-remote-p default-directory)
                    modes (cl-loop for m in minor-mode-list
                                   when (and (boundp m) (symbol-value m))
                                   collect (symbol-name m))
                    proc ghostel--process
                    cmd (and proc (process-live-p proc)
                             (mapconcat (lambda (s) (format "%s" s))
                                        (process-command proc) " "))
                    shell ghostel-shell
                    shell-integ ghostel-shell-integration
                    tramp-integ ghostel-tramp-shell-integration
                    detected (ghostel--detect-shell
                              (car (ghostel--shell-program-and-args
                                    ghostel-shell)))
                    term ghostel--term
                    term-rows ghostel--term-rows
                    term-cols ghostel--term-cols
                    force ghostel--force-next-redraw
                    timer (and ghostel--redraw-timer t)
                    input-mode ghostel--input-mode
                    buf-size (buffer-size)
                    buf-lines (count-lines (point-min) (point-max))
                    pt (point)
                    dec2026 (and term (ghostel--mode-enabled term 2026))
                    alt-scr (and term (ghostel--alt-screen-p term))
                    dln-on (bound-and-true-p display-line-numbers-mode)
                    dln-style display-line-numbers
                    spawn-capture ghostel-debug--spawn-capture))
            (let ((win (get-buffer-window ghostel-buf)))
              ;; Buffer
              (insert "\n--- Buffer ---\n")
              (insert (format "Buffer name:         %s\n" buf-name))
              (insert (format "Major mode:          %s\n" maj-mode))
              (insert (format "Default directory:   %s\n" dir))
              (insert (format "Remote:              %s\n" (or remote "no")))
              (when remote
                (insert (format "TRAMP method:        %s\n"
                                (file-remote-p dir 'method))))
              (insert (format "Active minor modes:  %s\n"
                              (if modes
                                  (mapconcat #'identity (sort modes #'string<) " ")
                                "(none)")))
              ;; Process
              (insert "\n--- Process ---\n")
              (cond
               ((null proc)
                (insert "Process:             nil\n"))
               ((not (process-live-p proc))
                (insert (format "Process:             dead (status: %s)\n"
                                (process-status proc))))
               (t
                (insert (format "PID:                 %s\n" (process-id proc)))
                (insert (format "Status:              %s\n" (process-status proc)))
                (insert (format "Command:             %s\n" cmd))
                (insert (format "TTY:                 %s\n"
                                (or (process-tty-name proc) "(none)")))))
              (insert (format "Configured shell:    %s\n" shell))
              (insert (format "Detected shell type: %s\n" (or detected "(unknown)")))
              (insert (format "Shell integration:   %s\n" shell-integ))
              (when remote
                (insert (format "TRAMP integration:   %s\n" tramp-integ)))
              ;; TRAMP — only meaningful for remote ghostel buffers, but
              ;; the load-bearing piece for ssh/tramp bugs (#224 et al.).
              (when remote
                (insert "\n--- TRAMP ---\n")
                (ghostel-debug--insert-tramp-section dir))
              ;; Spawn capture — populated by `ghostel-debug-ghostel'.
              ;; Survives process death, so we can show what was sent
              ;; even after the spawned shell exits.
              (insert "\n--- Spawn capture ---\n")
              (if spawn-capture
                  (ghostel-debug--insert-spawn-capture spawn-capture)
                (insert "(no capture — buffer was started via plain M-x ghostel.\n")
                (insert " Re-spawn under M-x ghostel-debug-ghostel to capture\n")
                (insert " the wrapper script, process-environment, first PTY\n")
                (insert " output bytes, and first keystrokes.)\n"))
              ;; Live remote probes — only when remote and explicit.
              ;; These add network roundtrips and require a healthy
              ;; TRAMP connection, so they're opt-in via prefix arg.
              (when (and remote with-remote-probes)
                (insert "\n--- Remote probes ---\n")
                (ghostel-debug--insert-remote-probes ghostel-buf))
              ;; Window
              (insert "\n--- Window ---\n")
              (if (window-live-p win)
                  (progn
                    (insert (format "Window body:         %dx%d (cols x rows)\n"
                                    (window-body-width win) (window-body-height win)))
                    (insert (format "Max chars per line:  %d\n"
                                    (window-max-chars-per-line win)))
                    (insert (format "Window start:        %d\n" (window-start win)))
                    (insert (format "Window end:          %d\n" (window-end win t)))
                    (let ((fr (window-fringes win)))
                      (insert (format "Fringes:             left=%spx right=%spx outside-margins=%s\n"
                                      (nth 0 fr) (nth 1 fr) (nth 2 fr))))
                    (let ((mg (window-margins win)))
                      (insert (format "Margins:             left=%s right=%s\n"
                                      (or (car mg) 0) (or (cdr mg) 0))))
                    (insert (format "Line numbers:        %s\n"
                                    (if dln-on (format "%s" dln-style) "off")))
                    (insert (format "Buffer windows:      %d\n"
                                    (length (get-buffer-window-list
                                             ghostel-buf nil t)))))
                (insert "Window:              not displayed in current frame\n"))
              ;; Terminal
              (insert "\n--- Terminal ---\n")
              (if term
                  (progn
                    (insert (format "Term size:           %sx%s (cols x rows)\n"
                                    term-cols term-rows))
                    (insert (format "Buffer size:         %d chars, %d lines\n"
                                    buf-size buf-lines))
                    (insert (format "Point:               %d\n" pt))
                    (insert (format "DEC 2026 (sync):     %s\n"
                                    (if dec2026 "ACTIVE" "off")))
                    (insert (format "Alt screen:          %s\n"
                                    (if alt-scr "yes" "no")))
                    (insert (format "Force next redraw:   %s\n" force))
                    (insert (format "Redraw timer:        %s\n"
                                    (if timer "pending" "none")))
                    (insert (format "Input mode:          %s\n"
                                    (or input-mode "(unknown)"))))
                (insert "Term handle:         nil (no terminal)\n"))
              ;; Size sync — surfaces #192-class bugs.
              ;; Compare term-rows against `floor(window-screen-lines)' (what
              ;; `window-adjust-process-window-size-smallest' uses), NOT
              ;; `window-body-height': the latter divides by frame char
              ;; height while screen-lines divides by `default-line-height'
              ;; (face-remap-aware).  When a theme remaps the default face
              ;; height, the two disagree and the body-height comparison
              ;; cries wolf.
              (when (and term (window-live-p win))
                (insert "\n--- Size sync ---\n")
                (let* ((cur-body-px (window-body-height win t))
                       (old-body-px (window-old-body-pixel-height win))
                       (cur-total-px (window-pixel-height win))
                       (old-total-px (window-old-pixel-height win))
                       (screen-lines (with-selected-window win
                                       (window-screen-lines)))
                       (body-rows (window-body-height win))
                       (frame-ch (frame-char-height))
                       (default-fh (with-selected-window win
                                     (default-font-height)))
                       (default-lh (with-selected-window win
                                     (default-line-height)))
                       (target-rows (floor screen-lines))
                       (rendered-px (* term-rows default-lh))
                       (gap-px (- cur-body-px rendered-px))
                       (rows-match (eql target-rows term-rows))
                       (px-match (eql cur-body-px old-body-px)))
                  (insert (format "screen-lines:        %.3f → target %d (term=%s) %s\n"
                                  screen-lines target-rows term-rows
                                  (if rows-match "[in sync]" "[MISMATCH]")))
                  (insert (format "Body rows (frame):   %d (window-body-height — frame chars)\n"
                                  body-rows))
                  (insert (format "Line height:         frame=%d px  default-font=%d px  default-line=%d px%s\n"
                                  frame-ch default-fh default-lh
                                  (cond ((not (eql frame-ch default-fh))
                                         " [font ≠ frame: face-remap or :height]")
                                        ((not (eql default-fh default-lh))
                                         " [extra from line-spacing]")
                                        (t ""))))
                  (insert (format "Body pixels:         cur=%d  recorded=%d %s\n"
                                  cur-body-px old-body-px
                                  (if px-match "" "[redisplay pending]")))
                  (insert (format "Window pixels:       cur=%d  recorded=%d\n"
                                  cur-total-px old-total-px))
                  (insert (format "Bottom gap:          %d px (%d rendered − %d body)\n"
                                  gap-px rendered-px cur-body-px))
                  (cond
                   (rows-match
                    (insert "Diagnosis:           in sync\n"))
                   (px-match
                    (insert "Diagnosis:           Emacs absorbed the change but\n")
                    (insert "                     ghostel didn't reconcile (#192)\n"))
                   (t
                    (insert "Diagnosis:           pending redisplay; hooks will fire\n")
                    (insert "                     on next paint\n"))))
                ;; Rendering — font / line-spacing / face-remap.
                ;; Most #192-class follow-ups so far have been about
                ;; line-spacing or face-remap silently changing the row
                ;; metric.  Surface the live values so a report tells
                ;; us in one capture which knob is responsible.
                (insert "\n--- Rendering ---\n")
                (let* ((face-family
                        (with-current-buffer ghostel-buf
                          (face-attribute 'default :family nil 'default)))
                       (face-height
                        (with-current-buffer ghostel-buf
                          (face-attribute 'default :height nil 'default)))
                       (face-weight
                        (with-current-buffer ghostel-buf
                          (face-attribute 'default :weight nil 'default)))
                       (resolved-font
                        (with-selected-window win (face-font 'default)))
                       (frame-font (frame-parameter nil 'font))
                       (lsp-buf (with-current-buffer ghostel-buf
                                  (and (local-variable-p 'line-spacing)
                                       line-spacing)))
                       (lsp-default (default-value 'line-spacing))
                       (lsp-frame (frame-parameter nil 'line-spacing))
                       (remap (with-current-buffer ghostel-buf
                                face-remapping-alist)))
                  (insert (format "Default face:        %s %S %s\n"
                                  face-family face-height face-weight))
                  (insert (format "Resolved font:       %s\n" resolved-font))
                  (insert (format "Frame font:          %s%s\n"
                                  frame-font
                                  (if (and (stringp resolved-font)
                                           (stringp frame-font)
                                           (not (string= resolved-font frame-font)))
                                      " [resolved differs — fallback or remap]"
                                    "")))
                  (insert (format "line-spacing:        buf=%S  default-value=%S  frame=%S\n"
                                  lsp-buf lsp-default lsp-frame))
                  (insert (format "face-remapping:      %s\n"
                                  (if remap
                                      (format "%S" remap)
                                    "(none)"))))))))
        ;; Key encoding probe — show the bytes Ghostel produces for chords
        ;; that commonly drive `.inputrc' / readline issue reports (#239).
        ;; Probes a fresh legacy-mode terminal so the bytes are what readline
        ;; sees in its default state, regardless of whether the live terminal
        ;; has kitty keyboard / modifyOtherKeys turned on by some app.
        (insert "\n--- Key encoding (legacy mode) ---\n")
        (cond
         ((not (fboundp 'ghostel--encode-key))
          (insert "(native module not loaded — cannot probe encoder)\n"))
         (t
          (let ((probe (ignore-errors (ghostel--new 25 80 100)))
                (sent nil))
            (cond
             ((null probe)
              (insert "(could not create probe terminal)\n"))
             (t
              (cl-letf (((symbol-function 'ghostel--write-pty)
                         (lambda (_term s) (setq sent s))))
                (dolist (chord '(("backspace" ""          "Backspace")
                                 ("backspace" "ctrl"      "C-Backspace")
                                 ("backspace" "meta"      "M-Backspace")
                                 ("f"         "meta"      "M-f")
                                 ("b"         "meta"      "M-b")
                                 ("."         "meta"      "M-.")
                                 ("f"         "ctrl,meta" "C-M-f")
                                 ("v"         "ctrl,meta" "C-M-v")
                                 ("h"         "ctrl"      "C-h")))
                  (setq sent nil)
                  ;; Mirror `ghostel--send-encoded': try encoder, fall back
                  ;; to the raw-key-sequence path on nil.  Encoder skips
                  ;; plain Meta+letter when no utf8 is supplied (live
                  ;; keystrokes don't supply it either) — the fallback
                  ;; produces ESC + char.
                  (unless (ghostel--encode-key probe (nth 0 chord)
                                               (nth 1 chord) nil)
                    (setq sent (ghostel--raw-key-sequence (nth 0 chord)
                                                          (nth 1 chord))))
                  (insert (format "  %-13s → %s\n"
                                  (nth 2 chord)
                                  (cond ((null sent) "(no output)")
                                        ((string-empty-p sent) "(empty)")
                                        (t (mapconcat
                                            (lambda (b) (format "0x%02x" b))
                                            (string-to-list sent) " ")))))))
              (insert "\nReadline `.inputrc' rules expecting these byte streams:\n")
              (insert "  \"\\C-?\"     → 0x7f          (Backspace)\n")
              (insert "  \"\\C-\\b\"    → 0x08          (C-Backspace, also C-h in legacy)\n")
              (insert "  \"\\eb\"      → 0x1b 0x62     (M-b)\n")
              (insert "  \"\\e\\C-f\"   → 0x1b 0x06     (C-M-f)\n")
              (insert "  \"\\e\\C-v\"   → 0x1b 0x16     (C-M-v)\n"))))))
        ;; Non-default ghostel settings
        (insert "\n--- Non-default ghostel settings ---\n")
        (let (changed)
          (mapatoms
           (lambda (sym)
             (when (and (boundp sym)
                        (string-match-p "ghostel" (symbol-name sym))
                        (get sym 'standard-value)
                        ;; Skip minor-mode toggle vars — they show up
                        ;; in the "Active minor modes" list already and
                        ;; aren't user-tunable settings.
                        (not (memq sym minor-mode-list)))
               (let* ((std (get sym 'standard-value))
                      (default (condition-case nil
                                   (eval (car std) t)
                                 (error :eval-error)))
                      (current (symbol-value sym)))
                 (unless (equal current default)
                   (push (list sym current default) changed))))))
          (if (null changed)
              (insert "(all settings at defaults)\n")
            (setq changed (sort changed
                                (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b))))))
            (dolist (entry changed)
              (insert (format "%s: %S\n  default: %S\n"
                              (car entry) (nth 1 entry) (nth 2 entry))))))
        (goto-char (point-min)))
      ;; Read-only with `q' to quit (matches *Help*-style buffers).
      ;; `ghostel-debug-start' / `ghostel-debug-typing-latency' reset to
      ;; `fundamental-mode' before they erase, so this doesn't trap them.
      (special-mode))
    (display-buffer out)
    (message "Debug info written to *ghostel-debug*")))

(defun ghostel-debug--insert-tramp-section (dir)
  "Insert the TRAMP diagnostic block for remote DIR.
Surfaces the values that load-bear in TRAMP `make-process' paths:
the connection-shell TERM (`tramp-terminal-type'), whether the
direct-async path applies, multi-hop status, and the local-vs-
toplevel TERM mismatch that drives `tramp-local-environment-
variable-p' to silently strip ghostel's pushed TERM.

Each value is read with a `boundp'/`fboundp' guard — older TRAMP
versions (notably the one bundled with Emacs 28) lack
`tramp-direct-async-process' / `tramp-direct-async-process-p',
and the report should still render usefully on those Emacsen."
  (require 'tramp)
  (insert (format "tramp-version:       %s\n"
                  (condition-case _ (tramp-version nil)
                    (error "(unavailable)"))))
  (insert (format "tramp-terminal-type: %s\n"
                  (if (boundp 'tramp-terminal-type)
                      tramp-terminal-type
                    "(unavailable)")))
  ;; tramp-direct-async-process is a defvar; report both the global
  ;; and the connection-local-resolved value (they often differ).
  ;; Added in TRAMP 2.5 — Emacs 28 ships an older bundled TRAMP that
  ;; doesn't have it, so guard with `boundp'.
  (cond
   ((not (boundp 'tramp-direct-async-process))
    (insert "direct-async (global):    (unavailable on this TRAMP version)\n")
    (insert "direct-async (effective): (unavailable on this TRAMP version)\n"))
   (t
    (let ((global (default-value 'tramp-direct-async-process))
          (effective
           (condition-case _
               (with-parsed-tramp-file-name dir nil
                 (with-connection-local-variables
                  tramp-direct-async-process))
             (error :unknown))))
      (insert (format "direct-async (global):    %S\n" global))
      (insert (format "direct-async (effective): %S\n" effective)))))
  ;; Would TRAMP dispatch direct-async for a make-process call here?
  ;; Use a synthetic args plist that mimics ghostel's spawn shape.
  (let ((dispatched
         (condition-case _
             (let ((default-directory dir))
               (and (fboundp 'tramp-direct-async-process-p)
                    (tramp-direct-async-process-p
                     :command '("/bin/sh" "-c" "true")
                     :buffer nil :stderr nil)))
           (error :unknown))))
    (insert (format "Would dispatch direct-async: %s\n"
                    (cond ((not (fboundp 'tramp-direct-async-process-p))
                           "(unavailable on this TRAMP version)")
                          ((eq dispatched :unknown) "(unknown)")
                          (dispatched "yes")
                          (t "no")))))
  ;; Multi-hop path matters because direct-async refuses multi-hop
  ;; and some env-stripping/connection-shell behaviors differ.
  (let ((hops (and (fboundp 'tramp-compute-multi-hops)
                   (condition-case _
                       (with-parsed-tramp-file-name dir vec
                         (length (tramp-compute-multi-hops vec)))
                     (error nil)))))
    (insert (format "Multi-hop length:    %s\n" (or hops "(unknown)"))))
  ;; TERM in the *connection shell* — what TRAMP exports for
  ;; `process-file' calls and (without our preamble) what the
  ;; spawned shell would inherit.  Ghostel's spawned shell does
  ;; NOT see this directly: the on-remote `/bin/sh -c' preamble
  ;; in `ghostel--remote-term-preamble' overrides TERM via
  ;; `infocmp xterm-ghostty' before exec'ing the shell.  See the
  ;; Spawn capture's wrapper command for the actual TERM the
  ;; spawned shell ends up with.
  (insert (format "TERM (connection shell): %s\n"
                  (or (getenv "TERM") "(unset)"))))

(defun ghostel-debug--insert-command-cells (cmd nil-message)
  "Insert CMD as `program: …' / `args: …' lines.
CMD is a `make-process' / `process-command'-shaped list (program
followed by args), or nil.  NIL-MESSAGE is the placeholder shown
when CMD is nil."
  (cond
   ((null cmd) (insert (format "  %s\n" nil-message)))
   ((not (consp cmd)) (insert (format "  %S\n" cmd)))
   (t
    (insert (format "  program: %s\n" (car cmd)))
    (let ((args (cdr cmd)))
      (cond
       ((null args) (insert "  args:    (none)\n"))
       (t
        (insert "  args:\n")
        (dolist (a args)
          (insert (format "    %s\n" a)))))))))

(defun ghostel-debug--insert-spawn-capture (cap)
  "Render the spawn capture plist CAP into the current buffer.
Wrapper script is printed verbatim (as sent to `make-process')
because that single string is the smoking gun for #224-class bugs:
it shows whether the on-remote TERM preamble was assembled, with
which branches.  `process-environment' is shown as a sorted list
of the entries that differ from the current Emacs env, since the
delta is what ghostel + TRAMP actually contributed."
  (insert (format "Captured at:         %s\n"
                  (format-time-string "%F %T.%3N"
                                      (plist-get cap :time))))
  (insert (format "default-directory:   %s\n"
                  (plist-get cap :default-directory)))
  (insert (format "Remote-p:            %s\n"
                  (if (plist-get cap :remote-p) "yes" "no")))
  (insert (format "Program:             %s\n" (plist-get cap :program)))
  (let ((args (plist-get cap :program-args)))
    (insert (format "Program args:        %s\n"
                    (if args (format "%S" args) "(none)"))))
  (insert (format "Geometry:            %sx%s (cols x rows)\n"
                  (plist-get cap :cols) (plist-get cap :rows)))
  (let ((extra (plist-get cap :extra-env)))
    (insert "extra-env:           ")
    (if (null extra)
        (insert "(none)\n")
      (insert "\n")
      (dolist (e extra)
        (insert (format "  %s\n" e)))))
  ;; The wrapper script — the single most useful piece for spawn bugs.
  ;; This is what ghostel passed to `make-process', captured before
  ;; TRAMP can rewrite it on its non-direct-async dispatch path.
  (let ((cmd (plist-get cap :command)))
    (insert "\nWrapper command sent to `make-process':\n")
    (ghostel-debug--insert-command-cells cmd
      "(nil — make-process advice did not capture a :command)"))
  ;; If TRAMP rewrote the command for legacy-async dispatch, the
  ;; resulting `process-command' won't match what we sent — typically
  ;; it's a bridge like ("/bin/sh" "-i") that proxies stdio while the
  ;; real wrapper runs on the remote via the connection shell.  Show
  ;; the divergence so the path is obvious.
  (let ((cmd (plist-get cap :command))
        (executed (plist-get cap :executed-command)))
    (when (and executed (not (equal cmd executed)))
      (insert "\nLocal process command (`process-command'):\n")
      (ghostel-debug--insert-command-cells executed "(unavailable)")
      (insert
       (concat "  TRAMP rewrote the command for legacy-async dispatch — the\n"
               "  wrapper above runs on the remote via the connection shell;\n"
               "  the bridge process here just proxies stdio.  Direct-async\n"
               "  would show the wrapper command verbatim in both sections.\n"))))
  ;; process-environment delta — the entries ghostel + TRAMP wove in
  ;; or that differ from the current Emacs env at info-display time.
  ;; Showing only the delta (rather than the full ~100-entry env)
  ;; keeps the diagnostic readable.
  (let* ((spawn-env (plist-get cap :process-environment))
         (now-env process-environment)
         (added (cl-set-difference spawn-env now-env :test #'string=))
         (removed (cl-set-difference now-env spawn-env :test #'string=)))
    (insert (format "\nprocess-environment at spawn (%d entries):\n"
                    (length spawn-env)))
    (cond
     ((and (null added) (null removed))
      (insert "  (identical to current Emacs env)\n"))
     (t
      (when added
        (insert "  Added vs current:\n")
        (dolist (e (sort (copy-sequence added) #'string<))
          (insert (format "    + %s\n" e))))
      (when removed
        (insert "  Missing vs current (current has these, spawn didn't):\n")
        (dolist (e (sort (copy-sequence removed) #'string<))
          (insert (format "    - %s\n" e)))))))
  ;; Phase timings — answers `where did the time go per spawn?'.
  ;; Three deltas: elisp prep (start-process → spawn-pty), TRAMP+ssh
  ;; handshake (spawn-pty → first PTY byte), and any further wait
  ;; for the prompt.  See `ghostel-debug--insert-spawn-phase-timings'.
  (ghostel-debug--insert-spawn-phase-timings cap)
  ;; Unified RECV/SEND timeline.  Interleaving PTY output and
  ;; keystrokes by timestamp makes echo gaps obvious — a SEND "l"
  ;; followed only by another SEND (no RECV "l" between) is the
  ;; #224 signature.  Keeping them as separate sections (the previous
  ;; layout) hid that pattern.
  (ghostel-debug--insert-spawn-timeline cap))

(defun ghostel-debug--insert-spawn-phase-timings (cap)
  "Render CAP's per-phase timings into the current buffer.
CAP is the spawn-capture plist (see `ghostel-debug--spawn-capture').
Shows three checkpoints relative to `ghostel--start-process' entry:
elisp-prep cost (anything before `make-process' — typically dominated
by TRAMP shell-detection round-trips), TRAMP+ssh+remote-shell startup
cost (`make-process' return → first PTY byte), and the inter-byte
gap between spawn-pty entry and the first byte received from the
remote shell.

When `:start-process-time' is missing (capture was created from a
direct `ghostel--spawn-pty' call without going through
`ghostel--start-process'), the elisp-prep delta is omitted."
  (let* ((t-sp   (plist-get cap :start-process-time))
         (t-spawn (plist-get cap :time))
         (events (plist-get cap :filter-events))
         (t-first-rx (and events (car (car events)))))
    (insert "\nPhase timings:\n")
    (cond
     ((null t-spawn)
      (insert "  (no `ghostel--spawn-pty' time recorded)\n"))
     (t
      (when t-sp
        (insert (format "  %8s  ghostel--start-process entered\n" "T0")))
      (insert (format "  %8s  ghostel--spawn-pty entered%s\n"
                      (if t-sp
                          (format "+%dms"
                                  (round
                                   (* 1000
                                      (float-time
                                       (time-subtract t-spawn t-sp)))))
                        "T0")
                      (if t-sp
                          "  (elisp prep: getent shell, integration setup, env build)"
                        "")))
      (cond
       (t-first-rx
        (insert (format "  %8s  first PTY byte received  (TRAMP make-process + ssh + remote shell startup)\n"
                        (format "+%dms"
                                (round
                                 (* 1000
                                    (float-time
                                     (time-subtract t-first-rx
                                                    (or t-sp t-spawn))))))))
        (when t-sp
          (insert (format "  %8s  ↳ from spawn-pty entry\n"
                          (format "+%dms"
                                  (round
                                   (* 1000
                                      (float-time
                                       (time-subtract t-first-rx
                                                      t-spawn)))))))))
       (t
        (insert "  (no PTY output yet — first-byte timing unavailable)\n")))))))

(defun ghostel-debug--insert-spawn-timeline (cap)
  "Render CAP's interleaved RECV/SEND timeline into the current buffer.
CAP is the spawn-capture plist (see `ghostel-debug--spawn-capture').
Long chunks are truncated for display; the full bytes remain in
the plist."
  (let* ((t0 (plist-get cap :time))
         (recv-cap (plist-get cap :filter-cap))
         (recv-bytes (plist-get cap :filter-bytes))
         (recv-events (plist-get cap :filter-events))
         (recv-truncated (plist-get cap :filter-truncated))
         (send-cap (plist-get cap :send-cap))
         (sends (plist-get cap :send-keys))
         (send-truncated (plist-get cap :send-truncated))
         (events
          (sort (append
                 (mapcar (lambda (e)
                           (list (car e) :recv (cdr e)))
                         recv-events)
                 (mapcar (lambda (s)
                           (list (car s) :send (cdr s))) sends))
                (lambda (a b) (time-less-p (car a) (car b))))))
    (insert (format
             "\nTimeline (RECV cap=%d bytes/%d captured%s; SEND cap=%d/%d captured%s):\n"
             recv-cap (or recv-bytes 0)
             (if recv-truncated ", more dropped" "")
             send-cap (length sends)
             (if send-truncated ", more dropped" "")))
    (cond
     ((null events)
      (insert "  (no PTY output, no sends — shell never wrote and Emacs never typed)\n"))
     (t
      (let ((print-escape-control-characters t)
            (print-escape-newlines t)
            (display-cap 240))
        (dolist (ev events)
          (let* ((ts (nth 0 ev))
                 (kind (nth 1 ev))
                 (data (nth 2 ev))
                 (label (if (eq kind :send) "SEND" "RECV"))
                 (truncated (> (length data) display-cap))
                 (shown (if truncated
                            (substring data 0 display-cap)
                          data)))
            (insert (format "  +%7.3fs  %s  %s%s\n"
                            (float-time (time-subtract ts t0))
                            label
                            (prin1-to-string shown)
                            (if truncated
                                (format " (… +%d bytes)"
                                        (- (length data) display-cap))
                              ""))))))))))

(defun ghostel-debug--insert-remote-probes (ghostel-buf)
  "Run live probes against the remote of GHOSTEL-BUF and insert results.
Single round-trip via `process-file' + `/bin/sh -c' to keep latency
predictable.  Probes the things the on-remote TERM preamble depends
on: `infocmp' presence and the `xterm-ghostty'/`xterm-256color'
terminfo entries, bundled `~/.local/share/ghostel/terminfo' paths,
remote `/bin/sh' identity, login shell.

Then runs ghostel's actual remote-term preamble inside the same
probe shell and reports what TERM the spawned shell would inherit.
This is the load-bearing piece: it answers `what does ghostel's
shell actually see' rather than `what does TRAMP's connection
shell export', which is `TERM=dumb' regardless of preamble.

Last, probes bash version and dumps `~/.inputrc' (or `$INPUTRC'
when set) so issue reports about readline rules not firing — see
issue #239 — carry the actual rule file alongside the byte stream
ghostel produces (rendered locally in the `Key encoding' section)."
  (let* ((preamble (ghostel--remote-term-preamble))
         ;; Strip the trailing "; " so we can append more commands.
         (preamble-clean (replace-regexp-in-string "; *\\'" "" preamble))
         (script
          (concat
           "echo '== uname =='; uname -srm 2>&1; echo; "
           "echo '== id / shell =='; id 2>&1; "
           "echo \"login shell: $(getent passwd \"$(id -un)\" 2>/dev/null "
           "| awk -F: '{print $7}')\"; echo; "
           "echo '== /bin/sh =='; ls -la /bin/sh 2>&1; "
           "echo \"sh prints \\$0 as: $(/bin/sh -c 'echo $0' 2>&1)\"; echo; "
           "echo '== infocmp =='; "
           "if command -v infocmp >/dev/null 2>&1; then "
           "  echo \"infocmp: $(command -v infocmp)\"; "
           "  if infocmp xterm-ghostty >/dev/null 2>&1; then "
           "    echo 'xterm-ghostty terminfo: FOUND'; "
           "  else echo 'xterm-ghostty terminfo: not found'; fi; "
           "  if infocmp xterm-256color >/dev/null 2>&1; then "
           "    echo 'xterm-256color terminfo: FOUND'; "
           "  else echo 'xterm-256color terminfo: NOT FOUND'; fi; "
           "else echo 'infocmp: NOT ON PATH (preamble fallback always trips)'; fi; "
           "echo; echo '== bundled terminfo paths =='; "
           "for p in ~/.local/share/ghostel/terminfo/x/xterm-ghostty "
           "~/.local/share/ghostel/terminfo/78/xterm-ghostty; do "
           "  if [ -e \"$p\" ]; then echo \"  $p: exists\"; "
           "  else echo \"  $p: missing\"; fi; done; "
           ;; Run the actual preamble in a subshell, then print what
           ;; TERM/TERMINFO_DIRS/COLORTERM the spawned shell would
           ;; see.  Subshell isolates the probe shell's env from any
           ;; downstream commands we might add.
           "echo; echo '== preamble simulation =='; "
           "echo 'Running the on-remote `ghostel--remote-term-preamble` snippet,'; "
           "echo 'then printing the env it would hand the spawned shell:'; "
           "( " preamble-clean "; "
           "  echo \"  TERM=${TERM:-unset}\"; "
           "  echo \"  TERMINFO_DIRS=${TERMINFO_DIRS:-unset}\"; "
           "  echo \"  TERM_PROGRAM=${TERM_PROGRAM:-unset}\"; "
           "  echo \"  TERM_PROGRAM_VERSION=${TERM_PROGRAM_VERSION:-unset}\"; "
           "  echo \"  COLORTERM=${COLORTERM:-unset}\"; "
           ") 2>&1; "
           ;; Bash + inputrc probe — answers `.inputrc' issue reports
           ;; (e.g. #239).  Surfaces bash version, the resolved INPUTRC
           ;; path, and the file's contents so we can spot $if-term
           ;; gates, syntax errors, or rules referencing different byte
           ;; streams than ghostel produces (cross-check against the
           ;; local `Key encoding' section).  Bound to 80 lines so a
           ;; large customized inputrc doesn't drown the report.
           "echo; echo '== bash + inputrc =='; "
           "if command -v bash >/dev/null 2>&1; then "
           "  bash --version 2>/dev/null | head -1; "
           "else echo 'bash: NOT ON PATH'; fi; "
           "echo \"INPUTRC=${INPUTRC:-unset}\"; "
           "echo \"HOME=$HOME\"; "
           "inputrc_path=${INPUTRC:-$HOME/.inputrc}; "
           "if [ -e \"$inputrc_path\" ]; then "
           "  lines=$(wc -l < \"$inputrc_path\" 2>/dev/null); "
           "  echo \"$inputrc_path: $lines lines\"; "
           "  echo '----- contents (first 80 lines) -----'; "
           "  head -80 \"$inputrc_path\"; "
           "  echo '----- end inputrc -----'; "
           "else echo \"$inputrc_path: missing\"; fi")))
    (with-temp-buffer
      (let* ((default-directory (with-current-buffer ghostel-buf
                                  default-directory))
             (rc (condition-case err
                     (process-file "/bin/sh" nil t nil "-c" script)
                   (error (insert (format "\n[probe error: %s]" err))
                          -1))))
        (let ((output (buffer-string)))
          (with-current-buffer (get-buffer "*ghostel-debug*")
            (insert "(Probes run via TRAMP `process-file', NOT through ghostel's\n")
            (insert " spawn — the connection shell exports TERM=dumb to all\n")
            (insert " process-file calls, so we run the preamble ourselves at\n")
            (insert " the end and report the resulting env.)\n\n")
            (insert (format "Remote probe (exit=%s):\n" rc))
            (dolist (line (split-string output "\n"))
              (insert (format "  %s\n" line)))))))))


;;; Spawn capture

;; `ghostel-debug-ghostel' wraps a single `ghostel' invocation with
;; advice that snapshots `ghostel--spawn-pty's arguments, the live
;; `process-environment', the wrapper command sent to `make-process',
;; the first ~4 KB of PTY output, and the first ~64 keystrokes sent.
;; The advice removes itself once the spawn returns, so plain
;; `ghostel' sessions are unaffected.  `ghostel-debug-info' renders
;; the capture when present.
;;
;; Why not also wire up the noisy `ghostel-debug-start' loggers
;; (REDRAW/RESIZE/VT)?  Those are useful for redraw/sync bugs but
;; pure noise for the spawn/connectivity/no-echo bugs this command
;; targets.  Users who need full instrumentation can still run
;; `ghostel-debug-start' alongside.

;;;###autoload
(defun ghostel-debug-ghostel (&optional arg)
  "Like `ghostel', but capture spawn diagnostics into the new buffer.

The capture includes the wrapper script, process environment, phase
timestamps, early PTY output, and the first keystrokes typed.

ARG is forwarded to `ghostel' (same prefix-argument conventions).
View the capture with \\[ghostel-debug-info]."
  (interactive "P")
  (advice-add 'ghostel--start-process :around
              #'ghostel-debug--capture-start-process)
  (advice-add 'ghostel--spawn-pty :around
              #'ghostel-debug--capture-spawn-pty)
  (unwind-protect
      (ghostel arg)
    ;; The advices remove themselves once `ghostel--spawn-pty' returns,
    ;; but if the spawn never happened (e.g. user pointed at an
    ;; existing buffer with a live process) clean up here.
    (advice-remove 'ghostel--start-process
                   #'ghostel-debug--capture-start-process)
    (advice-remove 'ghostel--spawn-pty
                   #'ghostel-debug--capture-spawn-pty)))

(defun ghostel-debug--capture-start-process (orig &rest args)
  "Around-advice on `ghostel--start-process' that records its entry time.
ORIG is the original function; ARGS are forwarded verbatim.  The
timestamp is stashed buffer-locally so the spawn-pty advice can fold
it into the spawn-capture plist.  Self-removing — fires at most once."
  (advice-remove 'ghostel--start-process
                 #'ghostel-debug--capture-start-process)
  (setq ghostel-debug--pending-start-process-time (current-time))
  (apply orig args))

(defun ghostel-debug--capture-spawn-pty
    (orig program program-args extra-env &optional remote-p)
  "Around-advice on `ghostel--spawn-pty' that snapshots the spawn.
ORIG is the original function; PROGRAM, PROGRAM-ARGS, EXTRA-ENV, and
REMOTE-P are forwarded verbatim and recorded into
`ghostel-debug--spawn-capture'.  Self-removing — fires at most once.

Captures the wrapper command via `cl-letf*' on `make-process' rather
than reading `process-command' on the returned process: on TRAMP's
non-direct-async path `tramp-sh-handle-make-process' substitutes a
local bridge process (e.g. `/bin/sh -i') for the actual spawn and
dispatches the real command via the connection shell.  In that case
`process-command' returns the bridge — useless for diagnosing what
actually ran on the remote.  The intercept catches the call as ghostel
made it, before any TRAMP rewriting, so the wrapper section in the
report stays accurate regardless of TRAMP dispatch path.

Both views are kept: `:command' is what ghostel passed to
`make-process' (always the meaningful wrapper script), and
`:executed-command' is what `process-command' reports (post-TRAMP-
rewrite — handy for telling direct-async vs legacy apart).  When the
two differ, the renderer flags it."
  (advice-remove 'ghostel--spawn-pty
                 #'ghostel-debug--capture-spawn-pty)
  (let ((spawn-time (current-time))
        (start-process-time ghostel-debug--pending-start-process-time)
        (spawn-env (copy-sequence process-environment))
        (spawn-dir default-directory)
        (intercepted-cmd nil))
    ;; Consume the stashed value so a stale entry doesn't survive
    ;; into a future capture if the user runs ghostel-debug-ghostel
    ;; again in the same buffer.
    (setq ghostel-debug--pending-start-process-time nil)
    (let* ((orig-make-process (symbol-function #'make-process))
           (proc
            (cl-letf
                (((symbol-function #'make-process)
                  (lambda (&rest plist)
                    ;; Only capture the OUTERMOST call: with direct-
                    ;; async, TRAMP's file handler may recursively
                    ;; call make-process to reach the real spawn —
                    ;; the first call is ghostel's, which is what
                    ;; we want.
                    (unless intercepted-cmd
                      (setq intercepted-cmd
                            (plist-get plist :command)))
                    (apply orig-make-process plist))))
              (funcall orig program program-args extra-env remote-p))))
      ;; `ghostel--spawn-pty' runs in the new ghostel buffer (the
      ;; spawn target), so `setq-local' here lands on the right
      ;; buffer-local.
      (setq ghostel-debug--spawn-capture
            (list :time spawn-time
                  :start-process-time start-process-time
                  :default-directory spawn-dir
                  :remote-p (and remote-p t)
                  :program program
                  :program-args program-args
                  :cols ghostel--term-cols
                  :rows ghostel--term-rows
                  :extra-env extra-env
                  :process-environment spawn-env
                  :command intercepted-cmd
                  :executed-command (and (processp proc)
                                         (process-command proc))
                  :filter-events nil
                  :filter-cap ghostel-debug--filter-cap
                  :filter-bytes 0
                  :filter-truncated nil
                  :send-keys nil
                  :send-cap ghostel-debug--send-cap
                  :send-truncated nil))
      ;; Idempotent installs — if the user runs `ghostel-debug-ghostel'
      ;; for several buffers the advice is added once and no-ops in
      ;; buffers without a capture.
      (advice-add 'ghostel--filter :before
                  #'ghostel-debug--capture-filter)
      (advice-add 'ghostel--send-string :before
                  #'ghostel-debug--capture-send-string)
      proc)))

(defun ghostel-debug--capture-filter (proc output)
  "Append OUTPUT to the capture's :filter-events for PROC's buffer.
Each call appends a (TIMESTAMP . CHUNK) event so the post-mortem
report can interleave PTY output with sends on a single timeline.
Bounded by `:filter-cap' total bytes; sets `:filter-truncated' once
the cap is hit and further chunks are dropped."
  (when (and (stringp output)
             (buffer-live-p (process-buffer proc)))
    (with-current-buffer (process-buffer proc)
      (when ghostel-debug--spawn-capture
        (let* ((cap (plist-get ghostel-debug--spawn-capture :filter-cap))
               (total (plist-get ghostel-debug--spawn-capture :filter-bytes))
               (room (- cap total)))
          (cond
           ((<= room 0)
            (unless (plist-get ghostel-debug--spawn-capture
                               :filter-truncated)
              (setq ghostel-debug--spawn-capture
                    (plist-put ghostel-debug--spawn-capture
                               :filter-truncated t))))
           (t
            (let* ((take (min room (length output)))
                   (fits (substring output 0 take))
                   (events (plist-get ghostel-debug--spawn-capture
                                      :filter-events)))
              (setq ghostel-debug--spawn-capture
                    (plist-put ghostel-debug--spawn-capture :filter-events
                               (append events
                                       (list (cons (current-time) fits)))))
              (setq ghostel-debug--spawn-capture
                    (plist-put ghostel-debug--spawn-capture :filter-bytes
                               (+ total take)))
              (when (> (length output) take)
                (setq ghostel-debug--spawn-capture
                      (plist-put ghostel-debug--spawn-capture
                                 :filter-truncated t)))))))))))

(defun ghostel-debug--capture-send-string (string)
  "Append STRING to the capture's :send-keys for the current buffer.
Bounded by `:send-cap'; sets `:send-truncated' once exceeded."
  (when (and (stringp string) ghostel-debug--spawn-capture)
    (let ((cap (plist-get ghostel-debug--spawn-capture :send-cap))
          (cur (plist-get ghostel-debug--spawn-capture :send-keys)))
      (cond
       ((>= (length cur) cap)
        (unless (plist-get ghostel-debug--spawn-capture :send-truncated)
          (setq ghostel-debug--spawn-capture
                (plist-put ghostel-debug--spawn-capture
                           :send-truncated t))))
       (t
        (setq ghostel-debug--spawn-capture
              (plist-put ghostel-debug--spawn-capture :send-keys
                         (append cur
                                 (list (cons (current-time) string))))))))))


;;; Keypress capture

(defvar ghostel--debug-kp-state nil
  "In-progress `ghostel-debug-keypress' capture, or nil.
A plist with at least :buffer (the target ghostel buffer) and :calls
\(an alist of (KIND . BYTES) reverse-collected during the captured
command, where KIND is `:write-pty' or `:send-string').")

;;;###autoload
(defun ghostel-debug-keypress ()
  "Capture diagnostics for the next keystroke in this ghostel buffer.
After you press one key, a report appears in *ghostel-debug-keypress*
suitable for pasting into a GitHub issue.

Captures the raw event, resolved key binding, terminal bytes emitted
during the command, terminal mode flags, and process state."
  (interactive)
  (unless (derived-mode-p 'ghostel-mode)
    (user-error "Not in a ghostel buffer"))
  (when ghostel--debug-kp-state (ghostel--debug-kp-teardown))
  (setq ghostel--debug-kp-state
        (list :buffer (current-buffer) :calls nil))
  (advice-add 'ghostel--write-pty :before
              #'ghostel--debug-kp-record-write-pty)
  (advice-add 'ghostel--send-string :before
              #'ghostel--debug-kp-record-send-string)
  (add-hook 'pre-command-hook #'ghostel--debug-kp-pre-command)
  (message "ghostel-debug-keypress: armed — press a key in this buffer"))

(defun ghostel--debug-kp-add-call (kind value)
  "Append (KIND . VALUE) to the in-progress capture's :calls list."
  (when ghostel--debug-kp-state
    (setq ghostel--debug-kp-state
          (plist-put ghostel--debug-kp-state :calls
                     (cons (cons kind value)
                           (plist-get ghostel--debug-kp-state :calls))))))

(defun ghostel--debug-kp-record-write-pty (_term data)
  "Record DATA flowing through `ghostel--write-pty'."
  (when (eq (current-buffer)
            (plist-get ghostel--debug-kp-state :buffer))
    (ghostel--debug-kp-add-call :write-pty data)))

(defun ghostel--debug-kp-record-send-string (string)
  "Record STRING flowing through `ghostel--send-string'."
  (when (eq (current-buffer)
            (plist-get ghostel--debug-kp-state :buffer))
    (ghostel--debug-kp-add-call :send-string string)))

(defun ghostel--debug-kp-pre-command ()
  "Capture event details just before the user's command runs."
  (cond
   ;; Skip the arming command itself.
   ((eq this-command 'ghostel-debug-keypress) nil)
   ;; Skip events outside the target buffer; stay armed.
   ((not (eq (current-buffer)
             (plist-get ghostel--debug-kp-state :buffer)))
    nil)
   (t
    (remove-hook 'pre-command-hook #'ghostel--debug-kp-pre-command)
    (setq ghostel--debug-kp-state
          (append (list :event last-input-event
                        :keys (this-command-keys-vector)
                        :command this-command
                        :binding (ignore-errors
                                   (key-binding (this-command-keys-vector))))
                  ghostel--debug-kp-state))
    (add-hook 'post-command-hook #'ghostel--debug-kp-post-command))))

(defun ghostel--debug-kp-post-command ()
  "After the captured command runs, render the report and tear down."
  (let ((state ghostel--debug-kp-state))
    (ghostel--debug-kp-teardown)
    (when (plist-get state :event)
      (ghostel--debug-kp-show state))))

(defun ghostel--debug-kp-teardown ()
  "Remove all advice and hooks installed by `ghostel-debug-keypress'."
  (advice-remove 'ghostel--write-pty #'ghostel--debug-kp-record-write-pty)
  (advice-remove 'ghostel--send-string #'ghostel--debug-kp-record-send-string)
  (remove-hook 'pre-command-hook #'ghostel--debug-kp-pre-command)
  (remove-hook 'post-command-hook #'ghostel--debug-kp-post-command)
  (setq ghostel--debug-kp-state nil))

(defun ghostel--debug-kp-fmt-bytes (s)
  "Format S as escaped Lisp string + length + hex dump."
  (let ((print-escape-control-characters t)
        (print-escape-newlines t))
    (format "%s  (%d bytes, hex: %s)"
            (prin1-to-string s)
            (length s)
            (mapconcat (lambda (c) (format "%02x" c)) s " "))))

(defun ghostel--debug-kp-show (state)
  "Render STATE into *ghostel-debug-keypress* and display it."
  (let* ((buf (plist-get state :buffer))
         (out (get-buffer-create "*ghostel-debug-keypress*"))
         (calls (nreverse (plist-get state :calls)))
         term proc)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq term ghostel--term
              proc ghostel--process)))
    (with-current-buffer out
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "=== ghostel-debug-keypress ===\n\n")
        ;; Event
        (insert "--- Event ---\n")
        (insert (format "Buffer:              %s\n"
                        (if (buffer-live-p buf) (buffer-name buf) "(killed)")))
        (insert (format "last-input-event:    %S\n" (plist-get state :event)))
        (insert (format "Keys vector:         %S\n" (plist-get state :keys)))
        (insert (format "Key description:     %s\n"
                        (ignore-errors
                          (key-description (plist-get state :keys)))))
        (insert (format "this-command:        %S\n" (plist-get state :command)))
        (insert (format "Resolved binding:    %S\n" (plist-get state :binding)))
        ;; Sends
        (insert "\n--- Sends during this command ---\n")
        (if (null calls)
            (insert "(no calls to ghostel--send-string or ghostel--write-pty)\n")
          (cl-loop for (kind . data) in calls
                   for i from 1
                   do (insert (format "%d. %s: %s\n"
                                      i
                                      (substring (symbol-name kind) 1)
                                      (ghostel--debug-kp-fmt-bytes data)))))
        ;; Terminal modes
        (insert "\n--- Terminal modes ---\n")
        (if term
            (let ((modes '((1    "DECCKM (cursor keys app)")
                           (66   "DECKPAM (keypad app)")
                           (1000 "Mouse X10")
                           (1002 "Mouse button-event")
                           (1003 "Mouse any-event")
                           (1004 "Focus events")
                           (1006 "Mouse SGR")
                           (1015 "Mouse urxvt")
                           (1047 "Alt screen (alt buffer)")
                           (1049 "Alt screen (cursor save)")
                           (2004 "Bracketed paste")
                           (2026 "DEC 2026 sync"))))
              (cl-loop for (id name) in modes
                       do (insert
                           (format "%-26s %s\n"
                                   (format "%s (%d):" name id)
                                   (if (ghostel--mode-enabled term id)
                                       "ON" "off")))))
          (insert "(no terminal handle)\n"))
        ;; Process
        (insert "\n--- Process ---\n")
        (cond
         ((null proc)
          (insert "Process:             nil\n"))
         ((not (process-live-p proc))
          (insert (format "Process:             dead (status: %s)\n"
                          (process-status proc))))
         (t
          (insert (format "PID:                 %s\n" (process-id proc)))
          (insert (format "Status:              %s\n" (process-status proc)))
          (insert (format "TTY:                 %s\n"
                          (or (process-tty-name proc) "(none)")))))
        (goto-char (point-min)))
      (special-mode))
    (display-buffer out)
    (message "Wrote *ghostel-debug-keypress* — paste into the issue")))


(provide 'ghostel-debug)
;;; ghostel-debug.el ends here
