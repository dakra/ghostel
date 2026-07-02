;;; meow-ghostel-test.el --- Tests for meow-ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L ~/.cache/meow -L lisp -L extensions/meow-ghostel \
;;     -l ert -l test/meow-ghostel-test.el -f meow-ghostel-test-run

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'meow)
(require 'ghostel)
(require 'meow-ghostel)

;; Batch Emacs starts with `transient-mark-mode' off, but meow's
;; selection model (and `region-active-p') requires it — as in any
;; interactive session.
(transient-mark-mode 1)

;; -----------------------------------------------------------------------
;; Helpers: set up a ghostel buffer with meow
;; -----------------------------------------------------------------------

(defun meow-ghostel-test--insert (&rest args)
  "Insert ARGS as renderer-owned test setup text."
  (let ((inhibit-read-only t))
    (apply #'insert args)))

(defmacro meow-ghostel-test--with-buffer (rows cols text &rest body)
  "Create a ghostel buffer with ROWS x COLS, feed TEXT, render, then run BODY.
The buffer has meow-mode and `meow-ghostel-mode' active.  The variable
`term' is bound to the terminal handle.  Requires the native module;
without it the test is skipped (e.g. CI's elisp-only `test-meow' job)."
  (declare (indent 3) (debug t))
  `(progn
     (skip-unless (fboundp 'ghostel--new))
     (let* ((ghostel-max-scrollback 100)
            (buf (ghostel--create " *meow-ghostel-test*" nil ,rows ,cols))
            (term (buffer-local-value 'ghostel--term buf)))
       (unwind-protect
           (with-current-buffer buf
             (ghostel--write-vt term ,text)
             (meow-mode 1)
             (meow-ghostel-mode 1)
             (let ((inhibit-read-only t))
               (ghostel--redraw term t))
             (cl-macrolet ((insert (&rest args)
                             `(meow-ghostel-test--insert ,@args)))
               ,@body))
         (when (buffer-live-p buf)
           (kill-buffer buf))))))

(defmacro meow-ghostel-test--with-meow-buffer (&rest body)
  "Set up a ghostel buffer with meow active (no native module).
Uses mocks for native functions."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (ghostel-mode)
     ;; Mock tests don't go through `ghostel--resize', so
     ;; `ghostel--term-rows' stays nil by default.  Pick a value large
     ;; enough that the viewport covers whatever text a mock test
     ;; `insert's — the scrollback-offset computation then collapses to
     ;; zero.
     (setq-local ghostel--term-rows 100)
     (meow-mode 1)
     (meow-ghostel-mode 1)
     (cl-macrolet ((insert (&rest args)
                     `(meow-ghostel-test--insert ,@args)))
       ,@body)))

(defmacro meow-ghostel-test--with-input-fixture (prompt input &rest body)
  "Set up a mock terminal buffer with PROMPT (carrying `ghostel-prompt')
followed by INPUT, with `ghostel--cursor-char-pos' positioned at the
end of INPUT.  Runs BODY in the buffer in meow NORMAL state.

Mocks the terminal handle and viewport so the input-region helpers can
derive prompt boundaries and viewport rows without a native module."
  (declare (indent 2))
  `(let ((buf (generate-new-buffer " *meow-ghostel-test-input*")))
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
           (meow-mode 1)
           (meow-ghostel-mode 1)
           (meow--switch-state 'normal)
           (cl-letf (((symbol-function 'ghostel--mode-enabled)
                      (lambda (&rest _) nil)))
             ,@body))
       (kill-buffer buf))))

(defmacro meow-ghostel-test--with-cursor-fixture (prompt typed trail &rest body)
  "Mock terminal: PROMPT (`ghostel-prompt') + TYPED (`ghostel-input') + TRAIL,
with `ghostel--cursor-char-pos' at the TYPED/TRAIL boundary so TRAIL
occupies cells to the right of the cursor.  Runs BODY in NORMAL state
with the terminal mocked."
  (declare (indent 3))
  `(let ((buf (generate-new-buffer " *meow-ghostel-test-cursor*")))
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
           (meow-mode 1)
           (meow-ghostel-mode 1)
           (meow--switch-state 'normal)
           (cl-letf (((symbol-function 'ghostel--mode-enabled)
                      (lambda (&rest _) nil)))
             ,@body))
       (kill-buffer buf))))

(defmacro meow-ghostel-test--with-line-mode (input-text input-start input-end &rest body)
  "Set up a line-mode buffer for meow tests.
INPUT-TEXT is inserted; INPUT-START / INPUT-END (1-indexed positions)
become `ghostel--line-input-start' / `--line-input-end'."
  (declare (indent 3) (debug t))
  `(meow-ghostel-test--with-meow-buffer
    (setq-local ghostel--term t)
    (setq-local ghostel--input-mode 'line)
    (setq buffer-read-only nil)
    (insert ,input-text)
    (setq-local ghostel--line-input-start (copy-marker ,input-start nil))
    (setq-local ghostel--line-input-end (copy-marker ,input-end t))
    (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
      ,@body)))

(defmacro meow-ghostel-test--with-escape-stubs (alt-screen-p &rest body)
  "Run BODY with `ghostel--mode-enabled' returning ALT-SCREEN-P for 1049
and with `ghostel--send-encoded' captured into the local list `sent'."
  (declare (indent 1) (debug t))
  `(let ((sent '()))
     (ignore sent)
     (cl-letf (((symbol-function 'ghostel--mode-enabled)
                (lambda (_term mode) (and (= mode 1049) ,alt-screen-p)))
               ((symbol-function 'ghostel--anchor-window) #'ignore)
               ((symbol-function 'ghostel--send-encoded)
                (lambda (key mods &rest _) (push (cons key mods) sent))))
       (setq-local ghostel--term t)
       ,@body)))

;; -----------------------------------------------------------------------
;; Test: mode activation
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-mode-activation ()
  "`meow-ghostel-mode' wires hooks, advice, remaps, and buffer-locals.
Bindings are remap-form (`[remap meow-FOO]') so whatever keys the
user's `meow-setup' picked flow through to the PTY-routed variants —
verified here by looking up the remap rather than a literal key."
  (meow-ghostel-test--with-meow-buffer
   (should meow-ghostel-mode)
   (should (memq 'meow-ghostel--insert-enter meow-insert-enter-hook))
   (should (memq 'meow-ghostel--anchor-inhibit
                 ghostel-inhibit-anchor-functions))
   (should (advice--p (advice--symbol-function 'ghostel--redraw)))
   (should (advice--p (advice--symbol-function 'ghostel--apply-cursor-style)))
   (should (eq #'meow-ghostel-kill
               (lookup-key meow-ghostel-mode-map [remap meow-kill])))
   (should (eq #'meow-ghostel-change
               (lookup-key meow-ghostel-mode-map [remap meow-change])))
   (should (eq #'meow-ghostel-escape
               (lookup-key meow-ghostel-mode-map [remap meow-insert-exit])))
   ;; Literal key bindings must NOT be present — meow has no default
   ;; layout, so a literal key would only match one user's setup.
   (should-not (lookup-key meow-ghostel-mode-map "s"))
   (should-not (lookup-key meow-ghostel-mode-map "d"))))

(ert-deftest meow-ghostel-test-mode-activation-kbd-overrides ()
  "Activation installs the buffer-local `meow--kbd-*' overrides.
Without them meow's kbd-macro commands resolve through ghostel's
semi-char map to PTY senders (`meow-next' would browse shell history,
`meow-save' would type M-w into the shell)."
  (meow-ghostel-test--with-meow-buffer
   (dolist (override meow-ghostel--kbd-overrides)
     (should (local-variable-p (car override)))
     (should (eq (cdr override) (symbol-value (car override)))))
   (should (local-variable-p 'meow--delete-region-function))
   (should (eq #'meow-ghostel--delete-region meow--delete-region-function))
   (should (eq #'meow-ghostel--insert meow--insert-function))))

(ert-deftest meow-ghostel-test-mode-activation-no-insert-exit-hook ()
  "`meow-ghostel-mode' does not install a `meow-insert-exit-hook'.
Point is synced on insert entry and preserved through redraws in
normal state; re-syncing on exit would overwrite the position the
user navigated to."
  (meow-ghostel-test--with-meow-buffer
   (should-not (memq 'meow-ghostel--insert-exit meow-insert-exit-hook))))

(ert-deftest meow-ghostel-test-mode-deactivation ()
  "`meow-ghostel-mode' cleans up hooks and buffer-locals on deactivation."
  (meow-ghostel-test--with-meow-buffer
   (meow-ghostel-mode -1)
   (should-not meow-ghostel-mode)
   (should-not (memq 'meow-ghostel--insert-enter meow-insert-enter-hook))
   (should-not (memq 'meow-ghostel--anchor-inhibit
                     ghostel-inhibit-anchor-functions))
   (dolist (override meow-ghostel--kbd-overrides)
     (should-not (local-variable-p (car override))))
   (should-not (local-variable-p 'meow--delete-region-function))
   (should-not (local-variable-p 'meow--insert-function))
   ;; The global defaults are intact.
   (should (equal "C-n" meow--kbd-forward-line))
   (should (eq #'delete-region meow--delete-region-function))))

(ert-deftest meow-ghostel-test-selection-inhibits-mark-copy-mode ()
  "Activating the mark must not flip ghostel into copy mode.
`ghostel-mode' wires `ghostel--mark-activated' onto `activate-mark-hook',
which (for vanilla users) switches semi-char -> copy mode when the mark
activates.  Every meow selection command activates the mark, so without
suppression the first `meow-mark-word' would flip the buffer to copy
mode before the PTY-aware commands can run."
  (meow-ghostel-test--with-meow-buffer
   (should (eq ghostel--input-mode 'semi-char))
   (should (memq #'ghostel--mark-activated activate-mark-hook))
   (should (local-variable-p 'ghostel-mark-activation-input-mode))
   (should (null ghostel-mark-activation-input-mode))
   (let (copied)
     (cl-letf (((symbol-function 'ghostel-copy-mode)
                (lambda (&rest _) (setq copied t))))
       (ghostel--mark-activated)
       (should-not copied)
       (let ((ghostel-mark-activation-input-mode 'copy))
         (ghostel--mark-activated)
         (should copied))))))

(ert-deftest meow-ghostel-test-disable-restores-mark-activation ()
  "Disabling `meow-ghostel-mode' restores ghostel's mark-activation behavior."
  (meow-ghostel-test--with-meow-buffer
   (should (local-variable-p 'ghostel-mark-activation-input-mode))
   (meow-ghostel-mode -1)
   (should-not (local-variable-p 'ghostel-mark-activation-input-mode))))

(ert-deftest meow-ghostel-test-advice-survives-disable-in-other-buffer ()
  "Global advice survives one buffer disabling the mode.
The advice is global but the mode is buffer-local; `advice-remove'
during disable must wait until the LAST `meow-ghostel-mode' buffer
is gone."
  (let ((a (generate-new-buffer " *meow-ghostel-test-advice-a*"))
        (b (generate-new-buffer " *meow-ghostel-test-advice-b*")))
    (unwind-protect
        (progn
          (with-current-buffer a
            (ghostel-mode)
            (setq-local ghostel--term-rows 100)
            (meow-mode 1)
            (meow-ghostel-mode 1))
          (with-current-buffer b
            (ghostel-mode)
            (setq-local ghostel--term-rows 100)
            (meow-mode 1)
            (meow-ghostel-mode 1))
          (should (advice-member-p #'meow-ghostel--around-redraw
                                   'ghostel--redraw))
          (with-current-buffer a (meow-ghostel-mode -1))
          (should (advice-member-p #'meow-ghostel--around-redraw
                                   'ghostel--redraw))
          (should (advice-member-p #'meow-ghostel--override-cursor-style
                                   'ghostel--apply-cursor-style))
          (with-current-buffer b (meow-ghostel-mode -1))
          (should-not (advice-member-p #'meow-ghostel--around-redraw
                                       'ghostel--redraw))
          (should-not (advice-member-p #'meow-ghostel--override-cursor-style
                                       'ghostel--apply-cursor-style)))
      (when (buffer-live-p a) (kill-buffer a))
      (when (buffer-live-p b) (kill-buffer b)))))

(ert-deftest meow-ghostel-test-command-remapping-dispatch ()
  "`command-remapping' resolves meow commands to the PTY variants.
Meow's state keymaps live in `emulation-mode-map-alists' (above
minor-mode maps), but they bind no `[remap meow-*]' entries, so the
remaps in our ordinary minor-mode map still apply at dispatch time."
  (meow-ghostel-test--with-meow-buffer
   (meow--switch-state 'normal)
   (should (eq #'meow-ghostel-kill (command-remapping 'meow-kill)))
   (should (eq #'meow-ghostel-change (command-remapping 'meow-change)))
   (should (eq #'meow-ghostel-yank (command-remapping 'meow-yank)))
   ;; Alias symbols need their own remap entries: a key bound to
   ;; `meow-delete' (qwerty `d', an alias for `meow-C-d') only matches a
   ;; remap of the alias symbol itself.
   (should (eq #'meow-ghostel-C-d (command-remapping 'meow-delete)))
   (should (eq #'meow-ghostel-backspace
               (command-remapping 'meow-backward-delete)))
   (meow--switch-state 'insert)
   (should (eq #'meow-ghostel-escape (command-remapping 'meow-insert-exit)))))

;; -----------------------------------------------------------------------
;; Test: initial-state defcustom
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-initial-state-load-applied ()
  "Loading meow-ghostel registers the initial state in `meow-mode-state-list'."
  (should (eq meow-ghostel-initial-state
              (alist-get 'ghostel-mode meow-mode-state-list))))

(ert-deftest meow-ghostel-test-initial-state-custom-set-updates-registry ()
  "Setting the defcustom through custom updates `meow-mode-state-list'."
  (let ((orig meow-ghostel-initial-state))
    (unwind-protect
        (progn
          (customize-set-variable 'meow-ghostel-initial-state 'normal)
          (should (eq 'normal (alist-get 'ghostel-mode meow-mode-state-list))))
      (customize-set-variable 'meow-ghostel-initial-state orig))))

(ert-deftest meow-ghostel-test-initial-state-applied-on-meow-enable ()
  "Enabling meow in a ghostel buffer starts in the configured state."
  (with-temp-buffer
    (ghostel-mode)
    (setq-local ghostel--term-rows 100)
    (meow-mode 1)
    (should (eq meow-ghostel-initial-state meow--current-state))))

;; -----------------------------------------------------------------------
;; Test: around-redraw point and selection policy
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-around-redraw-does-not-restore-normal-point ()
  "In normal state the redraw advice leaves point where the user put it."
  (meow-ghostel-test--with-meow-buffer
   (insert "hello world")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-pos '(11 . 0))
   (setq-local ghostel--cursor-char-pos 12)
   (meow--switch-state 'normal)
   (goto-char 3)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (meow-ghostel--around-redraw #'ignore 'fake))
   (should (= 3 (point)))))

(ert-deftest meow-ghostel-test-around-redraw-snaps-point-in-insert ()
  "In insert state the redraw advice snaps point to the terminal cursor.
The temp buffer has no window, which counts as anchored/following."
  (meow-ghostel-test--with-meow-buffer
   (insert "hello world")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-pos '(11 . 0))
   (setq-local ghostel--cursor-char-pos 12)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'meow-ghostel--insert-enter) #'ignore))
     (meow--switch-state 'insert)
     (goto-char (point-min))
     (meow-ghostel--around-redraw #'ignore 'fake)
     (should (= 11 (current-column))))))

(ert-deftest meow-ghostel-test-around-redraw-restores-selection ()
  "An active region survives the repaint: the mark marker is restored
and the repaint's `deactivate-mark' is suppressed."
  (meow-ghostel-test--with-meow-buffer
   (insert "hello world")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-pos '(11 . 0))
   (setq-local ghostel--cursor-char-pos 12)
   (meow--switch-state 'normal)
   (goto-char 6)
   (push-mark 2 t t)
   (should (region-active-p))
   (setq deactivate-mark nil)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (meow-ghostel--around-redraw
      ;; Simulate a repaint that clobbers the mark marker and requests
      ;; mark deactivation, as buffer edits do.
      (lambda (&rest _)
        (set-marker (mark-marker) (point-min))
        (setq deactivate-mark t))
      'fake))
   (should-not deactivate-mark)
   (should (= 2 (mark t)))
   (should (region-active-p))))

(ert-deftest meow-ghostel-test-around-redraw-bypassed-in-alt-screen ()
  "In alt-screen (DECSET 1049) the advice defers entirely to the original."
  (meow-ghostel-test--with-meow-buffer
   (insert "hello world")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-pos '(11 . 0))
   (setq-local ghostel--cursor-char-pos 12)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) t))
             ((symbol-function 'meow-ghostel--insert-enter) #'ignore))
     (meow--switch-state 'insert)
     (goto-char (point-min))
     (let ((orig-called nil))
       (meow-ghostel--around-redraw (lambda (&rest _) (setq orig-called t))
                                    'fake)
       (should orig-called)
       ;; Not snapped to the cursor: TUIs own point placement.
       (should (= (point) (point-min)))))))

(ert-deftest meow-ghostel-test-around-redraw-keeps-point-in-scrollback ()
  "In insert state with the window scrolled off the bottom, no snap.
Dragging point to the cursor would yank the viewport back each frame
while the user reads scrollback."
  (meow-ghostel-test--with-meow-buffer
   (insert "hello world")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-pos '(11 . 0))
   (setq-local ghostel--cursor-char-pos 12)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'meow-ghostel--insert-enter) #'ignore)
             ((symbol-function 'get-buffer-window) (lambda (&rest _) 'fake-win))
             ((symbol-function 'ghostel--window-anchored-p) (lambda (_) nil)))
     (meow--switch-state 'insert)
     (goto-char (point-min))
     (meow-ghostel--around-redraw #'ignore 'fake)
     (should (= (point) (point-min))))))

;; -----------------------------------------------------------------------
;; Test: anchor-inhibit predicate
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-anchor-inhibit-predicate ()
  "The anchor veto holds only off-cursor outside insert state, sans FORCE."
  (meow-ghostel-test--with-meow-buffer
   (insert "hello world")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-char-pos 12)
   (setq-local ghostel--cursor-pos '(11 . 0))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'meow-ghostel--insert-enter) #'ignore))
     (meow--switch-state 'normal)
     (goto-char 3)
     ;; Normal state, point off cursor: veto.
     (should (meow-ghostel--anchor-inhibit nil nil))
     ;; FORCE overrides the veto.
     (should-not (meow-ghostel--anchor-inhibit nil t))
     ;; Point on the cursor: no veto.
     (goto-char 12)
     (should-not (meow-ghostel--anchor-inhibit nil nil))
     ;; Insert state: no veto.
     (meow--switch-state 'insert)
     (goto-char 3)
     (should-not (meow-ghostel--anchor-inhibit nil nil))
     ;; Mode inactive (copy mode): no veto.
     (meow--switch-state 'normal)
     (let ((ghostel--input-mode 'copy))
       (should-not (meow-ghostel--anchor-inhibit nil nil))))))

;; -----------------------------------------------------------------------
;; Test: reset-cursor-point
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-reset-cursor-point ()
  "Point lands on the cursor's column on a single row."
  (meow-ghostel-test--with-meow-buffer
   (insert "hello world")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-pos '(5 . 0))
   (goto-char (point-min))
   (meow-ghostel--reset-cursor-point)
   (should (= 5 (current-column)))))

(ert-deftest meow-ghostel-test-reset-cursor-point-multiline ()
  "Point lands on the cursor's row and column across rows."
  (meow-ghostel-test--with-meow-buffer
   (insert "first\nsecond\nthird")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-pos '(3 . 2))
   (goto-char (point-min))
   (meow-ghostel--reset-cursor-point)
   (should (= 3 (line-number-at-pos)))
   (should (= 3 (current-column)))))

(ert-deftest meow-ghostel-test-reset-cursor-point-with-scrollback ()
  "The viewport-relative cursor row is offset by scrollback lines."
  (meow-ghostel-test--with-meow-buffer
   ;; 6 buffer lines, 3 viewport rows -> 3 scrollback lines.
   (insert "sb-0\nsb-1\nsb-2\nvp-0\nvp-1\nvp-2")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--term-rows 3)
   (setq-local ghostel--cursor-pos '(2 . 1)) ; viewport row 1 = "vp-1"
   (goto-char (point-min))
   (meow-ghostel--reset-cursor-point)
   (should (= 5 (line-number-at-pos)))
   (should (= 2 (current-column)))))

;; -----------------------------------------------------------------------
;; Test: goto-input-position (unit)
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-goto-input-position-sends-arrows-unit ()
  "Unit: |dx| left arrows are sent when the target is left of the cursor."
  (meow-ghostel-test--with-input-fixture "$ " "hello world"
    ;; cursor col 13 (after "$ hello world"); target col 7 -> 6 LEFT.
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (push key keys-sent))))
        (meow-ghostel-goto-input-position 8))
      (should (= 6 (length keys-sent)))
      (should (cl-every (lambda (k) (equal k "left")) keys-sent)))))

(ert-deftest meow-ghostel-test-goto-input-position-no-op-at-target ()
  "No keys are sent when point already matches the terminal cursor."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (push key keys-sent))))
        (meow-ghostel-goto-input-position ghostel--cursor-char-pos))
      (should (zerop (length keys-sent))))))

;; The color-based suggestion detection (`suggestion-p'/`greyed-out-p') is
;; not exercisable under `--batch' (`color-values' has no display frame),
;; so these test the clamp contract directly by stubbing
;; `meow-ghostel--input-end' — the boundary a rightward target is trimmed
;; to.  Live coverage is the elate boundary suites.

(ert-deftest meow-ghostel-test-goto-clamps-rightward-into-suggestion ()
  "A rightward target past `meow-ghostel--input-end' (an autosuggestion)
is clamped to it: no right arrows cross the boundary (issue #493)."
  (meow-ghostel-test--with-cursor-fixture "$ " "ls" " --all"
    (let ((sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'meow-ghostel--sync-render) #'ignore)
                ((symbol-function 'meow-ghostel--input-end)
                 (lambda () ghostel--cursor-char-pos)))
        (meow-ghostel-goto-input-position (+ ghostel--cursor-char-pos 3)))
      (should-not (cl-find "right" sent :key #'car :test #'equal))
      (should-not (cl-find "backspace" sent :key #'car :test #'equal))
      (should (= (point) ghostel--cursor-char-pos)))))

(ert-deftest meow-ghostel-test-goto-rightward-within-input-sends-right ()
  "Rightward motion within typed input still sends right arrows — the
suggestion clamp does not over-restrict (issue #493)."
  (meow-ghostel-test--with-cursor-fixture "$ " "hel" "lo"
    (let ((sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'meow-ghostel--sync-render) #'ignore)
                ((symbol-function 'meow-ghostel--input-end)
                 (lambda () (+ ghostel--cursor-char-pos 2))))
        (meow-ghostel-goto-input-position (+ ghostel--cursor-char-pos 2)))
      (should (= 2 (cl-count "right" sent :key #'car :test #'equal)))
      (should-not (cl-find "backspace" sent :key #'car :test #'equal)))))

;; -----------------------------------------------------------------------
;; Test: sync-render
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-sync-render-forces-deferred-redraw ()
  "`sync-render' force-runs `ghostel--redraw-now' after a bulk-output drain.
Bulk echoes queue a timer-driven redraw, so cursor state is stale until
the timer fires; `sync-render' must close the gap before the next
command reads `ghostel--cursor-pos'."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let* ((redraw-calls 0)
           (fake-timer (run-with-timer 999 nil #'ignore))
           (ghostel--redraw-timer fake-timer)
           (ghostel--process 'fake-proc))
      (unwind-protect
          (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                    ((symbol-function 'accept-process-output)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--redraw-now)
                     (lambda (_buf) (cl-incf redraw-calls))))
            (meow-ghostel--sync-render)
            (should (= 1 redraw-calls)))
        (when (timerp fake-timer) (cancel-timer fake-timer))))))

(ert-deftest meow-ghostel-test-sync-render-no-op-when-nothing-deferred ()
  "`sync-render' does not force a redraw when the filter handled the echo."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((redraw-calls 0)
          (ghostel--redraw-timer nil)
          (ghostel--process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (cl-incf redraw-calls))))
        (meow-ghostel--sync-render)
        (should (zerop redraw-calls))))))

(ert-deftest meow-ghostel-test-sync-render-drain-loop-respects-cap ()
  "`sync-render' caps the drain loop at `*-max-iterations'."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((accept-calls 0)
          (meow-ghostel-sync-render-max-iterations 5)
          (ghostel--redraw-timer nil)
          (ghostel--process 'fake-proc))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _) (cl-incf accept-calls) t))
                ((symbol-function 'ghostel--redraw-now) #'ignore))
        (meow-ghostel--sync-render)
        (should (= 5 accept-calls))))))

;; -----------------------------------------------------------------------
;; Test: delete / replace input region primitives
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-delete-input-region-sends-backspaces ()
  "`meow-ghostel-delete-input-region' sends one backspace per char."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (push key keys-sent))))
        (meow-ghostel-delete-input-region 3 ghostel--cursor-char-pos))
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal))))))

(ert-deftest meow-ghostel-test-delete-input-region-excludes-soft-wraps ()
  "Soft-wrap newlines (renderer artifacts) don't cost a backspace."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((inhibit-read-only t))
      ;; Renderer-inserted wrap newline inside the range.
      (goto-char 6)
      (insert (propertize "\n" 'ghostel-wrap t)))
    (setq ghostel--cursor-char-pos (point-max))
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (push key keys-sent))))
        (meow-ghostel-delete-input-region 3 (point-max)))
      ;; "hel" + wrap-\n + "lo" -> 5 meaningful chars, not 6.
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal))))))

(ert-deftest meow-ghostel-test-replace-input-region-deletes-then-pastes ()
  "`meow-ghostel-replace-input-region' first deletes, then pastes."
  (meow-ghostel-test--with-input-fixture "$ " "abc"
    (let ((pasted nil)
          (keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent)))
                ((symbol-function 'ghostel--paste-text)
                 (lambda (text) (setq pasted text))))
        (meow-ghostel-replace-input-region 3 ghostel--cursor-char-pos "XYZ"))
      (should (= 3 (cl-count "backspace" keys-sent :test #'equal)))
      (should (equal "XYZ" pasted)))))

;; -----------------------------------------------------------------------
;; Test: input-region helpers (input-end, input-start, clamp)
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-input-end-from-input-property ()
  "`meow-ghostel--input-end' prefers the OSC 133 `ghostel-input' region."
  (meow-ghostel-test--with-cursor-fixture "$ " "hello" ""
    (cl-letf (((symbol-function 'meow-ghostel--suggestion-p)
               (lambda (&rest _) nil)))
      (should (= (point-max) (meow-ghostel--input-end))))))

(ert-deftest meow-ghostel-test-input-end-excludes-suggestion ()
  "A trailing run flagged as a suggestion moves the boundary to the cursor."
  (meow-ghostel-test--with-cursor-fixture "$ " "ls" " --all"
    (cl-letf (((symbol-function 'meow-ghostel--suggestion-p)
               (lambda (&rest _) t)))
      (should (= ghostel--cursor-char-pos (meow-ghostel--input-end))))))

(ert-deftest meow-ghostel-test-input-end-strips-padding ()
  "Without a `ghostel-input' region, trailing blanks are stripped,
but never past the live cursor."
  (meow-ghostel-test--with-input-fixture "$ " "hi   "
    ;; Cursor sits at the end of "hi   "; padding strip stops at it.
    (should (= ghostel--cursor-char-pos (meow-ghostel--input-end)))
    ;; With the cursor after the typed text, padding is stripped to "hi".
    (setq ghostel--cursor-char-pos 5)   ; after "hi"
    (setq ghostel--cursor-pos '(4 . 0))
    (should (= 5 (meow-ghostel--input-end)))))

(ert-deftest meow-ghostel-test-input-start-nil-without-prompt ()
  "`meow-ghostel--input-start' is nil when no prompt is recognized.
The clamp then leaves BEG alone instead of collapsing the range."
  (meow-ghostel-test--with-meow-buffer
   (insert "no prompt here")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-char-pos (point-max))
   (setq-local ghostel--cursor-pos (cons (current-column) 0))
   (let ((ghostel-prompt-regexp nil))
     (should-not (meow-ghostel--input-start)))))

(ert-deftest meow-ghostel-test-clamp ()
  "`meow-ghostel--clamp' raises BEG to input-start, lowers END to input-end."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    ;; Prompt is positions 1-2, input 3-7, cursor at 8.
    (let ((clamped (meow-ghostel--clamp 1 (point-max))))
      (should (= 3 (car clamped)))
      (should (= (point-max) (cdr clamped))))
    ;; END never below BEG.
    (cl-letf (((symbol-function 'meow-ghostel--input-end) (lambda () 4)))
      (let ((clamped (meow-ghostel--clamp 6 7)))
        (should (= 6 (car clamped)))
        (should (= 6 (cdr clamped)))))))

;; -----------------------------------------------------------------------
;; Test: insert / append / open commands
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-insert-drives-shell-cursor ()
  "`meow-ghostel-insert' drives the shell cursor to point and enters insert."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 4)
    (let ((target nil))
      (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (pos &rest _) (setq target pos) (goto-char pos) t)))
        (meow-ghostel-insert))
      (should (= 4 target))
      (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-insert-goes-to-selection-start ()
  "With a selection, `meow-ghostel-insert' targets the region beginning."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 6)
    (push-mark 4 t t)
    (let ((target nil))
      (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (pos &rest _) (setq target pos) (goto-char pos) t)))
        (meow-ghostel-insert))
      (should (= 4 target))
      (should-not (region-active-p))
      (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-append-goes-to-selection-end ()
  "With a selection, `meow-ghostel-append' targets the region end."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 4)
    (push-mark 6 t t)
    (let ((target nil))
      (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (pos &rest _) (setq target pos) (goto-char pos) t)))
        (meow-ghostel-append))
      (should (= 6 target))
      (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-append-no-selection-stays-at-point ()
  "Without a selection or the cursor-position hack, append is insert-at-point.
Meow treats point as sitting between characters."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 5)
    (let ((meow-use-cursor-position-hack nil)
          (target nil))
      (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (pos &rest _) (setq target pos) (goto-char pos) t)))
        (meow-ghostel-append))
      (should (= 5 target))
      (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-append-hack-advances-within-input ()
  "With `meow-use-cursor-position-hack', append advances one char."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 5)
    (let ((meow-use-cursor-position-hack t)
          (target nil))
      (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (pos &rest _) (setq target pos) (goto-char pos) t)))
        (meow-ghostel-append))
      (should (= 6 target)))))

(ert-deftest meow-ghostel-test-append-hack-at-cursor-does-not-advance ()
  "With the hack, append at the cursor with padding does not advance (#493).
An advance onto an RPROMPT padding cell would desync point from the
PTY cursor."
  (meow-ghostel-test--with-meow-buffer
   (insert "word")
   (insert (make-string 10 ?\s))
   (insert "rprompt")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--cursor-pos '(4 . 0))
   (setq-local ghostel--cursor-char-pos 5)
   (meow--switch-state 'normal)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'meow-ghostel-goto-input-position)
              (lambda (pos &rest _) (goto-char pos) t))
             ((symbol-function 'meow-ghostel--insert-enter) #'ignore))
     (goto-char 5)                     ; point AT the cursor (end of input)
     (let ((meow-use-cursor-position-hack t))
       (meow-ghostel-append))
     (should (= 5 (point)))
     (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-open-below-goes-to-input-end-no-ret ()
  "`meow-ghostel-open-below' targets input-end and NEVER sends RET.
Vanilla `meow-open-below' sends a literal RET keyboard macro, which in
a terminal executes the current command line."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 4)
    (let ((sent '())
          (target nil))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (pos &rest _) (setq target pos) (goto-char pos) t)))
        (meow-ghostel-open-below))
      (should (equal (point-max) target))
      (should (meow-insert-mode-p))
      (should-not (cl-find "return" sent :key #'car :test #'equal))
      (should-not (cl-find "enter" sent :key #'car :test #'equal)))))

(ert-deftest meow-ghostel-test-open-above-goes-to-input-start ()
  "`meow-ghostel-open-above' targets the input start (after the prompt)."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 6)
    (let ((target nil))
      (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (pos &rest _) (setq target pos) (goto-char pos) t)))
        (meow-ghostel-open-above))
      (should (= 3 target))
      (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-insert-enter-hook-syncs-column-same-row ()
  "Direct insert-state entry drives the PTY cursor to point (same row)."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 4)
    (let ((target nil))
      (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (pos &rest _) (setq target pos) t)))
        (meow--switch-state 'insert))
      (should (= 4 target)))))

(ert-deftest meow-ghostel-test-insert-enter-hook-no-vertical-sync ()
  "Insert entry on a different row snaps point back to the cursor.
Driving the cursor across rows would be read as history navigation."
  (meow-ghostel-test--with-meow-buffer
   (insert "line-one\nline-two")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--term-rows 2)
   (setq-local ghostel--cursor-pos '(8 . 1))
   (setq-local ghostel--cursor-char-pos (point-max))
   (meow--switch-state 'normal)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (goto-char (point-min))           ; row 0, cursor is on row 1
     (let ((arrows '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _) (push (cons key mods) arrows))))
         (meow--switch-state 'insert))
       (should-not arrows)
       (should (= (point) (point-max)))))))

(ert-deftest meow-ghostel-test-insert-enter-hook-no-op-outside-ghostel ()
  "The insert-enter hook does nothing outside ghostel buffers."
  (with-temp-buffer
    (meow-mode 1)
    (let ((moved nil))
      (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                 (lambda (&rest _) (setq moved t)))
                ((symbol-function 'meow-ghostel--reset-cursor-point)
                 (lambda () (setq moved t))))
        (meow-ghostel--insert-enter))
      (should-not moved))))

;; -----------------------------------------------------------------------
;; Test: kill / delete commands
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-kill-sends-backspaces-and-fills-kill-ring ()
  "`meow-ghostel-kill' backspaces over the selection and saves the text."
  (meow-ghostel-test--with-input-fixture "$ " "hello world"
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (keys-sent '()))
      (goto-char 3)                     ; start of "hello"
      (push-mark 8 t t)                 ; "hello"
      (exchange-point-and-mark)         ; point at 8, mark 3
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (meow-ghostel-kill))
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal)))
      (should (equal "hello" (car kill-ring)))
      (should-not (region-active-p)))))

(ert-deftest meow-ghostel-test-kill-clamps-selection-overshoot ()
  "A selection reaching into the prompt is clamped to input-start."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (keys-sent '()))
      (goto-char (point-min))           ; inside the prompt
      (push-mark (point-max) t t)
      (exchange-point-and-mark)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (meow-ghostel-kill))
      ;; Only "hello" (5 chars), not the "$ " prompt.
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal)))
      (should (equal "hello" (car kill-ring))))))

(ert-deftest meow-ghostel-test-kill-no-selection-falls-back-to-C-k ()
  "Without a selection, kill routes through the fallback (meow-C-k),
which dispatches through `command-remapping' to the PTY variant."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (keys-sent '()))
      (goto-char 5)                     ; "he|llo"
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (meow-ghostel-kill))
      ;; C-k analog: delete point..input-end = "llo".
      (should (= 3 (cl-count "backspace" keys-sent :test #'equal)))
      (should (equal "llo" (car kill-ring))))))

(ert-deftest meow-ghostel-test-kill-append-appends ()
  "`meow-ghostel-kill-append' appends the deleted text to the last kill."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring (list "prev"))
          (kill-ring-yank-pointer nil)
          (keys-sent '()))
      (setq kill-ring-yank-pointer kill-ring)
      (goto-char 3)
      (push-mark 6 t t)                 ; "hel"
      (exchange-point-and-mark)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (meow-ghostel-kill-append))
      (should (= 3 (cl-count "backspace" keys-sent :test #'equal)))
      (should (string-match-p "hel" (car kill-ring)))
      (should (string-match-p "prev" (car kill-ring))))))

(ert-deftest meow-ghostel-test-kill-whole-line-clamps-to-input ()
  "`meow-ghostel-kill-whole-line' deletes the clamped input, not the prompt."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (keys-sent '()))
      (goto-char 5)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (meow-ghostel-kill-whole-line))
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal)))
      (should (equal "hello" (car kill-ring))))))

(ert-deftest meow-ghostel-test-C-d-deletes-at-point ()
  "`meow-ghostel-C-d' forward-deletes at point, not at the cursor.
Sends arrows first when point is off the cursor, then a delete."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((sent '()))
      (goto-char 3)                     ; point at "h", cursor at end
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'meow-ghostel--sync-render) #'ignore))
        (meow-ghostel-C-d))
      (setq sent (nreverse sent))
      ;; 5 left arrows to reach point, then one forward-delete.
      (should (= 5 (cl-count "left" sent :key #'car :test #'equal)))
      (should (equal '("delete" . "") (car (last sent)))))))

(ert-deftest meow-ghostel-test-backspace-deletes-at-point ()
  "`meow-ghostel-backspace' backward-deletes at point over the PTY."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((sent '()))
      (goto-char 5)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'meow-ghostel--sync-render) #'ignore))
        (meow-ghostel-backspace))
      (setq sent (nreverse sent))
      (should (equal '("backspace" . "") (car (last sent)))))))

(ert-deftest meow-ghostel-test-kill-word-routes-via-delete-region-function ()
  "`meow-kill-word' PTY-routes through `meow--delete-region-function'.
Its primary `kill-region' path signals on the read-only buffer and
falls back to `meow--delete-region' — carried by our buffer-local
function variable, no remap involved."
  (meow-ghostel-test--with-input-fixture "$ " "hello world"
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (keys-sent '()))
      (goto-char 3)                     ; start of "hello"
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (meow-kill-word 1))
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal))))))

;; -----------------------------------------------------------------------
;; Test: change commands
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-change-deletes-and-enters-insert ()
  "`meow-ghostel-change' deletes the selection and enters insert state.
Like `meow-change', the text does not land on the kill ring."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (keys-sent '()))
      (goto-char 3)
      (push-mark 8 t t)
      (exchange-point-and-mark)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent)))
                ((symbol-function 'meow-ghostel--insert-enter) #'ignore))
        (meow-ghostel-change))
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal)))
      (should-not kill-ring)
      (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-change-no-selection-falls-back-to-change-char ()
  "Without a selection, change falls back to the change-char PTY variant."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((sent '()))
      (goto-char 3)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'meow-ghostel--sync-render) #'ignore)
                ((symbol-function 'meow-ghostel--insert-enter) #'ignore))
        (meow-ghostel-change))
      (should (cl-find "delete" sent :key #'car :test #'equal))
      (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-change-save-kills-then-inserts ()
  "`meow-ghostel-change-save' saves the text and enters insert state."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (keys-sent '()))
      (goto-char 3)
      (push-mark 8 t t)
      (exchange-point-and-mark)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent)))
                ((symbol-function 'meow-ghostel--insert-enter) #'ignore))
        (meow-ghostel-change-save))
      (should (equal "hello" (car kill-ring)))
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal)))
      (should (meow-insert-mode-p)))))

;; -----------------------------------------------------------------------
;; Test: replace commands
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-replace-pastes-kill-over-selection ()
  "`meow-ghostel-replace' deletes the selection and pastes the kill."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring (list "NEW"))
          (kill-ring-yank-pointer nil)
          (keys-sent '())
          (pasted nil))
      (setq kill-ring-yank-pointer kill-ring)
      (goto-char 3)
      (push-mark 8 t t)
      (exchange-point-and-mark)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent)))
                ((symbol-function 'ghostel--paste-text)
                 (lambda (text) (setq pasted text))))
        (meow-ghostel-replace))
      (should (= 5 (cl-count "backspace" keys-sent :test #'equal)))
      (should (equal "NEW" pasted)))))

(ert-deftest meow-ghostel-test-replace-char-replaces-one ()
  "`meow-ghostel-replace-char' replaces the char at point with the kill."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring (list "X"))
          (kill-ring-yank-pointer nil)
          (keys-sent '())
          (pasted nil))
      (setq kill-ring-yank-pointer kill-ring)
      (goto-char 3)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent)))
                ((symbol-function 'ghostel--paste-text)
                 (lambda (text) (setq pasted text))))
        (meow-ghostel-replace-char))
      (should (= 1 (cl-count "backspace" keys-sent :test #'equal)))
      (should (equal "X" pasted)))))

;; -----------------------------------------------------------------------
;; Test: yank / undo
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-yank-pastes-at-point-not-cursor ()
  "`meow-ghostel-yank' drives the cursor to point before pasting.
Vanilla `meow-yank' resolves C-y to `ghostel-yank', which pastes at
the terminal cursor regardless of point."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring (list "PASTE"))
          (kill-ring-yank-pointer nil)
          (sent '())
          (pasted nil))
      (setq kill-ring-yank-pointer kill-ring)
      (goto-char 3)                     ; point off the cursor
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent)))
                ((symbol-function 'meow-ghostel--sync-render) #'ignore)
                ((symbol-function 'ghostel--paste-text)
                 (lambda (text) (setq pasted text))))
        (meow-ghostel-yank))
      ;; Arrows to reach point, then bracketed paste.
      (should (= 5 (cl-count "left" sent :key #'car :test #'equal)))
      (should (equal "PASTE" pasted)))))

(ert-deftest meow-ghostel-test-yank-pop-signals-user-error ()
  "`meow-ghostel-yank-pop' signals a `user-error' in semi-char."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (should-error (meow-ghostel-yank-pop) :type 'user-error)))

(ert-deftest meow-ghostel-test-undo-sends-ctrl-underscore ()
  "`meow-ghostel-undo' sends Ctrl+_ and cancels the selection."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((sent '()))
      (goto-char 3)
      (push-mark 6 t t)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent))))
        (meow-ghostel-undo))
      (should (equal '(("_" . "ctrl")) sent))
      (should-not (region-active-p)))))

;; -----------------------------------------------------------------------
;; Test: kbd-macro overrides (motions must not hit the PTY)
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-meow-next-moves-point-without-pty ()
  "`meow-next' moves point via the kbd override; zero PTY traffic.
Without the override C-n resolves to a PTY sender = shell history."
  (meow-ghostel-test--with-meow-buffer
   (insert "line-one\nline-two\nline-three")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--term-rows 3)
   (setq-local ghostel--cursor-pos '(0 . 2))
   (setq-local ghostel--cursor-char-pos (1- (point-max)))
   (meow--switch-state 'normal)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (goto-char (point-min))
     (let ((sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _) (push (cons key mods) sent))))
         (meow-next nil))
       (should-not sent)
       (should (= 2 (line-number-at-pos)))))))

(ert-deftest meow-ghostel-test-meow-next-clamps-at-cursor-row ()
  "`meow-next' cannot move below the terminal cursor's row."
  (meow-ghostel-test--with-meow-buffer
   (insert "line-one\nline-two\nline-three")
   (setq-local ghostel--term 'fake)
   (setq-local ghostel--term-rows 3)
   (setq-local ghostel--cursor-pos '(0 . 1)) ; cursor on line-two
   (setq-local ghostel--cursor-char-pos 10)
   (meow--switch-state 'normal)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (goto-char (point-min))
     (meow-next nil)
     (should (= 2 (line-number-at-pos)))
     (meow-next nil)                    ; would land on line-three
     (should (= 2 (line-number-at-pos))))))

(ert-deftest meow-ghostel-test-meow-left-right-move-point-without-pty ()
  "`meow-left' / `meow-right' are pure point motion; zero PTY traffic."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char 5)
    (let ((sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent))))
        (meow-left)
        (should (= 4 (point)))
        (meow-right)
        (should (= 5 (point))))
      (should-not sent))))

(ert-deftest meow-ghostel-test-back-to-indentation-goes-to-input-start ()
  "`meow-back-to-indentation' lands after the prompt, not at buffer BOL."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (goto-char (point-max))
    (let ((sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent))))
        (meow-back-to-indentation))
      (should-not sent)
      (should (= 3 (point))))))

(ert-deftest meow-ghostel-test-meow-save-copies-without-pty ()
  "`meow-save' copies the selection; the M-w kbd macro must not reach
the PTY (ghostel's semi-char map binds M-w to a sender)."
  (meow-ghostel-test--with-input-fixture "$ " "hello"
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (sent '()))
      (goto-char 3)
      (push-mark 8 t t)
      (exchange-point-and-mark)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _) (push (cons key mods) sent))))
        (meow-save))
      (should-not sent)
      (should (equal "hello" (car kill-ring))))))

;; -----------------------------------------------------------------------
;; Test: line mode
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-line-mode-active-p ()
  "`meow-ghostel--line-mode-active-p' is true with markers in line mode."
  (meow-ghostel-test--with-line-mode "$ echo hello" 3 13
    (should (meow-ghostel--line-mode-active-p))
    (should-not (meow-ghostel--active-p))))

(ert-deftest meow-ghostel-test-line-mode-active-p-needs-markers ()
  "Predicate returns nil in line mode if the input markers are unset."
  (meow-ghostel-test--with-meow-buffer
   (setq-local ghostel--input-mode 'line)
   (setq-local ghostel--line-input-start nil)
   (setq-local ghostel--line-input-end nil)
   (should-not (meow-ghostel--line-mode-active-p))))

(ert-deftest meow-ghostel-test-insert-enter-skips-sync-in-line-mode ()
  "The insert-enter hook does not touch cursor sync in line mode."
  (meow-ghostel-test--with-line-mode "$ echo hi" 3 10
    (cl-letf ((ghostel--cursor-pos '(0 . 0)))
      (meow--switch-state 'normal)
      (let ((sync-called nil))
        (cl-letf (((symbol-function 'meow-ghostel-goto-input-position)
                   (lambda (&rest _) (setq sync-called t)))
                  ((symbol-function 'meow-ghostel--reset-cursor-point)
                   (lambda () (setq sync-called t))))
          (meow--switch-state 'insert))
        (should-not sync-called)))))

(ert-deftest meow-ghostel-test-open-above-jumps-to-line-input-start ()
  "Open-above in line mode lands at `ghostel--line-input-start'."
  (meow-ghostel-test--with-line-mode "$ echo hello" 3 13
    (meow--switch-state 'normal)
    (goto-char (point-max))
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (meow-ghostel-open-above))
      (should (= (point) 3))
      (should (meow-insert-mode-p))
      (should-not keys-sent))))

(ert-deftest meow-ghostel-test-open-below-jumps-to-line-input-end ()
  "Open-below in line mode lands at `ghostel--line-input-end'."
  (meow-ghostel-test--with-line-mode "$ echo hello" 3 13
    (meow--switch-state 'normal)
    (goto-char (point-min))
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _) (push key keys-sent))))
        (meow-ghostel-open-below))
      (should (= (point) 13))
      (should (meow-insert-mode-p))
      (should-not keys-sent))))

(ert-deftest meow-ghostel-test-kill-edits-buffer-in-line-mode ()
  "Kill in line mode falls through to vanilla meow and edits the text.
The kbd override resolves `meow--kbd-kill-region' to `kill-region'
directly, so line mode's own keymap cannot misroute it."
  (meow-ghostel-test--with-line-mode "hello world" 1 12
    (meow--switch-state 'normal)
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil)
          (bs-count 0))
      (goto-char (point-min))
      (push-mark 6 t t)
      (exchange-point-and-mark)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (when (equal key "backspace") (cl-incf bs-count)))))
        (meow-ghostel-kill))
      (should (= bs-count 0))
      (should (equal " world" (buffer-string)))
      (should (equal "hello" (car kill-ring))))))

;; -----------------------------------------------------------------------
;; Test: fall-through outside ghostel / when inactive
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-kill-no-op-outside-ghostel ()
  "The PTY variants call vanilla meow outside ghostel buffers."
  (with-temp-buffer
    (meow-mode 1)
    (meow--switch-state 'normal)
    (insert "hello world")
    (let ((kill-ring nil)
          (kill-ring-yank-pointer nil))
      (goto-char (point-min))
      (push-mark 6 t t)
      (exchange-point-and-mark)
      (meow-ghostel-kill)
      (should (equal " world" (buffer-string))))))

(ert-deftest meow-ghostel-test-active-p-guards ()
  "`meow-ghostel--active-p' requires semi-char and no alt-screen."
  (meow-ghostel-test--with-meow-buffer
   (setq-local ghostel--term 'fake)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (should (meow-ghostel--active-p))
     (let ((ghostel--input-mode 'copy))
       (should-not (meow-ghostel--active-p)))
     (let ((ghostel--input-mode 'char))
       (should-not (meow-ghostel--active-p))))
   ;; Alt-screen: inactive even in semi-char.
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) t)))
     (should-not (meow-ghostel--active-p)))
   ;; No terminal handle: inactive.
   (setq-local ghostel--term nil)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil)))
     (should-not (meow-ghostel--active-p)))))

;; -----------------------------------------------------------------------
;; Test: cursor style override
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-cursor-style-override ()
  "Outside alt-screen meow owns the cursor; in alt-screen the terminal does."
  (meow-ghostel-test--with-meow-buffer
   (setq-local ghostel--term 'fake)
   (let ((blink-stopped nil)
         (meow-updated nil)
         (orig-called nil))
     (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
               ((symbol-function 'ghostel--cursor-blink-stop)
                (lambda () (setq blink-stopped t)))
               ((symbol-function 'meow--update-cursor)
                (lambda () (setq meow-updated t))))
       (meow-ghostel--override-cursor-style
        (lambda () (setq orig-called t)))
       (should blink-stopped)
       (should meow-updated)
       (should-not orig-called))
     ;; Alt-screen: defer to the terminal's style.
     (setq blink-stopped nil meow-updated nil orig-called nil)
     (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) t)))
       (meow-ghostel--override-cursor-style
        (lambda () (setq orig-called t)))
       (should orig-called)
       (should-not blink-stopped)))))

;; -----------------------------------------------------------------------
;; Test: ESC routing
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-escape-init-from-defcustom ()
  "Activating the mode initializes `meow-ghostel--escape-mode'."
  (let ((meow-ghostel-escape 'terminal))
    (meow-ghostel-test--with-meow-buffer
     (should (eq 'terminal meow-ghostel--escape-mode)))))

(ert-deftest meow-ghostel-test-escape-mode-terminal-sends-pty ()
  "In `terminal' mode ESC goes to the PTY; insert state stays."
  (meow-ghostel-test--with-meow-buffer
   (meow-ghostel-test--with-escape-stubs nil
     (setq meow-ghostel--escape-mode 'terminal)
     (cl-letf (((symbol-function 'meow-ghostel--insert-enter) #'ignore))
       (meow--switch-state 'insert))
     (meow-ghostel-escape)
     (should (equal '(("escape" . "")) sent))
     (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-escape-terminal-runs-user-input-hook ()
  "Terminal-bound ESC runs `ghostel--on-user-input' housekeeping."
  (meow-ghostel-test--with-meow-buffer
   (meow-ghostel-test--with-escape-stubs nil
     (setq meow-ghostel--escape-mode 'terminal)
     (let ((user-input-called nil))
       (cl-letf (((symbol-function 'ghostel--on-user-input)
                  (lambda (&rest _) (setq user-input-called t))))
         (meow-ghostel-escape))
       (should user-input-called)))))

(ert-deftest meow-ghostel-test-escape-mode-meow-exits-insert ()
  "In `meow' mode ESC runs `meow-insert-exit' -> normal state."
  (meow-ghostel-test--with-meow-buffer
   (meow-ghostel-test--with-escape-stubs nil
     (setq meow-ghostel--escape-mode 'meow)
     (cl-letf (((symbol-function 'meow-ghostel--insert-enter) #'ignore))
       (meow--switch-state 'insert))
     (meow-ghostel-escape)
     (should-not sent)
     (should (meow-normal-mode-p)))))

(ert-deftest meow-ghostel-test-escape-auto-altscreen-sends-pty ()
  "In `auto' mode with alt-screen active, ESC goes to the PTY."
  (meow-ghostel-test--with-meow-buffer
   (meow-ghostel-test--with-escape-stubs t
     (setq meow-ghostel--escape-mode 'auto)
     (cl-letf (((symbol-function 'meow-ghostel--insert-enter) #'ignore))
       (meow--switch-state 'insert))
     (meow-ghostel-escape)
     (should (equal '(("escape" . "")) sent))
     (should (meow-insert-mode-p)))))

(ert-deftest meow-ghostel-test-escape-auto-no-altscreen-exits-insert ()
  "In `auto' mode without alt-screen, ESC exits insert state."
  (meow-ghostel-test--with-meow-buffer
   (meow-ghostel-test--with-escape-stubs nil
     (setq meow-ghostel--escape-mode 'auto)
     (cl-letf (((symbol-function 'meow-ghostel--insert-enter) #'ignore))
       (meow--switch-state 'insert))
     (meow-ghostel-escape)
     (should-not sent)
     (should (meow-normal-mode-p)))))

(ert-deftest meow-ghostel-test-escape-toggle-cycle ()
  "`meow-ghostel-toggle-send-escape' cycles auto -> terminal -> meow."
  (meow-ghostel-test--with-meow-buffer
   (setq meow-ghostel--escape-mode 'auto)
   (meow-ghostel-toggle-send-escape)
   (should (eq 'terminal meow-ghostel--escape-mode))
   (meow-ghostel-toggle-send-escape)
   (should (eq 'meow meow-ghostel--escape-mode))
   (meow-ghostel-toggle-send-escape)
   (should (eq 'auto meow-ghostel--escape-mode))))

(ert-deftest meow-ghostel-test-escape-toggle-prefix-set ()
  "Numeric prefixes 1/2/3 set auto/terminal/meow directly."
  (meow-ghostel-test--with-meow-buffer
   (meow-ghostel-toggle-send-escape 2)
   (should (eq 'terminal meow-ghostel--escape-mode))
   (meow-ghostel-toggle-send-escape 3)
   (should (eq 'meow meow-ghostel--escape-mode))
   (meow-ghostel-toggle-send-escape 1)
   (should (eq 'auto meow-ghostel--escape-mode))))

(ert-deftest meow-ghostel-test-escape-toggle-prefix-invalid ()
  "An out-of-range prefix signals a `user-error'."
  (meow-ghostel-test--with-meow-buffer
   (should-error (meow-ghostel-toggle-send-escape 4) :type 'user-error)))

(ert-deftest meow-ghostel-test-escape-mode-buffer-local ()
  "The ESC routing mode is buffer-local."
  (let ((a (generate-new-buffer " *meow-ghostel-test-esc-a*"))
        (b (generate-new-buffer " *meow-ghostel-test-esc-b*")))
    (unwind-protect
        (progn
          (dolist (buf (list a b))
            (with-current-buffer buf
              (ghostel-mode)
              (setq-local ghostel--term-rows 100)
              (meow-mode 1)
              (meow-ghostel-mode 1)))
          (with-current-buffer a
            (meow-ghostel-toggle-send-escape 2)
            (should (eq 'terminal meow-ghostel--escape-mode)))
          (with-current-buffer b
            (should (eq meow-ghostel-escape meow-ghostel--escape-mode))))
      (when (buffer-live-p a) (kill-buffer a))
      (when (buffer-live-p b) (kill-buffer b)))))

;; -----------------------------------------------------------------------
;; Test: native module end-to-end
;; -----------------------------------------------------------------------

(ert-deftest meow-ghostel-test-goto-input-position-end-to-end ()
  "End-to-end: `meow-ghostel-goto-input-position' sends LEFT arrows
against a real libghostty terminal."
  (meow-ghostel-test--with-buffer 5 40 "$ echo hello world"
    (should (equal '(18 . 0) ghostel--cursor-pos))
    (let ((keys-sent '()))
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key _mods &rest _)
                   (push key keys-sent))))
        ;; Target: position 8 = column 7 (start of "hello").
        (meow-ghostel-goto-input-position 8))
      (should (= 11 (length keys-sent)))
      (should (cl-every (lambda (k) (equal k "left")) keys-sent)))))

(ert-deftest meow-ghostel-test-goto-input-position-with-scrollback ()
  "Regression: goto-input-position subtracts scrollback from buffer lines."
  (skip-unless (fboundp 'ghostel--new))
  (with-temp-buffer
    (ghostel-mode)
    (let ((term (ghostel--new 5 40 1000)))
      (setq-local ghostel--term term)
      (setq-local ghostel--term-rows 5)
      (dotimes (i 12)
        (ghostel--write-vt term (format "row-%02d\r\n" i)))
      (ghostel--write-vt term "tail")
      (meow-mode 1)
      (meow-ghostel-mode 1)
      (let ((inhibit-read-only t))
        (ghostel--redraw term t))
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
            (meow-ghostel-goto-input-position target-pos))
          (should (= 1 (length keys-sent)))
          (should (equal "up" (car keys-sent))))))))

(ert-deftest meow-ghostel-test-redraw-preserves-point-normal-native ()
  "Native: redraws preserve point in meow normal state."
  (meow-ghostel-test--with-buffer 5 40 "first\r\nsecond\r\nthird"
    (meow--switch-state 'normal)
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (goto-char (point-min))
      (move-to-column 3)
      (let ((inhibit-read-only t))
        (ghostel--redraw term t))
      (should (= 3 (current-column)))
      (should (= 1 (line-number-at-pos))))))

(ert-deftest meow-ghostel-test-redraw-moves-point-insert-native ()
  "Native: redraws snap point to the terminal cursor in insert state."
  (meow-ghostel-test--with-buffer 5 40 "hello world"
    (cl-letf (((symbol-function 'meow-ghostel--insert-enter) #'ignore))
      (meow--switch-state 'insert))
    (goto-char (point-min))
    (let ((inhibit-read-only t))
      (ghostel--redraw term t))
    (should (= 11 (current-column)))))

;; -----------------------------------------------------------------------
;; Runner
;; -----------------------------------------------------------------------

(defun meow-ghostel-test-run ()
  "Run all meow-ghostel tests in batch mode."
  (ert-run-tests-batch-and-exit "^meow-ghostel-test-"))

(provide 'meow-ghostel-test)
;;; meow-ghostel-test.el ends here
