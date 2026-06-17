;;; ghostel-exec-test.el --- Tests for ghostel: exec -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-exec` public API and `ghostel-eshell` visual-command integration.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-exec-errors-on-live-process ()
  "`ghostel-exec' signals `user-error' if BUFFER has a live process."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq ghostel--process 'fake-process))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'process-live-p)
                     (lambda (p) (eq p 'fake-process))))
            (should-error (ghostel-exec buf "ls" nil) :type 'user-error)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-threads-remote-p-from-tramp-dir ()
  "`ghostel-exec' derives remote-p from BUFFER's `default-directory'."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*"))
        captured)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local default-directory "/ssh:somehost:/home/user/"))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--new)
                     (lambda (&rest _) 'fake-term))
                    ((symbol-function 'ghostel--set-size) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore)
                    ((symbol-function 'ghostel--spawn-pty)
                     (lambda (&rest args) (setq captured args) 'fake-proc)))
            (ghostel-exec buf "ls" nil)
            (should (nth 6 captured))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-uses-default-size-when-buffer-not-displayed ()
  "`ghostel-exec' on an undisplayed buffer uses the 80x24 default.
Falling back to (selected-window) sized the PTY from whatever window
happened to be focused at call time, which rarely matches where the
buffer eventually shows up."
  (let ((buf (generate-new-buffer "ghostel-exec-test"))
        captured)
    (unwind-protect
        (progn
          ;; Sanity: the buffer is not displayed in any window.
          (should-not (get-buffer-window buf t))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--new)
                     (lambda (&rest args) (setq captured args) 'fake-term))
                    ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore)
                    ((symbol-function 'ghostel--spawn-pty)
                     (lambda (&rest _) 'fake-proc)))
            (ghostel-exec buf "ls" nil)
            ;; ghostel--new is called as
            ;; (height width max-scrollback kitty-storage-limit kitty-mediums-bits).
            (should (equal captured
                           (list 24 80
                                 ghostel-max-scrollback
                                 ghostel-kitty-graphics-storage-limit
                                 (ghostel--kitty-mediums-bits))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-preserves-identity-bookkeeping ()
  "`ghostel-exec' does not clobber buffer identity bookkeeping vars."
  (let ((buf (generate-new-buffer " *ghostel-exec-identity*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (ghostel-mode)
            (setq-local ghostel--managed-buffer-name "managed")
            (setq-local ghostel--buffer-identity "identity"))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--new)
                     (lambda (&rest _) 'fake-term))
                    ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore)
                    ((symbol-function 'ghostel--apply-bold-config) #'ignore)
                    ((symbol-function 'ghostel--spawn-pty)
                     (lambda (&rest _) 'fake-proc)))
            (ghostel-exec buf "ls" nil)
            (with-current-buffer buf
              (should (equal ghostel--managed-buffer-name "managed"))
              (should (equal ghostel--buffer-identity "identity")))))
      (kill-buffer buf))))

(defun ghostel-test-exec--pid-live-p (pid)
  "Return non-nil when PID names a live process."
  (and (integerp pid)
       (= 0 (call-process "/bin/sh" nil nil nil
                          "-c" (format "kill -0 %d" pid)))))

(defun ghostel-test-exec--wait-for-file (file &optional process timeout)
  "Wait until FILE exists and return FILE.
PROCESS and TIMEOUT are passed to `ghostel-test--wait-until'."
  (ghostel-test--wait-until
   (lambda () (and (file-exists-p file) file))
   process timeout))

(defun ghostel-test-exec--loop-script (&optional hup-file ignore-hup)
  "Return a shell script that loops forever.
When HUP-FILE is non-nil, SIGHUP is trapped, recorded there, and exits
unless IGNORE-HUP is non-nil.  When IGNORE-HUP is non-nil and HUP-FILE
is nil, SIGHUP is ignored."
  (concat
   (cond
    (hup-file
     (format "trap 'echo HUP > %s%s' HUP; "
             (shell-quote-argument hup-file)
             (if ignore-hup "" "; exit 0")))
    (ignore-hup
     "trap '' HUP; ")
    (t ""))
   "printf GHOSTEL_LIFECYCLE_READY; "
   "while :; do sleep 1; done"))

(defun ghostel-test-exec--kill-pid (pid)
  "Best-effort SIGKILL for PID."
  (when (ghostel-test-exec--pid-live-p pid)
    (ignore-errors (signal-process pid 'KILL))))

(ert-deftest ghostel-test-exec-cat-roundtrip ()
  "Bytes written to a `ghostel-exec' PTY reach the child."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/cat"))
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-exec-buffer (buf proc "/bin/cat")
      (ghostel--write-pty ghostel--term "GHOSTEL_CAT_OK\r")
      (ghostel-test--wait-for-text "GHOSTEL_CAT_OK" proc 5))))

(ert-deftest ghostel-test-exec-keeps-final-output-after-exit ()
  "Final `ghostel-exec' output remains readable after process exit."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (ghostel-test--with-exec-buffer
        (buf proc "/bin/sh" '("-c" "printf GHOSTEL_FINAL_OUTPUT"))
      (ghostel-test--wait-for-text "GHOSTEL_FINAL_OUTPUT" nil 5)
      (ghostel-test--wait-until
       (lambda () (not (process-live-p proc))) nil 5)
      (should (buffer-live-p buf))
      (should (string-match-p "GHOSTEL_FINAL_OUTPUT"
                              (ghostel-test--terminal-text))))))

(ert-deftest ghostel-test-exec-kill-buffer-sends-sighup ()
  "Killing a `ghostel-exec' buffer sends SIGHUP to the child."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (let* ((dir (make-temp-file (expand-file-name "ghostel-life-" default-directory) t))
           (hup-file (expand-file-name "hup" dir))
           (buf (generate-new-buffer " *ghostel-test-kill-hup*"))
           proc pid)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (let ((ghostel-kill-buffer-on-exit nil))
                (setq proc (ghostel-exec
                            buf "/bin/sh"
                            (list "-c" (ghostel-test-exec--loop-script
                                        hup-file))))
                (ghostel-test--wait-for-text "GHOSTEL_LIFECYCLE_READY" proc 5)
                (setq pid ghostel--pid)))
            (kill-buffer buf)
            (ghostel-test-exec--wait-for-file hup-file nil 5)
            (ghostel-test--wait-until
             (lambda () (not (process-live-p proc))) nil 5)
            (should-not (ghostel-test-exec--pid-live-p pid)))
        (ghostel-test-exec--kill-pid pid)
        (when (buffer-live-p buf)
          (ghostel-test--cleanup-exec-buffer buf))
        (delete-directory dir t)))))

(ert-deftest ghostel-test-exec-kill-buffer-leaves-sighup-ignoring-child-live ()
  "A child that ignores SIGHUP keeps the lifecycle process alive after buffer kill."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (let* ((dir (make-temp-file (expand-file-name "ghostel-life-" default-directory) t))
           (buf (generate-new-buffer " *ghostel-test-kill-ignore-hup*"))
           proc pid)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (let ((ghostel-kill-buffer-on-exit nil))
                (setq proc (ghostel-exec
                            buf "/bin/sh"
                            (list "-c" (ghostel-test-exec--loop-script
                                        nil t))))
                (ghostel-test--wait-for-text "GHOSTEL_LIFECYCLE_READY" proc 5)
                (setq pid ghostel--pid)))
            (kill-buffer buf)
            ;; Give process deletion paths a chance to run.  The assertion that
            ;; PROC is still live also guards against blocking Emacs here: if
            ;; teardown waited synchronously for the child, this test would hang
            ;; before reaching the assertion.
            (accept-process-output proc 0.2)
            (should (ghostel-test-exec--pid-live-p pid))
            (should (process-live-p proc)))
        (ghostel-test-exec--kill-pid pid)
        (when (process-live-p proc)
          (ghostel-test--wait-until
           (lambda () (not (process-live-p proc))) nil 5))
        (when (buffer-live-p buf)
          (ghostel-test--cleanup-exec-buffer buf))
        (delete-directory dir t)))))

(ert-deftest ghostel-test-exec-child-kill-runs-exit-lifecycle ()
  "Killing the child process runs the normal Ghostel exit lifecycle."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (let* ((dir (make-temp-file (expand-file-name "ghostel-life-" default-directory) t))
           (buf (generate-new-buffer " *ghostel-test-child-kill*"))
           proc pid exit-buffer exit-event)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (let ((ghostel-kill-buffer-on-exit t))
                (setq proc (ghostel-exec
                            buf "/bin/sh"
                            (list "-c" (ghostel-test-exec--loop-script))))
                (add-hook 'ghostel-exit-functions
                          (lambda (buffer event)
                            (setq exit-buffer buffer
                                  exit-event event))
                          nil t)
                (ghostel-test--wait-for-text "GHOSTEL_LIFECYCLE_READY" proc 5)
                (setq pid ghostel--pid)))
            (signal-process pid 'TERM)
            (ghostel-test--wait-until (lambda () exit-event) proc 5)
            (should (eq exit-buffer buf))
            (should-not (buffer-live-p buf))
            (should-not (process-live-p proc)))
        (ghostel-test-exec--kill-pid pid)
        (when (buffer-live-p buf)
          (ghostel-test--cleanup-exec-buffer buf))
        (delete-directory dir t)))))

(ert-deftest ghostel-test-exec-delete-process-kills-sighup-ignoring-child ()
  "Deleting the lifecycle process kills the child even when it ignores SIGHUP."
  :tags '(native)
  (skip-unless (file-executable-p "/bin/sh"))
  (ghostel-test--with-pty-matrix backend
    (let* ((dir (make-temp-file (expand-file-name "ghostel-life-" default-directory) t))
           (buf (generate-new-buffer " *ghostel-test-delete-process*"))
           proc pid)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (let ((ghostel-kill-buffer-on-exit nil))
                (setq proc (ghostel-exec
                            buf "/bin/sh"
                            (list "-c" (ghostel-test-exec--loop-script
                                        nil t))))
                (ghostel-test--wait-for-text "GHOSTEL_LIFECYCLE_READY" proc 5)
                (setq pid ghostel--pid)))
            (delete-process proc)
            (ghostel-test--wait-until
             (lambda () (not (ghostel-test-exec--pid-live-p pid))) nil 5)
            (should-not (process-live-p proc)))
        (ghostel-test-exec--kill-pid pid)
        (when (buffer-live-p buf)
          (ghostel-test--cleanup-exec-buffer buf))
        (delete-directory dir t)))))

(ert-deftest ghostel-test-eshell-visual-command-mode-toggles-advice ()
  "Enabling/disabling the mode adds/removes the `eshell-exec-visual' advice."
  (let ((was-on ghostel-eshell-visual-command-mode))
    (unwind-protect
        (progn
          (ghostel-eshell-visual-command-mode -1)
          (should-not (advice-member-p #'ghostel-eshell--exec-visual
                                       'eshell-exec-visual))
          (ghostel-eshell-visual-command-mode 1)
          (should (advice-member-p #'ghostel-eshell--exec-visual
                                   'eshell-exec-visual))
          (ghostel-eshell-visual-command-mode -1)
          (should-not (advice-member-p #'ghostel-eshell--exec-visual
                                       'eshell-exec-visual)))
      (ghostel-eshell-visual-command-mode (if was-on 1 -1)))))

(ert-deftest ghostel-test-eshell/ghostel-dispatches-to-exec-visual ()
  "`eshell/ghostel' forwards its arguments to `eshell-exec-visual'."
  :tags '(native)
  (let (captured)
    (cl-letf (((symbol-function 'eshell-exec-visual)
               (lambda (&rest args) (setq captured args))))
      (eshell/ghostel "vim" "file.txt")
      (should (equal captured '("vim" "file.txt"))))))

(ert-deftest ghostel-test-eshell-visual-exit-q-binding-is-buffer-local ()
  "`ghostel-eshell--visual-exit' must not leak `q' into the shared keymap.
It binds `q' to `kill-current-buffer' in the finished buffer's own
local map; the shared `ghostel-semi-char-mode-map' must stay
unmodified so later visual buffers still send `q' to the program."
  (let ((buf (generate-new-buffer " *ghostel-visual-exit*")))
    (unwind-protect
        ;; Run the `run-at-time' deferral synchronously so the test is
        ;; not at the mercy of timer scheduling.
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat fn &rest args) (apply fn args))))
          (with-current-buffer buf
            (ghostel-mode))
          ;; Sanity: the shared map has no direct `q' binding to begin
          ;; with (bare `q' resolves through the self-insert remap).
          (should-not (lookup-key ghostel-semi-char-mode-map (kbd "q")))
          (ghostel-eshell--visual-exit buf "finished\n")
          ;; The finished buffer dismisses on `q'...
          (with-current-buffer buf
            (should (eq (lookup-key (current-local-map) (kbd "q"))
                        #'kill-current-buffer)))
          ;; ...but the shared map is untouched (no leak, issue #372).
          (should-not (lookup-key ghostel-semi-char-mode-map (kbd "q"))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-calls-spawn-pty-with-expected-args ()
  "`ghostel-exec' forwards PROGRAM, ARGS, size, stty flags, and remote-p."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*"))
        captured)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                  ((symbol-function 'ghostel--new)
                   (lambda (&rest _) 'fake-term))
                  ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                  ((symbol-function 'ghostel--apply-palette) #'ignore)
                  ((symbol-function 'ghostel--spawn-pty)
                   (lambda (&rest args) (setq captured args) 'fake-proc)))
          (ghostel-exec buf "less" '("/etc/hosts"))
          ;; Signature: program args height width stty-flags extra-env remote-p
          (should (equal (nth 0 captured) "less"))
          (should (equal (nth 1 captured) '("/etc/hosts")))
          (should (numberp (nth 2 captured)))
          (should (numberp (nth 3 captured)))
          (should (equal (nth 4 captured) ghostel--default-stty))
          (should (null (nth 5 captured)))
          ;; Local default-directory — no TRAMP — so remote-p must be nil.
          (should (null (nth 6 captured))))
      (kill-buffer buf))))


(provide 'ghostel-exec-test)
;;; ghostel-exec-test.el ends here
