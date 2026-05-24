;;; ghostel-render-test.el --- Tests for ghostel: rendering -*- lexical-binding: t; -*-

;;; Commentary:

;; Renderer-focused tests.  These cover the Emacs-buffer rendering boundary:
;; cell/row rendering, faces, hyperlinks, scrollback materialization, clear
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
            (ghostel--write-input term "line one\r\nline two\r\nline three")
            (ghostel--redraw term t)
            ;; Anchor mark to "two" so its position sits well past point-min.
            (goto-char (point-min))
            (search-forward "two")
            (let ((target (point)))
              (set-marker (mark-marker) target)
              ;; Trigger a full redraw (erase-buffer path).
              (ghostel--write-input term " more")
              (ghostel--redraw term t)
              (should (= target (marker-position (mark-marker)))))))
      (kill-buffer buf))))



;;; Cell and row rendering basics

(ert-deftest ghostel-test-sgr ()
  "Test SGR escape sequences set cell styles."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e[1;31mHELLO\e[0m normal")
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
            (ghostel--write-input term "\e[2mDIM\e[0m ok")
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
            (ghostel--write-input term "\e[31mRED\e[0m normal")
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
            (ghostel--write-input term "\e[32m┌──┐\e[0m text")
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
            (ghostel--write-input term "🟢")
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

(ert-deftest ghostel-test-crlf ()
  "Test that bare LF is normalized to CRLF by the Zig module."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "first\nsecond")
    (let ((state (ghostel--copy-all-text term)))
      (should (string-match-p "first" state))              ; first line
      (should (string-match-p "second" state)))             ; second line
    (let ((cur (ghostel-test--cursor term)))
      (should (equal 6 (car cur)))                          ; cursor col after LF
      (should (> (cdr cur) 0)))))

(ert-deftest ghostel-test-crlf-split-across-writes ()
  "CRLF pair split across two write-input calls must not double-insert \\r.
Chunk A ends with \\r, chunk B starts with \\n.  Without cross-call
state the normalizer would treat the leading \\n as bare and emit
\\r\\r\\n to libghostty.  Visible effect: cursor lands on row 1 col 6
after \"first\\r\" + \"\\nsecond\", exactly as if the pair were sent in
one call; a bug would leave it on row 2 or otherwise desynced."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (term-single (ghostel--new 25 80 1000)))
    (ghostel--write-input term "first\r")
    (ghostel--write-input term "\nsecond")
    (ghostel--write-input term-single "first\r\nsecond")
    (should (equal (ghostel-test--cursor term)
                   (ghostel-test--cursor term-single)))))

(ert-deftest ghostel-test-crlf-split-with-empty-chunk ()
  "An empty write between \\r and \\n preserves the cross-call CR flag.
Regression guard for a naive implementation that resets `last_input_was_cr'
on every entry rather than only when input was consumed."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (term-single (ghostel--new 25 80 1000)))
    (ghostel--write-input term "first\r")
    (ghostel--write-input term "")          ; empty chunk must not clear flag
    (ghostel--write-input term "\nsecond")
    (ghostel--write-input term-single "first\r\nsecond")
    (should (equal (ghostel-test--cursor term)
                   (ghostel-test--cursor term-single)))))

(ert-deftest ghostel-test-crlf-standalone-cr-then-crlf ()
  "A lone CR followed by a complete CRLF stays two logical line-endings.
The normalizer must not collapse the trailing CR of write A and the
leading \\r of write B's \\r\\n into a single sequence: the input
\"a\\r\" + \"\\r\\nb\" is equivalent to sending \"a\\r\\r\\nb\" in one
call.  (Bare \\n comes from Emacs PTYs lacking ONLCR; bare \\r from
programs that explicitly emit a carriage return — both must be passed
through without cross-call munging.)"
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (term-single (ghostel--new 25 80 1000)))
    (ghostel--write-input term "a\r")
    (ghostel--write-input term "\r\nb")
    (ghostel--write-input term-single "a\r\r\nb")
    (should (equal (ghostel-test--cursor term)
                   (ghostel-test--cursor term-single)))))

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
            (ghostel--write-input term "\e[H\e[2Jhi")
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
            (ghostel--write-input term "\e[H\e[2J$ ")
            (ghostel--redraw term t)
            (let ((lines (split-string (buffer-substring-no-properties
                                        (point-min) (point-max))
                                       "\n")))
              (should (equal "$ " (car lines))))))
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
            (ghostel--write-input term "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
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

(ert-deftest ghostel-test-set-buffer-face-uses-default-face-colors ()
  "Regression: New terminal colors should not flicker.
ghostel--set-buffer-face must only ever receive ghostel-default face colors in
new terminal. Regression guard against color flickering."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-face-colors*"))
        (calls nil))
    (unwind-protect
        (let ((expected-fg (ghostel--face-hex-color 'ghostel-default :foreground))
              (expected-bg (ghostel--face-hex-color 'ghostel-default :background)))
          (cl-letf (((symbol-function 'ghostel--start-process) (lambda () nil))
                    ((symbol-function 'ghostel--set-buffer-face)
                     (lambda (fg bg) (push (list fg bg) calls))))
            (ghostel--init-buffer buf)
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (ghostel--write-input ghostel--term "hello")
                (ghostel--redraw ghostel--term t))))
          (should calls)
          (dolist (call calls)
            (should (equal expected-fg (car call)))
            (should (equal expected-bg (cadr call)))))
      (kill-buffer buf))))

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
            (ghostel--write-input term "\e[31mRED\e[0m")
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
  "Test that ghostel-sync-theme reapplies palette and redraw post-processing."
  (let ((palette-calls nil)
        (redraw-calls nil)
        (post-process-calls 0))
    (cl-letf (((symbol-function 'ghostel--apply-palette)
               (lambda (term) (push term palette-calls)))
              ((symbol-function 'ghostel--redraw)
               (lambda (term _) (push term redraw-calls)))
              ((symbol-function 'ghostel--schedule-link-detection)
               (lambda (&rest _args)
                 (setq post-process-calls (1+ post-process-calls)))))
      (let ((buf (generate-new-buffer " *ghostel-test-theme*"))
            (other (generate-new-buffer " *ghostel-test-other*")))
        (unwind-protect
            (cl-letf (((symbol-function 'buffer-list)
                       (lambda (&rest _) (list buf other))))
              ;; Set up a ghostel-mode buffer with a fake terminal.
              (with-current-buffer buf
                (ghostel-mode)
                (setq ghostel--term 'fake-term)
                (setq ghostel--input-mode 'semi-char)
                (setq ghostel-enable-url-detection t))
              (set-window-buffer (selected-window) buf)
              ;; `other' is not a ghostel buffer and should be ignored.
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should (memq 'fake-term redraw-calls))
              (should (= post-process-calls 1))

              ;; Verify copy mode (frozen) skips redraw
              (setq palette-calls nil
                    redraw-calls nil
                    post-process-calls 0)
              (with-current-buffer buf
                (setq ghostel--input-mode 'copy))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))    ; palette still applied in copy mode
              (should-not (memq 'fake-term redraw-calls)) ; redraw skipped in copy mode
              (should (= post-process-calls 0))

              ;; Verify emacs mode (unfrozen) still redraws
              (setq palette-calls nil
                    redraw-calls nil
                    post-process-calls 0)
              (with-current-buffer buf
                (setq ghostel--input-mode 'emacs))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should (memq 'fake-term redraw-calls))     ; redraw runs in emacs mode
              (should (= post-process-calls 1)))
          (kill-buffer buf)
          (kill-buffer other))))))

(ert-deftest ghostel-test-apply-palette-default-colors ()
  "Test that ghostel--apply-palette sets default fg/bg from the Emacs default face."
  (let ((default-colors-calls nil)
        (palette-calls nil))
    (cl-letf (((symbol-function 'ghostel--set-default-colors)
               (lambda (term fg bg)
                 (push (list term fg bg) default-colors-calls)))
              ((symbol-function 'ghostel--set-palette)
               (lambda (term colors) (push (list term colors) palette-calls))))
      ;; With a fake terminal, apply-palette should call set-default-colors
      (ghostel--apply-palette 'fake-term)
      (should (= 1 (length default-colors-calls)))
      (should (eq 'fake-term (car (car default-colors-calls))))
      ;; fg and bg should be hex color strings from the default face
      (let ((fg (nth 1 (car default-colors-calls)))
            (bg (nth 2 (car default-colors-calls))))
        (should (string-prefix-p "#" fg))
        (should (string-prefix-p "#" bg)))
      ;; Palette should also be set
      (should (= 1 (length palette-calls)))
      ;; With nil term, nothing should be called
      (setq default-colors-calls nil palette-calls nil)
      (ghostel--apply-palette nil)
      (should-not default-colors-calls)
      (should-not palette-calls))))

(ert-deftest ghostel-test-apply-palette-ghostel-default-face ()
  "`ghostel--apply-palette' reads default fg/bg from `ghostel-default', not `default'."
  (let ((looked-up nil)
        (default-colors-calls nil))
    (cl-letf (((symbol-function 'ghostel--set-default-colors)
               (lambda (term fg bg)
                 (push (list term fg bg) default-colors-calls)))
              ((symbol-function 'ghostel--set-palette) #'ignore)
              ((symbol-function 'ghostel--face-hex-color)
               (lambda (face _attr)
                 (push face looked-up)
                 "#abcdef")))
      (ghostel--apply-palette 'fake-term)
      ;; The two default-color lookups must target `ghostel-default',
      ;; never `default' directly — otherwise buffer-local customization
      ;; of the terminal's fg/bg is impossible (issue #178).
      (should (memq 'ghostel-default looked-up))
      (should-not (memq 'default looked-up))
      ;; The mocked color must reach `ghostel--set-default-colors',
      ;; proving the function used the lookup result rather than a
      ;; hardcoded value.
      (should (= 1 (length default-colors-calls)))
      (should (equal (list 'fake-term "#abcdef" "#abcdef")
                     (car default-colors-calls))))))



;;; Terminal metadata and titles

(ert-deftest ghostel-test-title ()
  "Test OSC 2 title change."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e]2;My Title\e\\")
    (should (equal "My Title" (ghostel--get-title term)))))

(ert-deftest ghostel-test-title-does-not-overwrite-manual-rename ()
  "Test that title updates do not overwrite a manual buffer rename."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (ghostel)
          (setq buf (current-buffer))
          (with-current-buffer buf
            (should (equal "*ghostel*" (buffer-name)))
            (should (equal "*ghostel*" ghostel--managed-buffer-name))
            (ghostel--set-title "Title A")
            (should (equal "*ghostel: Title A*" (buffer-name)))
            (should (equal "*ghostel: Title A*" ghostel--managed-buffer-name))
            (ghostel--set-title "Title A2")
            (should (equal "*ghostel: Title A2*" (buffer-name)))
            (should (equal "*ghostel: Title A2*" ghostel--managed-buffer-name))
            (rename-buffer "ghostel manual title test" t)
            (ghostel--set-title "Title B")
            (should (equal "ghostel manual title test" (buffer-name)))
            (should (equal "*ghostel: Title A2*" ghostel--managed-buffer-name))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-title-tracking-disabled ()
  "Test that title updates are ignored when `ghostel-set-title-function' is nil."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel-set-title-function nil))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (should (equal "*ghostel*" (buffer-name)))
              (ghostel--set-title "Ignored Title")
              (should (equal "*ghostel*" (buffer-name)))
              (should (equal "*ghostel*" ghostel--managed-buffer-name)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))



;;; Hyperlinks and URL rendering

(ert-deftest ghostel-test-hyperlinks ()
  "Test hyperlink keymap and helpers."
  :tags '(native)
  (should (keymapp ghostel-link-map))                      ; ghostel-link-map is a keymap
  (should (lookup-key ghostel-link-map [mouse-1]))         ; mouse-1 bound in link map
  (should (lookup-key ghostel-link-map [mouse-2]))         ; mouse-2 bound in link map
  ;; RET is intentionally NOT bound in the text-property link map: a
  ;; binding there outranks the local map and hijacks RET away from the
  ;; PTY when a typed substring is misdetected as a link.  The
  ;; RET-follows-link affordance lives in the read-only and line-mode
  ;; maps so it works in copy, Emacs, and line modes without
  ;; intercepting RET in semi-char/char.
  (should (null (lookup-key ghostel-link-map (kbd "RET"))))
  (should (eq #'ghostel-open-link-at-point
              (lookup-key ghostel-readonly-mode-map (kbd "RET"))))
  (should (eq #'ghostel-open-link-at-point
              (lookup-key ghostel-readonly-mode-map (kbd "<return>"))))
  (should (eq #'ghostel-line-mode-send-or-open-link
              (lookup-key ghostel-line-mode-map (kbd "RET"))))
  (should (eq #'ghostel-line-mode-send-or-open-link
              (lookup-key ghostel-line-mode-map (kbd "<return>"))))
  (should (commandp #'ghostel-open-link-at-point))         ; open-link-at-point is interactive
  (should (null (ghostel--open-link nil)))                 ; open-link returns nil for empty
  (should (null (ghostel--open-link 42))))

(ert-deftest ghostel-test-uri-at-pos-prefers-string-help-echo ()
  "`ghostel--uri-at-pos' returns a string `help-echo' without calling native.
Plain-text link detection stores URIs as strings; the native path must
not be reached when the property is already a string."
  (with-temp-buffer
    (insert "click here")
    (put-text-property 1 11 'help-echo "https://static.example.com")
    (goto-char 5)
    (let (native-called)
      (cl-letf (((symbol-function 'ghostel--native-uri-at-pos)
                 (lambda (_) (setq native-called t) "should-not-reach")))
        (should (equal "https://static.example.com"
                       (ghostel--uri-at-pos (point))))
        (should-not native-called)))))

(ert-deftest ghostel-test-uri-at-pos-calls-native-for-function-help-echo ()
  "`ghostel--uri-at-pos' delegates to native when `help-echo' is a function.
OSC8 links set `help-echo' to the symbol `ghostel--native-link-help-echo';
`ghostel--uri-at-pos' must call `ghostel--native-uri-at-pos' in that case."
  (with-temp-buffer
    (insert "click here")
    (put-text-property 1 11 'help-echo #'ghostel--native-link-help-echo)
    (goto-char 5)
    (cl-letf (((symbol-function 'ghostel--native-uri-at-pos)
               (lambda (_pos) "native-uri")))
      (should (equal "native-uri" (ghostel--uri-at-pos (point)))))))

(ert-deftest ghostel-test-native-link-help-echo-calls-uri-at-pos ()
  "`ghostel--native-link-help-echo' delegates to `ghostel--native-uri-at-pos'.
The help-echo handler stored on OSC8 link text-properties must call the
native URI lookup when Emacs invokes it for tooltip display or clicking."
  (let ((buf (generate-new-buffer " *ghostel-test-echo-handler*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (insert "test content")
            (cl-letf (((symbol-function 'ghostel--native-uri-at-pos)
                       (lambda (pos) (format "uri-at-%d" pos))))
              (should (equal "uri-at-1"
                             (ghostel--native-link-help-echo
                              (selected-window) nil 1))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-url-detection ()
  "Test automatic URL detection in plain text."
  ;; Test buffers add a trailing newline so point lands on an empty line
  ;; below the test content; the cursor-row skip in `ghostel--detect-urls'
  ;; then leaves the test content untouched.
  ;; Basic URL detection
  (with-temp-buffer
    (insert "Visit https://example.com for info\n")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com"                   ; url help-echo
                   (get-text-property 7 'help-echo)))
    (should (get-text-property 7 'mouse-face))             ; url mouse-face
    (should (get-text-property 7 'keymap)))                ; url keymap
  ;; Disabled detection
  (with-temp-buffer
    (insert "Visit https://example.com for info\n")
    (let ((ghostel-enable-url-detection nil))
      (ghostel--detect-urls))
    (should (null (get-text-property 7 'help-echo))))      ; url detection disabled
  ;; Skips existing OSC 8 links (help-echo is the native handler function symbol)
  (with-temp-buffer
    (insert "Visit https://other.com for info\n")
    (put-text-property 7 26 'help-echo #'ghostel--native-link-help-echo)
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (eq #'ghostel--native-link-help-echo           ; osc8 handler not overwritten
                (get-text-property 7 'help-echo))))
  ;; URL not ending in punctuation
  (with-temp-buffer
    (insert "See https://example.com/path.\n")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com/path"              ; url strips trailing dot
                   (get-text-property 5 'help-echo))))
  ;; File:line detection with absolute path
  (let ((test-file (locate-library "ghostel")))
    (with-temp-buffer
      (insert (format "Error at %s:42 bad\n" test-file))
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (let ((he (get-text-property 10 'help-echo)))
        (should (and he (string-prefix-p "fileref:" he)))  ; file:line help-echo set
        (should (and he (string-suffix-p ":42" he)))))     ; file:line contains line number
    ;; File:line for non-existent file produces no link
    (with-temp-buffer
      (insert "Error at /no/such/file.el:10 bad\n")
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; nonexistent file: no help-echo
    ;; File detection disabled
    (with-temp-buffer
      (insert (format "Error at %s:42 bad\n" test-file))
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; file detection disabled
    ;; ghostel--open-link dispatches fileref:
    (let ((opened nil))
      (cl-letf (((symbol-function 'find-file-other-window)
                 (lambda (f) (setq opened f))))
        (ghostel--open-link (format "fileref:%s:10" test-file)))
      (should (equal test-file opened)))                   ; fileref opens correct file
    ;; Helper: find the first fileref help-echo anywhere in the buffer.
    (cl-flet ((find-fileref ()
                (save-excursion
                  (let ((pos (point-min)) found)
                    (while (and (not found) pos (< pos (point-max)))
                      (let ((he (get-text-property pos 'help-echo)))
                        (when (and he (string-prefix-p "fileref:" he))
                          (setq found he)))
                      (setq pos (next-single-property-change
                                 pos 'help-echo nil (point-max))))
                    found))))
      ;; Bare relative path (Rust/Go/TS compiler output)
      (let ((dir (file-name-directory test-file))
            (rel "ghostel.el"))
        ;; Nonexistent bare relative path: no link
        (with-temp-buffer
          (setq default-directory dir)
          (insert (format "   --> wrapped/%s:43\n" rel))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (should (null (find-fileref))))           ; nonexistent bare path skipped
        ;; Existing bare relative path: linkified with line AND column preserved
        (with-temp-buffer
          (setq default-directory (file-name-directory (directory-file-name dir)))
          (insert (format "  --> %s/%s:43:4\n"
                          (file-name-nondirectory (directory-file-name dir))
                          rel))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (let ((he (find-fileref)))
            (should (and he (string-prefix-p "fileref:" he)))
            (should (and he (string-suffix-p ":43:4" he)))))) ; col preserved
      ;; Path embedded in punctuation (Python traceback style) must match
      (with-temp-buffer
        (insert (format "  at foo (%s:10:5)\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (let ((he (find-fileref)))
          (should (and he (string-prefix-p "fileref:" he)))   ; paren-wrapped path matched
          (should (and he (string-suffix-p ":10:5" he)))
          ;; Trailing `)' must NOT be absorbed into the path
          (should (and he (not (string-suffix-p ")" he))))))
      ;; Wrapper chars (backtick, paren, bracket, brace, quotes) around a
      ;; path-only reference must not bleed into the match.
      (dolist (wrap '(("`" . "`") ("(" . ")") ("[" . "]") ("{" . "}")
                      ("'" . "'") ("\"" . "\"")))
        (with-temp-buffer
          (insert (format "see %s%s%s here\n" (car wrap) test-file (cdr wrap)))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (let ((he (find-fileref)))
            (should (and he (string-prefix-p "fileref:" he)))
            (should (and he (string-suffix-p test-file he)))    ; no wrapper tail
            (should (and he (not (string-suffix-p (cdr wrap) he)))))))
      ;; Tilde-prefixed paths are detected and linkified.
      (let* ((tilde-path "~/.emacs.d/init.el:42")
             (tilde-file (expand-file-name ".emacs.d/init.el" (expand-file-name "~"))))
        ;; Existing tilde path is linkified.
        (with-temp-buffer
          (insert (format "Error at %s bad\n" tilde-path))
          (cl-letf (((symbol-function 'file-exists-p)
                     (lambda (f) (equal f tilde-file))))
            (let ((ghostel-enable-url-detection t))
              (ghostel--detect-urls))
            (let ((he (find-fileref)))
              (should (and he (string-prefix-p "fileref:" he)))
              (should (and he (string-suffix-p ":42" he)))))))
      ;; Bare filename without a slash must NOT match (avoids FS stat storms)
      (with-temp-buffer
        (setq default-directory (file-name-directory test-file))
        (insert "main.go:12:5: undefined: foo\n")
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (null (find-fileref))))            ; bare filename skipped
      ;; TRAMP `default-directory' disables file detection entirely — otherwise
      ;; every candidate would trigger a remote stat per redraw.
      (with-temp-buffer
        (setq default-directory "/ssh:example.com:/tmp/")
        (insert (format "see %s here\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (null (find-fileref))))            ; TRAMP → detection skipped
      ;; Custom path regex can opt into broader matching (bare filenames)
      (with-temp-buffer
        (setq default-directory (file-name-directory test-file))
        (insert "ghostel.el:42 here\n")
        (let ((ghostel-enable-url-detection t)
              (ghostel-file-detection-path-regex
               "[[:alnum:]_.][^ \t\n\r:\"<>]*"))
          (ghostel--detect-urls))
        (should (find-fileref)))                   ; custom path regex opts in
      ;; Path-only reference (no `:line' suffix): /absolute and ./relative
      ;; both linkify when the file exists.
      (with-temp-buffer
        (insert (format "see %s here\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (let ((he (find-fileref)))
          (should (and he (string-prefix-p "fileref:" he)))
          (should (and he (not (string-match-p ":[0-9]+\\'" he)))))) ; no line
      ;; Path-only reference for a nonexistent file is not linkified.
      (with-temp-buffer
        (insert "see /no/such/path/exists here\n")
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (null (find-fileref))))
      ;; ghostel--open-link with :line:col positions the cursor
      (let ((opened nil) (col-arg nil))
        (cl-letf (((symbol-function 'find-file-other-window)
                   (lambda (f) (setq opened f)))
                  ((symbol-function 'move-to-column)
                   (lambda (c &optional _force) (setq col-arg c))))
          (ghostel--open-link (format "fileref:%s:10:7" test-file)))
        (should (equal test-file opened))
        (should (equal 6 col-arg)))                  ; :col 7 → column 6 (0-indexed)
      ;; ghostel--open-link with path-only fileref opens the file without
      ;; moving point past `point-min'.
      (let ((opened nil) (moved nil))
        (cl-letf (((symbol-function 'find-file-other-window)
                   (lambda (f) (setq opened f)))
                  ((symbol-function 'forward-line)
                   (lambda (&rest _) (setq moved t))))
          (ghostel--open-link (format "fileref:%s" test-file)))
        (should (equal test-file opened))
        (should (null moved))))))

(ert-deftest ghostel-test-detect-urls-skips-active-input ()
  "Link detection rules around prompts and user input (issue #199).
- `ghostel-prompt' (shell-generated decoration): never linkified.
- The cursor's line (active typing): not linkified — in tty Emacs RET
  on a linkified cell hijacks the keystroke, and the cursor-row skip
  works for both OSC 133 shells and markerless REPLs (Gemini CLI etc).
- Other lines (historical typed commands, output): linkified, so users
  can follow paths in past commands and program output."
  :tags '(native)
  (let ((test-file (locate-library "ghostel")))
    ;; History line → both file ref and URL linkified.  Active line
    ;; (cursor's line) → both skipped, regardless of whether the cells
    ;; carry `ghostel-input' or not.
    (with-temp-buffer
      (let ((default-directory (file-name-directory test-file)))
        (insert (format "$ ls %s https://hist.example\n" test-file)) ; line 1: history
        (insert (format "$ cat %s https://live.example" test-file))  ; line 2: active
        (put-text-property (point-min) (point-max) 'ghostel-input t)
        (goto-char (point-max))                                       ; cursor on line 2
        (let ((ghostel-enable-url-detection t)
              (ghostel-enable-file-detection t))
          (ghostel--detect-urls))
        (goto-char (point-min))
        (search-forward test-file nil t)
        (let ((he (get-text-property (match-beginning 0) 'help-echo)))
          (should (and he (string-prefix-p "fileref:" he)))) ; history file → linked
        (search-forward "https://hist.example")
        (should (equal "https://hist.example"
                       (get-text-property (match-beginning 0) 'help-echo))) ; history URL → linked
        (search-forward test-file nil t)
        (should (null (get-text-property (match-beginning 0) 'help-echo))) ; active file → skipped
        (search-forward "https://live.example")
        (should (null (get-text-property (match-beginning 0) 'help-echo))))) ; active URL → skipped
    ;; Cursor-row skip is unconditional: a URL on the cursor's line is
    ;; not linkified even when no `ghostel-input' marker covers it.  This
    ;; is what protects RET in REPLs like Gemini CLI or raw shells that
    ;; emit no OSC 133 sequences.  No trailing newline — cursor stays on
    ;; the typed line.
    (with-temp-buffer
      (insert "out https://before.example mid https://typed.example tail")
      (goto-char (point-max))                                           ; cursor on line 1
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (goto-char (point-min))
      (search-forward "https://before.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo))) ; cursor row → skipped
      (search-forward "https://typed.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo)))) ; cursor row → skipped
    ;; No OSC 133 markers at all (e.g. Gemini CLI prompt or a raw shell):
    ;; output on previous lines is still linkified, only the cursor row
    ;; is protected.
    (with-temp-buffer
      (insert "history https://past.example\n") ; line 1: previous output
      (insert "> https://typed.example tail")   ; line 2: REPL prompt with cursor
      (goto-char (point-max))                   ; cursor on line 2
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (goto-char (point-min))
      (search-forward "https://past.example")
      (should (equal "https://past.example"
                     (get-text-property (match-beginning 0) 'help-echo))) ; history → linked
      (search-forward "https://typed.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo)))) ; cursor row → skipped
    ;; `ghostel-prompt' (prompt prefix) is never linkified — neither on
    ;; the active line nor in scrollback.  Path appears in the prompt's
    ;; cwd display; output below is plain text and stays linkifiable.
    (with-temp-buffer
      (let ((default-directory (file-name-directory test-file)))
        (insert (format "%s λ ls\n" test-file))           ; line 1: prompt prefix
        (insert (format "%s\n" test-file))                ; line 2: output
        (insert (format "%s λ " test-file))               ; line 3: live prompt
        ;; Prompt rows carry `ghostel-prompt' on the prefix; output does not.
        (save-excursion
          (goto-char (point-min))
          (let ((eol (line-end-position)))
            (put-text-property (point-min) eol 'ghostel-prompt t))
          (forward-line 2)
          (put-text-property (point) (point-max) 'ghostel-prompt t))
        (goto-char (point-max))
        (let ((ghostel-enable-url-detection nil)
              (ghostel-enable-file-detection t))
          (ghostel--detect-urls))
        (goto-char (point-min))
        (search-forward test-file nil t)                  ; line 1: prompt prefix
        (should (null (get-text-property (match-beginning 0) 'help-echo)))
        (search-forward test-file nil t)                  ; line 2: output
        (should (get-text-property (match-beginning 0) 'help-echo))
        (search-forward test-file nil t)                  ; line 3: live prompt prefix
        (should (null (get-text-property (match-beginning 0) 'help-echo)))))))

(ert-deftest ghostel-test-delayed-redraw-defers-plain-link-detection ()
  "Redraw-triggered plain-text link detection should run after redraw."
  (let ((buf (generate-new-buffer " *ghostel-test-delayed-link*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term t)
                (ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (scheduled-count 0)
                timer-delay timer-repeat timer-fn timer-args)
            ;; FIXME: `ghostel--redraw' is stubbed because `ghostel--term'
            ;; here is the placeholder symbol `t', not a real native handle,
            ;; so the real renderer would crash.  The test still observes the
            ;; intended side effect (link-detection timer scheduling) via the
            ;; `run-with-timer' mock below.  A cleaner rewrite would require
            ;; spinning up a real terminal fixture.
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (delay repeat fn &rest args)
                         (setq scheduled-count (1+ scheduled-count)
                               timer-delay delay
                               timer-repeat repeat
                               timer-fn fn
                               timer-args args)
                         'ghostel-test-link-timer))
                      ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                      ((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--correct-mangled-scroll-positions)
                       #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--viewport-start)
                       (lambda () nil))
                      ((symbol-function 'get-buffer-window-list)
                       (lambda (&rest _) nil)))
              (let ((inhibit-read-only t))
                (insert "see https://example.com here\n"))
              (ghostel--delayed-redraw buf)
              (goto-char (point-min))
              (let* ((url "https://example.com")
                     (url-end (search-forward url nil t))
                     (url-beg (- url-end (length url))))
                (should url-end)
                (should (null (get-text-property url-beg 'help-echo)))
                (should (= scheduled-count 1))
                (should (numberp timer-delay))
                (should (> timer-delay 0))
                (should (null timer-repeat))
                (should timer-fn)
                ;; Move point off the URL line so the cursor-row skip in
                ;; `ghostel--detect-urls' doesn't mask the URL when the
                ;; queued detection runs.
                (goto-char (point-max))
                (apply timer-fn timer-args)
                (should (equal url
                               (get-text-property url-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-delayed-redraw-coalesces-plain-link-detection ()
  "Multiple redraws before the timer fires should share one detection pass."
  (let ((buf (generate-new-buffer " *ghostel-test-coalesced-link*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term t)
                (ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (scheduled-count 0)
                timer-repeat timer-fn timer-args)
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (_delay repeat fn &rest args)
                         (setq scheduled-count (1+ scheduled-count)
                               timer-repeat repeat
                               timer-fn fn
                               timer-args args)
                         'ghostel-test-link-timer))
                      ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                      ((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--correct-mangled-scroll-positions)
                       #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--viewport-start)
                       (lambda () nil))
                      ((symbol-function 'get-buffer-window-list)
                       (lambda (&rest _) nil)))
              (let ((inhibit-read-only t))
                (insert "first https://first.example\n"))
              (ghostel--delayed-redraw buf)
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (insert "second https://second.example\n"))
              (ghostel--delayed-redraw buf)
              (goto-char (point-min))
              (let* ((first-url "https://first.example")
                     (first-end (search-forward first-url nil t))
                     (first-beg (- first-end (length first-url)))
                     (second-url "https://second.example")
                     (second-end (search-forward second-url nil t))
                     (second-beg (- second-end (length second-url))))
                (should first-end)
                (should second-end)
                (should (null (get-text-property first-beg 'help-echo)))
                (should (null (get-text-property second-beg 'help-echo)))
                (should (= scheduled-count 1))
                (should (null timer-repeat))
                (should timer-fn)
                ;; Move point off the URL lines so the cursor-row skip in
                ;; `ghostel--detect-urls' doesn't mask either URL when the
                ;; queued detection runs.
                (goto-char (point-max))
                (apply timer-fn timer-args)
                (should (equal first-url
                               (get-text-property first-beg 'help-echo)))
                (should (equal second-url
                               (get-text-property second-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-detect-urls-allows-read-only-buffers ()
  "Plain-text link detection should still work in read-only buffers."
  (let* ((root (ghostel--resource-root))
         (test-file (file-relative-name
                     (expand-file-name "lisp/ghostel.el" root)
                     root)))
    (with-temp-buffer
      (let ((default-directory root))
        (insert (format "see %s:1 for details\n" test-file))
        (setq buffer-read-only t)
        (let ((ghostel-enable-url-detection nil)
              (ghostel-enable-file-detection t))
          (should (eq 'ok
                      (ignore-errors
                        (ghostel--detect-urls)
                        'ok)))
          (should (string-prefix-p
                   "fileref:"
                   (get-text-property 5 'help-echo))))))))

(ert-deftest ghostel-test-zero-delay-runs-plain-link-detection-synchronously ()
  "With delay set to 0, plain-link detection runs without scheduling a timer."
  (let ((buf (generate-new-buffer " *ghostel-test-zero-delay-link*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (ghostel-plain-link-detection-delay 0)
                (timer-scheduled nil)
                (inhibit-read-only t))
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (&rest _)
                         (setq timer-scheduled t)
                         'ghostel-test-zero-delay-timer)))
              (insert "see https://example.com here\n")
              (ghostel--queue-plain-link-detection (point-min) (point-max))
              (should-not timer-scheduled)
              (should-not ghostel--plain-link-detection-timer)
              (goto-char (point-min))
              (let* ((url "https://example.com")
                     (url-end (search-forward url nil t))
                     (url-beg (- url-end (length url))))
                (should url-end)
                (should (equal url
                               (get-text-property url-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-sentinel-cancels-plain-link-detection-timer ()
  "Process exit should cancel queued plain-text link detection timers."
  (let ((buf (generate-new-buffer " *ghostel-test-sentinel-links*")))
    (unwind-protect
        (let ((proc (make-pipe-process :name "ghostel-test-sentinel-links"
                                       :buffer buf
                                       :noquery t)))
          (with-current-buffer buf
            (setq ghostel-kill-buffer-on-exit nil
                  ghostel--plain-link-detection-timer
                  (run-with-timer 60 nil #'ignore))
            (ghostel--sentinel proc "finished\n")
            (should-not ghostel--plain-link-detection-timer))
          (when (process-live-p proc)
            (delete-process proc)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when ghostel--plain-link-detection-timer
            (cancel-timer ghostel--plain-link-detection-timer)))
        (kill-buffer buf)))))

(ert-deftest ghostel-test-hyperlink-navigation ()
  "Test `ghostel-next-hyperlink' / `ghostel-previous-hyperlink' search."
  :tags '(native)
  ;; Buffer layout (1-indexed positions):
  ;;   "AAA [LINK1] BBB [LINK2] CCC"
  ;;    123 4      5 6 7      8 9...
  (cl-flet ((setup ()
              (let ((buf (generate-new-buffer " *hyperlink-nav-test*")))
                (with-current-buffer buf
                  (insert "AAA ")                    ; 1..4
                  (let ((l1 (point)))                ; 5
                    (insert "LINK1")                 ; 5..9
                    (put-text-property l1 (point) 'help-echo "https://one"))
                  (insert " BBB ")                   ; 10..14
                  (let ((l2 (point)))                ; 15
                    (insert "LINK2")                 ; 15..19
                    (put-text-property l2 (point) 'help-echo "https://two"))
                  (insert " CCC"))                   ; 20..23
                buf)))
    ;; Forward from before any link lands on first link.
    (let ((buf (setup)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal 5 (ghostel--find-next-link (point-min))))
            (should (equal 5 (ghostel--find-next-link 2)))
            ;; From inside link1, skip to link2.
            (should (equal 15 (ghostel--find-next-link 5)))
            (should (equal 15 (ghostel--find-next-link 7)))
            ;; From inside link2, nothing after.
            (should (null (ghostel--find-next-link 15)))
            (should (null (ghostel--find-next-link 17)))
            (should (null (ghostel--find-next-link (point-max)))))
        (kill-buffer buf)))
    ;; Backward.
    (let ((buf (setup)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal 15 (ghostel--find-previous-link (point-max))))
            (should (equal 15 (ghostel--find-previous-link 22)))
            ;; From inside link2, find link1.
            (should (equal 5 (ghostel--find-previous-link 15)))
            (should (equal 5 (ghostel--find-previous-link 17)))
            ;; From inside link1, nothing before.
            (should (null (ghostel--find-previous-link 5)))
            (should (null (ghostel--find-previous-link 7)))
            (should (null (ghostel--find-previous-link (point-min)))))
        (kill-buffer buf)))
    ;; Empty buffer: no links at all.
    (with-temp-buffer
      (should (null (ghostel--find-next-link (point-min))))
      (should (null (ghostel--find-previous-link (point-max)))))
    ;; Buffer with no links but some text.
    (with-temp-buffer
      (insert "just some text with no links")
      (should (null (ghostel--find-next-link (point-min))))
      (should (null (ghostel--find-previous-link (point-max)))))
    ;; Commands are interactive.
    (should (commandp #'ghostel-next-hyperlink))
    (should (commandp #'ghostel-previous-hyperlink))))

(ert-deftest ghostel-test-hyperlink-navigation-wrap ()
  "Test that `ghostel--goto-hyperlink' wraps and errors cleanly."
  :tags '(native)
  ;; Wrap: from past the last link, next jumps back to first.
  (with-temp-buffer
    (insert "AAA LINK1 BBB LINK2 CCC")
    (put-text-property 5 10 'help-echo "https://one")
    (put-text-property 15 20 'help-echo "https://two")
    (goto-char (point-max))
    ;; No link after point — wraps to link1.
    (let ((inhibit-message t))
      (ghostel--goto-hyperlink 'next))
    (should (equal 5 (point)))
    ;; At point-min, going backward wraps to the last link.
    (goto-char (point-min))
    (let ((inhibit-message t))
      (ghostel--goto-hyperlink 'previous))
    (should (equal 15 (point))))
  ;; No links at all → user-error.
  (with-temp-buffer
    (insert "no links here at all")
    (should-error (ghostel--goto-hyperlink 'next) :type 'user-error)
    (should-error (ghostel--goto-hyperlink 'previous) :type 'user-error)))

(ert-deftest ghostel-test-scrollback-preserves-url-properties ()
  "Verify delayed plain-link properties survive scrollback promotion.
When libghostty pushes a row into scrollback, the redraw promotes the
existing buffer text instead of fetching a fresh copy from libghostty,
so any text properties the row earned while it was the viewport stay
attached."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-url*")))
    (unwind-protect
        (with-current-buffer buf
          (set-window-buffer (selected-window) (current-buffer))
          (ghostel-mode)
          (let* ((term (ghostel--new 5 80 1000))
                 (ghostel--term term)
                 (ghostel--term-rows 5)
                 (ghostel-plain-link-detection-delay 0)
                 (inhibit-read-only t)
                 (ghostel-enable-url-detection t)
                 (ghostel-enable-file-detection nil))
            ;; Write a row with a URL while it's in the viewport.
            (ghostel--write-input term "see https://example.com here\r\n")
            ;; Run the supported redraw path; zero delay keeps the deferred
            ;; post-processing deterministic while still exercising it.
            (ghostel--delayed-redraw buf)
            ;; Sanity: delayed plain-link detection applied a help-echo while
            ;; the row is visible.
            (goto-char (point-min))
            (let ((url-pos (search-forward "https://example.com" nil t)))
              (should url-pos)
              (should (equal "https://example.com"
                             (get-text-property (- url-pos 19) 'help-echo))))
            ;; Now scroll the URL row off the active screen.
            (dotimes (_ 6) (ghostel--write-input term "filler\r\n"))
            (ghostel--delayed-redraw buf)
            ;; The URL row now lives in the scrollback region of the buffer.
            (goto-char (point-min))
            (let ((url-pos (search-forward "https://example.com" nil t)))
              (should url-pos)
              ;; The clickable text properties survived the scroll because
              ;; promotion preserved the buffer text instead of re-fetching
              ;; from libghostty.
              (should (equal "https://example.com"
                             (get-text-property (- url-pos 19) 'help-echo))))))
      (kill-buffer buf))))



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
              (ghostel--write-input term (format "row-%02d\r\n" i)))
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
  "First-time scrollback materialization must contain actual content.
Regression test: when the initial (mostly empty) viewport was rendered
and then a burst of output overflowed the screen, the promotion
optimisation incorrectly kept the stale empty rows as scrollback
instead of fetching the real content from libghostty."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-bootstrap*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Render the initial (nearly empty) viewport so the buffer
            ;; has 5 rows of stale content — simulates a fresh terminal.
            (ghostel--write-input term "$ \r\n")
            (ghostel--redraw term t)
            ;; Now a burst of output overflows the viewport.
            (dotimes (i 15)
              (ghostel--write-input term (format "line-%02d\r\n" i)))
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
              (ghostel--write-input term (format "first-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "first-00" content))
              (should (string-match-p "first-07" content)))
            ;; Second batch: write more lines, redraw again.
            (dotimes (i 6)
              (ghostel--write-input term (format "second-%02d\r\n" i)))
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
              (ghostel--write-input term (format "early-%05d\r\n" i)))
            (ghostel--redraw term t)
            ;; Write a large batch in many small chunks with renders in between
            (dotimes (x 200)
              (dotimes (i 100)
                (ghostel--write-input term (format "late-%05d\r\n" i)))
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
              (ghostel--write-input term (format "early-%05d\r\n" i)))
            (ghostel--redraw term t)
            ;; Write a huge amount in one shot
            (dotimes (i 200000)
              (ghostel--write-input term (format "late-%05d\r\n" i)))
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
          ;; Simulate pending PTY output.  `ghostel-clear' must flush this
          ;; before writing CSI H / CSI 2J, otherwise the clear could race the
          ;; output and either lose history or recreate stale viewport text.
          (setq ghostel--pending-output
                (list (mapconcat (lambda (i) (format "clear-test-%d\r\n" i))
                                 (number-sequence 0 14) "")))
          (should ghostel--pending-output)
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
              (ghostel--write-input ghostel--term (format "line %d\r\n" i)))
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
              (ghostel--write-input term (format "before-%02d\r\n" i)))
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
            (ghostel--write-input term "\e[3J")
            (dotimes (i 5)
              (ghostel--write-input term (format "after-%02d\r\n" i)))
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
              (ghostel--write-input term (format "old-sb-%02d\r\n" i)))
            (dotimes (i 4)
              (ghostel--write-input term (format "old-vp-%02d\r\n" (+ i 6))))
            (ghostel--redraw term t)
            (let ((before (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "old-sb-00" before))
              (should (string-match-p "old-sb-05" before))
              (should (string-match-p "old-vp-09" before)))
            ;; Phase 2: clear scrollback and, before the next redraw, write
            ;; enough rows to recreate exactly 6 scrollback rows: the 4 old
            ;; viewport rows plus new-00 and new-01.  This keeps the row count
            ;; unchanged while changing the contents of the cleared region.
            (ghostel--write-input
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

(ert-deftest ghostel-test-clear-scrollback-resets-scroll-state ()
  "`ghostel-clear-scrollback' drops recorded scroll positions.
After the buffer is wiped, the old content no longer exists, so the
next redraw must anchor fresh to the new viewport rather than trying
to restore to a missing line."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-clear-reset*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; Pretend scroll state was recorded (e.g. user was reading
            ;; history when scrollback gets cleared).
            (setq ghostel--scroll-positions
                  (list (cons (selected-window)
                              (list '("scroll-10") '("scroll-11") 0))))
            (setq ghostel--last-anchor-position 42)
            (setq ghostel--process nil)
            (ghostel-clear-scrollback)
            ;; `ghostel--invalidate' schedules a redraw timer that
            ;; would otherwise fire after the buffer is killed.
            (when (timerp ghostel--redraw-timer)
              (cancel-timer ghostel--redraw-timer)
              (setq ghostel--redraw-timer nil))
            (should-not ghostel--scroll-positions)
            (should-not ghostel--last-anchor-position)))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
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
            (ghostel--write-input term "wrong\r\n")
            (ghostel--redraw term t)
            (ghostel--write-input term "\e[Hfoobar\e[5;0Hyolo\r\n")
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
              (ghostel--write-input term (format "row-%02d\r\n" i)))
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
              (ghostel--write-input term (format "row-%02d\r\n" i)))
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
              (ghostel--write-input term (format "first-%02d\r\n" i)))
            (ghostel--redraw term t)
            (ghostel-test--mark-all-lines-clean)
            ;; One more row scrolls through the viewport.
            (ghostel--write-input term "extra\r\n")
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
            (ghostel--write-input term "row-0\r\nrow-1\r\nrow-2\r\nrow-3\r\nrow-4\e[3;1H")
            (ghostel--redraw term t)
            (ghostel-test--mark-all-lines-clean)
            ;; Cursor is already on row 2; overwrite it in place.
            (ghostel--write-input term "modified")
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
            (ghostel--write-input term "line-A\r\nline-B\r\nline-C")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line-A" content))   ; initial row0
              (should (string-match-p "line-B" content))   ; initial row1
              (should (string-match-p "line-C" content)))  ; initial row2

            ;; Write more text on row 2 — only that row should be dirty
            (ghostel--write-input term " updated")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line-A" content))       ; row0 preserved
              (should (string-match-p "line-B" content))       ; row1 preserved
              (should (string-match-p "line-C updated" content))) ; row2 updated

            (should (equal 5 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))



;;; Resize rendering

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
              (ghostel--write-input term (format "row-%02d\r\n" i)))
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
            (ghostel--write-input term "hello\r\n")
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

(ert-deftest ghostel-test-resize-no-blank-flash ()
  "Buffer keeps old content after resize; redraw replaces it atomically.
Regression test: fnSetSize used to call `erase-buffer' synchronously,
leaving the buffer visibly empty until the next timer-driven redraw.
Now the erasure is deferred into redraw() under `inhibit-redisplay'."
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
              (ghostel--write-input term (format "LINE-%02d\r\n" i)))
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
  "Test that resize between BSU/ESU cycles gives clean content."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-sync*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 10 40 100))
                 (inhibit-read-only t))
            ;; Enter alt screen, write content, cursor at bottom
            (ghostel--write-input term "\e[?1049h")
            (dotimes (i 9) (ghostel--write-input term (format "line %d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (should (ghostel--mode-enabled term 1049))     ; alt screen enabled
            ;; Simulate a full BSU/ESU cycle (app redraw)
            (ghostel--write-input term "\e[?2026h\e[H\e[2J")
            (dotimes (i 9) (ghostel--write-input term (format "new %d\r\n" i)))
            (ghostel--write-input term "new prompt> ")
            (ghostel--write-input term "\e[?2026l")
            (should-not (ghostel--mode-enabled term 2026)) ; sync off after ESU
            ;; Resize between cycles (sync OFF) — should get clean content
            (ghostel--set-size term 6 40)
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "new prompt>" content)) ; prompt visible after resize
              (should (> (line-number-at-pos) 1))          ; cursor not at top
              (should (equal 6 (count-lines (point-min) (point-max))))) ; correct line count
            ;; Verify: resize DURING BSU gives garbage (cursor at top)
            (ghostel--write-input term "\e[?2026h\e[H\e[2J")
            (ghostel--write-input term "BANNER\r\n")
            (should (ghostel--mode-enabled term 2026))     ; sync on during BSU
            (ghostel--set-size term 5 40)
            (ghostel--redraw term)
            (should (<= (line-number-at-pos) 2))           ; mid-BSU: cursor near top
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should-not (string-match-p "new prompt>" content))))) ; mid-BSU: no prompt
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
            (ghostel--write-input term "\e[?1049h")  ; alt screen on
            (dotimes (i 10)
              (ghostel--write-input term (format "\e[%d;1HOLD-LINE-%02d" (1+ i) i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "OLD-LINE-00" content))
              (should (string-match-p "OLD-LINE-09" content)))

            ;; 2) Simulate what ghostel--window-adjust-process-window-size does:
            ;;    resize VT, synchronous redraw, set force flag.
            (ghostel--set-size term 6 40)
            (ghostel--redraw term t)
            (setq ghostel--force-next-redraw t)

            ;; 3) Simulate the app's SIGWINCH-triggered redraw with BSU/ESU.
            ;;    The app clears screen and redraws for the new 6-row size.
            (ghostel--write-input term "\e[?2026h")     ; BSU
            (ghostel--write-input term "\e[H\e[2J")     ; clear
            (dotimes (i 6)
              (ghostel--write-input term (format "\e[%d;1HNEW-LINE-%02d" (1+ i) i)))
            (ghostel--write-input term "\e[?2026l")     ; ESU

            ;; 4) Simulate what ghostel--delayed-redraw does:
            ;;    check BSU gate, flush, redraw.
            (ghostel--delayed-redraw buf)

            ;; 5) Verify: buffer must show NEW content, not OLD.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "NEW-LINE-00" content))
              (should (string-match-p "NEW-LINE-05" content))
              (should-not (string-match-p "OLD-LINE" content)))))
      (kill-buffer buf))))

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
          (let* ((proc (start-process "ghostel-test-w" buf "sleep" "60"))
                 (ghostel--process proc)
                 (inhibit-read-only t))
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 6 80)
            (set-process-query-on-exit-flag proc nil)
            (unwind-protect
                (progn
                  ;; Alt screen, fill all rows at 80 columns.
                  (ghostel--write-input ghostel--term "\e[?1049h\e[H\e[2J")
                  (dotimes (i 6)
                    (ghostel--write-input ghostel--term
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
                  (ghostel--delayed-redraw buf)

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
The app's output enters via `ghostel--filter' (pending-output) and is
rendered by `ghostel--delayed-redraw'.  This is the exact real-world path."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pipeline*")))
    (unwind-protect
        (with-current-buffer buf
          (set-window-buffer (selected-window) (current-buffer))
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 10 40 100))
          (let* ((process-environment
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
                  (ghostel--write-input ghostel--term "\e[?1049h\e[H\e[2J")
                  (dotimes (i 10)
                    (ghostel--write-input ghostel--term
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
                  ;; This is the real pipeline: filter → pending-output → delayed-redraw.
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
                    ;; Feed through the filter to accumulate as pending output.
                    (ghostel--filter proc response))

                  ;; Now call delayed-redraw (as the timer would).
                  (ghostel--delayed-redraw buf)

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
  "When the buffer has no window, `ghostel--delayed-redraw' must not call \
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
              (ghostel--delayed-redraw buf)
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
              (ghostel--write-input term "initial\r\n")
              (ghostel--redraw term t)
              (should (string-match-p "initial" (buffer-string)))

              ;; Hide the buffer.
              (set-window-buffer win orig-buf)

              ;; Output arrives while hidden but does not appear; make
              ;; run-with-timer fire synchronously so no sleep is needed.
              (ghostel--write-input term "while-hidden\r\n")
              (cl-letf (((symbol-function 'run-with-timer)
                         (lambda (_delay _repeat fn &rest args)
                           (apply fn args) nil)))
                (ghostel--invalidate))

              ;; Redraw blocked: buffer still shows the old content.
              (should-not (string-match-p "while-hidden" (buffer-string)))

              ;; Reshow the buffer; hook calls ghostel--invalidate again.
              (set-window-buffer win buf)
              (cl-letf (((symbol-function 'run-with-timer)
                         (lambda (_delay _repeat fn &rest args)
                           (apply fn args) nil)))
                (run-hook-with-args 'window-buffer-change-functions win))

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
              (ghostel--write-input term "initial\r\n")
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

(ert-deftest ghostel-test-hidden-buffer-snaps-on-reshow ()
  "Buffer re-shown after output-while-hidden snaps to the viewport (issue #177).
Dispatches through `window-buffer-change-functions' so the hook
wiring — not just `ghostel--reshow-snap' in isolation — is exercised."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-177-snap*"))
        (other (get-buffer-create "*ghostel-test-177-other*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t)
                 (win (selected-window)))
            (dotimes (i 30)
              (ghostel--write-input term (format "pre-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (set-window-buffer win buf)
            (goto-char (point-max))
            (set-window-point win (point-max))
            (set-window-start win (ghostel--viewport-start) t)
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            (let ((pre-hide-ws (window-start win)))
              ;; Hide; output arrives while hidden so the anchor advances.
              (set-window-buffer win other)
              (dotimes (i 30)
                (ghostel--write-input term (format "hidden-%02d\r\n" i)))
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              ;; Re-show with the stale pre-hide `window-start', then
              ;; dispatch the hook the way redisplay would.
              (set-window-buffer win buf)
              (set-window-start win pre-hide-ws t)
              (run-hook-with-args 'window-buffer-change-functions win)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              (should (= (window-start win) (ghostel--viewport-start)))
              ;; The snap entry was consumed and cleared.
              (should-not ghostel--windows-needing-snap))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf)
      (when (buffer-live-p other) (kill-buffer other)))))



;;; Window anchoring and scroll preservation

(ert-deftest ghostel-test-resize-redraw-anchors-window-start ()
  "After resize + redraw, `window-start' is at the viewport origin.
Without explicit anchoring, erase+rebuild inside redraw() clamps
`window-start' to 1 (top of scrollback), causing a visible jump when
Emacs auto-scrolls to make point visible."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-anchor*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (ghostel--force-next-redraw nil)
                 (inhibit-read-only t))
            ;; Build up scrollback so the viewport is not at buffer start.
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (should (> (line-number-at-pos (point-max)) 10))

            ;; Display in a real window so we can test window-start.
            (set-window-buffer (selected-window) buf)
            ;; Simulate the pre-resize steady state: window was
            ;; following the viewport (auto-follow), and a prior
            ;; redraw anchored `window-start' at the viewport.
            (let ((vp-before (save-excursion
                               (goto-char (point-max))
                               (forward-line -10)
                               (line-beginning-position))))
              (set-window-start (selected-window) vp-before t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; Resize + redraw via delayed-redraw (simulates the real path).
            (ghostel--set-size term 6 40)
            (setq ghostel--term-rows 6)
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; window-start should be at the viewport, not at buffer start.
            (let* ((ws (window-start (selected-window)))
                   (wp (window-point (selected-window)))
                   (vp-start (save-excursion
                               (goto-char (point-max))
                               (forward-line -6)
                               (line-beginning-position))))
              (should (= ws vp-start))
              (should (>= wp vp-start)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resets-vscroll ()
  "Redraw resets `window-vscroll' when point is in the viewport.
Regression for issue #105: with `pixel-scroll-precision-mode',
a non-zero pixel vscroll left on the window clips the top line
after a redraw (e.g. `clear').  Anchoring `window-start' alone is
not enough; the pixel offset must also be cleared."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll*"))
        (orig-buf (window-buffer (selected-window)))
        ;; Simulated pixel vscroll state per window.  Batch-mode
        ;; `window-vscroll' always returns 0, so we track the value
        ;; ourselves via a mocked `set-window-vscroll'.
        (vscroll-by-window (make-hash-table :test 'eq)))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Window was showing the viewport before the redraw — this
            ;; is the auto-follow case where vscroll must be reset.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp-before (save-excursion
                               (goto-char (point-max))
                               (forward-line -9)
                               (line-beginning-position))))
              (set-window-start (selected-window) vp-before t))
            ;; Seed a non-zero pixel vscroll (simulating what
            ;; `pixel-scroll-precision-mode' leaves behind).
            (puthash (selected-window) 7 vscroll-by-window)
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (win vscroll &optional pixels-p &rest _)
                         (should (eq pixels-p t))
                         (puthash win vscroll vscroll-by-window))))
              (ghostel--delayed-redraw buf))
            (should (= 0 (gethash (selected-window) vscroll-by-window)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resets-vscroll-all-windows ()
  "Redraw resets `window-vscroll' on every window showing the buffer.
`ghostel--delayed-redraw' iterates `get-buffer-window-list' so both
windows must be anchored."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll-multi*"))
        (orig-config (current-window-configuration))
        (vscroll-by-window (make-hash-table :test 'eq)))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (goto-char (point-max))
            (delete-other-windows)
            (set-window-buffer (selected-window) buf)
            (let ((w1 (selected-window))
                  (w2 (split-window-vertically))
                  (vp-before (save-excursion
                               (goto-char (point-max))
                               (forward-line -9)
                               (line-beginning-position))))
              (set-window-buffer w2 buf)
              (set-window-point w1 (point-max))
              (set-window-point w2 (point-max))
              ;; Both windows were at the viewport pre-redraw.
              (set-window-start w1 vp-before t)
              (set-window-start w2 vp-before t)
              (puthash w1 7 vscroll-by-window)
              (puthash w2 4 vscroll-by-window)
              (cl-letf (((symbol-function 'set-window-vscroll)
                         (lambda (win vscroll &optional pixels-p &rest _)
                           (should (eq pixels-p t))
                           (puthash win vscroll vscroll-by-window))))
                (ghostel--delayed-redraw buf))
              (should (= 0 (gethash w1 vscroll-by-window)))
              (should (= 0 (gethash w2 vscroll-by-window))))))
      (set-window-configuration orig-config)
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-vscroll-in-scrollback ()
  "Redraw leaves `window-vscroll' alone when point is in scrollback.
The vscroll reset is gated on the same condition as `set-window-start':
a user reading history should not be pulled around by live redraws."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll-scrollback*"))
        (orig-buf (window-buffer (selected-window)))
        (vscroll-called nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Seed the anchor by running a prior redraw so subsequent
            ;; scroll-preservation logic is in steady state.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Simulate the user scrolling into scrollback: both
            ;; window-start and point move above the viewport (that's
            ;; what real Emacs scrollers — pixel-scroll-precision,
            ;; mouse-wheel, scroll-up-command — produce).
            (goto-char (point-min))
            (set-window-point (selected-window) (point-min))
            (set-window-start (selected-window) (point-min) t)
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (&rest _) (setq vscroll-called t))))
              (ghostel--delayed-redraw buf))
            (should-not vscroll-called)))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-captures-scrollback-on-first-non-anchored ()
  "First non-anchored redraw captures `window-start' / `window-point'.
Simulates wheel/pixel-scroll that moves `window-start' above the
viewport before any scroll-positions entry has been recorded.  The
redraw must not yank ws back to the viewport (no snap) and must
capture the new scrollback state so subsequent redraws can preserve
it through mangling."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-ws-scrollback*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (ghostel--snap-requested nil)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Seed the anchor via a prior redraw so we're in steady
            ;; auto-follow state before simulating the wheel-up.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Simulate a scroller that moves window-start without moving
            ;; point (unusual but possible — e.g., pixel-scroll-precision
            ;; on a scroll that's small enough to keep point on-screen).
            (set-window-start (selected-window) (point-min) t)
            (let ((ws-before (window-start (selected-window)))
                  (wp-before (window-point (selected-window))))
              ;; No scroll-positions entry for this window yet, so the
              ;; pre-redraw restore is a no-op; this exercises capture,
              ;; not restoration.
              (should-not ghostel--scroll-positions)
              (ghostel--delayed-redraw buf)
              (should (= ws-before (window-start (selected-window))))
              (should (= wp-before (window-point (selected-window))))
              ;; And now scroll-positions has the captured entry.
              (should ghostel--scroll-positions))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-second-window-does-not-disturb-scrollback ()
  "Opening a second window on a ghostel buffer does not yank peer windows.
Issue #177 regression guard for the multi-window case: a window
already scrolled back for reading history must stay put when a new
window opens on the same buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-177-multi*"))
        (orig-config (current-window-configuration))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t)
                 (win-a (selected-window)))
            (dotimes (i 30)
              (ghostel--write-input term (format "pre-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (set-window-buffer win-a buf)
            (set-window-start win-a (ghostel--viewport-start) t)
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Scroll win-a into the scrollback.
            (set-window-start win-a (point-min) t)
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            (let ((scrollback-ws (window-start win-a))
                  (win-b (split-window win-a)))
              (set-window-buffer win-b buf)
              (set-window-start win-b (point-min) t)
              ;; Simulate the callback redisplay fires for the new window.
              (run-hook-with-args 'window-buffer-change-functions win-b)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              ;; win-b snapped; win-a's scrollback is untouched.
              (should (= (window-start win-b) (ghostel--viewport-start)))
              (should (= (window-start win-a) scrollback-ws))
              (should-not ghostel--windows-needing-snap))))
      (set-window-configuration orig-config)
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-scroll-during-live-output ()
  "Scrollback view is preserved when live PTY output triggers a redraw.
Before the fix, any redraw timer firing while the user was reading
scrollback yanked `window-start' and cursor back to the viewport.  With
the fix, live output grows the buffer without disturbing the scrolled-up
view or the user's cursor position."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-live-output-scroll*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Auto-follow steady state.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; User scrolls into scrollback (ws and point both move).
            (set-window-start (selected-window) (point-min) t)
            (goto-char (point-min))
            (set-window-point (selected-window) (point-min))
            (let ((ws-before (window-start (selected-window)))
                  (wp-before (window-point (selected-window))))

              ;; More PTY output arrives and the redraw timer fires.
              (ghostel--write-input term "extra-line\r\n")
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)

              (should (= ws-before (window-start (selected-window))))
              (should (= wp-before (window-point (selected-window)))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-scroll-across-window-resize ()
  "Window resize (e.g. `M-x' opening the minibuffer) keeps scrollback view.
Reproduces the reported bug: user scrolls up with the mouse wheel and
presses `M-x'; the minibuffer opens and shrinks the ghostel window,
which calls `ghostel--window-adjust-process-window-size' → delayed
redraw.  Before the fix, that redraw yanked `window-start' back to the
viewport.  After the fix, the scrolled-up view is preserved."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-preserve*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Steady-state auto-follow: window was at the viewport
            ;; and a prior redraw established `last-anchor-position'.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; Simulate wheel-up that moves both window-start and point
            ;; into the scrollback (as `pixel-scroll-precision-mode'
            ;; does when point would otherwise fall off-screen).
            (set-window-start (selected-window) (point-min) t)
            (goto-char (point-min))
            (set-window-point (selected-window) (point-min))
            ;; Real-world flow: some PTY output arrives between the
            ;; wheel-up and `M-x', so an output-driven redraw captures
            ;; the scrolled window into `ghostel--scroll-positions'
            ;; before the resize fires.  Without this intermediate
            ;; capture the resize redraw's drift heuristic would
            ;; (correctly, by that heuristic) classify this window as
            ;; drifted-but-anchored and snap it back.
            (ghostel--delayed-redraw buf)
            (should (assq (selected-window) ghostel--scroll-positions))
            (let ((ws-before (window-start (selected-window)))
                  (wp-before (window-point (selected-window))))

              ;; Simulate the M-x minibuffer resize path.  `cl-letf' on
              ;; the default adjust-fn returns a smaller size, so the
              ;; real handler runs `ghostel--set-size' and
              ;; `ghostel--delayed-redraw'.
              (cl-letf (((default-value 'window-adjust-process-window-size-function)
                         (lambda (&rest _) (cons 40 6)))
                        ;; The real handler reads process-buffer.  A
                        ;; throwaway pipe process with this buffer is
                        ;; enough; we clean it up below without letting
                        ;; the sentinel insert any status text.
                        ((symbol-function 'set-process-window-size) #'ignore))
                (setq ghostel--process
                      (make-pipe-process :name "ghostel-test-fake"
                                         :buffer buf
                                         :noquery t
                                         :filter #'ignore
                                         :sentinel #'ignore))
                (unwind-protect
                    (ghostel--window-adjust-process-window-size
                     ghostel--process
                     (list (selected-window)))
                  (delete-process ghostel--process)
                  (setq ghostel--process nil)))

              ;; The user's scrolled-up view must be preserved.
              (should (= ws-before (window-start (selected-window))))
              (should (= wp-before (window-point (selected-window)))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resize-preserves-anchor-when-emacs-drifts-ws ()
  "Resize keeps the window anchored when Emacs drifted `window-start' below it.
Regression test for issue #127: in TUIs whose cursor sits above the
viewport bottom, opening the minibuffer shrinks the window body and
Emacs's `keep-point-visible' moves `window-start' forward so the TUI
cursor stays on screen.  The resulting `ws < anchor' looked identical
to a real user scroll, so the force redraw captured a blank-row key,
found it at `point-min', and jumped `window-start' to 1.

With the fix, a force redraw classifies a window as anchored when it
wasn't recorded in `ghostel--scroll-positions' at the prior redraw —
so an Emacs-driven drift is treated as drift, not a scroll."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-anchor-drift*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            ;; Write enough blank-terminated lines that a drifted
            ;; ws-key would ambiguously match near `point-min'.
            (dotimes (i 30)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Steady-state auto-follow; prior redraw seeds the anchor.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            (should ghostel--last-anchor-position)
            (should-not ghostel--scroll-positions)

            ;; Simulate Emacs drift: `keep-point-visible' on a
            ;; minibuffer-triggered resize slides `window-start' a
            ;; couple rows below the anchor.  Point stays in the live
            ;; viewport (TUI cursor on a row above the bottom).
            (let ((drifted-ws (save-excursion
                                (goto-char ghostel--last-anchor-position)
                                (forward-line -2)
                                (line-beginning-position))))
              (should (< drifted-ws ghostel--last-anchor-position))
              (set-window-start (selected-window) drifted-ws t))
            ;; Window is NOT in `ghostel--scroll-positions' — it was
            ;; auto-following, not user-scrolled.
            (should-not ghostel--scroll-positions)

            ;; Resize path (same harness as the scrolled-view test).
            (cl-letf (((default-value 'window-adjust-process-window-size-function)
                       (lambda (&rest _) (cons 40 6)))
                      ((symbol-function 'set-process-window-size) #'ignore))
              (setq ghostel--process
                    (make-pipe-process :name "ghostel-test-fake"
                                       :buffer buf
                                       :noquery t
                                       :filter #'ignore
                                       :sentinel #'ignore))
              (unwind-protect
                  (ghostel--window-adjust-process-window-size
                   ghostel--process
                   (list (selected-window)))
                (delete-process ghostel--process)
                (setq ghostel--process nil)))

            ;; Window must be re-anchored to the live viewport, NOT
            ;; yanked to `point-min'.
            (should (= (ghostel--viewport-start)
                       (window-start (selected-window))))
            (should (> (window-start (selected-window)) 1))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resize-preserves-scrollback-jump ()
  "Resize redraw must NOT re-anchor a window whose point is in scrollback.
Regression test: consult-line / consult-imenu / plain `goto-char' jumps in
line mode opened a minibuffer that resized the body twice.  The second
resize fired with `ghostel--scroll-positions' empty (no scroll-tracking
redraw ran while the minibuffer was open) and the predicate's
resize-active branch classified the window as anchored, yanking
`window-point' back to the live cursor.

The fix is a `window-point' >= anchor guard on the resize branch:
it preserves the drifted-ws case (`window-point' still in the live
viewport) but rejects this case (`window-point' moved into scrollback)."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-scrollback-jump*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Steady-state: cursor at live viewport, window anchored.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            (should ghostel--last-anchor-position)
            (should-not ghostel--scroll-positions)

            ;; Simulate consult-line jumping point into scrollback.
            (let ((target (save-excursion
                            (goto-char (point-min))
                            (forward-line 5)
                            (line-beginning-position))))
              (should (< target ghostel--last-anchor-position))
              (set-window-point (selected-window) target)
              (set-window-start (selected-window) target t)
              (goto-char target)
              ;; No plain redraw runs while the minibuffer is open, so
              ;; `ghostel--scroll-positions' stays empty — exactly the
              ;; state the resize-active branch used to misclassify.
              (should-not ghostel--scroll-positions)

              ;; Resize fires when the minibuffer closes.
              (cl-letf (((default-value 'window-adjust-process-window-size-function)
                         (lambda (&rest _) (cons 40 6)))
                        ((symbol-function 'set-process-window-size) #'ignore))
                (setq ghostel--process
                      (make-pipe-process :name "ghostel-test-fake"
                                         :buffer buf
                                         :noquery t
                                         :filter #'ignore
                                         :sentinel #'ignore))
                (unwind-protect
                    (ghostel--window-adjust-process-window-size
                     ghostel--process
                     (list (selected-window)))
                  (delete-process ghostel--process)
                  (setq ghostel--process nil)))

              ;; Window-point must still be in scrollback, not yanked
              ;; back to the live viewport.
              (should (< (window-point (selected-window))
                         (ghostel--viewport-start))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-viewport-start-skips-trailing-newline ()
  "`ghostel--viewport-start' must not be off-by-one on a trailing \\n.
Partial redraws can leave the buffer ending with \\n (e.g. after
trimming excess rows).  Emacs then counts an empty phantom line
past `point-max'; a naive `forward-line (- (1- tr))' lands one line
too deep and the anchored window clips the bottom content row.
The fix must return the start of row 1, covering exactly TR content
rows in the viewport — with or without the trailing newline."
  (with-temp-buffer
    (let ((tr 5))
      (dotimes (i tr)
        (insert (format "row-%d" (1+ i)))
        (when (< i (1- tr)) (insert "\n")))
      (let* ((ghostel--term-rows tr)
             (vs-no-nl (ghostel--viewport-start)))
        (should (= 1 vs-no-nl))
        (insert "\n")
        (let ((vs-nl (ghostel--viewport-start)))
          (should (= 1 vs-nl))
          (should (= tr (count-lines vs-nl (save-excursion
                                             (goto-char (point-max))
                                             (skip-chars-backward "\n")
                                             (point))))))))))

(ert-deftest ghostel-test-anchor-window-no-clamp-without-pending-wrap ()
  "`ghostel--anchor-window' must leave `window-point' at PT outside pending-wrap.
Regression test for #146: PR #139 originally clamped unconditionally
whenever PT equalled `point-max', which pulled the block cursor onto
the last character of a normal shell prompt (the cursor is legitimately
at `point-max' right after typing).  The clamp must only fire for the
#138 scenario where the terminal is genuinely in pending-wrap state.

This pure-elisp test leaves `ghostel--term' nil; the helper must then
skip the clamp entirely regardless of where PT sits."
  (let ((buf (generate-new-buffer " *ghostel-test-anchor-no-clamp*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "row-1\nrow-2\n$ ls"))
          (set-window-buffer (selected-window) buf)
          (let ((win (selected-window))
                (pmax (with-current-buffer buf (point-max))))
            ;; pt at point-max, no term: window-point stays put (#146).
            (with-current-buffer buf
              (setq-local ghostel--term nil)
              (ghostel--anchor-window win (point-min) pmax))
            (should (= pmax (window-point win)))
            ;; pt inside the buffer: window-point is left alone.
            (with-current-buffer buf
              (ghostel--anchor-window win (point-min) (- pmax 3)))
            (should (= (- pmax 3) (window-point win))))
          ;; Empty buffer: no underflow when pt == point-min == point-max.
          (let ((empty-buf (generate-new-buffer " *ghostel-test-anchor-empty*")))
            (unwind-protect
                (progn
                  (set-window-buffer (selected-window) empty-buf)
                  (with-current-buffer empty-buf
                    (setq-local ghostel--term nil)
                    (ghostel--anchor-window (selected-window)
                                            (point-min) (point-max)))
                  (should (= (point-min)
                             (window-point (selected-window)))))
              (kill-buffer empty-buf))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-anchors-window-start-on-snap-request ()
  "Redraw anchors `window-start' to the viewport when snap is requested.
`ghostel--snap-to-input' sets `ghostel--snap-requested' on typing/paste/
yank/drop.  The next redraw must override a scrolled-up `window-start'
and pull it back to the viewport, then clear the flag."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-ws-snap*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (ghostel--snap-requested t)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (set-window-start (selected-window) (point-min) t)
            (ghostel--delayed-redraw buf)
            (let ((viewport-start (ghostel--viewport-start)))
              (should (= viewport-start (window-start (selected-window))))
              (should-not ghostel--snap-requested))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-scroll-preserved-across-blank-lines ()
  "Scroll preservation disambiguates blank / repeated lines.
Ghostel's content-based scroll restoration uses a multi-line key (not a
single line's text) so that a window scrolled to a blank line isn't
yanked to the first blank line in the buffer when a redraw rebuilds
scrollback positions."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-blank-line*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            ;; Lots of blank-line separators mixed with content so the
            ;; first match of "" is near the top.
            (dotimes (i 30)
              (ghostel--write-input term (format "line-%02d\r\n\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            ;; Seed auto-follow.
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; Scroll so window-start is on a blank line in the middle
            ;; (not the first blank line in the buffer).
            (let ((target (save-excursion
                            (goto-char (point-max))
                            (forward-line -26)
                            (line-beginning-position))))
              (set-window-start (selected-window) target t)
              (let ((pre-key (ghostel--line-key target)))
                ;; Sanity: the line we're on is blank.
                (should (equal "" (car pre-key)))
                ;; Non-anchored redraw to capture scroll-positions.
                (setq ghostel--force-next-redraw t)
                (ghostel--delayed-redraw buf)
                ;; Simulate Emacs mangling window-start to 1.
                (set-window-start (selected-window) (point-min) t)
                ;; Next redraw restores via multi-line key match.
                (setq ghostel--force-next-redraw t)
                (ghostel--delayed-redraw buf)
                ;; Window-start must be back on the user's blank-line
                ;; row, NOT at the first blank line in the buffer.
                (should (equal pre-key
                               (ghostel--line-key
                                (window-start (selected-window)))))
                (should (> (window-start (selected-window)) 1))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-anchored-and-scrolled-multi-window ()
  "Anchored and scrolled windows showing the same buffer coexist.
Two windows show the ghostel buffer: one follows the viewport, the
other is pinned to scrollback.  A redraw must anchor the first and
preserve the second."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-multi*"))
        (orig-config (current-window-configuration)))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (goto-char (point-max))
            (delete-other-windows)
            (set-window-buffer (selected-window) buf)
            (let* ((w1 (selected-window))
                   (w2 (split-window-vertically))
                   (vp (ghostel--viewport-start)))
              (set-window-buffer w2 buf)
              ;; w1 follows viewport; w2 will be scrolled to scrollback
              ;; top *after* the seed redraw (the first-ever redraw
              ;; treats every window as anchored).
              (set-window-start w1 vp t)
              (set-window-point w1 (point-max))
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              (set-window-start w2 (point-min) t)
              (set-window-point w2 (point-min))
              (let* ((w2-ws-before (window-start w2)))
                ;; A redraw that appends more output should anchor w1
                ;; to the new viewport and leave w2 where it is.
                (ghostel--write-input term "extra-line\r\n")
                (setq ghostel--force-next-redraw t)
                (ghostel--delayed-redraw buf)
                ;; w1 anchored to new viewport.
                (let ((new-vp (ghostel--viewport-start)))
                  (should (= new-vp (window-start w1))))
                ;; w2 still in scrollback (same line content).
                (should (equal (ghostel--line-key w2-ws-before)
                               (ghostel--line-key (window-start w2))))))))
      (set-window-configuration orig-config)
      (kill-buffer buf))))

(ert-deftest ghostel-test-copy-mode-exit-resets-scroll-state ()
  "Exiting copy mode drops stale scroll-positions.
Delayed-redraw is short-circuited during copy mode; on exit, whatever
`ghostel--scroll-positions' held is stale.  The exit handler drops it
and requests a snap so the next redraw lands at the live viewport."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-copy-exit*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--input-mode 'copy)
          (setq ghostel--scroll-positions
                (list (cons (selected-window)
                            (list '("stale") '("stale") 0))))
          (setq ghostel--snap-requested nil)
          (setq ghostel--force-next-redraw nil)
          (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                    ((symbol-function 'message) #'ignore))
            (ghostel-readonly-exit))
          (should-not ghostel--scroll-positions)
          (should ghostel--snap-requested)
          ;; `force-next-redraw' must also be set so the snap fires
          ;; even when DEC 2026 synchronized output is active.
          (should ghostel--force-next-redraw))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-syncs-window-point-to-cursor ()
  "Anchored redraw syncs `window-point' to the terminal cursor.
When an OSC 51;E callback moved selection elsewhere and left the
ghostel window's `window-point' stale, the next redraw (which is
anchored because the window is at the viewport) must update it."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-wp-sync*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            ;; Simulate OSC 51;E leaving window-point stale.
            (set-window-point (selected-window) (point-min))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Anchored window's window-point follows the cursor
            ;; (buffer-point after native redraw), not the stale value.
            (should (= (window-point (selected-window)) (point)))
            (should (> (window-point (selected-window)) 1))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-respects-user-rescroll ()
  "A second scroll + redraw respects the NEW scroll position.
Reproduces the bug where `ghostel--scroll-positions' goes stale across
redraws: user scrolls to A, triggers a redraw (captures A), scrolls
to B, triggers another redraw — the pre-redraw restore must detect
that the user moved ws to a new valid position and refresh the saved
key to B, rather than yanking ws back to A."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-rescroll*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 50)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; Scroll #1: to an early (but non-point-min) line.
            (let* ((target-a (save-excursion
                               (goto-char (point-min))
                               (forward-line 5)
                               (line-beginning-position)))
                   (key-a (ghostel--line-key target-a)))
              (set-window-start (selected-window) target-a t)
              (set-window-point (selected-window) target-a)
              ;; Redraw #1 (simulates M-x triggering delayed-redraw).
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              (should (equal key-a
                             (ghostel--line-key
                              (window-start (selected-window)))))

              ;; Scroll #2: to a DIFFERENT non-point-min line.  The
              ;; pre-redraw restore must leave ws alone (only
              ;; point-min looks mangled); the post-redraw capture
              ;; rebuilds `ghostel--scroll-positions' from the
              ;; window's live ws/wp, so the saved key picks up B.
              (let* ((target-b (save-excursion
                                 (goto-char (point-min))
                                 (forward-line 15)
                                 (line-beginning-position)))
                     (key-b (ghostel--line-key target-b)))
                (should-not (equal key-a key-b))
                (set-window-start (selected-window) target-b t)
                (set-window-point (selected-window) target-b)
                ;; Redraw #2.
                (setq ghostel--force-next-redraw t)
                (ghostel--delayed-redraw buf)
                ;; Must land on target-b (user's current intent),
                ;; NOT target-a.
                (should (equal key-b
                               (ghostel--line-key
                                (window-start (selected-window)))))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-restores-from-mangled-point-min ()
  "When Emacs clamps `window-start' to `point-min', redraw restores.
This is the signature behavior used to distinguish Emacs-side ws
mangling (from window resize etc.) from a legitimate user scroll.
If ws is clamped to point-min but the saved key points elsewhere,
the pre-redraw restore searches for the saved key and moves ws back."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-mangled*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 50)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            (let* ((target (save-excursion
                             (goto-char (point-min))
                             (forward-line 15)
                             (line-beginning-position)))
                   (key (ghostel--line-key target)))
              (set-window-start (selected-window) target t)
              (set-window-point (selected-window) target)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)

              ;; Simulate Emacs clamping ws to point-min (mangling).
              (set-window-start (selected-window) (point-min) t)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              ;; Must restore ws to the saved key's line content.
              (should (equal key
                             (ghostel--line-key
                              (window-start (selected-window))))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-restores-wp-mangled-independently ()
  "`window-point' mangled to point-min is restored even when ws isn't.
The wp restore path is decoupled from ws restore.  Emacs can in
principle reset wp without touching ws (e.g. when the selected window
changes and the previous buffer's point gets reset); verify the
restore still fires."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-wp-mangled*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 50)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            (let* ((ws-target (save-excursion
                                (goto-char (point-min))
                                (forward-line 15)
                                (line-beginning-position)))
                   (wp-target (save-excursion
                                (goto-char (point-min))
                                (forward-line 18)
                                (line-beginning-position)))
                   (wp-key (ghostel--line-key wp-target)))
              (set-window-start (selected-window) ws-target t)
              (set-window-point (selected-window) wp-target)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)

              ;; Mangle only wp — ws stays at the same content.
              (set-window-point (selected-window) (point-min))
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              (should (equal wp-key
                             (ghostel--line-key
                              (window-point (selected-window))))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-false-negative-mangle-refreshes-saved-key ()
  "Non-point-min mangling is indistinguishable from user scroll.
Document and lock in the known limitation of the no-post-command-hook
heuristic: if Emacs moves `window-start' to a non-point-min position
that doesn't match the saved key (e.g. programmatic `recenter',
`follow-mode'), the pre-redraw pass treats it as a user scroll and
refreshes the saved key rather than restoring.  The original scroll
intent is lost."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-false-neg*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 50)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            (let* ((saved (save-excursion
                            (goto-char (point-min))
                            (forward-line 10)
                            (line-beginning-position)))
                   (hijacked (save-excursion
                               (goto-char (point-min))
                               (forward-line 20)
                               (line-beginning-position)))
                   (hijacked-key (ghostel--line-key hijacked)))
              (set-window-start (selected-window) saved t)
              (set-window-point (selected-window) saved)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)

              ;; Move ws to a different VALID position (not point-min).
              ;; The heuristic can't tell this from a user scroll.
              (set-window-start (selected-window) hijacked t)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              ;; Known limitation: ws is accepted as the new intent.
              (should (equal hijacked-key
                             (ghostel--line-key
                              (window-start (selected-window)))))
              ;; scroll-positions has the new key, not the original.
              (let* ((entry (assq (selected-window)
                                  ghostel--scroll-positions))
                     (saved-ws-key (nth 0 (cdr entry))))
                (should (equal hijacked-key saved-ws-key))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-first-call-anchors-fresh-buffer ()
  "First-ever redraw anchors the window to the viewport.
`ghostel--last-anchor-position' is nil on the first delayed-redraw; my
code treats every window as anchored in that case so the fresh buffer
pins to the viewport.  This guards the bootstrap path."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-first-redraw*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Fresh state.
            (setq ghostel--last-anchor-position nil
                  ghostel--scroll-positions nil
                  ghostel--snap-requested nil)
            (goto-char (point-max))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Anchor fired: window-start pinned to viewport.
            (let ((vs (ghostel--viewport-start)))
              (should (= vs (window-start (selected-window))))
              (should (= vs ghostel--last-anchor-position)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))



;;; Preedit overlays during redraw

(ert-deftest ghostel-test-delayed-redraw-preserves-preedit-anchor ()
  "Active GUI preedit text keeps its point anchor across redraws.
GTK/PGTK input-method candidate windows are anchored to the preedit
overlay at point.  During streaming TUI output, native redraws move
point to the terminal cursor; while preedit text is visible, the
composing window must instead keep the overlay and `window-point' at
the same viewport row and column.
FIXME: `ghostel--term' is bound to a placeholder rather than a real
native handle, and `ghostel--redraw' is stubbed to simulate the
destructive renderer behavior.  A clean rewrite would need a real
terminal fixture with a preedit overlay that survives the renderer's
buffer rewrite at the right viewport row — non-trivial fixture work."
  (let ((buf (generate-new-buffer " *ghostel-test-preedit-anchor*"))
        (orig-buf (window-buffer (selected-window)))
        (old-bound (boundp 'x-preedit-overlay))
        (old-value (and (boundp 'x-preedit-overlay) x-preedit-overlay))
        overlay)
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (setq-local ghostel--term 'fake-term
                        ghostel--term-rows 5
                        ghostel--force-next-redraw nil
                        ghostel-enable-url-detection nil
                        ghostel-enable-file-detection nil)
            (insert "old-0\nold-1\nold-2\nold-3\nold-4")
            (goto-char (point-max))
            (setq overlay (make-overlay (point) (point) buf))
            (overlay-put overlay 'before-string "ni")
            (overlay-put overlay 'window (selected-window))
            (setq x-preedit-overlay overlay)
            (set-window-start (selected-window) (point-min) t)
            (set-window-point (selected-window) (point)))
          (cl-letf (((symbol-function 'ghostel--mode-enabled)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--redraw)
                     (lambda (&rest _)
                       ;; Simulate a destructive native redraw that leaves
                       ;; point at the terminal cursor on a different row.
                       (erase-buffer)
                       (insert "new-0\nnew-1\nnew-2\nnew-3\nnew-4")
                       (goto-char (point-min))
                       (forward-line 1)))
                    ((symbol-function 'ghostel--cursor-pending-wrap-p)
                     (lambda (&rest _)
                       (error "Preedit anchor should bypass clamp checks")))
                    ((symbol-function 'ghostel--cursor-on-empty-row-p)
                     (lambda (&rest _)
                       (error "Preedit anchor should bypass clamp checks"))))
            (ghostel--delayed-redraw buf))
          (with-current-buffer buf
            (let ((expected (save-excursion
                              (goto-char (point-min))
                              (forward-line 4)
                              (move-to-column 5)
                              (point))))
              (should (= expected (overlay-start overlay)))
              (should (= expected (window-point (selected-window))))
              (should (= expected (point))))))
      (if old-bound
          (setq x-preedit-overlay old-value)
        (makunbound 'x-preedit-overlay))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (when (and overlay (overlayp overlay))
        (delete-overlay overlay))
      (kill-buffer buf))))

(ert-deftest ghostel-test-preedit-window-fallback ()
  "Verify the `selected-window' fallback in `ghostel--preedit-window'.
This covers the pgtk-preedit-overlay shape, which has no `window'
overlay property."
  (let ((buf (generate-new-buffer " *ghostel-test-preedit-window*"))
        (orig-buf (window-buffer (selected-window)))
        overlay)
    (unwind-protect
        (with-current-buffer buf
          (setq overlay (make-overlay (point-min) (point-min) buf))
          ;; No 'window property — selected-window must show the buffer.
          (set-window-buffer (selected-window) buf)
          (should (eq (ghostel--preedit-window overlay) (selected-window)))
          ;; Explicit 'window wins over the fallback.
          (overlay-put overlay 'window (selected-window))
          (should (eq (ghostel--preedit-window overlay) (selected-window)))
          ;; Selected window showing some other buffer and no 'window
          ;; property: nothing usable, return nil.
          (overlay-put overlay 'window nil)
          (when (buffer-live-p orig-buf)
            (set-window-buffer (selected-window) orig-buf))
          (should (null (ghostel--preedit-window overlay))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (when (and overlay (overlayp overlay))
        (delete-overlay overlay))
      (kill-buffer buf))))




;;; Crash and internal-invariant regressions
;;
;; Tests for bugs that manifested as panics or internal state corruption
;; rather than wrong visible output.  Grouped here so they don't dilute
;; the feature-oriented sections above and have an obvious home for
;; future additions.

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
              (ghostel--write-input term line))
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


(provide 'ghostel-render-test)
;;; ghostel-render-test.el ends here
