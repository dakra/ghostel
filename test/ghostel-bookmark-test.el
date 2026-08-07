;;; ghostel-bookmark-test.el --- Tests for ghostel: bookmarks -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs bookmark integration: the `bookmark-make-record-function' maker and
;; the jump handler.  The maker tests are pure elisp (a `ghostel-mode' buffer
;; spawns no process).  The handler tests need the native module: they spawn a
;; real shell and observe OSC 7 directory tracking, so they are tagged
;; `native'.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-bookmark)

(ert-deftest ghostel-test-bookmark-make-record ()
  "`ghostel--bookmark-make-record' captures handler, dir, and buffer name.
The directory goes under `location' so `bookmark-bmenu-list' shows it
instead of \"-- Unknown location --\"."
  (ghostel-test--with-compile-buffer buf
    (let* ((default-directory "/tmp/ghostel-bookmark-make-record/")
           (record (ghostel--bookmark-make-record)))
      (should (eq (bookmark-prop-get record 'handler)
                  'ghostel--bookmark-handler))
      (should (equal (bookmark-prop-get record 'location)
                     "/tmp/ghostel-bookmark-make-record/"))
      ;; `bookmark-location' is what the bmenu File column shows.  Point
      ;; `bookmark-default-file' at nothing so it cannot load the user's.
      (let ((bookmark-default-file "/nonexistent/ghostel-test-bookmarks"))
        (should (equal (bookmark-location record)
                       "/tmp/ghostel-bookmark-make-record/")))
      (should (equal (bookmark-prop-get record 'buf-name) (buffer-name))))))

(ert-deftest ghostel-test-bookmark-handler-type ()
  "The handler carries a `bookmark-handler-type' for the bmenu Type column."
  (should (equal (get 'ghostel--bookmark-handler 'bookmark-handler-type)
                 "Ghostel")))

(ert-deftest ghostel-test-bookmark-mode-wires-record-function ()
  "`ghostel-mode' wires `bookmark-make-record-function'; the record round-trips.
`bookmark-make-record' is the entry point bookmark.el itself uses on
`bookmark-set'; the handler and buffer name must survive its post-processing."
  (ghostel-test--with-compile-buffer buf
    (should (eq bookmark-make-record-function #'ghostel--bookmark-make-record))
    (let ((record (bookmark-make-record)))
      (should (eq (bookmark-prop-get record 'handler)
                  'ghostel--bookmark-handler))
      (should (equal (bookmark-prop-get record 'buf-name) (buffer-name))))))

(defun ghostel-test--bookmark-record (buf-name dir)
  "Return a ghostel bookmark record for BUF-NAME pointing at DIR."
  `(,buf-name
    (handler . ghostel--bookmark-handler)
    (location . ,dir)
    (buf-name . ,buf-name)
    (defaults . nil)))

(ert-deftest ghostel-test-bookmark-handler-creates-buffer ()
  "Jumping to a bookmark with no live buffer starts a fresh shell in its dir."
  :tags '(native)
  (let* ((ghostel-macos-login-shell nil)
         (dir (file-name-as-directory (make-temp-file "ghostel-bm-create" t)))
         (buf-name (generate-new-buffer-name " *ghostel-bm-create*"))
         (buf nil))
    (unwind-protect
        (progn
          (ghostel--bookmark-handler
           (ghostel-test--bookmark-record buf-name dir))
          (setq buf (get-buffer buf-name))
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should (eq major-mode 'ghostel-mode))
            (should (process-live-p ghostel--process))
            ;; `file-equal-p' tolerates OSC 7 / symlink-resolved variants.
            (should (file-equal-p default-directory dir))))
      (when (buffer-live-p (get-buffer buf-name))
        (ghostel-test--cleanup-exec-buffer (get-buffer buf-name)))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest ghostel-test-bookmark-handler-reuse-cd ()
  "Reusing a live buffer in a different dir types a TRAMP-stripped, quoted `cd'.
Asserts the exact bytes the handler sends rather than the shell's OSC 7
round-trip (that is ghostel's own directory tracking, covered elsewhere, and
too timing-sensitive to drive a real shell through here).  With
`ghostel-bookmark-check-dir' nil, nothing is typed."
  :tags '(native)
  ;; `ghostel-test--with-terminal-buffer' gives a live `ghostel--term' (so the
  ;; reuse-branch guard passes) without a process; we stub the send functions.
  (ghostel-test--with-terminal-buffer (buf term 24 80 1000)
    (let ((sent nil)
          (default-directory "/tmp/ghostel-bm-here/")
          ;; A remote dir with a space exercises both departures from vterm:
          ;; TRAMP-prefix stripping and shell quoting.
          (remote "/ssh:host:/remote dir/"))
      (cl-letf (((symbol-function 'ghostel-send-string)
                 (lambda (s) (push (cons 'string s) sent)))
                ((symbol-function 'ghostel-send-key)
                 (lambda (k &rest _) (push (cons 'key k) sent))))
        ;; Enabled + differing dir: a quoted `cd' with the TRAMP prefix stripped.
        (ghostel--bookmark-handler
         (ghostel-test--bookmark-record (buffer-name) remote))
        (should (equal (nreverse sent)
                       `((string . ,(concat "cd " (shell-quote-argument
                                                   (file-local-name remote))))
                         (key . "return"))))
        ;; Disabled: nothing is typed even though the dirs differ.
        (setq sent nil)
        (let ((ghostel-bookmark-check-dir nil))
          (ghostel--bookmark-handler
           (ghostel-test--bookmark-record (buffer-name) "/tmp/elsewhere/")))
        (should-not sent)))))

(provide 'ghostel-bookmark-test)
;;; ghostel-bookmark-test.el ends here
