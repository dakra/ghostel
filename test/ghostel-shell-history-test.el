;;; ghostel-shell-history-test.el --- Tests for ghostel: shell history -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-shell-history' retrieval: shell-type dispatch, output
;; parsing (newline and NUL contracts), and the error paths.  Runs the
;; real /bin/sh with fake commands; no shell history files are touched.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-shell-history-test--with-buffer (program &rest body)
  "Run BODY in a fake ghostel buffer whose spawned shell was PROGRAM."
  (declare (indent 1))
  `(with-temp-buffer
     (setq major-mode 'ghostel-mode)
     (setq-local ghostel--shell-program ,program)
     ,@body))

(ert-deftest ghostel-test-shell-history-newline-parse ()
  "Newline output parses into trimmed entries, order preserved."
  (ghostel-shell-history-test--with-buffer "zsh"
    (let ((ghostel-shell-history-commands
           '((zsh . "printf '\\t ls -l\\nmake -j8\\n\\n  \\ngit st\\n'"))))
      (should (equal (ghostel-shell-history)
                     '("ls -l" "make -j8" "git st"))))))

(ert-deftest ghostel-test-shell-history-nul-parse ()
  "Output containing NUL splits on NUL, preserving embedded newlines."
  (ghostel-shell-history-test--with-buffer "fish"
    (let ((ghostel-shell-history-commands
           '((fish . "printf 'for f in *\\necho $f\\nend\\0ls\\0'"))))
      (should (equal (ghostel-shell-history)
                     '("for f in *\necho $f\nend" "ls"))))))

(ert-deftest ghostel-test-shell-history-function-entry ()
  "A function-valued entry supplies the list directly."
  (ghostel-shell-history-test--with-buffer "bash"
    (let ((ghostel-shell-history-commands
           (list (cons 'bash (lambda () '("one" "two"))))))
      (should (equal (ghostel-shell-history) '("one" "two"))))))

(ert-deftest ghostel-test-shell-history-shell-detection ()
  "The spawned program picks the alist entry, including path and variants."
  (ghostel-shell-history-test--with-buffer "/opt/homebrew/bin/fish"
    (let ((ghostel-shell-history-commands '((fish . "echo fish-hist"))))
      (should (equal (ghostel-shell-history) '("fish-hist"))))))

(ert-deftest ghostel-test-shell-history-errors ()
  "Unrecognized shell, missing entry, failing command, empty history."
  ;; `ghostel-exec' buffers never record a shell program.
  (ghostel-shell-history-test--with-buffer nil
    (should-error (ghostel-shell-history) :type 'user-error))
  ;; Recognized program without an alist entry.
  (ghostel-shell-history-test--with-buffer "zsh"
    (let ((ghostel-shell-history-commands nil))
      (should-error (ghostel-shell-history) :type 'user-error)))
  ;; Non-zero exit surfaces stderr in the error message.
  (ghostel-shell-history-test--with-buffer "zsh"
    (let ((ghostel-shell-history-commands
           '((zsh . "echo broken-pipe >&2; exit 3"))))
      (let ((err (should-error (ghostel-shell-history) :type 'user-error)))
        (should (string-match-p "broken-pipe" (cadr err))))))
  ;; Success with no output.
  (ghostel-shell-history-test--with-buffer "zsh"
    (let ((ghostel-shell-history-commands '((zsh . "true"))))
      (should-error (ghostel-shell-history) :type 'user-error))))

(provide 'ghostel-shell-history-test)
;;; ghostel-shell-history-test.el ends here
