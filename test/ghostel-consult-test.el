;;; ghostel-consult-test.el --- Tests for ghostel: consult -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-consult' source plists and their item/enabled/arrange logic.
;; consult itself is not on the test load path, so `consult--buffer-pair'
;; is stubbed and the commands (which `require' consult) are not exercised.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-consult)

(ert-deftest ghostel-test-consult-source-properties ()
  "Sources carry the consult properties that drive preview and create-on-miss."
  (dolist (src (list ghostel-consult-source ghostel-consult-project-source))
    (should (eq (plist-get src :category) 'buffer))
    (should (eq (plist-get src :state) 'consult--buffer-state))
    (should (functionp (plist-get src :new))))
  ;; Hidden variants inherit those and add `:hidden'.
  (dolist (src (list ghostel-consult-source-hidden
                     ghostel-consult-project-source-hidden))
    (should (plist-get src :hidden))
    (should (eq (plist-get src :category) 'buffer))
    (should (eq (plist-get src :state) 'consult--buffer-state))
    (should (functionp (plist-get src :new)))))

(ert-deftest ghostel-test-consult-source-items ()
  "`ghostel-consult-source' :items returns (name . buffer) pairs."
  (let ((a (generate-new-buffer " *ghostel-consult-a*"))
        (b (generate-new-buffer " *ghostel-consult-b*"))
        (inhibit-message t))
    (unwind-protect
        (progn
          (with-current-buffer a (ghostel-mode))
          (with-current-buffer b (ghostel-mode))
          (cl-letf (((symbol-function 'consult--buffer-pair)
                     (lambda (buf) (cons (buffer-name buf) buf))))
            (let* ((items (funcall (plist-get ghostel-consult-source :items)))
                   (bufs (mapcar #'cdr items)))
              (should (memq a bufs))
              (should (memq b bufs))
              (should (equal (car (rassq a items)) (buffer-name a))))))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest ghostel-test-consult-arrange-current-last ()
  "`ghostel-consult--arrange' preserves the set and puts current buffer last."
  (let ((a (generate-new-buffer " *ghostel-arrange-a*"))
        (b (generate-new-buffer " *ghostel-arrange-b*")))
    (unwind-protect
        (with-current-buffer a
          (let ((ordered (ghostel-consult--arrange (list a b))))
            ;; Same set, no dupes/drops.
            (should (equal (sort (mapcar #'buffer-name ordered) #'string<)
                           (sort (list (buffer-name a) (buffer-name b)) #'string<)))
            ;; Current buffer is last (you rarely switch to where you are).
            (should (eq (car (last ordered)) a))))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest ghostel-test-consult-new-empty-string ()
  "`:new' with a blank name (empty-list submission) reaches `ghostel-create'.
`ghostel-create' itself normalizes the empty name; here we only assert the
consult layer forwards it without erroring."
  (let (created)
    (cl-letf (((symbol-function 'ghostel-create)
               (lambda (name &rest _) (setq created name) (current-buffer))))
      (funcall (plist-get ghostel-consult-source :new) "")
      (should (equal created "")))))

(ert-deftest ghostel-test-consult-project-source-no-project ()
  "Project source is disabled and yields no items (no error) outside a project."
  (require 'project)
  (let ((project-find-functions nil))
    (should-not (funcall (plist-get ghostel-consult-project-source :enabled)))
    (should-not (funcall (plist-get ghostel-consult-project-source :items)))))

(provide 'ghostel-consult-test)
;;; ghostel-consult-test.el ends here
