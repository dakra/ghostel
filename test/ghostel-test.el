;;; ghostel-test.el --- Tests for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run
;;
;; Pure Elisp tests only (no native module):
;;   emacs --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run-elisp

;;; Code:

(require 'ert)
(require 'ghostel)

(declare-function ghostel--cleanup-temp-paths "ghostel")

;;; Helper: read first N rows from render state via debug-state

(defun ghostel-test--row0 (term)
  "Return the first row text from the render state of TERM."
  (let ((state (ghostel--debug-state term)))
    (when (string-match "row0=\"\\([^\"]*\\)\"" state)
      ;; Trim trailing spaces
      (string-trim-right (match-string 1 state)))))

(defun ghostel-test--cursor (term)
  "Return (COL . ROW) cursor position from debug-feed."
  (let ((info (ghostel--debug-feed term "")))
    (when (string-match "cur=(\\([0-9]+\\),\\([0-9]+\\))" info)
      (cons (string-to-number (match-string 1 info))
            (string-to-number (match-string 2 info))))))

(defun ghostel-test--wait-for (proc pred &optional timeout)
  "Poll PROC until PRED returns non-nil, or TIMEOUT seconds (default 5).
Signal an ERT failure if TIMEOUT is reached or PROC exits before PRED
succeeds."
  (let* ((timeout (or timeout 5))
         (deadline (+ (float-time) timeout))
         result)
    (while (and (not (setq result (funcall pred)))
                (< (float-time) deadline)
                (process-live-p proc))
      (accept-process-output proc 0.05))
    (unless result
      (ert-fail
       (if (process-live-p proc)
           (format "Timed out after %.1fs waiting for predicate" timeout)
         (format "Process %s exited before predicate succeeded" (process-name proc)))))
    result))

;; -----------------------------------------------------------------------
;; Test: terminal creation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-create ()
  "Test terminal creation and basic properties."
  (let ((term (ghostel--new 25 80 1000)))
    (should term)                                         ; create returns non-nil
    (should (equal "" (ghostel-test--row0 term)))         ; row0 is blank
    (should (equal '(0 . 0) (ghostel-test--cursor term))) ; cursor at origin
    ))

;; -----------------------------------------------------------------------
;; Test: write-input and render state
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-write-input ()
  "Test feeding text to the terminal."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    (should (equal "hello" (ghostel-test--row0 term)))        ; text appears
    (should (equal '(5 . 0) (ghostel-test--cursor term)))     ; cursor after text

    ;; Newline (CRLF — the Zig module normalizes bare LF)
    (ghostel--write-input term " world\nline2")
    (let ((state (ghostel--debug-state term)))
      (should (string-match-p "hello world" state))  ; row0 has full first line
      (should (string-match-p "line2" state)))))      ; row1 has line2

;; -----------------------------------------------------------------------
;; Test: backspace handling
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-backspace ()
  "Test backspace (BS) processing by the terminal."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    (should (equal "hello" (ghostel-test--row0 term)))        ; before BS

    ;; BS + space + BS erases last character
    (ghostel--write-input term "\b \b")
    (should (equal "hell" (ghostel-test--row0 term)))         ; after 1 BS
    (should (equal '(4 . 0) (ghostel-test--cursor term)))     ; cursor after BS

    ;; Multiple backspaces
    (ghostel--write-input term "\b \b\b \b")
    (should (equal "he" (ghostel-test--row0 term)))))         ; after 3 BS total

;; -----------------------------------------------------------------------
;; Test: cursor movement escape sequences
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-cursor-movement ()
  "Test CSI cursor movement sequences."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "abcdef")
    (ghostel--write-input term "\e[3D")
    (should (equal '(3 . 0) (ghostel-test--cursor term)))     ; cursor left 3

    (ghostel--write-input term "\e[1C")
    (should (equal '(4 . 0) (ghostel-test--cursor term)))     ; cursor right 1

    (ghostel--write-input term "\e[H")
    (should (equal '(0 . 0) (ghostel-test--cursor term)))     ; cursor home

    ;; Cursor to specific position (row 3, col 5 — 1-based in CSI)
    (ghostel--write-input term "\e[4;6H")
    (should (equal '(5 . 3) (ghostel-test--cursor term)))))   ; cursor to (5,3)

;; -----------------------------------------------------------------------
;; Test: cursor-position query
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-cursor-position ()
  "Test `ghostel--cursor-position' returns correct (COL . ROW)."
  (let ((term (ghostel--new 25 80 1000)))
    ;; Origin
    (should (equal '(0 . 0) (ghostel--cursor-position term)))

    ;; After writing text
    (ghostel--write-input term "hello")
    (should (equal '(5 . 0) (ghostel--cursor-position term)))

    ;; After cursor movement
    (ghostel--write-input term "\e[3D")
    (should (equal '(2 . 0) (ghostel--cursor-position term)))

    ;; After newline — cursor on row 1
    (ghostel--write-input term "\nworld")
    (should (equal '(5 . 1) (ghostel--cursor-position term)))

    ;; Absolute positioning
    (ghostel--write-input term "\e[4;6H")
    (should (equal '(5 . 3) (ghostel--cursor-position term)))))

;; -----------------------------------------------------------------------
;; Test: erase sequences
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-erase ()
  "Test CSI erase sequences."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello world")
    (ghostel--write-input term "\e[6D")   ; cursor left 6 (on 'w')
    (ghostel--write-input term "\e[K")    ; erase to end of line
    (should (equal "hello" (ghostel-test--row0 term)))    ; erase to EOL

    (ghostel--write-input term "\e[2K")
    (should (equal "" (ghostel-test--row0 term)))))       ; erase whole line

;; -----------------------------------------------------------------------
;; Test: terminal resize
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-resize ()
  "Test terminal resize."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    (ghostel--set-size term 10 40)
    (should (equal "hello" (ghostel-test--row0 term)))    ; content survives resize
    ;; Write long text to verify new width
    (ghostel--write-input term "\r\n")
    (ghostel--write-input term (make-string 40 ?x))
    (let ((state (ghostel--debug-state term)))
      (should (string-match-p "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" state))))) ; 40 x's on row

;; -----------------------------------------------------------------------
;; Test: scrollback is materialized into the Emacs buffer (vterm parity)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-scrollback-in-buffer ()
  "After overflowing the viewport, scrolled-off rows live in the Emacs buffer.
This is the vterm-style growing-buffer model that lets `isearch' and
`consult-line' search history without entering copy mode."
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
            ;; 12 distinct rows made it into the buffer.  The trailing
            ;; empty cursor row is trimmed to nothing by the renderer
            ;; and therefore contributes no additional line.
            (should (= 12 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-bootstrap-not-blank ()
  "First-time scrollback materialization must contain actual content.
Regression test: when the initial (mostly empty) viewport was rendered
and then a burst of output overflowed the screen, the promotion
optimisation incorrectly kept the stale empty rows as scrollback
instead of fetching the real content from libghostty."
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

(ert-deftest ghostel-test-render-trims-trailing-whitespace ()
  "Rendered rows do not carry libghostty's full-width padding.
The renderer should only keep cells the terminal actually wrote to,
so a short line in a 40-column terminal shows up as the written
content plus no trailing space padding.  Shell-written spaces
\(e.g. the trailing space in a \\='$ \\=' prompt or `%-80s' layout)
are retained — only unwritten padding cells are trimmed."
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

(ert-deftest ghostel-test-scrollback-preserves-url-properties ()
  "Verify URL text properties survive scrollback promotion.
When libghostty pushes a row into scrollback, the redraw promotes the
existing buffer text instead of fetching a fresh copy from libghostty,
so any text properties the row earned while it was the viewport (URL
detection, ghostel-prompt) stay attached."
  (let ((buf (generate-new-buffer " *ghostel-test-sb-url*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t)
                 (ghostel-enable-url-detection t)
                 (ghostel-enable-file-detection nil))
            ;; Write a row with a URL while it's in the viewport.
            (ghostel--write-input term "see https://example.com here\r\n")
            (ghostel--redraw term t)
            ;; Sanity: detect-urls applied a help-echo while the row is visible.
            (goto-char (point-min))
            (let ((url-pos (search-forward "https://example.com" nil t)))
              (should url-pos)
              (should (equal "https://example.com"
                             (get-text-property (- url-pos 19) 'help-echo))))
            ;; Now scroll the URL row off the active screen.
            (dotimes (_ 6) (ghostel--write-input term "filler\r\n"))
            (ghostel--redraw term t)
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

(ert-deftest ghostel-test-scrollback-grows-incrementally ()
  "Successive redraws append newly-scrolled-off rows without losing history."
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

(ert-deftest ghostel-test-scrollback-rotation-rebuild ()
  "Verify cap rotation triggers a rebuild so the buffer reflects libghostty.
The test fills libghostty past its scrollback cap with EARLY markers,
redraws once so the buffer matches the current libghostty state, then
writes a much bigger batch of LATE markers (without an intervening
redraw).  When the next redraw runs, libghostty's `total_rows' is
plateaued at the cap so the normal delta-detection sees nothing to do
— the rotation-detect path must kick in, notice the first scrollback
row's hash has changed, erase the buffer, and let the bootstrap fetch
re-sync from libghostty so the buffer reflects the LATE rows."
  (let ((buf (generate-new-buffer " *ghostel-test-sb-rotate*")))
    (unwind-protect
        (with-current-buffer buf
          (let* (;; 4 KB cap empirically holds ~920 rows of short content
                 ;; in libghostty's compact storage.
                 (term (ghostel--new 5 80 (* 4 1024)))
                 (inhibit-read-only t))
            ;; Phase 1: write 5000 EARLY rows. libghostty's scrollback
            ;; saturates at ~920 rows so the surviving rows are
            ;; early-04080..early-04999 (the most recent 920 of 5000).
            (dotimes (i 5000)
              (ghostel--write-input term (format "early-%05d\r\n" i)))
            (ghostel--redraw term t)
            ;; After this redraw, buffer's scrollback_in_buffer matches
            ;; libghostty's count (~920) and contains those high-numbered
            ;; early rows.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "early-04999" content)))
            ;; Phase 2: write 5000 LATE rows WITHOUT redrawing in
            ;; between. libghostty rotates: every new write evicts an
            ;; early row and pushes a late row. After 5000 writes, all
            ;; survivors are late-* (since 5000 > 920 cap).
            (dotimes (i 5000)
              (ghostel--write-input term (format "late-%05d\r\n" i)))
            ;; Final redraw: total_rows hasn't changed (libghostty is
            ;; still at the cap) but the content has fully rotated.
            ;; Without rotation-detect this would be a no-op and the
            ;; buffer would still show early-* rows.
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; Late rows must be present (libghostty kept the most
              ;; recent ones, the rebuild fetched them into the buffer).
              (should (string-match-p "late-04999" content))
              ;; Early rows must NOT be present anywhere — libghostty
              ;; evicted them AND the rebuild flushed our stale copy.
              (should-not (string-match-p "early-" content)))))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: clear screen (ghostel-clear)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-clear-screen ()
  "Test that ghostel-clear clears the visible screen but preserves scrollback.
With the growing-buffer model the scrollback is always materialized into
the Emacs buffer, so we just check the buffer text directly instead of
scrolling libghostty's viewport."
  (let ((buf (generate-new-buffer " *ghostel-test-clear*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 100))
          (let* ((process-environment
                  (append (list "TERM=xterm-256color" "COLUMNS=80" "LINES=5")
                          process-environment))
                 (proc (make-process
                        :name "ghostel-test-clear"
                        :buffer buf
                        :command '("/bin/zsh" "-f")
                        :connection-type 'pty
                        :filter #'ghostel--filter)))
            (setq ghostel--process proc)
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 5 80)
            (set-process-query-on-exit-flag proc nil)
            ;; Wait for shell init
            (ghostel-test--wait-for proc
                                    (lambda () ghostel--pending-output) 10)
            (ghostel--flush-pending-output)
            (let ((inhibit-read-only t)) (ghostel--redraw ghostel--term t))
            ;; Generate scrollback
            (dotimes (i 15)
              (process-send-string proc (format "echo clear-test-%d\n" i)))
            (ghostel-test--wait-for proc
                                    (lambda ()
                                      (cl-some (lambda (s) (string-match-p "clear-test-14" s))
                                               ghostel--pending-output))
                                    10)
            ;; Do NOT manually flush — let ghostel-clear handle it
            (should (> (length ghostel--pending-output) 0))    ; pending output exists
            ;; Clear screen
            (ghostel-clear)
            ;; Simulate what delayed-redraw does
            (ghostel--flush-pending-output)
            (let ((inhibit-read-only t)) (ghostel--redraw ghostel--term t))
            ;; Scrollback rows live in the buffer above the cleared
            ;; viewport — search for any clear-test echo to confirm.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "clear-test-[0-9]+" content)))
            (delete-process proc)))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: clear scrollback (ghostel-clear-scrollback)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-clear-scrollback ()
  "Test that ghostel-clear-scrollback clears both screen and scrollback."
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

;; -----------------------------------------------------------------------
;; Test: SGR styling (bold, color, etc.)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-sgr ()
  "Test SGR escape sequences set cell styles."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e[1;31mHELLO\e[0m normal")
    (should (equal "HELLO normal" (ghostel-test--row0 term))))) ; styled text content

;; -----------------------------------------------------------------------
;; Test: SGR 2 (dim/faint) renders with dimmed foreground color
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-dim-text ()
  "Test that SGR 2 (faint) produces a dimmed foreground color, not :weight light."
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

;; -----------------------------------------------------------------------
;; Test: multi-byte character rendering (box drawing, Unicode)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-multibyte-rendering ()
  "Test that styled multi-byte text renders without args-out-of-range."
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

;; -----------------------------------------------------------------------
;; Test: wide character (emoji) does not overflow line
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-wide-char-no-overflow ()
  "Test that wide characters (emoji) don't make rendered lines overflow.
A 2-cell-wide emoji should not produce an extra space for the spacer
cell, so the visual line width must equal the emoji width (2).  The
renderer trims trailing blank cells, so we compare against 2 rather
than the full terminal `cols'."
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

;; -----------------------------------------------------------------------
;; Test: title change (OSC 2)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-title ()
  "Test OSC 2 title change."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e]2;My Title\e\\")
    (should (equal "My Title" (ghostel--get-title term))))) ; title set via OSC 2

(ert-deftest ghostel-test-title-does-not-overwrite-manual-rename ()
  "Test that title updates do not overwrite a manual buffer rename."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel--buffer-counter 0))
            (ghostel)
            (setq buf (current-buffer)))
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
  "Test that title updates are ignored when `ghostel-enable-title-tracking' is nil."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel--buffer-counter 0)
                (ghostel-enable-title-tracking nil))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (should (equal "*ghostel*" (buffer-name)))
              (ghostel--set-title "Ignored Title")
              (should (equal "*ghostel*" (buffer-name)))
              (should (equal "*ghostel*" ghostel--managed-buffer-name)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;; -----------------------------------------------------------------------
;; Test: CRLF normalization in Zig
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-crlf ()
  "Test that bare LF is normalized to CRLF by the Zig module."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "first\nsecond")
    (let ((state (ghostel--debug-state term)))
      (should (string-match-p "first" state))              ; first line
      (should (string-match-p "second" state)))             ; second line
    (let ((cur (ghostel-test--cursor term)))
      (should (equal 6 (car cur)))                          ; cursor col after LF
      (should (> (cdr cur) 0)))))                           ; cursor moved to row 1+

;; -----------------------------------------------------------------------
;; Test: raw key sequence fallback
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-raw-key-sequences ()
  "Test the Elisp raw key sequence builder."
  ;; Basic keys
  (should (equal "\x7f" (ghostel--raw-key-sequence "backspace" "")))  ; backspace
  (should (equal "\r" (ghostel--raw-key-sequence "return" "")))       ; return
  (should (equal "\t" (ghostel--raw-key-sequence "tab" "")))          ; tab
  (should (equal "\e" (ghostel--raw-key-sequence "escape" "")))       ; escape
  ;; Cursor keys
  (should (equal "\e[A" (ghostel--raw-key-sequence "up" "")))         ; up
  (should (equal "\e[B" (ghostel--raw-key-sequence "down" "")))       ; down
  (should (equal "\e[C" (ghostel--raw-key-sequence "right" "")))      ; right
  (should (equal "\e[D" (ghostel--raw-key-sequence "left" "")))       ; left
  ;; Shift+arrow
  (should (equal "\e[1;2A" (ghostel--raw-key-sequence "up" "shift"))) ; shift-up
  ;; Ctrl+letter
  (should (equal "\x01" (ghostel--raw-key-sequence "a" "ctrl")))      ; ctrl-a
  (should (equal "\x03" (ghostel--raw-key-sequence "c" "ctrl")))      ; ctrl-c
  (should (equal "\x1a" (ghostel--raw-key-sequence "z" "ctrl")))      ; ctrl-z
  ;; Function keys
  (should (equal "\eOP" (ghostel--raw-key-sequence "f1" "")))         ; f1
  (should (equal "\e[15~" (ghostel--raw-key-sequence "f5" "")))       ; f5
  (should (equal "\e[24~" (ghostel--raw-key-sequence "f12" "")))      ; f12
  ;; Tilde keys
  (should (equal "\e[2~" (ghostel--raw-key-sequence "insert" "")))    ; insert
  (should (equal "\e[3~" (ghostel--raw-key-sequence "delete" "")))    ; delete
  (should (equal "\e[5~" (ghostel--raw-key-sequence "prior" "")))     ; pgup
  ;; Unknown key
  (should (equal nil (ghostel--raw-key-sequence "xyzzy" ""))))        ; unknown

;; -----------------------------------------------------------------------
;; Test: modifier number calculation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-modifier-number ()
  "Test modifier bitmask parsing."
  (should (equal 0 (ghostel--modifier-number "")))            ; no mods
  (should (equal 1 (ghostel--modifier-number "shift")))       ; shift
  (should (equal 4 (ghostel--modifier-number "ctrl")))        ; ctrl
  (should (equal 2 (ghostel--modifier-number "alt")))         ; alt
  (should (equal 2 (ghostel--modifier-number "meta")))        ; meta
  (should (equal 5 (ghostel--modifier-number "shift,ctrl")))  ; shift,ctrl
  (should (equal 4 (ghostel--modifier-number "control"))))    ; control

;; -----------------------------------------------------------------------
;; Test: send-event key extraction
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-send-event ()
  "Test that ghostel--send-event extracts key names and modifiers correctly."
  (let (captured-key captured-mods)
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key captured-mods mods))))
      (cl-flet ((sim (event expected-key expected-mods)
                  (setq captured-key nil captured-mods nil)
                  (let ((last-command-event event))
                    (ghostel--send-event))
                  (should (equal expected-key captured-key))
                  (should (equal expected-mods captured-mods))))
        ;; Unmodified special keys
        (sim (aref (kbd "<return>") 0)    "return"    "")
        (sim (aref (kbd "<tab>") 0)       "tab"       "")
        (sim (aref (kbd "<backspace>") 0) "backspace" "")
        (sim (aref (kbd "<escape>") 0)    "escape"    "")
        (sim (aref (kbd "<up>") 0)        "up"        "")
        (sim (aref (kbd "<f1>") 0)        "f1"        "")
        (sim (aref (kbd "<deletechar>") 0) "delete"   "")
        ;; Modified special keys
        (sim (aref (kbd "S-<return>") 0)  "return"    "shift")
        (sim (aref (kbd "C-<return>") 0)  "return"    "ctrl")
        (sim (aref (kbd "M-<return>") 0)  "return"    "meta")
        (sim (aref (kbd "C-<up>") 0)      "up"        "ctrl")
        (sim (aref (kbd "M-<left>") 0)    "left"      "meta")
        (sim (aref (kbd "S-<f5>") 0)      "f5"        "shift")
        (sim (aref (kbd "C-S-<return>") 0) "return"   "ctrl,shift")
        ;; backtab (Emacs's name for S-TAB)
        (sim (aref (kbd "<backtab>") 0)   "tab"       "shift")))))

;; -----------------------------------------------------------------------
;; Test: modified special keys in raw fallback
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-raw-key-modified-specials ()
  "Test raw fallback produces CSI u encoding for modified specials."
  (should (equal "\e[13;2u"                                       ; shift-return
                 (ghostel--raw-key-sequence "return" "shift")))
  (should (equal "\e[9;5u"                                        ; ctrl-tab
                 (ghostel--raw-key-sequence "tab" "ctrl")))
  (should (equal "\e[127;3u"                                      ; meta-backspace
                 (ghostel--raw-key-sequence "backspace" "meta")))
  (should (equal "\e[27;6u"                                       ; ctrl-shift-escape
                 (ghostel--raw-key-sequence "escape" "shift,ctrl")))
  ;; Unmodified still produce raw bytes
  (should (equal "\r" (ghostel--raw-key-sequence "return" "")))   ; plain return
  (should (equal "\t" (ghostel--raw-key-sequence "tab" ""))))     ; plain tab

;; -----------------------------------------------------------------------
;; Test: shell process integration
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-shell-integration ()
  "Test shell process with echo command."
  (let ((buf (generate-new-buffer " *ghostel-test-shell*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 25 80 1000))
          (let* ((process-environment
                  (append (list "TERM=xterm-256color" "COLUMNS=80" "LINES=25")
                          process-environment))
                 (proc (make-process
                        :name "ghostel-test-sh"
                        :buffer buf
                        :command '("/bin/zsh" "-f")
                        :connection-type 'pty
                        :filter #'ghostel--filter)))
            (setq ghostel--process proc)
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 25 80)
            (set-process-query-on-exit-flag proc nil)
            ;; Wait for shell init
            (ghostel-test--wait-for proc
                                    (lambda () (not (equal "" (ghostel--debug-state ghostel--term)))) 10)
            (should (process-live-p proc))                ; shell process alive

            ;; Run a command
            (process-send-string proc "echo GHOSTEL_TEST_OK\n")
            (ghostel-test--wait-for proc
                                    (lambda () (string-match-p "GHOSTEL_TEST_OK"
                                                               (ghostel--debug-state ghostel--term))))
            (let ((state (ghostel--debug-state ghostel--term)))
              (should (string-match-p "GHOSTEL_TEST_OK" state))) ; command output visible

            ;; Test typing + backspace via PTY echo
            (process-send-string proc "abc")
            (ghostel-test--wait-for proc
                                    (lambda () (string-match-p "abc"
                                                               (ghostel--debug-state ghostel--term))))
            (let ((state (ghostel--debug-state ghostel--term)))
              (should (string-match-p "abc" state)))      ; typed text visible

            (process-send-string proc "\x7f")
            (ghostel-test--wait-for proc
                                    (lambda () (not (string-match-p "abc"
                                                                    (ghostel--debug-state ghostel--term)))))
            (let ((state (ghostel--debug-state ghostel--term)))
              (should (string-match-p "ab" state))        ; backspace removed char
              (should-not (string-match-p "abc" state)))  ; no abc after BS

            (delete-process proc)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-cleanup-temp-paths-handles-files-and-dirs ()
  "`ghostel--cleanup-temp-paths' deletes files and recursively deletes dirs.
Mirrors the real zsh case where the directory still contains a
`.zshenv' at cleanup time."
  (let* ((dir (make-temp-file "ghostel-test-" t))
         (nested (expand-file-name ".zshenv" dir))
         (standalone (make-temp-file "ghostel-test-")))
    (unwind-protect
        (progn
          (with-temp-file nested (insert "# test"))
          (should (file-exists-p nested))
          (should (file-directory-p dir))
          (should (file-exists-p standalone))
          (ghostel--cleanup-temp-paths (list standalone) (list dir))
          (should-not (file-exists-p standalone))
          (should-not (file-exists-p nested))
          (should-not (file-directory-p dir)))
      (ignore-errors (delete-file standalone))
      (ignore-errors (delete-directory dir t)))))

;; -----------------------------------------------------------------------
;; Test: encode-key with kitty keyboard protocol active
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-encode-key-kitty-backspace ()
  "Test that backspace is correctly encoded when kitty keyboard mode is active."
  (let* ((term (ghostel--new 25 80 1000))
         (sent-bytes nil))
    ;; Activate kitty keyboard protocol (flags=5: disambiguate + report-alternates)
    ;; by feeding CSI = 5 u to the terminal
    (ghostel--write-input term "\e[=5u")
    ;; Capture what ghostel--flush-output sends
    (cl-letf (((symbol-function 'ghostel--flush-output)
               (lambda (data)
                 (setq sent-bytes data))))
      ;; Encode backspace — should succeed and send \x7f
      (should (ghostel--encode-key term "backspace" ""))
      (should sent-bytes)
      (should (equal "\x7f" sent-bytes)))))

(ert-deftest ghostel-test-encode-key-legacy-backspace ()
  "Test that backspace is correctly encoded in legacy mode (no kitty)."
  (let* ((term (ghostel--new 25 80 1000))
         (sent-bytes nil))
    ;; No kitty mode set — legacy encoding
    (cl-letf (((symbol-function 'ghostel--flush-output)
               (lambda (data)
                 (setq sent-bytes data))))
      (should (ghostel--encode-key term "backspace" ""))
      (should sent-bytes)
      (should (equal "\x7f" sent-bytes)))))

(ert-deftest ghostel-test-da-response ()
  "Test that the terminal responds to DA1 queries."
  (let* ((term (ghostel--new 25 80 1000))
         (sent-bytes nil))
    (cl-letf (((symbol-function 'ghostel--flush-output)
               (lambda (data)
                 (setq sent-bytes (concat sent-bytes data)))))
      ;; Feed DA1 query: CSI c
      (ghostel--write-input term "\e[c")
      ;; Should have responded with DA1 (CSI ? 62 ; 22 c)
      (should sent-bytes)
      (should (string-match-p "\e\\[\\?62;22c" sent-bytes)))))

(ert-deftest ghostel-test-fish-backspace ()
  "Test backspace works with fish shell."
  :tags '(:fish)
  (skip-unless (executable-find "fish"))
  (let ((buf (generate-new-buffer " *ghostel-test-fish*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 25 80 1000))
          (let* ((process-environment
                  (append (list "TERM=xterm-256color"
                                "COLORTERM=truecolor"
                                "COLUMNS=80" "LINES=25")
                          process-environment))
                 (proc (make-process
                        :name "ghostel-test-fish"
                        :buffer buf
                        :command '("/bin/sh" "-c"
                                   "stty erase '^?' 2>/dev/null; exec fish --no-config")
                        :connection-type 'pty
                        :filter #'ghostel--filter)))
            (setq ghostel--process proc)
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 25 80)
            (set-process-query-on-exit-flag proc nil)
            ;; Wait for fish init (may need longer for DA query handshake)
            (ghostel-test--wait-for proc
                                    (lambda () (not (equal "" (ghostel--debug-state ghostel--term)))) 10)
            (should (process-live-p proc))

            ;; Type "abc" then backspace
            (process-send-string proc "abc")
            (ghostel-test--wait-for proc
                                    (lambda () (string-match-p "abc"
                                                               (ghostel--debug-state ghostel--term))))
            (let ((state (ghostel--debug-state ghostel--term)))
              (should (string-match-p "abc" state)))

            ;; Send backspace (\x7f) and verify it works
            (process-send-string proc "\x7f")
            (ghostel-test--wait-for proc
                                    (lambda () (not (string-match-p "abc"
                                                                    (ghostel--debug-state ghostel--term)))))
            (ghostel--flush-pending-output)
            (let ((state (ghostel--debug-state ghostel--term)))
              (should (string-match-p "ab" state))
              (should-not (string-match-p "abc" state)))

            (delete-process proc)))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: update-directory
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-update-directory ()
  "Test OSC 7 directory tracking helper."
  (let* ((ghostel--last-directory nil)
         (dir (file-name-as-directory default-directory))
         (url-path (replace-regexp-in-string "\\\\" "/"
                                             (directory-file-name dir)))
         (file-url (concat "file://"
                           (if (string-match-p "\\`[[:alpha:]]:/" url-path)
                               "/"
                             "")
                           url-path))
         (default-directory default-directory))
    (ghostel--update-directory dir)
    (should (equal dir default-directory))                 ; plain path
    (ghostel--update-directory file-url)
    (should (equal dir default-directory))                 ; file URL
    ;; Dedup: same path shouldn't re-trigger
    (let ((old ghostel--last-directory))
      (ghostel--update-directory file-url)
      (should (equal old ghostel--last-directory)))))       ; dedup

;; -----------------------------------------------------------------------
;; Test: OSC 7 end-to-end through libghostty
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc7-parsing ()
  "Test that OSC 7 sequences are parsed by libghostty."
  (let ((term (ghostel--new 25 80 1000)))
    (should (equal nil (ghostel--get-pwd term)))           ; no pwd initially

    (ghostel--write-input term "\e]7;file:///tmp/testdir\e\\")
    (should (equal "file:///tmp/testdir"                    ; pwd after OSC 7 (ST)
                   (ghostel--get-pwd term)))

    (ghostel--write-input term "\e]7;file:///home/user\a")
    (should (equal "file:///home/user"                      ; pwd after OSC 7 (BEL)
                   (ghostel--get-pwd term)))))

;; -----------------------------------------------------------------------
;; Test: OSC 52 clipboard
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc52 ()
  "Test OSC 52 clipboard handling."
  (let ((term (ghostel--new 25 80 1000)))
    ;; With osc52 disabled, kill ring should not be modified
    (let ((ghostel-enable-osc52 nil)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;aGVsbG8=\e\\")  ; "hello" in base64
      (should (equal nil kill-ring)))                       ; osc52 disabled: no kill

    ;; With osc52 enabled, text should appear in kill ring
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;aGVsbG8=\e\\")
      (should (> (length kill-ring) 0))                     ; kill ring has entry
      (when kill-ring
        (should (equal "hello" (car kill-ring)))))          ; decoded text

    ;; BEL terminator
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;d29ybGQ=\a")
      (when kill-ring
        (should (equal "world" (car kill-ring)))))          ; osc52 BEL terminator

    ;; Query ('?') should be ignored
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;?\e\\")
      (should (equal nil kill-ring)))))                     ; osc52 query ignored

;; -----------------------------------------------------------------------
;; Test: OSC 4/10/11 color query responses
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc-color-query ()
  "Test that OSC 4/10/11 color queries get responses."
  (let* ((term (ghostel--new 25 80 1000))
         (sent-bytes nil))
    (cl-letf (((symbol-function 'ghostel--flush-output)
               (lambda (data)
                 (setq sent-bytes (concat sent-bytes data)))))

      ;; OSC 11 background query with ST terminator.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]11;?\e\\")
      (should sent-bytes)
      (should (string-match-p "\\`\e\\]11;rgb:[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}\e\\\\\\'"
                              sent-bytes))

      ;; OSC 10 foreground query with BEL terminator.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]10;?\a")
      (should sent-bytes)
      (should (string-match-p "\\`\e\\]10;rgb:[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}\a\\'"
                              sent-bytes))

      ;; OSC 4 palette query for index 1, after a prior set.  The extractor
      ;; runs before vtWrite inside a single write-input, so the set must
      ;; land in a previous call for the new value to be visible.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]4;1;rgb:11/22/33\e\\")
      (should (equal nil sent-bytes))                   ; set: no reply
      (ghostel--write-input term "\e]4;1;?\e\\")
      (should (equal "\e]4;1;rgb:1111/2222/3333\e\\" sent-bytes))

      ;; OSC 10 with a set value (not a query) — no response.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]10;rgb:aa/bb/cc\e\\")
      (should (equal nil sent-bytes))

      ;; OSC 4 set (not a query) — no response.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]4;2;rgb:44/55/66\e\\")
      (should (equal nil sent-bytes))

      ;; Malformed OSC 4 payloads — don't crash, don't reply.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]4;\e\\")           ; empty
      (ghostel--write-input term "\e]4;xyz;?\e\\")     ; non-numeric index
      (ghostel--write-input term "\e]4;999;?\e\\")     ; index out of range
      (ghostel--write-input term "\e]4;0\e\\")         ; index without value
      (ghostel--write-input term "\e]4;99999999999999999999;?\e\\") ; overflow
      (should (equal nil sent-bytes))

      ;; Multiple different-type queries in one write must reply in source
      ;; order so termenv-style readers can match by position.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]11;?\e\\\e]10;?\e\\")
      (should (string-match-p "\\`\e\\]11;rgb:.*?\e\\\\\e\\]10;rgb:.*?\e\\\\\\'"
                              sent-bytes))

      ;; Multi-pair OSC 4 with mixed set+query: the extractor runs before
      ;; vtWrite, so the set is not yet visible to the query in the same
      ;; payload — but the index=1 value seeded in the earlier write
      ;; above is still there, and both indices get replied to in order.
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]4;1;?;3;?\e\\")
      (should (string-match-p
               "\\`\e\\]4;1;rgb:1111/2222/3333\e\\\\\e\\]4;3;rgb:.*?\e\\\\\\'"
               sent-bytes))

      ;; Unterminated OSC query — reply is withheld until the terminator
      ;; arrives.  (We don't buffer across write-input calls, so the
      ;; terminator must be in the same call to get a reply.)
      (setq sent-bytes nil)
      (ghostel--write-input term "\e]11;?")
      (should (equal nil sent-bytes)))))

(ert-deftest ghostel-test-osc-color-query-filter-flush ()
  "The process filter must flush synchronously on a color query.
Programs like `duf' read stdin with a short timeout and give up if
the reply waits for the redraw timer."
  (let ((buf (generate-new-buffer " *ghostel-osc-flush*"))
        (fake-proc (make-symbol "fake-proc"))
        (sent nil))
    (unwind-protect
        (with-current-buffer buf
          (setq ghostel--term (ghostel--new 25 80 1000))
          (setq ghostel--process fake-proc)
          (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                    ((symbol-function 'process-live-p) (lambda (_) t))
                    ((symbol-function 'ghostel--flush-output)
                     (lambda (data) (setq sent (concat sent data))))
                    ((symbol-function 'ghostel--invalidate) #'ignore))
            ;; OSC 11 query arrives — reply must be produced before
            ;; `ghostel--filter' returns, not on a later timer tick.
            (ghostel--filter fake-proc "\e]11;?\e\\")
            (should sent)
            (should (string-match-p "\\`\e\\]11;rgb:" sent))
            (should (equal nil ghostel--pending-output))

            ;; A non-query OSC 11 set must NOT trigger the sync flush,
            ;; so the data stays pending for the redraw timer.
            (setq sent nil)
            (ghostel--filter fake-proc "\e]11;rgb:11/22/33\e\\")
            (should (equal nil sent))
            (should ghostel--pending-output)))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: focus events gated by mode 1004
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-focus-events ()
  "Test that focus events are only sent when mode 1004 is enabled."
  (let ((term (ghostel--new 25 80 1000)))
    (should (equal nil (ghostel--focus-event term t)))     ; focus ignored without mode 1004
    ;; Enable mode 1004 via DECSET
    (ghostel--write-input term "\e[?1004h")
    (should (equal t (ghostel--focus-event term t)))       ; focus sent with mode 1004
    (should (equal t (ghostel--focus-event term nil)))     ; focus-out sent with mode 1004
    ;; Disable mode 1004 via DECRST
    (ghostel--write-input term "\e[?1004l")
    (should (equal nil (ghostel--focus-event term t)))))   ; focus ignored after reset

;; -----------------------------------------------------------------------
;; Test: incremental (partial) redraw
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-incremental-redraw ()
  "Test that incremental redraw correctly updates dirty rows."
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

            ;; 3 content rows + 2 trailing blank rows trimmed to
            ;; empty strings = 4 newlines = 4 lines counted.
            (should (equal 4 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: soft-wrap newline filtering in copy mode
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-soft-wrap-copy ()
  "Test that soft-wrapped newlines are filtered during copy."
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

;; -----------------------------------------------------------------------
;; Test: ghostel--filter-soft-wraps pure function
;; -----------------------------------------------------------------------

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
    (should (equal "aaabbb\nccc" (ghostel--filter-soft-wraps s))))) ; mixed newlines

;; -----------------------------------------------------------------------
;; Test: ANSI color palette customization
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-color-palette ()
  "Test setting a custom ANSI color palette via faces."
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
  (let ((term (ghostel--new 5 40 100)))
    (should (ghostel--apply-palette term)))                ; apply-palette succeeds

  ;; Test face-hex-color extraction
  (let ((color (ghostel--face-hex-color 'ghostel-color-red :foreground)))
    (should (and (stringp color)                           ; face color is hex string
                 (string-prefix-p "#" color)
                 (= (length color) 7)))))

(ert-deftest ghostel-test-hyperlinks ()
  "Test hyperlink keymap and helpers."
  (should (keymapp ghostel-link-map))                      ; ghostel-link-map is a keymap
  (should (lookup-key ghostel-link-map [mouse-1]))         ; mouse-1 bound in link map
  (should (lookup-key ghostel-link-map (kbd "RET")))       ; RET bound in link map
  (should (commandp #'ghostel-open-link-at-point))         ; open-link-at-point is interactive
  ;; Test that help-echo property is read correctly
  (with-temp-buffer
    (insert "click here")
    (put-text-property 1 11 'help-echo "https://example.com")
    (goto-char 5)
    (should (equal "https://example.com"                   ; help-echo at point
                   (get-text-property (point) 'help-echo))))
  (should (null (ghostel--open-link nil)))                 ; open-link returns nil for empty
  (should (null (ghostel--open-link 42))))                 ; open-link returns nil for non-string

(ert-deftest ghostel-test-url-detection ()
  "Test automatic URL detection in plain text."
  ;; Basic URL detection
  (with-temp-buffer
    (insert "Visit https://example.com for info")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com"                   ; url help-echo
                   (get-text-property 7 'help-echo)))
    (should (get-text-property 7 'mouse-face))             ; url mouse-face
    (should (get-text-property 7 'keymap)))                ; url keymap
  ;; Disabled detection
  (with-temp-buffer
    (insert "Visit https://example.com for info")
    (let ((ghostel-enable-url-detection nil))
      (ghostel--detect-urls))
    (should (null (get-text-property 7 'help-echo))))      ; url detection disabled
  ;; Skips existing OSC 8 links
  (with-temp-buffer
    (insert "Visit https://other.com for info")
    (put-text-property 7 26 'help-echo "https://osc8.example.com")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://osc8.example.com"              ; osc8 link preserved
                   (get-text-property 7 'help-echo))))
  ;; URL not ending in punctuation
  (with-temp-buffer
    (insert "See https://example.com/path.")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com/path"              ; url strips trailing dot
                   (get-text-property 5 'help-echo))))
  ;; File:line detection with absolute path
  (let ((test-file (expand-file-name "ghostel.el"
                                     (file-name-directory (or load-file-name default-directory)))))
    (with-temp-buffer
      (insert (format "Error at %s:42 bad" test-file))
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (let ((he (get-text-property 10 'help-echo)))
        (should (and he (string-prefix-p "fileref:" he)))  ; file:line help-echo set
        (should (and he (string-suffix-p ":42" he)))))     ; file:line contains line number
    ;; File:line for non-existent file produces no link
    (with-temp-buffer
      (insert "Error at /no/such/file.el:10 bad")
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; nonexistent file: no help-echo
    ;; File detection disabled
    (with-temp-buffer
      (insert (format "Error at %s:42 bad" test-file))
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; file detection disabled
    ;; ghostel--open-link dispatches fileref:
    (let ((opened nil))
      (cl-letf (((symbol-function 'find-file-other-window)
                 (lambda (f) (setq opened f))))
        (ghostel--open-link (format "fileref:%s:10" test-file)))
      (should (equal test-file opened)))))                 ; fileref opens correct file

;; -----------------------------------------------------------------------
;; Test: OSC 133 prompt marker parsing
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc133-parsing ()
  "Test that OSC 133 sequences are detected and the callback fires."
  (let ((term (ghostel--new 25 80 1000))
        (markers nil))
    (cl-letf (((symbol-function 'ghostel--osc133-marker)
               (lambda (type param) (push (cons type param) markers))))
      (ghostel--write-input term "\e]133;A\e\\")
      (should (assoc "A" markers))                         ; 133;A detected

      (ghostel--write-input term "\e]133;B\a")
      (should (assoc "B" markers))                         ; 133;B detected

      (ghostel--write-input term "\e]133;C\e\\")
      (should (assoc "C" markers))                         ; 133;C detected

      (ghostel--write-input term "\e]133;D;0\e\\")
      (let ((d-entry (assoc "D" markers)))
        (should d-entry)                                   ; 133;D detected
        (should (equal "0" (cdr d-entry))))                ; 133;D param is exit code

      ;; Non-zero exit
      (setq markers nil)
      (ghostel--write-input term "\e]133;D;1\e\\")
      (let ((d-entry (assoc "D" markers)))
        (should (equal "1" (cdr d-entry))))                ; 133;D non-zero exit

      ;; Mixed with other output
      (setq markers nil)
      (ghostel--write-input term "hello\e]133;A\e\\world\e]133;B\e\\")
      (should (assoc "A" markers))                         ; 133;A in mixed stream
      (should (assoc "B" markers)))))                      ; 133;B in mixed stream

;; -----------------------------------------------------------------------
;; Test: OSC 133 prompt text properties
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc133-text-properties ()
  "Test that prompt markers set ghostel-prompt text property."
  (let ((buf (generate-new-buffer " *ghostel-test-osc133*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t)
                 (ghostel--prompt-positions nil))
            ;; Simulate a prompt: A, prompt text, B, command, output, D
            (ghostel--write-input term "\e]133;A\e\\")
            (ghostel--write-input term "$ ")
            (ghostel--redraw term)
            (ghostel--write-input term "\e]133;B\e\\")
            (ghostel--write-input term "echo hi\r\n")
            (ghostel--write-input term "hi\r\n")
            (ghostel--write-input term "\e]133;D;0\e\\")
            (ghostel--redraw term)

            (goto-char (point-min))
            (should (text-property-any (point-min) (point-max)
                                       'ghostel-prompt t)) ; ghostel-prompt property set

            ;; Property should survive a full redraw
            (ghostel--redraw term)
            (should (text-property-any (point-min) (point-max)
                                       'ghostel-prompt t)) ; ghostel-prompt survives redraw

            (should (> (length ghostel--prompt-positions) 0)) ; prompt-positions has entry

            ;; Check exit status stored
            (when ghostel--prompt-positions
              (should (equal 0 (cdr (car ghostel--prompt-positions))))))) ; exit status stored
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: prompt navigation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-prompt-navigation ()
  "Test next/previous prompt navigation."
  (with-temp-buffer
    ;; Realistic layout: property covers WHOLE row (row-level fallback),
    ;; prompt text is "my-prompt # " followed by user command.
    (let ((p1 (point)))
      (insert "my-prompt # cmd1\n")
      (put-text-property p1 (1- (point)) 'ghostel-prompt t))
    (insert "output1\n")
    (let ((p2 (point)))
      (insert "my-prompt # cmd2\n")
      (put-text-property p2 (1- (point)) 'ghostel-prompt t))
    (insert "output2\n")
    (let ((p3 (point)))
      (insert "my-prompt # cmd3\n")
      (put-text-property p3 (1- (point)) 'ghostel-prompt t))
    (insert "output3\n")

    (goto-char (point-min))

    (ghostel--navigate-next-prompt 1)
    (should (looking-at "cmd2"))                           ; next-prompt lands on cmd2

    (ghostel--navigate-next-prompt 1)
    (should (looking-at "cmd3"))                           ; next-prompt lands on cmd3

    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "cmd2"))                           ; previous-prompt lands on cmd2

    (goto-char (point-max))
    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "cmd3"))                           ; previous from end lands on cmd3

    ;; From inside a prompt, previous should skip to the prior prompt
    (goto-char (point-min))
    (ghostel--navigate-next-prompt 1)       ; prompt 2
    (ghostel--navigate-next-prompt 1)       ; prompt 3
    (forward-char 1)                       ; inside prompt 3's command
    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "cmd2"))))                         ; previous from inside prompt lands on cmd2

;; -----------------------------------------------------------------------
;; Test: resize during sync output (alt screen)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-resize-sync ()
  "Test that resize between BSU/ESU cycles gives clean content."
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

;; -----------------------------------------------------------------------
;; Test: resize + app redraw produces correct buffer content
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-resize-redraw-alt-screen ()
  "After resize on alt screen, the app's SIGWINCH-triggered redraw renders correctly.
Simulates: alt-screen TUI fills screen → window resize → app redraws
for new size inside BSU/ESU → verify buffer shows new content."
  (let ((buf (generate-new-buffer " *ghostel-test-resize-redraw*")))
    (unwind-protect
        (with-current-buffer buf
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

;; -----------------------------------------------------------------------
;; Test: resize preserves old frame until redraw replaces it
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-resize-no-blank-flash ()
  "Buffer keeps old content after resize; redraw replaces it atomically.
Regression test: fnSetSize used to call erase-buffer synchronously,
leaving the buffer visibly empty until the next timer-driven redraw.
Now the erasure is deferred into redraw() under inhibit-redisplay."
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

(ert-deftest ghostel-test-resize-redraw-anchors-window-start ()
  "After resize + redraw, window-start is at the viewport origin.
Without explicit anchoring, erase+rebuild inside redraw() clamps
window-start to 1 (top of scrollback), causing a visible jump when
Emacs auto-scrolls to make point visible."
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
                               (forward-line -5)
                               (line-beginning-position))))
              (should (= ws vp-start))
              (should (>= wp vp-start)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: resize with real process — verify PTY and buffer content
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-resize-width-change-full-repaint ()
  "After width change on alt screen, all rows repainted correctly.
Matches the real htop scenario: width changes from wide to narrow,
app redraws all rows at new width via the filter pipeline."
  (let ((buf (generate-new-buffer " *ghostel-test-width-change*")))
    (unwind-protect
        (with-current-buffer buf
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
  (let ((buf (generate-new-buffer " *ghostel-test-pipeline*")))
    (unwind-protect
        (with-current-buffer buf
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

;; -----------------------------------------------------------------------
;; Test: theme synchronization
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-sync-theme ()
  "Test that ghostel-sync-theme applies palette and redraws ghostel buffers."
  (let ((palette-calls nil)
        (redraw-calls nil))
    (cl-letf (((symbol-function 'ghostel--apply-palette)
               (lambda (term) (push term palette-calls)))
              ((symbol-function 'ghostel--redraw)
               (lambda (term) (push term redraw-calls))))
      (let ((buf (generate-new-buffer " *ghostel-test-theme*"))
            (other (generate-new-buffer " *ghostel-test-other*")))
        (unwind-protect
            (progn
              ;; Set up a ghostel-mode buffer with a fake terminal
              (with-current-buffer buf
                (ghostel-mode)
                (setq ghostel--term 'fake-term)
                (setq ghostel--copy-mode-active nil))
              ;; other buffer is not ghostel-mode
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))    ; palette applied to ghostel buffer
              (should (memq 'fake-term redraw-calls))     ; redraw called for ghostel buffer

              ;; Verify copy-mode skips redraw
              (setq palette-calls nil redraw-calls nil)
              (with-current-buffer buf
                (setq ghostel--copy-mode-active t))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))    ; palette still applied in copy mode
              (should-not (memq 'fake-term redraw-calls))) ; redraw skipped in copy mode
          (kill-buffer buf)
          (kill-buffer other))))))

;; -----------------------------------------------------------------------
;; Test: apply-palette sets default fg/bg from Emacs default face
;; -----------------------------------------------------------------------

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

;; -----------------------------------------------------------------------
;; OSC 51 elisp eval
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc51-eval ()
  "Test that OSC 51;E dispatches to whitelisted functions."
  (let* ((called-with nil)
         (ghostel-eval-cmds
          `(("test-fn" ,(lambda (&rest args) (setq called-with args))))))
    (ghostel--osc51-eval "\"test-fn\" \"hello\" \"world\"")
    (should (equal '("hello" "world") called-with))))

(ert-deftest ghostel-test-osc51-eval-unknown ()
  "Test that unknown OSC 51;E commands produce a message."
  (let ((ghostel-eval-cmds nil)
        (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (ghostel--osc51-eval "\"unknown-fn\" \"arg\"")
      (should (car messages))
      (should (string-match-p "unknown eval command" (car messages))))))

(ert-deftest ghostel-test-osc51-eval-catches-errors ()
  "Errors signaled by a dispatched OSC 51;E function must not
propagate out of `ghostel--osc51-eval' — otherwise they crash the
process filter / redraw timer that invoked the native parser.
Regression for a follow-up to #82 where `dow' with no args called
`dired-other-window' with 0 arguments and signaled up through the
filter."
  (let* ((ghostel-eval-cmds
          `(("boom" ,(lambda (&rest _) (error "kaboom")))))
         (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      ;; Must not raise.
      (ghostel--osc51-eval "\"boom\"")
      (should (car messages))
      (should (string-match-p "error calling boom" (car messages)))
      (should (string-match-p "kaboom" (car messages))))))

(ert-deftest ghostel-test-flush-pending-output-preserves-buffer ()
  "Regression for #82: a buffer switch performed by a synchronous
native callback (as OSC 51;E dispatch does when it calls
`find-file-other-window') must not leak out of
`ghostel--flush-pending-output'.  Otherwise callers such as
`ghostel--delayed-redraw' read `ghostel--term' from the wrong
buffer and hand nil to the native module."
  (let ((ghostel-buf (generate-new-buffer " *ghostel-test-flush-buf*"))
        (other-buf (generate-new-buffer " *ghostel-test-flush-other*")))
    (unwind-protect
        (with-current-buffer ghostel-buf
          (setq-local ghostel--term 'fake-handle)
          (setq-local ghostel--pending-output (list "payload"))
          (cl-letf (((symbol-function 'ghostel--write-input)
                     (lambda (_term _data)
                       ;; Simulate `find-file-other-window' flipping
                       ;; the current buffer via `select-window'.
                       (set-buffer other-buf))))
            (ghostel--flush-pending-output))
          (should (eq (current-buffer) ghostel-buf))
          (should (null ghostel--pending-output)))
      (kill-buffer ghostel-buf)
      (kill-buffer other-buf))))

;; -----------------------------------------------------------------------
;; Test: copy-mode cursor visibility
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-mode-cursor ()
  "Test that copy-mode restores cursor visibility when terminal hid it."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Simulate a terminal app hiding the cursor
          (ghostel--set-cursor-style 1 nil)
          (should (null cursor-type))                       ; cursor hidden
          ;; Enter copy mode — cursor should become visible
          (let ((ghostel--copy-mode-active nil)
                (ghostel--redraw-timer nil))
            (ghostel-copy-mode)
            (should ghostel--copy-mode-active)              ; in copy mode
            (should cursor-type)                            ; cursor visible
            (should (equal cursor-type (default-value 'cursor-type))) ; uses user default
            ;; Exit copy mode — cursor should be hidden again
            (ghostel-copy-mode-exit)
            (should-not ghostel--copy-mode-active)          ; exited copy mode
            (should (null cursor-type))))                   ; cursor hidden again
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: copy-mode hl-line-mode management
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-mode-hl-line ()
  "Test that global-hl-line-mode is suppressed and hl-line restored in copy-mode."
  (let ((buf (generate-new-buffer " *ghostel-test-hl-line*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (require 'hl-line)
          ;; Simulate global-hl-line-mode being active
          (let ((global-hl-line-mode t))
            (should global-hl-line-mode)
            ;; Suppress should opt this buffer out
            (ghostel--suppress-interfering-modes)
            (should ghostel--saved-hl-line-mode)
            ;; Buffer-local global-hl-line-mode must be nil — this is the
            ;; mechanism that prevents global-hl-line-highlight (on
            ;; post-command-hook) from creating overlays in this buffer.
            (should-not global-hl-line-mode))
          ;; Enter copy mode — local hl-line-mode should be enabled
          (let ((ghostel--copy-mode-active nil)
                (ghostel--redraw-timer nil))
            (ghostel-copy-mode)
            (should (bound-and-true-p hl-line-mode))
            ;; Exit copy mode — local hl-line-mode disabled again
            (ghostel-copy-mode-exit)
            (should-not (bound-and-true-p hl-line-mode))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (kill-local-variable 'global-hl-line-mode))
        (kill-buffer buf)))))

;; -----------------------------------------------------------------------
;; Test: ghostel-project buffer naming
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-project-buffer-name ()
  "Test that `ghostel-project' derives the buffer name correctly."
  (require 'project)
  (let ((ghostel-buffer-name "*ghostel*")
        result)
    (cl-letf (((symbol-function 'project-current)
               (lambda (_maybe-prompt) '(transient . "/tmp/myproj/")))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'project-prefixed-buffer-name)
               (lambda (name) (format "*myproj-%s*" name)))
              ((symbol-function 'ghostel)
               (lambda (&optional _)
                 (setq result (cons default-directory ghostel-buffer-name)))))
      (ghostel-project)
      (should (equal "/tmp/myproj/" (car result)))
      (should (string-match-p "ghostel" (cdr result)))
      (should-not (string-match-p "\\*\\*" (cdr result))))))

;; -----------------------------------------------------------------------
;; Test: ghostel-project passes universal args to ghostel
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-project-universal-arg ()
  "Test that `ghostel-project' passes the universal arg to `ghostel'."
  (require 'project)
  ;; Numeric prefix arg (C-5 M-x ghostel-project)
  (let ((ghostel-buffer-name "*ghostel*")
        result)
    (cl-letf (((symbol-function 'project-current)
               (lambda (_maybe-prompt) '(transient . "/tmp/myproj/")))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'project-prefixed-buffer-name)
               (lambda (name) (format "*myproj-%s*" name)))
              ((symbol-function 'ghostel)
               (lambda (&optional arg)
                 (setq result arg))))
      (ghostel-project 4)
      (should (equal 4 result))))
  ;; Universal prefix arg (C-u M-x ghostel-project)
  (let ((ghostel-buffer-name "*ghostel*")
        result)
    (cl-letf (((symbol-function 'project-current)
               (lambda (_maybe-prompt) '(transient . "/tmp/myproj/")))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'project-prefixed-buffer-name)
               (lambda (name) (format "*myproj-%s*" name)))
              ((symbol-function 'ghostel)
               (lambda (&optional arg)
                 (setq result arg))))
      (ghostel-project '(4))
      (should (equal '(4) result)))))

;; -----------------------------------------------------------------------
;; Test: ghostel-copy-all copies to kill ring
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-all ()
  "Test that `ghostel-copy-all' puts text into the kill ring."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-all*"))
        (old-kill kill-ring))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake-term))
            (cl-letf (((symbol-function 'ghostel--copy-all-text)
                       (lambda (_term) "hello world")))
              (ghostel-copy-all)
              (should (equal "hello world" (car kill-ring))))))
      (setq kill-ring old-kill)
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: copy-mode scroll commands use Emacs navigation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-mode-buffer-navigation ()
  "Copy-mode navigation commands operate on the Emacs buffer directly."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-nav*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--copy-mode-active t)
                (ghostel--term 'fake-term)
                (inhibit-read-only t))
            (insert (mapconcat #'number-to-string (number-sequence 1 20) "\n"))
            (goto-char (point-min))
            (ghostel-copy-mode-end-of-buffer)
            (should (= (point) (point-max)))
            (ghostel-copy-mode-beginning-of-buffer)
            (should (= (point) (point-min)))
            (ghostel-copy-mode-next-line)
            (should (= 2 (line-number-at-pos)))
            (ghostel-copy-mode-previous-line)
            (should (= 1 (line-number-at-pos)))))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Runner
;; -----------------------------------------------------------------------

;; -----------------------------------------------------------------------
;; Test: module download version selection
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-module-download-url-uses-requested-version ()
  "Requested download versions are decoupled from the package version."
  (let ((ghostel-github-release-url "https://example.invalid/releases"))
    (cl-letf (((symbol-function 'ghostel--module-asset-name)
               (lambda () "ghostel-module-x86_64-linux.so")))
      (should (equal "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-linux.so"
                     (ghostel--module-download-url "0.7.1"))))))

(ert-deftest ghostel-test-module-download-url-uses-latest-release ()
  "A nil download version uses the latest release asset."
  (let ((ghostel-github-release-url "https://example.invalid/releases"))
    (cl-letf (((symbol-function 'ghostel--module-asset-name)
               (lambda () "ghostel-module-x86_64-linux.so")))
      (should (equal "https://example.invalid/releases/latest/download/ghostel-module-x86_64-linux.so"
                     (ghostel--module-download-url nil))))))

(ert-deftest ghostel-test-download-module-defaults-to-minimum-version ()
  "Automatic downloads pin to the minimum supported native module version."
  (let ((ghostel--minimum-module-version "0.7.1")
        (captured-version :unset)
        (download-dest nil))
    (cl-letf (((symbol-function 'ghostel--module-download-url)
               (lambda (&optional version)
                 (setq captured-version version)
                 "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-linux.so"))
              ((symbol-function 'ghostel--download-file)
               (lambda (_url dest)
                 (setq download-dest dest)
                 t))
              ((symbol-function 'message)
               (lambda (&rest _))))
      (should (ghostel--download-module "C:/ghostel/"))
      (should (equal "0.7.1" captured-version))
      (should (equal (downcase (expand-file-name
                                (concat "ghostel-module" module-file-suffix)
                                "C:/ghostel/"))
                     (downcase download-dest))))))

(ert-deftest ghostel-test-download-module-prefix-uses-requested-version ()
  "Prefix downloads pass the requested release version through unchanged."
  (let ((ghostel--minimum-module-version "0.7.1")
        (captured-version :unset)
        (captured-latest nil)
        (loaded-module nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "C:/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "0.8.0"))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional version latest-release)
                   (setq captured-version version
                         captured-latest latest-release)
                   t))
                ((symbol-function 'module-load)
                 (lambda (path)
                   (setq loaded-module path)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (ghostel-download-module '(4))
        (should (equal "0.8.0" captured-version))
        (should-not captured-latest)
        (should (equal (downcase (expand-file-name
                                  (concat "ghostel-module" module-file-suffix)
                                  "C:/ghostel/"))
                       (downcase loaded-module)))))))

(ert-deftest ghostel-test-download-module-prefix-empty-uses-latest ()
  "Prefix download treats blank input as a request for the latest release."
  (let ((captured-version :unset)
        (captured-latest nil)
        (loaded-module nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "C:/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'read-string)
                 (lambda (&rest _) ""))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional version latest-release)
                   (setq captured-version version
                         captured-latest latest-release)
                   t))
                ((symbol-function 'module-load)
                 (lambda (path)
                   (setq loaded-module path)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (ghostel-download-module '(4))
        (should (null captured-version))
        (should captured-latest)
        (should (equal (downcase (expand-file-name
                                  (concat "ghostel-module" module-file-suffix)
                                  "C:/ghostel/"))
                       (downcase loaded-module)))))))

(ert-deftest ghostel-test-download-module-prefix-rejects-too-old-version ()
  "Prefix download rejects versions below the minimum supported version."
  (let ((ghostel--minimum-module-version "0.7.1"))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "C:/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "0.7.0")))
        (should-error (ghostel-download-module '(4))
                      :type 'user-error)))))

(ert-deftest ghostel-test-compile-module-invokes-zig-build ()
  "Source compilation runs zig build directly."
  (let ((default-directory nil)
        (messages nil)
        (warnings nil)
        (process-invocation nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages)))
                ((symbol-function 'display-warning)
                 (lambda (&rest args)
                   (push args warnings)))
                ((symbol-function 'process-file)
                 (lambda (program infile buffer display &rest args)
                   (setq process-invocation
                         (list program infile buffer display args default-directory))
                   0)))
        (should (ghostel--compile-module "C:/ghostel/"))
        (should (equal
                 '("zig" nil "*ghostel-build*" nil ("build" "-Doptimize=ReleaseFast" "-Dcpu=baseline") "C:/ghostel/")
                 process-invocation))
        (should-not warnings)))))

(ert-deftest ghostel-test-module-compile-command-uses-zig-build ()
  "Interactive compilation uses zig build directly."
  (let ((compile-invocation nil)
        (default-directory nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "C:/ghostel/ghostel.el"))
                ((symbol-function 'compile)
                 (lambda (command &optional comint)
                   (setq compile-invocation (list command comint default-directory)))))
        (ghostel-module-compile)
        (should (equal "zig build -Doptimize=ReleaseFast -Dcpu=baseline"
                       (nth 0 compile-invocation)))
        (should (eq t (nth 1 compile-invocation)))
        (should (equal (downcase "C:/ghostel/")
                       (downcase (nth 2 compile-invocation))))))))

(ert-deftest ghostel-test-module-version-match ()
  "Test that version check does nothing when module meets minimum."
  (let ((warned nil)
        (ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.2.0"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (ghostel--check-module-version "/tmp")
      (should-not warned))))

(ert-deftest ghostel-test-module-version-mismatch ()
  "Test that version check warns when module is below minimum."
  (let ((warned nil)
        (ensure-called nil)
        (noninteractive nil)
        (ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.1.0"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t)))
              ((symbol-function 'ghostel--ensure-module)
               (lambda (dir) (setq ensure-called dir))))
      (ghostel--check-module-version "/tmp")
      (should warned)
      (should (equal "/tmp" ensure-called)))))

(ert-deftest ghostel-test-module-version-newer-than-minimum ()
  "Test that version check does nothing when module exceeds minimum."
  (let ((warned nil)
        (ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.3.0"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (ghostel--check-module-version "/tmp")
      (should-not warned))))

;; -----------------------------------------------------------------------
;; Test: immediate redraw for interactive echo
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-immediate-redraw-triggers-on-small-echo ()
  "Small output after recent send-key triggers immediate redraw."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time nil)
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (immediate-called nil)
          (invalidate-called nil))
      ;; Stub out process-buffer, delayed-redraw, and invalidate
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--delayed-redraw)
                 (lambda (_buf) (setq immediate-called t)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidate-called t))))
        ;; Simulate recent keystroke
        (setq ghostel--last-send-time (current-time))
        ;; Simulate small echo arriving
        (ghostel--filter 'fake-proc "a")
        (should immediate-called)
        (should-not invalidate-called)))))

(ert-deftest ghostel-test-immediate-redraw-skips-large-output ()
  "Large output falls back to timer-based batching."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (current-time))
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (immediate-called nil)
          (invalidate-called nil))
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--delayed-redraw)
                 (lambda (_buf) (setq immediate-called t)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidate-called t))))
        ;; Large output should batch
        (ghostel--filter 'fake-proc (make-string 500 ?x))
        (should-not immediate-called)
        (should invalidate-called)))))

(ert-deftest ghostel-test-immediate-redraw-skips-stale-send ()
  "Output arriving long after last keystroke uses timer batching."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (time-subtract (current-time) 1))
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (immediate-called nil)
          (invalidate-called nil))
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--delayed-redraw)
                 (lambda (_buf) (setq immediate-called t)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidate-called t))))
        (ghostel--filter 'fake-proc "a")
        (should-not immediate-called)
        (should invalidate-called)))))

(ert-deftest ghostel-test-immediate-redraw-disabled-when-zero ()
  "Immediate redraw is disabled when threshold is 0."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (current-time))
          (ghostel-immediate-redraw-threshold 0)
          (ghostel-immediate-redraw-interval 0.05)
          (immediate-called nil)
          (invalidate-called nil))
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--delayed-redraw)
                 (lambda (_buf) (setq immediate-called t)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidate-called t))))
        (ghostel--filter 'fake-proc "a")
        (should-not immediate-called)
        (should invalidate-called)))))

;; -----------------------------------------------------------------------
;; Test: input coalescing
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-input-coalesce-buffers-single-chars ()
  "Single-char sends are buffered when coalescing is enabled."
  (with-temp-buffer
    (let* ((ghostel--process nil)
           (ghostel--input-buffer nil)
           (ghostel--input-timer nil)
           (ghostel--last-send-time nil)
           (ghostel-input-coalesce-delay 0.003)
           (sent nil))
      ;; Create a mock process
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_proc str) (push str sent)))
                ((symbol-function 'run-with-timer)
                 (lambda (_delay _repeat fn &rest args)
                   ;; Return a fake timer but call function for test
                   'fake-timer)))
        (setq ghostel--process 'fake)
        (ghostel--send-key "a")
        ;; Should be buffered, not sent
        (should (equal ghostel--input-buffer '("a")))
        (should-not sent)))))

(ert-deftest ghostel-test-input-coalesce-disabled ()
  "With coalesce delay 0, characters are sent immediately."
  (with-temp-buffer
    (let* ((ghostel--process nil)
           (ghostel--input-buffer nil)
           (ghostel--input-timer nil)
           (ghostel--last-send-time nil)
           (ghostel-input-coalesce-delay 0)
           (sent nil))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_proc str) (push str sent))))
        (setq ghostel--process 'fake)
        (ghostel--send-key "a")
        (should (member "a" sent))
        (should-not ghostel--input-buffer)))))

(ert-deftest ghostel-test-input-flush-sends-buffered ()
  "Flushing input buffer sends concatenated characters."
  (with-temp-buffer
    (let* ((ghostel--process nil)
           (ghostel--input-buffer '("c" "b" "a"))
           (ghostel--input-timer nil)
           (sent nil))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_proc str) (push str sent))))
        (setq ghostel--process 'fake)
        (ghostel--flush-input (current-buffer))
        (should (equal sent '("abc")))
        (should-not ghostel--input-buffer)))))

;; -----------------------------------------------------------------------
;; Test: send-encoded sets last-send-time on encoder success
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-send-encoded-sets-send-time ()
  "When the native encoder succeeds, last-send-time is updated."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--last-send-time nil))
      ;; Stub encode-key to return non-nil (success)
      (cl-letf (((symbol-function 'ghostel--encode-key)
                 (lambda (_term _key _mods &optional _utf8) t)))
        (ghostel--send-encoded "backspace" "")
        (should ghostel--last-send-time)))))

(ert-deftest ghostel-test-send-encoded-no-send-time-on-fallback ()
  "When the encoder fails, last-send-time is set by send-key, not send-encoded."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process nil)
          (ghostel--last-send-time nil)
          (ghostel--input-buffer nil)
          (ghostel--input-timer nil)
          (ghostel-input-coalesce-delay 0))
      ;; Stub encode-key to return nil (failure) — triggers raw fallback
      (cl-letf (((symbol-function 'ghostel--encode-key)
                 (lambda (_term _key _mods &optional _utf8) nil))
                ((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_proc _str) nil)))
        (setq ghostel--process 'fake)
        (ghostel--send-encoded "backspace" "")
        ;; send-key sets last-send-time via the fallback path
        (should ghostel--last-send-time)))))

(ert-deftest ghostel-test-scroll-on-input-self-insert ()
  "Self-insert scrolls to bottom when `ghostel-scroll-on-input' is non-nil."
  (let ((ghostel--term 'fake)
        (ghostel--force-next-redraw nil)
        (ghostel-scroll-on-input t)
        (scroll-bottom-called nil)
        (sent-key nil))
    (cl-letf (((symbol-function 'ghostel--scroll-bottom)
               (lambda (_term) (setq scroll-bottom-called t)))
              ((symbol-function 'ghostel--send-key)
               (lambda (str) (setq sent-key str))))
      (let ((last-command-event ?a))
        (cl-letf (((symbol-function 'this-command-keys) (lambda () "a")))
          (ghostel--self-insert)))
      (should scroll-bottom-called)
      (should ghostel--force-next-redraw)
      (should (equal "a" sent-key)))))

(ert-deftest ghostel-test-scroll-on-input-send-event ()
  "Send-event scrolls to bottom when `ghostel-scroll-on-input' is non-nil."
  (let ((ghostel--term 'fake)
        (ghostel--force-next-redraw nil)
        (ghostel-scroll-on-input t)
        (scroll-bottom-called nil))
    (cl-letf (((symbol-function 'ghostel--scroll-bottom)
               (lambda (_term) (setq scroll-bottom-called t)))
              ((symbol-function 'ghostel--send-encoded)
               (lambda (_key _mods &optional _utf8) nil)))
      (let ((last-command-event (aref (kbd "<return>") 0)))
        (ghostel--send-event))
      (should scroll-bottom-called)
      (should ghostel--force-next-redraw))))

(ert-deftest ghostel-test-scroll-on-input-disabled ()
  "Self-insert does not scroll when `ghostel-scroll-on-input' is nil."
  (let ((ghostel--term 'fake)
        (ghostel--force-next-redraw nil)
        (ghostel-scroll-on-input nil)
        (scroll-bottom-called nil))
    (cl-letf (((symbol-function 'ghostel--scroll-bottom)
               (lambda (_term) (setq scroll-bottom-called t)))
              ((symbol-function 'ghostel--send-key)
               (lambda (_str) nil)))
      (cl-letf (((symbol-function 'this-command-keys) (lambda () "a")))
        (let ((last-command-event ?a))
          (ghostel--self-insert)))
      (should-not scroll-bottom-called)
      (should-not ghostel--force-next-redraw))))

(ert-deftest ghostel-test-scroll-intercept-forwards-mouse-tracking ()
  "Scroll intercept forwards events when mouse tracking is active."
  (let ((ghostel--term 'fake)
        (ghostel--process 'fake)
        (ghostel--copy-mode-active nil)
        (ghostel--scroll-intercept-active t)
        (mouse-event-args nil)
        ;; Fake wheel-up event at row 5, col 10
        (fake-event `(wheel-up (,(selected-window) 1 (10 . 5) 0))))
    ;; Mouse tracking active: ghostel--mouse-event returns non-nil
    (cl-letf (((symbol-function 'ghostel--mouse-event)
               (lambda (_term action button row col mods)
                 (setq mouse-event-args (list action button row col mods))
                 t))
              ((symbol-function 'process-live-p) (lambda (_p) t)))
      (ghostel--scroll-intercept-up fake-event)
      (should mouse-event-args)
      (should (equal 0 (nth 0 mouse-event-args)))   ; action = press
      (should (equal 4 (nth 1 mouse-event-args)))   ; button 4 = scroll up
      (should (equal 5 (nth 2 mouse-event-args)))   ; row
      (should (equal 10 (nth 3 mouse-event-args)))  ; col
      ;; Event should NOT be re-dispatched
      (should ghostel--scroll-intercept-active)
      (should-not unread-command-events))
    ;; Reset and test scroll-down with a wheel-down event
    (setq mouse-event-args nil)
    (let ((fake-down-event `(wheel-down (,(selected-window) 1 (10 . 5) 0))))
      (cl-letf (((symbol-function 'ghostel--mouse-event)
                 (lambda (_term action button row col mods)
                   (setq mouse-event-args (list action button row col mods))
                   t))
                ((symbol-function 'process-live-p) (lambda (_p) t)))
        (ghostel--scroll-intercept-down fake-down-event)
        (should mouse-event-args)
        (should (equal 5 (nth 1 mouse-event-args)))   ; button 5 = scroll down
        (should ghostel--scroll-intercept-active)
        (should-not unread-command-events)))))

(ert-deftest ghostel-test-scroll-intercept-fallthrough ()
  "Scroll intercept re-dispatches when mouse tracking is off."
  (let ((ghostel--term 'fake)
        (ghostel--process 'fake)
        (ghostel--copy-mode-active nil)
        (ghostel--scroll-intercept-active t)
        (fake-up-event `(wheel-up (,(selected-window) 1 (10 . 5) 0)))
        (fake-down-event `(wheel-down (,(selected-window) 1 (10 . 5) 0))))
    ;; Mouse tracking off: ghostel--mouse-event returns nil
    (cl-letf (((symbol-function 'ghostel--mouse-event)
               (lambda (_term _action _button _row _col _mods) nil))
              ((symbol-function 'process-live-p) (lambda (_p) t)))
      ;; Test wheel-up re-dispatch
      (ghostel--scroll-intercept-up fake-up-event)
      ;; Intercept should be disabled so the event loop skips our map
      (should-not ghostel--scroll-intercept-active)
      ;; Event should be pushed back for re-processing
      (should (equal fake-up-event (car unread-command-events)))
      ;; Clean up for next assertion
      (setq unread-command-events nil)
      (ghostel--reenable-scroll-intercept)
      ;; Test wheel-down re-dispatch
      (ghostel--scroll-intercept-down fake-down-event)
      (should-not ghostel--scroll-intercept-active)
      (should (equal fake-down-event (car unread-command-events)))
      (setq unread-command-events nil)
      (ghostel--reenable-scroll-intercept))))

(ert-deftest ghostel-test-control-key-bindings ()
  "All non-exception C-<letter> keys should be bound in ghostel-mode-map."
  (dolist (c (number-sequence ?a ?z))
    (let* ((key-str (format "C-%c" c))
           (key-vec (kbd key-str))
           (binding (lookup-key ghostel-mode-map key-vec)))
      ;; Skip exceptions (may have sub-keymaps like C-c C-c)
      (unless (member key-str ghostel-keymap-exceptions)
        (should binding))))
  ;; C-@ should also be bound (sends NUL)
  (should (lookup-key ghostel-mode-map (kbd "C-@"))))

(ert-deftest ghostel-test-meta-key-bindings ()
  "All non-exception M-<letter> keys should be bound in ghostel-mode-map."
  (dolist (c (number-sequence ?a ?z))
    (let* ((key-str (format "M-%c" c))
           (key-vec (kbd key-str))
           (binding (lookup-key ghostel-mode-map key-vec)))
      (unless (eq c ?y)  ; M-y is ghostel-yank-pop
        (if (member key-str ghostel-keymap-exceptions)
            (should-not (eq binding #'ghostel--send-event))
          (should (eq binding #'ghostel--send-event))))))
  ;; M-y should be bound to ghostel-yank-pop, not send-event
  (should (eq (lookup-key ghostel-mode-map (kbd "M-y")) #'ghostel-yank-pop)))

;; -----------------------------------------------------------------------
;; Test: ghostel-copy-mode-recenter
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-mode-recenter ()
  "Copy-mode recenter delegates to the standard `recenter' command."
  (let ((called nil))
    (cl-letf (((symbol-function 'recenter)
               (lambda (&rest _) (setq called t))))
      (ghostel-copy-mode-recenter)
      (should called))))

;; -----------------------------------------------------------------------
;; Test: ghostel-send-next-key
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-send-next-key-control-x ()
  "send-next-key sends C-x as raw byte 24 (not intercepted by Emacs)."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-key)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?\C-x)))
        (ghostel-send-next-key))
      (should (equal (string 24) sent-key)))))

(ert-deftest ghostel-test-send-next-key-control-h ()
  "send-next-key sends C-h as raw byte 8."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-key)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?\C-h)))
        (ghostel-send-next-key))
      (should (equal (string 8) sent-key)))))

(ert-deftest ghostel-test-send-next-key-regular-char ()
  "send-next-key sends a regular character as-is."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-key)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?a)))
        (ghostel-send-next-key))
      (should (equal "a" sent-key)))))

(ert-deftest ghostel-test-send-next-key-meta-x ()
  "send-next-key routes M-x through the encoder with meta modifier."
  (let (captured-key captured-mods
                     (ghostel--term 'fake))
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key captured-mods mods))))
      (let ((unread-command-events (list ?\M-x)))
        (ghostel-send-next-key))
      (should (equal "x" captured-key))
      (should (equal "meta" captured-mods)))))

(ert-deftest ghostel-test-send-next-key-function-key ()
  "send-next-key routes function keys through the encoder."
  (let (captured-key captured-mods
                     (ghostel--term 'fake))
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key captured-mods mods))))
      (let ((unread-command-events (list 'up)))
        (ghostel-send-next-key))
      (should (equal "up" captured-key))
      (should (equal "" captured-mods)))))

;; -----------------------------------------------------------------------
;; Test: TRAMP integration
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-local-host-p ()
  "Test local hostname detection."
  (should (ghostel--local-host-p nil))
  (should (ghostel--local-host-p ""))
  (should (ghostel--local-host-p "localhost"))
  (should (ghostel--local-host-p (system-name)))
  (should (ghostel--local-host-p (car (split-string (system-name) "\\."))))
  (should-not (ghostel--local-host-p "remote-server.example.com")))

(ert-deftest ghostel-test-update-directory-remote ()
  "Test TRAMP path construction from remote OSC 7."
  ;; Remote hostname -> TRAMP path using tramp-default-method fallback
  (let ((ghostel--last-directory nil)
        (default-directory "/tmp/")
        (ghostel-tramp-default-method nil)
        (tramp-default-method "ssh"))
    (ghostel--update-directory "file://remote-host/home/user")
    (should (equal "/ssh:remote-host:/home/user/" default-directory)))
  ;; ghostel-tramp-default-method takes precedence over tramp-default-method
  (let ((ghostel--last-directory nil)
        (default-directory "/tmp/")
        (ghostel-tramp-default-method "rsync")
        (tramp-default-method "ssh"))
    (ghostel--update-directory "file://remote-host/home/user")
    (should (equal "/rsync:remote-host:/home/user/" default-directory)))
  ;; Preserves method from existing TRAMP default-directory
  (let ((ghostel--last-directory nil)
        (default-directory "/scp:server:/"))
    (ghostel--update-directory "file://server/app")
    (should (equal "/scp:server:/app/" default-directory)))
  ;; Preserves user from existing TRAMP default-directory
  (let ((ghostel--last-directory nil)
        (default-directory "/ssh:dan@myhost:/tmp/"))
    (ghostel--update-directory "file://myhost/home/dan")
    (should (equal "/ssh:dan@myhost:/home/dan/" default-directory))))

(ert-deftest ghostel-test-get-shell-local ()
  "Test that local shell resolution returns `ghostel-shell'."
  (let ((default-directory "/tmp/")
        (ghostel-shell "/bin/zsh"))
    (should (equal "/bin/zsh" (ghostel--get-shell)))))

(ert-deftest ghostel-test-start-process-sets-size-via-stty-not-env ()
  "Initial terminal size must be baked into the `stty' wrapper, not
into `LINES'/`COLUMNS' env vars.  Setting those env vars freezes
ncurses apps like htop at start-up size and breaks live resize."
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'window-body-height)
               (lambda (&optional _w) 43))
              ((symbol-function #'window-max-chars-per-line)
               (lambda (&optional _w) 137))
              ((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               (default-directory "/tmp/")
               (proc (ghostel--start-process)))
          (unwind-protect
              (let ((cmd (process-command proc)))
                (should (equal #'ghostel--window-adjust-process-window-size
                               (process-get proc 'adjust-window-size-function)))
                (should (equal '("/bin/sh" "-c") (seq-take cmd 2)))
                (should (string-match-p "stty .* rows 43 columns 137"
                                        (nth 2 cmd)))
                (should (string-match-p "-ixon" (nth 2 cmd)))
                (should-not (seq-some (lambda (s) (string-prefix-p "LINES=" s))
                                      captured-env))
                (should-not (seq-some (lambda (s) (string-prefix-p "COLUMNS=" s))
                                      captured-env))
                (should (member "TERM=xterm-256color" captured-env))
                (should (member "COLORTERM=truecolor" captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

;; -----------------------------------------------------------------------
;; Tests: window resize
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-resize-window-adjust ()
  "Window adjust resizes the VT, marks redraw state, and returns dimensions."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size)
                   (lambda (_term h w) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--delayed-redraw)
                   (lambda (_buf) (setq redraw-called t)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 40))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (equal '(120 . 40) result))
            (should (equal '(40 120) set-size-args))
            (should ghostel--force-next-redraw)
            (should redraw-called)))))))

(ert-deftest ghostel-test-resize-nil-size ()
  "When default function returns nil, no resize happens."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (set-size-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size)
                 (lambda (_term _h _w) (setq set-size-called t)))
                ((symbol-function 'process-buffer)
                 (lambda (_proc) nil))
                ((default-value 'window-adjust-process-window-size-function)
                 (lambda (_proc _wins) nil)))
        (let ((result (ghostel--window-adjust-process-window-size
                       'fake-proc nil)))
          (should (null result))
          (should-not set-size-called))))))

;;; SIGWINCH delivery tests — verify the PTY actually sends the signal

;; Uses ghostel-test--wait-for defined at the top of this file.

(defconst ghostel-test--bash (executable-find "bash")
  "Absolute path to bash, or nil if not found.
The baseline SIGWINCH tests explicitly use bash because trap-on-signal
behavior for an idle shell reading stdin differs across implementations
\(bash delivers immediately; dash defers until the next input line\).")

(ert-deftest ghostel-test-sigwinch-reaches-shell-basic ()
  "Verify `set-process-window-size' delivers SIGWINCH to a PTY shell.
This is the baseline: if this fails, the Emacs PTY mechanism itself
is broken on this system."
  (skip-unless (not (eq system-type 'windows-nt)))
  (skip-unless ghostel-test--bash)
  (let* ((buf (generate-new-buffer " *sigwinch-basic*"))
         (output "")
         (proc nil))
    (unwind-protect
        (progn
          (setq proc
                (make-process
                 :name "sigwinch-basic"
                 :buffer buf
                 :command (list ghostel-test--bash)
                 :connection-type 'pty
                 :noquery t
                 :coding 'binary
                 :filter (lambda (_p s) (setq output (concat output s)))))
          (set-process-window-size proc 24 80)
          ;; Install a SIGWINCH trap that prints a marker to stdout.
          (process-send-string
           proc "trap 'printf \"__WINCH__\\n\"' WINCH\n")
          ;; Wait for shell to start and consume the trap command.
          ;; Bash with readline needs more startup time than /bin/sh.
          (sleep-for 0.5)
          ;; Clear output so we only see post-resize output.
          (setq output "")
          ;; Now trigger a resize — this is what Emacs does after
          ;; adjust-window-size-function returns a (width . height).
          (set-process-window-size proc 30 120)
          ;; Wait up to 2 seconds for trap to fire.
          (ghostel-test--wait-for
           proc (lambda () (string-match-p "__WINCH__" output)) 2.0)
          (should (string-match-p "__WINCH__" output)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-sigwinch-reaches-shell-ghostel-style ()
  "Verify SIGWINCH delivery using ghostel's exact shell-invocation pattern.
Ghostel starts the shell via `/bin/sh -c \"stty ...; exec <shell>\"',
which could affect process group setup and SIGWINCH delivery."
  (skip-unless (not (eq system-type 'windows-nt)))
  (skip-unless ghostel-test--bash)
  (let* ((buf (generate-new-buffer " *sigwinch-ghostel*"))
         (output "")
         (proc nil))
    (unwind-protect
        (progn
          (setq proc
                (make-process
                 :name "sigwinch-ghostel"
                 :buffer buf
                 :command (list "/bin/sh" "-c"
                                (format "stty erase '^?' iutf8 2>/dev/null; \
printf '\\033[H\\033[2J'; exec %s"
                                        ghostel-test--bash))
                 :connection-type 'pty
                 :noquery t
                 :coding 'binary
                 :filter (lambda (_p s) (setq output (concat output s)))))
          (set-process-window-size proc 24 80)
          ;; Wait for the exec to complete and shell to be ready.
          (sleep-for 0.5)
          (process-send-string
           proc "trap 'printf \"__WINCH__\\n\"' WINCH\n")
          (sleep-for 0.3)
          (setq output "")
          (set-process-window-size proc 30 120)
          (ghostel-test--wait-for
           proc (lambda () (string-match-p "__WINCH__" output)) 2.0)
          (should (string-match-p "__WINCH__" output)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-sigwinch-via-ghostel-resize-handler ()
  "Verify SIGWINCH reaches child processes when resize goes through
`ghostel--window-adjust-process-window-size'.  This is the full path
Emacs takes: call the adjust-window-size-function, get (width . height),
then call `set-process-window-size'."
  (skip-unless (not (eq system-type 'windows-nt)))
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf (generate-new-buffer " *sigwinch-gh-handler*"))
         (output "")
         (proc nil))
    (unwind-protect
        (progn
          (setq proc
                (make-process
                 :name "sigwinch-gh-handler"
                 :buffer buf
                 :command '("/bin/sh" "-c"
                            "stty erase '^?' iutf8 2>/dev/null; \
printf '\\033[H\\033[2J'; exec /bin/sh")
                 :connection-type 'pty
                 :noquery t
                 :coding 'binary
                 :filter (lambda (_p s) (setq output (concat output s)))))
          (set-process-window-size proc 24 80)
          (sleep-for 0.5)
          (setq output "")
          ;; Start a foreground child that traps SIGWINCH (simulates htop).
          (process-send-string
           proc "/bin/sh -c 'trap \"printf __CHILD_WINCH__\\\\n\" WINCH; \
while :; do sleep 0.1; done'\n")
          (sleep-for 0.5)
          ;; Now simulate Emacs's window--adjust-process-windows path:
          ;; register the adjust-window-size-function and trigger the handler.
          (process-put proc 'adjust-window-size-function
                       #'ghostel--window-adjust-process-window-size)
          (with-current-buffer buf
            (let ((ghostel--term 'fake-term))
              (cl-letf (((symbol-function 'ghostel--set-size)
                         (lambda (_t _h _w) nil))
                        ((symbol-function 'ghostel--delayed-redraw) #'ignore)
                        ((default-value 'window-adjust-process-window-size-function)
                         (lambda (_p _w) (cons 120 30))))
                ;; Invoke the handler as Emacs would.
                (let ((size (ghostel--window-adjust-process-window-size
                             proc (list))))
                  ;; Emacs calls set-process-window-size with the returned size.
                  (should (equal size (cons 120 30)))
                  (set-process-window-size proc (cdr size) (car size))))))
          (ghostel-test--wait-for
           proc (lambda () (string-match-p "__CHILD_WINCH__" output)) 2.0)
          (should (string-match-p "__CHILD_WINCH__" output)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-sigwinch-reaches-child-process ()
  "Verify SIGWINCH reaches a foreground child of the shell (mimicking htop).
When htop runs, it is a child process of the shell.  Since ghostel's
shell is non-interactive (no job control), the child inherits the
shell's process group and should receive SIGWINCH sent to the PTY's
foreground process group."
  (skip-unless (not (eq system-type 'windows-nt)))
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf (generate-new-buffer " *sigwinch-child*"))
         (output "")
         (proc nil))
    (unwind-protect
        (progn
          (setq proc
                (make-process
                 :name "sigwinch-child"
                 :buffer buf
                 :command '("/bin/sh" "-c" "exec /bin/sh")
                 :connection-type 'pty
                 :noquery t
                 :coding 'binary
                 :filter (lambda (_p s) (setq output (concat output s)))))
          (set-process-window-size proc 24 80)
          (sleep-for 0.3)
          (setq output "")
          ;; Start a child sh in the foreground with its own SIGWINCH trap,
          ;; sleeping forever.  This child simulates htop waiting for SIGWINCH.
          ;; We can't send more commands after this because the outer shell
          ;; is blocked on wait() for the child — but that's fine, we only
          ;; need the resize to fire and the child's trap to print the marker.
          (process-send-string
           proc "/bin/sh -c 'trap \"printf __CHILD_WINCH__\\\\n\" WINCH; \
while :; do sleep 0.1; done'\n")
          (sleep-for 0.5)
          (set-process-window-size proc 30 120)
          (ghostel-test--wait-for
           proc (lambda () (string-match-p "__CHILD_WINCH__" output)) 2.0)
          (should (string-match-p "__CHILD_WINCH__" output)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))


(defconst ghostel-test--elisp-tests
  '(ghostel-test-raw-key-sequences
    ghostel-test-modifier-number
    ghostel-test-send-event
    ghostel-test-raw-key-modified-specials
    ghostel-test-update-directory
    ghostel-test-filter-soft-wraps
    ghostel-test-prompt-navigation
    ghostel-test-sync-theme
    ghostel-test-apply-palette-default-colors
    ghostel-test-osc51-eval
    ghostel-test-osc51-eval-unknown
    ghostel-test-osc51-eval-catches-errors
    ghostel-test-flush-pending-output-preserves-buffer
    ghostel-test-copy-mode-cursor
    ghostel-test-copy-mode-hl-line
    ghostel-test-project-buffer-name
    ghostel-test-project-universal-arg
    ghostel-test-copy-all
    ghostel-test-copy-mode-buffer-navigation
    ghostel-test-compile-module-invokes-zig-build
    ghostel-test-module-compile-command-uses-zig-build
    ghostel-test-module-download-url-uses-requested-version
    ghostel-test-module-download-url-uses-latest-release
    ghostel-test-download-module-defaults-to-minimum-version
    ghostel-test-download-module-prefix-uses-requested-version
    ghostel-test-download-module-prefix-empty-uses-latest
    ghostel-test-download-module-prefix-rejects-too-old-version
    ghostel-test-module-version-match
    ghostel-test-module-version-mismatch
    ghostel-test-module-version-newer-than-minimum
    ghostel-test-title-does-not-overwrite-manual-rename
    ghostel-test-title-tracking-disabled
    ghostel-test-immediate-redraw-triggers-on-small-echo
    ghostel-test-immediate-redraw-skips-large-output
    ghostel-test-immediate-redraw-skips-stale-send
    ghostel-test-immediate-redraw-disabled-when-zero
    ghostel-test-input-coalesce-buffers-single-chars
    ghostel-test-input-coalesce-disabled
    ghostel-test-input-flush-sends-buffered
    ghostel-test-send-encoded-sets-send-time
    ghostel-test-send-encoded-no-send-time-on-fallback
    ghostel-test-scroll-on-input-self-insert
    ghostel-test-scroll-on-input-send-event
    ghostel-test-scroll-on-input-disabled
    ghostel-test-scroll-intercept-forwards-mouse-tracking
    ghostel-test-scroll-intercept-fallthrough
    ghostel-test-control-key-bindings
    ghostel-test-meta-key-bindings
    ghostel-test-copy-mode-recenter
    ghostel-test-send-next-key-control-x
    ghostel-test-send-next-key-control-h
    ghostel-test-send-next-key-regular-char
    ghostel-test-send-next-key-meta-x
    ghostel-test-send-next-key-function-key
    ghostel-test-local-host-p
    ghostel-test-update-directory-remote
    ghostel-test-get-shell-local
    ghostel-test-resize-window-adjust
    ghostel-test-resize-nil-size
    ghostel-test-sigwinch-reaches-shell-basic
    ghostel-test-sigwinch-reaches-shell-ghostel-style
    ghostel-test-sigwinch-reaches-child-process
    ghostel-test-sigwinch-via-ghostel-resize-handler)
  "Tests that require only Elisp (no native module).")

(defun ghostel-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit
   `(member ,@ghostel-test--elisp-tests)))

(defun ghostel-test-run-native ()
  "Run only tests that require the native module."
  (ert-run-tests-batch-and-exit
   `(and "^ghostel-test-"
         (not (member ,@ghostel-test--elisp-tests)))))

(defun ghostel-test-run ()
  "Run all ghostel tests."
  (ert-run-tests-batch-and-exit "^ghostel-test-"))

;;; ghostel-test.el ends here
