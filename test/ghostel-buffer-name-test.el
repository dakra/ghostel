;;; ghostel-buffer-name-test.el --- Tests for ghostel: buffer naming -*- lexical-binding: t; -*-

;;; Commentary:

;; Event-driven buffer naming.  A single `ghostel-buffer-name-function'
;; maps the terminal title (OSC 2) and `default-directory' (OSC 7) to a
;; buffer name, applied through the `ghostel--rename-managed' guard which
;; defers to a manual rename.  The latest OSC title is kept buffer-local so
;; title changes and `cd' events can both apply the same naming function.

;;; Code:

(require 'ghostel-test-helpers)

;;; Pure formatters

(ert-deftest ghostel-test-buffer-name-by-title-is-pure ()
  "`ghostel-buffer-name-by-title' maps TITLE to a name; nil/empty give nil."
  (with-temp-buffer
    (let ((name (buffer-name)))
      (should (equal "*ghostel: My Title*"
                     (ghostel-buffer-name-by-title "My Title")))
      (should (null (ghostel-buffer-name-by-title nil)))
      (should (null (ghostel-buffer-name-by-title "")))
      ;; Pure: computing the name must not rename the current buffer.
      (should (equal name (buffer-name))))))

(ert-deftest ghostel-test-buffer-name-by-directory-is-pure ()
  "`ghostel-buffer-name-by-directory' names from `default-directory'."
  (let ((default-directory "/tmp/some/dir/"))
    (with-temp-buffer
      (let ((name (buffer-name))
            (expected (format "*ghostel: %s*"
                              (abbreviate-file-name
                               (directory-file-name default-directory)))))
        (should (equal expected (ghostel-buffer-name-by-directory nil)))
        ;; The title argument is ignored.
        (should (equal expected (ghostel-buffer-name-by-directory "ignored")))
        (should (equal name (buffer-name)))))))

(ert-deftest ghostel-test-set-title-function-obsolete-alias ()
  "`ghostel-set-title-function' is an obsolete alias for the new variable."
  (should (eq (indirect-variable 'ghostel-set-title-function)
              'ghostel-buffer-name-function)))

;;; Title path (OSC 2) -- pure elisp

(ert-deftest ghostel-test-set-title-renames-and-respects-manual ()
  "An OSC 2 title renames via the default function; a manual rename wins."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (ghostel)
          (setq buf (current-buffer))
          (with-current-buffer buf
            (should (equal "*ghostel*" (buffer-name)))
            (should (equal "*ghostel*" ghostel--managed-buffer-name))
            (ghostel--set-title "Title A")
            (should (equal "Title A" ghostel--title))
            (should (equal "*ghostel: Title A*" (buffer-name)))
            (should (equal "*ghostel: Title A*" ghostel--managed-buffer-name))
            (ghostel--set-title "Title A2")
            (should (equal "*ghostel: Title A2*" (buffer-name)))
            (rename-buffer "manual title" t)
            (ghostel--set-title "Title B")
            (should (equal "manual title" (buffer-name)))
            (should (equal "*ghostel: Title A2*" ghostel--managed-buffer-name))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-buffer-name-disabled ()
  "A nil `ghostel-buffer-name-function' disables renaming."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel-buffer-name-function nil))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (should (equal "*ghostel*" (buffer-name)))
              (ghostel--set-title "Ignored")
              (should (equal "Ignored" ghostel--title))
              (should (equal "*ghostel*" (buffer-name)))
              (should (equal "*ghostel*" ghostel--managed-buffer-name)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-buffer-name-custom-function ()
  "A custom `ghostel-buffer-name-function' drives the rename."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel-buffer-name-function
                 (lambda (title) (format "term[%s]" title))))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (ghostel--set-title "A")
              (should (equal "term[A]" (buffer-name)))
              (should (equal "term[A]" ghostel--managed-buffer-name)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-buffer-name-nil-return-keeps-name ()
  "A nil return from `ghostel-buffer-name-function' leaves the name."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          ;; `ignore' returns nil for any title.
          (let ((ghostel-buffer-name-function #'ignore))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (should (equal "*ghostel*" (buffer-name)))
              (ghostel--set-title "Whatever")
              (should (equal "*ghostel*" (buffer-name)))
              (should (equal "*ghostel*" ghostel--managed-buffer-name)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; Directory path (OSC 7) and combination -- native term

(ert-deftest ghostel-test-directory-rename-by-directory ()
  "With the by-directory function, an OSC 7 `cd' names by directory."
  :tags '(native)
  (let ((dir (file-name-as-directory (make-temp-file "ghostel-cd" t)))
        (ghostel-buffer-name-function #'ghostel-buffer-name-by-directory))
    (unwind-protect
        (ghostel-test--with-terminal-buffer (_buf _term 25 80 1000)
          (ghostel--update-directory dir)
          (let ((expected (format "*ghostel: %s*"
                                  (abbreviate-file-name
                                   (directory-file-name dir)))))
            (should (equal dir default-directory))
            (should (equal expected (buffer-name)))
            (should (equal expected ghostel--managed-buffer-name))))
      (delete-directory dir))))

(ert-deftest ghostel-test-directory-rename-respects-manual ()
  "A manual rename survives a later OSC 7 `cd'; the directory still tracks."
  :tags '(native)
  (let ((dir1 (file-name-as-directory (make-temp-file "ghostel-cd1" t)))
        (dir2 (file-name-as-directory (make-temp-file "ghostel-cd2" t)))
        (ghostel-buffer-name-function #'ghostel-buffer-name-by-directory))
    (unwind-protect
        (ghostel-test--with-terminal-buffer (_buf _term 25 80 1000)
          (ghostel--update-directory dir1)
          (let ((first (format "*ghostel: %s*"
                               (abbreviate-file-name
                                (directory-file-name dir1)))))
            (should (equal first (buffer-name)))
            (rename-buffer "manual cd test" t)
            (ghostel--update-directory dir2)
            (should (equal "manual cd test" (buffer-name)))
            (should (equal first ghostel--managed-buffer-name))
            (should (equal dir2 default-directory))))
      (delete-directory dir1)
      (delete-directory dir2))))

(ert-deftest ghostel-test-buffer-name-combined ()
  "A combined function uses the buffer-local title plus cwd.
This is the cross-input case from issue #357."
  :tags '(native)
  (let ((dir (file-name-as-directory (make-temp-file "ghostel-cd" t)))
        (ghostel-buffer-name-function
         (lambda (title)
           (let ((cwd (directory-file-name
                       (abbreviate-file-name default-directory))))
             (if (and title (not (string= "" title)))
                 (format "ghostel::%s::%s" cwd title)
               (format "ghostel::%s" cwd))))))
    (unwind-protect
        (ghostel-test--with-terminal-buffer (_buf _term 25 80 1000)
          (ghostel--set-title "build")
          ;; A cd now combines the new cwd with the buffer-local title.
          (ghostel--update-directory dir)
          (should (equal dir default-directory))
          (should (equal (format "ghostel::%s::build"
                                 (directory-file-name
                                  (abbreviate-file-name dir)))
                         (buffer-name))))
      (delete-directory dir))))

(ert-deftest ghostel-test-by-title-cd-keeps-name-when-no-title ()
  "By-title default: a `cd' before any title leaves the name unchanged.
Guards against renaming to \"*ghostel: nil*\" before a title is set."
  :tags '(native)
  (let ((dir (file-name-as-directory (make-temp-file "ghostel-cd" t)))
        (ghostel-buffer-name-function #'ghostel-buffer-name-by-title))
    (unwind-protect
        (ghostel-test--with-terminal-buffer (_buf _term 25 80 1000)
          (should (null ghostel--title))
          (let ((before (buffer-name)))
            (ghostel--update-directory dir)
            (should (equal before (buffer-name)))
            (should (equal dir default-directory))))
      (delete-directory dir))))

(provide 'ghostel-buffer-name-test)
;;; ghostel-buffer-name-test.el ends here
