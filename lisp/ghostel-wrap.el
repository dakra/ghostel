;;; ghostel-wrap.el --- Logical lines over soft-wrapped rows -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Terminal rows that soft-wrap are separate buffer lines joined by a
;; newline carrying the `ghostel-wrap' text property.  This file makes
;; those rows behave as one logical line for the operations where the
;; physical newline would leak: copying and searching.
;;
;; Copying: `ghostel--filter-buffer-substring' (installed as the
;; buffer-local `filter-buffer-substring-function') splices wrap
;; newlines out of killed text and strips trailing whitespace, so the
;; kill ring receives the original terminal content.
;;
;; Searching: the renderer gives wrap newlines expression-prefix
;; syntax (class 6) via the `syntax-table' text property, and
;; `ghostel-mode' enables `parse-sexp-lookup-properties'.  No other
;; character in a ghostel buffer has that class, so the regexp atom
;; \\s' matches exactly the wrap newlines: a literal search string
;; compiled with `ghostel--wrap-tolerant-regexp' matches across soft
;; wraps but can never cross a hard newline.  Integrations: isearch
;; (buffer-local `isearch-search-fun-function', installed by
;; `ghostel-mode') and the occur family (advice on `occur-1' and on
;; `isearch-occur', which quotes the search string before occur sees
;; it).  Both advices are global and live for the session, gated on
;; their targets being ghostel buffers.  Char-folded isearch composes
;; with the transform; word and symbol search, regexp search,
;; query-replace, `how-many', hi-lock, and third-party tools with
;; private search loops are not covered.
;;
;; Two side effects of `parse-sexp-lookup-properties': a wrap newline
;; reports expression-prefix rather than whitespace syntax, so `\\s-'
;; no longer matches one, and `forward-sexp' treats the rows it joins
;; as one expression.

;;; Code:

(require 'seq)
(require 'subr-x)


;;; Copying

(defun ghostel--filter-soft-wraps (text)
  "Remove newlines from TEXT that were inserted by soft line wrapping.
These are newlines with the `ghostel-wrap' text property."
  (let ((chunks nil)
        (chunk-start 0)
        (pos 0)
        (len (length text)))
    (while (< pos len)
      (when (and (eq (aref text pos) ?\n)
                 (get-text-property pos 'ghostel-wrap text))
        (when (< chunk-start pos)
          (push (substring text chunk-start pos) chunks))
        (setq chunk-start (1+ pos)))
      (setq pos (1+ pos)))
    (when (< chunk-start len)
      (push (substring text chunk-start len) chunks))
    (string-join (nreverse chunks))))

(defun ghostel--clean-copy-text (text)
  "Clean TEXT for copying: remove soft-wrap newlines, strip trailing whitespace."
  (let* ((unwrapped (ghostel--filter-soft-wraps text))
         (lines (split-string unwrapped "\n"))
         (trimmed (mapcar (lambda (line) (string-trim-right line)) lines)))
    (mapconcat #'identity trimmed "\n")))

(defun ghostel--filter-buffer-substring (beg end delete)
  "Filter Ghostel buffer text between BEG and END for copying.
DELETE has the same meaning as in `filter-buffer-substring'."
  (ghostel--clean-copy-text
   (funcall (default-value 'filter-buffer-substring-function) beg end delete)))


;;; Wrap-tolerant regexps

(defun ghostel--wrap-literal-safe-p (string)
  "Return non-nil if STRING is a regexp matching only itself literally.
Transformed regexps contain backslashes, so they fail this test;
that makes it double as a guard against double transformation."
  (string= (regexp-quote string) string))

(defun ghostel--wrap-atoms (string)
  "Split STRING into the units a wrap newline may fall between.
Each unit is one character, except that a run of spaces stays whole:
`search-spaces-regexp' and `char-fold-to-regexp' both collapse such a
run into a single whitespace matcher, and splitting it would instead
demand one run of whitespace per space."
  (let ((atoms nil)
        (pos 0)
        (len (length string)))
    (while (< pos len)
      (let ((start pos))
        (if (eq (aref string pos) ?\s)
            (while (and (< pos len) (eq (aref string pos) ?\s))
              (setq pos (1+ pos)))
          (setq pos (1+ pos)))
        (push (substring string start pos) atoms)))
    (nreverse atoms)))

(defun ghostel--wrap-tolerant-regexp (string)
  "Return a regexp matching literal STRING across soft-wrapped rows.
An optional wrap newline (syntax class 6, regexp atom \\s\\=') is
permitted between any two units of STRING, see `ghostel--wrap-atoms'."
  (mapconcat #'regexp-quote (ghostel--wrap-atoms string) "\\s'?"))

(defun ghostel--wrap-tolerant-char-fold-regexp (string &optional lax)
  "Return a char-folded regexp for STRING that also crosses soft-wrapped rows.
LAX is passed to `char-fold-to-regexp'.  The first alternative folds
STRING as a whole, keeping folds that span several characters such as
ligatures; the second folds each unit separately so a wrap newline may
sit between them."
  (concat "\\(?:" (char-fold-to-regexp string lax) "\\|"
          (mapconcat #'char-fold-to-regexp (ghostel--wrap-atoms string) "\\s'?")
          "\\)"))


;;; isearch

(defun ghostel--isearch-search-fun ()
  "Return an isearch search function tolerant of soft wraps.
Literal searches and char-folded ones (`search-default-mode' set to
`char-fold-to-regexp') match across soft-wrapped rows.  Regexp, word and
symbol searches use the default isearch behavior."
  (let ((default (isearch-search-fun-default)))
    (lambda (string &optional bound noerror count)
      (if (or isearch-regexp
              (and isearch-regexp-function
                   (not (eq isearch-regexp-function #'char-fold-to-regexp))))
          (funcall default string bound noerror count)
        ;; Both bindings in one `let': the regexp must be built before
        ;; `search-spaces-regexp' takes effect, which is also why
        ;; `isearch-search-fun-default' computes it in this order.
        (let ((regexp
               (if isearch-regexp-function
                   (let ((lax (and (not bound) ; not lazy-highlight
                                   (isearch--lax-regexp-function-p))))
                     (when lax (setq isearch-adjusted 'lax))
                     (ghostel--wrap-tolerant-char-fold-regexp string lax))
                 (ghostel--wrap-tolerant-regexp string)))
              (search-spaces-regexp (and isearch-lax-whitespace
                                         search-whitespace-regexp)))
          (funcall (if isearch-forward #'re-search-forward #'re-search-backward)
                   regexp bound noerror count))))))


;;; occur

(defun ghostel--occur-buffer-p (buffer-or-overlay)
  "Return non-nil if BUFFER-OR-OVERLAY denotes a live ghostel buffer."
  (let ((buf (cond ((overlayp buffer-or-overlay)
                    (overlay-buffer buffer-or-overlay))
                   ((bufferp buffer-or-overlay) buffer-or-overlay)
                   ((stringp buffer-or-overlay)
                    (get-buffer buffer-or-overlay)))))
    (and (buffer-live-p buf)
         (with-current-buffer buf (derived-mode-p 'ghostel-mode)))))

(defun ghostel--occur-wrap-args (args)
  "Make a literal `occur-1' regexp in ARGS tolerant of soft wraps.
Only applies when every target buffer is a ghostel buffer.
The original string is kept as the `isearch-string' property so occur
displays it instead of the transformed regexp."
  (pcase-let ((`(,regexp ,nlines ,bufs . ,rest) args))
    (if (and (stringp regexp)
             (ghostel--wrap-literal-safe-p regexp)
             bufs
             (seq-every-p #'ghostel--occur-buffer-p bufs))
        `(,(propertize (ghostel--wrap-tolerant-regexp regexp)
                       'isearch-string (substring-no-properties regexp))
          ,nlines ,bufs . ,rest)
      args)))

(advice-add 'occur-1 :filter-args #'ghostel--occur-wrap-args)

(defun ghostel--isearch-occur-wrap-args (args)
  "Make the regexp `isearch-occur' built in ARGS tolerant of soft wraps.
`isearch-occur' quotes or folds `isearch-string' itself, and the result
no longer looks literal to `ghostel--occur-wrap-args'.  Only a regexp
that isearch would have produced from the current `isearch-string' is
replaced, so a caller passing its own regexp is left alone."
  (pcase-let ((`(,regexp . ,rest) args))
    (if-let* (((stringp regexp))
              ((derived-mode-p 'ghostel-mode))
              ((not (string-empty-p isearch-string)))
              (rebuilt
               (cond
                ((and (eq isearch-regexp-function #'char-fold-to-regexp)
                      (equal regexp (char-fold-to-regexp isearch-string)))
                 (ghostel--wrap-tolerant-char-fold-regexp isearch-string))
                ((and (not isearch-regexp)
                      (not isearch-regexp-function)
                      (equal regexp (regexp-quote isearch-string)))
                 (ghostel--wrap-tolerant-regexp isearch-string)))))
        (cons (propertize rebuilt 'isearch-string
                          (substring-no-properties isearch-string))
              rest)
      args)))

(advice-add 'isearch-occur :filter-args #'ghostel--isearch-occur-wrap-args)

(provide 'ghostel-wrap)
;;; ghostel-wrap.el ends here
