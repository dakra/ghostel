;;; ghostel-taskbar-test.el --- Tests for ghostel: taskbar -*- lexical-binding: t; -*-

;;; Commentary:

;; System taskbar integration: bell hook dispatch, progress-bar
;; ownership, and attention gating.  The `system-taskbar' functions are
;; stubbed, so these tests run on any Emacs version.

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
         (ghostel-taskbar--last-progress nil)
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

;;; Bell hook (core dispatch)

(ert-deftest ghostel-test-taskbar-bell-runs-hook ()
  "`ghostel--bell' runs `ghostel-bell-functions' with the buffer current.
`ghostel-ding' is a default hook member."
  (should (memq 'ghostel-ding (default-value 'ghostel-bell-functions)))
  (let (calls)
    (with-temp-buffer
      (let ((ghostel-bell-functions
             (list (lambda () (push (current-buffer) calls)))))
        (ghostel--bell)
        (should (equal (list (current-buffer)) calls))))))

(ert-deftest ghostel-test-taskbar-bell-hook-error-isolated ()
  "An erroring bell hook member does not stop later members."
  (let (second)
    (with-temp-buffer
      (let ((ghostel-bell-functions
             (list (lambda () (error "Boom"))
                   (lambda () (setq second t)))))
        (ghostel--bell)
        (should second)))))

(ert-deftest ghostel-test-taskbar-bell-native-dispatch ()
  "BEL in the VT stream reaches `ghostel-bell-functions'."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 40 100)
    (let (calls)
      (let ((ghostel-bell-functions
             (list (lambda () (push (current-buffer) calls)))))
        (ghostel--write-vt term "\a")
        ;; The effect is deferred via a 0s timer.
        (ghostel-test--wait-until (lambda () calls) nil 1)
        (should (equal (list buf) calls))))))

;;; Progress-bar ownership

(ert-deftest ghostel-test-taskbar-progress-set-remove ()
  "`set' claims the bar and maps 0-100 to 0.0-1.0; owner `remove' clears."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (ghostel-taskbar--progress 'set 42)
      (should (equal '((progress 0.42)) calls))
      (should (eq (current-buffer) ghostel-taskbar--progress-owner))
      (ghostel-taskbar--progress 'remove nil)
      (should (equal '((progress nil) (progress 0.42)) calls))
      (should-not ghostel-taskbar--progress-owner))))

(ert-deftest ghostel-test-taskbar-progress-repeat-value-deduped ()
  "An unchanged progress value is not re-sent to the back end."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (ghostel-taskbar--progress 'set 42)
      (ghostel-taskbar--progress 'set 42)
      (should (equal '((progress 0.42)) calls))
      (ghostel-taskbar--progress 'set 43)
      (should (equal '((progress 0.43) (progress 0.42)) calls)))))

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
          (ghostel-taskbar--progress 'set 41)
          (ghostel-taskbar--progress 'set 42)
          (ghostel-taskbar--progress 'set 43)
          (should (equal nil calls))
          (should (= 1 (length queued))))
        (funcall (caar queued))
        (should (equal '((progress 0.43)) calls))))))

(ert-deftest ghostel-test-taskbar-progress-nonowner-remove-ignored ()
  "A `remove' from a buffer that does not own the bar is ignored."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (let ((owner (current-buffer)))
        (ghostel-taskbar--progress 'set 10)
        (with-temp-buffer
          (ghostel-taskbar--progress 'remove nil))
        (should (equal '((progress 0.1)) calls))
        (should (eq owner ghostel-taskbar--progress-owner))
        ;; A `set' from another buffer steals ownership.
        (with-temp-buffer
          (ghostel-taskbar--progress 'set 50)
          (should (eq (current-buffer) ghostel-taskbar--progress-owner)))
        (should (equal '((progress 0.5) (progress 0.1)) calls))))))

(ert-deftest ghostel-test-taskbar-progress-error-pause-owner-only ()
  "`error'/`pause' update the bar only from the owner and only with a value."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (ghostel-taskbar--progress 'set 10)
      (setq calls nil)
      (ghostel-taskbar--progress 'error 60)
      (should (equal '((progress 0.6)) calls))
      (setq calls nil)
      (ghostel-taskbar--progress 'pause nil)
      (should (equal nil calls))
      (with-temp-buffer
        (ghostel-taskbar--progress 'error 90))
      (should (equal nil calls)))))

(ert-deftest ghostel-test-taskbar-progress-indeterminate-clears-owner-bar ()
  "Owner `indeterminate' clears the bar; from other buffers it is inert."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      ;; Not the owner: neither draws nor claims ownership.
      (ghostel-taskbar--progress 'indeterminate nil)
      (should (equal nil calls))
      (should-not ghostel-taskbar--progress-owner)
      ;; set → indeterminate must not leave a stale percentage.
      (ghostel-taskbar--progress 'set 50)
      (ghostel-taskbar--progress 'indeterminate nil)
      (should (equal '((progress nil) (progress 0.5)) calls))
      (should (eq (current-buffer) ghostel-taskbar--progress-owner)))))

(ert-deftest ghostel-test-taskbar-progress-release ()
  "`ghostel-taskbar--release' clears only when the buffer owns the bar."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (let ((owner (current-buffer)))
        (ghostel-taskbar--progress 'set 10)
        (setq calls nil)
        (with-temp-buffer
          (ghostel-taskbar--release (current-buffer) "exit event"))
        (should (equal nil calls))
        (ghostel-taskbar--release owner)
        (should (equal '((progress nil)) calls))
        (should-not ghostel-taskbar--progress-owner)))))

(ert-deftest ghostel-test-taskbar-flush-error-keeps-cache ()
  "A back-end error in the flush is demoted and leaves the cache unset.
An identical later report is then re-sent instead of deduped
against a value that was never displayed."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (cl-letf (((symbol-function 'system-taskbar-progress)
                 (lambda (&optional _) (error "Bus gone"))))
        (ghostel-taskbar--progress 'set 42))
      (should-not ghostel-taskbar--last-progress)
      ;; Back end recovered: the same value goes through.
      (ghostel-taskbar--progress 'set 42)
      (should (equal '((progress 0.42)) calls)))))

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

(ert-deftest ghostel-test-taskbar-command-finish-releases-bar ()
  "A command finish clears a progress bar its buffer still owns."
  (ghostel-taskbar-test--with-stubs calls
    (ghostel-taskbar-test--with-focus t
      (with-temp-buffer
        (ghostel-taskbar--progress 'set 42)
        (setq calls nil)
        (ghostel-taskbar--command-finish (current-buffer) 0)
        (should (equal '((progress nil)) calls))
        (should-not ghostel-taskbar--progress-owner)))))

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
  "Only GUI frames are consulted; a tty frame's `unknown' has no veto."
  (let ((gui-frame (selected-frame))
        (tty-frame (selected-frame)))
    ;; One GUI frame (unfocused) + one tty frame (unknown): unfocused.
    (cl-letf (((symbol-function 'frame-list)
               (lambda () (list gui-frame tty-frame)))
              ((symbol-function 'display-graphic-p)
               (lambda (frame) (eq frame gui-frame)))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional frame)
                 (if (eq frame gui-frame) nil 'unknown))))
      (should-not (ghostel-taskbar--focused-p)))
    ;; GUI frame focused: focused.
    (cl-letf (((symbol-function 'frame-list)
               (lambda () (list gui-frame)))
              ((symbol-function 'display-graphic-p)
               (lambda (_frame) t))
              ((symbol-function 'frame-focus-state)
               (lambda (&optional _frame) t)))
      (should (ghostel-taskbar--focused-p)))))

;;; Mode toggling

(ert-deftest ghostel-test-taskbar-disable-clears-command-start ()
  "Disabling the mode drops recorded command start times."
  (ghostel-taskbar-test--with-stubs calls
    (with-temp-buffer
      (setq ghostel-taskbar--command-start (float-time))
      (ghostel-taskbar-mode -1)
      (should-not ghostel-taskbar--command-start))))

(provide 'ghostel-taskbar-test)

;;; ghostel-taskbar-test.el ends here
