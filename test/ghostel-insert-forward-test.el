;;; ghostel-insert-forward-test.el --- Tests for ghostel: insert forwarding -*- lexical-binding: t; -*-

;;; Commentary:

;; Programmatic insert forwarding: foreign buffer insertions in
;; terminal-input modes accumulate during a command and are flushed to
;; the PTY at command end, replaying the final point offset as Left
;; keys (`skeleton-pair-insert-maybe', `emoji-insert', `insert-char',
;; …).  Deletions of renderer-owned text signal, and the read-only
;; barrier comes back in copy/Emacs modes and on process exit.

;;; Code:

(require 'ghostel-test-helpers)
(require 'skeleton)

(defmacro ghostel-insert-forward-test--with-live-buffer (&rest body)
  "Run BODY in a semi-char ghostel buffer with a live dummy process.
Binds SENT, PASTED, and KEYS to lists collecting forwarded strings,
pastes, and encoded key names (newest first), and PROC to the dummy
process.  The terminal handle is fake and the PTY writers are
stubbed, so no native module is needed."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let ((ghostel-scroll-on-input nil)
           (sent '())
           (pasted '())
           (keys '())
           (proc nil))
       (ignore sent pasted keys)
       (unwind-protect
           (progn
             (ghostel-mode)
             (setq proc (ghostel-test--dummy-process
                         "ghostel-insert-forward" (current-buffer)))
             (setq-local ghostel--process proc)
             (setq-local ghostel--term 'fake)
             (ghostel--sync-inhibit-read-only)
             (cl-letf(((symbol-function 'ghostel--send-string)
                        (lambda (s) (push s sent)))
                       ((symbol-function 'ghostel--paste-text)
                        (lambda (s) (push s pasted)))
                       ((symbol-function 'ghostel--send-encoded)
                        (lambda (key _mods &optional _utf8) (push key keys))))
               ,@body))
         (when (process-live-p proc)
           (delete-process proc))))))

(defun ghostel-insert-forward-test--pump ()
  "Run the buffer-local `post-command-hook' members, like command end."
  (run-hooks 'post-command-hook))

(ert-deftest ghostel-test-insert-forward-single-line ()
  "A foreign insertion is flushed to the PTY as UTF-8 at command end."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "user@host$ ")
    (insert "😀")
    ;; Deferred: still in the buffer until the command ends.
    (should (equal (buffer-string) "user@host$ 😀"))
    (should (null sent))
    (ghostel-insert-forward-test--pump)
    (should (equal (buffer-string) "user@host$ "))
    (should (equal sent (list (encode-coding-string "😀" 'utf-8))))
    (should (null pasted))
    (should (null keys))))

(ert-deftest ghostel-test-insert-forward-point-offset-sends-left ()
  "Point left inside the insertion is replayed as Left key presses."
  (ghostel-insert-forward-test--with-live-buffer
    (insert "()")
    (backward-char 1)
    (ghostel-insert-forward-test--pump)
    (should (equal (buffer-string) ""))
    (should (equal sent '("()")))
    (should (equal keys '("left")))))

(ert-deftest ghostel-test-insert-forward-skeleton-pair ()
  "`skeleton-pair-insert-maybe' sends the pair and one Left (issue #561)."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "$ ")
    (goto-char (point-max))
    (let ((skeleton-pair t)
          (last-command-event ?\())
      (call-interactively #'skeleton-pair-insert-maybe))
    (ghostel-insert-forward-test--pump)
    (should (equal (buffer-string) "$ "))
    (should (equal sent '("()")))
    (should (equal keys '("left")))))

(ert-deftest ghostel-test-insert-forward-multiline-uses-paste ()
  "A multi-line insertion is pasted; point offset is not replayed."
  (ghostel-insert-forward-test--with-live-buffer
    (insert "echo a\necho b")
    (backward-char 3)
    (ghostel-insert-forward-test--pump)
    (should (equal (buffer-string) ""))
    (should (equal pasted '("echo a\necho b")))
    (should (null sent))
    (should (null keys))))

(ert-deftest ghostel-test-insert-forward-disjoint-inserts-flush-in-order ()
  "A disjoint second insertion flushes the first, offsets untouched."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "PROMPT ")
    (goto-char (point-max))
    (insert "a")
    (goto-char (point-min))
    (insert "b")
    (ghostel-insert-forward-test--pump)
    (should (equal (buffer-string) "PROMPT "))
    (should (equal sent '("b" "a")))
    (should (null keys))))

(ert-deftest ghostel-test-insert-forward-deletion-inside-pending-allowed ()
  "Deleting within the pending insertion shrinks it instead of signalling."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "$ ")
    (goto-char (point-max))
    (insert "abc")
    (delete-region 4 5)
    (should-error (delete-region (point-min) (point-max))
                  :type 'text-read-only)
    (ghostel--rearm-change-hooks)
    (ghostel-insert-forward-test--pump)
    (should (equal (buffer-string) "$ "))
    (should (equal sent '("ac")))))

(ert-deftest ghostel-test-insert-forward-flush-idempotent ()
  "A second flush after the first is a no-op."
  (ghostel-insert-forward-test--with-live-buffer
    (insert "x")
    (ghostel--flush-pending-insert)
    (ghostel--flush-pending-insert)
    (ghostel-insert-forward-test--pump)
    (should (equal sent '("x")))))

(ert-deftest ghostel-test-insert-forward-backup-timer-flushes ()
  "An insertion outside a command is flushed by the backup timer."
  (ghostel-insert-forward-test--with-live-buffer
    (insert "x")
    (should ghostel--pending-insert-timer)
    (ghostel-test--wait-until (lambda () sent))
    (should (equal (buffer-string) ""))
    (should (equal sent '("x")))
    (should-not ghostel--pending-insert-timer)))

(ert-deftest ghostel-test-insert-forward-star-spec-commands-run ()
  "`(interactive \"*\")' commands run: the read-only barrier is lifted.
`buffer-read-only' itself stays non-nil so packages gating on the
variable (e.g. meow's `meow--allow-modify-p') still see protection."
  (ghostel-insert-forward-test--with-live-buffer
    (should buffer-read-only)
    (barf-if-buffer-read-only)
    (call-interactively
     (lambda () (interactive "*") (insert "hi")))
    (ghostel-insert-forward-test--pump)
    (should (equal (buffer-string) ""))
    (should (equal sent '("hi")))))

(ert-deftest ghostel-test-insert-forward-blocks-deletions ()
  "Deleting renderer-owned text signals `text-read-only', repeatedly.
The veto's signal makes Emacs wipe the buffer's change hooks; the veto
schedules a one-shot `post-command-hook' re-arm that restores the
barrier for the next command, then detaches itself."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "abc")
    (should-not (memq #'ghostel--rearm-change-hooks post-command-hook))
    (should-error (delete-region (point-min) (point-max))
                  :type 'text-read-only)
    ;; Emacs wiped the before-change hook and the veto armed the re-arm.
    (should-not (memq #'ghostel--forward-inserts-before-change
                      before-change-functions))
    (should (memq #'ghostel--rearm-change-hooks post-command-hook))
    (run-hooks 'post-command-hook)
    (should (memq #'ghostel--forward-inserts-before-change
                  before-change-functions))
    (should-not (memq #'ghostel--rearm-change-hooks post-command-hook))
    (should-error (delete-region (point-min) (point-max))
                  :type 'text-read-only)
    (should (equal (buffer-string) "abc"))))

(ert-deftest ghostel-test-insert-forward-opt-out ()
  "Setting the opt-out flag restores the plain read-only barrier."
  (ghostel-insert-forward-test--with-live-buffer
    (setq ghostel--inhibit-insert-forwarding t)
    (ghostel--sync-inhibit-read-only)
    (should-error (insert "x") :type 'buffer-read-only)
    (should (null sent))))

(ert-deftest ghostel-test-insert-forward-copy-mode-restores-barrier ()
  "Copy mode restores the plain read-only barrier; exiting lifts it again."
  (ghostel-insert-forward-test--with-live-buffer
    (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
              ((symbol-function 'ghostel--anchor-window) #'ignore)
              ((symbol-function 'ghostel-force-redraw) #'ignore)
              ((symbol-function 'ghostel--adjust-size) #'ignore))
      (ghostel-copy-mode)
      (should-error (insert "x") :type 'buffer-read-only)
      (should-error (barf-if-buffer-read-only) :type 'buffer-read-only)
      (ghostel-readonly-exit)
      (should (eq ghostel--input-mode 'semi-char))
      (insert "y")
      (ghostel-insert-forward-test--pump)
      (should (equal sent '("y")))
      (should (equal (buffer-string) "")))))

(ert-deftest ghostel-test-insert-forward-inhibit-hook ()
  "A `ghostel-inhibit-input-forwarding-functions' veto exempts an edit.
This is the seam `ghostel-ime' uses to protect its composition inserts."
  (ghostel-insert-forward-test--with-live-buffer
    (add-hook 'ghostel-inhibit-input-forwarding-functions
              (lambda () t) nil t)
    (insert "ㅎ")
    (ghostel-insert-forward-test--pump)
    (should (equal (buffer-string) "ㅎ"))
    (should (null sent))))

(ert-deftest ghostel-test-insert-forward-process-exit-restores-barrier ()
  "After the terminal process dies the buffer is plainly read-only again."
  (ghostel-insert-forward-test--with-live-buffer
    (let ((ghostel-kill-buffer-on-exit nil))
      (delete-process proc)
      (ghostel--sentinel proc "finished\n")
      (should-error (insert "x") :type 'buffer-read-only)
      (should (null sent)))))

(ert-deftest ghostel-test-insert-forward-process-exit-drops-pending ()
  "A pending insertion is dropped, not sent, when the process dies."
  (ghostel-insert-forward-test--with-live-buffer
    (let ((ghostel-kill-buffer-on-exit nil))
      (insert "x")
      (delete-process proc)
      (ghostel--sentinel proc "finished\n")
      (should-not ghostel--pending-insert)
      (should (equal (buffer-string) "\n[Process exited]\n"))
      (should (null sent))
      (should (null keys)))))

(provide 'ghostel-insert-forward-test)
;;; ghostel-insert-forward-test.el ends here
