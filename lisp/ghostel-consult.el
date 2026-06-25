;;; ghostel-consult.el --- Consult integration for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Pick a ghostel buffer through `consult', so moving through the
;; candidate list previews each ghostel buffer in the target window.
;; Ghostel's own `ghostel-list-buffers' / `ghostel-project-list-buffers'
;; route through `read-buffer', which has no preview.
;;
;;   `ghostel-consult-buffer'          all ghostel buffers
;;   `ghostel-consult-project-buffer'  ghostel buffers in this project
;;
;; Candidates are ordered for switching (recently-used first, current
;; buffer last), and submitting a name that matches no buffer creates a
;; new ghostel terminal with that name (reach-or-create, like
;; `consult-buffer's create-on-miss).
;;
;; The sources are also exposed for the global lists.  Ghostel buffers
;; already appear in `consult-buffer's default "Buffer" source, so use
;; the `-hidden' variants there: they don't duplicate the default view
;; and are summoned via the `g' narrow key.
;;
;;   (with-eval-after-load 'consult
;;     (require 'ghostel-consult)
;;     (add-to-list 'consult-buffer-sources
;;                  'ghostel-consult-source-hidden t)
;;     (add-to-list 'consult-project-buffer-sources
;;                  'ghostel-consult-project-source-hidden t))
;;
;; Enable by adding to your init:
;;
;;   (use-package ghostel-consult
;;     :after (ghostel consult)
;;     :bind (:map ghostel-semi-char-mode-map
;;            ("M" . ghostel-consult-project-buffer)))

;;; Code:

(require 'ghostel)

;; Soft dependency: `consult' is not required at load time (and not a
;; package dependency of ghostel).  The commands `require' it lazily;
;; these declarations keep the byte-compiler quiet without it present.
(defvar consult--buffer-display)
(declare-function consult--multi "consult" (sources &rest options))
(declare-function consult--buffer-pair "consult" (buffer))
(declare-function consult--buffer-state "consult" ())

(defvar ghostel-consult-history nil
  "Minibuffer history for the `ghostel-consult-*' commands.")

(defun ghostel-consult--arrange (buffers)
  "Order BUFFERS for switching: recently-used first, current buffer last.
Visible buffers are grouped just before the current one.  Mirrors
consult's `visibility' buffer sort, but over the given BUFFERS set so
ghostel's own scoping is preserved."
  (let ((current (current-buffer))
        visible rest)
    ;; `buffer-list' is in most-recently-selected-first order; filtering
    ;; it to our set keeps that recency order.
    (dolist (buf (buffer-list))
      (when (memq buf buffers)
        (cond ((eq buf current))            ; appended last, below
              ((get-buffer-window buf 'visible) (push buf visible))
              (t (push buf rest)))))
    (nconc (nreverse rest) (nreverse visible)
           (and (memq current buffers) (list current)))))

(defun ghostel-consult--pairs (buffers)
  "Return `consult' (name . buffer) pairs for BUFFERS, switch-ordered."
  (mapcar #'consult--buffer-pair (ghostel-consult--arrange buffers)))

(defvar ghostel-consult-source
  `( :name     "Ghostel"
     :narrow   ?g
     :category buffer
     :face     consult-buffer
     :history  buffer-name-history
     :state    ,#'consult--buffer-state
     :new      ,(lambda (name) (ghostel-consult--spawn name))
     :items    ,(lambda () (ghostel-consult--pairs (ghostel-buffer-list))))
  "`consult' source for all ghostel buffers.")

(defvar ghostel-consult-project-source
  `( :name     "Ghostel (Project)"
     :narrow   ?g
     :category buffer
     :face     consult-buffer
     :history  buffer-name-history
     :state    ,#'consult--buffer-state
     :enabled  ,(lambda () (project-current nil))
     :new      ,(lambda (name)
                  ;; Root the new terminal at the project so it is recognized
                  ;; as project-scoped via `default-directory'.  Under an
                  ;; `identity'-only `ghostel-project-buffer-scope' it would
                  ;; not match (its identity is NAME, not the project prefix).
                  (let ((default-directory (project-root (project-current t))))
                    (ghostel-consult--spawn name)))
     :items    ,(lambda ()
                  ;; `ghostel-project-buffer-list' signals when there is no
                  ;; current project; `consult' calls `:items' for every
                  ;; enabled source, so guard against erroring.
                  (when (project-current nil)
                    (ghostel-consult--pairs (ghostel-project-buffer-list)))))
  "`consult' source for ghostel buffers in the current project.
Project membership is determined by `ghostel-project-buffer-scope'.")

(defvar ghostel-consult-source-hidden
  `(:hidden t :narrow (?g . "Ghostel") ,@ghostel-consult-source)
  "Like `ghostel-consult-source' but hidden by default.
Add to `consult-buffer-sources' to summon ghostel buffers via `g'
without duplicating them in the default \"Buffer\" source.")

(defvar ghostel-consult-project-source-hidden
  `(:hidden t :narrow (?g . "Ghostel") ,@ghostel-consult-project-source)
  "Like `ghostel-consult-project-source' but hidden by default.
Add to `consult-project-buffer-sources'.")

(defun ghostel-consult--display (buffer &optional norecord)
  "Pop to BUFFER like ghostel's own buffer commands.
Uses the same-window action under the `comint' display category so
`display-buffer-alist' rules match `ghostel-list-buffers'.  NORECORD is
passed through to `pop-to-buffer'."
  (pop-to-buffer buffer
                 (append display-buffer--same-window-action
                         '((category . comint)))
                 norecord))

(defun ghostel-consult--spawn (name)
  "Create and display a new ghostel terminal named NAME in `default-directory'."
  (ghostel-create name (append display-buffer--same-window-action
                               '((category . comint)))))

(defun ghostel-consult--switch (source prompt)
  "Pick a ghostel buffer from SOURCE via `consult--multi' with PROMPT.
Previews candidates; a non-matching name creates a new terminal via the
source's `:new' handler."
  (require 'consult)
  (let ((consult--buffer-display #'ghostel-consult--display))
    (consult--multi (list source)
                    :require-match (confirm-nonexistent-file-or-buffer)
                    :prompt prompt
                    :history 'ghostel-consult-history
                    :sort nil)))

;;;###autoload
(defun ghostel-consult-buffer ()
  "Switch to a ghostel buffer, previewing candidates.
Submitting a name that matches no buffer creates a new ghostel terminal."
  (interactive)
  (ghostel-consult--switch 'ghostel-consult-source "Ghostel buffer: "))

;;;###autoload
(defun ghostel-consult-project-buffer ()
  "Switch to a ghostel buffer in the current project, previewing candidates.
Submitting a name that matches no buffer creates a new ghostel terminal
rooted at the project.  Project membership is determined by
`ghostel-project-buffer-scope'."
  (interactive)
  (ghostel-consult--switch 'ghostel-consult-project-source
                           "Project ghostel buffer: "))

(provide 'ghostel-consult)
;;; ghostel-consult.el ends here
