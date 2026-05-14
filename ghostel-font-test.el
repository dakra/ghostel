;;; ghostel-font-test.el --- Automate font rendering tests -*- lexical-binding: t -*-

(defvar ghostel-test-fonts '("Fira Code"
                             "FiraCode Nerd Font"
                             "Victor Mono"
                             "DejaVu Sans Mono"
                             "FreeMono"
                             "Inconsolata")
  "List of fonts to test.")

(defvar ghostel-test-sizes '(12 16 18)
  "List of font sizes (points) to test.")

(defvar ghostel-test-output-dir "font-tests"
  "Directory to save screenshots.")

(defvar ghostel-test-frame-width 800
  "Width of the test frame in pixels.")

(defvar ghostel-test-frame-height 600
  "Height of the test frame in pixels.")

(defun ghostel--setup-test-frame ()
  "Setup frame for testing."
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (setq-default mode-line-format nil)
  (set-frame-size (selected-frame) ghostel-test-frame-width ghostel-test-frame-height t))

(defun ghostel--apply-font-and-size (font size)
  "Apply FONT and SIZE to the frame and enforce fixed pixel dimensions."
  (set-frame-font (format "%s-%d" font size) t t)
  (set-frame-size (selected-frame) ghostel-test-frame-width ghostel-test-frame-height t)
  (redisplay t))

(defun ghostel--capture-screenshot (filename)
  "Capture the current frame as a PNG and save to FILENAME."
  (let ((png-data (x-export-frames nil 'png)))
    (with-temp-file filename
      (set-buffer-multibyte nil)
      (insert png-data)
      (message "Saved: %s" filename))))

(defmacro ghostel--with-test-loop (prefix &rest body)
  "Iterate over fonts and sizes, prepare the frame, and run BODY.
Binds `filename' and `font-spec' for use within BODY."
  (declare (indent 1))
  `(dolist (font ghostel-test-fonts)
     (dolist (size ghostel-test-sizes)
       (let* ((font-spec (format "%s-%d" font size))
              (clean-font (replace-regexp-in-string " " "_" font))
              (filename (expand-file-name
                         (format "%s-%s-%s.png" ,prefix clean-font size)
                         ghostel-test-output-dir)))
         (message "Testing %s: %s" ,prefix font-spec)
         (condition-case err
             (progn
               (ghostel--apply-font-and-size font size)
               ,@body)
           (error (message "Failed to test %s: %s" font-spec (error-message-string err))))))))

(defun ghostel--run-buffer-tests ()
  "Core logic for buffer tests."
  (let ((buf (find-file-noselect "box-test.txt")))
    (with-current-buffer buf
      (set-window-buffer (selected-window) buf)
      (fundamental-mode)
;;      (goto-char (point-min))
;;      (insert "\n") ; Newline like prompt in Ghostel
      (goto-char (point-max))
      (ghostel--with-test-loop "emacs"
        (sleep-for 0.1)
        (ghostel--capture-screenshot filename)))))

(defun ghostel--run-native-tests ()
  "Core logic for Ghostel terminal tests."
  (add-to-list 'load-path (expand-file-name "lisp"))
  (require 'ghostel)
  (setq ghostel-module-path (expand-file-name "ghostel-module.so"))
  (ghostel--with-test-loop "ghostel"
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
        (ghostel--capture-screenshot filename)
        (kill-buffer buf)))))

(defun ghostel-run-all-tests-and-exit ()
  "Run buffer and native tests, then exit."
  (unless (file-exists-p ghostel-test-output-dir)
    (make-directory ghostel-test-output-dir))
  (ghostel--setup-test-frame)
  (ghostel--run-buffer-tests)
;;  (ghostel--run-native-tests)
  (message "All font tests complete. Exiting...")
  (kill-emacs))

(provide 'ghostel-font-test)
