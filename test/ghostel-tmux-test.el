;;; ghostel-tmux-test.el --- Tests for ghostel-tmux -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure-Elisp tests for the tmux protocol layer (parser, octal decoder,
;; layout parser, hex encoder, command queue).  The end-to-end tmux
;; integration is covered by ghostel-tmux-integration-test.el and
;; verified live.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-tmux)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defmacro ghostel-tmux-test--with-controller (var &rest body)
  "Bind VAR to a fresh controller buffer, run BODY inside it."
  (declare (indent 1))
  `(let ((,var (generate-new-buffer " *ghostel-tmux-test-ctl*")))
     (unwind-protect
         (with-current-buffer ,var
           (ghostel-tmux-control-mode)
           ,@body)
       (kill-buffer ,var))))

(defun ghostel-tmux-test--feed (controller string)
  "Feed STRING into CONTROLLER's parser."
  (with-current-buffer controller
    (ghostel-tmux--feed-bytes string)))

;; ---------------------------------------------------------------------------
;; Octal escape decoder
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-decode-no-escapes ()
  (should (equal (ghostel-tmux--decode-output "hello world")
                 "hello world")))

(ert-deftest ghostel-tmux-test-decode-esc ()
  (should (equal (ghostel-tmux--decode-output "\\033[1mFOO\\033[0m")
                 "\x1b[1mFOO\x1b[0m")))

(ert-deftest ghostel-tmux-test-decode-crlf ()
  (should (equal (ghostel-tmux--decode-output "line1\\015\\012line2")
                 "line1\r\nline2")))

(ert-deftest ghostel-tmux-test-decode-bel ()
  (should (equal (ghostel-tmux--decode-output "\\007")
                 "\x07")))

(ert-deftest ghostel-tmux-test-decode-mixed ()
  (should (equal (ghostel-tmux--decode-output
                  "\\033[?2004hroot@host:/# \\015\\012")
                 "\x1b[?2004hroot@host:/# \r\n")))

(ert-deftest ghostel-tmux-test-decode-non-octal-backslash ()
  ;; \X (not three octal digits) is left verbatim
  (should (equal (ghostel-tmux--decode-output "a\\nb")
                 "a\\nb")))

(ert-deftest ghostel-tmux-test-decode-empty ()
  (should (equal (ghostel-tmux--decode-output "") "")))

(ert-deftest ghostel-tmux-test-decode-high-octal-single-byte ()
  ;; \310 must decode to the single raw byte 0xC8, not the two-byte
  ;; UTF-8 form of U+00C8 that `string' + binary encoding produces.
  (let ((decoded (ghostel-tmux--decode-output "\\310")))
    (should-not (multibyte-string-p decoded))
    (should (equal (append decoded nil) '(#xC8)))))

(ert-deftest ghostel-tmux-test-decode-high-octal-mixed-with-utf8 ()
  ;; Raw multibyte pane content mixed with a high octal escape: the
  ;; UTF-8 text keeps its bytes and the escape stays a single byte.
  (let ((decoded (ghostel-tmux--decode-output "×\\310")))
    (should-not (multibyte-string-p decoded))
    (should (equal (append decoded nil) '(#xC3 #x97 #xC8)))))

;; ---------------------------------------------------------------------------
;; Layout parser
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-layout-single-leaf ()
  (should (equal (ghostel-tmux--parse-layout "bd5b,80x24,0,0,0")
                 '((0 80 24 0 0)))))

(ert-deftest ghostel-tmux-test-layout-h-split ()
  (should (equal (ghostel-tmux--parse-layout
                  "f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}")
                 '((1 40 24 0 0) (2 40 24 40 0)))))

(ert-deftest ghostel-tmux-test-layout-v-split ()
  (should (equal (ghostel-tmux--parse-layout
                  "1234,80x24,0,0[80x12,0,0,3,80x12,0,12,4]")
                 '((3 80 12 0 0) (4 80 12 0 12)))))

(ert-deftest ghostel-tmux-test-layout-nested ()
  ;; Outer h-split: left leaf, right v-split.
  (should (equal (ghostel-tmux--parse-layout
                  "abcd,80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}")
                 '((1 40 24 0 0) (2 40 12 40 0) (3 40 12 40 12)))))

(ert-deftest ghostel-tmux-test-layout-empty-returns-nil ()
  (should (null (ghostel-tmux--parse-layout nil)))
  (should (null (ghostel-tmux--parse-layout ""))))

;; ---------------------------------------------------------------------------
;; Hex encoding for send-keys -H
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-hex-crlf ()
  (should (equal (ghostel-tmux--bytes-to-hex "\r\n") "0d 0a")))

(ert-deftest ghostel-tmux-test-hex-printable ()
  (should (equal (ghostel-tmux--bytes-to-hex "abc") "61 62 63")))

(ert-deftest ghostel-tmux-test-hex-esc-sequence ()
  (should (equal (ghostel-tmux--bytes-to-hex "\e[A")
                 "1b 5b 41")))

(ert-deftest ghostel-tmux-test-hex-empty ()
  (should (equal (ghostel-tmux--bytes-to-hex "") "")))

;; ---------------------------------------------------------------------------
;; Wire-format parser
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-parser-strips-dcs-preamble ()
  (ghostel-tmux-test--with-controller ctl
    (ghostel-tmux-test--feed ctl "\eP1000p%begin 1 2 0\r\n%end 1 2 0\r\n")
    (should (eq ghostel-tmux--parser-state 'idle))
    (should (string-empty-p ghostel-tmux--line-buffer))))

(ert-deftest ghostel-tmux-test-parser-session-changed ()
  (ghostel-tmux-test--with-controller ctl
    ;; Skip preamble/idle bootstrap by switching state directly.
    (setq ghostel-tmux--parser-state 'idle)
    (ghostel-tmux-test--feed ctl "%session-changed $42 work\r\n")
    (should (= ghostel-tmux--session-id 42))
    (should (equal ghostel-tmux--session-name "work"))))

(ert-deftest ghostel-tmux-test-parser-output-octal-decoded ()
  (let (called-with-pid called-with-data)
    (cl-letf (((symbol-function 'ghostel-tmux--on-output)
               (lambda (pid data)
                 (setq called-with-pid pid called-with-data data))))
      (ghostel-tmux-test--with-controller ctl
        (setq ghostel-tmux--parser-state 'idle)
        (ghostel-tmux-test--feed ctl
                                 "%output %5 hi\\015\\012\r\n")
        (should (= called-with-pid 5))
        (should (equal called-with-data "hi\\015\\012"))))))

(ert-deftest ghostel-tmux-test-parser-block-end-runs-cont ()
  (ghostel-tmux-test--with-controller ctl
    (setq ghostel-tmux--parser-state 'idle)
    (let ((received nil))
      (setq ghostel-tmux--command-in-flight
            (cons "display-message" (lambda (out) (setq received out))))
      (ghostel-tmux-test--feed
       ctl "%begin 1 7 0\r\nhello world\r\n%end 1 7 0\r\n")
      (should (equal received "hello world"))
      (should (eq ghostel-tmux--parser-state 'idle))
      (should (null ghostel-tmux--command-in-flight)))))

(ert-deftest ghostel-tmux-test-parser-block-error-runs-cont-with-nil ()
  (ghostel-tmux-test--with-controller ctl
    (setq ghostel-tmux--parser-state 'idle)
    (let ((called nil) (received 'unset))
      (setq ghostel-tmux--command-in-flight
            (cons "bad" (lambda (out)
                          (setq called t received out))))
      (ghostel-tmux-test--feed
       ctl "%begin 1 7 0\r\nbad cmd\r\n%error 1 7 0\r\n")
      (should called)
      (should (null received)))))

(ert-deftest ghostel-tmux-test-parser-block-payload-with-percent-end ()
  ;; A line in the block that *looks* like a terminator but has wrong tag
  ;; count must be treated as payload.
  (ghostel-tmux-test--with-controller ctl
    (setq ghostel-tmux--parser-state 'idle)
    (let ((received nil))
      (setq ghostel-tmux--command-in-flight
            (cons "x" (lambda (out) (setq received out))))
      (ghostel-tmux-test--feed
       ctl
       (concat
        "%begin 1 9 0\r\n"
        "%end notatag\r\n"          ; non-numeric — payload
        "real line\r\n"
        "%end 1 9 0\r\n"))
      (should (equal received "%end notatag\nreal line")))))

(ert-deftest ghostel-tmux-test-parser-block-forged-end-is-payload ()
  ;; A terminator-shaped line whose TIME/CMD fields don't match the
  ;; opening %begin tag is block payload (e.g. a captured pane that was
  ;; showing a control-mode transcript), not the block's end.
  (ghostel-tmux-test--with-controller ctl
    (setq ghostel-tmux--parser-state 'idle)
    (let ((received nil))
      (setq ghostel-tmux--command-in-flight
            (cons "capture-pane" (lambda (out) (setq received out))))
      (ghostel-tmux-test--feed
       ctl
       (concat
        "%begin 1622 17 0\r\n"
        "%end 99 99 0\r\n"           ; forged — wrong TIME/CMD
        "real line\r\n"
        "%end 1622 17 0\r\n"))
      (should (equal received "%end 99 99 0\nreal line"))
      (should (eq ghostel-tmux--parser-state 'idle)))))

(ert-deftest ghostel-tmux-test-parser-multi-chunk ()
  ;; Notification arrives split across two filter calls.
  (ghostel-tmux-test--with-controller ctl
    (setq ghostel-tmux--parser-state 'idle)
    (ghostel-tmux-test--feed ctl "%session-cha")
    (should (eq ghostel-tmux--parser-state 'idle))
    (should (null ghostel-tmux--session-id))
    (ghostel-tmux-test--feed ctl "nged $7 main\r\n")
    (should (= ghostel-tmux--session-id 7))
    (should (equal ghostel-tmux--session-name "main"))))

(ert-deftest ghostel-tmux-test-parser-ignores-bare-lines ()
  ;; tmux delivers async `run-shell' output as bare lines outside any
  ;; %begin/%end block; they must be dropped, not wedge the parser.
  (ghostel-tmux-test--with-controller ctl
    (setq ghostel-tmux--parser-state 'idle)
    (ghostel-tmux-test--feed ctl "run-shell output line\r\n")
    (should (eq ghostel-tmux--parser-state 'idle))
    ;; The stream keeps parsing afterwards.
    (ghostel-tmux-test--feed ctl "%session-changed $7 main\r\n")
    (should (= ghostel-tmux--session-id 7))))

(ert-deftest ghostel-tmux-test-parser-junk-before-first-notification ()
  ;; With the DCS preamble missing (wrapper script, tmux warning line),
  ;; junk preceding the first `%' line must not prevent the parser from
  ;; picking up the protocol.
  (ghostel-tmux-test--with-controller ctl
    (should (eq ghostel-tmux--parser-state 'preamble))
    (ghostel-tmux-test--feed
     ctl "some config warning\r\n%session-changed $3 demo\r\n")
    (should (eq ghostel-tmux--parser-state 'idle))
    (should (= ghostel-tmux--session-id 3))))

;; ---------------------------------------------------------------------------
;; Command queue
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-command-queue-fifo ()
  (ghostel-tmux-test--with-controller ctl
    (let ((sent nil))
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent)))
                ((symbol-function 'process-live-p) (lambda (_) t)))
        (setq ghostel-tmux--controller-process 'fake)
        (ghostel-tmux--queue-command "first" #'ignore)
        (ghostel-tmux--queue-command "second" #'ignore)
        ;; Only the first command should have been sent.
        (should (equal (nreverse sent) '("first\n")))
        (should (equal (caar ghostel-tmux--command-queue) "second"))
        ;; Simulate %end terminating the first command.
        (setq ghostel-tmux--command-in-flight nil)
        (ghostel-tmux--pump-command-queue)
        (should (member "second\n" sent))))))

(ert-deftest ghostel-tmux-test-send-bytes-waits-behind-in-flight-command ()
  ;; Keystrokes must not overtake a command awaiting its reply block:
  ;; tmux pairs reply blocks to command lines in wire order, so a raw
  ;; send while another command is in flight shifts every subsequent
  ;; pairing by one.
  (ghostel-tmux-test--with-controller ctl
    (let ((sent nil))
      (with-current-buffer ctl
        (setq ghostel-tmux--controller-process 'fake-proc
              ghostel-tmux--command-in-flight (cons "list-windows" #'ignore)))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent))))
        (ghostel-tmux--send-bytes-from-pane ctl 0 "x"))
      (should (null sent))
      (with-current-buffer ctl
        (should (= 1 (length ghostel-tmux--command-queue)))
        (should (string-prefix-p "send-keys -t %0 -H "
                                 (caar ghostel-tmux--command-queue)))))))

(ert-deftest ghostel-tmux-test-pump-defers-inside-feed ()
  ;; Sends triggered from inside the feed (a continuation queueing a
  ;; follow-up command) must be deferred to a timer: a blocking process
  ;; write can re-enter process filters and deliver protocol bytes out
  ;; of order.
  (ghostel-tmux-test--with-controller ctl
    (let ((sent nil) (timers nil))
      (with-current-buffer ctl
        (setq ghostel-tmux--parser-state 'idle
              ghostel-tmux--controller-process 'fake-proc
              ghostel-tmux--command-in-flight
              (cons "list-windows"
                    (lambda (_out)
                      (ghostel-tmux--queue-command "capture-pane")))))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent)))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args)
                   (push (cons fn args) timers))))
        (ghostel-tmux-test--feed ctl "%begin 1 1 0\r\n%end 1 1 0\r\n")
        ;; Nothing sent synchronously; a deferred pump was scheduled.
        (should (null sent))
        (should (= 1 (length timers)))
        ;; Firing the timer outside the feed performs the send.
        (pcase-let ((`(,fn . ,args) (car timers)))
          (apply fn args))
        (should (equal sent '("capture-pane\n")))))))

;; ---------------------------------------------------------------------------
;; Buffer naming
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-default-buffer-name ()
  (should (equal (ghostel-tmux--default-buffer-name "work" "shell" 3)
                 "*ghostel-tmux:work:shell%3*"))
  (should (equal (ghostel-tmux--default-buffer-name "work" nil 3)
                 "*ghostel-tmux:work:<unnamed>%3*"))
  (should (equal (ghostel-tmux--default-buffer-name nil "shell" 3)
                 "*ghostel-tmux:session:shell%3*")))

;; ---------------------------------------------------------------------------
;; Prefix-key dispatch (`C-b ...')
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-prefix-target-formats-pane-id ()
  (with-temp-buffer
    (setq-local ghostel-tmux--pane-id 7)
    (should (equal (ghostel-tmux--prefix-target) "%7")))
  (with-temp-buffer
    (setq-local ghostel-tmux--pane-id nil)
    (should (null (ghostel-tmux--prefix-target)))))

(ert-deftest ghostel-tmux-test-cmd-errors-without-controller ()
  (with-temp-buffer
    (setq-local ghostel-tmux--controller-buffer nil)
    (should-error (ghostel-tmux--cmd "list-sessions")
                  :type 'user-error)))

(ert-deftest ghostel-tmux-test-cmd-sends-to-controller ()
  (let ((sent nil))
    (ghostel-tmux-test--with-controller ctl
      (setq ghostel-tmux--controller-process 'fake-proc)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent))))
        (with-temp-buffer
          (setq-local ghostel-tmux--controller-buffer ctl)
          (ghostel-tmux--cmd "split-window -h"))))
    (should (equal sent '("split-window -h\n")))))

(ert-deftest ghostel-tmux-test-prefix-split-h-builds-vertical-split ()
  (let ((cmds nil))
    (cl-letf (((symbol-function 'ghostel-tmux--cmd)
               (lambda (c) (push c cmds))))
      (with-temp-buffer
        (setq-local ghostel-tmux--pane-id 3)
        (ghostel-tmux--prefix-split-h)))
    (should (equal cmds '("split-window -v -t %3")))))

(ert-deftest ghostel-tmux-test-prefix-split-v-builds-horizontal-split ()
  (let ((cmds nil))
    (cl-letf (((symbol-function 'ghostel-tmux--cmd)
               (lambda (c) (push c cmds))))
      (with-temp-buffer
        (setq-local ghostel-tmux--pane-id 4)
        (ghostel-tmux--prefix-split-v)))
    (should (equal cmds '("split-window -h -t %4")))))

(ert-deftest ghostel-tmux-test-prefix-zoom ()
  (let ((cmds nil))
    (cl-letf (((symbol-function 'ghostel-tmux--cmd)
               (lambda (c) (push c cmds))))
      (with-temp-buffer
        (setq-local ghostel-tmux--pane-id 1)
        (ghostel-tmux--prefix-zoom)))
    (should (equal cmds '("resize-pane -Z -t %1")))))

;; Window-level commands target the session (`$SID') or window (`@WID'),
;; not the pane (`%pid') — tmux doesn't accept a pane target for these.

(ert-deftest ghostel-tmux-test-session-target-from-controller ()
  (ghostel-tmux-test--with-controller ctl
    (setq ghostel-tmux--session-id 4)
    (with-temp-buffer
      (setq-local ghostel-tmux--controller-buffer ctl)
      (should (equal (ghostel-tmux--session-target) "$4")))))

(ert-deftest ghostel-tmux-test-session-target-nil-without-controller ()
  (with-temp-buffer
    (setq-local ghostel-tmux--controller-buffer nil)
    (should (null (ghostel-tmux--session-target)))))

(ert-deftest ghostel-tmux-test-window-target-from-buffer-local ()
  (with-temp-buffer
    (setq-local ghostel-tmux--window-id 7)
    (should (equal (ghostel-tmux--window-target) "@7")))
  (with-temp-buffer
    (setq-local ghostel-tmux--window-id nil)
    (should (null (ghostel-tmux--window-target)))))

(ert-deftest ghostel-tmux-test-prefix-next-window-sends-select-window ()
  ;; `C-t n' only sends `select-window' to tmux; the visible switch
  ;; arrives reactively via `%window-pane-changed' →
  ;; `--on-window-pane-changed' once tmux acks.
  (let ((cmds nil)
        (displayed nil))
    (ghostel-tmux-test--with-controller ctl
      (setq ghostel-tmux--window-order '(10 20)
            ghostel-tmux--windows (make-hash-table)
            ghostel-tmux--panes (make-hash-table))
      (puthash 10 (list :name "w1" :panes (list 1)) ghostel-tmux--windows)
      (puthash 20 (list :name "w2" :panes (list 2)) ghostel-tmux--windows)
      (cl-letf (((symbol-function 'ghostel-tmux--cmd)
                 (lambda (c) (push c cmds)))
                ((symbol-function 'ghostel-tmux--display-pane-in-window)
                 (lambda (buf _win) (push buf displayed))))
        (with-temp-buffer
          (setq-local ghostel-tmux--controller-buffer ctl
                      ghostel-tmux--window-id 10
                      ghostel-tmux--pane-id 1)
          (ghostel-tmux--prefix-next-window))))
    (should (equal cmds '("select-window -t @20")))
    (should (null displayed))))

(ert-deftest ghostel-tmux-test-prefix-prev-window-wraps-around ()
  (let ((cmds nil))
    (ghostel-tmux-test--with-controller ctl
      (setq ghostel-tmux--window-order '(10 20)
            ghostel-tmux--windows (make-hash-table)
            ghostel-tmux--panes (make-hash-table))
      (puthash 10 (list :name "w1" :panes (list 1)) ghostel-tmux--windows)
      (puthash 20 (list :name "w2" :panes (list 2)) ghostel-tmux--windows)
      (cl-letf (((symbol-function 'ghostel-tmux--cmd)
                 (lambda (c) (push c cmds))))
        ;; From window 10, `prev' wraps to window 20.
        (with-temp-buffer
          (setq-local ghostel-tmux--controller-buffer ctl
                      ghostel-tmux--window-id 10
                      ghostel-tmux--pane-id 1)
          (ghostel-tmux--prefix-prev-window))))
    (should (equal cmds '("select-window -t @20")))))

(ert-deftest ghostel-tmux-test-prefix-next-window-noop-on-single-window ()
  ;; With only one window, next/prev are silent no-ops — no command,
  ;; no buffer switch, no error.
  (let ((cmds nil))
    (ghostel-tmux-test--with-controller ctl
      (setq ghostel-tmux--window-order '(10)
            ghostel-tmux--windows (make-hash-table)
            ghostel-tmux--panes (make-hash-table))
      (puthash 10 (list :name "w1" :panes (list 1)) ghostel-tmux--windows)
      (cl-letf (((symbol-function 'ghostel-tmux--cmd)
                 (lambda (c) (push c cmds))))
        (with-temp-buffer
          (setq-local ghostel-tmux--controller-buffer ctl
                      ghostel-tmux--window-id 10
                      ghostel-tmux--pane-id 1)
          (ghostel-tmux--prefix-next-window))))
    (should (null cmds))))

(ert-deftest ghostel-tmux-test-prefix-new-window-uses-session-target ()
  (let ((cmds nil))
    (ghostel-tmux-test--with-controller ctl
      (setq ghostel-tmux--session-id 5)
      (cl-letf (((symbol-function 'ghostel-tmux--cmd)
                 (lambda (c) (push c cmds))))
        (with-temp-buffer
          (setq-local ghostel-tmux--controller-buffer ctl
                      ghostel-tmux--pane-id 99)
          (ghostel-tmux--prefix-new-window))))
    (should (equal cmds '("new-window -t $5")))))

(ert-deftest ghostel-tmux-test-prefix-kill-window-uses-window-target ()
  (let ((cmds nil))
    (cl-letf (((symbol-function 'ghostel-tmux--cmd)
               (lambda (c) (push c cmds))))
      (with-temp-buffer
        (setq-local ghostel-tmux--window-id 3
                    ghostel-tmux--pane-id 99)
        (ghostel-tmux--prefix-kill-window)))
    (should (equal cmds '("kill-window -t @3")))))

(ert-deftest ghostel-tmux-test-prefix-kill-pane-still-uses-pane-target ()
  ;; kill-pane really does want the pane target — regression guard.
  (let ((cmds nil))
    (cl-letf (((symbol-function 'ghostel-tmux--cmd)
               (lambda (c) (push c cmds))))
      (with-temp-buffer
        (setq-local ghostel-tmux--pane-id 8)
        (ghostel-tmux--prefix-kill-pane)))
    (should (equal cmds '("kill-pane -t %8")))))

(ert-deftest ghostel-tmux-test-prefix-keymap-bindings-installed ()
  (should (eq (lookup-key ghostel-tmux-prefix-map "\"")
              #'ghostel-tmux--prefix-split-h))
  (should (eq (lookup-key ghostel-tmux-prefix-map "%")
              #'ghostel-tmux--prefix-split-v))
  (should (eq (lookup-key ghostel-tmux-prefix-map "c")
              #'ghostel-tmux--prefix-new-window))
  (should (eq (lookup-key ghostel-tmux-prefix-map "x")
              #'ghostel-tmux--prefix-kill-pane))
  (should (eq (lookup-key ghostel-tmux-prefix-map "n")
              #'ghostel-tmux--prefix-next-window))
  (should (eq (lookup-key ghostel-tmux-prefix-map "d")
              #'ghostel-tmux-detach)))

(ert-deftest ghostel-tmux-test-prefix-keymap-numeric-bindings ()
  (dotimes (n 10)
    (let ((binding (lookup-key ghostel-tmux-prefix-map
                               (kbd (number-to-string n)))))
      (should (commandp binding)))))

(ert-deftest ghostel-tmux-test-pane-mode-map-default-prefix-is-ctrl-t ()
  ;; Default `ghostel-tmux-prefix-key' is "C-t" and routes to the
  ;; prefix sub-keymap.  The keymap is the pane minor-mode's own
  ;; `:keymap', which composes with the local input-mode map via the
  ;; standard minor-mode dispatch.
  (should (equal ghostel-tmux-prefix-key "C-t"))
  (should (eq (lookup-key ghostel-tmux-pane-mode-map (kbd "C-t"))
              ghostel-tmux-prefix-map)))

(ert-deftest ghostel-tmux-test-pane-mode-map-prefix-self-binding ()
  ;; `<prefix> <prefix>' sends the prefix byte raw to the underlying
  ;; program, matching tmux's convention.
  (should (eq (lookup-key ghostel-tmux-prefix-map (kbd "C-t"))
              #'ghostel-tmux--prefix-self-insert)))

(ert-deftest ghostel-tmux-test-pane-mode-map-customization-rebinds ()
  ;; Setting `ghostel-tmux-prefix-key' via customize moves the binding
  ;; in the pane keymap and in the prefix sub-map's self-binding.
  (let ((orig ghostel-tmux-prefix-key))
    (unwind-protect
        (progn
          (customize-set-variable 'ghostel-tmux-prefix-key "C-b")
          (should (eq (lookup-key ghostel-tmux-pane-mode-map (kbd "C-b"))
                      ghostel-tmux-prefix-map))
          (should-not (lookup-key ghostel-tmux-pane-mode-map (kbd "C-t")))
          (should (eq (lookup-key ghostel-tmux-prefix-map (kbd "C-b"))
                      #'ghostel-tmux--prefix-self-insert))
          (should-not (lookup-key ghostel-tmux-prefix-map (kbd "C-t"))))
      (customize-set-variable 'ghostel-tmux-prefix-key orig))))

(ert-deftest ghostel-tmux-test-pane-mode-wins-over-local-map ()
  ;; Activating the minor mode in a buffer must make the prefix win
  ;; over a local-map binding for the same key.
  (with-temp-buffer
    (let ((shadow-map (make-sparse-keymap)))
      (define-key shadow-map (kbd "C-t") #'ignore)
      (use-local-map shadow-map)
      (should (eq (key-binding (kbd "C-t")) #'ignore))
      (ghostel-tmux-pane-mode 1)
      (unwind-protect
          (should (eq (key-binding (kbd "C-t")) ghostel-tmux-prefix-map))
        (ghostel-tmux-pane-mode -1)))))

(ert-deftest ghostel-tmux-test-pane-mode-composes-with-local-map ()
  ;; Bindings on the local map for unrelated keys must remain reachable
  ;; — the whole reason we use a minor-mode keymap instead of an
  ;; emulation-alist override.
  (with-temp-buffer
    (let ((local (make-sparse-keymap)))
      (define-key local (kbd "RET") #'newline)
      (use-local-map local))
    (ghostel-tmux-pane-mode 1)
    (unwind-protect
        (progn
          (should (eq (key-binding (kbd "RET")) #'newline))
          (should (eq (key-binding (kbd "C-t")) ghostel-tmux-prefix-map)))
      (ghostel-tmux-pane-mode -1))))

(ert-deftest ghostel-tmux-test-pane-mode-map-cc-bindings-installed ()
  (should (eq (lookup-key ghostel-tmux-pane-mode-map (kbd "C-c C-n"))
              #'ghostel-tmux-next-pane))
  (should (eq (lookup-key ghostel-tmux-pane-mode-map (kbd "C-c C-p"))
              #'ghostel-tmux-prev-pane))
  (should (eq (lookup-key ghostel-tmux-pane-mode-map (kbd "C-c C-s"))
              #'ghostel-tmux-switch-pane))
  (should (eq (lookup-key ghostel-tmux-pane-mode-map (kbd "C-c C-d"))
              #'ghostel-tmux-detach)))

;; ---------------------------------------------------------------------------
;; on-window-renamed regression (preserves session name across buffer switch)
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-window-renamed-preserves-session-name ()
  ;; Regression: rename-buffer used to look up session-name AFTER
  ;; switching to the pane buffer, where it's nil.  Pane buffers ended up
  ;; named "*ghostel-tmux:nil:bash%0*" instead of using the session name.
  (ghostel-tmux-test--with-controller ctl
    (let ((pane-buf (generate-new-buffer
                     "*ghostel-tmux:work:initial%5*")))
      (unwind-protect
          (progn
            (with-current-buffer pane-buf
              (setq-local ghostel-tmux--pane-id 5
                          ghostel-tmux--window-id 0))
            (with-current-buffer ctl
              (setq ghostel-tmux--session-name "work")
              (puthash 0 (list :name "initial" :panes (list 5))
                       ghostel-tmux--windows)
              (puthash 5 pane-buf ghostel-tmux--panes)
              (ghostel-tmux--on-window-renamed 0 "renamed"))
            (should (equal (buffer-name pane-buf)
                           "*ghostel-tmux:work:renamed%5*")))
        (when (buffer-live-p pane-buf) (kill-buffer pane-buf))))))

;; ---------------------------------------------------------------------------
;; Display-pane-in-window: terminal sized to window dimensions
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-display-pane-noop-on-dead-window ()
  ;; Should not error when given a dead window or buffer.
  (let ((dead-buf (generate-new-buffer " *gone*")))
    (kill-buffer dead-buf)
    (should-not (ghostel-tmux--display-pane-in-window
                 dead-buf (selected-window)))))

(ert-deftest ghostel-tmux-test-on-layout-change-sizes-hidden-panes-only ()
  ;; Layout-change applies tmux's geometry to panes that aren't
  ;; currently displayed.  For visible panes, the Emacs window size
  ;; is authoritative (via `--apply-pane-size' / zoom) and applying
  ;; layout geometry would fight zoom and shrink the active pane.
  (ghostel-tmux-test--with-controller ctl
    (let ((sizes nil)
          (existing-pane (generate-new-buffer "*ghostel-tmux:s:w%0*"))
          (created-pane nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                     (lambda (_term rows cols)
                       (push (cons cols rows) sizes)))
                    ;; Pretend pane %0 is not visible in any window
                    ;; (tests run in batch mode without windows).
                    ((symbol-function 'get-buffer-window-list)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel-tmux--get-or-create-pane)
                     (lambda (_ctl pid _wid _name)
                       (cond
                        ((= pid 0) existing-pane)
                        (t
                         (or created-pane
                             (setq created-pane
                                   (let ((b (generate-new-buffer
                                             "*ghostel-tmux:s:w%1*")))
                                     (with-current-buffer b
                                       (setq-local ghostel--term 'fake
                                                   ghostel--term-cols 1
                                                   ghostel--term-rows 1
                                                   ghostel-tmux--initialized t))
                                     b))))))))
            (with-current-buffer existing-pane
              (setq-local ghostel--term 'fake
                          ghostel--term-cols 1
                          ghostel--term-rows 1
                          ghostel-tmux--initialized t))
            (with-current-buffer ctl
              (ghostel-tmux--on-layout-change
               0 "1234,80x24,0,0[80x12,0,0,0,80x12,0,12,1]"))
            ;; Hidden panes get the layout geometry applied.
            (should (member (cons 80 12) sizes))
            (should (= (cl-count (cons 80 12) sizes :test #'equal) 2)))
        (when (buffer-live-p existing-pane) (kill-buffer existing-pane))
        (when (buffer-live-p created-pane) (kill-buffer created-pane))))))

(ert-deftest ghostel-tmux-test-on-layout-change-skips-visible-panes ()
  ;; Counterpart to the previous test: a pane that IS in a window
  ;; must NOT be resized by layout-change.
  (ghostel-tmux-test--with-controller ctl
    (let ((sizes nil)
          (visible-pane (generate-new-buffer "*ghostel-tmux:visible%0*")))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                     (lambda (_t rows cols) (push (cons cols rows) sizes)))
                    ((symbol-function 'get-buffer-window-list)
                     (lambda (buf &rest _)
                       (when (eq buf visible-pane) '(fake-window))))
                    ((symbol-function 'ghostel-tmux--get-or-create-pane)
                     (lambda (_ctl _pid _wid _name) visible-pane)))
            (with-current-buffer visible-pane
              (setq-local ghostel--term 'fake
                          ghostel--term-cols 80
                          ghostel--term-rows 40
                          ghostel-tmux--initialized t))
            (with-current-buffer ctl
              ;; Single visible pane reported by tmux at half-height.
              (ghostel-tmux--on-layout-change
               0 "1234,80x24,0,0,0"))
            (should-not sizes))
        (when (buffer-live-p visible-pane) (kill-buffer visible-pane))))))

(ert-deftest ghostel-tmux-test-follow-active-pane-no-buffer ()
  ;; If the buffer for the active pane doesn't exist yet (e.g.
  ;; `%window-pane-changed' raced ahead of `%layout-change'),
  ;; `--follow-active-pane' must no-op rather than error.  The
  ;; subsequent `--on-layout-change' picks up the deferred redirect.
  (ghostel-tmux-test--with-controller ctl
    (let ((displayed nil))
      (cl-letf (((symbol-function 'ghostel-tmux--display-pane-in-window)
                 (lambda (buf _window) (push buf displayed))))
        (with-current-buffer ctl
          (ghostel-tmux--follow-active-pane 99)
          (should (null displayed)))))))

(ert-deftest ghostel-tmux-test-pane-changed-records-and-follows ()
  ;; `--on-window-pane-changed' updates `--active-pane-id' AND drives
  ;; the Emacs-side switch by calling `--follow-active-pane'.  This is
  ;; the single trigger for visible pane switches under the
  ;; tmux-source-of-truth model.
  (ghostel-tmux-test--with-controller ctl
    (let ((followed nil))
      (cl-letf (((symbol-function 'ghostel-tmux--follow-active-pane)
                 (lambda (pid) (push pid followed))))
        (with-current-buffer ctl
          (ghostel-tmux--on-window-pane-changed 7 42))
        (should (equal followed '(42)))
        (with-current-buffer ctl
          (should (= ghostel-tmux--active-pane-id 42)))))))

(ert-deftest ghostel-tmux-test-cycle-pane-sends-select-pane ()
  ;; `--cycle-pane' (C-c C-n / C-c C-p) sends `select-pane' to tmux
  ;; and lets `%window-pane-changed' drive the visible switch.  No
  ;; direct `--display-pane-in-window' call.
  (let ((cmds nil)
        (displayed nil)
        (pane-a (generate-new-buffer "*test-cp-a*"))
        (pane-b (generate-new-buffer "*test-cp-b*")))
    (unwind-protect
        (ghostel-tmux-test--with-controller ctl
          (with-current-buffer pane-a
            (setq-local ghostel-tmux--pane-id 1))
          (with-current-buffer pane-b
            (setq-local ghostel-tmux--pane-id 2))
          (cl-letf (((symbol-function 'ghostel-tmux--cmd)
                     (lambda (c) (push c cmds)))
                    ((symbol-function 'ghostel-tmux--display-pane-in-window)
                     (lambda (buf _w) (push buf displayed)))
                    ((symbol-function 'ghostel-tmux--pane-list)
                     (lambda (_ctl) (list pane-a pane-b))))
            (with-current-buffer pane-a
              (setq-local ghostel-tmux--controller-buffer ctl)
              (ghostel-tmux-next-pane)))
          (should (equal cmds '("select-pane -t %2")))
          (should (null displayed)))
      (kill-buffer pane-a)
      (kill-buffer pane-b))))

(ert-deftest ghostel-tmux-test-switch-pane-sends-select-pane ()
  ;; Same source-of-truth model: completing-read pane switching sends
  ;; `select-pane' instead of directly displaying.
  (let ((cmds nil)
        (displayed nil)
        (pane-a (generate-new-buffer "*test-sp-a*"))
        (pane-b (generate-new-buffer "*test-sp-b*")))
    (unwind-protect
        (ghostel-tmux-test--with-controller ctl
          (with-current-buffer pane-a
            (setq-local ghostel-tmux--pane-id 1))
          (with-current-buffer pane-b
            (setq-local ghostel-tmux--pane-id 2))
          (cl-letf (((symbol-function 'ghostel-tmux--cmd)
                     (lambda (c) (push c cmds)))
                    ((symbol-function 'ghostel-tmux--display-pane-in-window)
                     (lambda (buf _w) (push buf displayed)))
                    ((symbol-function 'ghostel-tmux--pane-list)
                     (lambda (_ctl) (list pane-a pane-b)))
                    ((symbol-function 'completing-read)
                     (lambda (_p _c &rest _) (buffer-name pane-b))))
            (with-current-buffer pane-a
              (setq-local ghostel-tmux--controller-buffer ctl)
              (ghostel-tmux-switch-pane)))
          (should (equal cmds '("select-pane -t %2")))
          (should (null displayed)))
      (kill-buffer pane-a)
      (kill-buffer pane-b))))

(ert-deftest ghostel-tmux-test-layout-change-redirects-after-deferred-pane-changed ()
  ;; Race: `%window-pane-changed' arrives before `%layout-change'
  ;; materializes the new pane buffer.  `--on-window-pane-changed'
  ;; records the active id but its `--follow-active-pane' no-ops
  ;; because no pane buffer exists yet.  When `--on-layout-change'
  ;; subsequently creates the buffer, it must re-trigger the redirect.
  (ghostel-tmux-test--with-controller ctl
    (let ((followed nil)
          (created-pane nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel-tmux--get-or-create-pane)
                     (lambda (_ctl pid _wid _name)
                       (or created-pane
                           (setq created-pane
                                 (let ((b (generate-new-buffer
                                           "*ghostel-tmux:deferred%99*")))
                                   (with-current-buffer b
                                     (setq-local ghostel--term 'fake
                                                 ghostel--term-cols 1
                                                 ghostel--term-rows 1
                                                 ghostel-tmux--initialized t))
                                   (puthash pid b ghostel-tmux--panes)
                                   b)))))
                    ((symbol-function 'ghostel--set-size-with-cell-dims)
                     (lambda (&rest _) nil))
                    ((symbol-function 'get-buffer-window-list)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel-tmux--follow-active-pane)
                     (lambda (pid) (push pid followed))))
            (with-current-buffer ctl
              (ghostel-tmux--on-window-pane-changed 0 99)
              (setq followed nil)
              (ghostel-tmux--on-layout-change
               0 "1234,80x24,0,0,99"))
            (should (equal followed '(99))))
        (when (buffer-live-p created-pane) (kill-buffer created-pane))))))

(ert-deftest ghostel-tmux-test-pane-mode-installs-buffer-change-hook ()
  ;; Tab-line clicks (and other paths that call `switch-to-buffer'
  ;; directly) need the resize via `window-buffer-change-functions'.
  (let ((buf (generate-new-buffer "*ghostel-tmux:bch%0*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-tmux-pane-mode 1)
          (should (memq #'ghostel-tmux--on-window-buffer-change
                        window-buffer-change-functions)))
      (kill-buffer buf))))

(ert-deftest ghostel-tmux-test-window-resized-accepts-window-arg ()
  ;; Regression: `window-size-change-functions' buffer-local hooks
  ;; receive the WINDOW (not the frame), with the buffer current.  An
  ;; earlier (eq frame (selected-frame)) guard made the function a
  ;; silent no-op so Emacs window resizes never reached tmux.
  (let* ((ctl (generate-new-buffer "*ghostel-tmux:resize-ctl%0*"))
         (pane (generate-new-buffer "*ghostel-tmux:resize-pane%0*"))
         (sent nil))
    (unwind-protect
        (progn
          (with-current-buffer ctl
            (setq-local ghostel-tmux--controller-process 'fake-proc))
          (with-current-buffer pane
            (ghostel-tmux-pane-mode 1)
            (setq-local ghostel-tmux--controller-buffer ctl
                        ghostel--term-cols 80
                        ghostel--term-rows 24
                        ghostel--term nil)
            (cl-letf (((symbol-function 'ghostel-tmux--smallest-window-size)
                       (lambda (_) (cons 120 40)))
                      ((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'process-send-string)
                       (lambda (_proc s) (push s sent))))
              (ghostel-tmux--window-resized (selected-window)))
            (should (equal ghostel--term-cols 120))
            (should (equal ghostel--term-rows 40))
            (should (equal sent '("refresh-client -C 120,40\n")))))
      (kill-buffer pane)
      (kill-buffer ctl))))

(ert-deftest ghostel-tmux-test-window-resized-ignores-dead-window ()
  (let ((buf (generate-new-buffer "*ghostel-tmux:resize-dead%0*"))
        (called nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-tmux-pane-mode 1)
          (setq-local ghostel-tmux--controller-buffer buf)
          (cl-letf (((symbol-function 'ghostel-tmux--smallest-window-size)
                     (lambda (_) (setq called t) (cons 80 24))))
            (ghostel-tmux--window-resized 'not-a-live-window))
          (should-not called))
      (kill-buffer buf))))

(ert-deftest ghostel-tmux-test-on-window-buffer-change-resizes ()
  ;; The window-buffer-change hook routes through `--apply-pane-size'.
  (let ((buf (generate-new-buffer "*ghostel-tmux:bch-r%0*"))
        (resized nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel-tmux--apply-pane-size)
                   (lambda (b w) (push (cons b w) resized))))
          (with-current-buffer buf
            (ghostel-tmux-pane-mode 1)
            (setq-local ghostel-tmux--controller-buffer buf)
            (cl-letf (((symbol-function 'window-live-p) (lambda (_) t))
                      ((symbol-function 'window-buffer)
                       (lambda (_) buf)))
              (ghostel-tmux--on-window-buffer-change 'fake-window))
            (should (equal resized
                           (list (cons buf 'fake-window))))))
      (kill-buffer buf))))

;; ---------------------------------------------------------------------------
;; ghostel-tmux--spawn-controller command construction
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-spawn-controller-attach-cmd ()
  (let ((seen-cmd nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest plist)
                 (setq seen-cmd (plist-get plist :command))
                 'fake-proc))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore))
      (let ((buf (ghostel-tmux--spawn-controller
                  "demo" '("attach-session" "-t" "demo"))))
        (kill-buffer buf)))
    (should (equal seen-cmd
                   '("tmux" "-CC" "attach-session" "-t" "demo")))))

(ert-deftest ghostel-tmux-test-spawn-controller-new-cmd ()
  (let ((seen-cmd nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest plist)
                 (setq seen-cmd (plist-get plist :command))
                 'fake-proc))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore))
      (let ((buf (ghostel-tmux--spawn-controller
                  "fresh" '("new-session" "-As" "fresh"))))
        (kill-buffer buf)))
    (should (equal seen-cmd
                   '("tmux" "-CC" "new-session" "-As" "fresh")))))

;; ---------------------------------------------------------------------------
;; Detach
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-detach-dedicated-kills-process ()
  ;; Dedicated controller (`ghostel-tmux-control-mode' buffer): the
  ;; tmux -CC subprocess belongs to ghostel-tmux and must be killed.
  (ghostel-tmux-test--with-controller ctl
    (let ((deleted nil)
          (sent nil))
      (with-current-buffer ctl
        (setq ghostel-tmux--controller-process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent)))
                ((symbol-function 'accept-process-output) #'ignore)
                ((symbol-function 'delete-process)
                 (lambda (p) (setq deleted p))))
        (with-current-buffer ctl
          (ghostel-tmux-detach)))
      (should (member "detach-client\n" sent))
      (should (eq deleted 'fake-proc)))))

;; ---------------------------------------------------------------------------
;; Unknown pane / backfill / reset / sentinel / list-windows
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-test-on-output-drops-unknown-pane ()
  ;; A `%output' for a pane id we don't know about must be silently
  ;; dropped (per the documented startup-ordering fragility) rather
  ;; than throwing.
  (ghostel-tmux-test--with-controller ctl
    (with-current-buffer ctl
      (puthash 0 (current-buffer) ghostel-tmux--panes)
      ;; Different pane id than what we registered:
      (should-not (ghostel-tmux--on-output 999 "junk")))))

(ert-deftest ghostel-tmux-test-on-output-before-init-dropped ()
  ;; %output arriving before the capture-pane backfill completes is
  ;; already contained in the `visible' snapshot; replaying it would
  ;; duplicate the bytes.
  (ghostel-tmux-test--with-controller ctl
    (let ((pane (generate-new-buffer "*ghostel-tmux:pre-init%0*"))
          (written nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--write-vt)
                     (lambda (_term data) (push data written)))
                    ((symbol-function 'ghostel--invalidate) #'ignore))
            (with-current-buffer pane
              (setq-local ghostel--term 'fake))
            (with-current-buffer ctl
              (puthash 0 pane ghostel-tmux--panes)
              (ghostel-tmux--on-output 0 "too-early")
              (should (null written))
              (with-current-buffer pane
                (setq ghostel-tmux--initialized t))
              (ghostel-tmux--on-output 0 "on-time")
              (should (equal written '("on-time")))))
        (when (buffer-live-p pane) (kill-buffer pane))))))

(ert-deftest ghostel-tmux-test-history-feeds-block-payload-raw ()
  ;; %begin/%end block payloads are NOT octal-escaped by tmux (unlike
  ;; %output), so literal backslash text in captured pane content must
  ;; survive the backfill as text, not decode into control bytes.
  (ghostel-tmux-test--with-controller ctl
    (let ((pane (generate-new-buffer "*ghostel-tmux:raw%0*"))
          (written nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--write-vt)
                     (lambda (_term data) (push data written)))
                    ((symbol-function 'ghostel--invalidate) #'ignore))
            (with-current-buffer pane
              (setq-local ghostel--term 'fake))
            (with-current-buffer ctl
              (puthash 0 pane ghostel-tmux--panes))
            (ghostel-tmux--receive-pane-history ctl 0 'history
                                                "literal \\033[31m text")
            (should (equal written '("literal \\033[31m text\n")))
            (should (with-current-buffer pane
                      (not ghostel-tmux--initialized)))
            (ghostel-tmux--receive-pane-history ctl 0 'visible "$ ")
            (should (equal (car written) "$ "))
            (should (buffer-local-value 'ghostel-tmux--initialized pane)))
        (when (buffer-live-p pane) (kill-buffer pane))))))

(ert-deftest ghostel-tmux-test-bootstrap-queued-once-per-pane ()
  ;; A second %layout-change arriving before the first capture-pane
  ;; replies must not queue a duplicate backfill pair.
  (ghostel-tmux-test--with-controller ctl
    (let ((pane (generate-new-buffer "*ghostel-tmux:boot%0*"))
          (captures 0))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel-tmux--queue-command)
                     (lambda (cmd &optional _cont)
                       (when (string-prefix-p "capture-pane" cmd)
                         (cl-incf captures))))
                    ((symbol-function 'get-buffer-window-list)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel-tmux--get-or-create-pane)
                     (lambda (&rest _) pane)))
            (with-current-buffer pane
              (setq-local ghostel--term 'fake
                          ghostel--term-cols 80
                          ghostel--term-rows 24))
            (with-current-buffer ctl
              (ghostel-tmux--on-layout-change 0 "1234,80x24,0,0,0")
              (ghostel-tmux--on-layout-change 0 "1234,80x24,0,0,0"))
            (should (= captures 2)))   ; one history + one visible
        (when (buffer-live-p pane) (kill-buffer pane))))))

(ert-deftest ghostel-tmux-test-session-renamed-updates-name ()
  ;; %session-renamed must refresh the session label and rename
  ;; existing pane buffers; tmux >= 2.5 prefixes the name with $ID.
  (ghostel-tmux-test--with-controller ctl
    (let ((pane (generate-new-buffer "*ghostel-tmux:old:sh%0*")))
      (unwind-protect
          (with-current-buffer ctl
            (setq ghostel-tmux--session-name "old")
            (puthash 0 pane ghostel-tmux--panes)
            (puthash 0 (list :name "sh" :panes (list 0))
                     ghostel-tmux--windows)
            (ghostel-tmux--dispatch-notification "%session-renamed $0 neu")
            (should (equal ghostel-tmux--session-name "neu"))
            (should (equal (buffer-name pane) "*ghostel-tmux:neu:sh%0*")))
        (when (buffer-live-p pane) (kill-buffer pane))))))

(ert-deftest ghostel-tmux-test-reset-from-pane-buffer ()
  ;; The escape hatch must work from the user-visible pane buffer, not
  ;; only from the hidden controller buffer.
  (ghostel-tmux-test--with-controller ctl
    (let ((pane (generate-new-buffer "*ghostel-tmux:reset%0*"))
          (deleted nil))
      (unwind-protect
          (progn
            (with-current-buffer pane
              (ghostel-tmux-pane-mode 1)
              (setq-local ghostel-tmux--controller-buffer ctl
                          ghostel--pty-out-function #'ignore))
            (with-current-buffer ctl
              (setq ghostel-tmux--controller-process 'fake-proc)
              (puthash 0 pane ghostel-tmux--panes))
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'delete-process)
                       (lambda (p) (setq deleted p))))
              (with-current-buffer pane
                (ghostel-tmux-reset)))
            (should (eq deleted 'fake-proc))
            (should (with-current-buffer pane
                      (and (null ghostel--pty-out-function)
                           buffer-read-only))))
        (when (buffer-live-p pane) (kill-buffer pane))))))

(ert-deftest ghostel-tmux-test-read-session-fails-cleanly-without-server ()
  ;; tmux exiting non-zero (no server running) must yield the clean
  ;; user-error, never parse stderr text as a session name.
  (cl-letf (((symbol-function 'process-file)
             (lambda (&rest _) 1)))
    (should-error (ghostel-tmux--read-session) :type 'user-error)))

(ert-deftest ghostel-tmux-test-capture-errors-on-failed-capture ()
  ;; capture-pane failing (bad target) must raise a user-error instead
  ;; of rendering tmux's error text as terminal content.
  (cl-letf (((symbol-function 'process-file)
             (lambda (&rest _) 1)))
    (should-error (ghostel-tmux-capture "nope:0.0") :type 'user-error)))

(ert-deftest ghostel-tmux-test-receive-window-rows-handles-spaces ()
  ;; Window names containing spaces (common with auto-rename) must
  ;; round-trip through the tab-delimited list-windows format.
  (ghostel-tmux-test--with-controller ctl
    (let ((row "@7\tpython -m foo\tbd5b,80x24,0,0,3"))
      (cl-letf (((symbol-function 'ghostel-tmux--on-layout-change)
                 (lambda (wid layout)
                   (should (= wid 7))
                   (should (equal layout "bd5b,80x24,0,0,3")))))
        (ghostel-tmux--receive-window-rows row))
      (should (equal (plist-get (gethash 7 ghostel-tmux--windows) :name)
                     "python -m foo")))))

(ert-deftest ghostel-tmux-test-window-close-removes-pane-buffer ()
  (ghostel-tmux-test--with-controller ctl
    (let ((pane (generate-new-buffer "*ghostel-tmux:s:w%5*")))
      (unwind-protect
          (with-current-buffer ctl
            (puthash 5 pane ghostel-tmux--panes)
            (puthash 0 (list :name "w" :panes (list 5))
                     ghostel-tmux--windows)
            (setq ghostel-tmux--window-order (list 0))
            (ghostel-tmux--on-window-close 0)
            (should-not (gethash 0 ghostel-tmux--windows))
            (should-not (gethash 5 ghostel-tmux--panes))
            (should-not (memq 0 ghostel-tmux--window-order)))
        (when (buffer-live-p pane) (kill-buffer pane))))))

(ert-deftest ghostel-tmux-test-unlinked-window-close-dispatches-as-close ()
  ;; tmux 3.6 sends `%unlinked-window-close @WID' (not `%window-close')
  ;; when the only client's session no longer has the window linked,
  ;; which is exactly what fires when a shell exits in a non-current
  ;; tmux window.  We must route it to `--on-window-close' or pane
  ;; buffers leak.
  (let ((seen nil))
    (cl-letf (((symbol-function 'ghostel-tmux--on-window-close)
               (lambda (wid) (push wid seen))))
      (ghostel-tmux--dispatch-notification "%unlinked-window-close @2")
      (ghostel-tmux--dispatch-notification "%window-close @3")
      (should (equal (nreverse seen) '(2 3))))))

(ert-deftest ghostel-tmux-test-layout-change-tolerates-empty-raw-flags ()
  ;; A window with no printable flags makes `#{window_raw_flags}'
  ;; expand to "", leaving a trailing space on the notification line.
  ;; The dispatcher must still match and extract the layout.
  (let (seen-wid seen-layout)
    (cl-letf (((symbol-function 'ghostel-tmux--on-layout-change)
               (lambda (wid layout)
                 (setq seen-wid wid seen-layout layout))))
      (ghostel-tmux--dispatch-notification
       "%layout-change @4 b33d,80x24,0,0,0 b33d,80x24,0,0,0 ")
      (should (= seen-wid 4))
      (should (equal seen-layout "b33d,80x24,0,0,0")))))

(ert-deftest ghostel-tmux-test-sentinel-seals-panes-on-controller-death ()
  (ghostel-tmux-test--with-controller ctl
    (let ((pane (generate-new-buffer "*ghostel-tmux-sentinel-pane*")))
      (unwind-protect
          (progn
            (with-current-buffer pane
              (ghostel-tmux-pane-mode 1)
              (setq-local ghostel--pty-out-function #'ignore))
            (with-current-buffer ctl
              (puthash 0 pane ghostel-tmux--panes))
            (cl-letf (((symbol-function 'process-buffer)
                       (lambda (_p) ctl))
                      ((symbol-function 'process-live-p)
                       (lambda (_p) nil)))
              (ghostel-tmux--sentinel 'fake-proc "killed: 9\n"))
            (should (with-current-buffer pane
                      (and (null ghostel--pty-out-function)
                           buffer-read-only))))
        (when (buffer-live-p pane) (kill-buffer pane))))))

(ert-deftest ghostel-tmux-test-sentinel-seals-panes-when-controller-buffer-dead ()
  ;; If the hidden controller buffer was killed before the process
  ;; died, its pane table is gone; the sentinel must still find and
  ;; seal the panes via their back-pointers.
  (let ((dead-ctl (generate-new-buffer " *ghostel-tmux-dead-ctl*"))
        (pane (generate-new-buffer "*ghostel-tmux-orphan-pane*")))
    (unwind-protect
        (progn
          (with-current-buffer pane
            (ghostel-tmux-pane-mode 1)
            (setq-local ghostel-tmux--controller-buffer dead-ctl
                        ghostel--pty-out-function #'ignore))
          (kill-buffer dead-ctl)
          (cl-letf (((symbol-function 'process-buffer)
                     (lambda (_p) dead-ctl))
                    ((symbol-function 'process-live-p)
                     (lambda (_p) nil)))
            (ghostel-tmux--sentinel 'fake-proc "killed: 9\n"))
          (should (with-current-buffer pane
                    (and (null ghostel--pty-out-function)
                         buffer-read-only))))
      (when (buffer-live-p pane) (kill-buffer pane))
      (when (buffer-live-p dead-ctl) (kill-buffer dead-ctl)))))

(ert-deftest ghostel-tmux-test-cmd-routes-through-queue ()
  ;; `--cmd' must use the command queue so tmux replies come back
  ;; correlated with the command, not eaten by another block.
  (ghostel-tmux-test--with-controller ctl
    (let (queued)
      (cl-letf (((symbol-function 'ghostel-tmux--queue-command)
                 (lambda (cmd _cont) (push cmd queued)))
                ((symbol-function 'process-live-p) (lambda (_) t)))
        (with-temp-buffer
          (setq-local ghostel-tmux--controller-buffer ctl)
          (with-current-buffer ctl
            (setq ghostel-tmux--controller-process 'fake-proc))
          (ghostel-tmux--cmd "split-window -h")))
      (should (equal queued '("split-window -h"))))))

(ert-deftest ghostel-tmux-test-bytes-to-hex-multibyte-utf8 ()
  ;; Hex encoder must accept a multibyte string (e.g. a paste of
  ;; non-Latin-1 text) and emit its UTF-8 bytes.
  (should (equal (ghostel-tmux--bytes-to-hex "ä")
                 "c3 a4")))

(ert-deftest ghostel-tmux-test-send-bytes-suppressed-during-write-vt ()
  ;; Regression: OSC/DA/cursor query replies generated while feeding
  ;; %output to a pane's VT engine would round-trip through send-keys,
  ;; arrive at the pane's stdin after the asking program had exited,
  ;; and leak into the next shell prompt as typed input.  The fix is
  ;; to drop those bytes when `--in-write-vt' is non-nil.
  (ghostel-tmux-test--with-controller ctl
    (let ((sent nil))
      (with-current-buffer ctl
        (setq ghostel-tmux--controller-process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent))))
        (let ((ghostel-tmux--in-write-vt t))
          (ghostel-tmux--send-bytes-from-pane ctl 0 "\e]10;rgb:c6c6/c6c6/c6c6\e\\"))
        (should (null sent))
        (let ((ghostel-tmux--in-write-vt nil))
          (ghostel-tmux--send-bytes-from-pane ctl 0 "abc"))
        (should sent)))))

(ert-deftest ghostel-tmux-test-on-output-binds-write-vt-flag ()
  ;; The flag must be set during `--on-output' so the override sees
  ;; it for any reply triggered by feeding the pane.
  (ghostel-tmux-test--with-controller ctl
    (let ((pane (generate-new-buffer "*ghostel-tmux:wi%0*"))
          (saw-flag nil))
      (unwind-protect
          (progn
            (with-current-buffer pane
              (setq-local ghostel--term 'fake-term
                          ghostel-tmux--initialized t))
            (with-current-buffer ctl
              (puthash 0 pane ghostel-tmux--panes))
            (cl-letf (((symbol-function 'ghostel--write-vt)
                       (lambda (_term _data)
                         (setq saw-flag ghostel-tmux--in-write-vt)))
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (with-current-buffer ctl
                (ghostel-tmux--on-output 0 "anything"))
              (should saw-flag))
            ;; After the call returns, the flag is back to nil.
            (should-not ghostel-tmux--in-write-vt))
        (when (buffer-live-p pane) (kill-buffer pane))))))

(ert-deftest ghostel-tmux-test-ensure-pane-zoomed-skips-single-pane ()
  ;; Single-pane windows must NOT be sent a zoom command (zoom is a
  ;; no-op on single-pane windows but emits a tmux status message).
  (ghostel-tmux-test--with-controller ctl
    (let ((sent nil))
      (with-current-buffer ctl
        (setq ghostel-tmux--controller-process 'fake-proc)
        (puthash 0 (list :name "w" :panes (list 5)) ghostel-tmux--windows))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent))))
        (with-current-buffer ctl
          (ghostel-tmux--ensure-pane-zoomed 0 5)))
      (should (null sent)))))

(ert-deftest ghostel-tmux-test-ensure-pane-zoomed-multi-pane ()
  ;; Multi-pane windows: queue a select-pane and a conditional zoom as
  ;; two separate commands (tmux emits one reply block per command, so
  ;; a `;'-joined line would desync reply pairing).
  (ghostel-tmux-test--with-controller ctl
    (let ((sent nil))
      (with-current-buffer ctl
        (setq ghostel-tmux--controller-process 'fake-proc)
        (puthash 0 (list :name "w" :panes (list 5 6)) ghostel-tmux--windows))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent))))
        (with-current-buffer ctl
          (ghostel-tmux--ensure-pane-zoomed 0 5)
          ;; select-pane is in flight; the zoom command waits in queue.
          (should (equal sent '("select-pane -t %5\n")))
          (let ((queued (mapcar #'car ghostel-tmux--command-queue)))
            (should (= 1 (length queued)))
            (should (string-match-p "if-shell" (car queued)))
            (should (string-match-p "resize-pane -Z -t %5" (car queued)))))))))

(ert-deftest ghostel-tmux-test-send-bytes-from-pane-chunks-large ()
  ;; A paste larger than `--send-keys-chunk-bytes' must be split into
  ;; multiple `send-keys' commands so the controller PTY's input line
  ;; doesn't overflow.  Chunks go through the FIFO command queue: the
  ;; first is sent immediately (nothing in flight), the rest wait for
  ;; their predecessors' reply blocks.
  (ghostel-tmux-test--with-controller ctl
    (let ((sent nil)
          (big (make-string 1500 ?a)))
      (with-current-buffer ctl
        (setq ghostel-tmux--controller-process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_p s) (push s sent))))
        (ghostel-tmux--send-bytes-from-pane ctl 0 big)
        (with-current-buffer ctl
          ;; 1500 bytes / 512 per chunk → 3 send-keys commands: one in
          ;; flight, two queued.
          (should (= (length sent) 1))
          (should (= (length ghostel-tmux--command-queue) 2))
          ;; Completing each reply block releases the next chunk.
          (setq ghostel-tmux--parser-state 'idle)
          (ghostel-tmux-test--feed
           ctl "%begin 1 1 0\r\n%end 1 1 0\r\n")
          (ghostel-tmux--pump-command-queue)
          (ghostel-tmux-test--feed
           ctl "%begin 1 2 0\r\n%end 1 2 0\r\n")
          (ghostel-tmux--pump-command-queue)))
      (should (= (length sent) 3))
      (dolist (cmd sent)
        (should (string-prefix-p "send-keys -t %0 -H " cmd))))))

(provide 'ghostel-tmux-test)

;;; ghostel-tmux-test.el ends here
