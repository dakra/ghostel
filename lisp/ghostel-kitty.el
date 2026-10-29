;;; ghostel-kitty.el --- Kitty graphics support for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Rendering and state helpers for ghostel's Kitty graphics protocol support.

;;; Code:

(require 'cl-lib)

(declare-function ghostel--viewport-start "ghostel")


;;; Customization

(defcustom ghostel-kitty-graphics-storage-limit (* 320 1024 1024)  ; 320 MiB
  "Kitty graphics image storage cap, in bytes, per terminal.

Caps how much memory libghostty's kitty-graphics image store can
hold per ghostel buffer.  Each transmitted image (PNG bytes or raw
pixels) counts; libghostty evicts the oldest image when a new
transmission would exceed this limit.

Set to 0 to disable kitty graphics entirely — image transmissions
are then ignored and no storage is allocated.  Useful on low-memory
systems or for terminals you know won't display images."
  :type 'integer
  :group 'ghostel)

(defcustom ghostel-kitty-graphics-mediums '(file temp-file shared-mem)
  "Image-loading mediums to enable for the Kitty graphics protocol.

The direct medium (base64 inline, used by timg and yazi) is always
enabled.  The others let the program name data on the local machine:
- file: a local file, read by the terminal (broot PNG previews)
- temp-file: a temp file, read and unlinked (broot, ranger)
- shared-mem: a POSIX shared-memory region

The default matches Ghostty and kitty.  A program running remotely
\(SSH, tmux passthrough) can use these mediums to make ghostel display
a local file; set this to nil to accept inline data only."
  :type '(set (const :tag "Local file medium" file)
              (const :tag "Temp-file medium" temp-file)
              (const :tag "Shared-memory medium" shared-mem))
  :group 'ghostel)



;;; Internal state

(defvar-local ghostel--kitty-active nil
  "Non-nil when kitty image overlays are present in the buffer.")

(defvar-local ghostel--kitty-last-error nil
  "Last error raised inside a kitty display callback, or nil.
Captured here instead of being lost to a fleeting message so it can be
inspected when image rendering misbehaves.")



;;; Kitty graphics protocol

(defun ghostel--kitty-mediums-bits ()
  "Encode `ghostel-kitty-graphics-mediums' as a bitfield for the module."
  (let ((bits 0)
        (mediums ghostel-kitty-graphics-mediums))
    (when (memq 'file mediums) (setq bits (logior bits 1)))
    (when (memq 'temp-file mediums) (setq bits (logior bits 2)))
    (when (memq 'shared-mem mediums) (setq bits (logior bits 4)))
    bits))

(defun ghostel--kitty-apply-row-slice (row cw ch img
                                           vp-col-clamped visible-cols
                                           slice-x slice-w)
  "Apply one row of the sliced image at point.
ROW is the slice index (0-based) into the image's grid of cells.
CW / CH are the cell pixel dimensions.  IMG is the Emacs image object.
VP-COL-CLAMPED is the placement's column origin clamped to >= 0;
VISIBLE-COLS is how many columns of that row are on-screen; SLICE-X is
the slice's x-origin in image pixels (non-zero only when the placement
is partially scrolled off the left); SLICE-W is the fallback slice
width when the buffer line is shorter than the placement.

Decides between the text-property and overlay paths based on whether
the buffer line is long enough to hold the placement's column range."
  (let* ((line-pos (point))
         (line-end-pos (line-end-position))
         (start (min (+ line-pos vp-col-clamped) line-end-pos))
         (end (min (+ line-pos vp-col-clamped visible-cols) line-end-pos))
         ;; The slice's pixel width must match the cell-range width Emacs
         ;; gives us; otherwise the display engine renders the slice at
         ;; its declared size and either overlaps subsequent cells or
         ;; truncates.  This bites when `vp-col + g-cols' exceeds the
         ;; terminal width (line-end-pos clamps `end` shorter than the
         ;; slice the placement asked for) and shows up as a ghosted
         ;; copy of the image bleeding to the right.
         (range-cols (- end start))
         (clamped-slice-w (* range-cols cw))
         (slice (list 'slice slice-x (* row ch)
                      (if (> range-cols 0) clamped-slice-w slice-w)
                      ch))
         (spec (list slice img)))
    (cond
     ;; Range is empty (line shorter than vp-col) — use an overlay so we
     ;; don't eat the newline.
     ((<= end start)
      (let ((ov (make-overlay start start)))
        (overlay-put ov 'before-string (propertize " " 'display spec))
        (overlay-put ov 'ghostel-kitty t)))
     ;; Line has enough text — use text property.
     (t
      (add-text-properties start end
                           (list 'display spec 'ghostel-kitty t))))
    (when (< line-end-pos (point-max))
      (add-text-properties line-end-pos (1+ line-end-pos)
                           (list 'line-height ch 'ghostel-kitty t)))
    (setq ghostel--kitty-active t)))

(defun ghostel--kitty-image-type (data)
  "Return the image type of the module's image DATA.
The module sends `png' for images with transparent pixels, which PPM
cannot carry, and `pbm' for the rest."
  (if (string-prefix-p "\211PNG" data) 'png 'pbm))

(defun ghostel--kitty-display-image (data abs-row vp-col grid-cols grid-rows pixel-w pixel-h)
  "Display a kitty graphics image placement in the buffer.
Called from the native module during redraw for each visible placement.
DATA is a unibyte PPM, or PNG when it has transparency, string of the
placement's source rect.
ABS-ROW is the buffer row (0-indexed from `point-min') of the image's
top: libghostty's screen row, which the renderer keeps equal to the
buffer line.  May be negative when the top is above the first line.
VP-COL is the column (may be negative — image partially off the left).
GRID-COLS and GRID-ROWS are the cell dimensions.
PIXEL-W and PIXEL-H are the rendered pixel dimensions.

The image is sized to fill its grid cells and then sliced per row, with
each slice applied on its own buffer line.  Slicing — rather than a
single multi-line `display' property — is required for the image to
actually occupy each cell row (otherwise Emacs draws the image once at
the first character of the range and the remaining rows show the
underlying text or stay blank).  Mirrors the virtual-placeholder path's
`:ascent \\='center' and `line-height' clamping so slices tile flush
across rows.

Falls back to PIXEL-W/PIXEL-H when GRID-COLS/GRID-ROWS arrive as 0 —
libghostty hasn't computed the cell layout yet on the first redraw
after a placement (a subsequent layout change would fix it, but the
user shouldn't have to trigger one)."
  (when (display-graphic-p)
    (condition-case err
        (let* ((cw (default-font-width))
               (ch (default-font-height))
               (g-cols (if (> grid-cols 0) grid-cols
                         (max 1 (/ (+ pixel-w cw -1) cw))))
               (g-rows (if (> grid-rows 0) grid-rows
                         (max 1 (/ (+ pixel-h ch -1) ch))))
               (img (create-image data (ghostel--kitty-image-type data) t
                                  :width (* g-cols cw)
                                  :height (* g-rows ch)
                                  :scale 1
                                  :ascent 'center))
               (skip (max 0 abs-row))
               (start-row (max 0 (- abs-row)))
               ;; Clamp negative vp-col (image partially scrolled off
               ;; the left edge): start the buffer range at column 0
               ;; and skip the off-screen pixel columns inside the
               ;; slice.
               (vp-col-clamped (max 0 vp-col))
               (start-col (max 0 (- vp-col)))
               (slice-x (* start-col cw))
               (visible-cols (max 0 (- g-cols start-col)))
               (slice-w (* visible-cols cw)))
          (when (> visible-cols 0)
            (save-excursion
              (goto-char (point-min))
              (when (zerop (forward-line skip))
                ;; Skip rows already in materialized scrollback — they
                ;; got their overlays in an earlier emit and
                ;; `kitty-clear' preserves scrollback overlays.
                ;; Re-applying here would stack a second overlay on
                ;; every scrolled-in row.
                (let ((row start-row)
                      (more t)
                      (vp-start (or (ghostel--viewport-start) (point-min))))
                  (while (and more (< row g-rows))
                    (when (>= (point) vp-start)
                      (ghostel--kitty-apply-row-slice
                       row cw ch img
                       vp-col-clamped visible-cols slice-x slice-w))
                    (setq row (1+ row))
                    (unless (zerop (forward-line 1))
                      (setq more nil))))))))
      (error
       (setq ghostel--kitty-last-error err)
       (message "ghostel: kitty image error: %S" err)))))

(defun ghostel--kitty-display-virtual (data row-up nth img-row img-col
                                            width grid-cols grid-rows)
  "Display one placeholder run of a virtual kitty placement.
DATA is a unibyte PPM or PNG string.  ROW-UP is the run's row counted up from
the last screen row (0 = last row); its first cell is the NTH (0-based)
U+10EEEE placeholder on that row.  IMG-ROW and IMG-COL are the image
cell it starts at, WIDTH its length in cells, GRID-COLS and GRID-ROWS
the whole image.  Cells are located by counting placeholders, since
their combining diacritics make buffer width differ from cell width."
  (when (display-graphic-p)
    (condition-case err
        (let* ((cw (default-font-width))
               (ch (default-font-height))
               (img (create-image data (ghostel--kitty-image-type data) t
                                  :width (* grid-cols cw)
                                  :height (* grid-rows ch)
                                  :scale 1
                                  :ascent 'center)))
          (save-excursion
            ;; The last screen row is the line before the final newline.
            (goto-char (point-max))
            (let ((ph (string #x10EEEE)))
              (when (and (zerop (forward-line (- (1+ row-up))))
                         (search-forward ph (line-end-position) t (1+ nth)))
                (let ((start (1- (point)))
                      (eol (line-end-position)))
                  (when (or (= width 1)
                            (search-forward ph eol t (1- width)))
                    (while (and (< (point) eol)
                                (eq (get-char-code-property
                                     (char-after) 'general-category)
                                    'Mn))
                      (forward-char))
                    (add-text-properties
                     start (point)
                     (list 'display (list (list 'slice (* img-col cw) (* img-row ch)
                                                (* width cw) ch)
                                          img)
                           'ghostel-kitty t))
                    ;; Clamp the line to `ch' so the slice tiles flush; the
                    ;; placeholder fallback font would otherwise grow the line.
                    (add-text-properties eol (1+ eol)
                                         (list 'line-height ch
                                               'ghostel-kitty t))
                    (setq ghostel--kitty-active t)))))))
      (error
       (setq ghostel--kitty-last-error err)
       (message "ghostel: kitty virtual image error: %S" err)))))

(defun ghostel--kitty-clear ()
  "Remove kitty image overlays and per-line clamps from the viewport.
Both display paths tag the regions/overlays with the `ghostel-kitty'
property so this strips only kitty-applied `display' and `line-height',
leaving other consumers of `display' (e.g. wide-char compensation)
alone.

Only the viewport region is cleared — overlays on rows that have
already been promoted to materialized scrollback are preserved so
images stay visible after they scroll past the live viewport.
libghostty stops reporting placements once they're fully out of the
viewport (`viewport_visible' goes false), so wiping scrollback would
leave nothing to re-emit and the image would vanish from history."
  (when ghostel--kitty-active
    (let* ((inhibit-read-only t)
           (vp-start (or (ghostel--viewport-start) (point-min)))
           (end (point-max))
           (pos vp-start))
      (dolist (ov (overlays-in pos end))
        (when (and (overlay-get ov 'ghostel-kitty)
                   (>= (overlay-start ov) pos))
          (delete-overlay ov)))
      (while (< pos end)
        (let ((next (next-single-property-change pos 'ghostel-kitty nil end)))
          (when (get-text-property pos 'ghostel-kitty)
            (remove-text-properties
             pos next '(display nil line-height nil ghostel-kitty nil)))
          (setq pos next)))
      ;; Drop any image fragment left over by scrollback eviction (see
      ;; `ghostel--kitty-strip-orphan-top').
      (ghostel--kitty-strip-orphan-top)
      ;; Sticky-flag hygiene: once we've stripped the viewport, anything
      ;; remaining must be in scrollback.  If there's nothing left at all,
      ;; clear the flag so future redraws skip the buffer scan entirely.
      (unless (ghostel--kitty-any-remaining-p (point-min) vp-start)
        (setq ghostel--kitty-active nil)))))

(defun ghostel--kitty-slice-y-at (pos)
  "Return the slice y-offset of a kitty image at POS, or nil if absent.
Looks at both the buffer text-property `display' and at any
`ghostel-kitty'-tagged overlay's `before-string' display property."
  (let ((display
         (or (get-text-property pos 'display)
             (cl-loop for ov in (overlays-at pos)
                      when (overlay-get ov 'ghostel-kitty)
                      thereis
                      (let ((bs (overlay-get ov 'before-string)))
                        (and bs (get-text-property 0 'display bs)))))))
    ;; Display spec is `((slice X Y W H) IMAGE)'.
    (when (and (consp display)
               (consp (car display))
               (eq (car (car display)) 'slice)
               (numberp (nth 2 (car display))))
      (nth 2 (car display)))))

(defun ghostel--kitty-strip-orphan-top ()
  "Strip kitty image debris left at point-min by scrollback eviction.

Two distinct artifacts both surface here:

1. Collapsed overlays.  `delete-region' clamps overlays inside the
   deleted range to its start instead of deleting them, so an evicted
   row's zero-width kitty overlays all snap onto the new point-min and
   stack there (dozens for a tall image).  Detected by counting
   zero-width kitty overlays per start-position — more than one at the
   same position is never legitimate (the placement loop emits at most
   one overlay per row).

2. Orphan text-property slices.  When eviction straddles an image, the
   surviving rows keep their `display' slices into a now-incomplete
   image.  Detected by a slice y-offset > 0 at point-min (y=0 would
   mean the row IS the image's top, so it's an intact image's first
   row, not an orphan)."
  (let ((inhibit-read-only t))
    ;; (1) Eviction-collapsed overlay stacks.
    (let ((counts (make-hash-table)))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (overlay-get ov 'ghostel-kitty)
                   (= (overlay-start ov) (overlay-end ov)))
          (let ((pos (overlay-start ov)))
            (puthash pos (1+ (gethash pos counts 0)) counts))))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (and (overlay-get ov 'ghostel-kitty)
                   (= (overlay-start ov) (overlay-end ov))
                   (> (gethash (overlay-start ov) counts 0) 1))
          (delete-overlay ov))))
    ;; (2) Orphan text-property slices at point-min.
    (let ((slice-y (ghostel--kitty-slice-y-at (point-min))))
      (when (and slice-y (> slice-y 0))
        (let ((start (point-min))
              (end (save-excursion
                     (goto-char (point-min))
                     (while (and (< (point) (point-max))
                                 (or (get-text-property (point) 'ghostel-kitty)
                                     (cl-some
                                      (lambda (ov) (overlay-get ov 'ghostel-kitty))
                                      (overlays-at (point)))))
                       (forward-line 1))
                     (point))))
          (when (> end start)
            (remove-text-properties
             start end '(display nil line-height nil ghostel-kitty nil))
            (dolist (ov (overlays-in start end))
              (when (overlay-get ov 'ghostel-kitty)
                (delete-overlay ov)))))))))

(defun ghostel--kitty-any-remaining-p (start end)
  "Non-nil if any kitty-tagged overlay or text property exists in [START, END)."
  (catch 'found
    (dolist (ov (overlays-in start end))
      (when (overlay-get ov 'ghostel-kitty)
        (throw 'found t)))
    (let ((pos start))
      (while (< pos end)
        (when (get-text-property pos 'ghostel-kitty)
          (throw 'found t))
        (setq pos (next-single-property-change pos 'ghostel-kitty nil end))))
    nil))

(provide 'ghostel-kitty)
;;; ghostel-kitty.el ends here
