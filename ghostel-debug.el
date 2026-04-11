;;; ghostel-debug.el --- Diagnostic logging for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.14.0
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

(declare-function ghostel--module-version "ghostel-module")
(declare-function ghostel--mode-enabled "ghostel-module")

(defvar ghostel-debug--log-buffer nil
  "Buffer used for ghostel debug logging.")

;;;###autoload
(defun ghostel-debug-start ()
  "Start logging ghostel events to *ghostel-debug* buffer.
Logs filter calls, key sends, resize events, redraw decisions
\(including DEC 2026 skip/force), and `window-start' anchoring."
  (interactive)
  (setq ghostel-debug--log-buffer (get-buffer-create "*ghostel-debug*"))
  (with-current-buffer ghostel-debug--log-buffer
    (erase-buffer)
    (insert "=== Ghostel Debug Log ===\n\n"))
  ;; Data path
  (advice-add 'ghostel--filter :before #'ghostel-debug--log-filter)
  (advice-add 'ghostel--send-key :before #'ghostel-debug--log-send)
  (advice-add 'ghostel--send-encoded :before #'ghostel-debug--log-encoded)
  ;; Render path
  (advice-add 'ghostel--delayed-redraw :around #'ghostel-debug--log-redraw)
  (advice-add 'ghostel--window-adjust-process-window-size
              :around #'ghostel-debug--log-resize)
  (when (fboundp 'ghostel--enable-vt-log)
    (ghostel--enable-vt-log))
  (message "ghostel-debug: logging started, check *ghostel-debug* buffer"))

(defun ghostel-debug-stop ()
  "Stop logging."
  (interactive)
  (advice-remove 'ghostel--filter #'ghostel-debug--log-filter)
  (advice-remove 'ghostel--send-key #'ghostel-debug--log-send)
  (advice-remove 'ghostel--send-encoded #'ghostel-debug--log-encoded)
  (advice-remove 'ghostel--delayed-redraw #'ghostel-debug--log-redraw)
  (advice-remove 'ghostel--window-adjust-process-window-size
                 #'ghostel-debug--log-resize)
  (when (fboundp 'ghostel--disable-vt-log)
    (ghostel--disable-vt-log))
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

(defun ghostel-debug--log-redraw (orig-fn buffer)
  "Log redraw decisions: skip vs execute, DEC 2026 state, timing.
ORIG-FN is `ghostel--delayed-redraw', BUFFER is the target buffer."
  (when ghostel-debug--log-buffer
    (let (sync force win-start pt buf-size)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq sync (and ghostel--term
                          (ghostel--mode-enabled ghostel--term 2026)))
          (setq force ghostel--force-next-redraw)
          (setq buf-size (buffer-size))
          (setq pt (point))
          (let ((win (get-buffer-window buffer)))
            (when win
              (setq win-start (window-start win))))))
      (let ((t0 (current-time)))
        (funcall orig-fn buffer)
        (let ((elapsed (* 1000 (float-time (time-subtract (current-time) t0))))
              pt-after win-start-after buf-size-after)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq pt-after (point))
              (setq buf-size-after (buffer-size))
              (let ((win (get-buffer-window buffer)))
                (when win
                  (setq win-start-after (window-start win))))))
          (with-current-buffer ghostel-debug--log-buffer
            (goto-char (point-max))
            (if (and sync (not force))
                (insert (format "[%s] REDRAW: SKIPPED (DEC2026 active, force=nil)\n"
                                (format-time-string "%T.%3N")))
              (insert (format "[%s] REDRAW: %.1fms force=%s dec2026=%s buf=%d→%d pt=%d→%d wstart=%s→%s\n"
                              (format-time-string "%T.%3N")
                              elapsed force sync
                              buf-size buf-size-after
                              pt pt-after
                              win-start win-start-after)))))))))

(defun ghostel-debug--log-resize (orig-fn process windows)
  "Log resize events with old/new dimensions and timing.
ORIG-FN is `ghostel--window-adjust-process-window-size'.
PROCESS and WINDOWS are passed through."
  (let* ((old-rows (when (buffer-live-p (process-buffer process))
                     (buffer-local-value 'ghostel--term-rows (process-buffer process))))
         (t0 (current-time))
         (size (funcall orig-fn process windows))
         (elapsed (* 1000 (float-time (time-subtract (current-time) t0)))))
    (when ghostel-debug--log-buffer
      (with-current-buffer ghostel-debug--log-buffer
        (goto-char (point-max))
        (insert (format "[%s] RESIZE: %sx%s → %sx%s (%.1fms)\n"
                        (format-time-string "%T.%3N")
                        (and old-rows (cdr size)) old-rows
                        (car size) (cdr size)
                        elapsed))))
    size))


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
      (erase-buffer)
      (insert "=== Ghostel Typing Latency Measurement ===\n")
      (insert (format "Type %d characters to collect measurements...\n\n" n)))
    (advice-add 'ghostel--send-key :before #'ghostel-debug--latency-on-send)
    (advice-add 'ghostel--filter :before #'ghostel-debug--latency-on-echo)
    (advice-add 'ghostel--delayed-redraw :after #'ghostel-debug--latency-on-render)
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

(defun ghostel-debug--latency-on-render (_buffer)
  "Record render-completion time and finalize latency entry."
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
  (advice-remove 'ghostel--send-key #'ghostel-debug--latency-on-send)
  (advice-remove 'ghostel--filter #'ghostel-debug--latency-on-echo)
  (advice-remove 'ghostel--delayed-redraw #'ghostel-debug--latency-on-render)
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
        (insert "\n")))
    (message "ghostel-debug: latency report ready in *ghostel-debug*")))


;;; Environment diagnostics

;;;###autoload
(defun ghostel-debug-info ()
  "Display diagnostic info about the ghostel environment.
Collects Emacs version, system info, native module state, terminal
state, and settings into *ghostel-debug* for pasting into bug reports."
  (interactive)
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
        ;; Ghostel versions
        (insert "\n--- Ghostel ---\n")
        (let* ((lib (locate-library "ghostel"))
               (dir (and lib (file-name-directory lib))))
          (insert (format "Package version:     %s\n"
                          (condition-case nil
                              (lm-version (locate-library "ghostel.el" t))
                            (error "Unknown"))))
          (insert (format "Min module version:  %s\n" ghostel--minimum-module-version))
          (insert (format "Library path:        %s\n" (or lib "not found")))
          ;; Native module
          (let ((mod-loaded (fboundp 'ghostel--module-version)))
            (insert (format "Module loaded:       %s\n" (if mod-loaded "yes" "no")))
            (when mod-loaded
              (let ((mod-ver (ghostel--module-version)))
                (insert (format "Module version:      %s\n" mod-ver))
                (unless (string= mod-ver ghostel--minimum-module-version)
                  (insert (format "  *** VERSION MISMATCH: elisp expects >= %s, module is %s ***\n"
                                  ghostel--minimum-module-version mod-ver)))))
            (when dir
              (let ((mod-file (expand-file-name
                               (concat "ghostel-module" module-file-suffix) dir)))
                (if (file-exists-p mod-file)
                    (let ((attrs (file-attributes mod-file)))
                      (insert (format "Module file:         %s\n" mod-file))
                      (insert (format "Module size:         %s bytes\n"
                                      (file-attribute-size attrs)))
                      (insert (format "Module modified:     %s\n"
                                      (format-time-string
                                       "%F %T"
                                       (file-attribute-modification-time attrs)))))
                  (insert (format "Module file:         NOT FOUND in %s\n" dir)))))))
        ;; Terminal state
        (insert "\n--- Terminal State ---\n")
        (if ghostel-buf
            (let (info)
              (with-current-buffer ghostel-buf
                (setq info
                      (list :buffer (buffer-name)
                            :rows ghostel--term-rows
                            :buf-size (buffer-size)
                            :buf-lines (count-lines (point-min) (point-max))
                            :point (point)
                            :term ghostel--term
                            :force ghostel--force-next-redraw
                            :pending (length ghostel--pending-output)
                            :timer (and ghostel--redraw-timer t)
                            :input-mode ghostel--input-mode
                            :dec2026 (and ghostel--term
                                          (ghostel--mode-enabled ghostel--term 2026))))
                (let ((win (get-buffer-window ghostel-buf)))
                  (when win
                    (setq info (plist-put info :win-w (window-body-width win)))
                    (setq info (plist-put info :win-h (window-body-height win)))
                    (setq info (plist-put info :win-start (window-start win)))
                    (setq info (plist-put info :win-end (window-end win t))))))
              (insert (format "Buffer:              %s\n" (plist-get info :buffer)))
              (insert (format "Term rows:           %s\n" (plist-get info :rows)))
              (insert (format "Buffer size:         %d chars, %d lines\n"
                              (plist-get info :buf-size) (plist-get info :buf-lines)))
              (insert (format "Point:               %d\n" (plist-get info :point)))
              (if (plist-get info :win-w)
                  (progn
                    (insert (format "Window body:         %dx%d (cols x rows)\n"
                                    (plist-get info :win-w) (plist-get info :win-h)))
                    (insert (format "Window start:        %d\n" (plist-get info :win-start)))
                    (insert (format "Window end:          %d\n" (plist-get info :win-end))))
                (insert "Window:              not displayed\n"))
              (if (plist-get info :term)
                  (progn
                    (insert (format "DEC 2026 (sync):     %s\n"
                                    (if (plist-get info :dec2026) "ACTIVE" "off")))
                    (insert (format "Force next redraw:   %s\n" (plist-get info :force)))
                    (insert (format "Pending output:      %s chunks\n" (plist-get info :pending)))
                    (insert (format "Redraw timer:        %s\n"
                                    (if (plist-get info :timer) "pending" "none")))
                    (insert (format "Copy mode:           %s\n"
                                    (if (plist-get info :copy) "active" "off"))))
                (insert "Term handle:         nil (no terminal)\n")))
          (insert "(not in a ghostel buffer)\n"))
        ;; Settings
        (insert "\n--- Settings ---\n")
        (insert (format "timer-delay:         %s\n" ghostel-timer-delay))
        (insert (format "full-redraw:         %s\n" ghostel-full-redraw))
        (insert (format "adaptive-fps:        %s\n" ghostel-adaptive-fps))
        (insert (format "immediate-threshold: %s\n" ghostel-immediate-redraw-threshold))
        (insert (format "immediate-interval:  %s\n" ghostel-immediate-redraw-interval))
        (insert (format "scroll-conservatively: %s\n"
                        (if ghostel-buf
                            (buffer-local-value 'scroll-conservatively ghostel-buf)
                          scroll-conservatively)))))
    (display-buffer out)
    (message "Debug info written to *ghostel-debug*")))

(provide 'ghostel-debug)
;;; ghostel-debug.el ends here
