;;; ghostel-evil.el --- Evil-mode integration for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.10.0
;; Package-Requires: ((emacs "28.1") (evil "1.0") (ghostel "0.8.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Provides evil-mode compatibility for the ghostel terminal emulator.
;; Synchronizes the terminal cursor with Emacs point during evil state
;; transitions so that normal-mode navigation works correctly.
;;
;; Enable by adding to your init:
;;
;;   (use-package ghostel-evil
;;     :after (ghostel evil)
;;     :hook (ghostel-mode . ghostel-evil-mode))

;;; Code:

(require 'ghostel)

;; Silence the byte-compiler.  evil is a required runtime dependency but is
;; not needed at compile time; users must have evil loaded before activating
;; `ghostel-evil-mode'.
(declare-function evil-define-key*       "ext:evil-core")
(declare-function evil-get-register      "ext:evil-common")
(declare-function evil-insert            "ext:evil-commands")
(declare-function evil-refresh-cursor    "ext:evil-core")
(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-set-register      "ext:evil-common")
(declare-function evil-yank              "ext:evil-commands")
(defvar evil-insert-state-map)
(defvar evil-move-cursor-back)
(defvar evil-state)
(defvar evil-was-yanked-without-register)

;; ---------------------------------------------------------------------------
;; Guard predicate
;; ---------------------------------------------------------------------------

(defun ghostel-evil--active-p ()
  "Return non-nil when ghostel-evil editing should intercept."
  (and ghostel-evil-mode
       ghostel--term
       (not (ghostel--mode-enabled ghostel--term 1049))
       (not ghostel--copy-mode-active)))

;; ---------------------------------------------------------------------------
;; Cursor synchronization
;; ---------------------------------------------------------------------------

(defun ghostel-evil--reset-cursor-point ()
  "Move Emacs point to the terminal cursor position."
  (when ghostel--term
    (let ((pos (ghostel--cursor-position ghostel--term)))
      (when pos
        (goto-char (point-min))
        (forward-line (cdr pos))
        (move-to-column (car pos))))))

(defun ghostel-evil--cursor-to-point ()
  "Move the terminal cursor to Emacs point by sending arrow keys."
  (when ghostel--term
    (let* ((tpos (ghostel--cursor-position ghostel--term))
           (tcol (car tpos))
           (trow (cdr tpos))
           (ecol (current-column))
           (erow (- (line-number-at-pos (point) t) 1))
           (dy (- erow trow))
           (dx (- ecol tcol)))
      (cond ((> dy 0) (dotimes (_ dy) (ghostel--send-encoded "down" "")))
            ((< dy 0) (dotimes (_ (abs dy)) (ghostel--send-encoded "up" ""))))
      (cond ((> dx 0) (dotimes (_ dx) (ghostel--send-encoded "right" "")))
            ((< dx 0) (dotimes (_ (abs dx)) (ghostel--send-encoded "left" "")))))))

;; ---------------------------------------------------------------------------
;; Redraw: preserve point in normal state
;; ---------------------------------------------------------------------------

(defun ghostel-evil--around-redraw (orig-fn term &optional full)
  "Preserve Emacs point during redraws in evil normal state.
Without this, the ~30fps redraw timer would snap point back to
the terminal cursor, undoing any evil normal-mode navigation."
  (if (and ghostel-evil-mode
           (not (eq evil-state 'insert))
           (not (ghostel--mode-enabled term 1049)))
      (let ((saved-point (point)))
        (funcall orig-fn term full)
        (goto-char (min saved-point (point-max))))
    (funcall orig-fn term full)))

;; ---------------------------------------------------------------------------
;; Cursor style: let evil control cursor shape
;; ---------------------------------------------------------------------------

(defun ghostel-evil--override-cursor-style (orig-fn style visible)
  "Let evil control cursor shape instead of the terminal.
In alt-screen mode, defer to the terminal's cursor style."
  (if (and ghostel-evil-mode
           ghostel--term
           (not (ghostel--mode-enabled ghostel--term 1049)))
      (evil-refresh-cursor)
    (funcall orig-fn style visible)))

;; ---------------------------------------------------------------------------
;; Evil state hooks
;; ---------------------------------------------------------------------------

(defvar ghostel-evil--sync-inhibit nil
  "When non-nil, skip arrow-key sync in the insert-state-entry hook.
Set by the `I'/`A' advice which send Home/End directly.")

(defun ghostel-evil--normal-state-entry ()
  "Snap Emacs point to the terminal cursor when entering normal state."
  (when (and (derived-mode-p 'ghostel-mode) (ghostel-evil--active-p))
    (ghostel-evil--reset-cursor-point)))

(defun ghostel-evil--insert-state-entry ()
  "Sync terminal cursor to Emacs point when entering insert state.
Skipped when `ghostel-evil--sync-inhibit' is set (by I/A advice
which already sent C-a/C-e).
When point is on a different row from the terminal cursor, snap
back to the terminal cursor instead of sending up/down arrows
which the shell would interpret as history navigation."
  (when (derived-mode-p 'ghostel-mode)
    (if ghostel-evil--sync-inhibit
        (setq ghostel-evil--sync-inhibit nil)
      (when ghostel--term
        (let* ((tpos (ghostel--cursor-position ghostel--term))
               (trow (cdr tpos))
               (erow (- (line-number-at-pos (point) t) 1)))
          (if (= erow trow)
              (ghostel-evil--cursor-to-point)
            (ghostel-evil--reset-cursor-point)))))))

(defun ghostel-evil--escape-stay ()
  "Disable `evil-move-cursor-back' in ghostel buffers.
Moving the cursor back on ESC desynchronizes point from the terminal
cursor."
  (setq-local evil-move-cursor-back nil))

;; ---------------------------------------------------------------------------
;; Advice for evil insert-line / append-line
;; ---------------------------------------------------------------------------

(defun ghostel-evil--before-insert-line (&rest _)
  "Send C-a to move terminal cursor to start of input."
  (when (and ghostel-evil-mode ghostel--term)
    (ghostel--send-encoded "a" "ctrl")
    (setq ghostel-evil--sync-inhibit t)))

(defun ghostel-evil--before-append-line (&rest _)
  "Send C-e to move terminal cursor to end of input."
  (when (and ghostel-evil-mode ghostel--term)
    (ghostel--send-encoded "e" "ctrl")
    (setq ghostel-evil--sync-inhibit t)))

;; ---------------------------------------------------------------------------
;; Editing primitives
;; ---------------------------------------------------------------------------

(defun ghostel-evil--delete-region (beg end)
  "Delete text between BEG and END via the terminal PTY.
Moves terminal cursor to END, then sends backspace keys.
Uses backspace rather than forward-delete because the Delete key
escape sequence is not bound in all shell configurations."
  (let ((count (- end beg)))
    (when (> count 0)
      (goto-char end)
      (ghostel-evil--cursor-to-point)
      (dotimes (_ count)
        (ghostel--send-encoded "backspace" ""))
      (goto-char beg))))

;; ---------------------------------------------------------------------------
;; Advice for evil editing operators
;; ---------------------------------------------------------------------------

(defun ghostel-evil--around-delete
    (orig-fn beg end &optional type register yank-handler)
  "Intercept `evil-delete' in ghostel buffers.
Yanks text to REGISTER, then deletes via PTY.
Covers d, dd, D, x, X."
  (if (ghostel-evil--active-p)
      (progn
        (unless register
          (let ((text (filter-buffer-substring beg end)))
            (unless (string-match-p "\n" text)
              (evil-set-register ?- text))))
        (let ((evil-was-yanked-without-register nil))
          (evil-yank beg end type register yank-handler))
        (if (eq type 'line)
            ;; For line-type (dd): clear the input line
            (progn
              (ghostel--send-encoded "e" "ctrl")
              (ghostel--send-encoded "u" "ctrl"))
          (ghostel-evil--delete-region beg end)))
    (funcall orig-fn beg end type register yank-handler)))

(defun ghostel-evil--around-change
    (orig-fn beg end type register yank-handler &optional delete-func)
  "Intercept `evil-change' in ghostel buffers.
Deletes via PTY, then enters insert state.
Covers c, cc, C, s, S."
  (if (ghostel-evil--active-p)
      (progn
        (let ((evil-was-yanked-without-register nil))
          (evil-yank beg end type register yank-handler))
        (if (eq type 'line)
            (progn
              (ghostel--send-encoded "e" "ctrl")
              (ghostel--send-encoded "u" "ctrl"))
          (ghostel-evil--delete-region beg end))
        (setq ghostel-evil--sync-inhibit t)
        (evil-insert 1))
    (funcall orig-fn beg end type register yank-handler delete-func)))

(defun ghostel-evil--around-replace (orig-fn beg end type char)
  "Intercept `evil-replace' in ghostel buffers.
Deletes the range, then inserts replacement characters."
  (if (ghostel-evil--active-p)
      (when char
        (let ((count (- end beg)))
          (ghostel-evil--delete-region beg end)
          (ghostel--paste-text (make-string count char))))
    (funcall orig-fn beg end type char)))

(defun ghostel-evil--around-paste-after
    (orig-fn count &optional register yank-handler)
  "Intercept `evil-paste-after' in ghostel buffers.
Pastes from REGISTER via the terminal PTY."
  (if (ghostel-evil--active-p)
      (let ((text (if register
                      (evil-get-register register)
                    (current-kill 0)))
            (count (prefix-numeric-value count)))
        (when text
          (ghostel-evil--cursor-to-point)
          (ghostel--send-encoded "right" "")
          (dotimes (_ count)
            (ghostel--paste-text text))))
    (funcall orig-fn count register yank-handler)))

(defun ghostel-evil--around-paste-before
    (orig-fn count &optional register yank-handler)
  "Intercept `evil-paste-before' in ghostel buffers.
Pastes from REGISTER via the terminal PTY."
  (if (ghostel-evil--active-p)
      (let ((text (if register
                      (evil-get-register register)
                    (current-kill 0)))
            (count (prefix-numeric-value count)))
        (when text
          (ghostel-evil--cursor-to-point)
          (dotimes (_ count)
            (ghostel--paste-text text))))
    (funcall orig-fn count register yank-handler)))

;; ---------------------------------------------------------------------------
;; Insert-state Ctrl key passthrough
;; ---------------------------------------------------------------------------

(defvar ghostel-evil-mode-map (make-sparse-keymap)
  "Keymap for `ghostel-evil-mode'.
Insert-state Ctrl key bindings are set up via `evil-define-key*'.")

(defconst ghostel-evil--ctrl-passthrough-keys
  '("a" "d" "e" "k" "n" "p" "r" "t" "u" "w" "y")
  "Ctrl+key combinations to pass through to the terminal in insert state.
These keys all have standard readline/zle bindings (C-a beginning-of-line,
C-d EOF, C-e end-of-line, C-k kill-line, etc.) that would otherwise be
intercepted by evil's insert-state commands.")

(defun ghostel-evil--passthrough-ctrl (key)
  "Send Ctrl+KEY to the terminal PTY, or fall back to evil's binding.
Used for insert-state Ctrl keys that have readline/zle equivalents."
  (if (ghostel-evil--active-p)
      (ghostel--send-encoded key "ctrl")
    (let ((cmd (lookup-key evil-insert-state-map (kbd (concat "C-" key)))))
      (when (commandp cmd)
        (call-interactively cmd)))))

(with-eval-after-load 'evil
  (dolist (key ghostel-evil--ctrl-passthrough-keys)
    (let ((k key))
      (evil-define-key* 'insert ghostel-evil-mode-map
        (kbd (concat "C-" k))
        (defalias (intern (format "ghostel-evil--passthrough-ctrl-%s" k))
          (lambda ()
            (interactive)
            (ghostel-evil--passthrough-ctrl k))
          (format "Send C-%s to the terminal or fall back to evil." k))))))

(defun ghostel-evil--around-undo (orig-fn count)
  "Intercept `evil-undo' in ghostel buffers.
Sends Ctrl+_ (readline undo) COUNT times."
  (if (ghostel-evil--active-p)
      (dotimes (_ (or count 1))
        (ghostel--send-encoded "_" "ctrl"))
    (funcall orig-fn count)))

(defun ghostel-evil--around-redo (orig-fn count)
  "Intercept `evil-redo' in ghostel buffers."
  (if (ghostel-evil--active-p)
      (message "Redo not supported in terminal")
    (funcall orig-fn count)))

;; ---------------------------------------------------------------------------
;; Minor mode
;; ---------------------------------------------------------------------------

;;;###autoload
(define-minor-mode ghostel-evil-mode
  "Minor mode for evil integration in ghostel terminal buffers.
Synchronizes the terminal cursor with Emacs point during evil
state transitions."
  :lighter nil
  :keymap ghostel-evil-mode-map
  (if ghostel-evil-mode
      (progn
        (evil-set-initial-state 'ghostel-mode 'insert)
        (ghostel-evil--escape-stay)
        (add-hook 'evil-normal-state-entry-hook
                  #'ghostel-evil--normal-state-entry nil t)
        (add-hook 'evil-insert-state-entry-hook
                  #'ghostel-evil--insert-state-entry nil t)
        (advice-add 'evil-insert-line :before #'ghostel-evil--before-insert-line)
        (advice-add 'evil-append-line :before #'ghostel-evil--before-append-line)
        (advice-add 'evil-delete :around #'ghostel-evil--around-delete)
        (advice-add 'evil-change :around #'ghostel-evil--around-change)
        (advice-add 'evil-replace :around #'ghostel-evil--around-replace)
        (advice-add 'evil-paste-after :around #'ghostel-evil--around-paste-after)
        (advice-add 'evil-paste-before :around #'ghostel-evil--around-paste-before)
        (advice-add 'evil-undo :around #'ghostel-evil--around-undo)
        (advice-add 'evil-redo :around #'ghostel-evil--around-redo)
        (advice-add 'ghostel--redraw :around #'ghostel-evil--around-redraw)
        (advice-add 'ghostel--set-cursor-style :around
                    #'ghostel-evil--override-cursor-style)
        (evil-refresh-cursor))
    (remove-hook 'evil-normal-state-entry-hook
                 #'ghostel-evil--normal-state-entry t)
    (remove-hook 'evil-insert-state-entry-hook
                 #'ghostel-evil--insert-state-entry t)
    (advice-remove 'evil-insert-line #'ghostel-evil--before-insert-line)
    (advice-remove 'evil-append-line #'ghostel-evil--before-append-line)
    (advice-remove 'evil-delete #'ghostel-evil--around-delete)
    (advice-remove 'evil-change #'ghostel-evil--around-change)
    (advice-remove 'evil-replace #'ghostel-evil--around-replace)
    (advice-remove 'evil-paste-after #'ghostel-evil--around-paste-after)
    (advice-remove 'evil-paste-before #'ghostel-evil--around-paste-before)
    (advice-remove 'evil-undo #'ghostel-evil--around-undo)
    (advice-remove 'evil-redo #'ghostel-evil--around-redo)
    (advice-remove 'ghostel--redraw #'ghostel-evil--around-redraw)
    (advice-remove 'ghostel--set-cursor-style
                   #'ghostel-evil--override-cursor-style)))

(provide 'ghostel-evil)
;;; ghostel-evil.el ends here
