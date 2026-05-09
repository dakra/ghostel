;;; evil-ghostel-test.el --- Tests for evil-ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L ~/.emacs.d/lib/evil -L . \
;;     -l ert -l test/evil-ghostel-test.el -f evil-ghostel-test-run

;;; Code:

(require 'ert)
(require 'evil)
(require 'ghostel)
(require 'evil-ghostel)

;; -----------------------------------------------------------------------
;; Helper: set up a ghostel buffer with evil
;; -----------------------------------------------------------------------

(defmacro evil-ghostel-test--with-buffer (rows cols text &rest body)
  "Create a ghostel buffer with ROWS x COLS, feed TEXT, render, then run BODY.
The buffer has evil-mode and evil-ghostel-mode active.
The variable `term' is bound to the terminal handle.
Requires the native module."
  (declare (indent 3) (debug t))
  `(let ((term (ghostel--new ,rows ,cols 100)))
     (ghostel--write-input term ,text)
     (with-temp-buffer
       (ghostel-mode)
       (setq-local ghostel--term term)
       ;; Production wires `ghostel--term-rows' via `ghostel--resize';
       ;; tests that drive the module directly must set it themselves so
       ;; viewport-aware helpers (e.g. `evil-ghostel--reset-cursor-point')
       ;; can translate viewport rows into buffer lines.
       (setq-local ghostel--term-rows ,rows)
       (evil-local-mode 1)
       (evil-ghostel-mode 1)
       (let ((inhibit-read-only t))
         (ghostel--redraw term t))
       ,@body)))

(defmacro evil-ghostel-test--with-evil-buffer (&rest body)
  "Set up a ghostel buffer with evil-mode active (no native module).
Uses mocks for native functions."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (ghostel-mode)
     ;; Mock tests don't go through `ghostel--resize', so
     ;; `ghostel--term-rows' stays nil by default.  Pick a value large
     ;; enough that the viewport covers whatever text a mock test
     ;; `insert's — the scrollback-offset computation then collapses to
     ;; zero and matches pre-scrollback-fix behaviour.
     (setq-local ghostel--term-rows 100)
     (evil-local-mode 1)
     (evil-ghostel-mode 1)
     ,@body))

;; -----------------------------------------------------------------------
;; Test: mode activation
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-mode-activation ()
  "Test that `evil-ghostel-mode' activates correctly."
  (evil-ghostel-test--with-evil-buffer
   (should evil-ghostel-mode)
   (should (memq 'evil-ghostel--insert-state-entry
                 evil-insert-state-entry-hook))
   (should (advice--p (advice--symbol-function 'evil-insert-line)))
   (should (advice--p (advice--symbol-function 'ghostel--redraw)))
   (should (advice--p (advice--symbol-function 'ghostel--set-cursor-style)))))

(ert-deftest evil-ghostel-test-mode-activation-no-normal-entry-hook ()
  "`evil-ghostel-mode' does not install a `normal-state-entry-hook'.
Point is synced on entry to `emacs'/`insert' and preserved through
redraws in `normal'; re-syncing on every normal-state entry would
overwrite the position evil assigns at operator/visual completion."
  (evil-ghostel-test--with-evil-buffer
   (should-not (memq 'evil-ghostel--normal-state-entry
                     evil-normal-state-entry-hook))))

(ert-deftest evil-ghostel-test-mode-deactivation ()
  "Test that `evil-ghostel-mode' cleans up on deactivation."
  (evil-ghostel-test--with-evil-buffer
   (evil-ghostel-mode -1)
   (should-not evil-ghostel-mode)
   (should-not (memq 'evil-ghostel--insert-state-entry
                     evil-insert-state-entry-hook))))

;; -----------------------------------------------------------------------
;; Test: initial-state defcustom
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-initial-state-load-applied ()
  "Current value of `evil-ghostel-initial-state' is registered with evil at load."
  (should (eq (evil-initial-state 'ghostel-mode)
              evil-ghostel-initial-state)))

(ert-deftest evil-ghostel-test-initial-state-custom-set-updates-registry ()
  "Setting the option via `customize-set-variable' updates evil's registry."
  (let ((orig evil-ghostel-initial-state))
    (unwind-protect
        (progn
          (customize-set-variable 'evil-ghostel-initial-state 'emacs)
          (should (eq (evil-initial-state 'ghostel-mode) 'emacs))
          (customize-set-variable 'evil-ghostel-initial-state 'normal)
          (should (eq (evil-initial-state 'ghostel-mode) 'normal)))
      (customize-set-variable 'evil-ghostel-initial-state orig))))

(ert-deftest evil-ghostel-test-mode-activation-preserves-initial-state ()
  "Enabling `evil-ghostel-mode' must not clobber the initial-state setting.
Regression guard: the minor-mode body used to call
`evil-set-initial-state' on every activation, overriding user config."
  (let ((orig evil-ghostel-initial-state))
    (unwind-protect
        (progn
          (customize-set-variable 'evil-ghostel-initial-state 'emacs)
          (evil-ghostel-test--with-evil-buffer
           (should (eq (evil-initial-state 'ghostel-mode) 'emacs))))
      (customize-set-variable 'evil-ghostel-initial-state orig))))

;; -----------------------------------------------------------------------
;; Test: escape-stay (evil-move-cursor-back disabled)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-escape-stay ()
  "Test that `evil-move-cursor-back' is disabled in ghostel buffers."
  (evil-ghostel-test--with-evil-buffer
   (should-not evil-move-cursor-back)))

;; -----------------------------------------------------------------------
;; Test: around-redraw preserves point / mark / visual markers
;; -----------------------------------------------------------------------

(defmacro evil-ghostel-test--simulating-redraw (&rest body)
  "Run BODY with `ghostel--redraw' replaced by a buffer-rewriter.
The mock erases the buffer and reinserts the same text, which is what
the native full-redraw path does at the Emacs level — every marker in
the buffer snaps to `point-min' across the call."
  `(cl-letf (((symbol-function 'ghostel--redraw)
              (lambda (_term &optional _full)
                (let ((text (buffer-string)))
                  (erase-buffer)
                  (insert text))))
             ((symbol-function 'ghostel--mode-enabled)
              (lambda (_term _mode) nil)))
     ,@body))

(ert-deftest evil-ghostel-test-around-redraw-preserves-point-in-normal ()
  "Point is restored in non-terminal states after the native redraw call."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\nthree\nfour\nfive\n")
   (evil-normal-state)
   (goto-char (point-min))
   (search-forward "three")
   (let ((target (point)))
     (evil-ghostel-test--simulating-redraw
      (evil-ghostel--around-redraw (symbol-function 'ghostel--redraw) nil))
     (should (= target (point))))))

(ert-deftest evil-ghostel-test-around-redraw-lets-point-follow-in-emacs ()
  "Point is NOT preserved in `emacs'/`insert' — it follows the TUI cursor."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\nthree\nfour\nfive\n")
   (evil-emacs-state)
   (goto-char (point-min))
   (search-forward "three")
   (evil-ghostel-test--simulating-redraw
    ;; Mock redraw places point at point-min (like eraseBuffer does).
    (evil-ghostel--around-redraw
     (lambda (_term &optional _full)
       (let ((text (buffer-string)))
         (erase-buffer)
         (insert text)
         (goto-char (point-min))))
     nil))
   (should (= (point-min) (point)))))

(ert-deftest evil-ghostel-test-around-redraw-preserves-visual-markers ()
  "`evil-visual-beginning'/`evil-visual-end' are restored in visual state."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\nthree\nfour\nfive\n")
   (goto-char (point-min))
   (search-forward "two")
   (let ((vb-target (point)))
     (search-forward "four")
     (let ((ve-target (point)))
       (setq-local evil-visual-beginning (copy-marker vb-target))
       (setq-local evil-visual-end (copy-marker ve-target t))
       (let ((evil-state 'visual))
         (evil-ghostel-test--simulating-redraw
          (evil-ghostel--around-redraw
           (symbol-function 'ghostel--redraw) nil)))
       (should (= vb-target (marker-position evil-visual-beginning)))
       (should (= ve-target (marker-position evil-visual-end)))))))

(ert-deftest evil-ghostel-test-around-redraw-bypassed-in-alt-screen ()
  "Advice is a passthrough when the terminal is in alt-screen mode (1049).
Fullscreen TUIs own the screen and drive their own redraw cycle; the
advice must not restore point or visual markers there."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\nthree\nfour\nfive\n")
   (evil-normal-state)
   (goto-char (point-min))
   (search-forward "three")
   (cl-letf (((symbol-function 'ghostel--redraw)
              (lambda (_term &optional _full)
                (let ((text (buffer-string)))
                  (erase-buffer)
                  (insert text)
                  (goto-char (point-min)))))
             ((symbol-function 'ghostel--mode-enabled)
              (lambda (_term mode) (= mode 1049))))
     (evil-ghostel--around-redraw (symbol-function 'ghostel--redraw) nil))
   ;; Advice bypassed → the mock's point placement (point-min) wins.
   (should (= (point-min) (point)))))

(ert-deftest evil-ghostel-test-around-redraw-snaps-point-on-prompt-line ()
  "Point follows the new cursor line in normal state when on the prompt.
Output that grows scrollback must not strand point above the new
prompt — the renderer's cursor placement should win."
  (evil-ghostel-test--with-buffer 5 40 "$ "
                                  (evil-normal-state)
                                  ;; After the initial redraw, point sits on the cursor line.
                                  (should (evil-ghostel--point-on-cursor-line-p))
                                  ;; Stream output that overflows the 5-row viewport, growing
                                  ;; scrollback.  Without the on-prompt-line heuristic the
                                  ;; advice would restore the stale buffer position from before
                                  ;; the scroll.
                                  (ghostel--write-input term "\r\n")
                                  (dotimes (i 8)
                                    (ghostel--write-input term (format "out-%d\r\n" i)))
                                  (ghostel--write-input term "$ ")
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term nil))
                                  ;; Point lands on the new cursor line, not above it.
                                  (should (evil-ghostel--point-on-cursor-line-p))))

(ert-deftest evil-ghostel-test-around-redraw-preserves-point-off-prompt ()
  "Point is preserved in normal state when parked off the prompt line.
Scrollback navigation must not be disturbed by output redraws."
  (evil-ghostel-test--with-buffer 5 40 "alpha\r\nbeta\r\ngamma\r\n$ "
                                  (evil-normal-state)
                                  ;; Park point on a non-cursor line above the prompt.
                                  (goto-char (point-min))
                                  (search-forward "beta")
                                  (beginning-of-line)
                                  (should-not (evil-ghostel--point-on-cursor-line-p))
                                  ;; Drive a redraw that doesn't grow scrollback (still fits).
                                  (ghostel--write-input term "x")
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term nil))
                                  ;; Point still on the same content line, not snapped to cursor.
                                  (should (string-match-p
                                           "beta"
                                           (buffer-substring-no-properties
                                            (line-beginning-position)
                                            (line-end-position))))
                                  (should-not (evil-ghostel--point-on-cursor-line-p))))

;; -----------------------------------------------------------------------
;; Test: reset-cursor-point
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-reset-cursor-point ()
  "Test that `evil-ghostel--reset-cursor-point' moves point to terminal cursor."
  (evil-ghostel-test--with-buffer 5 40 "hello world"
                                  ;; Terminal cursor is at col 11, row 0
                                  (should (equal '(11 . 0) ghostel--cursor-pos))
                                  ;; Move point somewhere else
                                  (goto-char (point-min))
                                  (should (= 0 (current-column)))
                                  ;; Reset should snap back to terminal cursor
                                  (evil-ghostel--reset-cursor-point)
                                  (should (= 11 (current-column)))
                                  (should (= 1 (line-number-at-pos)))))

(ert-deftest evil-ghostel-test-reset-cursor-point-multiline ()
  "Test cursor reset with text on multiple lines."
  (evil-ghostel-test--with-buffer 5 40 "line1\nline2-text"
                                  ;; Cursor should be on row 1 (second line)
                                  (let ((pos ghostel--cursor-pos))
                                    (should (= 1 (cdr pos))))
                                  (goto-char (point-min))
                                  (evil-ghostel--reset-cursor-point)
                                  (should (= 2 (line-number-at-pos)))))

(ert-deftest evil-ghostel-test-reset-cursor-point-with-scrollback ()
  "Regression: reset-cursor-point must anchor to the viewport, not point-min.
`ghostel--cursor-pos' holds the row within the viewport (the
last `ghostel--term-rows' lines of the buffer).  With scrollback
present, interpreting the row as an offset from `point-min' lands
point in the scrollback region instead of the visible viewport."
  (let ((term (ghostel--new 5 40 1000)))
    ;; Overflow a 5-row viewport with 12 lines so 7 scroll off.  The
    ;; final row ("last-11") is in the viewport; earlier rows live in
    ;; scrollback above.
    (dotimes (i 12)
      (ghostel--write-input term (format "row-%02d\r\n" i)))
    (ghostel--write-input term "last-11")
    (with-temp-buffer
      (ghostel-mode)
      (setq-local ghostel--term term)
      (setq-local ghostel--term-rows 5)
      (evil-local-mode 1)
      (evil-ghostel-mode 1)
      (let ((inhibit-read-only t))
        (ghostel--redraw term t))
      ;; Walk point back into the scrollback region.
      (goto-char (point-min))
      (should (string-match-p "row-00" (buffer-substring-no-properties
                                         (line-beginning-position)
                                         (line-end-position))))
      ;; Reset must snap point into the viewport, not to scrollback row N.
      (evil-ghostel--reset-cursor-point)
      ;; The landing line is the one that contains the terminal cursor —
      ;; "last-11" (the last written row before the trailing cursor).
      (let ((line-text (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position))))
        (should (string-match-p "last-11" line-text)))
      ;; And the landing column matches the terminal cursor column.
      (should (= (car ghostel--cursor-pos)
                 (current-column))))))

;; -----------------------------------------------------------------------
;; Test: cursor-to-point (arrow key sending)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-cursor-to-point ()
  "Test that `evil-ghostel--cursor-to-point' sends correct arrow keys."
  (evil-ghostel-test--with-buffer 5 40 "$ echo hello world"
                                  ;; Terminal cursor at col 18, row 0
                                  (should (equal '(18 . 0) ghostel--cursor-pos))
                                  ;; Move point to col 7 (start of "hello")
                                  (goto-char (point-min))
                                  (move-to-column 7)
                                  ;; Track what keys are sent
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel--cursor-to-point))
                                    ;; Should send 11 LEFT arrows (18 - 7 = 11)
                                    (should (= 11 (length keys-sent)))
                                    (should (cl-every (lambda (k) (equal k "left")) keys-sent)))))

(ert-deftest evil-ghostel-test-cursor-to-point-right ()
  "Test arrow key sending when point is to the right of terminal cursor."
  (evil-ghostel-test--with-buffer 5 40 "hello"
                                  ;; Terminal cursor at col 5
                                  ;; Move cursor left in terminal, then redraw so ghostel--cursor-pos
                                  ;; reflects the new position (col 2).
                                  (ghostel--write-input term "\e[3D") ; cursor left 3 → col 2
                                  (let ((inhibit-read-only t)) (ghostel--redraw term t))
                                  (goto-char (point-min))
                                  (move-to-column 4) ; point at col 4
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel--cursor-to-point))
                                    ;; Should send 2 RIGHT arrows (4 - 2 = 2)
                                    (should (= 2 (length keys-sent)))
                                    (should (cl-every (lambda (k) (equal k "right")) keys-sent)))))

(ert-deftest evil-ghostel-test-cursor-to-point-no-op ()
  "Test that no arrows are sent when point matches terminal cursor."
  (evil-ghostel-test--with-buffer 5 40 "hello"
                                  ;; Point is already at terminal cursor after redraw
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel--cursor-to-point))
                                    (should (= 0 (length keys-sent))))))

(ert-deftest evil-ghostel-test-cursor-to-point-with-scrollback ()
  "Regression: cursor-to-point must subtract scrollback from buffer line.
`ghostel--cursor-pos' holds viewport-relative rows, so a
buffer line N must be converted to viewport row N-scrollback before
diffing — otherwise dy is wrong by exactly the scrollback line count
and the helper sends arrows that move the cursor off the input."
  (let ((term (ghostel--new 5 40 1000)))
    ;; Push 7 rows into scrollback so the viewport shows rows 8..12 plus
    ;; the trailing cursor row.
    (dotimes (i 12)
      (ghostel--write-input term (format "row-%02d\r\n" i)))
    (ghostel--write-input term "tail")
    (with-temp-buffer
      (ghostel-mode)
      (setq-local ghostel--term term)
      (setq-local ghostel--term-rows 5)
      (evil-local-mode 1)
      (evil-ghostel-mode 1)
      (let ((inhibit-read-only t))
        (ghostel--redraw term t))
      ;; Terminal cursor is on the last viewport row; move point to the
      ;; first viewport row (one row above the cursor).
      (let* ((tpos ghostel--cursor-pos)
             (trow (cdr tpos))
             (target-viewport-row (1- trow))
             (scrollback (max 0 (- (count-lines (point-min) (point-max))
                                   ghostel--term-rows))))
        (goto-char (point-min))
        (forward-line (+ scrollback target-viewport-row))
        (move-to-column (car tpos))
        (let ((keys-sent '()))
          (cl-letf (((symbol-function 'ghostel--send-encoded)
                     (lambda (key _mods &rest _)
                       (push key keys-sent))))
            (evil-ghostel--cursor-to-point))
          ;; Exactly one UP, no horizontal motion (cols match).
          (should (= 1 (length keys-sent)))
          (should (equal "up" (car keys-sent))))))))

;; -----------------------------------------------------------------------
;; Test: redraw preserves point in normal state
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-redraw-preserves-point-normal ()
  "Test that redraws preserve point in evil normal state.
Specifically when point is parked off the cursor's buffer line —
on-cursor-line normal state intentionally follows the cursor across
redraws so the prompt isn't left behind by output."
  (evil-ghostel-test--with-buffer 5 40 "first\r\nsecond\r\nthird"
                                  (evil-normal-state)
                                  ;; Park point on the first row, off the cursor line.
                                  (goto-char (point-min))
                                  (move-to-column 3)
                                  (should (= 3 (current-column)))
                                  (should (= 1 (line-number-at-pos)))
                                  ;; Redraw — should NOT move point back to terminal cursor
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 3 (current-column)))
                                  (should (= 1 (line-number-at-pos)))))

(ert-deftest evil-ghostel-test-redraw-moves-point-insert ()
  "Test that redraws move point to terminal cursor in insert state."
  (evil-ghostel-test--with-buffer 5 40 "hello world"
                                  (evil-insert-state)
                                  ;; Move point away from terminal cursor
                                  (goto-char (point-min))
                                  ;; Redraw — should snap point to terminal cursor (col 11)
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 11 (current-column)))))

(ert-deftest evil-ghostel-test-redraw-moves-point-emacs-state ()
  "Test that redraws follow terminal cursor in evil emacs-state.
Emacs-state is evil's vanilla-Emacs escape hatch; point should track
the terminal cursor there just like in insert-state.  Otherwise the
cursor freezes wherever it was on state entry while TUIs keep
redrawing elsewhere."
  (evil-ghostel-test--with-buffer 5 40 "hello world"
                                  (evil-emacs-state)
                                  ;; Move point away from terminal cursor
                                  (goto-char (point-min))
                                  ;; Redraw — should snap point to terminal cursor (col 11)
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 11 (current-column)))))

;; -----------------------------------------------------------------------
;; Test: advice fires on evil-insert / evil-append
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-advice-on-insert ()
  "Test that `evil-ghostel--before-insert' fires on `evil-insert'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0)))
     (evil-normal-state)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'evil-ghostel--cursor-to-point)
                  (lambda () (setq sync-called t))))
         (evil-insert 1))
       (should sync-called)))))

(ert-deftest evil-ghostel-test-advice-on-append ()
  "Test that `evil-ghostel--before-append' fires on `evil-append'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(5 . 0)))
     (evil-normal-state)
     (goto-char (point-min))
     (move-to-column 2)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'evil-ghostel--cursor-to-point)
                  (lambda () (setq sync-called t))))
         (evil-append 1))
       (should sync-called)))))

(ert-deftest evil-ghostel-test-advice-insert-line-sends-home ()
  "Test that `evil-insert-line' sends C-a and inhibits hook sync."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0)))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (push key keys-sent))))
         (evil-insert-line 1))
       (should (member "a" keys-sent))
       ;; Hook should NOT have sent additional arrow keys
       (should-not (member "left" keys-sent))
       (should-not (member "right" keys-sent))))))

(ert-deftest evil-ghostel-test-advice-append-line-sends-end ()
  "Test that `evil-append-line' sends C-e and inhibits hook sync."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0)))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (push key keys-sent))))
         (evil-append-line 1))
       (should (member "e" keys-sent))
       ;; Hook should NOT have sent additional arrow keys
       (should-not (member "left" keys-sent))
       (should-not (member "right" keys-sent))))))

(ert-deftest evil-ghostel-test-insert-line-multiline-syncs-row ()
  "Regression: `I' on a different row must sync the terminal cursor first.
Without the row sync, the Ctrl-a sent by the advice operates on the
last input line (where the terminal cursor was parked), not on the
line the user navigated to with `kk'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "line one\nline two\nline three")
   ;; Terminal cursor at end of line three (row 2); point on row 0.
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(10 . 2)))
     (evil-normal-state)
     (goto-char (point-min))
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-insert-line 1))
       ;; Two `up' arrows precede the Ctrl-a so the shell's readline
       ;; cursor lands on the right input row before going to bol.
       (should (= 2 (cl-count '("up" . "") keys-sent :test #'equal)))
       (should (cl-find '("a" . "ctrl") keys-sent :test #'equal))))))

(ert-deftest evil-ghostel-test-append-line-multiline-syncs-row ()
  "Regression: `A' on a different row must sync the terminal cursor first.
Symmetric to the `I' multi-row case — without the row sync the Ctrl-e
goes to the end of the last input line."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "line one\nline two\nline three")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(10 . 2)))
     (evil-normal-state)
     (goto-char (point-min))
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-append-line 1))
       (should (= 2 (cl-count '("up" . "") keys-sent :test #'equal)))
       (should (cl-find '("e" . "ctrl") keys-sent :test #'equal))))))

(ert-deftest evil-ghostel-test-change-eol-syncs-cursor-to-point ()
  "Regression: `C' at eol of a non-cursor row must sync before insert.
With point at end of line one and the terminal cursor at end of line
three, `C' produces an empty range (count = 0).  Without an explicit
sync after `delete-region', insert state would inherit the terminal
cursor from line three and the user's typed characters would land on
the last input line — what was reported as `C deletes the last line'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "line one\nline two\nline three")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(10 . 2)))
     (evil-normal-state)
     ;; Point at end of line one (just before the first newline).
     (goto-char (point-min))
     (end-of-line)
     (let ((keys-sent '())
           (eol-pos (point)))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         ;; `C' at eol → evil-change with empty range.
         (evil-change eol-pos eol-pos 'inclusive nil nil
                      #'evil-delete-line))
       ;; The post-delete cursor-to-point must emit two `up' arrows so
       ;; the terminal cursor lands on point's row before insert state.
       (should (= 2 (cl-count '("up" . "") keys-sent :test #'equal)))))))

;; -----------------------------------------------------------------------
;; Test: advice is no-op outside ghostel buffers
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-advice-no-op-outside-ghostel ()
  "Test that advice does nothing when `evil-ghostel-mode' is nil."
  (with-temp-buffer
    (evil-local-mode 1)
    (evil-normal-state)
    (let ((sync-called nil))
      (cl-letf (((symbol-function 'evil-ghostel--cursor-to-point)
                 (lambda () (setq sync-called t))))
        (evil-insert 1))
      (should-not sync-called))))

;; -----------------------------------------------------------------------
;; Test: cursor style override
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-cursor-style-override ()
  "Test that `ghostel--set-cursor-style' defers to evil."
  (evil-ghostel-test--with-buffer 5 40 "hello"
                                  (evil-normal-state)
                                  (let ((evil-called nil)
                                        (orig-called nil))
                                    (cl-letf (((symbol-function 'evil-refresh-cursor)
                                               (lambda (&rest _) (setq evil-called t))))
                                      (ghostel--set-cursor-style 0 t)
                                      (should evil-called)))))

;; -----------------------------------------------------------------------
;; Test: delete-region primitive
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-region ()
  "Test that `evil-ghostel--delete-region' sends correct keys."
  (evil-ghostel-test--with-buffer 5 40 "$ echo hello"
                                  ;; Delete "hello" (col 7-12)
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel--delete-region 8 13))
                                    ;; Should send arrow keys to move cursor, then 5 backspaces
                                    (should (= 5 (cl-count "backspace" keys-sent :test #'equal))))))

;; -----------------------------------------------------------------------
;; Test: meaningful-length helper (render padding stripping)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-meaningful-length-strips-trailing ()
  "Trailing whitespace counts only when TEXT spans multiple lines.
Single-line `\"word \"' is real user content (e.g. `dw' over a word
plus its trailing space); multi-line ranges may contain TUI box
padding that should be stripped per line."
  (should (= 0 (evil-ghostel--meaningful-length "")))
  (should (= 3 (evil-ghostel--meaningful-length "AAA")))
  ;; Single-line: trailing whitespace is preserved (real content).
  (should (= 9 (evil-ghostel--meaningful-length "AAA      ")))
  (should (= 5 (evil-ghostel--meaningful-length "word ")))
  ;; Multi-line: per-line trailing whitespace stripped (TUI padding).
  (should (= 7 (evil-ghostel--meaningful-length "AAA      \nBBB     ")))
  (should (= 4 (evil-ghostel--meaningful-length "AAA      \n")))
  ;; Inner whitespace preserved either way.
  (should (= 7 (evil-ghostel--meaningful-length "A B C  ")))
  (should (= 8 (evil-ghostel--meaningful-length "A B C  D"))))

;; -----------------------------------------------------------------------
;; Test: evil-delete advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-sends-backspace-keys ()
  "Test that `evil-delete' advice sends backspace keys via PTY."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         ;; Delete 5 chars (simulates dw on "hello")
         (evil-delete 1 6 'inclusive nil nil))
       (should (= 5 bs-count))))))

(ert-deftest evil-ghostel-test-delete-line-same-row-uses-ctrl-u ()
  "Test that `dd' on the cursor's own line uses the Ctrl-e/Ctrl-u shortcut.
Single-line shell case: the buffer line includes the prompt prefix,
so backspacing through the buffer text would hit the prompt boundary
and silently no-op.  Readline's Ctrl-u clears just the input area.
See issue #218 for the multi-line counterpart."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "$ hello")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Terminal cursor on the same row as point.
             (ghostel--cursor-pos '(7 . 0)))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-delete (line-beginning-position) (line-end-position) 'line nil nil))
       (should (cl-find '("e" . "ctrl") keys-sent :test #'equal))
       (should (cl-find '("u" . "ctrl") keys-sent :test #'equal))
       (should-not (cl-find '("backspace" . "") keys-sent :test #'equal))
       ;; Flag set so the next redraw snaps point to the cursor's new
       ;; position (start of input area) instead of leaving point on the
       ;; prompt at column 0.
       (should evil-ghostel--sync-point-on-next-redraw)))))

(ert-deftest evil-ghostel-test-change-line-same-row-uses-ctrl-u ()
  "Test that `cc' on the cursor's own line uses Ctrl-e/Ctrl-u then enters insert.
Same single-line shell rationale as `dd' — see
`evil-ghostel-test-delete-line-same-row-uses-ctrl-u'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "$ hello")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(7 . 0)))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-change (line-beginning-position) (line-end-position)
                      'line nil nil nil))
       (should (cl-find '("e" . "ctrl") keys-sent :test #'equal))
       (should (cl-find '("u" . "ctrl") keys-sent :test #'equal))
       (should-not (cl-find '("backspace" . "") keys-sent :test #'equal))
       (should (eq evil-state 'insert))))))

(ert-deftest evil-ghostel-test-delete-line-multiline-syncs-cursor ()
  "Regression for #218: line-type delete must sync terminal cursor first.
With a multi-line input where the terminal cursor sits on the last line,
pressing dd on the first line must move the terminal cursor up to that
line before deleting — otherwise Ctrl+U / shortcut-style deletion would
target the line the cursor sat on (the last input line)."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "line one\nline two\nline three")
   ;; Terminal cursor reported at end of line three (col 10, row 2)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(10 . 2)))
     (evil-normal-state)
     (goto-char (point-min))
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         ;; Line 1 spans positions 1..10 ("line one" + newline = 9 chars)
         (evil-delete 1 10 'line nil nil))
       ;; Sync from row 2 to row 1 (end of deleted region = bol of line 2)
       (should (= 1 (cl-count '("up" . "") keys-sent :test #'equal)))
       ;; Sync from col 10 to col 0
       (should (= 10 (cl-count '("left" . "") keys-sent :test #'equal)))
       ;; "line one\n" = 9 chars deleted via backspace
       (should (= 9 (cl-count '("backspace" . "") keys-sent :test #'equal)))
       (should-not (cl-find '("u" . "ctrl") keys-sent :test #'equal))))))

(ert-deftest evil-ghostel-test-delete-line-strips-render-padding ()
  "Regression for #218: multi-line `dd' must not backspace TUI box-padding.
TUIs that draw a fixed-width input box (e.g. prompt_toolkit) write
spaces past the user's input out to the box border; those land in
the Emacs buffer but are not characters in the TUI's input model.
Backspace count must equal trimmed line length + newline.
Forces the multi-line backspace path by placing the terminal cursor
on a different row than point."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; "AAA" + 77 box-padding spaces + newline + "BBB" + 77 box-padding spaces.
   (insert (concat "AAA" (make-string 77 ?\s) "\n"
                   "BBB" (make-string 77 ?\s)))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Terminal cursor on row 1 (BBB); point will be on row 0 (AAA).
             (ghostel--cursor-pos '(0 . 1))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (goto-char (point-min))
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         ;; Line 1 spans bol..bol-of-line-2 (81 chars including newline).
         (evil-delete (point-min) (line-beginning-position 2) 'line nil nil))
       ;; Trimmed: "AAA\n" = 4 backspaces, not 81.
       (should (= 4 bs-count))))))

(ert-deftest evil-ghostel-test-delete-char ()
  "Test that `evil-delete-char' (x) works without error.
Regression: yank-handler arg was not optional in advice signature,
so calls from `evil-delete-char' (which passes only 4 args to
`evil-delete') raised `wrong-number-of-arguments'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore)
             ((symbol-function 'ghostel--send-encoded) #'ignore))
     (evil-normal-state)
     ;; evil-delete-char calls evil-delete without yank-handler
     (evil-delete-char 1 2 'exclusive nil)
     (should (eq evil-state 'normal)))))

;; -----------------------------------------------------------------------
;; Test: evil-change advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-change-deletes-and-inserts ()
  "Test that `evil-change' advice deletes via PTY and enters insert state."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         (evil-change 1 6 'inclusive nil nil nil))
       (should (= 5 bs-count))
       (should (eq evil-state 'insert))))))

(ert-deftest evil-ghostel-test-change-whole-line ()
  "Test that `evil-change-whole-line' (cc/S) works without error.
Regression: delete-func arg was not optional in advice signature."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'ghostel--send-encoded) #'ignore))
     (evil-normal-state)
     ;; evil-change-whole-line calls evil-change without delete-func
     (evil-change-whole-line 1 12 nil nil)
     (should (eq evil-state 'insert)))))

;; -----------------------------------------------------------------------
;; Test: evil-replace advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-replace-deletes-and-inserts ()
  "Test that `evil-replace' deletes then inserts replacement text."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0)
           (pasted nil))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count))))
                 ((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text))))
         (evil-replace 1 4 'inclusive ?X))
       (should (= 3 bs-count))
       (should (equal "XXX" pasted))))))

(ert-deftest evil-ghostel-test-replace-counts-match-on-trailing-space ()
  "Regression: paste count and delete count must agree.
Both `evil-ghostel--delete-region' and the paste in
`evil-ghostel--around-replace' use `evil-ghostel--meaningful-length'
on the same substring, so the values must agree even when trailing
whitespace handling differs (multi-line ranges strip; single-line
ranges don't)."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; Multi-line range with TUI-style padding on the first row.
   ;; meaningful-length strips per-line padding → 4 chars: "AB\nC".
   (insert "AB   \nC")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0)
           (pasted nil))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count))))
                 ((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text))))
         (evil-replace 1 8 'inclusive ?X))
       ;; Pre-fix: bs-count read meaningful-length (4) but pasted used
       ;; raw substring length (7), leaving a stray "XXX" on screen.
       (should (= 4 bs-count))
       (should (equal "XXXX" pasted))))))

;; -----------------------------------------------------------------------
;; Test: evil-paste advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-paste-after ()
  "Test that `evil-paste-after' pastes via PTY."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (kill-new "world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((pasted nil))
       (cl-letf (((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text)))
                 ((symbol-function 'ghostel--send-encoded) #'ignore))
         (evil-paste-after 1))
       (should (equal "world" pasted))))))

;; -----------------------------------------------------------------------
;; Test: insert-state Ctrl key passthrough
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-ctrl-passthrough-sends-to-terminal ()
  "Test that Ctrl keys in insert state are sent to the terminal."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(11 . 0)))
     (evil-insert-state)
     ;; Test a sample of keys from evil-ghostel--ctrl-passthrough-keys
     (dolist (key '("a" "d" "e" "k" "r" "u" "w" "y"))
       (let ((keys-sent '()))
         (cl-letf (((symbol-function 'ghostel--send-encoded)
                    (lambda (k mods &rest _)
                      (push (cons k mods) keys-sent))))
           (evil-ghostel--passthrough-ctrl key))
         (should (cl-find (cons key "ctrl") keys-sent :test #'equal)))))))

(ert-deftest evil-ghostel-test-ctrl-passthrough-invalidates-shadow ()
  "Ctrl passthrough must invalidate the shadow cursor.
C-a / C-e / C-u / C-w / C-r / C-n / C-p reposition the readline
cursor or swap in a different input line — a stale shadow would
mislead the next `cursor-to-point' into computing deltas from a
position the cursor no longer holds."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(5 . 0))
             ((symbol-function 'ghostel--send-encoded) #'ignore))
     (evil-insert-state)
     (setq evil-ghostel--shadow-cursor (cons 5 0))
     (evil-ghostel--passthrough-ctrl "a")
     (should-not evil-ghostel--shadow-cursor))))

;; -----------------------------------------------------------------------
;; Test: insert-state entry skips vertical sync
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-insert-entry-no-vertical-sync ()
  "Test that entering insert from a different row snaps to terminal cursor.
Prevents up/down arrows being sent as history navigation."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "line one\nline two\nline three")
   ;; Terminal cursor on row 2 (last line), col 5
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(5 . 2)))
     (evil-normal-state)
     ;; Move point to row 0 (first line) simulating `kk`
     (goto-char (point-min))
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push key keys-sent))))
         (evil-insert-state))
       ;; Should NOT have sent up/down arrows
       (should-not (member "up" keys-sent))
       (should-not (member "down" keys-sent))
       ;; Point should have snapped to terminal cursor row
       (should (= (line-number-at-pos (point) t) 3))))))

;; -----------------------------------------------------------------------
;; Test: insert-state entry syncs column on same row
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-insert-entry-syncs-column-same-row ()
  "Test that entering insert on the same row syncs column position."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   ;; Terminal cursor on row 0, col 0
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0)))
     (evil-normal-state)
     ;; Move point to col 5 on the same row
     (goto-char (point-min))
     (move-to-column 5)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (push key keys-sent))))
         (evil-insert-state))
       ;; Should have sent right arrows to sync column
       (should (member "right" keys-sent))
       ;; Should NOT have sent vertical arrows
       (should-not (member "up" keys-sent))
       (should-not (member "down" keys-sent))))))

;; -----------------------------------------------------------------------
;; Test: line mode + evil interaction
;; -----------------------------------------------------------------------

(defmacro evil-ghostel-test--with-line-mode (input-text input-start input-end &rest body)
  "Set up a line-mode buffer for evil tests.
INPUT-TEXT is inserted; INPUT-START / INPUT-END (1-indexed positions)
become `ghostel--line-input-start' / `--line-input-end'."
  (declare (indent 3) (debug t))
  `(evil-ghostel-test--with-evil-buffer
    (setq-local ghostel--term t)
    (setq-local ghostel--input-mode 'line)
    (insert ,input-text)
    (setq-local ghostel--line-input-start (copy-marker ,input-start nil))
    (setq-local ghostel--line-input-end (copy-marker ,input-end t))
    (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
      ,@body)))

(ert-deftest evil-ghostel-test-line-mode-active-p ()
  "`evil-ghostel--line-mode-active-p' is true with markers in line mode."
  (evil-ghostel-test--with-line-mode "$ echo hello" 3 13
    (should (evil-ghostel--line-mode-active-p))
    (should-not (evil-ghostel--active-p))))

(ert-deftest evil-ghostel-test-line-mode-active-p-needs-markers ()
  "Predicate returns nil in line mode if the input markers are unset."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--input-mode 'line)
   (setq-local ghostel--line-input-start nil)
   (setq-local ghostel--line-input-end nil)
   (should-not (evil-ghostel--line-mode-active-p))))

(ert-deftest evil-ghostel-test-insert-entry-skips-sync-in-line-mode ()
  "Insert-state entry hook does not touch cursor sync in line mode.
Point and the terminal cursor are intentionally decoupled there."
  (evil-ghostel-test--with-line-mode "$ echo hi" 3 10
    (cl-letf ((ghostel--cursor-pos '(0 . 0)))
      (evil-normal-state)
      (let ((sync-called nil))
        (cl-letf (((symbol-function 'evil-ghostel--cursor-to-point)
                   (lambda () (setq sync-called t)))
                  ((symbol-function 'evil-ghostel--reset-cursor-point)
                   (lambda () (setq sync-called t))))
          (evil-insert-state))
        (should-not sync-called)))))

(ert-deftest evil-ghostel-test-insert-entry-skips-sync-in-copy-mode ()
  "Insert-state entry hook does not sync the cursor in copy mode."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (setq-local ghostel--input-mode 'copy)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0)))
     (evil-normal-state)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'evil-ghostel--cursor-to-point)
                  (lambda () (setq sync-called t)))
                 ((symbol-function 'evil-ghostel--reset-cursor-point)
                  (lambda () (setq sync-called t))))
         (evil-insert-state))
       (should-not sync-called)))))

(ert-deftest evil-ghostel-test-insert-line-jumps-to-input-start-in-line-mode ()
  "I in line mode lands at `ghostel--line-input-start' and sends no PTY C-a."
  (evil-ghostel-test--with-line-mode "$ echo hello" 3 13
    (evil-normal-state)
    (goto-char (point-max))
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (evil-insert-line 1))
      (should (= (point) 3))
      (should (evil-insert-state-p))
      (should-not (member "a" keys-sent)))))

(ert-deftest evil-ghostel-test-append-line-jumps-to-input-end-in-line-mode ()
  "A in line mode lands at `ghostel--line-input-end' and sends no PTY C-e."
  (evil-ghostel-test--with-line-mode "$ echo hello" 3 13
    (evil-normal-state)
    (goto-char (point-min))
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (evil-append-line 1))
      (should (= (point) 13))
      (should (evil-insert-state-p))
      (should-not (member "e" keys-sent)))))

(ert-deftest evil-ghostel-test-passthrough-ctrl-prefers-local-map-outside-semi-char ()
  "Outside semi-char, the local map's binding wins over `evil-insert-state-map'.
Without this, a passthrough handler in the minor-mode aux map would
shadow line mode's own C-a (`ghostel-beginning-of-input-or-line') and
C-d (`ghostel-line-mode-delete-char-or-eof')."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (setq-local ghostel--input-mode 'line)
   (let* ((called nil)
          (sentinel (lambda () (interactive) (setq called t)))
          (map (make-sparse-keymap)))
     (define-key map (kbd "C-a") sentinel)
     (use-local-map map)
     (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
       (evil-insert-state)
       (evil-ghostel--passthrough-ctrl "a")
       (should called)))))

(ert-deftest evil-ghostel-test-delete-falls-through-in-line-mode ()
  "evil-delete in line mode does not route to the PTY — runs evil's default."
  (evil-ghostel-test--with-line-mode "hello world" 1 12
    (goto-char (point-min))
    (let ((bs-count 0))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (when (equal key "backspace") (cl-incf bs-count)))))
        (evil-normal-state)
        (evil-delete (point-min) (+ (point-min) 5) 'inclusive nil nil))
      (should (= bs-count 0))
      (should (equal " world" (buffer-string))))))

;; -----------------------------------------------------------------------
;; Test: evil-undo advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-undo-sends-ctrl-underscore ()
  "Test that `evil-undo' sends Ctrl+_ to the terminal."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0)))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-undo 3))
       (should (= 3 (cl-count '("_" . "ctrl") keys-sent :test #'equal)))))))

;; -----------------------------------------------------------------------
;; Test: advice is no-op outside ghostel
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-no-op-outside-ghostel ()
  "Test that delete advice falls through when not in ghostel."
  (with-temp-buffer
    (evil-local-mode 1)
    (evil-normal-state)
    (insert "hello world")
    (goto-char (point-min))
    ;; evil-delete should work normally (modify buffer)
    (evil-delete 1 6 'inclusive nil nil)
    (should (equal " world" (buffer-string)))))

;; -----------------------------------------------------------------------
;; Test: ESC routing
;; -----------------------------------------------------------------------

(defmacro evil-ghostel-test--with-escape-stubs (alt-screen-p &rest body)
  "Run BODY with `ghostel--mode-enabled' returning ALT-SCREEN-P for 1049
and with `ghostel--send-encoded' captured into the local list `sent'."
  (declare (indent 1) (debug t))
  `(let ((sent '()))
     (cl-letf (((symbol-function 'ghostel--mode-enabled)
                (lambda (_term mode) (and (= mode 1049) ,alt-screen-p)))
               ((symbol-function 'ghostel--send-encoded)
                (lambda (key mods &rest _) (push (cons key mods) sent))))
       (setq-local ghostel--term t)
       ,@body)))

(ert-deftest evil-ghostel-test-escape-init-from-defcustom ()
  "Activating the mode initializes `evil-ghostel--escape-mode' from defcustom."
  (let ((evil-ghostel-escape 'terminal))
    (evil-ghostel-test--with-evil-buffer
     (should (eq 'terminal evil-ghostel--escape-mode)))))

(ert-deftest evil-ghostel-test-escape-mode-terminal-sends-pty ()
  "`terminal' mode always routes ESC to the PTY, regardless of alt-screen."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'terminal)
   (evil-ghostel-test--with-escape-stubs nil
     (evil-ghostel--escape)
     (should (member '("escape" . "") sent)))))

(ert-deftest evil-ghostel-test-escape-terminal-snaps-to-input ()
  "Terminal-bound ESC must snap the viewport like every other typed key.
Regression guard: dispatching directly via `ghostel--send-encoded'
bypasses the snap that `ghostel-mode-map''s `<escape>' route applies."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'terminal)
   (let ((snapped 0))
     (cl-letf (((symbol-function 'ghostel--snap-to-input)
                (lambda () (cl-incf snapped)))
               ((symbol-function 'ghostel--send-encoded)
                (lambda (&rest _))))
       (setq-local ghostel--term t)
       (evil-ghostel--escape)
       (should (= 1 snapped))))))

(ert-deftest evil-ghostel-test-escape-mode-evil-stays ()
  "`evil' mode never routes ESC to the PTY and triggers evil's binding."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'evil)
   (evil-insert-state)
   (evil-ghostel-test--with-escape-stubs t
     (evil-ghostel--escape)
     (should-not (member '("escape" . "") sent))
     (should-not (eq evil-state 'insert)))))

(ert-deftest evil-ghostel-test-escape-auto-altscreen-sends-pty ()
  "`auto' mode routes ESC to the PTY when alt-screen (1049) is active."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'auto)
   (evil-ghostel-test--with-escape-stubs t
     (evil-ghostel--escape)
     (should (member '("escape" . "") sent)))))

(ert-deftest evil-ghostel-test-escape-auto-no-altscreen-stays ()
  "`auto' mode routes ESC to evil when alt-screen is not active."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'auto)
   (evil-insert-state)
   (evil-ghostel-test--with-escape-stubs nil
     (evil-ghostel--escape)
     (should-not (member '("escape" . "") sent))
     (should-not (eq evil-state 'insert)))))

(ert-deftest evil-ghostel-test-escape-toggle-cycle ()
  "Calling toggle without a prefix cycles auto → terminal → evil → auto."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'auto)
   (evil-ghostel-toggle-send-escape)
   (should (eq 'terminal evil-ghostel--escape-mode))
   (evil-ghostel-toggle-send-escape)
   (should (eq 'evil evil-ghostel--escape-mode))
   (evil-ghostel-toggle-send-escape)
   (should (eq 'auto evil-ghostel--escape-mode))))

(ert-deftest evil-ghostel-test-escape-toggle-prefix-set ()
  "Numeric prefix sets the mode directly: 1=auto, 2=terminal, 3=evil."
  (evil-ghostel-test--with-evil-buffer
   (evil-ghostel-toggle-send-escape 2)
   (should (eq 'terminal evil-ghostel--escape-mode))
   (evil-ghostel-toggle-send-escape 3)
   (should (eq 'evil evil-ghostel--escape-mode))
   (evil-ghostel-toggle-send-escape 1)
   (should (eq 'auto evil-ghostel--escape-mode))))

(ert-deftest evil-ghostel-test-escape-toggle-prefix-invalid ()
  "An out-of-range numeric prefix signals `user-error' and leaves state alone."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'auto)
   (should-error (evil-ghostel-toggle-send-escape 7) :type 'user-error)
   (should (eq 'auto evil-ghostel--escape-mode))))

(ert-deftest evil-ghostel-test-escape-mode-buffer-local ()
  "Setting the mode in one ghostel buffer must not leak into another."
  (let ((buf-a (generate-new-buffer " *ghostel-a*"))
        (buf-b (generate-new-buffer " *ghostel-b*")))
    (unwind-protect
        (progn
          (with-current-buffer buf-a
            (ghostel-mode)
            (setq-local ghostel--term-rows 100)
            (evil-local-mode 1)
            (evil-ghostel-mode 1)
            (setq evil-ghostel--escape-mode 'terminal))
          (with-current-buffer buf-b
            (ghostel-mode)
            (setq-local ghostel--term-rows 100)
            (evil-local-mode 1)
            (evil-ghostel-mode 1)
            (setq evil-ghostel--escape-mode 'evil))
          (with-current-buffer buf-a
            (should (eq 'terminal evil-ghostel--escape-mode)))
          (with-current-buffer buf-b
            (should (eq 'evil evil-ghostel--escape-mode))))
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

(ert-deftest evil-ghostel-test-escape-evil-fallback-when-lookup-nil ()
  "When `lookup-key' yields no command (user rebound ESC to a chord
prefix), the dispatcher must fall back to `evil-force-normal-state'
rather than silently dropping the keystroke."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'evil)
   (evil-insert-state)
   (cl-letf (((symbol-function 'lookup-key)
              (lambda (&rest _) nil)))
     (evil-ghostel--escape)
     (should (eq 'normal evil-state)))))

;; -----------------------------------------------------------------------
;; Test: beginning-of-line lands at input start, not column 0
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-beginning-of-line-skips-prompt ()
  "`0' / `^' jump to start of input on a prompt row, not column 0.
Without this, `0' lands point on top of the `$ ' prompt and `0i'
inserts at the prompt position rather than at the input start."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "$ command")
   ;; Mark the prompt prefix so ghostel-beginning-of-input-or-line
   ;; treats it as a prompt row.
   (put-text-property 1 3 'ghostel-prompt t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (evil-normal-state)
     (goto-char (point-max))
     (evil-beginning-of-line)
     ;; Lands at col 2 (after "$ "), not col 0.
     (should (= 2 (current-column)))
     (goto-char (point-max))
     (evil-first-non-blank)
     (should (= 2 (current-column))))))

(ert-deftest evil-ghostel-test-beginning-of-line-falls-through-no-prompt ()
  "On rows without a prompt property `0' / `^' keep their default
column-0 / first-non-blank behaviour — scrollback navigation must
not be hijacked."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "  output line")  ; no ghostel-prompt property anywhere
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (evil-normal-state)
     (goto-char (point-max))
     (evil-beginning-of-line)
     (should (= 0 (current-column))))))

;; -----------------------------------------------------------------------
;; Test: shadow cursor (queued-key model)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-shadow-cursor-tracks-cursor-to-point ()
  "After `cursor-to-point' the shadow holds point's viewport position.
A second `cursor-to-point' call within the same operation must read
from the shadow rather than the still-stale live libghostty cursor —
otherwise it computes deltas from the wrong baseline and emits extra
arrows.  Mocks the live cursor at (17 . 0) and verifies the second
sync emits zero keys once point is at col 6."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "word1 word2 word3")
   (goto-char (point-min))
   (move-to-column 6)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(17 . 0)))
     (let ((first-keys '()) (second-keys '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _) (push key first-keys))))
         (evil-ghostel--cursor-to-point))
       (should (= 11 (length first-keys)))
       (should (equal '(6 . 0) evil-ghostel--shadow-cursor))
       ;; Second sync — point is unchanged, shadow already at (6 . 0),
       ;; so no further keys should be emitted.
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _) (push key second-keys))))
         (evil-ghostel--cursor-to-point))
       (should (= 0 (length second-keys)))))))

(ert-deftest evil-ghostel-test-shadow-cursor-tracks-delete-region ()
  "After `delete-region' the shadow advances by COUNT columns.
A follow-up `cursor-to-point' from BEG should be a no-op."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "word1 word2 word3")
   (goto-char (point-min))
   (move-to-column 6)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(17 . 0)))
     (cl-letf (((symbol-function 'ghostel--send-encoded) #'ignore))
       (evil-ghostel--delete-region 7 12))
     ;; Shadow is at end-col (11) - count (5) = 6, viewport row 0.
     (should (equal '(6 . 0) evil-ghostel--shadow-cursor))
     ;; Point is at col 6 (beg).  cursor-to-point should now be a no-op.
     (let ((extra-keys '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _) (push key extra-keys))))
         (evil-ghostel--cursor-to-point))
       (should (= 0 (length extra-keys)))))))

;; -----------------------------------------------------------------------
;; Test: cw doesn't emit redundant left arrows after delete
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-word-with-trailing-space ()
  "Regression: `dw' over `\"word \"' must send 5 backspaces, not 4.
With the old `meaningful-length' the trailing space was always
stripped, so `dw' on `\"word word word\" + ESC bb' sent only 4
backspaces — leaving a stray `w' behind (`word wword' instead of
`word word').  Trailing whitespace in single-line ranges is real
content."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "word word word")
   (goto-char (point-min))
   (move-to-column 5)  ; start of word2
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(14 . 0)))
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace") (cl-incf bs-count)))))
         ;; `dw' from col 5 deletes "word " (chars 6..10, exclusive end 11).
         (evil-delete 6 11 'exclusive nil nil))
       (should (= 5 bs-count))))))

(ert-deftest evil-ghostel-test-change-partial-no-post-delete-sync ()
  "After `cw' (count > 0) `around-change' must not run a second
post-delete cursor-to-point.  The redundant sync used to read the
stale live cursor and emit extra left arrows that pushed the
terminal cursor past the start of input — observed as `cw seems
to move the point to the beginning of the line'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "word1 word2 word3")
   (goto-char (point-min))
   (move-to-column 6)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(17 . 0)))
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _) (push key keys-sent))))
         (evil-change 7 12 'exclusive nil nil))
       (let* ((seq (nreverse keys-sent))
              (left-count (cl-count "left" seq :test #'equal))
              (bs-count (cl-count "backspace" seq :test #'equal)))
         ;; Exactly one initial sync (6 lefts: col 17 → col 11 = end)
         ;; and the 5 backspaces.  No second sync after backspaces —
         ;; with the bug, that second sync read the stale live cursor
         ;; (col 17) against point's now-col-6 and emitted 11 more
         ;; left arrows, pushing the terminal cursor past col 0.
         (should (= 6 left-count))
         (should (= 5 bs-count)))))))

;; -----------------------------------------------------------------------
;; Test: insert-state-entry uses viewport row, not buffer line
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-insert-entry-same-viewport-row-with-scrollback ()
  "Regression: with scrollback, `insert-state-entry' must compare
viewport rows, not buffer lines.  Otherwise the same-row check
fails (buffer-line N vs viewport-row 0) and we drop into
`reset-cursor-point', snapping point back to the terminal cursor
and silently undoing the user's `^' / `$' / `0' navigation."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (setq-local ghostel--term-rows 5)
   ;; Push 7 buffer lines so point's buffer line (line 7) is far from
   ;; the cursor's viewport row (0) when measured in raw line numbers.
   (insert "scroll-0\nscroll-1\nscroll-2\nscroll-3\nscroll-4\nscroll-5\nscroll-6\n$ ")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Cursor on the cursor's row at viewport row 4 (last).
             (ghostel--cursor-pos '(2 . 4)))
     ;; Park point at col 0 of the cursor row (buffer line 7) — this is
     ;; the same viewport row as the cursor.
     (goto-char (point-max))
     (beginning-of-line)
     (let ((reset-called nil) (sync-called nil))
       (cl-letf (((symbol-function 'evil-ghostel--reset-cursor-point)
                  (lambda () (setq reset-called t)))
                 ((symbol-function 'evil-ghostel--cursor-to-point)
                  (lambda () (setq sync-called t))))
         (evil-ghostel--insert-state-entry))
       ;; Same viewport row → cursor-to-point, NOT reset-cursor-point.
       (should sync-called)
       (should-not reset-called)))))

;; -----------------------------------------------------------------------
;; Test: column navigation survives idle redraw
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-around-redraw-preserves-column-nav ()
  "In normal state, `^'/`$'/`0' must survive a redraw on the cursor's
line so long as the prompt didn't scroll to a new line.  The
`prompt-moved' override only applies when output actually moves the
cursor onto a different buffer line — for redraws that stay on the
same line, the saved point position wins so column-only navigation
sticks."
  (evil-ghostel-test--with-buffer 5 40 "$ hello world"
                                  (evil-normal-state)
                                  ;; Point at col 0 of the prompt line — user did `0'.
                                  (goto-char (point-min))
                                  (should (= 0 (current-column)))
                                  (should (= 1 (line-number-at-pos)))
                                  ;; Redraw without growing scrollback (single-line update).
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term nil))
                                  ;; Point stays where the user navigated.
                                  (should (= 0 (current-column)))
                                  (should (= 1 (line-number-at-pos)))))

;; -----------------------------------------------------------------------
;; Runner
;; -----------------------------------------------------------------------

(defconst evil-ghostel-test--elisp-tests
  '(evil-ghostel-test-mode-activation
    evil-ghostel-test-mode-deactivation
    evil-ghostel-test-escape-stay
    evil-ghostel-test-advice-on-insert
    evil-ghostel-test-advice-on-append
    evil-ghostel-test-advice-insert-line-sends-home
    evil-ghostel-test-advice-append-line-sends-end
    evil-ghostel-test-insert-line-multiline-syncs-row
    evil-ghostel-test-append-line-multiline-syncs-row
    evil-ghostel-test-change-eol-syncs-cursor-to-point
    evil-ghostel-test-advice-no-op-outside-ghostel
    evil-ghostel-test-meaningful-length-strips-trailing
    evil-ghostel-test-delete-sends-backspace-keys
    evil-ghostel-test-delete-line-same-row-uses-ctrl-u
    evil-ghostel-test-change-line-same-row-uses-ctrl-u
    evil-ghostel-test-delete-line-multiline-syncs-cursor
    evil-ghostel-test-delete-line-strips-render-padding
    evil-ghostel-test-replace-counts-match-on-trailing-space
    evil-ghostel-test-delete-char
    evil-ghostel-test-change-deletes-and-inserts
    evil-ghostel-test-replace-deletes-and-inserts
    evil-ghostel-test-paste-after
    evil-ghostel-test-undo-sends-ctrl-underscore
    evil-ghostel-test-change-whole-line
    evil-ghostel-test-delete-no-op-outside-ghostel
    evil-ghostel-test-escape-init-from-defcustom
    evil-ghostel-test-escape-mode-terminal-sends-pty
    evil-ghostel-test-escape-terminal-snaps-to-input
    evil-ghostel-test-escape-mode-evil-stays
    evil-ghostel-test-escape-auto-altscreen-sends-pty
    evil-ghostel-test-escape-auto-no-altscreen-stays
    evil-ghostel-test-escape-toggle-cycle
    evil-ghostel-test-escape-toggle-prefix-set
    evil-ghostel-test-escape-toggle-prefix-invalid
    evil-ghostel-test-escape-mode-buffer-local
    evil-ghostel-test-escape-evil-fallback-when-lookup-nil
    evil-ghostel-test-beginning-of-line-skips-prompt
    evil-ghostel-test-beginning-of-line-falls-through-no-prompt
    evil-ghostel-test-shadow-cursor-tracks-cursor-to-point
    evil-ghostel-test-shadow-cursor-tracks-delete-region
    evil-ghostel-test-delete-word-with-trailing-space
    evil-ghostel-test-change-partial-no-post-delete-sync
    evil-ghostel-test-insert-entry-same-viewport-row-with-scrollback
    evil-ghostel-test-ctrl-passthrough-invalidates-shadow)
  "Tests that require only Elisp (no native module).")

(defun evil-ghostel-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit
   `(member ,@evil-ghostel-test--elisp-tests)))

(defun evil-ghostel-test-run ()
  "Run all evil-ghostel tests."
  (ert-run-tests-batch-and-exit "^evil-ghostel-test-"))

;;; evil-ghostel-test.el ends here
