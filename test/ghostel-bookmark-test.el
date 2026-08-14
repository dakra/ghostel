;;; ghostel-bookmark-test.el --- Tests for ghostel: bookmarks -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs bookmark integration: the `bookmark-make-record-function' maker and
;; the jump handler.  The maker tests and the stub-driven handler tests are
;; pure elisp (a `ghostel-mode' buffer spawns no process; reuse tests attach
;; a dummy pipe process so the handler's live-shell check passes).  Handler
;; tests that spawn a real shell are tagged `native'.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-bookmark)

(ert-deftest ghostel-test-bookmark-make-record ()
  "`ghostel-bookmark-make-record' captures handler, dir, name, and identity.
The directory goes under `location' so `bookmark-bmenu-list' shows it
instead of \"-- Unknown location --\"."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-identity '((kind . term) (instance . 42)))
    (let* ((default-directory "/tmp/ghostel-bookmark-make-record/")
           (record (ghostel-bookmark-make-record)))
      (should (equal (bookmark-prop-get record 'identity)
                     '((kind . term) (instance . 42))))
      (should (eq (bookmark-prop-get record 'handler)
                  'ghostel-bookmark-handler))
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
  (should (equal (get 'ghostel-bookmark-handler 'bookmark-handler-type)
                 "Ghostel")))

(ert-deftest ghostel-test-bookmark-old-handler-name-restores ()
  "Records naming the pre-rename private handler still restore.
Bookmark files persist the handler symbol, so the old name must stay
funcall-able and carry the bmenu Type property."
  (should (eq (indirect-function 'ghostel--bookmark-handler)
              (indirect-function 'ghostel-bookmark-handler)))
  (should (equal (get 'ghostel--bookmark-handler 'bookmark-handler-type)
                 "Ghostel")))

(ert-deftest ghostel-test-bookmark-mode-wires-record-function ()
  "`ghostel-mode' wires `bookmark-make-record-function'; the record round-trips.
`bookmark-make-record' is the entry point bookmark.el itself uses on
`bookmark-set'; the handler and buffer name must survive its post-processing."
  (ghostel-test--with-compile-buffer buf
    (should (eq bookmark-make-record-function #'ghostel-bookmark-make-record))
    (let ((record (bookmark-make-record)))
      (should (eq (bookmark-prop-get record 'handler)
                  'ghostel-bookmark-handler))
      (should (equal (bookmark-prop-get record 'buf-name) (buffer-name))))))

(defun ghostel-test--bookmark-record (buf-name dir &optional identity)
  "Return a ghostel bookmark record for BUF-NAME pointing at DIR.
Non-nil IDENTITY adds an `identity' property; omitting it mimics a
record saved before identities were recorded."
  `(,buf-name
    (handler . ghostel-bookmark-handler)
    (location . ,dir)
    (buf-name . ,buf-name)
    ,@(and identity `((identity . ,identity)))
    (defaults . nil)))

(ert-deftest ghostel-test-bookmark-handler-reuses-by-identity ()
  "A renamed buffer is still reused when the record carries its identity.
The default `ghostel-buffer-name-function' renames buffers from the
terminal title, so the name recorded at `bookmark-set' time is usually
stale by jump time; the rename-stable identity must find the buffer."
  (ghostel-test--with-compile-buffer buf
    (let ((id '((kind . term) (project-root . "~/bm-reuse/") (instance . 1))))
      (setq ghostel-identity id
            default-directory "/tmp/ghostel-bm-reuse/")
      (setq-local ghostel--process (ghostel-test--dummy-process "bm-reuse" nil))
      (rename-buffer (generate-new-buffer-name " *ghostel-bm-renamed*"))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--create)
                     (lambda (&rest _)
                       (ert-fail "Created a new buffer instead of reusing"))))
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record " *ghostel-bm-stale-name*"
                                              "/tmp/ghostel-bm-reuse/"
                                              id))
              (should (eq (current-buffer) buf))))
        (delete-process ghostel--process)))))

(ert-deftest ghostel-test-bookmark-handler-reuses-by-name-fallback ()
  "A record without identity (saved before identities) reuses by name."
  (ghostel-test--with-compile-buffer buf
    (setq default-directory "/tmp/ghostel-bm-name/")
    (setq-local ghostel--process (ghostel-test--dummy-process "bm-name" nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                  ((symbol-function 'ghostel--create)
                   (lambda (&rest _)
                     (ert-fail "Created a new buffer instead of reusing"))))
          (with-temp-buffer
            (ghostel-bookmark-handler
             (ghostel-test--bookmark-record (buffer-name buf)
                                            "/tmp/ghostel-bm-name/"))
            (should (eq (current-buffer) buf))))
      (delete-process ghostel--process))))

(ert-deftest ghostel-test-bookmark-handler-skips-dead-identity-holder ()
  "A dead buffer sharing the identity must not shadow a live one.
After a dead-shell fall-through both the retained buffer and its
replacement carry the bookmarked identity; when the dead one ranks
higher in `buffer-list' the handler must still reuse the live one."
  (ghostel-test--with-compile-buffer dead
    (let ((id '((kind . term) (instance . 9))))
      (setq ghostel-identity id)
      (let ((live (generate-new-buffer " *ghostel-bm-shadow-live*")))
        (unwind-protect
            (progn
              (with-current-buffer live
                (ghostel-mode)
                (setq ghostel-identity id
                      default-directory "/tmp/ghostel-bm-shadow/")
                (setq-local ghostel--process
                            (ghostel-test--dummy-process "bm-shadow" nil)))
              (bury-buffer live)
              ;; Precondition: the dead buffer outranks the live one.
              (should (eq (ghostel--find-buffer-by-identity id) dead))
              (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                        ((symbol-function 'ghostel--create)
                         (lambda (&rest _)
                           (ert-fail "Created a new buffer instead of reusing"))))
                (with-temp-buffer
                  (ghostel-bookmark-handler
                   (ghostel-test--bookmark-record " *ghostel-bm-shadow-stale*"
                                                  "/tmp/ghostel-bm-shadow/"
                                                  id))
                  (should (eq (current-buffer) live)))))
          (let ((p (buffer-local-value 'ghostel--process live)))
            (when (processp p) (delete-process p)))
          (kill-buffer live))))))

(ert-deftest ghostel-test-bookmark-handler-identity-record-skips-name ()
  "An identity-bearing record must not reuse an unrelated name match.
When the identity's buffer is gone, a live shell that merely holds the
recorded (often generic) name must be left alone; the jump creates a
fresh buffer instead of typing a `cd' into the unrelated one."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-identity '((kind . term) (instance . 77)))
    (setq-local ghostel--process (ghostel-test--dummy-process "bm-other" nil))
    (let ((created nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--create)
                     (lambda (name &rest _)
                       (let ((b (generate-new-buffer name)))
                         (with-current-buffer b (ghostel-mode))
                         (setq created b)
                         b)))
                    ((symbol-function 'ghostel--start-process) #'ignore)
                    ((symbol-function 'ghostel--apply-initial-input-mode)
                     #'ignore))
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record (buffer-name buf)
                                              "/tmp/ghostel-bm-other/"
                                              '((kind . term)
                                                (instance . 78))))
              (should created)
              (should (eq (current-buffer) created))))
        (delete-process ghostel--process)
        (when (buffer-live-p created) (kill-buffer created))))))

(ert-deftest ghostel-test-bookmark-handler-dead-shell-creates-fresh ()
  "A matched buffer whose shell has exited is not reused.
With `ghostel-kill-buffer-on-exit' nil the buffer outlives its shell;
typing a `cd' into the dead PTY would error mid-jump, so the handler
must fall through to the create branch instead."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-identity '((kind . term) (instance . 5)))
    (let ((created nil))
      (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                ((symbol-function 'ghostel--create)
                 (lambda (name &rest _)
                   (let ((b (generate-new-buffer name)))
                     (with-current-buffer b (ghostel-mode))
                     (setq created b)
                     b)))
                ((symbol-function 'ghostel--start-process) #'ignore)
                ((symbol-function 'ghostel--apply-initial-input-mode)
                 #'ignore))
        (unwind-protect
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record (buffer-name buf)
                                              "/tmp/ghostel-bm-dead/"
                                              '((kind . term)
                                                (instance . 5))))
              (should created)
              (should (eq (current-buffer) created)))
          (when (buffer-live-p created)
            (kill-buffer created)))))))

(ert-deftest ghostel-test-bookmark-handler-create-stamps-identity ()
  "The create branch stamps the recorded identity.
Records without one (or with a pre-structured name string) get no
identity: fabricating a slot would let plain `ghostel' claim the
restored buffer."
  (let ((made nil))
    (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel--create)
               (lambda (name &rest _)
                 (let ((b (generate-new-buffer name)))
                   (with-current-buffer b (ghostel-mode))
                   (push b made)
                   b)))
              ((symbol-function 'ghostel--start-process) #'ignore)
              ((symbol-function 'ghostel--apply-initial-input-mode) #'ignore))
      (unwind-protect
          (progn
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record " *ghostel-bm-new*"
                                              "/tmp/ghostel-bm-create/"
                                              '((kind . term)
                                                (project-root . "~/bm/")
                                                (instance . 2)))))
            (should (equal (buffer-local-value 'ghostel-identity (car made))
                           '((kind . term)
                             (project-root . "~/bm/")
                             (instance . 2))))
            ;; Legacy record: a string identity is treated as absent.
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record " *ghostel-bm-old*"
                                              "/tmp/ghostel-bm-create/"
                                              "bm-legacy-name")))
            (should-not (buffer-local-value 'ghostel-identity (car made))))
        (dolist (b made)
          (when (buffer-live-p b) (kill-buffer b)))))))

(ert-deftest ghostel-test-bookmark-handler-kind-identity-not-reused ()
  "A kind-only identity (no `instance') is shared, so reuse goes by name.
A live buffer of the same kind running a different program must not
be hijacked; the jump creates a fresh buffer instead."
  (ghostel-test--with-compile-buffer other
    (setq ghostel-identity '((kind . eshell)))
    (setq-local ghostel--process (ghostel-test--dummy-process "bm-kind" nil))
    (let ((created nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--create)
                     (lambda (name &rest _)
                       (let ((b (generate-new-buffer name)))
                         (with-current-buffer b (ghostel-mode))
                         (setq created b)
                         b)))
                    ((symbol-function 'ghostel--start-process) #'ignore)
                    ((symbol-function 'ghostel--apply-initial-input-mode)
                     #'ignore))
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record " *ghostel-bm-kind-stale*"
                                              "/tmp/ghostel-bm-kind/"
                                              '((kind . eshell))))
              (should created)
              (should (eq (current-buffer) created))))
        (delete-process ghostel--process)
        (when (buffer-live-p created) (kill-buffer created))))))

(ert-deftest ghostel-test-bookmark-handler-reattaches-by-command ()
  "A command record reattaches to the live buffer running that command.
The buffer's (possibly uniquified) name is irrelevant; a different
command does not match; no `cd' is typed into a command buffer."
  (ghostel-test--with-compile-buffer running
    (rename-buffer " *ghostel-bm-vim*<2>" t)
    (setq ghostel-identity '((kind . eshell) (command . ("vim" "notes"))))
    (setq-local ghostel--term 'fake-term)
    (setq default-directory "/tmp/ghostel-bm-a/")
    (setq-local ghostel--process (ghostel-test--dummy-process "bm-vim" nil))
    (let (sent created)
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel-send-string)
                     (lambda (s) (push s sent)))
                    ((symbol-function 'ghostel-send-key)
                     (lambda (&rest _) (push 'key sent)))
                    ((symbol-function 'ghostel-exec)
                     (lambda (buffer &rest _)
                       (setq created buffer)
                       (with-current-buffer buffer
                         (setq major-mode 'ghostel-mode))
                       'fake-proc)))
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record
                " *ghostel-bm-vim*" "/tmp/ghostel-bm-b/"
                '((kind . eshell) (command . ("vim" "notes")))))
              (should (eq (current-buffer) running)))
            (should-not sent)
            (should-not created)
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record
                " *ghostel-bm-vim*" "/tmp/ghostel-bm-b/"
                '((kind . eshell) (command . ("vim" "other"))))))
            (should created))
        (delete-process ghostel--process)
        (when (buffer-live-p created) (kill-buffer created))))))

(ert-deftest ghostel-test-bookmark-handler-command-reattach-prefers-name ()
  "The recorded name picks among several buffers running the same command.
A stale recorded name falls back to any live command match."
  (ghostel-test--with-compile-buffer first
    (rename-buffer " *ghostel-bm-top*" t)
    (setq ghostel-identity '((kind . eshell) (command . ("top"))))
    (setq-local ghostel--process (ghostel-test--dummy-process "bm-top-a" nil))
    (let ((first-proc ghostel--process))
      (unwind-protect
          (ghostel-test--with-compile-buffer second
            (rename-buffer " *ghostel-bm-top*<2>" t)
            (setq ghostel-identity '((kind . eshell) (command . ("top"))))
            (setq-local ghostel--process
                        (ghostel-test--dummy-process "bm-top-b" nil))
            (unwind-protect
                (cl-letf (((symbol-function 'ghostel--load-module) #'ignore))
                  (with-temp-buffer
                    (ghostel-bookmark-handler
                     (ghostel-test--bookmark-record
                      " *ghostel-bm-top*<2>" "/tmp/ghostel-bm-t/"
                      '((kind . eshell) (command . ("top")))))
                    (should (eq (current-buffer) second)))
                  (with-temp-buffer
                    (ghostel-bookmark-handler
                     (ghostel-test--bookmark-record
                      " *ghostel-bm-top*" "/tmp/ghostel-bm-t/"
                      '((kind . eshell) (command . ("top")))))
                    (should (eq (current-buffer) first)))
                  (with-temp-buffer
                    (ghostel-bookmark-handler
                     (ghostel-test--bookmark-record
                      " *ghostel-bm-top-gone*" "/tmp/ghostel-bm-t/"
                      '((kind . eshell) (command . ("top")))))
                    (should (memq (current-buffer) (list first second)))))
              (delete-process ghostel--process)))
        (delete-process first-proc)))))

(ert-deftest ghostel-test-bookmark-handler-respawn-failure-cleans-up ()
  "A failing spawn kills the partially created buffer and re-signals.
Covers both the command respawn and the shell branch."
  (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
            ((symbol-function 'ghostel-exec)
             (lambda (&rest _) (error "Spawn failed"))))
    (should-error
     (ghostel-bookmark-handler
      (ghostel-test--bookmark-record " *ghostel-bm-fail*"
                                     "/tmp/ghostel-bm-f/"
                                     '((kind . exec) (command . ("nope"))))))
    (should-not (get-buffer " *ghostel-bm-fail*")))
  (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
            ((symbol-function 'ghostel--create)
             (lambda (name &rest _)
               (let ((b (generate-new-buffer name)))
                 (with-current-buffer b (ghostel-mode))
                 b)))
            ((symbol-function 'ghostel--start-process)
             (lambda () (error "Spawn failed"))))
    (should-error
     (ghostel-bookmark-handler
      (ghostel-test--bookmark-record " *ghostel-bm-fail-sh*"
                                     "/tmp/ghostel-bm-f/")))
    (should-not (get-buffer " *ghostel-bm-fail-sh*"))))

(ert-deftest ghostel-test-bookmark-handler-respawns-command ()
  "A command-bearing identity respawns the program instead of a shell."
  (let ((exec-calls nil)
        (shell-started nil))
    (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel-exec)
               (lambda (buffer program &optional args identity)
                 (push (list buffer program args identity) exec-calls)
                 (with-current-buffer buffer
                   (setq major-mode 'ghostel-mode)
                   (setq-local ghostel-identity identity))
                 'fake-proc))
              ((symbol-function 'ghostel--start-process)
               (lambda () (setq shell-started t))))
      (unwind-protect
          (progn
            (with-temp-buffer
              (ghostel-bookmark-handler
               (ghostel-test--bookmark-record
                " *ghostel-bm-htop*" "/tmp/ghostel-bm-cmd/"
                '((kind . exec) (command . ("htop" "-d" "10"))))))
            (should-not shell-started)
            (should (= 1 (length exec-calls)))
            (pcase-let ((`(,b ,prog ,args ,id) (car exec-calls)))
              (should (equal (buffer-name b) " *ghostel-bm-htop*"))
              (should (equal prog "htop"))
              (should (equal args '("-d" "10")))
              (should (equal (alist-get 'command id) '("htop" "-d" "10")))))
        (when-let* ((b (get-buffer " *ghostel-bm-htop*")))
          (kill-buffer b))))))

(ert-deftest ghostel-test-bookmark-handler-creates-buffer ()
  "Jumping to a bookmark with no live buffer starts a fresh shell in its dir."
  :tags '(native)
  (let* ((ghostel-macos-login-shell nil)
         (dir (file-name-as-directory (make-temp-file "ghostel-bm-create" t)))
         (buf-name (generate-new-buffer-name " *ghostel-bm-create*"))
         (buf nil))
    (unwind-protect
        (progn
          (ghostel-bookmark-handler
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
  ;; reuse-branch guard passes); a dummy pipe process satisfies the handler's
  ;; live-shell check, and the send functions are stubbed.
  (ghostel-test--with-terminal-buffer (buf term 24 80 1000)
    (setq-local ghostel--process (ghostel-test--dummy-process "bm-cd" nil))
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
        (ghostel-bookmark-handler
         (ghostel-test--bookmark-record (buffer-name) remote))
        (should (equal (nreverse sent)
                       `((string . ,(concat "cd " (shell-quote-argument
                                                   (file-local-name remote))))
                         (key . "return"))))
        ;; Disabled: nothing is typed even though the dirs differ.
        (setq sent nil)
        (let ((ghostel-bookmark-check-dir nil))
          (ghostel-bookmark-handler
           (ghostel-test--bookmark-record (buffer-name) "/tmp/elsewhere/")))
        (should-not sent)))))

(provide 'ghostel-bookmark-test)
;;; ghostel-bookmark-test.el ends here
