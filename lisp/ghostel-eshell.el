;;; ghostel-eshell.el --- Eshell integration for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run Eshell "visual" commands (programs in `eshell-visual-commands',
;; `eshell-visual-subcommands', and `eshell-visual-options' — e.g. vim,
;; htop, less, top) inside a dedicated ghostel buffer.  Eshell's default
;; implementation uses `term-mode' via `eshell-exec-visual'; this mode
;; overrides that to dispatch through `ghostel-exec' so full-screen
;; TUIs get a real terminal emulator.
;;
;; Enable with:
;;
;;   (add-hook 'eshell-load-hook #'ghostel-eshell-visual-command-mode)
;;
;; Running ad-hoc commands in a ghostel buffer without adding them to
;; `eshell-visual-commands' is also supported via the `ghostel' eshell
;; built-in:
;;
;;   ~ $ ghostel nethack
;;
;; Add a shorter alias in your init.el if you like:
;;
;;   (defalias 'eshell/v 'eshell/ghostel)    ;; then:  ~ $ v nethack

;;; Code:

(require 'ghostel)

(defvar eshell-interpreter-alist)
(defvar eshell-destroy-buffer-when-process-dies)

(declare-function eshell-find-interpreter "esh-ext"
                  (file args &optional no-examine-p))
(declare-function eshell-stringify-list "esh-util" (args))
(declare-function eshell-exec-visual "em-term" (&rest args))

(defcustom ghostel-eshell-track-title nil
  "Whether to let visual-command buffers rename themselves via OSC titles.
When nil (the default), the visual-command buffer keeps its initial
name (e.g. \"*vim*\") for the duration of the program.  When non-nil,
OSC 0/2 title escapes rename the buffer via `ghostel-buffer-name-by-title'."
  :type 'boolean
  :group 'ghostel)

(defun ghostel-eshell--visual-exit (buffer _event)
  "Post-exit cleanup for a visual-command BUFFER.
Deferred via `run-at-time' so ghostel's sentinel has appended its
\"[Process exited]\" marker first.  No-op if the buffer was killed
\(i.e. `ghostel-kill-buffer-on-exit' was non-nil).  Otherwise snaps
point and all windows showing BUFFER to `point-max' and binds `q'
to dismiss the buffer."
  (run-at-time
   0 nil
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (goto-char (point-max))
         ;; Bind `q' in a fresh buffer-local map to not mutate the shared
         ;; `ghostel-semi-char-mode-map' and leak into other buffers.
         (let ((map (make-sparse-keymap)))
           (set-keymap-parent map (current-local-map))
           (keymap-set map "q" #'kill-current-buffer)
           (use-local-map map))
         (dolist (win (get-buffer-window-list buffer nil t))
           (set-window-point win (point-max))))))))

(defun ghostel-eshell--exec-visual (&rest args)
  "Replacement for `eshell-exec-visual' that dispatches to ghostel.
ARGS are the program name followed by its arguments, as passed by
eshell."
  (require 'esh-ext)
  (require 'esh-util)
  (save-current-buffer
    (let* ((eshell-interpreter-alist nil)
           (interp (eshell-find-interpreter (car args) (cdr args)))
           (program (car interp))
           (prog-args (flatten-tree
                       (eshell-stringify-list
                        (append (cdr interp) (cdr args)))))
           (buf (generate-new-buffer
                 (concat "*" (file-name-nondirectory program) "*"))))
      (switch-to-buffer buf)
      (ghostel-exec buf program prog-args '((kind . eshell)))
      (with-current-buffer buf
        (setq-local ghostel-kill-buffer-on-exit
                    (bound-and-true-p eshell-destroy-buffer-when-process-dies))
        (setq-local ghostel-buffer-name-function
                    (and ghostel-eshell-track-title
                         #'ghostel-buffer-name-by-title))
        (add-hook 'ghostel-exit-functions
                  #'ghostel-eshell--visual-exit nil t))
      nil)))

;;;###autoload
(defun eshell/ghostel (&rest args)
  "Run ARGS as a visual command in a dedicated ghostel buffer.
This is an eshell built-in; type `ghostel PROGRAM ...' at the
eshell prompt to launch any program in a ghostel terminal buffer
without adding it to `eshell-visual-commands'.  Dispatches through
`eshell-exec-visual', so when `ghostel-eshell-visual-command-mode'
is enabled the program runs under ghostel; otherwise it falls
back to eshell's default `term-mode' visual handling."
  (apply #'eshell-exec-visual args))

;;;###autoload
(define-minor-mode ghostel-eshell-visual-command-mode
  "Run Eshell visual commands (vim, htop, less, ...) in ghostel buffers.
When enabled, `eshell-exec-visual' is overridden to launch the
program in a dedicated ghostel terminal buffer.  When the program
exits, the buffer stays on `[Process exited]' so any remaining
output is visible; press `q' to dismiss it.  Set
`eshell-destroy-buffer-when-process-dies' to non-nil to kill the
buffer automatically on exit instead."
  :global t
  :group 'ghostel
  (if ghostel-eshell-visual-command-mode
      (advice-add 'eshell-exec-visual :override
                  #'ghostel-eshell--exec-visual)
    (advice-remove 'eshell-exec-visual
                   #'ghostel-eshell--exec-visual)))

(provide 'ghostel-eshell)

;;; ghostel-eshell.el ends here
