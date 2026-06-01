;;; ghostel-osc-test.el --- Tests for ghostel: osc -*- lexical-binding: t; -*-

;;; Commentary:

;; OSC 4/9/10/11/51/52/777 handling, color queries, progress / notification
;; dispatch, spinners.  OSC 8 hyperlink behavior lives in `ghostel-links-test'.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-osc52 ()
  "Test OSC 52 clipboard handling."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    ;; With osc52 disabled, kill ring should not be modified
    (let ((ghostel-enable-osc52 nil)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;aGVsbG8=\e\\")  ; "hello" in base64
      (should (equal nil kill-ring)))                       ; osc52 disabled: no kill

    ;; With osc52 enabled, text should appear in kill ring
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;aGVsbG8=\e\\")
      (should (> (length kill-ring) 0))                     ; kill ring has entry
      (when kill-ring
        (should (equal "hello" (car kill-ring)))))          ; decoded text

    ;; BEL terminator
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;d29ybGQ=\a")
      (when kill-ring
        (should (equal "world" (car kill-ring)))))          ; osc52 BEL terminator

    ;; Query ('?') should be ignored
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;?\e\\")
      (should (equal nil kill-ring)))))                     ; osc52 query ignored

(ert-deftest ghostel-test-osc9-notification ()
  "OSC 9 iTerm2-style notifications reach `ghostel-notification-function'."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (calls nil)
         (ghostel-notification-function
          (lambda (title body) (push (cons title body) calls))))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _rep fn &rest args) (apply fn args))))
      ;; Plain iTerm2 notification, ST terminator.
      (ghostel--write-input term "\e]9;Hello world\e\\")
      (should (equal '(("" . "Hello world")) calls))

      ;; BEL terminator
      (setq calls nil)
      (ghostel--write-input term "\e]9;bell form\a")
      (should (equal '(("" . "bell form")) calls))

      ;; Single-character body
      (setq calls nil)
      (ghostel--write-input term "\e]9;X\e\\")
      (should (equal '(("" . "X")) calls))

      ;; Empty payload is dropped at the handler — the elisp default
      ;; notifier would just show the buffer name with an empty body,
      ;; so there's nothing useful to dispatch.
      (setq calls nil)
      (ghostel--write-input term "\e]9;\e\\")
      (should (equal nil calls)))))

(ert-deftest ghostel-test-osc9-conemu-suppressed ()
  "ConEmu OSC 9 sub-codes must not fire a notification.
Covers the forms that ghostty-vt's parser accepts as valid ConEmu
sequences (sleep, message box, tab title, wait input, emulation
mode, prompt start).  Payloads that ghostty-vt rejects fall through
to the notification path — see `ghostel-test-osc9-invalid-conemu-notifies'."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (calls nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) calls)))
              ((symbol-function 'ghostel--osc-progress)
               (lambda (_s _p) nil)))
      ;; 9;1;<ms> sleep, 9;2;<msg> message box, 9;3;<title> tab title
      (ghostel--write-input term "\e]9;1;500\e\\")
      (ghostel--write-input term "\e]9;2;hello\e\\")
      (ghostel--write-input term "\e]9;3;tab\e\\")
      ;; 9;5 wait-input, 9;12 prompt start
      (ghostel--write-input term "\e]9;5\e\\")
      (ghostel--write-input term "\e]9;12\e\\")
      ;; 9;10 xterm emulation — bare and with valid args 0-3
      (ghostel--write-input term "\e]9;10\e\\")
      (ghostel--write-input term "\e]9;10;0\e\\")
      (ghostel--write-input term "\e]9;10;3\e\\")
      ;; Trailing bytes after a valid first-arg digit are tolerated
      ;; (matches ghostty-vt).
      (ghostel--write-input term "\e]9;10;01\e\\")
      (ghostel--write-input term "\e]9;10;3x\e\\")
      (should (equal nil calls)))))

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
  (let ((term (ghostel--new 25 80 1000))
        (calls nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) calls)))
              ((symbol-function 'ghostel--osc-progress)
               (lambda (_s _p) nil)))
      (ghostel--write-input term "\e]9;10;4\e\\")
      (should (equal '(("" . "10;4")) calls))

      (setq calls nil)
      (ghostel--write-input term "\e]9;10;\e\\")
      (should (equal '(("" . "10;")) calls))

      (setq calls nil)
      (ghostel--write-input term "\e]9;10;abc\e\\")
      (should (equal '(("" . "10;abc")) calls)))))

(ert-deftest ghostel-test-osc9-cwd-routing ()
  "OSC 9;9;PATH updates the terminal's working directory.
ConEmu's CWD-reporting alias is routed through libghostty's `setPwd'
\(the same plumbing OSC 7 uses), so `ghostel--get-pwd' reflects the
reported path and no notification fires."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (notifs nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) notifs))))
      (ghostel--write-input term "\e]9;9;/tmp/ghostel-cwd\e\\")
      (should (equal "/tmp/ghostel-cwd" (ghostel--get-pwd term)))
      (should (equal nil notifs)))))

(ert-deftest ghostel-test-osc9-progress ()
  "OSC 9;4 progress reports reach `ghostel-progress-function'."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (calls nil)
         (ghostel-progress-function
          (lambda (state progress) (push (list state progress) calls))))
    ;; set, with progress
    (ghostel--write-input term "\e]9;4;1;50\e\\")
    (should (equal '((set 50)) calls))

    ;; set without progress defaults to 0 (matches ghostty-vt)
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;1\e\\")
    (should (equal '((set 0)) calls))

    ;; remove
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;0\e\\")
    (should (equal '((remove nil)) calls))

    ;; remove ignores trailing progress (matches ghostty-vt's "remove
    ;; ignores progress" test)
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;0;100\e\\")
    (should (equal '((remove nil)) calls))

    ;; error without progress
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;2\e\\")
    (should (equal '((error nil)) calls))

    ;; error with progress
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;2;73\e\\")
    (should (equal '((error 73)) calls))

    ;; indeterminate
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;3\e\\")
    (should (equal '((indeterminate nil)) calls))

    ;; indeterminate ignores trailing progress
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;3;50\e\\")
    (should (equal '((indeterminate nil)) calls))

    ;; pause with progress
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;4;25\e\\")
    (should (equal '((pause 25)) calls))

    ;; Trailing semicolon is tolerated (9;4;0;)
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;0;\e\\")
    (should (equal '((remove nil)) calls))

    ;; Progress overflow clamps to 100
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;1;999\e\\")
    (should (equal '((set 100)) calls))

    ;; Huge numbers beyond u16 still parse and clamp (would overflow
    ;; u16, but parser uses u64).
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;1;99999999999\e\\")
    (should (equal '((set 100)) calls))

    ;; Non-numeric progress arrives as nil — ghostty's parser pre-fills
    ;; progress=0 for state=.set, but `;<unparseable>` reaches the value
    ;; branch and `parseUnsigned` failure writes nil over that pre-fill.
    ;; (Bare `9;4;1` with no value at all still yields 0 — see above.)
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;1;foo\e\\")
    (should (equal '((set nil)) calls))
    (setq calls nil)
    (ghostel--write-input term "\e]9;4;2;foo\e\\")
    (should (equal '((error nil)) calls))))

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
  (let ((term (ghostel--new 25 80 1000))
        (calls nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) calls))))
      (ghostel--write-input term "\e]777;notify;Subject;Body text\e\\")
      (should (equal '(("Subject" . "Body text")) calls))

      ;; BEL terminator
      (setq calls nil)
      (ghostel--write-input term "\e]777;notify;T;B\a")
      (should (equal '(("T" . "B")) calls))

      ;; Empty title AND empty body is dropped at the handler — same
      ;; rule as OSC 9 (the elisp default notifier has nothing useful
      ;; to show).  Non-empty title or body still dispatches.
      (setq calls nil)
      (ghostel--write-input term "\e]777;notify;;\e\\")
      (should (equal nil calls))

      (setq calls nil)
      (ghostel--write-input term "\e]777;notify;T;\e\\")
      (should (equal '(("T" . "")) calls))

      (setq calls nil)
      (ghostel--write-input term "\e]777;notify;;B\e\\")
      (should (equal '(("" . "B")) calls))

      ;; Unknown extension is dropped
      (setq calls nil)
      (ghostel--write-input term "\e]777;bogus;a;b\e\\")
      (should (equal nil calls)))))

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
  "Progress updates compose with `ghostel--mode-line-tag', not clobber it.
Regression test: the previous implementation overwrote
`mode-line-process' directly, so OSC 9;4 progress reports erased
input-mode labels like \":Char\" or \":Line\".  The composed
`mode-line-process' must contain both the tag and the progress."
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
  "Refresh skips FMLU when the composed mode-line value is unchanged.
Regression: the previous `ghostel--mode-line-refresh' always
fired `force-mode-line-update', defeating the no-spam contract
that motivated the face-cache fix on the progress callpath."
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
Input \"\\e]7;PARTIAL\\e]52;c;aGVsbG8=\\a\" used to be treated as
two distinct OSCs by ghostel's own scanner: the partial OSC 7 was
dropped and OSC 52 dispatched.  ghostty-vt's OSC parser treats the
intervening \\e] as the end of the OSC 7 (truncating its payload to
\"PARTIAL\") and then starts OSC 52 fresh — both dispatch, and the
truncated OSC 7 lands as PWD = \"PARTIAL\".  This test pins the new
behavior so a regression toward the old reject-partial logic would
be caught."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (ghostel-enable-osc52 t)
        (kill-ring nil))
    (ghostel--write-input term "\e]7;PARTIAL\e]52;c;aGVsbG8=\a")
    ;; OSC 52 dispatched: "hello" in kill-ring.
    (should kill-ring)
    (should (equal "hello" (car kill-ring)))
    ;; OSC 7 dispatched with the truncated payload "PARTIAL".
    (should (equal "PARTIAL" (ghostel--get-pwd term)))))

(ert-deftest ghostel-test-osc-color-query ()
  "Test that OSC 4/10/11 color queries get responses."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (sent-bytes nil))
    (cl-letf (((symbol-function 'ghostel--flush-output)
               (lambda (data)
                 (setq sent-bytes (concat sent-bytes data)))))

      ;; OSC 11 background query with ST terminator.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]11;?\e\\")
      (should sent-bytes)
      (should (string-match-p "\\`\e\\]11;rgb:[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}\e\\\\\\'"
                              sent-bytes))

      ;; OSC 10 foreground query with BEL terminator.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]10;?\a")
      (should sent-bytes)
      (should (string-match-p "\\`\e\\]10;rgb:[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}\a\\'"
                              sent-bytes))

      ;; OSC 4 palette query for index 1, after a prior set.  The extractor
      ;; runs before vtWrite inside a single write-input, so the set must
      ;; land in a previous call for the new value to be visible.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]4;1;rgb:11/22/33\e\\")
      (should (equal nil sent-bytes))                   ; set: no reply
      (ghostel--write-input term "\e]4;1;?\e\\")
      (should (equal "\e]4;1;rgb:1111/2222/3333\e\\" sent-bytes))

      ;; OSC 10 with a set value (not a query) — no response.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]10;rgb:aa/bb/cc\e\\")
      (should (equal nil sent-bytes))

      ;; OSC 4 set (not a query) — no response.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]4;2;rgb:44/55/66\e\\")
      (should (equal nil sent-bytes))

      ;; Malformed OSC 4 payloads — don't crash, don't reply.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]4;\e\\")           ; empty
      (ghostel--write-input term "\e]4;xyz;?\e\\")     ; non-numeric index
      (ghostel--write-input term "\e]4;999;?\e\\")     ; index out of range
      (ghostel--write-input term "\e]4;0\e\\")         ; index without value
      (ghostel--write-input term "\e]4;99999999999999999999;?\e\\") ; overflow
      (should (equal nil sent-bytes))

      ;; Multiple different-type queries in one write must reply in source
      ;; order so termenv-style readers can match by position.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]11;?\e\\\e]10;?\e\\")
      (should (string-match-p "\\`\e\\]11;rgb:.*?\e\\\\\e\\]10;rgb:.*?\e\\\\\\'"
                              sent-bytes))

      ;; Multi-pair OSC 4 with mixed set+query: the extractor runs before
      ;; vtWrite, so the set is not yet visible to the query in the same
      ;; payload — but the index=1 value seeded in the earlier write
      ;; above is still there, and both indices get replied to in order.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]4;1;?;3;?\e\\")
      (should (string-match-p
               "\\`\e\\]4;1;rgb:1111/2222/3333\e\\\\\e\\]4;3;rgb:.*?\e\\\\\\'"
               sent-bytes))

      ;; Unterminated OSC query — reply is withheld until the terminator
      ;; arrives.  (We don't buffer across write-input calls, so the
      ;; terminator must be in the same call to get a reply.)
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]11;?")
      (should (equal nil sent-bytes)))))

(ert-deftest ghostel-test-osc-color-query-filter-flush ()
  "The process filter must flush synchronously on a color query.
Programs like `duf' read stdin with a short timeout and give up if
the reply waits for the redraw timer."
  :tags '(native)
  (let ((fake-proc (make-symbol "fake-proc"))
        (sent nil))
    (ghostel-test--with-terminal-buffer (buf _term 25 80 1000)
      (setq ghostel--process fake-proc)
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'ghostel--flush-output)
                 (lambda (data) (setq sent (concat sent data))))
                ((symbol-function 'ghostel--invalidate) #'ignore))
        ;; OSC 11 query arrives — reply must be produced before
        ;; `ghostel--filter' returns, not on a later timer tick.
        (ghostel--filter fake-proc "\e]11;?\e\\")
        (should sent)
        (should (string-match-p "\\`\e\\]11;rgb:" sent))
        (should (equal nil ghostel--pending-output))

        ;; A non-query OSC 11 set must NOT trigger the sync flush,
        ;; so the data stays pending for the redraw timer.
        (setq sent nil)
        (ghostel--filter fake-proc "\e]11;rgb:11/22/33\e\\")
        (should (equal nil sent))
        (should ghostel--pending-output)))))

(ert-deftest ghostel-test-osc52-eval-filter-flush ()
  "The process filter must dispatch OSC 52;e synchronously.
Callers like `b4 prep --edit-cover' delete temp files shortly
after sending the OSC; a delayed dispatch (via the redraw timer)
loses the race with `tempfile.TemporaryDirectory' cleanup, so
`find-file' opens a file whose parent directory is already gone."
  :tags '(native)
  (let ((fake-proc (make-symbol "fake-proc"))
        (dispatched nil))
    (ghostel-test--with-terminal-buffer (buf _term 25 80 1000)
      (setq ghostel--process fake-proc)
      (let ((ghostel-eval-cmds
             `(("noop" ,(lambda (&rest args)
                          (setq dispatched (cons 'noop args)))))))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'ghostel--invalidate) #'ignore))
          ;; OSC 52;e must run before `ghostel--filter' returns.
          (ghostel--filter fake-proc "\e]52;e;noop \"hi\"\e\\")
          (should (equal '(noop "hi") dispatched))
          (should (equal nil ghostel--pending-output))

          ;; OSC 52;c (standard clipboard) must NOT trigger the sync
          ;; flush — it's harmless to defer, unlike eval.
          (setq dispatched nil)
          (ghostel--filter fake-proc "\e]52;c;aGVsbG8=\e\\")
          (should (equal nil dispatched))
          (should ghostel--pending-output)

          ;; The OSC introducer can straddle a filter-call boundary
          ;; (slow producers, SSH, tiny TCP segments).  The first
          ;; chunk alone doesn't match — but the second chunk plus
          ;; the carryover tail of the first must trigger dispatch.
          (setq dispatched nil
                ghostel--pending-output nil)
          (ghostel--filter fake-proc "prefix\e]52;")
          (should (equal nil dispatched))
          (ghostel--filter fake-proc "e;noop \"split\"\e\\")
          (should (equal '(noop "split") dispatched))
          (should (equal nil ghostel--pending-output)))))))

(ert-deftest ghostel-test-osc52-eval-filter-flush-after-introducer ()
  "Sync-flush survives the introducer landing alone at chunk end.
Regression for the case where chunk 1 = `\\e]52;e;\\=' (regex matches,
flush, pending cleared) and chunk 2 = body + ST (no `52;e;\\=', no
carry).  Without the in-flight flag the eval defers to the redraw
timer and `b4 prep --edit-cover\\=' can race its temp-dir cleanup."
  :tags '(native)
  (let ((fake-proc (make-symbol "fake-proc"))
        (dispatched nil))
    (ghostel-test--with-terminal-buffer (buf _term 25 80 1000)
      (setq ghostel--process fake-proc)
      (let ((ghostel-eval-cmds
             `(("noop" ,(lambda (&rest args)
                          (setq dispatched (cons 'noop args)))))))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'ghostel--invalidate) #'ignore))
          (ghostel--filter fake-proc "\e]52;e;")
          (should ghostel--osc52-eval-in-flight)
          (should-not dispatched)
          (ghostel--filter fake-proc "\"noop\" \"post\"\e\\")
          (should (equal '(noop "post") dispatched))
          (should-not ghostel--osc52-eval-in-flight)
          (should (equal nil ghostel--pending-output)))))))

(ert-deftest ghostel-test-osc52-eval-filter-flush-mid-body ()
  "Sync-flush survives a body-split with the terminator in chunk 2.
Chunk 1 carries the introducer + partial body; chunk 2 finishes the
body and the ST.  The in-flight flag keeps forcing flush on chunk 2
even though chunk 2 itself contains no `52;e;\\=' substring."
  :tags '(native)
  (let ((fake-proc (make-symbol "fake-proc"))
        (dispatched nil))
    (ghostel-test--with-terminal-buffer (buf _term 25 80 1000)
      (setq ghostel--process fake-proc)
      (let ((ghostel-eval-cmds
             `(("noop" ,(lambda (&rest args)
                          (setq dispatched (cons 'noop args)))))))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'ghostel--invalidate) #'ignore))
          (ghostel--filter fake-proc "\e]52;e;\"noop\" \"sp")
          (should ghostel--osc52-eval-in-flight)
          (should-not dispatched)
          (ghostel--filter fake-proc "lit\"\e\\")
          (should (equal '(noop "split") dispatched))
          (should-not ghostel--osc52-eval-in-flight))))))

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
  "OSC 52 kind \\='e\\=' reaches `ghostel--osc52-eval' through the native parser."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (called-with nil)
         (ghostel-eval-cmds
          `(("test-fn" ,(lambda (&rest args) (setq called-with args))))))
    (ghostel--write-input term "\e]52;e;\"test-fn\" \"hi\"\e\\")
    (should (equal '("hi") called-with))))

(ert-deftest ghostel-test-osc52-kind-dispatch ()
  "OSC 52 dispatches on kind: \\='e\\=' to eval, others to clipboard."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (eval-called nil)
         (ghostel-eval-cmds
          `(("k" ,(lambda (&rest _) (setq eval-called t))))))
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;aGVsbG8=\e\\")
      (should-not eval-called)
      (should (equal "hello" (car kill-ring))))
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;e;\"k\"\e\\")
      (should eval-called)
      (should-not kill-ring))))

(ert-deftest ghostel-test-osc52-eval-cross-chunk ()
  "OSC 52;e payload split across two write-input calls dispatches once.
Ghostty's parser buffers the OSC body across stream-feed calls, so the
elisp callback fires exactly when the terminator arrives in the second
call.  The OSC 51 scanner this replaces could not handle this case."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (called-with nil)
         (ghostel-eval-cmds
          `(("test-fn" ,(lambda (&rest args) (setq called-with args))))))
    (ghostel--write-input term "\e]52;e;\"test-fn\" \"par")
    (should-not called-with)
    (ghostel--write-input term "t1\" \"part2\"\e\\")
    (should (equal '("part1" "part2") called-with))))

(ert-deftest ghostel-test-osc52-mixed-kinds-one-write ()
  "A single write containing both OSC 52;e and OSC 52;c dispatches both."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (eval-payloads nil)
         (ghostel-eval-cmds
          `(("k" ,(lambda (&rest args) (push args eval-payloads))))))
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term
                            "\e]52;e;\"k\" \"first\"\e\\\e]52;c;aGVsbG8=\e\\")
      (should (equal '(("first")) eval-payloads))
      (should (equal "hello" (car kill-ring))))))

(provide 'ghostel-osc-test)
;;; ghostel-osc-test.el ends here
