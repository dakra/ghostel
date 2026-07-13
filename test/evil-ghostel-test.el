;;; evil-ghostel-test.el --- Tests for evil-ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L ~/.emacs.d/lib/evil -L . \
;;     -l ert -l test/evil-ghostel-test.el -f evil-ghostel-test-run

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'evil)
(require 'ghostel)
(require 'evil-ghostel)

;; -----------------------------------------------------------------------
;; Helper: set up a ghostel buffer with evil
;; -----------------------------------------------------------------------

(defun evil-ghostel-test--insert (&rest args)
  "Insert ARGS as renderer-owned test setup text."
  (let ((inhibit-read-only t))
    (apply #'insert args)))

(defmacro evil-ghostel-test--with-buffer (rows cols text &rest body)
  "Create a ghostel buffer with ROWS x COLS, feed TEXT, render, then run BODY.
The buffer has evil-mode and evil-ghostel-mode active.
The variable `term' is bound to the terminal handle.
Requires the native module; without it the test is skipped
(e.g. CI's elisp-only `test-evil' job)."
  (declare (indent 3) (debug t))
  `(progn
     (skip-unless (fboundp 'ghostel--new))
     (let* ((ghostel-max-scrollback 100)
            (buf (ghostel--create " *evil-ghostel-test*" nil ,rows ,cols))
            (term (buffer-local-value 'ghostel--term buf)))
       (unwind-protect
		   (with-selected-window (display-buffer buf)
			 (with-current-buffer buf
               (ghostel--write-vt term ,text)
               (evil-local-mode 1)
               (evil-ghostel-mode 1)
               (let ((inhibit-read-only t))
				 (ghostel--redraw term t))
               (cl-macrolet ((insert (&rest args)
                               `(evil-ghostel-test--insert ,@args)))
				 ,@body)))
         (when (buffer-live-p buf)
           (kill-buffer buf))))))

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
     (cl-macrolet ((insert (&rest args)
                     `(evil-ghostel-test--insert ,@args)))
       ,@body)))

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
   (should (memq 'evil-ghostel--anchor-inhibit
                 ghostel-inhibit-anchor-functions))
   (should (advice--p (advice--symbol-function 'ghostel--redraw)))
   (should (advice--p (advice--symbol-function 'ghostel--apply-cursor-style)))
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

(ert-deftest evil-ghostel-test-visual-inhibits-mark-copy-mode ()
  "Entering evil visual must not flip ghostel into copy mode.
`ghostel-mode' wires `ghostel--mark-activated' onto `activate-mark-hook',
which (for vanilla users) switches semi-char -> copy mode when the mark
activates.  Evil's `v' activates the mark, so without suppression copy mode
would take over before Evil's terminal-aware visual operators run.
`evil-ghostel-mode' sets `ghostel-mark-activation-input-mode' to nil
buffer-locally so that chain yields to evil's own selection model."
  (evil-ghostel-test--with-evil-buffer
   ;; Preconditions the major mode established (mirrors a live buffer):
   (should (eq ghostel--input-mode 'semi-char))
   (should (memq #'ghostel--mark-activated activate-mark-hook))
   ;; The minor mode opted the buffer out, buffer-locally:
   (should (local-variable-p 'ghostel-mark-activation-input-mode))
   (should (null ghostel-mark-activation-input-mode))
   (let (copied)
     (cl-letf (((symbol-function 'ghostel-copy-mode)
                (lambda (&rest _) (setq copied t))))
       ;; Opted out -> activating the mark is a no-op, mode stays semi-char.
       (ghostel--mark-activated)
       (should-not copied)
       ;; With the default knob restored, the hook switches modes.
       (let ((ghostel-mark-activation-input-mode 'copy))
         (ghostel--mark-activated)
         (should copied))))))

(ert-deftest evil-ghostel-test-disable-restores-mark-activation ()
  "Disabling `evil-ghostel-mode' restores ghostel's mark-activation behavior."
  (evil-ghostel-test--with-evil-buffer
   (should (local-variable-p 'ghostel-mark-activation-input-mode))
   (evil-ghostel-mode -1)
   (should-not (local-variable-p 'ghostel-mark-activation-input-mode))))

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
                                   'ghostel--apply-cursor-style))
          ;; Disable in B — no buffers left, advice removed.
          (with-current-buffer b (evil-ghostel-mode -1))
          (should-not (advice-member-p #'evil-ghostel--around-redraw
                                       'ghostel--redraw))
          (should-not (advice-member-p #'evil-ghostel--override-cursor-style
                                       'ghostel--apply-cursor-style)))
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
  "Enabling `evil-ghostel-mode' must not clobber the initial-state setting."
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
;; Test: around-redraw point and visual-marker policy
;; -----------------------------------------------------------------------

(defmacro evil-ghostel-test--simulating-redraw (&rest body)
  "Run BODY with `ghostel--redraw' replaced by a buffer-rewriter.
The mock erases and reinserts the same text so these tests exercise
`evil-ghostel--around-redraw' independent of renderer marker handling."
  `(cl-letf (((symbol-function 'ghostel--redraw)
              (lambda (_term &optional _full _force-sync)
                (let ((text (buffer-string))
                      (inhibit-read-only t))
                  (erase-buffer)
                  (insert text)
                  t)))
             ((symbol-function 'ghostel--mode-enabled)
              (lambda (_term _mode) nil)))
     ,@body))

(ert-deftest evil-ghostel-test-around-redraw-does-not-restore-normal-point ()
  "Normal-state point is left where the renderer placed it."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\nthree\nfour\nfive\n")
   (evil-normal-state)
   (goto-char (point-min))
   (search-forward "two")
   (let ((renderer-point (save-excursion
                           (goto-char (point-min))
                           (search-forward "four"))))
     (cl-letf (((symbol-function 'ghostel--redraw)
                (lambda (_term &optional _full _force-sync)
                  (goto-char renderer-point)
                  t))
               ((symbol-function 'ghostel--mode-enabled)
                (lambda (_term _mode) nil)))
      (evil-ghostel--around-redraw (symbol-function 'ghostel--redraw) nil))
     (should (= renderer-point (point))))))

(defun evil-ghostel-test--streamed-output-redraw ()
  "Run `evil-ghostel--around-redraw' with a mock render streaming output.
The mock appends rows below, advances the cursor to the new prompt at
`point-max', and leaves point untouched, like the renderer."
  (cl-letf (((symbol-function 'ghostel--redraw)
             (lambda (_term &optional _full _force-sync)
               (save-excursion
                 (goto-char (point-max))
                 (evil-ghostel-test--insert "\nout-1\nout-2\n$ "))
               (setq ghostel--cursor-char-pos (point-max)
                     ghostel--cursor-pos '(2 . 5))))
            ((symbol-function 'ghostel--mode-enabled)
             (lambda (_term _mode) nil)))
    (evil-ghostel--around-redraw (symbol-function 'ghostel--redraw) 'fake)))

(ert-deftest evil-ghostel-test-around-redraw-tracks-parked-normal-point ()
  "Normal-state point parked at the cursor follows it across a redraw.
Output that advances the cursor must not detach a point the user
never moved (issue #228)."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\n$ ")
   (setq-local ghostel--term 'fake
               ghostel--cursor-char-pos (point-max)
               ghostel--cursor-pos '(2 . 2))
   (evil-normal-state)
   (goto-char ghostel--cursor-char-pos)
   (evil-ghostel-test--streamed-output-redraw)
   (should (= ghostel--cursor-char-pos (point)))
   (should (= 6 (line-number-at-pos)))))

(ert-deftest evil-ghostel-test-around-redraw-keeps-roamed-normal-point ()
  "Normal-state point off the cursor stays put across an output redraw
\(issue #454)."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\n$ ")
   (setq-local ghostel--term 'fake
               ghostel--cursor-char-pos (point-max)
               ghostel--cursor-pos '(2 . 2))
   (evil-normal-state)
   (goto-char (point-min))
   (evil-ghostel-test--streamed-output-redraw)
   (should (= (point-min) (point)))))

(ert-deftest evil-ghostel-test-around-redraw-follows-cursor-row-keeps-column ()
  "Normal-state point elsewhere on the cursor's row follows it row-wise.
Point rides to the new cursor's row at its old column instead of
snapping to the cursor or stranding in scrollback."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\n$ ")
   (setq-local ghostel--term 'fake
               ghostel--cursor-char-pos (point-max)
               ghostel--cursor-pos '(2 . 2))
   (evil-normal-state)
   ;; Park at column 0 of the cursor's row (left of the cursor).
   (goto-char ghostel--cursor-char-pos)
   (move-to-column 0)
   (evil-ghostel-test--streamed-output-redraw)
   (should (= (line-beginning-position)
              (save-excursion (goto-char ghostel--cursor-char-pos)
                              (line-beginning-position))))
   (should (= 0 (current-column)))
   (should (/= (point) ghostel--cursor-char-pos))))

(ert-deftest evil-ghostel-test-around-redraw-lets-point-follow-in-emacs ()
  "Point follows the TUI cursor in `emacs'/`insert' states."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\nthree\nfour\nfive\n")
   (evil-emacs-state)
   (setq-local ghostel--term 'fake
               ghostel--cursor-pos '(0 . 2))
   (goto-char (point-min))
   (search-forward "five")
   (cl-letf (((symbol-function 'ghostel--redraw) (lambda (&rest _) t))
             ((symbol-function 'ghostel--mode-enabled)
              (lambda (_term _mode) nil)))
     (evil-ghostel--around-redraw (symbol-function 'ghostel--redraw) 'fake))
   (should (= 3 (line-number-at-pos)))
   (should (= 0 (current-column)))))

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

(ert-deftest evil-ghostel-test-around-redraw-propagates-native-refusal ()
  "A deferred native redraw skips Evil post-processing and returns nil."
  (evil-ghostel-test--with-evil-buffer
   (let ((evil-state 'insert)
         reset-called)
     (cl-letf (((symbol-function 'ghostel--mode-enabled)
                (lambda (_term _mode) nil))
               ((symbol-function 'evil-ghostel--reset-cursor-point)
                (lambda () (setq reset-called t))))
       (should-not
        (evil-ghostel--around-redraw (lambda (&rest _) nil) 'fake))
       (should-not reset-called)))))

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
              (lambda (_term &optional _full _force-sync)
                (let ((text (buffer-string))
                      (inhibit-read-only t))
                  (erase-buffer)
                  (insert text)
                  (goto-char (point-min))
                  t)))
             ((symbol-function 'ghostel--mode-enabled)
              (lambda (_term mode) (= mode 1049))))
     (evil-ghostel--around-redraw (symbol-function 'ghostel--redraw) nil))
   ;; Advice bypassed → the mock's point placement (point-min) wins.
   (should (= (point-min) (point)))))

(ert-deftest evil-ghostel-test-around-redraw-keeps-point-in-scrollback ()
  "Insert-state redraw keeps point put while reading scrollback (seam 2).
When the window has scrolled off the live output, `evil-ghostel--around-redraw'
must not drag point to the terminal cursor; when the window follows the bottom,
it still snaps point to the cursor."
  (let ((buf (generate-new-buffer " *evil-ghostel-test-seam2*"))
        (previous-buffer (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (evil-local-mode 1)
            (evil-ghostel-mode 1)
            (let ((rows (max 1 (window-body-height))))
              (setq-local ghostel--term 'fake
                          ghostel--term-rows rows)
              (let ((inhibit-read-only t))
                (dotimes (i (+ rows 20))
                  (insert (format "row-%02d\n" i)))
                (insert "$ ")))
            (setq ghostel--cursor-char-pos (point))
            ;; Viewport-relative cursor: last row, column past the prompt.
            (setq ghostel--cursor-pos (cons (current-column) (1- ghostel--term-rows)))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil)))
              ;; Bind `evil-state' directly: entering insert via
              ;; `evil-insert-state' would fire entry hooks that touch the
              ;; (fake) native term.
              (let ((win (selected-window))
                    (evil-state 'insert))
                ;; Scrolled into scrollback: point must stay put.
                (goto-char (point-min))
                (set-window-start win (point-min) t)
                (should-not (ghostel--window-anchored-p win))
                (evil-ghostel--around-redraw (lambda (&rest _) t) 'fake)
                (should (= (point) (point-min)))
                ;; Following the bottom: point snaps to the live cursor.
                (goto-char (point-max))
                (ghostel--anchor-window win)
                (should (ghostel--window-anchored-p win))
                (goto-char (point-min))
                (evil-ghostel--around-redraw (lambda (&rest _) t) 'fake)
                (should (/= (point) (point-min)))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (evil-ghostel-mode -1)))
      (set-window-buffer (selected-window) previous-buffer)
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-anchor-inhibit-predicate ()
  "`evil-ghostel--anchor-inhibit' vetoes only when roaming off the cursor.
Fires only where evil-ghostel drives PTY input (`evil-ghostel--active-p':
semi-char, outside alt-screen).  There: non-nil in a motion-capable state with
point off the live cursor and no FORCE; nil on the cursor, under FORCE, or in
insert state.  Inert (never vetoes) when not active, e.g. in alt-screen."
  (evil-ghostel-test--with-evil-buffer
   (insert "one\ntwo\nthree\n$ ")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-char-pos (point))
   (let ((off (point-min)))
     ;; Active: semi-char input mode, not alt-screen.
     (cl-letf (((symbol-function 'ghostel--mode-enabled)
                (lambda (&rest _) nil)))
       (let ((evil-state 'normal))
         ;; Normal state, point off the cursor: veto, unless FORCE.
         (goto-char off)
         (should (evil-ghostel--anchor-inhibit nil nil))
         (should-not (evil-ghostel--anchor-inhibit nil t))
         ;; Point back on the live cursor: no veto.
         (goto-char ghostel--cursor-char-pos)
         (should-not (evil-ghostel--anchor-inhibit nil nil)))
       ;; Insert state roams point off the cursor but still follows: no veto.
       (let ((evil-state 'insert))
         (goto-char off)
         (should-not (evil-ghostel--anchor-inhibit nil nil))))
     ;; Not active (alt-screen): ghostel owns the anchor, never vetoed even
     ;; while roaming off the cursor in a motion state.
     (cl-letf (((symbol-function 'ghostel--mode-enabled)
                (lambda (&rest _) t)))
       (let ((evil-state 'normal))
         (goto-char off)
         (should-not (evil-ghostel--anchor-inhibit nil nil)))))))

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
  (evil-ghostel-test--with-buffer
   5 40 ""
   ;; Overflow a 5-row viewport with 12 lines so 7 scroll off.  The
   ;; final row ("last-11") is in the viewport; earlier rows live in
   ;; scrollback above.
   (dotimes (i 12)
     (ghostel--write-vt term (format "row-%02d\r\n" i)))
   (ghostel--write-vt term "last-11")
   (let ((inhibit-read-only t))
     (ghostel--redraw term t))
   ;; Walk point back into the scrollback region.
   (goto-char (point-min))
   (should (string-match-p "row-00" (buffer-substring-no-properties
                                     (line-beginning-position)
                                     (line-end-position))))
   ;; Reset must snap point into the viewport,
   ;; not to scrollback row N.
   (evil-ghostel--reset-cursor-point)
   ;; The landing line contains the terminal cursor:
   ;; "last-11" (last written row before the trailing cursor).
   (let ((line-text (buffer-substring-no-properties
                     (line-beginning-position)
                     (line-end-position))))
     (should (string-match-p "last-11" line-text)))
   ;; And the landing column matches the terminal cursor column.
   (should (= (car ghostel--cursor-pos)
              (current-column)))))

;; -----------------------------------------------------------------------
;; Test: G (evil-ghostel-goto-cursor) is a linewise motion (#485)
;; -----------------------------------------------------------------------
;;
;; The #485 defect lives in evil's *visual command-loop* handling, not in
;; `evil-ghostel-goto-cursor''s body: a plain command makes evil expand the
;; line-visual region before `G' and contract it after, snapping point back
;; to the start line.  `evil-define-motion' supplies `:keep-visual t', which
;; suppresses that expand/contract.  `execute-kbd-macro' does not dispatch
;; commands under `--batch', so these drive `G' through the same hooks the
;; real command loop runs (`evil-visual-pre-command' / `-post-command').

(defun evil-ghostel-test--visual-goto-cursor (type)
  "Select a TYPE visual region at point, then run `G' as the command loop would.
TYPE is `line' or `char'.  Reproduces #485 without `execute-kbd-macro'."
  (evil-visual-make-selection (point) (point) type)
  (let ((this-command 'evil-ghostel-goto-cursor))
    (evil-visual-pre-command 'evil-ghostel-goto-cursor)
    (call-interactively 'evil-ghostel-goto-cursor)
    (evil-visual-post-command 'evil-ghostel-goto-cursor)))

(ert-deftest evil-ghostel-test-visual-line-goto-cursor-extends ()
  "Regression for #485: `VG' extends the line-visual selection to the cursor.
Pre-fix this reverted point to the start line; a linewise motion keeps it."
  (evil-ghostel-test--with-buffer 8 40 "r1\r\nr2\r\nr3\r\nr4\r\nr5\r\nr6"
    (should (evil-ghostel--active-p))
    (let ((cursor-line (save-excursion
                         (evil-ghostel--reset-cursor-point)
                         (line-number-at-pos))))
      (evil-normal-state)
      (goto-char (point-min))
      (evil-ghostel-test--visual-goto-cursor 'line)
      (should (evil-visual-state-p))
      (should (= cursor-line (line-number-at-pos (point))))
      (should (= 1 (line-number-at-pos evil-visual-beginning)))
      (should (>= (line-number-at-pos evil-visual-end) cursor-line)))))

(ert-deftest evil-ghostel-test-visual-char-goto-cursor-extends ()
  "Guard for #485: `vG' (char-visual) still extends to the cursor row.
This case always worked; keep it working while fixing the line-visual one."
  (evil-ghostel-test--with-buffer 8 40 "r1\r\nr2\r\nr3\r\nr4\r\nr5\r\nr6"
    (let ((cursor-line (save-excursion
                         (evil-ghostel--reset-cursor-point)
                         (line-number-at-pos))))
      (evil-normal-state)
      (goto-char (point-min))
      (evil-ghostel-test--visual-goto-cursor 'char)
      (should (evil-visual-state-p))
      (should (= cursor-line (line-number-at-pos (point))))
      (should (= 1 (line-number-at-pos evil-visual-beginning))))))

(ert-deftest evil-ghostel-test-goto-cursor-inactive-falls-back ()
  "When evil-ghostel is inactive, `evil-ghostel-goto-cursor' acts like
`evil-goto-line': honor a count, else go to the last line."
  (evil-ghostel-test--with-buffer 8 40 "r1\r\nr2\r\nr3\r\nr4\r\nr5\r\nr6"
    (setq-local ghostel--input-mode 'line)
    (should-not (evil-ghostel--active-p))
    ;; With a count: jump to that line.
    (goto-char (point-min))
    (evil-ghostel-goto-cursor 3)
    (should (= 3 (line-number-at-pos)))
    ;; Without a count: same landing spot as vanilla `evil-goto-line'.
    (let ((expected (save-excursion
                      (goto-char (point-min))
                      (evil-goto-line nil)
                      (point))))
      (goto-char (point-min))
      (evil-ghostel-goto-cursor nil)
      (should (= expected (point))))))

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
  (skip-unless (fboundp 'ghostel--new))
  (with-temp-buffer
    (ghostel-mode)
    (let ((term (ghostel--new 5 40 1000)))
      (setq-local ghostel--term term)
      (setq-local ghostel--term-rows 5)
      ;; Push 12 rows so the viewport shows rows 8..12 plus a trailing
      ;; cursor row.
      (dotimes (i 12)
        (ghostel--write-vt term (format "row-%02d\r\n" i)))
      (ghostel--write-vt term "tail")
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
  "Redraws preserve point in evil normal state once the user navigated.
The renderer does not snap point to the terminal cursor; in normal
state point stays wherever the user moved it.  Point follows the
cursor only while parked exactly on it (and in insert / emacs state)."
  (evil-ghostel-test--with-buffer 5 40 "first\r\nsecond\r\nthird"
                                  (evil-normal-state)
                                  (save-window-excursion
                                    (switch-to-buffer (current-buffer))
                                  ;; Park point on the first row, off the cursor line.
                                  (goto-char (point-min))
                                  (move-to-column 3)
                                  (should (= 3 (current-column)))
                                  (should (= 1 (line-number-at-pos)))
                                  ;; Redraw — should NOT move point back to terminal cursor
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 3 (current-column)))
                                    (should (= 1 (line-number-at-pos))))))

(defun evil-ghostel-test--stream-overflow (term)
  "Stream output through TERM that overflows a 5-row viewport, then redraw.
The whole burst lands in a single redraw, like fast un-throttled output."
  (ghostel--write-vt term "\r\n")
  (dotimes (i 8)
    (ghostel--write-vt term (format "out-%d\r\n" i)))
  (ghostel--write-vt term "$ ")
  (let ((inhibit-read-only t))
    (ghostel--redraw term nil)))

(ert-deftest evil-ghostel-test-redraw-tracks-cursor-when-parked ()
  "Output that grows scrollback keeps a parked normal-state point on the cursor.
Point must end up at the new cursor, not stranded above the new prompt
in freshly materialized scrollback (issue #228).  The buffer stays
displayed: the whole point is that a burst through a visible window
must not disengage tracking."
  (evil-ghostel-test--with-buffer 5 40 "$ "
                                  (evil-normal-state)
                                  (goto-char ghostel--cursor-char-pos)
                                  (evil-ghostel-test--stream-overflow term)
                                  (should (> (count-lines (point-min) (point-max)) 5))
                                  (should (= ghostel--cursor-char-pos (point)))))

(ert-deftest evil-ghostel-test-redraw-follows-cursor-row-in-scrollback ()
  "Output that grows scrollback carries an on-row point to the new cursor row.
Point parked on the cursor's row (but not at the cursor) keeps its
column on the row where the cursor lands."
  (evil-ghostel-test--with-buffer 5 40 "$ "
                                  (evil-normal-state)
                                  (goto-char ghostel--cursor-char-pos)
                                  (move-to-column 0)
                                  (evil-ghostel-test--stream-overflow term)
                                  (should (= (line-beginning-position)
                                             (save-excursion
                                               (goto-char ghostel--cursor-char-pos)
                                               (line-beginning-position))))
                                  (should (= 0 (current-column)))
                                  (should (/= (point) ghostel--cursor-char-pos))))

(ert-deftest evil-ghostel-test-redraw-keeps-roamed-point-in-scrollback ()
  "Output that grows scrollback leaves a roamed normal-state point on its text
\(issue #454)."
  (evil-ghostel-test--with-buffer 5 40 "alpha\r\nbeta\r\n$ "
                                  (evil-normal-state)
                                  (goto-char (point-min))
                                  (move-to-column 3)
                                  (let ((saved (point)))
                                    (evil-ghostel-test--stream-overflow term)
                                    (should (= saved (point)))
                                    (should (looking-back "alp" (line-beginning-position))))))

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
  "Test that `ghostel--apply-cursor-style' defers to evil."
  (evil-ghostel-test--with-buffer 5 40 "hello"
                                  (evil-normal-state)
                                  (let ((evil-called nil))
                                    (cl-letf (((symbol-function 'evil-refresh-cursor)
                                               (lambda (&rest _) (setq evil-called t))))
                                      (setq-local ghostel--cursor-style 0)
                                      (ghostel--apply-cursor-style)
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
;; Test: input-region helpers (input-end, clamp)
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

(defmacro evil-ghostel-test--with-cursor-fixture (prompt typed trail &rest body)
  "Mock terminal: PROMPT (`ghostel-prompt') + TYPED (`ghostel-input') + TRAIL,
with `ghostel--cursor-char-pos' at the TYPED/TRAIL boundary so TRAIL occupies
cells to the right of the cursor.  Runs BODY with evil + `evil-ghostel-mode'
on and the terminal mocked."
  (declare (indent 3))
  `(let ((buf (generate-new-buffer " *evil-ghostel-test-cursor*")))
     (unwind-protect
         (with-current-buffer buf
           (ghostel-mode)
           (let ((inhibit-read-only t))
             (insert (propertize ,prompt 'ghostel-prompt t))
             (insert (propertize ,typed 'ghostel-input t))
             (setq ghostel--cursor-char-pos (point))
             (setq ghostel--cursor-pos (cons (current-column) 0))
             (insert (propertize ,trail 'ghostel-input t)))
           (setq ghostel--term 'fake)
           (setq ghostel--term-rows 1)
           (evil-local-mode 1)
           (evil-ghostel-mode 1)
           (cl-letf (((symbol-function 'ghostel--mode-enabled)
                      (lambda (&rest _) nil)))
             ,@body))
       (kill-buffer buf))))

;; The color-based suggestion detection (`suggestion-p'/`greyed-out-p') is not
;; exercisable under `--batch' (`color-values' has no display frame), so these
;; test the clamp contract directly by stubbing `evil-ghostel--input-end' — the
;; boundary the clamp trims a rightward target to.

(ert-deftest evil-ghostel-test-goto-clamps-rightward-into-suggestion ()
  "A rightward target past `evil-ghostel--input-end' (a trailing autosuggestion)
is clamped to it: no right arrows cross the boundary and no `C-_'/backspace
correction is emitted (issue #493)."
  (evil-ghostel-test--with-cursor-fixture "$ " "ls" " --all"
    (let ((sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'evil-ghostel--sync-render) #'ignore)
                ;; Suggestion trails the cursor -> the input end is the cursor.
                ((symbol-function 'evil-ghostel--input-end)
                 (lambda () ghostel--cursor-char-pos)))
        ;; Aim into the trailing "suggestion".
        (evil-ghostel-goto-input-position (+ ghostel--cursor-char-pos 3)))
      (should-not (cl-find "right" sent :key #'car :test #'equal))
      (should-not (cl-find '("_" . "ctrl") sent :test #'equal))
      (should-not (cl-find "backspace" sent :key #'car :test #'equal))
      ;; Point clamped back to the cursor (start of the suggestion).
      (should (= (point) ghostel--cursor-char-pos)))))

(ert-deftest evil-ghostel-test-goto-rightward-within-input-sends-right ()
  "Rightward motion within typed input still sends right arrows — the
suggestion clamp does not over-restrict (issue #493)."
  (evil-ghostel-test--with-cursor-fixture "$ " "hel" "lo"
    (let ((sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'evil-ghostel--sync-render) #'ignore)
                ;; Real input end is two cells right of the cursor.
                ((symbol-function 'evil-ghostel--input-end)
                 (lambda () (+ ghostel--cursor-char-pos 2))))
        (evil-ghostel-goto-input-position (+ ghostel--cursor-char-pos 2)))
      (should (= 2 (cl-count "right" sent :key #'car :test #'equal)))
      (should-not (cl-find '("_" . "ctrl") sent :test #'equal))
      (should-not (cl-find "backspace" sent :key #'car :test #'equal)))))

(ert-deftest evil-ghostel-test-sync-render-forces-deferred-redraw ()
  "`sync-render' force-runs `ghostel--redraw-now' after a bulk-output drain.
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
           (ghostel--process 'fake-proc))
      (unwind-protect
          (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                    ((symbol-function 'accept-process-output)
                     (lambda (&rest _) nil))
                    ;; Stubbed redraw stands in for the real
                    ;; `ghostel--redraw-now', which cancels the timer.
                    ((symbol-function 'ghostel--redraw-now)
                     (lambda (_buf) (cl-incf redraw-calls))))
            (evil-ghostel--sync-render)
            (should (= 1 redraw-calls)))
        (when (timerp fake-timer) (cancel-timer fake-timer))))))

(ert-deftest evil-ghostel-test-sync-render-no-op-when-nothing-deferred ()
  "`sync-render' does NOT force a redraw when the filter handled the echo.
Small interactive echoes are drawn synchronously inside
`ghostel--filter''s immediate-redraw branch, which clears
`ghostel--redraw-timer'.  In that state `sync-render' must not call
`ghostel--redraw-now' a second time — the cursor state is already
current."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let ((redraw-calls 0)
          (ghostel--redraw-timer nil)
          (ghostel--process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--redraw-now)
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
          (ghostel--process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _) (cl-incf accept-calls) t))
                ((symbol-function 'ghostel--redraw-now) #'ignore))
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
       ;; Point lands at input-start (pos 3, just after "$ ").
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

(ert-deftest evil-ghostel-test-paste-interactive-on-read-only ()
  "Interactive p/P does not trip the read-only guard — paste goes via the PTY.
Regression: `(interactive \"*P\")' barfed on the read-only ghostel buffer
before the body ran, even though the live-terminal path writes nothing to it.
`active-p' is stubbed so the test isolates the interactive spec, not the
live-terminal detection."
  (evil-ghostel-test--with-evil-buffer
   (setq buffer-read-only t)
   (let (pasted)
     (cl-letf (((symbol-function 'evil-ghostel--active-p) (lambda () t))
               ((symbol-function 'evil-ghostel--do-paste)
                (lambda (&rest _) (setq pasted t))))
       (call-interactively #'evil-ghostel-paste-after)
       (should pasted)
       (setq pasted nil)
       (call-interactively #'evil-ghostel-paste-before)
       (should pasted)))))

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

(ert-deftest evil-ghostel-test-ctrl-passthrough-sends-in-alt-screen ()
  "Insert-state Ctrl passthrough remains active in alt-screen TUIs.
`evil-ghostel--active-p' excludes alt-screen so normal-mode editing
falls through there, but C-u/C-w/etc. must still go to the terminal
instead of invoking Evil's insert-state editing commands."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (setq-local ghostel--input-mode 'semi-char)
   (cl-letf (((symbol-function 'ghostel--mode-enabled)
              (lambda (_term mode) (= mode 1049))))
     (should-not (evil-ghostel--active-p))
     (should (evil-ghostel--ctrl-passthrough-active-p))
     (let (sent)
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (setq sent (cons key mods)))))
         (evil-ghostel--passthrough-ctrl "u"))
       (should (equal '("u" . "ctrl") sent))))))

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
    (setq buffer-read-only nil)
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
               ((symbol-function 'ghostel--anchor-window) #'ignore)
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

(ert-deftest evil-ghostel-test-escape-terminal-runs-user-input-hook ()
  "Terminal-bound ESC runs through the same input hook as other typed keys."
  (evil-ghostel-test--with-evil-buffer
   (setq evil-ghostel--escape-mode 'terminal)
   (let ((input-hook-called 0))
     (cl-letf (((symbol-function 'ghostel--on-user-input)
                (lambda () (cl-incf input-hook-called)))
               ((symbol-function 'ghostel--send-encoded)
                (lambda (&rest _))))
       (setq-local ghostel--term t)
       (evil-ghostel--escape)
       (should (= 1 input-hook-called))))))

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
;; Test: cw doesn't emit redundant left arrows after delete
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-word-with-trailing-space ()
  "`dw' over `\"word \"' sends 5 backspaces, not 4.
Trailing whitespace in single-line ranges is real user content."
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

(ert-deftest evil-ghostel-test-delete-word-on-last-word-clamps-overshoot ()
  "Regression: `dw' on the last input word clamps motion overshoot.
With input `\"word word\"' and cursor mid-input, the motion `w'
walks off the cursor row (no next word on this line) so END
lands on a buffer row below the cursor.  The operator-level
clamp trims END to `evil-ghostel--input-end' so backspaces
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
landing position to `evil-ghostel--input-end'.  Without
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

(ert-deftest evil-ghostel-test-delete-key-sends-pty-in-alt-screen ()
  "`<delete>' still reaches the PTY in an alt-screen TUI (1049)."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; Report alt-screen (1049) as active, every other mode as inactive.
   (cl-letf (((symbol-function 'ghostel--mode-enabled)
              (lambda (_term mode) (= mode 1049))))
     (let ((keys-sent '()) (fell-back nil))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _) (push key keys-sent)))
                 ((symbol-function 'evil-ghostel--fallback-key)
                  (lambda (&rest _) (setq fell-back t))))
         (evil-ghostel--passthrough-delete))
       (should (equal '("delete") keys-sent))
       (should-not fell-back)))))

(ert-deftest evil-ghostel-test-delete-key-falls-back-off-semi-char ()
  "Off semi-char (e.g. line mode) `<delete>' falls back to evil, not the PTY."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (setq-local ghostel--input-mode 'line)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (let ((keys-sent '()) (fell-back nil))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _) (push key keys-sent)))
                 ((symbol-function 'evil-ghostel--fallback-key)
                  (lambda (&rest _) (setq fell-back t))))
         (evil-ghostel--passthrough-delete))
       (should-not keys-sent)
       (should fell-back)))))

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

;; -----------------------------------------------------------------------
;; Test: input-region boundary (vterm-style; input-end + clamp)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-input-end-returns-eol-no-property ()
  "`evil-ghostel--input-end' strips trailing whitespace when no OSC 133.
Without a `ghostel-input' property it falls back to end-of-line with
renderer padding stripped."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (should (= (point-max) (evil-ghostel--input-end)))))

(ert-deftest evil-ghostel-test-input-end-empty-prompt-is-cursor ()
  "On an empty prompt the input end is the cursor, not inside the prompt.
The fallback strips trailing whitespace from EOL; on `\"$ \"' with no
typed input that would strip the prompt's own trailing space and land
the boundary at col 1 (left of the live cursor), breaking `A' / `$' /
the operator clamp.  It must floor at the cursor."
  (evil-ghostel-test--with-input-fixture "$ " ""
    ;; Cursor sits just after the prompt (point-max here).
    (should (= ghostel--cursor-char-pos (evil-ghostel--input-end)))
    ;; And the operator clamp is not inverted there.
    (let ((c (evil-ghostel--clamp ghostel--cursor-char-pos
                                  ghostel--cursor-char-pos)))
      (should (<= (car c) (cdr c))))))

(ert-deftest evil-ghostel-test-input-end-via-input-property ()
  "OSC 133;B `ghostel-input' cells decide the input end.
Padding / hint cells past the input (no `ghostel-input') are ignored."
  (let ((buf (generate-new-buffer " *eg-input-prop*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            (insert (propertize "hello" 'ghostel-input t))
            (insert "   hint"))
          (setq ghostel--term 'fake ghostel--term-rows 1
                ghostel--cursor-char-pos 8 ghostel--cursor-pos '(7 . 0))
          (should (= 8 (evil-ghostel--input-end))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-input-end-uses-first-region ()
  "Two `ghostel-input' regions (typed input + a right prompt that
libghostty also tags input): the end of the FIRST region wins."
  (let ((buf (generate-new-buffer " *eg-fish-rprompt*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            (insert (propertize "foo bar" 'ghostel-input t))
            (insert (make-string 20 ?\s))
            (insert (propertize "main *" 'ghostel-input t)))
          (setq ghostel--term 'fake ghostel--term-rows 1
                ghostel--cursor-char-pos 10 ghostel--cursor-pos '(9 . 0))
          (should (= 10 (evil-ghostel--input-end))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-input-end-excludes-autosuggestion ()
  "A faint autosuggestion after the cursor is not counted as input.
zsh / fish render POSTDISPLAY in a dimmer foreground; the typed input
ends at the cursor, so `evil-ghostel--input-end' stops there."
  (let ((buf (generate-new-buffer " *eg-autosuggest*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            ;; Typed input: bright foreground.
            (insert (propertize "echo" 'ghostel-input t
                                'face '(:foreground "#ffffff")))
            ;; Autosuggestion: same `ghostel-input', faint foreground.
            (insert (propertize " world" 'ghostel-input t
                                'face '(:foreground "#4d4d4d"))))
          (setq ghostel--term 'fake ghostel--term-rows 1
                ;; Cursor sits at the typed/suggestion boundary (after "echo").
                ghostel--cursor-char-pos 7 ghostel--cursor-pos '(6 . 0))
          ;; Input ends at the cursor (7), not at the end of " world" (13).
          (should (= 7 (evil-ghostel--input-end))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-input-end-excludes-brighter-suggestion ()
  "A suggestion is excluded even when it is BRIGHTER than the typed text.
fish paints an invalid command red (`#ee0000', darker than its own grey
`#4d4d4d' suggestion), so a luminance test misses the suggestion; the
color-difference test still finds it because the trailing run is a
uniform color distinct from the typed char."
  (let ((buf (generate-new-buffer " *eg-autosuggest-bright*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            ;; Typed "ec": red, DARKER than the grey suggestion.
            (insert (propertize "ec" 'ghostel-input t 'face '(:foreground "#ee0000")))
            ;; Suggestion: grey, BRIGHTER than the red typed text.
            (insert (propertize "ho hello" 'ghostel-input t
                                'face '(:foreground "#4d4d4d"))))
          (setq ghostel--term 'fake ghostel--term-rows 1
                ;; Cursor at the typed/suggestion boundary (after "ec").
                ghostel--cursor-char-pos 5 ghostel--cursor-pos '(4 . 0))
          ;; Input ends at the cursor (5), not at the end of the brighter
          ;; suggestion (13).
          (should (= 5 (evil-ghostel--input-end))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-input-end-keeps-input-when-cursor-at-start ()
  "Trailing colored input is not mistaken for a suggestion at the line start.
After deleting the first word, the cursor sits at the input start over
recolored real input; the whole line remains editable."
  (let ((buf (generate-new-buffer " *eg-no-suggest-at-start*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            ;; Real input, recolored (red command, cyan arg); cursor at its start.
            (insert (propertize "hello" 'ghostel-input t 'face '(:foreground "#ee0000")))
            (insert (propertize " world" 'ghostel-input t
                                'face '(:foreground "#00cdcd"))))
          (setq ghostel--term 'fake ghostel--term-rows 1
                ;; Cursor at the input start (3) — no typed text precedes it.
                ghostel--cursor-char-pos 3 ghostel--cursor-pos '(2 . 0))
          ;; Input runs to the real end (14), not collapsed to the cursor.
          (should (= 14 (evil-ghostel--input-end))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-input-end-keeps-mid-input-colored-tail ()
  "A saturated uniform tail under a mid-input cursor is NOT a suggestion.
With the terminal cursor parked on the last word (e.g. a cyan argument),
the run from the cursor to the line end is one color distinct from the
char before it — but it is a *saturated* syntax color, not the greyed-out
autosuggestion style, so the editable input must still run to the real
end (else `D'/`C'/`$' under-act)."
  (let ((buf (generate-new-buffer " *eg-mid-input-tail*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert (propertize "$ " 'ghostel-prompt t))
            ;; Typed "echo " (white) then a cyan argument "bar".
            (insert (propertize "echo " 'ghostel-input t 'face '(:foreground "#ffffff")))
            (insert (propertize "bar" 'ghostel-input t 'face '(:foreground "#00cdcd"))))
          (setq ghostel--term 'fake ghostel--term-rows 1
                ;; Terminal cursor parked on "bar" (pos 8), mid-input.
                ghostel--cursor-char-pos 8 ghostel--cursor-pos '(7 . 0))
          ;; "bar" is bright/saturated, not greyed-out → input runs to 11,
          ;; not collapsed to the cursor (8).
          (should (= 11 (evil-ghostel--input-end))))
      (kill-buffer buf))))

(ert-deftest evil-ghostel-test-clamp-narrows-on-cursor-row ()
  "`evil-ghostel--clamp' raises BEG to the prompt boundary."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let ((clamped (evil-ghostel--clamp 1 ghostel--cursor-char-pos)))
      (should (= 3 (car clamped)))
      (should (= ghostel--cursor-char-pos (cdr clamped))))))

(ert-deftest evil-ghostel-test-clamp-trims-end-past-input ()
  "`evil-ghostel--clamp' lowers END to the end of typed input."
  (evil-ghostel-test--with-input-fixture "$ " "hello"
    (let ((inhibit-read-only t))
      (save-excursion (insert "   ")))  ; renderer padding past the cursor
    (let ((clamped (evil-ghostel--clamp 3 (+ ghostel--cursor-char-pos 3))))
      (should (= 3 (car clamped)))
      (should (= ghostel--cursor-char-pos (cdr clamped))))))

(ert-deftest evil-ghostel-test-clamp-leaves-beg-without-prompt ()
  "Without a detectable prompt, BEG is left alone (no collapse).
`ghostel-input-start-point' degenerates to the cursor when no prompt
is found; `evil-ghostel--input-start' returns nil there so the clamp
does not push BEG up to the cursor and collapse the range."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "word1 word2")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(11 . 0))
             (ghostel--cursor-char-pos (point)))
     (let ((clamped (evil-ghostel--clamp 1 7)))
       (should (= 1 (car clamped)))
       (should (= 7 (cdr clamped)))))))

(ert-deftest evil-ghostel-test-end-of-line-stops-at-last-typed-char ()
  "`$' lands on the last typed char, not on trailing renderer padding."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     (insert "cmd   "))  ; trailing renderer padding
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(5 . 0))
             (ghostel--cursor-char-pos 6))
     (evil-normal-state)
     (goto-char 3)
     (evil-ghostel-end-of-line 1)
     ;; Last typed char is 'd' at pos 5 (col 4), before the padding.
     (should (= 5 (point))))))

(ert-deftest evil-ghostel-test-end-of-line-excludes-autosuggestion ()
  "`$' stops at the last typed char even with a faint suggestion after it."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (let ((inhibit-read-only t))
     (insert (propertize "$ " 'ghostel-prompt t))
     (insert (propertize "echo" 'ghostel-input t 'face '(:foreground "#ffffff")))
     (insert (propertize " ls" 'ghostel-input t 'face '(:foreground "#4d4d4d"))))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(6 . 0))
             (ghostel--cursor-char-pos 7))  ; after "echo"
     (evil-normal-state)
     (goto-char 3)
     (evil-ghostel-end-of-line 1)
     ;; Last typed char 'o' is pos 6 (col 5); the " ls" suggestion is skipped.
     (should (= 6 (point))))))

(ert-deftest evil-ghostel-test-first-non-blank-skips-prompt ()
  "`^' jumps to the first input char on a prompt row, not column 0."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "$ command")
   (let ((inhibit-read-only t))
     (put-text-property 1 3 'ghostel-prompt t))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (evil-normal-state)
     (goto-char (point-max))
     (evil-ghostel-first-non-blank)
     (should (= 2 (current-column))))))

(ert-deftest evil-ghostel-test-replace-count-excludes-soft-wraps ()
  "`r' deletes and re-pastes the same count, excluding soft-wrap newlines.
A `ghostel-wrap' newline is a renderer line break, not a real input
character, so it must not consume a backspace or a replacement char."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   ;; "AB" + soft-wrap newline + "C" -> 3 real input chars.
   (let ((inhibit-read-only t))
     (insert "AB")
     (insert (propertize "\n" 'ghostel-wrap t))
     (insert "C"))
   ;; Terminal cursor at the end of input (after "C"), as right after
   ;; typing; the input region spans the whole buffer.
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             (ghostel--cursor-pos '(1 . 0))
             (ghostel--cursor-char-pos (point-max))
             ((symbol-function 'evil-ghostel-goto-input-position) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0) (pasted nil))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace") (cl-incf bs-count))))
                 ((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text))))
         (evil-ghostel-replace (point-min) (point-max) 'inclusive ?X))
       (should (= 3 bs-count))
       (should (equal "XXX" pasted))))))

(ert-deftest evil-ghostel-test-change-registered-for-cw-to-ce ()
  "`evil-ghostel-change' is registered in `evil-change-commands' so
`cw' / `cW' behave like `ce' / `cE' (stop at the word end)."
  (should (memq 'evil-ghostel-change evil-change-commands)))

(defun evil-ghostel-test-run ()
  "Run all evil-ghostel tests.
Most tests mock the native module; the few that drive a real terminal
guard themselves with `skip-unless', so this one regex runner serves both
`make test-evil' (module built, all run) and CI's elisp-only `test-evil'
job (native tests skipped)."
  (ert-run-tests-batch-and-exit "^evil-ghostel-test-"))

;;; evil-ghostel-test.el ends here
