;;; ghostel-glyph-test.el --- Glyph adjustment tests for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Glyph-adjust geometry and shaped/composed glyph metric handling.

;;; Code:

(require 'ghostel-test-helpers)
(require 'cl-lib)

(defun ghostel-test--mock-font-p (font)
  "Return non-nil if FONT is a mock created by `ghostel-test--make-font'."
  (and (consp font) (eq (car font) 'mock-font)))

(defun ghostel-test--make-font (metrics &optional glyphs)
  "Make a mock font carrying METRICS and optionally GLYPHS.
METRICS is a `query-font'-style vector.  GLYPHS is a vector of glyph
info vectors in the gstring glyph format.  The first glyph is used for
mock shaping."
  (list 'mock-font :metrics metrics :glyphs glyphs))

(defun ghostel-test--make-gstring (font glyphs)
  "Return a minimal shaped gstring for FONT and GLYPHS."
  (and glyphs (vector (vector font) nil (aref glyphs 0))))

(defun ghostel-test--mock-font-gstring (font)
  "Return FONT's mock shaped gstring, or nil."
  (and (ghostel-test--mock-font-p font)
       (ghostel-test--make-gstring font (plist-get (cdr font) :glyphs))))

(defmacro ghostel-test--with-glyph-mocks (specs &rest body)
  "Bind font functions to mock implementations described by SPECS, then eval BODY.
SPECS is a plist with these keys:
  :default-font        -- mock font (from `ghostel-test--make-font') returned by
                          `face-attribute' for the default face; its :metrics is
                          used by the `query-font' mock.
  :remapped-default-font -- mock font returned by a synthetic-string `font-at'
                          default-face probe, falling back to :default-font.
  :glyph-font          -- mock font returned by `font-at'; its :metrics and
                          shaped gstring are used by `query-font',
                          `composition-get-gstring', and `font-shape-gstring'.
  :composition-gstring -- shaped gstring returned by `find-composition'."
  (declare (indent 1))
  `(let* ((--orig-face-attribute (symbol-function 'face-attribute))
          (--orig-fontp (symbol-function 'fontp))
          (--orig-font-at (symbol-function 'font-at))
          (--orig-query-font (symbol-function 'query-font))
          (--orig-font-has-char-p (symbol-function 'font-has-char-p))
          (--orig-find-composition (symbol-function 'find-composition))
          (--orig-composition-get-gstring (symbol-function 'composition-get-gstring))
          (--orig-font-shape-gstring (symbol-function 'font-shape-gstring)))
     (ignore --orig-face-attribute --orig-fontp --orig-font-at --orig-query-font
             --orig-font-has-char-p --orig-find-composition
             --orig-composition-get-gstring --orig-font-shape-gstring)
     (cl-letf (,@(when-let* ((df (plist-get specs :default-font)))
                   `(((symbol-function 'face-attribute)
                      (lambda (face attr &rest args)
                        (if (and (eq face 'default) (eq attr :font))
                            ,df
                          (apply --orig-face-attribute face attr args))))
                     ((symbol-function 'fontp)
                      (lambda (font &rest args)
                        (or (ghostel-test--mock-font-p font)
                            (apply --orig-fontp font args))))
                     ((symbol-function 'font-has-char-p)
                      (lambda (font char)
                        (if (ghostel-test--mock-font-p font)
                            nil
                          (funcall --orig-font-has-char-p font char))))
                     ((symbol-function 'query-font)
                      (lambda (font)
                        (or (and (ghostel-test--mock-font-p font)
                                 (plist-get (cdr font) :metrics))
                            (funcall --orig-query-font font))))))
               ,@(let ((gf (plist-get specs :glyph-font))
                       (default-probe-font (or (plist-get specs :remapped-default-font)
                                               (plist-get specs :default-font))))
                   (when (or gf default-probe-font)
                     `(((symbol-function 'font-at)
                        (lambda (pos &optional window string)
                          (cond
                           (string
                            ,(or default-probe-font
                                 '(funcall --orig-font-at pos window string)))
                           ,@(when gf `(((>= pos (point-min)) ,gf)))
                           (t (funcall --orig-font-at pos window string))))))))
               ,@(when-let* ((gf (plist-get specs :glyph-font)))
                   `(((symbol-function 'composition-get-gstring)
                      (lambda (from to font &optional string)
                        (or (and (ghostel-test--mock-font-p font)
                                 (ghostel-test--mock-font-gstring font))
                            (funcall --orig-composition-get-gstring
                                     from to font string))))
                     ((symbol-function 'font-shape-gstring)
                      (lambda (gstring direction)
                        (if (and (vectorp gstring)
                                 (> (length gstring) 0)
                                 (let ((header (aref gstring 0)))
                                   (and (vectorp header)
                                        (> (length header) 0)
                                        (ghostel-test--mock-font-p (aref header 0)))))
                            gstring
                          (funcall --orig-font-shape-gstring gstring direction))))))
               ,@(when-let* ((cg (plist-get specs :composition-gstring)))
                   `(((symbol-function 'find-composition)
                      (lambda (pos &optional limit string detail-p)
                        (if detail-p
                            (list pos (or limit pos) ,cg)
                          (funcall --orig-find-composition
                                   pos limit string detail-p)))))))
       ,@body)))

(defconst ghostel-test--default-font-info
  ["MockDefault" "mock.ttf" 12 120 10 10 10 10 0])

(ert-deftest ghostel-test-query-font-cached-reuses-font-info ()
  "`ghostel--query-font-cached' reuses metrics inside one redraw cache."
  (let ((font (list 'mock-font))
        (metrics ["Mock" "mock.ttf" 12 120 10 10 10 10 0])
        (calls 0)
        (ghostel--query-font-cache (make-hash-table :test 'eq)))
    (cl-letf (((symbol-function 'query-font)
               (lambda (_font)
                 (cl-incf calls)
                 metrics)))
      (should (eq (ghostel--query-font-cached font) metrics))
      (should (eq (ghostel--query-font-cached font) metrics))
      (should (= calls 1)))))

(ert-deftest ghostel-test-glyph-adjust-uses-remapped-default-font ()
  "Cell metrics come from the remapped default font, not `face-attribute'."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-remapped-default*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (base (ghostel-test--make-font ghostel-test--default-font-info))
                   (remapped (ghostel-test--make-font
                              ["MockRemappedDefault" "mock.ttf" 24 240 20 20 20 20 0]))
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 24 240 20 20 20 20 0]
                                [[0 1 ?\u0100 0 20 0 0 20 20 0]])))
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font base
                              :remapped-default-font remapped
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (should-not (get-text-property (point) 'display))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-uses-composition-gstring ()
  "A composed glyph uses `find-composition' metrics for adjustment."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-composition*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   (composition-font
                    (ghostel-test--make-font
                     ["MockEmoji" "mock.ttf" 12 120 10 10 17 17 0]
                     [[0 1 ?⚠ 0 17 0 0 10 10 0]]))
                   (composition-gstring
                    (ghostel-test--mock-font-gstring composition-font)))
              (ghostel--write-vt term "⚠️")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :composition-gstring composition-gstring)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((disp (get-text-property (point) 'display)))
                 (should disp)
                 (should (equal (cadr (assq 'min-width disp)) '(2))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-clamps-on-ascent ()
  "An oversized glyph is clamped by its ascent when only the ascent overflows.
The default font is 10 ascent / 10 descent.  This glyph's ascent (20)
exceeds the default ascent while its descent (5) fits.  The scale must
bound the ascent side (10/20 = 0.5)."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-ascent*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   ;; ascent 20 > default 10; descent 5 < default 10.
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 20 5 10 10 0]
                                [[0 1 ?\u0100 0 10 0 0 20 5 0]])))
              ;; Write a character above the coverage threshold.
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((disp (get-text-property (point) 'display)))
                 (should disp)
                 (let ((scale (cadr (assq 'height disp))))
                   (should scale)
                   ;; Bound by the ascent side, not the looser sum ratio.
                   (should (< (abs (- scale (/ 10.0 20))) 1e-6))
                   (should (< scale (/ 20.0 25)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-clamps-on-descent ()
  "An oversized glyph is clamped by its descent when only the descent overflows.
Mirror of the ascent case: this glyph's descent (20) exceeds the default
descent (10) while its ascent (5) fits.  The scale must bound the descent
side \(10/20 = 0.5\); the sum ratio \(20/25 = 0.8\) would leave the
descent below the line."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-descent*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   ;; ascent 5 < default 10; descent 20 > default 10.
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 5 20 10 10 0]
                                [[0 1 ?\u0100 0 10 0 0 5 20 0]])))
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((disp (get-text-property (point) 'display)))
                 (should disp)
                 (let ((scale (cadr (assq 'height disp))))
                   (should scale)
                   ;; Bound by the descent side, not the looser sum ratio.
                   (should (< (abs (- scale (/ 10.0 20))) 1e-6))
                   (should (< scale (/ 20.0 25)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-quantizes-height-scale ()
  "Glyph height scaling is floored to an integral font pixel size.
The raw ascent clamp here is 10/13.  With a 12px glyph font, Emacs
could round 12 * 10/13 up and overflow the cell, so the renderer must
request floor(12 * 10/13) / 12 = 0.75 instead."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-quantized-scale*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 13 10 10 10 0]
                                [[0 1 ?\u0100 0 10 0 0 13 10 0]])))
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((disp (get-text-property (point) 'display)))
                 (should disp)
                 (let ((scale (cadr (assq 'height disp))))
                   (should scale)
                   (should (= scale 0.75))
                   (should (< scale (/ 10.0 13)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-double-width-small ()
  "A double-width glyph is adjusted to its native width."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-2*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   ;; Glyph: 18px wide x 20px tall, fitting within its native
                   ;; two-cell slot.
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 10 10 18 18 0]
                                [[0 1 ?あ 0 18 0 0 10 10 0]])))
              ;; Write a CJK character (double-width).
              (ghostel--write-vt term "あ")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((disp (get-text-property (point) 'display)))
                 (should disp)
                 (let ((min-w (cadr (assq 'min-width disp))))
                   (should (equal min-w '(2)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-cjk-never-claims-extra-space ()
  "A CJK glyph never claims extra space at EOL or before a space."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-cjk-no-claim*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   ;; Glyph: 30px wide x 20px tall; too wide for its native
                   ;; two-cell slot, but CJK cells must not claim more space.
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 10 10 30 30 0]
                                [[0 1 ?あ 0 30 0 0 10 10 0]])))
              ;; Keep a non-space after the space so it is not right-trimmed.
              (ghostel--write-vt term "あ x\r\nあ")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((disp-before-space (get-text-property (point) 'display)))
                 (should disp-before-space)
                 (should (equal (cadr (assq 'min-width disp-before-space)) '(2))))
               (forward-char 1)
               (should (equal (char-after) ?\s))
               (should-not (get-text-property (point) 'display))
               (forward-line 1)
               (let ((disp-at-eol (get-text-property (point) 'display)))
                 (should disp-at-eol)
                 (should (equal (cadr (assq 'min-width disp-at-eol)) '(2))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-identical-metrics ()
  "A glyph whose pixel size matches the cell perfectly is not adjusted."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-3*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   ;; Glyph: exactly 10px wide x 20px tall
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 10 10 10 10 0]
                                [[0 1 ?\u0100 0 10 0 0 10 10 0]])))
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (should-not (get-text-property (point) 'display))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-claims-following-space ()
  "An oversized single-width glyph claims an adjacent space as :width 0."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-4*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   ;; Glyph: 12px wide x 20px tall \u2014 wider than 10px cell but aspect
                   ;; ratio 0.6 < 1.0, so one claimed space (2 cells) is sufficient.
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 10 10 12 12 0]
                                [[0 1 ?\u0100 0 12 0 0 10 10 0]])))
              ;; Write: [oversized glyph][space]
              (ghostel--write-vt term "\u0100 ")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((glyph-disp (get-text-property (point) 'display)))
                 (should (assq 'min-width glyph-disp))
                 (should (equal (cadr (assq 'min-width glyph-disp)) '(2))))
               (forward-char 1)
               (should (equal (get-text-property (point) 'display) '(space :width 0)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-claims-past-eol ()
  "An oversized single-width glyph claims at most one trailing cell."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-5*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   ;; Glyph: 25px wide x 10px tall (would need >2 cells).
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 5 5 25 25 0]
                                [[0 1 ?\u0100 0 25 0 0 5 5 0]])))
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((disp (get-text-property (point) 'display)))
                 (should disp)
                 (let ((min-w (cadr (assq 'min-width disp))))
                   (should (equal min-w '(2)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-last-column-no-claim ()
  "A glyph at the last column does not claim out-of-bounds space."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-6*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 10 1000)) ;; only 10 columns!
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 5 5 15 15 0]
                                [[0 1 ?\u0100 0 15 0 0 5 5 0]])))
              (ghostel--write-vt term "\e[1;10H")
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (end-of-line)
               (let ((disp (get-text-property (1- (point)) 'display)))
                 (should disp)
                 (let ((min-w (cadr (assq 'min-width disp))))
                   (should (equal min-w '(1)))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-scale-floor-clamps-scale ()
  "A non-zero `ghostel-glyph-scale-floor' prevents shrinking below the floor.
Sets floor to 1.0 and feeds a glyph larger than the cell.  With floor
0.0 the glyph would be scaled to ~0.77; with floor 1.0 it stays at 1.0."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-floor*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (ghostel-glyph-scale-floor 1.0)   ; clamp: never shrink
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   ;; Glyph: 12px wide x 25px tall (larger than 10x20 cell);
                   ;; without floor this would scale to ~0.77.
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 12 13 12 12 0]
                                [[0 1 ?\u0100 0 12 0 0 12 13 0]])))
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (ghostel--redraw term t)
               (goto-char (point-min))
               (let ((disp (get-text-property (point) 'display)))
                 (should disp)
                 (let ((scale (cadr (assq 'height disp))))
                   (should scale)
                   ;; Floor 1.0 clamps the scale so the glyph is NOT shrunk.
                   (should (>= scale 1.0))))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-reuses-known-glyph-metrics ()
  "A known glyph is not queried again on a later render."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-cache*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (font-at-calls 0)
                   (glyph-query-font-calls 0)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   (glyph-font (ghostel-test--make-font
                                ["MockGlyph" "mock.ttf" 12 120 12 13 12 12 0]
                                [[0 1 ?\u0100 0 12 0 0 12 13 0]])))
              (ghostel--write-vt term "\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df
                              :glyph-font glyph-font)
               (let ((mock-font-at (symbol-function 'font-at))
                     (mock-query-font (symbol-function 'query-font)))
                 (cl-letf (((symbol-function 'font-at)
                            (lambda (&rest args)
                              (unless (nth 2 args)
                                (cl-incf font-at-calls))
                              (apply mock-font-at args)))
                           ((symbol-function 'query-font)
                            (lambda (font)
                              (when (eq font glyph-font)
                                (cl-incf glyph-query-font-calls))
                              (funcall mock-query-font font))))
                   (ghostel--redraw term t)
                   (should (= font-at-calls 1))
                   (should (= glyph-query-font-calls 1))
                   (ghostel--redraw term t)))
               (goto-char (point-min))
               (should (get-text-property (point) 'display))
               (should (= font-at-calls 1))
               (should (= glyph-query-font-calls 1))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-cache-distinguishes-styled-font ()
  "The metrics cache must not reuse normal glyph metrics for styled text."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-cache-style*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info))
                   (normal-font (ghostel-test--make-font
                                 ["NormalGlyph" "normal.ttf" 12 120 10 10 10 10 0]
                                 [[0 1 ?\u0100 0 10 0 0 10 10 0]]))
                   (bold-font (ghostel-test--make-font
                               ["BoldGlyph" "bold.ttf" 12 120 10 10 30 30 0]
                               [[0 1 ?\u0100 0 30 0 0 10 10 0]])))
              (ghostel--write-vt term "\u0100 \e[1m\u0100")
              (ghostel-test--with-glyph-mocks
               (:default-font df)
               (cl-letf (((symbol-function 'font-at)
                          (lambda (pos &optional _window string)
                            (cond
                             (string df)
                             ((eq (plist-get (get-text-property pos 'face) :weight)
                                  'bold)
                              bold-font)
                             (t normal-font))))
                         ((symbol-function 'composition-get-gstring)
                          (lambda (_from _to font &optional _string)
                            (ghostel-test--mock-font-gstring font)))
                         ((symbol-function 'font-shape-gstring)
                          (lambda (gstring _direction)
                            gstring))
                         ((symbol-function 'query-font)
                          (lambda (font)
                            (plist-get (cdr font) :metrics))))
                 (ghostel--redraw term t)
                 (goto-char (point-min))
                 (should-not (get-text-property (point) 'display))
                 (forward-char 2)
                 (should (get-text-property (point) 'display)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-glyph-adjust-covered-by-main-font ()
  "A codepoint below the coverage threshold is not registered in adjust_cells."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-glyph-7*")))
    (unwind-protect
        (save-window-excursion
          (with-selected-window (display-buffer buf)
            (ghostel-mode)
            (let* ((term (ghostel--new 5 80 1000))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t)
                   (df (ghostel-test--make-font ghostel-test--default-font-info)))
              (ghostel--write-vt term "a")
              ;; Tripwire: if the code wrongly tried to adjust this glyph it
              ;; would call `font-at', and the deliberately-broken stub below
              ;; would fail the test.
              (cl-letf (((symbol-function 'font-at)
                         (lambda (&rest args)
                           (when (null (nth 2 args))
                             (error "font-at must not be called for covered glyphs"))
                           nil)))
                (ghostel-test--with-glyph-mocks
                 (:default-font df)
                 (ghostel--redraw term t)
                 (goto-char (point-min))
                 (should (equal (char-after) ?a))
                 ;; No adjustment side effects: no display property and no
                 ;; overlays were created on the rendered text.
                 (should-not (get-text-property (point) 'display))
                 (should (null (overlays-in (point-min) (point-max)))))))))
      (kill-buffer buf))))

(provide 'ghostel-glyph-test)
;;; ghostel-glyph-test.el ends here
