;;; ghostel-test-helpers.el --- Shared helpers + runner for ghostel tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers shared across the per-topic test files (ghostel-*-test.el).
;; Also defines the batch runner functions used by the Makefile:
;; `ghostel-test-run-elisp' and `ghostel-test-run-native' select via the
;; `native' ERT tag (set per-test in files that require the Zig module).

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
  `(let ((inhibit-read-only t))
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

(defun ghostel-test--wait-for (proc pred &optional timeout)
  "Poll PROC until PRED returns non-nil, or TIMEOUT seconds (default 5).
Signal an ERT failure if TIMEOUT is reached or PROC exits before PRED
succeeds."
  (let* ((timeout (or timeout 5))
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
BACKEND is bound to `emacs-pty' and `native-pty' in turn.  The
corresponding `ghostel-use-native-pty' value is let-bound around
BODY, and failures include the backend name in ERT output."
  (declare (indent 1))
  `(dolist (entry '((emacs-pty . nil) (native-pty . t)))
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
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when ghostel--term
        (ignore-errors (ghostel--kill-native-process ghostel--term)))
      (when (process-live-p ghostel--process)
        (ignore-errors (delete-process ghostel--process)))
      (when ghostel--redraw-timer
        (cancel-timer ghostel--redraw-timer)
        (setq ghostel--redraw-timer nil))
      (when ghostel--plain-link-detection-timer
        (cancel-timer ghostel--plain-link-detection-timer)
        (setq ghostel--plain-link-detection-timer nil)))
    (kill-buffer buffer)))

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

(defmacro ghostel-test--with-raw-cat-buffer (spec &rest body)
  "Run BODY in a fresh ghostel buffer backed by a raw `/bin/cat'.
SPEC is (BUFFER PROCESS).  The child PTY is switched to raw/no-echo
before `cat' starts, so bytes written with `ghostel--write-pty' are
round-tripped to ghostel as terminal output without line-discipline
rewriting."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,process) spec))
    `(progn
       (skip-unless (and (file-executable-p "/bin/sh")
                         (file-executable-p "/bin/cat")))
       (let ((,buffer (generate-new-buffer " *ghostel-test-raw-cat*"))
             (,process nil)
             (ghostel-kill-buffer-on-exit nil))
         (unwind-protect
             (with-current-buffer ,buffer
               (let ((ghostel-detect-password-prompts nil))
                 (setq ,process
                       (ghostel-exec
                        ,buffer "/bin/sh"
                        '("-c" "stty raw -echo; printf GHOSTEL_RAW_CAT_READY; exec /bin/cat"))))
               (setq-local ghostel-detect-password-prompts nil)
               (ghostel-test--wait-for-text "GHOSTEL_RAW_CAT_READY"
                                            ,process 5)
               ,@body)
           (ghostel-test--cleanup-exec-buffer ,buffer))))))

(defun ghostel-test--hex-encode-string (string)
  "Return lowercase hex for STRING's raw bytes."
  (mapconcat (lambda (byte) (format "%02x" byte))
             (string-to-list (encode-coding-string string 'binary))
             ""))

(defconst ghostel-test--pty-reply-probe-script
  (string-join
   '("import os, select, sys, tty, time"
     "fd = sys.stdin.fileno()"
     "if os.isatty(fd):"
     "    tty.setraw(fd)"
     "timeout = float(sys.argv[1])"
     "payloads = sys.argv[2:]"
     "for idx, payload_hex in enumerate(payloads):"
     "    sys.stdout.buffer.write(bytes.fromhex(payload_hex))"
     "    sys.stdout.buffer.flush()"
     "    buf = b''"
     "    deadline = time.time() + timeout"
     "    while time.time() < deadline:"
     "        readable, _, _ = select.select([fd], [], [], 0.02)"
     "        if not readable:"
     "            continue"
     "        chunk = os.read(fd, 4096)"
     "        if not chunk:"
     "            break"
     "        buf += chunk"
     "    marker = ('\\r\\nGHOSTEL_PTY_REPLY_%d_HEX:' % idx).encode('ascii')"
     "    sys.stdout.buffer.write(marker + buf.hex().encode('ascii') + b'\\r\\n')"
     "    sys.stdout.buffer.flush()")
   "\n")
  "Python code that writes hex payloads and reports PTY replies.
The first argument is a per-payload read timeout in seconds.  Remaining
arguments are hex-encoded payloads to write to stdout.  After each write,
the script prints `GHOSTEL_PTY_REPLY_N_HEX:' followed by any reply bytes
read from stdin as lowercase hex.")

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
Emacs PTY and native event output can be drained."
  (let* ((timeout (or timeout 5))
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

(defun ghostel-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit '(not (tag native))))

(defun ghostel-test-run-native ()
  "Run only tests that require the native module."
  (ert-run-tests-batch-and-exit '(tag native)))

(defun ghostel-test-run ()
  "Run all ghostel tests."
  (ert-run-tests-batch-and-exit "^ghostel-test-"))

(provide 'ghostel-test-helpers)
;;; ghostel-test-helpers.el ends here
