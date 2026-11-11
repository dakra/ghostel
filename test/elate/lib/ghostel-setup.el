;;; ghostel-setup.el --- Shared elate startup for plain-ghostel scenarios -*- lexical-binding: t; -*-

;; Loaded from a scenario's session.eval:
;;   (load ".../test/elate/lib/ghostel-setup.el")
;; Sets up ghostel from THIS checkout (self-locating) without evil.

;;; Code:

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name "../../../" here)))
  (add-to-list 'load-path (expand-file-name "lisp" repo)))

(require 'ghostel)

;; macOS `login(1)' would reset HOME/SHELL from the passwd DB, ignoring the
;; elate sandbox HOME; disable it so the sandbox stays isolated.  VC probing
;; can hang a sandboxed GUI Emacs on "Waiting for git".
(setq ghostel-macos-login-shell nil
      ring-bell-function 'ignore
      vc-handled-backends nil)

(when-let* ((sh (getenv "ELATE_GHOSTEL_SHELL")))
  (setq ghostel-shell sh))

(defun ghostel-elate--vt (string &optional sentinel)
  "Feed STRING to the terminal as raw bytes, bypassing the line editor.
With SENTINEL, echo it afterwards so a `wait text' step can synchronise on it."
  (let ((file (expand-file-name "elate-vt" (or (getenv "ELATE_SCRATCH")
                                               temporary-file-directory)))
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert string))
    (ghostel-send-string
     (format "cat %s%s\n" (shell-quote-argument file)
             (if sentinel (format "; echo %s" sentinel) "")))))

(defun ghostel-elate--kitty-cells ()
  "Return (LINE . COL) for every kitty image slice in the current buffer.
Covers both the text-property and the overlay display paths.  Lines are
1-based, columns 0-based."
  (let (cells)
    (save-excursion
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (when (and (get-text-property pos 'ghostel-kitty)
                     (get-text-property pos 'display))
            (goto-char pos)
            (push (cons (line-number-at-pos) (current-column)) cells))
          (setq pos (next-single-property-change pos 'display nil (point-max)))))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (overlay-get ov 'ghostel-kitty)
          (goto-char (overlay-start ov))
          (push (cons (line-number-at-pos) (current-column)) cells))))
    (sort (delete-dups cells)
          (lambda (a b) (or (< (car a) (car b))
                            (and (= (car a) (car b)) (< (cdr a) (cdr b))))))))

(defun ghostel-elate--kitty-slices ()
  "Return (DLINE COL X W) per kitty slice, in cells, relative to the first.
DLINE is the line offset from the first slice's line; X and W are the
slice's x-origin and width in the image divided by the cell width."
  (let ((cw (default-font-width)) (base nil) slices)
    (dolist (cell (ghostel-elate--kitty-cells))
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- (car cell)))
        (move-to-column (cdr cell))
        (let* ((ov (seq-find (lambda (o) (overlay-get o 'ghostel-kitty))
                             (overlays-in (point) (point))))
               (spec (if ov
                         (get-text-property 0 'display (overlay-get ov 'before-string))
                       (get-text-property (point) 'display)))
               (slice (car spec)))
          (unless base (setq base (car cell)))
          (push (list (- (car cell) base) (cdr cell)
                      (/ (nth 1 slice) cw) (/ (nth 3 slice) cw))
                slices))))
    (nreverse slices)))

(defun ghostel-elate--kitty-data ()
  "Return the distinct PPM `:data' strings of the kitty slices, in cell order."
  (let (data)
    (dolist (cell (ghostel-elate--kitty-cells))
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- (car cell)))
        (move-to-column (cdr cell))
        (let* ((ov (seq-find (lambda (o) (overlay-get o 'ghostel-kitty))
                             (overlays-in (point) (point))))
               (spec (if ov
                         (get-text-property 0 'display (overlay-get ov 'before-string))
                       (get-text-property (point) 'display))))
          (push (image-property (nth 1 spec) :data) data))))
    (delete-dups (nreverse data))))

(defun ghostel-elate--line-wrap-columns ()
  "Return the columns where line mode breaks the input, in order."
  (sort (mapcar (lambda (ov)
                  (save-excursion (goto-char (overlay-end ov))
                                  (current-column)))
                (seq-filter (lambda (ov) (overlay-get ov 'ghostel-line-wrap))
                            (overlays-in (point-min) (point-max))))
        #'<))

(defun ghostel-elate--screen-row (pos)
  "Return the window row POS is displayed on in a TTY frame, nil if out of view."
  (nth 1 (pos-visible-in-window-p pos nil t)))

(defun ghostel-elate--input-row ()
  "Return the window row the line-mode input starts on."
  (ghostel-elate--screen-row ghostel--line-input-start))

(defun ghostel-elate--has-line (regexp)
  "Non-nil when a whole buffer line matches REGEXP."
  (save-excursion
    (goto-char (point-min))
    (and (re-search-forward (concat "^" regexp "$") nil t) t)))

(defun ghostel-elate--has-text (regexp)
  "Non-nil when REGEXP matches anywhere in the buffer."
  (save-excursion
    (goto-char (point-min))
    (and (re-search-forward regexp nil t) t)))

(defun ghostel-elate--count-lines (regexp)
  "Return the number of whole buffer lines matching REGEXP."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (re-search-forward (concat "^" regexp "$") nil t)
        (setq n (1+ n)))
      n)))

(defun ghostel-elate--in-order-p (&rest regexps)
  "Non-nil when whole buffer lines match REGEXPS in this order."
  (save-excursion
    (goto-char (point-min))
    (cl-every (lambda (re) (re-search-forward (concat "^" re "$") nil t))
              regexps)))

(provide 'ghostel-setup)
;;; ghostel-setup.el ends here
