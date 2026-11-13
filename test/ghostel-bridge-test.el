;;; ghostel-bridge-test.el --- Tests for ghostel: bridged terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; The functions a client of a terminal without a process builds on:
;; making the terminal, writing its output, sizing it, and telling it
;; what the client learns elsewhere.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-bridge-test--with-terminal (spec &rest body)
  "Run BODY in a bridged terminal's buffer.
SPEC is (ROWS COLS) for `ghostel-make-terminal'."
  (declare (indent 1))
  `(let ((buffer (ghostel-make-terminal " *ghostel-bridge-test*" ,@spec)))
     (unwind-protect
         (with-current-buffer buffer
           ,@body)
       (kill-buffer buffer))))

(defun ghostel-bridge-test--columns ()
  "Return the number of columns this terminal reads its output at."
  (let* (reply
         (ghostel-pty-out-function (lambda (data) (setq reply data))))
    (ghostel-write-output "\e[999C\e[6n")
    (and (string-match "\\`\e\\[[0-9]+;\\([0-9]+\\)R\\'" reply)
         (string-to-number (match-string 1 reply)))))

(ert-deftest ghostel-test-make-terminal-new-buffer ()
  "A name makes a new terminal buffer of the given size, without a process."
  :tags '(native)
  (let ((taken (generate-new-buffer " *ghostel-bridge-test*")))
    (unwind-protect
        (ghostel-bridge-test--with-terminal (10 40)
          (should-not (eq buffer taken))
          (should (derived-mode-p 'ghostel-mode))
          (should ghostel--term)
          (should-not ghostel--process)
          (should (equal '(40 . 10) (ghostel-terminal-size))))
      (kill-buffer taken))))

(ert-deftest ghostel-test-make-terminal-replaces-terminal ()
  "A terminal buffer is emptied and gets a new terminal."
  :tags '(native)
  (ghostel-bridge-test--with-terminal (10 40)
    (let ((old ghostel--term))
      (setq ghostel-pty-out-function #'ignore
            ghostel--prompt-positions '((1 . 0)))
      (setq-local ghostel-bridge-test--own 'kept)
      (ghostel-write-output "old")
      (ghostel--commit-frame buffer)
      (should (string-prefix-p "old" (buffer-string)))
      (should (eq buffer (ghostel-make-terminal buffer 5 20)))
      (should-not (eq old ghostel--term))
      (should (equal "" (buffer-string)))
      (should-not (ghostel--copy-all-text ghostel--term))
      (should-not ghostel-pty-out-function)
      (should-not ghostel--prompt-positions)
      (should (eq 'kept (bound-and-true-p ghostel-bridge-test--own)))
      (should (equal '(20 . 5) (ghostel-terminal-size))))))

(defun ghostel-bridge-test--reuse-from (enter)
  "Check that a terminal made in a buffer that ENTER switched mode starts clean.
ENTER is called at a shell prompt, with input written to the bridge recorded."
  (ghostel-bridge-test--with-terminal (10 40)
    (let (sent)
      (setq ghostel-pty-out-function (lambda (data) (push data sent)))
      (ghostel-write-output "\e]133;A\e\\$ \e]133;B\e\\")
      (ghostel--commit-frame buffer)
      (funcall enter)
      (should ghostel--mode-line-tag)
      (should-not (eq ghostel-semi-char-mode-map (current-local-map)))
      (setq ghostel--pending-initial-line-mode t)
      (ghostel-make-terminal buffer 10 40)
      (should (eq 'semi-char ghostel--input-mode))
      (should (eq ghostel-semi-char-mode-map (current-local-map)))
      (should-not ghostel--mode-line-tag)
      (should-not mode-line-process)
      (should-not ghostel--char-mode-override-active)
      (should-not ghostel--line-mode-paused)
      (should-not ghostel--line-input-start)
      (should-not ghostel--pending-initial-line-mode)
      ;; Read-only like a new terminal until its bridge is set up.
      (should buffer-read-only)
      (should-not (memq #'ghostel--fake-cursor-update pre-redisplay-functions))
      ;; Nothing is sent to the replaced terminal.
      (should-not sent))))

(ert-deftest ghostel-test-make-terminal-reuses-copy-mode-buffer ()
  "A buffer in copy mode is left for semi-char mode."
  :tags '(native)
  (ghostel-bridge-test--reuse-from #'ghostel-copy-mode))

(ert-deftest ghostel-test-make-terminal-reuses-char-mode-buffer ()
  "A buffer in char mode is left for semi-char mode."
  :tags '(native)
  (ghostel-bridge-test--reuse-from #'ghostel-char-mode))

(ert-deftest ghostel-test-make-terminal-reuses-emacs-mode-buffer ()
  "A buffer in Emacs mode is left for semi-char mode."
  :tags '(native)
  (ghostel-bridge-test--reuse-from #'ghostel-emacs-mode))

(ert-deftest ghostel-test-make-terminal-reuses-line-mode-buffer ()
  "A buffer in line mode is left for semi-char mode, dropping its input."
  :tags '(native)
  (ghostel-bridge-test--reuse-from
   (lambda ()
     ;; Input typed before entry is adopted, to be erased from the shell
     ;; on exit.
     (ghostel-write-output "l")
     (ghostel--commit-frame (current-buffer))
     (ghostel-line-mode)
     (should (equal 1 ghostel--line-mode-adopted-count))
     (insert "s"))))

(ert-deftest ghostel-test-make-terminal-missing-directory ()
  "A bridged terminal does not need `default-directory' to exist."
  :tags '(native)
  (let ((default-directory "/ghostel-bridge-test-no-such-directory/"))
    (ghostel-bridge-test--with-terminal (10 40)
      (should ghostel--term)
      (should-error (ghostel--init-buffer buffer 10 40) :type 'user-error))))

(ert-deftest ghostel-test-make-terminal-kills-buffer-on-error ()
  "A new buffer whose terminal cannot be made is killed."
  (let ((before (buffer-list)))
    (cl-letf (((symbol-function 'ghostel--new) #'ignore)
              ((symbol-function 'ghostel--init-buffer)
               (lambda (&rest _) (error "No terminal"))))
      (should-error (ghostel-make-terminal " *ghostel-bridge-test*")))
    (should (equal before (buffer-list)))))

(ert-deftest ghostel-test-make-terminal-without-module ()
  "Without the native module no terminal is made and nothing is asked."
  (let ((before (buffer-list)))
    (cl-letf (((symbol-function 'ghostel--new) nil)
              ((symbol-function 'ghostel--load-module)
               (lambda (&rest _) (ert-fail "tried to load the module"))))
      (should-error (ghostel-make-terminal " *ghostel-bridge-test*")))
    (should (equal before (buffer-list)))))

(ert-deftest ghostel-test-make-terminal-refuses-live-process ()
  "A buffer whose terminal runs a process is not made a bridged one."
  (with-temp-buffer
    (let ((ghostel--process 'fake))
      (cl-letf (((symbol-function 'ghostel--new) #'ignore)
                ((symbol-function 'process-live-p) (lambda (p) (eq p 'fake))))
        (should-error (ghostel-make-terminal (current-buffer))
                      :type 'user-error)))))

(ert-deftest ghostel-test-write-output ()
  "Written output reaches the terminal and its replies the bridge."
  :tags '(native)
  (ghostel-bridge-test--with-terminal (10 40)
    (let (sent)
      (setq ghostel-pty-out-function (lambda (data) (push data sent)))
      (ghostel-write-output "hello\e[6n")
      (should (equal "hello" (ghostel--copy-all-text ghostel--term)))
      (should (equal '("\e[1;6R") sent))
      (should ghostel--pending-redraw))))

(ert-deftest ghostel-test-write-output-no-reply ()
  "Replies to output written with NO-REPLY are dropped, later input is not."
  :tags '(native)
  (ghostel-bridge-test--with-terminal (10 40)
    (let (sent)
      (setq ghostel-pty-out-function (lambda (data) (push data sent)))
      (cl-letf (((symbol-function 'ghostel--invalidate)
                 (lambda () (ghostel--pty-out "typed"))))
        (ghostel-write-output "hello\e[6n" t))
      (should (equal "hello" (ghostel--copy-all-text ghostel--term)))
      (should (equal '("typed") sent)))))

(ert-deftest ghostel-test-write-output-without-terminal ()
  "Writing to a buffer without a terminal does nothing."
  (with-temp-buffer
    (ghostel-write-output "hello")
    (should (equal "" (buffer-string)))))

(ert-deftest ghostel-test-set-size-hidden ()
  "A hidden terminal has its new size before the next output."
  :tags '(native)
  (ghostel-bridge-test--with-terminal (10 40)
    (should (= 40 (ghostel-bridge-test--columns)))
    (ghostel-set-size 5 60)
    (should (equal '(60 . 5) (ghostel-terminal-size)))
    (should ghostel--repair-pending)
    (should ghostel--pending-redraw)
    (should (= 60 (ghostel-bridge-test--columns)))))

(ert-deftest ghostel-test-set-size-waits-in-hidden-line-mode ()
  "A hidden terminal in line mode gets a new size when it is next redrawn."
  :tags '(native)
  (ghostel-bridge-test--with-terminal (10 40)
    (setq ghostel--input-mode 'line)
    (cl-letf (((symbol-function 'ghostel--commit-frame)
               (lambda (&rest _) (ert-fail "rendered"))))
      (ghostel-set-size 5 60))
    (should (equal '(60 . 5) (ghostel-terminal-size)))
    (should (= 40 (ghostel-bridge-test--columns)))
    (should ghostel--pending-redraw)
    (should ghostel--force-next-redraw)
    ;; The same size again leaves it waiting.
    (ghostel-set-size 5 60)
    (should (= 40 (ghostel-bridge-test--columns)))
    (setq ghostel--input-mode 'semi-char)
    (save-window-excursion
      (set-window-buffer (selected-window) buffer)
      (ghostel--pre-redisplay (selected-window)))
    (should (= 60 (ghostel-bridge-test--columns)))))

(ert-deftest ghostel-test-set-size-in-copy-mode ()
  "A terminal in copy mode has its new size at once, shown or hidden."
  :tags '(native)
  (dolist (shown '(nil t))
    (ghostel-bridge-test--with-terminal (10 40)
      (save-window-excursion
        (when shown
          (set-window-buffer (selected-window) buffer))
        (setq ghostel--input-mode 'copy)
        (ghostel-set-size 5 60)
        (should (= 60 (ghostel-bridge-test--columns)))))))

(ert-deftest ghostel-test-set-size-held-back-redraw ()
  "A redraw held back delays the size in line mode only."
  :tags '(native)
  (dolist (mode '(semi-char line))
    (ghostel-bridge-test--with-terminal (10 40)
      (save-window-excursion
        (set-window-buffer (selected-window) buffer)
        (setq ghostel--input-mode mode)
        (let ((ghostel-inhibit-redraw-functions (list (lambda (_buffer) t))))
          (ghostel-set-size 5 60))
        (when ghostel--redraw-timer
          (cancel-timer ghostel--redraw-timer))
        (should (= (if (eq mode 'line) 40 60)
                   (ghostel-bridge-test--columns)))))))

(ert-deftest ghostel-test-set-size-shown-commits-through-held-frame ()
  "A shown terminal has its new size at once, also with mode 2026 open."
  :tags '(native)
  (ghostel-bridge-test--with-terminal (10 40)
    (save-window-excursion
      (set-window-buffer (selected-window) buffer)
      (ghostel-write-output "\e[?2026h")
      (ghostel-set-size 5 60)
      (should (= 60 (ghostel-bridge-test--columns)))
      (should-not ghostel--repair-pending))))

(ert-deftest ghostel-test-set-size-unchanged ()
  "The terminal's own size renders nothing."
  :tags '(native)
  (ghostel-bridge-test--with-terminal (10 40)
    (cl-letf (((symbol-function 'ghostel--commit-frame)
               (lambda (&rest _) (ert-fail "rendered")))
              ((symbol-function 'ghostel--redraw-now)
               (lambda (&rest _) (ert-fail "rendered"))))
      (ghostel-set-size 10 40))
    (should (equal '(40 . 10) (ghostel-terminal-size)))
    (should-not ghostel--repair-pending)))

(ert-deftest ghostel-test-terminal-size-without-terminal ()
  "A buffer without a terminal has no terminal size."
  (with-temp-buffer
    (should-not (ghostel-terminal-size))))

(ert-deftest ghostel-test-fit-window-passes-unchanged-size ()
  "`ghostel-fit-window' asks for the windows' size even when unchanged."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          received)
      (setq-local ghostel-resize-function
                  (lambda (rows cols) (push (list rows cols) received)))
      (cl-letf (((symbol-function 'ghostel--window-anchored-p) #'ignore)
                ((symbol-function 'window-old-body-pixel-height) #'ignore)
                ((symbol-function 'ghostel--windows) (lambda (&rest _) '(fake)))
                ((symbol-function 'window-buffer)
                 (let ((buffer (current-buffer))) (lambda (&rest _) buffer)))
                ((default-value 'window-adjust-process-window-size-function)
                 (lambda (&rest _) '(120 . 40))))
        (ghostel-fit-window 'fake-window))
      (should (equal '((40 120)) received)))))

(ert-deftest ghostel-test-send-string-raw ()
  "A raw string reaches the bridge without the effects of typing."
  :tags '(native)
  (ghostel-bridge-test--with-terminal (10 40)
    (let (sent)
      (setq ghostel-pty-out-function (lambda (data) (push data sent)))
      (cl-letf (((symbol-function 'ghostel--on-user-input)
                 (lambda () (ert-fail "counted as typed"))))
        (ghostel-send-string "raw" t))
      (should (equal '("raw") sent))
      (ghostel-send-string "typed")
      (should (equal '("typed" "raw") sent)))))

(ert-deftest ghostel-test-set-directory ()
  "`ghostel-set-directory' moves the buffer to a directory or a file URL."
  (with-temp-buffer
    (let ((dir (file-name-as-directory temporary-file-directory)))
      (ghostel-set-directory "/")
      (should (equal "/" default-directory))
      (ghostel-set-directory (concat "file://localhost" dir))
      (should (equal dir default-directory)))))

(ert-deftest ghostel-test-set-command-running ()
  "The command hooks run when the recorded state changes."
  (with-temp-buffer
    (let (events)
      (let ((ghostel-command-start-functions
             (list (lambda (buffer)
                     (push (list 'start buffer ghostel--command-running)
                           events))))
            (ghostel-command-finish-functions
             (list (lambda (buffer status)
                     (push (list 'finish buffer status) events)))))
        (ghostel-set-command-running nil)
        (should-not events)
        (ghostel-set-command-running 'yes)
        (ghostel-set-command-running t)
        (should (eq t ghostel--command-running))
        ;; The hook sees the new state.
        (should (equal `((start ,(current-buffer) t)) events))
        (ghostel-set-command-running nil 3)
        (ghostel-set-command-running nil 4)
        (should-not ghostel--command-running)
        (should (equal `(finish ,(current-buffer) 3) (car events)))
        (should (= 2 (length events)))))))

(ert-deftest ghostel-test-theme-colors ()
  "`ghostel-theme-colors' gives the colors of ghostel's faces."
  (cl-letf (((symbol-function 'ghostel--face-hex-color)
             (lambda (face attr)
               (pcase (list face attr)
                 ('(ghostel-default :foreground) "#eeeeee")
                 ('(ghostel-default :background) "#111111")
                 ('(cursor :background) "#ff0000")
                 (_ "#123456"))))
            ((symbol-function 'face-background) (lambda (&rest _) "red")))
    (let-alist (ghostel-theme-colors)
      (should (equal "#eeeeee" .foreground))
      (should (equal "#111111" .background))
      (should (equal "#ff0000" .cursor))
      (should (eq 'dark .scheme))
      (should (equal (make-vector 16 "#123456") .palette))))
  (cl-letf (((symbol-function 'face-background) #'ignore))
    (should-not (alist-get 'cursor (ghostel-theme-colors)))))

(ert-deftest ghostel-test-apply-palette-uses-theme-colors ()
  "The terminal gets the colors `ghostel-theme-colors' returns."
  (let (calls)
    (cl-letf (((symbol-function 'ghostel-theme-colors)
               (lambda () `((foreground . "#eeeeee") (background . "#111111")
                            (scheme . dark) (palette . ["#000001" "#000002"]))))
              ((symbol-function 'ghostel--set-default-colors)
               (lambda (&rest args) (push args calls)))
              ((symbol-function 'ghostel--set-palette)
               (lambda (&rest args) (push args calls))))
      (ghostel--apply-palette 'term))
    (should (equal '((term "#000001#000002")
                     (term "#eeeeee" "#111111" dark))
                   calls))
    (setq calls nil)
    (cl-letf (((symbol-function 'ghostel-theme-colors)
               (lambda () `((foreground . "#eeeeee") (background . "#111111")
                            (scheme . dark) (palette . []))))
              ((symbol-function 'ghostel--set-default-colors)
               (lambda (&rest args) (push args calls)))
              ((symbol-function 'ghostel--set-palette)
               (lambda (&rest _) (ert-fail "empty palette set"))))
      (ghostel--apply-palette 'term))
    (should (= 1 (length calls)))))

(provide 'ghostel-bridge-test)
;;; ghostel-bridge-test.el ends here
