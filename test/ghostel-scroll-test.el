;;; ghostel-scroll-test.el --- Tests for ghostel scrolling behavior -*- lexical-binding: t; -*-

;;; Commentary:

;; User-visible scrolling, viewport following, and scrollback preservation.
;; Renderer-internal position preservation belongs in ghostel-render-test.el.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-test-scroll--with-buffer (spec &rest body)
  "Run BODY in a displayed ghostel buffer with a native terminal.
SPEC is (BUFFER TERM ROWS COLS SCROLLBACK)."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,term ,rows ,cols ,scrollback) spec))
    `(let ((,buffer (generate-new-buffer " *ghostel-test-scroll*"))
           (orig-buf (window-buffer (selected-window))))
       (unwind-protect
           (with-current-buffer ,buffer
             (ghostel-mode)
             (set-window-buffer (selected-window) ,buffer)
             (let* ((,term (ghostel--new ,rows ,cols ,scrollback))
                    (ghostel--term ,term)
                    (ghostel--term-rows ,rows)
                    (ghostel--term-cols ,cols)
                    (inhibit-read-only t))
               ,@body))
         (when (buffer-live-p orig-buf)
           (set-window-buffer (selected-window) orig-buf))
         (kill-buffer ,buffer)))))

(defun ghostel-test-scroll--write-lines (term prefix count)
  "Write COUNT numbered lines with PREFIX to TERM."
  (dotimes (i count)
    (ghostel--write-vt term (format "%s-%02d\r\n" prefix i))))

(defun ghostel-test-scroll--at-viewport-p (&optional win)
  "Return non-nil when WIN's start is at the current viewport."
  (= (window-start (or win (selected-window)))
     (ghostel--viewport-start)))

(defun ghostel-test-scroll--bottom-position ()
  "Return the beginning position of the last content row."
  (save-excursion
    (goto-char (point-max))
    (skip-chars-backward "\n")
    (line-beginning-position)))

(defun ghostel-test-scroll--bottom-visible-p (win)
  "Return non-nil when WIN shows the last content row."
  (with-current-buffer (window-buffer win)
    (let ((start (window-start win))
          (bottom (ghostel-test-scroll--bottom-position))
          (lines (floor (with-selected-window win
                          (window-screen-lines)))))
      (and (<= start bottom)
           (< (count-lines start bottom) lines)))))

(defun ghostel-test-scroll--line-position (line)
  "Return the beginning position of zero-based LINE."
  (save-excursion
    (goto-char (point-min))
    (forward-line line)
    (line-beginning-position)))

(defun ghostel-test-scroll--anchor-window (win)
  "Put WIN at the live bottom-row view."
  (set-window-point win (ghostel-test-scroll--bottom-position))
  (ghostel--anchor-window win)
  (should (ghostel-test-scroll--bottom-visible-p win)))

(defun ghostel-test-scroll--scroll-window-to-history (win)
  "Put WIN in scrollback, away from the live bottom row."
  (let ((pos (ghostel-test-scroll--line-position 3)))
    (set-window-start win pos t)
    (set-window-point win pos)
    (should-not (ghostel-test-scroll--bottom-visible-p win))))

(defmacro ghostel-test-scroll--with-anchored-and-history-windows (spec &rest body)
  "Run BODY with one anchored and one history window on the same buffer.
SPEC is (BUFFER TERM ANCHORED-WINDOW HISTORY-WINDOW)."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,term ,anchored-window ,history-window) spec))
    `(let ((orig-config (current-window-configuration)))
       (unwind-protect
           (ghostel-test-scroll--with-buffer (,buffer ,term 10 40 200)
              (delete-other-windows)
              (set-window-buffer (selected-window) ,buffer)
              (let ((,anchored-window (selected-window))
                    (,history-window (split-window-vertically)))
                (set-window-buffer ,history-window ,buffer)
                (ghostel-test-scroll--write-lines ,term "scroll" 80)
                (ghostel--redraw ,term t)
                (ghostel-test-scroll--anchor-window ,anchored-window)
                (ghostel-test-scroll--scroll-window-to-history ,history-window)
                ,@body))
         (set-window-configuration orig-config)))))

(ert-deftest ghostel-test-clear-scrollback-scrolls-to-viewport ()
  "Clearing scrollback leaves the window at the live viewport."
  :tags '(native)
  (ghostel-test-scroll--with-buffer (buf term 10 40 200)
    (ghostel-test-scroll--write-lines term "scroll" 30)
    (ghostel--redraw term t)
    (set-window-start (selected-window) (point-min) t)
    (ghostel-clear-scrollback)
    (when (timerp ghostel--redraw-timer)
        (cancel-timer ghostel--redraw-timer)
        (setq ghostel--redraw-timer nil))
    (ghostel--redraw term t)
    (should (ghostel-test-scroll--at-viewport-p))))

(ert-deftest ghostel-test-redraw-with-new-output-preserves-window-anchor-states ()
  "New output keeps anchored windows at bottom and history windows untouched."
  :tags '(native)
  (ghostel-test-scroll--with-anchored-and-history-windows
   (buf term anchored history)
   (let ((history-start-before (window-start history))
         (history-point-before (window-point history)))
     (ghostel--write-vt term "extra\r\n")
     (ghostel--redraw-now buf)
     (should (ghostel-test-scroll--bottom-visible-p anchored))
     (should (= history-start-before (window-start history)))
     (should (= history-point-before (window-point history)))
     (should-not (ghostel-test-scroll--bottom-visible-p history)))))

(ert-deftest ghostel-test-resize-preserves-window-anchor-states ()
  "Resize keeps anchored windows at bottom and history windows untouched."
  :tags '(native)
  (ghostel-test-scroll--with-anchored-and-history-windows
   (buf term anchored history)
   (let ((history-start-before (window-start history))
         (history-point-before (window-point history)))
     (ghostel--set-size term 6 40)
     (setq ghostel--term-rows 6)
     (setq ghostel--force-next-redraw t)
     (ghostel--redraw-now buf)
     (should (ghostel-test-scroll--bottom-visible-p anchored))
     (should (= history-start-before (window-start history)))
     (should (= history-point-before (window-point history)))
     (should-not (ghostel-test-scroll--bottom-visible-p history)))))

(ert-deftest ghostel-test-minibuffer-open-and-close-preserves-window-anchor-states ()
  "Minibuffer open/close keeps bottom windows anchored and history untouched."
  :tags '(native)
  (ghostel-test-scroll--with-anchored-and-history-windows (buf term anchored history)
                                                          (let ((history-start-before (window-start history))
          (history-point-before (window-point history))
          timer-fn)
      ;; Opening the minibuffer leaves only the bottom window anchored.
      (should (ghostel-test-scroll--bottom-visible-p anchored))
      (should (= history-start-before (window-start history)))
      (should (= history-point-before (window-point history)))
      (should-not (ghostel-test-scroll--bottom-visible-p history))
      ;; Closing the minibuffer schedules a deferred re-anchor, after
      ;; redisplay/Vertico have had a chance to perturb window-start.
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_secs _repeat function &rest args)
                   (setq timer-fn (lambda () (apply function args)))
                   'ghostel-test-timer)))
        (ghostel--minibuffer-exit))
      (set-window-start anchored (point-min) t)
      (should-not (ghostel-test-scroll--bottom-visible-p anchored))
      (funcall timer-fn)
      (should (ghostel-test-scroll--bottom-visible-p anchored))
      (should (= history-start-before (window-start history)))
      (should (= history-point-before (window-point history)))
      (should-not (ghostel-test-scroll--bottom-visible-p history)))))

(ert-deftest ghostel-test-minibuffer-exit-preserves-copy-mode-point ()
  "Minibuffer exit does not re-anchor frozen copy-mode windows."
  :tags '(native)
  (ghostel-test-scroll--with-buffer (buf term 10 40 200)
    (ghostel-test-scroll--write-lines term "scroll" 80)
    (ghostel--redraw term t)
    (ghostel-test-scroll--anchor-window (selected-window))
    (setq ghostel--input-mode 'copy)
    (let ((target (save-excursion
                    (goto-char (point-max))
                    (forward-line -3)
                    (line-beginning-position)))
          timer-fn)
      (set-window-point (selected-window) target)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_secs _repeat function &rest args)
                   (setq timer-fn (lambda () (apply function args)))
                   'ghostel-test-timer)))
        (ghostel--minibuffer-exit))
      (should timer-fn)
      (funcall timer-fn)
      (should (= target (window-point))))))

(ert-deftest ghostel-test-minibuffer-exit-skips-replaced-window-buffer ()
  "A deferred minibuffer re-anchor only applies to the captured buffer."
  (let ((orig-config (current-window-configuration))
        (ghostel-buf (generate-new-buffer " *ghostel-test-minibuffer*"))
        (doc-buf (generate-new-buffer " *ghostel-test-doc*"))
        timer-fn)
    (unwind-protect
        (progn
          (delete-other-windows)
          (with-current-buffer ghostel-buf
            (ghostel-mode))
          (set-window-buffer (selected-window) ghostel-buf)
          (should (ghostel--window-anchored-p (selected-window)))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_secs _repeat function &rest args)
                       (setq timer-fn (lambda () (apply function args)))
                       'ghostel-test-timer)))
            (ghostel--minibuffer-exit))
          (should timer-fn)
          (with-current-buffer doc-buf
            (dotimes (i 500)
              (insert (format "line %d\n" i)))
            (goto-char (point-min)))
          (set-window-buffer (selected-window) doc-buf)
          (set-window-start (selected-window) (point-min) t)
          (set-window-point (selected-window) (point-min))
          (funcall timer-fn)
          (should (= (window-start) (point-min)))
          (should (= (window-point) (point-min))))
      (set-window-configuration orig-config)
      (when (buffer-live-p ghostel-buf)
        (kill-buffer ghostel-buf))
      (when (buffer-live-p doc-buf)
        (kill-buffer doc-buf)))))

(defun ghostel-test-scroll--set-gui-anchor-start (win)
  "Park WIN's `window-start' at the GUI-anchored steady state.
The graphical branch of `ghostel--anchor-window' parks `window-start' one
line above the topmost grid row to make room for its partial-top-line
vscroll, so a bottom-anchored GUI window has
`ws-lines-to-end' = floor(window-screen-lines) + 1.  That branch is gated
on `display-graphic-p', which is never true in batch, so set
`window-start' directly to reproduce the same position."
  (let* ((target (1+ (floor (with-selected-window win
                              (window-screen-lines)))))
         (start (save-excursion
                  (goto-char (point-max))
                  (forward-line (- target))
                  (line-beginning-position))))
    (set-window-start win start t)))

(ert-deftest ghostel-test-window-anchored-p-survives-mode-line-toggle ()
  "`ghostel--window-anchored-p' ignores the mode-line's height (issue #373).
A GUI-anchored window's `window-start' sits floor(window-screen-lines)+1
lines above `point-max'.  The predicate must judge it \"following output\"
whether or not a mode-line is present.  Measuring the threshold from the
full `window-pixel-height' (mode-line included) only worked because the
mode-line donated the +1 line of slack; disabling it removed that slack
and stranded the cursor off-screen.

In batch the GUI anchor's `forward-line -1' (display-graphic-p only)
cannot run, so `window-start' is set directly; toggling the mode-line in
batch reproduces the GUI geometry shift (the window body grows by one line
while `window-pixel-height' stays constant)."
  :tags '(native)
  (ghostel-test-scroll--with-buffer (buf term 10 40 200)
    (let ((win (selected-window)))
      (ghostel-test-scroll--write-lines term "scroll" 60)
      (ghostel--redraw term t)
      ;; Control: mode-line present — an anchored window reads as following.
      (ghostel-test-scroll--set-gui-anchor-start win)
      (should (ghostel--window-anchored-p win))
      ;; Disable the mode-line and let the geometry settle; the body grows
      ;; by one line.  Re-derive the anchored `window-start' for the larger
      ;; body and assert the predicate still follows.  (Fails on HEAD
      ;; before the fix; passes after.)
      (setq-local mode-line-format nil)
      (redisplay t)
      (ghostel-test-scroll--set-gui-anchor-start win)
      (should (ghostel--window-anchored-p win)))))

(ert-deftest ghostel-test-pixel-anchor-gate-matches-emacs-version ()
  "`ghostel--pixel-anchor-supported-p' gates on the Emacs 29 cons FROM form.
The cons-cell meaning of `window-text-pixel-size's FROM argument, which
`ghostel--pixel-anchor' relies on, arrived in Emacs 29.  The predicate
must therefore be nil on Emacs 28 (where a cons FROM signals
`wrong-type-argument') and non-nil from Emacs 29 on.  This guards against
regressing to a bare `fboundp' check, which is true on Emacs 28 because
`window-text-pixel-size' has existed since Emacs 25 (issue #384)."
  (should (eq (and ghostel--pixel-anchor-supported-p t)
              (>= emacs-major-version 29))))

(ert-deftest ghostel-test-second-window-does-not-disturb-scrollback ()
  "Opening another window on the buffer does not move a scrolled peer."
  :tags '(native)
  (let ((orig-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test-scroll--with-buffer (buf term 10 40 200)
          (ghostel-test-scroll--write-lines term "scroll" 30)
          (ghostel--redraw term t)
          (let ((w1 (selected-window)))
            (set-window-start w1 (point-min) t)
            (set-window-point w1 (point-min))
            (let ((start-before (window-start w1))
                  (w2 (split-window w1)))
              (set-window-buffer w2 buf)
              (run-hook-with-args 'window-buffer-change-functions w2)
              (should (= start-before (window-start w1)))
              (should (ghostel--window-anchored-p w2)))))
      (set-window-configuration orig-config))))

(ert-deftest ghostel-test-user-rescroll-is-preserved ()
  "A later user scroll position is the position preserved by redraw."
  :tags '(native)
  (ghostel-test-scroll--with-buffer (buf term 10 40 200)
    (ghostel-test-scroll--write-lines term "scroll" 50)
    (ghostel--redraw term t)
    (let ((target-a (save-excursion
                        (goto-char (point-min))
                        (forward-line 5)
                        (line-beginning-position)))
            (target-b (save-excursion
                    (goto-char (point-min))
                    (forward-line 15)
                    (line-beginning-position))))
        (set-window-start (selected-window) target-a t)
        (set-window-point (selected-window) target-a)
        (ghostel--redraw-now buf)
        (set-window-start (selected-window) target-b t)
        (set-window-point (selected-window) target-b)
        (ghostel--redraw-now buf)
        (should (= target-b (window-start)))
        (should (= target-b (window-point))))))

(ert-deftest ghostel-test-redraw-resets-vscroll ()
  "Redraw resets `window-vscroll' when point is in the viewport.
Regression for issue #105: with `pixel-scroll-precision-mode',
a non-zero pixel vscroll left on the window clips the top line
after a redraw (e.g. `clear').  Anchoring `window-start' alone is
not enough; the pixel offset must also be cleared."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll*"))
        (orig-buf (window-buffer (selected-window)))
        ;; Simulated pixel vscroll state per window.  Batch-mode
        ;; `window-vscroll' always returns 0, so we track the value
        ;; ourselves via a mocked `set-window-vscroll'.
        (vscroll-by-window (make-hash-table :test 'eq)))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-vt term (format "scroll-%02d\r\n" i)))
            (ghostel--write-vt term "prompt> ")
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Window was showing the viewport before the redraw — this
            ;; is the auto-follow case where vscroll must be reset.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp-before (save-excursion
                               (goto-char (point-max))
                               (forward-line -9)
                               (line-beginning-position))))
              (set-window-start (selected-window) vp-before t))
            ;; Seed a non-zero pixel vscroll (simulating what
            ;; `pixel-scroll-precision-mode' leaves behind).
            (puthash (selected-window) 7 vscroll-by-window)
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (win vscroll &optional pixels-p &rest _)
                         (should (eq pixels-p t))
                         (puthash win vscroll vscroll-by-window))))
              (ghostel--redraw-now buf))
            (should (= 0 (gethash (selected-window) vscroll-by-window)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resets-vscroll-all-windows ()
  "Redraw resets `window-vscroll' on every window showing the buffer.
`ghostel--redraw-now' iterates `get-buffer-window-list' so both
windows must be anchored."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll-multi*"))
        (orig-config (current-window-configuration))
        (vscroll-by-window (make-hash-table :test 'eq)))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-vt term (format "scroll-%02d\r\n" i)))
            (ghostel--write-vt term "prompt> ")
            (ghostel--redraw term t)
            (goto-char (point-max))
            (delete-other-windows)
            (set-window-buffer (selected-window) buf)
            (let ((w1 (selected-window))
                  (w2 (split-window-vertically))
                  (vp-before (save-excursion
                               (goto-char (point-max))
                               (forward-line -9)
                               (line-beginning-position))))
              (set-window-buffer w2 buf)
              (set-window-point w1 (point-max))
              (set-window-point w2 (point-max))
              ;; Both windows were at the viewport pre-redraw.
              (set-window-start w1 vp-before t)
              (set-window-start w2 vp-before t)
              (puthash w1 7 vscroll-by-window)
              (puthash w2 4 vscroll-by-window)
              (cl-letf (((symbol-function 'set-window-vscroll)
                         (lambda (win vscroll &optional pixels-p &rest _)
                           (should (eq pixels-p t))
                           (puthash win vscroll vscroll-by-window))))
                (ghostel--redraw-now buf))
              (should (= 0 (gethash w1 vscroll-by-window)))
              (should (= 0 (gethash w2 vscroll-by-window))))))
      (set-window-configuration orig-config)
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-vscroll-in-scrollback ()
  "Redraw leaves `window-vscroll' alone when point is in scrollback.
The vscroll reset is gated on the same condition as `set-window-start':
a user reading history should not be pulled around by live redraws."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll-scrollback*"))
        (orig-buf (window-buffer (selected-window)))
        (vscroll-called nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-vt term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Seed the anchor by running a prior redraw so subsequent
            ;; scroll-preservation logic is in steady state.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--redraw-now buf)
            ;; Simulate the user scrolling into scrollback: both
            ;; window-start and point move above the viewport (that's
            ;; what real Emacs scrollers — pixel-scroll-precision,
            ;; mouse-wheel, scroll-up-command — produce).
            (goto-char (point-min))
            (set-window-point (selected-window) (point-min))
            (set-window-start (selected-window) (point-min) t)
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (&rest _) (setq vscroll-called t))))
              (ghostel--redraw-now buf))
            (should-not vscroll-called)))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-syncs-window-point-to-cursor ()
  "Anchored redraw syncs `window-point' to the terminal cursor.
When an OSC 52;e callback moved selection elsewhere and left the
ghostel window's `window-point' stale, the next redraw (which is
anchored because the window is at the viewport) must update it."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-wp-sync*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-vt term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            ;; Simulate OSC 52;e leaving window-point stale.
            (set-window-point (selected-window) (point-min))
            (setq ghostel--force-next-redraw t)
            (ghostel--redraw-now buf)
            ;; Anchored window's window-point follows the cursor
            ;; (buffer-point after native redraw), not the stale value.
            (should (= (window-point (selected-window)) (point)))
            (should (> (window-point (selected-window)) 1))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-viewport-start-skips-trailing-newline ()
  "`ghostel--viewport-start' must not be off-by-one on a trailing \\n.
Partial redraws can leave the buffer ending with \\n (e.g. after
trimming excess rows).  Emacs then counts an empty phantom line
past `point-max'; a naive `forward-line (- (1- tr))' lands one line
too deep and the anchored window clips the bottom content row.
The fix must return the start of row 1, covering exactly TR content
rows in the viewport — with or without the trailing newline."
  (with-temp-buffer
    (let ((tr 5))
      (dotimes (i tr)
        (insert (format "row-%d" (1+ i)))
        (when (< i (1- tr)) (insert "\n")))
      (let* ((ghostel--term-rows tr)
             (vs-no-nl (ghostel--viewport-start)))
        (should (= 1 vs-no-nl))
        (insert "\n")
        (let ((vs-nl (ghostel--viewport-start)))
          (should (= 1 vs-nl))
          (should (= tr (count-lines vs-nl (save-excursion
                                             (goto-char (point-max))
                                             (skip-chars-backward "\n")
                                             (point))))))))))

(defmacro ghostel-test--with-scroll-on-input-window (scroll-on-input &rest body)
  "Run BODY with SCROLL-ON-INPUT in a buffer scrolled above its live cursor."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer " *ghostel-test-scroll-on-input*"))
         (previous-buffer (window-buffer (selected-window))))
     (unwind-protect
         (progn
           (set-window-buffer (selected-window) buf)
           (with-current-buffer buf
             (ghostel-mode)
             (let* ((rows (max 1 (window-body-height)))
                    (ghostel--term 'fake)
                    (ghostel--term-rows rows)
                    (ghostel--process 'fake-proc)
                    (ghostel-scroll-on-input ,scroll-on-input))
               (let ((inhibit-read-only t))
                 (dotimes (i (+ rows 20))
                   (insert (format "row-%02d\n" i))))
               (setq ghostel--cursor-char-pos (point-max))
               (goto-char (point-min))
               (set-window-start (selected-window) (point-min) t)
               ,@body)))
       (set-window-buffer (selected-window) previous-buffer)
       (kill-buffer buf))))

(ert-deftest ghostel-test-scroll-on-input-self-insert ()
  "Self-insert scrolls the window to the live cursor."
  (let (sent-key)
    (ghostel-test--with-scroll-on-input-window t
        (cl-letf (((symbol-function 'ghostel--send-string)
                  (lambda (str) (setq sent-key str)))
                ((symbol-function 'this-command-keys)
              (lambda () "a")))
        (let ((last-command-event ?a))
        (ghostel--self-insert)))
        (should (equal "a" sent-key))
        (should (> (window-start) (point-min))))))

(ert-deftest ghostel-test-scroll-on-input-send-event ()
  "Send-event scrolls the window to the live cursor."
  (let (sent-event)
    (ghostel-test--with-scroll-on-input-window t
        (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (_key _mods &optional _utf8)
                (setq sent-event t))))
        (let ((last-command-event (aref (kbd "<return>") 0)))
        (ghostel--send-event)))
        (should sent-event)
        (should (> (window-start) (point-min))))))

(ert-deftest ghostel-test-scroll-on-input-disabled ()
  "Self-insert does not scroll when `ghostel-scroll-on-input' is nil."
  (let (sent-key)
    (ghostel-test--with-scroll-on-input-window nil
        (cl-letf (((symbol-function 'ghostel--send-string)
                  (lambda (str) (setq sent-key str)))
                ((symbol-function 'this-command-keys)
              (lambda () "a")))
        (let ((last-command-event ?a))
        (ghostel--self-insert)))
        (should (equal "a" sent-key))
        (should (= (point-min)
                  (window-start (selected-window)))))))

(ert-deftest ghostel-test-scroll-on-input-paste ()
  "Paste scrolls the window to the live cursor."
  (let ((kill-ring '("hello"))
        (kill-ring-yank-pointer nil)
        (interprogram-paste-function nil)
        sent-text)
    (ghostel-test--with-scroll-on-input-window t
      (cl-letf (((symbol-function 'ghostel--encode-paste)
                 (lambda (_term string)
                   (setq sent-text string))))
        (ghostel-paste))
      (should (equal "hello" sent-text))
      (should (> (window-start) (point-min))))))

(ert-deftest ghostel-test-emacs-mode-yank-scrolls-to-live-cursor ()
  "Yanking in Emacs mode scrolls the window to the live cursor."
  (let ((kill-ring '("hello"))
        (kill-ring-yank-pointer nil)
        (interprogram-paste-function nil)
        (ghostel-readonly-fast-exit nil)
        sent-text)
    (ghostel-test--with-scroll-on-input-window t
        (setq ghostel--input-mode 'emacs)
        (cl-letf (((symbol-function 'ghostel--encode-paste)
                   (lambda (_term string)
                     (setq sent-text string))))
        (ghostel-yank))
        (should (equal "hello" sent-text))
        (should (> (window-start) (point-min))))))

(ert-deftest ghostel-test-anchor-window-inhibit-functions-veto ()
  "`ghostel-inhibit-anchor-functions' vetoes anchoring per window.
A non-nil-returning hook (honoring FORCE) leaves both point and the viewport
put in semi-char mode, where the anchor would otherwise snap point to the live
cursor and scroll to the bottom.  FORCE bypasses the veto."
  (let ((buf (generate-new-buffer " *ghostel-test-anchor-inhibit*"))
        (previous-buffer (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (setq ghostel--term 'fake)
            ;; Scrollback above the prompt so a bottom-anchor is observable.
            (let ((rows (max 1 (window-body-height))))
              (ghostel-test--with-rendered-output
                (dotimes (i (+ rows 20))
                  (insert (format "row-%02d\n" i)))))
            ;; Prompt on the cursor's row; terminal cursor right after it.
            (ghostel-test--insert-rendered "$ ")
            (setq ghostel--cursor-char-pos (point))
            (setq ghostel--cursor-pos (cons (current-column) 0))
            (should (eq ghostel--input-mode 'semi-char))
            (let* ((win (selected-window))
                   ;; Park point up in the scrollback, off the live cursor.
                   (parked (point-min))
                   ;; Stub mirrors evil-ghostel: veto unless FORCE.
                   (ghostel-inhibit-anchor-functions
                    (list (lambda (_window force) (not force)))))
              ;; Vetoed: neither point nor the viewport moves.
              (goto-char parked)
              (set-window-point win parked)
              (set-window-start win (point-min) t)
              (ghostel--anchor-window win)
              (should (= (window-point win) parked))
              (should (= (window-start win) (point-min)))
              ;; FORCE bypasses the veto: point snaps, viewport scrolls.
              (ghostel--anchor-window win t)
              (should (= (window-point win) ghostel--cursor-char-pos))
              (should (> (window-start win) (point-min))))))
      (set-window-buffer (selected-window) previous-buffer)
      (kill-buffer buf))))

(ert-deftest ghostel-test-emacs-mode-follows-output-on-cursor ()
  "Emacs mode keeps following live output while point rides the cursor.
Two write/redraw rounds prove the follow loop self-sustains through the
post-render anchor's point snap."
  :tags '(native)
  (ghostel-test-scroll--with-buffer (buf term 10 40 200)
    (ghostel-test-scroll--write-lines term "scroll" 80)
    (ghostel--redraw term t)
    (let ((win (selected-window)))
      ;; Anchor in semi-char so window-point snaps to the live cursor,
      ;; then enter Emacs mode with point still riding it.
      (ghostel-test-scroll--anchor-window win)
      (setq ghostel--input-mode 'emacs)
      (dotimes (round 2)
        (ghostel-test-scroll--write-lines
         term (format "extra%d" round) 5)
        (ghostel--redraw-now buf)
        (should (ghostel-test-scroll--bottom-visible-p win))
        (should (= (window-point win) ghostel--cursor-char-pos))))))

(ert-deftest ghostel-test-emacs-mode-stops-following-off-cursor ()
  "Emacs mode stops following once point leaves the live cursor."
  :tags '(native)
  (ghostel-test-scroll--with-buffer (buf term 10 40 200)
    (ghostel-test-scroll--write-lines term "scroll" 80)
    (ghostel--redraw term t)
    (let ((win (selected-window)))
      (ghostel-test-scroll--anchor-window win)
      (setq ghostel--input-mode 'emacs)
      (let ((parked (save-excursion
                      (goto-char ghostel--cursor-char-pos)
                      (forward-line -3)
                      (line-beginning-position))))
        (set-window-point win parked)
        (let ((start-before (window-start win)))
          (ghostel-test-scroll--write-lines term "extra" 5)
          (ghostel--redraw-now buf)
          (should (= start-before (window-start win)))
          (should (= parked (window-point win)))
          (should-not (ghostel-test-scroll--bottom-visible-p win)))))))

(ert-deftest ghostel-test-emacs-mode-resumes-following-at-end ()
  "Emacs mode resumes following when point lands at or past the cursor.
Jumping to `point-max' (or anywhere past the cursor) counts as riding
the cursor, so an end-of-buffer jump resumes the follow."
  :tags '(native)
  (ghostel-test-scroll--with-buffer (buf term 10 40 200)
    (ghostel-test-scroll--write-lines term "scroll" 80)
    (ghostel--redraw term t)
    (let ((win (selected-window)))
      (ghostel-test-scroll--anchor-window win)
      (setq ghostel--input-mode 'emacs)
      ;; Stop the follow by navigating off the cursor.
      (ghostel-test-scroll--scroll-window-to-history win)
      (ghostel-test-scroll--write-lines term "extra" 5)
      (ghostel--redraw-now buf)
      (should-not (ghostel-test-scroll--bottom-visible-p win))
      ;; Jump to the end: the next redraw follows and snaps to the cursor.
      (set-window-point win (point-max))
      (ghostel--anchor-window win)
      (ghostel-test-scroll--write-lines term "more" 5)
      (ghostel--redraw-now buf)
      (should (ghostel-test-scroll--bottom-visible-p win))
      (should (= (window-point win) ghostel--cursor-char-pos)))))

(ert-deftest ghostel-test-emacs-mode-follow-is-per-window ()
  "In Emacs mode one window can follow while a peer reads scrollback."
  :tags '(native)
  (ghostel-test-scroll--with-anchored-and-history-windows
   (buf term anchored history)
   (setq ghostel--input-mode 'emacs)
   (let ((history-start-before (window-start history))
         (history-point-before (window-point history)))
     (ghostel--write-vt term "extra\r\n")
     (ghostel--redraw-now buf)
     (should (ghostel-test-scroll--bottom-visible-p anchored))
     (should (= (window-point anchored) ghostel--cursor-char-pos))
     (should (= history-start-before (window-start history)))
     (should (= history-point-before (window-point history)))
     (should-not (ghostel-test-scroll--bottom-visible-p history)))))

(ert-deftest ghostel-test-anchor-window-emacs-mode-following-arg ()
  "FOLLOWING anchors an Emacs-mode window whose point sits at the old cursor.
The redraw path decides \"was following\" before the native render
advances `ghostel--cursor-char-pos' away from the preserved window-point;
FOLLOWING carries that decision past the render.  Without FOLLOWING the
self-check sees the stale point and declines."
  :tags '(native)
  (ghostel-test-scroll--with-buffer (buf term 10 40 200)
    (ghostel-test-scroll--write-lines term "scroll" 80)
    (ghostel--redraw term t)
    (let ((win (selected-window)))
      (ghostel-test-scroll--anchor-window win)
      (setq ghostel--input-mode 'emacs)
      ;; Raw native render: cursor advances, window-point is preserved.
      (ghostel-test-scroll--write-lines term "extra" 5)
      (ghostel--redraw term t)
      (should-not (= (window-point win) ghostel--cursor-char-pos))
      (let ((start-before (window-start win)))
        (ghostel--anchor-window win)
        (should (= start-before (window-start win)))
        (ghostel--anchor-window win nil t)
        (should (ghostel-test-scroll--bottom-visible-p win))
        (should (= (window-point win) ghostel--cursor-char-pos))))))

(ert-deftest ghostel-test-window-on-cursor-p-riding-positions ()
  "Point on the cursor or at `point-max' rides; between them does not.
A region vetoes only the selected window's ride."
  (let ((buf (generate-new-buffer " *ghostel-test-on-cursor*"))
        (previous-buffer (window-buffer (selected-window)))
        (orig-config (current-window-configuration)))
    (unwind-protect
        (progn
          (delete-other-windows)
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (ghostel-test--with-rendered-output
              (insert "out\n$ ls\n"))
            ;; Readline cursor moved back over the typed tail "ls".
            (setq ghostel--cursor-char-pos (- (point-max) 3))
            (let ((win (selected-window)))
              (set-window-point win ghostel--cursor-char-pos)
              (should (ghostel--window-on-cursor-p win))
              (set-window-point win (point-max))
              (should (ghostel--window-on-cursor-p win))
              ;; Between cursor and point-max: parked on content, no ride.
              (set-window-point win (1- (point-max)))
              (should-not (ghostel--window-on-cursor-p win))
              ;; A region vetoes the selected window, not a peer window.
              ;; Batch runs without `transient-mark-mode'; enable it so
              ;; `region-active-p' can report the activated mark.
              (let ((transient-mark-mode t)
                    (w2 (split-window)))
                (set-window-buffer w2 buf)
                (set-window-point win ghostel--cursor-char-pos)
                (set-window-point w2 ghostel--cursor-char-pos)
                (push-mark (point-min) t t)
                (should-not (ghostel--window-on-cursor-p win))
                (should (ghostel--window-on-cursor-p w2))
                (deactivate-mark)))))
      (set-window-configuration orig-config)
      (when (buffer-live-p previous-buffer)
        (set-window-buffer (selected-window) previous-buffer))
      (kill-buffer buf))))

(provide 'ghostel-scroll-test)
;;; ghostel-scroll-test.el ends here
