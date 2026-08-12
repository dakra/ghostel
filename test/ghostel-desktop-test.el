;;; ghostel-desktop-test.el --- Tests for ghostel: desktop.el support -*- lexical-binding: t; -*-

;;; Commentary:

;; desktop.el session persistence: the buffer-local `desktop-save-buffer'
;; data function and the `desktop-buffer-mode-handlers' restore handler.
;; The save tests and the stub-driven restore tests are pure elisp (a
;; `ghostel-mode' buffer spawns no process; the reuse test attaches a
;; dummy pipe process so the handler's live-shell check passes).  The
;; restore test that spawns a real shell is tagged `native'.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-desktop)

(ert-deftest ghostel-test-desktop-save-buffer-data ()
  "`ghostel-desktop-save-buffer' captures the directory and identity.
This is the MISC data `desktop-save' writes for the buffer; the restore
handler consumes it as (DIRECTORY IDENTITY)."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-identity '((kind . term)
                             (project-root . "~/desk-save/")
                             (instance . 3)))
    (let ((default-directory "/tmp/ghostel-desk-save/"))
      (should (equal (ghostel-desktop-save-buffer "/tmp/desktop-dir/")
                     '("/tmp/ghostel-desk-save/"
                       ((kind . term)
                        (project-root . "~/desk-save/")
                        (instance . 3))))))))

(ert-deftest ghostel-test-desktop-mode-wires-save-buffer ()
  "`ghostel-mode' wires the buffer-local `desktop-save-buffer'.
Without it `desktop-save' would treat ghostel buffers like any other
non-file buffer and drop them from the desktop file."
  (ghostel-test--with-compile-buffer buf
    (should (eq desktop-save-buffer #'ghostel-desktop-save-buffer))))

(ert-deftest ghostel-test-desktop-handler-registered ()
  "The restore handler is registered for `ghostel-mode'.
ghostel.el registers it at load time; `desktop-read' looks it up right
after loading ghostel via the saved major mode."
  (should (eq (cdr (assq 'ghostel-mode desktop-buffer-mode-handlers))
              'ghostel-desktop-restore-buffer)))

(ert-deftest ghostel-test-desktop-restore-creates-shell ()
  "The restore handler starts a shell under the saved name and identity.
The exact buffer name lets restored window configurations find the
buffer; the carried-over identity and managed/initial names keep
identity-based reuse and title tracking working after the restart."
  (let ((id '((kind . term) (project-root . "~/desk-create/") (instance . 2)))
        (created nil))
    (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel--new) #'ignore)
              ((symbol-function 'ghostel--create)
               (lambda (name &rest _)
                 (let ((b (generate-new-buffer name)))
                   (with-current-buffer b (ghostel-mode))
                   (setq created b)
                   b)))
              ((symbol-function 'ghostel--start-process) #'ignore)
              ((symbol-function 'ghostel--apply-initial-input-mode) #'ignore))
      (unwind-protect
          (let ((restored (ghostel-desktop-restore-buffer
                           nil " *ghostel-desk-create*"
                           (list temporary-file-directory id))))
            (should created)
            (should (eq restored created))
            (with-current-buffer restored
              (should (equal (buffer-name) " *ghostel-desk-create*"))
              (should (equal ghostel-identity id))
              (should (equal ghostel--managed-buffer-name (buffer-name)))
              (should (equal ghostel--initial-name (buffer-name)))))
        (when (buffer-live-p created) (kill-buffer created))))))

(ert-deftest ghostel-test-desktop-restore-reuses-live-slot ()
  "A live buffer holding the saved slot identity is reused, not duplicated.
A repeated `desktop-read' (or one after some terminals were already
recreated by hand) must switch to the existing terminal instead of
spawning a second shell for the same slot."
  (ghostel-test--with-compile-buffer buf
    (let ((id '((kind . term) (project-root . "~/desk-reuse/") (instance . 1))))
      (setq ghostel-identity id)
      (setq-local ghostel--process (ghostel-test--dummy-process "desk-reuse" nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--create)
                     (lambda (&rest _)
                       (ert-fail "Created a new buffer instead of reusing"))))
            (should (eq (ghostel-desktop-restore-buffer
                         nil " *ghostel-desk-reuse-stale*"
                         (list "/tmp/ghostel-desk-reuse/" id))
                        buf)))
        (delete-process ghostel--process)))))

(ert-deftest ghostel-test-desktop-restore-skips-dead-shell-holder ()
  "A dead-shell buffer holding the identity is not reused.
With `ghostel-kill-buffer-on-exit' nil a buffer outlives its shell;
returning it would \"restore\" a terminal with no process, so the
handler must fall through to the create branch."
  (ghostel-test--with-compile-buffer dead
    (let ((id '((kind . term) (project-root . "~/desk-dead/") (instance . 1)))
          (created nil))
      (setq ghostel-identity id)
      (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                ((symbol-function 'ghostel--new) #'ignore)
                ((symbol-function 'ghostel--create)
                 (lambda (name &rest _)
                   (let ((b (generate-new-buffer name)))
                     (with-current-buffer b (ghostel-mode))
                     (setq created b)
                     b)))
                ((symbol-function 'ghostel--start-process) #'ignore)
                ((symbol-function 'ghostel--apply-initial-input-mode) #'ignore))
        (unwind-protect
            (let ((restored (ghostel-desktop-restore-buffer
                             nil " *ghostel-desk-dead-fresh*"
                             (list temporary-file-directory id))))
              (should created)
              (should (eq restored created))
              (should-not (eq restored dead)))
          (when (buffer-live-p created) (kill-buffer created)))))))

(ert-deftest ghostel-test-desktop-restore-skips-remote ()
  "A remote saved terminal is skipped.
Spawning its shell would open a TRAMP connection -- possibly prompting
for credentials -- in the middle of `desktop-read'."
  (cl-letf (((symbol-function 'ghostel--create)
             (lambda (&rest _)
               (ert-fail "Tried to restore a remote terminal"))))
    (should-not (ghostel-desktop-restore-buffer
                 nil " *ghostel-desk-remote*"
                 (list "/ssh:host:/home/u/proj/"
                       '((kind . term) (instance . 1)))))))

(ert-deftest ghostel-test-desktop-restore-skips-command-identity ()
  "A command-bearing identity is not respawned.
Unlike a bookmark jump, a desktop restore runs unattended at startup,
where re-running a saved command (say, a build) would be surprising."
  (cl-letf (((symbol-function 'ghostel--create)
             (lambda (&rest _)
               (ert-fail "Tried to respawn a command buffer"))))
    (should-not (ghostel-desktop-restore-buffer
                 nil " *ghostel-desk-htop*"
                 (list "/tmp/ghostel-desk-cmd/"
                       '((kind . exec)
                         (command . ("htop" "-d" "10"))
                         (instance . 1)))))))

(ert-deftest ghostel-test-desktop-restore-tolerates-malformed-misc ()
  "Malformed MISC data degrades gracefully.
Desktop files are external data: a missing MISC is skipped without
error, and a pre-alist string identity is treated as absent (the
restored buffer gets a nil identity -- an invented one would let plain
`ghostel' claim it)."
  (should-not (ghostel-desktop-restore-buffer nil " *ghostel-desk-nil*" nil))
  (let ((created nil))
    (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel--new) #'ignore)
              ((symbol-function 'ghostel--create)
               (lambda (name &rest _)
                 (let ((b (generate-new-buffer name)))
                   (with-current-buffer b (ghostel-mode))
                   (setq created b)
                   b)))
              ((symbol-function 'ghostel--start-process) #'ignore)
              ((symbol-function 'ghostel--apply-initial-input-mode) #'ignore))
      (unwind-protect
          (progn
            (ghostel-desktop-restore-buffer
             nil " *ghostel-desk-legacy*"
             (list temporary-file-directory "legacy-string"))
            (should created)
            (should-not (buffer-local-value 'ghostel-identity created)))
        (when (buffer-live-p created) (kill-buffer created))))))

(ert-deftest ghostel-test-desktop-restore-spawn-failure-cleans-up ()
  "A failing spawn kills the partially created buffer and re-signals.
`desktop-read' catches the error, reports the buffer as not restored,
and moves on; a half-initialized terminal buffer must not linger."
  (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
            ((symbol-function 'ghostel--new) #'ignore)
            ((symbol-function 'ghostel--create)
             (lambda (name &rest _)
               (let ((b (generate-new-buffer name)))
                 (with-current-buffer b (ghostel-mode))
                 b)))
            ((symbol-function 'ghostel--start-process)
             (lambda () (error "Spawn failed"))))
    (should-error
     (ghostel-desktop-restore-buffer
      nil " *ghostel-desk-fail*"
      (list temporary-file-directory
            '((kind . term) (instance . 1)))))
    (should-not (get-buffer " *ghostel-desk-fail*"))))

(ert-deftest ghostel-test-desktop-restore-skips-compile-identity ()
  "A `compile' identity is not respawned.
`ghostel-compile' identities carry no `command' key, so the compile
kind itself gates the respawn."
  (cl-letf (((symbol-function 'ghostel--create)
             (lambda (&rest _)
               (ert-fail "Tried to respawn a compile buffer"))))
    (should-not (ghostel-desktop-restore-buffer
                 nil " *ghostel-compile*"
                 (list temporary-file-directory
                       '((kind . compile)
                         (project-root . "~/desk-compile/")
                         (instance . 1)))))))

(ert-deftest ghostel-test-desktop-restore-skips-missing-directory ()
  "A saved directory that no longer exists is skipped.
On the native-PTY path the child's chdir failure would kill the shell
right after spawn, silently losing the restored buffer."
  (cl-letf (((symbol-function 'ghostel--create)
             (lambda (&rest _)
               (ert-fail "Spawned a shell in a missing directory"))))
    (should-not (ghostel-desktop-restore-buffer
                 nil " *ghostel-desk-gone*"
                 (list (expand-file-name "ghostel-desk-gone-nonexistent/"
                                         temporary-file-directory)
                       '((kind . term) (instance . 1)))))))

(ert-deftest ghostel-test-desktop-restore-reuses-live-remote ()
  "A live remote terminal matching the identity is reused, not skipped.
The remote skip only guards the spawn branch (opening a TRAMP
connection); reusing an already-open buffer opens none."
  (ghostel-test--with-compile-buffer buf
    (let ((id '((kind . term)
                (project-root . "/ssh:host:~/proj/")
                (instance . 1))))
      (setq ghostel-identity id)
      (setq-local ghostel--process
                  (ghostel-test--dummy-process "desk-remote-live" nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ghostel--create)
                     (lambda (&rest _)
                       (ert-fail "Spawned instead of reusing"))))
            (should (eq (ghostel-desktop-restore-buffer
                         nil " *ghostel-desk-remote-live*"
                         (list "/ssh:host:/home/u/proj/" id))
                        buf)))
        (delete-process ghostel--process)))))

(ert-deftest ghostel-test-desktop-restore-reuse-syncs-managed-name ()
  "Reuse renames the live buffer to the saved name and keeps rename tracking.
`desktop-create-buffer' renames the returned buffer to the saved name;
without syncing `ghostel--managed-buffer-name' that would look like a
manual rename and disable automatic title renames."
  (ghostel-test--with-compile-buffer buf
    (let ((id '((kind . term) (project-root . "~/desk-sync/") (instance . 1)))
          (saved (generate-new-buffer-name " *ghostel-desk-sync-saved*")))
      (setq ghostel-identity id)
      (setq ghostel--managed-buffer-name (buffer-name))
      (setq-local ghostel--process
                  (ghostel-test--dummy-process "desk-sync" nil))
      (unwind-protect
          (progn
            (should (eq (ghostel-desktop-restore-buffer
                         nil saved (list temporary-file-directory id))
                        buf))
            (should (equal (buffer-name buf) saved))
            (should (equal (buffer-local-value 'ghostel--managed-buffer-name
                                               buf)
                           saved)))
        (delete-process ghostel--process)))))

(ert-deftest ghostel-test-desktop-restore-schedules-replay-shield ()
  "Restoring schedules a zero-delay timer undoing desktop's state replay.
`desktop-create-buffer' replays saved point/mark/read-only after the
handler returns; the timer runs after that replay."
  (let ((scheduled nil))
    (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel--new) #'ignore)
              ((symbol-function 'ghostel--create)
               (lambda (name &rest _)
                 (let ((b (generate-new-buffer name)))
                   (with-current-buffer b (ghostel-mode))
                   b)))
              ((symbol-function 'ghostel--start-process) #'ignore)
              ((symbol-function 'ghostel--apply-initial-input-mode) #'ignore)
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args)
                 (setq scheduled (cons fn args)))))
      (let ((buf (ghostel-desktop-restore-buffer
                  nil " *ghostel-desk-shield*"
                  (list temporary-file-directory
                        '((kind . term) (instance . 1))))))
        (unwind-protect
            (should (eq (car scheduled) #'ghostel-desktop--undo-replay))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest ghostel-test-desktop-undo-replay-resets-state ()
  "The replay shield deactivates a replayed mark and exits copy mode.
A saved active mark makes `desktop-create-buffer' call `activate-mark',
which flips a semi-char terminal into copy mode."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)) (insert "prompt$ "))
    (setq ghostel--input-mode 'copy)    ; as left by the replayed mark
    (set-mark 2)
    (activate-mark)
    (let ((exited nil))
      (cl-letf (((symbol-function 'ghostel-readonly-exit)
                 (lambda () (setq exited t))))
        (ghostel-desktop--undo-replay buf 'semi-char nil)
        (should-not (region-active-p))
        (should exited)))))

(ert-deftest ghostel-test-desktop-undo-replay-preserves-user-copy-mode ()
  "The replay shield leaves a reused buffer's own copy mode alone.
When the buffer was already in copy mode with an active region before
the replay, nothing may be reset."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)) (insert "prompt$ "))
    (setq ghostel--input-mode 'copy)
    (set-mark 2)
    (activate-mark)
    (cl-letf (((symbol-function 'ghostel-readonly-exit)
               (lambda () (ert-fail "Exited the user's copy mode"))))
      (ghostel-desktop--undo-replay buf 'copy t)
      (should (region-active-p)))))

(ert-deftest ghostel-test-desktop-sentinel-drops-dead-terminal ()
  "A terminal whose shell exited is no longer desktop-saved.
Restoring it would spawn a live shell without the scrollback the
buffer was kept for."
  (ghostel-test--with-compile-buffer buf
    (should desktop-save-buffer)
    (let ((ghostel-kill-buffer-on-exit nil)
          (proc (ghostel-test--dummy-process "desk-dead-drop" buf)))
      (ghostel--sentinel proc "finished\n")
      (should (buffer-live-p buf))
      (should-not desktop-save-buffer))))

(ert-deftest ghostel-test-desktop-restore-spawns-real-shell ()
  "Restoring with no live buffer starts a fresh shell in the saved dir."
  :tags '(native)
  (let* ((ghostel-macos-login-shell nil)
         (dir (file-name-as-directory (make-temp-file "ghostel-desk-real" t)))
         (buf-name (generate-new-buffer-name " *ghostel-desk-real*"))
         (id '((kind . term) (project-root . "~/desk-real/") (instance . 1)))
         (buf nil))
    (unwind-protect
        (progn
          (ghostel-desktop-restore-buffer nil buf-name (list dir id))
          (setq buf (get-buffer buf-name))
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should (eq major-mode 'ghostel-mode))
            (should (process-live-p ghostel--process))
            (should (equal ghostel-identity id))
            ;; `file-equal-p' tolerates OSC 7 / symlink-resolved variants.
            (should (file-equal-p default-directory dir))))
      (when (buffer-live-p (get-buffer buf-name))
        (ghostel-test--cleanup-exec-buffer (get-buffer buf-name)))
      (ignore-errors (delete-directory dir t)))))

(provide 'ghostel-desktop-test)
;;; ghostel-desktop-test.el ends here
