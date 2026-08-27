;;; ghostel-word-boundary-test.el --- Tests for ghostel: word boundaries  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-mode-syntax-table' and the `ghostel-word-boundary-string'
;; defcustom that drives it.  All tests are pure elisp — no native module
;; required.  We enter `ghostel-mode' via `ghostel-test--with-compile-buffer'
;; so the buffer's syntax table is whatever `define-derived-mode' installs,
;; matching the production buffers a user actually clicks in.
;;
;; Tests assert via two paths.  `thing-at-point 'word' goes through
;; `bounds-of-thing-at-point', the call chain `M-f' / `M-b', Evil `iw' / `aw'
;; and isearch word matching follow.  `mouse-start-end' with mode 1 is the
;; call `mouse-set-point' makes for double-click promotion (via
;; `mouse-set-region').  Both share the syntax table here, but exercising
;; them separately catches regressions in either path.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-syntax-table-selects-hostname ()
  "Word selection covers a full dotted hostname.

Default boundaries make `.' a word constituent, so a click inside `example'
returns the whole `api.example.com' run."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "api.example.com"))
    (goto-char (point-min))
    (search-forward "example")
    (backward-char 4)                    ; somewhere inside `example'
    (should (equal (thing-at-point 'word t) "api.example.com"))))

(ert-deftest ghostel-test-syntax-table-selects-path ()
  "Word selection covers a full filesystem path."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "~/src/foo/bar.txt"))
    (goto-char (point-min))
    (search-forward "foo")
    (backward-char 2)
    (should (equal (thing-at-point 'word t) "~/src/foo/bar.txt"))))

(ert-deftest ghostel-test-syntax-table-stops-at-boundary ()
  "Default boundary characters still split words.

Confirms the rebuild does not collapse every codepoint to word syntax —
SPC, `|', and U+2502 should each terminate a selection."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "alpha bravo|charlie\u2502delta"))
    (dolist (word '("alpha" "bravo" "charlie" "delta"))
      (goto-char (point-min))
      (search-forward word)
      (backward-char 2)
      (should (equal (thing-at-point 'word t) word)))))

(ert-deftest ghostel-test-syntax-table-mouse-start-end ()
  "`mouse-start-end' with mode 1 grows a click into the surrounding word.

`mouse-set-point' calls `mouse-set-region' → `mouse-start-end' on a
multi-click event; this is the actual call chain `mouse-1' double-click
takes after `ghostel-mouse-release-or-set-point' delegates to
`mouse-set-point'.  The other tests go through `bounds-of-thing-at-point',
which only catches a subset of the same syntax-table classification."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "api.example.com"))
    (goto-char (point-min))
    (search-forward "example")
    (backward-char 4)
    (let* ((bounds (mouse-start-end (point) (point) 1))
           (text (buffer-substring-no-properties (nth 0 bounds)
                                                 (nth 1 bounds))))
      (should (equal text "api.example.com")))))

(ert-deftest ghostel-test-syntax-table-rebuild-on-customize ()
  "`customize-set-variable' rebuilds `ghostel-mode-syntax-table' in place.

Live ghostel buffers hold a reference to `ghostel-mode-syntax-table' via
`set-syntax-table', so the rebuild has to mutate the existing object — a
fresh table would leave existing buffers with the old boundaries."
  (let ((saved ghostel-word-boundary-string))
    (unwind-protect
        (ghostel-test--with-compile-buffer buf
          (let ((inhibit-read-only t))
            (insert "git@github.com:dakra/ghostel"))
          (goto-char (point-min))
          (search-forward "github")
          (backward-char 2)
          ;; Default: `:' is a boundary, so the word stops before `:dakra'.
          (should (equal (thing-at-point 'word t) "git@github.com"))
          ;; Drop `:' from the boundary set — same string with `:' removed.
          (customize-set-variable 'ghostel-word-boundary-string
                                  " \t\"'`|;,()[]{}<>$\u2502")
          (should (equal (thing-at-point 'word t)
                         "git@github.com:dakra/ghostel")))
      (customize-set-variable 'ghostel-word-boundary-string saved))))

(ert-deftest ghostel-test-syntax-table-drops-stale-non-ascii-boundary ()
  "A non-ASCII char dropped from the boundary string reverts to inherited syntax."
  (let ((table (make-syntax-table)))
    (ghostel--realize-word-boundaries table "|é")
    (with-syntax-table table
      (should (eq (char-syntax ?é) ?.)))
    (ghostel--realize-word-boundaries table "|")
    (with-syntax-table table
      (should (eq (char-syntax ?é) ?w)))))

(provide 'ghostel-word-boundary-test)
;;; ghostel-word-boundary-test.el ends here
