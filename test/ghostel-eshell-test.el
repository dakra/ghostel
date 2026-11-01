;;; ghostel-eshell-test.el --- In-buffer Eshell terminal tests  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for `ghostel-eshell-mode' and the process attachment layer it
;; installs: real PTY processes are attached through the same functions
;; Eshell uses, then rendered, frozen and cleaned up.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-embedded)
(require 'ghostel-eshell)
(require 'eshell)

(defconst ghostel-test--eshell-plain-script
  (string-join
   '("import sys"
     "sys.stdout.write('hello\\r\\nworld\\r\\n')"
     "sys.stdout.flush()")
   "\n")
  "Python program printing two plain lines.")

(defconst ghostel-test--eshell-alt-script
  (string-join
   '("import sys"
     "sys.stdout.write('keep\\r\\n')"
     "sys.stdout.write('\\x1b[?1049h\\x1b[2J\\x1b[HTUI')"
     "sys.stdout.flush()")
   "\n")
  "Python program that prints a line, then exits on the alternate screen.")

(defconst ghostel-test--eshell-sleep-script
  (string-join
   '("import sys, time"
     "sys.stdout.write('ready\\r\\n')"
     "sys.stdout.flush()"
     "time.sleep(5)")
   "\n")
  "Python program that reports readiness and keeps running.")

(defun ghostel-test--eshell-buffer ()
  "Return a fresh buffer in a mode that can host an embedded terminal."
  (let ((buffer (generate-new-buffer " *ghostel-test-eshell*")))
    (with-current-buffer buffer
      (setq default-directory (ghostel-test--temp-directory))
      (ghostel--eshell-local-mode 1))
    buffer))

(defun ghostel-test--eshell-start (buffer script)
  "Start SCRIPT in BUFFER and attach an embedded terminal to its process.
Returns the Emacs process."
  (with-current-buffer buffer
    (let ((process (make-process
                    :name "ghostel-test-eshell"
                    :buffer buffer
                    :command (list (ghostel-test--python) "-c" script)
                    :connection-type 'pty
                    :coding 'no-conversion
                    ;; No default "Process NAME finished" line: the test
                    ;; asserts the frozen region text exactly.
                    :sentinel #'ignore)))
      (ghostel--eshell-attach-process process)
      process)))

(defun ghostel-test--eshell-region-text (session)
  "Return SESSION's terminal region text without properties."
  (with-current-buffer (ghostel-embedded-buffer session)
    (buffer-substring-no-properties (ghostel-embedded-start session)
                                    (ghostel-embedded-end session))))

(defun ghostel-test--eshell-wait-exit (process)
  "Wait for PROCESS to exit and its embedded session to be frozen."
  (ghostel-test--wait-for
   process
   (lambda ()
     (with-current-buffer (process-buffer process)
       (null ghostel--embedded-session)))
   10))

(defun ghostel-test--eshell-teardown (buffer process)
  "Kill PROCESS and BUFFER after a test."
  (when (process-live-p process)
    (ignore-errors (delete-process process)))
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

(ert-deftest ghostel-test-eshell-plain-output-freezes ()
  "A plain program renders into the Eshell buffer and freezes at exit."
  :tags '(native)
  (let* ((buffer (ghostel-test--eshell-buffer))
         (process (ghostel-test--eshell-start
                   buffer ghostel-test--eshell-plain-script))
         (session (process-get process 'ghostel--eshell-session)))
    (unwind-protect
        (progn
          (should session)
          (ghostel-test--eshell-wait-exit process)
          (with-current-buffer buffer
            (should-not ghostel--embedded-session)
            (should (equal (string-trim-right
                            (ghostel-test--eshell-region-text session))
                           "hello\nworld"))
            ;; The frozen region is ordinary editable text again.
            (should-not (get-text-property
                         (ghostel-embedded-start session) 'read-only))
            ;; The host keymap and terminal state were restored.
            (should (null (current-local-map)))
            (should-not ghostel--term)))
      (ghostel-test--eshell-teardown buffer process))))

(ert-deftest ghostel-test-eshell-alt-screen-discarded ()
  "Exiting on the alternate screen freezes the normal screen instead."
  :tags '(native)
  (let* ((buffer (ghostel-test--eshell-buffer))
         (process (ghostel-test--eshell-start
                   buffer ghostel-test--eshell-alt-script))
         (session (process-get process 'ghostel--eshell-session)))
    (unwind-protect
        (progn
          (ghostel-test--eshell-wait-exit process)
          (let ((text (ghostel-test--eshell-region-text session)))
            (should (string-match-p "keep" text))
            (should-not (string-match-p "TUI" text))))
      (ghostel-test--eshell-teardown buffer process))))

(ert-deftest ghostel-test-eshell-cleanup-idempotent ()
  "Cleaning up twice is harmless and a second command can start."
  :tags '(native)
  (let* ((buffer (ghostel-test--eshell-buffer))
         (process (ghostel-test--eshell-start
                   buffer ghostel-test--eshell-plain-script))
         (session (process-get process 'ghostel--eshell-session)))
    (unwind-protect
        (progn
          (ghostel-test--eshell-wait-exit process)
          ;; Running the sentinel again must not signal.
          (with-current-buffer buffer
            (ghostel--eshell-sentinel process "finished\n")
            (ghostel--eshell-sentinel process "finished\n")
            (should-not ghostel--embedded-session))
          ;; A second command starts a fresh terminal after the frozen text.
          (let* ((second (ghostel-test--eshell-start
                          buffer ghostel-test--eshell-plain-script))
                 (second-session (process-get second 'ghostel--eshell-session)))
            (unwind-protect
                (progn
                  (should second-session)
                  (ghostel-test--eshell-wait-exit second)
                  (with-current-buffer buffer
                    (should (equal
                             (string-trim-right
                              (ghostel-test--eshell-region-text second-session))
                             "hello\nworld"))
                    ;; The first command's text is still above it.
                    (should (string-match-p
                             "hello"
                             (ghostel-test--eshell-region-text session)))))
              (ghostel-test--eshell-teardown buffer second))))
      (ghostel-test--eshell-teardown buffer process))))

(ert-deftest ghostel-test-eshell-resize-updates-process ()
  "Resizing an attached terminal also resizes its PTY."
  :tags '(native)
  (let* ((buffer (ghostel-test--eshell-buffer))
         (process (ghostel-test--eshell-start
                   buffer ghostel-test--eshell-sleep-script))
         (session (process-get process 'ghostel--eshell-session))
         calls)
    (unwind-protect
        (progn
          (ghostel-test--wait-for
           process
           (lambda ()
             (string-match-p "ready"
                             (ghostel-test--eshell-region-text session)))
           5)
          (cl-letf (((symbol-function 'set-process-window-size)
                     (lambda (proc rows cols)
                       (setq calls (list proc rows cols)))))
            (ghostel--embedded-resize session 12 40 t))
          (should (equal (cdr calls) '(12 40)))
          (should (eq (car calls) process)))
      (ghostel-test--eshell-teardown buffer process))))

(ert-deftest ghostel-test-eshell-use-terminal-guards ()
  "Only interactive local commands with `stty' get a terminal."
  :tags '(native)
  (with-temp-buffer
    (setq default-directory (ghostel-test--temp-directory))
    (ghostel--eshell-local-mode 1)
    (cl-letf (((symbol-function 'eshell-interactive-output-p)
               (lambda (&rest _) t))
              ((symbol-function 'executable-find)
               (lambda (&rest _) "/usr/bin/stty")))
      (let ((ghostel--eshell-stty-available :unknown)
            (eshell-current-subjob-p nil))
        (should (ghostel--eshell-use-terminal-p)))
      ;; Use `setq' (not `let') for the subjob flag: the guard reads it
      ;; via `bound-and-true-p', so it must be a dynamic binding.
      (let ((ghostel--eshell-stty-available :unknown))
        (setq eshell-current-subjob-p t)
        (unwind-protect
            (should-not (ghostel--eshell-use-terminal-p))
          (setq eshell-current-subjob-p nil)))
      ;; A pipeline element's stdin is a pipe, not the terminal.
      (let ((ghostel--eshell-stty-available :unknown))
        (setq eshell-in-pipeline-p 'last)
        (unwind-protect
            (should-not (ghostel--eshell-use-terminal-p))
          (setq eshell-in-pipeline-p nil))))
    ;; Remote buffers never attach a local terminal.  `file-remote-p' is
    ;; stubbed because TRAMP may not be loaded in a bare batch run.
    (let ((default-directory "/ssh:nowhere:/tmp/"))
      (cl-letf (((symbol-function 'eshell-interactive-output-p)
                 (lambda (&rest _) t))
                ((symbol-function 'file-remote-p)
                 (lambda (&rest _) "/ssh:nowhere:/tmp/")))
        (should-not (ghostel--eshell-use-terminal-p))))
    ;; Non-interactive output (pipes, redirections) keeps Eshell's path.
    (with-temp-buffer
      (setq default-directory (ghostel-test--temp-directory))
      (ghostel--eshell-local-mode 1)
      (cl-letf (((symbol-function 'eshell-interactive-output-p)
                 (lambda (&rest _) nil)))
        (let ((ghostel--eshell-stty-available :unknown)
              (eshell-current-subjob-p nil))
          (should-not (ghostel--eshell-use-terminal-p)))))
    ;; Missing stty with the silent-fallback setting also skips it.
    (let ((default-directory (ghostel-test--temp-directory)))
      (cl-letf (((symbol-function 'eshell-interactive-output-p)
                 (lambda (&rest _) t))
                ((symbol-function 'executable-find)
                 (lambda (&rest _) nil)))
        (let ((ghostel--eshell-stty-available :unknown)
              (ghostel-eshell-fallback-if-stty-unavailable t)
              (eshell-current-subjob-p nil))
          (should-not (ghostel--eshell-use-terminal-p)))))))

(ert-deftest ghostel-test-eshell-visual-command-advice ()
  "Visual commands are embedded only when they can run in a terminal."
  :tags '(native)
  (with-temp-buffer
    (setq default-directory (ghostel-test--temp-directory))
    (let ((orig (lambda (_command _args) 'visual)))
      (cl-letf (((symbol-function 'eshell-interactive-output-p)
                 (lambda (&rest _) t))
                ((symbol-function 'file-remote-p)
                 (lambda (&rest _) nil)))
        ;; Local mode off: Eshell's own classification.
        (should (eq (ghostel--eshell-visual-command-p orig "vim" nil) 'visual))
        (ghostel--eshell-local-mode 1)
        (unwind-protect
            (progn
              ;; Embeddable: take the normal external-command path.
              (should-not (ghostel--eshell-visual-command-p orig "vim" nil))
              ;; A pipeline element's stdin is a pipe, so Eshell keeps
              ;; its visual handling (it runs it in a term buffer).
              ;; `setq' (not `let'): the predicate reads these with
              ;; `bound-and-true-p', so they need dynamic bindings.
              (setq eshell-in-pipeline-p 'last)
              (let (hint)
                (cl-letf (((symbol-function 'message)
                           (lambda (fmt &rest args)
                             (setq hint (apply #'format fmt args)))))
                  (should (eq (ghostel--eshell-visual-command-p
                               orig "less" nil)
                              'visual)))
                ;; Eshell drops the piped input, so the user gets a hint.
                (should (string-match-p "Piped input is dropped" hint)))
              (setq eshell-in-pipeline-p nil)
              (setq eshell-current-subjob-p t)
              (should (eq (ghostel--eshell-visual-command-p orig "vim" nil)
                          'visual))
              (setq eshell-current-subjob-p nil)
              ;; Remote commands keep Eshell's handling too.
              (let ((default-directory "/ssh:nowhere:/tmp/"))
                (cl-letf (((symbol-function 'file-remote-p)
                           (lambda (&rest _) "/ssh:nowhere:/tmp/")))
                  (should (eq (ghostel--eshell-visual-command-p orig "vim" nil)
                              'visual)))))
          (setq eshell-in-pipeline-p nil
                eshell-current-subjob-p nil)
          (ghostel--eshell-local-mode -1))))))

(ert-deftest ghostel-test-eshell-stty-prefix ()
  "The stty wrapper sizes the PTY before exec'ing the real command."
  :tags '(native)
  (let ((prefix (ghostel--eshell-stty-prefix 24 80)))
    (should (equal (car prefix) "/usr/bin/env"))
    (should (equal (nth 1 prefix) "sh"))
    (should (equal (nth 2 prefix) "-c"))
    (should (string-match-p "rows 24 columns 80" (nth 3 prefix)))
    (should (string-match-p "exec \"\\$@\"" (nth 3 prefix)))
    (should (equal (nth 4 prefix) ".."))))

(ert-deftest ghostel-test-eshell-process-environment ()
  "Only the spawned process sees the ghostel TERM/TERMINFO values."
  :tags '(native)
  (let ((process-environment '("FOO=bar")))
    (let ((environment (ghostel--eshell-process-environment)))
      (should (member (concat "TERM=" ghostel-term) environment))
      (should (member "FOO=bar" environment))
      (when (ghostel--terminfo-directory)
        (should (member (concat "TERMINFO=" (ghostel--terminfo-directory))
                        environment)))
      ;; The caller's environment is untouched.
      (should (equal process-environment '("FOO=bar"))))))

(defun ghostel-test--eshell-lighter-text (lighter)
  "Return LIGHTER's propertized input-mode string, or nil.
LIGHTER is what `ghostel--eshell-lighter' returns, (\"[\" TEXT \"]\"),
where TEXT is either a propertized string or a `:propertize' construct.
`format-mode-line' returns \"\" in batch Emacs, so a `:propertize'
construct is applied directly instead of rendering a mode line."
  (let ((text (and (listp lighter) (nth 1 lighter))))
    (cond ((stringp text) text)
          ((eq (car-safe text) :propertize)
           (apply #'propertize (cdr text))))))

(defun ghostel-test--eshell-lighter-assert (label click-1 click-3)
  "Assert the current lighter shows LABEL and binds CLICK-1 and CLICK-3.
CLICK-1 and CLICK-3 are the commands a left and right click should run."
  (let* ((text (ghostel-test--eshell-lighter-text
                (ghostel--eshell-lighter)))
         (map (and text (get-text-property 0 'local-map text))))
    (should (equal text label))
    (should (keymapp map))
    (should (eq (lookup-key map [mode-line mouse-1]) click-1))
    (should (eq (lookup-key map [mode-line mouse-3]) click-3))
    (should (eq (get-text-property 0 'mouse-face text) 'mode-line-highlight))
    (should (string-match-p "mouse-1:" (get-text-property 0 'help-echo text)))))

(ert-deftest ghostel-test-eshell-lighter-input-modes ()
  "The mode-line lighter names the input mode and switches on a click."
  (with-temp-buffer
    (ghostel--eshell-local-mode 1)
    (let ((ghostel--embedded-session
           (ghostel-embedded--make
            :buffer (current-buffer)
            :term 'fake
            :input-mode 'semi-char
            ;; The mode switchers look these up; the terminal handle is
            ;; never dereferenced, so a placeholder term suffices.
            :start (copy-marker (point-min))
            :end (copy-marker (point-max) t))))
      (unwind-protect
          (progn
            ;; No live terminal: the mode line shows nothing.
            (let ((ghostel--embedded-session nil))
              (should-not (ghostel--eshell-lighter)))
            ;; Each mode names itself; a click offers the other two modes.
            (ghostel-embedded-semi-char-mode)
            (ghostel-test--eshell-lighter-assert
             "semi-char" #'ghostel-embedded-char-mode
             #'ghostel-embedded-emacs-mode)
            (ghostel-embedded-char-mode)
            (ghostel-test--eshell-lighter-assert
             "char" #'ghostel-embedded-semi-char-mode
             #'ghostel-embedded-emacs-mode)
            (ghostel-embedded-emacs-mode)
            (ghostel-test--eshell-lighter-assert
             "emacs" #'ghostel-embedded-semi-char-mode
             #'ghostel-embedded-char-mode))
        (setq ghostel--embedded-semi-char-active nil
              ghostel--embedded-char-active nil)))))

(ert-deftest ghostel-test-eshell-lighter-prefix ()
  "The lighter's prefix is read from `ghostel-eshell-lighter-prefix'."
  (with-temp-buffer
    (ghostel--eshell-local-mode 1)
    (let ((original ghostel-eshell-mode))
      (unwind-protect
          (progn
            (setq ghostel-eshell-mode t)
            (let* ((lighter (cadr (assq 'ghostel-eshell-mode
                                        minor-mode-alist)))
                   (constructs (cadr lighter))
                   (prefix-form (and (eq (car-safe (car constructs)) :eval)
                                     (cadr (car constructs))))
                   (mode-form (and (eq (car-safe (nth 1 constructs)) :eval)
                                   (cadr (nth 1 constructs)))))
              ;; `:lighter (ghostel--eshell-local-mode (CONSTRUCTS...))':
              ;; the leading symbol makes it conditional on the local mode.
              (should (eq (car-safe lighter) 'ghostel--eshell-local-mode))
              (should (eq (car-safe mode-form) 'ghostel--eshell-lighter))
              ;; The prefix is formatted when the mode line renders, so a
              ;; customized value takes effect without reloading the mode.
              (should (equal (eval prefix-form t)
                             (format " %s"
                                     ghostel-eshell-lighter-prefix)))
              ;; A distinct value proves the prefix is read at render time
              ;; (the default in batch Emacs is already "G").
              (let ((ghostel-eshell-lighter-prefix "X"))
                (should (equal (eval prefix-form t) " X")))))
        (setq ghostel-eshell-mode original)))))

;;; Native PTY backend

(defconst ghostel-test--eshell-native-script
  (string-join
   '("import sys"
     "sys.stdout.write('native\\r\\n')"
     "sys.stdout.flush()"
     "raise SystemExit(7)")
   "\n")
  "Python program printing a line and exiting with status 7.")

(defun ghostel-test--eshell-native-run (buffer command args)
  "Run COMMAND with ARGS in BUFFER through the native PTY advice.
Forces the native path and provides the interactive Eshell handles the
real command evaluator would bind.  Returns the event pipe process."
  (with-current-buffer buffer
    (let ((ghostel-eshell-use-native-pty t)
          (ghostel-use-native-pty t)
          (eshell-current-handles (eshell-create-handles t 'insert)))
      (ghostel--eshell-gather-process-output
       #'eshell-gather-process-output command args))))

(ert-deftest ghostel-test-eshell-native-p-gating ()
  "The native PTY is chosen by setting, platform and availability."
  (let ((ghostel-eshell-use-native-pty t)
        (ghostel-use-native-pty t))
    (should (ghostel--eshell-native-p)))
  (let ((ghostel-eshell-use-native-pty nil)
        (ghostel-use-native-pty t))
    (should-not (ghostel--eshell-native-p)))
  (let ((ghostel-eshell-use-native-pty 'auto)
        (ghostel-use-native-pty t))
    (let ((system-type 'windows-nt))
      (should (ghostel--eshell-native-p)))
    (let ((system-type 'gnu/linux))
      (should-not (ghostel--eshell-native-p))))
  (let ((ghostel-eshell-use-native-pty t)
        (ghostel-use-native-pty nil))
    (should-not (ghostel--eshell-native-p))))

(ert-deftest ghostel-test-eshell-native-run ()
  "A native-PTY command renders, reports its status and freezes."
  :tags '(native)
  (let* ((buffer (ghostel-test--eshell-buffer))
         process session)
    (unwind-protect
        (progn
          (setq process
                (ghostel-test--eshell-native-run
                 buffer (ghostel-test--python)
                 (list "-c" ghostel-test--eshell-native-script)))
          (should (process-get process 'ghostel--eshell-native))
          (should (process-get process 'ghostel--native-pid))
          ;; The event stream must stay Lisp-readable: a `binary' pipe
          ;; would corrupt the UTF-8 event text.
          (should-not (eq (car (process-coding-system process)) 'binary))
          (setq session (process-get process 'ghostel--eshell-session))
          (should session)
          (should (ghostel-embedded-native-p session))
          (ghostel-test--eshell-wait-exit process)
          (with-current-buffer buffer
            (should-not ghostel--embedded-session)
            (should (equal (string-trim-right
                            (ghostel-test--eshell-region-text session))
                           "native"))
            (should-not (get-text-property
                         (ghostel-embedded-start session) 'read-only)))
          (with-current-buffer buffer
            ;; The pipe reports 0; the sentinel restores the native code
            ;; in the buffer-local Eshell reads for `$?'.
            (should (= eshell-last-command-status 7))))
      (ghostel-test--eshell-teardown buffer process))))

(ert-deftest ghostel-test-eshell-native-input ()
  "Input reaches a native child through the module's PTY writer."
  :tags '(native)
  (let ((cat (executable-find "cat")))
    (skip-unless cat)
    (let* ((buffer (ghostel-test--eshell-buffer))
           process session)
      (unwind-protect
          (progn
            (setq process
                  (ghostel-test--eshell-native-run buffer cat nil))
            (setq session (process-get process 'ghostel--eshell-session))
            (should session)
            (ghostel--embedded-send-string session "hello\n")
            (ghostel-test--wait-for
             process
             (lambda ()
               (with-current-buffer buffer
                 (string-match-p
                  "hello"
                  (ghostel-test--eshell-region-text session))))
             10))
        (ghostel-test--eshell-teardown buffer process)))))

(ert-deftest ghostel-test-eshell-native-cleanup-kills-child ()
  "Cleaning up a running native session stops the child."
  :tags '(native)
  (let* ((buffer (ghostel-test--eshell-buffer))
         process)
    (unwind-protect
        (progn
          (setq process
                (ghostel-test--eshell-native-run
                 buffer (ghostel-test--python)
                 (list "-c" ghostel-test--eshell-sleep-script)))
          (should (process-live-p process))
          (with-current-buffer buffer
            (ghostel--eshell-cleanup)
            (should-not ghostel--embedded-session))
          (ghostel-test--wait-for
           process (lambda () (not (process-live-p process))) 10))
      (ghostel-test--eshell-teardown buffer process))))

(provide 'ghostel-eshell-test)
;;; ghostel-eshell-test.el ends here
