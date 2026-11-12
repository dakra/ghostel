;;; ghostel-kitty.el --- Kitty graphics support for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Settings and Lisp-owned image storage for the native Kitty row renderer.

;;; Code:


;;; Customization

(defcustom ghostel-kitty-graphics-storage-limit (* 320 1024 1024)  ; 320 MiB
  "Kitty graphics image storage cap, in bytes, per terminal.

Caps how much memory libghostty's kitty-graphics image store can
hold per ghostel buffer.  Each transmitted image (PNG bytes or raw
pixels) counts; libghostty evicts the oldest image when a new
transmission would exceed this limit.

Set to 0 to disable kitty graphics entirely — image transmissions
are then ignored and no storage is allocated.  Useful on low-memory
systems or for terminals you know won't display images."
  :type 'integer
  :group 'ghostel)

(defcustom ghostel-kitty-graphics-mediums '(file temp-file shared-mem)
  "Image-loading mediums to enable for the Kitty graphics protocol.

The direct medium (base64 inline, used by timg and yazi) is always
enabled.  The others let the program name data on the local machine:
- file: a local file, read by the terminal (broot PNG previews)
- temp-file: a temp file, read and unlinked (broot, ranger)
- shared-mem: a POSIX shared-memory region

The default matches Ghostty and kitty.  A program running remotely
\(SSH, tmux passthrough) can use these mediums to make ghostel display
a local file; set this to nil to accept inline data only."
  :type '(set (const :tag "Local file medium" file)
              (const :tag "Temp-file medium" temp-file)
              (const :tag "Shared-memory medium" shared-mem))
  :group 'ghostel)

(defun ghostel--kitty-mediums-bits ()
  "Encode `ghostel-kitty-graphics-mediums' as a bitfield for the module."
  (let ((bits 0)
        (mediums ghostel-kitty-graphics-mediums))
    (when (memq 'file mediums) (setq bits (logior bits 1)))
    (when (memq 'temp-file mediums) (setq bits (logior bits 2)))
    (when (memq 'shared-mem mediums) (setq bits (logior bits 4)))
    bits))

(provide 'ghostel-kitty)
;;; ghostel-kitty.el ends here
