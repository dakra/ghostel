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
                                  (should (equal '(11 . 0) (ghostel--cursor-position term)))
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
                                  (let ((pos (ghostel--cursor-position term)))
                                    (should (= 1 (cdr pos))))
                                  (goto-char (point-min))
                                  (evil-ghostel--reset-cursor-point)
                                  (should (= 2 (line-number-at-pos)))))

(ert-deftest evil-ghostel-test-reset-cursor-point-with-scrollback ()
  "Regression: reset-cursor-point must anchor to the viewport, not point-min.
`ghostel--cursor-position' returns the row within the viewport (the
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
      (should (= (car (ghostel--cursor-position term))
                 (current-column))))))

;; -----------------------------------------------------------------------
;; Test: cursor-to-point (arrow key sending)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-cursor-to-point ()
  "Test that `evil-ghostel--cursor-to-point' sends correct arrow keys."
  (evil-ghostel-test--with-buffer 5 40 "$ echo hello world"
                                  ;; Terminal cursor at col 18, row 0
                                  (should (equal '(18 . 0) (ghostel--cursor-position term)))
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
                                  ;; Move cursor left in terminal, then move point right of it
                                  (ghostel--write-input term "\e[3D") ; cursor left 3 → col 2
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(5 . 0))))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
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
;; Test: evil-delete advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-sends-backspace-keys ()
  "Test that `evil-delete' advice sends backspace keys via PTY."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
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

(ert-deftest evil-ghostel-test-delete-line-sends-ctrl-u ()
  "Test that line-type `evil-delete' sends Ctrl+U to clear line."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-delete (point-min) (point-max) 'line nil nil))
       ;; Should have sent C-e and Ctrl+U
       (should (cl-find '("u" . "ctrl") keys-sent :test #'equal))
       (should (cl-find '("e" . "ctrl") keys-sent :test #'equal))))))

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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(11 . 0))))
     (evil-insert-state)
     ;; Test a sample of keys from evil-ghostel--ctrl-passthrough-keys
     (dolist (key '("a" "d" "e" "k" "r" "u" "w" "y"))
       (let ((keys-sent '()))
         (cl-letf (((symbol-function 'ghostel--send-encoded)
                    (lambda (k mods &rest _)
                      (push (cons k mods) keys-sent))))
           (evil-ghostel--passthrough-ctrl key))
         (should (cl-find (cons key "ctrl") keys-sent :test #'equal)))))))

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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(5 . 2))))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
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
    (cl-letf (((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
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
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
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
    evil-ghostel-test-advice-no-op-outside-ghostel
    evil-ghostel-test-delete-sends-backspace-keys
    evil-ghostel-test-delete-line-sends-ctrl-u
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
    evil-ghostel-test-escape-evil-fallback-when-lookup-nil)
  "Tests that require only Elisp (no native module).")

(defun evil-ghostel-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit
   `(member ,@evil-ghostel-test--elisp-tests)))

(defun evil-ghostel-test-run ()
  "Run all evil-ghostel tests."
  (ert-run-tests-batch-and-exit "^evil-ghostel-test-"))

;;; evil-ghostel-test.el ends here
