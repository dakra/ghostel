;;; ghostel-bookmark.el --- Bookmark support for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Integrate ghostel buffers with Emacs's built-in bookmark facility
;; (`bookmark-set' / `bookmark-jump', i.e. `C-x r m' / `C-x r b').  A
;; bookmark records the buffer's working directory and name; jumping to
;; it reuses a live ghostel buffer of that name, or starts a fresh shell
;; in the bookmarked directory when none exists.
;;
;; `ghostel-mode' wires up `bookmark-make-record-function' to point at
;; `ghostel--bookmark-make-record' (a quoted symbol, so ghostel.el needs
;; no load-time dependency on this file).  Both the record maker and the
;; handler are autoloaded, so a bookmark saved in one session restores in
;; a fresh Emacs the first time it is used.

;;; Code:

(require 'bookmark)
(require 'ghostel)

(defcustom ghostel-bookmark-check-dir t
  "When non-nil, restoring a ghostel bookmark also restores its directory.
For a freshly created buffer the shell starts in the bookmarked
directory; for a reused live buffer that has since moved elsewhere,
a `cd' to the bookmarked directory is typed into the shell."
  :type 'boolean
  :group 'ghostel)

;;;###autoload
(defun ghostel--bookmark-make-record ()
  "Return a bookmark record for the current ghostel buffer.
Notes the working directory and buffer name.
See `ghostel--bookmark-handler' for how they are restored."
  `(nil
    (handler . ghostel--bookmark-handler)
    (location . ,default-directory)
    (buf-name . ,(buffer-name))
    (defaults . nil)))

;;;###autoload
(defun ghostel--bookmark-handler (bmk)
  "Restore the ghostel bookmark BMK.
Reuse a live ghostel buffer of the bookmarked name, or create one with a shell
started in the bookmarked directory.  When a reused buffer's directory differs
and `ghostel-bookmark-check-dir' is non-nil, type a `cd' into the shell."
  (ghostel--load-module t)
  (let* ((dir (bookmark-prop-get bmk 'location))
         (buf-name (bookmark-prop-get bmk 'buf-name))
         (buf (get-buffer buf-name))
         (mode (and buf (buffer-local-value 'major-mode buf))))
    ;; Create branch: the shell starts directly in DIR (no `cd').
    (when (or (not buf) (not (eq mode 'ghostel-mode)))
      (let ((default-directory (if ghostel-bookmark-check-dir
                                   dir
                                 default-directory)))
        (setq buf (ghostel--create buf-name))
        (with-current-buffer buf
          (setq ghostel--managed-buffer-name (buffer-name)
                ghostel--buffer-identity buf-name)
          (ghostel--start-process)
          (ghostel--apply-initial-input-mode))))
    ;; Reuse branch: `cd' if the live buffer has wandered elsewhere.
    (with-current-buffer buf
      (when (and ghostel-bookmark-check-dir
                 ghostel--term
                 (not (string-equal default-directory dir)))
        (when (memq ghostel--input-mode '(copy emacs))
          (ghostel-readonly-exit))
        ;; Ghostel records remote dirs as TRAMP paths, so strip the TRAMP prefix
        ;; with `file-local-name', and quote so paths with spaces survive.
        (ghostel-send-string
         (concat "cd " (shell-quote-argument (file-local-name dir))))
        (ghostel-send-key "return")))
    (set-buffer buf)))

;; Fills the Type column of `bookmark-bmenu-list' (Emacs 29+).
(put 'ghostel--bookmark-handler 'bookmark-handler-type "Ghostel")

(provide 'ghostel-bookmark)
;;; ghostel-bookmark.el ends here
