;;; ghostel-insert-forward-test.el --- Tests for ghostel: insert forwarding -*- lexical-binding: t; -*-

;;; Commentary:

;; Programmatic insert forwarding: foreign buffer insertions in
;; terminal-input modes are routed to the PTY (`emoji-insert',
;; `insert-char', …), deletions are repaired by a full redraw once the
;; deleting command ends, and the read-only barrier comes back in
;; copy/Emacs modes and on process exit.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-insert-forward-test--with-live-buffer (&rest body)
  "Run BODY in a semi-char ghostel buffer with a live dummy process.
Binds SENT and PASTED to lists collecting forwarded strings (newest
first) and PROC to the dummy process.  The terminal handle is fake
and the PTY writers are stubbed, so no native module is needed."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let ((ghostel-scroll-on-input nil)
           (sent '())
           (pasted '())
           (proc nil))
       (ignore sent pasted)
       (unwind-protect
           (progn
             (ghostel-mode)
             (setq proc (ghostel-test--dummy-process
                         "ghostel-insert-forward" (current-buffer)))
             (setq-local ghostel--process proc)
             (setq-local ghostel--term 'fake)
             (ghostel--sync-read-only)
             (cl-letf (((symbol-function 'ghostel--send-string)
                        (lambda (s) (push s sent)))
                       ((symbol-function 'ghostel--paste-text)
                        (lambda (s) (push s pasted))))
               ,@body))
         (when (process-live-p proc)
           (delete-process proc))))))

(ert-deftest ghostel-test-insert-forward-single-line ()
  "A foreign insertion is sent to the PTY as UTF-8, not kept in the buffer."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "user@host$ ")
    (insert "😀")
    (should (equal (buffer-string) "user@host$ "))
    (should (equal sent (list (encode-coding-string "😀" 'utf-8))))
    (should (null pasted))))

(ert-deftest ghostel-test-insert-forward-multiline-uses-paste ()
  "A multi-line insertion is forwarded as a bracketed paste."
  (ghostel-insert-forward-test--with-live-buffer
    (insert "echo a\necho b")
    (should (equal (buffer-string) ""))
    (should (equal pasted '("echo a\necho b")))
    (should (null sent))))

(ert-deftest ghostel-test-insert-forward-star-spec-commands-run ()
  "`(interactive \"*\")' commands run: the buffer is writable.
`buffer-read-only' is nil in live terminal-input modes; the edits
these commands make are intercepted by the after-change hook."
  (ghostel-insert-forward-test--with-live-buffer
    (should-not buffer-read-only)
    (barf-if-buffer-read-only)
    (call-interactively
     (lambda () (interactive "*") (insert "hi")))
    (should (equal (buffer-string) ""))
    (should (equal sent '("hi")))))

(defmacro ghostel-insert-forward-test--with-fake-repair (redraws &rest body)
  "Run BODY with `ghostel--redraw-now' stubbed to restore \"abc\".
REDRAWS collects the stub's (BUFFER FORCE) arguments, newest first."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'ghostel--redraw-now)
              (lambda (buf &optional force)
                (push (list buf force) ,redraws)
                (erase-buffer)
                (insert "abc")
                (setq ghostel--repair-pending nil))))
     ,@body))

(ert-deftest ghostel-test-insert-forward-repairs-deletions ()
  "Deleting rendered text schedules one forced repair for after the command."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "abc")
    (let ((redraws '()))
      (ghostel-insert-forward-test--with-fake-repair redraws
        (delete-region (point-min) (point-max))
        (should (equal (buffer-string) ""))
        (should (null redraws))
        (should (memq #'ghostel--repair-after-command post-command-hook))
        (run-hooks 'post-command-hook)
        (should (equal redraws (list (list (current-buffer) t))))
        (should (equal (buffer-string) "abc"))
        (should-not (memq #'ghostel--repair-after-command post-command-hook))
        (should (null sent))
        (insert "z")
        (should (equal sent '("z")))
        (should (= (length redraws) 1))))))

(ert-deftest ghostel-test-insert-forward-repairs-on-redisplay-without-command ()
  "A deletion made outside a command is repaired when the buffer is redisplayed."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "abc")
    (let ((redraws '()))
      (ghostel-insert-forward-test--with-fake-repair redraws
        (delete-region (point-min) (point-max))
        (should ghostel--pending-redraw)
        (ghostel--pre-redisplay nil)
        (should (equal redraws (list (list (current-buffer) nil))))
        (should (equal (buffer-string) "abc"))))))

(ert-deftest ghostel-test-insert-forward-repairs-replacements ()
  "A replacement of rendered text is repaired, never forwarded."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "abc")
    (let ((redraws '()))
      (ghostel-insert-forward-test--with-fake-repair redraws
        (goto-char (point-min))
        (search-forward "b")
        (replace-match "X")
        (should (equal (buffer-string) "aXc"))
        (run-hooks 'post-command-hook)
        (should (equal redraws (list (list (current-buffer) t))))
        (should (equal (buffer-string) "abc"))
        (should (null sent))
        (should (null pasted))))))

(ert-deftest ghostel-test-insert-forward-drops-inserts-while-repair-pending ()
  "An insertion after a deletion in the same command is not forwarded."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "abc")
    (let ((redraws '()))
      (ghostel-insert-forward-test--with-fake-repair redraws
        (goto-char (point-min))
        (delete-char 1)
        (insert "x")
        (should (equal (buffer-string) "xbc"))
        (should (null sent))
        (run-hooks 'post-command-hook)
        (should (equal (buffer-string) "abc"))))))

(ert-deftest ghostel-test-insert-forward-looping-deletion-finishes ()
  "`delete-indentation' returns: the repair waits for the command to end."
  (ghostel-insert-forward-test--with-live-buffer
    (ghostel-test--insert-rendered "ab\ncd")
    (let ((redraws '()))
      (ghostel-insert-forward-test--with-fake-repair redraws
        (goto-char (point-max))
        (call-interactively #'delete-indentation)
        (should (equal (buffer-string) "ab cd"))
        (should (null redraws))
        (should (null sent))
        (run-hooks 'post-command-hook)
        (should (equal (buffer-string) "abc"))))))

(ert-deftest ghostel-test-insert-forward-cr-uses-paste ()
  "A carriage return in a foreign insertion is paste-protected.
Sent raw, a \\r would execute the pending input in the shell."
  (ghostel-insert-forward-test--with-live-buffer
    (insert "echo a\r")
    (should (equal pasted '("echo a\r")))
    (should (null sent))))

(ert-deftest ghostel-test-insert-forward-repair-restores-render ()
  "The deferred repair re-renders foreign-deleted text and realigns point."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-repair*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (set-window-buffer (selected-window) buf)
          (let ((proc (ghostel-test--dummy-process "ghostel-repair" buf)))
            (unwind-protect
                (progn
                  (setq-local ghostel--term (ghostel--new 5 40 100))
                  (setq-local ghostel--process proc)
                  (ghostel--sync-read-only)
                  (ghostel--write-vt ghostel--term "\e[H\e[2Jhello world")
                  (ghostel-test--redraw ghostel--term t)
                  (let ((before (buffer-string)))
                    (should (string-match-p "hello world" before))
                    (delete-region (point-min) (point-max))
                    (should (equal (buffer-string) ""))
                    (run-hooks 'post-command-hook)
                    (should (equal (buffer-string) before))
                    (should (= (point) ghostel--cursor-char-pos))
                    (should-not ghostel--repair-pending)))
              (when (process-live-p proc)
                (delete-process proc)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-insert-forward-opt-out ()
  "Setting the opt-out flag restores the plain read-only barrier."
  (ghostel-insert-forward-test--with-live-buffer
    (setq ghostel--inhibit-insert-forwarding t)
    (ghostel--sync-read-only)
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
      (should (equal sent '("y")))
      (should (equal (buffer-string) "")))))

(ert-deftest ghostel-test-insert-forward-inhibit-hook ()
  "A `ghostel-inhibit-input-forwarding-functions' veto exempts an edit.
This is the seam `ghostel-ime' uses to protect its composition inserts."
  (ghostel-insert-forward-test--with-live-buffer
    (add-hook 'ghostel-inhibit-input-forwarding-functions
              (lambda () t) nil t)
    (insert "ㅎ")
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

(ert-deftest ghostel-test-insert-forward-no-local-inhibit-read-only ()
  "`inhibit-read-only' never becomes buffer-local (issue #570).
A buffer-local binding would make `(let ((inhibit-read-only t)) ...)'
entered in the ghostel buffer rebind only the local slot, breaking
writes to other read-only buffers made from inside the let."
  (ghostel-insert-forward-test--with-live-buffer
    (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
              ((symbol-function 'ghostel--anchor-window) #'ignore)
              ((symbol-function 'ghostel-force-redraw) #'ignore)
              ((symbol-function 'ghostel--adjust-size) #'ignore))
      (should-not (local-variable-p 'inhibit-read-only))
      (ghostel-char-mode)
      (should-not (local-variable-p 'inhibit-read-only))
      (ghostel-copy-mode)
      (should-not (local-variable-p 'inhibit-read-only))
      (ghostel-emacs-mode)
      (should-not (local-variable-p 'inhibit-read-only))
      (ghostel-semi-char-mode)
      (should-not (local-variable-p 'inhibit-read-only))
      (let ((ghostel-kill-buffer-on-exit nil))
        (delete-process proc)
        (ghostel--sentinel proc "finished\n"))
      (should-not (local-variable-p 'inhibit-read-only)))))

(ert-deftest ghostel-test-insert-forward-inhibit-read-only-let-reaches-other-buffers ()
  "A global `inhibit-read-only' let-binding works across buffers (issue #570).
`window--display-buffer' and friends bind `inhibit-read-only' with the
ghostel buffer current and then write to another read-only buffer
\(e.g. *Completions*); that write must not signal."
  (ghostel-insert-forward-test--with-live-buffer
    (let ((other (generate-new-buffer " *ghostel-570-other*")))
      (unwind-protect
          (progn
            (with-current-buffer other
              (setq buffer-read-only t))
            (let ((inhibit-read-only t))
              (with-current-buffer other
                (insert "x")))
            (should (equal (with-current-buffer other (buffer-string)) "x")))
        (kill-buffer other)))))

(provide 'ghostel-insert-forward-test)
;;; ghostel-insert-forward-test.el ends here
