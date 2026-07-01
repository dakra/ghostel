;;; ghostel-render-test.el --- Tests for ghostel: rendering -*- lexical-binding: t; -*-

;;; Commentary:

;; Renderer-focused tests.  These cover the Emacs-buffer rendering boundary:
;; cell/row rendering, faces, scrollback materialization, clear
;; operations, dirty-row reuse, resize rendering, delayed redraws, and window
;; anchoring.  Feature-specific tests that merely observe the terminal through
;; redraws live with their owning feature (for example shell integration, Evil,
;; line mode, and kitty graphics).

;;; Code:

(require 'ghostel-test-helpers)

(defvar x-preedit-overlay)
(defvar pgtk-preedit-overlay)

(defun ghostel-test--mark-all-lines-clean ()
  "Mark every line in the current buffer with `ghostel-test-clean' property.
Used with `ghostel-test--line-clean-p' to detect whether the redrawer
rebuilt a line: a rebuild calls `delete-region' on the line, stripping
all text properties including this sentinel."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (put-text-property (point) (1+ (point)) 'ghostel-test-clean t)
        (forward-line 1)))))

(defun ghostel-test--line-clean-p (n)
  "Return non-nil if line N (0-indexed from `point-min') was not rebuilt.
The `ghostel-test-clean' property is placed by
`ghostel-test--mark-all-lines-clean' and is stripped by the redrawer's
`delete-region' call when a line is rebuilt."
  (save-excursion
    (goto-char (point-min))
    (forward-line n)
    (get-text-property (point) 'ghostel-test-clean)))


;;; Redraw harness and buffer invariants

(ert-deftest ghostel-test-size-vars-follow-committed-resize ()
  "`ghostel--term-rows' and `ghostel--term-cols' update when resize commits."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-size-vars*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((term (ghostel--new 5 40 1000)))
            (should (= ghostel--term-rows 5))
            (should (= ghostel--term-cols 40))
            (ghostel--set-size term 7 30)
            (should (= ghostel--term-rows 5))
            (should (= ghostel--term-cols 40))
            (ghostel--redraw term)
            (should (= ghostel--term-rows 7))
            (should (= ghostel--term-cols 30))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-mark ()
  "`ghostel--redraw' must keep `mark' stable across the destructive ops.
Full redraws call `eraseBuffer' and partial redraws `deleteRegion',
either of which would snap every marker in the buffer to `point-min'."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-mark*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 1000))
                 (inhibit-read-only t))
            (ghostel--write-vt term "line one\r\nline two\r\nline three")
            (ghostel--redraw term t)
            ;; Anchor mark to "two" so its position sits well past point-min.
            (goto-char (point-min))
            (search-forward "two")
            (let ((target (point)))
              (set-marker (mark-marker) target)
              ;; Trigger a full redraw (erase-buffer path).
              (ghostel--write-vt term " more")
              (ghostel--redraw term t)
              (should (= target (marker-position (mark-marker)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-rejects-reentrant-call ()
  "A nested `ghostel--redraw' of the same terminal signals an error."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-reentrant-redraw*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((term (ghostel--new 5 40 1000))
                caught
                entered)
            (ghostel--write-vt term "hello")
            (cl-letf* ((orig-mark-marker (symbol-function 'mark-marker))
                       ((symbol-function 'mark-marker)
                        (lambda (&optional buffer)
                          (unless entered
                            (setq entered t)
                            (setq caught
                                  (condition-case err
                                      (progn (ghostel--redraw term) nil)
                                    (error err))))
                          (if buffer
                              (funcall orig-mark-marker buffer)
                            (funcall orig-mark-marker)))))
              (ghostel--redraw term t))
            (should caught)
            (should (string-match-p "ReentrantRedraw"
                                    (error-message-string caught)))))
      (kill-buffer buf))))

(defun ghostel-test--token-position (token)
  "Return the start position of TOKEN in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward token)
    (match-beginning 0)))

(defun ghostel-test--token-at-p (pos token)
  "Return non-nil when TOKEN starts at POS in the current buffer."
  (and pos
       (<= (+ pos (length token)) (1+ (point-max)))
       (equal token
              (buffer-substring-no-properties pos (+ pos (length token))))))

(defun ghostel-test--set-position-preservation-anchors (win)
  "Set mark, WIN point, and WIN start on distinct semantic targets."
  (let ((mark-pos (ghostel-test--token-position "MARK_TARGET"))
        (point-pos (ghostel-test--token-position "POINT_TARGET"))
        (start-pos (ghostel-test--token-position "START_TARGET")))
    (set-marker (mark-marker) mark-pos)
    (goto-char point-pos)
    (set-window-point win point-pos)
    (set-window-start win start-pos t)))

(defun ghostel-test--assert-position-preservation (win)
  "Assert mark, point, WIN point, and WIN start kept their targets."
  (should (ghostel-test--token-at-p (marker-position (mark-marker))
                                    "MARK_TARGET"))
  (should (ghostel-test--token-at-p (point)
                                    "POINT_TARGET"))
  (should (ghostel-test--token-at-p (window-point win)
                                    "POINT_TARGET"))
  (should (ghostel-test--token-at-p (window-start win)
                                    "START_TARGET")))

(defmacro ghostel-test--with-position-preservation-case (spec &rest body)
  "Run BODY in a displayed native terminal buffer.
SPEC is (BUFFER TERM ROWS COLS SCROLLBACK WRITER).  WRITER is called
with TERM and must write MARK_TARGET, POINT_TARGET, and START_TARGET."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,term ,rows ,cols ,scrollback ,writer) spec))
    `(let ((,buffer (generate-new-buffer " *ghostel-test-position-preservation*"))
           (orig-buf (window-buffer (selected-window))))
       (unwind-protect
           (with-current-buffer ,buffer
             (ghostel-mode)
             (set-window-buffer (selected-window) ,buffer)
             (let* ((,term (ghostel--new ,rows ,cols ,scrollback))
                    (ghostel--term ,term)
                    (ghostel--term-rows ,rows)
                    (ghostel--term-cols ,cols)
                    (inhibit-read-only t)
                    (win (selected-window)))
               (funcall ,writer ,term)
               (ghostel--redraw ,term t)
               (ghostel-test--set-position-preservation-anchors win)
               ,@body
               (ghostel-test--assert-position-preservation win)))
         (when (buffer-live-p orig-buf)
           (set-window-buffer (selected-window) orig-buf))
         (kill-buffer ,buffer)))))

(defun ghostel-test--write-position-preservation-lines (term count)
  "Write COUNT hard-wrapped rows containing the position target tokens to TERM."
  (dotimes (i count)
    (ghostel--write-vt
     term
     (cond
      ((= i 3) "START_TARGET start-row\r\n")
      ((= i 7) "mark row MARK_TARGET here\r\n")
      ((= i 11) "point row POINT_TARGET here\r\n")
      (t (format "row-%03d ordinary content\r\n" i))))))

(defun ghostel-test--write-position-preservation-reflow-content (term)
  "Write content to TERM whose target rows survive a width-changing reflow."
  (ghostel--write-vt term "START_TARGET stable start row\r\n")
  (ghostel--write-vt term
                     (concat "long row before mark "
                             (make-string 45 ?a)
                             " MARK_TARGET "
                             (make-string 45 ?b)
                             " POINT_TARGET tail\r\n"))
  (dotimes (i 8)
    (ghostel--write-vt term (format "after-%02d\r\n" i))))

(defun ghostel-test--write-position-preservation-alt-screen (term rows)
  "Write target tokens to TERM into ROWS of alt-screen content."
  (ghostel--write-vt term "\e[?1049h\e[H\e[2J")
  (dotimes (i rows)
    (ghostel--write-vt
     term
     (format "\e[%d;1H%s" (1+ i)
             (pcase i
               (0 "START_TARGET alt-start")
               (2 "MARK_TARGET alt-mark")
               (4 "POINT_TARGET alt-point")
               (_ (format "alt-row-%02d" i)))))))

(ert-deftest ghostel-test-position-preservation-regular-redraw ()
  "Incremental redraw preserves mark, point, and window start semantically."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 8 80 2000 (lambda (term)
                         (ghostel-test--write-position-preservation-lines term 12)))
   (ghostel--write-vt term "\e[2;1Hdirty-row")
   (ghostel--redraw term)))

(ert-deftest ghostel-test-position-preservation-after-changed-length-line ()
  "Positions after a changed-length dirty row stay at semantic targets."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 12 80 2000 (lambda (term)
                          (ghostel--write-vt term "short mutable row\r\n")
                          (ghostel--write-vt term "START_TARGET start-row\r\n")
                          (ghostel--write-vt term "mark row MARK_TARGET here\r\n")
                          (ghostel--write-vt term "point row POINT_TARGET here\r\n")
                          (dotimes (i 4)
                            (ghostel--write-vt term
                                               (format "tail-%02d\r\n" i)))))
   (let ((old-start (ghostel-test--token-position "START_TARGET"))
         (old-mark (ghostel-test--token-position "MARK_TARGET"))
         (old-point (ghostel-test--token-position "POINT_TARGET")))
     (ghostel--write-vt
      term
      "\e[1;1H\e[2Kthis mutable row is now much longer than before")
     (ghostel--redraw term)
     (should (/= old-start (ghostel-test--token-position "START_TARGET")))
     (should (/= old-mark (ghostel-test--token-position "MARK_TARGET")))
     (should (/= old-point (ghostel-test--token-position "POINT_TARGET"))))))

(ert-deftest ghostel-test-position-preservation-on-changed-length-line-no-clamp ()
  "Positions on a changed-length dirty row keep their row offsets."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 12 80 2000 (lambda (term)
                          (ghostel--write-vt
                           term
                           "short START_TARGET MARK_TARGET POINT_TARGET tail\r\n")
                          (dotimes (i 7)
                            (ghostel--write-vt term
                                               (format "tail-%02d\r\n" i)))))
   (let ((old-start (ghostel-test--token-position "START_TARGET"))
         (old-mark (ghostel-test--token-position "MARK_TARGET"))
         (old-point (ghostel-test--token-position "POINT_TARGET")))
     (ghostel--write-vt
      term
      "\e[1;1H\e[2Kshort START_TARGET MARK_TARGET POINT_TARGET longer suffix")
     (ghostel--redraw term)
     (should (= old-start (ghostel-test--token-position "START_TARGET")))
     (should (= old-mark (ghostel-test--token-position "MARK_TARGET")))
     (should (= old-point (ghostel-test--token-position "POINT_TARGET"))))))

(ert-deftest ghostel-test-position-preservation-on-shortened-line-clamps ()
  "Positions past a shortened dirty row clamp to that row's end."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-position-clamp*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (set-window-buffer (selected-window) buf)
          (let* ((term (ghostel--new 12 80 2000))
                 (ghostel--term term)
                 (ghostel--term-rows 12)
                 (ghostel--term-cols 80)
                 (inhibit-read-only t)
                 (win (selected-window)))
            (ghostel--write-vt
             term
             "prefix START_TARGET middle MARK_TARGET more POINT_TARGET tail\r\n")
            (dotimes (i 7)
              (ghostel--write-vt term (format "tail-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-start win
                              (ghostel-test--token-position "START_TARGET")
                              t)
            (set-marker (mark-marker)
                        (ghostel-test--token-position "MARK_TARGET"))
            (goto-char (ghostel-test--token-position "POINT_TARGET"))
            (set-window-point win (point))
            (ghostel--write-vt term "\e[1;1H\e[2Kshort")
            (ghostel--redraw term)
            (let* ((line-end (save-excursion
                               (goto-char (point-min))
                               (line-end-position)))
                   (row-boundary (1+ line-end)))
              (should (equal "short"
                             (buffer-substring-no-properties
                              (point-min) line-end)))
              (should (= row-boundary (window-start win)))
              (should (= row-boundary (marker-position (mark-marker))))
              (should (= row-boundary (point)))
              (should (= row-boundary (window-point win))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-position-preservation-full-redraw ()
  "Full redraw preserves mark, point, and window start semantically."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 8 80 2000 (lambda (term)
                         (ghostel-test--write-position-preservation-lines term 12)))
   (ghostel--redraw term t)))

(ert-deftest ghostel-test-position-preservation-scrollback-row-added ()
  "Adding a row with scrollback preserves semantic buffer positions."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 6 80 4000 (lambda (term)
                         (ghostel-test--write-position-preservation-lines term 16)))
   (ghostel--write-vt term "new-row-after-anchors\r\n")
   (ghostel--redraw term)))

(ert-deftest ghostel-test-position-preservation-width-reflow ()
  "Width-changing reflow preserves semantic buffer positions."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 8 80 4000 #'ghostel-test--write-position-preservation-reflow-content)
   (ghostel--set-size term 8 40)
   (setq ghostel--term-cols 40)
   (ghostel--redraw term)))

(ert-deftest ghostel-test-position-preservation-height-resize-no-scrollback ()
  "Height resize on the primary screen preserves positions without scrollback."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 14 80 4000 (lambda (term)
                          (ghostel-test--write-position-preservation-lines term 12)))
   (ghostel--set-size term 16 80)
   (setq ghostel--term-rows 16)
   (ghostel--redraw term)))

(ert-deftest ghostel-test-position-preservation-height-resize-with-scrollback ()
  "Height resize on the primary screen preserves positions with scrollback."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 6 80 4000 (lambda (term)
                         (ghostel-test--write-position-preservation-lines term 18)))
   (ghostel--set-size term 9 80)
   (setq ghostel--term-rows 9)
   (ghostel--redraw term)))

(ert-deftest ghostel-test-position-preservation-alt-screen-resize ()
  "Alt-screen resize preserves mark, point, and window start semantically."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 6 80 4000 (lambda (term)
                         (ghostel-test--write-position-preservation-alt-screen term 6)))
   (ghostel--set-size term 8 80)
   (setq ghostel--term-rows 8)
   (ghostel--redraw term)))

(ert-deftest ghostel-test-position-preservation-scrollback-eviction ()
  "Scrollback eviction preserves positions for surviving content."
  :tags '(native)
  (ghostel-test--with-position-preservation-case
   (buf term 6 80 4096 (lambda (term)
                         (dotimes (i 140)
                           (ghostel--write-vt
                            term
                            (cond
                             ((= i 105) "START_TARGET start-row\r\n")
                             ((= i 115) "mark row MARK_TARGET here\r\n")
                             ((= i 125) "point row POINT_TARGET here\r\n")
                             (t (format "initial-%03d content\r\n" i)))))))
   (let ((old-start (window-start win)))
     (dotimes (i 60)
       (ghostel--write-vt term (format "later-%03d content\r\n" i)))
     (ghostel--redraw term)
     (should (< (point-min) old-start)))))



;;; Cell and row rendering basics

(ert-deftest ghostel-test-sgr ()
  "Test SGR escape sequences set cell styles."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "\e[1;31mHELLO\e[0m normal")
    (should (equal "HELLO normal" (ghostel-test--row0 term)))))

(ert-deftest ghostel-test-dim-text ()
  "Test that SGR 2 (faint) produces a dimmed foreground color, not :weight light."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-dim*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            ;; Set a known palette so we can predict the dimmed color.
            ;; Default FG=#ffffff, default BG=#000000, red=#ff0000.
            (let ((rest (apply #'concat (make-list 14 "#000000"))))
              (ghostel--set-palette term
                                    (concat "#000000" "#ff0000" rest
                                            "#ffffff" "#000000")))
            ;; Dim text with default foreground
            (ghostel--write-vt term "\e[2mDIM\e[0m ok")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should face)                                   ; face property exists
              (when face
                ;; Should have a :foreground (dimmed color), not :weight light
                (should (plist-get face :foreground))         ; dimmed :foreground set
                (should-not (eq 'light (plist-get face :weight)))))))  ; no :weight light
      (kill-buffer buf))))

(ert-deftest ghostel-test-face-props-survive-font-lock ()
  "Regression: per-cell face text-properties must survive a font-lock pass.
User configs that force `font-lock-defaults' on (notably Doom Emacs,
which sets `(nil t)' globally) cause `font-lock-mode' to activate in
ghostel buffers despite the mode body disabling it.  JIT-lock's
fontify pass then calls `font-lock-unfontify-region' which, without
the buffer-local override installed by `ghostel-mode', strips every
`face' property the native module wrote."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-fl*")))
    (unwind-protect
        (with-current-buffer buf
          ;; Activate `ghostel-mode' so the fix under test (buffer-local
          ;; `font-lock-unfontify-region-function' override) is installed.
          (ghostel-mode)
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (setq-local ghostel--term term)
            ;; Known palette so the red SGR resolves predictably.
            (let ((rest (apply #'concat (make-list 14 "#000000"))))
              (ghostel--set-palette term
                                    (concat "#000000" "#ff0000" rest
                                            "#ffffff" "#000000")))
            (ghostel--write-vt term "\e[31mRED\e[0m normal")
            (ghostel--redraw term t)
            (goto-char (point-min))
            (let ((face-before (get-text-property (point) 'face)))
              (should face-before)
              (should (plist-get face-before :foreground))
              ;; Simulate a user config that force-enables font-lock.
              ;; Without the buffer-local unfontify override installed
              ;; by `ghostel-mode', the fontify pass would strip face
              ;; props across the buffer.
              (setq-local font-lock-defaults '(nil t))
              (font-lock-mode 1)
              (font-lock-ensure (point-min) (point-max))
              ;; Face property for the coloured cell must still be there.
              (goto-char (point-min))
              (let ((face-after (get-text-property (point) 'face)))
                (should face-after)
                (should (plist-get face-after :foreground))
                (should (equal (plist-get face-before :foreground)
                               (plist-get face-after :foreground)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-multibyte-rendering ()
  "Test that styled multi-byte text renders without args-out-of-range."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-mb*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[32m┌──┐\e[0m text")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "┌──┐" content))    ; box drawing rendered
              (should (string-match-p "text" content)))    ; text after box drawing
            (goto-char (point-min))
            (should (get-text-property (point) 'face))))   ; multibyte face property
      (kill-buffer buf))))

(ert-deftest ghostel-test-wide-char-no-overflow ()
  "Test that wide characters (emoji) don't make rendered lines overflow.
A 2-cell-wide emoji should not produce an extra space for the spacer
cell, so the visual line width must equal the emoji width (2).  The
renderer trims trailing blank cells, so we compare against 2 rather
than the full terminal `cols'."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-wide*"))
        (cols 40))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 cols 100))
                 (inhibit-read-only t))
            ;; Feed a wide emoji — occupies 2 terminal cells
            (ghostel--write-vt term "🟢")
            (ghostel--redraw term t)
            ;; First rendered line should have visual width 2 (the
            ;; emoji) and no trailing padding from the spacer cell.
            (goto-char (point-min))
            (let* ((line (buffer-substring (line-beginning-position)
                                           (line-end-position)))
                   (width (string-width line)))
              (should (equal 2 width))
              ;; And the line must NOT exceed the terminal width.
              (should (<= width cols)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-render-trims-trailing-whitespace ()
  "Rendered rows do not carry libghostty's full-width padding.
The renderer should only keep cells the terminal actually wrote to,
so a short line in a 40-column terminal shows up as the written
content plus no trailing space padding.  Shell-written spaces
\(e.g. the trailing space in a \\='$ \\=' prompt or `%-80s' layout)
are retained — only unwritten padding cells are trimmed."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-trim-ws*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 3 40 100))
                 (inhibit-read-only t))
            ;; Write `hi` at the top-left and redraw.
            (ghostel--write-vt term "\e[H\e[2Jhi")
            (ghostel--redraw term t)
            (let ((lines (split-string (buffer-substring-no-properties
                                        (point-min) (point-max))
                                       "\n")))
              ;; First row is trimmed to "hi" (no trailing spaces).
              (should (equal "hi" (car lines)))
              ;; Remaining rows are empty (not rows of 40 spaces).
              (dolist (row (cdr lines))
                (should (string-empty-p row))))
            ;; Shell-written trailing space is preserved.
            (ghostel--write-vt term "\e[H\e[2J$ ")
            (ghostel--redraw term t)
            (let ((lines (split-string (buffer-substring-no-properties
                                        (point-min) (point-max))
                                       "\n")))
              (should (equal "$ " (car lines))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-render-untrims-cursor-line-to-cursor-column ()
  "A cursor past EOL keeps only enough blanks to place point there."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-cursor-untrim*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 3 20 100))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[H\e[2Jhi\e[1;11H")
            (ghostel--redraw term t)
            (should (equal '(10 . 0) ghostel--cursor-pos))
            (goto-char ghostel--cursor-char-pos)
            (should (= 10 (current-column)))
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position)
                         (line-end-position))))
              (should (equal (concat "hi" (make-string 8 ?\s)) line)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-render-retrims-old-cursor-line-on-cursor-move ()
  "Moving the cursor trims the old line and untrims the new one."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-cursor-retrim*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 3 20 100))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[H\e[2Jhi\e[1;11H")
            (ghostel--redraw term t)
            (ghostel--write-vt term "\e[2;6H")
            (ghostel--redraw term)
            (should (equal '(5 . 1) ghostel--cursor-pos))
            (let ((lines (split-string (buffer-substring-no-properties
                                        (point-min) (point-max))
                                       "\n")))
              (should (equal "hi" (nth 0 lines)))
              (should (equal (make-string 5 ?\s) (nth 1 lines))))
            (goto-char ghostel--cursor-char-pos)
            (should (= 5 (current-column)))))
      (kill-buffer buf))))

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



;;; Palette, faces, and theme sync

(ert-deftest ghostel-test-color-palette ()
  "Test setting a custom ANSI color palette via faces."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-palette*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            ;; Set palette index 1 (red) to a known color via set-palette
            (let ((rest (apply #'concat (make-list 14 "#000000"))))
              (ghostel--set-palette term
                                    (concat "#000000" "#ff0000" rest)))
            ;; Write red text (SGR 31 = ANSI red = palette index 1)
            (ghostel--write-vt term "\e[31mRED\e[0m")
            (ghostel--redraw term)
            (should (string-match-p "RED"                  ; red text rendered
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            ;; Check that the face property uses our custom red
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should face)                                ; face property exists
              (when face
                (let ((fg (plist-get face :foreground)))
                  (should (and fg (string= fg "#ff0000"))))))))  ; foreground is custom red
      (kill-buffer buf))))

(ert-deftest ghostel-test-apply-palette ()
  "Test the face-based apply-palette helper."
  :tags '(native)
  (let ((term (ghostel--new 5 40 100)))
    (should (ghostel--apply-palette term)))                ; apply-palette succeeds

  ;; Test face-hex-color extraction
  (let ((color (ghostel--face-hex-color 'ghostel-color-red :foreground)))
    (should (and (stringp color)                           ; face color is hex string
                 (string-prefix-p "#" color)
                 (= (length color) 7)))))

(ert-deftest ghostel-test-face-hex-color-tty-unspecified ()
  "TTY sentinel colors must not collapse fg and bg to the same hex (#297).
On a Linux framebuffer the `default' face reports \"unspecified-fg\" and
\"unspecified-bg\".  If `ghostel--face-hex-color' returned the same
fallback for both, the buffer default face was remapped black-on-black
and typed text was invisible."
  (cl-letf (((symbol-function 'face-attribute)
             (lambda (_face attr &optional _frame _inherit)
               (pcase attr
                 (:foreground "unspecified-fg")
                 (:background "unspecified-bg")
                 (_ 'unspecified)))))
    (let ((fg (ghostel--face-hex-color 'ghostel-default :foreground))
          (bg (ghostel--face-hex-color 'ghostel-default :background)))
      (should (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" fg))
      (should (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" bg))
      (should-not (string= fg bg)))))

(ert-deftest ghostel-test-sync-theme ()
  "Test that ghostel-sync-theme reapplies palette and requests redraws."
  (let ((palette-calls nil)
        (redraw-calls nil))
    (cl-letf (((symbol-function 'ghostel--apply-palette)
               (lambda (term) (push term palette-calls)))
              ((symbol-function 'ghostel--redraw-now)
               (lambda (buf) (push buf redraw-calls))))
      (let ((buf (generate-new-buffer " *ghostel-test-theme*"))
            (other (generate-new-buffer " *ghostel-test-other*")))
        (unwind-protect
            (cl-letf (((symbol-function 'buffer-list)
                       (lambda (&rest _) (list buf other))))
              ;; Set up a ghostel-mode buffer with a fake terminal.
              (with-current-buffer buf
                (ghostel-mode)
                (setq ghostel--term 'fake-term)
                (setq ghostel--input-mode 'semi-char))
              ;; `other' is not a ghostel buffer and should be ignored.
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should (memq buf redraw-calls))

              ;; Verify copy mode (frozen) skips redraw.
              (setq palette-calls nil
                    redraw-calls nil)
              (with-current-buffer buf
                (setq ghostel--input-mode 'copy))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should-not (memq buf redraw-calls))

              ;; Verify emacs mode (unfrozen) still redraws.
              (setq palette-calls nil
                    redraw-calls nil)
              (with-current-buffer buf
                (setq ghostel--input-mode 'emacs))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should (memq buf redraw-calls)))
          (kill-buffer buf)
          (kill-buffer other))))))

;;; Terminal metadata and titles

(ert-deftest ghostel-test-title ()
  "Test OSC 2 title change."
  :tags '(native)
  (with-temp-buffer
    (let ((term (ghostel--new 25 80 1000)))
      (ghostel--write-vt term "\e]2;My Title\e\\")
      (should (equal "My Title"
                     (ghostel-test--wait-until
                      (lambda () ghostel--title) nil 1))))))


;;; Scrollback materialization and eviction

(ert-deftest ghostel-test-scrollback-in-buffer ()
  "After overflowing the viewport, scrolled-off rows live in the Emacs buffer.
This is the vterm-style growing-buffer model that lets `isearch' and
`consult-line' search history without entering copy mode."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-buffer*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Write 12 lines into a 5-row terminal — 7 should scroll off.
            (dotimes (i 12)
              (ghostel--write-vt term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; Earliest row that scrolled off must now live in the buffer.
              (should (string-match-p "row-00" content))
              ;; A middle row that scrolled off must also be present.
              (should (string-match-p "row-05" content))
              ;; The most recent row is on the active screen.
              (should (string-match-p "row-11" content)))
            ;; 12 distinct rows made it into the buffer + trailing newline
            (should (= 13 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-bootstrap-not-blank ()
  "First-time scrollback materialization must contain actual content."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-bootstrap*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Render the initial (nearly empty) viewport so the buffer
            ;; has 5 rows of stale content — simulates a fresh terminal.
            (ghostel--write-vt term "$ \r\n")
            (ghostel--redraw term t)
            ;; Now a burst of output overflows the viewport.
            (dotimes (i 15)
              (ghostel--write-vt term (format "line-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; The scrollback region (above the viewport) must contain
            ;; the actual output, not blank lines from the old viewport.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "\\$ " content))   ; prompt survived
              (should (string-match-p "line-00" content)) ; first output line
              (should (string-match-p "line-05" content)) ; middle output line
              ;; No blank lines in the scrollback region: every line
              ;; before the viewport should have visible content.
              (goto-char (point-min))
              (let ((blank-count 0))
                (while (and (not (eobp))
                            (< (line-number-at-pos) (- (line-number-at-pos (point-max)) 4)))
                  (when (looking-at-p "^$")
                    (setq blank-count (1+ blank-count)))
                  (forward-line 1))
                (should (= 0 blank-count))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-grows-incrementally ()
  "Successive redraws append newly-scrolled-off rows without losing history."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-incr*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; First batch: write 8 lines, redraw.
            (dotimes (i 8)
              (ghostel--write-vt term (format "first-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "first-00" content))
              (should (string-match-p "first-07" content)))
            ;; Second batch: write more lines, redraw again.
            (dotimes (i 6)
              (ghostel--write-vt term (format "second-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; All earlier scrollback rows survive the second redraw.
              (should (string-match-p "first-00" content))
              (should (string-match-p "first-07" content))
              (should (string-match-p "second-00" content))
              (should (string-match-p "second-05" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-eviction-chunked ()
  "Scrollback eviction works for chunked writes with interleaved renders.
Writes a small batch, renders, then writes a large batch across many
small writes interspersed with renders.  The accumulated scrollback
from the second phase must evict the first phase from the Emacs
buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-evict*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 6 80 1024))
                 (inhibit-read-only t))
            ;; Write a small initial batch
            (dotimes (i 20)
              (ghostel--write-vt term (format "early-%05d\r\n" i)))
            (ghostel--redraw term t)
            ;; Write a large batch in many small chunks with renders in between
            (dotimes (x 200)
              (dotimes (i 100)
                (ghostel--write-vt term (format "late-%05d\r\n" i)))
              (ghostel--redraw term t))
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "late-" content))
              (should-not (string-match-p "early-" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-eviction-bulk ()
  "Scrollback eviction works for a single large bulk write.
Writes a small batch, renders, then writes a massive amount in one go
that pushes all rows out of libghostty's scrollback cap at once.  The
second redraw must evict the first-batch rows from the Emacs buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-evict*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 6 80 1024))
                 (inhibit-read-only t))
            ;; Write a small initial batch
            (dotimes (i 20)
              (ghostel--write-vt term (format "early-%05d\r\n" i)))
            (ghostel--redraw term t)
            ;; Write a huge amount in one shot
            (dotimes (i 200000)
              (ghostel--write-vt term (format "late-%05d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "late-" content))
              (should-not (string-match-p "early-" content)))))
      (kill-buffer buf))))



;;; Clear screen and clear scrollback rendering

(ert-deftest ghostel-test-clear-screen ()
  "Test that ghostel-clear clears the visible screen but preserves scrollback.
With the growing-buffer model the scrollback is always materialized into
the Emacs buffer, so we just check the buffer text directly instead of
scrolling libghostty's viewport."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-clear*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 100))
          ;; Seed enough content to create scrollback, then clear only the
          ;; visible viewport.
          (ghostel--write-vt
           ghostel--term
           (mapconcat (lambda (i) (format "clear-test-%d\r\n" i))
                      (number-sequence 0 14) ""))
          (ghostel-clear)
          ;; Simulate what delayed-redraw does after `ghostel-clear' invalidates.
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term t))
          ;; Scrollback rows live in the buffer above the cleared
          ;; viewport — search for any clear-test output to confirm.
          (let ((content (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "clear-test-[0-9]+" content))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-clear-scrollback ()
  "Test that ghostel-clear-scrollback clears both screen and scrollback."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-clear-sb*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 100))
          (let ((inhibit-read-only t))
            ;; Fill screen + scrollback with 10 lines
            (dotimes (i 10)
              (ghostel--write-vt ghostel--term (format "line %d\r\n" i)))
            (ghostel--redraw ghostel--term t)
            ;; Verify lines materialized in the buffer
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line 0" content))
              (should (string-match-p "line 9" content)))
            ;; Clear scrollback (sends CSI 3J to libghostty)
            (ghostel-clear-scrollback)
            (ghostel--redraw ghostel--term t)
            ;; Screen and scrollback should be empty
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should-not (string-match-p "line [0-9]" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-clear-scrollback-drops-stale-buffer-tail ()
  "CSI H/2J/3J must not leave pre-clear buffer content above the prompt."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-clear-sb-stale-tail*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 24 80 10000))
                 (inhibit-read-only t)
                 (long-line (concat "wrapped " (make-string 160 ?Z))))
            ;; Mixed line lengths reproduce the stale-tail shape without
            ;; making libghostty's page layout part of the test contract.
            (dotimes (i 300)
              (ghostel--write-vt
               term
               (format "%04d %s\r\n" i (if (= (% i 3) 0) "short" long-line))))
            (ghostel--write-vt term "$ ")
            (ghostel--redraw term t)
            (should (string-match-p
                     "Z" (buffer-substring-no-properties (point-min) (point-max))))
            (ghostel--write-vt term "\e[H\e[2J\e[3J$ ")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should-not (string-match-p "Z" content))
              (should (string-prefix-p "$ " content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-csi3j-then-refill ()
  "CSI 3 J must not leave stale pre-clear rows in the buffer.

Scenario (5-row terminal, 10 before-* rows, CSI 3J, 5 after-* rows,
single redraw):
  - After the first redraw: before-00..before-05 are in scrollback (6
    rows scrolled off), before-06..before-09 fill the viewport.  The
    redraw parks libghostty's viewport at `max_offset - 1'.
  - CSI 3J clears libghostty's scrollback, which snaps the viewport
    back to the bottom (`offset + len == total').
  - Five new after-* rows scroll before-06..before-09 and after-00 into
    libghostty's freshly-cleared scrollback (5 rows); after-01..after-04
    are left in the viewport.
  - At the next redraw, the viewport-snap signal (`offset + len ==
    total' rather than the parked `max - 1') tells the renderer that
    libghostty cleared its scrollback, triggering an erase + full
    rebuild from the current libghostty state."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-csi3j-refill*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Phase 1: fill scrollback with 10 "before" rows and redraw.
            (dotimes (i 10)
              (ghostel--write-vt term (format "before-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; Confirm before-00..before-05 are now in the buffer's scrollback
            ;; and before-06..before-09 are in the viewport.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "before-00" content))
              (should (string-match-p "before-05" content))
              (should (string-match-p "before-09" content)))
            ;; Phase 2: CSI 3 J (erase scrollback only) then immediately
            ;; write 5 "after" rows — no redraw in between.  before-06..before-09
            ;; scroll off into libghostty's freshly-cleared scrollback as the
            ;; after-* rows push through the viewport.
            (ghostel--write-vt term "\e[3J")
            (dotimes (i 5)
              (ghostel--write-vt term (format "after-%02d\r\n" i)))
            ;; Phase 3: single redraw — must rebuild from libghostty.
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; Rows that were in scrollback when CSI 3J fired are gone.
              (should-not (string-match-p "before-00" content))
              (should-not (string-match-p "before-05" content))
              ;; Rows that were in the viewport during CSI 3J are now in
              ;; libghostty's new scrollback and must be present.
              (should (string-match-p "before-06" content))
              (should (string-match-p "before-09" content))
              ;; after-00 scrolled into scrollback; after-01..after-04 in viewport.
              (should (string-match-p "after-00" content))
              (should (string-match-p "after-04" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-csi3j-refill-same-count ()
  "CSI 3 J plus same-count refill must drop stale cleared scrollback.

Regression shape: the pre-clear and post-refill buffers have the same
number of materialized scrollback rows, so a renderer that only compares
counts can leave the old scrollback text in place.  Rows that were in the
active viewport when CSI 3J ran may legitimately scroll into the new
scrollback; rows that were already in scrollback must not survive."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-csi3j-same-count*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Phase 1: 10 rows in a 5-row terminal gives 6 materialized
            ;; scrollback rows (old-sb-00..old-sb-05) after redraw, with
            ;; old-vp-06..old-vp-09 in the active viewport.
            (dotimes (i 6)
              (ghostel--write-vt term (format "old-sb-%02d\r\n" i)))
            (dotimes (i 4)
              (ghostel--write-vt term (format "old-vp-%02d\r\n" (+ i 6))))
            (ghostel--redraw term t)
            (let ((before (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "old-sb-00" before))
              (should (string-match-p "old-sb-05" before))
              (should (string-match-p "old-vp-09" before)))
            ;; Phase 2: clear scrollback and, before the next redraw, write
            ;; enough rows to recreate exactly 6 scrollback rows: the 4 old
            ;; viewport rows plus new-00 and new-01.  This keeps the row count
            ;; unchanged while changing the contents of the cleared region.
            (ghostel--write-vt
             term
             (concat "\e[3J"
                     (mapconcat (lambda (i) (format "new-%02d\r\n" i))
                                (number-sequence 0 5) "")))
            ;; Phase 3: incremental redraw must notice the cleared/refilled
            ;; scrollback, not reuse stale pre-clear rows just because the
            ;; materialized row count stayed the same.
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; Rows that were in scrollback when CSI 3J fired are gone.
              (should-not (string-match-p "old-sb-00" content))
              (should-not (string-match-p "old-sb-05" content))
              ;; Rows from the active viewport at CSI 3J time legitimately
              ;; scrolled into the new scrollback.
              (should (string-match-p "old-vp-06" content))
              (should (string-match-p "old-vp-09" content))
              ;; The refill rows are present too, with new-00/new-01 in
              ;; scrollback and the rest in the viewport.
              (should (string-match-p "new-00" content))
              (should (string-match-p "new-05" content)))))
      (kill-buffer buf))))

;;; Incremental and dirty-row rendering

(ert-deftest ghostel-test-no-stale-lines-in-scrollback ()
  "Rows modified and scrolled out in one write must not leak stale text.
A row that has been materialized in a previous render and is then
modified and scrolled out in a single write should not scroll out the
stale row."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-buffer*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            (ghostel--write-vt term "wrong\r\n")
            (ghostel--redraw term t)
            (ghostel--write-vt term "\e[Hfoobar\e[5;0Hyolo\r\n")
            (ghostel--redraw term t)
            (goto-char (point-min))
            (let ((line (buffer-substring-no-properties (line-beginning-position)
                                                        (line-end-position))))
              ;; Should now equal "foobar", not "wrong"
              (should (string= line "foobar")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-not-rebuilt-on-shrink ()
  "Scrollback rows survive a vertical-only viewport shrink without rerendering.
A column-only or full resize erases and rebuilds the buffer, but shrinking
only the row count must leave existing scrollback lines untouched."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-shrink*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; 8 rows into a 5-row terminal → lines 0-2 scroll into scrollback.
            (dotimes (i 8)
              (ghostel--write-vt term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; Stamp every line with the sentinel after the initial full render.
            (ghostel-test--mark-all-lines-clean)
            ;; Shrink rows only — columns are unchanged so the buffer is not erased.
            (ghostel--set-size term 3 80)
            (ghostel--redraw term)
            ;; The 3 original scrollback lines must not have been rebuilt.
            (should (ghostel-test--line-clean-p 0))
            (should (ghostel-test--line-clean-p 1))
            (should (ghostel-test--line-clean-p 2))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-not-rebuilt-on-expand ()
  "Scrollback rows above the new active area survive a vertical viewport expand.
Expanding the row count pulls some scrollback rows back into the viewport,
but rows that remain in scrollback must not be rerendered."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-expand*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; 20 rows into a 5-row terminal → 15 scrollback rows in the buffer.
            (dotimes (i 20)
              (ghostel--write-vt term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (ghostel-test--mark-all-lines-clean)
            ;; Expand to 8 rows.  The resize render re-renders the last 8 lines,
            ;; so lines 0-11 stay in scrollback and must remain untouched.
            (ghostel--set-size term 8 80)
            (ghostel--redraw term)
            (dotimes (i 12)
              (should (ghostel-test--line-clean-p i)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-not-rebuilt-on-new-row ()
  "Adding a row to a full viewport does not recreate existing scrollback rows.
When a new row pushes the top viewport row into scrollback, the rows
already in scrollback must remain untouched."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-newrow*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; 8 rows → lines 0-2 are scrollback after the initial render.
            (dotimes (i 8)
              (ghostel--write-vt term (format "first-%02d\r\n" i)))
            (ghostel--redraw term t)
            (ghostel-test--mark-all-lines-clean)
            ;; One more row scrolls through the viewport.
            (ghostel--write-vt term "extra\r\n")
            (ghostel--redraw term)
            ;; The 3 pre-existing scrollback rows must not have been rebuilt.
            (should (ghostel-test--line-clean-p 0))
            (should (ghostel-test--line-clean-p 1))
            (should (ghostel-test--line-clean-p 2))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-partial-redraw-only-dirty-row-rebuilt ()
  "Modifying one active row rebuilds only that row; unchanged rows are preserved.
The incremental dirty-row path calls `delete-region' + re-insert for dirty rows
and `forward-line' for clean ones.  Only the dirty row loses the sentinel."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-partial-dirty*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Fill the viewport and park the cursor on row 2 before the
            ;; initial draw.  This avoids dirtying row 4 on the second
            ;; render: a cursor move from row 4 → row 2 would dirty both
            ;; rows, breaking the single-dirty-row assertion below.
            (ghostel--write-vt term "row-0\r\nrow-1\r\nrow-2\r\nrow-3\r\nrow-4\e[3;1H")
            (ghostel--redraw term t)
            (ghostel-test--mark-all-lines-clean)
            ;; Cursor is already on row 2; overwrite it in place.
            (ghostel--write-vt term "modified")
            (ghostel--redraw term)
            ;; Row 2 was dirty and must have been rebuilt (sentinel gone).
            (should-not (ghostel-test--line-clean-p 2))
            ;; The remaining rows were clean and must not have been rebuilt.
            (should (ghostel-test--line-clean-p 0))
            (should (ghostel-test--line-clean-p 1))
            (should (ghostel-test--line-clean-p 3))
            (should (ghostel-test--line-clean-p 4))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-incremental-redraw ()
  "Test that incremental redraw correctly updates dirty rows."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-redraw*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-vt term "line-A\r\nline-B\r\nline-C")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line-A" content))   ; initial row0
              (should (string-match-p "line-B" content))   ; initial row1
              (should (string-match-p "line-C" content)))  ; initial row2

            ;; Write more text on row 2 — only that row should be dirty
            (ghostel--write-vt term " updated")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line-A" content))       ; row0 preserved
              (should (string-match-p "line-B" content))       ; row1 preserved
              (should (string-match-p "line-C updated" content))) ; row2 updated

            (should (equal 5 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))



;;; Alt-screen rendering invariants

(ert-deftest ghostel-test-alt-screen-overflow-line-count ()
  "Overflowing an alt-screen scroll region does not grow the buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-alt-overflow-lines*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[?1049h")
            (ghostel--write-vt term "\e[1;3r")
            (dotimes (i 10)
              (ghostel--write-vt term (format "ROW-%02d\r\n" i)))
            (ghostel--redraw term t)
            (should (= 5 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))



;;; Resize rendering

(ert-deftest ghostel-test-expand-with-restored-cursor-keeps-scrollback ()
  "Vertical expand with restored cursor keeps existing scrollback.
When growing the viewport, libghostty only pulls scrollback into the active area
when the cursor is at the bottom.  If the cursor is restored away from the
bottom while the resize is pending, the existing scrollback row must remain
materialized above the expanded active area."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-restore-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 2 10 10))
                 (inhibit-read-only t))
            (ghostel--write-vt term "row0\r\nrow1\r\n")
            (ghostel--set-size term 3 10)
            ;; DECRC restores the default saved cursor position, away from the
            ;; bottom, before the pending resize commits on redraw.
            (ghostel--write-vt term "\e8")
            (ghostel--redraw term)
            ;; row0 is still scrollback; row1 plus two blank rows are the
            ;; expanded active area.
            (should (equal "row0\nrow1\n\n\n"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-content-preserved-across-vertical-resizes ()
  "Buffer content survives expand then shrink without loss or duplication.
Expands from the initial size (staying within the available scrollback so
no rows are pulled back) then shrinks below the original size.  No
assumption is made about which lines are rebuilt; the full buffer text
must be identical after each resize."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-roundtrip*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Write 20 rows into a 5-row terminal → 15 rows in scrollback.
            (dotimes (i 20)
              (ghostel--write-vt term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((baseline (buffer-substring-no-properties (point-min) (point-max))))
              ;; Expand to 8 rows — within the 15-row scrollback, so no
              ;; rows are exhausted from libghostty's scrollback cap.
              (ghostel--set-size term 8 80)
              (ghostel--redraw term)
              (should (equal baseline (buffer-substring-no-properties (point-min) (point-max))))
              ;; Shrink to 3 rows — smaller than the original 5.
              (ghostel--set-size term 3 80)
              (ghostel--redraw term)
              (should (equal baseline (buffer-substring-no-properties (point-min) (point-max)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-shrink-line-count-and-content ()
  "After a vertical shrink the buffer contracts to the new viewport row count.
With no scrollback the content fits entirely within the smaller viewport, so
the buffer must have exactly as many lines as the new row count — no phantom
rows left over from the previous larger size.  The first line must contain
the written content; all remaining lines must be empty."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-shrink-lines*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            (ghostel--write-vt term "hello\r\n")
            (ghostel--redraw term t)
            (ghostel--set-size term 3 80)
            (ghostel--redraw term)
            (should (= 3 (count-lines (point-min) (point-max))))
            (goto-char (point-min))
            (should (equal "hello"
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position))))
            (dotimes (_ 2)
              (forward-line 1)
              (should (equal ""
                             (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-alt-screen-vertical-shrink-line-count ()
  "Shrinking the alt-screen viewport leaves exactly the new row count."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-alt-shrink-lines*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[?1049h")
            (dotimes (i 5)
              (ghostel--write-vt term (format "\e[%d;1HROW-%d" (1+ i) i)))
            (ghostel--redraw term t)
            (ghostel--set-size term 3 80)
            (ghostel--redraw term)
            (should (= 3 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-alt-screen-vertical-grow-line-count ()
  "Growing the alt-screen viewport leaves exactly the new row count."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-alt-grow-lines*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 3 80 1000))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[?1049h")
            (dotimes (i 3)
              (ghostel--write-vt term (format "\e[%d;1HROW-%d" (1+ i) i)))
            (ghostel--redraw term t)
            (ghostel--set-size term 5 80)
            (ghostel--redraw term)
            (should (= 5 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-resize-no-blank-flash ()
  "Buffer keeps old content after resize; redraw replaces it atomically."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-no-blank*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 100))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            ;; Fill the viewport with identifiable content.
            (dotimes (i 10)
              (ghostel--write-vt term (format "LINE-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((pre-content (buffer-substring-no-properties
                                (point-min) (point-max))))
              (should (string-match-p "LINE-00" pre-content))
              (should (string-match-p "LINE-09" pre-content))

              ;; Resize — old content must survive in the buffer.
              (ghostel--set-size term 6 40)
              (setq ghostel--term-rows 6)
              (let ((mid-content (buffer-substring-no-properties
                                  (point-min) (point-max))))
                (should (> (length mid-content) 0))
                (should (string-match-p "LINE-" mid-content)))

              ;; Redraw rebuilds the buffer from the new terminal state.
              (ghostel--redraw term t)
              (let ((post-content (buffer-substring-no-properties
                                   (point-min) (point-max))))
                (should (> (length post-content) 0))
                ;; Viewport should have the new row count; extra lines
                ;; above are scrollback from the old viewport rows.
                (should (>= (count-lines (point-min) (point-max)) 6))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-resize-sync ()
  "Resize between BSU/ESU cycles renders clean content."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-sync*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 10 40 100))
                 (inhibit-read-only t))
            ;; Enter alt screen and simulate a complete synchronized
            ;; update cycle before resizing.
            (ghostel--write-vt term "\e[?1049h")
            (dotimes (i 9)
              (ghostel--write-vt term (format "line %d\r\n" i)))
            (ghostel--write-vt term "prompt> ")
            (should (ghostel--mode-enabled term 1049))
            (ghostel--write-vt term "\e[?2026h\e[H\e[2J")
            (dotimes (i 9)
              (ghostel--write-vt term (format "new %d\r\n" i)))
            (ghostel--write-vt term "new prompt> ")
            (ghostel--write-vt term "\e[?2026l")
            (should-not (ghostel--mode-enabled term 2026))
            (ghostel--set-size term 6 40)
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "new prompt>" content))
              (should (= 6 (count-lines (point-min) (point-max)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-resize-redraw-alt-screen ()
  "Resize on alt screen: SIGWINCH-triggered redraw renders correctly.
Simulates: alt-screen TUI fills screen → window resize → app redraws
for new size inside BSU/ESU → verify buffer shows new content."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-redraw*")))
    (unwind-protect
        (with-current-buffer buf
          (set-window-buffer (selected-window) (current-buffer))
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 100))
                 (ghostel--term term)
                 (ghostel--force-next-redraw nil)
                 (inhibit-read-only t))
            ;; 1) Enter alt screen and fill with "old" content using
            ;;    cursor positioning (like a TUI app would).
            (ghostel--write-vt term "\e[?1049h")  ; alt screen on
            (dotimes (i 10)
              (ghostel--write-vt term (format "\e[%d;1HOLD-LINE-%02d" (1+ i) i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "OLD-LINE-00" content))
              (should (string-match-p "OLD-LINE-09" content)))

            ;; 2) Simulate what ghostel--adjust-size does:
            ;;    resize VT, synchronous redraw, set force flag.
            (ghostel--set-size term 6 40)
            (ghostel--redraw term t)
            (setq ghostel--force-next-redraw t)

            ;; 3) Simulate the app's SIGWINCH-triggered redraw with BSU/ESU.
            ;;    The app clears screen and redraws for the new 6-row size.
            (ghostel--write-vt term "\e[?2026h")     ; BSU
            (ghostel--write-vt term "\e[H\e[2J")     ; clear
            (dotimes (i 6)
              (ghostel--write-vt term (format "\e[%d;1HNEW-LINE-%02d" (1+ i) i)))
            (ghostel--write-vt term "\e[?2026l")     ; ESU

            ;; 4) Simulate what ghostel--redraw-now does:
            ;;    check BSU gate, flush, redraw.
            (ghostel--redraw-now buf)

            ;; 5) Verify: buffer must show NEW content, not OLD.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "NEW-LINE-00" content))
              (should (string-match-p "NEW-LINE-05" content))
              (should-not (string-match-p "OLD-LINE" content)))))
      (kill-buffer buf))))

(defmacro ghostel-test--with-open-sync-output (spec &rest body)
  "Run BODY in a displayed terminal buffer left mid synchronized output.
SPEC is (BUFFER TERM).  Sets up a ghostel buffer showing BASELINE-CONTENT,
then opens mode 2026 and mutates the grid to UPDATED-CONTENT *without*
closing it - the state of a buffer hidden while a TUI streams a frame."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,term) spec))
    `(let ((,buffer (generate-new-buffer " *ghostel-test-open-sync-output*")))
       (unwind-protect
           (with-current-buffer ,buffer
             (set-window-buffer (selected-window) (current-buffer))
             (ghostel-mode)
             (let* ((,term (ghostel--new 10 40 100))
                    (ghostel--term ,term)
                    (ghostel--term-rows 10)
                    (ghostel--term-cols 40)
                    (ghostel--force-next-redraw nil)
                    (inhibit-read-only t))
               ;; Baseline content, rendered into the buffer.
               (ghostel--write-vt ,term "\e[H\e[2JBASELINE-CONTENT")
               (ghostel--redraw ,term t)
               (should (string-match-p "BASELINE-CONTENT" (buffer-string)))
               ;; Open synchronized output and mutate the grid without closing
               ;; it, as a streaming TUI does mid-frame.
               (ghostel--write-vt ,term "\e[?2026h\e[H\e[2JUPDATED-CONTENT")
               (should (ghostel--mode-enabled ,term 2026))
               ,@body))
         (kill-buffer ,buffer)))))

(ert-deftest ghostel-test-redraw-now-force-bypasses-open-sync-output ()
  "FORCE makes `ghostel--redraw-now' repaint even while mode 2026 is open.
Without FORCE the redraw is correctly suppressed during synchronized
output; with FORCE it repaints now (the contract the #456 fix relies on)."
  :tags '(native)
  (ghostel-test--with-open-sync-output (buf term)
    ;; Unforced redraw is suppressed mid synchronized output: still baseline.
    (ghostel--redraw-now buf)
    (should (string-match-p "BASELINE-CONTENT" (buffer-string)))
    (should-not (string-match-p "UPDATED-CONTENT" (buffer-string)))
    ;; Forced redraw bypasses the skip and repaints now.
    (ghostel--redraw-now buf t)
    (should (string-match-p "UPDATED-CONTENT" (buffer-string)))
    (should-not (string-match-p "BASELINE-CONTENT" (buffer-string)))))

(ert-deftest ghostel-test-window-buffer-change-repaints-stale-reappear ()
  "Regression for #456: a buffer reappearing repaints past open mode 2026.
A hidden ghostel buffer renders nothing, so its content is stale on
reappear.  `ghostel--window-buffer-change' must force the repaint instead
of leaving the stale content until the next non-2026 output."
  :tags '(native)
  (ghostel-test--with-open-sync-output (_buf term)
    (ghostel--window-buffer-change (selected-window))
    (should (string-match-p "UPDATED-CONTENT" (buffer-string)))
    (should-not (string-match-p "BASELINE-CONTENT" (buffer-string)))))

(ert-deftest ghostel-test-force-redraw-recovers-during-sync-output ()
  "`ghostel-force-redraw' recovers stale content even while mode 2026 is open.
The user-facing recovery command must not be defeated by the same
synchronized-output skip that stranded the content (#456)."
  :tags '(native)
  (ghostel-test--with-open-sync-output (_buf term)
    (ghostel-force-redraw)
    (should (string-match-p "UPDATED-CONTENT" (buffer-string)))
    (should-not (string-match-p "BASELINE-CONTENT" (buffer-string)))))

(ert-deftest ghostel-test-resize-width-change-full-repaint ()
  "After width change on alt screen, all rows repainted correctly.
Matches the real htop scenario: width changes from wide to narrow,
app redraws all rows at new width via the filter pipeline."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-width-change*")))
    (unwind-protect
        (with-current-buffer buf
          (set-window-buffer (selected-window) (current-buffer))
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 6 80 100))
          (let* ((ghostel-detect-password-prompts nil)
                 (proc (start-process "ghostel-test-w" buf "sleep" "60"))
                 (ghostel--process proc)
                 (inhibit-read-only t))
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 6 80)
            (set-process-query-on-exit-flag proc nil)
            (unwind-protect
                (progn
                  ;; Alt screen, fill all rows at 80 columns.
                  (ghostel--write-vt ghostel--term "\e[?1049h\e[H\e[2J")
                  (dotimes (i 6)
                    (ghostel--write-vt ghostel--term
                                       (format "\e[%d;1H%-80s" (1+ i) (format "WIDE-R%02d" i))))
                  (ghostel--redraw ghostel--term t)
                  (let ((c (buffer-substring-no-properties (point-min) (point-max))))
                    (should (string-match-p "WIDE-R00" c))
                    ;; Row 1 is at most `cols' chars wide after the
                    ;; renderer trims unwritten padding.  The shell
                    ;; here left-pads with spaces up to 80 cols via
                    ;; `%-80s', which libghostty records as written
                    ;; space cells, so row 1 stays exactly 80 chars.
                    (should (= 80 (length (car (split-string c "\n"))))))

                  ;; Simulate what the resize function does.
                  (ghostel--set-size ghostel--term 6 40)
                  (set-process-window-size proc 6 40)
                  (setq ghostel--force-next-redraw t)

                  ;; App redraws ALL rows at new width, through filter pipeline.
                  (let ((response (concat
                                   "\e[H\e[2J"
                                   (mapconcat
                                    (lambda (i) (format "\e[%d;1HNARROW-R%02d" (1+ i) i))
                                    (number-sequence 0 5) ""))))
                    (ghostel--filter proc response))
                  (ghostel--redraw-now buf)

                  (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                    ;; All rows must have new narrow content.
                    (should (string-match-p "NARROW-R00" content))
                    (should (string-match-p "NARROW-R05" content))
                    ;; No old wide content.
                    (should-not (string-match-p "WIDE-R" content))
                    ;; Each row is at most 40 chars (the new terminal
                    ;; width) — the app wrote 10 chars then stopped,
                    ;; so the renderer trims at the content end.
                    (dolist (row (split-string content "\n"))
                      (should (<= (length row) 40)))))
              (when (process-live-p proc)
                (delete-process proc)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-resize-through-filter-pipeline ()
  "Full pipeline test: resize, then app response goes through filter path.
The app's output enters the terminal via `ghostel--filter' and is
rendered by `ghostel--redraw-now'.  This is the exact real-world path."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pipeline*")))
    (unwind-protect
        (with-current-buffer buf
          (set-window-buffer (selected-window) (current-buffer))
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 10 40 100))
          (let* ((ghostel-detect-password-prompts nil)
                 (process-environment
                  (append (list "TERM=xterm-256color" "COLUMNS=40" "LINES=10")
                          process-environment))
                 (proc (start-process "ghostel-test-pipe" buf "sleep" "60")))
            (setq ghostel--process proc)
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 10 40)
            (set-process-query-on-exit-flag proc nil)
            (unwind-protect
                (let ((inhibit-read-only t))
                  ;; Initial content on alt screen (written directly to VT).
                  (ghostel--write-vt ghostel--term "\e[?1049h\e[H\e[2J")
                  (dotimes (i 10)
                    (ghostel--write-vt ghostel--term
                                       (format "\e[%d;1H%-40s" (1+ i) (format "OLD-%02d" i))))
                  (ghostel--redraw ghostel--term t)
                  (should (string-match-p "OLD-00"
                                          (buffer-substring-no-properties (point-min) (point-max))))

                  ;; Resize (as our resize function does).
                  (ghostel--set-size ghostel--term 6 40)
                  (set-process-window-size proc 6 40)
                  (ghostel--redraw ghostel--term t)
                  (setq ghostel--force-next-redraw t)

                  ;; Simulate app's SIGWINCH response arriving through the filter.
                  ;; This is the real pipeline: filter → terminal → delayed-redraw.
                  ;; Use BSU/ESU like htop does.
                  (let ((response (concat
                                   "\e[?2026h"      ; BSU
                                   "\e[?25l"         ; hide cursor
                                   "\e[H\e[2J"       ; clear
                                   (mapconcat
                                    (lambda (i)
                                      (format "\e[%d;1HNEW-%02d%s" (1+ i) i
                                              (make-string (- 40 6) ?\s)))
                                    (number-sequence 0 5) "")
                                   "\e[6;7H"         ; position cursor
                                   "\e[?25h"         ; show cursor
                                   "\e[?2026l")))    ; ESU
                    ;; Feed through the filter into the terminal.
                    (ghostel--filter proc response))

                  ;; Now call delayed-redraw (as the timer would).
                  (ghostel--redraw-now buf)

                  (let ((content (buffer-substring-no-properties (point-min) (point-max))))
                    (should (string-match-p "NEW-00" content))
                    (should (string-match-p "NEW-05" content))
                    (should-not (string-match-p "OLD-" content))
                    (should (equal 6 (count-lines (point-min) (point-max))))))
              (when (process-live-p proc)
                (delete-process proc)))))
      (kill-buffer buf))))



;;; Delayed redraw and hidden buffers

(ert-deftest ghostel-test-delayed-redraw-skips-native-redraw-without-window ()
  "When the buffer has no window, `ghostel--redraw-now' must not call \
`ghostel--redraw'."
  (let ((buf (generate-new-buffer " *ghostel-test-no-window-redraw*"))
        (ghostel-detect-password-prompts nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; The buffer from `generate-new-buffer' is not displayed in
          ;; any window, so `ghostel--get-render-window' returns nil
          ;; naturally — no need to stub `get-buffer-window-list'.
          (let ((ghostel--term t)
                (redraw-called nil))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw)
                       (lambda (&rest _) (setq redraw-called t))))
              (ghostel--redraw-now buf)
              (should-not redraw-called))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-defers-redraw-while-hidden ()
  "Buffer is not redrawn while hidden.
When the buffer reappears, it is immediately redrawn."
  :tags '(native)
  (let* ((win (selected-window))
         (orig-buf (window-buffer win))
         (buf (generate-new-buffer " *ghostel-test-hidden-defer*")))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (with-current-buffer buf
            (ghostel-mode)
            (let* ((term (ghostel--new 5 40 100))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t))
              (ghostel--write-vt term "initial\r\n")
              (ghostel--redraw term t)
              (should (string-match-p "initial" (buffer-string)))

              ;; Hide the buffer.
              (set-window-buffer win orig-buf)

              ;; Output arrives while hidden but does not appear; make
              ;; run-with-timer fire synchronously so no sleep is needed.
              (ghostel--write-vt term "while-hidden\r\n")
              (cl-letf (((symbol-function 'run-with-timer)
                         (lambda (_delay _repeat fn &rest args)
                           (apply fn args) nil)))
                (ghostel--invalidate))

              ;; Redraw blocked: buffer still shows the old content.
              (should-not (string-match-p "while-hidden" (buffer-string)))

              ;; Reshow the buffer; the hook redraws immediately without
              ;; waiting for the delayed invalidation timer.
              (set-window-buffer win buf)
              (run-hook-with-args 'window-buffer-change-functions win)

              (should (string-match-p "while-hidden" (buffer-string))))))
      (set-window-buffer win orig-buf)
      (kill-buffer buf))))

(ert-deftest ghostel-test-pty-output-is-processed-when-buffer-is-hidden ()
  "Output is processed but not drawn while the buffer is hidden.
When the buffer reappears, it is immediately redrawn."
  :tags '(native)
  (let* ((win (selected-window))
         (orig-buf (window-buffer win))
         (buf (generate-new-buffer " *ghostel-test-hidden-defer*")))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (with-current-buffer buf
            (ghostel-mode)
            (let* ((term (ghostel--new 5 40 100))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t))
              (ghostel--write-vt term "initial\r\n")
              (ghostel--redraw term t)
              (should (string-match-p "initial" (buffer-string)))

              ;; Hide the buffer.
              (set-window-buffer win orig-buf)

              ;; Simulate process output; make run-with-timer fire
              ;; synchronously so no sleep is needed.
              (cl-letf (((symbol-function 'run-with-timer)
                         (lambda (_delay _repeat fn &rest args)
                           (apply fn args) nil))
                        ((symbol-function 'process-buffer)
                         (lambda (_) buf)))
                (ghostel--filter nil "while-hidden\r\n"))
              (should-not (string-match-p "while-hidden" (buffer-string)))

              ;; Output should have been processed so force redrawing should
              ;; show it:
              (ghostel--redraw term)
              (should (string-match-p "while-hidden" (buffer-string))))))
      (set-window-buffer win orig-buf)
      (kill-buffer buf))))

;;; Crash and internal-invariant regressions
;;
;; Tests for bugs that manifested as panics or internal state corruption
;; rather than wrong visible output.  Grouped here so they don't dilute
;; the feature-oriented sections above and have an obvious home for
;; future additions.

(defun ghostel-test--numbered-lines (count width)
  "Return COUNT numbered lines with WIDTH x characters per line."
  (with-temp-buffer
    (dotimes (i count)
      (insert (format "%05d: " i) (make-string width ?x) "\n"))
    (buffer-string)))

(ert-deftest ghostel-test-page-eviction-before-redraw ()
  "Regression: page-serial underflow when initial active area scrolls off entirely.
Scenario (from Hypothesis failure): 1×136 terminal, render once while
empty (seeds pages_in_buffer with the initial blank page serial), then
write 231 lines of 273 bytes each — each line wraps to 3 visual rows,
so 693 total rows cross the libghostty page boundary and force the
active row onto a fresh internal page.  The second redraw must be
incremental (no force-full) so the buffer is not cleared: the renderer
then has existing buffer content to replace rather than append, and
without evicting stale pages_in_buffer entries before rendering it
subtracts old_line_len from the newly-created page whose char_len is
0, causing integer underflow at Renderer.zig:654."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-page-evict*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 1 136 16384))
                 (inhibit-read-only t)
                 ;; 273-byte lines wrap to 3 visual rows in a 136-col
                 ;; terminal (136+136+1), so 231 lines = 693 rows
                 ;; which exceeds the libghostty page capacity and
                 ;; forces allocation of a new internal page.
                 (line (concat (make-string 273 ?x) "\r\n")))
            ;; Render once while empty — seeds pages_in_buffer with
            ;; the initial (blank) page serial.
            (ghostel--redraw term t)
            ;; Write enough wrapped lines to push the active row onto
            ;; a new libghostty page.
            (dotimes (_ 231)
              (ghostel--write-vt term line))
            ;; Incremental redraw (no force-full): the buffer retains
            ;; the content from the first render, so the renderer takes
            ;; the replace path.  Without the fix it underflows
            ;; char_len, signalling an error from the native module.
            (ghostel--redraw term)
            ;; Sanity: the active row content is present in the buffer.
            (should (string-match-p "x"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-resize-eviction-char-count-stays-in-buffer-bounds ()
  "Regression: resizing must not stale scrollback char counts.
A row-count resize between materialized scrollback and later eviction
left page character accounting larger than the actual buffer, so the
next eviction called `delete-region' beyond `point-max'."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-evict*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((term (ghostel--new 1 90 16384))
                (inhibit-read-only t))
            (ghostel--write-vt term (ghostel-test--numbered-lines 400 20))
            (ghostel--set-size term 10 90)
            (ghostel--redraw term)
            (ghostel--set-size term 11 90)
            (ghostel--redraw term)
            (ghostel--write-vt term (ghostel-test--numbered-lines 800 20))
            (ghostel--redraw term)))
      (kill-buffer buf))))


(defun ghostel-test--bold-color-palette ()
  "Return a 256-entry hex palette string with index 1 red and 9 green.
Used by bold-color tests so palette mapping is observable."
  (concat "#000000"                                ;; 0
          "#ff0000"                                ;; 1 (red)
          (apply #'concat (make-list 7 "#000000")) ;; 2..8
          "#00ff00"                                ;; 9 (bright red, distinguishable)
          (apply #'concat (make-list 246 "#000000"))))

(ert-deftest ghostel-test-bold-is-bright ()
  "Test that bold text uses bright colors when ghostel-bold-color is 'bright."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-bold*"))
        (ghostel-bold-color 'bright))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--set-palette term (ghostel-test--bold-color-palette))
            (ghostel--apply-bold-config term)

            ;; Write bold red text
            (ghostel--write-vt term "\e[1;31mBOLD\e[0m")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (equal "#00ff00" (plist-get face :foreground)))
              (should (eq 'bold (plist-get face :weight))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-bold-fixed-color ()
  "Test that bold text uses a fixed color when ghostel-bold-color is a hex string."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-bold-fixed*"))
        (ghostel-bold-color "#abcdef"))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--apply-bold-config term)

            ;; Write bold text without color
            (ghostel--write-vt term "\e[1mBOLD\e[0m")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (equal "#abcdef" (plist-get face :foreground)))
              (should (eq 'bold (plist-get face :weight))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-bold-fixed-color-keeps-truecolor-fg ()
  "A fixed bold color must not override an explicit truecolor foreground."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-bold-fixed-truecolor*"))
        (ghostel-bold-color "#abcdef"))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--apply-bold-config term)
            (ghostel--write-vt term "\e[1;38;2;17;34;51mRGB\e[0m")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (equal "#112233" (plist-get face :foreground)))
              (should (eq 'bold (plist-get face :weight))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-bold-color-nil-leaves-fg-alone ()
  "Test that bold text keeps its original color when `ghostel-bold-color' is nil."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-bold-nil*"))
        (ghostel-bold-color nil))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--set-palette term (ghostel-test--bold-color-palette))
            (ghostel--apply-bold-config term)
            ;; Bold red (palette 1) must stay red — no brightening to palette 9.
            (ghostel--write-vt term "\e[1;31mBOLD\e[0m")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (equal "#ff0000" (plist-get face :foreground)))
              (should (eq 'bold (plist-get face :weight))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-bold-fixed-also-brightens-palette ()
  "Test that fixed-color bold still maps palette 0-7 to 8-15.
The fixed color only applies to default-fg cells; palette colors take
the bright variant just like in `bright' mode."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-bold-fixed-palette*"))
        (ghostel-bold-color "#abcdef"))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--set-palette term (ghostel-test--bold-color-palette))
            (ghostel--apply-bold-config term)
            ;; Bold red (palette 1) → bright red (palette 9 = #00ff00),
            ;; NOT the fixed color #abcdef.
            (ghostel--write-vt term "\e[1;31mBOLD\e[0m")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (equal "#00ff00" (plist-get face :foreground))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-bold-leaves-bright-palette-alone ()
  "Test that bold on palette 8-15 is not re-mapped (no overflow into 16-23)."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-bold-bright-palette*"))
        (ghostel-bold-color 'bright))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--set-palette term (ghostel-test--bold-color-palette))
            (ghostel--apply-bold-config term)
            ;; SGR 91 selects palette 9 directly; bold must not shift it further.
            (ghostel--write-vt term "\e[1;91mBOLD\e[0m")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (equal "#00ff00" (plist-get face :foreground)))
              (should (eq 'bold (plist-get face :weight))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-render-default-bg-omits-background ()
  "Default-bg cells carry :foreground but no :background.
A non-default fg with the default bg lets a transparent frame show
through; fully default text carries no face at all."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-default-bg*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[31mRED\e[0mX")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (plist-get face :foreground))       ; colored fg present
              (should-not (plist-get face :background)))   ; default bg omitted
            ;; The trailing default 'X' needs no properties.
            (should-not (get-text-property (+ (point-min) 3) 'face))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-render-explicit-bg-kept ()
  "An explicit SGR background (48) is still emitted as :background."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-explicit-bg*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[48;2;18;52;86mX\e[0m")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (equal "#123456" (plist-get face :background))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-render-inverse-omits-fg-bg ()
  "Inverse video (7) on a default cell emits :inverse-video with no fg/bg.
Emacs swaps the default face at display time, so theme colors and frame
transparency are preserved instead of being baked into the cell."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-inverse*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-vt term "\e[7mINV\e[0m")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should (eq t (plist-get face :inverse-video)))
              (should-not (plist-get face :foreground))
              (should-not (plist-get face :background)))))
      (kill-buffer buf))))


;;; OSC 133 semantic property rendering

(ert-deftest ghostel-test-osc133-text-properties ()
  "OSC 133 prompt markers render `ghostel-prompt' text properties."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-osc133*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            ;; Simulate a prompt: A, prompt text, B, command, output, D.
            (ghostel--write-vt term "\e]133;A\e\\")
            (ghostel--write-vt term "$ ")
            (ghostel--redraw term)
            (ghostel--write-vt term "\e]133;B\e\\")
            (ghostel--write-vt term "echo hi\r\n")
            (ghostel--write-vt term "hi\r\n")
            (ghostel--write-vt term "\e]133;D;0\e\\")
            (ghostel--redraw term)

            (goto-char (point-min))
            (should (text-property-any (point-min) (point-max)
                                       'ghostel-prompt t))

            ;; Property should survive a full redraw.
            (ghostel--redraw term)
            (should (text-property-any (point-min) (point-max)
                                       'ghostel-prompt t))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-osc133-input-text-property ()
  "Cells between OSC 133 B and C should be marked `ghostel-input'.
This is what keeps `ghostel--detect-urls' from linkifying the user's
in-progress command line — the renderer marks input cells, the elisp
scanner skips them."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-osc133-input*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-vt
             term "\e]133;A\e\\$ \e]133;B\e\\cd src/main.rs")
            (ghostel--redraw term)
            (goto-char (point-min))
            (should (search-forward "cd src/main.rs" nil t))
            (let ((path-beg (- (point) (length "cd src/main.rs")))
                  (path-end (point)))
              (should (get-text-property path-beg 'ghostel-input))
              (should (get-text-property (1- path-end) 'ghostel-input))
              ;; The "$ " prompt prefix should NOT be marked as input.
              (should (null (get-text-property
                             (point-min) 'ghostel-input))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-osc133-prompt-stops-at-input ()
  "`ghostel-prompt' must end where `ghostel-input' begins on the row.
Without this, the historical prompt row carries `ghostel-prompt'
across the typed command, and `ghostel--detect-urls-skip-p' refuses
to linkify paths in past commands — even though they are outside the
active input range."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-osc133-prompt-input*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-vt
             term "\e]133;A\e\\$ \e]133;B\e\\ls /etc/hosts")
            (ghostel--redraw term)
            (goto-char (point-min))
            (should (search-forward "ls /etc/hosts" nil t))
            (let ((path-beg (- (point) (length "ls /etc/hosts")))
                  (path-end (point)))
              (should (get-text-property 1 'ghostel-prompt))
              (should (get-text-property 2 'ghostel-prompt))
              (should (null (get-text-property path-beg 'ghostel-prompt)))
              (should (null (get-text-property (1- path-end) 'ghostel-prompt)))
              (should (get-text-property path-beg 'ghostel-input))
              (should (get-text-property (1- path-end) 'ghostel-input)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-osc133-historical-input-linkifies ()
  "Historical typed commands keep their links after the prompt advances.
After the row scrolls past the active prompt the typed `/etc/hosts'
must gain a `fileref:' help-echo when `ghostel--detect-urls' runs.
Active prompt rows must NOT — RET on a linkified active-input cell
hijacks the keystroke in tty Emacs."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-osc133-historical-link*"))
        (target "/etc/hosts"))
    (skip-unless (file-exists-p target))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t)
                 (ghostel-enable-url-detection nil)
                 (ghostel-enable-file-detection t))
            ;; First prompt: still the active row.  Cursor is on the typed
            ;; line, so the path inside the input span must NOT be
            ;; linkified.
            (ghostel--write-vt
             term (format "\e]133;A\e\\$ \e]133;B\e\\ls %s" target))
            (ghostel--redraw term)
            (let ((path-beg (save-excursion
                              (goto-char (point-min))
                              (search-forward target)
                              (- (point) (length target)))))
              ;; Point sits at the live cursor after redraw; that is the
              ;; row `ghostel--detect-urls' treats as active.  Don't move it.
              (ghostel--detect-urls)
              (should (null (get-text-property path-beg 'help-echo))))

            ;; End the input, advance to a fresh prompt — the previous row
            ;; is now history.  Its `/etc/hosts' should become a fileref.
            (ghostel--write-vt
             term "\e]133;C\e\\\r\n\e]133;D;0\e\\\e]133;A\e\\$ \e]133;B\e\\")
            (ghostel--redraw term)
            (let ((path-beg (save-excursion
                              (goto-char (point-min))
                              (search-forward target)
                              (- (point) (length target)))))
              (ghostel--detect-urls)
              (let ((he (get-text-property path-beg 'help-echo)))
                (should (and he (string-prefix-p "fileref:" he)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-osc133-input-wide-char-boundary ()
  "Wide input chars take one Emacs char of `ghostel-input'.
The libghostty spacer-tail cell that follows a wide char produces
no Emacs char and must not extend the property region.  Trailing
narrow input after the wide char keeps growing the region."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-osc133-input-wide*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-vt
             term "\e]133;A\e\\$ \e]133;B\e\\日a")
            (ghostel--redraw term)
            (goto-char (point-min))
            (should (search-forward "日a" nil t))
            ;; "$ " is 2 narrow cells (positions 1-2); "日" is wide
            ;; (1 emacs char at position 3, occupying terminal cols 2-3);
            ;; "a" is narrow (position 4, terminal col 4).
            (should (null (get-text-property 1 'ghostel-input)))
            (should (null (get-text-property 2 'ghostel-input)))
            (should (get-text-property 3 'ghostel-input))
            (should (get-text-property 4 'ghostel-input))
            ;; The newline after "a" is past the input range.
            (should (null (get-text-property 5 'ghostel-input)))))
      (kill-buffer buf))))

(provide 'ghostel-render-test)
;;; ghostel-render-test.el ends here
