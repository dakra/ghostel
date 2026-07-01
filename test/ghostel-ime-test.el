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
(declare-function ghostel--redraw "ghostel" (term &optional full))
(declare-function ghostel--terminal-input-mode-p "ghostel")
(declare-function ghostel--send-string "ghostel" (string))

;; `quail-overlay' is defined by quail.el, which is not loaded in batch.
(defvar quail-overlay)

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
