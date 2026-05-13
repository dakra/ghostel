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
  "Test that `evil-ghostel-mode' activates correctly.
Asserts that the insert-state-entry hook is wired up, the redraw
advice is installed, and the command-remap bindings are in
`evil-ghostel-mode-map' for normal and visual states.

Bindings are remap-form (`[remap evil-FOO]') so user remappings of
the underlying evil commands flow through to our PTY-routed
variants — verified here by looking up the remap rather than a
literal key."
  (evil-ghostel-test--with-evil-buffer
   (should evil-ghostel-mode)
   (should (memq 'evil-ghostel--insert-state-entry
                 evil-insert-state-entry-hook))
   (should (advice--p (advice--symbol-function 'ghostel--redraw)))
   (should (advice--p (advice--symbol-function 'ghostel--set-cursor-style)))
   ;; Editing operators are bound via [remap evil-FOO] in normal state.
   (should (eq #'evil-ghostel-delete
               (lookup-key (evil-get-auxiliary-keymap
                            evil-ghostel-mode-map 'normal)
                           [remap evil-delete])))
   (should (eq #'evil-ghostel-change
               (lookup-key (evil-get-auxiliary-keymap
                            evil-ghostel-mode-map 'normal)
                           [remap evil-change])))
   ;; And in visual state.
   (should (eq #'evil-ghostel-delete
               (lookup-key (evil-get-auxiliary-keymap
                            evil-ghostel-mode-map 'visual)
                           [remap evil-delete])))
   ;; Literal key bindings must NOT be present — that would shadow
   ;; user remappings of the underlying evil commands.
   (should-not (lookup-key (evil-get-auxiliary-keymap
                            evil-ghostel-mode-map 'normal)
                           "d"))))

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

(ert-deftest evil-ghostel-test-advice-survives-disable-in-other-buffer ()
  "Global `ghostel--redraw' / cursor-style advice survives one buffer disabling.
The advice is global but the mode is buffer-local; `advice-remove'
during disable must wait until the LAST `evil-ghostel-mode' buffer
is gone, otherwise toggling off in one buffer silently strips the
wrapper from every other ghostel buffer."
  (let ((a (generate-new-buffer " *evil-ghostel-test-advice-a*"))
        (b (generate-new-buffer " *evil-ghostel-test-advice-b*")))
    (unwind-protect
        (progn
          (with-current-buffer a
            (ghostel-mode)
            (setq-local ghostel--term-rows 100)
            (evil-local-mode 1)
            (evil-ghostel-mode 1))
          (with-current-buffer b
            (ghostel-mode)
            (setq-local ghostel--term-rows 100)
            (evil-local-mode 1)
            (evil-ghostel-mode 1))
          (should (advice-member-p #'evil-ghostel--around-redraw
                                   'ghostel--redraw))
          ;; Disable in A — B still has the mode on, advice must stay.
          (with-current-buffer a (evil-ghostel-mode -1))
          (should (advice-member-p #'evil-ghostel--around-redraw
                                   'ghostel--redraw))
          (should (advice-member-p #'evil-ghostel--override-cursor-style
                                   'ghostel--set-cursor-style))
          ;; Disable in B — no buffers left, advice removed.
          (with-current-buffer b (evil-ghostel-mode -1))
          (should-not (advice-member-p #'evil-ghostel--around-redraw
                                       'ghostel--redraw))
          (should-not (advice-member-p #'evil-ghostel--override-cursor-style
                                       'ghostel--set-cursor-style)))
      (when (buffer-live-p a) (kill-buffer a))
      (when (buffer-live-p b) (kill-buffer b)))))

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
;; Test: evil-ghostel-goto-input-position end-to-end with the native module
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-goto-input-position-end-to-end ()
  "End-to-end: `evil-ghostel-goto-input-position' sends LEFT arrows.
Verifies the lifted-from-evil-ghostel implementation against a real
libghostty terminal (the Phase 1 mock tests exercise the bare
algorithm; this one walks scrollback math and viewport offsets too)."
  (evil-ghostel-test--with-buffer 5 40 "$ echo hello world"
                                  (should (equal '(18 . 0) ghostel--cursor-pos))
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      ;; Target: position 8 = column 7
                                      ;; (start of "hello").
                                      (evil-ghostel-goto-input-position 8))
                                    (should (= 11 (length keys-sent)))
                                    (should (cl-every (lambda (k) (equal k "left")) keys-sent)))))

(ert-deftest evil-ghostel-test-goto-input-position-with-scrollback ()
  "Regression: goto-input-position must subtract scrollback from buffer line.
`ghostel--cursor-pos' holds viewport-relative rows, so a buffer
line N must be converted to viewport row N-scrollback before
diffing — otherwise dy is wrong by the scrollback line count."
  (let ((term (ghostel--new 5 40 1000)))
    ;; Push 12 rows so the viewport shows rows 8..12 plus a trailing
    ;; cursor row.
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
      ;; Terminal cursor is on the last viewport row; target a
      ;; buffer position on the previous viewport row, same column.
      (let* ((tpos ghostel--cursor-pos)
             (trow (cdr tpos))
             (target-viewport-row (1- trow))
             (scrollback (max 0 (- (count-lines (point-min) (point-max))
                                   ghostel--term-rows)))
             (target-pos (save-excursion
                           (goto-char (point-min))
                           (forward-line (+ scrollback target-viewport-row))
                           (move-to-column (car tpos))
                           (point))))
        (let ((keys-sent '()))
          (cl-letf (((symbol-function 'ghostel--send-encoded)
                     (lambda (key _mods &rest _)
                       (push key keys-sent))))
            (evil-ghostel-goto-input-position target-pos))
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

(ert-deftest evil-ghostel-test-insert-drives-shell-cursor ()
  "`evil-ghostel-insert' drives the shell cursor to point via arrow keys.
The command calls `evil-ghostel-goto-input-position' which moves the
terminal cursor to point's buffer position."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0)))
     (evil-normal-state)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'evil-ghostel-goto-input-position)
                  (lambda (&rest _) (setq sync-called t))))
         (evil-ghostel-insert))
       (should sync-called)))))

(ert-deftest evil-ghostel-test-append-drives-shell-cursor ()
  "`evil-ghostel-append' drives the shell cursor to point via arrow keys."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(5 . 0)))
     (evil-normal-state)
     (goto-char (point-min))
     (move-to-column 2)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'evil-ghostel-goto-input-position)
                  (lambda (&rest _) (setq sync-called t))))
         (evil-ghostel-append))
       (should sync-called)))))

(ert-deftest evil-ghostel-test-append-at-cursor-does-not-advance ()
  "Regression: `evil-ghostel-append' at the terminal cursor does not forward-char.
Reproduces noctuid's report: with zsh-autosuggestions / RPROMPT
painting cells past the typed input, vanilla `evil-append' would
`forward-char' onto a non-input padding cell so the visual cursor
lands one cell past `d' while the PTY cursor (and backspace target)
stays on `d'.  The guard skips the +1 step when point is at or past
`ghostel-cursor-point' and the cell at the cursor is blank/eol."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; Simulate RPROMPT padding: typed "word" + 10 padding cells +
   ;; faux right-prompt content.  Terminal cursor sits at the end of
   ;; the typed input (pos 5), not at end of line.
   (let ((inhibit-read-only t))
     (insert "word")
     (insert (make-string 10 ?\s))
     (insert "rprompt"))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Isolate target-computation from PTY mechanics: simulate
             ;; goto-input-position's net effect on point.
             ((symbol-function 'evil-ghostel-goto-input-position)
              (lambda (pos &rest _) (goto-char pos) t))
             ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore)
             (ghostel--cursor-pos '(4 . 0))
             (ghostel--cursor-char-pos 5))
     (evil-normal-state)
     (goto-char 5) ; point AT cursor-char-pos (end of typed input)
     (evil-ghostel-append)
     ;; Without the guard, target would be pos 6 (onto a padding space).
     ;; The guard keeps target = point so the cursor stays put.
     (should (= 5 (point)))
     (should (eq 'insert evil-state)))))

(ert-deftest evil-ghostel-test-append-after-cursor-moved-mid-input-advances ()
  "Regression: after the insert-state-entry hook moved the terminal cursor
mid-input (typical of `i' then `<esc>' then `a'), pressing `a' must
still advance one char.  The padding-cell guard correctly falls
through when the cell at the cursor is non-blank typed text."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; Buffer: "hi" (the user typed `hi').  Then they pressed `i', and
   ;; the insert-state-entry hook moved the terminal cursor from pos 3
   ;; (end of input) back to pos 2 (on `i').  Now they press `<esc>'
   ;; then `a' — the cursor is at pos 2, the same as point.
   (insert "hi")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'evil-ghostel-goto-input-position)
              (lambda (pos &rest _) (goto-char pos) t))
             ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore)
             ;; Cursor moved to mid-input by a previous sync.
             (ghostel--cursor-pos '(1 . 0))
             (ghostel--cursor-char-pos 2))
     (evil-normal-state)
     (goto-char 2) ; point on `i', same as cursor
     (evil-ghostel-append)
     ;; Cell at cursor (pos 2, "i") is non-blank typed text → the
     ;; guard falls through; target = (1+ point) = 3.
     (should (= 3 (point)))
     (should (eq 'insert evil-state)))))

(ert-deftest evil-ghostel-test-insert-on-rprompt-clamps-to-row-end ()
  "Regression: `evil-ghostel-insert' on a padding/RPROMPT cell clamps target.
Symmetric to `evil-ghostel-test-append-at-cursor-does-not-advance':
when point sits past typed input (in the padding gap or on
RPROMPT cells), `i' must drive the cursor to row-end rather than
the raw point — otherwise N right-arrows are sent, the shell
clamps them silently, and Emacs `point' ends up past the live
cursor."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert "word")
     (insert (make-string 10 ?\s))
     (insert "rprompt"))
   (cl-letf* ((target-pos nil)
              ((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
              ((symbol-function 'evil-ghostel-goto-input-position)
               (lambda (pos &rest _) (setq target-pos pos) (goto-char pos) t))
              ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore)
              (ghostel--cursor-pos '(4 . 0))
              (ghostel--cursor-char-pos 5))
     (evil-normal-state)
     (goto-char 12) ; point inside the padding gap
     (evil-ghostel-insert)
     ;; Target clamped to row-end (= 5 — end of "word"), NOT raw point (12).
     (should (= 5 target-pos))
     (should (eq 'insert evil-state)))))

(ert-deftest evil-ghostel-test-append-before-cursor-uses-vanilla ()
  "Append mid-input advances by one cell.
Point inside the input region but before the terminal cursor must
still advance by one cell (vim semantics)."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'evil-ghostel-goto-input-position)
              (lambda (pos &rest _) (goto-char pos) t))
             ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore)
             (ghostel--cursor-pos '(11 . 0))
             (ghostel--cursor-char-pos 12))
     (evil-normal-state)
     (goto-char 3) ; point on 'e' of "hello"
     (evil-ghostel-append)
     ;; Target = (min (1+ point) row-end) = 4.
     (should (= 4 (point)))
     (should (eq 'insert evil-state)))))

(ert-deftest evil-ghostel-test-insert-line-sends-arrows-to-input-start ()
  "`evil-ghostel-insert-line' drives the shell cursor to input-start via arrows.
The vterm-style shape uses `evil-ghostel-goto-input-position' rather
than sending readline's C-a — deterministic regardless of the shell's
`bindkey -v' / vi-mode key bindings, which is what Bug B (issue #264)
was exposing."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (evil-normal-state)
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _)
                   (push (cons key mods) keys-sent)))
                ((symbol-function 'evil-ghostel--sync-render) #'ignore)
                ;; Mock the entry hook to avoid double-counting arrows: in
                ;; tests `sync-render' is a no-op so `ghostel--cursor-pos'
                ;; doesn't track the move, and the hook's idempotent re-run
                ;; would otherwise re-send the same arrows.
                ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore))
        (evil-ghostel-insert-line))
      ;; Cursor at col 7 (end of "hello"), input-start at col 2 → 5 lefts.
      (should (= 5 (cl-count '("left" . "") keys-sent :test #'equal)))
      ;; Critically: no readline C-a — Bug B (#264) determinism.
      (should-not (cl-find '("a" . "ctrl") keys-sent :test #'equal))
      (should (evil-insert-state-p)))))

(ert-deftest evil-ghostel-test-append-line-sends-arrows-to-row-end ()
  "`evil-ghostel-append-line' drives the shell cursor to row-end via arrows.
Same vterm-style shape as `I' — no readline C-e, deterministic
regardless of shell vi-mode."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (evil-normal-state)
    (goto-char 3) ; point at input-start ("h" of "hello"); cursor at 8 (eol).
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _)
                   (push (cons key mods) keys-sent)))
                ((symbol-function 'evil-ghostel--sync-render) #'ignore)
                ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore))
        (evil-ghostel-append-line))
      ;; Cursor at col 7, row-end at col 7 (after "hello", no padding) →
      ;; goto-input-position with target == cursor-pos is a no-op horizontally.
      (should-not (cl-find '("e" . "ctrl") keys-sent :test #'equal))
      (should (evil-insert-state-p)))))

(ert-deftest evil-ghostel-test-insert-line-pins-point-at-input-start ()
  "Regression for Bug A (#264): `I' lands point at `ghostel-input-start-point'.
After the vterm-style rewrite point is set deterministically before
`evil-insert-state' runs — no async redraw can drag point past the
right prompt (Bug A's \"until first keystroke\" symptom)."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (evil-normal-state)
    (cl-letf (((symbol-function 'ghostel--send-encoded) #'ignore)
              ((symbol-function 'evil-ghostel--sync-render) #'ignore)
              ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore))
      (evil-ghostel-insert-line))
    (should (= 3 (point))) ; right after "$ "
    (should (evil-insert-state-p))))

(ert-deftest evil-ghostel-test-append-line-pins-point-at-row-end ()
  "Regression for Bug A (#264): `A' lands point at end of typed input."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (evil-normal-state)
    (goto-char (point-min))
    (cl-letf (((symbol-function 'ghostel--send-encoded) #'ignore)
              ((symbol-function 'evil-ghostel--sync-render) #'ignore)
              ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore))
      (evil-ghostel-append-line))
    (should (= 8 (point))) ; end of "hello"
    (should (evil-insert-state-p))))

(ert-deftest evil-ghostel-test-change-eol-snaps-point-to-cursor ()
  "`C' at eol of a non-cursor row enters insert state at the live cursor.
Off the cursor row there's no PTY-routed editing to be done — the
delete is a no-op on the scrollback line, then `evil-ghostel-insert'
takes the off-row branch and the entry hook's `reset-cursor-point'
pulls point onto the live cursor's row.  No history-navigation `up'
arrows are sent (which the old `sync-inhibit' path mistakenly did)."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "line one\nline two\nline three")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(10 . 2)))
     (evil-normal-state)
     (goto-char (point-min))
     (end-of-line)
     (let ((keys-sent '())
           (eol-pos (point)))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-ghostel-change-line eol-pos eol-pos 'inclusive nil nil))
       (should-not (cl-find '("up" . "") keys-sent :test #'equal))
       (should (evil-insert-state-p))))))

;; -----------------------------------------------------------------------
;; Test: insert-state-entry hook is a no-op outside ghostel buffers
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-insert-state-entry-no-op-outside-ghostel ()
  "Insert-state-entry hook is buffer-local: nothing fires in unrelated buffers."
  (with-temp-buffer
    (evil-local-mode 1)
    (evil-normal-state)
    (let ((sync-called nil))
      (cl-letf (((symbol-function 'evil-ghostel-goto-input-position)
                 (lambda (&rest _) (setq sync-called t))))
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
  "End-to-end: `evil-ghostel-delete-input-region' sends the expected keys."
  (evil-ghostel-test--with-buffer 5 40 "$ echo hello"
                                  ;; Delete "hello" (col 7-12)
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel-delete-input-region 8 13))
                                    ;; Should send arrow keys to move cursor, then 5 backspaces
                                    (should (= 5 (cl-count "backspace" keys-sent :test #'equal))))))

;; -----------------------------------------------------------------------
;; Test: meaningful-input-length helper (render padding stripping)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-meaningful-length-strips-trailing ()
  "Trailing whitespace counts only when TEXT spans multiple lines.
Single-line `\"word \"' is real user content (e.g. `dw' over a word
plus its trailing space); multi-line ranges may contain TUI box
padding that should be stripped per line.

The implementation lives in `evil-ghostel--meaningful-input-length'."
  (should (= 0 (evil-ghostel--meaningful-input-length "")))
  (should (= 3 (evil-ghostel--meaningful-input-length "AAA")))
  ;; Single-line: trailing whitespace is preserved (real content).
  (should (= 9 (evil-ghostel--meaningful-input-length "AAA      ")))
  (should (= 5 (evil-ghostel--meaningful-input-length "word ")))
  ;; Multi-line: per-line trailing whitespace stripped (TUI padding).
  (should (= 7 (evil-ghostel--meaningful-input-length "AAA      \nBBB     ")))
  (should (= 4 (evil-ghostel--meaningful-input-length "AAA      \n")))
  ;; Inner whitespace preserved either way.
  (should (= 7 (evil-ghostel--meaningful-input-length "A B C  ")))
  (should (= 8 (evil-ghostel--meaningful-input-length "A B C  D"))))

;; -----------------------------------------------------------------------
;; Test: input-region helpers (cursor-row-end, point-in-input, clamp)
;; -----------------------------------------------------------------------

(defmacro evil-ghostel-test--with-input-fixture (prompt input &rest body)
  "Set up a mock terminal buffer with PROMPT (carrying `ghostel-prompt')
followed by INPUT, with `ghostel--cursor-char-pos' positioned at the
end of INPUT.  Runs BODY in the buffer.

Evil and `evil-ghostel-mode' are enabled so tests can invoke evil
commands.  Mocks the terminal handle and viewport so the
input-region helpers can derive prompt boundaries and viewport rows
without a real native module."
  (declare (indent 2))
  `(let ((buf (generate-new-buffer " *evil-ghostel-test-input*")))
     (unwind-protect
         (with-current-buffer buf
           (ghostel-mode)
           (let ((inhibit-read-only t))
             (insert (propertize ,prompt 'ghostel-prompt t))
             (insert ,input))
           (setq ghostel--term 'fake)
           (setq ghostel--term-rows 1)
           (setq ghostel--cursor-char-pos (point))
           (setq ghostel--cursor-pos (cons (current-column) 0))
           (evil-local-mode 1)
           (evil-ghostel-mode 1)
           (cl-letf (((symbol-function 'ghostel--mode-enabled)
                      (lambda (&rest _) nil)))
             ,@body))
       (kill-buffer buf))))

(ert-deftest evil-ghostel-test-cursor-row-end-point-returns-eol ()
  "`evil-ghostel--cursor-row-end-point' is end-of-line at the cursor's row."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (should (= (point-max) (evil-ghostel--cursor-row-end-point)))))

(ert-deftest evil-ghostel-test-cursor-row-end-point-respects-input-property ()
  "OSC 133;B `ghostel-input' cells win over the gap heuristic.
A row painted with bash/zsh shell integration carries `ghostel-input'
on every input cell; the helper returns the position right after the
rightmost such cell, regardless of trailing renderer cells."
  (let ((buf (generate-new-buffer " *evil-ghostel-test-input-prop*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            ;; OSC 133;B span over the typed input.
            (insert (propertize "hello" 'ghostel-input t))
            ;; Padding + autosuggest hint past the input (no input prop).
            (insert "   hint"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          ;; Cursor at end of typed input (between "hello" and the padding).
          (setq ghostel--cursor-char-pos 8) ; just after "hello"
          (setq ghostel--cursor-pos '(7 . 0))
          ;; End-of-input is right after the last `ghostel-input' cell.
          (should (= 8 (evil-ghostel--cursor-row-end-point))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-cursor-row-end-point-uses-first-input-region ()
  "Issue #264 fish repro: libghostty tags BOTH typed input cells AND
right-prompt cells as SEMANTIC_INPUT (the latter via its cell-
positioning heuristic when fish jumps the cursor to draw the right
prompt).  Two disjoint `ghostel-input' regions separated by the
padding gap.  The helper must return the end of the *first* region
\(typed input), not the rightmost cell (inside the right prompt)."
  (let ((buf (generate-new-buffer " *evil-ghostel-test-fish-rprompt*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            (insert (propertize "foo bar" 'ghostel-input t))
            (insert (make-string 20 ?\s))
            (insert (propertize "main *" 'ghostel-input t)))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          ;; Cursor at end of typed "foo bar" (col 9, pos 10).
          (setq ghostel--cursor-char-pos 10)
          (setq ghostel--cursor-pos '(9 . 0))
          ;; First `ghostel-input' region ends at pos 10 (after "foo bar").
          ;; Rightmost region (the right prompt) is ignored.
          (should (= 10 (evil-ghostel--cursor-row-end-point))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-cursor-row-end-point-clamps-at-right-prompt-gap ()
  "Bug A (#264): fish-style right prompt is excluded by the gap heuristic.
With no `ghostel-input' property on the row (fish without OSC 133;B),
a whitespace gap of `evil-ghostel-right-prompt-gap' or more columns
between typed input and right-aligned content marks the boundary."
  (let ((buf (generate-new-buffer " *evil-ghostel-test-rprompt*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            (insert "nslookup")
            (insert (make-string 20 ?\s)) ; >> gap threshold
            (insert "main *"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          ;; Cursor at end of typed "nslookup" (col 10, pos 11).
          (setq ghostel--cursor-char-pos 11)
          (setq ghostel--cursor-pos '(10 . 0))
          ;; End-of-input is pos 11 (just after "nslookup"), NOT the
          ;; position after "main *" — the gap excludes the right prompt.
          (should (= 11 (evil-ghostel--cursor-row-end-point))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-cursor-row-end-point-tight-gap-keeps-input ()
  "Normal input with double-space (gap < threshold) stays whole.
A `cmd  arg' pattern (2 spaces between tokens) must not trigger the
right-prompt heuristic — input includes both words and the spaces."
  (let ((buf (generate-new-buffer " *evil-ghostel-test-tight*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            (insert "cmd  arg")) ; 2-space gap, < threshold (6)
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--cursor-char-pos 11) ; just after "arg"
          (setq ghostel--cursor-pos '(10 . 0))
          (should (= 11 (evil-ghostel--cursor-row-end-point))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-end-of-line-clamps-past-right-prompt ()
  "Bug A (#264) end-to-end: `$' lands at end of input, not on the right prompt."
  (let ((buf (generate-new-buffer " *evil-ghostel-test-end-of-line-rprompt*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            (insert "cmd")
            (insert (make-string 20 ?\s))
            (insert "branch *"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--cursor-char-pos 6) ; just after "cmd"
          (setq ghostel--cursor-pos '(5 . 0))
          (evil-local-mode 1)
          (evil-ghostel-mode 1)
          (cl-letf (((symbol-function 'ghostel--mode-enabled)
                     (lambda (&rest _) nil)))
            (evil-normal-state)
            (goto-char 3) ; on first input char
            (evil-ghostel-end-of-line 1))
          ;; Clamped to end-of-input (after "cmd" = pos 6), NOT into
          ;; "branch *" past the 20-space gap.  Without the right-prompt
          ;; clamp `$' would have landed somewhere inside "branch *".
          (should (= 6 (point))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-point-in-input-p-true-between-prompt-and-eol ()
  "Returns t when point is on the cursor row between input-start and EOL."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    ;; Right after the prompt — first char of input.
    (should (evil-ghostel-point-in-input-p 3))
    ;; At the cursor itself.
    (should (evil-ghostel-point-in-input-p ghostel--cursor-char-pos))))

(ert-deftest evil-ghostel-test-point-in-input-p-false-on-prompt-char ()
  "Returns nil when POS is inside the prompt prefix."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    ;; Position 1 ($ char) and 2 (space) are part of the prompt.
    (should-not (evil-ghostel-point-in-input-p 1))
    (should-not (evil-ghostel-point-in-input-p 2))))

(ert-deftest evil-ghostel-test-clamp-to-input-narrows-on-cursor-row ()
  "A range with endpoints inside the prompt is clamped to the input region."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let ((clamped (evil-ghostel--clamp-to-input
                    (cons 1 ghostel--cursor-char-pos))))
      ;; BEG was in the prompt (1) → bumped to input-start (3).
      (should (= 3 (car clamped)))
      ;; END was at the cursor → unchanged.
      (should (= ghostel--cursor-char-pos (cdr clamped))))))

(ert-deftest evil-ghostel-test-clamp-to-input-trims-end-past-cursor ()
  "A range whose END walks past the live cursor is trimmed back."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    ;; Pretend the renderer wrote some padding after the cursor (TUI box).
    (let ((inhibit-read-only t))
      (save-excursion (insert "   ")))
    (let* ((past-cursor (+ ghostel--cursor-char-pos 3))
           (clamped (evil-ghostel--clamp-to-input (cons 3 past-cursor))))
      (should (= 3 (car clamped)))
      (should (= ghostel--cursor-char-pos (cdr clamped))))))

(ert-deftest evil-ghostel-test-clamp-to-input-passes-through-off-row ()
  "Ranges that touch a non-cursor row are returned unchanged."
  (let ((buf (generate-new-buffer " *evil-ghostel-test-clamp-off-row*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert "scrollback\n")
            (insert (propertize "$ " 'ghostel-prompt t))
            (insert "input"))
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 2)
          (setq ghostel--cursor-char-pos (point))
          (setq ghostel--cursor-pos (cons (current-column) 1))
          ;; Range spans first row (off cursor row) and cursor row.
          (let ((input (cons 1 ghostel--cursor-char-pos)))
            (should (equal input (evil-ghostel--clamp-to-input input)))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-goto-input-position-sends-arrows-unit ()
  "Unit: |dx| left arrows are sent when point is left of the cursor."
  (evil-ghostel-test--with-input-fixture "$ " "hello world"
    ;; cursor-pos col 13 (after "$ hello world"); target is col 7 (start
    ;; of "hello"), so 6 LEFT arrows.
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (push key keys-sent))))
        (evil-ghostel-goto-input-position 8)) ; pos 8 = column 7
      (should (= 6 (length keys-sent)))
      (should (cl-every (lambda (k) (equal k "left")) keys-sent)))))

(ert-deftest evil-ghostel-test-goto-input-position-no-op-at-target ()
  "No keys are sent when point already matches the terminal cursor."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (push key keys-sent))))
        (evil-ghostel-goto-input-position ghostel--cursor-char-pos))
      (should (zerop (length keys-sent))))))

(ert-deftest evil-ghostel-test-sync-render-forces-deferred-redraw ()
  "`sync-render' force-runs `ghostel--delayed-redraw' after a bulk-output drain.
The filter only takes the synchronous redraw path for small echoes
arriving within `ghostel-immediate-redraw-interval' of the last
keystroke.  Larger echoes (e.g. `cc' sending 100 backspaces) take
the bulk-output branch, which queues a timer-driven redraw — so
`ghostel--cursor-pos' / `ghostel--cursor-char-pos' are stale until
the timer fires.  `sync-render' must close the gap by forcing the
deferred redraw before returning, otherwise the next operator
(e.g. `i' after `cc') reads stale cursor state and computes a
wrong arrow delta."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let* ((redraw-calls 0)
           ;; Pretend the filter deferred a redraw to its timer.
           (fake-timer (run-with-timer 999 nil #'ignore))
           (ghostel--redraw-timer fake-timer)
           (ghostel--pending-output (list "x"))
           (ghostel--process 'fake-proc))
      (unwind-protect
          (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                    ((symbol-function 'accept-process-output)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--delayed-redraw)
                     (lambda (_buf) (cl-incf redraw-calls))))
            (evil-ghostel--sync-render)
            (should (= 1 redraw-calls))
            (should (null ghostel--redraw-timer)))
        (when (timerp fake-timer) (cancel-timer fake-timer))))))

(ert-deftest evil-ghostel-test-sync-render-no-op-when-nothing-deferred ()
  "`sync-render' does NOT force a redraw when the filter handled the echo.
Small interactive echoes are drawn synchronously inside
`ghostel--filter''s immediate-redraw branch, which clears both
`ghostel--pending-output' and `ghostel--redraw-timer'.  In that
state `sync-render' must not call `ghostel--delayed-redraw' a
second time — the cursor state is already current."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let ((redraw-calls 0)
          (ghostel--redraw-timer nil)
          (ghostel--pending-output nil)
          (ghostel--process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--delayed-redraw)
                 (lambda (_buf) (cl-incf redraw-calls))))
        (evil-ghostel--sync-render)
        (should (zerop redraw-calls))))))

(ert-deftest evil-ghostel-test-sync-render-drain-loop-respects-cap ()
  "`sync-render' caps the drain loop at `*-max-iterations'.
A runaway shell that returns non-nil from every
`accept-process-output' call must not hang the caller.  The cap
bounds total wait at ~max-iter × 50 ms."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let ((accept-calls 0)
          (evil-ghostel-sync-render-max-iterations 5)
          (ghostel--redraw-timer nil)
          (ghostel--pending-output nil)
          (ghostel--process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _) (cl-incf accept-calls) t))
                ((symbol-function 'ghostel--delayed-redraw) #'ignore))
        (evil-ghostel--sync-render)
        ;; Loop exits via the iteration cap, not via accept returning nil.
        (should (= 5 accept-calls))))))

(ert-deftest evil-ghostel-test-delete-input-region-sends-backspaces ()
  "`evil-ghostel-delete-input-region' sends one backspace per meaningful char."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (push key keys-sent))))
        (evil-ghostel-delete-input-region 3 ghostel--cursor-char-pos))
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal))))))

(ert-deftest evil-ghostel-test-replace-input-region-deletes-then-pastes ()
  "`evil-ghostel-replace-input-region' first deletes, then pastes new text."
  (evil-ghostel-test--with-input-fixture "$ " "abc"
    (let ((pasted nil)
          (keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent)))
                ((symbol-function 'ghostel--paste-text)
                 (lambda (text) (setq pasted text))))
        (evil-ghostel-replace-input-region 3 ghostel--cursor-char-pos "XYZ"))
      (should (= 3 (cl-count "backspace" keys-sent :test #'equal)))
      (should (equal "XYZ" pasted)))))

;; -----------------------------------------------------------------------
;; Test: evil-delete advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-sends-backspace-keys ()
  "`evil-ghostel-delete' sends backspace keys via the PTY."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel-goto-input-position) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         ;; Delete 5 chars (simulates dw on "hello")
         (evil-ghostel-delete 1 6 'inclusive nil nil))
       (should (= 5 bs-count))))))

(ert-deftest evil-ghostel-test-delete-line-same-row-uses-backspaces ()
  "`dd' on the cursor's own line routes through `delete-input-region'.
vterm-collection's shape: same code path as every other delete.
The clamped range is [input-start, row-end], so the backspace count
equals the typed input length (5 for `hello'); no readline C-e/C-u
shortcut is invoked."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     (insert "hello"))
   (setq-local ghostel--cursor-pos '(7 . 0))
   (setq-local ghostel--cursor-char-pos 8)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent)))
                 ((symbol-function 'evil-ghostel--sync-render) #'ignore))
         (evil-ghostel-delete (line-beginning-position) (line-end-position)
                              'line nil nil))
       ;; 5 backspaces — one per char of "hello".
       (should (= 5 (cl-count '("backspace" . "") keys-sent :test #'equal)))
       ;; No readline shortcuts.
       (should-not (cl-find '("e" . "ctrl") keys-sent :test #'equal))
       (should-not (cl-find '("u" . "ctrl") keys-sent :test #'equal))))))

(ert-deftest evil-ghostel-test-change-line-same-row-uses-backspaces ()
  "`cc' on the cursor's own line routes through `delete-input-region'
then enters insert state.  Same vterm-style shape as `dd'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     (insert "hello"))
   (setq-local ghostel--cursor-pos '(7 . 0))
   (setq-local ghostel--cursor-char-pos 8)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent)))
                 ((symbol-function 'evil-ghostel--sync-render) #'ignore)
                 ((symbol-function 'evil-ghostel--insert-state-entry) #'ignore))
         (evil-ghostel-change (line-beginning-position) (line-end-position)
                              'line nil nil))
       (should (= 5 (cl-count '("backspace" . "") keys-sent :test #'equal)))
       (should-not (cl-find '("e" . "ctrl") keys-sent :test #'equal))
       (should-not (cl-find '("u" . "ctrl") keys-sent :test #'equal))
       ;; Bug fix: point lands at input-start (pos 3, just after "$ "),
       ;; NOT at column 0 of the buffer line.
       (should (= 3 (point)))
       (should (eq evil-state 'insert))))))

(ert-deftest evil-ghostel-test-delete-line-multiline-syncs-cursor ()
  "Regression for #218: line-type delete syncs terminal cursor first.
With a multi-line input where the terminal cursor sits on the last
line, pressing `dd' on the first line moves the terminal cursor up
to that line before deleting — otherwise Ctrl+U / shortcut-style
deletion would target the line the cursor sat on (the last input
line)."
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
         (evil-ghostel-delete 1 10 'line nil nil))
       ;; Sync from row 2 to row 1 (end of deleted region = bol of line 2)
       (should (= 1 (cl-count '("up" . "") keys-sent :test #'equal)))
       ;; Sync from col 10 to col 0
       (should (= 10 (cl-count '("left" . "") keys-sent :test #'equal)))
       ;; "line one\n" = 9 chars deleted via backspace
       (should (= 9 (cl-count '("backspace" . "") keys-sent :test #'equal)))
       (should-not (cl-find '("u" . "ctrl") keys-sent :test #'equal))))))

(ert-deftest evil-ghostel-test-delete-line-strips-render-padding ()
  "Regression for #218: multi-line `dd' does not backspace TUI box-padding.
TUIs that draw a fixed-width input box (e.g. prompt_toolkit) write
spaces past the user's input out to the box border; those land in
the Emacs buffer but are not characters in the TUI's input model.
Backspace count equals trimmed line length + newline.

Forces the multi-line backspace path by placing the terminal
cursor on a different row than point."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; "AAA" + 77 box-padding spaces + newline + "BBB" + 77 box-padding spaces.
   (insert (concat "AAA" (make-string 77 ?\s) "\n"
                   "BBB" (make-string 77 ?\s)))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Terminal cursor on row 1 (BBB); point will be on row 0 (AAA).
             (ghostel--cursor-pos '(0 . 1))
             ((symbol-function 'evil-ghostel-goto-input-position) #'ignore))
     (evil-normal-state)
     (goto-char (point-min))
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         ;; Line 1 spans bol..bol-of-line-2 (81 chars including newline).
         (evil-ghostel-delete (point-min) (line-beginning-position 2)
                              'line nil nil))
       ;; Trimmed: "AAA\n" = 4 backspaces, not 81.
       (should (= 4 bs-count))))))

(ert-deftest evil-ghostel-test-delete-char ()
  "`evil-ghostel-delete-char' (x) routes through PTY and stays in normal."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel-goto-input-position) #'ignore)
             ((symbol-function 'ghostel--send-encoded) #'ignore))
     (evil-normal-state)
     (evil-ghostel-delete-char 1 2 'exclusive nil)
     (should (eq evil-state 'normal)))))

;; -----------------------------------------------------------------------
;; Test: evil-change advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-change-deletes-and-inserts ()
  "`evil-ghostel-change' deletes via PTY and enters insert state."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel-goto-input-position) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         (evil-ghostel-change 1 6 'inclusive nil nil))
       (should (= 5 bs-count))
       (should (eq evil-state 'insert))))))

(ert-deftest evil-ghostel-test-change-whole-line ()
  "`evil-ghostel-substitute-line' (cc/S) runs without error."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'ghostel--send-encoded) #'ignore))
     (evil-normal-state)
     (evil-ghostel-substitute-line 1 12 nil nil)
     (should (eq evil-state 'insert)))))

;; -----------------------------------------------------------------------
;; Test: evil-replace advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-replace-deletes-and-inserts ()
  "`evil-ghostel-replace' deletes then inserts replacement text."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel-goto-input-position) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0)
           (pasted nil))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count))))
                 ((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text))))
         (evil-ghostel-replace 1 4 'inclusive ?X))
       (should (= 3 bs-count))
       (should (equal "XXX" pasted))))))

(ert-deftest evil-ghostel-test-replace-counts-match-on-trailing-space ()
  "Regression: paste count and delete count agree on multi-line ranges.
Both `evil-ghostel-delete-input-region' and the paste in
`evil-ghostel-replace' use `evil-ghostel--meaningful-input-length' on
the same substring, so the values agree even when trailing
whitespace handling differs (multi-line ranges strip per-line
padding; single-line ranges don't)."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; Multi-line range with TUI-style padding on the first row.
   ;; meaningful-input-length strips per-line padding → 4 chars: "AB\nC".
   (insert "AB   \nC")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel-goto-input-position) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0)
           (pasted nil))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count))))
                 ((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text))))
         (evil-ghostel-replace 1 8 'inclusive ?X))
       ;; Pre-fix: bs-count read meaningful-length (4) but pasted used
       ;; raw substring length (7), leaving a stray "XXX" on screen.
       (should (= 4 bs-count))
       (should (equal "XXXX" pasted))))))

;; -----------------------------------------------------------------------
;; Test: evil-paste advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-paste-after ()
  "`evil-ghostel-paste-after' pastes the kill ring's head via PTY."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (kill-new "world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0))
             ((symbol-function 'evil-ghostel-goto-input-position) #'ignore))
     (evil-normal-state)
     (let ((pasted nil))
       (cl-letf (((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text)))
                 ((symbol-function 'ghostel--send-encoded) #'ignore))
         (evil-ghostel-paste-after 1))
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

;; (Removed: evil-ghostel-test-ctrl-passthrough-invalidates-shadow.
;; The shadow-cursor model is gone — the new architecture reads
;; `ghostel--cursor-pos' directly each time.)

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
        (cl-letf (((symbol-function 'evil-ghostel-goto-input-position)
                   (lambda (&rest _) (setq sync-called t)))
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
       (cl-letf (((symbol-function 'evil-ghostel-goto-input-position)
                  (lambda (&rest _) (setq sync-called t)))
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
        (evil-ghostel-insert-line))
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
        (evil-ghostel-append-line))
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
  "`evil-ghostel-undo' sends Ctrl+_ to the terminal."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(0 . 0)))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-ghostel-undo 3))
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
     (evil-ghostel-beginning-of-line)
     ;; Lands at col 2 (after "$ "), not col 0.
     (should (= 2 (current-column)))
     (goto-char (point-max))
     (evil-ghostel-first-non-blank)
     (should (= 2 (current-column))))))

(ert-deftest evil-ghostel-test-beginning-of-line-falls-through-no-prompt ()
  "On rows without a prompt property `0' / `^' keep their default
column-0 / first-non-blank behaviour — scrollback navigation must
not be hijacked.

`ghostel-beginning-of-input-or-line' itself handles the fall-through
\(it calls `move-beginning-of-line' when no prompt prop / line-mode
marker is in play), so the new motion still does the right thing
even when active-p is true."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "  output line")  ; no ghostel-prompt property anywhere
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (evil-normal-state)
     (goto-char (point-max))
     (evil-ghostel-beginning-of-line)
     (should (= 0 (current-column))))))

;; (Removed: evil-ghostel-test-shadow-cursor-tracks-cursor-to-point and
;; evil-ghostel-test-shadow-cursor-tracks-delete-region.  The shadow-cursor
;; model is gone — the new operators read `ghostel--cursor-pos' directly
;; each time and don't rely on a queued-key projection.  See the
;; "Shadow-cursor: drop" analysis in plans/evil-rewrite-plan.md.)

;; -----------------------------------------------------------------------
;; Test: cw doesn't emit redundant left arrows after delete
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-word-with-trailing-space ()
  "Regression: `dw' over `\"word \"' sends 5 backspaces, not 4.
Trailing whitespace in single-line ranges is real user content.
\(With the old per-line stripping heuristic applied to single-line
ranges, `dw' over `\"word word word\" + ESC bb' would send only 4
backspaces — leaving a stray `w' behind.)"
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
         (evil-ghostel-delete 6 11 'exclusive nil nil))
       (should (= 5 bs-count))))))

(ert-deftest evil-ghostel-test-forward-word-stops-at-input-end ()
  "`evil-ghostel-forward-word-begin' clamps point to the input row's end.
Vanilla `evil-forward-word-begin' would scan into the blank renderer
rows below the prompt; the wrapper clamps point to
`evil-ghostel--cursor-row-end-point' so `w' from the last input word stays
on the cursor row."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "% " 'ghostel-prompt t))
     (insert "word word")
     (insert "\n\n\n\n"))
   (goto-char 8) ; start of last "word" in input
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(7 . 0))
             (ghostel--cursor-char-pos 8))
     (evil-normal-state)
     (evil-ghostel-forward-word-begin 1)
     ;; Clamped to row-end (past "word" on row 0), not point-of-next-line.
     (should (= 1 (line-number-at-pos))))))

(ert-deftest evil-ghostel-test-forward-word-falls-through-off-cursor-row ()
  "Off the cursor row, the wrapper delegates to `evil-forward-word-begin'.
Scrollback navigation must keep working — clamping only kicks in on
the cursor's row where empty cells past end-of-input are not real
content."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert "hello world\n")
     (insert (propertize "% " 'ghostel-prompt t))
     (insert "cmd"))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Cursor on row 1; we'll move point onto row 0 (scrollback).
             (ghostel--cursor-pos '(5 . 1))
             (ghostel--cursor-char-pos 18))
     (evil-normal-state)
     (goto-char (point-min)) ; point on row 0 (scrollback row)
     (evil-ghostel-forward-word-begin 1)
     ;; Vanilla forward-word-begin from "hello" lands on "world" (col 6).
     (should (= 6 (current-column))))))

(ert-deftest evil-ghostel-test-delete-word-on-last-word-clamps-overshoot ()
  "Regression: `dw' on the last input word clamps motion overshoot.
With input `\"word word\"' and cursor mid-input, the motion `w'
walks off the cursor row (no next word on this line) so END
lands on a buffer row below the cursor.  The operator-level
clamp trims END to `evil-ghostel--cursor-row-end-point' so backspaces
target only the typed characters, not the renderer-painted
padding/blanks past end-of-input."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; Simulate the post-bbcw state: prompt-prefixed input "word word"
   ;; with cursor mid-input and several blank renderer rows below.
   (let ((inhibit-read-only t))
     (insert (propertize "% " 'ghostel-prompt t))
     (insert "word word")
     (insert "\n\n\n\n"))  ; blank renderer rows below row 0
   (goto-char 8)  ; col 5 in input = start of last "word"
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(7 . 0))
             (ghostel--cursor-char-pos 8))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace") (cl-incf bs-count)))))
         ;; Motion `w' from pos 8 walks past end-of-input to a blank
         ;; row below — simulate by passing END beyond the cursor row.
         (evil-ghostel-delete 8 13 'exclusive nil nil))
       ;; Clamp trims END to row-end (pos 12, after "word"), so the
       ;; delete sends 4 backspaces for "word", not 5+ for "word\n..."
       (should (= 4 bs-count))))))

(ert-deftest evil-ghostel-test-change-partial-no-post-delete-sync ()
  "After `cw' (count > 0) the post-delete `evil-ghostel-insert' is idempotent.
Once the shell has echoed our 6 LEFT + 5 BACKSPACE the live cursor
sits at the same buffer position as point — `evil-ghostel-insert' →
`goto-input-position' computes dx=dy=0 and sends nothing further.
The mock updates `ghostel--cursor-pos' from the keys we emit to
mirror that drain behaviour."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "word1 word2 word3")
   (goto-char (point-min))
   (move-to-column 6)
   (setq ghostel--cursor-pos '(17 . 0))
   (setq ghostel--cursor-char-pos (+ (point-min) 17))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'evil-ghostel--sync-render)
              (lambda (&rest _) nil))) ; we already update pos inline
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (push key keys-sent)
                    ;; Simulate the shell echo updating cursor-pos.
                    (pcase key
                      ((or "left" "backspace")
                       (let ((col (car ghostel--cursor-pos))
                             (row (cdr ghostel--cursor-pos)))
                         (setq ghostel--cursor-pos (cons (max 0 (1- col)) row))
                         (when ghostel--cursor-char-pos
                           (setq ghostel--cursor-char-pos
                                 (max (point-min)
                                      (1- ghostel--cursor-char-pos))))))
                      ("right"
                       (let ((col (car ghostel--cursor-pos))
                             (row (cdr ghostel--cursor-pos)))
                         (setq ghostel--cursor-pos (cons (1+ col) row))
                         (when ghostel--cursor-char-pos
                           (setq ghostel--cursor-char-pos
                                 (1+ ghostel--cursor-char-pos)))))))))
         (evil-ghostel-change 7 12 'exclusive nil nil))
       (let* ((seq (nreverse keys-sent))
              (left-count (cl-count "left" seq :test #'equal))
              (right-count (cl-count "right" seq :test #'equal))
              (bs-count (cl-count "backspace" seq :test #'equal)))
         ;; 6 LEFTs to drive cursor to END (col 17 → 11) then 5 backspaces.
         ;; The post-delete `evil-ghostel-insert' is a no-op once cursor-pos
         ;; has caught up — no extra LEFTs, no spurious RIGHT.
         (should (= 6 left-count))
         (should (= 5 bs-count))
         (should (zerop right-count)))))))

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
                 ((symbol-function 'evil-ghostel-goto-input-position)
                  (lambda (&rest _) (setq sync-called t))))
         (evil-ghostel--insert-state-entry))
       ;; Same viewport row → goto-input-position, NOT reset-cursor-point.
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
;; Test: forward-char / backward-char / end-of-line clamps
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-forward-char-clamps-at-row-end ()
  "`evil-ghostel-forward-char' stops at `evil-ghostel--cursor-row-end-point'
on the cursor row.  Trailing renderer cells (stale glyphs from prior
input, RPROMPT padding) sit between cursor and physical EOL; vanilla
`evil-forward-char' walks through them, the wrapper clamps it back."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     ;; "cmd" + 10 spaces of trailing renderer padding, then \n.
     (insert "cmd          \n"))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Live cursor at end of "cmd" (col 5, pos 6).
             (ghostel--cursor-pos '(5 . 0))
             (ghostel--cursor-char-pos 6))
     (evil-normal-state)
     (goto-char 3) ; start of "cmd"
     ;; Try to walk 8 chars right — vanilla would land in trailing padding.
     (evil-ghostel-forward-char 8)
     ;; Clamped to end of "cmd" on the cursor row (pos 6).
     (should (= 6 (point))))))

(ert-deftest evil-ghostel-test-forward-char-falls-through-off-cursor-row ()
  "Off the cursor row, `evil-ghostel-forward-char' delegates to vanilla.
Scrollback navigation keeps working — clamping only kicks in on
the cursor's row."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert "hello world\n")
     (insert (propertize "$ " 'ghostel-prompt t))
     (insert "cmd"))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Cursor on row 1; we'll move point onto row 0 (scrollback).
             (ghostel--cursor-pos '(5 . 1))
             (ghostel--cursor-char-pos 18))
     (evil-normal-state)
     (goto-char (point-min)) ; row 0 (scrollback)
     (evil-ghostel-forward-char 5)
     ;; Vanilla forward-char advances 5 columns.
     (should (= 5 (current-column))))))

(ert-deftest evil-ghostel-test-backward-char-clamps-at-input-start ()
  "`evil-ghostel-backward-char' stops at `ghostel-input-start-point' on
the cursor row, so `h' can't walk into the prompt prefix."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     (insert "cmd"))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(5 . 0))
             (ghostel--cursor-char-pos 6))
     (evil-normal-state)
     (goto-char 6) ; end of "cmd"
     (evil-ghostel-backward-char 100)
     ;; Clamped to input-start (just past "$ ").
     (should (= 3 (point))))))

(ert-deftest evil-ghostel-test-end-of-line-clamps-at-row-end ()
  "`evil-ghostel-end-of-line' (`$') stops at the last input char, not
on trailing renderer cells.  With `(insert \"cmd   \")' the buffer's
physical end-of-line is at column 5 but only `cmd' is input."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     (insert "cmd   "))  ; trailing renderer padding
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(5 . 0))
             (ghostel--cursor-char-pos 6))
     (evil-normal-state)
     (goto-char 3) ; start of "cmd"
     (evil-ghostel-end-of-line 1)
     ;; Clamped to end-of-input (after "cmd"), not after the trailing spaces.
     (should (= 6 (point))))))

(ert-deftest evil-ghostel-test-end-of-line-falls-through-off-cursor-row ()
  "Off the cursor row, `$' falls through to vanilla `evil-end-of-line'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert "long scrollback line\n")
     (insert (propertize "$ " 'ghostel-prompt t)))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(2 . 1))
             (ghostel--cursor-char-pos 24))
     (evil-normal-state)
     (goto-char (point-min)) ; row 0
     (evil-ghostel-end-of-line 1)
     ;; Vanilla end-of-line reaches the actual buffer-line end on row 0.
     ;; In normal state evil places point one column before the \n, so
     ;; column == length - 1 = 19 for "long scrollback line".
     (should (= 1 (line-number-at-pos)))
     (should (= (1- (length "long scrollback line")) (current-column))))))

;; -----------------------------------------------------------------------
;; Test: next-line clamp (j cannot go below cursor row)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-next-line-clamps-at-cursor-row ()
  "`evil-ghostel-next-line' (`j') doesn't move below the cursor's row.
Prevents stranding the user on empty renderer rows below the live
prompt."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (setq-local ghostel--term-rows 5)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     (insert "cmd")
     (insert "\n\n\n\n"))  ; blank renderer rows below row 0
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(5 . 0)))
     (evil-normal-state)
     (goto-char (point-min))
     (evil-ghostel-next-line 10)
     ;; Clamped to the cursor's buffer line (line 1).
     (should (= 1 (line-number-at-pos))))))

(ert-deftest evil-ghostel-test-next-line-falls-through-outside-semi-char ()
  "Outside semi-char `evil-ghostel-next-line' delegates to vanilla."
  (evil-ghostel-test--with-evil-buffer
   ;; ghostel--term nil → evil-ghostel--active-p returns nil.
   (let ((inhibit-read-only t))
     (insert "a\nb\nc\nd\ne\n"))
   (evil-normal-state)
   (goto-char (point-min))
   (evil-ghostel-next-line 2)
   (should (= 3 (line-number-at-pos)))))

;; -----------------------------------------------------------------------
;; Test: G (goto-cursor) maps to live terminal cursor
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-goto-cursor-resets-to-cursor ()
  "`evil-ghostel-goto-cursor' (`G') invokes `reset-cursor-point' in
semi-char.  Replaces `evil-goto-line' so `G' lands on the live
prompt instead of the (post-cursor) end of buffer."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (let ((reset-called nil))
       (cl-letf (((symbol-function 'evil-ghostel--reset-cursor-point)
                  (lambda () (setq reset-called t))))
         (evil-ghostel-goto-cursor))
       (should reset-called)))))

(ert-deftest evil-ghostel-test-goto-cursor-falls-through-outside-semi-char ()
  "`G' falls through to `evil-goto-line' when not in semi-char."
  (evil-ghostel-test--with-evil-buffer
   ;; ghostel--term nil → not active.
   (let ((goto-called nil))
     (cl-letf (((symbol-function 'evil-goto-line)
                ;; `call-interactively' requires `interactive', so the
                ;; mock must declare it even though we ignore arguments.
                (lambda (&rest _) (interactive) (setq goto-called t))))
       (evil-ghostel-goto-cursor))
     (should goto-called))))

;; -----------------------------------------------------------------------
;; Test: append vanilla-fallthrough clamps to row-end
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-append-before-cursor-clamps-to-row-end ()
  "Regression: `a' before the cursor must clamp the `forward-char'
landing position to `evil-ghostel--cursor-row-end-point'.  Without
the clamp `forward-char' can walk past end-of-input onto trailing
renderer cells (RPROMPT, autosuggest, stale glyphs) and the visual
cursor jumps to the right edge of the window."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     ;; "cmd" + render padding to column 20 (e.g. RPROMPT padding).
     (insert "cmd")
     (insert "                 "))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ;; Live cursor at column 5 (just after "cmd").  Point is
             ;; one to the left of the cursor — vanilla fall-through.
             (ghostel--cursor-pos '(5 . 0))
             (ghostel--cursor-char-pos 6))
     (evil-normal-state)
     (goto-char 5) ; on "d", before cursor
     (evil-ghostel-append)
     ;; After append: forward-char would reach pos 7, but row-end is 6
     ;; (after "cmd").  Clamped to 6.
     (should (= 6 (point))))))

;; -----------------------------------------------------------------------
;; Test: <delete> insert-state sends PTY key
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-key-sends-pty ()
  "`<delete>' in insert state sends the `delete' PTY key in semi-char."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _) (push key keys-sent))))
         (evil-ghostel--passthrough-delete))
       (should (equal '("delete") keys-sent))))))

(ert-deftest evil-ghostel-test-delete-key-bound-in-insert-state ()
  "`<delete>' is bound to `evil-ghostel--passthrough-delete' in insert state."
  (should (eq #'evil-ghostel--passthrough-delete
              (lookup-key (evil-get-auxiliary-keymap
                           evil-ghostel-mode-map 'insert)
                          (kbd "<delete>")))))

;; -----------------------------------------------------------------------
;; Test: prompt-nav bindings and extended Ctrl passthrough
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-prompt-nav-bound-in-normal ()
  "`[[' and `]]' are bound to ghostel's prompt-nav commands."
  (should (eq #'ghostel-previous-prompt
              (lookup-key (evil-get-auxiliary-keymap
                           evil-ghostel-mode-map 'normal)
                          (kbd "[["))))
  (should (eq #'ghostel-next-prompt
              (lookup-key (evil-get-auxiliary-keymap
                           evil-ghostel-mode-map 'normal)
                          (kbd "]]")))))

(ert-deftest evil-ghostel-test-ctrl-passthrough-includes-vterm-set ()
  "Passthrough list contains every Ctrl key vterm passes through
except `z' (kept for `evil-emacs-state' escape hatch)."
  (dolist (k '("a" "b" "d" "e" "f" "k" "l" "n" "o" "p"
               "q" "r" "s" "t" "u" "v" "w" "y"))
    (should (member k evil-ghostel--ctrl-passthrough-keys)))
  (should-not (member "z" evil-ghostel--ctrl-passthrough-keys)))

;; -----------------------------------------------------------------------
;; Runner
;; -----------------------------------------------------------------------

(defconst evil-ghostel-test--elisp-tests
  '(evil-ghostel-test-mode-activation
    evil-ghostel-test-mode-deactivation
    evil-ghostel-test-advice-survives-disable-in-other-buffer
    evil-ghostel-test-escape-stay
    evil-ghostel-test-insert-drives-shell-cursor
    evil-ghostel-test-append-drives-shell-cursor
    evil-ghostel-test-append-at-cursor-does-not-advance
    evil-ghostel-test-append-after-cursor-moved-mid-input-advances
    evil-ghostel-test-insert-on-rprompt-clamps-to-row-end
    evil-ghostel-test-append-before-cursor-uses-vanilla
    evil-ghostel-test-insert-line-sends-arrows-to-input-start
    evil-ghostel-test-append-line-sends-arrows-to-row-end
    evil-ghostel-test-insert-line-pins-point-at-input-start
    evil-ghostel-test-append-line-pins-point-at-row-end
    evil-ghostel-test-change-eol-snaps-point-to-cursor
    evil-ghostel-test-insert-state-entry-no-op-outside-ghostel
    evil-ghostel-test-meaningful-length-strips-trailing
    evil-ghostel-test-cursor-row-end-point-returns-eol
    evil-ghostel-test-cursor-row-end-point-respects-input-property
    evil-ghostel-test-cursor-row-end-point-clamps-at-right-prompt-gap
    evil-ghostel-test-cursor-row-end-point-uses-first-input-region
    evil-ghostel-test-cursor-row-end-point-tight-gap-keeps-input
    evil-ghostel-test-end-of-line-clamps-past-right-prompt
    evil-ghostel-test-point-in-input-p-true-between-prompt-and-eol
    evil-ghostel-test-point-in-input-p-false-on-prompt-char
    evil-ghostel-test-clamp-to-input-narrows-on-cursor-row
    evil-ghostel-test-clamp-to-input-trims-end-past-cursor
    evil-ghostel-test-clamp-to-input-passes-through-off-row
    evil-ghostel-test-goto-input-position-sends-arrows-unit
    evil-ghostel-test-goto-input-position-no-op-at-target
    evil-ghostel-test-sync-render-forces-deferred-redraw
    evil-ghostel-test-sync-render-no-op-when-nothing-deferred
    evil-ghostel-test-sync-render-drain-loop-respects-cap
    evil-ghostel-test-delete-input-region-sends-backspaces
    evil-ghostel-test-replace-input-region-deletes-then-pastes
    evil-ghostel-test-delete-sends-backspace-keys
    evil-ghostel-test-delete-line-same-row-uses-backspaces
    evil-ghostel-test-change-line-same-row-uses-backspaces
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
    evil-ghostel-test-delete-word-with-trailing-space
    evil-ghostel-test-delete-word-on-last-word-clamps-overshoot
    evil-ghostel-test-forward-word-stops-at-input-end
    evil-ghostel-test-forward-word-falls-through-off-cursor-row
    evil-ghostel-test-change-partial-no-post-delete-sync
    evil-ghostel-test-insert-entry-same-viewport-row-with-scrollback
    evil-ghostel-test-forward-char-clamps-at-row-end
    evil-ghostel-test-forward-char-falls-through-off-cursor-row
    evil-ghostel-test-backward-char-clamps-at-input-start
    evil-ghostel-test-end-of-line-clamps-at-row-end
    evil-ghostel-test-end-of-line-falls-through-off-cursor-row
    evil-ghostel-test-next-line-clamps-at-cursor-row
    evil-ghostel-test-next-line-falls-through-outside-semi-char
    evil-ghostel-test-goto-cursor-resets-to-cursor
    evil-ghostel-test-goto-cursor-falls-through-outside-semi-char
    evil-ghostel-test-append-before-cursor-clamps-to-row-end
    evil-ghostel-test-delete-key-sends-pty
    evil-ghostel-test-delete-key-bound-in-insert-state
    evil-ghostel-test-prompt-nav-bound-in-normal
    evil-ghostel-test-ctrl-passthrough-includes-vterm-set)
  "Tests that require only Elisp (no native module).")

(defun evil-ghostel-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit
   `(member ,@evil-ghostel-test--elisp-tests)))

(defun evil-ghostel-test-run ()
  "Run all evil-ghostel tests."
  (ert-run-tests-batch-and-exit "^evil-ghostel-test-"))

;;; evil-ghostel-test.el ends here
