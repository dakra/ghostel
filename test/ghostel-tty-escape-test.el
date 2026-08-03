;;; ghostel-tty-escape-test.el --- Tests for ghostel-tty-escape-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; The lone-Escape decoder for TTY Emacs: the input-decode filter's
;; branch logic and the global mode's frame-hook lifecycle.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-tty-escape-filter ()
  "Yield `escape' only for a lone ESC in a ghostel input buffer with no
pending input; pass MAP through in every other case, so Meta (ESC+key),
CSI/SS3 function-key sequences, and non-ghostel buffers are untouched."
  ;; Positive: ghostel buffer, terminal input mode, keys are ESC, nothing pending.
  (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
            ((symbol-function 'ghostel--terminal-input-mode-p) (lambda () t))
            ((symbol-function 'this-single-command-keys) (lambda () [?\e]))
            ((symbol-function 'sit-for) (lambda (&rest _) t)))
    (should (equal [escape] (ghostel--tty-escape 'orig))))
  ;; Not a ghostel buffer -> unchanged (Esc keeps its global Meta meaning).
  (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) nil)))
    (should (eq 'orig (ghostel--tty-escape 'orig))))
  ;; Input already pending (Meta/CSI): sit-for returns nil -> unchanged.
  (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
            ((symbol-function 'ghostel--terminal-input-mode-p) (lambda () t))
            ((symbol-function 'this-single-command-keys) (lambda () [?\e]))
            ((symbol-function 'sit-for) (lambda (&rest _) nil)))
    (should (eq 'orig (ghostel--tty-escape 'orig))))
  ;; More than a lone ESC (a function-key sequence) -> unchanged.
  (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
            ((symbol-function 'ghostel--terminal-input-mode-p) (lambda () t))
            ((symbol-function 'this-single-command-keys) (lambda () [?\e ?O]))
            ((symbol-function 'sit-for) (lambda (&rest _) t)))
    (should (eq 'orig (ghostel--tty-escape 'orig)))))

(ert-deftest ghostel-test-tty-escape-mode-toggles-frame-hook ()
  "Enabling installs the per-frame decoder hook; disabling removes it."
  (cl-letf (((symbol-function 'ghostel--tty-escape-init) #'ignore)
            ((symbol-function 'ghostel--tty-escape-deinit) #'ignore))
    (unwind-protect
        (progn
          (ghostel-tty-escape-mode 1)
          (should (memq #'ghostel--tty-escape-init after-make-frame-functions))
          (ghostel-tty-escape-mode -1)
          (should-not (memq #'ghostel--tty-escape-init after-make-frame-functions)))
      (ghostel-tty-escape-mode -1))))

(provide 'ghostel-tty-escape-test)
;;; ghostel-tty-escape-test.el ends here
