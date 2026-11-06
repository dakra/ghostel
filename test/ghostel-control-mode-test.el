;;; ghostel-control-mode-test.el --- Tests for ghostel: tmux control mode -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-control-mode-function': the control-mode DCS (`ESC P 1000 p')
;; is fed through the real VT parser and its events are recorded.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-test--with-control-mode (spec &rest body)
  "Run BODY in a terminal buffer that records control-mode events.
SPEC is (TERM EVENTS).  EVENTS holds (EVENT . DATA) conses, newest first."
  (declare (indent 1))
  (pcase-let ((`(,term ,events) spec))
    `(ghostel-test--with-terminal-buffer (buffer ,term 24 80 100)
       (let* ((,events nil)
              (ghostel-control-mode-function
               (lambda (event data) (push (cons event data) ,events))))
         ,@body))))

(defun ghostel-test--control-mode-write (term bytes)
  "Feed BYTES to TERM and run the events they queue."
  (ghostel--write-vt term bytes)
  ;; Events are deferred to timers; one scheduled now runs after them.
  (let (done)
    (run-at-time 0 nil (lambda () (setq done t)))
    (ghostel-test--wait-until (lambda () done))))

(defun ghostel-test--control-mode-body (events)
  "Return the concatenated data of EVENTS, oldest first."
  (mapconcat #'cdr (reverse events) ""))

(ert-deftest ghostel-test-control-mode-frame ()
  "A frame reports enter, its body and exit; the rest stays terminal output."
  :tags '(native)
  (ghostel-test--with-control-mode (term events)
    (ghostel-test--control-mode-write term "before\r\n\eP1000pHELLO\e\\after")
    (should (equal '((enter) (data . "HELLO") (exit)) (reverse events)))
    (let ((text (ghostel--copy-all-text term)))
      (should (string-match-p "before" text))
      (should (string-match-p "after" text))
      (should-not (string-match-p "HELLO" text)))))

(ert-deftest ghostel-test-control-mode-split-writes ()
  "A frame split across writes streams its body, a split character included."
  :tags '(native)
  (ghostel-test--with-control-mode (term events)
    (ghostel-test--control-mode-write term "\eP10")
    (should-not events)
    (ghostel-test--control-mode-write term "00pB\303")
    (should (equal '((enter) (data . "B\303")) (reverse events)))
    ;; Any ESC ends the string, so exit fires before the backslash.
    (ghostel-test--control-mode-write term "\227Y\e")
    (should (eq 'exit (caar events)))
    (ghostel-test--control-mode-write term "\\after")
    (should (equal "B\303\227Y" (ghostel-test--control-mode-body events)))
    (should-not (seq-some (lambda (event) (multibyte-string-p (cdr event)))
                          events))))

(ert-deftest ghostel-test-control-mode-body-bytes ()
  "Control characters and every high byte reach the function unchanged."
  :tags '(native)
  (ghostel-test--with-control-mode (term events)
    (let ((body (concat "a\001b\tc"
                        (apply #'unibyte-string (number-sequence #x80 #xff)))))
      (ghostel-test--control-mode-write term (concat "\eP1000p" body "\e\\"))
      (should (equal body (ghostel-test--control-mode-body events))))))

(ert-deftest ghostel-test-control-mode-pty ()
  "A frame in PTY output reports its body bytes on every PTY backend."
  :tags '(native posix)
  (let* ((body (concat "a\001b"
                       (apply #'unibyte-string (number-sequence #x80 #xff))))
         (events nil)
         (ghostel-control-mode-function
          (lambda (event data) (push (cons event data) events)))
         ;; The frame must not depend on the process coding default.
         (default-process-coding-system '(latin-1-unix . latin-1-unix)))
    (ghostel-test--with-pty-matrix backend
      (ghostel-test--with-raw-echo-buffer (buf proc)
        (setq events nil)
        (ghostel--write-pty ghostel--term (concat "\eP1000p" body "\e\\"))
        (ghostel-test--wait-until (lambda () (eq 'exit (caar events))) proc)
        (should (equal body (ghostel-test--control-mode-body events)))))))

(ert-deftest ghostel-test-control-mode-other-dcs ()
  "Other DCS sequences report nothing."
  :tags '(native)
  (ghostel-test--with-control-mode (term events)
    (ghostel-test--control-mode-write term "\eP1001pX\e\\\eP$qm\e\\")
    (should-not events)))

(ert-deftest ghostel-test-control-mode-without-function ()
  "Without a function the body is discarded and output continues."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buffer term 24 80 100)
    (ghostel-test--control-mode-write term "\eP1000pHELLO\e\\after")
    (let ((text (ghostel--copy-all-text term)))
      (should (string-match-p "after" text))
      (should-not (string-match-p "HELLO" text)))))

(provide 'ghostel-control-mode-test)
;;; ghostel-control-mode-test.el ends here
