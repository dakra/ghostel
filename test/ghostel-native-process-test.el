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
FN receives a pipe process and a zero-argument function
returning the number of redraw invalidations requested."
  (let ((buffer (generate-new-buffer " *ghostel-test-events-filter*"))
        (pipe (make-pipe-process :name "ghostel-test-events-filter" :noquery t)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((ghostel-test-native-process--events nil)
                (invalidations 0))
            (cl-letf (((symbol-function 'process-buffer)
                       (lambda (_process) buffer))
                      ((symbol-function 'ghostel--invalidate)
                       (lambda () (cl-incf invalidations))))
              (funcall fn pipe (lambda () invalidations)))))
      (delete-process pipe)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ghostel-test-native-process--stash (pipe)
  "Return the incomplete event tail held on PIPE."
  (process-get pipe 'ghostel--event-buf))

(defun ghostel-test-native-process--command-output (command &optional spawn-wrapper)
  "Spawn COMMAND through the native primitive and return its output.
COMMAND is an argv list.  SPAWN-WRAPPER, when non-nil, is called with
and should call the zero-argument spawn function under any dynamic
bindings needed by the test.  A held COMMAND (one that prints
`ghostel-test--held-marker' and then reads a line) is released with a
newline once the marker is on screen."
  (ghostel-test--with-terminal-buffer (buf _term 200 32767 2000000)
    (let* ((exit-status nil)
           (pipe (make-pipe-process
                  :name "ghostel-native-command-test"
                  :buffer (current-buffer)
                  ;; The reaper's bare exit status ends the event stream.
                  :filter (lambda (pipe output)
                            (when (string-match "\\([0-9]+\\)\n\\'" output)
                              (setq exit-status (match-string 1 output)))
                            (ghostel--events-filter pipe output))
                  :noquery t))
           pid)
      (unwind-protect
          (progn
            (let ((spawn (lambda ()
                           (setq pid (ghostel--spawn-native-process
                                      ghostel--term command pipe)))))
              (if spawn-wrapper
                  (funcall spawn-wrapper spawn)
                (funcall spawn)))
            (ghostel-test--wait-until
             (lambda ()
               (or (not (process-live-p pipe))
                   (string-match-p ghostel-test--held-marker
                                   (ghostel-test--terminal-text buf))))
             pipe 5)
            (when (process-live-p pipe)
              (ghostel--write-pty ghostel--term "\n"))
            (ghostel-test--wait-until
             (lambda () (not (process-live-p pipe))) pipe 5)
            (should (eq (current-buffer) buf))
            (let ((text (ghostel-test--terminal-text)))
              (when (string-empty-p text)
                (ert-fail (format "%s produced no output (exit status %s)"
                                  command exit-status)))
              text))
        (when pid
          (ignore-errors (signal-process pid 9)))
        (ignore-errors (ghostel--kill-native-process ghostel--term))
        (when (process-live-p pipe)
          (delete-process pipe))))))

(ert-deftest ghostel-test-native-process-exit-hook-kills-children ()
  "Emacs exit attempts to kill every recorded native child."
  (let (signals)
    (cl-letf (((symbol-function 'process-list)
               (lambda () '(pipe-a unrelated pipe-b dead-pipe)))
              ((symbol-function 'process-get)
               (lambda (process property)
                 (and (eq property 'ghostel--native-pid)
                      (pcase process
                        ('pipe-a 101)
                        ('pipe-b 202)
                        ('dead-pipe 303)))))
              ((symbol-function 'signal-process)
               (lambda (pid signal)
                 (push (list pid signal) signals))))
      (ghostel--kill-native-processes-on-exit)
      (should (equal (nreverse signals) '((101 9) (202 9) (303 9)))))))

(ert-deftest ghostel-test-native-kill-buffer-hook-cleans-up-dead-process ()
  "Native `kill-buffer' cleanup runs after the event process exits."
  (let ((buffer (generate-new-buffer " *ghostel-test-native-cleanup*"))
        cleaned)
    (unwind-protect
        (with-current-buffer buffer
          (let ((pipe (ghostel-test--dummy-process "ghostel-dead-pipe" buffer))
                (ghostel--term 'term))
            (delete-process pipe)
            (setq ghostel--process pipe)
            (cl-letf (((symbol-function 'ghostel--kill-native-process)
                       (lambda (term) (setq cleaned term))))
              (ghostel--kill-native-process-hook))
            (should (eq cleaned 'term))
            (should-not (process-buffer pipe))))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-native-kill-buffer-hook-tolerates-nil-term ()
  "Native `kill-buffer' cleanup is a no-op when `ghostel--term' is nil.
A major-mode change after process exit wipes the buffer-local term while
the permanent-local `kill-buffer-hook' keeps the hook entry; the hook
must not signal, or `kill-buffer' aborts and the buffer survives."
  (let ((buffer (generate-new-buffer " *ghostel-test-native-nil-term*"))
        called)
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'ghostel--kill-native-process)
                     (lambda (_term) (setq called t))))
            (ghostel--kill-native-process-hook))
          (should-not called))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-events-filter-multiple-events-per-chunk ()
  "Native process event filter evaluates multiple events in one chunk."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc invalidations)
     (ghostel--events-filter
      proc
      "(ghostel-test-native-process--record \"one\")(ghostel-test-native-process--record \"two\" 2)")
     (should (equal '(("two" 2) ("one")) ghostel-test-native-process--events))
     (should (null (ghostel-test-native-process--stash proc)))
     (should (= 1 (funcall invalidations))))))

(ert-deftest ghostel-test-events-filter-partial-writes-across-chunks ()
  "Native process event filter keeps incomplete events across chunks."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc _invalidations)
     (ghostel--events-filter proc "(ghostel-test-native-process--record \"par")
     (should (equal nil ghostel-test-native-process--events))
     (should (equal "(ghostel-test-native-process--record \"par" (ghostel-test-native-process--stash proc)))
     (ghostel--events-filter proc "tial\" 42)")
     (should (equal '(("partial" 42)) ghostel-test-native-process--events))
     (should (null (ghostel-test-native-process--stash proc))))))

(ert-deftest ghostel-test-events-filter-exit-status-split-across-chunks ()
  "A split exit status is reassembled before the pipe is deleted."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc _invalidations)
     (let (deleted)
       (cl-letf (((symbol-function 'delete-process)
                  (lambda (_proc) (setq deleted t))))
         (ghostel--events-filter proc "13")
         (should-not deleted)
         (should (equal "13" (ghostel-test-native-process--stash proc)))
         (ghostel--events-filter proc "7\n")
         (should (= 137 (process-get proc 'ghostel--exit-status)))
         (should deleted))))))

(ert-deftest ghostel-test-events-filter-complete-prefix-with-partial-tail ()
  "Native process event filter evaluates complete events before a partial tail."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc _invalidations)
     (ghostel--events-filter
      proc
      "(ghostel-test-native-process--record \"first\")(ghostel-test-native-process--record \"sec")
     (should (equal '(("first")) ghostel-test-native-process--events))
     (should (equal "(ghostel-test-native-process--record \"sec" (ghostel-test-native-process--stash proc)))
     (ghostel--events-filter proc "ond\")")
     (should (equal '(("second") ("first")) ghostel-test-native-process--events))
     (should (null (ghostel-test-native-process--stash proc))))))

(ert-deftest ghostel-test-events-filter-failing-event-does-not-poison-next-write ()
  "Native process event filter can process a good write after a failing one.
A well-formed event whose evaluation signals is logged and discarded; it
must not leave a poisoned tail on the pipe."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc _invalidations)
     (ghostel--events-filter proc "(error \"boom\")")
     (should (null (ghostel-test-native-process--stash proc)))
     (ghostel--events-filter proc "(ghostel-test-native-process--record \"good\")")
     (should (equal '(("good")) ghostel-test-native-process--events))
     (should (null (ghostel-test-native-process--stash proc))))))

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
     (should (equal "(ghostel-test-native-process--record \"par" (ghostel-test-native-process--stash proc)))
     (should (= 1 (funcall invalidations)))
     (ghostel--events-filter proc "tial\")")
     (should (equal '(("partial") ("after") ("before"))
                    ghostel-test-native-process--events))
     (should (null (ghostel-test-native-process--stash proc))))))

(ert-deftest ghostel-test-native-process-decodes-windows-unibyte-inputs ()
  "Native spawn decodes Windows unibyte process inputs with the ANSI code page."
  :tags '(native windows)
  (skip-unless (ghostel-test--windows-p))
  (let* ((python (ghostel-test--python))
         (acp-coding-system
          (or (coding-system-from-name (format "cp%d" w32-ansi-code-page))
              (ert-fail (format "No coding system for Windows code page %d"
                                w32-ansi-code-page))))
         (unicode-value
          (or (cl-find-if
               (lambda (candidate)
                 (let ((bytes (encode-coding-string candidate acp-coding-system)))
                   (and (not (multibyte-string-p bytes))
                        (seq-some (lambda (char) (> char 127)) bytes)
                        (equal candidate
                               (decode-coding-string bytes acp-coding-system)))))
               '("â" "Ž" "Ж" "Ω" "İ" "א" "ا" "ก" "あ" "中" "한" "€"))
              (ert-fail (format "No non-ASCII fixture for Windows code page %d"
                                w32-ansi-code-page))))
         (unibyte-value
          (encode-coding-string unicode-value acp-coding-system))
         (unicode-directory
          (file-name-as-directory
           (make-temp-file
            (expand-file-name (format "ghostel-%s-" unicode-value)
                              temporary-file-directory)
            t)))
         (unibyte-directory
          (encode-coding-string unicode-directory acp-coding-system))
         (environment-entry (concat "GHOSTEL_ACP_TEST=" unibyte-value))
         (script
          (concat
           "import os, sys\n"
           "ok = (sys.argv[1] == sys.argv[2] and "
           "os.environ.get('GHOSTEL_ACP_TEST') == sys.argv[2] and "
           "os.path.normcase(os.getcwd()) == os.path.normcase(sys.argv[3]))\n"
           "print('GHOSTEL_ACP_OK' if ok else 'GHOSTEL_ACP_BAD')\n")))
    (unwind-protect
        (progn
          (let* ((process-environment
                  (cons environment-entry
                        (ghostel-test--base-process-environment)))
                 (default-directory (ghostel-test--temp-directory))
                 (text
                  (ghostel-test-native-process--command-output
                   (list python "-c" script unibyte-value unicode-value
                         (directory-file-name unicode-directory))
                   (lambda (spawn)
                     (cl-letf (((symbol-function 'expand-file-name)
                                (lambda (&rest _) unibyte-directory)))
                       (funcall spawn))))))
            (should (ghostel-test--terminal-text-line-p "GHOSTEL_ACP_OK" text))))
      (delete-directory unicode-directory t))))

(ert-deftest ghostel-test-native-process-adds-display-for-graphical-frame ()
  "Native env builder mirrors Emacs' DISPLAY fallback for graphical frames."
  :tags '(native)
  (let ((env-command (ghostel-test--env-command)))
    (let* ((process-environment (append '("DISPLAY_FOO=1")
                                        (ghostel-test--base-process-environment)))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test-native-process--command-output
                  env-command
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
  (let ((env-command (ghostel-test--env-command)))
    (let* ((process-environment (ghostel-test--base-process-environment))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test-native-process--command-output
                  env-command
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
  (let ((env-command (ghostel-test--env-command)))
    (let* ((process-environment (append '("GHOSTEL_ENV_TEST_UNSET"
                                          "GHOSTEL_ENV_TEST_UNSET=later"
                                          "GHOSTEL_ENV_TEST_DUP=first"
                                          "GHOSTEL_ENV_TEST_DUP=later")
                                        (ghostel-test--base-process-environment)))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test-native-process--command-output env-command)))
      (should-not (ghostel-test--terminal-text-line-prefix-p
                   "GHOSTEL_ENV_TEST_UNSET=" text))
      (should (ghostel-test--terminal-text-line-p
               "GHOSTEL_ENV_TEST_DUP=first" text))
      (should-not (ghostel-test--terminal-text-line-p
                   "GHOSTEL_ENV_TEST_DUP=later" text)))))

(ert-deftest ghostel-test-native-process-display-unset-suppresses-fallback ()
  "A bare DISPLAY entry suppresses graphical DISPLAY fallback."
  :tags '(native)
  (let ((env-command (ghostel-test--env-command)))
    (let* ((process-environment (cons "DISPLAY"
                                      (ghostel-test--base-process-environment)))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test-native-process--command-output
                  env-command
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
    (ghostel-test--with-raw-echo-buffer (buf proc)
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

(defun ghostel-test-native-process--event-backpressure ()
  "Fill the event pipe, then take the terminal lock without draining it.
The reader must release the terminal lock while its event write blocks,
otherwise Emacs waits for the lock and can never resume draining the pipe."
  (ghostel-test--with-terminal-buffer (buf term 24 80 1000)
    (let* ((directory (make-temp-file "ghostel-native-events-" t))
           (ready (expand-file-name "ready" directory))
           (script (string-join
                    '("import pathlib, sys"
                      "sys.path.insert(0, sys.argv[1])"
                      "from pty_setup import read_for, set_raw_stdio, start_reader, write_all"
                      "set_raw_stdio()"
                      "pathlib.Path(sys.argv[2]).touch()"
                      "write_all(b'\\x1b]52;c;' + b'm' * (512 * 1024) + b'\\x1b\\\\')"
                      "# Keep the PTY open until Emacs has checked the event."
                      "read_for(start_reader(), 30, 1)")
                    "\n"))
           (pipe (make-pipe-process
                  :name "ghostel-native-events" :buffer buf
                  :filter #'ghostel--events-filter :noquery t))
           pid received)
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--osc52-handle)
                     (lambda (_selection data) (setq received data))))
            (setq pid (ghostel--spawn-native-process
                       term (list (ghostel-test--python) "-u" "-c" script
                                  (ghostel-test--fixture-directory) ready)
                       pipe))
            ;; Wait out of band: accepting process output here would drain
            ;; the very pipe we need to fill.
            (let ((deadline (+ (float-time)
                               (* 5 ghostel-test--timeout-scale))))
              (while (and (not (file-exists-p ready))
                          (< (float-time) deadline))))
            (should (file-exists-p ready))
            ;; Give the reader time to overflow its 16 KiB event buffer and
            ;; block on the undrained pipe; sleeping would service that pipe.
            (let ((deadline (+ (float-time) 0.5)))
              (while (< (float-time) deadline)))
            ;; This triggers the deadlock if the reader still holds the
            ;; terminal lock: Emacs waits for that lock while the reader
            ;; waits for Emacs to drain the event pipe.
            (ghostel--focus-event term t)
            (ghostel-test--wait-until (lambda () received) pipe 5)
            (should (equal received (make-string (* 512 1024) ?m))))
        (when pid (ignore-errors (signal-process pid 9)))
        ;; Close the pipe before joining the reader, including on failure.
        (when (process-live-p pipe) (delete-process pipe))
        (ghostel--kill-native-process term)
        (delete-directory directory t)))))

(ert-deftest ghostel-test-native-process-event-pipe-backpressure ()
  "A full event pipe does not deadlock terminal access or lose OSC 52 data."
  :tags '(native)
  ;; An Emacs timer cannot interrupt a native mutex wait. Keep the timeout
  ;; in a separate Emacs so a regression fails instead of hanging the suite.
  (let* ((output (generate-new-buffer " *ghostel-native-events-output*"))
         (process
          (make-process
           :name "ghostel-native-events-emacs" :buffer output
           :connection-type 'pipe :noquery t :sentinel #'ignore
           :command
           (list (expand-file-name invocation-name invocation-directory)
                 "--batch" "-Q"
                 "--eval" (prin1-to-string
                           `(setq load-path ',load-path
                                  load-prefer-newer t
                                  ghostel-module-directory
                                  ,(ghostel--module-directory)))
                 "-l" (locate-library "ghostel-native-process-test")
                 "-f" "ghostel-test-native-process--event-backpressure"))))
    (unwind-protect
        (progn
          (ghostel-test--wait-until
           (lambda () (not (process-live-p process))) process 20)
          (ert-info ((with-current-buffer output (buffer-string)))
            (should (= (process-exit-status process) 0))))
      (when (process-live-p process) (delete-process process))
      (kill-buffer output))))

;;; ghostel-native-process-test.el ends here
