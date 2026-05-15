;;; emacs-font-test.el --- Automate font rendering tests -*- lexical-binding: t -*-

;; Note: This script does not assume all these fonts are installed.
;; If a font is missing on the system, `set-frame-font` will signal an error,
;; which is caught by a `condition-case` inside `font-test--with-loop`.
;; Missing fonts will simply log an error message and be skipped.
(defvar font-test-fonts '(
                             "DejaVu Sans Mono"
                             "Fira Code"
                             "FiraCode Nerd Font"
                             "FreeMono"
                             "Inconsolata"
                             "Symbola"
                             "Victor Mono"
                             )
  "List of fonts to test. Skipped gracefully if not installed.")

(defvar font-test-sizes '(12 16 18)
  "List of font sizes (points) to test.")

(defvar font-test-output-dir "font-tests"
  "Directory to save screenshots.")

(defvar font-test-frame-width 800
  "Width of the test frame in pixels.")

(defvar font-test-frame-height 600
  "Height of the test frame in pixels.")

(defun font-test--setup-frame ()
  "Setup frame for testing."
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (setq-default mode-line-format nil)
  (set-frame-size (selected-frame) font-test-frame-width font-test-frame-height t))

(defun font-test--apply-font-and-size (font size)
  "Apply FONT and SIZE to the frame and enforce fixed pixel dimensions."
  (set-frame-font (format "%s-%d" font size) t t)
  (set-frame-size (selected-frame) font-test-frame-width font-test-frame-height t)
  (redisplay t))

(defun font-test--capture-screenshot (filename)
  "Capture the current frame as a PNG and save to FILENAME.
Requires an Emacs build with Cairo support (`x-export-frames')."
  (if (fboundp 'x-export-frames)
      (let ((png-data (x-export-frames nil 'png)))
        (with-temp-file filename
          (set-buffer-multibyte nil)
          (insert png-data)
          (message "Saved: %s" filename)))
    (error "Emacs was not built with Cairo support (`x-export-frames` is missing)")))

(defmacro font-test--with-loop (prefix &rest body)
  "Iterate over fonts and sizes, prepare the frame, and run BODY.
Binds `filename' and `font-spec' for use within BODY."
  (declare (indent 1))
  `(dolist (font font-test-fonts)
     (dolist (size font-test-sizes)
       (let* ((font-spec (format "%s-%d" font size))
              (clean-font (replace-regexp-in-string " " "_" font))
              (filename (expand-file-name
                         (format "%s-%s-%s.png" ,prefix clean-font size)
                         font-test-output-dir)))
         (message "Testing %s: %s" ,prefix font-spec)
         (condition-case err
             (progn
               (font-test--apply-font-and-size font size)
               ,@body)
           (error (message "Failed to test %s: %s" font-spec (error-message-string err))))))))

(defun font-test-run-buffer-tests ()
  "Core logic for buffer tests."
  (let ((buf (find-file-noselect "box-test.txt")))
    (with-current-buffer buf
      (set-window-buffer (selected-window) buf)
      (fundamental-mode)
      (goto-char (point-min))
      (font-test--with-loop "emacs"
        (sleep-for 0.2)
        (font-test--capture-screenshot filename)))))

(defun font-test-run-ghostel-tests ()
  "Core logic for Ghostel terminal tests."
  (add-to-list 'load-path (expand-file-name "lisp"))
  (require 'ghostel)
  (setq ghostel-module-path (expand-file-name "ghostel-module.so"))
  (font-test--with-loop "ghostel"
    (let ((buf (ghostel)))
      (with-current-buffer buf
        (redisplay t)
        (sleep-for 0.2)
        (ghostel-send-string "unset RPROMPT\n")
        (ghostel-send-string "export PROMPT='%% '\n")
        (ghostel-send-string "clear\n")
        (ghostel-send-string "/bin/cat box-test.txt\n")
        (redisplay t)
        (sleep-for 0.2)
        (font-test--capture-screenshot filename)
        (kill-buffer buf)))))

(defun font-test-run-all-and-exit ()
  "Run buffer and native tests, then exit."
  (unless (file-exists-p font-test-output-dir)
    (make-directory font-test-output-dir))
  (font-test--setup-frame)
  (font-test-run-buffer-tests)
  (message "All font tests complete. Exiting...")
  (kill-emacs))

(provide 'emacs-font-test)
