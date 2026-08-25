;;; ghostel-taskbar.el --- System taskbar integration for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Surface ghostel terminal activity on the system taskbar (Dock,
;; launcher) via Emacs 31's `system-taskbar':
;;
;; - ConEmu OSC 9;4 progress reports become a progress bar on the
;;   Emacs taskbar icon.  The taskbar is global, so the bar tracks a
;;   single owner: the last terminal to report determinate progress.
;;   The bar is also cleared when the owning terminal's command
;;   finishes, exits, or its buffer is killed, so a program that stops
;;   reporting cannot leave the icon stuck at a stale percentage.
;; - When a shell command that ran for at least
;;   `ghostel-taskbar-attention-min-duration' seconds finishes while
;;   no Emacs frame has focus, the taskbar icon requests attention
;;   (`critical' when the command failed).  Requires OSC 133 shell
;;   integration.
;; - OSC 9 / OSC 777 desktop notifications and the terminal bell also
;;   request attention while Emacs is unfocused.  At most one request
;;   is issued per unfocused period (`critical' upgrades an active
;;   `informational' request).
;;
;; Enable with `ghostel-taskbar-mode'.  Requires Emacs 31 on a
;; supported window system (macOS, MS-Windows, or a launcher
;; implementing the Unity D-Bus spec — see `system-taskbar').

;;; Code:

(require 'seq)
(require 'ghostel)

(declare-function system-taskbar-mode "system-taskbar")
(declare-function system-taskbar-progress "system-taskbar")
(declare-function system-taskbar-attention "system-taskbar")
(defvar system-taskbar-mode)

(defgroup ghostel-taskbar nil
  "System taskbar integration for ghostel."
  :group 'ghostel)

(defcustom ghostel-taskbar-attention-min-duration 5
  "Seconds a command must run before its finish requests attention.
Command finishes while an Emacs frame is focused never request
attention, regardless of duration."
  :type 'number)

(defvar ghostel-taskbar--progress-owner nil
  "Terminal buffer currently owning the taskbar progress bar, or nil.")

(defvar ghostel-taskbar--last-progress nil
  "Progress value last successfully sent to the taskbar, or nil.")

(defvar ghostel-taskbar--pending-progress nil
  "Cons holding the progress value awaiting the coalescing flush, or nil.")

(defvar ghostel-taskbar--attention-urgency nil
  "Urgency of the attention request active this unfocused period, or nil.")

(defvar-local ghostel-taskbar--command-start nil
  "`float-time' of the running command's OSC 133 C marker, or nil.")

(defun ghostel-taskbar--focused-p ()
  "Return non-nil when a GUI frame has (or may have) focus.
Only GUI frames are consulted: the taskbar exists only for them,
and a tty frame without focus reporting answers `unknown', which
must not permanently veto attention.  `unknown' on a GUI frame
counts as focused to avoid spurious requests."
  (seq-some (lambda (frame)
              (and (display-graphic-p frame)
                   (memq (frame-focus-state frame) '(t unknown))))
            (frame-list)))

(defun ghostel-taskbar--send-progress (value)
  "Send VALUE to the taskbar via a coalescing 0s timer.
Multiple reports within one event batch collapse into the last
one, keeping back-end calls (Dock redraw, D-Bus send) off the
terminal event dispatch path."
  (if ghostel-taskbar--pending-progress
      (setcar ghostel-taskbar--pending-progress value)
    (setq ghostel-taskbar--pending-progress (cons value nil))
    (run-at-time 0 nil #'ghostel-taskbar--flush-progress)))

(defun ghostel-taskbar--flush-progress ()
  "Send the pending progress value unless it is unchanged.
Errors are demoted, and the sent-value cache updates only after a
successful call, so a transient back-end error (e.g. a vanished
D-Bus session) does not suppress an identical later report."
  (let ((value (car ghostel-taskbar--pending-progress)))
    (setq ghostel-taskbar--pending-progress nil)
    (unless (eql value ghostel-taskbar--last-progress)
      (with-demoted-errors "ghostel-taskbar: %S"
        (system-taskbar-progress value)
        (setq ghostel-taskbar--last-progress value)))))

(defun ghostel-taskbar--progress (state progress)
  "Mirror the current terminal's OSC 9;4 STATE/PROGRESS on the taskbar icon.
Only the owner buffer may update or clear the bar; a `set' report
takes ownership.  `indeterminate' clears the owner's bar — the
taskbar API has no indeterminate state, and a stale percentage
must not survive a determinate→indeterminate switch."
  (pcase state
    ('set
     (setq ghostel-taskbar--progress-owner (current-buffer))
     (ghostel-taskbar--send-progress (/ (or progress 0) 100.0)))
    ((or 'error 'pause)
     (when (and (eq (current-buffer) ghostel-taskbar--progress-owner) progress)
       (ghostel-taskbar--send-progress (/ progress 100.0))))
    ('indeterminate
     (when (eq (current-buffer) ghostel-taskbar--progress-owner)
       (ghostel-taskbar--send-progress nil)))
    ('remove
     (ghostel-taskbar--release))))

(defun ghostel-taskbar--release (&optional buffer &rest _)
  "Clear the taskbar progress bar when BUFFER (default current) owns it."
  (when (eq (or buffer (current-buffer)) ghostel-taskbar--progress-owner)
    (setq ghostel-taskbar--progress-owner nil)
    (ghostel-taskbar--send-progress nil)))

(defun ghostel-taskbar--attention (urgency)
  "Request URGENCY attention, at most once per unfocused period.
No-op while a frame is focused; `critical' upgrades an active
`informational' request.  The period state updates only after a
successful back-end call, so a transient error does not mute the
rest of the period."
  (unless (or (ghostel-taskbar--focused-p)
              (eq ghostel-taskbar--attention-urgency 'critical)
              (eq ghostel-taskbar--attention-urgency urgency))
    (system-taskbar-attention urgency)
    (setq ghostel-taskbar--attention-urgency urgency)))

(defun ghostel-taskbar--focus-change ()
  "Reset the per-unfocused-period attention state on regained focus."
  (when (and ghostel-taskbar--attention-urgency
             (ghostel-taskbar--focused-p))
    (setq ghostel-taskbar--attention-urgency nil)))

(defun ghostel-taskbar--command-start (buffer)
  "Record the command start time in BUFFER."
  (with-current-buffer buffer
    (setq ghostel-taskbar--command-start (float-time))))

(defun ghostel-taskbar--command-finish (buffer status)
  "Handle a command finishing in BUFFER with exit STATUS.
Releases a progress bar BUFFER still owns — a command that died
without an OSC 9;4 remove must not leave the icon stuck — and
requests attention for long-running commands."
  (ghostel-taskbar--release buffer)
  (with-current-buffer buffer
    (let ((start ghostel-taskbar--command-start))
      (setq ghostel-taskbar--command-start nil)
      (when (and start
                 (>= (- (float-time) start)
                     ghostel-taskbar-attention-min-duration))
        (ghostel-taskbar--attention
         (if (and (integerp status) (/= status 0)) 'critical 'informational))))))

(defun ghostel-taskbar--alert (&rest _)
  "Request `informational' attention; adapter for bell/notification hooks."
  (ghostel-taskbar--attention 'informational))

(defvar ghostel-taskbar--system-mode-enabled nil
  "Non-nil when `ghostel-taskbar-mode' turned on `system-taskbar-mode'.")

(defconst ghostel-taskbar--hooks
  '((ghostel-progress-functions        . ghostel-taskbar--progress)
    (ghostel-command-start-functions   . ghostel-taskbar--command-start)
    (ghostel-command-finish-functions  . ghostel-taskbar--command-finish)
    (ghostel-notification-functions    . ghostel-taskbar--alert)
    (ghostel-bell-functions            . ghostel-taskbar--alert)
    (ghostel-exit-functions            . ghostel-taskbar--release)
    (kill-buffer-hook                  . ghostel-taskbar--release))
  "Hook subscriptions (HOOK . FUNCTION) managed by `ghostel-taskbar-mode'.")

;;;###autoload
(define-minor-mode ghostel-taskbar-mode
  "Mirror ghostel progress and alerts on the system taskbar icon.
Requires Emacs 31's `system-taskbar', which is enabled if needed."
  :global t
  (if ghostel-taskbar-mode
      (condition-case err
          (progn
            (unless (require 'system-taskbar nil t)
              (user-error "`ghostel-taskbar-mode' requires Emacs 31's system-taskbar"))
            (unless system-taskbar-mode
              (system-taskbar-mode 1)
              ;; `system-taskbar-mode' resets its variable when no
              ;; back end could be initialized.
              (unless system-taskbar-mode
                (user-error "`system-taskbar-mode' could not be initialized"))
              (setq ghostel-taskbar--system-mode-enabled t))
            (dolist (entry ghostel-taskbar--hooks)
              (add-hook (car entry) (cdr entry)))
            (add-function :after after-focus-change-function
                          #'ghostel-taskbar--focus-change))
        (error
         (setq ghostel-taskbar-mode nil)
         (signal (car err) (cdr err))))
    (dolist (entry ghostel-taskbar--hooks)
      (remove-hook (car entry) (cdr entry)))
    (remove-function after-focus-change-function
                     #'ghostel-taskbar--focus-change)
    (when ghostel-taskbar--progress-owner
      (ghostel-taskbar--release ghostel-taskbar--progress-owner))
    (setq ghostel-taskbar--attention-urgency nil)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (kill-local-variable 'ghostel-taskbar--command-start)))
    (when ghostel-taskbar--system-mode-enabled
      (setq ghostel-taskbar--system-mode-enabled nil)
      (system-taskbar-mode -1))))

(provide 'ghostel-taskbar)

;;; ghostel-taskbar.el ends here
