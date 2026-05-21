;;; ghostel-anchored-test.el --- Tests for ghostel: anchored terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; Anchored terminals render into a buffer region bounded by two markers
;; instead of taking over the whole buffer.  The renderer's destructive
;; ops are confined to the region; surrounding text survives redraws.
;; First and main consumer is `ghostel-comint' (per-command rendering).

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-anchored-renders-between-markers ()
  "Anchored terminal writes only inside its marker range.
Text outside the start/end markers must survive a force-full redraw,
and the rendered VT output must land inside the marker range."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-anchored*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            ;; Build the buffer layout FIRST, then create the
            ;; terminal -- the Zig constructor takes start/end
            ;; positions and builds markers from them (end with
            ;; insertion-type t).  Inserting surrounding text AFTER
            ;; the terminal exists would let the end marker ride
            ;; forward through that text and the renderer would
            ;; clobber it.
            (insert "BEFORE\n")
            (let ((start (point)))
              (insert "\n")
              (let ((end (point)))
                (insert "AFTER\n")
                (let ((term (ghostel--new-anchored start end 3 20 100)))
                  (ghostel--write-input term "hi")
                  (ghostel--redraw term t)
                  (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                    (should (string-prefix-p "BEFORE\n" content))
                    (should (string-suffix-p "AFTER\n" content))
                    (let ((mid (substring content
                                          (length "BEFORE\n")
                                          (- (length content) (length "AFTER\n")))))
                      (should (string-match-p "hi" mid)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-anchored-multi-redraw-overwrites-grid ()
  "Successive redraws update the anchored grid in place.
CR (\\r) returns the cursor to column 0; the second write must
overwrite the start of the existing line rather than appending,
and surrounding text must still survive."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-anchored-multi*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (insert "TOP\n")
            (let ((start (point)))
              (insert (make-string 3 ?\n))
              (let ((end (point)))
                (insert "BOTTOM\n")
                (let ((term (ghostel--new-anchored start end 3 20 100)))
                  (ghostel--write-input term "hello")
                  (ghostel--redraw term t)
                  (let ((c (buffer-substring-no-properties (point-min) (point-max))))
                    (should (string-match-p "hello" c)))
                  ;; CR back to column 0, overwrite first three chars.
                  (ghostel--write-input term "\rwor")
                  (ghostel--redraw term t)
                  (let ((c (buffer-substring-no-properties (point-min) (point-max))))
                    ;; "hello" + "\rwor" -> "worlo" on row 0.
                    (should (string-match-p "worlo" c))
                    (should (string-prefix-p "TOP\n" c))
                    (should (string-suffix-p "BOTTOM\n" c))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-anchored-scrollback-grows-region ()
  "With MAX-SCROLLBACK > 0, an anchored terminal materializes scrollback.
Feeds enough rows to overflow the 5-row grid several times.  The region
between the markers must grow past the live grid, contain rows already
scrolled off the active area, and remain flanked by the original
BEFORE/AFTER surrounding text."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-anchored-scrollback*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (insert "BEFORE-TOP\n")
            (let ((start (point)))
              (insert "\n")
              (let ((end (point)))
                (insert "AFTER-BOTTOM\n")
                (let ((term (ghostel--new-anchored start end 5 20 51200)))
                  (dotimes (i 30)
                    (ghostel--write-input term (format "line-%02d\r\n" i)))
                  (ghostel--redraw term t)
                  (let* ((pair (gethash term ghostel--anchored-terminals))
                         (rs (car pair))
                         (re (cdr pair))
                         (start-pos (marker-position rs))
                         (end-pos (marker-position re))
                         (content (buffer-substring-no-properties
                                   (point-min) (point-max)))
                         (mid (buffer-substring-no-properties start-pos end-pos)))
                    (should (string-prefix-p "BEFORE-TOP\n" content))
                    (should (string-suffix-p "AFTER-BOTTOM\n" content))
                    (should (markerp rs))
                    (should (markerp re))
                    (should (eq (marker-buffer rs) buf))
                    (should (eq (marker-buffer re) buf))
                    (should (< start-pos end-pos))
                    (should (string-match-p "line-29" mid))
                    (should (string-match-p "line-25" mid))
                    (should (string-match-p "line-15" mid))
                    (should (string-match-p "line-10" mid))
                    (let ((region-lines (length (split-string mid "\n"))))
                      (should (> region-lines 5)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-anchored-scrollback-zero-bounds-region ()
  "With MAX-SCROLLBACK = 0, the anchored region stays bounded.
Scrolled-off rows are evicted by libghostty, and the renderer
follows by trimming the buffer.  Verifies the eviction math
\(`libghostty_rows < rows_in_buffer' branch) works in anchored mode."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-anchored-no-sb*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (insert "BEFORE-TOP\n")
            (let ((start (point)))
              (insert "\n")
              (let ((end (point)))
                (insert "AFTER-BOTTOM\n")
                (let ((term (ghostel--new-anchored start end 5 20 0)))
                  (dotimes (i 30)
                    (ghostel--write-input term (format "line-%02d\r\n" i)))
                  (ghostel--redraw term t)
                  (let* ((pair (gethash term ghostel--anchored-terminals))
                         (rs (car pair))
                         (re (cdr pair))
                         (start-pos (marker-position rs))
                         (end-pos (marker-position re))
                         (content (buffer-substring-no-properties
                                   (point-min) (point-max)))
                         (mid (buffer-substring-no-properties start-pos end-pos)))
                    (should (string-prefix-p "BEFORE-TOP\n" content))
                    (should (string-suffix-p "AFTER-BOTTOM\n" content))
                    (should (markerp rs))
                    (should (markerp re))
                    (should (< start-pos end-pos))
                    (should (string-match-p "line-29" mid))
                    (should-not (string-match-p "line-00" mid))
                    (should-not (string-match-p "line-10" mid))
                    (let ((region-lines (length (split-string mid "\n"))))
                      (should (<= region-lines 7)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-anchored-scrollback-after-text-survives ()
  "Text past the end marker is pushed down by region growth, never overwritten."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-anchored-sb-after*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (insert "BEFORE-TOP\n")
            (let ((start (point)))
              (insert "\n")
              (let ((end (point)))
                (insert "AFTER-LINE-1\nAFTER-LINE-2\nTAIL\n")
                (let ((initial-after (buffer-substring-no-properties
                                      end (point-max)))
                      (term (ghostel--new-anchored start end 5 20 51200)))
                  (dotimes (i 30)
                    (ghostel--write-input term (format "scroll-%02d\r\n" i)))
                  (ghostel--redraw term t)
                  (let* ((pair (gethash term ghostel--anchored-terminals))
                         (re (cdr pair))
                         (end-pos (marker-position re))
                         (after-now (buffer-substring-no-properties
                                     end-pos (point-max))))
                    (should (equal initial-after after-now))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-anchored-multi-terminals-independent ()
  "Two anchored terminals in the same buffer render independently.
Each terminal has its own marker pair in `ghostel--anchored-terminals'.
Feeding term1 must not affect term2's region, and vice versa."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-anchored-multi-terms*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (insert "TOP-OUTER\n")
            (let ((s1 (point)))
              (insert "\n")
              (let ((e1 (point)))
                (insert "MIDDLE-OUTER\n")
                (let ((s2 (point)))
                  (insert "\n")
                  (let ((e2 (point)))
                    (insert "BOTTOM-OUTER\n")
                    (let* ((t1 (ghostel--new-anchored s1 e1 3 20 100))
                           (t2 (ghostel--new-anchored s2 e2 3 20 100))
                           (p1 (gethash t1 ghostel--anchored-terminals))
                           (p2 (gethash t2 ghostel--anchored-terminals))
                           (rs1 (car p1)) (re1 (cdr p1))
                           (rs2 (car p2)) (re2 (cdr p2)))
                      (should (hash-table-p ghostel--anchored-terminals))
                      (should (= 2 (hash-table-count
                                    ghostel--anchored-terminals)))
                      (should (markerp rs1))
                      (should (markerp re1))
                      (should (markerp rs2))
                      (should (markerp re2))
                      (ghostel--write-input t1 "AAAAA")
                      (ghostel--redraw t1 t)
                      (let ((content (buffer-substring-no-properties
                                      (point-min) (point-max))))
                        (should (string-prefix-p "TOP-OUTER\n" content))
                        (should (string-match-p "MIDDLE-OUTER" content))
                        (should (string-suffix-p "BOTTOM-OUTER\n" content))
                        (let ((r1 (buffer-substring-no-properties
                                   (marker-position rs1)
                                   (marker-position re1)))
                              (r2 (buffer-substring-no-properties
                                   (marker-position rs2)
                                   (marker-position re2))))
                          (should (string-match-p "AAAAA" r1))
                          (should-not (string-match-p "AAAAA" r2))
                          (should-not (string-match-p "BBBBB" r2))))
                      (ghostel--write-input t2 "BBBBB")
                      (ghostel--redraw t2 t)
                      (let ((r1 (buffer-substring-no-properties
                                 (marker-position rs1)
                                 (marker-position re1)))
                            (r2 (buffer-substring-no-properties
                                 (marker-position rs2)
                                 (marker-position re2))))
                        (should (string-match-p "AAAAA" r1))
                        (should-not (string-match-p "BBBBB" r1))
                        (should (string-match-p "BBBBB" r2))
                        (should-not (string-match-p "AAAAA" r2)))
                      (ghostel--write-input t1 "X")
                      (ghostel--redraw t1 t)
                      (let ((r1 (buffer-substring-no-properties
                                 (marker-position rs1)
                                 (marker-position re1)))
                            (r2 (buffer-substring-no-properties
                                 (marker-position rs2)
                                 (marker-position re2))))
                        (should (string-match-p "AAAAAX" r1))
                        (should (string-match-p "BBBBB" r2))
                        (should-not (string-match-p "X" r2))))))))))
      (kill-buffer buf))))

(provide 'ghostel-anchored-test)
;;; ghostel-anchored-test.el ends here
