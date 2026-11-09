;;; ghostel-project.el --- Project-scoped ghostel terminals -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `ghostel-project' opens a terminal in the current project's root and
;; the `ghostel-project-*' commands cycle and pick among a project's
;; terminals.  Project membership is governed by
;; `ghostel-project-buffer-scope'.
;;
;;   (add-to-list 'project-switch-commands '(ghostel-project "Ghostel") t)
;;
;; `project-kill-buffers' leaves ghostel buffers alone unless they are
;; among its conditions:
;;
;;   (add-to-list 'project-kill-buffer-conditions '(derived-mode . ghostel-mode))

;;; Code:

(require 'cl-lib)
(require 'ghostel)
(require 'project)

(defcustom ghostel-project-buffer-scope 'both
  "How `ghostel-project-next', `-previous', and `-list-buffers' scope buffers.
Controls which ghostel buffers are considered part of the current project:
- `default-directory': match each buffer's `default-directory'
  against the current project root.  Follows shell `cd'.
  A terminal that walked out of the project is excluded; a plain
  `ghostel' buffer that cd'd into the project is included.
- `identity': match each buffer's `ghostel-identity' against the
  current project root, for interactive terminals only.
  Stable across `cd', but only finds buffers originally
  created via `ghostel-project'.
- `both' (default): union of the two - `default-directory' first,
  then identity-matched buffers not already covered."
  :type '(choice (const :tag "Match by buffer default-directory" default-directory)
                 (const :tag "Match by creation-time project identity" identity)
                 (const :tag "Both (union)" both))
  :group 'ghostel)

(defun ghostel--project-buffer-name (root)
  "Return the project-prefixed ghostel buffer name for project ROOT.
For remote ROOTs the TRAMP prefix is folded into the name so a local
and a remote project with the same name get distinct buffers."
  (let ((name (project-prefixed-buffer-name
               (string-trim ghostel-buffer-name "*" "*")))
        (remote (file-remote-p root)))
    (if remote
        (format "%s@%s*" (substring name 0 -1)
                (string-trim remote "/" ":"))
      name)))

;;;###autoload
(defun ghostel-project (&optional arg)
  "Start a new Ghostel terminal in the current project's root.
The buffer name is prefixed with the project name; remote (TRAMP) projects also
carry the remote host, to distinguish equally named local and remote projects.
If a buffer already exists for this project, switch to it.
Otherwise create a new Ghostel buffer.  ARG is passed through to
`ghostel' and accepts the same universal argument conventions.
To add this to `project-switch-commands':
  (add-to-list \\='project-switch-commands \\='(ghostel-project \"Ghostel\") t)
Returns the buffer."
  (interactive "P")
  (let ((default-directory (project-root (project-current t))))
    (ghostel--start `((kind . term)
                      (project-root . ,(ghostel--normalize-root
                                        default-directory)))
                    (ghostel--project-buffer-name default-directory)
                    arg)))

;;;###autoload
(defun ghostel-project-new ()
  "Create a new Ghostel terminal in the current project's root.
Like \\[universal-argument] `ghostel-project'.  Returns the buffer."
  (interactive)
  (ghostel-project t))

;;;###autoload
(defun ghostel-project-buffer-list ()
  "Return ghostel buffers belonging to the current project, sorted by name.
Scoping is controlled by `ghostel-project-buffer-scope'.
Prompts to choose a project when there is none.

Buffers whose `default-directory' is remote are skipped in the
`default-directory' scope branch; querying `project-current' against a TRAMP
path would walk the remote filesystem synchronously on every cycle."
  (let* ((proj (project-current t))
         (root (project-root proj))
         (scope ghostel-project-buffer-scope)
         (all (ghostel-buffer-list))
         (by-dir
          (and (memq scope '(default-directory both))
               (cl-remove-if-not
                (lambda (b)
                  (let ((bd (buffer-local-value 'default-directory b)))
                    (and bd
                         (not (file-remote-p bd))
                         (ignore-errors
                           (let ((bp (project-current nil bd)))
                             (and bp (equal (project-root bp) root)))))))
                all)))
         (by-id
          (and (memq scope '(identity both))
               (let ((pattern `((kind . term)
                                (project-root . ,(ghostel--normalize-root
                                                  root)))))
                 (cl-remove-if-not
                  (lambda (b)
                    (ghostel-identity-match-p
                     pattern (buffer-local-value 'ghostel-identity b)))
                  all)))))
    (sort (cl-delete-duplicates (append by-dir by-id) :test #'eq)
          (lambda (a b) (string< (buffer-name a) (buffer-name b))))))

;;;###autoload
(defun ghostel-project-next ()
  "Switch to the next ghostel buffer in the current project (wraps around).
Project membership is determined by `ghostel-project-buffer-scope'."
  (interactive)
  (ghostel--cycle (ghostel-project-buffer-list) +1
                  "No ghostel buffers in this project"
                  "Only one ghostel buffer in this project"))

;;;###autoload
(defun ghostel-project-previous ()
  "Switch to the previous ghostel buffer in the current project (wraps around).
Project membership is determined by `ghostel-project-buffer-scope'."
  (interactive)
  (ghostel--cycle (ghostel-project-buffer-list) -1
                  "No ghostel buffers in this project"
                  "Only one ghostel buffer in this project"))

;;;###autoload
(defun ghostel-project-list-buffers ()
  "Pick a ghostel buffer in the current project via `read-buffer'.
Project membership is determined by `ghostel-project-buffer-scope'."
  (interactive)
  (pop-to-buffer (ghostel--read-buffer "Project ghostel buffer: "
                                       (ghostel-project-buffer-list))
                 (append display-buffer--same-window-action
                         '((category . comint)))))

(provide 'ghostel-project)

;;; ghostel-project.el ends here
