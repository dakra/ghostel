;;; ghostel-comint-test.el --- Tests for ghostel-comint-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the global minor mode `ghostel-comint-mode': comint owns
;; input editing, ghostel owns output rendering via per-exchange
;; anchored terminals.  Tests run against a real /bin/sh subprocess
;; spawned via `make-comint-in-buffer'.

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

(defun ghostel-test-comint--goto-input (proc)
  "Position point where the next user input would go for PROC.
After a render, `process-mark' sits at the libghostty cursor (just
before any trailing newline the renderer materialized), which is
where an interactive user's cursor lands.  Use this instead of
`(goto-char (point-max))' in tests so they exercise the same code
path that interactive use does."
  (goto-char (marker-position (process-mark proc))))

(defmacro ghostel-test-comint--with-shell (&rest body)
  "Spawn /bin/sh in a fresh buffer with `ghostel-comint-mode' enabled.
BODY runs in the buffer (with `buf' and `proc' bound).  Waits up to
5 seconds for the initial prompt to render before BODY.  Ensures the
global mode and any spawned subprocess are cleaned up on exit,
regardless of the global mode state on entry."
  (declare (indent 0) (debug t))
  `(let ((buf (generate-new-buffer " *ghostel-comint-test*"))
         (was-on ghostel-comint-mode))
     (unwind-protect
         (progn
           (unless was-on (ghostel-comint-mode 1))
           (with-current-buffer buf
             (make-comint-in-buffer "ghostel-comint-test" buf "/bin/sh")
             (let ((proc (get-buffer-process buf)))
               ;; Disable the query-on-exit flag immediately, BEFORE any
               ;; assertion that might raise: an unhandled error in
               ;; `body' otherwise leaves the process live, and the
               ;; outer `kill-buffer' would then prompt — which in batch
               ;; mode reads EOF and crashes the runner without
               ;; surfacing the original assertion failure.
               (set-process-query-on-exit-flag proc nil)
               (ghostel-test--wait-for proc
                                       (lambda () (> (point-max) 5))
                                       5)
               ,@body
               (when (process-live-p proc)
                 (delete-process proc)))))
       (unless was-on (ghostel-comint-mode -1))
       (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-comint-mode-toggle ()
  "Enabling the global mode adds hooks; disabling removes them."
  :tags '(native)
  (let ((was-on ghostel-comint-mode))
    (unwind-protect
        (progn
          (ghostel-comint-mode -1)
          (should-not (memq #'ghostel-comint--setup comint-mode-hook))
          (should-not (memq #'ghostel-comint--install comint-exec-hook))
          (ghostel-comint-mode 1)
          (should (memq #'ghostel-comint--setup comint-mode-hook))
          (should (memq #'ghostel-comint--install comint-exec-hook))
          ;; Idempotency: enabling twice doesn't double-install
          (ghostel-comint-mode 1)
          (should (= 1 (cl-count #'ghostel-comint--setup comint-mode-hook)))
          (ghostel-comint-mode -1)
          (should-not (memq #'ghostel-comint--setup comint-mode-hook))
          (should-not (memq #'ghostel-comint--install comint-exec-hook)))
      (if was-on (ghostel-comint-mode 1) (ghostel-comint-mode -1)))))

(ert-deftest ghostel-test-comint-basic-echo ()
  "A simple `echo' command produces rendered output in the buffer."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
    (insert "echo GHOSTEL-CT-ECHO")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-ECHO") 2))
     10)
    (should (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-ECHO") 2))))

(ert-deftest ghostel-test-comint-active-flag-set ()
  "`ghostel-comint--active' is set in the comint buffer."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (should ghostel-comint--active)
    (should (eq comint-input-sender #'ghostel-comint--input-sender-wrapper))
    (should comint-inhibit-carriage-motion)))

(ert-deftest ghostel-test-comint-term-bump ()
  "Spawned subprocess sees TERM=xterm-ghostty."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
    (insert "printf '@@TERM=%s@@\\n' \"$TERM\"")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (save-excursion
         (goto-char (point-min))
         (re-search-forward "@@TERM=xterm-ghostty@@" nil t)))
     10)
    (should
     (save-excursion
       (goto-char (point-min))
       (re-search-forward "@@TERM=xterm-ghostty@@" nil t)))))

(ert-deftest ghostel-test-comint-ansi-color ()
  "An ANSI SGR sequence renders with a `face' text-property."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
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
      (ghostel-test-comint--goto-input proc)
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
    (ghostel-test-comint--goto-input proc)
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

(ert-deftest ghostel-test-comint-no-trailing-empty-lines ()
  "After a short command, no long tail of empty rows sits below the prompt.
The renderer's grid is 24 rows; the trim hook removes everything past
the cursor's line.  Allow up to a couple of blank lines as slack — we
assert there is NOT a 22+-line blank tail."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
    (insert "echo GCT-TRIM-MARKER")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GCT-TRIM-MARKER") 2))
     10)
    ;; Wait for the next prompt to settle so the trim has run on the
    ;; final chunk.
    (accept-process-output proc 0.3)
    (let* ((pmark (process-mark proc))
           (pend (marker-position pmark))
           (tail (buffer-substring-no-properties pend (point-max))))
      ;; Past the process mark there should be at most a handful of
      ;; whitespace characters (trailing newline, maybe one blank line).
      ;; A pre-trim implementation leaves ~22 blank lines (88+ chars).
      (should (< (length tail) 32)))))

(ert-deftest ghostel-test-comint-multi-command-persistence ()
  "Output of a previous command stays in the buffer after the next runs."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
    (insert "echo GHOSTEL-CT-FIRST")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-FIRST") 2))
     10)
    (ghostel-test-comint--goto-input proc)
    (insert "echo GHOSTEL-CT-SECOND")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-SECOND") 2))
     10)
    (should (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-FIRST") 2))
    (should (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-SECOND") 2))
    (should (<= (hash-table-count ghostel--anchored-terminals) 1))))

(ert-deftest ghostel-test-comint-input-history ()
  "Submitted input lands in the comint input ring.
`comint-previous-input' (bound to \\`M-p') recalls the most recent input."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
    (insert "echo GHOSTEL-CT-HIST")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-HIST") 2))
     10)
    (ghostel-test-comint--goto-input proc)
    (let ((pmark (process-mark proc)))
      (should (= (point) (marker-position pmark))))
    (comint-previous-input 1)
    (let ((pmark (process-mark proc)))
      (should (string= "echo GHOSTEL-CT-HIST"
                       (buffer-substring-no-properties
                        (marker-position pmark) (point)))))))

(ert-deftest ghostel-test-comint-window-resize ()
  "`ghostel-comint--adjust-window-size' resizes the active grid."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
    (insert "echo GHOSTEL-CT-RESIZE")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-RESIZE") 2))
     10)
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

(ert-deftest ghostel-test-comint-cleanup-on-kill ()
  "Killing the buffer mid-run reaps the process and clears state."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-comint-cleanup*"))
        (was-on ghostel-comint-mode))
    (unwind-protect
        (progn
          (unless was-on (ghostel-comint-mode 1))
          (with-current-buffer buf
            (make-comint-in-buffer "ghostel-comint-cleanup" buf "/bin/sh")
            (let ((proc (get-buffer-process buf)))
              (ghostel-test--wait-for proc
                                      (lambda () (> (point-max) 5))
                                      5)
              (ghostel-test-comint--goto-input proc)
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
              (should-not (buffer-live-p buf)))))
      (unless was-on (ghostel-comint-mode -1))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-comint-user-text-not-clobbered-by-quiet-period ()
  "Typed input remains in the buffer when no further output is rendered."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
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
    (ghostel-test-comint--goto-input proc)
    (insert "echo GHOSTEL-CT-RETIRE-A")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-RETIRE-A") 2))
     10)
    (let ((first-term ghostel-comint--term))
      (should first-term)
      (ghostel-test-comint--goto-input proc)
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

(ert-deftest ghostel-test-comint-survives-shell-mode-reset ()
  "Survive a derived-mode re-entry that calls `kill-all-local-variables'.
\\[shell] calls `shell-mode' on top of an already-set-up comint
buffer; that wipes the input-sender wrap and would otherwise leave
our output filter duplicated in the permanent-local
`comint-output-filter-functions'.  Both invariants must survive."
  :tags '(native)
  (require 'shell)
  (let ((buf (generate-new-buffer " *ghostel-comint-shellmode*"))
        (was-on ghostel-comint-mode))
    (unwind-protect
        (progn
          (unless was-on (ghostel-comint-mode 1))
          (with-current-buffer buf
            (make-comint-in-buffer "ghostel-comint-shellmode" buf "/bin/sh")
            ;; Force a derived-mode re-entry: this is what `M-x shell'
            ;; effectively does at the end of `(shell)' after the
            ;; subprocess is already spawned in `comint-mode'.
            (shell-mode)
            (should (eq comint-input-sender
                        #'ghostel-comint--input-sender-wrapper))
            (should (= 1 (cl-count #'ghostel-comint--output-filter
                                   comint-output-filter-functions)))
            (let ((proc (get-buffer-process buf)))
              (when (process-live-p proc)
                (set-process-query-on-exit-flag proc nil)
                (delete-process proc)))))
      (unless was-on (ghostel-comint-mode -1))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-comint-field-navigation ()
  "Anchored region text carries `field=output' for comint navigation."
  :tags '(native)
  (ghostel-test-comint--with-shell
    (ghostel-test-comint--goto-input proc)
    (insert "echo GHOSTEL-CT-FIELD")
    (comint-send-input)
    (ghostel-test--wait-for
     proc
     (lambda ()
       (>= (ghostel-test-comint--count-matches "GHOSTEL-CT-FIELD") 2))
     10)
    (let* ((pos (save-excursion
                  (ghostel-test-comint--goto-input proc)
                  (re-search-backward "GHOSTEL-CT-FIELD")
                  (point))))
      (should (eq 'output (get-char-property pos 'field))))))

(define-derived-mode ghostel-test-comint-excluded-mode comint-mode "ExclTest"
  "Stub comint-derived mode used by the excluded-modes test.")

(ert-deftest ghostel-test-comint-excluded-mode ()
  "A mode listed in `ghostel-comint-excluded-modes' is left vanilla."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-comint-excluded*"))
        (was-on ghostel-comint-mode)
        (ghostel-comint-excluded-modes
         '(ghostel-test-comint-excluded-mode)))
    (unwind-protect
        (progn
          (unless was-on (ghostel-comint-mode 1))
          (with-current-buffer buf
            (ghostel-test-comint-excluded-mode)
            (make-comint-in-buffer "ghostel-comint-excluded" buf "/bin/sh")
            (should-not ghostel-comint--active)
            (should-not
             (memq #'ghostel-comint--output-filter
                   comint-output-filter-functions))
            (should-not (eq comint-input-sender
                            #'ghostel-comint--input-sender-wrapper))
            (let ((proc (get-buffer-process buf)))
              (when (process-live-p proc)
                (set-process-query-on-exit-flag proc nil)
                (delete-process proc)))))
      (unless was-on (ghostel-comint-mode -1))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'ghostel-comint-test)
;;; ghostel-comint-test.el ends here
