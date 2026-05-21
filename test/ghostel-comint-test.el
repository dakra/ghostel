;;; ghostel-comint-test.el --- Tests for ghostel-comint -*- lexical-binding: t; -*-

;;; Commentary:

;; Integration tests for `ghostel-comint-mode': comint owns input editing,
;; ghostel owns output rendering via per-command anchored terminals.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-comint)

(defun ghostel-test-comint--count-matches (regexp)
  "Return how many times REGEXP matches in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (re-search-forward regexp nil t)
        (setq n (1+ n)))
      n)))

(defmacro ghostel-test-comint--with-shell (&rest body)
  "Run BODY in a fresh `ghostel-comint-mode' buffer with /bin/sh spawned.
Binds `buf' to the buffer and `proc' to the shell process.  Waits up
to 5 seconds for the initial shell prompt to render before running
BODY.  Cleans up the buffer and process on exit."
  (declare (indent 0) (debug t))
  `(let ((buf (generate-new-buffer " *ghostel-comint-test*")))
     (unwind-protect
         (with-current-buffer buf
           (ghostel-comint-mode)
           (ghostel-comint--spawn buf "/bin/sh" nil)
           (let ((proc (get-buffer-process buf)))
             (ghostel-test--wait-for proc
                                     (lambda () (> (point-max) 5))
                                     5)
             ,@body
             (when (process-live-p proc)
               (set-process-query-on-exit-flag proc nil)
               (delete-process proc))))
       (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-comint-basic-echo ()
  "A simple `echo' command produces rendered output in the buffer."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "echo GHOSTEL-CT-ECHO")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-ECHO") 2))
     10)
    (should (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-ECHO") 2))))

(ert-deftest ghostel-test-comint-ansi-color ()
  "An ANSI SGR sequence renders with a `face' text-property."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "printf '\\033[31mGCRED\\033[0m\\n'")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (and (>= (ghostel-test-comint--count-matches "GCRED") 2)
            (save-excursion
              (goto-char (point-min))
              (let (face-found)
                (while (and (not face-found)
                            (re-search-forward "GCRED" nil t))
                  (let ((face (get-text-property (match-beginning 0)
                                                 'face)))
                    (when face (setq face-found face))))
                face-found))))
     10)
    (save-excursion
      (goto-char (point-max))
      (re-search-backward "GCRED")
      (let ((face (get-text-property (point) 'face)))
        (should face)
        (should (plist-get face :foreground))))))

(ert-deftest ghostel-test-comint-cr-overwrite ()
  "CR (\\r) returns the cursor to column 0; the next write overwrites.
Sends `printf hello\\rwor\\n'.  The rendered output should contain
`worlo' (CR moved the cursor back, `wor' overwrote `hel'), NOT a
literal `hello\\rwor' run."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "printf 'hello\\rwor\\n'")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (save-excursion
         (goto-char (point-min))
         (search-forward "worlo" nil t)))
     10)
    (should
     (save-excursion
       (goto-char (point-min))
       (search-forward "worlo" nil t)))))

(ert-deftest ghostel-test-comint-multi-command-persistence ()
  "Output of a previous command stays in the buffer after the next runs."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "echo GHOSTEL-CT-FIRST")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-FIRST") 2))
     10)
    (goto-char (point-max))
    (insert "echo GHOSTEL-CT-SECOND")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-SECOND") 2))
     10)
    (should (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-FIRST") 2))
    (should (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-SECOND") 2))
    ;; At most one anchored terminal is live (the most recent).  Zero
    ;; is also fine -- OSC 133 D may have retired the active one
    ;; already if the shell has integration installed.
    (should (<= (hash-table-count ghostel--anchored-terminals) 1))))

(ert-deftest ghostel-test-comint-input-history ()
  "Submitted input lands in the comint input ring.
`comint-previous-input' (bound to \\`M-p') recalls the most recent input."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "echo GHOSTEL-CT-HIST")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-HIST") 2))
     10)
    (goto-char (point-max))
    (let ((pmark (process-mark proc)))
      (should (= (point) (marker-position pmark))))
    (comint-previous-input 1)
    (let ((pmark (process-mark proc)))
      (should (string= "echo GHOSTEL-CT-HIST"
                       (buffer-substring-no-properties
                        (marker-position pmark) (point)))))))

(ert-deftest ghostel-test-comint-cleanup-on-kill ()
  "Killing the buffer mid-run reaps the process and clears state."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-comint-cleanup*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-comint-mode)
          (ghostel-comint--spawn buf "/bin/sh" nil)
          (let ((proc (get-buffer-process buf)))
            (ghostel-test--wait-for proc
                                    (lambda () (> (point-max) 5))
                                    5)
            (goto-char (point-max))
            (insert "for i in 1 2 3 4 5; do echo GCT-LINE-$i; sleep 0.05; done")
            (comint-send-input)
            (ghostel-test--wait-for
             proc
             (lambda ()
               (save-excursion
                 (goto-char (point-min))
                 (search-forward "GCT-LINE-1" nil t)))
             5)
            (set-process-query-on-exit-flag proc nil)
            (kill-buffer buf)
            (let ((deadline (+ (float-time) 3.0)))
              (while (and (process-live-p proc) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should-not (process-live-p proc))
            (should-not (buffer-live-p buf))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-comint-window-resize ()
  "`ghostel-comint--adjust-window-size' resizes the active grid."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "echo GHOSTEL-CT-RESIZE")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-RESIZE") 2))
     10)
    ;; A fresh terminal exists by now -- either created when the
    ;; original prompt rendered, or retired and recreated by the
    ;; echo command's input-sender.
    (when (null ghostel-comint--term)
      (ghostel-comint--make-terminal proc))
    (should ghostel-comint--term)
    (let* ((before-rows ghostel-comint--rows)
           (before-cols ghostel-comint--cols)
           (target-rows (+ before-rows 3))
           (target-cols (+ before-cols 7))
           (window-adjust-process-window-size-function
            (lambda (_proc _windows) (cons target-cols target-rows))))
      (let ((size (ghostel-comint--adjust-window-size proc nil)))
        (should size)
        (should (= (car size) target-cols))
        (should (= (cdr size) target-rows)))
      (should (= ghostel-comint--rows target-rows))
      (should (= ghostel-comint--cols target-cols))
      (let ((window-adjust-process-window-size-function
             (lambda (_proc _windows) (cons target-cols target-rows))))
        (should-not (ghostel-comint--adjust-window-size proc nil))))))

(ert-deftest ghostel-test-comint-sentinel-exit-notice ()
  "Shell `exit' triggers our sentinel; notice lands as inert text."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-comint-sentinel*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-comint-mode)
          (ghostel-comint--spawn buf "/bin/sh" nil)
          (let ((proc (get-buffer-process buf)))
            (ghostel-test--wait-for proc (lambda () (> (point-max) 5)) 5)
            (goto-char (point-max))
            (insert "exit")
            (comint-send-input)
            (let ((deadline (+ (float-time) 5.0)))
              (while (and (process-live-p proc) (< (float-time) deadline))
                (accept-process-output proc 0.05)))
            (should-not (process-live-p proc))
            (let ((deadline (+ (float-time) 1.0)))
              (while (and ghostel-comint--term (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should-not ghostel-comint--term)
            (should (= 0 (hash-table-count
                          (or ghostel--anchored-terminals
                              (make-hash-table)))))
            (should
             (save-excursion
               (goto-char (point-min))
               (re-search-forward "Process ghostel-comint " nil t)))
            (should (buffer-live-p buf))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-comint-user-text-not-clobbered-by-quiet-period ()
  "Typed input remains in the buffer when no further output is rendered.
Regression guard: after a command renders, with no new output flowing
in, no further redraw happens, and the typed bytes must still be in
the buffer.  Typing INTO the active anchored region (past the
`process-mark') is not supported in v1; this test only covers typing
at the comint input area."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "echo GCT-USER-Q1")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GCT-USER-Q1") 2))
     10)
    (let ((tag "GCT-USER-AT-INPUT-AREA")
          (pmark (process-mark proc)))
      (goto-char (marker-position pmark))
      (insert tag)
      (accept-process-output proc 0.1)
      (should
       (save-excursion
         (goto-char (point-min))
         (search-forward tag nil t))))))

(ert-deftest ghostel-test-comint-retired-region-inert ()
  "After a second command, the first command's region is plain text."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "echo GHOSTEL-CT-RETIRE-A")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-RETIRE-A") 2))
     10)
    (let ((first-term ghostel-comint--term))
      (should first-term)
      ;; First terminal must be live in the hash table until retired.
      ;; (May also be retired by OSC 133 D before we observe.)
      (goto-char (point-max))
      (insert "echo GHOSTEL-CT-RETIRE-B")
      (comint-send-input)
      (ghostel-test--wait-for
       proc
       (lambda ()
         (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-RETIRE-B") 2))
       10)
      (should-not (gethash first-term ghostel--anchored-terminals))
      (should (<= (hash-table-count ghostel--anchored-terminals) 1))
      (should-not (eq first-term ghostel-comint--term))
      (should (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-RETIRE-A")
                  2)))))

(ert-deftest ghostel-test-comint-field-navigation ()
  "Anchored region text carries `field=output' for comint navigation."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (goto-char (point-max))
    (insert "echo GHOSTEL-CT-FIELD")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-FIELD") 2))
     10)
    (let* ((pos (save-excursion
                  (goto-char (point-max))
                  (re-search-backward "GHOSTEL-CT-FIELD")
                  (point))))
      (should (eq 'output (get-char-property pos 'field))))))

(provide 'ghostel-comint-test)
;;; ghostel-comint-test.el ends here
