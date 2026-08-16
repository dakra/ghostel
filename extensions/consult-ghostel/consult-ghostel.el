;;; consult-ghostel.el --- Consult integration for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.50.0
;; Package-Requires: ((emacs "28.1") (consult "1.5") (ghostel "0.50.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Pick a ghostel buffer through `consult', so moving through the
;; candidate list previews each ghostel buffer in the target window.
;; Ghostel's own `ghostel-list-buffers' / `ghostel-project-list-buffers'
;; route through `read-buffer', which has no preview.
;;
;;   `consult-ghostel'          all ghostel buffers
;;   `consult-ghostel-project'  ghostel buffers in this project
;;
;; Candidates are ordered for switching (recently-used first, current
;; buffer last) and annotated with the terminal title, and submitting a
;; name that matches no buffer creates a new ghostel terminal with that
;; name (reach-or-create, like `consult-buffer's create-on-miss).
;; With a prefix argument the buffer pickers behave like `ghostel' /
;; `ghostel-project' instead (C-u creates a new terminal); a "New"
;; group inside the picker offers the same default-named creation.
;; When marginalia is installed, the title is prepended to marginalia's
;; buffer annotations instead, in every buffer prompt.
;;
;; Loading also registers hidden sources in `consult-buffer' and
;; `consult-project-buffer': ghostel buffers already appear in the
;; default "Buffer" view, so they stay invisible there until the `g'
;; narrow key summons them exclusively.  Opt out with:
;;
;;   (setq consult-buffer-sources
;;         (delq 'consult-ghostel-source-hidden consult-buffer-sources))
;;
;; Loading this package also makes `consult-line' match across soft
;; line wraps in ghostel buffers: rows joined by wrap newlines become
;; one candidate.
;;
;; Enable by adding to your init:
;;
;;   (use-package consult-ghostel
;;     :after (ghostel consult)
;;     :demand t
;;     :bind (:map ghostel-semi-char-mode-map
;;            ("C-c M" . consult-ghostel-project)))

;;; Code:

(require 'cl-lib)
(require 'consult)
(require 'ghostel)
(require 'marginalia nil 'noerror)

(defvar consult-ghostel-history nil
  "Minibuffer history for the `consult-ghostel' commands.")

(defun consult-ghostel--pairs (buffers)
  "Return `consult' (name . buffer) pairs for BUFFERS, switch-ordered.
Runs BUFFERS through `consult--buffer-query', so consult's visibility
order (recently-used first, current buffer last),
`consult-buffer-list-function', and `consult-buffer-filter' all apply."
  (consult--buffer-query :sort 'visibility
                         :predicate (lambda (buf) (memq buf buffers))
                         :as #'consult--buffer-pair))

(defvar consult-ghostel-source
  `( :name     "Ghostel"
     :narrow   ?g
     :category buffer
     :face     consult-buffer
     :history  buffer-name-history
     :annotate ,#'ghostel-annotate-buffer
     :state    ,#'consult--buffer-state
     :new      ,#'consult-ghostel--spawn
     :items    ,(lambda () (consult-ghostel--pairs (ghostel-buffer-list))))
  "`consult' source for all ghostel buffers.")

(defvar consult-ghostel-project-source
  `( :name     "Ghostel (Project)"
     :narrow   ?g
     :category buffer
     :face     consult-buffer
     :history  buffer-name-history
     :annotate ,#'ghostel-annotate-buffer
     :state    ,#'consult--buffer-state
     ;; Resolve the project through consult so the source agrees with
     ;; `consult-project-function'.
     :enabled  ,(lambda () (consult--project-root))
     :new      ,(lambda (name)
                  ;; Allocate in `ghostel-project's own slot family, so
                  ;; the new terminal is exactly the buffer `ghostel-project'
                  ;; finds and reuses; NAME only names the buffer.
                  (let ((default-directory (consult--project-root t)))
                    (if (member name '(nil ""))
                        (ghostel-project t)
                      (let* ((context `((kind . term)
                                        (project-root
                                         . ,(ghostel--normalize-root
                                             default-directory))))
                             (next-instance (ghostel--next-instance context))
                             (identity
                              `(,@context (instance . ,next-instance))))
                        (consult-ghostel--spawn name identity)))))
     :items    ,(lambda ()
                  ;; The `project-current' check keeps
                  ;; `ghostel-project-buffer-list' from prompting for a
                  ;; project when project.el finds none under the root
                  ;; (e.g. a projectile-only project).
                  (when-let* ((default-directory (consult--project-root))
                              ((project-current)))
                    (consult-ghostel--pairs (ghostel-project-buffer-list)))))
  "`consult' source for ghostel buffers in the current project.
Project membership is determined by `ghostel-project-buffer-scope'.")

(defvar consult-ghostel-source-new
  `( :name     "New"
     :narrow   ?n
     :category ghostel-new
     :face     font-lock-constant-face
     :action   ,(lambda (_) (ghostel t))
     :items    ("Create a new Ghostel terminal"))
  "`consult' source offering creation of a default-named terminal.
Selecting the candidate behaves like \\[universal-argument] `ghostel'.")

(defvar consult-ghostel-project-source-new
  `( :name     "New"
     :narrow   ?n
     :category ghostel-new
     :face     font-lock-constant-face
     :enabled  ,(lambda () (consult--project-root))
     :action   ,(lambda (_) (ghostel-project t))
     :items    ("Create a new project Ghostel terminal"))
  "`consult' source offering creation of a project terminal.
Selecting the candidate behaves like \\[universal-argument] `ghostel-project'.")

;; `copy-sequence', or the spliced tail would be shared structure and
;; `consult-customize' on one variable would mutate the other.
(defvar consult-ghostel-source-hidden
  `(:hidden t :narrow (?g . "Ghostel") ,@(copy-sequence consult-ghostel-source))
  "Like `consult-ghostel-source' but hidden by default.
Registered in `consult-buffer-sources' at load: ghostel buffers stay
in the default \"Buffer\" view and the `g' narrow key summons them
exclusively.")

(defvar consult-ghostel-project-source-hidden
  `( :hidden t :narrow (?g . "Ghostel")
     ,@(copy-sequence consult-ghostel-project-source))
  "Like `consult-ghostel-project-source' but hidden by default.
Registered in `consult-project-buffer-sources' at load.")

(add-to-list 'consult-buffer-sources 'consult-ghostel-source-hidden t)
(add-to-list 'consult-project-buffer-sources
             'consult-ghostel-project-source-hidden t)

(defun consult-ghostel--display (buffer &optional norecord)
  "Pop to BUFFER like ghostel's own buffer commands.
Uses the same-window action under the `comint' display category so
`display-buffer-alist' rules match `ghostel-list-buffers'.  NORECORD is
passed through to `pop-to-buffer'."
  (pop-to-buffer buffer
                 (append display-buffer--same-window-action
                         '((category . comint)))
                 norecord))

(defun consult-ghostel--spawn (name &optional identity)
  "Create and display a new ghostel terminal named NAME in `default-directory'.
Displays through `consult--buffer-display', so the other-window/-frame
variants of `consult-buffer' place a created terminal like a picked
one.  IDENTITY is passed through to `ghostel-create'."
  (funcall consult--buffer-display (ghostel-create name nil identity)))

(defun consult-ghostel--switch (sources prompt)
  "Pick a ghostel buffer from SOURCES via `consult--multi' with PROMPT.
Previews candidates; a non-matching name creates a new terminal via the
first source's `:new' handler."
  (let ((consult--buffer-display #'consult-ghostel--display))
    (consult--multi sources
                    :require-match (confirm-nonexistent-file-or-buffer)
                    :prompt prompt
                    :history 'consult-ghostel-history
                    :sort nil)))

;;;###autoload
(defun consult-ghostel (&optional arg)
  "Switch to a ghostel buffer, previewing candidates.
Submitting a name that matches no buffer creates a new ghostel
terminal; the \"New\" candidate creates one with the default name.
With prefix ARG, behave like `ghostel' called with ARG instead
\(\\[universal-argument] creates a new terminal, a numeric arg picks
that numbered terminal)."
  (interactive "P")
  (if arg
      (ghostel arg)
    (consult-ghostel--switch
     '(consult-ghostel-source consult-ghostel-source-new)
     "Ghostel buffer: ")))

;;;###autoload
(defun consult-ghostel-project (&optional arg)
  "Switch to a ghostel buffer in the current project, previewing candidates.
Submitting a name that matches no buffer creates a new ghostel terminal
rooted at the project; the \"New\" candidate creates one with the
default name.  With prefix ARG, behave like `ghostel-project' called
with ARG.  Project membership is determined by
`ghostel-project-buffer-scope'."
  (interactive "P")
  (if arg
      (ghostel-project arg)
    ;; The source's `:enabled' guard is not enough: `consult--multi' with
    ;; zero enabled sources still opens an (empty) picker and errors on
    ;; submit, so refuse before entering the minibuffer.
    (unless (consult--project-root)
      (user-error "No current project"))
    (consult-ghostel--switch
     '(consult-ghostel-project-source consult-ghostel-project-source-new)
     "Project ghostel buffer: ")))

;;; Marginalia integration

;; Keep the byte-compile clean when marginalia is not installed.
(declare-function marginalia-annotate-buffer "marginalia" (cand))
(defvar marginalia-annotators)

(defun consult-ghostel-marginalia-annotate (cand)
  "Annotate buffer CAND like marginalia, prefixed with the terminal title."
  (concat (when-let* ((annotation (ghostel-annotate-buffer cand)))
            (propertize annotation 'face 'marginalia-value))
          (marginalia-annotate-buffer cand)))

;; The registry variable gates the registration: `marginalia-annotators'
;; only exists since marginalia 2.1.
(when (boundp 'marginalia-annotators)
  ;; Marginalia's own `buffer' annotator takes precedence over the
  ;; sources' `:annotate', hiding the title, so prepend the title
  ;; through marginalia's annotator registry instead.
  (dolist (category '(buffer project-buffer))
    (cl-pushnew #'consult-ghostel-marginalia-annotate
                (alist-get category marginalia-annotators))))

;;; consult-line over logical lines

(defun consult-ghostel--line-candidates (orig top curr-line)
  "Build consult-line candidates from logical lines in ghostel buffers.
Rows joined by wrap newlines become one candidate with the newlines
spliced out, so matching works across soft wraps.  Outside ghostel
buffers, call ORIG with TOP and CURR-LINE unchanged."
  (if (not (derived-mode-p 'ghostel-mode))
      (funcall orig top curr-line)
    (let ((buffer (current-buffer))
          (line (line-number-at-pos (point-min) consult-line-numbers-widen))
          default-cand candidates)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          ;; Core's helpers define the logical line (including the row
          ;; cap), so consult-line agrees with the link scanner and
          ;; `consult-ghostel--wrap-corrected-dest'.
          (let* ((beg (point))
                 (end (ghostel--soft-wrap-line-end
                       beg ghostel--soft-wrap-row-limit))
                 ;; `count-lines' skips the final row when END sits at
                 ;; a beginning of line (empty continuation row), which
                 ;; would drift the line counter.
                 (rows (max 1 (+ (count-lines beg end)
                                 (if (and (> end beg)
                                          (save-excursion (goto-char end)
                                                          (bolp)))
                                     1
                                   0))))
                 (str (car (ghostel--wrap-joined-region
                            beg end ghostel--soft-wrap-row-limit))))
            (unless (string-match-p "\\`[ \t]*\\'" str)
              ;; The property gates the point-placement advice: only
              ;; candidates built here are wrap-joined.
              (push (propertize
                     (consult--location-candidate str (cons buffer beg)
                                                  line line)
                     'consult-ghostel--joined t)
                    candidates)
              ;; Default to the logical line CONTAINING curr-line: its
              ;; first row may be above point when point sits on a
              ;; continuation row.
              (when (and (not default-cand) (> (+ line rows) curr-line))
                (setq default-cand candidates)))
            (setq line (+ line rows))
            (goto-char (min (1+ end) (point-max))))))
      (unless candidates
        (user-error "No lines"))
      (nreverse
       (if (or top (not default-cand))
           candidates
         (let ((before (cdr default-cand)))
           (setcdr default-cand nil)
           (nconc before candidates)))))))

(advice-add 'consult--line-candidates :around
            #'consult-ghostel--line-candidates)

(defun consult-ghostel--wrap-corrected-dest (pos offset)
  "Return the buffer position for OFFSET into POS's wrap-joined line.
The candidate string has the wrap newlines spliced out while the
buffer still contains them; core's chunk map translates between the
two.  An offset at a row boundary lands past the wrap newline, on
the match itself."
  (with-current-buffer (if (markerp pos) (marker-buffer pos) (current-buffer))
    (let* ((end (ghostel--soft-wrap-line-end
                 pos ghostel--soft-wrap-row-limit))
           (chunks (cdr (ghostel--wrap-joined-region
                         pos end ghostel--soft-wrap-row-limit))))
      ;; No chunks to map through when the buffer shrank under the
      ;; candidate (eviction, screen clear) and POS clamped to
      ;; `point-max'; land on POS rather than crashing the jump.
      (or (ghostel--wrap-offset-to-pos offset chunks) pos))))

(defun consult-ghostel--line-point-placement
    (orig selected candidates highlighted &rest ignored-faces)
  "Place point correctly on wrap-joined ghostel candidates.
consult computes the destination as buffer position + offset in the
candidate string; with the wrap newlines spliced out of the string
that arithmetic lands short past every wrap boundary, so map through
the wrap chunks instead.  For candidates without the wrap-joined
property (`consult-line-multi' candidates are per-row even in ghostel
buffers) call ORIG unchanged.  SELECTED, CANDIDATES, HIGHLIGHTED, and
IGNORED-FACES are as for `consult--line-point-placement'."
  (let* ((pos (and highlighted (consult--lookup-location selected candidates)))
         (buf (cond ((markerp pos) (marker-buffer pos))
                    (pos (current-buffer)))))
    (if (not (and buf (buffer-live-p buf)
                  (get-text-property 0 'consult-ghostel--joined
                                     (car candidates))))
        (apply orig selected candidates highlighted ignored-faces)
      (let* ((matches (apply #'consult--point-placement highlighted 0
                             ignored-faces))
             (dest (consult-ghostel--wrap-corrected-dest pos (car matches))))
        (when (and (markerp pos) (not (eq buf (current-buffer))))
          (setq dest (move-marker (make-marker) dest buf)))
        (cons dest (cdr matches))))))

(advice-add 'consult--line-point-placement :around
            #'consult-ghostel--line-point-placement)

(provide 'consult-ghostel)
;;; consult-ghostel.el ends here
