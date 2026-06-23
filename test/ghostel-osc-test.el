;;; ghostel-osc-test.el --- Tests for ghostel: osc -*- lexical-binding: t; -*-

;;; Commentary:

;; OSC 4/9/10/11/51/52/777 handling, color queries, progress / notification
;; dispatch, spinners.  OSC 8 hyperlink behavior lives in `ghostel-links-test'.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-osc52 ()
  "Test OSC 52 clipboard handling."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      ;; With osc52 disabled, kill ring should not be modified.
      (let ((ghostel-enable-osc52 nil)
            (kill-ring nil))
        (ghostel--write-pty ghostel--term
                            "\e]52;c;aGVsbG8=\e\\GHOSTEL_OSC52_DISABLED_DRAIN")
        (ghostel-test--wait-for-text "GHOSTEL_OSC52_DISABLED_DRAIN" proc 5)
        (should (equal nil kill-ring)))

      ;; With osc52 enabled, text should appear in kill ring.
      (let ((ghostel-enable-osc52 t)
            (kill-ring nil))
        (ghostel--write-pty ghostel--term "\e]52;c;aGVsbG8=\e\\")
        (ghostel-test--wait-until (lambda () kill-ring) proc 5)
        (should (equal "hello" (car kill-ring))))

      ;; BEL terminator.
      (let ((ghostel-enable-osc52 t)
            (kill-ring nil))
        (ghostel--write-pty ghostel--term "\e]52;c;d29ybGQ=\a")
        (ghostel-test--wait-until (lambda () kill-ring) proc 5)
        (should (equal "world" (car kill-ring))))

      ;; Query ('?') should be ignored.
      (let ((ghostel-enable-osc52 t)
            (kill-ring nil))
        (ghostel--write-pty ghostel--term
                            "\e]52;c;?\e\\GHOSTEL_OSC52_QUERY_DRAIN")
        (ghostel-test--wait-for-text "GHOSTEL_OSC52_QUERY_DRAIN" proc 5)
        (should (equal nil kill-ring))))))

(ert-deftest ghostel-test-osc9-notification ()
  "OSC 9 iTerm2-style notifications reach `ghostel-notification-function'."
  :tags '(native)
  (ghostel-test--with-pty-matrix
      backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let* ((calls nil)
             (ghostel-notification-function
              (lambda (title body) (push (cons title body) calls))))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_secs _rep fn &rest args) (apply fn args))))
          ;; Plain iTerm2 notification, ST terminator.
          (ghostel--write-pty ghostel--term "\e]9;Hello world\e\\")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("" . "Hello world")) calls))

          ;; BEL terminator
          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]9;bell form\a")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("" . "bell form")) calls))

          ;; Single-character body
          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]9;X\e\\")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("" . "X")) calls))

          ;; Empty payload is dropped at the handler — the elisp default
          ;; notifier would just show the buffer name with an empty body,
          ;; so there's nothing useful to dispatch.
          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]9;\e\\GHOSTEL_OSC9_EMPTY_DRAIN")
          (ghostel-test--wait-for-text "GHOSTEL_OSC9_EMPTY_DRAIN" proc 5)
          (should (equal nil calls)))))))

(ert-deftest ghostel-test-osc9-conemu-suppressed ()
  "ConEmu OSC 9 sub-codes must not fire a notification.
Covers the forms that ghostty-vt's parser accepts as valid ConEmu
sequences (sleep, message box, tab title, wait input, emulation
mode, prompt start).  Payloads that ghostty-vt rejects fall through
to the notification path — see `ghostel-test-osc9-invalid-conemu-notifies'."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let (calls)
        (cl-letf (((symbol-function 'ghostel--handle-notification)
                   (lambda (title body) (push (cons title body) calls)))
                  ((symbol-function 'ghostel--osc-progress)
                   (lambda (_s _p) nil)))
          ;; 9;1;<ms> sleep, 9;2;<msg> message box, 9;3;<title> tab title.
          (ghostel--write-pty ghostel--term "\e]9;1;500\e\\")
          (ghostel--write-pty ghostel--term "\e]9;2;hello\e\\")
          (ghostel--write-pty ghostel--term "\e]9;3;tab\e\\")
          ;; 9;5 wait-input, 9;12 prompt start.
          (ghostel--write-pty ghostel--term "\e]9;5\e\\")
          (ghostel--write-pty ghostel--term "\e]9;12\e\\")
          ;; 9;10 xterm emulation — bare and with valid args 0-3.
          (ghostel--write-pty ghostel--term "\e]9;10\e\\")
          (ghostel--write-pty ghostel--term "\e]9;10;0\e\\")
          (ghostel--write-pty ghostel--term "\e]9;10;3\e\\")
          ;; Trailing bytes after a valid first-arg digit are tolerated
          ;; (matches ghostty-vt).
          (ghostel--write-pty ghostel--term "\e]9;10;01\e\\")
          (ghostel--write-pty ghostel--term
                              "\e]9;10;3x\e\\GHOSTEL_OSC9_CONEMU_DRAIN")
          (ghostel-test--wait-for-text "GHOSTEL_OSC9_CONEMU_DRAIN" proc 5)
          (should (equal nil calls)))))))

(ert-deftest ghostel-test-osc9-invalid-conemu-notifies ()
  "Malformed ConEmu payloads fall through to notification.
Mirrors ghostty-vt's parser: e.g. `9;10;4' and `9;10;abc' are
invalid emulation args and surface as notifications with the raw
payload as body.

Note: `9;5' and `9;12' are accepted as ConEmu wait-input / mark
prompt-start regardless of trailing bytes (ghostty's parser does
not require the bare form).  That means a notification body that
starts with `5 ' or `12 ' is now lost — pre-refactor we had a
defensive carve-out that fell back to the iTerm2 path, but with
the handler-based dispatch we trust ghostty's parser as the
authority for OSC 9 disambiguation."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let (calls)
        (cl-letf (((symbol-function 'ghostel--handle-notification)
                   (lambda (title body) (push (cons title body) calls)))
                  ((symbol-function 'ghostel--osc-progress)
                   (lambda (_s _p) nil)))
          (ghostel--write-pty ghostel--term "\e]9;10;4\e\\")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("" . "10;4")) calls))

          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]9;10;\e\\")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("" . "10;")) calls))

          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]9;10;abc\e\\")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("" . "10;abc")) calls)))))))

(ert-deftest ghostel-test-osc9-cwd-routing ()
  "OSC 9;9;PATH updates the buffer-local working-directory report.
ConEmu's CWD-reporting alias uses the same callback as OSC 7, so
`ghostel--last-directory' records the reported path and no notification fires."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let (notifs)
        (cl-letf (((symbol-function 'ghostel--handle-notification)
                   (lambda (title body) (push (cons title body) notifs))))
          (ghostel--write-pty ghostel--term "\e]9;9;/tmp/ghostel-cwd\e\\")
          (ghostel-test--wait-until
           (lambda () (equal "/tmp/ghostel-cwd" ghostel--last-directory))
           proc 5)
          (should (equal nil notifs)))))))

(ert-deftest ghostel-test-osc9-progress ()
  "OSC 9;4 progress reports reach `ghostel-progress-function'."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let* ((calls nil)
             (ghostel-progress-function
              (lambda (state progress) (push (list state progress) calls))))
        (pcase-dolist (`(,payload ,expected)
                       '(("\e]9;4;1;50\e\\" (set 50))
                         ("\e]9;4;1\e\\" (set 0))
                         ("\e]9;4;0\e\\" (remove nil))
                         ("\e]9;4;0;100\e\\" (remove nil))
                         ("\e]9;4;2\e\\" (error nil))
                         ("\e]9;4;2;73\e\\" (error 73))
                         ("\e]9;4;3\e\\" (indeterminate nil))
                         ("\e]9;4;3;50\e\\" (indeterminate nil))
                         ("\e]9;4;4;25\e\\" (pause 25))
                         ("\e]9;4;0;\e\\" (remove nil))
                         ("\e]9;4;1;999\e\\" (set 100))
                         ("\e]9;4;1;99999999999\e\\" (set 100))
                         ("\e]9;4;1;foo\e\\" (set nil))
                         ("\e]9;4;2;foo\e\\" (error nil))))
          (setq calls nil)
          (ghostel--write-pty ghostel--term payload)
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal (list expected) calls)))))))

(ert-deftest ghostel-test-osc-progress-dispatch ()
  "`ghostel--osc-progress' converts the state string to a symbol."
  (let ((calls nil))
    (let ((ghostel-progress-function
           (lambda (state progress) (push (list state progress) calls))))
      (ghostel--osc-progress "set" 42)
      (should (equal '((set 42)) calls))
      (setq calls nil)
      (ghostel--osc-progress "remove" nil)
      (should (equal '((remove nil)) calls))
      ;; Unknown state strings are dropped without invoking the handler
      ;; (defends against a Zig-side typo polluting the obarray).
      ;; `calls' is populated only by `ghostel-progress-function', so
      ;; asserting it stayed nil proves the sink was not invoked.
      (setq calls nil)
      (should-not (ghostel--osc-progress "bogus" 1))
      (should (equal nil calls)))
    ;; nil function → no call, no error
    (let ((ghostel-progress-function nil))
      (should-not (ghostel--osc-progress "set" 10)))))

(ert-deftest ghostel-test-osc777-notification ()
  "OSC 777 `notify;TITLE;BODY' reaches `ghostel-notification-function'."
  :tags '(native)
  (ghostel-test--with-pty-matrix
      backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let (calls)
        (cl-letf (((symbol-function 'ghostel--handle-notification)
                   (lambda (title body) (push (cons title body) calls))))
          (ghostel--write-pty ghostel--term "\e]777;notify;Subject;Body text\e\\")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("Subject" . "Body text")) calls))

          ;; BEL terminator
          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]777;notify;T;B\a")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("T" . "B")) calls))

          ;; Empty title AND empty body is dropped at the handler — same
          ;; rule as OSC 9 (the elisp default notifier has nothing useful
          ;; to show).  Non-empty title or body still dispatches.
          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]777;notify;;\e\\GHOSTEL_OSC777_EMPTY_DRAIN")
          (ghostel-test--wait-for-text "GHOSTEL_OSC777_EMPTY_DRAIN" proc 5)
          (should (equal nil calls))

          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]777;notify;T;\e\\")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("T" . "")) calls))

          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]777;notify;;B\e\\")
          (ghostel-test--wait-until (lambda () calls) proc 5)
          (should (equal '(("" . "B")) calls))

          ;; Unknown extension is dropped
          (setq calls nil)
          (ghostel--write-pty ghostel--term "\e]777;bogus;a;b\e\\GHOSTEL_OSC777_BOGUS_DRAIN")
          (ghostel-test--wait-for-text "GHOSTEL_OSC777_BOGUS_DRAIN" proc 5)
          (should (equal nil calls)))))))

(ert-deftest ghostel-test-notification-dispatch ()
  "`ghostel--handle-notification' honours `ghostel-notification-function'.
`run-at-time' is stubbed synchronously since the dispatcher defers
the handler off the VT-parser callpath."
  (cl-letf (((symbol-function 'run-at-time)
             (lambda (_secs _rep fn &rest args) (apply fn args))))
    (let ((calls nil))
      (let ((ghostel-notification-function
             (lambda (title body) (push (cons title body) calls))))
        (ghostel--handle-notification "T" "B")
        (should (equal '(("T" . "B")) calls)))
      ;; nil → silently ignored: returns nil and does not signal.
      (let ((ghostel-notification-function nil))
        (should-not (condition-case _
                        (progn (ghostel--handle-notification "T" "B") nil)
                      (error t))))
      ;; Error in handler is demoted to message (does not propagate)
      (let ((ghostel-notification-function (lambda (_t _b) (error "Boom")))
            (inhibit-message t)
            (debug-on-error nil))
        (should-not (condition-case _
                        (progn (ghostel--handle-notification "T" "B") nil)
                      (error t)))))))

(ert-deftest ghostel-test-notification-dispatch-current-buffer ()
  "Dispatcher re-enters the originating buffer before calling the handler.
Even if the user has switched to a different buffer by the time
the deferred timer fires, the handler sees the ghostel buffer
that emitted the escape as `current-buffer'."
  (cl-letf (((symbol-function 'run-at-time)
             (lambda (_secs _rep fn &rest args)
               ;; Simulate the timer firing later, from a different
               ;; buffer.
               (with-temp-buffer
                 (rename-buffer " *unrelated*" t)
                 (apply fn args)))))
    (let ((captured-name nil))
      (with-temp-buffer
        (rename-buffer "*ghostel: origin*" t)
        (let ((ghostel-notification-function
               (lambda (_title _body) (setq captured-name (buffer-name)))))
          (ghostel--handle-notification "" "hi")
          (should (equal captured-name "*ghostel: origin*")))))))

(ert-deftest ghostel-test-notification-dispatch-real-timer ()
  "Async path runs end-to-end through a real `run-at-time'.
Every other dispatcher test stubs `run-at-time' synchronously, so
the closure capture, `buffer-live-p' guard, `with-current-buffer'
re-entry, and `condition-case' all go uncovered unless this test
actually yields the event loop and observes the delayed side effect."
  (let ((captured nil))
    (with-temp-buffer
      (rename-buffer "*ghostel: real-timer*" t)
      (let ((ghostel-notification-function
             (lambda (title body)
               (push (list title body (buffer-name)) captured))))
        (ghostel--handle-notification "T" "B")
        ;; Not fired yet — still scheduled.
        (should (equal nil captured))
        ;; Let the 0s timer run.  `sit-for' yields even in batch mode,
        ;; which triggers pending `run-at-time 0 nil ...' callbacks.
        (with-timeout (1.0 (error "Timer never fired"))
          (while (null captured) (sit-for 0.01)))
        (should (equal '(("T" "B" "*ghostel: real-timer*")) captured))))))

(ert-deftest ghostel-test-notification-dispatch-buffer-killed ()
  "Drop notifications whose originating buffer died before timer firing.
Uses a second notification from a live buffer as a positive
control so we can wait on *something* and then assert the
killed-buffer one did not fire."
  (let ((dead-fired nil)
        (live-fired nil))
    (let* ((dead (generate-new-buffer " *ghostel-test-killed*")))
      (let ((ghostel-notification-function
             (lambda (_t _b) (setq dead-fired t))))
        (with-current-buffer dead
          (ghostel--handle-notification "D" "D")))
      (kill-buffer dead))
    (with-temp-buffer
      (rename-buffer " *ghostel-test-live*" t)
      (let ((ghostel-notification-function
             (lambda (_t _b) (setq live-fired t))))
        (ghostel--handle-notification "L" "L")
        (with-timeout (1.0 (error "Live timer never fired"))
          (while (null live-fired) (sit-for 0.01)))))
    (should live-fired)
    (should (equal nil dead-fired))))

(ert-deftest ghostel-test-osc-progress-dispatch-error-isolated ()
  "Errors in `ghostel-progress-function' are caught and demoted."
  (let ((ghostel-progress-function (lambda (_s _p) (error "Boom")))
        (inhibit-message t)
        (debug-on-error nil))
    (should-not (condition-case _
                    (progn (ghostel--osc-progress "set" 10) nil)
                  (error t)))))

(ert-deftest ghostel-test-default-notify-uses-alert ()
  "Route notifications through `alert' when the package is available.
`alert' is pre-provided so the branch fires under batch mode
without the real package installed.  Also verifies that
`ghostel-notification-function' is wired to `ghostel-default-notify'
by default, so a notification arriving through the dispatcher ends
up at the alert backend."
  (provide 'alert)
  (let ((captured nil))
    (cl-letf (((symbol-function 'alert)
               (lambda (msg &rest kw) (setq captured (cons msg kw)))))
      (ghostel-default-notify "Title" "body text")
      (should captured)
      (should (equal (car captured) "body text"))
      (should (equal (plist-get (cdr captured) :title) "Title"))

      ;; Wiring: the dispatcher's default sink is `ghostel-default-notify',
      ;; so going through `ghostel--handle-notification' must also hit the
      ;; alert mock.  `run-at-time' is stubbed synchronous.
      (setq captured nil)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_secs _rep fn &rest args) (apply fn args))))
        (should (eq ghostel-notification-function #'ghostel-default-notify))
        (ghostel--handle-notification "Wired" "via dispatch")
        (should captured)
        (should (equal (car captured) "via dispatch"))
        (should (equal (plist-get (cdr captured) :title) "Wired"))))))

(ert-deftest ghostel-test-default-notify-empty-title-uses-buffer-name ()
  "When TITLE is empty, the alert uses the current buffer's name."
  (provide 'alert)
  (let ((captured nil))
    (cl-letf (((symbol-function 'alert)
               (lambda (msg &rest kw) (setq captured (cons msg kw)))))
      (with-temp-buffer
        (rename-buffer "*ghostel: zsh*" t)
        (ghostel-default-notify "" "hi")
        (should (equal (plist-get (cdr captured) :title) (buffer-name)))))))

(ert-deftest ghostel-test-default-progress-modeline ()
  "`ghostel-default-progress' sets `mode-line-process' per state."
  (with-temp-buffer
    (ghostel-default-progress 'set 42)
    (should (equal " [42%]" mode-line-process))
    (ghostel-default-progress 'indeterminate nil)
    (should (equal " [...]" mode-line-process))
    (ghostel-default-progress 'pause 10)
    (should (equal " [paused 10%]" mode-line-process))
    (ghostel-default-progress 'pause nil)
    (should (equal " [paused]" mode-line-process))
    (ghostel-default-progress 'error 99)
    (should (string-match-p "\\[err 99%\\]" mode-line-process))
    (ghostel-default-progress 'remove nil)
    (should (null mode-line-process))))

(ert-deftest ghostel-test-spinner-progress-errors-without-spinner ()
  "`ghostel-spinner-progress' signals a user-error when spinner.el is absent.
Stubs `require' to refuse loading `spinner' so the test does not depend on
whether spinner.el is actually installed in the test env.

FIXME: stubbing `require' is fragile — a stronger test would
exercise the real no-spinner path (e.g. via a sandboxed `load-path'
with no spinner.el available).  The stub currently matches reality
\(returns nil for `(require 'spinner nil t)' when absent), but a
future refactor of the require call would silently invalidate it."
  (cl-letf* ((orig-require (symbol-function #'require))
             ((symbol-function #'require)
                 (lambda (feature &optional filename noerror)
                   (if (eq feature 'spinner)
                       (if noerror nil
                         (signal 'file-missing (list "stub-no-spinner")))
                     (funcall orig-require feature filename noerror)))))
    (with-temp-buffer
      (should-error (ghostel-spinner-progress 'indeterminate nil)
                    :type 'user-error))))

(ert-deftest ghostel-test-spinner-progress-indeterminate-starts-once ()
  "`ghostel-spinner-progress' starts the spinner once across repeat events.
Multiple `indeterminate' events during one working phase must not stack
spinners — claude-code emits transitions repeatedly.  Verifies that
`spinner-start' is called with the configured TYPE symbol (which is the
form that installs spinner.el's mode-line construct) and that
`ghostel--spinner-active' tracks the started/stopped state."
  (let ((start-calls 0)
        (start-args nil))
    (cl-letf (((symbol-function #'require)
               (lambda (&rest _) t))
              ((symbol-function #'spinner-start)
                 (lambda (&rest args)
                   (cl-incf start-calls)
                   (setq start-args args)))
              ((symbol-function #'spinner-stop) #'ignore))
      (with-temp-buffer
        (ghostel-spinner-progress 'indeterminate nil)
        (ghostel-spinner-progress 'indeterminate nil)
        (should (= 1 start-calls))
        (should (equal (list ghostel-spinner-type) start-args))
        (should ghostel--spinner-active)))))

(ert-deftest ghostel-test-spinner-progress-set-stops-and-shows-percent ()
  "On `set', the spinner is stopped and `mode-line-process' is the percent text.
Without the explicit stop, spinner.el's mode-line construct would
remain (rendering empty alongside the percentage)."
  (let ((stop-calls 0))
    (cl-letf (((symbol-function #'require)
               (lambda (&rest _) t))
              ((symbol-function #'spinner-start) #'ignore)
              ((symbol-function #'spinner-stop)
                 (lambda (&rest _) (cl-incf stop-calls))))
      (with-temp-buffer
        (ghostel-spinner-progress 'indeterminate nil)
        (ghostel-spinner-progress 'set 50)
        (should (= 1 stop-calls))
        (should-not ghostel--spinner-active)
        (should (equal " [50%]" mode-line-process))))))

(ert-deftest ghostel-test-spinner-progress-remove-clears-modeline ()
  "On `remove', the spinner stops and `mode-line-process' is nil."
  (cl-letf (((symbol-function #'require)
             (lambda (&rest _) t))
            ((symbol-function #'spinner-start) #'ignore)
            ((symbol-function #'spinner-stop) #'ignore))
    (with-temp-buffer
      (ghostel-spinner-progress 'indeterminate nil)
      (ghostel-spinner-progress 'remove nil)
      (should-not ghostel--spinner-active)
      (should (null mode-line-process)))))

(ert-deftest ghostel-test-spinner-stop-helper-clears-state ()
  "`ghostel--spinner-stop' calls `spinner-stop' and clears the active flag.
The sentinel relies on this helper to drop a live spinner when the shell
exits, so a regression here would leak the timer past the buffer's life."
  (let ((stop-calls 0))
    (cl-letf (((symbol-function #'spinner-stop)
               (lambda (&rest _) (cl-incf stop-calls))))
      (with-temp-buffer
        (setq ghostel--spinner-active t)
        (ghostel--spinner-stop)
        (should (= 1 stop-calls))
        (should-not ghostel--spinner-active)
        ;; Idempotent: a second call is a no-op.
        (ghostel--spinner-stop)
        (should (= 1 stop-calls))))))

(ert-deftest ghostel-test-progress-preserves-input-mode-tag ()
  "Progress updates compose with the input-mode tag in `mode-line-process'."
  (with-temp-buffer
    (setq ghostel--mode-line-tag ":Line")
    (ghostel--mode-line-refresh)
    (should (equal ":Line" mode-line-process))
    (ghostel-default-progress 'set 42)
    (should (equal '(":Line" " [42%]") mode-line-process))
    (ghostel-default-progress 'remove nil)
    (should (equal ":Line" mode-line-process))))

(ert-deftest ghostel-test-spinner-preserves-input-mode-tag ()
  "Spinner transitions preserve `ghostel--mode-line-tag'.
The composed `mode-line-process' must list both the tag and the
spinner construct so the input-mode label keeps rendering while
the spinner is active."
  (cl-letf (((symbol-function #'require)
             (lambda (&rest _) t))
            ((symbol-function #'spinner-start) #'ignore)
            ((symbol-function #'spinner-stop) #'ignore))
    (with-temp-buffer
      (setq ghostel--mode-line-tag ":Char")
      (ghostel--mode-line-refresh)
      (should (equal ":Char" mode-line-process))
      (ghostel-spinner-progress 'indeterminate nil)
      (should (equal '(":Char" spinner--mode-line-construct) mode-line-process))
      (ghostel-spinner-progress 'set 75)
      (should (equal '(":Char" " [75%]") mode-line-process))
      (ghostel-spinner-progress 'remove nil)
      (should (equal ":Char" mode-line-process)))))

(ert-deftest ghostel-test-mode-line-refresh-skips-fmlu-when-unchanged ()
  "Refresh skips FMLU when the composed mode-line value is unchanged."
  (let ((fmlu-calls 0))
    (cl-letf (((symbol-function #'force-mode-line-update)
               (lambda (&rest _) (cl-incf fmlu-calls))))
      (with-temp-buffer
        (setq ghostel--mode-line-tag ":Char")
        (ghostel--mode-line-refresh)
        (should (= 1 fmlu-calls))
        ;; Same composed value — FMLU must not fire again.
        (ghostel--mode-line-refresh)
        (ghostel--mode-line-refresh)
        (should (= 1 fmlu-calls))
        ;; Tag actually changes → FMLU fires.
        (setq ghostel--mode-line-tag ":Line")
        (ghostel--mode-line-refresh)
        (should (= 2 fmlu-calls))
        ;; Same again → still no extra FMLU.
        (ghostel--mode-line-refresh)
        (should (= 2 fmlu-calls))
        ;; Progress changes the composed list → FMLU fires.
        (setq ghostel--mode-line-progress " [42%]")
        (ghostel--mode-line-refresh)
        (should (= 3 fmlu-calls))
        ;; Identical progress packet → no FMLU.
        (ghostel--mode-line-refresh)
        (should (= 3 fmlu-calls))))))

(ert-deftest ghostel-test-osc-partial-does-not-starve-later ()
  "A partial OSC must not cannibalize a following complete OSC.
The parser dispatches the truncated OSC 7 payload and then starts OSC 52
fresh."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let ((ghostel-enable-osc52 t)
            (kill-ring nil))
        (ghostel--write-pty ghostel--term "\e]7;PARTIAL\e]52;c;aGVsbG8=\a")
        (ghostel-test--wait-until
         (lambda ()
           (and kill-ring
                (equal "PARTIAL" ghostel--last-directory)))
         proc 5)
        ;; OSC 52 dispatched: "hello" in kill-ring.
        (should (equal "hello" (car kill-ring)))
        ;; OSC 7 dispatched with the truncated payload "PARTIAL".
        (should (equal "PARTIAL" ghostel--last-directory))))))

(ert-deftest ghostel-test-osc-color-query ()
  "Test that OSC 4/10/11 color queries get responses."
  :tags '(native)
  (let ((python (executable-find "python3")))
    (skip-unless python)
    ;; Each case pairs a payload written to the terminal with a CHECK on the
    ;; reply the terminal writes back to the child (reported as lowercase hex):
    ;;   (PAYLOAD :none)       no reply expected
    ;;   (PAYLOAD :equal HEX)  reply must equal HEX exactly
    ;;   (PAYLOAD :match RE)   reply must match regexp RE
    ;; The cases are replayed through one long-lived child in order, so palette
    ;; state set by an earlier case is visible to a later query.
    (let ((cases
           (list
            ;; OSC 11 background query with ST terminator.
            '("\e]11;?\e\\" :match "\\`1b5d31313b7267623a[0-9a-f]+1b5c\\'")
            ;; OSC 10 foreground query with BEL terminator.
            '("\e]10;?\a" :match "\\`1b5d31303b7267623a[0-9a-f]+07\\'")
            ;; OSC 4 set for index 1 (no reply), then a query that must see it.
            '("\e]4;1;rgb:11/22/33\e\\" :none)
            '("\e]4;1;?\e\\" :equal
              "1b5d343b313b7267623a313131312f323232322f333333331b5c")
            ;; OSC 10 with a set value (not a query) — no reply.
            '("\e]10;rgb:aa/bb/cc\e\\" :none)
            ;; OSC 4 set (not a query) — no reply.
            '("\e]4;2;rgb:44/55/66\e\\" :none)
            ;; Malformed OSC 4 payloads — don't crash, don't reply.
            '("\e]4;\e\\" :none)                       ; empty
            '("\e]4;xyz;?\e\\" :none)                  ; non-numeric index
            '("\e]4;999;?\e\\" :none)                  ; index out of range
            '("\e]4;0\e\\" :none)                      ; index without value
            '("\e]4;99999999999999999999;?\e\\" :none) ; overflow
            ;; Multiple different-type queries in one write must reply in source
            ;; order so termenv-style readers can match by position.
            '("\e]11;?\e\\\e]10;?\e\\" :match
              "\\`1b5d31313b7267623a.*1b5c1b5d31303b7267623a.*1b5c\\'")
            ;; Multi-pair OSC 4 query: the index=1 value seeded above is still
            ;; there, and both indices get replied to in order.
            '("\e]4;1;?;3;?\e\\" :match
              "\\`1b5d343b313b7267623a313131312f323232322f333333331b5c1b5d343b333b7267623a.*1b5c\\'"))))
      (cl-labels ((run-probe (payloads)
                    (ghostel-test--with-exec-buffer
                        (buf proc python
                             (append (list "-c" ghostel-test--pty-reply-probe-script "0.15")
                                     (mapcar #'ghostel-test--hex-encode-string payloads)))
                      (cl-loop for i below (length payloads)
                               collect (ghostel-test--wait-for-pty-reply i proc 6)))))
        (ghostel-test--with-pty-matrix backend
          (let ((replies (run-probe (mapcar #'car cases))))
            (cl-loop for (payload check arg) in cases
                     for reply in replies
                     do (ert-info ((format "payload: %S" payload))
                          (pcase check
                            (:none (should (equal "" reply)))
                            (:equal (should (equal arg reply)))
                            (:match (should (string-match-p arg reply))))))))))))

(ert-deftest ghostel-test-osc52-eval ()
  "Test that OSC 52;e dispatches to whitelisted functions."
  (let* ((called-with nil)
         (ghostel-eval-cmds
          `(("test-fn" ,(lambda (&rest args) (setq called-with args))))))
    (ghostel--osc52-eval "\"test-fn\" \"hello\" \"world\"")
    (should (equal '("hello" "world") called-with))))

(ert-deftest ghostel-test-osc52-eval-unknown ()
  "Test that unknown OSC 52;e commands produce a message."
  (let ((ghostel-eval-cmds nil)
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (ghostel--osc52-eval "\"unknown-fn\" \"arg\"")
      (should (car messages))
      (should (string-match-p "unknown eval command" (car messages))))))

(ert-deftest ghostel-test-osc52-eval-catches-errors ()
  "Errors from a dispatched OSC 52;e function are caught, not propagated.
Otherwise they crash the process filter / redraw timer that invoked the
native parser.  Regression for a follow-up to #82 where `dow' with no
args called `dired-other-window' with 0 arguments and signaled up
through the filter."
  (let* ((ghostel-eval-cmds
          `(("boom" ,(lambda (&rest _) (error "Kaboom")))))
         (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      ;; Must not raise.
      (ghostel--osc52-eval "\"boom\"")
      (should (car messages))
      (should (string-match-p "error calling boom" (car messages)))
      (should (string-match-p "Kaboom" (car messages))))))

(ert-deftest ghostel-test-osc52-eval-native ()
  "OSC 52 kind \='e\=' reaches `ghostel--osc52-eval'."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let* ((called-with nil)
             (ghostel-eval-cmds
              `(("test-fn" ,(lambda (&rest args) (setq called-with args))))))
        (ghostel--write-pty ghostel--term "\e]52;e;\"test-fn\" \"hi\"\e\\")
        (ghostel-test--wait-until (lambda () called-with) proc 5)
        (should (equal '("hi") called-with))))))

(ert-deftest ghostel-test-osc52-kind-dispatch ()
  "OSC 52 dispatches on kind: \='e\=' to eval, others to clipboard."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let* ((eval-called nil)
             (ghostel-eval-cmds
              `(("k" ,(lambda (&rest _) (setq eval-called t)))))
             (ghostel-enable-osc52 t)
             (kill-ring nil))
        (ghostel--write-pty ghostel--term "\e]52;c;aGVsbG8=\e\\")
        (ghostel-test--wait-until (lambda () kill-ring) proc 5)
        (should-not eval-called)
        (should (equal "hello" (car kill-ring)))

        (setq kill-ring nil)
        (ghostel--write-pty ghostel--term "\e]52;e;\"k\"\e\\")
        (ghostel-test--wait-until (lambda () eval-called) proc 5)
        (should eval-called)
        (should-not kill-ring)))))

(ert-deftest ghostel-test-osc52-eval-cross-chunk ()
  "OSC 52;e payload split across two PTY writes dispatches once.
Ghostty's parser buffers the OSC body across stream-feed calls, so the
elisp callback fires exactly when the terminator arrives in the second
call.  The OSC 51 scanner this replaces could not handle this case."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let* ((called-with nil)
             (ghostel-eval-cmds
              `(("test-fn" ,(lambda (&rest args) (setq called-with args))))))
        (ghostel--write-pty ghostel--term "\e]52;e;\"test-fn\" \"par")
        (accept-process-output proc 0.1)
        (should-not called-with)
        (ghostel--write-pty ghostel--term "t1\" \"part2\"\e\\")
        (ghostel-test--wait-until (lambda () called-with) proc 5)
        (should (equal '("part1" "part2") called-with))))))

(ert-deftest ghostel-test-osc52-mixed-kinds-one-write ()
  "A single PTY write containing both OSC 52;e and OSC 52;c dispatches both."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let* ((eval-payloads nil)
             (ghostel-eval-cmds
              `(("k" ,(lambda (&rest args) (push args eval-payloads)))))
             (ghostel-enable-osc52 t)
             (kill-ring nil))
        (ghostel--write-pty
         ghostel--term
         "\e]52;e;\"k\" \"first\"\e\\\e]52;c;aGVsbG8=\e\\")
        (ghostel-test--wait-until
         (lambda () (and eval-payloads kill-ring)) proc 5)
        (should (equal '(("first")) eval-payloads))
        (should (equal "hello" (car kill-ring)))))))

(ert-deftest ghostel-test-osc7-parsing ()
  "OSC 7 child output updates the buffer-local directory report."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (should (equal nil ghostel--last-directory))

      (ghostel--write-pty ghostel--term "\e]7;file:///tmp/testdir\e\\")
      (ghostel-test--wait-until
       (lambda () (equal "file:///tmp/testdir" ghostel--last-directory))
       proc 5)
      (should (equal "file:///tmp/testdir" ghostel--last-directory))

      (ghostel--write-pty ghostel--term "\e]7;file:///home/user\a")
      (ghostel-test--wait-until
       (lambda () (equal "file:///home/user" ghostel--last-directory))
       proc 5)
      (should (equal "file:///home/user" ghostel--last-directory)))))

(ert-deftest ghostel-test-osc133-parsing ()
  "OSC 133 child output dispatches prompt markers."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let (markers)
        (cl-letf (((symbol-function 'ghostel--osc133-marker)
                   (lambda (type param) (push (cons type param) markers))))
          (ghostel--write-pty ghostel--term "\e]133;A\e\\")
          (ghostel-test--wait-until (lambda () (assoc "A" markers)) proc 5)

          (setq markers nil)
          (ghostel--write-pty ghostel--term "\e]133;B\a")
          (ghostel-test--wait-until (lambda () (assoc "B" markers)) proc 5)

          (setq markers nil)
          (ghostel--write-pty ghostel--term "\e]133;C\e\\")
          (ghostel-test--wait-until (lambda () (assoc "C" markers)) proc 5)

          (setq markers nil)
          (ghostel--write-pty ghostel--term "\e]133;D;0\e\\")
          (ghostel-test--wait-until
           (lambda () (equal "0" (cdr (assoc "D" markers))))
           proc 5)

          (setq markers nil)
          (ghostel--write-pty ghostel--term "\e]133;D;1\e\\")
          (ghostel-test--wait-until
           (lambda () (equal "1" (cdr (assoc "D" markers))))
           proc 5)

          (setq markers nil)
          (ghostel--write-pty ghostel--term "hello\e]133;A\e\\world\e]133;B\e\\")
          (ghostel-test--wait-until
           (lambda () (and (assoc "A" markers) (assoc "B" markers)))
           proc 5)

          ;; 133;P (explicit prompt start, no fresh-line side effect) — used
          ;; by the zsh `zle-line-init' fallback and forwarded to elisp the
          ;; same way as A so prompt navigation keeps working when the
          ;; PROMPT-wrap was clobbered by a theme.
          (setq markers nil)
          (ghostel--write-pty ghostel--term "\e]133;P\e\\")
          (ghostel-test--wait-until (lambda () (assoc "P" markers)) proc 5)
          (setq markers nil)
          (ghostel--write-pty ghostel--term "\e]133;P;k=i\e\\")
          (ghostel-test--wait-until
           (lambda () (equal "k=i" (cdr (assoc "P" markers))))
           proc 5)

          ;; 133;N (new_command) surfaces as A.  Ghostel doesn't track
          ;; commands by aid, so N uses the same prompt navigation and hooks.
          (setq markers nil)
          (ghostel--write-pty ghostel--term "\e]133;N\e\\")
          (ghostel-test--wait-until (lambda () (assoc "A" markers)) proc 5)
          (setq markers nil)
          (ghostel--write-pty ghostel--term "\e]133;N;aid=42\e\\")
          (ghostel-test--wait-until
           (lambda () (equal "aid=42" (cdr (assoc "A" markers))))
           proc 5))))))

(ert-deftest ghostel-test-command-finish-hook ()
  "OSC 133 D fires `ghostel-command-finish-functions'."
  (with-temp-buffer
    (let* ((calls nil)
           (ghostel-command-finish-functions
            (list (lambda (buf exit) (push (cons buf exit) calls)))))
      (ghostel--osc133-marker "A" nil)
      (ghostel--osc133-marker "D" "0")
      (should (equal 1 (length calls)))
      (should (eq (caar calls) (current-buffer)))
      (should (equal 0 (cdar calls)))

      (setq calls nil)
      (ghostel--osc133-marker "A" nil)
      (ghostel--osc133-marker "D" "2")
      (should (equal 2 (cdar calls)))

      ;; Missing param -> exit is nil, hook still fires
      (setq calls nil)
      (ghostel--osc133-marker "A" nil)
      (ghostel--osc133-marker "D" nil)
      (should (equal 1 (length calls)))
      (should (null (cdar calls))))))

(ert-deftest ghostel-test-command-finish-hook-from-child-output ()
  "OSC 133 D child output fires `ghostel-command-finish-functions'."
  :tags '(native)
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (let* ((calls nil)
             (ghostel-command-finish-functions
              (list (lambda (_buf exit) (push exit calls)))))
        (ghostel--write-pty ghostel--term "\e]133;A\e\\$ \e]133;B\e\\")
        (ghostel--write-pty ghostel--term "echo hi\r\nhi\r\n")
        (ghostel--write-pty ghostel--term "\e]133;D;0\e\\")
        (ghostel-test--wait-until (lambda () (equal '(0) calls)) proc 5)
        (should (equal '(0) calls))

        (ghostel--write-pty ghostel--term "\e]133;A\e\\$ \e]133;B\e\\")
        (ghostel--write-pty ghostel--term "\e]133;D;127\e\\")
        (ghostel-test--wait-until (lambda () (equal '(127 0) calls)) proc 5)
        (should (equal '(127 0) calls))))))

(ert-deftest ghostel-test-command-finish-hook-error-caught ()
  "Errors in `ghostel-command-finish-functions' are demoted to messages.
Bind `debug-on-error' to nil so we test the production code path
\(under `--batch -Q' Emacs sets `debug-on-error' to t, which
intentionally makes `with-demoted-errors' re-signal so a hook
author's debugger can fire)."
  (with-temp-buffer
    (let ((inhibit-message t)
          (debug-on-error nil)
          (ghostel-command-finish-functions
           (list (lambda (_buf _exit) (error "Boom")))))
      (ghostel--osc133-marker "A" nil)
      (should-not (condition-case _ (progn (ghostel--osc133-marker "D" "0") nil)
                    (error t))))))

(ert-deftest ghostel-test-command-finish-hook-error-isolated ()
  "A raising hook must not prevent later hooks from running.
See `ghostel-test-command-finish-hook-error-caught' for why we
bind `debug-on-error' to nil."
  (with-temp-buffer
    (let ((inhibit-message t)
          (debug-on-error nil)
          (later-ran nil))
      (let ((ghostel-command-finish-functions
             (list (lambda (_buf _exit) (error "First boom"))
                   (lambda (_buf _exit) (setq later-ran t)))))
        (ghostel--osc133-marker "A" nil)
        (ghostel--osc133-marker "D" "0")
        (should later-ran)))))

(ert-deftest ghostel-test-command-finish-hook-runs-synchronously ()
  "Regression: `ghostel-command-finish-functions' must fire synchronously.
They run inside `ghostel--osc133-marker', not deferred via timers.
Downstream consumers (notably `ghostel-compile') depend on it."
  (let ((ran nil))
    (let ((ghostel-command-finish-functions
           (list (lambda (_b _e) (setq ran t)))))
      (ghostel--osc133-marker "D" "0")
      (should ran))))

(ert-deftest ghostel-test-command-start-hook-runs-synchronously ()
  "Regression: `ghostel-command-start-functions' must fire synchronously."
  (let ((ran nil))
    (let ((ghostel-command-start-functions
           (list (lambda (_b) (setq ran t)))))
      (ghostel--osc133-marker "C" nil)
      (should ran))))

(provide 'ghostel-osc-test)
;;; ghostel-osc-test.el ends here
