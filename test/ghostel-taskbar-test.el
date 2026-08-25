;;; ghostel-taskbar-test.el --- Tests for ghostel: taskbar -*- lexical-binding: t; -*-

;;; Commentary:

;; System taskbar integration: progress-bar ownership and attention
;; gating.  The `system-taskbar' functions are stubbed, so these tests
;; run on any Emacs version.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-taskbar)

(defmacro ghostel-taskbar-test--with-stubs (calls &rest body)
  "Run BODY with the system-taskbar API stubbed, recording into CALLS.
CALLS collects (progress VALUE) and (attention URGENCY) entries in
call order.  `run-at-time' is stubbed synchronously so the
coalescing progress flush runs inline."
  (declare (indent 1))
  `(let ((,calls nil)
         (ghostel-taskbar--progress-owner nil)
         (ghostel-taskbar--pending-progress nil)
         (ghostel-taskbar--attention-urgency nil))
     (cl-letf (((symbol-function 'system-taskbar-progress)
                (lambda (&optional value) (push (list 'progress value) ,calls)))
               ((symbol-function 'system-taskbar-attention)
                (lambda (&optional urgency _timeout)
                  (push (list 'attention urgency) ,calls)))
               ((symbol-function 'run-at-time)
                (lambda (_secs _rep fn &rest args) (apply fn args))))
       ,@body)))

(defmacro ghostel-taskbar-test--with-focus (focused &rest body)
  "Run BODY with `ghostel-taskbar--focused-p' returning FOCUSED."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'ghostel-taskbar--focused-p)
              (lambda () ,focused)))
     ,@body))

(defun ghostel-taskbar-test--root (state &optional progress)
  "Feed a root record with STATE and PROGRESS to the taskbar status hook."
  (ghostel-taskbar--status
   "" nil (and state `(:state ,state ,@(and progress (list :progress progress))))))

;;; Progress-bar ownership

(ert-deftest ghostel-test-taskbar-progress-set-remove ()
  "A root percentage claims the bar and maps 0-100 to 0.0-1.0; removal clears."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (ghostel-taskbar-test--root 'working 42)
      (should (equal '((progress 0.42)) calls))
      (should (eq (current-buffer) ghostel-taskbar--progress-owner))
      (ghostel-taskbar-test--root nil)
      (should (equal '((progress nil) (progress 0.42)) calls))
      (should-not ghostel-taskbar--progress-owner))))

(ert-deftest ghostel-test-taskbar-progress-child-records-ignored ()
  "Records with a non-root id neither draw nor clear the bar."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (ghostel-taskbar-test--root 'working 42)
      (ghostel-taskbar--status "build" nil '(:state working :progress 10))
      (ghostel-taskbar--status "build" '(:state working :progress 10) nil)
      (should (equal '((progress 0.42)) calls))
      (should (eq (current-buffer) ghostel-taskbar--progress-owner)))))

(ert-deftest ghostel-test-taskbar-progress-flush-coalesces ()
  "Reports within one event batch collapse into a single back-end call."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      ;; Simulate batched dispatch: while the flush timer is pending,
      ;; further reports only replace the pending value.
      (let (queued)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_secs _rep fn &rest args)
                     (push (cons fn args) queued))))
          (ghostel-taskbar-test--root 'working 41)
          (ghostel-taskbar-test--root 'working 42)
          (ghostel-taskbar-test--root 'working 43)
          (should (equal nil calls))
          (should (= 1 (length queued))))
        (funcall (caar queued))
        (should (equal '((progress 0.43)) calls))))))

(ert-deftest ghostel-test-taskbar-progress-nonowner-clear-ignored ()
  "A clear from a buffer that does not own the bar is ignored."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (let ((owner (current-buffer)))
        (ghostel-taskbar-test--root 'working 10)
        (with-temp-buffer
          (ghostel-taskbar-test--root nil)
          (ghostel-taskbar-test--root 'working))
        (should (equal '((progress 0.1)) calls))
        (should (eq owner ghostel-taskbar--progress-owner))
        ;; A percentage from another buffer steals ownership.
        (with-temp-buffer
          (ghostel-taskbar-test--root 'blocked 50)
          (should (eq (current-buffer) ghostel-taskbar--progress-owner)))
        (should (equal '((progress 0.5) (progress 0.1)) calls))))))

(ert-deftest ghostel-test-taskbar-progress-no-percentage-clears-owner-bar ()
  "A root record without a percentage clears the owner's bar."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      ;; working with → without a percentage must not leave a stale bar.
      (ghostel-taskbar-test--root 'working 50)
      (ghostel-taskbar-test--root 'working)
      (should (equal '((progress nil) (progress 0.5)) calls))
      (should-not ghostel-taskbar--progress-owner))))

(ert-deftest ghostel-test-taskbar-progress-done-error-clear-bar ()
  "`done' and `error' clear the bar even with a percentage; error is critical."
  (ghostel-taskbar-test--with-stubs calls
    (ghostel-taskbar-test--with-focus nil
      (with-temp-buffer
        (ghostel-taskbar-test--root 'working 50)
        (ghostel-taskbar-test--root 'done 100)
        (should (equal '((progress nil) (progress 0.5)) calls))
        (should-not ghostel-taskbar--progress-owner)
        (setq calls nil)
        (ghostel-taskbar-test--root 'working 50)
        (ghostel-taskbar-test--root 'error 50)
        (should (equal '((attention critical) (progress nil) (progress 0.5)) calls))))))

(ert-deftest ghostel-test-taskbar-progress-release ()
  "`ghostel-taskbar--release' clears only when the buffer owns the bar."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (let ((owner (current-buffer)))
        (ghostel-taskbar-test--root 'working 10)
        (setq calls nil)
        (with-temp-buffer
          (ghostel-taskbar--release (current-buffer) "exit event"))
        (should (equal nil calls))
        (ghostel-taskbar--release owner)
        (should (equal '((progress nil)) calls))
        (should-not ghostel-taskbar--progress-owner)))))

(ert-deftest ghostel-test-taskbar-osc-progress-drives-bar ()
  "OSC 9;4 reports reach the bar through the program status model."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (let ((ghostel-program-status-functions '(ghostel-taskbar--status)))
        (ghostel--osc-progress "set" 25)
        (ghostel--osc-progress "indeterminate" nil)
        (ghostel--osc-progress "set" 75)
        (ghostel--osc-progress "remove" nil)
        (should (equal '((progress nil) (progress 0.75) (progress nil) (progress 0.25))
                       calls))))))

;;; Attention gating

(ert-deftest ghostel-test-taskbar-command-finish-attention ()
  "A long command finishing while unfocused requests attention."
  (ghostel-taskbar-test--with-stubs calls
    (ghostel-taskbar-test--with-focus nil
      (with-temp-buffer
        (setq ghostel-taskbar--command-start (- (float-time) 10))
        (ghostel-taskbar--command-finish (current-buffer) 0)
        (should (equal '((attention informational)) calls))
        (should-not ghostel-taskbar--command-start)
        ;; Non-zero exit escalates an active informational request.
        (setq calls nil
              ghostel-taskbar--command-start (- (float-time) 10))
        (ghostel-taskbar--command-finish (current-buffer) 2)
        (should (equal '((attention critical)) calls))))))

(ert-deftest ghostel-test-taskbar-command-finish-gates ()
  "Short commands, focused frames, and start-less D markers stay silent."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      ;; Shorter than the minimum duration.
      (ghostel-taskbar-test--with-focus nil
        (setq ghostel-taskbar--command-start (float-time))
        (ghostel-taskbar--command-finish (current-buffer) 0)
        ;; D without C (prompt redraw): no recorded start.
        (ghostel-taskbar--command-finish (current-buffer) 0))
      ;; Focused.
      (ghostel-taskbar-test--with-focus t
        (setq ghostel-taskbar--command-start (- (float-time) 10))
        (ghostel-taskbar--command-finish (current-buffer) 2))
      (should (equal nil calls)))))

(ert-deftest ghostel-test-taskbar-command-start-records-time ()
  "The OSC 133 C handler records a buffer-local start time."
  (with-temp-buffer
    (ghostel-taskbar--command-start (current-buffer))
    (should (< (- (float-time) ghostel-taskbar--command-start) 5))))

(ert-deftest ghostel-test-taskbar-attention-once-per-unfocused-period ()
  "Repeat attention requests are dropped until focus resets the period."
  (ghostel-taskbar-test--with-stubs calls
    (ghostel-taskbar-test--with-focus nil
      (ghostel-taskbar--alert)
      (ghostel-taskbar--alert)
      (should (equal '((attention informational)) calls))
      ;; Critical upgrades an active informational request once.
      (ghostel-taskbar--attention 'critical)
      (ghostel-taskbar--attention 'critical)
      (should (equal '((attention critical) (attention informational)) calls))
      ;; ... after which informational stays suppressed.
      (ghostel-taskbar--alert)
      (should (equal '((attention critical) (attention informational)) calls)))
    ;; Regaining focus resets the period.
    (ghostel-taskbar-test--with-focus t
      (ghostel-taskbar--focus-change))
    (should-not ghostel-taskbar--attention-urgency)
    (ghostel-taskbar-test--with-focus nil
      (setq calls nil)
      (ghostel-taskbar--alert)
      (should (equal '((attention informational)) calls)))))

(ert-deftest ghostel-test-taskbar-attention-error-keeps-period-open ()
  "A back-end error does not mark the unfocused period as requested."
  (ghostel-taskbar-test--with-stubs calls
    (ghostel-taskbar-test--with-focus nil
      (cl-letf (((symbol-function 'system-taskbar-attention)
                 (lambda (&rest _) (error "Bus gone"))))
        (ignore-errors (ghostel-taskbar--attention 'informational)))
      (should-not ghostel-taskbar--attention-urgency)
      ;; Back end recovered: the next request goes through.
      (ghostel-taskbar--alert)
      (should (equal '((attention informational)) calls)))))

(ert-deftest ghostel-test-taskbar-attention-focused-silent ()
  "Attention requests while a frame is focused are dropped."
  (ghostel-taskbar-test--with-stubs calls
    (ghostel-taskbar-test--with-focus t
      (ghostel-taskbar--alert)
      (ghostel-taskbar--attention 'critical))
    (should (equal nil calls))))

(ert-deftest ghostel-test-taskbar-focused-p-ignores-tty-frames ()
  "Only GUI frames are consulted; a tty frame's focus state has no say."
  (let (states)
    (cl-letf (((symbol-function 'frame-list) (lambda () '(gui tty)))
              ((symbol-function 'display-graphic-p) (lambda (frame) (eq frame 'gui)))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional frame) (alist-get frame states))))
      (setq states '((gui . nil) (tty . unknown)))
      (should-not (ghostel-taskbar--focused-p))
      (setq states '((gui . nil) (tty . t)))
      (should-not (ghostel-taskbar--focused-p))
      (setq states '((gui . t) (tty . nil)))
      (should (ghostel-taskbar--focused-p)))))

;;; Hook wiring and mode toggling

(ert-deftest ghostel-test-taskbar-osc133-markers-drive-attention ()
  "OSC 133 C and D reach the handlers through the shell hooks."
  (ghostel-taskbar-test--with-stubs calls
    (ghostel-taskbar-test--with-focus nil
      (with-temp-buffer
        (let ((ghostel-command-start-functions '(ghostel-taskbar--command-start))
              (ghostel-command-finish-functions '(ghostel-taskbar--command-finish)))
          (ghostel--osc133-marker "C" nil)
          (should ghostel-taskbar--command-start)
          (setq ghostel-taskbar--command-start (- (float-time) 10))
          (ghostel--osc133-marker "D" 1)
          (should (equal '((attention critical)) calls)))))))

(ert-deftest ghostel-test-taskbar-disable-releases-and-unhooks ()
  "Turning the mode off clears an owned bar and removes every hook entry."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (cl-progv (mapcar #'car ghostel-taskbar--hooks) nil
        (dolist (entry ghostel-taskbar--hooks)
          (add-hook (car entry) (cdr entry)))
        (ghostel-taskbar-test--root 'working 30)
        (setq calls nil)
        (ghostel-taskbar-mode -1)
        (should (equal '((progress nil)) calls))
        (should-not ghostel-taskbar--progress-owner)
        (dolist (entry ghostel-taskbar--hooks)
          (should-not (memq (cdr entry) (symbol-value (car entry)))))))))

(ert-deftest ghostel-test-taskbar-enable-without-backend-fails ()
  "Enabling without a usable system-taskbar signals and leaves the mode off."
  ;; Load first so the mode's own `require' cannot replace the stub.
  (require 'system-taskbar nil t)
  (let ((system-taskbar-mode nil))
    (cl-letf (((symbol-function 'system-taskbar-mode)
               (lambda (&rest _) (setq system-taskbar-mode nil))))
      (should-error (ghostel-taskbar-mode 1) :type 'user-error)
      (should-not ghostel-taskbar-mode)
      (should-not (memq #'ghostel-taskbar--status
                        ghostel-program-status-functions)))))

(provide 'ghostel-taskbar-test)

;;; ghostel-taskbar-test.el ends here
