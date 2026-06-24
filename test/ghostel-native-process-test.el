;;; ghostel-native-process-test.el --- Tests for ghostel: native process -*- lexical-binding: t; -*-

;;; Commentary:

;; Native PTY event serialization and Elisp event-filter parsing.

;;; Code:

(require 'ghostel-test-helpers)

(defvar ghostel-test-native-process--events nil
  "Events recorded by native process unit-test callbacks.")

(defvar ghostel-test-native-process--evil nil
  "Non-nil if a native process quoting test evaluates injected Lisp.")

(defun ghostel-test-native-process--record (&rest args)
  "Record ARGS for native process event-filter tests."
  (push args ghostel-test-native-process--events))

(defun ghostel-test-native-process--with-events-filter (fn)
  "Call FN in a buffer-local `ghostel--events-filter' unit-test context.
FN receives a fake pipe process value and a zero-argument function
returning the number of redraw invalidations requested."
  (let ((buffer (generate-new-buffer " *ghostel-test-events-filter*")))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local ghostel--event-buf nil)
          (let ((ghostel-test-native-process--events nil)
                (invalidations 0))
            (cl-letf (((symbol-function 'process-buffer)
                       (lambda (_process) buffer))
                      ((symbol-function 'ghostel--invalidate)
                       (lambda () (cl-incf invalidations))))
              (funcall fn 'ghostel-test-process (lambda () invalidations)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ghostel-test-native-process--env-output (env-program &optional spawn-wrapper)
  "Spawn ENV-PROGRAM through the native primitive and return its output.
SPAWN-WRAPPER, when non-nil, is called with the zero-argument spawn
function and should call it under any dynamic bindings needed by the test."
  (ghostel-test--with-terminal-buffer (buf _term 200 32767 2000000)
    (let ((pipe (make-pipe-process
                 :name "ghostel-native-env-test"
                 :buffer (current-buffer)
                 :filter #'ghostel--events-filter
                 :noquery t))
          pid)
      (unwind-protect
          (progn
            (let ((spawn (lambda ()
                           (setq pid (ghostel--spawn-native-process
                                      ghostel--term (list env-program) pipe)))))
              (if spawn-wrapper
                  (funcall spawn-wrapper spawn)
                (funcall spawn)))
            (ghostel-test--wait-until
             (lambda () (not (process-live-p pipe))) pipe 5)
            (ghostel-test--terminal-text))
        (when pid
          (ignore-errors (signal-process pid 9)))
        (ignore-errors (ghostel--kill-native-process ghostel--term))
        (when (process-live-p pipe)
          (delete-process pipe))))))

(ert-deftest ghostel-test-events-filter-multiple-events-per-chunk ()
  "Native process event filter evaluates multiple events in one chunk."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc invalidations)
     (ghostel--events-filter
      proc
      "(ghostel-test-native-process--record \"one\")(ghostel-test-native-process--record \"two\" 2)")
     (should (equal '(("two" 2) ("one")) ghostel-test-native-process--events))
     (should (null ghostel--event-buf))
     (should (= 1 (funcall invalidations))))))

(ert-deftest ghostel-test-events-filter-partial-writes-across-chunks ()
  "Native process event filter keeps incomplete events across chunks."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc _invalidations)
     (ghostel--events-filter proc "(ghostel-test-native-process--record \"par")
     (should (equal nil ghostel-test-native-process--events))
     (should (equal "(ghostel-test-native-process--record \"par" ghostel--event-buf))
     (ghostel--events-filter proc "tial\" 42)")
     (should (equal '(("partial" 42)) ghostel-test-native-process--events))
     (should (null ghostel--event-buf)))))

(ert-deftest ghostel-test-events-filter-complete-prefix-with-partial-tail ()
  "Native process event filter evaluates complete events before a partial tail."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc _invalidations)
     (ghostel--events-filter
      proc
      "(ghostel-test-native-process--record \"first\")(ghostel-test-native-process--record \"sec")
     (should (equal '(("first")) ghostel-test-native-process--events))
     (should (equal "(ghostel-test-native-process--record \"sec" ghostel--event-buf))
     (ghostel--events-filter proc "ond\")")
     (should (equal '(("second") ("first")) ghostel-test-native-process--events))
     (should (null ghostel--event-buf)))))

(ert-deftest ghostel-test-events-filter-failing-event-does-not-poison-next-write ()
  "Native process event filter can process a good write after a failing one.
A well-formed event whose evaluation signals is logged and discarded; it
must not leave `ghostel--event-buf' in a poisoned state."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc _invalidations)
     (ghostel--events-filter proc "(error \"boom\")")
     (should (null ghostel--event-buf))
     (ghostel--events-filter proc "(ghostel-test-native-process--record \"good\")")
     (should (equal '(("good")) ghostel-test-native-process--events))
     (should (null ghostel--event-buf)))))

(ert-deftest ghostel-test-events-filter-signalling-event-does-not-lose-tail ()
  "A signalling event is logged but does not abort the rest of the batch."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc invalidations)
     ;; Batch: a good event, an event whose evaluation signals, another good
     ;; event, then a partial tail.  The signal must not propagate out of the
     ;; filter, nor drop the events/tail that follow it.
     (ghostel--events-filter
      proc
      (concat "(ghostel-test-native-process--record \"before\")"
              "(error \"boom\")"
              "(ghostel-test-native-process--record \"after\")"
              "(ghostel-test-native-process--record \"par"))
     (should (equal '(("after") ("before")) ghostel-test-native-process--events))
     (should (equal "(ghostel-test-native-process--record \"par" ghostel--event-buf))
     (should (= 1 (funcall invalidations)))
     (ghostel--events-filter proc "tial\")")
     (should (equal '(("partial") ("after") ("before"))
                    ghostel-test-native-process--events))
     (should (null ghostel--event-buf)))))

(ert-deftest ghostel-test-native-process-adds-display-for-graphical-frame ()
  "Native env builder mirrors Emacs' DISPLAY fallback for graphical frames."
  :tags '(native)
  (let ((env-program (executable-find "env")))
    (skip-unless env-program)
    (let* ((process-environment '("DISPLAY_FOO=1" "PATH=/usr/bin:/bin" "HOME=/tmp"))
           (default-directory "/tmp/")
           (text (ghostel-test-native-process--env-output
                  env-program
                  (lambda (spawn)
                    (cl-letf (((symbol-function 'display-graphic-p)
                               (lambda (&optional _display) t))
                              ((symbol-function 'getenv)
                               (lambda (variable &optional _frame)
                                 (and (string= variable "DISPLAY") ":99"))))
                      (funcall spawn))))))
      (should (ghostel-test--terminal-text-line-p "DISPLAY=:99" text))
      (should (ghostel-test--terminal-text-line-p "DISPLAY_FOO=1" text)))))

(ert-deftest ghostel-test-native-process-does-not-add-display-for-terminal-frame ()
  "Native env builder does not synthesize DISPLAY for non-graphical frames."
  :tags '(native)
  (let ((env-program (executable-find "env")))
    (skip-unless env-program)
    (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
           (default-directory "/tmp/")
           (text (ghostel-test-native-process--env-output
                  env-program
                  (lambda (spawn)
                    (cl-letf (((symbol-function 'display-graphic-p)
                               (lambda (&optional _display) nil))
                              ((symbol-function 'getenv)
                               (lambda (variable &optional _frame)
                                 (and (string= variable "DISPLAY") ":99"))))
                      (funcall spawn))))))
      (should-not (ghostel-test--terminal-text-line-prefix-p "DISPLAY=" text)))))

(ert-deftest ghostel-test-native-process-env-first-entry-wins ()
  "Native env builder follows `process-environment' first-entry semantics."
  :tags '(native)
  (let ((env-program (executable-find "env")))
    (skip-unless env-program)
    (let* ((process-environment '("GHOSTEL_ENV_TEST_UNSET"
                                  "GHOSTEL_ENV_TEST_UNSET=later"
                                  "GHOSTEL_ENV_TEST_DUP=first"
                                  "GHOSTEL_ENV_TEST_DUP=later"
                                  "PATH=/usr/bin:/bin"
                                  "HOME=/tmp"))
           (default-directory "/tmp/")
           (text (ghostel-test-native-process--env-output env-program)))
      (should-not (ghostel-test--terminal-text-line-prefix-p
                   "GHOSTEL_ENV_TEST_UNSET=" text))
      (should (ghostel-test--terminal-text-line-p
               "GHOSTEL_ENV_TEST_DUP=first" text))
      (should-not (ghostel-test--terminal-text-line-p
                   "GHOSTEL_ENV_TEST_DUP=later" text)))))

(ert-deftest ghostel-test-native-process-display-unset-suppresses-fallback ()
  "A bare DISPLAY entry suppresses graphical DISPLAY fallback."
  :tags '(native)
  (let ((env-program (executable-find "env")))
    (skip-unless env-program)
    (let* ((process-environment '("DISPLAY" "PATH=/usr/bin:/bin" "HOME=/tmp"))
           (default-directory "/tmp/")
           (text (ghostel-test-native-process--env-output
                  env-program
                  (lambda (spawn)
                    (cl-letf (((symbol-function 'display-graphic-p)
                               (lambda (&optional _display) t))
                              ((symbol-function 'getenv)
                               (lambda (variable &optional _frame)
                                 (and (string= variable "DISPLAY") ":99"))))
                      (funcall spawn))))))
      (should-not (ghostel-test--terminal-text-line-prefix-p "DISPLAY=" text)))))

(ert-deftest ghostel-test-native-process-lisp-string-quoting ()
  "Native process event strings do not escape Lisp quoting."
  :tags '(native)
  (let ((ghostel-use-native-pty t)
        (ghostel-test-native-process--evil nil)
        (titles nil)
        (payloads '("plain title"
                    "quoted \") (setq ghostel-test-native-process--evil 'quote) (\" title"
                    "backslash \\\") (setq ghostel-test-native-process--evil 'backslash) (\" title"
                    "newline\n\")\n(setq ghostel-test-native-process--evil 'newline)\n(\" title")))
    (ghostel-test--with-raw-cat-buffer (buf proc)
      (should ghostel--process)
      (cl-letf (((symbol-function 'ghostel--set-title)
                 (lambda (title) (push title titles))))
        (dolist (payload payloads)
          (ghostel--write-pty ghostel--term (concat "\e]2;" payload "\e\\")))
        (ghostel-test--wait-until
         (lambda () (>= (length titles) (length payloads)))
         proc 5)
        (should-not ghostel-test-native-process--evil)
        (should (equal (mapcar (lambda (title)
                                 (replace-regexp-in-string "\n" "" title))
                               payloads)
                       (reverse titles)))))))

;;; ghostel-native-process-test.el ends here
