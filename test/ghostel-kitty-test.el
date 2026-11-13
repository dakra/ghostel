;;; ghostel-kitty-test.el --- Kitty graphics tests for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Cell geometry and the native row-integrated Kitty renderer.

;;; Code:

(require 'ghostel-test-helpers)
(require 'cl-lib)
(require 'image-mode)

(defvar image-types)
(defvar ghostel--kitty-image-cache)

(defun ghostel-test--kitty-init-storage-limit (graphic &optional dummy)
  "Return the storage limit `ghostel--init-buffer' passes on a GRAPHIC frame.
DUMMY non-nil fakes the daemon's initial frame."
  (let (limit)
    (with-temp-buffer
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) graphic))
                ((symbol-function 'ghostel--daemon-dummy-frame-p) (lambda (_) dummy))
                ((symbol-function 'ghostel--new)
                 (lambda (_h _w _sb storage &rest _)
                   (setq limit storage) 'fake-term))
                ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                ((symbol-function 'ghostel--apply-palette) #'ignore)
                ((symbol-function 'ghostel--apply-bold-config) #'ignore))
        (ghostel--init-buffer (current-buffer) 24 80)))
    limit))

(ert-deftest ghostel-test-kitty-disabled-on-tty-frame ()
  "A terminal frame creates the terminal with kitty graphics disabled."
  (should (eql 0 (ghostel-test--kitty-init-storage-limit nil)))
  (should (eql ghostel-kitty-graphics-storage-limit
               (ghostel-test--kitty-init-storage-limit t)))
  (should (eql ghostel-kitty-graphics-storage-limit
               (ghostel-test--kitty-init-storage-limit nil t))))

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


(defmacro ghostel-test--with-kitty (&rest body)
  "Run BODY with a native TERM and one-pixel cells in a fresh buffer.
Image/display availability and font metrics are faked; PNG encoding,
image specifications, row projection, properties, and caching use
production code."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (let ((term (ghostel--new 5 20 1000))
           (image-types '(png))
           (inhibit-read-only t))
       (ghostel--set-size term 5 20 1 1)
       (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                 ((symbol-function 'image-type-available-p) (lambda (type) (eq type 'png)))
                 ((symbol-function 'fontp) (lambda (&rest _) nil))
                 ((symbol-function 'default-font-width) (lambda () 1))
                 ((symbol-function 'default-font-height) (lambda () 1)))
         ,@body))))

(defun ghostel-test--kitty-transmit (id rgba &optional width height)
  "Transmit RGBA pixels as image ID, with optional WIDTH and HEIGHT."
  (format "\e_Ga=t,f=32,i=%d,s=%d,v=%d,q=2;%s\e\\"
          id (or width 1) (or height 1)
          (base64-encode-string (apply #'unibyte-string rgba) t)))

(defun ghostel-test--kitty-place (id &optional keys)
  "Place image ID without moving the cursor, with additional KEYS."
  (format "\e_Ga=p,i=%d,C=1,q=2%s\e\\" id (if keys (concat "," keys) "")))

(defun ghostel-test--kitty-display-at (row col)
  "Return the image display specification at terminal ROW and COL."
  (save-excursion
    (goto-char (point-min))
    (forward-line row)
    (move-to-column col)
    (get-text-property (point) 'display)))

(defun ghostel-test--kitty-image-at (row col)
  "Return the cached row image displayed at terminal ROW and COL."
  (cadr (ghostel-test--kitty-display-at row col)))

(defun ghostel-test--kitty-display-size (display)
  "Return DISPLAY's slice dimensions, checking its bounds against the PNG."
  (pcase-let ((`((slice ,x ,y ,width ,height) ,image) display))
    (let ((data (image-property image :data)))
      (cl-labels ((be32 (offset)
                    (let ((n 0))
                      (dotimes (i 4)
                        (setq n (+ (ash n 8) (aref data (+ offset i)))))
                      n)))
        (should (equal (substring data 0 8) (unibyte-string 137 80 78 71 13 10 26 10)))
        (should (<= 0 x))
        (should (<= 0 y))
        (should (<= (+ x width) (be32 16)))
        (should (<= (+ y height) (be32 20)))
        (cons width height)))))

(ert-deftest ghostel-test-kitty-pads-empty-rows ()
  "Image extents preserve spaces that normal row rendering would trim."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat "\e[6G"
                               (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                               (ghostel-test--kitty-place 1 "c=4,r=2")))
    (ghostel-test--redraw term)
    (should (equal (car (split-string (buffer-string) "\n")) (make-string 9 ?\s)))
    (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 5)) '(4 . 1)))
    (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 1 5)) '(4 . 1)))
    (should-not (ghostel-test--kitty-image-at 0 4))))

(ert-deftest ghostel-test-kitty-delete-repaints-without-text-change ()
  "Deleting only a placement removes its properties and synthetic padding."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat "text\e[H"
                                    (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1 "c=8,r=1")))
    (ghostel-test--redraw term)
    (should (ghostel-test--kitty-image-at 0 0))
    (ghostel--write-vt term "\e_Ga=d,d=a,q=2\e\\")
    (ghostel-test--redraw term)
    (should-not (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil))
    (should (equal (car (split-string (buffer-string) "\n")) "text"))))

(ert-deftest ghostel-test-kitty-move-repaints-and-reuses-content ()
  "Moving a placement with a restored cursor dirties its old and new coverage."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat "0123456789\e[H"
                                    (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1 "p=1,c=2,r=1")))
    (ghostel-test--redraw term)
    (let ((image (ghostel-test--kitty-image-at 0 0)))
      (ghostel--write-vt term (concat "\e7\e[7G" (ghostel-test--kitty-place 1 "p=1,c=2,r=1") "\e8"))
      (ghostel-test--redraw term)
      (should-not (ghostel-test--kitty-image-at 0 0))
      (should (eq image (ghostel-test--kitty-image-at 0 6))))))

(ert-deftest ghostel-test-kitty-retransmit-invalidates-same-sized-content ()
  "Image IDs and dimensions alone cannot identify the cached pixels."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((old (ghostel-test--kitty-image-at 0 0)))
      (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(0 0 255 255))
                                      (ghostel-test--kitty-place 1)))
      (ghostel-test--redraw term)
      (should-not (equal (image-property old :data)
                         (image-property (ghostel-test--kitty-image-at 0 0) :data))))))

(ert-deftest ghostel-test-kitty-alpha-overlap-and-negative-z ()
  "Source-over respects z order, including the foreground approximation for negative z."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat (ghostel-test--kitty-transmit 1 '(128 0 127 255))
                               (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((expected (image-property (ghostel-test--kitty-image-at 0 0) :data)))
      (ghostel--write-vt term
			 (concat "\e_Ga=d,d=A,q=2\e\\"
				 (ghostel-test--kitty-transmit 2 '(0 0 255 255))
				 (ghostel-test--kitty-transmit 3 '(255 0 0 128))
				 (ghostel-test--kitty-place 3 "z=-1")
				 (ghostel-test--kitty-place 2 "z=-2")))
      (ghostel-test--redraw term)
      (should (equal expected (image-property (ghostel-test--kitty-image-at 0 0) :data))))))

(ert-deftest ghostel-test-kitty-transparent-upper-layer-keeps-lower-image ()
  "An upper rectangle does not occlude lower content when its alpha is zero."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(0 0 255 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((expected (image-property (ghostel-test--kitty-image-at 0 0) :data)))
      (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 2 '(255 0 0 0))
                                      (ghostel-test--kitty-place 2 "z=1")))
      (ghostel-test--redraw term)
      (should (equal expected (image-property (ghostel-test--kitty-image-at 0 0) :data))))))

(ert-deftest ghostel-test-kitty-equal-z-orders-by-image-id ()
  "Higher image IDs win equal-z opaque overlaps regardless of placement insertion."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 9 '(0 0 255 255))
                                    (ghostel-test--kitty-place 9)))
    (ghostel-test--redraw term)
    (let ((expected (image-property (ghostel-test--kitty-image-at 0 0) :data)))
      (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                      (ghostel-test--kitty-place 1)))
      (ghostel-test--redraw term)
      (should (equal expected (image-property (ghostel-test--kitty-image-at 0 0) :data))))))

(ert-deftest ghostel-test-kitty-transparent-cells-leave-text-alone ()
  "Whole-cell alpha holes leave underlying text and styles undisplayed by images."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat "abc\e[H"
                               (ghostel-test--kitty-transmit 1 '(255 0 0 255 0 255 0 0 0 0 255 255) 3 1)
                               (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (should (ghostel-test--kitty-image-at 0 0))
    (should-not (ghostel-test--kitty-image-at 0 1))
    (should (ghostel-test--kitty-image-at 0 2))
    (should (equal (car (split-string (buffer-string) "\n")) "abc"))))

(ert-deftest ghostel-test-kitty-native-size-and-intracell-offset ()
  "A natural-size pixel is padded, not stretched to the occupied cell."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--set-size term 5 20 2 2)
    (cl-letf (((symbol-function 'default-font-width) (lambda () 2))
              ((symbol-function 'default-font-height) (lambda () 2)))
      (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                      (ghostel-test--kitty-place 1 "X=1,Y=1")))
      (ghostel-test--redraw term)
      (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 0)) '(2 . 2)))
      (let ((offset (image-property (ghostel-test--kitty-image-at 0 0) :data)))
        (ghostel--write-vt term
                           (concat "\e_Ga=d,d=A,q=2\e\\\e[H"
                                   (ghostel-test--kitty-transmit
                                    2 '(0 0 0 0 0 0 0 0 0 0 0 0 255 0 0 255) 2 2)
                                   (ghostel-test--kitty-place 2)))
        (ghostel-test--redraw term)
        (should (equal offset (image-property (ghostel-test--kitty-image-at 0 0) :data)))))))

(ert-deftest ghostel-test-kitty-crops-before-scaling ()
  "A source crop produces the same output as transmitting only that source pixel."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(0 0 255 255))
                                    (ghostel-test--kitty-place 1 "c=3,r=1")))
    (ghostel-test--redraw term)
    (let ((expected (image-property (ghostel-test--kitty-image-at 0 0) :data)))
      (ghostel--write-vt term
			 (concat "\e_Ga=d,d=A,q=2\e\\"
				 (ghostel-test--kitty-transmit 2 '(255 0 0 255 0 0 255 255 0 255 0 255 255 255 255 255) 2 2)
				 (ghostel-test--kitty-place 2 "x=1,y=0,w=1,h=1,c=3,r=1")))
      (ghostel-test--redraw term)
      (should (equal expected (image-property (ghostel-test--kitty-image-at 0 0) :data))))))

(ert-deftest ghostel-test-kitty-maps-wide-and-combining-text ()
  "An image at column four replaces x after combining and double-width text."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat "á界x\e[4G"
                                    (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (should (get-text-property 4 'ghostel-kitty))
    (should-not (get-text-property 3 'ghostel-kitty))
    (should (equal (buffer-substring-no-properties 1 5) "á界x"))))

(ert-deftest ghostel-test-kitty-row-placeholder-plans-merge-and-track-image-only-changes ()
  "Row-local placeholders merge with pinned layers and react without text changes."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat (ghostel-test--kitty-transmit 1 '(0 0 255 255))
                               (ghostel-test--kitty-place 1 "z=-1")))
    (ghostel-test--redraw term)
    (let ((blue (image-property (ghostel-test--kitty-image-at 0 0) :data)))
      (ghostel--write-vt term
                         (concat (ghostel-test--kitty-transmit 9 '(128 0 127 255))
                                 (ghostel-test--kitty-place 9 "z=1")))
      (ghostel-test--redraw term)
      (let ((purple (image-property (ghostel-test--kitty-image-at 0 0) :data)))
        (ghostel--write-vt term
                           (concat "\e_Ga=d,d=I,i=9,q=2\e\\"
                                   (ghostel-test--kitty-transmit 2 '(255 0 0 128))
                                   (ghostel-test--kitty-place 2 "U=1,c=1,r=1")
                                   "\e[38;5;2m" (string #x10eeee #x0305 #x0305)))
        (ghostel-test--redraw term)
        (should (equal purple (image-property (ghostel-test--kitty-image-at 0 0) :data)))
        (ghostel--write-vt term
                           (concat (ghostel-test--kitty-transmit 2 '(0 255 0 128))
                                   (ghostel-test--kitty-place 2 "U=1,c=1,r=1")))
        (ghostel-test--redraw term)
        (should-not (equal purple (image-property (ghostel-test--kitty-image-at 0 0) :data))))
      (ghostel--write-vt term "\e_Ga=d,d=I,i=2,q=2\e\\")
      (ghostel-test--redraw term)
      (should (equal blue (image-property (ghostel-test--kitty-image-at 0 0) :data)))
      (ghostel--write-vt term "\e_Ga=d,d=A,q=2\e\\")
      (ghostel-test--redraw term)
      (should-not (get-text-property 1 'ghostel-kitty)))))

(ert-deftest ghostel-test-kitty-disjoint-placeholder-runs ()
  "Two image fragments share a row while the text between them remains visible."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255 0 0 255 255) 2 1)
                               (ghostel-test--kitty-place 1 "U=1,c=2,r=1")
                               "\e[38;5;1m"
                               (string #x10eeee #x0305 #x0305)
                               "xy"
                               (string #x10eeee #x0305 #x030d)
                               "\e[0m"))
    (ghostel-test--redraw term)
    (should (equal (car (split-string (buffer-string) "\n")) " xy "))
    (should (get-text-property 1 'ghostel-kitty))
    (should-not (get-text-property 2 'ghostel-kitty))
    (should (get-text-property 4 'ghostel-kitty))
    (should (eq (ghostel-test--kitty-image-at 0 0) (ghostel-test--kitty-image-at 0 3)))
    (should-not (equal (get-text-property 1 'display) (get-text-property 4 'display)))))

(ert-deftest ghostel-test-kitty-explicit-placeholder-target-must-be-virtual ()
  "Placeholders cannot target a pinned placement with the same explicit ID."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                               "\e[3;1H"
                               (ghostel-test--kitty-place 1 "p=7")
                               "\e[H\e[38;5;1;58;5;7m"
                               (string #x10eeee #x0305 #x0305)))
    (ghostel-test--redraw term)
    (should-not (get-text-property 1 'ghostel-kitty))
    (should (ghostel-test--kitty-image-at 2 0))))

(ert-deftest ghostel-test-kitty-relative-clips-left-and-skips-offscreen ()
  "Relative placements use the root pin and clip their negative cell offsets."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                               (ghostel-test--kitty-place 1 "p=1,c=2,r=1")
                               (ghostel-test--kitty-place 1 "p=2,P=1,Q=1,H=-2,V=1,c=4,r=1")
                               (ghostel-test--kitty-place 1 "p=3,P=1,Q=1,H=200,V=2,c=4,r=1")))
    (ghostel-test--redraw term)
    (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 1 0)) '(2 . 1)))
    (should-not (ghostel-test--kitty-image-at 2 0))))

(ert-deftest ghostel-test-kitty-rows-leaving-active-area-between-redraws ()
  "Both pinned and placeholder rows are rendered during batched scrolling."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel-test--redraw term)
    (ghostel--write-vt term
                       (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                               (ghostel-test--kitty-place 1 "p=1")
                               "\r\n"
                               (ghostel-test--kitty-place 1 "U=1,c=1,r=1")
                               "\e[38;5;1m" (string #x10eeee #x0305 #x0305)
                               "\e[0m" (make-string 10 ?\n)))
    (ghostel-test--redraw term)
    (should (ghostel-test--kitty-image-at 0 0))
    (should (ghostel-test--kitty-image-at 1 0))))

(ert-deftest ghostel-test-kitty-cache-hit-survives-ordinary-row-rewrite ()
  "Rebuilding a text row reuses the Lisp-owned descriptor without encoding again."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((image (ghostel-test--kitty-image-at 0 0))
          (create (symbol-function 'create-image))
          (calls 0))
      (cl-letf (((symbol-function 'create-image)
                 (lambda (&rest args) (cl-incf calls) (apply create args))))
	(ghostel--write-vt term "\e[3Gx")
	(ghostel-test--redraw term))
      (should (= calls 0))
      (should (eq image (ghostel-test--kitty-image-at 0 0)))
      (should (local-variable-p 'ghostel--kitty-image-cache)))))

(ert-deftest ghostel-test-kitty-wide-layout-adjusts-raster-bounds-at-terminal-edges ()
  "Image bounds cover whole wide characters and shrink when narrow text replaces them."
  :tags '(native)
  (dolist (case '((0 0) (0 1) (18 18) (18 19)))
    (pcase-let ((`(,wide-col ,image-col) case))
      (ghostel-test--with-kitty
        (ghostel--write-vt term
                           (concat (format "\e[%dG界%s\e[%dG"
                                           (1+ wide-col) (if (= wide-col 0) "x" "") (1+ image-col))
                                   (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                   (ghostel-test--kitty-place 1)))
        (ghostel-test--redraw term)
        (let ((image (ghostel-test--kitty-image-at 0 wide-col))
              (create (symbol-function 'create-image))
              (calls 0))
          (should (equal (car (ghostel-test--kitty-display-at 0 wide-col)) '(slice 0 0 2 1)))
          (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 wide-col)) '(2 . 1)))
          (when (= wide-col 0)
            (should-not (get-text-property 2 'ghostel-kitty)))
          (cl-letf (((symbol-function 'create-image)
                     (lambda (&rest args) (cl-incf calls) (apply create args))))
            (ghostel--write-vt term (format "\e[%dGab" (1+ wide-col)))
            (ghostel-test--redraw term)
            (should (= calls 1))
            (should-not (eq image (ghostel-test--kitty-image-at 0 image-col)))
            (should (equal (car (ghostel-test--kitty-display-at 0 image-col)) '(slice 0 0 1 1)))
            (ghostel--write-vt term (format "\e[%dG界" (1+ wide-col)))
            (ghostel-test--redraw term)
            (should (= calls 1))
            (should (eq image (ghostel-test--kitty-image-at 0 wide-col)))
            (should (equal (car (ghostel-test--kitty-display-at 0 wide-col)) '(slice 0 0 2 1))))
          (should (= (hash-table-count ghostel--kitty-image-cache) 2)))))))

(ert-deftest ghostel-test-kitty-span-visibility-follows-whole-glyphs ()
  "Either visible half selects a wide glyph; transparent glyphs stay outside spans."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat "界界\e[H"
                               (ghostel-test--kitty-transmit
                                1 '(255 0 0 255 0 0 0 0 0 0 0 0 0 0 255 255) 4 1)
                               (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((image (ghostel-test--kitty-image-at 0 0))
          (create (symbol-function 'create-image))
          (calls 0))
      (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 0)) '(4 . 1)))
      (cl-letf (((symbol-function 'create-image)
                 (lambda (&rest args) (cl-incf calls) (apply create args))))
        (dolist (text '("a界b" "abcd"))
          (ghostel--write-vt term (concat "\e[H" text))
          (ghostel-test--redraw term)
          (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 0)) '(1 . 1)))
          (should-not (ghostel-test--kitty-display-at 0 1))
          (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 3)) '(1 . 1)))
          (should (eq image (ghostel-test--kitty-image-at 0 0)))
          (should (eq image (ghostel-test--kitty-image-at 0 3)))))
      (should (= calls 0))
      (should (= (hash-table-count ghostel--kitty-image-cache) 1)))))

(ert-deftest ghostel-test-kitty-wide-layout-reuses-raster ()
  "Changing text width rebuilds slices without compositing or encoding a new image."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat "abx\e[H"
                               (ghostel-test--kitty-transmit 1 '(255 0 0 255 0 0 255 0) 2 1)
                               (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((image (ghostel-test--kitty-image-at 0 0))
          (create (symbol-function 'create-image))
          (calls 0))
      (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 0)) '(1 . 1)))
      (cl-letf (((symbol-function 'create-image)
                 (lambda (&rest args) (cl-incf calls) (apply create args))))
        (ghostel--write-vt term "\e[H界")
        (ghostel-test--redraw term)
        (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 0)) '(2 . 1)))
        (should (eq image (ghostel-test--kitty-image-at 0 0)))
        (ghostel--write-vt term "\e[HAB")
        (ghostel-test--redraw term)
        (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 0)) '(1 . 1)))
        (should-not (ghostel-test--kitty-display-at 0 1)))
      (should (= calls 0))
      (should (eq image (ghostel-test--kitty-image-at 0 0)))
      (should (= (hash-table-count ghostel--kitty-image-cache) 1)))))

(ert-deftest ghostel-test-kitty-historical-plans-realize-only-when-requested ()
  "Historical image updates stay unencoded until a redraw requests those rows."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1 "U=1,c=1,r=1")
                                    "\e[38;5;1m" (string #x10eeee #x0305 #x0305)))
    (ghostel-test--redraw term)
    (ghostel--write-vt term (make-string 10 ?\n))
    (ghostel-test--redraw term)
    (let ((old (ghostel-test--kitty-image-at 0 0))
          (create (symbol-function 'create-image))
          (calls 0))
      (should old)
      (clrhash ghostel--kitty-image-cache)
      (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(0 0 255 255))
                                      (ghostel-test--kitty-place 1 "U=1,c=1,r=1")))
      (cl-letf (((symbol-function 'create-image)
                 (lambda (&rest args)
                   (cl-incf calls)
                   (apply create args))))
        (ghostel-test--redraw term)
        (should (= calls 0))
        (should (= (hash-table-count ghostel--kitty-image-cache) 0))
        (ghostel-test--redraw term t)
        (should (= calls 1)))
      (should-not (equal (image-property old :data)
                         (image-property (ghostel-test--kitty-image-at 0 0) :data))))))

(ert-deftest ghostel-test-kitty-cache-clears-wholesale-at-limit ()
  "A cache miss at the fixed cap clears all entries without invalidating shown images."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((old (ghostel-test--kitty-image-at 0 0)))
      (dotimes (i 255) (puthash i t ghostel--kitty-image-cache))
      (should (= (hash-table-count ghostel--kitty-image-cache) 256))
      (ghostel--write-vt term (concat "\e[2H"
                                      (ghostel-test--kitty-transmit 2 '(0 0 255 255))
                                      (ghostel-test--kitty-place 2)))
      (ghostel-test--redraw term)
      (should (= (hash-table-count ghostel--kitty-image-cache) 1))
      (garbage-collect)
      (should (eq old (ghostel-test--kitty-image-at 0 0)))
      (should (image-property old :data)))))

(ert-deftest ghostel-test-kitty-fully-transparent-row-is-cached ()
  "Transparent image results are cached and reused when the text changes."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(0 0 255 0))
                                    (ghostel-test--kitty-place 1 "c=4,r=1")))
    (ghostel-test--redraw term)
    (should (= (hash-table-count ghostel--kitty-image-cache) 1))
    (should-not (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil))
    (should (equal (car (split-string (buffer-string) "\n")) ""))
    (let ((cached (car (hash-table-values ghostel--kitty-image-cache))))
      (ghostel--write-vt term "\e[Htext")
      (ghostel-test--redraw term)
      (should (= (hash-table-count ghostel--kitty-image-cache) 1))
      (should (eq cached (car (hash-table-values ghostel--kitty-image-cache))))
      (should-not (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil))
      (should (equal (car (split-string (buffer-string) "\n")) "text")))))

(ert-deftest ghostel-test-kitty-screen-reset-and-full-redraw ()
  "Reset drops native plans without retaining references to freed pages or image bytes."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (ghostel--write-vt term "\ec")
    (ghostel-test--redraw term t)
    (should-not (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil))))

(ert-deftest ghostel-test-kitty-creation-error-is-retried ()
  "An image error propagates, and the next redraw retries the dirty row."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (cl-letf (((symbol-function 'create-image) (lambda (&rest _) (error "Image failure"))))
      (should-error (ghostel-test--redraw term)))
    (ghostel-test--redraw term)
    (should (ghostel-test--kitty-image-at 0 0))))

(ert-deftest ghostel-test-kitty-placeholder-bands-share-full-transform ()
  "Placeholder rows sample the same full-image transform as a pinned placement."
  :tags '(native)
  (ghostel-test--with-kitty
    (let ((rgba '(255 0 0 255 0 0 255 255 0 255 0 255 255 255 255 255))
          (marks [#x0305 #x030d #x030e #x0310])
          expected)
      (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 rgba 2 2)
                                      (ghostel-test--kitty-place 1 "c=4,r=4")))
      (ghostel-test--redraw term)
      (dotimes (row 4)
	(push (image-property (ghostel-test--kitty-image-at row 0) :data) expected))
      (setq expected (nreverse expected))
      (ghostel--write-vt term
                         (concat "\e_Ga=d,d=A,q=2\e\\\e[2J\e[H"
                                 (ghostel-test--kitty-transmit 2 rgba 2 2)
                                 (ghostel-test--kitty-place 2 "U=1,c=4,r=4")
                                 "\e[38;5;2m"))
      (dotimes (row 4)
	(dotimes (col 4)
          (ghostel--write-vt term (string #x10eeee (aref marks row) (aref marks col))))
	(ghostel--write-vt term "\r\n"))
      (ghostel-test--redraw term)
      (dotimes (row 4)
	(should (equal (nth row expected)
                       (image-property (ghostel-test--kitty-image-at row 0) :data)))))))

(ert-deftest ghostel-test-kitty-placeholder-prototype-ignores-source-crops ()
  "Virtual prototypes always fit the full image, regardless of source-crop fields."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat (ghostel-test--kitty-transmit
				1 '(255 0 0 255 0 0 255 255 0 255 0 255 255 255 255 255) 2 2)
                               (ghostel-test--kitty-place 1 "U=1,c=2,r=2")
                               "\e[38;5;1m"
                               (string #x10eeee #x0305 #x0305 #x10eeee #x0305 #x030d)
                               "\r\n"
                               (string #x10eeee #x030d #x0305 #x10eeee #x030d #x030d)
                               "\r\n\e[0m"))
    (ghostel-test--redraw term)
    (let ((images (list (ghostel-test--kitty-image-at 0 0)
                        (ghostel-test--kitty-image-at 1 0))))
      (dolist (crop '("x=1,y=1,w=1,h=1"
                      "x=0,y=0,w=1,h=1"
                      "x=4294967295,y=4294967295,w=1,h=1"))
        (ghostel--write-vt term (concat "\e7\e[H"
					(ghostel-test--kitty-place 1 (concat "U=1,c=2,r=2," crop))
					"\e8"))
        (ghostel-test--redraw term t)
        (dotimes (row 2)
          (should (nth row images))
          (should (eq (nth row images) (ghostel-test--kitty-image-at row 0))))))))

(ert-deftest ghostel-test-kitty-placeholder-coordinates-select-image-fragment ()
  "Placeholder coordinates select fragments of the full image."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(0 0 255 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((blue (image-property (ghostel-test--kitty-image-at 0 0) :data)))
      (ghostel--write-vt term
                         (concat "\e_Ga=d,d=A,q=2\e\\\e[2J\e[H"
                                 (ghostel-test--kitty-transmit 2 '(255 0 0 255 0 0 255 255) 2 1)
                                 (ghostel-test--kitty-place 2 "U=1,c=2,r=1")
                                 "\e[38;5;2m" (string #x10eeee #x0305 #x030d)))
      (ghostel-test--redraw term)
      (should (equal blue (image-property (ghostel-test--kitty-image-at 0 0) :data))))))

(ert-deftest ghostel-test-kitty-wrap-spacer-can-carry-an-image ()
  "A wide glyph's wrap-padding cell can still display a pinned image."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--set-size term 5 4 1 1)
    (ghostel-test--redraw term)
    (ghostel--write-vt term (concat "abc界\e[1;4H"
                                    (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (should (ghostel-test--kitty-image-at 0 3))
    (should (equal (car (split-string (buffer-string) "\n")) "abc "))))

(ert-deftest ghostel-test-kitty-shrink-clips-and-grow-reuses-row-image ()
  "Shrinking clips an image; restoring the width reuses the cached full image."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat "\e[7G"
                                    (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1 "c=8,r=1")))
    (ghostel-test--redraw term)
    (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 6)) '(8 . 1)))
    (let ((image (ghostel-test--kitty-image-at 0 6)))
      (ghostel--set-size term 5 10 1 1)
      (ghostel-test--redraw term)
      (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 6)) '(4 . 1)))
      (ghostel--set-size term 5 20 1 1)
      (ghostel-test--redraw term)
      (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 6)) '(8 . 1)))
      (should (eq image (ghostel-test--kitty-image-at 0 6))))))

(ert-deftest ghostel-test-kitty-screen-switch-keeps-state-independent ()
  "Alternate-screen plans cannot leak into the primary screen or reuse freed pins."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (let ((image (ghostel-test--kitty-image-at 0 0)))
      (ghostel--write-vt term "\e[?1049h")
      (ghostel-test--redraw term)
      (should-not (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil))
      (ghostel--write-vt term "\e[?1049l")
      (ghostel-test--redraw term)
      (should (eq image (ghostel-test--kitty-image-at 0 0))))))

(ert-deftest ghostel-test-kitty-scrollback-eviction-removes-image-properties ()
  "Images disappear when their rows are evicted from scrollback."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                    (ghostel-test--kitty-place 1)))
    (ghostel-test--redraw term)
    (ghostel--write-vt term (apply #'concat (make-list 5000 "line\r\n")))
    (ghostel-test--redraw term)
    (should-not (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil))))

(ert-deftest ghostel-test-kitty-oversized-virtual-grid-does-not-block-text ()
  "Unrepresentable virtual geometry is omitted without poisoning later redraws."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--set-size term 5 20 2 2)
    (cl-letf (((symbol-function 'default-font-width) (lambda () 2))
              ((symbol-function 'default-font-height) (lambda () 2)))
      (dolist (grid '("c=4294967295,r=1" "c=1,r=4294967295"))
	(ghostel--write-vt term
                           (concat "\e_Ga=d,d=A,q=2\e\\\e[2J\e[H"
                                   (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                   (ghostel-test--kitty-place 1 (concat "U=1," grid))
                                   "\e[38;5;1m" (string #x10eeee #x0305 #x0305)
                                   "\e[0m text"))
	(ghostel-test--redraw term)
	(ghostel--write-vt term " still works")
	(ghostel-test--redraw term t)
	(should (string-match-p "text still works" (buffer-string)))
	(should-not (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil))))))

(ert-deftest ghostel-test-kitty-resampler-budget-keeps-other-layers-and-text ()
  "Resizing 1x10000 to 800x1 exceeds the budget but leaves text and other images."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--set-size term 5 800 1 1)
    (ghostel--write-vt term
                       (concat "ok\e[H"
                               (ghostel-test--kitty-transmit 1 (apply #'append (make-list 10000 '(255 0 0 255))) 1 10000)
                               (ghostel-test--kitty-place 1 "c=800,r=1")
                               (ghostel-test--kitty-transmit 2 '(0 0 255 255))
                               (ghostel-test--kitty-place 2 "z=1")))
    (ghostel-test--redraw term)
    (should (equal (car (split-string (buffer-string) "\n")) "ok"))
    (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 0)) '(1 . 1)))))

(ert-deftest ghostel-test-kitty-row-canvas-budget-does-not-block-text ()
  "An excessive row canvas leaves normal text projection intact."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--set-size term 5 20 4096 4096)
    (cl-letf (((symbol-function 'default-font-width) (lambda () 4096))
              ((symbol-function 'default-font-height) (lambda () 4096)))
      (ghostel--write-vt term (concat "ok\e[H"
                                      (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                      (ghostel-test--kitty-place 1 "c=4,r=2")))
      (ghostel-test--redraw term)
      (should (equal (car (split-string (buffer-string) "\n")) "ok"))
      (should-not (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil)))))

(ert-deftest ghostel-test-kitty-unresolved-placeholders-project-as-spaces ()
  "Placeholders and their diacritics become styled spaces even without graphics."
  :tags '(native)
  (dolist (graphic '(nil t))
    (ghostel-test--with-kitty
      (ghostel--write-vt term
                         (concat "a\e[48;2;17;34;51m"
                                 (string #x10eeee)
                                 (string #x10eeee #x0305 #x0305 #x0305)
                                 "\e[0mb"))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) graphic)))
	(ghostel-test--redraw term)
	(should (equal (car (split-string (buffer-string) "\n")) "a  b"))
	(should (equal ghostel--cursor-pos '(4 . 0)))
	(should (equal (plist-get (get-text-property 2 'face) :background) "#112233"))
	(should-not (text-property-not-all (point-min) (point-max) 'display nil))))))

(ert-deftest ghostel-test-kitty-transparent-placeholder-cells-stay-hidden ()
  "Only image pixels need display spans; transparent placeholders are plain spaces."
  :tags '(native)
  (ghostel-test--with-kitty
    (let ((marks [#x0305 #x030d #x030e]))
      (ghostel--write-vt term
                         (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255 0 255 0 0 0 0 255 255) 3 1)
                                 (ghostel-test--kitty-place 1 "U=1,c=3,r=1")
                                 "\e[38;5;1m"))
      (dotimes (col 3)
	(ghostel--write-vt term (string #x10eeee #x0305 (aref marks col))))
      (ghostel-test--redraw term)
      (should (equal (car (split-string (buffer-string) "\n")) "   "))
      (should (get-text-property 1 'ghostel-kitty))
      (should-not (get-text-property 2 'display))
      (should (get-text-property 3 'ghostel-kitty))
      (should (equal (ghostel-test--kitty-display-size (get-text-property 1 'display)) '(1 . 1))))))

(ert-deftest ghostel-test-kitty-horizontal-letterbox-hides-placeholder-padding ()
  "Padding around the fitted image is plain spaces without image descriptors."
  :tags '(native)
  (ghostel-test--with-kitty
    (let ((marks [#x0305 #x030d #x030e #x0310 #x0312 #x033d]))
      (ghostel--write-vt term
                         (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                 (ghostel-test--kitty-place 1 "U=1,c=6,r=1")
                                 "\e[38;5;1m"))
      (dotimes (col 6)
	(ghostel--write-vt term (string #x10eeee #x0305 (aref marks col))))
      (ghostel-test--redraw term)
      (should (equal (car (split-string (buffer-string) "\n")) "      "))
      (dotimes (col 6)
	(should (eq (not (null (get-text-property (1+ col) 'ghostel-kitty))) (= col 2))))
      (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at 0 2)) '(1 . 1))))))

(ert-deftest ghostel-test-kitty-vertical-letterbox-hides-fully-empty-row ()
  "A placeholder row wholly outside the source image is spaces without a display."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--set-size term 5 20 1 2)
    (cl-letf (((symbol-function 'default-font-height) (lambda () 2)))
      (let ((marks [#x0305 #x030d #x030e]))
	(ghostel--write-vt term
                           (concat (ghostel-test--kitty-transmit 1 '(255 0 0 255))
                                   (ghostel-test--kitty-place 1 "U=1,c=3,r=3")
                                   "\e[38;5;1m"))
	(dotimes (row 3)
          (dotimes (col 3)
            (ghostel--write-vt term (string #x10eeee (aref marks row) (aref marks col))))
          (ghostel--write-vt term "\r\n"))
	(ghostel-test--redraw term)
	(should (equal (seq-take (split-string (buffer-string) "\n") 3) '("   " "   " "   ")))
	(dotimes (row 2)
          (should (equal (ghostel-test--kitty-display-size (ghostel-test--kitty-display-at row 0)) '(3 . 2))))
	(should-not (ghostel-test--kitty-image-at 2 0))))))

(ert-deftest ghostel-test-kitty-disjoint-transparent-placeholders-leave-text-gap ()
  "Transparent placeholder runs become spaces and leave intervening text alone."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat (ghostel-test--kitty-transmit 1 '(255 0 0 0 255 0 0 0 255 0 0 0) 3 1)
                               (ghostel-test--kitty-place 1 "U=1,c=3,r=1")
                               "\e[38;5;1m" (string #x10eeee #x0305 #x0305)
                               "\e[0mb\e[38;5;1m" (string #x10eeee #x0305 #x030e)))
    (ghostel-test--redraw term)
    (should (equal (car (split-string (buffer-string) "\n")) " b "))
    (should-not (text-property-not-all (point-min) (point-max) 'display nil))))

(ert-deftest ghostel-test-kitty-gui-image-dimensions-and-row-pitch ()
  "A four-column image has the expected pixel width and one-row slice height."
  :tags '(native)
  (skip-unless (display-graphic-p))
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (let* ((cw (default-font-width))
             (ch (default-font-height))
             (term (ghostel--new 5 20 1000))
             (inhibit-read-only t))
        (ghostel--set-size term 5 20 cw ch)
        (ghostel--write-vt term (concat "\e[4G"
					(ghostel-test--kitty-transmit 1 '(255 0 0 128))
					(ghostel-test--kitty-place 1 "c=4,r=2")))
        (ghostel-test--redraw term)
        (goto-char (point-min))
        (redisplay t)
        (should (equal (image-display-size (ghostel-test--kitty-display-at 0 3) t)
                       (cons (* 4 cw) ch)))
        (let* ((first (posn-at-point (+ (point-min) 3)))
               (second (save-excursion
                         (forward-line 1)
                         (posn-at-point (+ (point) 3)))))
          (should first)
          (should second)
          (should (= (- (cdr (posn-x-y second)) (cdr (posn-x-y first))) ch)))))))

(ert-deftest ghostel-test-kitty-gui-transparent-placeholders-preserve-row-pitch ()
  "Transparent and letterboxed image rows stay exactly one font height apart."
  :tags '(native)
  (skip-unless (display-graphic-p))
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (let* ((cw (default-font-width))
             (ch (default-font-height))
             (term (ghostel--new 6 20 1000))
             (inhibit-read-only t)
             (marks [#x0305 #x030d #x030e #x0310 #x0312 #x033d])
             previous-y)
        (ghostel--set-size term 6 20 cw ch)
        (ghostel--write-vt term
                           (concat (ghostel-test--kitty-transmit
                                    1 '(0 0 0 0 255 0 0 255 0 0 0 0
					  255 0 0 255 255 0 0 255 255 0 0 255
					  0 0 0 0 255 0 0 128 0 0 0 0) 3 3)
                                   (ghostel-test--kitty-place 1 "U=1,c=6,r=4")
                                   "\e[38;5;1m"))
        (dotimes (row 4)
          (dotimes (col 6)
            (ghostel--write-vt term (string #x10eeee (aref marks row) (aref marks col))))
          (ghostel--write-vt term "\r\n"))
        (ghostel-test--redraw term)
        (goto-char (point-min))
        (redisplay t)
        (should (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil))
        (should-not (string-match-p (string #x10eeee) (buffer-string)))
        (dotimes (row 4)
          (let* ((image-pos (save-excursion
                              (goto-char (point-min))
                              (forward-line row)
                              (text-property-not-all (point) (line-end-position) 'ghostel-kitty nil)))
                 (image (and image-pos (get-text-property image-pos 'display)))
                 (pos (save-excursion
                        (goto-char (point-min))
                        (forward-line row)
                        (posn-at-point (point))))
                 (y (cdr (posn-x-y pos))))
            (when image
              (let ((size (image-display-size image t)))
                (should (<= (car size) (* 6 cw)))
                (should (= (% (car size) cw) 0))
                (should (= (cdr size) ch))))
            (when previous-y (should (= (- y previous-y) ch)))
            (setq previous-y y)))))))

(ert-deftest ghostel-test-kitty-shared-runs-preserve-style-and-links ()
  "One image display object spans cells with different backgrounds and links."
  :tags '(native)
  (ghostel-test--with-kitty
    (ghostel--write-vt term
                       (concat "\e[48;2;17;34;51mab\e[48;2;68;85;102m"
                               "\e]8;id=image-link;https://example.invalid/image\e\\cd\e]8;;\e\\"
                               "\e[0m\e[H"
                               (ghostel-test--kitty-transmit 1 '(255 0 0 128))
                               (ghostel-test--kitty-place 1 "c=4,r=1")))
    (ghostel-test--redraw term)
    (let ((image (get-text-property 1 'display)))
      (dotimes (i 4) (should (eq image (get-text-property (1+ i) 'display))))
      (should (equal (ghostel-test--kitty-display-size image) '(4 . 1))))
    (should (equal (plist-get (get-text-property 1 'face) :background) "#112233"))
    (should (equal (plist-get (get-text-property 3 'face) :background) "#445566"))
    (should-not (get-text-property 1 'help-echo))
    (should (equal (get-text-property 3 'help-echo) "https://example.invalid/image"))
    (should (equal (get-text-property 3 'ghostel-link-id) "image-link"))))

(ert-deftest ghostel-test-kitty-image-at-cursor-after-shrink ()
  "An image placed at the cursor is drawn after a shrink erased the cursor's row."
  :tags '(native)
  (with-temp-buffer
    (let ((term (ghostel--new 10 40 1000))
          (image-types '(png))
          (inhibit-read-only t))
      (ghostel--set-size term 10 40 1 1)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'image-type-available-p) (lambda (type) (eq type 'png)))
                ((symbol-function 'fontp) (lambda (&rest _) nil))
                ((symbol-function 'default-font-width) (lambda () 1))
                ((symbol-function 'default-font-height) (lambda () 1)))
        ;; The bottom-row x makes the shrink push rows off the top.
        (ghostel--write-vt term "\e[?1049h\e[999;1Hx\e[Hready\r\n")
        (ghostel--redraw term t)
        (ghostel--set-size term 7 40 1 1)
        (ghostel--redraw term t)
        (ghostel--write-vt term "\e_Ga=T,f=24,s=1,v=1,c=8,r=1,q=2;/wAA\e\\")
        (ghostel--redraw term t))
      (should (text-property-not-all (point-min) (point-max) 'ghostel-kitty nil)))))

(ert-deftest ghostel-test-kitty-gui-style-splits-display-image-once ()
  "Changing background mid-image does not draw it twice or force a line height."
  :tags '(native)
  (skip-unless (display-graphic-p))
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (let* ((cw (default-font-width))
             (ch (default-font-height))
             (term (ghostel--new 5 20 1000))
             (inhibit-read-only t))
        (ghostel--set-size term 5 20 cw ch)
        (ghostel--write-vt term
                           (concat "\e[48;2;17;34;51mab\e[48;2;68;85;102mcd\e[0mx\e[H"
                                   (ghostel-test--kitty-transmit 1 '(255 0 0 128))
                                   (ghostel-test--kitty-place 1 "c=4,r=1")))
        (ghostel-test--redraw term)
        (goto-char (point-min))
        (redisplay t)
        (let ((image (get-text-property 1 'display))
              (before (posn-at-point 1))
              (after (posn-at-point 5)))
          (should (eq image (get-text-property 3 'display)))
          (should (equal (image-display-size image t) (cons (* 4 cw) ch)))
          (should before)
          (should after)
          (should (= (- (car (posn-x-y after)) (car (posn-x-y before))) (* 4 cw))))
        (should-not (get-text-property (line-end-position) 'line-height))))))

(provide 'ghostel-kitty-test)
;;; ghostel-kitty-test.el ends here
