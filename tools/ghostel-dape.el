;;; ghostel-dape.el --- Dape launch helpers for ghostel tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Project-local Dape helpers for debugging Ghostel's native module under
;; test.  Load this file, then use:
;;
;;   M-x ghostel-dape-ert-test-at-point
;;   M-x ghostel-dape-ert-file
;;   M-x ghostel-dape-hypothesis-case-file
;;   M-x ghostel-dape-hypothesis-latest-failure
;;
;; The commands launch a fresh batch Emacs under lldb-dap, matching the
;; existing manual Dape workflow but without typing the long config blob.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function dape "dape")
(declare-function dired-get-file-for-visit "dired")
(defvar dape-configs)

(defconst ghostel-dape--source-directory
  (when-let* ((file (or load-file-name buffer-file-name)))
    (file-name-directory file))
  "Directory containing this Ghostel Dape helper file.")

(defgroup ghostel-dape nil
  "Dape helpers for Ghostel tests."
  :group 'ghostel)

(defcustom ghostel-dape-build-command
  "zig build -Doptimize=Debug -Dcpu=baseline"
  "Build command run before launching Dape.
Set to nil to skip automatic compilation."
  :type '(choice (const :tag "Do not build" nil) string)
  :group 'ghostel-dape)

(defcustom ghostel-dape-hypothesis-failure-case-file
  (expand-file-name
   "case.json"
   (or (getenv "GHOSTEL_HYPOTHESIS_FAILURE_DIR")
       "/private/tmp/ghostel-hypothesis-failure"))
  "Case file written for the latest Hypothesis render failure."
  :type 'file
  :group 'ghostel-dape)

(defun ghostel-dape--root ()
  "Return the Ghostel project root."
  (or (locate-dominating-file default-directory "build.zig")
      (when ghostel-dape--source-directory
        (locate-dominating-file ghostel-dape--source-directory "build.zig"))
      (user-error "Could not find Ghostel project root")))

(defun ghostel-dape--relative-file (file)
  "Return FILE relative to the Ghostel project root."
  (file-relative-name (expand-file-name file) (ghostel-dape--root)))

(defun ghostel-dape--vector (&rest args)
  "Return ARGS as a vector, dropping nil elements."
  (vconcat (delq nil args)))

(defun ghostel-dape--launch-emacs (&rest args)
  "Launch batch Emacs with ARGS under Dape/lldb-dap."
  (unless (require 'dape nil t)
    (user-error "Package `dape' is required to launch Ghostel Dape helpers"))
  (let* ((root (file-name-as-directory (expand-file-name (ghostel-dape--root))))
         (base (or (cdr (assoc 'lldb-dap dape-configs))
                   (user-error "No `lldb-dap' entry in `dape-configs'")))
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

(defun ghostel-dape--current-file ()
  "Return the current buffer's file, including Dired's file at point."
  (cond
   (buffer-file-name)
   ((and (derived-mode-p 'dired-mode)
         (fboundp 'dired-get-file-for-visit))
    (dired-get-file-for-visit))))

(defun ghostel-dape--read-hypothesis-case-file ()
  "Read a Hypothesis JSON case file name from the minibuffer."
  (let* ((root (ghostel-dape--root))
         (cases-dir (expand-file-name "test/hypothesis/cases/" root))
         (current-file (ghostel-dape--current-file))
         (default-file (and current-file
                            (string-equal (file-name-extension current-file) "json")
                            current-file))
         (directory (or (and default-file (file-name-directory default-file))
                        cases-dir)))
    (read-file-name "Hypothesis case file: " directory default-file t nil
                    (lambda (file)
                      (or (file-directory-p file)
                          (string-equal (file-name-extension file) "json"))))))

(defun ghostel-dape--hypothesis-replay-eval (case-file)
  "Return Elisp form string that replays Hypothesis CASE-FILE."
  (format "(ghostel-hypothesis-replay-file %S)" (expand-file-name case-file)))

(defun ghostel-dape--launch-hypothesis-case (case-file)
  "Launch batch Emacs under Dape to replay Hypothesis CASE-FILE."
  (ghostel-dape--launch-emacs
   "--batch" "-Q"
   "-L" "lisp"
   "-L" "test"
   "-l" "test/ghostel-test-helpers.el"
   "-l" "test/hypothesis/ghostel-hypothesis-driver.el"
   "--eval" (ghostel-dape--hypothesis-replay-eval case-file)))

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

;;;###autoload
(defun ghostel-dape-hypothesis-case-file (case-file)
  "Debug one saved Hypothesis render CASE-FILE under Dape.

CASE-FILE should be a JSON case from `test/hypothesis/cases/' or the
failure artifact written as `case.json' by the Hypothesis test runner."
  (interactive (list (ghostel-dape--read-hypothesis-case-file)))
  (unless (file-readable-p case-file)
    (user-error "Hypothesis case file is not readable: %s" case-file))
  (ghostel-dape--launch-hypothesis-case case-file))

;;;###autoload
(defun ghostel-dape-hypothesis-latest-failure ()
  "Debug the latest Hypothesis failure artifact under Dape."
  (interactive)
  (ghostel-dape-hypothesis-case-file ghostel-dape-hypothesis-failure-case-file))

(provide 'ghostel-dape)
;;; ghostel-dape.el ends here
