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
  "`ghostel-buffer-name-by-title' maps TITLE to a name; nil gives nil."
  (with-temp-buffer
    (let ((name (buffer-name)))
      (should (equal "*ghostel: My Title*"
                     (ghostel-buffer-name-by-title "My Title")))
      (should (null (ghostel-buffer-name-by-title nil)))
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

(ert-deftest ghostel-test-title-is-buffer-local ()
  "`ghostel-title' stores each terminal buffer's title independently."
  (with-temp-buffer
    (ghostel--set-title "first")
    (with-temp-buffer
      (should (null ghostel-title))
      (ghostel--set-title "second")
      (should (equal "second" ghostel-title)))
    (should (equal "first" ghostel-title))))

(ert-deftest ghostel-test-set-title-renames-and-respects-manual ()
  "An OSC 2 title renames via the by-title function; a manual rename wins."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel-buffer-name-function #'ghostel-buffer-name-by-title))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (should (equal "*ghostel*" (buffer-name)))
              (should (equal "*ghostel*" ghostel--managed-buffer-name))
              (ghostel--set-title "Title A")
              (should (equal "Title A" ghostel-title))
              (should (equal "*ghostel: Title A*" (buffer-name)))
              (should (equal "*ghostel: Title A*" ghostel--managed-buffer-name))
              (ghostel--set-title "Title A2")
              (should (equal "*ghostel: Title A2*" (buffer-name)))
              (rename-buffer "manual title" t)
              (ghostel--set-title "Title B")
              (should (equal "manual title" (buffer-name)))
              (should (equal "*ghostel: Title A2*" ghostel--managed-buffer-name)))))
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
              (should (equal "Ignored" ghostel-title))
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

(ert-deftest ghostel-test-set-title-clear-reverts-name ()
  "An empty or nil title clears `ghostel-title' and reverts the name."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel-buffer-name-function #'ghostel-buffer-name-by-title))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (ghostel--set-title "Title A")
              (should (equal "*ghostel: Title A*" (buffer-name)))
              (ghostel--set-title "")
              (should (null ghostel-title))
              (should (equal "*ghostel*" (buffer-name)))
              (should (equal "*ghostel*" ghostel--managed-buffer-name))
              (ghostel--set-title "Title B")
              (should (equal "*ghostel: Title B*" (buffer-name)))
              (ghostel--set-title nil)
              (should (null ghostel-title))
              (should (equal "*ghostel*" (buffer-name))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-set-title-clear-respects-manual ()
  "A title clear declines to rename after a manual rename."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel-buffer-name-function #'ghostel-buffer-name-by-title))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (ghostel--set-title "Title A")
              (rename-buffer "manual title" t)
              (ghostel--set-title "")
              (should (null ghostel-title))
              (should (equal "manual title" (buffer-name))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-set-title-clear-unclaimed-keeps-name ()
  "A clear does not rename a buffer title tracking never renamed."
  (with-temp-buffer
    (setq-local ghostel--initial-name "*ghostel-orig*")
    (let ((ghostel-buffer-name-function #'ghostel-buffer-name-by-title)
          (name (buffer-name)))
      (ghostel--set-title "")
      (should (null ghostel-title))
      (should (equal name (buffer-name))))))

(ert-deftest ghostel-test-set-title-clear-by-directory-keeps-name ()
  "A title clear leaves a by-directory name alone."
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
                 #'ghostel-buffer-name-by-directory))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (let ((expected (ghostel-buffer-name-by-directory nil)))
                (ghostel--set-title "ignored")
                (should (equal expected (buffer-name)))
                (ghostel--set-title "")
                (should (null ghostel-title))
                (should (equal expected (buffer-name)))))))
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
          (should (null ghostel-title))
          (let ((before (buffer-name)))
            (ghostel--update-directory dir)
            (should (equal before (buffer-name)))
            (should (equal dir default-directory))))
      (delete-directory dir))))

;;; Mode-line buffer identification

(ert-deftest ghostel-test-buffer-name-function-default-nil ()
  "Renaming is off by default; the title lives in the mode line instead."
  (should (null (default-value 'ghostel-buffer-name-function))))

;; `format-mode-line' renders as "" in batch Emacs, so these tests
;; assert on the mode-line construct itself.  `equal' ignores text
;; properties: ("%b") is the live buffer-name construct returned by
;; `propertized-buffer-identification'.

(ert-deftest ghostel-test-buffer-identification-title-and-dir ()
  "%t and %d substitute; %b stays a live mode-line construct."
  (with-temp-buffer
    (setq-local ghostel-title "vim main.c")
    (let ((default-directory "/tmp/some/dir/"))
      (should (equal `("" ("%b") ,(format " (vim main.c) [%s]"
                                          (abbreviate-file-name
                                           "/tmp/some/dir")))
                     (ghostel--buffer-identification "%b (%t) [%d]"))))))

(ert-deftest ghostel-test-buffer-identification-truncates-title ()
  "A precision modifier caps the title; `help-echo' keeps the full title."
  (with-temp-buffer
    (setq-local ghostel-title "abcdefgh")
    (let* ((construct (ghostel--buffer-identification "%b %.5t"))
           (seg (car (last construct))))
      (should (equal '("" ("%b") " abcde") construct))
      (should (equal "abcdefgh"
                     (get-text-property (string-search "abcde" seg) 'help-echo
                                        seg))))))

(ert-deftest ghostel-test-buffer-identification-empty-title-fallback ()
  "A format referencing %t collapses to the buffer name without a title."
  (with-temp-buffer
    (setq-local ghostel-title nil)
    (should (equal '("%b")
                   (ghostel--buffer-identification "%b (%.30t)")))))

(ert-deftest ghostel-test-buffer-identification-no-title-spec-renders ()
  "A format without %t renders even when the terminal has no title."
  (with-temp-buffer
    (setq-local ghostel-title nil)
    (let ((default-directory "/tmp/some/dir/"))
      (should (equal `("" ("%b") ,(format " [%s]"
                                          (abbreviate-file-name
                                           "/tmp/some/dir")))
                     (ghostel--buffer-identification "%b [%d]"))))))

(ert-deftest ghostel-test-buffer-identification-escapes-percent ()
  "A % in the title is escaped instead of parsed as a mode-line construct."
  (with-temp-buffer
    (setq-local ghostel-title "100% done")
    (should (equal '("" ("%b") " (100%% done)")
                   (ghostel--buffer-identification "%b (%t)")))))

(ert-deftest ghostel-test-buffer-identification-b-ignores-modifiers ()
  "Width/precision modifiers on %b are dropped, not applied to the placeholder."
  (with-temp-buffer
    (setq-local ghostel-title "title")
    (dolist (fmt '("%-10b (%t)" "%12b (%t)" "%.0b (%t)"))
      (should (equal '("" ("%b") " (title)")
                     (ghostel--buffer-identification fmt))))))

(ert-deftest ghostel-test-buffer-identification-quoted-percent-not-title ()
  "A quoted %% before t is not read as a %t reference."
  (with-temp-buffer
    (setq-local ghostel-title nil)
    ;; No fallback: the format does not reference the title.
    (should (equal '("" ("%b") " 50%%tests")
                   (ghostel--buffer-identification "%b 50%%tests")))))

(ert-deftest ghostel-test-buffer-identification-help-echo-tracks-title ()
  "Titles sharing a truncated prefix still refresh the `help-echo'."
  (with-temp-buffer
    (let ((ghostel-buffer-identification-format "%b %.5t"))
      (setq-local ghostel-title "abcdeXX")
      (ghostel--buffer-identification-update)
      (setq-local ghostel-title "abcdeYY")
      (ghostel--buffer-identification-update)
      (let ((seg (car (last mode-line-buffer-identification))))
        (should (equal "abcdeYY"
                       (get-text-property (string-search "abcde" seg)
                                          'help-echo seg)))))))

(ert-deftest ghostel-test-buffer-identification-b-stays-live ()
  "%b expands to the live construct, never a frozen buffer name."
  (with-temp-buffer
    (setq-local ghostel-title "title")
    (let ((construct (ghostel--buffer-identification "%b (%t)")))
      (should (equal '("%b") (nth 1 construct)))
      ;; No segment carries a snapshot of the current buffer name.
      (dolist (part construct)
        (when (stringp part)
          (should-not (string-search (buffer-name) part)))))))

(ert-deftest ghostel-test-buffer-identification-nil-format-leaves-mode-line ()
  "A nil `ghostel-buffer-identification-format' leaves the mode line alone."
  (with-temp-buffer
    (setq-local ghostel-title "title")
    (let ((before mode-line-buffer-identification)
          (ghostel-buffer-identification-format nil))
      (ghostel--buffer-identification-update)
      (should (eq before mode-line-buffer-identification)))))

(ert-deftest ghostel-test-set-title-updates-identification ()
  "An OSC 2 title lands in the mode line; the buffer name stays put."
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
            ;; No title yet: identification is the plain buffer name.
            (should (equal '("%b") mode-line-buffer-identification))
            (ghostel--set-title "Hello")
            ;; Default `ghostel-buffer-name-function' nil: no rename.
            (should (equal "*ghostel*" (buffer-name)))
            (should (equal '("" ("%b") " (Hello)")
                           mode-line-buffer-identification))
            ;; Reinitializing a reused buffer drops the stale title.
            (ghostel--init-buffer buf)
            (should (null ghostel-title))
            (should (equal '("%b") mode-line-buffer-identification))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-update-directory-updates-identification ()
  "An OSC 7 `cd' recomputes a %d identification."
  (let ((dir (file-name-as-directory (make-temp-file "ghostel-cd" t)))
        (ghostel-buffer-identification-format "%b [%d]")
        buf)
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
            (ghostel--update-directory dir)
            (should (equal dir default-directory))
            (should (equal `("" ("%b") ,(format " [%s]"
                                                (abbreviate-file-name
                                                 (directory-file-name dir))))
                           mode-line-buffer-identification))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory dir))))

(provide 'ghostel-buffer-name-test)
;;; ghostel-buffer-name-test.el ends here
