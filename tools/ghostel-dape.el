;;; ghostel-dape.el --- Dape launch helpers for ghostel tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Project-local Dape helpers for debugging Ghostel's native module under
;; test.  Load this file, then use:
;;
;;   M-x ghostel-dape-ert-test-at-point
;;   M-x ghostel-dape-ert-file
;;
;; The commands launch a fresh batch Emacs under codelldb, matching the
;; existing manual Dape workflow but without typing the long config blob.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'dape)

(defgroup ghostel-dape nil
  "Dape helpers for Ghostel tests."
  :group 'ghostel)

(defcustom ghostel-dape-build-command
  "zig build -Doptimize=Debug -Dcpu=baseline"
  "Build command run before launching Dape.
Set to nil to skip automatic compilation."
  :type '(choice (const :tag "Do not build" nil) string)
  :group 'ghostel-dape)

(defun ghostel-dape--root ()
  "Return the Ghostel project root."
  (or (locate-dominating-file default-directory "build.zig")
      (user-error "Could not find Ghostel project root")))

(defun ghostel-dape--relative-file (file)
  "Return FILE relative to the Ghostel project root."
  (file-relative-name (expand-file-name file) (ghostel-dape--root)))

(defun ghostel-dape--vector (&rest args)
  "Return ARGS as a vector, dropping nil elements."
  (vconcat (delq nil args)))

(defun ghostel-dape--launch-emacs (&rest args)
  "Launch batch Emacs with ARGS under Dape/codelldb."
  (let* ((root (file-name-as-directory (expand-file-name (ghostel-dape--root))))
         (base (or (cdr (assoc 'codelldb-cc dape-configs))
                   (user-error "No `codelldb-cc' entry in `dape-configs'")))
         (config (copy-sequence base)))
    (setq config (plist-put config 'command-cwd root))
    (setq config (plist-put config :program (expand-file-name invocation-name invocation-directory)))
    (setq config (plist-put config :cwd root))
    (setq config (plist-put config :args (apply #'ghostel-dape--vector args)))
    (setq config (plist-put config :stopOnEntry nil))
    (if ghostel-dape-build-command
        (setq config (plist-put config 'compile ghostel-dape-build-command))
      (cl-remf config 'compile))
    (dape config)))

(defun ghostel-dape--current-ert-test ()
  "Return the `ert-deftest' name around point, or nil."
  (save-excursion
    (end-of-line)
    (when (re-search-backward "^(ert-deftest[[:space:]]+\\([^[:space:]]+\\)" nil t)
      (match-string-no-properties 1))))

(defun ghostel-dape--ert-eval (test-regexp)
  "Return Elisp form string that runs ERT tests matching TEST-REGEXP."
  (format "(ert-run-tests-batch-and-exit %S)" test-regexp))

;;;###autoload
(defun ghostel-dape-ert-test-at-point (&optional test-name)
  "Debug the ERT TEST-NAME at point under Dape.
When called interactively outside an `ert-deftest', prompt for the test
name.  The current buffer's test file is loaded into a fresh batch Emacs."
  (interactive)
  (let* ((file (buffer-file-name))
         (_ (unless file (user-error "Current buffer is not visiting a file")))
         (test (or test-name
                   (ghostel-dape--current-ert-test)
                   (read-string "ERT test name: ")))
         (regexp (concat "^" (regexp-quote test) "$")))
    (ghostel-dape--launch-emacs
     "--batch" "-Q"
     "-L" "lisp"
     "-L" "test"
     "-l" "ert"
     "-l" "test/ghostel-test-helpers.el"
     "-l" (ghostel-dape--relative-file file)
     "--eval" (ghostel-dape--ert-eval regexp))))

;;;###autoload
(defun ghostel-dape-ert-file ()
  "Debug all ERT tests in the current file under Dape."
  (interactive)
  (let ((file (buffer-file-name)))
    (unless file
      (user-error "Current buffer is not visiting a file"))
    (ghostel-dape--launch-emacs
     "--batch" "-Q"
     "-L" "lisp"
     "-L" "test"
     "-l" "ert"
     "-l" "test/ghostel-test-helpers.el"
     "-l" (ghostel-dape--relative-file file)
     "--eval" "(ert-run-tests-batch-and-exit t)")))

(provide 'ghostel-dape)
;;; ghostel-dape.el ends here
