;;; ghostel-ime.el --- Emacs Lisp IME integration for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Optional integration for Emacs Lisp input methods that commit text by
;; inserting into the current buffer.  `hangul-input-method' is the common
;; example: it calls `self-insert-command' directly for the composed syllable,
;; bypassing ghostel's key remapping, so the commit lands in the buffer but is
;; not sent to the PTY.
;;
;; `ghostel-ime-mode' wraps the buffer-local `input-method-function'.  If the
;; input method inserts committed text into the ghostel buffer, the wrapper
;; captures that text, deletes the local insert, and forwards the UTF-8 bytes to
;; the PTY.  The shell then echoes the text through ghostel's normal redraw path.
;;
;; During an in-flight Lisp IME composition, the mode also asks core ghostel to
;; defer redraws via `ghostel-inhibit-redraw-functions'.  This keeps the native
;; redrawer from rewriting the buffer while Quail-style overlays use it as
;; scratch state.  GUI preedit overlays are left to ghostel.el's native preedit
;; preservation path.

;;; Code:

(require 'ghostel)

(declare-function ghostel--buffer-editable-p "ghostel")
(declare-function ghostel--send-string "ghostel" (string))

(defvar ghostel-ime-mode)

(defgroup ghostel-ime nil
  "Emacs Lisp input-method integration for ghostel."
  :group 'ghostel
  :prefix "ghostel-ime-")

(defvar-local ghostel-ime--original-input-method-function nil
  "Original buffer-local `input-method-function' before ghostel-ime wrapped it.")

(defvar ghostel-ime--composition-buffer nil
  "Buffer where a Lisp input-method composition is currently in flight.")

(defun ghostel-ime--active-quail-overlay-p (buffer)
  "Return non-nil if BUFFER has a live non-empty `quail-overlay'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((overlay (and (boundp 'quail-overlay)
                          (symbol-value 'quail-overlay))))
        (and (overlayp overlay)
             (eq (overlay-buffer overlay) buffer)
             (let ((start (overlay-start overlay))
                   (end (overlay-end overlay)))
               (and start end (< start end))))))))

(defun ghostel-ime-lisp-composing-p (&optional buffer)
  "Return non-nil when a Lisp IME composition is active in BUFFER.
BUFFER defaults to the current buffer.  This detects the dynamic
wrapper state and Quail-style `quail-overlay' state.  It intentionally
ignores GUI preedit overlays, which core ghostel handles separately."
  (let ((buffer (or buffer (current-buffer))))
    (or (eq ghostel-ime--composition-buffer buffer)
        (ghostel-ime--active-quail-overlay-p buffer))))

(defun ghostel-ime--wrap-input-method (key)
  "Translate KEY through the original input method.
If the input method commits text by inserting into the current ghostel
buffer, delete that transient insertion and forward the committed text
to the PTY as UTF-8."
  (let ((ghostel-ime--composition-buffer (current-buffer))
        (original ghostel-ime--original-input-method-function)
        (before-point (point)))
    (if (or (null original)
            ;; `list' is the framework's pass-through sentinel, not a real
            ;; translator; calling it would silently skip composition.
            (eq original #'list))
        (list key)
      (let ((events (funcall original key)))
        (let ((after-point (point)))
          (when (and (> after-point before-point)
                     (ghostel--buffer-editable-p))
            (let ((inserted (buffer-substring-no-properties
                             before-point after-point)))
              (let ((inhibit-read-only t))
                (delete-region before-point after-point))
              (ghostel--send-string
               (encode-coding-string inserted 'utf-8)))))
        events))))

(defun ghostel-ime--install ()
  "Wrap `input-method-function' in the current ghostel buffer."
  (when (and ghostel-ime-mode
             (derived-mode-p 'ghostel-mode)
             input-method-function
             ;; Never capture the `list' pass-through sentinel as the
             ;; original; it appears when no real input method is active,
             ;; and wrapping it would bypass composition.  Wait for the
             ;; activation hook to fire with a genuine translator.
             (not (eq input-method-function #'list))
             (not (eq input-method-function
                      #'ghostel-ime--wrap-input-method)))
    (setq-local ghostel-ime--original-input-method-function
                input-method-function)
    (setq-local input-method-function
                #'ghostel-ime--wrap-input-method)))

(defun ghostel-ime--reassert ()
  "Reinstall the wrapper if an active input method left it unwrapped.
An external input-method or editing-state manager can restore the raw
translator into `input-method-function' without going through
`input-method-activate-hook'.  Run late from `post-command-hook' so the
wrapper is back in place before the next key is read."
  (when current-input-method
    (ghostel-ime--install)))

(defun ghostel-ime--uninstall ()
  "Restore the original `input-method-function' in the current buffer."
  (when (and (eq input-method-function
                 #'ghostel-ime--wrap-input-method)
             ghostel-ime--original-input-method-function)
    (setq-local input-method-function
                ghostel-ime--original-input-method-function))
  (setq-local ghostel-ime--original-input-method-function nil))

;;;###autoload
(define-minor-mode ghostel-ime-mode
  "Toggle Emacs Lisp input-method integration in this ghostel buffer.

When enabled, ghostel forwards committed text from Lisp input methods
that insert directly into the buffer, and defers redraws while a
Quail-style composition is in flight.  A typical setup is:

  (add-hook \='ghostel-mode-hook #\='ghostel-ime-mode)"
  :lighter nil
  (if ghostel-ime-mode
      (progn
        (add-hook 'input-method-activate-hook #'ghostel-ime--install nil t)
        (add-hook 'input-method-deactivate-hook #'ghostel-ime--uninstall nil t)
        (add-hook 'ghostel-inhibit-redraw-functions
                  #'ghostel-ime-lisp-composing-p nil t)
        (add-hook 'post-command-hook #'ghostel-ime--reassert 90 t)
        (ghostel-ime--install))
    (remove-hook 'input-method-activate-hook #'ghostel-ime--install t)
    (remove-hook 'input-method-deactivate-hook #'ghostel-ime--uninstall t)
    (remove-hook 'ghostel-inhibit-redraw-functions
                 #'ghostel-ime-lisp-composing-p t)
    (remove-hook 'post-command-hook #'ghostel-ime--reassert t)
    (ghostel-ime--uninstall)))

(provide 'ghostel-ime)
;;; ghostel-ime.el ends here
