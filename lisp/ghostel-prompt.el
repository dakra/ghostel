;;; ghostel-prompt.el --- OSC 133 prompt navigation and imenu for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Shell-integration (OSC 133) prompt features for ghostel:
;;
;; - `ghostel--osc133-marker' is the handler the native module funcalls for each
;;   semantic prompt marker (A/B/C/D/P); it tracks prompt positions and fires
;;  `ghostel-command-start-functions' / `ghostel-command-finish-functions'.
;; - `ghostel-next-prompt' / `ghostel-previous-prompt' jump between
;;   prompts (switching to Emacs mode so the terminal keeps running).
;; - imenu integration turns each OSC 133 prompt into an index entry
;;   labelled "<cwd>  <command>".
;;
;; `ghostel.el' requires this file eagerly (the native marker handler
;; must exist before any VT data is processed) and calls
;; `ghostel-imenu-setup' from its mode setup.  The command-lifecycle
;; hooks and state this code drives live in `ghostel.el'; this file only
;; forward-declares them, so the require introduces no cycle.

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'imenu)
(require 'seq)

(declare-function ghostel-emacs-mode "ghostel")
(declare-function ghostel--run-hook-safely "ghostel")
(defvar ghostel--input-mode)
(defvar ghostel--command-running)
(defvar ghostel--prompt-positions)
(defvar ghostel-command-start-functions)
(defvar ghostel-command-finish-functions)


;;; Prompt navigation (OSC 133)

(defun ghostel--osc133-marker (type param)
  "Handle an OSC 133 semantic prompt marker from the Zig module.
TYPE is a single character string: A, B, C, D, or P.
PARAM is the exit status string for type D, or nil.
Note: the `ghostel-prompt' text property is applied by the native
render loop (which queries libghostty's per-row semantic state),
not here.  This handler only tracks prompt positions and exit status."
  (pcase type
    ((or "A" "P")
     ;; Prompt start — record line number.  P is the explicit
     ;; prompt-start marker (no fresh-line side effect); both mark
     ;; a navigable prompt position.
     (push (cons (count-lines (point-min) (point-max)) nil)
           ghostel--prompt-positions))
    ("C"
     ;; Command output start — notify `ghostel-command-start-functions'.
     (ghostel--run-hook-safely 'ghostel-command-start-functions
                               (current-buffer))
     (setq ghostel--command-running t))
    ("D"
     ;; Command finished — store exit status on the most recent entry
     ;; and notify `ghostel-command-finish-functions'.
     (let ((exit (and param (string-to-number param))))
       (when (and ghostel--prompt-positions param)
         (setcdr (car ghostel--prompt-positions) exit))
       (ghostel--run-hook-safely 'ghostel-command-finish-functions
                                 (current-buffer) exit))
     (setq ghostel--command-running nil))))

(defun ghostel--prompt-input-start ()
  "From the start of a `ghostel-prompt' region, move past the prefix.
If `ghostel-input' begins on the same line, point lands at its
start; otherwise point lands just past the prompt-prefix region -
the natural position where the user would begin typing."
  (goto-char (or (next-single-property-change
                  (point) 'ghostel-prompt nil (line-end-position))
                 (line-end-position))))

(defun ghostel--navigate-next-prompt (&optional n)
  "Move point to the start of the Nth next prompt region."
  (let ((pos (point)))
    (dotimes (_ (or n 1))
      ;; First skip past the current prompt region if we're inside one.
      (let ((next (next-single-property-change pos 'ghostel-prompt)))
        (when next
          (if (get-text-property next 'ghostel-prompt)
              ;; Landed on the next prompt.
              (setq pos next)
            ;; In a gap — find the next prompt, or stay put.
            (let ((found (next-single-property-change next 'ghostel-prompt)))
              (when found
                (setq pos found)))))))
    (when (and pos (/= pos (point)))
      (goto-char pos)
      (ghostel--prompt-input-start))))

(defun ghostel--navigate-previous-prompt (&optional n)
  "Move point to the start of the Nth previous prompt region."
  (let ((pos (point)))
    (dotimes (_ (or n 1))
      ;; If inside or on a prompt, first skip backward past it.
      (when (or (get-text-property pos 'ghostel-input)
                (and (> pos (point-min))
                     (get-text-property (1- pos) 'ghostel-input)))
        (setq pos (or (previous-single-property-change pos 'ghostel-input)
                      (point-min))))
      (when (or (get-text-property pos 'ghostel-prompt)
                (and (> pos (point-min))
                     (get-text-property (1- pos) 'ghostel-prompt)))
        (setq pos (or (previous-single-property-change pos 'ghostel-prompt)
                      (point-min))))
      ;; Now search backward for the previous prompt.
      (let ((prev (previous-single-property-change pos 'ghostel-prompt)))
        (cond
         (prev
          (setq pos prev)
          ;; If we landed at the end of a prompt, step to its start.
          (when (get-text-property (max (1- pos) (point-min)) 'ghostel-prompt)
            (setq pos (or (previous-single-property-change pos 'ghostel-prompt)
                          (point-min)))))
         ;; No property change before pos, but a prompt may start at point-min.
         ((and (> pos (point-min))
               (get-text-property (point-min) 'ghostel-prompt))
          (setq pos (point-min))))))
    (when (and pos (/= pos (point)))
      (goto-char pos)
      (ghostel--prompt-input-start))))

(defun ghostel-next-prompt (&optional n)
  "Enter Emacs mode and move to the Nth next prompt.
Emacs mode keeps the terminal running, so you can navigate between
prompts while output continues streaming in."
  (interactive "p")
  (unless (memq ghostel--input-mode '(emacs copy))
    (ghostel-emacs-mode))
  (ghostel--navigate-next-prompt n))

(defun ghostel-previous-prompt (&optional n)
  "Enter Emacs mode and move to the Nth previous prompt.
Emacs mode keeps the terminal running, so you can navigate between
prompts while output continues streaming in."
  (interactive "p")
  (unless (memq ghostel--input-mode '(emacs copy))
    (ghostel-emacs-mode))
  (ghostel--navigate-previous-prompt n))


;;; OSC 133 imenu integration

;; Each OSC 133 prompt becomes an imenu entry.  Label is
;; "<cwd>  <command>"; target is the prompt prefix's start.
;; Composes with `consult-imenu', `imenu-list', evil's `]m'/`[m'.
;;
;; The cwd is captured at OSC 133 'C' (command-start) and pushed
;; onto `ghostel--imenu-cwds', a chronological list (newest-first).
;; Reading `default-directory' lazily at index time would
;; mis-attribute every prior prompt to the *current* cwd after a `cd'.
;;
;; Position-based tracking (text properties or markers) does not
;; survive: the renderer's per-row delete+reinsert wipes ad-hoc
;; text properties on dirty rows, and `eraseBuffer' (resize-cols,
;; force-full redraw, scrollback edge cases) collapses every marker
;; to `point-min'.  Pairing chronological cwds with the
;; `ghostel-prompt' regions in buffer order at index time is robust
;; to both: resize reflows the grid but preserves prompt order;
;; scrollback eviction is detected as (cwd-count > region-count)
;; and the oldest cwds are dropped to realign.

(defvar-local ghostel--imenu-cwds nil
  "Chronological list of cwds for prompts that have had OSC 133 \\='C\\=' fire.
Pushed at command-start time, so newest-first.  Aligned by order
to the `ghostel-prompt' regions in the buffer when the index is
built.")

(defun ghostel--imenu-stamp-cwd (buffer)
  "Record BUFFER's `default-directory' for its most recent submitted command.
Hung off `ghostel-command-start-functions' (OSC 133 \\='C\\=')."
  (with-current-buffer buffer
    (push default-directory ghostel--imenu-cwds)))

(defun ghostel--imenu--collect-prompt-regions ()
  "Return a list of (START . PREFIX-END) for every `ghostel-prompt' region.
Ordered by buffer position (oldest first)."
  (let ((regions nil)
        (pos (point-min))
        (end (point-max)))
    (while (setq pos (text-property-any pos end 'ghostel-prompt t))
      (let ((rend (or (next-single-property-change pos 'ghostel-prompt nil end)
                      end)))
        (push (cons pos rend) regions)
        (setq pos rend)))
    (nreverse regions)))

(defun ghostel--imenu-create-index ()
  "Build an imenu alist of OSC 133 prompts in the current buffer.
Each entry's label is \"<cwd>  <command>\"; cwd is omitted when no
recorded entry aligns with the region (e.g. a still-active prompt
whose \\='C\\=' has not fired).  Empty-command prompts are
skipped.  Labels are truncated to 80 columns."
  (let* ((regions (ghostel--imenu--collect-prompt-regions))
         (cwds (reverse ghostel--imenu-cwds))    ; oldest first
         ;; Scrollback eviction removes prompts from the buffer top
         ;; but leaves cwds in the list.  Drop the oldest cwds so
         ;; the remaining list aligns with the current regions.
         (extra (max 0 (- (length cwds) (length regions))))
         (cwds (nthcdr extra cwds))
         ;; Trim the stored list opportunistically so it doesn't
         ;; grow unboundedly across long sessions.
         (_ (when (> extra 0)
              (setq ghostel--imenu-cwds
                    (seq-take ghostel--imenu-cwds (- (length ghostel--imenu-cwds)
                                                     extra)))))
         (index nil))
    (cl-loop for region in regions
             for cwd = (pop cwds)
             do (let* ((pos (car region))
                       (prompt-end (cdr region))
                       (cmd-end (save-excursion
                                  (goto-char prompt-end)
                                  (line-end-position)))
                       (cmd (string-trim
                             (buffer-substring-no-properties prompt-end cmd-end))))
                  (unless (string-empty-p cmd)
                    (let ((label (if cwd
                                     (format "%s  %s"
                                             (abbreviate-file-name
                                              (directory-file-name cwd))
                                             cmd)
                                   cmd)))
                      (push (cons (truncate-string-to-width label 80 nil nil t)
                                  pos)
                            index)))))
    (nreverse index)))

(defun ghostel--imenu-goto (_name position &rest _)
  "Jump to POSITION, then advance past the prompt prefix.
Switches to Emacs mode first in semi-char/char modes so navigation
stays in scrollback while the terminal continues running.  Line mode
is preserved.  Mirrors the landing position used by
`ghostel-next-prompt'."
  (unless (memq ghostel--input-mode '(emacs line copy))
    (ghostel-emacs-mode))
  (when (or (< position (point-min)) (> position (point-max)))
    (widen))
  (goto-char position)
  (ghostel--prompt-input-start))

(defun ghostel-imenu-setup ()
  "Wire OSC 133 prompts as imenu entries in the current buffer.
Prompt labels include the command and, when known, the command's
working directory."
  (setq-local imenu-create-index-function #'ghostel--imenu-create-index)
  (setq-local imenu-default-goto-function #'ghostel--imenu-goto)
  (add-hook 'ghostel-command-start-functions
            #'ghostel--imenu-stamp-cwd nil t))

(provide 'ghostel-prompt)
;;; ghostel-prompt.el ends here
