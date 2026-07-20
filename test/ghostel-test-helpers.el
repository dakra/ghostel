;;; ghostel-test-helpers.el --- Shared helpers + runner for ghostel tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers shared across the per-topic test files (ghostel-*-test.el).
;; Also defines the batch runner functions used by the Makefile:
;; `ghostel-test-run-elisp' and `ghostel-test-run-native' select via the
;; `native' and `posix' ERT tags.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)
(require 'ghostel)
(require 'ghostel-compile)
(require 'ghostel-debug)
(require 'ghostel-eshell)

(declare-function ghostel--cleanup-temp-paths "ghostel")
(declare-function ghostel--kill-native-process "ghostel-module" (term))

(defmacro ghostel-test--with-compile-buffer (var &rest body)
  "Run BODY in a fresh ghostel-mode buffer bound to VAR."
  (declare (indent 1))
  `(let ((,var (generate-new-buffer " *ghostel-test-compile*"))
         (inhibit-message t))
     (unwind-protect
         (with-current-buffer ,var
           (ghostel-mode)
           ,@body)
       (kill-buffer ,var))))

(defmacro ghostel-test--with-terminal-buffer (spec &rest body)
  "Run BODY in a fresh ghostel buffer with a terminal attached.
SPEC is (BUFFER TERM ROWS COLS SCROLLBACK).  The terminal is created
through the production `ghostel--create' path."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,term ,rows ,cols ,scrollback) spec))
    `(let* ((ghostel-max-scrollback ,scrollback)
            (,buffer (ghostel--create " *ghostel-test-term*" nil
                                      ,rows ,cols))
            (,term (buffer-local-value 'ghostel--term ,buffer)))
       (unwind-protect
           (with-current-buffer ,buffer
             ,@body)
         (ghostel-test--cleanup-exec-buffer ,buffer)))))

(defun ghostel-test--row0 (term)
  "Return the first row text from TERM's scrollback."
  (let ((text (or (ghostel--copy-all-text term) "")))
    (string-trim-right (car (split-string text "\n")))))

(defun ghostel-test--terminal-text (&optional buffer)
  "Return all terminal text for BUFFER, or the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (or (and ghostel--term (ghostel--copy-all-text ghostel--term)) "")))

(defun ghostel-test--terminal-text-line-p (line &optional text)
  "Return non-nil if LINE appears as a complete terminal row in TEXT."
  (string-match-p (concat "\\(?:\\`\\|\n\\)[[:blank:]]*" (regexp-quote line)
                          "[[:blank:]]*\\(?:\\'\\|\n\\)")
                  (or text (ghostel-test--terminal-text))))

(defun ghostel-test--terminal-text-line-prefix-p (prefix &optional text)
  "Return non-nil if a complete terminal row in TEXT starts with PREFIX."
  (string-match-p (concat "\\(?:\\`\\|\n\\)[[:blank:]]*" (regexp-quote prefix))
                  (or text (ghostel-test--terminal-text))))

(defmacro ghostel-test--with-rendered-output (&rest body)
  "Run BODY while mutating fake renderer-owned buffer text."
  (declare (indent 0) (debug t))
  `(let ((inhibit-read-only t)
         (inhibit-modification-hooks t))
     ,@body))

(defun ghostel-test--insert-rendered (&rest args)
  "Insert ARGS as fake renderer-owned output in the current buffer."
  (ghostel-test--with-rendered-output
    (apply #'insert args)))

(defun ghostel-test--redraw (term &optional full)
  "Redraw TERM as renderer-owned test output.
When FULL is non-nil, request a full redraw.  This mirrors
`ghostel--redraw-now', which allows terminal renderer mutations
even when the ghostel buffer is read-only."
  (ghostel-test--with-rendered-output
    (ghostel--redraw term full)))

(defun ghostel-test--cursor (term)
  "Return (COL . ROW) cursor position for TERM via redraw."
  (ghostel-test--redraw term)
  ghostel--cursor-pos)

(defconst ghostel-test--timeout-scale
  ;; Gate on a *positive numeric* parse, not mere presence: `getenv'
  ;; returns "" (non-nil) for a set-but-empty var, and
  ;; `string-to-number' maps "" and garbage to 0 — which would zero
  ;; every timeout and fail every wait instantly.  A bad override
  ;; falls through to the CI/default logic instead.
  (let* ((env (getenv "GHOSTEL_TEST_TIMEOUT_SCALE"))
         (n (and env (string-to-number env))))
    (cond ((and n (> n 0)) n)
          ((getenv "CI") 4)             ; GitHub Actions et al. set CI=true
          (t 1)))
  "Multiplier applied to every polling-wait timeout.
Heavily-loaded CI runners (`make -jN test-native' spawns a real PTY
child per test file in parallel) can take far longer than the local
default to reach a predicate.  The wait helpers early-exit the moment
their predicate holds, so a larger ceiling costs nothing on a passing
run; only a genuinely slow startup (or a failing predicate) waits the
extra time.  Override with the `GHOSTEL_TEST_TIMEOUT_SCALE'
environment variable (must parse to a positive number).")

(defun ghostel-test--windows-p ()
  "Return non-nil when the tests are running on native Windows."
  (eq system-type 'windows-nt))

(defun ghostel-test--posix-p ()
  "Return non-nil when the tests are running on a POSIX-like system."
  (not (ghostel-test--windows-p)))

(defun ghostel-test--temp-directory ()
  "Return a writable local directory for spawned test processes."
  (file-name-as-directory (expand-file-name temporary-file-directory)))

(defun ghostel-test--shell-command (script)
  "Return a command list that runs SCRIPT in the platform shell."
  (if (ghostel-test--windows-p)
      (list (or (getenv "COMSPEC") "cmd.exe") "/s" "/d" "/c" script)
    (list "/bin/sh" "-c" script)))

(defun ghostel-test--env-command ()
  "Return a command list that prints the process environment."
  (if (ghostel-test--windows-p)
      (ghostel-test--shell-command "set")
    (list (executable-find "env"))))

(defun ghostel-test--env-done-command ()
  "Return a shell command that prints the environment and a done marker."
  (if (ghostel-test--windows-p)
      (ghostel-test--shell-command "set & echo GHOSTEL_ENV_DONE")
    '("/bin/sh" "-c" "env; printf GHOSTEL_ENV_DONE")))

(defun ghostel-test--base-process-environment ()
  "Return a small process environment suitable for native spawn tests."
  (if (ghostel-test--windows-p)
      (delq nil
            (list (and (getenv "SystemRoot")
                       (format "SystemRoot=%s" (getenv "SystemRoot")))
                  (and (getenv "COMSPEC")
                       (format "COMSPEC=%s" (getenv "COMSPEC")))
                  (format "PATH=%s" (or (getenv "PATH") ""))
                  (format "TEMP=%s" (or (getenv "TEMP")
                                         (ghostel-test--temp-directory)))))
    '("PATH=/usr/bin:/bin" "HOME=/tmp")))

(defun ghostel-test--wait-for (proc pred &optional timeout)
  "Poll PROC until PRED returns non-nil, or TIMEOUT seconds (default 5).
Signal an ERT failure if TIMEOUT is reached or PROC exits before PRED
succeeds.  TIMEOUT is scaled by `ghostel-test--timeout-scale'."
  (let* ((timeout (* (or timeout 5) ghostel-test--timeout-scale))
         (deadline (+ (float-time) timeout))
         result)
    (while (and (not (setq result (funcall pred)))
                (< (float-time) deadline)
                (process-live-p proc))
      (accept-process-output proc 0.05))
    (unless result
      (ert-fail
       (if (process-live-p proc)
           (format "Timed out after %.1fs waiting for predicate" timeout)
         (format "Process %s exited before predicate succeeded" (process-name proc)))))
    result))

(defmacro ghostel-test--with-pty-matrix (backend &rest body)
  "Run BODY once per local PTY backend.
BACKEND is bound to `emacs-pty' and `native-pty' in turn on POSIX.
On Windows, only `native-pty' is exercised because these tests target
ConPTY and Emacs does not provide the POSIX PTY setup used by the
`emacs-pty' branch.  The corresponding `ghostel-use-native-pty' value
is let-bound around BODY, and failures include the backend name in ERT
output."
  (declare (indent 1))
  `(dolist (entry (if (ghostel-test--windows-p)
                      '((native-pty . t))
                    '((emacs-pty . nil) (native-pty . t))))
     (let ((,backend (car entry))
           (ghostel-use-native-pty (cdr entry)))
       (ert-info ((format "backend: %S" ,backend))
         ,@body))))

(defun ghostel-test--lifecycle-process (&optional buffer)
  "Return BUFFER's active ghostel lifecycle process, if any.
BUFFER defaults to the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    ghostel--process))

(defun ghostel-test--cleanup-exec-buffer (buffer)
  "Best-effort cleanup for a ghostel exec BUFFER."
  ;; Test cleanup is forceful: start child termination before releasing
  ;; native state.
  (when (buffer-live-p buffer)
    (let ((process (buffer-local-value 'ghostel--process buffer)))
      (when (and process (process-live-p process))
        (ignore-errors (delete-process process)))))
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when ghostel--term
        (ignore-errors (ghostel--kill-native-process ghostel--term)))
      (when ghostel--redraw-timer
        (cancel-timer ghostel--redraw-timer)
        (setq ghostel--redraw-timer nil))
      (when ghostel--plain-link-detection-timer
        (cancel-timer ghostel--plain-link-detection-timer)
        (setq ghostel--plain-link-detection-timer nil)))
    (kill-buffer buffer)))

(defun ghostel-test--dummy-process (name buffer)
  "Return a live pipe process named NAME attached to BUFFER."
  (make-pipe-process :name name :buffer buffer :noquery t))

(defmacro ghostel-test--with-exec-buffer (spec &rest body)
  "Run BODY in a fresh ghostel buffer running PROGRAM.
SPEC is (BUFFER PROCESS PROGRAM &optional ARGS).  PROCESS is bound
to the lifecycle process returned by `ghostel-exec'; see
`ghostel-test--lifecycle-process'."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,process ,program . ,args) spec))
    `(let ((,buffer (generate-new-buffer " *ghostel-test-exec*"))
           (,process nil)
           (ghostel-kill-buffer-on-exit nil))
       (unwind-protect
           (with-current-buffer ,buffer
             (let ((ghostel-detect-password-prompts nil))
               (setq ,process (ghostel-exec ,buffer ,program ,@args)))
             (setq-local ghostel-detect-password-prompts nil)
             ,@body)
         (ghostel-test--cleanup-exec-buffer ,buffer)))))

(defvar ghostel-test--python-executable :unknown
  "Cached Python 3 executable used by integration tests.")

(defun ghostel-test--python ()
  "Return a Python 3 executable, or fail the current test."
  (when (eq ghostel-test--python-executable :unknown)
    (setq ghostel-test--python-executable
          (cl-find-if
           (lambda (program)
             (and program
                  (eql 0 (call-process
                          program nil nil nil "-c"
                          "import sys; raise SystemExit(sys.version_info[0] != 3)"))))
           (list (executable-find "python3")
                 (executable-find "python")))))
  (or ghostel-test--python-executable
      (ert-fail "Python 3 is unavailable")))

(defun ghostel-test--fixture-directory ()
  "Return the absolute path of the test fixture directory."
  (expand-file-name
   "fixtures"
   (file-name-directory (locate-library "ghostel-test-helpers"))))

(defconst ghostel-test--raw-echo-script
  (string-join
   '("import os, sys"
     "sys.path.insert(0, sys.argv[1])"
     "from pty_setup import set_raw_stdio"
     "set_raw_stdio()"
     "stdin_fd = sys.stdin.fileno()"
     "stdout_fd = sys.stdout.fileno()"
     "def write_all(data):"
     "    while data:"
     "        data = data[os.write(stdout_fd, data):]"
     "write_all(b'GHOSTEL_RAW_ECHO_READY')"
     "while True:"
     "    data = os.read(stdin_fd, 4096)"
     "    if not data:"
     "        break"
     "    write_all(data)")
   "\n")
  "Python code that copies raw PTY input to output.")

(defmacro ghostel-test--with-raw-echo-buffer (spec &rest body)
  "Run BODY in a fresh ghostel buffer backed by a raw byte echo process.
SPEC is (BUFFER PROCESS).  Bytes written with `ghostel--write-pty' are
returned as terminal output without line-discipline rewriting."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,process) spec))
    `(let ((python (ghostel-test--python))
           (,buffer (generate-new-buffer " *ghostel-test-raw-echo*"))
           (,process nil)
           (ghostel-kill-buffer-on-exit nil))
       (unwind-protect
           (with-current-buffer ,buffer
             (let ((ghostel-detect-password-prompts nil))
               (setq ,process
                     (ghostel-exec
                      ,buffer python
                      (list "-u" "-c" ghostel-test--raw-echo-script
                            (ghostel-test--fixture-directory)))))
             (setq-local ghostel-detect-password-prompts nil)
             (ghostel-test--wait-for-text "GHOSTEL_RAW_ECHO_READY"
                                          ,process 5)
             ,@body)
         (ghostel-test--cleanup-exec-buffer ,buffer)))))

(defun ghostel-test--hex-encode-string (string)
  "Return lowercase hex for STRING's raw bytes."
  (mapconcat (lambda (byte) (format "%02x" byte))
             (string-to-list (encode-coding-string string 'binary))
             ""))

(defconst ghostel-test--pty-reply-probe-script
  (string-join
   '("import os, queue, sys, threading, time"
     "sys.path.insert(0, sys.argv[1])"
     "from pty_setup import set_raw_stdio"
     "set_raw_stdio()"
     "stdin_fd = sys.stdin.fileno()"
     "stdout_fd = sys.stdout.fileno()"
     "timeout = float(sys.argv[2])"
     "payloads = sys.argv[3:]"
     "input_queue = queue.Queue()"
     "def read_input():"
     "    while True:"
     "        chunk = os.read(stdin_fd, 4096)"
     "        input_queue.put(chunk)"
     "        if not chunk:"
     "            return"
     "def write_all(data):"
     "    while data:"
     "        data = data[os.write(stdout_fd, data):]"
     "threading.Thread(target=read_input, daemon=True).start()"
     "for idx, payload_hex in enumerate(payloads):"
     "    write_all(bytes.fromhex(payload_hex))"
     "    buf = bytearray()"
     "    deadline = time.monotonic() + timeout"
     "    while True:"
     "        remaining = deadline - time.monotonic()"
     "        if remaining <= 0:"
     "            break"
     "        try:"
     "            chunk = input_queue.get(timeout=remaining)"
     "        except queue.Empty:"
     "            break"
     "        if not chunk:"
     "            break"
     "        buf.extend(chunk)"
     "    marker = ('\\r\\nGHOSTEL_PTY_REPLY_%d_HEX:' % idx).encode('ascii')"
     "    write_all(marker + buf.hex().encode('ascii') + b'\\r\\n')")
   "\n")
  "Python code that writes hex payloads and reports PTY replies.
The first argument locates the portable PTY setup module, the second is
a per-payload read timeout in seconds, and the rest are hex-encoded
payloads to write to stdout.  After each write, the script prints
`GHOSTEL_PTY_REPLY_N_HEX:' followed by any reply bytes read from stdin
as lowercase hex.")

(defun ghostel-test--wait-for-pty-reply (index &optional process timeout)
  "Return reply hex for PTY probe reply INDEX.
PROCESS and TIMEOUT are passed to `ghostel-test--wait-until'."
  (let ((marker (format "GHOSTEL_PTY_REPLY_%d_HEX:" index)))
    (ghostel-test--wait-until
     (lambda ()
       (let ((text (or (ghostel--copy-all-text ghostel--term) "")))
         (when (string-match (concat (regexp-quote marker) "\\([0-9a-f]*\\)")
                             text)
           (match-string 1 text))))
     process timeout)))

(defconst ghostel-test--pty-byte-recorder-script
  (string-join
   '("import os, select, sys, tty, time"
     "fd = sys.stdin.fileno()"
     "if os.isatty(fd):"
     "    tty.setraw(fd)"
     "count = int(sys.argv[1])"
     "sys.stdout.buffer.write(b'GHOSTEL_RECORDER_READY\\r\\n')"
     "sys.stdout.buffer.flush()"
     "buf = b''"
     "deadline = time.time() + 5"
     "while len(buf) < count and time.time() < deadline:"
     "    readable, _, _ = select.select([fd], [], [], 0.05)"
     "    if readable:"
     "        chunk = os.read(fd, count - len(buf))"
     "        if not chunk:"
     "            break"
     "        buf += chunk"
     "sys.stdout.buffer.write(b'\\r\\nGHOSTEL_INPUT_HEX:' + buf.hex().encode('ascii') + b'\\r\\n')"
     "sys.stdout.buffer.flush()")
   "\n")
  "Python code that reads N bytes from stdin and prints them as hex.")

(defun ghostel-test--last-marker-payload (marker)
  "Return the last hex-like payload following MARKER in terminal text."
  (let ((text (or (ghostel--copy-all-text ghostel--term) ""))
        (start 0)
        result)
    (while (string-match (concat (regexp-quote marker) "\\([0-9a-f]+\\)")
                         text start)
      (setq result (match-string 1 text)
            start (match-end 0)))
    result))

(defun ghostel-test--wait-for-marker-payload (marker pred &optional process timeout)
  "Wait until MARKER has a hex payload satisfying PRED.
Return the matching payload.  PROCESS and TIMEOUT are passed to
`ghostel-test--wait-until'."
  (ghostel-test--wait-until
   (lambda ()
     (let ((payload (ghostel-test--last-marker-payload marker)))
       (and payload (funcall pred payload) payload)))
   process timeout))

(defun ghostel-test--wait-until (pred &optional process timeout)
  "Poll until PRED returns non-nil, or TIMEOUT seconds elapse.
PROCESS, when non-nil, is passed to `accept-process-output' so both
Emacs PTY and native event output can be drained.  TIMEOUT is scaled
by `ghostel-test--timeout-scale'."
  (let* ((timeout (* (or timeout 5) ghostel-test--timeout-scale))
         (deadline (+ (float-time) timeout))
         result)
    (while (and (not (setq result (funcall pred)))
                (< (float-time) deadline))
      (accept-process-output (and process (process-live-p process) process)
                             0.05))
    (unless result
      (ert-fail
       (if (and process (not (process-live-p process)))
           (format "Timed out after %.1fs waiting for predicate after process %s exited"
                   timeout (process-name process))
         (format "Timed out after %.1fs waiting for predicate" timeout))))
    result))

(defun ghostel-test--wait-for-text (text &optional process timeout)
  "Wait until the current ghostel terminal text contains TEXT.
PROCESS and TIMEOUT are passed to `ghostel-test--wait-until'."
  (ghostel-test--wait-until
   (lambda ()
     (and ghostel--term
          (string-match-p (regexp-quote text)
                          (or (ghostel--copy-all-text ghostel--term) ""))))
   process timeout))

(defun ghostel-test--start-process-and-wait-for-text (text &optional rows cols timeout)
  "Start `ghostel--start-process' in a fresh terminal buffer and wait for TEXT.
ROWS, COLS, and TIMEOUT control the fresh terminal and wait.
Return the terminal text after TEXT appears.  Dynamic process-spawn
bindings from the caller are honored."
  (ghostel-test--with-terminal-buffer (buf _term (or rows 24) (or cols 80) 1000)
    (let ((proc (ghostel--start-process)))
      (ghostel-test--wait-for-text text proc timeout)
      (ghostel-test--terminal-text))))

(defun ghostel-test--enable-start-logging ()
  "Log each ERT test name as it starts, gated on `GHOSTEL_DEBUG_TESTS'.

When the `GHOSTEL_DEBUG_TESTS' environment variable is set, add
`:before' advice to `ert-run-test' so the name of the test about to
run is printed synchronously before its body executes.  The last
printed line is then the test that hung or crashed — useful for
isolating failures in the native module or in PTY-driven tests that
never return.  No-op when the env var is unset, so production batch
runs are unaffected."
  (when (getenv "GHOSTEL_DEBUG_TESTS")
    (unless (advice-member-p #'ghostel-test--log-start 'ert-run-test)
      (advice-add 'ert-run-test :before #'ghostel-test--log-start))))

(defun ghostel-test--log-start (test)
  "Message the ERT TEST about to run."
  (message "ERT starting: %s" (ert-test-name test)))

(ghostel-test--enable-start-logging)

(defun ghostel-test--elisp-selector ()
  "Return the ERT selector for pure Elisp tests on the current platform."
  (if (ghostel-test--windows-p)
      '(and (not (tag native)) (not (tag posix)))
    '(and (not (tag native)) (not (tag windows)))))

(defun ghostel-test-run-elisp ()
  "Run only pure Elisp tests for this platform."
  (ert-run-tests-batch-and-exit (ghostel-test--elisp-selector)))

(defun ghostel-test--native-selector ()
  "Return the ERT selector for native tests on the current platform."
  (if (ghostel-test--windows-p)
      '(and (tag native) (not (tag posix)))
    '(and (tag native) (not (tag windows)))))

(defun ghostel-test-run-native ()
  "Run only tests that require the native module for this platform."
  (ert-run-tests-batch-and-exit (ghostel-test--native-selector)))

(defun ghostel-test--all-selector ()
  "Return the ERT selector for all tests on the current platform."
  (if (ghostel-test--windows-p)
      '(and "^ghostel-test-" (not (tag posix)))
    '(and "^ghostel-test-" (not (tag windows)))))

(defun ghostel-test-run ()
  "Run all ghostel tests for this platform."
  (ert-run-tests-batch-and-exit (ghostel-test--all-selector)))

(defun ghostel-test--bash-at-least-p (major minor)
  "Return non-nil when the bash in PATH is at least MAJOR.MINOR."
  (let ((ver (with-temp-buffer
               (call-process "bash" nil t nil "-c"
                             "printf '%s.%s' \"$BASH_VERSINFO\" \"${BASH_VERSINFO[1]}\"")
               (buffer-string))))
    (and (string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)\\'" ver)
         (let ((got-major (string-to-number (match-string 1 ver)))
               (got-minor (string-to-number (match-string 2 ver))))
           (or (> got-major major)
               (and (= got-major major) (>= got-minor minor)))))))

(provide 'ghostel-test-helpers)
;;; ghostel-test-helpers.el ends here
