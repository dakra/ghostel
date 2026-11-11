;;; ghostel-faces.el --- Faces and color palette for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Appearance definitions for ghostel's terminal rendering: the 16 ANSI
;; color faces (inheriting Emacs's `ansi-color-*' faces), the bold and
;; italic attribute faces, the hint-cursor faces drawn in copy/Emacs
;; modes, the `ghostel-default' base face that controls the buffer's
;; inherited terminal appearance, and the `ghostel-color-palette' vector
;; that maps the 16 palette slots to those faces.

;;; Code:

(require 'ansi-color)


;;; ANSI color faces

(defface ghostel-color-black
  '((t :inherit ansi-color-black))
  "Face used to render black color code."
  :group 'ghostel)

(defface ghostel-color-red
  '((t :inherit ansi-color-red))
  "Face used to render red color code."
  :group 'ghostel)

(defface ghostel-color-green
  '((t :inherit ansi-color-green))
  "Face used to render green color code."
  :group 'ghostel)

(defface ghostel-color-yellow
  '((t :inherit ansi-color-yellow))
  "Face used to render yellow color code."
  :group 'ghostel)

(defface ghostel-color-blue
  '((t :inherit ansi-color-blue))
  "Face used to render blue color code."
  :group 'ghostel)

(defface ghostel-color-magenta
  '((t :inherit ansi-color-magenta))
  "Face used to render magenta color code."
  :group 'ghostel)

(defface ghostel-color-cyan
  '((t :inherit ansi-color-cyan))
  "Face used to render cyan color code."
  :group 'ghostel)

(defface ghostel-color-white
  '((t :inherit ansi-color-white))
  "Face used to render white color code."
  :group 'ghostel)

(defface ghostel-color-bright-black
  '((t :inherit ansi-color-bright-black))
  "Face used to render bright black color code."
  :group 'ghostel)

(defface ghostel-color-bright-red
  '((t :inherit ansi-color-bright-red))
  "Face used to render bright red color code."
  :group 'ghostel)

(defface ghostel-color-bright-green
  '((t :inherit ansi-color-bright-green))
  "Face used to render bright green color code."
  :group 'ghostel)

(defface ghostel-color-bright-yellow
  '((t :inherit ansi-color-bright-yellow))
  "Face used to render bright yellow color code."
  :group 'ghostel)

(defface ghostel-color-bright-blue
  '((t :inherit ansi-color-bright-blue))
  "Face used to render bright blue color code."
  :group 'ghostel)

(defface ghostel-color-bright-magenta
  '((t :inherit ansi-color-bright-magenta))
  "Face used to render bright magenta color code."
  :group 'ghostel)

(defface ghostel-color-bright-cyan
  '((t :inherit ansi-color-bright-cyan))
  "Face used to render bright cyan color code."
  :group 'ghostel)

(defface ghostel-color-bright-white
  '((t :inherit ansi-color-bright-white))
  "Face used to render bright white color code."
  :group 'ghostel)


;;; Text attribute faces

(defface ghostel-bold
  '((t :inherit ansi-color-bold))
  "Face used to render bold text."
  :group 'ghostel)

(defface ghostel-italic
  '((t :inherit ansi-color-italic))
  "Face used to render italic text."
  :group 'ghostel)


;;; Cursor and default faces

(defface ghostel-fake-cursor
  '((t :box (:line-width (-1 . -1))))
  "Face for the hollow hint cursor drawn in copy and Emacs modes."
  :group 'ghostel)

(defface ghostel-fake-cursor-box
  '((t :inherit cursor))
  "Face for the solid hint cursor drawn for box-style cursors.
Used when `cursor-in-non-selected-windows' resolves to box."
  :group 'ghostel)

(defface ghostel-default
  '((t nil))
  "Base face for default text in ghostel terminal buffers.
Customize this to give ghostel buffers a different default foreground,
background, font, or size than the rest of Emacs.  Foreground and
background also seed OSC 10/11 protocol color replies."
  :group 'ghostel)


;;; Color palette

(defvar ghostel-color-palette
  [ghostel-color-black
   ghostel-color-red
   ghostel-color-green
   ghostel-color-yellow
   ghostel-color-blue
   ghostel-color-magenta
   ghostel-color-cyan
   ghostel-color-white
   ghostel-color-bright-black
   ghostel-color-bright-red
   ghostel-color-bright-green
   ghostel-color-bright-yellow
   ghostel-color-bright-blue
   ghostel-color-bright-magenta
   ghostel-color-bright-cyan
   ghostel-color-bright-white]
  "Color palette for the terminal (vector of 16 face names).")


;;; Face utilities

(defun ghostel--face-hex-color (face attr)
  "Extract hex color string from FACE's ATTR (:foreground or :background).
Falls back to white (for :foreground) or black (for :background)."
  (or (let ((color (face-attribute face attr nil 'default)))
        (when (and (stringp color)
                   (not (member color '("unspecified"
                                        "unspecified-fg"
                                        "unspecified-bg"))))
          (let ((rgb (color-values color)))
            (if rgb
                (apply #'format "#%02x%02x%02x"
                       (mapcar (lambda (c) (ash c -8)) rgb))
              ;; Batch mode / TTY: color-values returns nil without a
              ;; display.  If the color is already "#RRGGBB", use it.
              (and (string-prefix-p "#" color) (= (length color) 7)
                   color)))))
      (if (eq attr :foreground) "#ffffff" "#000000")))

(defun ghostel--hex-color-scheme (hex)
  "Return `light' or `dark' for HEX (\"#RRGGBB\") as `color-dark-p' judges it."
  (if (color-dark-p (mapcar (lambda (i)
                              (/ (string-to-number (substring hex i (+ i 2)) 16)
                                 255.0))
                            '(1 3 5)))
      'dark 'light))

(defun ghostel-theme-colors ()
  "Return the terminal colors that ghostel's faces give, as an alist.
A color is a string \"#RRGGBB\".  The keys are `foreground' and
`background', from the face `ghostel-default'; `cursor', the background
of the face `cursor', or nil when it has none; `scheme', `dark' or
`light' as the background is; and `palette', a vector of the 16 colors
of `ghostel-color-palette'."
  (let ((bg (ghostel--face-hex-color 'ghostel-default :background)))
    `((foreground . ,(ghostel--face-hex-color 'ghostel-default :foreground))
      (background . ,bg)
      (cursor . ,(and (face-background 'cursor nil t)
                      (ghostel--face-hex-color 'cursor :background)))
      (scheme . ,(ghostel--hex-color-scheme bg))
      (palette . ,(vconcat (mapcar (lambda (face)
                                     (ghostel--face-hex-color face :foreground))
                                   ghostel-color-palette))))))

(provide 'ghostel-faces)
;;; ghostel-faces.el ends here
