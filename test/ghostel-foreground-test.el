;;; ghostel-foreground-test.el --- Tests for ghostel: foreground process probe -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-foreground-pid', `ghostel-command-running-p', the
;; foreground-change hook, and the kill-buffer query that builds on them.

;;; Code:

(require 'ghostel-test-helpers)

;;; Live-PTY probe tests

(ert-deftest ghostel-test-foreground-pid-tracks-running-command ()
  "The probe reports the shell at its prompt and the command while it runs."
  :tags '(native posix)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-exec-buffer (buf proc "/bin/sh" (list "-i"))
      ;; At the prompt the shell's own group is in the foreground.
      (ghostel-test--wait-for proc
                              (lambda () (eql (ghostel-foreground-pid)
                                              ghostel--pid)))
      (should-not (ghostel-command-running-p))
      (ghostel--write-pty ghostel--term "sleep 5\n")
      (ghostel-test--wait-for proc
                              (lambda ()
                                (when-let* ((fg (ghostel-foreground-pid)))
                                  (and (/= fg ghostel--pid)
                                       (equal (alist-get
                                               'comm (process-attributes fg))
                                              "sleep")))))
      (should (ghostel-command-running-p))
      ;; C-c interrupts the command; the shell reclaims the terminal.
      (ghostel--write-pty ghostel--term "\C-c")
      (ghostel-test--wait-for proc
                              (lambda () (eql (ghostel-foreground-pid)
                                              ghostel--pid)))
      (should-not (ghostel-command-running-p)))))

(ert-deftest ghostel-test-foreground-change-notify-fires-on-change ()
  "`ghostel--notify-foreground-change' fires once per foreground change."
  :tags '(native posix)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-exec-buffer (buf proc "/bin/sh" (list "-i"))
      (let* ((calls nil)
             (ghostel-foreground-change-functions
              (list (lambda (buffer pid comm)
                      (push (list buffer pid comm) calls)))))
        (ghostel-test--wait-for proc
                                (lambda () (eql (ghostel-foreground-pid)
                                                ghostel--pid)))
        (ghostel--notify-foreground-change)     ; baseline: the shell
        (should (= (length calls) 1))
        (ghostel--write-pty ghostel--term "sleep 5\n")
        ;; Wait until the command has exec'ed, not just forked: a fresh
        ;; fork still reports the shell's comm, and sampling that window
        ;; would legitimately fire an extra pre-exec event.
        (ghostel-test--wait-for proc
                                (lambda ()
                                  (when-let* ((fg (ghostel-foreground-pid)))
                                    (and (/= fg ghostel--pid)
                                         (equal (alist-get
                                                 'comm (process-attributes fg))
                                                "sleep")))))
        (ghostel--notify-foreground-change)
        ;; Unchanged foreground does not fire again.
        (ghostel--notify-foreground-change)
        (should (= (length calls) 2))
        (pcase-let ((`(,cbuf ,pid ,comm) (car calls)))
          (should (eq cbuf buf))
          (should (/= pid ghostel--pid))
          (should (equal comm "sleep")))))))

(ert-deftest ghostel-test-foreground-change-hook-fires-from-redraw ()
  "The redraw path itself samples the foreground and runs the hook."
  :tags '(native posix)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-exec-buffer (buf proc "/bin/sh" (list "-i"))
      ;; The sampling site is guarded by `ghostel--get-render-window',
      ;; so the buffer must be displayed for redraws to run it.
      (set-window-buffer (selected-window) buf)
      (let* ((calls nil)
             (ghostel-foreground-change-functions
              (list (lambda (buffer pid comm)
                      (push (list buffer pid comm) calls)))))
        ;; Terminal output drives redraws; no manual notify call.  The
        ;; command echo redraw may sample the pre-exec fork, so assert
        ;; only that a non-shell pgid event arrived through the wiring.
        (ghostel--write-pty ghostel--term "sleep 5\n")
        (ghostel-test--wait-for proc
                                (lambda ()
                                  (cl-find-if
                                   (lambda (call)
                                     (and (eq (nth 0 call) buf)
                                          (/= (nth 1 call) ghostel--pid)))
                                   calls)))))))

;;; Predicate and kill-query logic (no live PTY)

(ert-deftest ghostel-test-command-running-p-arms ()
  "`ghostel-command-running-p' combines the probe and the OSC 133 state."
  (with-temp-buffer
    (setq-local ghostel--pid 100)
    ;; Probe unavailable, no OSC markers.
    (cl-letf (((symbol-function 'ghostel-foreground-pid) (lambda () nil)))
      (should-not (ghostel-command-running-p)))
    ;; Probe unavailable, OSC command running (e.g. TRAMP).
    (setq-local ghostel--command-running t)
    (cl-letf (((symbol-function 'ghostel-foreground-pid) (lambda () nil)))
      (should (ghostel-command-running-p)))
    (setq-local ghostel--command-running nil)
    ;; Shell at its prompt.
    (cl-letf (((symbol-function 'ghostel-foreground-pid) (lambda () 100)))
      (should-not (ghostel-command-running-p)))
    ;; Another process group in the foreground.
    (cl-letf (((symbol-function 'ghostel-foreground-pid) (lambda () 200)))
      (should (ghostel-command-running-p)))))

(ert-deftest ghostel-test-foreground-pid-child-state-mapping ()
  "`process-running-child-p' results map onto pids: nil→shell, t→unknown."
  (with-temp-buffer
    (setq-local ghostel--term 'fake-term
                ghostel--pid 100
                ghostel--process 'fake-proc)
    (cl-letf* ((child-state nil)
               ((symbol-function 'ghostel--pty-foreground-pgid)
                (lambda (_) nil))
               ((symbol-function 'process-type) (lambda (_) 'real))
               ((symbol-function 'process-live-p) (lambda (_) t))
               ((symbol-function 'process-running-child-p)
                (lambda (_) child-state)))
      (setq child-state 200)
      (should (eql (ghostel-foreground-pid) 200))
      (setq child-state nil)                   ; shell at its prompt
      (should (eql (ghostel-foreground-pid) 100))
      (setq child-state t)                     ; OS can't tell
      (should-not (ghostel-foreground-pid)))))

(ert-deftest ghostel-test-kill-buffer-query-settings ()
  "`ghostel--kill-buffer-query' honors `ghostel-query-before-killing'."
  (with-temp-buffer
    ;; Dead process: killing is always allowed, no query.
    (should (ghostel--kill-buffer-query))
    (dolist (case '((t       nil t)
                    (t       t   t)
                    (nil     nil nil)
                    (nil     t   nil)
                    (auto    nil nil)
                    (auto    t   t)))
      (pcase-let ((`(,setting ,running ,expect-query) case))
        ;; When a query is expected, the user's answer must become the
        ;; return value; without a query, killing must be allowed (t).
        (dolist (answer '(t nil))
          (let ((queried nil))
            (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'ghostel-command-running-p)
                       (lambda () running))
                      ((symbol-function 'yes-or-no-p)
                       (lambda (_) (setq queried t) answer)))
              (let* ((ghostel-query-before-killing setting)
                     (result (ghostel--kill-buffer-query)))
                (ert-info ((format "setting %S, running %S, answer %S"
                                   setting running answer))
                  (should (eq queried expect-query))
                  (should (eq result (if expect-query answer t))))))))))))

(provide 'ghostel-foreground-test)
;;; ghostel-foreground-test.el ends here
