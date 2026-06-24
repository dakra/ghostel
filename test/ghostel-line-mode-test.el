;;; ghostel-line-mode-test.el --- Tests for ghostel: line-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Line mode: entry/exit, alt-screen pause/resume, input-region API,
;; snapshot/restore, history, TAB completion.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-test--with-input-fixture (prompt input &rest body)
  "Set up a mock terminal buffer with PROMPT (carrying `ghostel-prompt')
followed by INPUT, with `ghostel--cursor-char-pos' positioned at the
end of INPUT.  Runs BODY in the buffer.

Mocks the terminal handle and viewport so the new public input-region
helpers can derive prompt boundaries and viewport rows without a real
native module."
  (declare (indent 2))
  `(let ((buf (generate-new-buffer " *ghostel-test-input*")))
     (unwind-protect
         (with-current-buffer buf
           (ghostel-mode)
           (ghostel-test--with-rendered-output
             (insert (propertize ,prompt 'ghostel-prompt t))
             (insert ,input))
           (setq ghostel--term 'fake)
           (setq ghostel--term-rows 1)
           (setq ghostel--cursor-char-pos (point))
           (setq ghostel--cursor-pos (cons (current-column) 0))
           ,@body)
       (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-live-redraws-preserve-input ()
  "Line mode redraws live; in-progress input survives via snapshot/restore.
Output keeps streaming around the prompt while the user composes,
and the snapshot/restore path in `ghostel--redraw-now' puts
the input region back after each redraw so the user's typing is
not clobbered."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
    (setq ghostel-detect-password-prompts nil)
    (set-window-buffer (selected-window) buf)
    (setq ghostel--process 'fake-proc)
    ;; First prompt with OSC 133 A/B markers.
    (ghostel--write-vt term "\e]133;A\e\\$ \e]133;B\e\\")
    (ghostel-test--redraw term t)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'ghostel--write-pty) #'ignore)
              ((symbol-function 'ghostel--invalidate) #'ignore))
      (ghostel-line-mode)
      (should (eq ghostel--input-mode 'line))
      (should (markerp ghostel--line-input-start))
      ;; Type some input locally.
      (insert "ls")
      (should (equal (ghostel--line-mode-input-text) "ls"))
      ;; Simulate the post-RET sequence: shell echoes the line,
      ;; runs the command, prints output, then a new prompt
      ;; with OSC 133 markers.  The redraw must preserve the
      ;; user's input AND show the new output above the new
      ;; prompt.
      (ghostel--write-vt term
                         "ls\r\nfile1\r\n\e]133;A\e\\$ \e]133;B\e\\")
      (ghostel--redraw-now buf)
      ;; Input is still there.
      (should (equal (ghostel--line-mode-input-text) "ls"))
      ;; New output is in the buffer.
      (let ((content (buffer-substring-no-properties
                      (point-min) (point-max))))
        (should (string-match-p "file1" content)))
      ;; Marker now points at the NEW prompt-end, not the old
      ;; one — find-prompt-end picks the last prompt char.
      ;; Exit cleans up state.
      (ghostel-semi-char-mode)
      (should-not (text-property-any (point-min) (point-max)
                                     'read-only t)))))

(ert-deftest ghostel-test-mouse-1-drag-no-tracking-line-mode-no-copy-mode ()
  "Drag-end in line mode does not enter copy mode.
Line mode keeps its own buffer state and must not be flipped into
copy mode behind the user's back."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (set-region-arg nil)
        (copy-mode-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'line)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'mouse-set-region)
                 (lambda (event) (setq set-region-arg event)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t))))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should (equal fake-event set-region-arg))
      (should-not copy-mode-called))))

(ert-deftest ghostel-test-input-start-point-walks-back-without-cursor ()
  "`ghostel-input-start-point' walks back from `point-max'.
Exercises the fallback path used when no live terminal cursor is
available (unit tests, native module not loaded)."
  (with-temp-buffer
    ;; No prompt property anywhere → nil
    (insert "plain text")
    (should-not (ghostel-input-start-point))
    ;; With prompt property
    (erase-buffer)
    (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
    (insert "")  ; cursor right after prompt
    (should (= (ghostel-input-start-point) 3))
    ;; With prompt property followed by user-typed content
    (erase-buffer)
    (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
    (insert "ls -la")
    (should (= (ghostel-input-start-point) 3))))

(ert-deftest ghostel-test-input-start-point-uses-cursor-without-prop ()
  "When a terminal cursor is available, it anchors the input boundary.
Mimics a python3-style REPL: no `ghostel-prompt' anywhere, but the
cursor sits at the end of the `>>> ' prompt the REPL printed."
  (let ((buf (generate-new-buffer " *ghostel-test-line-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-test--insert-rendered ">>> \n")
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--cursor-char-pos 5)
          ;; Cursor at char-pos 5 → `ghostel-input-start-point'
          ;; returns 5, pointing right after `>>> '.
          (should (= (ghostel-input-start-point) 5)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-input-start-point-prefers-cursor-over-stale-prompt ()
  "A stale `ghostel-prompt' above the cursor row is ignored.
When bash printed an OSC-133 prompt and then the user launched
python3 (which doesn't speak OSC 133), the only `ghostel-prompt'
chars in the buffer are above the python session.  The cursor row
takes precedence so input is sent to python3, not concatenated
onto the bash prompt."
  (let ((buf (generate-new-buffer " *ghostel-test-line-stale-prompt*")))
    (unwind-protect
        (with-current-buffer buf
          ;; 3 renderer rows: bash row + 2 python rows.
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (insert "python3\n")
          (insert "Python 3.x\n")
          (ghostel-test--insert-rendered ">>> \n")
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 3)
          (setq ghostel--cursor-char-pos (1- (point-max)))
          (let ((pos (ghostel-input-start-point)))
            (should pos)
            (should (string= ">>> "
                             (buffer-substring-no-properties
                              (- pos 4) pos)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-input-start-point-returns-after-prompt-prop ()
  "`ghostel-input-start-point' returns position right after the prompt prefix."
  (ghostel-test--with-input-fixture "$ " "ls -la"
    (should (= 3 (ghostel-input-start-point)))))

(ert-deftest ghostel-test-input-start-point-without-prop-or-regex-uses-cursor ()
  "When neither prop nor regex finds a prompt, returns the cursor position.
The cursor is the final fallback so empty / non-shell lines still
have a usable input boundary."
  (let ((buf (generate-new-buffer " *ghostel-test-input-nocursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--with-rendered-output
            ;; Line has no prompt prefix and no prompt char anywhere —
            ;; `ghostel-prompt-regexp' can't match, so the cursor wins.
            (insert "plain text line"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--cursor-char-pos (point))
          (setq ghostel--cursor-pos (cons (current-column) 0))
          (should (= (point) (ghostel-input-start-point))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-input-start-point-regex-fallback-python ()
  "Regex fallback detects `>>> ' prompt when OSC 133 isn't available."
  (let ((buf (generate-new-buffer " *ghostel-test-input-regex-py*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--with-rendered-output
            ;; Python REPL line — no prop, but `>>> ' matches the regex.
            (insert ">>> hello"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--cursor-char-pos (point))
          (setq ghostel--cursor-pos (cons (current-column) 0))
          ;; Regex matches `>>> ' ending at pos 5 → input starts at 5.
          (should (= 5 (ghostel-input-start-point))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-input-start-point-regex-fallback-lambda ()
  "Regex fallback detects `λ ' prompts."
  (let ((buf (generate-new-buffer " *ghostel-test-input-regex-lambda*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "λ ls")
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--cursor-char-pos (point))
          (setq ghostel--cursor-pos (cons (current-column) 0))
          ;; `λ ' is 2 chars (λ + space) so input-start at 3.
          (should (= 3 (ghostel-input-start-point))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-input-start-point-prop-wins-over-regex ()
  "When both `ghostel-prompt' prop and the regex match, prop wins.
Constructs a fixture where the two methods disagree: the prop is
set only on the `$' (position 1), so the walk-back returns position
2; the regex still matches `$ ' and would return position 3.  The
result must be 2 to prove the prop branch is consulted first."
  (let ((buf (generate-new-buffer " *ghostel-test-input-prop-wins*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--with-rendered-output
            ;; Prop ONLY on the `$' — not the space.  The walk-back in
            ;; `ghostel-input-start-point' stops as soon as it finds any
            ;; `ghostel-prompt' char, so it returns the position right after
            ;; the `$' (= 2).  The regex would match `$ ' (end = 3).
            ;; Different answers → precedence matters.
            (ghostel-test--insert-rendered (propertize "$" 'ghostel-prompt t))
            (insert " ls"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--cursor-char-pos (point))
          (setq ghostel--cursor-pos (cons (current-column) 0))
          (should (= 2 (ghostel-input-start-point))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-input-start-point-regex-disabled-falls-back-to-cursor ()
  "Setting `ghostel-prompt-regexp' to nil disables the regex fallback."
  (let ((buf (generate-new-buffer " *ghostel-test-input-regex-off*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--with-rendered-output
            (insert ">>> hello"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--cursor-char-pos (point))
          (setq ghostel--cursor-pos (cons (current-column) 0))
          ;; With regex off, the only fallback is the cursor — pos 10.
          (let ((ghostel-prompt-regexp nil))
            (should (= 10 (ghostel-input-start-point)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-cursor-point-tracks-cursor-char-pos ()
  "`ghostel-cursor-point' returns the cursor position, not `(point)'.
Also verifies the documented nil-return when no cursor is available."
  (ghostel-test--with-input-fixture "$ " "hello"
    (let ((cursor-pos ghostel--cursor-char-pos))
      ;; Move point away from the cursor; the function still returns the
      ;; terminal cursor position.
      (goto-char (point-min))
      (should-not (= (point) cursor-pos))
      (should (= cursor-pos (ghostel-cursor-point))))
    ;; Documented contract: nil when no cursor is available.
    (let ((ghostel--cursor-char-pos nil))
      (should-not (ghostel-cursor-point)))))

(ert-deftest ghostel-test-point-on-cursor-row-p-true ()
  "Returns t when point sits on the cursor's row."
  (ghostel-test--with-input-fixture "$ " "hello world"
    (should (ghostel-point-on-cursor-row-p))
    ;; Explicit position on the same row.
    (should (ghostel-point-on-cursor-row-p 5))))

(ert-deftest ghostel-test-point-on-cursor-row-p-false-on-other-row ()
  "Returns nil when POS is on a different buffer row."
  (let ((buf (generate-new-buffer " *ghostel-test-multirow*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--with-rendered-output
            (insert "first line\n")
            (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
            (insert "second"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 2)
          (setq ghostel--cursor-char-pos (point))
          (setq ghostel--cursor-pos (cons (current-column) 1))
          ;; Point on the cursor row → t.
          (should (ghostel-point-on-cursor-row-p))
          ;; Point on the first row → nil.
          (should-not (ghostel-point-on-cursor-row-p 5)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-requires-anchor ()
  "Line mode refuses to enter when neither cursor nor prompt mark exists."
  (let ((buf (generate-new-buffer " *ghostel-test-line-noprompt*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil)))
              (should-error (ghostel-line-mode) :type 'user-error))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-copy-to-line-restarts-redraw-timer ()
  "Copy → line transition re-arms the redraw timer.
Copy mode freezes the timer; line mode is live, so redraws must resume
without waiting for another PTY byte."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-to-line*"))
        (invalidate-calls 0))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered ">>> \n")
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--process 'fake-proc)
          (cl-letf (((symbol-function 'ghostel--mode-enabled)
                     (lambda (&rest _) nil))
                    (ghostel--cursor-char-pos 4)
                    ((symbol-function 'ghostel--invalidate)
                     (lambda (&rest _) (cl-incf invalidate-calls)))
                    ((symbol-function 'ghostel--redraw) #'ignore))
            ;; Enter copy mode — freezes the redraw timer.
            (ghostel-copy-mode)
            (should (eq ghostel--input-mode 'copy))
            (should (ghostel--terminal-frozen-p))
            (let ((before invalidate-calls))
              ;; Copy → line must call invalidate so the timer is live again.
              (ghostel-line-mode)
              (should (eq ghostel--input-mode 'line))
              (should (> invalidate-calls before)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-emacs-to-line-does-not-double-invalidate ()
  "Emacs → line transition does not need the extra invalidate call.
The redraw timer is already running in Emacs mode (the terminal
is unfrozen), so `ghostel--line-mode-enter' must skip the
copy-only `ghostel--invalidate' call to avoid pointless work on
the hot path."
  (let ((buf (generate-new-buffer " *ghostel-test-emacs-to-line*"))
        (invalidate-calls 0))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered ">>> \n")
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--process 'fake-proc)
          (cl-letf (((symbol-function 'ghostel--mode-enabled)
                     (lambda (&rest _) nil))
                    (ghostel--cursor-char-pos 4)
                    ((symbol-function 'ghostel--invalidate)
                     (lambda (&rest _) (cl-incf invalidate-calls)))
                    ((symbol-function 'ghostel--redraw) #'ignore))
            (ghostel-emacs-mode)
            (should (eq ghostel--input-mode 'emacs))
            ;; Reset counter: any invalidates from the emacs-mode entry
            ;; itself are not the subject of this test.
            (setq invalidate-calls 0)
            (ghostel-line-mode)
            (should (eq ghostel--input-mode 'line))
            ;; No invalidate call from the copy-only branch.
            (should (= 0 invalidate-calls))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-defers-entry-on-alt-screen ()
  "Calling `ghostel-line-mode' in alt-screen arms deferred activation.
The user's intent (\"I want line mode\") is preserved; the
auto-resume path in `ghostel--line-mode-post-redraw' picks up the
sentinel and enters line mode for real once the TUI exits."
  (let ((buf (generate-new-buffer " *ghostel-test-line-defer*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode) (= mode 1049))))
              ;; Buffer is in semi-char, alt-screen is on.
              (should (eq ghostel--input-mode 'semi-char))
              (ghostel-line-mode)
              ;; Mode is unchanged (the TUI keeps getting raw keys),
              ;; but the paused sentinel is armed so a later
              ;; alt-screen-off cycle re-enters line mode.
              (should (eq ghostel--input-mode 'semi-char))
              (should ghostel--line-mode-paused)
              (should (equal (plist-get ghostel--line-mode-paused :input)
                             "")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-pauses-on-alt-screen-on ()
  "1049 ON while in line-mode discards type-ahead and drops to semi-char.
`ghostel--line-mode-paused' is armed (an empty sentinel) so a later
alt-screen exit re-enters line mode, but the typed input is not
preserved."
  (let ((buf (generate-new-buffer " *ghostel-test-line-pause*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((alt-on nil)
                (ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode)
                         (and alt-on (memq mode '(1049 1047)) t)))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (should (eq ghostel--input-mode 'line))
              (insert "ls")
              (should (equal (ghostel--line-mode-input-text) "ls"))
              ;; Alt-screen turns on; pre-redraw fires the pause.
              (setq alt-on t)
              (ghostel--line-mode-pre-redraw)
              (should (eq ghostel--input-mode 'semi-char))
              ;; Paused sentinel is armed, but the type-ahead is discarded.
              (should ghostel--line-mode-paused)
              (should (equal (plist-get ghostel--line-mode-paused :input) ""))
              ;; The typed "ls" was deleted from the buffer, not preserved.
              (should-not (string-match-p "ls" (buffer-string)))
              ;; Input region was extracted from the buffer.
              (should-not (markerp ghostel--line-input-start))
              ;; Read-only props from line-mode entry are gone.
              (should-not (text-property-any (point-min) (point-max)
                                             'read-only t)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-resumes-on-alt-screen-off ()
  "1049 OFF with a prompt in the buffer re-enters line mode.
Drives the pause, then the resume; the buffer is back in line mode
at the new prompt.  Type-ahead from before the pause is not
restored."
  (let ((buf (generate-new-buffer " *ghostel-test-line-resume*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((alt-on nil)
                (ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode)
                         (and alt-on (memq mode '(1049 1047)) t)))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              ;; Enter line mode and type some input.
              (ghostel-line-mode)
              (insert "ls -la")
              ;; Alt-screen ON → pause via pre-redraw.
              (setq alt-on t)
              (ghostel--line-mode-pre-redraw)
              (should (eq ghostel--input-mode 'semi-char))
              (should ghostel--line-mode-paused)
              ;; Post-redraw with alt-screen still on does NOT resume.
              (ghostel--line-mode-post-redraw)
              (should (eq ghostel--input-mode 'semi-char))
              ;; Alt-screen OFF → next post-redraw resumes.
              (setq alt-on nil)
              (ghostel--line-mode-pre-redraw)  ; no-op (not in line mode)
              (ghostel--line-mode-post-redraw)
              (should (eq ghostel--input-mode 'line))
              (should-not ghostel--line-mode-paused)
              ;; Re-entered at the new prompt with empty input — the
              ;; pre-pause type-ahead is not carried across.
              (should (equal (ghostel--line-mode-input-text) "")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-resume-defers-without-prompt ()
  "Resume with no prompt in the buffer keeps the paused sentinel for next cycle."
  (let ((buf (generate-new-buffer " *ghostel-test-line-resume-defer*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((alt-on nil)
                (ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode)
                         (and alt-on (memq mode '(1049 1047)) t)))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "echo hi")
              (setq alt-on t)
              (ghostel--line-mode-pre-redraw)
              (ghostel--line-mode-post-redraw)
              ;; Drop the prompt before alt-screen-off — simulates
              ;; a redraw cycle where the new post-TUI prompt has
              ;; not been painted yet.
              (ghostel-test--with-rendered-output (erase-buffer))
              (setq alt-on nil)
              (ghostel--line-mode-post-redraw)
              ;; Still paused (sentinel intact), mode still semi-char.
              (should (eq ghostel--input-mode 'semi-char))
              (should ghostel--line-mode-paused)
              (should (equal (plist-get ghostel--line-mode-paused :input) ""))
              ;; Add the new prompt and run another post-redraw —
              ;; resume succeeds.
              (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
              (ghostel--line-mode-post-redraw)
              (should (eq ghostel--input-mode 'line))
              (should-not ghostel--line-mode-paused)
              (should (equal (ghostel--line-mode-input-text) "")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-paused-cleared-on-manual-switch ()
  "An explicit mode switch drops the paused sentinel — no force-resume later."
  (let ((buf (generate-new-buffer " *ghostel-test-line-clear-paused*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((alt-on t)
                (ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode)
                         (and alt-on (memq mode '(1049 1047)) t)))
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              ;; Defer entry while alt-screen is on — paused armed.
              (ghostel-line-mode)
              (should ghostel--line-mode-paused)
              ;; User explicitly switches modes — paused is dropped.
              (ghostel-char-mode)
              (should-not ghostel--line-mode-paused)
              (should (eq ghostel--input-mode 'char)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-send ()
  "Line-mode-send ships the input as one write then an encoded return.
The trailing key is encoded via `ghostel--send-encoded' so apps
that distinguish CR/LF (claude-code, pi) get a real submit, not
a literal newline."
  (let ((buf (generate-new-buffer " *ghostel-test-line-send*"))
        (events nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term s) (push (cons 'send s) events)))
                      ((symbol-function 'ghostel--send-encoded)
                       (lambda (key _mods &optional _utf8)
                         (push (cons 'encoded key) events)))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (should (eq ghostel--input-mode 'line))
              (should (markerp ghostel--line-input-start))
              ;; Type some input.
              (insert "ls -la")
              (ghostel-line-mode-send)
              ;; Input written first, then a separately-encoded Enter.
              (should (equal (reverse events)
                             '((send . "ls -la")
                               (encoded . "return"))))
              ;; Send stays in line mode; the next redraw / prompt
              ;; cycle will reposition the marker via
              ;; snapshot/restore.  The input region is empty after
              ;; send.
              (should (eq ghostel--input-mode 'line))
              (should (markerp ghostel--line-input-start))
              (should (equal (ghostel--line-mode-input-text) ""))
              ;; History retains the sent line.
              (should (member "ls -la" ghostel--line-mode-history)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-send-or-open-link-opens-link-at-point ()
  "RET on a link in line-mode opens the link instead of sending."
  (let ((buf (generate-new-buffer " *ghostel-test-line-link*"))
        (sent nil)
        (opened nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Scrollback line carrying a help-echo (linkified).
          (ghostel-test--insert-rendered (propertize "see ./README.md\n" 'help-echo "fileref:./README.md"))
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term s) (setq sent s)))
                      ((symbol-function 'ghostel--open-link)
                       (lambda (url) (setq opened url)))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              ;; Park point on the linkified text in the scrollback.
              (goto-char (point-min))
              (forward-char 4)
              (ghostel-line-mode-send-or-open-link)
              (should (equal opened "fileref:./README.md"))
              (should (null sent)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-newline-inserts-and-sends-multiline ()
  "Shift-Enter inserts \\n; the multi-line input ships verbatim on send.
For chat apps that distinguish submit from newline (claude-code,
pi), the trailing encoded `return' is the submit and any embedded
\\n stays in the input as a literal newline."
  (let ((buf (generate-new-buffer " *ghostel-test-line-newline*"))
        (events nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term s) (push (cons 'send s) events)))
                      ((symbol-function 'ghostel--send-encoded)
                       (lambda (key _mods &optional _utf8)
                         (push (cons 'encoded key) events)))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "first line")
              (ghostel-line-mode-newline)
              (insert "second line")
              (should (equal (ghostel--line-mode-input-text)
                             "first line\nsecond line"))
              (ghostel-line-mode-send)
              (should (equal (reverse events)
                             '((send . "first line\nsecond line")
                               (encoded . "return")))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-newline-snaps-from-scrollback ()
  "Shift-Enter from the read-only scrollback snaps point to input end first."
  (let ((buf (generate-new-buffer " *ghostel-test-line-newline-snap*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "scrollback line\n")
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--send-encoded) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "abc")
              ;; Park point in the scrollback line.
              (goto-char (point-min))
              (ghostel-line-mode-newline)
              ;; Input now contains "abc\n", scrollback untouched.
              (should (equal (ghostel--line-mode-input-text) "abc\n"))
              (should (= (point) (marker-position ghostel--line-input-end))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-send-or-open-link-sends-without-link ()
  "RET in the input region with no link at point sends the line."
  (let ((buf (generate-new-buffer " *ghostel-test-line-nolink*"))
        (sent nil)
        (encoded nil)
        (opened nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term s) (setq sent s)))
                      ((symbol-function 'ghostel--send-encoded)
                       (lambda (key _mods &optional _utf8)
                         (setq encoded key)))
                      ;; No hyperlink at point with a fake terminal handle.
                      ((symbol-function 'ghostel--uri-at-pos)
                       (lambda (_pos) nil))
                      ((symbol-function 'ghostel--open-link)
                       (lambda (url) (setq opened url)))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "echo hi")
              (ghostel-line-mode-send-or-open-link)
              (should (equal sent "echo hi"))
              (should (equal encoded "return"))
              (should (null opened)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-send-clears-adopted-prefix ()
  "RET in line mode erases the shell's adopted prefix before sending.
When the user typed input via the PTY in a previous mode and then
switched to line mode, the shell's readline still holds those
chars.  `ghostel-line-mode-send' must send one backspace per
adopted char first — otherwise the shell concatenates and echoes
a duplicated line."
  (let ((buf (generate-new-buffer " *ghostel-test-line-send-dedup*"))
        (events nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          ;; Adopted input as the renderer would have painted it for
          ;; chars typed via the PTY in a previous mode.
          (ghostel-test--insert-rendered (propertize "ls -la" 'ghostel-input t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term s) (push (cons 'send s) events)))
                      ((symbol-function 'ghostel--send-encoded)
                       (lambda (key _mods &optional _utf8)
                         (push (cons 'encoded key) events)))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              ;; Entry adopts the rendered prefix into the editable
              ;; buffer and remembers the shell still has it.
              (should (= ghostel--line-mode-adopted-count 6))
              (should (equal (ghostel--line-mode-input-text) "ls -la"))
              (ghostel-line-mode-send)
              ;; Six "backspace" key encodes happen first, in order,
              ;; then the line is sent in a single write, then an
              ;; encoded "return" submits.  Asserting the full event
              ;; sequence locks down the ordering — a future
              ;; regression that re-introduced the duplication would
              ;; either drop the backspaces or send the line before
              ;; them, and a regression to a literal "\\n" submitter
              ;; would replace the trailing encoded return.
              (should (equal (reverse events)
                             (append (make-list 6 '(encoded . "backspace"))
                                     '((send . "ls -la")
                                       (encoded . "return")))))
              ;; Counter is zero after send so the next prompt cycle
              ;; (with empty readline) doesn't trigger spurious
              ;; backspaces.
              (should (= ghostel--line-mode-adopted-count 0)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-history ()
  "Line mode \\`M-p' / \\`M-n' cycle through the history ring."
  (let ((buf (generate-new-buffer " *ghostel-test-line-history*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (setq ghostel--line-mode-history '("third" "second" "first"))
              (ghostel-line-mode-history-previous)
              (should (equal (ghostel--line-mode-input-text) "third"))
              (ghostel-line-mode-history-previous)
              (should (equal (ghostel--line-mode-input-text) "second"))
              (ghostel-line-mode-history-previous)
              (should (equal (ghostel--line-mode-input-text) "first"))
              (ghostel-line-mode-history-next)
              (should (equal (ghostel--line-mode-input-text) "second"))
              (ghostel-line-mode-history-next)
              (should (equal (ghostel--line-mode-input-text) "third"))
              (ghostel-line-mode-history-next)
              (should (equal (ghostel--line-mode-input-text) "")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-beginning-of-input-or-line-on-prompt-row ()
  "On the prompt row, `C-a' jumps to the start of input.
Both line mode (where the marker pinpoints the input) and Emacs
mode (where only the `ghostel-prompt' text property is available)
should land at the position right after the prompt prefix."
  (let ((buf (generate-new-buffer " *ghostel-test-c-a-prompt*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (ghostel-test--insert-rendered "ls -la")
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              ;; Line mode: end of buffer, then C-a → input-start.
              (ghostel-line-mode)
              (goto-char (point-max))
              (ghostel-beginning-of-input-or-line)
              (should (= (point)
                         (marker-position ghostel--line-input-start)))
              (ghostel-semi-char-mode))
            ;; Emacs mode: text-property scan finds same position.
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-emacs-mode)
              (goto-char (point-max))
              (ghostel-beginning-of-input-or-line)
              ;; "$ " is 2 chars (positions 1-2), input starts at 3.
              (should (= (point) 3)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-beginning-of-input-or-line-in-scrollback ()
  "On a non-prompt line, `C-a' falls through to `beginning-of-line'.
This covers both modes: navigating up into scrollback and pressing
`C-a' should give the standard column-0 behaviour, not snap point
back to the active prompt's input area."
  (let ((buf (generate-new-buffer " *ghostel-test-c-a-bol*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "scrollback line one\nscrollback line two\n")
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              ;; Line mode: navigate up to scrollback, C-a → BOL of
              ;; that line, NOT the active prompt's input marker.
              (ghostel-line-mode)
              (goto-char (point-min))
              (search-forward "line two")  ; cursor mid-line in scrollback
              (let ((expected-bol (line-beginning-position)))
                (ghostel-beginning-of-input-or-line)
                (should (= (point) expected-bol))
                (should-not
                 (= (point)
                    (marker-position ghostel--line-input-start))))
              (ghostel-semi-char-mode))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-emacs-mode)
              ;; Emacs mode: same on a scrollback line.
              (goto-char (point-min))
              (search-forward "line one")
              (let ((expected-bol (line-beginning-position)))
                (ghostel-beginning-of-input-or-line)
                (should (= (point) expected-bol))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-beginning-of-input-or-line-regex-python ()
  "Regex fallback finds the prompt prefix on a `>>> ' line.
With no OSC 133 prop, `C-a' should still jump past the prompt
prefix on a Python REPL line."
  (let ((buf (generate-new-buffer " *ghostel-test-c-a-regex-py*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; No prop — the line just looks like a Python REPL line.
          (ghostel-test--insert-rendered ">>> import os")
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-emacs-mode)
              (goto-char (point-max))
              (ghostel-beginning-of-input-or-line)
              ;; `>>> ' is 4 chars (positions 1-4), input starts at 5.
              (should (= (point) 5)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-beginning-of-input-or-line-regex-lambda ()
  "Regex fallback recognizes `λ ' as a prompt prefix."
  (let ((buf (generate-new-buffer " *ghostel-test-c-a-regex-lambda*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "λ ls")
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-emacs-mode)
              (goto-char (point-max))
              (ghostel-beginning-of-input-or-line)
              ;; `λ ' is 2 chars; input starts at position 3.
              (should (= (point) 3)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-beginning-of-input-or-line-regex-disabled ()
  "Setting `ghostel-prompt-regexp' to nil disables the regex fallback.
Without prop, marker, or regex, the command falls through to BOL."
  (let ((buf (generate-new-buffer " *ghostel-test-c-a-regex-off*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered ">>> import os")
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc)
                (ghostel-prompt-regexp nil))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-emacs-mode)
              (goto-char (point-max))
              (ghostel-beginning-of-input-or-line)
              ;; No detection → BOL → point at column 0.
              (should (= (current-column) 0)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-beginning-of-input-or-line-regex-ps2-continuation ()
  "`C-a' on an empty PS2 continuation row lands past the prefix.
The helper's `<=' check enables this — every fresh `RET' the user
types produces a row like `> ' with no trailing input, and pressing
`C-a' should put point where input would start, not at column 0."
  (let ((buf (generate-new-buffer " *ghostel-test-c-a-ps2*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Empty continuation row — bash/zsh PS2 default is `> '.
          ;; No `ghostel-prompt' prop, no trailing input.
          (ghostel-test--insert-rendered "> ")
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-emacs-mode)
              (goto-char (point-min))
              (ghostel-beginning-of-input-or-line)
              ;; `> ' is 2 chars; input would start at position 3.
              (should (= (point) 3)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-regex-prompt-end-empty-prompt-returns-match ()
  "Helper returns the regex match end even on an empty prompt line.
A fresh `$ ' with no input typed yet should still report
input-start at position 3 — pressing `C-a' on a blank prompt row
should land past the prefix, not at column 0.  (Bug: an earlier
draft used `<' here and rejected all-prompt lines, breaking `C-a'
on every empty prompt the user pressed `RET' to.)"
  (with-temp-buffer
    (insert "$ ")
    (should (= 3 (ghostel--regex-prompt-end 1)))))

(ert-deftest ghostel-test-regex-prompt-end-matches-content ()
  "Helper returns the match end when there's input past the prompt."
  (with-temp-buffer
    (insert "$ ls")
    ;; `$ ' is 2 chars, `ls' starts at position 3.
    (should (= 3 (ghostel--regex-prompt-end 1)))))

(ert-deftest ghostel-test-regex-prompt-end-nil-regex-returns-nil ()
  "When `ghostel-prompt-regexp' is nil the helper returns nil."
  (with-temp-buffer
    (insert "$ ls")
    (let ((ghostel-prompt-regexp nil))
      (should (null (ghostel--regex-prompt-end 1))))))

(ert-deftest ghostel-test-line-mode-interrupt ()
  "Line-mode interrupt discards input, sends SIGINT, and exits."
  (let ((buf (generate-new-buffer " *ghostel-test-line-interrupt*"))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term s) (setq sent s)))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "half-typed")
              (ghostel-line-mode-interrupt)
              (should (equal sent "\C-c"))
              ;; Interrupt stays in line mode; the next redraw /
              ;; prompt cycle picks up the shell's new prompt and
              ;; snapshot/restore repositions the marker.  The input
              ;; region is empty after interrupt.
              (should (eq ghostel--input-mode 'line))
              (should (markerp ghostel--line-input-start))
              (should (equal (ghostel--line-mode-input-text) "")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-exit-sends-pending ()
  "Exiting line mode via a mode-switch sends the in-progress input raw.
The user's in-progress characters should not be lost when the
mode changes — they get forwarded to the shell's readline so the
user can continue editing at the shell prompt."
  (let ((buf (generate-new-buffer " *ghostel-test-line-exit*"))
        (sent-log nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term s) (push s sent-log)))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-line-mode)
              (insert "ls -la")
              ;; Exit via a mode switch.  The teardown should ship the
              ;; partially-typed input to the PTY raw (no newline).
              (ghostel-semi-char-mode)
              (should (eq ghostel--input-mode 'semi-char))
              (should (member "ls -la" sent-log)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-eof-on-empty ()
  "Line mode \\`C-d' at an empty input sends EOF; otherwise deletes forward."
  (let ((buf (generate-new-buffer " *ghostel-test-line-eof*"))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty)
                       (lambda (_term s) (setq sent s)))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              ;; Empty input → EOF.
              (ghostel-line-mode-delete-char-or-eof)
              (should (equal sent "\C-d")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-teardown-on-exit ()
  "Exiting line mode cleans up the marker and deletes in-progress input."
  (let ((buf (generate-new-buffer " *ghostel-test-line-teardown*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-line-mode)
              (insert "abandoned")
              (ghostel-semi-char-mode)
              (should (eq ghostel--input-mode 'semi-char))
              (should (null ghostel--line-input-start))
              ;; The abandoned input is gone from the buffer.
              (should-not (string-match-p "abandoned"
                                          (buffer-string)))
              ;; The read-only property is cleared too.
              (should-not (text-property-any (point-min) (point-max)
                                             'read-only t)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-scrollback-read-only ()
  "Line mode makes everything before the input marker read-only.
Typing in the middle of the scrollback / previous-output region
signals `text-read-only', while typing after the marker works
normally."
  (let ((buf (generate-new-buffer " *ghostel-test-line-ro*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Buffer: some previous output, then a prompt.
          (ghostel-test--insert-rendered "earlier output\n")
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-line-mode)
              ;; The scrollback region carries the read-only property.
              (should (get-text-property (point-min) 'read-only))
              ;; Attempting to edit in the MIDDLE of the scrollback
              ;; region errors.  (Emacs allows insertion right at
              ;; point-min because the new text goes "before" the
              ;; read-only region, not inside it — that is a known
              ;; property-read-only quirk and we do not fight it.)
              (goto-char 5)
              (should-error (insert "x") :type 'text-read-only)
              ;; Typing at the marker (inside the input region) works.
              (goto-char (marker-position ghostel--line-input-start))
              (insert "ls")
              (should (equal (ghostel--line-mode-input-text) "ls"))
              ;; Exit: the read-only property goes away.
              (ghostel-semi-char-mode)
              (should-not (text-property-any (point-min) (point-max)
                                             'read-only t)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-self-insert-snaps-from-scrollback ()
  "Typing while point sits in the scrollback snaps to the input end."
  (let ((buf (generate-new-buffer " *ghostel-test-line-snap-insert*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "earlier output\n")
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              ;; Type some input first so the input region has content.
              (goto-char (marker-position ghostel--line-input-start))
              (insert "ls")
              (let ((input-end (marker-position ghostel--line-input-end)))
                ;; Navigate up into the read-only scrollback.
                (goto-char (point-min))
                (should (< (point) (marker-position ghostel--line-input-start)))
                ;; Self-insert via the snap wrapper.
                (let ((last-command-event ?x))
                  (ghostel-line-mode-self-insert 1))
                ;; Point landed just past where input-end used to be,
                ;; the `x' was appended to the input region.
                (should (equal (ghostel--line-mode-input-text) "lsx"))
                (should (= (point) (1+ input-end)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-self-insert-no-jump-when-inside ()
  "When point is already inside the input region, self-insert stays put."
  (let ((buf (generate-new-buffer " *ghostel-test-line-no-snap*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (goto-char (marker-position ghostel--line-input-start))
              (insert "hello")
              ;; Move point to the middle of the input ("hel|lo").
              (let ((mid (- (point) 2)))
                (goto-char mid)
                (let ((last-command-event ?X))
                  (ghostel-line-mode-self-insert 1))
                ;; Inserted at the cursor, no jump to end.
                (should (equal (ghostel--line-mode-input-text) "helXlo"))
                (should (= (point) (1+ mid)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-self-insert-prefix-arg ()
  "Numeric prefix repeats the self-insert."
  (let ((buf (generate-new-buffer " *ghostel-test-line-prefix*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "earlier output\n")
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (goto-char (point-min))
              (let ((last-command-event ?a))
                (ghostel-line-mode-self-insert 5))
              (should (equal (ghostel--line-mode-input-text) "aaaaa")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-tab-binding ()
  "Both \\`TAB' and \\`<tab>' in line-mode-map call the completion command."
  (should (eq #'ghostel-line-mode-complete-at-point
              (lookup-key ghostel-line-mode-map (kbd "TAB"))))
  (should (eq #'ghostel-line-mode-complete-at-point
              (lookup-key ghostel-line-mode-map (kbd "<tab>")))))

(ert-deftest ghostel-test-line-mode-complete-narrows-to-input ()
  "Completion sees only the input region, not prompt or scrollback."
  (let ((buf (generate-new-buffer " *ghostel-test-line-complete-narrow*"))
        recorded)
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "earlier output\n")
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc)
                (ghostel-line-mode-completion-at-point-functions
                 (list (lambda ()
                         (setq recorded
                               (list :pmin (point-min)
                                     :pmax (point-max)
                                     :content
                                     (buffer-substring-no-properties
                                      (point-min) (point-max))))
                         nil)))
                ;; Skip bash-completion in this test regardless of host config.
                (ghostel-line-mode-use-bash-completion nil))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (goto-char (marker-position ghostel--line-input-end))
              (insert "ls fo")
              (ghostel-line-mode-complete-at-point)
              (should recorded)
              (should (equal (plist-get recorded :content) "ls fo"))
              (should (= (plist-get recorded :pmin)
                         (marker-position ghostel--line-input-start)))
              (should (= (plist-get recorded :pmax)
                         (marker-position ghostel--line-input-end))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-complete-filename ()
  "Filename completion expands a unique prefix in the buffer's `default-directory'.
Restricts the capf list to `comint-filename-completion' so the test
isn't perturbed by whatever \\=`ap*\\=' commands happen to live in
\\=`$PATH\\=' on the host (`shell-command-completion' fires for the
first word and would add e.g. \\=`apropos\\=', making the result
ambiguous)."
  (let* ((tmpdir (file-name-as-directory (make-temp-file "ghostel-cmp" 'dir)))
         (buf (generate-new-buffer " *ghostel-test-line-complete-fname*")))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "apple.txt" tmpdir))
          (with-temp-file (expand-file-name "banana.txt" tmpdir))
          (with-current-buffer buf
            (setq default-directory tmpdir)
            (ghostel-mode)
            (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
            (let ((ghostel--term 'fake)
                  (ghostel--process 'fake-proc)
                  (ghostel-line-mode-use-bash-completion nil)
                  (ghostel-line-mode-completion-at-point-functions
                   '(comint-filename-completion)))
              (cl-letf (((symbol-function 'ghostel--mode-enabled)
                         (lambda (&rest _) nil))
                        ((symbol-function 'ghostel--redraw) #'ignore)
                        ((symbol-function 'ghostel--invalidate) #'ignore))
                (ghostel-line-mode)
                (goto-char (marker-position ghostel--line-input-end))
                (insert "ap")
                (ghostel-line-mode-complete-at-point)
                ;; Unique prefix `ap' resolves to `apple.txt'.  Comint's
                ;; filename completion may add a trailing space — just
                ;; check the expansion happened.
                (should (string-match-p "\\`apple\\.txt"
                                        (ghostel--line-mode-input-text)))))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory tmpdir 'recursive))))

(ert-deftest ghostel-test-line-mode-complete-empty-input ()
  "TAB on empty input does not error."
  (let ((buf (generate-new-buffer " *ghostel-test-line-complete-empty*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc)
                (ghostel-line-mode-use-bash-completion nil)
                (ghostel-line-mode-completion-at-point-functions
                 ;; A capf that would crash if called on a non-string —
                 ;; ensures empty-input path doesn't blow up.
                 (list (lambda () nil))))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              ;; Should complete without raising.
              (ghostel-line-mode-complete-at-point))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-complete-snaps-from-scrollback ()
  "TAB pressed in scrollback snaps point to the input end before completing."
  (let ((buf (generate-new-buffer " *ghostel-test-line-complete-snap*"))
        snapped-point)
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "earlier output\n")
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc)
                (ghostel-line-mode-use-bash-completion nil)
                (ghostel-line-mode-completion-at-point-functions
                 (list (lambda ()
                         (setq snapped-point (point))
                         nil))))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (goto-char (marker-position ghostel--line-input-end))
              (insert "ls")
              (let ((input-end (marker-position ghostel--line-input-end)))
                (goto-char (point-min))
                (ghostel-line-mode-complete-at-point)
                (should (= snapped-point input-end))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-complete-refreshes-tramp-prefix ()
  "Each TAB updates `comint-file-name-prefix' from `default-directory'."
  (let ((buf (generate-new-buffer " *ghostel-test-line-complete-tramp*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc)
                (ghostel-line-mode-use-bash-completion nil)
                (ghostel-line-mode-completion-at-point-functions
                 (list (lambda () nil))))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (let ((default-directory "/ssh:host:/tmp/"))
                (goto-char (marker-position ghostel--line-input-end))
                (ghostel-line-mode-complete-at-point)
                (should (equal comint-file-name-prefix "/ssh:host:"))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-bash-completion-disabled-by-default-in-test ()
  "`ghostel--line-mode-effective-capfs' omits bash-completion when option is nil."
  (let ((ghostel-line-mode-use-bash-completion nil)
        (ghostel-line-mode-completion-at-point-functions
         '(comint-completion-at-point)))
    (should-not (memq 'bash-completion-capf-nonexclusive
                      (ghostel--line-mode-effective-capfs)))))

(ert-deftest ghostel-test-line-mode-bash-completion-prepended-when-available ()
  "`ghostel--line-mode-effective-capfs' prepends bash-completion when enabled."
  (skip-unless (require 'bash-completion nil 'noerror))
  (let ((ghostel-line-mode-use-bash-completion t)
        (ghostel-line-mode-completion-at-point-functions
         '(comint-completion-at-point)))
    (let ((funs (ghostel--line-mode-effective-capfs)))
      (should (eq (car funs) #'bash-completion-capf-nonexclusive))
      (should (memq #'comint-completion-at-point funs)))))

(ert-deftest ghostel-test-line-mode-bash-completion-no-double-add ()
  "Bash-completion is not added twice when the user has it in the defcustom."
  (skip-unless (require 'bash-completion nil 'noerror))
  (let ((ghostel-line-mode-use-bash-completion t)
        (ghostel-line-mode-completion-at-point-functions
         '(bash-completion-capf-nonexclusive comint-completion-at-point)))
    (let ((funs (ghostel--line-mode-effective-capfs)))
      (should (= 1 (cl-count #'bash-completion-capf-nonexclusive funs))))))

(ert-deftest ghostel-test-line-mode-bash-completion-prespawn-defaults-off ()
  "The prespawn defcustom is off by default."
  (should (eq nil (default-value
                   'ghostel-line-mode-bash-completion-prespawn))))

(ert-deftest ghostel-test-line-mode-snapshot-captures-input ()
  "`ghostel--line-mode-snapshot' returns a plist and clears the input region."
  (let ((buf (generate-new-buffer " *ghostel-test-line-snap*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "hello")
              (let* ((marker-pos (marker-position
                                  ghostel--line-input-start))
                     (snap (ghostel--line-mode-snapshot)))
                (should (equal (plist-get snap :input) "hello"))
                (should (equal (plist-get snap :point-offset) 5))
                (should-not (plist-get snap :mark-offset))
                ;; Input region was cleared from the buffer.
                (should (= (point-max) marker-pos))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-snapshot-no-marker-returns-nil ()
  "`ghostel--line-mode-snapshot' returns nil when no input marker is live."
  (with-temp-buffer
    (let ((ghostel--line-input-start nil))
      (should-not (ghostel--line-mode-snapshot)))))

(ert-deftest ghostel-test-line-mode-snapshot-captures-mark-offset ()
  "`ghostel--line-mode-snapshot' records mark offset when an active region overlaps the input."
  (let ((buf (generate-new-buffer " *ghostel-test-line-snap-mark*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "abcdef")
              ;; Place mark at +2, point at +5.
              (let ((marker-pos (marker-position
                                 ghostel--line-input-start)))
                (set-mark (+ marker-pos 2))
                (goto-char (+ marker-pos 5)))
              (let ((snap (ghostel--line-mode-snapshot)))
                (should (equal (plist-get snap :input) "abcdef"))
                (should (equal (plist-get snap :point-offset) 5))
                (should (equal (plist-get snap :mark-offset) 2))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-restore-reinserts-input ()
  "`ghostel--line-mode-restore' re-inserts SNAPSHOT after the new prompt."
  (let ((buf (generate-new-buffer " *ghostel-test-line-restore*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "command")
              (let ((snap (ghostel--line-mode-snapshot)))
                ;; Simulate a redraw rewriting the buffer: the renderer
                ;; would re-emit the prompt at a (potentially new)
                ;; position.  Erase and rebuild with a longer
                ;; preamble.
                (ghostel-test--with-rendered-output
                  (erase-buffer)
                  (insert "background line\n")
                  (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t)))
                (should (ghostel--line-mode-restore snap))
                ;; Input is back, marker points at the new prompt-end.
                (should (equal (ghostel--line-mode-input-text) "command"))
                ;; Point is at the original :point-offset (end of
                ;; "command" = 7) past the new marker.
                (should (= (- (point) (marker-position
                                       ghostel--line-input-start))
                           7))
                ;; Read-only re-applied to the new scrollback region.
                (should (get-text-property (point-min) 'read-only))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-restore-no-prompt-returns-nil ()
  "`ghostel--line-mode-restore' returns nil when the prompt cannot be found."
  (with-temp-buffer
    ;; No `ghostel-prompt' property anywhere → restore reports failure.
    (insert "no prompt here")
    (let ((snap '(:input "x" :point-offset 1 :mark-offset nil)))
      (should-not (ghostel--line-mode-restore snap)))))

(ert-deftest ghostel-test-line-mode-restore-marks-ghostel-input ()
  "`ghostel--line-mode-restore' marks the input region with `ghostel-input'.
This makes `ghostel--detect-urls-skip-p' skip the user's typed
input on the cursor's line so a path the user typed locally does
not get linkified (which would steal RET from line-mode-send)."
  (let ((buf (generate-new-buffer " *ghostel-test-line-input-prop*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (insert "cd src/main.rs")
              (let ((snap (ghostel--line-mode-snapshot)))
                ;; Simulate redraw rewriting buffer with same prompt.
                (ghostel-test--with-rendered-output
                  (erase-buffer)
                  (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t)))
                (should (ghostel--line-mode-restore snap))
                ;; Every char in the input region carries `ghostel-input'.
                (let ((start (marker-position
                              ghostel--line-input-start)))
                  (should (< start (point-max)))
                  (should (eq (get-text-property start 'ghostel-input) t))
                  (should (eq (get-text-property (1- (point-max))
                                                 'ghostel-input)
                              t)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-end-marker-bounds-snapshot ()
  "Snapshot reads `[start, end)' — content past the end marker is preserved.
Simulates a status bar drawn below the prompt row.  The renderer
would normally write past the prompt, then a redraw cycle of
snapshot/restore must leave the status-bar text untouched."
  (let ((buf (generate-new-buffer " *ghostel-test-line-end-marker*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (ghostel-test--insert-rendered "\n--- status ---\n")
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              ;; Both markers exist.
              (should (markerp ghostel--line-input-start))
              (should (markerp ghostel--line-input-end))
              ;; The status bar is non-blank, so the trailing trim
              ;; left it alone — buffer still contains it.
              (should (string-match-p "--- status ---" (buffer-string)))
              ;; Markers coincide (no input typed yet).
              (should (= (marker-position ghostel--line-input-start)
                         (marker-position ghostel--line-input-end)))
              ;; Type some input — end marker advances, start stays.
              (insert "ls -la")
              (should (= (- (marker-position ghostel--line-input-end)
                            (marker-position ghostel--line-input-start))
                         6))
              ;; Snapshot reads only [start, end), leaving the status
              ;; bar untouched.
              (let ((snap (ghostel--line-mode-snapshot)))
                (should (equal (plist-get snap :input) "ls -la"))
                (should (string-match-p "--- status ---"
                                        (buffer-string)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-adopts-existing-input-on-entry ()
  "Line mode entry adopts a pre-existing `ghostel-input' span as initial input.
This covers the workflow where the user typed at the shell in
semi-char mode, then switched to line mode partway through — the
already-typed chars in libghostty's INPUT cells (marked
`ghostel-input' by the renderer) become the line-mode input
instead of being discarded."
  (let ((buf (generate-new-buffer " *ghostel-test-line-adopt*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          ;; Pre-existing typed chars marked with `ghostel-input'.
          (ghostel-test--insert-rendered (propertize "cd src" 'ghostel-input t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              ;; Adopted chars become the initial line-mode input.
              (should (equal (ghostel--line-mode-input-text) "cd src"))
              ;; Point sits at end of input so user keeps typing.
              (should (= (point)
                         (marker-position ghostel--line-input-end)))
              ;; The adopted span carries `ghostel-input'.
              (let ((start (marker-position ghostel--line-input-start)))
                (should (eq (get-text-property start 'ghostel-input) t))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-preserves-status-below-prompt ()
  "Line-mode entry does not delete non-blank content past the prompt row.
A status bar (or any non-whitespace content) drawn below the prompt
row by the shell or another app survives entering line mode and
running through a redraw cycle."
  (let ((buf (generate-new-buffer " *ghostel-test-line-status*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (ghostel-test--insert-rendered "\n[status: ok]\n")
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (should (string-match-p "\\[status: ok\\]" (buffer-string)))
              (insert "ls")
              (should (equal (ghostel--line-mode-input-text) "ls"))
              (should (string-match-p "\\[status: ok\\]"
                                      (buffer-string))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-saves-restores-full-redraw ()
  "Entering line mode forces full redraws; teardown restores the prior setting."
  (let ((buf (generate-new-buffer " *ghostel-test-line-fullredraw*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc)
                (ghostel-full-redraw nil))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              ;; Was nil, no buffer-local override.
              (should-not (local-variable-p 'ghostel-full-redraw))
              (ghostel-line-mode)
              ;; Entry sets buffer-local override to t.
              (should (local-variable-p 'ghostel-full-redraw))
              (should (eq ghostel-full-redraw t))
              ;; Saved-state cons records "was not buffer-local".
              (should (equal ghostel--line-mode-saved-full-redraw
                             '(nil . nil)))
              (ghostel-semi-char-mode)
              ;; Teardown killed the buffer-local override.
              (should-not (local-variable-p 'ghostel-full-redraw))
              (should-not ghostel--line-mode-saved-full-redraw))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-restores-cursor-when-terminal-hid-it ()
  "Line mode shows the editor's cursor regardless of CSI ?25l from the TUI.
Entering line mode forces the editor default; teardown restores the saved value."
  (let ((buf (generate-new-buffer " *ghostel-test-line-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              ;; Simulate a TUI that hid the cursor in semi-char mode.
              (setq-local ghostel--cursor-style nil)
              (ghostel--apply-cursor-style)
              (should (null cursor-type))
              ;; Enter line mode — cursor must be visible (default).
              (ghostel-line-mode)
              (should (eq ghostel--input-mode 'line))
              (should (equal cursor-type (default-value 'cursor-type)))
              (should (equal ghostel--line-mode-saved-cursor-type '(nil)))
              ;; Exit line mode — cursor returns to terminal-hidden state.
              (ghostel-semi-char-mode)
              (should (null cursor-type))
              (should-not ghostel--line-mode-saved-cursor-type))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-enters-on-alt-screen-with-osc133-prompt ()
  "On the alt screen, a real OSC 133 prompt on the cursor row enters line mode.
A shell prompt inside tmux/screen whose OSC 133 passed through
carries `ghostel-prompt' on the cursor row, so line mode should
enter at that prompt instead of arming."
  (let ((buf (generate-new-buffer " *ghostel-test-line-alt-enter*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (setq ghostel--cursor-char-pos (point))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode) (= mode 1049)))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (should (eq ghostel--input-mode 'semi-char))
              (ghostel-line-mode)
              ;; Entered for real — not armed.
              (should (eq ghostel--input-mode 'line))
              (should-not ghostel--line-mode-paused)
              ;; Flagged as a deliberate alt-screen entry.
              (should ghostel--line-mode-on-alt-screen))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-arms-on-alt-screen-without-osc133 ()
  "On the alt screen with no OSC 133 prompt, line mode arms (raw-TUI guard).
A raw fullscreen TUI (vim/less) paints glyphs but carries no
`ghostel-prompt' on the cursor row, so line mode must NOT enter —
it would scrape garbage.  It arms a deferred sentinel instead."
  (let ((buf (generate-new-buffer " *ghostel-test-line-alt-arm*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; vim-like row: plain text, no prompt prop.
          (ghostel-test--with-rendered-output
            (insert "~ NORMAL line one"))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (setq ghostel--cursor-char-pos (point))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode) (= mode 1049)))
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (should (eq ghostel--input-mode 'semi-char))
              (ghostel-line-mode)
              ;; Stayed in semi-char, armed an empty snapshot.
              (should (eq ghostel--input-mode 'semi-char))
              (should ghostel--line-mode-paused)
              (should (equal (plist-get ghostel--line-mode-paused :input)
                             "")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-force-enters-on-alt-screen ()
  "A prefix arg forces line-mode entry on the alt screen even without OSC 133.
The multiplexer-without-passthrough user's escape hatch: with a
cursor to anchor on, a prefix arg bypasses the gate and enters."
  (let ((buf (generate-new-buffer " *ghostel-test-line-alt-force*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; No prompt prop — only a cursor anchors the boundary.
          (ghostel-test--with-rendered-output
            (insert "bash-5.2$ "))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc)
                (ghostel-prompt-regexp nil))  ; force the bare-cursor path
            (setq ghostel--cursor-char-pos (point))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode) (= mode 1049)))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              ;; Sanity: without the prefix this would arm, not enter.
              (should-not (ghostel--line-mode-prompt-on-screen-p))
              (let ((current-prefix-arg '(4)))
                (call-interactively #'ghostel-line-mode))
              (should (eq ghostel--input-mode 'line))
              (should-not ghostel--line-mode-paused)
              (should ghostel--line-mode-on-alt-screen))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-force-errors-without-anchor ()
  "Forced entry with nothing to anchor still errors — never silently no-ops.
With no cursor and no prompt prop, `ghostel--line-mode-enter'
returns nil; the forced branch must surface the `user-error'
rather than leave the mode unchanged."
  (let ((buf (generate-new-buffer " *ghostel-test-line-force-noanchor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--with-rendered-output
            (insert "no prompt here"))
          (let ((ghostel--term 'fake)
                (ghostel--cursor-char-pos nil))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode) (= mode 1049))))
              (let ((current-prefix-arg '(4)))
                (should-error (call-interactively #'ghostel-line-mode)
                              :type 'user-error)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-alt-screen-entry-not-paused-by-redraw ()
  "A deliberate alt-screen line-mode survives the next pre-redraw.
Regression for the pause-on-redraw self-defeat: without the
`ghostel--line-mode-on-alt-screen' flag, `pre-redraw' would pause
the freshly-entered line mode on the very next redraw because
alt-screen is still on, making the whole entry a no-op."
  (let ((buf (generate-new-buffer " *ghostel-test-line-alt-survive*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (setq ghostel--cursor-char-pos (point))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode) (= mode 1049)))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-line-mode)
              (should (eq ghostel--input-mode 'line))
              ;; Next redraw with alt-screen still on must NOT pause us.
              (ghostel--line-mode-pre-redraw)
              (should (eq ghostel--input-mode 'line))
              (should-not ghostel--line-mode-paused))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-normal-pause-still-fires ()
  "Auto-pause still fires for line mode entered on the PRIMARY screen.
Guards against the `on-alt-screen' flag accidentally suppressing
the normal vim-launched-from-a-shell-prompt pause: entry on the
primary screen leaves the flag nil, so a later alt-screen
transition pauses as before (type-ahead discarded)."
  (let ((buf (generate-new-buffer " *ghostel-test-line-normal-pause*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((alt-on nil)
                (ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode)
                         (and alt-on (memq mode '(1049 1047)) t)))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              ;; Enter on the primary screen — flag stays nil.
              (ghostel-line-mode)
              (should (eq ghostel--input-mode 'line))
              (should-not ghostel--line-mode-on-alt-screen)
              (insert "ls")
              ;; Now a TUI starts; pre-redraw must pause as before.
              (setq alt-on t)
              (ghostel--line-mode-pre-redraw)
              (should (eq ghostel--input-mode 'semi-char))
              (should ghostel--line-mode-paused)
              (should (equal (plist-get ghostel--line-mode-paused :input) "")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-prompt-on-screen-p-ignores-regex ()
  "`ghostel--line-mode-prompt-on-screen-p' only counts the OSC 133 prop.
The regex must NOT be treated as a prompt signal on the alt screen:
a TUI row that happens to look like `$ ' is not a real prompt.  The
predicate returns nil for a regex-only match and non-nil only when
the `ghostel-prompt' prop is present."
  (let ((buf (generate-new-buffer " *ghostel-test-prompt-on-screen*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Row matches `ghostel-prompt-regexp' (`$ ') but has no prop.
          (ghostel-test--with-rendered-output
            (insert "$ ls -la"))
          (setq ghostel--term 'fake)
          (setq ghostel--cursor-char-pos (point))
          (should (ghostel--regex-prompt-end ghostel--cursor-char-pos))
          (should-not (ghostel--line-mode-prompt-on-screen-p))
          ;; Now add a real prop on the cursor row → non-nil.
          (ghostel-test--with-rendered-output
            (erase-buffer)
            (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
            (ghostel-test--insert-rendered "ls -la"))
          (setq ghostel--cursor-char-pos (point))
          (should (ghostel--line-mode-prompt-on-screen-p)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-force-after-arm-preserves-input-on-alt-exit ()
  "Arming then force-entering must not double-enter when the TUI later exits.
Regression for the stale armed-snapshot bug: a first plain
`ghostel-line-mode' without OSC 133 passthrough arms a sentinel;
the advertised forced call (with a prefix argument) then enters.
A real entry
must clear that sentinel, otherwise the alt-screen-off `post-redraw'
would call
`ghostel--line-mode-try-resume' on top of the already-active line
mode — re-running `ghostel--line-mode-enter', wiping the user's
typed input (it restores the empty armed snapshot) and clobbering
the saved `ghostel-full-redraw' state captured on first entry."
  (let ((buf (generate-new-buffer " *ghostel-test-line-force-after-arm*"))
        (alt-on t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (setq ghostel--cursor-char-pos (point))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode) (and alt-on (= mode 1049))))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--send-encoded) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              ;; First press, no passthrough → arm a sentinel.
              (ghostel--line-mode-defer-entry)
              (should ghostel--line-mode-paused)
              ;; The advertised escape hatch: C-u C-c C-l → force entry.
              (ghostel-line-mode t)
              (should (eq ghostel--input-mode 'line))
              ;; The fix: the real entry cleared the stale sentinel.
              (should-not ghostel--line-mode-paused)
              ;; Capture the saved redraw state so we can detect a
              ;; second entry re-capturing it from modified values.
              (should-not (car ghostel--line-mode-saved-full-redraw))
              ;; User types a command in line mode.
              (goto-char (point-max))
              (insert "ls -la")
              ;; User exits the multiplexer: alt screen turns off, a
              ;; redraw runs pre- then post-redraw.
              (setq alt-on nil)
              (ghostel--line-mode-pre-redraw)
              (ghostel--line-mode-post-redraw)
              ;; Still in line mode, input intact, no double-enter.
              (should (eq ghostel--input-mode 'line))
              (should (equal (ghostel--line-mode-input-text) "ls -la"))
              (should-not ghostel--line-mode-paused)
              (should-not (car ghostel--line-mode-saved-full-redraw)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-line-mode-alt-exit-clears-flag-so-primary-tui-pauses ()
  "Leaving the alt screen drops the deliberate-entry flag.
Regression for the stale `ghostel--line-mode-on-alt-screen' flag:
after entering line mode at an inner tmux prompt and then exiting
the multiplexer (alt screen off) while staying in line mode, a TUI
later launched at the now-primary prompt must auto-pause as usual —
the flag must not keep suppressing the pause forever."
  (let ((buf (generate-new-buffer " *ghostel-test-line-alt-exit-flag*"))
        (alt-on t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
          (let ((ghostel--term 'fake)
                (ghostel--process 'fake-proc))
            (setq ghostel--cursor-char-pos (point))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term mode)
                         (and alt-on (memq mode '(1049 1047)) t)))
                      ((symbol-function 'process-live-p) (lambda (_p) t))
                      ((symbol-function 'ghostel--write-pty) #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              ;; Enter at an inner shell prompt inside tmux (branch c).
              (ghostel-line-mode)
              (should (eq ghostel--input-mode 'line))
              (should ghostel--line-mode-on-alt-screen)
              ;; Exit the multiplexer: alt off, still in line mode.  The
              ;; next redraw's pre-redraw must clear the flag.
              (setq alt-on nil)
              (ghostel--line-mode-pre-redraw)
              (should (eq ghostel--input-mode 'line))
              (should-not ghostel--line-mode-on-alt-screen)
              ;; Now a real TUI starts at the primary prompt: pre-redraw
              ;; must pause, exactly as for a normal primary-screen entry.
              (setq alt-on t)
              (ghostel--line-mode-pre-redraw)
              (should (eq ghostel--input-mode 'semi-char))
              (should ghostel--line-mode-paused))))
      (kill-buffer buf))))

;;; Initial input mode (ghostel-initial-input-mode)

(ert-deftest ghostel-test-initial-input-mode-line-arms-deferred-entry ()
  "`ghostel--apply-initial-input-mode' arms deferred entry for `line'.
The buffer stays in semi-char until a prompt renders."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf _term 5 80 1000)
    (with-current-buffer buf
      (let ((ghostel-initial-input-mode 'line))
        (ghostel--apply-initial-input-mode))
      (should ghostel--pending-initial-line-mode)
      (should (eq ghostel--input-mode 'semi-char)))))

(ert-deftest ghostel-test-initial-input-mode-char-applies-immediately ()
  "`ghostel-initial-input-mode' = `char' enters char mode at startup."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf _term 5 80 1000)
    (set-window-buffer (selected-window) buf)
    (with-current-buffer buf
      (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
        (let ((ghostel-initial-input-mode 'char))
          (ghostel--apply-initial-input-mode)))
      (should (eq ghostel--input-mode 'char))
      (should-not ghostel--pending-initial-line-mode))))

(ert-deftest ghostel-test-initial-line-mode-defers-until-prompt ()
  "`ghostel-initial-input-mode' = `line' waits for the first prompt, then enters.
The deferred entry stays armed across redraws with no detectable
prompt and engages on the redraw that exposes one."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
    (setq ghostel-detect-password-prompts nil)
    (set-window-buffer (selected-window) buf)
    (setq ghostel--process 'fake-proc)
    ;; Arm exactly as `ghostel--apply-initial-input-mode' would.
    (setq ghostel--pending-initial-line-mode t)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'ghostel--write-pty) #'ignore)
              ((symbol-function 'ghostel--invalidate) #'ignore))
      ;; Output with no prompt yet — must not enter line mode.
      (ghostel--write-vt term "starting up...\r\n")
      (ghostel--redraw-now buf)
      (should ghostel--pending-initial-line-mode)
      (should (eq ghostel--input-mode 'semi-char))
      ;; First prompt arrives — the next redraw enters line mode.
      (ghostel--write-vt term "\e]133;A\e\\$ \e]133;B\e\\")
      (ghostel--redraw-now buf)
      (should (eq ghostel--input-mode 'line))
      (should-not ghostel--pending-initial-line-mode)
      (should (markerp ghostel--line-input-start)))))

(ert-deftest ghostel-test-initial-line-mode-respects-manual-override ()
  "A manual mode switch before the first prompt cancels deferred line entry."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
    (setq ghostel-detect-password-prompts nil)
    (set-window-buffer (selected-window) buf)
    (setq ghostel--process 'fake-proc)
    (setq ghostel--pending-initial-line-mode t)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
              ((symbol-function 'ghostel--write-pty) #'ignore)
              ((symbol-function 'ghostel--invalidate) #'ignore))
      ;; User switches to char mode before any prompt.
      (ghostel-char-mode)
      (should (eq ghostel--input-mode 'char))
      ;; Prompt arrives; deferred entry must not override the user's choice.
      (ghostel--write-vt term "\e]133;A\e\\$ \e]133;B\e\\")
      (ghostel--redraw-now buf)
      (should (eq ghostel--input-mode 'char))
      (should-not ghostel--pending-initial-line-mode))))

(ert-deftest ghostel-test-anchor-window-line-mode-keeps-point ()
  "`ghostel--anchor-window' anchors the line-mode viewport but keeps point.
In line mode the input region between `ghostel--line-input-start' and
`ghostel--line-input-end' is user-owned, so an anchor (minibuffer grow, window
resize, redisplay) must scroll the viewport to the bottom WITHOUT snapping point
to the terminal cursor.  The semi-char control sub-case proves the
snap-to-`ghostel--cursor-char-pos' behaviour is preserved for the other modes."
  (let ((buf (generate-new-buffer " *ghostel-test-anchor-line*"))
        (previous-buffer (window-buffer (selected-window))))
    (unwind-protect
        ;; No native module: stub the alt-screen DEC-mode query so line-mode
        ;; entry takes the primary-screen path.
        (cl-letf (((symbol-function 'ghostel--mode-enabled)
                   (lambda (&rest _) nil)))
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (setq ghostel--term 'fake)
            ;; Scrollback above the prompt so a bottom-anchor is observable.
            (let ((rows (max 1 (window-body-height))))
              (ghostel-test--with-rendered-output
                (dotimes (i (+ rows 20))
                  (insert (format "row-%02d\n" i)))))
            ;; A prompt carrying `ghostel-prompt' on the cursor's row, with the
            ;; terminal cursor (= the input boundary) right after it.
            (ghostel-test--insert-rendered (propertize "$ " 'ghostel-prompt t))
            (setq ghostel--cursor-char-pos (point))
            (setq ghostel--cursor-pos (cons (current-column) 0))
            ;; Enter line mode: markers now wrap the (empty) input region.
            (ghostel-line-mode)
            (should (eq ghostel--input-mode 'line))
            (should (markerp ghostel--line-input-start))
            ;; Type input locally; the end marker grows to include it.
            (goto-char (marker-position ghostel--line-input-end))
            (insert "echo hello world")
            (should (equal (ghostel--line-mode-input-text) "echo hello world"))
            (let* ((win (selected-window))
                   (start (marker-position ghostel--line-input-start))
                   ;; Point mid-input: distinct from `ghostel--cursor-char-pos'
                   ;; (= input start) and from `point-max' (= input end).
                   (mid (+ start 5)))
              (should (= ghostel--cursor-char-pos start))
              (should (< start mid))
              (should (< mid (point-max)))
              ;; Park point mid-input and scroll the window off the bottom.
              (goto-char mid)
              (set-window-point win mid)
              (set-window-start win (point-min) t)
              ;; Line mode anchors the viewport but leaves point put.
              (ghostel--anchor-window win)
              (should (= (window-point win) mid))
              (should (> (window-start win) (point-min)))
              ;; Control: semi-char mode still snaps point to the live cursor.
              (setq ghostel--input-mode 'semi-char)
              (set-window-start win (point-min) t)
              (ghostel--anchor-window win)
              (should (= (window-point win) ghostel--cursor-char-pos))
              (should (> (window-start win) (point-min))))))
      (set-window-buffer (selected-window) previous-buffer)
      (kill-buffer buf))))

(provide 'ghostel-line-mode-test)
;;; ghostel-line-mode-test.el ends here
