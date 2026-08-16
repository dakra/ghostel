;;; ghostel-project-test.el --- Tests for ghostel: project -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-project` buffer naming, identity match, return-buffer semantics.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-project-buffer-name ()
  "`ghostel-project' derives the slot context and buffer name from the root."
  (require 'project)
  (let ((ghostel-buffer-name "*ghostel*")
        result)
    (cl-letf (((symbol-function 'project-current)
               (lambda (_maybe-prompt) '(transient . "/tmp/myproj/")))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'project-prefixed-buffer-name)
               (lambda (name) (format "*myproj-%s*" name)))
              ((symbol-function 'ghostel--start)
               (lambda (context name &optional _arg)
                 (setq result (list default-directory context name)))))
      (ghostel-project)
      (should (equal "/tmp/myproj/" (nth 0 result)))
      (should (equal `((kind . term)
                       (project-root . ,(ghostel--normalize-root
                                         "/tmp/myproj/")))
                     (nth 1 result)))
      (should (string-match-p "ghostel" (nth 2 result)))
      (should-not (string-match-p "\\*\\*" (nth 2 result))))))

(ert-deftest ghostel-test-project-universal-arg ()
  "`ghostel-project' forwards the prefix arg to the slot core."
  (require 'project)
  (dolist (arg '(4 (4)))
    (let ((ghostel-buffer-name "*ghostel*")
          captured)
      (cl-letf (((symbol-function 'project-current)
                 (lambda (_maybe-prompt) '(transient . "/tmp/myproj/")))
                ((symbol-function 'project-root)
                 (lambda (proj) (cdr proj)))
                ((symbol-function 'project-prefixed-buffer-name)
                 (lambda (name) (format "*myproj-%s*" name)))
                ((symbol-function 'ghostel--start)
                 (lambda (_context name &optional a)
                   (setq captured (cons a name)))))
        (ghostel-project arg)
        (should (equal (car captured) arg))
        (should (equal (cdr captured) "*myproj-ghostel*"))))))

(ert-deftest ghostel-test-project-buffer-name-remote ()
  "`ghostel--project-buffer-name' host-qualifies remote roots (bug #344)."
  (require 'project)
  (let ((ghostel-buffer-name "*ghostel*"))
    (cl-letf (((symbol-function 'project-prefixed-buffer-name)
               (lambda (name) (format "*myproj-%s*" name))))
      (should (equal (ghostel--project-buffer-name "/tmp/myproj/")
                     "*myproj-ghostel*"))
      (should (equal (ghostel--project-buffer-name
                      "/ssh:user@host:/tmp/myproj/")
                     "*myproj-ghostel@ssh:user@host*")))))

(ert-deftest ghostel-test-project-remote-not-confused-with-local ()
  "`ghostel-project' on a remote root ignores an equally named local buffer.
Regression test for bug #344: a local and a remote project with the
same name must get separate buffers."
  (require 'project)
  (let* ((ghostel-buffer-name "*ghostel*")
         (local (generate-new-buffer "*myproj-ghostel*"))
         (created (generate-new-buffer " *ghostel-test-remote-proj*"))
         result)
    (unwind-protect
        (progn
          (with-current-buffer local
            (ghostel-mode)
            (setq-local ghostel-identity
                        `((kind . term)
                          (project-root . ,(ghostel--normalize-root
                                            "/tmp/myproj/"))
                          (instance . 1)))
            (setq-local ghostel--term 'fake-term))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _)
                       '(transient . "/ssh:user@host:/tmp/myproj/")))
                    ((symbol-function 'project-root)
                     (lambda (proj) (cdr proj)))
                    ((symbol-function 'project-prefixed-buffer-name)
                     (lambda (name) (format "*myproj-%s*" name)))
                    ((symbol-function 'ghostel--load-module)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--create)
                     (lambda (&rest _) created))
                    ((symbol-function 'ghostel--start-process) #'ignore))
            (setq result (ghostel-project)))
          (should (eq result created))
          (with-current-buffer created
            (should (ghostel--identity-equal
                     ghostel-identity
                     `((kind . term)
                       (project-root . ,(ghostel--normalize-root
                                         "/ssh:user@host:/tmp/myproj/"))
                       (instance . 1))))))
      (dolist (b (list local created))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest ghostel-test-project-remote-reuses-remote ()
  "`ghostel-project' reuses the buffer of the same remote project."
  (require 'project)
  (let* ((ghostel-buffer-name "*ghostel*")
         (existing (generate-new-buffer "*myproj-ghostel@ssh:user@host*"))
         (pre-count (length (buffer-list)))
         popped)
    (unwind-protect
        (progn
          (with-current-buffer existing
            (ghostel-mode)
            (setq-local ghostel-identity
                        `((kind . term)
                          (project-root . ,(ghostel--normalize-root
                                            "/ssh:user@host:/tmp/myproj/"))
                          (instance . 1)))
            (setq-local ghostel--term 'fake-term))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&rest _)
                       '(transient . "/ssh:user@host:/tmp/myproj/")))
                    ((symbol-function 'project-root)
                     (lambda (proj) (cdr proj)))
                    ((symbol-function 'project-prefixed-buffer-name)
                     (lambda (name) (format "*myproj-%s*" name)))
                    ((symbol-function 'ghostel--load-module)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (b &rest _) (setq popped b))))
            (ghostel-project))
          (should (eq popped existing))
          (should (= pre-count (length (buffer-list)))))
      (when (buffer-live-p existing) (kill-buffer existing)))))

(ert-deftest ghostel-test-project-buffers-identity-scope-remote ()
  "Identity scope separates local and remote projects of the same name."
  (require 'project)
  (let ((ghostel-buffer-name "*ghostel*")
        (ghostel-project-buffer-scope 'identity)
        (local (generate-new-buffer "*ghostel: local myproj*"))
        (remote (generate-new-buffer "*ghostel: remote myproj*")))
    (unwind-protect
        (progn
          (with-current-buffer local
            (ghostel-mode)
            (setq-local ghostel-identity
                        `((kind . term)
                          (project-root . ,(ghostel--normalize-root
                                            "/tmp/myproj/"))
                          (instance . 1))))
          (with-current-buffer remote
            (ghostel-mode)
            (setq-local ghostel-identity
                        `((kind . term)
                          (project-root . ,(ghostel--normalize-root
                                            "/ssh:user@host:/tmp/myproj/"))
                          (instance . 1))))
          (cl-letf (((symbol-function 'project-root)
                     (lambda (proj) (cdr proj))))
            (cl-letf (((symbol-function 'project-current)
                       (lambda (&rest _) '(transient . "/tmp/myproj/"))))
              (should (equal (ghostel-project-buffer-list) (list local))))
            (cl-letf (((symbol-function 'project-current)
                       (lambda (&rest _)
                         '(transient . "/ssh:user@host:/tmp/myproj/"))))
              (should (equal (ghostel-project-buffer-list) (list remote))))))
      (dolist (b (list local remote))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest ghostel-test-reuses-identity-match-after-rename ()
  "`ghostel' reuses an identity-matched buffer after a title-tracking rename."
  (let* ((ghostel-buffer-name "*ghostel*")
         (existing (generate-new-buffer ghostel-buffer-name))
         (pre-count (length (buffer-list)))
         popped)
    (unwind-protect
        (progn
          (with-current-buffer existing
            (ghostel-mode)
            (setq-local ghostel-identity
                        '((kind . term) (name . "*ghostel*") (instance . 1)))
            (setq-local ghostel--term 'fake-term))
          (with-current-buffer existing (rename-buffer "*ghostel: zsh*"))
          (cl-letf (((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (b &rest _) (setq popped b))))
            (ghostel))
          (should (buffer-live-p existing))
          (should (eq popped existing))
          (should (equal "*ghostel: zsh*" (buffer-name existing)))
          (should (= pre-count (length (buffer-list)))))
      (when (buffer-live-p existing) (kill-buffer existing)))))

(ert-deftest ghostel-test-project-reuses-identity-match-after-rename ()
  "`ghostel-project' reuses a project's buffer after title tracking renames it."
  (require 'project)
  (let* ((ghostel-buffer-name "*ghostel*")
         (project-name "*myproj-ghostel*")
         (existing (generate-new-buffer project-name))
         (pre-count (length (buffer-list)))
         popped)
    (unwind-protect
        (progn
          (with-current-buffer existing
            (ghostel-mode)
            (setq-local ghostel-identity
                        `((kind . term)
                          (project-root . ,(ghostel--normalize-root
                                            "/tmp/myproj/"))
                          (instance . 1)))
            (setq-local ghostel--term 'fake-term))
          (with-current-buffer existing (rename-buffer "*ghostel: zsh*"))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _) '(transient . "/tmp/myproj/")))
                    ((symbol-function 'project-root)
                     (lambda (proj) (cdr proj)))
                    ((symbol-function 'project-prefixed-buffer-name)
                     (lambda (name) (format "*myproj-%s*" name)))
                    ((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (b &rest _) (setq popped b))))
            (ghostel-project))
          (should (buffer-live-p existing))
          (should (eq popped existing))
          (should (equal "*ghostel: zsh*" (buffer-name existing)))
          (should (= pre-count (length (buffer-list)))))
      (when (buffer-live-p existing) (kill-buffer existing)))))

(ert-deftest ghostel-test-ghostel-records-identity ()
  "`ghostel' records the identity it will use for later reuse."
  (let ((ghostel-buffer-name "*ghostel-identity-test*")
        (created (generate-new-buffer "*ghostel-identity-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
                  ((symbol-function 'ghostel--create) (lambda (&rest _) created))
                  ((symbol-function 'ghostel--start-process) #'ignore))
          (should (eq (ghostel) created))
          (with-current-buffer created
            (should (ghostel--identity-equal
                     ghostel-identity '((kind . term)
                                        (name . "*ghostel-identity-test*")
                                        (instance . 1))))
            (should (equal ghostel--managed-buffer-name (buffer-name)))
            (should (equal ghostel--initial-name (buffer-name)))))
      (when (buffer-live-p created)
        (kill-buffer created)))))

(ert-deftest ghostel-test-let-bound-buffer-name-gets-own-slot ()
  "A non-default `ghostel-buffer-name' keys its own slot family."
  (let ((created (generate-new-buffer "*scratch-term*"))
        (other nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
                  ((symbol-function 'ghostel--create)
                   (lambda (&rest _)
                     (with-current-buffer created
                       (setq major-mode 'ghostel-mode)
                       (setq-local ghostel--term 'fake-term))
                     created))
                  ((symbol-function 'ghostel--start-process) #'ignore))
          (let ((ghostel-buffer-name "*scratch-term*"))
            (should (eq (ghostel) created)))
          (with-current-buffer created
            (should (equal (alist-get 'name ghostel-identity)
                           "*scratch-term*")))
          ;; A default-named `ghostel' must not reuse the named slot.
          (setq other (generate-new-buffer "*ghostel*"))
          (cl-letf (((symbol-function 'ghostel--create) (lambda (&rest _) other)))
            (let ((ghostel-buffer-name "*ghostel*"))
              (should (eq (ghostel) other)))
            (with-current-buffer other
              (should (equal (alist-get 'name ghostel-identity)
                             "*ghostel*")))))
      (dolist (b (list created other))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest ghostel-test-init-buffer-clears-buffer ()
  "`ghostel--init-buffer' clears existing buffer contents."
  (let ((buf (generate-new-buffer " *ghostel-test-nonempty*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "existing text"))
          (cl-letf (((symbol-function 'ghostel--new) (lambda (&rest _) 'fake))
                    ((symbol-function 'ghostel--set-size) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore))
            (ghostel--init-buffer buf))
          (with-current-buffer buf
            (should (zerop (buffer-size)))
            (should (eq ghostel--term 'fake))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-init-buffer-replaces-stale-terminal ()
  "`ghostel--init-buffer' preserves identity while replacing stale terminal state."
  (let ((buf (generate-new-buffer " *ghostel-test-reinit*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (ghostel-mode)
            (setq-local ghostel--term 'old-term)
            (setq-local ghostel--term-rows 1)
            (setq-local ghostel--term-cols 2)
            (setq-local ghostel--managed-buffer-name "managed")
            (setq-local ghostel-identity '((kind . exec))))
          (cl-letf (((symbol-function 'ghostel--new) (lambda (&rest _) 'new-term))
                    ((symbol-function 'ghostel--set-size) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore))
            (ghostel--init-buffer buf 7 33))
          (with-current-buffer buf
            (should (eq ghostel--term 'new-term))
            (should-not ghostel--term-rows)
            (should-not ghostel--term-cols)
            (should (equal ghostel--managed-buffer-name "managed"))
            (should (equal ghostel-identity '((kind . exec))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-create-initializes-buffer ()
  "`ghostel--create' creates a buffer and attaches its terminal through init."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new) (lambda (&rest _) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette) #'ignore))
          (setq buf (ghostel--create " *ghostel-test-create*" nil 7 33))
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should (derived-mode-p 'ghostel-mode))
            (should (eq ghostel--term 'fake-term))
            (should-not ghostel--term-rows)
            (should-not ghostel--term-cols)
            ;; Identity is assigned by the caller, never by creation.
            (should-not ghostel-identity)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-create-kills-buffer-on-quit ()
  "`ghostel--create' kills the partially created buffer on quit.
A keyboard quit can arrive during initialization, e.g. at a dir-locals
prompt in `ghostel-mode'.  Uses `condition-case' directly since
`should-error' only traps `error', not `quit'."
  (cl-letf (((symbol-function 'ghostel--init-buffer)
             (lambda (&rest _) (signal 'quit nil))))
    (unwind-protect
        (progn
          (should (eq 'quit
                      (condition-case err
                          (progn (ghostel--create " *ghostel-test-quit*") nil)
                        (quit (car err)))))
          (should-not (get-buffer " *ghostel-test-quit*")))
      (when-let* ((leftover (get-buffer " *ghostel-test-quit*")))
        (kill-buffer leftover)))))

(ert-deftest ghostel-test-returns-buffer ()
  "`ghostel' returns the (live) Ghostel buffer."
  (let ((created (generate-new-buffer "*ghostel-return-test*"))
        result)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
                  ((symbol-function 'ghostel--create) (lambda (&rest _) created))
                  ((symbol-function 'ghostel--start-process) #'ignore))
          (setq result (ghostel))
          (should (eq result created))
          (should (buffer-live-p result)))
      (when (buffer-live-p created)
        (kill-buffer created)))))

(ert-deftest ghostel-test-project-returns-buffer ()
  "`ghostel-project' returns the (live) Ghostel buffer."
  (require 'project)
  (let ((created (generate-new-buffer "*retproj-ghostel*"))
        result)
    (unwind-protect
        (cl-letf (((symbol-function 'project-current)
                   (lambda (&optional _) '(transient . "/tmp/retproj/")))
                  ((symbol-function 'project-root)
                   (lambda (proj) (cdr proj)))
                  ((symbol-function 'project-prefixed-buffer-name)
                   (lambda (name) (format "*retproj-%s*" name)))
                  ((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
                  ((symbol-function 'ghostel--create) (lambda (&rest _) created))
                  ((symbol-function 'ghostel--start-process) #'ignore))
          (setq result (ghostel-project))
          (should (eq result created))
          (should (buffer-live-p result)))
      (when (buffer-live-p created)
        (kill-buffer created)))))

(ert-deftest ghostel-test-first-creation-respects-display-buffer-alist ()
  "First `ghostel' creation exposes `ghostel-mode' to display rules."
  (let ((saved (current-window-configuration))
        (origin (generate-new-buffer " *ghostel-test-origin*"))
        (ghostel-buffer-name "*ghostel-test-display*"))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer origin)
          (let ((display-buffer-alist
                 `((,(lambda (buf _action)
                       (with-current-buffer buf
                         (derived-mode-p 'ghostel-mode)))
                    (display-buffer-pop-up-window)))))
            (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                      ((symbol-function 'ghostel--new)
                       (lambda (&rest _) 'fake-term))
                      ((symbol-function 'ghostel--set-size) #'ignore)
                      ((symbol-function 'ghostel--apply-palette) #'ignore)
                      ((symbol-function 'ghostel--start-process) #'ignore))
              (ghostel)))
          (let ((created (get-buffer ghostel-buffer-name)))
            (should (buffer-live-p created))
            (should (with-current-buffer created
                      (derived-mode-p 'ghostel-mode)))
            (should (get-buffer-window origin))
            (should (get-buffer-window created))
            (should (not (eq (get-buffer-window origin)
                             (get-buffer-window created))))))
      (when (get-buffer ghostel-buffer-name)
        (kill-buffer ghostel-buffer-name))
      (when (buffer-live-p origin)
        (kill-buffer origin))
      (set-window-configuration saved))))

(provide 'ghostel-project-test)
;;; ghostel-project-test.el ends here
