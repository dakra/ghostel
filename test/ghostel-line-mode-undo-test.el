;;; ghostel-line-mode-undo-test.el --- Tests for line-mode undo -*- lexical-binding: t; -*-

;;; Commentary:

;; Undo in line mode records user edits in the input region only.
;; Renderer mutations and snapshot/restore bookkeeping stay out of the
;; undo list, and recording is disabled outside line mode.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-line-mode-undo-test--undo (&optional first)
  "Invoke the real `undo' command with batch-friendly command bookkeeping.
With FIRST non-nil this is the first undo in a sequence (so
`last-command' must not be `undo'); otherwise it chains onto the
previous undo."
  `(let ((this-command 'undo)
         (last-command ,(if first t ''undo)))
     (undo)))

(defun ghostel-line-mode-undo-test--enter-line-mode (term)
  "Write a fresh OSC 133 prompt to TERM, redraw, and enter line mode.
Stubs the process predicates so `ghostel-line-mode' runs without a
live PTY.  Leaves the buffer in line mode with point at the input."
  (ghostel--write-vt term "\e]133;A\e\\$ \e]133;B\e\\")
  (ghostel-test--redraw term t)
  (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
            ((symbol-function 'ghostel--write-pty) #'ignore)
            ((symbol-function 'ghostel--invalidate) #'ignore))
    (ghostel-line-mode)))

;; 6.1 — typing then undo reverts the in-progress input.
(ert-deftest ghostel-test-line-mode-undo-reverts-input ()
  "Typing in line mode is recorded; `undo' reverts it edit by edit."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
    (set-window-buffer (selected-window) buf)
    (setq ghostel--process 'fake-proc)
    (ghostel-line-mode-undo-test--enter-line-mode term)
    (should (eq ghostel--input-mode 'line))
    ;; Recording is armed (a list, not t).
    (should (listp buffer-undo-list))
    ;; Two edits separated by a boundary (batch has no command loop to
    ;; auto-amalgamate / insert boundaries).
    (insert "ls")
    (undo-boundary)
    (insert " -la")
    (undo-boundary)
    (should (equal (ghostel--line-mode-input-text) "ls -la"))
    (ghostel-line-mode-undo-test--undo t)
    (should (equal (ghostel--line-mode-input-text) "ls"))
    (ghostel-line-mode-undo-test--undo)
    (should (equal (ghostel--line-mode-input-text) ""))))

;; 6.2 — undo is off outside line mode, on inside, off again after exit.
(ert-deftest ghostel-test-line-mode-undo-disabled-outside-line-mode ()
  "`buffer-undo-list' is t in semi-char, a list in line mode, t again after."
  (let ((buf (generate-new-buffer " *ghostel-test-line-undo-off*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          ;; Fresh ghostel-mode buffer: recording off.
          (should (eq buffer-undo-list t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-line-mode)
              (should (eq ghostel--input-mode 'line))
              ;; Armed: a list, recording on.
              (should (listp buffer-undo-list))
              ;; Tear back down to semi-char.
              (ghostel-semi-char-mode)
              (should (eq ghostel--input-mode 'semi-char))
              (should (eq buffer-undo-list t)))))
      (kill-buffer buf))))

;; 6.3 — undo can never reach into the scrollback / prompt.
(ert-deftest ghostel-test-line-mode-undo-cannot-touch-scrollback ()
  "Undo only touches the input region; scrollback stays byte-for-byte intact.
The recorded undo list also carries no position before the input
start, so an undo can never delete the prompt or earlier output."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
    (set-window-buffer (selected-window) buf)
    (setq ghostel--process 'fake-proc)
    ;; Some prior output to form scrollback, then a fresh prompt.
    (ghostel--write-vt term "hello\r\nworld\r\n\e]133;A\e\\$ \e]133;B\e\\")
    (ghostel-test--redraw term t)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'ghostel--write-pty) #'ignore)
              ((symbol-function 'ghostel--invalidate) #'ignore))
      (ghostel-line-mode)
      (should (eq ghostel--input-mode 'line))
      (let* ((input-start (marker-position ghostel--line-input-start))
             (scrollback-before (buffer-substring-no-properties
                                 (point-min) input-start)))
        (insert "rm -rf /")
        (undo-boundary)
        ;; Every recorded change refers to a position >= input-start.
        (dolist (entry buffer-undo-list)
          (let ((pos (cond
                      ;; (TEXT . POSITION) — insertion record.
                      ((and (consp entry) (stringp (car entry)))
                       (abs (cdr entry)))
                      ;; (BEG . END) — deletion record.
                      ((and (consp entry) (integerp (car entry))
                            (integerp (cdr entry)))
                       (min (car entry) (cdr entry)))
                      (t nil))))
            (when pos
              (should (>= pos input-start)))))
        (ghostel-line-mode-undo-test--undo t)
        (should (equal (ghostel--line-mode-input-text) ""))
        ;; Scrollback is unchanged.
        (should (equal (buffer-substring-no-properties
                        (point-min) input-start)
                       scrollback-before))))))

;; 6.4 — a redraw firing between edits does not corrupt undo.
;; Redraw rewrites must stay out of undo history.  After a prompt moves,
;; new edits should undo at the input's current position.
(ert-deftest ghostel-test-line-mode-redraw-between-edits-no-undo-pollution ()
  "A redraw mid-edit preserves the input and leaves undo well-formed.
The renderer's mutations never enter the undo list, the stale
pre-redraw history is discarded, and a subsequent edit undoes
correctly against the input's new position."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
    (set-window-buffer (selected-window) buf)
    (setq ghostel--process 'fake-proc)
    (ghostel-line-mode-undo-test--enter-line-mode term)
    (should (eq ghostel--input-mode 'line))
    (insert "foo")
    (undo-boundary)
    ;; Drive a redraw between edits: shell output streams in and a new
    ;; prompt is painted.  The renderer rewrites the whole viewport
    ;; (line mode forces full redraws).
    (ghostel--write-vt term "some output\r\n\e]133;A\e\\$ \e]133;B\e\\")
    (ghostel--redraw-now buf)
    ;; The input survived snapshot/restore.
    (should (equal (ghostel--line-mode-input-text) "foo"))
    ;; Renderer rewrites did not pollute undo.
    (should (null buffer-undo-list))
    ;; A new edit after the redraw undoes at the input's current position.
    (let ((scrollback-before (buffer-substring-no-properties
                              (point-min)
                              (marker-position ghostel--line-input-start))))
      (goto-char (marker-position ghostel--line-input-end))
      (insert "bar")
      (undo-boundary)
      (should (equal (ghostel--line-mode-input-text) "foobar"))
      (ghostel-line-mode-undo-test--undo t)
      (should (equal (ghostel--line-mode-input-text) "foo"))
      ;; And the scrollback the renderer wrote is untouched by the undo.
      (should (equal (buffer-substring-no-properties
                      (point-min)
                      (marker-position ghostel--line-input-start))
                     scrollback-before)))))

;; 6.5 — sending a line clears the undo history.
(ert-deftest ghostel-test-line-mode-send-clears-undo ()
  "After RET the undo history is empty; the sent line can't be revived."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
    (set-window-buffer (selected-window) buf)
    (setq ghostel--process 'fake-proc)
    (ghostel-line-mode-undo-test--enter-line-mode term)
    (should (eq ghostel--input-mode 'line))
    (insert "echo hi")
    (undo-boundary)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'ghostel--write-pty) #'ignore)
              ((symbol-function 'ghostel--send-encoded) #'ignore))
      (ghostel-line-mode-send))
    ;; History cleared.
    (should (eq buffer-undo-list nil))
    ;; An undo now does nothing useful — the sent line is not revived.
    (let ((before (ghostel--line-mode-input-text)))
      (ignore-errors (ghostel-line-mode-undo-test--undo t))
      (should (equal (ghostel--line-mode-input-text) before)))))

(provide 'ghostel-line-mode-undo-test)
;;; ghostel-line-mode-undo-test.el ends here
