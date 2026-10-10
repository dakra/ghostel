;;; ghostel-kitty-test.el --- Kitty graphics tests for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Cell-pixel-scale detection and kitty graphics image display/clear.

;;; Code:

(require 'ghostel-test-helpers)
(require 'cl-lib)

(defun ghostel-test--kitty-fixture (body)
  "Run BODY in a temp buffer with kitty-related primitives faked.
Stubs `display-graphic-p', `create-image', and the font/frame cell
metrics so display callbacks can be exercised in batch.  The frame char
dimensions deliberately differ from the buffer's font dimensions, as
they do under a `default' face remap."
  (with-temp-buffer
    (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
              ((symbol-function 'create-image)
               (lambda (&rest _args) 'fake-image))
              ((symbol-function 'frame-char-width) (lambda (&rest _) 5))
              ((symbol-function 'frame-char-height) (lambda (&rest _) 10))
              ((symbol-function 'default-font-width) (lambda () 8))
              ((symbol-function 'default-font-height) (lambda () 16)))
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

(ert-deftest ghostel-test-reported-cell-dims-multiply-font-by-scale ()
  "Reported cell width/height = the buffer's font dim * scale, rounded.
The frame's char dimensions are not used: a `default' face remap
\(`text-scale-mode', `buffer-face-mode', a `ghostel-default' `:height')
resizes the buffer's font while they stay put.
Uses scale 1.4 (not 1.5) to avoid the half-integer boundary where
Emacs uses banker's rounding."
  (cl-letf (((symbol-function 'frame-char-width) (lambda (&rest _) 5))
            ((symbol-function 'frame-char-height) (lambda (&rest _) 10))
            ((symbol-function 'default-font-width) (lambda () 8))
            ((symbol-function 'default-font-height) (lambda () 16)))
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
	 (ghostel--kitty-display-image "data" 0 0 4 2 32 32)
	 ;; Both rows should have a display property covering them
	 (should (get-text-property 1 'display))
	 (should (get-text-property 1 'ghostel-kitty))
	 (should ghostel--kitty-active)
	 ;; Trailing space outside placement (col 4..6) should not be tagged
	 (should (null (get-text-property 5 'ghostel-kitty))))))

(ert-deftest ghostel-test-kitty-display-image-sized-from-buffer-font ()
  "Placement pixel geometry comes from the buffer's font, not the frame.
Sizing the image and its slices off `frame-char-width'/`frame-char-height'
tiles them at the wrong scale once the `default' face is remapped."
  (let (image-args)
    (with-temp-buffer
      (cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
                ((symbol-function 'create-image)
                 (lambda (&rest args) (setq image-args args) 'fake-image))
                ((symbol-function 'frame-char-width) (lambda (&rest _) 5))
                ((symbol-function 'frame-char-height) (lambda (&rest _) 10))
                ((symbol-function 'default-font-width) (lambda () 8))
                ((symbol-function 'default-font-height) (lambda () 16)))
        (insert "row1xx\nrow2xx\n")
        (ghostel--kitty-display-image "data" 0 0 4 2 32 32)
        (let ((props (nthcdr 3 image-args)))
          (should (= (plist-get props :width) 32))    ; 4 cols * 8
          (should (= (plist-get props :height) 32)))  ; 2 rows * 16
        (should (equal (car (get-text-property 1 'display))
                       '(slice 0 0 32 16)))
        (should (eql (get-text-property 7 'line-height) 16))))))

(ert-deftest ghostel-test-kitty-display-image-empty-line-uses-overlay ()
  "Empty placement range uses an overlay (so the newline isn't eaten)."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "\n\n")
	 (ghostel--kitty-display-image "data" 0 5 4 1 32 16)
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
	 (ghostel--kitty-display-image "data" 0 3 3 2 24 32)
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
	 (ghostel--kitty-display-image "data" 0 0 4 4 32 64)
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

(ert-deftest ghostel-test-kitty-display-virtual-tags-placeholder-run ()
  "A virtual run tags only its own placeholders on its row."
  (ghostel-test--kitty-fixture
   (lambda ()
     (let ((cell (string #x10EEEE #x0305 #x0305)))
       (insert "ab" cell cell cell "\n" "ab" cell cell cell "\n")
       (goto-char (point-min)))
     ;; Last row, image row 1 of a 3x2 image, run of 3 cells from col 0.
     (ghostel--kitty-display-virtual "data" 0 0 1 0 3 3 2)
     (should ghostel--kitty-active)
     ;; Row 0 untouched, text before the run untouched.
     (should-not (get-text-property 1 'display))
     (should-not (get-text-property (line-beginning-position 2) 'display))
     (let ((start (+ (line-beginning-position 2) (length "ab"))))
       (should (get-text-property start 'ghostel-kitty))
       ;; Slice geometry follows the buffer's font: x 0, y row*16, w 3*8.
       (should (equal (car (get-text-property start 'display))
                      '(slice 0 16 24 16)))
       ;; Three cells of three chars each, nothing past them.
       (should (= (+ start 9) (next-single-property-change start 'display)))))))

(ert-deftest ghostel-test-kitty-display-virtual-width-shortfall-skips ()
  "A run wider than the row's remaining placeholders is not tagged."
  (ghostel-test--kitty-fixture
   (lambda ()
     (let ((cell (string #x10EEEE #x0305 #x0305)))
       (insert "ab" cell cell "\n"))
     (ghostel--kitty-display-virtual "data" 0 0 0 0 3 3 1)
     (should-not ghostel--kitty-active))))

(ert-deftest ghostel-test-kitty-display-virtual-nth-selects-run ()
  "A run is located by its placeholder ordinal, not by arrival order."
  (ghostel-test--kitty-fixture
   (lambda ()
     (let ((cell (string #x10EEEE #x0305 #x0305)))
       (insert "ab" cell cell "xy" cell "\n")
       (goto-char (point-min)))
     (let* ((run1 (+ (point-min) (length "ab")))
            (gap (+ run1 6))
            (run2 (+ gap (length "xy"))))
       (ghostel--kitty-display-virtual "right" 0 2 0 0 1 1 1)
       (should-not (get-text-property run1 'display))
       (should (equal (car (get-text-property run2 'display)) '(slice 0 0 8 16)))
       (ghostel--kitty-display-virtual "left" 0 0 0 0 2 2 1)
       (should (equal (car (get-text-property run1 'display)) '(slice 0 0 16 16)))
       ;; The first run's tag ends before the gap text.
       (should (= gap (next-single-property-change run1 'display)))))))

(ert-deftest ghostel-test-kitty-display-image-records-error ()
  "Display-callback errors are captured to a buffer-local variable.
The error survives past the redraw — not just flashed via `message'."
  (ghostel-test--kitty-fixture
   (lambda ()
     (cl-letf (((symbol-function 'create-image)
                (lambda (&rest _) (error "Boom"))))
       (insert "row\n")
       (ghostel--kitty-display-image "data" 0 0 1 1 8 16)
       (should ghostel--kitty-last-error)
       (should (eq (car ghostel--kitty-last-error) 'error))))))

(ert-deftest ghostel-test-kitty-graphics-emit-crops-source-rect ()
  "A placement's source rect reaches Elisp as an already-cropped PPM."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-kitty-crop*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (let ((term (ghostel--new 5 40 1000))
                (inhibit-read-only t))
            (ghostel--set-size term 5 40 1 1)
            (cl-letf (((symbol-function 'ghostel--kitty-display-image)
                       (lambda (&rest args) (push args calls)))
                      ((symbol-function 'display-graphic-p) (lambda () t)))
              (ghostel--write-vt term ghostel-test--kitty-png-2x2)
              ;; Top-right pixel of the fixture is blue.
              (ghostel--write-vt term "\e_Ga=p,i=1,x=1,y=0,w=1,h=1,q=1\e\\")
              (ghostel--redraw term t))
            (should calls)
            (should (equal (car (car calls)) "P6\n1 1\n255\n\0\0\377"))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-kitty-display-image-clamps-negative-vp-col ()
  "Image partially scrolled off the left renders the visible portion.
The buffer range starts at column 0 and the slice's x-origin advances
to skip the off-screen pixels — without this clamp, negative vp-col
would write properties to the previous line."
  (ghostel-test--kitty-fixture
   (lambda ()
	 (insert "abcdefghij\nabcdefghij\n")
	 ;; vp-col = -2: 2 columns scrolled off, 2 visible (g-cols=4).
	 (ghostel--kitty-display-image "data" 0 -2 4 1 32 16)
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
	 (ghostel--kitty-display-image "data" 0 -5 4 1 32 16)
	 (should-not ghostel--kitty-active)
	 (should-not ghostel--kitty-last-error))))

(ert-deftest ghostel-test-kitty-graphics-emit-end-to-end ()
  "A kitty transmit-and-place escape reaches `ghostel--kitty-display-image'.
Smoke test for the C boundary: feeds a 2x2 RGB transmission, redraws,
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
			;; With 1x1 cells, the 2x2 image must occupy a 2x2 grid.
			(ghostel--set-size term 5 40 1 1)
			(cl-letf (((symbol-function 'ghostel--kitty-display-image)
					   (lambda (&rest args) (push args calls)))
					  ((symbol-function 'display-graphic-p) (lambda () t)))
			  (ghostel--write-vt
			   term (concat "\e_Ga=T,f=100,q=1;"
							"iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAA"
							"E0lEQVR4nGP4z8AAQmAKSDAwAAA/0gX7BydG0gAAAABJRU5E"
							"rkJggg==\e\\"))
			  (ghostel--redraw term t))
			(should calls)
			(let ((args (car calls)))
			  ;; (data abs-row vp-col grid-cols grid-rows pixel-w pixel-h)
			  (should (stringp (nth 0 args)))
			  ;; PPM header starts with "P6" — we converted RGB→PPM in
			  ;; the Zig layer.
			  (should (string-prefix-p "P6" (nth 0 args)))
			  (should (integerp (nth 1 args)))             ; abs-row
			  (should (integerp (nth 2 args)))             ; vp-col
			  (should (= (nth 3 args) 2))                  ; grid-cols
			  (should (= (nth 4 args) 2))                  ; grid-rows
			  (should (= (nth 5 args) 2))                  ; pixel-w
			  (should (= (nth 6 args) 2)))))               ; pixel-h
	  (kill-buffer buf))))

(defconst ghostel-test--kitty-png-2x2
  (concat "\e_Ga=t,f=100,i=1,q=1;"
          "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAA"
          "E0lEQVR4nGP4z8AAQmAKSDAwAAA/0gX7BydG0gAAAABJRU5E"
          "rkJggg==\e\\")
  "Transmit a 2x2 PNG as image id 1.")

(defun ghostel-test--kitty-virtual-calls (vt &optional place cell after)
  "Feed VT after a virtual placement and return the virtual callbacks.
PLACE overrides the default 2x2-cell placement command; CELL is the cell
pixel size (default 1).  AFTER is a list of further feeds, each followed
by an unforced redraw; only the last redraw's callbacks are returned."
  (let ((buf (generate-new-buffer " *ghostel-test-kitty-virtual*"))
        (calls nil))
    (unwind-protect
        (with-current-buffer buf
          (let ((term (ghostel--new 5 40 1000)))
            (ghostel--set-size term 5 40 (or cell 1) (or cell 1))
            (cl-letf (((symbol-function 'ghostel--kitty-display-virtual)
                       (lambda (&rest args) (push args calls)))
                      ((symbol-function 'display-graphic-p) (lambda () t)))
              (ghostel--write-vt term (concat ghostel-test--kitty-png-2x2
                                              (or place "\e_Ga=p,i=1,U=1,c=2,r=2,q=1\e\\")
                                              vt))
              (ghostel-test--redraw term t)
              (dolist (more after)
                (ghostel--write-vt term more)
                (setq calls nil)
                (ghostel-test--redraw term)))
            (nreverse calls)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-kitty-virtual-emits-one-call-per-placeholder-row ()
  "Each placeholder row in the viewport yields one callback.
The image row comes from the diacritics, not from buffer line order."
  :tags '(native)
  (let* ((r0 (string #x10EEEE #x0305 #x0305 #x10EEEE #x0305 #x030D))
         (r1 (string #x10EEEE #x030D #x0305 #x10EEEE #x030D #x030D))
         ;; Second image row first, so line order and image row differ.
         (calls (ghostel-test--kitty-virtual-calls
                 (concat "\e[38;5;1m" r1 "\r\n" r0 "\e[39m"))))
    (should (= (length calls) 2))
    ;; (data row-up nth img-row img-col width grid-cols grid-rows);
    ;; rows 0 and 1 of a 5-row screen are 4 and 3 rows above the last.
    (should (string-prefix-p "P6" (nth 0 (car calls))))
    (should (equal (nthcdr 1 (car calls)) '(4 0 1 0 2 2 2)))
    (should (equal (nthcdr 1 (cadr calls)) '(3 0 0 0 2 2 2)))))

(ert-deftest ghostel-test-kitty-virtual-second-image-on-row ()
  "A second image's run reports its ordinal and its own placement.
The placement id comes from the underline colour."
  :tags '(native)
  (let* ((r0 (string #x10EEEE #x0305 #x0305 #x10EEEE #x0305 #x030D))
         (cell (string #x10EEEE #x0305 #x0305))
         (calls (ghostel-test--kitty-virtual-calls
                 (concat (replace-regexp-in-string "i=1" "i=2" ghostel-test--kitty-png-2x2)
                         "\e_Ga=p,i=2,p=7,U=1,c=1,r=1,q=1\e\\"
                         "ab\e[38;5;1m" r0 "\e[39mxy"
                         "\e[38;5;2;58;5;7m" cell "\e[39;59m"))))
    (should (= (length calls) 2))
    (should (equal (nthcdr 1 (car calls)) '(4 0 0 0 2 2 2)))
    (should (equal (nthcdr 1 (cadr calls)) '(4 2 0 0 1 1 1)))))

(ert-deftest ghostel-test-kitty-virtual-grid-falls-back-to-image-size ()
  "Without c=/r= the grid is the image size in cells."
  :tags '(native)
  (let ((calls (ghostel-test--kitty-virtual-calls
                (concat "\e[38;5;1m" (string #x10EEEE #x0305 #x0305) "\e[39m")
                "\e_Ga=p,i=1,U=1,q=1\e\\" 3)))
    ;; A 2px image in 3px cells rounds up to one cell.
    (should (equal (nthcdr 1 (car calls)) '(4 0 0 0 1 1 1)))))

(ert-deftest ghostel-test-kitty-virtual-row-counts-from-bottom ()
  "ROW-UP counts from the last screen row, so scrollback does not shift it."
  :tags '(native)
  (let* ((r0 (string #x10EEEE #x0305 #x0305))
         ;; 8 line feeds on a 5-row terminal: the run is on the last row.
         (calls (ghostel-test--kitty-virtual-calls
                 (concat (make-string 8 ?\n) "\e[38;5;1m" r0 "\e[39m"))))
    (should (= (length calls) 1))
    (should (equal (nthcdr 1 (car calls)) '(0 0 0 0 1 2 2)))))

(ert-deftest ghostel-test-kitty-virtual-run-scrolled-out-since-last-redraw-emits ()
  "A run pushed out of the active area since the previous redraw is tagged."
  :tags '(native)
  (let ((calls (ghostel-test--kitty-virtual-calls
                (concat "\e[38;5;1m" (string #x10EEEE #x0305 #x0305) "\e[39m")
                nil nil (list (make-string 8 ?\n)))))
    (should (= (length calls) 1))
    ;; Screen row 0 with the cursor on row 8.
    (should (equal (nthcdr 1 (car calls)) '(8 0 0 0 1 2 2)))))

(ert-deftest ghostel-test-kitty-virtual-stale-placement-emits-nothing ()
  "A placement whose placeholders left the screen earlier emits nothing."
  :tags '(native)
  (should-not (ghostel-test--kitty-virtual-calls "no placeholders here"))
  (should-not (ghostel-test--kitty-virtual-calls
               (concat "\e[38;5;1m" (string #x10EEEE #x0305 #x0305) "\e[39m")
               nil nil (list (make-string 8 ?\n) ""))))

(provide 'ghostel-kitty-test)
;;; ghostel-kitty-test.el ends here
