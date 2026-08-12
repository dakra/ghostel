;;; ghostel-bookmark.el --- Bookmark support for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Integrate ghostel buffers with Emacs's built-in bookmark facility
;; (`bookmark-set' / `bookmark-jump', i.e. `C-x r m' / `C-x r b').  A
;; bookmark records the buffer's working directory, name, and identity
;; (see `ghostel-identity'); jumping to it reuses a live ghostel
;; buffer with that identity (or name, for records without one), or
;; starts a fresh shell in the bookmarked directory when none exists.
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
Notes the working directory, buffer name, and buffer identity.
An identity `command' key (an exec'd program and its arguments) is
saved to the bookmark file in plaintext.
See `ghostel--bookmark-handler' for how they are restored."
  `(nil
    (handler . ghostel--bookmark-handler)
    (location . ,default-directory)
    (buf-name . ,(buffer-name))
    (identity . ,ghostel-identity)
    (defaults . nil)))

;;;###autoload
(defun ghostel--bookmark-handler (bmk)
  "Restore the ghostel bookmark BMK.
Reuse a live ghostel buffer: slot identities match whole, command
records match a live buffer running the recorded command, other
records match by name (title tracking may have renamed the buffer).
Otherwise create one in the bookmarked directory, respawning the
recorded `command' or starting a shell.  Respawned buffers are plain
`ghostel-exec' buffers; kind-specific setup (e.g. eshell's
visual-command exit behavior) is not restored.
When a reused shell's directory differs and `ghostel-bookmark-check-dir'
is non-nil, a `cd' is typed into it; command buffers are left alone."
  (ghostel--load-module t)
  (let* ((dir (bookmark-prop-get bmk 'location))
         (buf-name (bookmark-prop-get bmk 'buf-name))
         ;; Bookmark files are external data; treat a non-alist identity
         ;; as absent.
         (identity (let ((id (bookmark-prop-get bmk 'identity)))
                     (and (consp id) id)))
         (command (alist-get 'command identity))
         (live-p (lambda (b)
                   (let ((p (and b (buffer-local-value 'ghostel--process b))))
                     (and p (process-live-p p) b))))
         ;; Retained dead-shell buffers may share the identity; reuse only
         ;; a live one.  Slot identities (with an `instance') are unique;
         ;; command records reattach to a live buffer running the same
         ;; command (its name may have been uniquified); the rest reuse
         ;; by name.
         (buf (cond
               ((alist-get 'instance identity)
                (ghostel--find-buffer-by-identity identity live-p))
               (command
                (let ((match-p
                       (lambda (b)
                         (and (with-current-buffer b
                                (and (derived-mode-p 'ghostel-mode)
                                     (ghostel-identity-match-p
                                      `((command . ,command))
                                      ghostel-identity)))
                              (funcall live-p b)))))
                  ;; Prefer the recorded name so several buffers running
                  ;; the same command each reattach to their own bookmark.
                  (or (when-let* ((b (get-buffer buf-name)))
                        (funcall match-p b))
                      (seq-find match-p (buffer-list)))))
               (t
                (let ((b (get-buffer buf-name)))
                  (and b
                       (eq (buffer-local-value 'major-mode b) 'ghostel-mode)
                       (funcall live-p b)))))))
    ;; Create branch: the program starts directly in DIR (no `cd').  A
    ;; failed spawn kills the partially created buffer and re-signals.
    (unless buf
      (let ((default-directory (if ghostel-bookmark-check-dir
                                   dir
                                 default-directory)))
        (condition-case err
            (if command
                (progn
                  (setq buf (generate-new-buffer buf-name))
                  (ghostel-exec buf (car command) (cdr command) identity))
              (setq buf (ghostel--create buf-name))
              (with-current-buffer buf
                ;; A nil identity stays nil: a fabricated slot would let
                ;; plain `ghostel' claim this buffer.
                (setq ghostel--managed-buffer-name (buffer-name)
                      ghostel--initial-name (buffer-name)
                      ghostel-identity identity)
                (ghostel--start-process)
                (ghostel--apply-initial-input-mode)))
          ((error quit)
           (when (buffer-live-p buf) (kill-buffer buf))
           (signal (car err) (cdr err))))))
    ;; Reuse branch: `cd' if the live shell has wandered elsewhere.  A
    ;; typed `cd' only makes sense in a shell, not in a command buffer.
    (with-current-buffer buf
      (when (and ghostel-bookmark-check-dir
                 ghostel--term
                 (not (alist-get 'command ghostel-identity))
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
