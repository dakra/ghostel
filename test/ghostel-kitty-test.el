;;; ghostel-kitty-test.el --- Kitty graphics tests for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Cell-pixel-scale detection and kitty graphics image display/clear.

;;; Code:

(require 'ghostel-test-helpers)
(require 'cl-lib)

(defun ghostel-test--kitty-fixture (body)
  "Run BODY in a temp buffer with kitty-related primitives faked.
Stubs `display-graphic-p', `create-image', `frame-char-width', and
`frame-char-height' so display callbacks can be exercised in batch."
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
              ((symbol-function 'create-image)
               (lambda (&rest _args) 'fake-image))
              ((symbol-function 'frame-char-width) (lambda (&rest _) 8))
              ((symbol-function 'frame-char-height) (lambda (&rest _) 16)))
      (funcall body))))

(ert-deftest ghostel-test-detect-cell-pixel-scale-standard-dpi ()
  "96 DPI display resolves to ~1.0 (no scaling)."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
            ;; 1920px / 508mm -> ~96 DPI
            ((symbol-function 'display-pixel-width) (lambda (&rest _) 1920))
            ((symbol-function 'display-mm-width) (lambda (&rest _) 508)))
    (let ((scale (ghostel--detect-cell-pixel-scale)))
      (should (numberp scale))
      (should (< (abs (- scale 1.0)) 0.05)))))

(ert-deftest ghostel-test-detect-cell-pixel-scale-hidpi ()
  "192 DPI display resolves to ~2.0."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
            ;; 3840px / 508mm -> ~192 DPI
            ((symbol-function 'display-pixel-width) (lambda (&rest _) 3840))
            ((symbol-function 'display-mm-width) (lambda (&rest _) 508)))
    (let ((scale (ghostel--detect-cell-pixel-scale)))
      (should (numberp scale))
      (should (< (abs (- scale 2.0)) 0.05)))))

(ert-deftest ghostel-test-detect-cell-pixel-scale-fractional ()
  "144 DPI display resolves to ~1.5 (fractional, not rounded to 1 or 2)."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
            ;; 2880px / 508mm -> ~144 DPI
            ((symbol-function 'display-pixel-width) (lambda (&rest _) 2880))
            ((symbol-function 'display-mm-width) (lambda (&rest _) 508)))
    (let ((scale (ghostel--detect-cell-pixel-scale)))
      (should (numberp scale))
      (should (< (abs (- scale 1.5)) 0.05)))))

(ert-deftest ghostel-test-detect-cell-pixel-scale-low-dpi-clamped ()
  "Sub-96 DPI displays clamp to 1.0 (don't shrink below the reference)."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
            ;; 800px / 508mm -> ~40 DPI (e.g. some virtual displays)
            ((symbol-function 'display-pixel-width) (lambda (&rest _) 800))
            ((symbol-function 'display-mm-width) (lambda (&rest _) 508)))
    (should (= (ghostel--detect-cell-pixel-scale) 1.0))))

(ert-deftest ghostel-test-detect-cell-pixel-scale-zero-mm-returns-nil ()
  "When the display reports 0 mm width (some setups), return nil."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
            ((symbol-function 'display-pixel-width) (lambda (&rest _) 1920))
            ((symbol-function 'display-mm-width) (lambda (&rest _) 0)))
    (should (null (ghostel--detect-cell-pixel-scale)))))

(ert-deftest ghostel-test-detect-cell-pixel-scale-non-graphic-returns-nil ()
  "On a non-graphic display, return nil."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil)))
    (should (null (ghostel--detect-cell-pixel-scale)))))

(ert-deftest ghostel-test-cell-pixel-scale-numeric-override ()
  "An explicit number overrides auto-detect verbatim."
  (let ((ghostel-cell-pixel-scale 2.28))
    (should (= (ghostel--cell-pixel-scale) 2.28))))

(ert-deftest ghostel-test-cell-pixel-scale-numeric-override-floor-1 ()
  "Numeric overrides below 1 are floored to 1 (no shrinking)."
  (let ((ghostel-cell-pixel-scale 0.5))
    (should (= (ghostel--cell-pixel-scale) 1))))

(ert-deftest ghostel-test-cell-pixel-scale-auto-falls-back-to-1 ()
  "When auto-detect returns nil, the active scale is 1."
  (let ((ghostel-cell-pixel-scale 'auto))
    (cl-letf (((symbol-function 'ghostel--detect-cell-pixel-scale)
               (lambda () nil)))
      (should (= (ghostel--cell-pixel-scale) 1)))))

(ert-deftest ghostel-test-reported-cell-dims-multiply-frame-by-scale ()
  "Reported cell width/height = frame char dim * scale, rounded.
Uses scale 1.4 (not 1.5) to avoid the half-integer boundary where
Emacs uses banker's rounding."
  (cl-letf (((symbol-function 'frame-char-width) (lambda (&rest _) 8))
            ((symbol-function 'frame-char-height) (lambda (&rest _) 16)))
    (let ((ghostel-cell-pixel-scale 2))
      (should (= (ghostel--reported-cell-width) 16))
      (should (= (ghostel--reported-cell-height) 32)))
    (let ((ghostel-cell-pixel-scale 1.4))
      (should (= (ghostel--reported-cell-width) 11))    ; round(8 * 1.4) = round(11.2) = 11
      (should (= (ghostel--reported-cell-height) 22))))) ; round(16 * 1.4) = round(22.4) = 22

(ert-deftest ghostel-test-kitty-display-image-tags-region ()
  "Non-virtual placement tags its region with `ghostel-kitty'.
The display property and the marker share the same range."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "row1xx\nrow2xx\n")
	 (ghostel--kitty-display-image "data" nil 0 0 4 2 32 32 0 0 0 0)
	 ;; Both rows should have a display property covering them
	 (should (get-text-property 1 'display))
	 (should (get-text-property 1 'ghostel-kitty))
	 (should ghostel--kitty-active)
	 ;; Trailing space outside placement (col 4..6) should not be tagged
	 (should (null (get-text-property 5 'ghostel-kitty))))))

(ert-deftest ghostel-test-kitty-display-image-empty-line-uses-overlay ()
  "Empty placement range uses an overlay (so the newline isn't eaten)."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "\n\n")
	 (ghostel--kitty-display-image "data" nil 0 5 4 1 32 16 0 0 0 0)
	 (let ((ovs (cl-remove-if-not
				 (lambda (ov) (overlay-get ov 'ghostel-kitty))
				 (overlays-in (point-min) (point-max)))))
	   (should ovs)
	   (should ghostel--kitty-active)))))

(ert-deftest ghostel-test-kitty-clear-strips-only-tagged-regions ()
  "Clearing only strips kitty-tagged regions and leaves others alone.
Other consumers of the `display' property (e.g. wide-char compensation)
must survive a clear."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "row1xx\nrow2xx\n")
	 ;; Apply an unrelated display property (e.g. wide-char comp).
	 (put-text-property 1 3 'display "PRESERVED")
	 ;; Apply kitty image.
	 (ghostel--kitty-display-image "data" nil 0 3 3 2 24 32 0 0 0 0)
	 (should ghostel--kitty-active)
	 (ghostel--kitty-clear)
	 ;; Unrelated display survives.
	 (should (equal (get-text-property 1 'display) "PRESERVED"))
	 ;; Tagged regions stripped of display + line-height + ghostel-kitty.
	 (let ((found nil))
	   (save-excursion
		 (goto-char (point-min))
		 (while (< (point) (point-max))
		   (when (or (get-text-property (point) 'ghostel-kitty)
					 (get-text-property (point) 'line-height))
			 (setq found (point)))
		   (forward-char 1)))
	   (should-not found)))))

(ert-deftest ghostel-test-kitty-clear-removes-overlays ()
  "`ghostel--kitty-clear' deletes overlays tagged with `ghostel-kitty'."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "\n")
	 (let ((ov (make-overlay (point-min) (point-min))))
	   (overlay-put ov 'ghostel-kitty t)
	   (setq ghostel--kitty-active t))
	 (let ((other (make-overlay (point-min) (point-min))))
	   (overlay-put other 'other-marker t))
	 (ghostel--kitty-clear)
	 (let ((kitty-ovs (cl-remove-if-not
					   (lambda (ov) (overlay-get ov 'ghostel-kitty))
					   (overlays-in (point-min) (point-max))))
		   (other-ovs (cl-remove-if-not
					   (lambda (ov) (overlay-get ov 'other-marker))
					   (overlays-in (point-min) (point-max)))))
	   (should-not kitty-ovs)
	   (should other-ovs)))))

(ert-deftest ghostel-test-kitty-clear-strips-orphan-fragment-after-eviction ()
  "Image fragment left by scrollback eviction at point-min gets stripped.
Simulates the post-eviction state: the first row of the buffer has a
kitty `display' property with slice y > 0 (i.e., it's the second or
later row of an image whose earlier rows were trimmed).  After clear,
the orphan must be gone."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "rowA\nrowB\nrowC\nrowD\n")
	 ;; Two-row viewport: rows 1-2 are scrollback, rows 3-4 are viewport.
	 (setq-local ghostel--term-rows 2)
	 ;; Tag row 1 as a stale image slice with y=16 (= one cell past the
	 ;; top of a multi-row image) and tag row 2 as another orphan slice.
	 (let ((spec1 (list (list 'slice 0 16 32 16) 'fake-img))
		   (spec2 (list (list 'slice 0 32 32 16) 'fake-img)))
	   (add-text-properties 1 5 (list 'display spec1 'ghostel-kitty t))
	   (add-text-properties 6 10 (list 'display spec2 'ghostel-kitty t)))
	 ;; Tag a viewport row too (just so the regular clear path still runs).
	 (add-text-properties 11 15 '(display "VP-IMG" ghostel-kitty t))
	 (setq ghostel--kitty-active t)
	 (ghostel--kitty-clear)
	 ;; Orphan rows stripped: no display, no kitty marker.
	 (should-not (get-text-property 1 'display))
	 (should-not (get-text-property 1 'ghostel-kitty))
	 (should-not (get-text-property 6 'display))
	 (should-not (get-text-property 6 'ghostel-kitty)))))

(ert-deftest ghostel-test-kitty-clear-strips-collapsed-overlay-stack ()
  "Stacked zero-width kitty overlays at one point are eviction debris.
`delete-region' clamps overlays inside the deleted range to its start
instead of deleting them, so a tall image's per-row overlays all
collapse onto the new point-min.  Detect by counting zero-width
kitty overlays per starting position; more than one is never legit.

A lone zero-width overlay at the same position must NOT be touched —
that's the standard rendering for an empty viewport row."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "rowA\nrowB\nrowC\n")
	 (setq-local ghostel--term-rows 1)         ; only the last row is viewport
	 ;; Stack 5 zero-width kitty overlays at point-min — eviction debris.
	 (dotimes (_ 5)
	   (let ((ov (make-overlay (point-min) (point-min))))
		 (overlay-put ov 'ghostel-kitty t)
		 (overlay-put ov 'before-string "img-slice")))
	 ;; Lone zero-width overlay at row 2: legit empty-line image.
	 (let ((legit (make-overlay 6 6)))
	   (overlay-put legit 'ghostel-kitty t)
	   (overlay-put legit 'before-string "legit"))
	 (setq ghostel--kitty-active t)
	 (ghostel--kitty-clear)
	 ;; Stacked overlays at point-min: all gone.  `overlays-in' with a
	 ;; one-char span picks up zero-width overlays anchored inside;
	 ;; `overlays-at' would not.
	 (let ((stacked (cl-remove-if-not
					 (lambda (o) (overlay-get o 'ghostel-kitty))
					 (overlays-in (point-min) (1+ (point-min))))))
	   (should (zerop (length stacked))))
	 ;; Lone overlay at row 2: preserved.
	 (let ((surviving (cl-remove-if-not
					   (lambda (o) (overlay-get o 'ghostel-kitty))
					   (overlays-in 6 7))))
	   (should (= 1 (length surviving)))))))

(ert-deftest ghostel-test-kitty-clear-preserves-intact-image-at-top ()
  "An image whose first slice (y=0) is at point-min is not stripped.
Distinguishing intact images from orphans matters: an image rendered at
the very start of scrollback that hasn't been straddled by eviction
has slice y=0 on its top row.  That row must survive the orphan-strip
heuristic."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "rowA\nrowB\nrowC\nrowD\n")
	 (setq-local ghostel--term-rows 2)
	 (let ((spec0 (list (list 'slice 0 0 32 16) 'fake-img))
		   (spec1 (list (list 'slice 0 16 32 16) 'fake-img)))
	   (add-text-properties 1 5 (list 'display spec0 'ghostel-kitty t))
	   (add-text-properties 6 10 (list 'display spec1 'ghostel-kitty t)))
	 (setq ghostel--kitty-active t)
	 (ghostel--kitty-clear)
	 ;; Intact image at point-min retained.
	 (should (get-text-property 1 'ghostel-kitty))
	 (should (get-text-property 6 'ghostel-kitty)))))

(ert-deftest ghostel-test-kitty-clear-noop-when-inactive ()
  "Clearing an inactive buffer is a no-op (skips the buffer scan)."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "hello")
	 (put-text-property 1 3 'display "UNRELATED")
	 (setq ghostel--kitty-active nil)
	 (ghostel--kitty-clear)
	 (should (equal (get-text-property 1 'display) "UNRELATED")))))

(ert-deftest ghostel-test-kitty-clear-resets-sticky-flag-when-empty ()
  "Clearing the last viewport image without scrollback resets the active flag.
The flag (`ghostel--kitty-active') guards `ghostel--kitty-clear' against
walking the buffer when there is nothing to find — it must reset to nil
once no kitty-tagged region remains anywhere in the buffer."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "row1xx\nrow2xx\n")
	 (setq-local ghostel--term-rows 2)         ; whole buffer is viewport
	 (add-text-properties 1 7 '(display "VP-IMG" ghostel-kitty t))
	 (let ((ov (make-overlay 1 1)))
	   (overlay-put ov 'ghostel-kitty t)
	   (setq ghostel--kitty-active t)
	   (ghostel--kitty-clear)
	   ;; Viewport stripped, no scrollback to retain — flag flips to nil.
	   (should-not ghostel--kitty-active))))
  ;; Same test, but with a scrollback row tagged: flag must stay t.
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "row1xx\nrow2xx\nrow3xx\n")
	 (setq-local ghostel--term-rows 1)         ; rows 1-2 scrollback, row 3 viewport
	 (add-text-properties 1 7 '(display "SCROLL-IMG" ghostel-kitty t))
	 (add-text-properties 15 21 '(display "VP-IMG" ghostel-kitty t))
	 (setq ghostel--kitty-active t)
	 (ghostel--kitty-clear)
	 ;; Scrollback retained → flag stays set.
	 (should ghostel--kitty-active))))

(ert-deftest ghostel-test-kitty-clear-preserves-scrollback-overlays ()
  "Clear strips viewport overlays/properties but leaves scrollback alone.
Once an image scrolls into materialized scrollback libghostty stops
reporting it (`viewport_visible' goes false), so wiping scrollback in
`ghostel--kitty-clear' would erase past images for good."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "row1xx\nrow2xx\nrow3xx\nrow4xx\n")
	 ;; Two-row viewport: rows 1-2 are scrollback, rows 3-4 are viewport.
	 (setq-local ghostel--term-rows 2)
	 ;; Tag a scrollback row and a viewport row with kitty marks.
	 (add-text-properties 1 7 '(display "SCROLL-IMG" ghostel-kitty t))
	 (add-text-properties 15 21 '(display "VIEW-IMG" ghostel-kitty t))
	 (let ((sb-ov (make-overlay 1 1))
		   (vp-ov (make-overlay 15 15)))
	   (overlay-put sb-ov 'ghostel-kitty t)
	   (overlay-put sb-ov 'before-string "SB")
	   (overlay-put vp-ov 'ghostel-kitty t)
	   (overlay-put vp-ov 'before-string "VP")
	   (setq ghostel--kitty-active t)
	   (ghostel--kitty-clear)
	   ;; Scrollback row: kept.
	   (should (equal (get-text-property 1 'display) "SCROLL-IMG"))
	   (should (get-text-property 1 'ghostel-kitty))
	   (should (overlay-buffer sb-ov))
	   ;; Viewport row: stripped.
	   (should-not (get-text-property 15 'display))
	   (should-not (get-text-property 15 'ghostel-kitty))
	   (should-not (overlay-buffer vp-ov))))))

(ert-deftest ghostel-test-kitty-display-image-skips-scrollback-rows ()
  "Re-emit of a partially-visible placement skips already-scrolled rows.
Scrollback overlays are preserved by `ghostel--kitty-clear' across
redraws; if `display-image' re-applied them on every emit, every
re-emit would stack another overlay on the same row, multiplying
overlays per row by the number of times the image has been visible."
  (ghostel-test--kitty-fixture
   (lambda ()
	 ;; Buffer: 6 lines, viewport = last 2 rows so lines 1-4 are scrollback.
	 (insert "row1xx\nrow2xx\nrow3xx\nrow4xx\nrow5xx\nrow6xx\n")
	 (setq-local ghostel--term-rows 2)
	 ;; Pretend a prior emit dropped one overlay per row of an image
	 ;; that spanned rows 1..4 — those rows are now scrollback.
	 (save-excursion
	   (goto-char (point-min))
	   (dotimes (_ 4)
		 (let ((ov (make-overlay (point) (point))))
		   (overlay-put ov 'ghostel-kitty t)
		   (overlay-put ov 'before-string "OLD"))
		 (forward-line 1)))
	 (setq ghostel--kitty-active t)
	 ;; Re-emit the same placement (image now spans scrollback + viewport).
	 ;; abs-row=0 means image starts at line 1, grid-rows=4 means it
	 ;; covers lines 1..4 — all of which are in scrollback.
	 (ghostel--kitty-display-image "data" nil 0 0 4 4 32 64 0 0 0 0)
	 ;; Each scrollback row should still have exactly ONE overlay (the
	 ;; pre-existing one from the earlier emit).
	 (save-excursion
	   (goto-char (point-min))
	   (dotimes (_ 4)
		 (let* ((p (point))
				(ovs-here (cl-remove-if-not
						   (lambda (o) (and (overlay-get o 'ghostel-kitty)
											(= (overlay-start o) p)))
						   (overlays-in p (1+ p)))))
		   (should (= 1 (length ovs-here))))
		 (forward-line 1))))))

(ert-deftest ghostel-test-kitty-display-virtual-tags-placeholder-line ()
  "Virtual placement scans for U+10EEEE and tags the placeholder region."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (let ((ph (string #x10EEEE)))
	   (insert ph ph ph "\n" ph ph ph "\n"))
	 (ghostel--kitty-display-virtual "data" nil)
	 (should ghostel--kitty-active)
	 (should (get-text-property 1 'display))
	 (should (get-text-property 1 'ghostel-kitty)))))

(ert-deftest ghostel-test-kitty-display-image-records-error ()
  "Display-callback errors are captured to a buffer-local variable.
The error survives past the redraw — not just flashed via `message'."
  (with-temp-buffer
	(cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
			  ((symbol-function 'create-image)
			   (lambda (&rest _) (error "Boom"))))
	  (insert "row\n")
	  (ghostel--kitty-display-image "data" nil 0 0 1 1 8 16 0 0 0 0)
	  (should ghostel--kitty-last-error)
	  (should (eq (car ghostel--kitty-last-error) 'error)))))

(ert-deftest ghostel-test-kitty-display-image-rejects-source-rect ()
  "Non-default source rect is recorded as an error rather than silent miss.
Emacs's image system can't crop pre-scale, so any atlas-style placement
should fail visibly."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "row1xx\nrow2xx\n")
	 ;; src-w=16 != pixel-w=32 → atlas-style sub-rect.
	 (ghostel--kitty-display-image "data" nil 0 0 4 2 32 32 0 0 16 32)
	 (should ghostel--kitty-last-error)
	 ;; The signaled symbol appears in the err data.
	 (should (memq 'ghostel-kitty-unsupported-source-rect
				   (flatten-list ghostel--kitty-last-error))))))

(ert-deftest ghostel-test-kitty-display-image-clamps-negative-vp-col ()
  "Image partially scrolled off the left renders the visible portion.
The buffer range starts at column 0 and the slice's x-origin advances
to skip the off-screen pixels — without this clamp, negative vp-col
would write properties to the previous line."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "abcdefghij\nabcdefghij\n")
	 ;; vp-col = -2: 2 columns scrolled off, 2 visible (g-cols=4).
	 (ghostel--kitty-display-image "data" nil 0 -2 4 1 32 16 0 0 0 0)
	 (should ghostel--kitty-active)
	 (should-not ghostel--kitty-last-error)
	 ;; Display property should land at column 0..2 of the placement
	 ;; line (the visible portion), NOT at column -2 of the previous line.
	 (should (get-text-property (point-min) 'ghostel-kitty)))))

(ert-deftest ghostel-test-kitty-display-image-fully-off-screen-skipped ()
  "When vp-col scrolls the image entirely off the left, render nothing."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "abc\nabc\n")
	 ;; g-cols=4, vp-col=-5 → start-col=5 > g-cols → visible-cols=0.
	 (ghostel--kitty-display-image "data" nil 0 -5 4 1 32 16 0 0 0 0)
	 (should-not ghostel--kitty-active)
	 (should-not ghostel--kitty-last-error))))

(ert-deftest ghostel-test-kitty-graphics-emit-end-to-end ()
  "A kitty transmit-and-place escape reaches `ghostel--kitty-display-image'.
Smoke test for the C boundary: feeds a 1x1 RGB transmission, redraws,
and checks that the elisp callback receives the expected geometry and
unibyte image data.  Without this, protocol-level regressions in the
Zig glue (placement iterator, render-info query, RGBA→PPM conversion)
slip past the unit tests.

FIXME: This stubs `ghostel--kitty-display-image' to capture arguments
crossing the C boundary, so it does not actually exercise the elisp
display path end-to-end.  Letting the real function run in batch would
require a working `create-image' on PPM data and Emacs GUI state; for
now we verify only the arguments the native module hands off."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-kitty-end-to-end*"))
		(calls nil))
	(unwind-protect
		(with-current-buffer buf
		  (let* ((term (ghostel--new 5 40 1000))
				 (inhibit-read-only t))
			;; Kitty graphics needs cell pixel dimensions to compute
			;; placement grid sizes (libghostty's example does this
			;; before sending kitty commands).
			(ghostel--set-size term 5 40 8 16)
			(cl-letf (((symbol-function 'ghostel--kitty-display-image)
					   (lambda (&rest args) (push args calls)))
					  ((symbol-function 'display-graphic-p) (lambda () t)))
			  ;; Kitty transmit-and-place a 1x1 red PNG, quiet=1
			  ;; (suppress success responses).  Payload is the
			  ;; ghostty/example/c-vt-kitty-graphics 1x1 red PNG.
			  (ghostel--write-input
			   term (concat "\e_Ga=T,f=100,q=1;"
							"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA"
							"DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
							"\e\\"))
			  (ghostel--redraw term t))
			(should calls)
			(let ((args (car calls)))
			  ;; (data is-png abs-row vp-col grid-cols grid-rows
			  ;;  pixel-w pixel-h src-x src-y src-w src-h)
			  (should (stringp (nth 0 args)))
			  ;; PPM header starts with "P6" — we converted RGB→PPM in
			  ;; the Zig layer.
			  (should (string-prefix-p "P6" (nth 0 args)))
			  (should (eq (nth 1 args) nil))               ; is-png = nil (PPM)
			  (should (integerp (nth 2 args)))             ; abs-row
			  (should (integerp (nth 3 args)))             ; vp-col
			  (should (>= (nth 4 args) 1))                 ; grid-cols >= 1
			  (should (>= (nth 5 args) 1))                 ; grid-rows >= 1
			  (should (= (nth 6 args) 1))                  ; pixel-w = 1
			  (should (= (nth 7 args) 1)))))               ; pixel-h = 1
	  (kill-buffer buf))))

(provide 'ghostel-kitty-test)
;;; ghostel-kitty-test.el ends here
