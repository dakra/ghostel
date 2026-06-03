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

(defcustom ghostel-kitty-graphics-mediums nil
  "Image-loading mediums to enable for the Kitty graphics protocol.

The kitty protocol supports four ways for a program to ship image
data to the terminal:
- direct: base64-encoded inline (always enabled, what timg / yazi use)
- file: program names a local file, terminal reads it
- temp-file: program names a temp file, terminal reads and unlinks it
- shared-mem: program names a POSIX shared-memory region

The non-direct mediums let a *remote* program (over SSH, tmux
passthrough, etc.) instruct ghostel to read arbitrary paths or shared
memory regions on the local machine — a privilege-escalation surface.
The default is nil (none enabled), keeping ghostel safe in remote
sessions while still supporting timg, yazi, and other tools that ship
data inline.  Enable individual mediums by adding `file', `temp-file',
or `shared-mem' to the list, e.g. `(file)' for trusted local-only use."
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

(define-error 'ghostel-kitty-unsupported-source-rect
              "Kitty graphics atlas-style source rect not supported"
              'error)

(defun ghostel--kitty-check-source-rect (src-x src-y src-w src-h pixel-w pixel-h)
  "Signal `ghostel-kitty-unsupported-source-rect' for non-default crops.
SRC-X / SRC-Y / SRC-W / SRC-H are the requested source-rect crop in image
pixels; PIXEL-W / PIXEL-H are the rendered pixel dimensions.  All zeros
means the whole image (the common case from timg/yazi).

Atlas-style placements (sub-region of the source image) aren't supported
because Emacs's image system can't crop pre-scale; refuse explicitly so
mis-rendering is visible as an error instead of silent."
  (when (or (> src-x 0) (> src-y 0)
            (and (> src-w 0) (/= src-w pixel-w))
            (and (> src-h 0) (/= src-h pixel-h)))
    (signal 'ghostel-kitty-unsupported-source-rect
            (list src-x src-y src-w src-h pixel-w pixel-h))))

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

(defun ghostel--kitty-display-image (data is-png abs-row vp-col grid-cols grid-rows pixel-w pixel-h
                                          src-x src-y src-w src-h)
  "Display a kitty graphics image placement in the buffer.
Called from the native module during redraw for each visible placement.
DATA is a unibyte string (PNG or PPM).
IS-PNG is non-nil for PNG, nil for PPM.
ABS-ROW is the absolute buffer row (0-indexed from `point-min'),
already accounting for materialized scrollback (the C side adds
`scrollback_in_buffer' to libghostty's viewport-relative row before
passing it here).  Without that pre-shift, an image at viewport row 0
would render at the top of the scrollback, jumping into the past as
soon as anything scrolled.  May be negative when the image's top is
above the buffer's first line (rare — only when libghostty's scrollback
got trimmed below the placement's anchor).
VP-COL is the column (may be negative — image partially off the left).
GRID-COLS and GRID-ROWS are the cell dimensions.
PIXEL-W and PIXEL-H are the rendered pixel dimensions.
SRC-X / SRC-Y / SRC-W / SRC-H are the source-rect crop in image pixels;
all zero means the whole image (the common case from timg/yazi).

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
        (progn
          (ghostel--kitty-check-source-rect src-x src-y src-w src-h pixel-w pixel-h)
          (let* ((cw (frame-char-width))
                 (ch (frame-char-height))
                 (g-cols (if (> grid-cols 0) grid-cols
                           (max 1 (/ (+ pixel-w cw -1) cw))))
                 (g-rows (if (> grid-rows 0) grid-rows
                           (max 1 (/ (+ pixel-h ch -1) ch))))
                 (img (create-image data (if is-png 'png 'pbm) t
                                    :width (* g-cols cw)
                                    :height (* g-rows ch)
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
                        (setq more nil)))))))))
      (error
       (setq ghostel--kitty-last-error err)
       (message "ghostel: kitty image error: %S" err)))))

(defun ghostel--kitty-display-virtual (data is-png)
  "Display a virtual kitty graphics placement (unicode placeholders).
Searches the buffer for U+10EEEE placeholder characters and overlays
per-row image slices on the placeholder regions of each line.
DATA is a unibyte string (PNG or PPM).  IS-PNG is non-nil for PNG."
  (when (display-graphic-p)
    (condition-case err
        (let ((placeholder (string #x10EEEE))
              (cw (frame-char-width))
              (ch (frame-char-height))
              grid-cols grid-rows img)
          (save-excursion
            ;; First pass: measure the grid by walking the buffer line by
            ;; line and counting placeholders.  Tracks the *maximum* count
            ;; across rows so a short first row doesn't undersize the
            ;; image.  Avoids `line-number-at-pos' in the search loop —
            ;; that's O(buffer size) per call and was the dominant cost
            ;; for large yazi previews.
            (goto-char (point-min))
            (let ((max-line-cols 0)
                  (total-rows 0))
              (while (not (eobp))
                (let ((eol (line-end-position))
                      (this-row 0))
                  (save-excursion
                    (while (search-forward placeholder eol t)
                      (setq this-row (1+ this-row))))
                  (when (> this-row 0)
                    (setq total-rows (1+ total-rows))
                    (when (> this-row max-line-cols)
                      (setq max-line-cols this-row))))
                (forward-line 1))
              (setq grid-cols (max 1 max-line-cols))
              (setq grid-rows (max 1 total-rows)))
            ;; Create the image sized to the full grid.  `:ascent center'
            ;; aligns each slice around the line's vertical center so it
            ;; tiles flush with adjacent slices regardless of the line's
            ;; baseline (the default `:ascent 50' splits the slice across
            ;; the baseline, leaving visible offsets between rows).
            (setq img (create-image data (if is-png 'png 'pbm) t
                                    :width (* grid-cols cw)
                                    :height (* grid-rows ch)
                                    :ascent 'center))
            ;; Second pass: apply per-row slices on placeholder regions.
            ;; Walks line by line — `line-end-position' is O(1) with no
            ;; full-buffer scan per placeholder.
            (goto-char (point-min))
            (let ((row 0))
              (while (not (eobp))
                (let* ((eol (line-end-position))
                       (line-start (save-excursion
                                     (search-forward placeholder eol t))))
                  (when line-start
                    (let ((line-end eol))
                      (setq line-start (1- line-start))
                      (when (> line-end line-start)
                        (add-text-properties
                         line-start line-end
                         (list 'display (list (list 'slice 0 (* row ch)
                                                    (* grid-cols cw) ch)
                                              img)
                               'ghostel-kitty t))
                        ;; Clamp the placeholder line to `ch' so the slice
                        ;; tiles flush and the file-list column on the same
                        ;; line doesn't grow taller than non-image lines.
                        ;; The U+10EEEE fallback font and any Nerd Font
                        ;; icons would otherwise pull line height above
                        ;; `frame-char-height', leaving gaps below the
                        ;; slice and above the next line's content.
                        (when (< line-end (point-max))
                          (add-text-properties line-end (1+ line-end)
                                               (list 'line-height ch
                                                     'ghostel-kitty t)))
                        (setq ghostel--kitty-active t)))
                    (setq row (1+ row))))
                (forward-line 1)))))
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
