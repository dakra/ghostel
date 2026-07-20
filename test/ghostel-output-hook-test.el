;;; ghostel-output-hook-test.el --- Tests for ghostel: output hook -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `ghostel-output-functions': firing after rendered text
;; changes, coalescing, hidden-buffer rendering, error demotion,
;; buffer-local isolation, and live-process scenarios on both PTY
;; backends.

;;; Code:

(require 'ghostel-test-helpers)

(defun ghostel-test--buffer-text ()
  "Return the current buffer's text without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(ert-deftest ghostel-test-output-hook-hidden-invalidate-schedules-redraw ()
  "A hidden buffer with a local handler schedules the coalescing redraw."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf _term 5 40 100)
    (add-hook 'ghostel-output-functions #'ignore nil t)
    (ghostel--invalidate)
    (should ghostel--redraw-timer)))

(ert-deftest ghostel-test-output-hook-hidden-without-handler-stays-pending ()
  "Without handlers, hidden output stays pending as before."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf _term 5 40 100)
    (ghostel--invalidate)
    (should-not ghostel--redraw-timer)
    (should ghostel--pending-redraw)))

(ert-deftest ghostel-test-output-hook-fires-after-text-render ()
  "The hook runs with BUFFER current after the text is rendered.
A second redraw without new output does not fire again."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 40 100)
    (let (calls)
      (add-hook 'ghostel-output-functions
                (lambda (b)
                  (push (cons (eq (current-buffer) b)
                              (with-current-buffer b
                                (ghostel-test--buffer-text)))
                        calls))
                nil t)
      (ghostel--write-vt term "hello")
      (ghostel--redraw-now buf)
      (should (= (length calls) 1))
      (should (caar calls))
      (should (string-match-p "hello" (cdar calls)))
      (ghostel--redraw-now buf)
      (should (= (length calls) 1)))))

(ert-deftest ghostel-test-output-hook-one-call-per-redraw ()
  "Many output chunks rendered by one redraw produce one call."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 10 40 1000)
    (let ((calls 0))
      (add-hook 'ghostel-output-functions
                (lambda (_) (cl-incf calls)) nil t)
      (dotimes (i 50)
        (ghostel--write-vt term (format "line-%d\r\n" i)))
      (ghostel--redraw-now buf)
      (should (= calls 1)))))

(ert-deftest ghostel-test-output-hook-invalidate-reuses-timer ()
  "Repeated invalidations while hidden share one redraw timer."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf _term 5 40 100)
    (add-hook 'ghostel-output-functions #'ignore nil t)
    (ghostel--invalidate)
    (let ((timer ghostel--redraw-timer))
      (should timer)
      (ghostel--invalidate)
      (ghostel--invalidate)
      (should (eq ghostel--redraw-timer timer)))))

(ert-deftest ghostel-test-output-hook-hidden-render-stays-pending ()
  "Hidden renders keep the redraw pending for the re-display catch-up."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 40 100)
    (add-hook 'ghostel-output-functions #'ignore nil t)
    (ghostel--write-vt term "hidden")
    (ghostel--redraw-now buf)
    (should ghostel--pending-redraw)))

(ert-deftest ghostel-test-output-hook-line-mode-teardown-fires ()
  "The teardown's direct full redraw notifies the hook."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf term 5 40 100)
    (let ((calls 0))
      (add-hook 'ghostel-output-functions
                (lambda (_) (cl-incf calls)) nil t)
      (ghostel--write-vt term "teardown-text")
      (ghostel--line-mode-teardown)
      (should (>= calls 1))
      (should (string-match-p "teardown-text" (ghostel-test--buffer-text))))))

(ert-deftest ghostel-test-output-hook-alt-screen ()
  "The hook fires for alternate-screen updates and the switch back."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 40 100)
    (let ((calls 0))
      (add-hook 'ghostel-output-functions
                (lambda (_) (cl-incf calls)) nil t)
      (ghostel--write-vt term "\e[?1049h\e[HTUI-CONTENT")
      (ghostel--redraw-now buf)
      (should (= calls 1))
      (should (string-match-p "TUI-CONTENT" (ghostel-test--buffer-text)))
      (ghostel--write-vt term "\e[?1049l")
      (ghostel--redraw-now buf)
      (should (>= calls 2)))))

(ert-deftest ghostel-test-output-hook-global-handler ()
  "A global (default-value) handler enables hidden rendering and fires."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 40 100)
    (let* ((calls 0)
           (ghostel-output-functions (list (lambda (_) (cl-incf calls)))))
      (ghostel--invalidate)
      (should ghostel--redraw-timer)
      (ghostel--write-vt term "global-output")
      (ghostel--redraw-now buf)
      (should (= calls 1)))))

(ert-deftest ghostel-test-output-hook-copy-mode-defers-to-exit ()
  "No calls while copy mode freezes the terminal; the exit redraw catches up."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 40 100)
    (let ((calls 0))
      (add-hook 'ghostel-output-functions
                (lambda (_) (cl-incf calls)) nil t)
      (setq ghostel--input-mode 'copy)
      (ghostel--write-vt term "during-copy")
      (ghostel--redraw-now buf)
      (should (= calls 0))
      (setq ghostel--input-mode 'semi-char)
      (ghostel--redraw-now buf t)
      (should (= calls 1))
      (should (string-match-p "during-copy" (ghostel-test--buffer-text))))))

(ert-deftest ghostel-test-output-hook-removed-handler-not-present ()
  "A residual local (t) after `remove-hook' does not count as handlers."
  (with-temp-buffer
    (add-hook 'ghostel-output-functions #'ignore nil t)
    (should (ghostel--output-hook-present-p))
    (remove-hook 'ghostel-output-functions #'ignore t)
    (should-not (ghostel--output-hook-present-p))
    ;; Re-adding leaves (ignore t); counts as handlers again.
    (add-hook 'ghostel-output-functions #'ignore nil t)
    (should (ghostel--output-hook-present-p))))

(ert-deftest ghostel-test-output-hook-error-demoted ()
  "A signaling handler is demoted; later handlers and rendering survive."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 40 100)
    (let (ok)
      (add-hook 'ghostel-output-functions
                (lambda (_) (error "Boom")) nil t)
      (add-hook 'ghostel-output-functions
                (lambda (_) (setq ok t)) t t)
      (ghostel--write-vt term "text")
      (let ((debug-on-error nil)
            (inhibit-message t))
        (ghostel--redraw-now buf))
      (should ok)
      (should (string-match-p "text" (ghostel-test--buffer-text))))))

(ert-deftest ghostel-test-output-hook-buffer-local-isolation ()
  "A handler local to terminal A never fires for terminal B.
A hidden buffer without handlers is not rendered either."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf-a _term-a 5 40 100)
    (let (calls)
      (add-hook 'ghostel-output-functions
                (lambda (b) (push b calls)) nil t)
      (let ((buf-b (let ((ghostel-max-scrollback 100))
                     (ghostel--create " *ghostel-test-term-b*" nil 5 40))))
        (unwind-protect
            (let ((term-b (buffer-local-value 'ghostel--term buf-b)))
              (ghostel--write-vt term-b "other")
              (ghostel--redraw-now buf-b)
              (should-not calls)
              ;; No handlers and no window: buffer B stays unrendered.
              (should-not (string-match-p
                           "other"
                           (with-current-buffer buf-b
                             (ghostel-test--buffer-text)))))
          (ghostel-test--cleanup-exec-buffer buf-b))))))

(ert-deftest ghostel-test-output-hook-kill-buffer-safe ()
  "Killing the buffer with a scheduled redraw produces no calls or errors."
  :tags '(native)
  (let* ((buf (let ((ghostel-max-scrollback 100))
                (ghostel--create " *ghostel-test-term-kill*" nil 5 40)))
         (term (buffer-local-value 'ghostel--term buf)))
    (with-current-buffer buf
      (add-hook 'ghostel-output-functions
                (lambda (_) (ert-fail "hook ran for killed buffer")) nil t)
      (ghostel--write-vt term "bye")
      (ghostel--invalidate)
      (should ghostel--redraw-timer))
    (kill-buffer buf)
    ;; A stale timer callback on the dead buffer must be a no-op.
    (ghostel--redraw-now buf)))

(ert-deftest ghostel-test-output-hook-live-echo ()
  "The hook observes rendered echo output on both PTY backends."
  :tags '(native posix)
  (ghostel-test--with-pty-matrix _backend
    (ghostel-test--with-exec-buffer
        (_buf proc "/bin/sh" '("-c" "echo hello; sleep 30"))
      (let (seen)
        (add-hook 'ghostel-output-functions
                  (lambda (b)
                    (with-current-buffer b
                      (when (string-match-p "hello"
                                            (ghostel-test--buffer-text))
                        (setq seen t))))
                  nil t)
        (should (ghostel-test--wait-until (lambda () seen) proc 10))))))

(ert-deftest ghostel-test-output-hook-python-repl ()
  "The hook observes a traceback from a REPL without OSC 133 markers."
  :tags '(native)
  (let ((python (ghostel-test--python)))
    (ghostel-test--with-pty-matrix _backend
      (ghostel-test--with-exec-buffer (_buf proc python '("-q" "-i"))
        (let (seen)
          (add-hook 'ghostel-output-functions
                    (lambda (b)
                      (with-current-buffer b
                        (when (string-match-p "ZeroDivisionError"
                                              (ghostel-test--buffer-text))
                          (setq seen t))))
                    nil t)
          (ghostel-test--wait-for-text ">>>" proc 10)
          (ghostel-send-string "1/0\r")
          (should (ghostel-test--wait-until (lambda () seen) proc 10)))))))

(ert-deftest ghostel-test-output-hook-coalesces-bulk-output ()
  "Bulk output produces far fewer calls than lines, ending fully rendered."
  :tags '(native posix)
  (ghostel-test--with-pty-matrix _backend
    (ghostel-test--with-exec-buffer
        (_buf proc "/bin/sh"
              '("-c" "seq 1 20000; echo GHOSTEL_SEQ_DONE; sleep 30"))
      (let ((calls 0) done)
        (add-hook 'ghostel-output-functions
                  (lambda (b)
                    (cl-incf calls)
                    (with-current-buffer b
                      (save-excursion
                        (goto-char (point-max))
                        (when (search-backward "GHOSTEL_SEQ_DONE"
                                               (max (point-min)
                                                    (- (point-max) 2000))
                                               t)
                          (setq done t)))))
                  nil t)
        (should (ghostel-test--wait-until (lambda () done) proc 20))
        (should (< calls (* 2000 ghostel-test--timeout-scale)))))))

(ert-deftest ghostel-test-output-hook-final-render-before-exit-kill ()
  "Handlers see the final output even when the buffer is killed on exit."
  :tags '(native posix)
  (ghostel-test--with-pty-matrix _backend
    (let ((buf (generate-new-buffer " *ghostel-test-exit*"))
          (ghostel-kill-buffer-on-exit t)
          (seen nil)
          proc)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (let ((ghostel-detect-password-prompts nil))
                (setq proc (ghostel-exec buf "/bin/sh"
                                         '("-c" "echo final-tail-987"))))
              (add-hook 'ghostel-output-functions
                        (lambda (b)
                          (with-current-buffer b
                            (when (string-match-p
                                   "final-tail-987"
                                   (ghostel-test--buffer-text))
                              (setq seen t))))
                        nil t))
            (should (ghostel-test--wait-until (lambda () seen) proc 10)))
        (when (buffer-live-p buf)
          (ghostel-test--cleanup-exec-buffer buf))))))

(provide 'ghostel-output-hook-test)
;;; ghostel-output-hook-test.el ends here
