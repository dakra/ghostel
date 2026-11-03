;;; ghostel-region-test.el --- Region-relative rendering tests  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for rendering a terminal into a region of a host buffer instead
;; of the whole buffer.  This is the native half of in-buffer Eshell
;; support: the terminal writes its rows between two markers and must
;; never touch the host text around them.

;;; Code:

(require 'ghostel-test-helpers)

(declare-function ghostel--set-region "ghostel-module" (term start end))

(defun ghostel-test--region-setup (buffer rows cols &optional before)
  "Create a terminal in BUFFER, ROWS by COLS, rendering into a region.
The region is delimited by fresh markers.  BEFORE, when non-nil, is
inserted above the region first.  Returns (TERM START END) where START
and END are the region's markers."
  (with-current-buffer buffer
    (when before (insert before))
    (let* ((start (copy-marker (point) nil))
           (end (copy-marker (point) t))
           (term (ghostel--new rows cols 4096)))
      (ghostel--set-region term start end)
      (list term start end))))

(defun ghostel-test--region-text (start end)
  "Return the region text between START and END without properties."
  (buffer-substring-no-properties start end))

(defun ghostel-test--region-prefix (start)
  "Return the host text before the region that starts at START."
  (buffer-substring-no-properties (point-min) start))

(ert-deftest ghostel-test-region-renders-between-markers ()
  "Terminal rows land inside the region and host text above survives."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-region*")))
    (unwind-protect
        (pcase-let ((`(,term ,start ,end)
                     (ghostel-test--region-setup buf 3 20 "before\n")))
          (with-current-buffer buf
            (ghostel--write-vt term "hello\r\nworld")
            (ghostel--redraw term t)
            (should (equal (ghostel-test--region-prefix start) "before\n"))
            (should (equal (string-trim-right
                            (ghostel-test--region-text start end))
                           "hello\nworld"))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-region-full-redraw-keeps-host-text ()
  "A forced full redraw clears only the region, not the host buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-region-full*")))
    (unwind-protect
        (pcase-let ((`(,term ,start ,end)
                     (ghostel-test--region-setup buf 3 20 "before\n")))
          (with-current-buffer buf
            (ghostel--write-vt term "one\r\ntwo")
            (ghostel--redraw term t)
            (ghostel--write-vt term "\r\e[2Kthree")
            (ghostel--redraw term t)
            (ghostel--write-vt term "\r\e[2Kfour")
            (ghostel--redraw term t)
            (should (equal (ghostel-test--region-prefix start) "before\n"))
            (should (equal (string-trim-right
                            (ghostel-test--region-text start end))
                           "one\nfour"))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-region-moves-with-host-edits ()
  "Editing the host buffer above the region shifts the region with it."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-region-edits*")))
    (unwind-protect
        (pcase-let ((`(,term ,start ,end)
                     (ghostel-test--region-setup buf 3 20 "before\n")))
          (with-current-buffer buf
            (ghostel--write-vt term "hello")
            (ghostel--redraw term t)
            (goto-char (point-min))
            (insert "top\n")
            (ghostel--redraw term)
            (should (equal (ghostel-test--region-prefix start)
                           "top\nbefore\n"))
            (should (equal (string-trim-right
                            (ghostel-test--region-text start end))
                           "hello"))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-region-materializes-scrollback ()
  "Rows that scroll out of the viewport are materialized inside the region."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-region-scrollback*")))
    (unwind-protect
        (pcase-let ((`(,term ,start ,end)
                     (ghostel-test--region-setup buf 3 80 "before\n")))
          (with-current-buffer buf
            (dotimes (i 8)
              (ghostel--write-vt term (format "line-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((text (ghostel-test--region-text start end)))
              (should (string-match-p "line-00" text))
              (should (string-match-p "line-07" text)))
            (should (>= (count-lines start end) 9))
            (should (equal (ghostel-test--region-prefix start) "before\n"))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-region-cursor-position-is-absolute ()
  "`ghostel--cursor-char-pos' is a host-buffer position inside the region."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-region-cursor*")))
    (unwind-protect
        (pcase-let ((`(,term ,start ,_end)
                     (ghostel-test--region-setup buf 3 20 "before\n")))
          (with-current-buffer buf
            (ghostel--write-vt term "abc")
            (ghostel--redraw term t)
            (should (= ghostel--cursor-char-pos (+ start 3)))
            (should (eq (char-after ghostel--cursor-char-pos) ?\n))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-region-mark-survives-redraw ()
  "A mark inside the region stays on the same terminal cell."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-region-mark*")))
    (unwind-protect
        (pcase-let ((`(,term ,start ,_end)
                     (ghostel-test--region-setup buf 3 20 "before\n")))
          (with-current-buffer buf
            (ghostel--write-vt term "one\r\ntwo")
            (ghostel--redraw term t)
            (goto-char start)
            (forward-line 1)
            (set-marker (mark-marker) (point))
            (ghostel--write-vt term " more")
            (ghostel--redraw term t)
            (let ((mark (marker-position (mark-marker))))
              (should (equal (buffer-substring-no-properties mark (+ mark 3))
                             "two")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-region-alt-screen-replaces-region ()
  "Alternate-screen content replaces the region and the normal screen returns."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-region-alt*")))
    (unwind-protect
        (pcase-let ((`(,term ,start ,end)
                     (ghostel-test--region-setup buf 3 20 "before\n")))
          (with-current-buffer buf
            (ghostel--write-vt term "normal")
            (ghostel--redraw term t)
            (ghostel--write-vt term "\e[?1049h\e[2J\e[HTUI")
            (ghostel--redraw term t)
            (let ((alt (ghostel-test--region-text start end)))
              (should (string-match-p "TUI" alt))
              (should-not (string-match-p "normal" alt)))
            (should (equal (ghostel-test--region-prefix start) "before\n"))
            (ghostel--write-vt term "\e[?1049l")
            (ghostel--redraw term t)
            (should (string-match-p "normal"
                                    (ghostel-test--region-text start end)))))
      (kill-buffer buf))))

(provide 'ghostel-region-test)
;;; ghostel-region-test.el ends here
