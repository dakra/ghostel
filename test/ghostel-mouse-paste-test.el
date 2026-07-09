;;; ghostel-mouse-paste-test.el --- Tests for ghostel: mouse-paste -*- lexical-binding: t; -*-

;;; Commentary:

;; Mouse events, xterm-paste, yank-pop, readonly-copy / readonly-RET, focus
;; events, scroll-on-input, scroll-intercept.

;;; Code:

(require 'ghostel-test-helpers)

(defvar xterm-store-paste-on-kill-ring)

(defun ghostel-test--make-focus-buffer (name)
  "Create a ghostel-mode buffer NAME with a fake term and live process.
Returns the buffer."
  (let ((buf (generate-new-buffer name)))
    (with-current-buffer buf
      (ghostel-mode)
      (setq ghostel--term (vector 'fake-term))
      (setq ghostel--process
            (start-process (concat "ghostel-test-focus-" name)
                           nil "cat"))
      (set-process-query-on-exit-flag ghostel--process nil))
    buf))

(defun ghostel-test--cleanup-focus-buffer (buf)
  "Kill BUF and its fake process."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and ghostel--process (process-live-p ghostel--process))
        (delete-process ghostel--process)))
    (kill-buffer buf)))

(defmacro ghostel-test--with-focus-stub (events-var focus-fn &rest body)
  "Run BODY with `ghostel--focus-event' and `frame-focus-state' stubbed.
EVENTS-VAR names a list that receives (BUFFER . FOCUSED) pairs.
FOCUS-FN is a zero-arg function returning the current `frame-focus-state'."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'ghostel--focus-event)
              (lambda (_term focused)
                (push (cons (current-buffer) focused) ,events-var)
                t))
             ((symbol-function 'frame-focus-state)
              (lambda (&optional _frame) (funcall ,focus-fn))))
     ,@body))

(ert-deftest ghostel-test-focus-events ()
  "Test that focus events are only sent when mode 1004 is enabled."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (should (equal nil (ghostel--focus-event term t)))     ; focus ignored without mode 1004
    ;; Enable mode 1004 via DECSET
    (ghostel--write-vt term "\e[?1004h")
    (should (equal t (ghostel--focus-event term t)))       ; focus sent with mode 1004
    (should (equal t (ghostel--focus-event term nil)))     ; focus-out sent with mode 1004
    ;; Disable mode 1004 via DECRST
    (ghostel--write-vt term "\e[?1004l")
    (should (equal nil (ghostel--focus-event term t)))))   ; focus ignored after reset

(ert-deftest ghostel-test-focus-window-selection ()
  "Window selection changes flip per-buffer focus state."
  (let* ((events nil)
         (focus-fn (lambda () t))
         (buf (ghostel-test--make-focus-buffer " *ghostel-focus-1*"))
         (other (generate-new-buffer " *other*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test--with-focus-stub events focus-fn
          (delete-other-windows)
          (switch-to-buffer buf)
          (let ((other-win (split-window)))
            (set-window-buffer other-win other)
            ;; ghostel window selected → focus-in
            (ghostel--focus-change)
            (should (equal (car events) (cons buf t)))
            ;; Select the other window → focus-out
            (select-window other-win)
            (setq events nil)
            (ghostel--focus-change)
            (should (equal (car events) (cons buf nil)))
            ;; Select ghostel window again → focus-in
            (select-window (get-buffer-window buf))
            (setq events nil)
            (ghostel--focus-change)
            (should (equal (car events) (cons buf t)))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf)
      (kill-buffer other))))

(ert-deftest ghostel-test-focus-dedup ()
  "Repeat calls with unchanged state do not re-send focus events."
  (let* ((events nil)
         (frame-focused t)
         (focus-fn (lambda () frame-focused))
         (buf (ghostel-test--make-focus-buffer " *ghostel-focus-dedup*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test--with-focus-stub events focus-fn
          (delete-other-windows)
          (switch-to-buffer buf)
          (ghostel--focus-change)          ; focus-in
          (ghostel--focus-change)          ; no-op (dedup)
          (ghostel--focus-change)          ; no-op (dedup)
          (should (equal events (list (cons buf t))))
          ;; Transition to focus-out, then confirm further calls dedup.
          (setq frame-focused nil)
          (ghostel--focus-change)          ; focus-out
          (ghostel--focus-change)          ; no-op (dedup)
          (should (equal events (list (cons buf nil) (cons buf t)))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf))))

(ert-deftest ghostel-test-focus-two-ghostel-buffers ()
  "Only the ghostel buffer in the selected window is focused."
  (let* ((events nil)
         (focus-fn (lambda () t))
         (buf-a (ghostel-test--make-focus-buffer " *ghostel-focus-a*"))
         (buf-b (ghostel-test--make-focus-buffer " *ghostel-focus-b*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test--with-focus-stub events focus-fn
          (delete-other-windows)
          (switch-to-buffer buf-a)
          (let ((win-b (split-window)))
            (set-window-buffer win-b buf-b)
            ;; A selected: A transitions nil→t, B stays nil (dedup).
            (ghostel--focus-change)
            (should (equal events (list (cons buf-a t))))
            ;; Select B: A transitions t→nil, B transitions nil→t.
            (select-window win-b)
            (setq events nil)
            (ghostel--focus-change)
            (should (= (length events) 2))
            (should (member (cons buf-a nil) events))
            (should (member (cons buf-b t) events))
            ;; Back to A: inverse transitions.
            (select-window (get-buffer-window buf-a))
            (setq events nil)
            (ghostel--focus-change)
            (should (= (length events) 2))
            (should (member (cons buf-a t) events))
            (should (member (cons buf-b nil) events))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf-a)
      (ghostel-test--cleanup-focus-buffer buf-b))))

(ert-deftest ghostel-test-focus-frame-blur ()
  "Frame losing focus drives the ghostel buffer to focus-out."
  (let* ((events nil)
         (frame-focused t)
         (focus-fn (lambda () frame-focused))
         (buf (ghostel-test--make-focus-buffer " *ghostel-focus-blur*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test--with-focus-stub events focus-fn
          (delete-other-windows)
          (switch-to-buffer buf)
          (ghostel--focus-change)          ; focus-in
          (should (equal (car events) (cons buf t)))
          (setq frame-focused nil)         ; simulate app blur
          (setq events nil)
          (ghostel--focus-change)
          (should (equal (car events) (cons buf nil)))
          (setq frame-focused t)           ; refocus
          (setq events nil)
          (ghostel--focus-change)
          (should (equal (car events) (cons buf t))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf))))

(ert-deftest ghostel-test-focus-skips-state-update-when-1004-off ()
  "Dropped events (mode 1004 off) do not update cached focus state.
Otherwise, enabling 1004 after a focus change would dedup away the
first real focus event."
  (let* ((events nil)
         (emit-p nil)
         (buf (ghostel-test--make-focus-buffer " *ghostel-focus-gated*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--focus-event)
                   (lambda (_term focused)
                     (when emit-p
                       (push (cons (current-buffer) focused) events))
                     emit-p))
                  ((symbol-function 'frame-focus-state)
                   (lambda (&optional _frame) t)))
          (delete-other-windows)
          (switch-to-buffer buf)
          ;; Mode 1004 off: event is dropped, state must remain nil.
          (ghostel--focus-change)
          (should (null events))
          (with-current-buffer buf
            (should (null ghostel--focus-state)))
          ;; Child now enables mode 1004.  Next focus-change must emit.
          (setq emit-p t)
          (ghostel--focus-change)
          (should (equal events (list (cons buf t)))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf))))

(ert-deftest ghostel-test-scroll-intercept-forwards-mouse-tracking ()
  "Scroll intercept forwards events when mouse tracking is active."
  (let ((ghostel--term 'fake)
        (ghostel--process 'fake)
        (ghostel--input-mode 'semi-char)
        (ghostel--scroll-intercept-active t)
        (mouse-event-args nil)
        ;; Fake wheel-up event at row 5, col 10
        (fake-event `(wheel-up (,(selected-window) 1 (10 . 5) 0))))
    ;; Mouse tracking active: ghostel--mouse-event returns non-nil
    (cl-letf (((symbol-function 'ghostel--mouse-event)
               (lambda (_term action button row col mods)
                 (setq mouse-event-args (list action button row col mods))
                 t))
              ((symbol-function 'process-live-p) (lambda (_p) t)))
      (ghostel--scroll-intercept-up fake-event)
      (should mouse-event-args)
      (should (equal 0 (nth 0 mouse-event-args)))   ; action = press
      (should (equal 4 (nth 1 mouse-event-args)))   ; button 4 = scroll up
      (should (equal 5 (nth 2 mouse-event-args)))   ; row
      (should (equal 10 (nth 3 mouse-event-args)))  ; col
      ;; Event should NOT be re-dispatched.
      (should-not unread-command-events))
    ;; Reset and test scroll-down with a wheel-down event
    (setq mouse-event-args nil)
    (let ((fake-down-event `(wheel-down (,(selected-window) 1 (10 . 5) 0))))
      (cl-letf (((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel--scroll-intercept-down fake-down-event)
        (should mouse-event-args)
        (should (equal 5 (nth 1 mouse-event-args)))   ; button 5 = scroll down
        (should-not unread-command-events)))))

(ert-deftest ghostel-test-scroll-intercept-fallthrough ()
  "Scroll intercept re-dispatches when mouse tracking is off."
  (let* ((event-buf (window-buffer (selected-window)))
         (fake-up-event `(wheel-up (,(selected-window) 1 (10 . 5) 0)))
         (fake-down-event `(wheel-down (,(selected-window) 1 (10 . 5) 0)))
         (unread-command-events nil))
    (with-current-buffer event-buf
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (setq-local ghostel--scroll-intercept-active t)
      (setq-local pre-command-hook nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--mouse-event)
                   (lambda (_term _action _button _row _col _mods) nil))
                  ((symbol-function 'process-live-p) (lambda (_p) t)))
          ;; Test wheel-up re-dispatch
          (ghostel--scroll-intercept-up fake-up-event)
          (should-not (buffer-local-value
                       'ghostel--scroll-intercept-active event-buf))
          (should (equal fake-up-event (car unread-command-events)))
          ;; Running the buffer-local pre-command-hook in event-buf
          ;; re-enables the intercept and removes the one-shot hook.
          (with-current-buffer event-buf
            (run-hooks 'pre-command-hook))
          (should (buffer-local-value
                   'ghostel--scroll-intercept-active event-buf))
          (should-not (buffer-local-value 'pre-command-hook event-buf))
          (setq unread-command-events nil)
          ;; Test wheel-down re-dispatch
          (ghostel--scroll-intercept-down fake-down-event)
          (should-not (buffer-local-value
                       'ghostel--scroll-intercept-active event-buf))
          (should (equal fake-down-event (car unread-command-events)))
          (with-current-buffer event-buf
            (run-hooks 'pre-command-hook))
          (should (buffer-local-value
                   'ghostel--scroll-intercept-active event-buf)))
      (with-current-buffer event-buf
        (kill-local-variable 'ghostel--term)
        (kill-local-variable 'ghostel--process)
        (kill-local-variable 'ghostel--input-mode)
        (kill-local-variable 'ghostel--scroll-intercept-active)
        (kill-local-variable 'pre-command-hook)))))

(ert-deftest ghostel-test-mouse-1-press-no-tracking-semi-char ()
  "Left-press in semi-char with no tracking does NOT enter copy mode.
In an already-focused window, the press hands EVENT off to
`mouse-drag-region'.  Copy mode is entered later by
`ghostel-mouse-drag-or-set-region' if the press grows into a drag,
so streaming output cannot clobber the resulting region."
  :tags '(native)
  (let ((fake-event `(down-mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (copy-mode-called nil)
        (drag-region-arg nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'mouse-drag-region)
                 (lambda (event) (setq drag-region-arg event)))
                ((symbol-function 'select-window) (lambda (&rest _) nil))
                ((symbol-function 'frame-focus-state)
                 (lambda (&optional _frame) t)))
        (ghostel-mouse-press-or-copy-mode fake-event))
      (should-not copy-mode-called)
      (should (equal fake-event drag-region-arg)))))

(ert-deftest ghostel-test-mouse-1-press-no-tracking-copy-mode ()
  "Left-press in copy mode hands off without re-toggling copy mode.
Calling `ghostel-copy-mode' while already in copy mode would exit it,
so the function must skip the toggle and go straight to drag-region."
  :tags '(native)
  (let ((fake-event `(down-mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (copy-mode-called nil)
        (drag-region-arg nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'copy)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'mouse-drag-region)
                 (lambda (event) (setq drag-region-arg event)))
                ((symbol-function 'select-window) (lambda (&rest _) nil)))
        (ghostel-mouse-press-or-copy-mode fake-event))
      (should-not copy-mode-called)
      (should (equal fake-event drag-region-arg)))))

(ert-deftest ghostel-test-mouse-1-press-tracking-copy-mode-selects ()
  "Left-press in copy mode selects even if terminal tracking is active."
  (let ((fake-event `(down-mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (drag-region-arg nil)
        (mouse-event-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--input-mode 'copy)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (eq mode 1000)))
                ((symbol-function 'mouse-drag-region)
                 (lambda (event) (setq drag-region-arg event)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) (setq mouse-event-called t) t))
                ((symbol-function 'process-live-p) (lambda (_p) t))
                ((symbol-function 'select-window) (lambda (&rest _) nil)))
        (ghostel-mouse-press-or-copy-mode fake-event))
      (should (equal fake-event drag-region-arg))
      (should-not mouse-event-called))))

(ert-deftest ghostel-test-mouse-1-release-tracking-copy-mode-sets-point ()
  "Left-release in copy mode sets point even if terminal tracking is active."
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (set-point-arg nil)
        (mouse-event-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--input-mode 'copy)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (eq mode 1000)))
                ((symbol-function 'mouse-set-point)
                 (lambda (event &optional _promote) (setq set-point-arg event)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) (setq mouse-event-called t) t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel-mouse-release-or-set-point fake-event))
      (should (equal fake-event set-point-arg))
      (should-not mouse-event-called))))

(ert-deftest ghostel-test-mouse-1-drag-tracking-copy-mode-sets-region ()
  "Left-drag in copy mode selects even if terminal tracking is active."
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (set-region-arg nil)
        (mouse-event-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--input-mode 'copy)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (eq mode 1000)))
                ((symbol-function 'mouse-set-region)
                 (lambda (event) (setq set-region-arg event)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) (setq mouse-event-called t) t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should (equal fake-event set-region-arg))
      (should-not mouse-event-called))))

(ert-deftest ghostel-test-mouse-1-press-no-tracking-line-mode ()
  "Left-press in line mode hands off to `mouse-drag-region' as-is.
Line mode keeps its own buffer state; we should not switch to copy
mode or otherwise interfere."
  :tags '(native)
  (let ((fake-event `(down-mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (copy-mode-called nil)
        (drag-region-arg nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'line)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'mouse-drag-region)
                 (lambda (event) (setq drag-region-arg event)))
                ((symbol-function 'select-window) (lambda (&rest _) nil)))
        (ghostel-mouse-press-or-copy-mode fake-event))
      (should-not copy-mode-called)
      (should (equal fake-event drag-region-arg)))))

(ert-deftest ghostel-test-mouse-1-release-unconsumed-sets-point ()
  "Release falls back to `mouse-set-point' when the terminal declines it."
  :tags '(native)
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (ghostel--mouse-press-was-selected t)
        (set-point-arg nil)
        (mouse-event-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (event &optional _promote) (setq set-point-arg event)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) (setq mouse-event-called t) nil)))
        (ghostel-mouse-release-or-set-point fake-event))
      (should (equal fake-event set-point-arg))
      (should mouse-event-called))))

(ert-deftest ghostel-test-mouse-1-release-no-tracking-promotes-multi-click ()
  "Release forwards PROMOTE-TO-REGION so double/triple-click selects.
A double-click release falls back to the single-click binding;
without forwarding the second arg, `mouse-set-point' would just
move point and clobber the word selection set by `mouse-drag-region'."
  :tags '(native)
  (let ((fake-event `(double-mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (ghostel--mouse-press-was-selected t)
        (set-point-promote nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (_event &optional promote) (setq set-point-promote promote))))
        (ghostel-mouse-release-or-set-point fake-event 1))
      (should (equal 1 set-point-promote)))))

(ert-deftest ghostel-test-mouse-1-release-multi-click-semi-char-enters-copy-mode ()
  "Multi-click release in semi-char enters copy mode after the region is set.
Mirrors the drag handler: terminal output that arrives after a
double/triple-click would otherwise overwrite the highlighted cells
and the live cursor advancing would extend the region."
  :tags '(native)
  (let ((fake-event `(double-mouse-1 (,(selected-window) 1 (10 . 5) 0) 2))
        (ghostel-mouse-drag-input-mode 'copy)
        (set-point-event nil)
        (copy-mode-called nil)
        (emacs-mode-called nil)
        (call-order nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (event &optional _promote)
                   (setq set-point-event event)
                   (push 'set-point call-order)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda ()
                   (setq copy-mode-called t)
                   (push 'copy-mode call-order)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel-mouse-release-or-set-point fake-event 1))
      (should (equal fake-event set-point-event))
      (should copy-mode-called)
      (should-not emacs-mode-called)
      (should (equal '(set-point copy-mode) (nreverse call-order))))))

(ert-deftest ghostel-test-mouse-1-release-single-click-already-selected-enters-copy-mode ()
  "Plain single click in an already-selected semi-char window enters copy mode.
Mirrors the drag/multi-click handlers: point is set first, then the
buffer freezes so streaming output cannot clobber the view."
  :tags '(native)
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (ghostel-mouse-drag-input-mode 'copy)
        (ghostel--mouse-press-was-selected t)
        (set-point-event nil)
        (copy-mode-called nil)
        (emacs-mode-called nil)
        (call-order nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (event &optional _promote)
                   (setq set-point-event event)
                   (push 'set-point call-order)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda ()
                   (setq copy-mode-called t)
                   (push 'copy-mode call-order)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel-mouse-release-or-set-point fake-event 1))
      (should (equal fake-event set-point-event))
      (should copy-mode-called)
      (should-not emacs-mode-called)
      ;; Point must be set before copy mode freezes the buffer.
      (should (equal '(set-point copy-mode) (nreverse call-order))))))

(ert-deftest ghostel-test-mouse-1-release-single-click-focus-click-only-focuses ()
  "A focus click of an unselected window only focuses.
With the feature on (`ghostel-mouse-drag-input-mode' non-nil) the click
does not enter copy mode (the #257 case), set point to the click, or snap
point to the live cursor (`ghostel--cursor-char-pos')."
  :tags '(native)
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (ghostel-mouse-drag-input-mode 'copy)
        (ghostel--mouse-press-was-selected nil)
        (set-point-called nil)
        (copy-mode-called nil))
    (with-temp-buffer
      (insert "hello world")
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (setq-local ghostel--cursor-char-pos 11)  ; live input position
      (goto-char 8)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (_event &optional _promote) (setq set-point-called t)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t))))
        (ghostel-mouse-release-or-set-point fake-event 1))
      (should-not set-point-called)
      (should-not copy-mode-called)
      ;; Point is left where it was before the focus-only release.
      (should (= (point) 8)))))

(ert-deftest ghostel-test-mouse-1-release-focus-click-feature-off-sets-point ()
  "With the feature off, a focus click sets point like standard Emacs.
When `ghostel-mouse-drag-input-mode' is nil, a single click in a
previously-unselected window sets point normally and enters no mode."
  :tags '(native)
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (ghostel-mouse-drag-input-mode nil)
        (ghostel--mouse-press-was-selected nil)
        (set-point-event nil)
        (copy-mode-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (event &optional _promote) (setq set-point-event event)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t))))
        (ghostel-mouse-release-or-set-point fake-event 1))
      (should (equal fake-event set-point-event))
      (should-not copy-mode-called))))

(ert-deftest ghostel-test-mouse-1-focus-click-preserves-scrollback-view ()
  "A focus click back into a scrolled window preserves its viewport."
  (let ((buf (generate-new-buffer " *ghostel-test-focus-scrollback*"))
        (other-buf (generate-new-buffer " *ghostel-test-focus-other*"))
        (orig-config (current-window-configuration))
        (ghostel-mouse-drag-input-mode 'copy))
    (unwind-protect
        (progn
          (delete-other-windows)
          (let ((ghostel-win (selected-window))
                (other-win (split-window-right)))
            (set-window-buffer ghostel-win buf)
            (set-window-buffer other-win other-buf)
            (with-current-buffer buf
              (ghostel-mode)
              (let ((inhibit-read-only t))
                (dotimes (i 80)
                  (insert (format "row-%02d\n" i))))
              (setq-local ghostel--term 'fake)
              (setq-local ghostel--input-mode 'semi-char)
              (setq-local ghostel--cursor-char-pos (point-max))
              (let ((saved-point (point-min))
                    (saved-start (point-min)))
                (set-window-point ghostel-win saved-point)
                (set-window-start ghostel-win saved-start t)
                (with-current-buffer other-buf
                  (setq-local ghostel--input-mode nil)
                  (select-window other-win)
                  (cl-letf (((symbol-function 'ghostel--mode-enabled)
                             (lambda (_term _mode) nil))
                            ((symbol-function 'ghostel--mouse-event)
                             (lambda (&rest _) nil))
                            ((symbol-function 'mouse-drag-region)
                             (lambda (_event)
                               (ert-fail "focus click called mouse-drag-region"))))
                    (ghostel-mouse-press-or-copy-mode
                     `(down-mouse-1 (,ghostel-win 1 (10 . 5) 0)))
                    (ghostel-mouse-release-or-set-point
                     `(mouse-1 (,ghostel-win 1 (10 . 5) 0)) 1)))
                (should (eq (selected-window) ghostel-win))
                (should (= (point) saved-point))
                (should (= (window-point ghostel-win) saved-point))
                (should (= (window-start ghostel-win) saved-start))))))
      (set-window-configuration orig-config)
      (kill-buffer buf)
      (kill-buffer other-buf))))

(ert-deftest ghostel-test-mouse-1-release-focus-click-hidden-cursor-does-not-anchor ()
  "A focus click with no visible terminal cursor preserves point and scroll."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-focus-hidden-cursor*"))
        (orig-buf (window-buffer (selected-window)))
        (ghostel-mouse-drag-input-mode 'copy)
        (ghostel--mouse-press-was-selected nil))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (let ((inhibit-read-only t))
              (dotimes (i 50)
                (insert (format "row-%02d\n" i))))
            (setq-local ghostel--term 'fake)
            (setq-local ghostel--input-mode 'semi-char)
            (setq-local ghostel--cursor-char-pos nil)
            (goto-char (point-min))
            (set-window-point (selected-window) (point-min))
            (set-window-start (selected-window) (point-min) t)
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (_term _mode) nil))
                      ((symbol-function 'ghostel--mouse-event)
                       (lambda (&rest _) nil)))
              (ghostel-mouse-release-or-set-point
               `(mouse-1 (,(selected-window) 1 (10 . 5) 0)) 1))
            (should (= (point) (point-min)))
            (should (= (window-point) (point-min)))
            (should (= (window-start) (point-min)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mouse-1-release-single-click-already-selected-nil-target-stays ()
  "Already-selected single click with a nil target only sets point.
With `ghostel-mouse-drag-input-mode' nil there is no copy/Emacs mode to
switch to, so the click just sets point and enters no mode."
  :tags '(native)
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (ghostel-mouse-drag-input-mode nil)
        (ghostel--mouse-press-was-selected t)
        (copy-mode-called nil)
        (emacs-mode-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (_event &optional _promote) nil))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel-mouse-release-or-set-point fake-event 1))
      (should-not copy-mode-called)
      (should-not emacs-mode-called))))

(ert-deftest ghostel-test-mouse-1-release-single-click-already-selected-emacs-target ()
  "Single click in an already-selected window honors `ghostel-mouse-drag-input-mode' = `emacs'."
  :tags '(native)
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (ghostel-mouse-drag-input-mode 'emacs)
        (ghostel--mouse-press-was-selected t)
        (copy-mode-called nil)
        (emacs-mode-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (_event &optional _promote) nil))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel-mouse-release-or-set-point fake-event 1))
      (should emacs-mode-called)
      (should-not copy-mode-called))))

(defmacro ghostel-test--with-click (focus-state &rest body)
  "Run BODY in a stubbed semi-char buffer where (click) does press + release.
FOCUS-STATE is what `frame-focus-state' reports.  BODY observes the
outcome via `copy-mode-called' (reset by each click) and point."
  (declare (indent 1))
  `(let ((ghostel-mouse-drag-input-mode 'copy)
         (ghostel--mouse-press-was-selected nil)
         (copy-mode-called nil))
     (with-temp-buffer
       (setq-local ghostel--term 'fake)
       (setq-local ghostel--input-mode 'semi-char)
       (unwind-protect
           (cl-letf (((symbol-function 'ghostel--mode-enabled)
                      (lambda (_term _mode) nil))
                     ((symbol-function 'ghostel--mouse-event)
                      (lambda (&rest _) nil))
                     ((symbol-function 'mouse-drag-region) (lambda (_event) nil))
                     ((symbol-function 'mouse-set-point)
                      (lambda (_event &optional _promote) nil))
                     ((symbol-function 'select-window) (lambda (&rest _) nil))
                     ((symbol-function 'frame-focus-state)
                      (lambda (&optional _f) ,focus-state))
                     ((symbol-function 'ghostel-copy-mode)
                      (lambda () (setq copy-mode-called t))))
             (cl-flet ((click ()
                         (setq copy-mode-called nil)
                         (ghostel-mouse-press-or-copy-mode
                          `(down-mouse-1 (,(selected-window) 1 (10 . 5) 0)))
                         (ghostel-mouse-release-or-set-point
                          `(mouse-1 (,(selected-window) 1 (10 . 5) 0)) 1)))
               ,@body))
         (set-frame-parameter nil 'ghostel--frame-refocused nil)))))

(ert-deftest ghostel-test-mouse-1-click-focused-frame-enters-copy-mode ()
  "Single click in a selected window of a focused frame enters copy mode."
  :tags '(native)
  (ghostel-test--with-click t
    (set-frame-parameter nil 'ghostel--frame-refocused nil)
    (click)
    (should copy-mode-called)))

(ert-deftest ghostel-test-mouse-1-click-refocused-frame-is-focus-click ()
  "First click after the frame regains focus only focuses; the second freezes.
The window stays selected while the frame is in the background."
  :tags '(native)
  (ghostel-test--with-click t
    (insert "hello world")
    (setq-local ghostel--cursor-char-pos 11)
    (goto-char 8)
    (set-frame-parameter nil 'ghostel--frame-refocused t)
    (click)
    (should-not copy-mode-called)
    (should (= (point) 8))              ; preserved pre-click point
    (click)
    (should copy-mode-called)))

(ert-deftest ghostel-test-mouse-1-click-before-focus-in-is-focus-click ()
  "Click dispatched before the focus-in is processed only focuses."
  :tags '(native)
  (ghostel-test--with-click nil
    (set-frame-parameter nil 'ghostel--frame-refocused nil)
    (click)
    (should-not copy-mode-called)))

(ert-deftest ghostel-test-mouse-1-click-focus-unknown-enters-copy-mode ()
  "Click with `frame-focus-state' `unknown' still enters copy mode.
Treating `unknown' as unfocused would break click->copy-mode on ttys."
  :tags '(native)
  (ghostel-test--with-click 'unknown
    (set-frame-parameter nil 'ghostel--frame-refocused nil)
    (click)
    (should copy-mode-called)))

(ert-deftest ghostel-test-mouse-1-click-stale-focus-is-focus-click ()
  "Refocus click is a focus click even when `frame-focus-state' reports stale t.
On NS a frame can keep reporting focus after losing it; the refocusing
click still delivers a focus-in, which `ghostel--frame-focus-flags' turns
into a pending flag, so the press is a focus click."
  :tags '(native)
  (ghostel-test--with-click t
    (insert "hello world")
    (setq-local ghostel--cursor-char-pos 11)
    (goto-char 8)
    ;; Frame reports focus with no pending flag yet.
    (set-frame-parameter nil 'ghostel--frame-refocused nil)
    ;; The refocusing click delivers a focus-in -> after-focus-change ->
    (ghostel--frame-focus-flags)
    (click)
    (should-not copy-mode-called)
    (should (= (point) 8))              ; preserved pre-click point
    ;; A genuine second interaction click (no new focus-in) freezes.
    (click)
    (should copy-mode-called)))

(ert-deftest ghostel-test-frame-focus-flags-event-based ()
  "`ghostel--frame-focus-flags' flags every frame that reports focus.
It reads the current focus state on each event, so a frame already
reporting t is flagged.  `unknown' (ttys) is not t, so unflagged."
  :tags '(native)
  (let ((state nil))
    (unwind-protect
        (cl-letf (((symbol-function 'frame-focus-state)
                   (lambda (&optional _f) state)))
          ;; Unfocused: no flag (and a stale flag is cleared).
          (set-frame-parameter nil 'ghostel--frame-refocused t)
          (ghostel--frame-focus-flags)
          (should-not (frame-parameter nil 'ghostel--frame-refocused))
          ;; Focus-in: flag set.
          (setq state t)
          (ghostel--frame-focus-flags)
          (should (frame-parameter nil 'ghostel--frame-refocused))
          ;; Flag consumed by a press; a fresh focus-in re-flags a frame
          ;; that still reports focus.
          (set-frame-parameter nil 'ghostel--frame-refocused nil)
          (ghostel--frame-focus-flags)
          (should (frame-parameter nil 'ghostel--frame-refocused))
          ;; `unknown' is not t: treated as unfocused, no flag.
          (setq state 'unknown)
          (set-frame-parameter nil 'ghostel--frame-refocused nil)
          (ghostel--frame-focus-flags)
          (should-not (frame-parameter nil 'ghostel--frame-refocused)))
      (set-frame-parameter nil 'ghostel--frame-refocused nil))))

(ert-deftest ghostel-test-mouse-1-release-tracking-forwards ()
  "Release with active tracking forwards via `ghostel--mouse-release'."
  :tags '(native)
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (set-point-called nil)
        (mouse-event-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (eq mode 1000)))
                ((symbol-function 'mouse-set-point)
                 (lambda (_e &optional _promote) (setq set-point-called t)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel-mouse-release-or-set-point fake-event))
      (should-not set-point-called)
      (should (equal 1 (nth 0 mouse-event-args))))))   ; action = release

(ert-deftest ghostel-test-mouse-1-drag-no-tracking-sets-region ()
  "Drag-end with no tracking hands off to `mouse-set-region'.
This is the bug guard: without it, `mouse-drag-track's exit hook
deactivates the mark, our intercept blocks `mouse-set-region', and
the user-visible region disappears on release.  The buffer here is
not in semi-char mode, so copy mode must not be entered."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (set-region-arg nil)
        (copy-mode-called nil)
        (mouse-event-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'emacs)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-region)
                 (lambda (event) (setq set-region-arg event)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) (setq mouse-event-called t) t)))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should (equal fake-event set-region-arg))
      (should-not copy-mode-called)
      (should-not mouse-event-called))))

(ert-deftest ghostel-test-mouse-1-drag-no-tracking-semi-char-enters-copy-mode ()
  "Drag-end in semi-char with no tracking enters copy mode after region.
The press handler no longer freezes the buffer, so freezing happens
here once the region is established — terminal output that arrives
after release would otherwise overwrite the highlighted cells.
Exercises the `copy' target of `ghostel-mouse-drag-input-mode'."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (ghostel-mouse-drag-input-mode 'copy)
        (set-region-arg nil)
        (copy-mode-called nil)
        (emacs-mode-called nil)
        (call-order nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-region)
                 (lambda (event)
                   (setq set-region-arg event)
                   (push 'set-region call-order)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda ()
                   (setq copy-mode-called t)
                   (push 'copy-mode call-order)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should (equal fake-event set-region-arg))
      (should copy-mode-called)
      (should-not emacs-mode-called)
      ;; Region must be set before copy mode freezes the buffer.
      (should (equal '(set-region copy-mode) (nreverse call-order))))))

(ert-deftest ghostel-test-mouse-1-drag-no-tracking-semi-char-emacs-target ()
  "Drag-end in semi-char with `ghostel-mouse-drag-input-mode' = `emacs'.
Enters Emacs mode (not copy) so the user keeps streaming output but
gains a read-only buffer that preserves the selection."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (ghostel-mouse-drag-input-mode 'emacs)
        (set-region-arg nil)
        (copy-mode-called nil)
        (emacs-mode-called nil)
        (call-order nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-region)
                 (lambda (event)
                   (setq set-region-arg event)
                   (push 'set-region call-order)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda ()
                   (setq emacs-mode-called t)
                   (push 'emacs-mode call-order))))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should (equal fake-event set-region-arg))
      (should emacs-mode-called)
      (should-not copy-mode-called)
      (should (equal '(set-region emacs-mode) (nreverse call-order))))))

(ert-deftest ghostel-test-mouse-1-drag-no-tracking-semi-char-nil-target-stays ()
  "Drag-end in semi-char with `ghostel-mouse-drag-input-mode' = nil.
Stays in semi-char so the selection is best-effort and will be lost
on the next redraw - neither copy nor Emacs mode is entered."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (ghostel-mouse-drag-input-mode nil)
        (set-region-arg nil)
        (copy-mode-called nil)
        (emacs-mode-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-region)
                 (lambda (event) (setq set-region-arg event)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should (equal fake-event set-region-arg))
      (should-not copy-mode-called)
      (should-not emacs-mode-called))))

(ert-deftest ghostel-test-mouse-1-drag-focus-click-microdrag-stays-semi-char ()
  "A focus-click micro-drag (no region) stays in semi-char.
A tiny pointer wiggle on a click that only focuses the window makes Emacs
report a drag with equal start/end points; it sets no region, preserves
point, and does not enter copy mode."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 5 (161 . 6) 0)
                      (,(selected-window) 5 (161 . 7) 0)))
        (ghostel-mouse-drag-input-mode 'copy)
        (ghostel--mouse-press-was-selected nil)
        (set-region-called nil)
        (copy-mode-called nil)
        (emacs-mode-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (insert "hello world")
      (setq-local ghostel--cursor-char-pos 11)
      (goto-char 3)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-region)
                 (lambda (_event) (setq set-region-called t)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'ghostel-emacs-mode)
                 (lambda () (setq emacs-mode-called t))))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should-not set-region-called)     ; no region established for a focus click
      (should-not copy-mode-called)
      (should-not emacs-mode-called)
      (should (= (point) 3)))))          ; preserved pre-click point

(ert-deftest ghostel-test-mouse-1-drag-microdrag-already-selected-enters-copy-mode ()
  "A micro-drag in an already-selected window still enters copy mode.
Equal start/end points only stay in semi-char for a focus click; a wiggle
in a window that was already selected is dispatched to the release path and
freezes like a single click there."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 5 (161 . 6) 0)
                      (,(selected-window) 5 (161 . 7) 0)))
        (ghostel-mouse-drag-input-mode 'copy)
        (ghostel--mouse-press-was-selected t)
        (copy-mode-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-point)
                 (lambda (_event &optional _promote) nil))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t))))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should copy-mode-called))))

(ert-deftest ghostel-test-mouse-1-drag-no-tracking-copy-mode-no-toggle ()
  "Drag-end in copy mode does not call `ghostel-copy-mode' again.
Calling `ghostel-copy-mode' from within copy mode would toggle it
off, dropping the user back into semi-char and unfreezing the
buffer right after they finished selecting."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (set-region-arg nil)
        (copy-mode-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'copy)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'mouse-set-region)
                 (lambda (event) (setq set-region-arg event)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t))))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should (equal fake-event set-region-arg))
      (should-not copy-mode-called))))

(ert-deftest ghostel-test-mouse-1-drag-tracking-forwards ()
  "Drag-end with active tracking forwards a release via `ghostel--mouse-drag'.
A `drag-mouse-N' event is only delivered at the end of a drag, so it
marks the button release (live motion is streamed separately during the
drag by `ghostel--mouse-drag-motion')."
  :tags '(native)
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (set-region-called nil)
        (mouse-event-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (eq mode 1000)))
                ((symbol-function 'mouse-set-region)
                 (lambda (_e) (setq set-region-called t)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel-mouse-drag-or-set-region fake-event))
      (should-not set-region-called)
      (should (equal 1 (nth 0 mouse-event-args))))))   ; action = release

(ert-deftest ghostel-test-mouse-press-arms-drag-tracking ()
  "A forwarded press with tracking active arms live motion tracking.
It sets the variable `track-mouse' to `dragging', records the held
button, and installs `ghostel--mouse-drag-map' as a transient map.  The
captured `keep-pred' keeps the map only while the motion handler is
running, and `on-exit' restores motion tracking and clears the state."
  :tags '(native)
  (let ((fake-event `(down-mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (captured-map nil)
        (captured-keep-pred nil)
        (captured-on-exit nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (let ((track-mouse nil))
        (cl-letf (((symbol-function 'ghostel--mode-enabled)
                   (lambda (_term mode) (eq mode 1002)))
                  ((symbol-function 'ghostel--mouse-event)
                   (lambda (&rest _) t))
                  ((symbol-function 'process-live-p) (lambda (_p) t))
                  ((symbol-function 'select-window) (lambda (&rest _) nil))
                  ((symbol-function 'set-transient-map)
                   (lambda (map &optional keep-pred on-exit &rest _)
                     (setq captured-map map
                           captured-keep-pred keep-pred
                           captured-on-exit on-exit))))
          (ghostel--mouse-press fake-event))
        ;; Tracking armed.
        (should (eq track-mouse 'dragging))
        (should (equal 1 ghostel--mouse-drag-button))
        (should (eq captured-map ghostel--mouse-drag-map))
        ;; keep-pred holds the map only during the motion handler.
        (should (let ((this-command 'ghostel--mouse-drag-motion))
                  (funcall captured-keep-pred)))
        (should-not (let ((this-command 'ghostel-mouse-release-or-set-point))
                      (funcall captured-keep-pred)))
        ;; on-exit restores track-mouse and clears the drag state.
        (funcall captured-on-exit)
        (should-not track-mouse)
        (should-not ghostel--mouse-drag-button)
        (should-not ghostel--mouse-drag-last-cell)))))

(ert-deftest ghostel-test-mouse-drag-motion-forwards-and-dedups ()
  "`ghostel--mouse-drag-motion' streams motion for the held button.
It labels each motion with `ghostel--mouse-drag-button' (movement
events carry no button) and suppresses repeated events in the same
cell so the PTY is not flooded."
  :tags '(native)
  (let ((forwards nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--mouse-drag-button 1)
      (cl-letf (((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (push (list action button row col mods) forwards)
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        ;; First movement at (col 10 . row 5) forwards a motion (action 2)
        ;; tagged with the held button 1.
        (ghostel--mouse-drag-motion `(mouse-movement (,(selected-window) 1 (10 . 5) 0)))
        ;; Same cell again: deduped, no new forward.
        (ghostel--mouse-drag-motion `(mouse-movement (,(selected-window) 1 (10 . 5) 0)))
        ;; New cell: forwarded.
        (ghostel--mouse-drag-motion `(mouse-movement (,(selected-window) 1 (11 . 6) 0))))
      (setq forwards (nreverse forwards))
      (should (equal 2 (length forwards)))
      (should (equal '(2 1 5 10) (butlast (nth 0 forwards))))
      (should (equal '(2 1 6 11) (butlast (nth 1 forwards)))))))

(ert-deftest ghostel-test-mouse-drag-motion-needs-held-button ()
  "`ghostel--mouse-drag-motion' is a no-op when no button is held.
Guards against stray movement events arriving outside a drag."
  :tags '(native)
  (let ((forwarded nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--mouse-drag-button nil)
      (cl-letf (((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) (setq forwarded t) t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel--mouse-drag-motion `(mouse-movement (,(selected-window) 1 (10 . 5) 0))))
      (should-not forwarded))))

(ert-deftest ghostel-test-mouse-drag-motion-continues-after-mode-switch ()
  "Motion for an accepted terminal drag continues outside input mode."
  (let ((mouse-event-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--input-mode 'copy)
      (setq-local ghostel--mouse-drag-button 1)
      (cl-letf (((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel--mouse-drag-motion `(mouse-movement (,(selected-window) 1 (10 . 5) 0))))
      (should (equal '(2 1 5 10 0) mouse-event-args)))))

(ert-deftest ghostel-test-mouse-release-continues-after-mode-switch ()
  "Release for an accepted terminal drag continues outside input mode."
  (let ((fake-event `(mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (mouse-event-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--input-mode 'copy)
      (setq-local ghostel--mouse-drag-button 1)
      (cl-letf (((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel--mouse-release fake-event))
      (should (equal '(1 1 5 10 0) mouse-event-args)))))

(ert-deftest ghostel-test-mouse-drag-release-continues-after-mode-switch ()
  "Drag-end release for an accepted terminal drag continues outside input mode."
  (let ((fake-event `(drag-mouse-1
                      (,(selected-window) 1 (5 . 2) 0)
                      (,(selected-window) 7 (10 . 4) 0)))
        (mouse-event-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--input-mode 'copy)
      (setq-local ghostel--mouse-drag-button 1)
      (cl-letf (((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel--mouse-drag fake-event))
      (should (equal '(1 1 4 10 0) mouse-event-args)))))

(ert-deftest ghostel-test-mouse-1-press-tracking-forwards-to-terminal ()
  "Left-press with active mouse-tracking forwards to libghostty.
Never enters copy mode and never hands off to `mouse-drag-region'."
  :tags '(native)
  (let ((fake-event `(down-mouse-1 (,(selected-window) 1 (10 . 5) 0)))
        (copy-mode-called nil)
        (drag-region-called nil)
        (mouse-event-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 ;; Pretend DEC mode 1000 (normal mouse) is enabled.
                 (lambda (_term mode) (eq mode 1000)))
                ((symbol-function 'ghostel-copy-mode)
                 (lambda () (setq copy-mode-called t)))
                ((symbol-function 'mouse-drag-region)
                 (lambda (_e) (setq drag-region-called t)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t))
                ((symbol-function 'select-window) (lambda (&rest _) nil)))
        (ghostel-mouse-press-or-copy-mode fake-event))
      (should-not copy-mode-called)
      (should-not drag-region-called)
      (should (equal 0 (nth 0 mouse-event-args)))   ; action = press
      (should (equal 1 (nth 1 mouse-event-args)))   ; button 1 = mouse-1
      (should (equal 5 (nth 2 mouse-event-args)))   ; row
      (should (equal 10 (nth 3 mouse-event-args)))))) ; col

(ert-deftest ghostel-test-mouse-2-down-unconsumed-noop ()
  "Middle-press is a no-op when the terminal declines it.
The matching release handler does the paste; the press may be offered
to the native encoder but must not forward bytes it declines to encode."
  :tags '(native)
  (let ((fake-event `(down-mouse-2 (,(selected-window) 1 (10 . 5) 0)))
        (mouse-event-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) (setq mouse-event-called t) nil)))
        (ghostel-mouse-down-2-or-noop fake-event))
      (should mouse-event-called))))

(ert-deftest ghostel-test-mouse-2-down-tracking-forwards ()
  "Middle-press with active tracking forwards to libghostty."
  :tags '(native)
  (let ((fake-event `(down-mouse-2 (,(selected-window) 1 (10 . 5) 0)))
        (mouse-event-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (eq mode 1000)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t))
                ((symbol-function 'select-window) (lambda (&rest _) nil)))
        (ghostel-mouse-down-2-or-noop fake-event))
      (should (equal 0 (nth 0 mouse-event-args)))     ; action = press
      (should (equal 3 (nth 1 mouse-event-args)))))) ; ghostty middle = 3

(ert-deftest ghostel-test-mouse-2-release-unconsumed-pastes-primary ()
  "Middle-release pastes the primary selection when the terminal declines it."
  :tags '(native)
  (let ((fake-event `(mouse-2 (,(selected-window) 1 (10 . 5) 0)))
        (paste-arg nil)
        (mouse-event-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'gui-get-primary-selection)
                 (lambda () "hello primary"))
                ((symbol-function 'ghostel--paste-text)
                 (lambda (text) (setq paste-arg text)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) (setq mouse-event-called t) nil))
                ((symbol-function 'select-window) (lambda (&rest _) nil)))
        (ghostel-mouse-paste-primary-or-release fake-event))
      (should (equal "hello primary" paste-arg)))))

(ert-deftest ghostel-test-mouse-2-release-empty-primary-no-paste ()
  "Middle-release with an empty primary selection does not paste."
  :tags '(native)
  (let ((fake-event `(mouse-2 (,(selected-window) 1 (10 . 5) 0)))
        (paste-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (&rest _) nil))
                ((symbol-function 'gui-get-primary-selection)
                 (lambda () ""))
                ((symbol-function 'ghostel--paste-text)
                 (lambda (_t) (setq paste-called t)))
                ((symbol-function 'select-window) (lambda (&rest _) nil)))
        (ghostel-mouse-paste-primary-or-release fake-event))
      (should-not paste-called))))

(ert-deftest ghostel-test-mouse-2-release-tracking-forwards ()
  "Middle-release with active tracking forwards to libghostty."
  :tags '(native)
  (let ((fake-event `(mouse-2 (,(selected-window) 1 (10 . 5) 0)))
        (paste-called nil)
        (mouse-event-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (eq mode 1000)))
                ((symbol-function 'gui-get-primary-selection)
                 (lambda () "should not be used"))
                ((symbol-function 'ghostel--paste-text)
                 (lambda (_t) (setq paste-called t)))
                ((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t))
                ((symbol-function 'select-window) (lambda (&rest _) nil)))
        (ghostel-mouse-paste-primary-or-release fake-event))
      (should-not paste-called)
      (should (equal 1 (nth 0 mouse-event-args)))     ; action = release
      (should (equal 3 (nth 1 mouse-event-args)))))) ; ghostty middle = 3

(ert-deftest ghostel-test-mouse-2-paste-fast-exit-leaves-copy-mode ()
  "Middle-click pasting in copy mode exits when fast-exit is on."
  :tags '(native)
  (let ((fake-event `(mouse-2 (,(selected-window) 1 (10 . 5) 0)))
        (exit-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'copy)
      (let ((ghostel-readonly-fast-exit t))
        (cl-letf (((symbol-function 'ghostel--mode-enabled)
                   (lambda (_term _mode) nil))
                  ((symbol-function 'ghostel--mouse-event)
                   (lambda (&rest _) nil))
                  ((symbol-function 'gui-get-primary-selection)
                   (lambda () "x"))
                  ((symbol-function 'ghostel--paste-text) #'ignore)
                  ((symbol-function 'ghostel-readonly-exit)
                   (lambda () (setq exit-called t)))
                  ((symbol-function 'select-window) (lambda (&rest _) nil)))
          (ghostel-mouse-paste-primary-or-release fake-event)))
      (should exit-called))))

(ert-deftest ghostel-test-mouse-2-paste-no-fast-exit-stays-in-copy-mode ()
  "Middle-click pasting in copy mode stays put when fast-exit is off."
  :tags '(native)
  (let ((fake-event `(mouse-2 (,(selected-window) 1 (10 . 5) 0)))
        (exit-called nil)
        (paste-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'copy)
      (let ((ghostel-readonly-fast-exit nil))
        (cl-letf (((symbol-function 'ghostel--mode-enabled)
                   (lambda (_term _mode) nil))
                  ((symbol-function 'ghostel--mouse-event)
                   (lambda (&rest _) nil))
                  ((symbol-function 'gui-get-primary-selection)
                   (lambda () "x"))
                  ((symbol-function 'ghostel--paste-text)
                   (lambda (_t) (setq paste-called t)))
                  ((symbol-function 'ghostel-readonly-exit)
                   (lambda () (setq exit-called t)))
                  ((symbol-function 'select-window) (lambda (&rest _) nil)))
          (ghostel-mouse-paste-primary-or-release fake-event)))
      (should-not exit-called)
      (should paste-called))))

(ert-deftest ghostel-test-mouse-2-release-selects-clicks-window ()
  "Middle-release retargets the click's window before pasting.
Without this, a middle-click in an unfocused ghostel window would
read `ghostel--input-mode' / `ghostel--process' from whatever
buffer happened to be current and paste into the wrong terminal."
  :tags '(native)
  (let* ((target-window 'fake-window)
         (fake-event `(mouse-2 (,target-window 1 (10 . 5) 0)))
         (selected-arg nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term _mode) nil))
                ((symbol-function 'ghostel--mouse-release)
                 (lambda (_event) nil))
                ((symbol-function 'gui-get-primary-selection)
                 (lambda () "x"))
                ((symbol-function 'ghostel--paste-text) #'ignore)
                ((symbol-function 'select-window)
                 (lambda (w &optional norecord)
                   (unless norecord
                     (setq selected-arg w)))))
        (ghostel-mouse-paste-primary-or-release fake-event))
      (should (eq target-window selected-arg)))))

;; FIXME: The tests below this point mock `ghostel-readonly-exit' to
;; isolate the decision logic (when does the readonly RET path call
;; exit?).  This means the exit mechanism itself — what
;; `ghostel-readonly-exit' actually does to the buffer / mode state —
;; is not exercised end-to-end here.  A dedicated test for the exit
;; mechanism is missing and should be added separately.

(ert-deftest ghostel-test-readonly-RET-on-link-opens-link ()
  "RET on a hyperlink with fast-exit opens the link and exits read-only mode.
The exit must happen before the link is opened so a file:// or
fileref: link that switches buffers does not leave the ghostel
buffer stuck in copy mode."
  :tags '(native)
  (let ((open-url nil)
        (exit-called nil)
        (send-called nil)
        (call-order nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'copy)
      (cl-letf (((symbol-function 'ghostel--uri-at-pos)
                 (lambda (_p) "https://example.com"))
                ((symbol-function 'ghostel--open-link)
                 (lambda (url)
                   (setq open-url url)
                   (push 'open call-order)))
                ((symbol-function 'ghostel-readonly-exit)
                 (lambda ()
                   (setq exit-called t)
                   (push 'exit call-order)))
                ((symbol-function 'ghostel--send-encoded)
                 (lambda (&rest _) (setq send-called t))))
        (ghostel-readonly-RET-or-exit-and-send))
      (should (equal open-url "https://example.com"))
      (should exit-called)
      (should-not send-called)
      ;; Exit before open so buffer-switching link openers
      ;; (file://, fileref:) don't leave the ghostel buffer in copy mode.
      (should (equal call-order '(open exit))))))

(ert-deftest ghostel-test-readonly-RET-off-link-exits-and-sends ()
  "RET off a hyperlink exits read-only mode and sends a CR."
  :tags '(native)
  (let ((open-called nil)
        (exit-called nil)
        (send-args nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'copy)
      (setq-local ghostel--pre-readonly-mode 'semi-char)
      (cl-letf (((symbol-function 'ghostel--uri-at-pos)
                 (lambda (_p) nil))
                ((symbol-function 'ghostel-open-link-at-point)
                 (lambda () (setq open-called t)))
                ((symbol-function 'ghostel-readonly-exit)
                 (lambda () (setq exit-called t)))
                ((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &rest _)
                   (setq send-args (list key mods)))))
        (ghostel-readonly-RET-or-exit-and-send))
      (should-not open-called)
      (should exit-called)
      (should (equal '("return" "") send-args)))))

(ert-deftest ghostel-test-readonly-RET-no-send-when-returning-to-emacs-mode ()
  "RET in copy mode returning to Emacs mode exits but does not send a CR.
Emacs mode is read-only too — sending RET would do nothing useful."
  :tags '(native)
  (let ((exit-called nil)
        (send-called nil))
    (with-temp-buffer
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--input-mode 'copy)
      (setq-local ghostel--pre-readonly-mode 'emacs)
      (cl-letf (((symbol-function 'ghostel--uri-at-pos)
                 (lambda (_p) nil))
                ((symbol-function 'ghostel-readonly-exit)
                 (lambda () (setq exit-called t)))
                ((symbol-function 'ghostel--send-encoded)
                 (lambda (&rest _) (setq send-called t))))
        (ghostel-readonly-RET-or-exit-and-send))
      (should exit-called)
      (should-not send-called))))

(ert-deftest ghostel-test-readonly-RET-bound-only-with-fast-exit ()
  "RET hits `ghostel-readonly-RET-or-exit-and-send' only when fast-exit is on.
With fast-exit off the parent map's `ghostel-open-link-at-point'
binding wins."
  :tags '(native)
  (should (eq #'ghostel-readonly-RET-or-exit-and-send
              (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "RET"))))
  (should (eq #'ghostel-readonly-RET-or-exit-and-send
              (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "<return>"))))
  (should (eq #'ghostel-open-link-at-point
              (lookup-key ghostel-readonly-mode-map (kbd "RET"))))
  (should (eq #'ghostel-open-link-at-point
              (lookup-key ghostel-readonly-mode-map (kbd "<return>")))))

(ert-deftest ghostel-test-scroll-intercept-unselected-window ()
  "Wheel events on an unselected ghostel window must not loop."
  (let ((ghostel-buf (generate-new-buffer " *ghostel-test-unsel*"))
        (other-buf (generate-new-buffer " *other-test-unsel*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((ghostel-win (split-window))
                 (_ (set-window-buffer ghostel-win ghostel-buf))
                 (_ (with-current-buffer ghostel-buf
                      (setq-local ghostel--term 'fake)
                      (setq-local ghostel--process 'fake)
                      (setq-local ghostel--input-mode 'semi-char)
                      (setq-local ghostel--scroll-intercept-active t)))
                 ;; Simulate a wheel event on an unselected ghostel window:
                 ;; current-buffer is the *other* buffer while the event's
                 ;; posn-window points at the ghostel window.
                 (fake-event `(wheel-up (,ghostel-win 1 (10 . 5) 0)))
                 (unread-command-events nil))
            (set-buffer other-buf)
            (cl-letf (((symbol-function 'ghostel--mouse-event)
                       (lambda (_term _action _button _row _col _mods) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t)))
              (ghostel--scroll-intercept-up fake-event)
              ;; Flag must be cleared in the *ghostel* buffer — otherwise
              ;; the next key lookup in that buffer loops.
              (should-not (buffer-local-value
                           'ghostel--scroll-intercept-active ghostel-buf))
              ;; Event pushed back for the user's scroll handler.
              (should (equal fake-event (car unread-command-events)))
              ;; The re-enable hook lives on the ghostel buffer's
              ;; pre-command-hook; running it there flips the flag back.
              (with-current-buffer ghostel-buf
                (run-hooks 'pre-command-hook))
              (should (buffer-local-value
                       'ghostel--scroll-intercept-active ghostel-buf)))))
      (kill-buffer ghostel-buf)
      (kill-buffer other-buf))))

(ert-deftest ghostel-test-scroll-intercept-forwards-from-unselected-window ()
  "Terminal mouse tracking must receive wheel events from an unselected window.
`ghostel--forward-scroll-event' reads buffer-local `ghostel--term'
and friends, which requires the command to run in the event's buffer
rather than the selected window's buffer."
  (let ((ghostel-buf (generate-new-buffer " *ghostel-test-fwd-unsel*"))
        (other-buf (generate-new-buffer " *other-test-fwd-unsel*"))
        (mouse-event-args nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((ghostel-win (split-window))
                 (_ (set-window-buffer ghostel-win ghostel-buf))
                 (_ (with-current-buffer ghostel-buf
                      (setq-local ghostel--term 'fake)
                      (setq-local ghostel--process 'fake)
                      (setq-local ghostel--input-mode 'semi-char)
                      (setq-local ghostel--scroll-intercept-active t)))
                 (fake-event `(wheel-up (,ghostel-win 1 (10 . 5) 0)))
                 (unread-command-events nil))
            (set-buffer other-buf)
            ;; Sanity: in `other-buf' these are all nil — the bug was
            ;; that forward-scroll read them from current-buffer.
            (should-not ghostel--term)
            (cl-letf (((symbol-function 'ghostel--mouse-event)
                       (lambda (_term action button row col mods)
                         (setq mouse-event-args
                               (list action button row col mods))
                         t))
                      ((symbol-function 'process-live-p) (lambda (_p) t)))
              (ghostel--scroll-intercept-up fake-event)
              ;; Mouse event should have been forwarded using the
              ;; ghostel buffer's state, not the other buffer's.
              (should mouse-event-args)
              (should (equal 4 (nth 1 mouse-event-args))) ; button 4
              ;; Not re-dispatched.
              (should-not unread-command-events))))
      (kill-buffer ghostel-buf)
      (kill-buffer other-buf))))

(ert-deftest ghostel-test-yank-remap-bindings ()
  "Alternative paste keys all route to `ghostel-yank'.
Regression test for issue #263.  `C-y' is bound explicitly so user
rebinds of the global `yank' key cannot break ghostel paste.
`S-<insert>' is bound explicitly in `ghostel-semi-char-mode-map'
because `ghostel--define-terminal-keys' otherwise routes it through
`ghostel--send-event' as part of the `<insert>' modifier expansion.
The `<remap> <yank>' entry catches everything else that Emacs binds
to `yank' globally — `s-v' on macOS, plus any user rebinds.  In
char mode all paste keys go to the terminal; line mode keeps
Emacs's regular `yank' so paste lands in the input region."
  :tags '(native)
  ;; The remap entry itself in the maps that want ghostel-yank.
  (should (eq (lookup-key ghostel-semi-char-mode-map [remap yank])
              #'ghostel-yank))
  (should (eq (lookup-key ghostel-readonly-mode-map [remap yank])
              #'ghostel-yank))
  ;; Line mode must NOT remap yank — regular yank into the input
  ;; region is the right behavior there.
  (should-not (lookup-key ghostel-line-mode-map [remap yank]))
  ;; Char mode has no parent and no remap — every key is sent to
  ;; the terminal.
  (should-not (lookup-key ghostel-char-mode-map [remap yank]))
  (should (eq (lookup-key ghostel-char-mode-map (kbd "S-<insert>"))
              #'ghostel--send-event))
  ;; End-to-end: with a ghostel buffer active, `key-binding' walks
  ;; the active maps and follows the remap chain.
  (let ((buf (generate-new-buffer " *ghostel-test-yank-remap*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Default mode is semi-char.
          (should (eq (key-binding (kbd "C-y")) #'ghostel-yank))
          (should (eq (key-binding (kbd "S-<insert>")) #'ghostel-yank))
          ;; `s-v' relies on `term/ns-win.el' binding `[?\s-v]' to
          ;; `yank' globally, which only happens when an NS window
          ;; system loads.  On macOS batch builds without that
          ;; binding (e.g. CI's Emacs) the remap has nothing to ride
          ;; on, so only assert when the prerequisite is actually
          ;; present.
          (when (and (eq system-type 'darwin)
                     (eq (lookup-key (current-global-map) (kbd "s-v"))
                         'yank))
            (should (eq (key-binding (kbd "s-v")) #'ghostel-yank))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-yank-pop-after-yank ()
  "`yank-pop' after yank should cycle the kill ring."
  (let* ((pasted nil)
         (erased nil)
         (kill-ring '("first" "second" "third"))
         (kill-ring-yank-pointer kill-ring)
         (ghostel--yank-index 0)
         (last-command 'ghostel-yank)
         (ghostel--process (start-process "true" nil "true")))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'ghostel--write-pty)
               (lambda (_term str) (setq erased str))))
      (ghostel-yank-pop)
      ;; Should have erased the previous paste (5 backspaces for "first")
      (should (= (length erased) 5))
      ;; Should have pasted the next kill ring entry
      (should (equal (car pasted) "second")))))

(ert-deftest ghostel-test-yank-pop-no-preceding-yank ()
  "`yank-pop' without preceding yank should use `completing-read'."
  (let* ((pasted nil)
         (kill-ring '("alpha" "beta"))
         (last-command 'ghostel--self-insert))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _) (car coll))))
      (ghostel-yank-pop)
      (should (equal (car pasted) "alpha")))))

(ert-deftest ghostel-test-xterm-paste-forwards-to-paste-text ()
  "`ghostel-xterm-paste' forwards the event payload via `ghostel--paste-text'."
  (let ((pasted nil)
        (ghostel--input-mode 'semi-char)
        (xterm-store-paste-on-kill-ring nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted))))
      (ghostel-xterm-paste '(xterm-paste "hello world"))
      (should (equal pasted '("hello world"))))))

(ert-deftest ghostel-test-xterm-paste-rejects-wrong-event ()
  "`ghostel-xterm-paste' signals when the event isn't an xterm-paste."
  (let ((ghostel--input-mode 'semi-char))
    (should-error (ghostel-xterm-paste '(mouse-1 "oops")))))

(ert-deftest ghostel-test-xterm-paste-no-text-is-noop ()
  "`ghostel-xterm-paste' with a nil payload does not forward or touch the kill ring."
  (let ((called nil)
        (kill-ring '("preexisting"))
        (kill-ring-yank-pointer nil)
        (ghostel--input-mode 'semi-char)
        (xterm-store-paste-on-kill-ring t))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (_text) (setq called t))))
      (ghostel-xterm-paste '(xterm-paste nil))
      (should-not called)
      (should (equal kill-ring '("preexisting"))))))

(ert-deftest ghostel-test-xterm-paste-stores-on-kill-ring ()
  "When `xterm-store-paste-on-kill-ring' is non-nil, push the paste onto the kill ring."
  (let ((pasted nil)
        (kill-ring nil)
        (kill-ring-yank-pointer nil)
        (ghostel--input-mode 'semi-char)
        (xterm-store-paste-on-kill-ring t))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted))))
      (ghostel-xterm-paste '(xterm-paste "clip"))
      (should (equal pasted '("clip")))
      (should (equal (car kill-ring) "clip")))))

(ert-deftest ghostel-test-xterm-paste-skips-kill-ring-when-disabled ()
  "When `xterm-store-paste-on-kill-ring' is nil, the kill ring is untouched."
  (let ((pasted nil)
        (kill-ring '("preexisting"))
        (kill-ring-yank-pointer nil)
        (ghostel--input-mode 'semi-char)
        (xterm-store-paste-on-kill-ring nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted))))
      (ghostel-xterm-paste '(xterm-paste "clip"))
      (should (equal pasted '("clip")))
      (should (equal kill-ring '("preexisting"))))))

(ert-deftest ghostel-test-xterm-paste-exits-copy-mode ()
  "`ghostel-xterm-paste' exits copy mode before forwarding."
  (let ((pasted nil)
        (exit-called nil)
        (ghostel--input-mode 'copy)
        (xterm-store-paste-on-kill-ring nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-readonly-exit)
               (lambda () (setq exit-called t))))
      (ghostel-xterm-paste '(xterm-paste "payload"))
      (should exit-called)
      (should (equal pasted '("payload"))))))

(ert-deftest ghostel-test-xterm-paste-bound-in-keymaps ()
  "`ghostel-xterm-paste' is bound to the [xterm-paste] event in both keymaps."
  (should (eq (lookup-key ghostel-mode-map [xterm-paste])
              #'ghostel-xterm-paste))
  ;; Inherited from `ghostel-mode-map' through the readonly map chain.
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map [xterm-paste])
              #'ghostel-xterm-paste)))

(ert-deftest ghostel-test-xterm-paste-copy-mode-and-kill-ring ()
  "All three side effects (exit copy mode, `kill-ring', forward) fire together."
  (let ((pasted nil)
        (exit-called nil)
        (kill-ring nil)
        (kill-ring-yank-pointer nil)
        (ghostel--input-mode 'copy)
        (xterm-store-paste-on-kill-ring t))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-readonly-exit)
               (lambda () (setq exit-called t))))
      (ghostel-xterm-paste '(xterm-paste "combo"))
      (should exit-called)
      (should (equal pasted '("combo")))
      (should (equal (car kill-ring) "combo")))))

(ert-deftest ghostel-test-xterm-paste-no-exit-when-fast-exit-disabled ()
  "With `ghostel-readonly-fast-exit' nil, `ghostel-xterm-paste' stays in copy mode.
The paste is still forwarded to the terminal (matching `ghostel-yank')."
  (let ((pasted nil)
        (exit-called nil)
        (ghostel--input-mode 'copy)
        (ghostel-readonly-fast-exit nil)
        (xterm-store-paste-on-kill-ring nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-readonly-exit)
               (lambda () (setq exit-called t))))
      (ghostel-xterm-paste '(xterm-paste "payload"))
      (should-not exit-called)
      (should (equal pasted '("payload"))))))

(ert-deftest ghostel-test-xterm-paste-exits-emacs-mode ()
  "`ghostel-xterm-paste' exits Emacs mode before forwarding."
  (let ((pasted nil)
        (exit-called nil)
        (ghostel--input-mode 'emacs)
        (xterm-store-paste-on-kill-ring nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-readonly-exit)
               (lambda () (setq exit-called t))))
      (ghostel-xterm-paste '(xterm-paste "payload"))
      (should exit-called)
      (should (equal pasted '("payload"))))))

(ert-deftest ghostel-test-yank-exits-readonly-mode-when-fast-exit-enabled ()
  "`ghostel-yank' exits copy/Emacs mode before forwarding the kill."
  (let ((pasted nil)
        (exit-called nil)
        (kill-ring '("payload"))
        (kill-ring-yank-pointer nil)
        (ghostel--input-mode 'copy)
        (ghostel-readonly-fast-exit t))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-readonly-exit)
               (lambda () (setq exit-called t))))
      (ghostel-yank)
      (should exit-called)
      (should (equal pasted '("payload"))))))

(ert-deftest ghostel-test-paste-exits-readonly-mode-when-fast-exit-enabled ()
  "`ghostel-paste' exits copy/Emacs mode before forwarding the kill."
  (let ((pasted nil)
        (exit-called nil)
        (kill-ring '("payload"))
        (kill-ring-yank-pointer nil)
        (ghostel--input-mode 'emacs)
        (ghostel-readonly-fast-exit t))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-readonly-exit)
               (lambda () (setq exit-called t))))
      (ghostel-paste)
      (should exit-called)
      (should (equal pasted '("payload"))))))

(ert-deftest ghostel-test-yank-no-exit-when-fast-exit-disabled ()
  "With `ghostel-readonly-fast-exit' nil, `ghostel-yank' stays in copy mode."
  (let ((pasted nil)
        (exit-called nil)
        (kill-ring '("payload"))
        (kill-ring-yank-pointer nil)
        (ghostel--input-mode 'copy)
        (ghostel-readonly-fast-exit nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-readonly-exit)
               (lambda () (setq exit-called t))))
      (ghostel-yank)
      (should-not exit-called)
      (should (equal pasted '("payload"))))))

(ert-deftest ghostel-test-readonly-copy-exits-when-fast-exit-enabled ()
  "`ghostel-readonly-copy' kills the region and exits when fast exit is on."
  (let ((exit-called nil)
        (kill-ring nil)
        (kill-ring-yank-pointer nil)
        (ghostel-readonly-fast-exit t))
    (with-temp-buffer
      (transient-mark-mode 1)
      (insert "hello world")
      (push-mark (point-min) t t)
      (goto-char (point-max))
      (cl-letf (((symbol-function 'ghostel-readonly-exit)
                 (lambda () (setq exit-called t))))
        (ghostel-readonly-copy))
      (should exit-called)
      (should (equal (car kill-ring) "hello world")))))

(ert-deftest ghostel-test-readonly-copy-no-exit-when-fast-exit-disabled ()
  "With `ghostel-readonly-fast-exit' nil, `ghostel-readonly-copy' copies but stays.
The selection still lands on the kill ring; only the auto-exit is suppressed."
  (let ((exit-called nil)
        (kill-ring nil)
        (kill-ring-yank-pointer nil)
        (ghostel-readonly-fast-exit nil))
    (with-temp-buffer
      (transient-mark-mode 1)
      (insert "hello world")
      (push-mark (point-min) t t)
      (goto-char (point-max))
      (cl-letf (((symbol-function 'ghostel-readonly-exit)
                 (lambda () (setq exit-called t))))
        (ghostel-readonly-copy))
      (should-not exit-called)
      (should (equal (car kill-ring) "hello world")))))

(ert-deftest ghostel-test-readonly-copy-deactivates-mark ()
  "`ghostel-readonly-copy' deactivates the mark like `kill-ring-save'.
Sets the variable `deactivate-mark' so the region is cleared after
the command, with point staying at the region end."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil)
        (ghostel-readonly-fast-exit nil))
    (with-temp-buffer
      (transient-mark-mode 1)
      (insert "hello world")
      (push-mark (point-min) t t)
      (goto-char (point-max))
      (let ((end (point))
            (deactivate-mark nil))
        (cl-letf (((symbol-function 'ghostel-readonly-exit)
                   (lambda () (ignore))))
          (ghostel-readonly-copy))
        (should deactivate-mark)
        (should (= (point) end))))))

(provide 'ghostel-mouse-paste-test)
;;; ghostel-mouse-paste-test.el ends here
