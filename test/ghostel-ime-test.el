;;; ghostel-ime-test.el --- Tests for ghostel-ime -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure-Elisp unit tests for `ghostel-ime': the redraw-inhibit hook,
;; the buffer-local minor-mode wiring, the IME commit-forward wrapper
;; (Korean/Japanese/Chinese), and the Quail-overlay composition probe.
;; None require the native module; the renderer and PTY send are mocked.

;;; Code:

(require 'cl-lib)
(require 'ghostel-test-helpers)
(require 'ghostel-ime)

(declare-function ghostel--redraw-now "ghostel" (buffer &optional force))
(declare-function ghostel--redraw "ghostel"
                  (term &optional full force-sync))
(declare-function ghostel--terminal-input-mode-p "ghostel")
(declare-function ghostel--send-string "ghostel" (string))

;; `quail-overlay' is defined by quail.el, which is not loaded in batch.
(defvar quail-overlay)

(ert-deftest ghostel-test-ime-inhibit-hook-defers-redraw ()
  "A non-nil `ghostel-inhibit-redraw-functions' reschedules the redraw.
The buffer must not be redrawn while a feature inhibits it."
  (ghostel-test--with-compile-buffer buf
    (let ((old-timer (run-with-timer 1000 nil #'ignore))
          timer-delay timer-repeat timer-fn timer-args)
      (setq-local ghostel--redraw-timer old-timer)
      (setq-local ghostel--term 'fake-term)
      (add-hook 'ghostel-inhibit-redraw-functions
                (lambda (buffer)
                  (should (eq buffer buf))
                  (should (eq (current-buffer) buf))
                  t)
                nil t)
      (cl-letf (((symbol-function 'ghostel--terminal-live-p)
                 (lambda (&rest _) t))
                ((symbol-function 'ghostel--redraw)
                 (lambda (&rest _)
                   (ert-fail "Inhibited redraw must not call native redraw")))
                ((symbol-function 'run-with-timer)
                 (lambda (delay repeat fn &rest args)
                   (setq timer-delay delay
                         timer-repeat repeat
                         timer-fn fn
                         timer-args args)
                   'ghostel-test-ime-timer)))
        (ghostel--redraw-now buf))
      (should (equal timer-delay ghostel-timer-delay))
      (should (null timer-repeat))
      (should (eq timer-fn #'ghostel--redraw-now))
      (should (equal timer-args (list buf)))
      (should (eq ghostel--redraw-timer 'ghostel-test-ime-timer))
      (when (timerp old-timer)
        (cancel-timer old-timer)))))

(ert-deftest ghostel-test-ime-mode-installs-buffer-local-wrapper ()
  "`ghostel-ime-mode' installs and removes its buffer-local wiring."
  (ghostel-test--with-compile-buffer buf
    (let ((original (lambda (_key) nil)))
      (setq-local input-method-function original)
      (ghostel-ime-mode 1)
      (should (eq ghostel-ime--original-input-method-function original))
      (should (eq input-method-function #'ghostel-ime--wrap-input-method))
      (should (memq #'ghostel-ime-lisp-composing-p
                    ghostel-inhibit-redraw-functions))
      (should (memq #'ghostel-ime--install input-method-activate-hook))
      (should (memq #'ghostel-ime--uninstall input-method-deactivate-hook))
      (should (memq #'ghostel-ime--reassert post-command-hook))
      (should (eq (car (last post-command-hook)) #'ghostel-ime--reassert))
      (ghostel-ime-mode -1)
      (should (eq input-method-function original))
      (should (null ghostel-ime--original-input-method-function))
      (should-not (memq #'ghostel-ime-lisp-composing-p
                        ghostel-inhibit-redraw-functions))
      (should-not (memq #'ghostel-ime--reassert post-command-hook)))))

(ert-deftest ghostel-test-ime-reasserts-wrapper-after-external-reset ()
  "An external manager must not leave the raw IM wrapper dropped.
An input-method or editing-state manager may restore the raw translator
without firing `input-method-activate-hook'.  `ghostel-ime--reassert',
run on `post-command-hook', rewraps before the next key is read."
  (ghostel-test--with-compile-buffer buf
    (ghostel-ime-mode 1)
    (let ((real (lambda (_key) nil)))
      (setq-local input-method-function real)
      (ghostel-ime--install)
      (should (eq input-method-function #'ghostel-ime--wrap-input-method))
      ;; External manager puts the raw translator back, IM still active.
      (setq-local current-input-method "korean-hangul")
      (setq-local input-method-function real)
      (ghostel-ime--reassert)
      (should (eq input-method-function #'ghostel-ime--wrap-input-method))
      ;; With no active input method, reassert is a no-op (does not wrap
      ;; a stray function).
      (setq-local current-input-method nil)
      (setq-local input-method-function real)
      (ghostel-ime--reassert)
      (should (eq input-method-function real)))
    (ghostel-ime-mode -1)))

(ert-deftest ghostel-test-ime-install-ignores-list-sentinel ()
  "Install must not capture the `list' pass-through sentinel as original.
It waits for the activation hook to deliver a genuine translator."
  (ghostel-test--with-compile-buffer buf
    (setq-local input-method-function #'list)
    (ghostel-ime-mode 1)
    (should (eq input-method-function #'list))
    (should (null ghostel-ime--original-input-method-function))
    (let ((real (lambda (_key) nil)))
      (setq-local input-method-function real)
      (ghostel-ime--install)
      (should (eq ghostel-ime--original-input-method-function real))
      (should (eq input-method-function #'ghostel-ime--wrap-input-method)))
    (ghostel-ime-mode -1)))

(ert-deftest ghostel-test-ime-wrap-forwards-cjk-buffer-commits ()
  "Buffer-inserted CJK commits are forwarded to the PTY and removed locally."
  (ghostel-test--with-compile-buffer buf
    (dolist (text '("한" "あ" "中"))
      (let ((inhibit-read-only t))
        (erase-buffer))
      (let (sent observed-composing)
        (setq-local ghostel-ime--original-input-method-function
                    (lambda (_key)
                      (setq observed-composing (ghostel-ime-lisp-composing-p))
                      (insert text)
                      nil))
        (cl-letf (((symbol-function 'ghostel--terminal-input-mode-p)
                   (lambda () t))
                  ((symbol-function 'ghostel--send-string)
                   (lambda (string) (push string sent))))
          (should (null (ghostel-ime--wrap-input-method ?x))))
        (should observed-composing)
        (should-not (ghostel-ime-lisp-composing-p))
        (should (equal (buffer-string) ""))
        (should (equal sent
                       (list (encode-coding-string text 'utf-8))))))))

(ert-deftest ghostel-test-ime-wrap-composes-in-read-only-buffer ()
  "IMEs that gate composition on `buffer-read-only' still compose and forward.
`hangul2-input-method' (and the 3-Bulsik variants) open with
  (if (or buffer-read-only ...) (list key) ...)
and return the key untranslated whenever the buffer is read-only.  A bare
`inhibit-read-only' bind lifts the modification barrier but leaves that
variable set, so the IME never composes and the raw keystroke is forwarded
instead of the syllable.  The wrapper must present a writable buffer."
  (ghostel-test--with-compile-buffer buf
    ;; Precondition: ghostel buffers are protected (read-only) by default.
    (should buffer-read-only)
    (let ((inhibit-read-only t))
      (erase-buffer))
    (let (sent gate-saw-writable)
      ;; Fake IME mirroring hangul's read-only gate exactly.
      (setq-local ghostel-ime--original-input-method-function
                  (lambda (key)
                    (if buffer-read-only
                        (list key)
                      (setq gate-saw-writable t)
                      (insert "가")
                      nil)))
      (cl-letf (((symbol-function 'ghostel--terminal-input-mode-p)
                 (lambda () t))
                ((symbol-function 'ghostel--send-string)
                 (lambda (string) (push string sent))))
        (should (null (ghostel-ime--wrap-input-method ?r))))
      ;; The IME saw a writable buffer, so it composed instead of passing through.
      (should gate-saw-writable)
      ;; Transient insertion removed locally; only the PTY sees the commit.
      (should (equal (buffer-string) ""))
      (should (equal sent
                     (list (encode-coding-string "가" 'utf-8)))))))

(ert-deftest ghostel-test-ime-wrap-discards-cjk-commits-in-protected-non-input-modes ()
  "Buffer-inserted IME commits in protected non-input modes are removed."
  (ghostel-test--with-compile-buffer buf
    (let (sent)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "base"))
      (goto-char (point-max))
      (setq-local ghostel-ime--original-input-method-function
                  (lambda (_key)
                    (insert "한")
                    nil))
      (cl-letf (((symbol-function 'ghostel--terminal-input-mode-p)
                 (lambda () nil))
                ((symbol-function 'ghostel--send-string)
                 (lambda (string) (push string sent))))
        (should (null (ghostel-ime--wrap-input-method ?x))))
      (should (equal (buffer-string) "base"))
      (should-not sent))))

(ert-deftest ghostel-test-ime-wrap-keeps-line-mode-commits ()
  "Buffer-inserted IME commits in line mode stay in the writable input."
  (ghostel-test--with-compile-buffer buf
    (let (sent)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "base"))
      (setq-local ghostel--input-mode 'line)
      (setq-local buffer-read-only nil)
      (goto-char (point-max))
      (setq-local ghostel-ime--original-input-method-function
                  (lambda (_key)
                    (insert "한")
                    nil))
      (cl-letf (((symbol-function 'ghostel--terminal-input-mode-p)
                 (lambda () nil))
                ((symbol-function 'ghostel--send-string)
                 (lambda (string) (push string sent))))
        (should (null (ghostel-ime--wrap-input-method ?x))))
      (should (equal (buffer-string) "base한"))
      (should-not sent))))

(ert-deftest ghostel-test-ime-composing-p-detects-quail-overlay ()
  "A live non-empty `quail-overlay' marks Lisp IME composition active."
  (let ((buf (generate-new-buffer " *ghostel-test-ime-quail*"))
        overlay)
    (unwind-protect
        (with-current-buffer buf
          (insert "compose")
          (setq overlay (make-overlay (point-min) (1+ (point-min)) buf))
          (setq-local quail-overlay overlay)
          (should (ghostel-ime-lisp-composing-p buf))
          (with-temp-buffer
            (should (ghostel-ime-lisp-composing-p buf)))
          (move-overlay overlay (point-min) (point-min) buf)
          (should-not (ghostel-ime-lisp-composing-p buf)))
      (when (and overlay (overlayp overlay))
        (delete-overlay overlay))
      (kill-buffer buf))))

(ert-deftest ghostel-test-ime-reinstalls-on-reactivation ()
  "Re-activating an input method must re-wrap, even after a deactivate.
This is the path an external state manager drives when it toggles the
IME off in one state and back on in another; the wrapper must return
and capture the genuine translator again, not stay dropped."
  (ghostel-test--with-compile-buffer buf
    (ghostel-ime-mode 1)
    (let ((real (lambda (_key) nil)))
      ;; First activation: the buffer-local activate hook wraps.
      (setq-local input-method-function real)
      (run-hooks 'input-method-activate-hook)
      (should (eq input-method-function #'ghostel-ime--wrap-input-method))
      ;; Deactivation resets the function the way `deactivate-input-method'
      ;; does, then the deactivate hook restores the original.
      (run-hooks 'input-method-deactivate-hook)
      (setq-local input-method-function nil)
      ;; Reactivation must wrap again.
      (setq-local input-method-function real)
      (run-hooks 'input-method-activate-hook)
      (should (eq input-method-function #'ghostel-ime--wrap-input-method))
      (should (eq ghostel-ime--original-input-method-function real)))
    (ghostel-ime-mode -1)))

(ert-deftest ghostel-test-ime-wrapper-survives-mode-switches ()
  "The IME wrapper must persist across ghostel input-mode transitions.
Entering line/char mode and returning to semi-char must not silently
drop the buffer-local `input-method-function' wrapper installed by
`ghostel-ime-mode'."
  :tags '(native)
  (let ((inhibit-message t))
    (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
      (set-window-buffer (selected-window) buf)
      (setq ghostel--process 'fake-proc)
      ;; Establish a prompt so line mode can locate the input boundary.
      (ghostel--write-vt term "\e]133;A\e\\$ \e]133;B\e\\")
      (let ((inhibit-read-only t))
        (ghostel--redraw term t))
      (ghostel-ime-mode 1)
      (let ((real (lambda (_key) nil)))
        (setq-local input-method-function real)
        (ghostel-ime--install)
        (should (eq input-method-function #'ghostel-ime--wrap-input-method))
        (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                  ((symbol-function 'process-send-string) #'ignore)
                  ((symbol-function 'ghostel--invalidate) #'ignore)
                  ((symbol-function 'ghostel--scroll-bottom) #'ignore))
          (dolist (enter (list #'ghostel-line-mode #'ghostel-char-mode))
            (funcall enter)
            (ghostel-semi-char-mode)
            (should (eq ghostel--input-mode 'semi-char))
            (should (eq input-method-function
                        #'ghostel-ime--wrap-input-method))))))))

(provide 'ghostel-ime-test)
;;; ghostel-ime-test.el ends here
