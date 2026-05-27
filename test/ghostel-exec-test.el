;;; ghostel-exec-test.el --- Tests for ghostel: exec -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-exec` public API and `ghostel-eshell` visual-command integration.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-exec-errors-on-live-process ()
  "`ghostel-exec' signals `user-error' if BUFFER has a live process."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq ghostel--process 'fake-process))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'process-live-p)
                     (lambda (p) (eq p 'fake-process))))
            (should-error (ghostel-exec buf "ls" nil) :type 'user-error)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-threads-remote-p-from-tramp-dir ()
  "`ghostel-exec' derives remote-p from BUFFER's `default-directory'."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*"))
        captured)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local default-directory "/ssh:somehost:/home/user/"))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--new)
                     (lambda (&rest _) 'fake-term))
                    ((symbol-function 'ghostel--set-size) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore)
                    ((symbol-function 'ghostel--spawn-pty)
                     (lambda (&rest args) (setq captured args) 'fake-proc)))
            (ghostel-exec buf "ls" nil)
            (should (nth 6 captured))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-uses-default-size-when-buffer-not-displayed ()
  "`ghostel-exec' on an undisplayed buffer uses the 80x24 default.
Falling back to (selected-window) sized the PTY from whatever window
happened to be focused at call time, which rarely matches where the
buffer eventually shows up."
  (let ((buf (generate-new-buffer "ghostel-exec-test"))
        captured)
    (unwind-protect
        (progn
          ;; Sanity: the buffer is not displayed in any window.
          (should-not (get-buffer-window buf t))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--new)
                     (lambda (&rest args) (setq captured args) 'fake-term))
                    ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore)
                    ((symbol-function 'ghostel--spawn-pty)
                     (lambda (&rest _) 'fake-proc)))
            (ghostel-exec buf "ls" nil)
            ;; ghostel--new is called as
            ;; (height width max-scrollback kitty-storage-limit kitty-mediums-bits).
            (should (equal captured
                           (list 24 80
                                 ghostel-max-scrollback
                                 ghostel-kitty-graphics-storage-limit
                                 (ghostel--kitty-mediums-bits))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-preserves-identity-bookkeeping ()
  "`ghostel-exec' does not clobber buffer identity bookkeeping vars."
  (let ((buf (generate-new-buffer " *ghostel-exec-identity*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (ghostel-mode)
            (setq-local ghostel--managed-buffer-name "managed")
            (setq-local ghostel--buffer-identity "identity"))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--new)
                     (lambda (&rest _) 'fake-term))
                    ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore)
                    ((symbol-function 'ghostel--apply-bold-config) #'ignore)
                    ((symbol-function 'ghostel--spawn-pty)
                     (lambda (&rest _) 'fake-proc)))
            (ghostel-exec buf "ls" nil)
            (with-current-buffer buf
              (should (equal ghostel--managed-buffer-name "managed"))
              (should (equal ghostel--buffer-identity "identity")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-eshell-visual-command-mode-toggles-advice ()
  "Enabling/disabling the mode adds/removes the `eshell-exec-visual' advice."
  (let ((was-on ghostel-eshell-visual-command-mode))
    (unwind-protect
        (progn
          (ghostel-eshell-visual-command-mode -1)
          (should-not (advice-member-p #'ghostel-eshell--exec-visual
                                       'eshell-exec-visual))
          (ghostel-eshell-visual-command-mode 1)
          (should (advice-member-p #'ghostel-eshell--exec-visual
                                   'eshell-exec-visual))
          (ghostel-eshell-visual-command-mode -1)
          (should-not (advice-member-p #'ghostel-eshell--exec-visual
                                       'eshell-exec-visual)))
      (ghostel-eshell-visual-command-mode (if was-on 1 -1)))))

(ert-deftest ghostel-test-eshell/ghostel-dispatches-to-exec-visual ()
  "`eshell/ghostel' forwards its arguments to `eshell-exec-visual'."
  :tags '(native)
  (let (captured)
    (cl-letf (((symbol-function 'eshell-exec-visual)
               (lambda (&rest args) (setq captured args))))
      (eshell/ghostel "vim" "file.txt")
      (should (equal captured '("vim" "file.txt"))))))

(provide 'ghostel-exec-test)
;;; ghostel-exec-test.el ends here
