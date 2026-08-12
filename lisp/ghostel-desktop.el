;;; ghostel-desktop.el --- desktop.el support for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Ghostel integrates with desktop.el to restore terminal buffers on restart.
;; As with bookmarks, only the directory and identity are saved and restored,
;; not scrollback or session contents.

;; Command buffers (`ghostel-exec', `ghostel-compile', eshell visual
;; commands), remote (TRAMP) terminals, and terminals whose directory no
;; longer exists are skipped at restore time, with a message: an unattended
;; restore should not re-run a saved command or open TRAMP connections.

;; Every restored terminal spawns a real shell; `desktop-restore-eager'
;; limits how many are restored during `desktop-read' itself.

;;; Code:

(require 'desktop)
(require 'ghostel)

;;;###autoload
(defun ghostel-desktop-save-buffer (_desktop-dirname)
  "Return this ghostel buffer's desktop data: (DIRECTORY IDENTITY).
An identity `command' key (the argv of an exec'd program) is written
to the desktop file in plaintext."
  (list default-directory ghostel-identity))

;;;###autoload
(defun ghostel-desktop-restore-buffer (_file-name buffer-name misc)
  "Restore a ghostel terminal named BUFFER-NAME from desktop data MISC.
MISC is (DIRECTORY IDENTITY) as saved by `ghostel-desktop-save-buffer'.
Reuse a live buffer matching IDENTITY, else start a fresh shell in DIRECTORY
under BUFFER-NAME -- skipping remote and missing directories and command
identities, with a message.  Return the buffer, or nil when skipping."
  (pcase-let ((`(,dir ,identity) misc))
    ;; Desktop files are external data; treat a non-alist identity as absent.
    (unless (consp identity) (setq identity nil))
    (if (not (stringp dir))
        (progn
          (message "Desktop: no directory recorded for ghostel buffer %s"
                   buffer-name)
          nil)
      (let ((buf (or (ghostel-desktop--reuse identity buffer-name)
                     (ghostel-desktop--spawn dir identity buffer-name))))
        (when buf
          (ghostel-desktop--shield-replay buf))
        buf))))

(defun ghostel-desktop--reuse (identity buffer-name)
  "Return a live terminal matching IDENTITY, renamed to BUFFER-NAME, or nil.
Reuse needs an `instance' key and a live shell -- with
`ghostel-kill-buffer-on-exit' nil a dead shell's buffer lingers,
identity included."
  (let ((buf (and (alist-get 'instance identity)
                  (ghostel--find-buffer-by-identity
                   identity
                   (lambda (b)
                     (let ((p (buffer-local-value 'ghostel--process b)))
                       (and p (process-live-p p) b)))))))
    (when buf
      (with-current-buffer buf
        ;; `desktop-create-buffer' renames the returned buffer to the saved
        ;; name; rename here already and keep `ghostel--managed-buffer-name'
        ;; in sync so automatic title renames keep working.
        (rename-buffer buffer-name t)
        (setq ghostel--managed-buffer-name (buffer-name)))
      buf)))

(defun ghostel-desktop--spawn (dir identity buffer-name)
  "Start a shell in DIR under BUFFER-NAME with IDENTITY as its identity.
Skip -- returning nil, with a message -- remote or missing directories
and command-running identities."
  (cond
   ((file-remote-p dir)
    (message "Desktop: skipping remote ghostel terminal %s" buffer-name)
    nil)
   ((or (alist-get 'command identity)
        (eq (alist-get 'kind identity) 'compile))
    (message "Desktop: not respawning ghostel command buffer %s" buffer-name)
    nil)
   ((not (file-directory-p dir))
    (message "Desktop: skipping ghostel terminal %s, directory %s is gone"
             buffer-name dir)
    nil)
   (t
    (ghostel--load-module)
    (unless (fboundp 'ghostel--new)
      (error "Ghostel native module is not available"))
    (let ((default-directory dir)
          (buf nil))
      (condition-case err
          (progn
            (setq buf (ghostel--create buffer-name))
            (with-current-buffer buf
              ;; Adopt the buffer as `ghostel--start' would: claim the
              ;; name for title tracking and carry over the saved
              ;; identity, which `ghostel-project' and friends match on.
              (setq ghostel--managed-buffer-name (buffer-name)
                    ghostel--initial-name (buffer-name)
                    ghostel-identity identity)
              (ghostel--start-process)
              (ghostel--apply-initial-input-mode))
            buf)
        ;; Kill the half-initialized buffer and re-signal so
        ;; `desktop-read' logs "Desktop: Can't load buffer".
        ((error quit)
         (when (buffer-live-p buf) (kill-buffer buf))
         (signal (car err) (cdr err))))))))

(defun ghostel-desktop--shield-replay (buf)
  "Undo, from a timer, the desktop state replay on restored terminal BUF.
After the handler returns, `desktop-create-buffer' replays the desktop
file's saved point, mark, and `buffer-read-only' onto BUF; a saved
active mark runs `activate-mark', flipping semi-char into copy mode.
Those belong to the live terminal, not the desktop file."
  (let ((mode (buffer-local-value 'ghostel--input-mode buf))
        (had-region (with-current-buffer buf (region-active-p))))
    (run-at-time 0 nil #'ghostel-desktop--undo-replay buf mode had-region)))

(defun ghostel-desktop--undo-replay (buf mode had-region)
  "Reset BUF's replayed mark, input mode, and read-only state.
MODE and HAD-REGION are BUF's input mode and region state from before
the desktop replay."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (unless had-region (deactivate-mark))
      (when (and (memq ghostel--input-mode '(copy emacs))
                 (not (memq mode '(copy emacs))))
        (ghostel-readonly-exit))
      (ghostel--sync-read-only))))

(provide 'ghostel-desktop)
;;; ghostel-desktop.el ends here
