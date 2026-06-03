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
    (ghostel--write-input term (format "%s-%02d\r\n" prefix i))))

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
  (ghostel-test-scroll--with-anchored-and-history-windows (buf term anchored history)
																					  (let ((history-start-before (window-start history))
								    (history-point-before (window-point history)))
							  (ghostel--write-input term "extra\r\n")
							  (ghostel--redraw-now buf)
							  (should (ghostel-test-scroll--bottom-visible-p anchored))
							  (should (= history-start-before (window-start history)))
							  (should (= history-point-before (window-point history)))
							  (should-not (ghostel-test-scroll--bottom-visible-p history)))))

(ert-deftest ghostel-test-resize-preserves-window-anchor-states ()
  "Resize keeps anchored windows at bottom and history windows untouched."
  :tags '(native)
  (ghostel-test-scroll--with-anchored-and-history-windows (buf term anchored history)
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
							  ;; Opening the minibuffer triggers the window-size-change hook.
							  (ghostel--anchor-on-resize anchored)
							  (ghostel--anchor-on-resize history)
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
		    (should (= (window-start w2) (ghostel--viewport-start))))))
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
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
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
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
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
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
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
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
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
  (let (sent-text)
    (ghostel-test--with-scroll-on-input-window t
	    (cl-letf (((symbol-function 'ghostel--bracketed-paste-p)
			      (lambda () nil))
			    ((symbol-function 'process-live-p)
			  (lambda (_process) t))
			    ((symbol-function 'process-send-string)
			  (lambda (_process string)
			    (setq sent-text string))))
	    (ghostel--paste-text "hello"))
	    (should (equal "hello" sent-text))
	    (should (> (window-start) (point-min))))))

(ert-deftest ghostel-test-emacs-mode-yank-scrolls-to-live-cursor ()
  "Yanking in Emacs mode scrolls the window to the live cursor."
  (let ((kill-ring '("hello"))
        (kill-ring-yank-pointer nil)
        sent-text)
    (ghostel-test--with-scroll-on-input-window t
	    (setq ghostel--input-mode 'emacs)
	    (cl-letf (((symbol-function 'ghostel--bracketed-paste-p)
			      (lambda () nil))
			    ((symbol-function 'process-live-p)
			  (lambda (_process) t))
			    ((symbol-function 'process-send-string)
			  (lambda (_process string)
			    (setq sent-text string))))
	    (ghostel-yank))
	    (should (equal "hello" sent-text))
	    (should (> (window-start) (point-min))))))

(provide 'ghostel-scroll-test)
;;; ghostel-scroll-test.el ends here
