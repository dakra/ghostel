;;; ghostel-foreground-test.el --- Tests for ghostel: foreground process probe -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-foreground-pid', `ghostel-command-running-p', the
;; foreground-change hook, and the kill-buffer query that builds on them.

;;; Code:

(require 'ghostel-test-helpers)

;;; Live-PTY probe tests

(defun ghostel-foreground-test--wait-for-shell (proc)
  "Poll PROC until the shell's own group holds the PTY foreground."
  (ghostel-test--wait-for
   proc (lambda () (eql (ghostel-foreground-pid) ghostel--pid))))

(defun ghostel-foreground-test--wait-for-comm (proc comm)
  "Poll PROC until a foreground group other than the shell's runs COMM."
  (ghostel-test--wait-for
   proc (lambda ()
          (when-let* ((fg (ghostel-foreground-pid)))
            (and (/= fg ghostel--pid)
                 (equal (alist-get 'comm (process-attributes fg)) comm))))))

(ert-deftest ghostel-test-foreground-pid-tracks-running-command ()
  "The probe reports the shell at its prompt and the command while it runs."
  :tags '(native posix)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-exec-buffer (buf proc "/bin/sh" (list "-i"))
      ;; At the prompt the shell's own group is in the foreground.
      (ghostel-foreground-test--wait-for-shell proc)
      (should-not (ghostel-command-running-p))
      (ghostel--write-pty ghostel--term "sleep 30\n")
      (ghostel-foreground-test--wait-for-comm proc "sleep")
      (should (ghostel-command-running-p))
      ;; C-c interrupts the command; the shell reclaims the terminal.
      (ghostel--write-pty ghostel--term "\C-c")
      (ghostel-foreground-test--wait-for-shell proc)
      (should-not (ghostel-command-running-p)))))

(ert-deftest ghostel-test-forked-shell-is-not-a-running-command ()
  "A shell the spawn wrapper forked rather than exec'ed reads as idle.
Simulates the `ghostel--shell-pgid' case: a shell in its own process group,
never equal to `ghostel--pid'."
  :tags '(native posix)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-exec-buffer (buf proc "/bin/sh" (list "-c" "/bin/sh -i; exit"))
      ;; `ghostel-exec' does not run the spawn path that sets this.
      (setq-local ghostel--shell-forked t)
      (ghostel-test--wait-for
       proc (lambda () (when-let* ((fg (ghostel-foreground-pid)))
                         (/= fg ghostel--pid))))
      (should-not (ghostel-command-running-p))
      (ghostel--write-pty ghostel--term "sleep 30\n")
      (ghostel-foreground-test--wait-for-comm proc "sleep")
      (should (ghostel-command-running-p)))))

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
        (ghostel-foreground-test--wait-for-shell proc)
        (ghostel--notify-foreground-change)     ; baseline: the shell
        (should (= (length calls) 1))
        (ghostel--write-pty ghostel--term "sleep 30\n")
        ;; Wait until the command has exec'ed, not just forked: a fresh
        ;; fork still reports the shell's comm, and sampling that window
        ;; would legitimately fire an extra pre-exec event.
        (ghostel-foreground-test--wait-for-comm proc "sleep")
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
        ;; Terminal output drives redraws, so the command has to emit
        ;; something once it already holds the foreground: a redraw
        ;; sampling only the echo can still see the pre-exec fork, and a
        ;; silent command never triggers another one.
        (ghostel--write-pty ghostel--term "/bin/sh -c 'echo GO; sleep 30'\n")
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
    (pcase-dolist (`(,probe ,osc ,expect)
                   '((nil nil nil)          ; no probe, no markers
                     (nil t   t)            ; no probe, OSC command (TRAMP)
                     (100 nil nil)          ; shell at its prompt
                     (200 nil t)))          ; another group in the foreground
      (setq-local ghostel--command-running osc)
      (cl-letf (((symbol-function 'ghostel-foreground-pid) (lambda () probe)))
        (ert-info ((format "probe %S, osc %S" probe osc))
          (should (eq (and (ghostel-command-running-p) t) expect)))))))

(ert-deftest ghostel-test-shell-pgid-adopts-forked-shell ()
  "`ghostel--shell-pgid' adopts a direct child once, and only a direct child."
  (with-temp-buffer
    (setq-local ghostel--pid 100
                ghostel--shell-forked t)
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (pid) (and (eql pid 200) '((ppid . 100))))))
      ;; The shell is `ghostel--pid' itself: nothing to adopt.
      (should (eql (ghostel--shell-pgid 100) 100))
      (should-not ghostel--shell-pgid-cache)
      ;; A group that is not our child is a command, not the shell.
      (should (eql (ghostel--shell-pgid 300) 100))
      (should-not ghostel--shell-pgid-cache)
      ;; A direct child is the forked shell, and is remembered.
      (should (eql (ghostel--shell-pgid 200) 200))
      (should (eql ghostel--shell-pgid-cache 200)))
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (_) (ert-fail "consulted the OS after caching"))))
      (should (eql (ghostel--shell-pgid 300) 200)))))

(ert-deftest ghostel-test-shell-pgid-never-adopts-without-a-fork ()
  "Nothing may be adopted as the shell without a forking wrapper.
A command the shell starts is a direct child of `ghostel--pid' too."
  (with-temp-buffer
    (setq-local ghostel--pid 100)
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (_) '((ppid . 100)))))
      (should (eql (ghostel--shell-pgid 200) 100))
      (should-not ghostel--shell-pgid-cache))))

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
