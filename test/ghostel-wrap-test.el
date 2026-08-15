;;; ghostel-wrap-test.el --- Tests for logical lines over soft wraps -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for treating soft-wrapped rows as logical lines: the copy
;; filters, the wrap-tolerant regexp transform, the isearch search
;; function, the occur integration, and the renderer-stamped
;; wrap-newline properties.

;;; Code:

(require 'ghostel-test-helpers)


;;; Helpers

(defun ghostel-test--insert-soft-wrapped (&rest rows)
  "Insert ROWS joined by newlines propertized like renderer wrap newlines."
  (let ((first t))
    (dolist (row rows)
      (unless first
        (insert (propertize "\n"
                            'ghostel-wrap t
                            'syntax-table (string-to-syntax "'"))))
      (insert row)
      (setq first nil))))

(defmacro ghostel-test--with-wrap-search-buffer (&rest body)
  "Run BODY in a temp buffer set up for wrap-tolerant searching."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (setq-local parse-sexp-lookup-properties t)
     ,@body))


;;; Copying

(ert-deftest ghostel-test-soft-wrap-copy ()
  "Test that soft-wrapped newlines are filtered during copy."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-wrap*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 20 100))
                 (inhibit-read-only t))
            ;; Write a line longer than 20 columns — should soft-wrap
            (ghostel--write-vt term "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "ABCDEFGHIJKLMNOPQRST\n" content))) ; wrapped content has newline
            ;; The newline at the wrap point should have ghostel-wrap property
            (goto-char (point-min))
            (let ((nl-pos (search-forward "\n" nil t)))
              (should nl-pos)                              ; wrap newline exists
              (when nl-pos
                (should (get-text-property (1- nl-pos) 'ghostel-wrap)))) ; ghostel-wrap property set
            ;; Test the filter function
            (let* ((raw (buffer-substring (point-min) (point-max)))
                   (filtered (ghostel--filter-soft-wraps raw)))
              (should-not (string-match-p "\n" (substring filtered 0 26)))))) ; filtered has no wrapped newline
      (kill-buffer buf))))

(ert-deftest ghostel-test-filter-soft-wraps ()
  "Test the soft-wrap filter on synthetic propertized strings."
  ;; String with a wrapped newline
  (let ((s (concat "hello" (propertize "\n" 'ghostel-wrap t) "world")))
    (should (equal "helloworld" (ghostel--filter-soft-wraps s)))) ; removes wrapped newline
  ;; String with a real (non-wrapped) newline
  (let ((s "hello\nworld"))
    (should (equal "hello\nworld" (ghostel--filter-soft-wraps s)))) ; keeps real newline
  ;; Mixed
  (let ((s (concat "aaa" (propertize "\n" 'ghostel-wrap t) "bbb\nccc")))
    (should (equal "aaabbb\nccc" (ghostel--filter-soft-wraps s)))))

(ert-deftest ghostel-test-kill-ring-save-filters-soft-wraps ()
  "Generic copy commands filter renderer-inserted soft-wrap newlines."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil)
        (interprogram-cut-function nil))
    (with-temp-buffer
      (ghostel-mode)
      (let ((inhibit-read-only t))
        (insert "hello")
        (insert (propertize "\n" 'ghostel-wrap t))
        (insert "world   "))
      (kill-ring-save (point-min) (point-max))
      (should (equal (car kill-ring) "helloworld")))))


;;; Regexp transform

(ert-deftest ghostel-test-search-literal-safe-p ()
  "Literal strings pass; regexps and transformed output fail."
  (should (ghostel--wrap-literal-safe-p "foo bar"))
  (should (ghostel--wrap-literal-safe-p "foo]bar}"))
  (should-not (ghostel--wrap-literal-safe-p "f.o"))
  (should-not (ghostel--wrap-literal-safe-p "foo\\|bar"))
  ;; Idempotence guard: our own output is never literal-safe.
  (should-not (ghostel--wrap-literal-safe-p
               (ghostel--wrap-tolerant-regexp "foo"))))

(ert-deftest ghostel-test-search-wrap-tolerant-regexp ()
  "Wrap atoms go between characters; specials are quoted; multibyte works."
  (should (equal (ghostel--wrap-tolerant-regexp "foo")
                 "f\\s'?o\\s'?o"))
  (should (equal (ghostel--wrap-tolerant-regexp "a") "a"))
  (should (equal (ghostel--wrap-tolerant-regexp "") ""))
  (should (equal (ghostel--wrap-tolerant-regexp "a.b")
                 "a\\s'?\\.\\s'?b"))
  (should (equal (ghostel--wrap-tolerant-regexp "añb")
                 "a\\s'?ñ\\s'?b")))


;;; Buffer search behavior

(ert-deftest ghostel-test-search-crosses-soft-wrap ()
  "A transformed literal matches across a wrap newline, both directions."
  (ghostel-test--with-wrap-search-buffer
    (ghostel-test--insert-soft-wrapped "foobarba" "zqux")
    (goto-char (point-min))
    (should (re-search-forward
             (ghostel--wrap-tolerant-regexp "barbazqu") nil t))
    (should (equal (match-string 0) "barba\nzqu"))
    (goto-char (point-max))
    (should (re-search-backward
             (ghostel--wrap-tolerant-regexp "barbazqu") nil t))))

(ert-deftest ghostel-test-search-hard-newline-never-matches ()
  "Unstamped newlines cannot be crossed, with or without property lookup."
  (ghostel-test--with-wrap-search-buffer
    (insert "foobarba\nzqux")
    (goto-char (point-min))
    (should-not (re-search-forward
                 (ghostel--wrap-tolerant-regexp "barbazqu") nil t)))
  ;; Without `parse-sexp-lookup-properties' even stamped newlines
  ;; keep their table syntax, so nothing matches either.
  (with-temp-buffer
    (ghostel-test--insert-soft-wrapped "foobarba" "zqux")
    (goto-char (point-min))
    (should-not (re-search-forward
                 (ghostel--wrap-tolerant-regexp "barbazqu") nil t))))

(ert-deftest ghostel-test-search-space-at-wrap-column ()
  "A search-string space matches a space kept at the wrap column."
  (ghostel-test--with-wrap-search-buffer
    (ghostel-test--insert-soft-wrapped "foo " "bar")
    (goto-char (point-min))
    (should (re-search-forward
             (ghostel--wrap-tolerant-regexp "foo bar") nil t))))


;;; isearch search function

(ert-deftest ghostel-test-search-isearch-fun-literal ()
  "The isearch fun matches wrapped literals forward and backward."
  (ghostel-test--with-wrap-search-buffer
    (ghostel-test--insert-soft-wrapped "foobarba" "zqux")
    (goto-char (point-min))
    (let* ((isearch-forward t)
           (isearch-regexp nil)
           (isearch-regexp-function nil)
           (isearch-lax-whitespace nil)
           (fun (ghostel--isearch-search-fun)))
      (should (funcall fun "barbazqu" nil t))
      (should (equal (match-string 0) "barba\nzqu")))
    (let* ((isearch-forward nil)
           (isearch-regexp nil)
           (isearch-regexp-function nil)
           (isearch-lax-whitespace nil)
           (fun (ghostel--isearch-search-fun)))
      (goto-char (point-max))
      (should (funcall fun "barbazqu" nil t)))))

(ert-deftest ghostel-test-search-isearch-fun-honors-bound-and-count ()
  "BOUND limits the search and COUNT selects the Nth match.
Lazy highlight passes BOUND and \\[universal-argument] 2 \\[isearch-forward] passes COUNT,
so dropping either silently breaks them while plain searching still works."
  (ghostel-test--with-wrap-search-buffer
    (ghostel-test--insert-soft-wrapped "foobarba" "zqux")
    (insert " and barbazqux again")
    (let* ((isearch-forward t)
           (isearch-regexp nil)
           (isearch-regexp-function nil)
           (isearch-lax-whitespace nil)
           (fun (ghostel--isearch-search-fun))
           (first (progn (goto-char (point-min))
                         (funcall fun "barbazqu" nil t))))
      (should first)
      ;; BOUND short of the first match finds nothing, and must not error
      ;; with NOERROR non-nil.
      (goto-char (point-min))
      (should-not (funcall fun "barbazqu" (- first 2) t))
      ;; COUNT 2 reaches the second occurrence.
      (goto-char (point-min))
      (let ((second (funcall fun "barbazqu" nil t 2)))
        (should second)
        (should (> second first)))
      ;; NOERROR nil signals rather than returning nil.
      (goto-char (point-min))
      (should-error (funcall fun "nosuchtext" nil nil)
                    :type 'search-failed))))

(ert-deftest ghostel-test-search-isearch-fun-lax-whitespace ()
  "Lax whitespace still collapses a run of spaces in the search string.
The transform must keep a space run whole; splitting it would demand one
whitespace run per space, which fails on ordinary unwrapped text too."
  (ghostel-test--with-wrap-search-buffer
    (insert "PREa bPOST")
    (let* ((isearch-forward t)
           (isearch-regexp nil)
           (isearch-regexp-function nil)
           (isearch-lax-whitespace t)
           (search-whitespace-regexp "[ \t]+")
           (fun (ghostel--isearch-search-fun)))
      ;; Two spaces in the needle, one in the buffer: stock isearch matches.
      (goto-char (point-min))
      (should (funcall fun "a  b" nil t))
      ;; And it still crosses a wrap.
      (erase-buffer)
      (ghostel-test--insert-soft-wrapped "PREa " "bPOST")
      (goto-char (point-min))
      (should (funcall fun "a b" nil t)))))

(ert-deftest ghostel-test-search-isearch-fun-lax-char-fold ()
  "Char-fold gets the lax flag and records it, as the stock fun does.
Lax lets a partially typed string stay on a ligature instead of jumping
to the next full match; it applies only while typing, not to lazy
highlight, which passes BOUND."
  (ghostel-test--with-wrap-search-buffer
    (insert "a ﬁle here")
    (let* ((isearch-forward t)
           (isearch-regexp nil)
           (isearch-regexp-function #'char-fold-to-regexp)
           (isearch-lax-whitespace nil)
           (this-command 'isearch-printing-char)
           (isearch-adjusted nil)
           (fun (ghostel--isearch-search-fun)))
      ;; Typing (no BOUND): lax applies and is recorded.
      (goto-char (point-min))
      (should (funcall fun "fi" nil t))
      (should (eq isearch-adjusted 'lax))
      ;; Lazy highlight (BOUND given): never lax, never records.
      (setq isearch-adjusted nil)
      (goto-char (point-min))
      (funcall fun "fi" (point-max) t)
      (should-not isearch-adjusted))))

(ert-deftest ghostel-test-search-wrap-atoms-groups-space-runs ()
  "`ghostel--wrap-atoms' keeps runs of spaces in one unit."
  (should (equal (ghostel--wrap-atoms "a  b") '("a" "  " "b")))
  (should (equal (ghostel--wrap-atoms "ab") '("a" "b")))
  (should (equal (ghostel--wrap-atoms "  ") '("  ")))
  (should (equal (ghostel--wrap-atoms "") nil))
  ;; No wrap atom lands inside the space run.
  (should (equal (ghostel--wrap-tolerant-regexp "a  b") "a\\s'?  \\s'?b")))

(ert-deftest ghostel-test-search-isearch-fun-regexp-delegates ()
  "Regexp isearch keeps default semantics (no wrap transform)."
  (ghostel-test--with-wrap-search-buffer
    (ghostel-test--insert-soft-wrapped "foobarba" "zqux")
    (goto-char (point-min))
    (let* ((isearch-forward t)
           (isearch-regexp t)
           (isearch-regexp-function nil)
           (isearch-regexp-lax-whitespace nil)
           (fun (ghostel--isearch-search-fun)))
      (should (funcall fun "f.obar" nil t))
      (should-not (funcall fun "barbazqu" nil t)))))

(ert-deftest ghostel-test-search-isearch-fun-char-fold ()
  "Char-folded isearch matches across soft wraps and keeps folding."
  (ghostel-test--with-wrap-search-buffer
    (ghostel-test--insert-soft-wrapped "foobarba" "zqux")
    (insert "\ncafé and a ﬁle\nHARDA\nHARDB")
    (let* ((isearch-forward t)
           (isearch-regexp nil)
           (isearch-regexp-function #'char-fold-to-regexp)
           (isearch-lax-whitespace nil)
           (fun (ghostel--isearch-search-fun)))
      ;; The wrapped occurrence is found (this is what plain delegation missed).
      (goto-char (point-min))
      (should (funcall fun "barbazqu" nil t))
      (should (equal (match-string 0) "barba\nzqu"))
      ;; Folding still works, including folds spanning several characters.
      (goto-char (point-min))
      (should (funcall fun "cafe" nil t))
      (goto-char (point-min))
      (should (funcall fun "file" nil t))
      ;; Hard newlines remain uncrossable.
      (goto-char (point-min))
      (should-not (funcall fun "HARDAHARDB" nil t)))))

(ert-deftest ghostel-test-search-isearch-fun-word-search-delegates ()
  "Word and symbol search keep default isearch behavior."
  (ghostel-test--with-wrap-search-buffer
    (ghostel-test--insert-soft-wrapped "foobarba" "zqux")
    (let* ((isearch-forward t)
           (isearch-regexp nil)
           (isearch-regexp-function #'word-search-regexp)
           (isearch-lax-whitespace nil)
           (fun (ghostel--isearch-search-fun)))
      (goto-char (point-min))
      (should-not (funcall fun "barbazqu" nil t))
      (goto-char (point-min))
      (should (funcall fun "foobarba" nil t)))))


;;; occur

(ert-deftest ghostel-test-search-occur-args-filter ()
  "The `occur-1' args filter transforms only literal, all-ghostel cases."
  (with-temp-buffer
    (ghostel-mode)
    (let* ((buf (current-buffer))
           (args (list "barbazqu" nil (list buf))))
      ;; Literal + ghostel buffer: transformed and labeled.
      (let ((out (ghostel--occur-wrap-args args)))
        (should (equal (car out)
                       (ghostel--wrap-tolerant-regexp "barbazqu")))
        (should (equal (get-text-property 0 'isearch-string (car out))
                       "barbazqu"))
        ;; Re-filtering the transformed args must not transform again.
        (should (eq (ghostel--occur-wrap-args out) out)))
      ;; Real regexps pass through unchanged.
      (let ((regexp-args (list "b.r" nil (list buf))))
        (should (eq (ghostel--occur-wrap-args regexp-args) regexp-args)))))
  ;; Non-ghostel buffer: untouched.
  (with-temp-buffer
    (let ((args (list "foo" nil (list (current-buffer)))))
      (should (eq (ghostel--occur-wrap-args args) args)))))

(ert-deftest ghostel-test-search-occur-args-accepts-overlays ()
  "BUFS entries may be overlays; `occur' on an active region passes one."
  (with-temp-buffer
    (ghostel-mode)
    (let* ((ov (make-overlay (point-min) (point-max)))
           (args (list "barbazqu" nil (list ov))))
      (should (equal (car (ghostel--occur-wrap-args args))
                     (ghostel--wrap-tolerant-regexp "barbazqu")))))
  ;; An overlay in a non-ghostel buffer is left alone.
  (with-temp-buffer
    (let* ((ov (make-overlay (point-min) (point-max)))
           (args (list "barbazqu" nil (list ov))))
      (should (eq (ghostel--occur-wrap-args args) args)))))

(ert-deftest ghostel-test-search-isearch-occur-transforms-quoted-string ()
  "`isearch-occur' quotes the search string; the advice restores wrap tolerance.
Without it, any regexp special in the search string (a dot, a dollar)
makes the quoted regexp fail the literal-safety gate, so \\[isearch-occur]
reports no matches for a wrapped hit that isearch just found."
  (with-temp-buffer
    (ghostel-mode)
    (let ((isearch-string "foo.bar")
          (isearch-regexp nil)
          (isearch-regexp-function nil))
      ;; What `isearch-occur' computes for a literal search.
      (let* ((quoted (regexp-quote isearch-string))
             (out (ghostel--isearch-occur-wrap-args (list quoted nil))))
        (should (equal (car out) (ghostel--wrap-tolerant-regexp isearch-string)))
        (should (equal (get-text-property 0 'isearch-string (car out))
                       "foo.bar")))
      ;; A caller-supplied regexp that isearch would not have produced
      ;; is passed through untouched.
      (let ((args (list "unrelated.*regexp" nil)))
        (should (eq (ghostel--isearch-occur-wrap-args args) args))))
    ;; Char-fold searches go through the folded transform.
    (let ((isearch-string "foo.bar")
          (isearch-regexp nil)
          (isearch-regexp-function #'char-fold-to-regexp))
      (let ((out (ghostel--isearch-occur-wrap-args
                  (list (char-fold-to-regexp isearch-string) nil))))
        (should (equal (car out)
                       (ghostel--wrap-tolerant-char-fold-regexp isearch-string))))))
  ;; Outside ghostel buffers nothing is rewritten.
  (with-temp-buffer
    (let ((isearch-string "foo.bar")
          (isearch-regexp nil)
          (isearch-regexp-function nil)
          (args (list (regexp-quote "foo.bar") nil)))
      (should (eq (ghostel--isearch-occur-wrap-args args) args)))))

(ert-deftest ghostel-test-search-occur-finds-wrapped-match ()
  "`occur' lists a match straddling a soft wrap; revert keeps it."
  (with-temp-buffer
    (ghostel-mode)
    (ghostel-test--with-rendered-output
      (ghostel-test--insert-soft-wrapped "foobarba" "zqux")
      (insert "\nplain line\n"))
    (occur "barbazqu")
    (unwind-protect
        (with-current-buffer "*Occur*"
          (should (string-match-p "1 match" (buffer-string)))
          (should (string-match-p "barba" (buffer-string)))
          (revert-buffer)
          (should (string-match-p "1 match" (buffer-string))))
      (when (get-buffer "*Occur*")
        (kill-buffer "*Occur*")))))


;;; Mode setup

(ert-deftest ghostel-test-search-mode-locals ()
  "`ghostel-mode' enables property lookup and installs the search fun."
  (with-temp-buffer
    (ghostel-mode)
    (should parse-sexp-lookup-properties)
    (should (eq isearch-search-fun-function #'ghostel--isearch-search-fun))))


;;; Renderer property stamping

(ert-deftest ghostel-test-search-renderer-stamps-wrap-newlines ()
  "Soft-wrap newlines get `ghostel-wrap' and expression-prefix syntax."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-search-render*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((term (ghostel--new 5 10 100)))
            (ghostel--write-vt term "foobarbazqux\r\nAAA\r\nBBB")
            (ghostel-test--redraw term t)
            (goto-char (point-min))
            (let ((wrap-nl (line-end-position)))
              (should (get-text-property wrap-nl 'ghostel-wrap))
              (should (equal (get-text-property wrap-nl 'syntax-table)
                             (string-to-syntax "'"))))
            ;; Hard newline after "ux" carries neither property.
            (goto-char (point-min))
            (search-forward "ux")
            (should-not (get-text-property (point) 'ghostel-wrap))
            (should-not (get-text-property (point) 'syntax-table))
            ;; End to end: literal crosses the rendered wrap, not the
            ;; hard boundary.
            (setq-local parse-sexp-lookup-properties t)
            (goto-char (point-min))
            (should (re-search-forward
                     (ghostel--wrap-tolerant-regexp "bazqux") nil t))
            (goto-char (point-min))
            (should-not (re-search-forward
                         (ghostel--wrap-tolerant-regexp "AAABBB") nil t))))
      (kill-buffer buf))))

(provide 'ghostel-wrap-test)
;;; ghostel-wrap-test.el ends here
