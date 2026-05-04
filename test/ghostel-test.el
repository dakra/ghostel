;;; ghostel-test.el --- Tests for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run via `make test' (pure Elisp, no native module required) or
;; `make test-native' (requires the built native module).  See the
;; Makefile for the underlying Emacs invocation.

;;; Code:

(require 'ert)
(require 'ghostel)
(require 'ghostel-compile)
(require 'ghostel-debug)
(require 'ghostel-eshell)

(declare-function ghostel--cleanup-temp-paths "ghostel")

;;; Helpers

(defmacro ghostel-test--with-compile-buffer (var &rest body)
  "Run BODY in a fresh ghostel-mode buffer bound to VAR."
  (declare (indent 1))
  `(let ((,var (generate-new-buffer " *ghostel-test-compile*"))
         (inhibit-message t))
     (unwind-protect
         (with-current-buffer ,var
           (ghostel-mode)
           ,@body)
       (kill-buffer ,var))))

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

(defun ghostel-test--row0 (term)
  "Return the first row text from the render state of TERM."
  (let ((state (ghostel--debug-state term)))
    (when (string-match "row0=\"\\([^\"]*\\)\"" state)
      ;; Trim trailing spaces
      (string-trim-right (match-string 1 state)))))

(defun ghostel-test--cursor (term)
  "Return (COL . ROW) cursor position from debug-feed for TERM."
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

(ert-deftest ghostel-test-cursor-position-preserves-viewport ()
  "`ghostel--cursor-position' must not move the viewport.
The function temporarily scrolls to the bottom to query the cursor and
must restore the previous offset.  If it leaves the viewport parked at
`offset+len==total', the next `ghostel--redraw' mistakes that for a
libghostty scrollback-clear and triggers a full erase + rebuild — which
would collapse all buffer markers to `point-min'.  Anchor a marker in
scrollback, call cursor-position, redraw, and assert the marker held."
  (let ((buf (generate-new-buffer " *ghostel-test-cursor-pos-vp*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Overflow the viewport so the buffer holds real scrollback.
            (dotimes (i 12)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; Anchor a marker on a scrolled-off row, well past `point-min'.
            (goto-char (point-min))
            (search-forward "row-00")
            (let* ((target (point))
                   (m (copy-marker target)))
              (unwind-protect
                  (progn
                    (ghostel--cursor-position term)
                    (ghostel--redraw term)
                    (should (= target (marker-position m))))
                (set-marker m nil)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-mark ()
  "`ghostel--redraw' must keep `mark' stable across the destructive ops.
Full redraws call `eraseBuffer' and partial redraws `deleteRegion',
either of which would snap every marker in the buffer to `point-min'."
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
            ;; 12 distinct rows made it into the buffer + trailing newline
            (should (= 13 (count-lines (point-min) (point-max))))))
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
  "Verify delayed plain-link properties survive scrollback promotion.
When libghostty pushes a row into scrollback, the redraw promotes the
existing buffer text instead of fetching a fresh copy from libghostty,
so any text properties the row earned while it was the viewport stay
attached."
  (let ((buf (generate-new-buffer " *ghostel-test-sb-url*")))
    (unwind-protect
        (with-current-buffer buf
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

;; -----------------------------------------------------------------------
;; Tests: OSC 8 on-demand URI lookup (native)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc8-renders-native-link-handler ()
  "OSC8 links set `help-echo' to the native handler symbol, not a URI string.
After the refactor, render stores `ghostel--native-link-help-echo' as the
`help-echo' text property so Emacs calls it lazily instead of embedding
the URI in the buffer."
  (let ((buf (generate-new-buffer " *ghostel-test-osc8-render*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 5 80 1000))
                 (ghostel--term term)
                 (ghostel--term-rows 5)
                 (inhibit-read-only t))
            (ghostel--write-input term "\e]8;;https://example.com\e\\link text\e]8;;\e\\")
            (ghostel--redraw term t)
            (goto-char (point-min))
            (let* ((end (search-forward "link text" nil t))
                   (link-pos (- end (length "link text"))))
              (should end)
              (should (eq #'ghostel--native-link-help-echo  ; function symbol, not string URI
                          (get-text-property link-pos 'help-echo)))
              (should (keymapp (get-text-property link-pos 'keymap))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-osc8-uri-at-pos-returns-uri ()
  "`ghostel--native-uri-at-pos' queries libghostty and returns the OSC8 URI."
  (let ((buf (generate-new-buffer " *ghostel-test-osc8-uri*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 5 80 1000))
                 (ghostel--term term)
                 (ghostel--term-rows 5)
                 (inhibit-read-only t))
            (ghostel--write-input term "\e]8;;https://example.com\e\\link text\e]8;;\e\\")
            (ghostel--redraw term t)
            (goto-char (point-min))
            (let* ((end (search-forward "link text" nil t))
                   (link-pos (- end (length "link text"))))
              (should end)
              (should (equal "https://example.com"
                             (ghostel--native-uri-at-pos link-pos))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-osc8-uri-at-pos-nil-outside-link ()
  "`ghostel--native-uri-at-pos' returns nil or empty for a non-link cell."
  (let ((buf (generate-new-buffer " *ghostel-test-osc8-nolink*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 5 80 1000))
                 (ghostel--term term)
                 (ghostel--term-rows 5)
                 (inhibit-read-only t))
            (ghostel--write-input term "plain text")
            (ghostel--redraw term t)
            (goto-char (point-min))
            (let ((uri (ghostel--native-uri-at-pos (point))))
              (should (or (null uri) (string= "" uri))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-osc8-uri-at-pos-two-links ()
  "`ghostel--native-uri-at-pos' returns the correct URI for each of two links."
  (let ((buf (generate-new-buffer " *ghostel-test-osc8-two*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 5 80 1000))
                 (ghostel--term term)
                 (ghostel--term-rows 5)
                 (inhibit-read-only t))
            (ghostel--write-input
             term
             (concat "\e]8;;https://first.example\e\\first\e]8;;\e\\"
                     " and "
                     "\e]8;;https://second.example\e\\second\e]8;;\e\\"))
            (ghostel--redraw term t)
            (goto-char (point-min))
            (let* ((first-end (search-forward "first" nil t))
                   (first-pos (- first-end (length "first")))
                   (second-end (search-forward "second" nil t))
                   (second-pos (- second-end (length "second"))))
              (should first-end)
              (should second-end)
              (should (equal "https://first.example"
                             (ghostel--native-uri-at-pos first-pos)))
              (should (equal "https://second.example"
                             (ghostel--native-uri-at-pos second-pos))))))
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

(ert-deftest ghostel-test-scrollback-eviction-chunked ()
  "Scrollback eviction works for chunked writes with interleaved renders.
Writes a small batch, renders, then writes a large batch across many
small writes interspersed with renders.  The accumulated scrollback
from the second phase must evict the first phase from the Emacs
buffer."
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

(ert-deftest ghostel-test-no-stale-lines-in-scrollback ()
  "Rows modified and scrolled out in one write must not leak stale text.
A row that has been materialized in a previous render and is then
modified and scrolled out in a single write should not scroll out the
stale row."
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

;; -----------------------------------------------------------------------
;; Tests: scrollback rows are not rerendered (dirty-row reuse)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-scrollback-not-rebuilt-on-shrink ()
  "Scrollback rows survive a vertical-only viewport shrink without rerendering.
A column-only or full resize erases and rebuilds the buffer, but shrinking
only the row count must leave existing scrollback lines untouched."
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

(ert-deftest ghostel-test-content-preserved-across-vertical-resizes ()
  "Buffer content survives expand then shrink without loss or duplication.
Expands from the initial size (staying within the available scrollback so
no rows are pulled back) then shrinks below the original size.  No
assumption is made about which lines are rebuilt; the full buffer text
must be identical after each resize."
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

(ert-deftest ghostel-test-scrollback-not-rebuilt-on-new-row ()
  "Adding a row to a full viewport does not recreate existing scrollback rows.
When a new row pushes the top viewport row into scrollback, the rows
already in scrollback must remain untouched."
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
;; Test: per-cell face props survive font-lock activation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-face-props-survive-font-lock ()
  "Regression: per-cell face text-properties must survive a font-lock pass.
User configs that force `font-lock-defaults' on (notably Doom Emacs,
which sets `(nil t)' globally) cause `font-lock-mode' to activate in
ghostel buffers despite the mode body disabling it.  JIT-lock's
fontify pass then calls `font-lock-unfontify-region' which, without
the buffer-local override installed by `ghostel-mode', strips every
`face' property the native module wrote."
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

;; -----------------------------------------------------------------------
;; Test: set-buffer-face only called with ghostel-default colors
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-set-buffer-face-uses-default-face-colors ()
  "Regression: New terminal colors should not flicker.
ghostel--set-buffer-face must only ever receive ghostel-default face colors in
new terminal. Regression guard against color flickering."
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

(ert-deftest ghostel-test-crlf-split-across-writes ()
  "CRLF pair split across two write-input calls must not double-insert \\r.
Chunk A ends with \\r, chunk B starts with \\n.  Without cross-call
state the normalizer would treat the leading \\n as bare and emit
\\r\\r\\n to libghostty.  Visible effect: cursor lands on row 1 col 6
after \"first\\r\" + \"\\nsecond\", exactly as if the pair were sent in
one call; a bug would leave it on row 2 or otherwise desynced."
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
  (let ((term (ghostel--new 25 80 1000))
        (term-single (ghostel--new 25 80 1000)))
    (ghostel--write-input term "a\r")
    (ghostel--write-input term "\r\nb")
    (ghostel--write-input term-single "a\r\r\nb")
    (should (equal (ghostel-test--cursor term)
                   (ghostel-test--cursor term-single)))))

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
        ;; Terminal mode sends ASCII 127 for backspace
        (sim ?\d                          "backspace" "")
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
;; Test: fish auto-inject shim
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-fish-auto-inject-loads-integration ()
  "Fish auto-inject shim chains to ghostel.fish and cleans XDG_DATA_DIRS.
Regression test: the vendor_conf.d shim previously (a) inlined a
partial copy of the integration and silently dropped the outbound
\\='ssh' wrapper, and (b) used a temp variable name (\\='xdg_data_dirs')
that collided with a fish-internal local variable, leaking
\\='/fish'-suffixed paths back to exported XDG_DATA_DIRS."
  :tags '(:fish)
  (skip-unless (executable-find "fish"))
  (let* ((ghostel-dir (or (ghostel--resource-root)
                          (file-name-directory
                           (or (locate-library "ghostel")
                               load-file-name
                               buffer-file-name))))
         (integ-dir (directory-file-name
                     (expand-file-name "etc/shell/bootstrap" ghostel-dir)))
         ;; Isolate from the dev's fish config: a user `function ssh' or
         ;; pre-defined ghostel-like helpers would otherwise satisfy the
         ;; assertions even if our shim didn't chain to etc/shell/ghostel.fish.
         ;; Pointing HOME and XDG_CONFIG_HOME at an empty temp dir skips
         ;; config.fish, conf.d/, and functions/ autoload without
         ;; disturbing XDG_DATA_DIRS (so vendor_conf.d still loads).
         (fish-home (make-temp-file "ghostel-test-fish-home-" t)))
    (unwind-protect
        (let* ((probe (concat
                       "functions -q __ghostel_osc7; and echo osc7=yes; or echo osc7=no\n"
                       "functions -q ghostel_cmd; and echo cmd=yes; or echo cmd=no\n"
                       "functions -q ssh; and echo ssh=yes; or echo ssh=no\n"
                       "echo xdg=$XDG_DATA_DIRS\n"))
               (process-environment
                (append (list (format "HOME=%s" fish-home)
                              (format "XDG_CONFIG_HOME=%s" fish-home)
                              (format "EMACS_GHOSTEL_PATH=%s" ghostel-dir)
                              "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                              (format "XDG_DATA_DIRS=%s:/usr/local/share:/usr/share"
                                      integ-dir)
                              (format "GHOSTEL_SHELL_INTEGRATION_XDG_DIR=%s"
                                      integ-dir))
                        process-environment))
               ;; `call-process' inherits `default-directory' as the cwd.
               ;; Avoid a path with tildes — `~' would expand against the
               ;; overridden HOME above and point at a missing subdir.
               (default-directory fish-home)
               (output (with-temp-buffer
                         (call-process "fish" nil (current-buffer) nil
                                       "-i" "-c" probe)
                         (buffer-string))))
          ;; Shim must chain to etc/shell/ghostel.fish so the integration loads.
          (should (string-match-p "^osc7=yes$" output))
          (should (string-match-p "^cmd=yes$" output))
          ;; GHOSTEL_SSH_INSTALL_TERMINFO=1 must reach etc/shell/ghostel.fish so
          ;; the ssh install-and-cache wrapper is defined.
          (should (string-match-p "^ssh=yes$" output))
          ;; XDG cleanup must strip the injected integration dir without
          ;; leaking fish's internal `/fish'-suffixed form.
          (should (string-match "^xdg=\\(.*\\)$" output))
          (should-not (string-match-p (regexp-quote integ-dir)
                                      (match-string 1 output))))
      (delete-directory fish-home t))))

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
         (default-directory default-directory)
         list-buffers-directory)
    (ghostel--update-directory dir)
    (should (equal dir default-directory))                 ; plain path
    (should (equal dir list-buffers-directory))            ; mirrored
    (ghostel--update-directory file-url)
    (should (equal dir default-directory))                 ; file URL
    (should (equal dir list-buffers-directory))            ; mirrored
    ;; Dedup: same path shouldn't re-trigger
    (let ((old ghostel--last-directory))
      (ghostel--update-directory file-url)
      (should (equal old ghostel--last-directory)))))       ; dedup

;; -----------------------------------------------------------------------
;; Test: cwd exposed via list-buffers-directory
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-list-buffers-directory ()
  "Test that `ghostel-mode' exposes cwd via `list-buffers-directory'."
  (let ((default-directory (file-name-as-directory
                            (expand-file-name temporary-file-directory))))
    (with-temp-buffer
      (ghostel-mode)
      (should (equal list-buffers-directory default-directory)))))

(ert-deftest ghostel-test-compile-view-list-buffers-directory ()
  "Test that `ghostel-compile-view-mode' exposes cwd via `list-buffers-directory'."
  (let ((default-directory (file-name-as-directory
                            (expand-file-name temporary-file-directory))))
    (with-temp-buffer
      (ghostel-compile-view-mode)
      (should (equal list-buffers-directory default-directory)))))

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

(ert-deftest ghostel-test-osc9-notification ()
  "OSC 9 iTerm2-style notifications reach `ghostel-notification-function'."
  (let ((term (ghostel--new 25 80 1000))
        (calls nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) calls))))
      ;; Plain iTerm2 notification, ST terminator.
      (ghostel--write-input term "\e]9;Hello world\e\\")
      (should (equal '(("" . "Hello world")) calls))

      ;; BEL terminator
      (setq calls nil)
      (ghostel--write-input term "\e]9;bell form\a")
      (should (equal '(("" . "bell form")) calls))

      ;; Single-character body
      (setq calls nil)
      (ghostel--write-input term "\e]9;X\e\\")
      (should (equal '(("" . "X")) calls))

      ;; Empty payload: no dispatch
      (setq calls nil)
      (ghostel--write-input term "\e]9;\e\\")
      (should (equal nil calls)))))

(ert-deftest ghostel-test-osc9-conemu-suppressed ()
  "ConEmu OSC 9 sub-codes must not fire a notification.
Covers the forms that ghostty-vt's parser accepts as valid ConEmu
sequences (sleep, message box, tab title, wait input, emulation
mode, prompt start).  Payloads that ghostty-vt rejects fall through
to the notification path — see `ghostel-test-osc9-invalid-conemu-notifies'."
  (let ((term (ghostel--new 25 80 1000))
        (calls nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) calls)))
              ((symbol-function 'ghostel--osc-progress)
               (lambda (_s _p) nil)))
      ;; 9;1;<ms> sleep, 9;2;<msg> message box, 9;3;<title> tab title
      (ghostel--write-input term "\e]9;1;500\e\\")
      (ghostel--write-input term "\e]9;2;hello\e\\")
      (ghostel--write-input term "\e]9;3;tab\e\\")
      ;; 9;5 wait-input, 9;12 prompt start
      (ghostel--write-input term "\e]9;5\e\\")
      (ghostel--write-input term "\e]9;12\e\\")
      ;; 9;10 xterm emulation — bare and with valid args 0-3
      (ghostel--write-input term "\e]9;10\e\\")
      (ghostel--write-input term "\e]9;10;0\e\\")
      (ghostel--write-input term "\e]9;10;3\e\\")
      ;; Trailing bytes after a valid first-arg digit are tolerated
      ;; (matches ghostty-vt).
      (ghostel--write-input term "\e]9;10;01\e\\")
      (ghostel--write-input term "\e]9;10;3x\e\\")
      (should (equal nil calls)))))

(ert-deftest ghostel-test-osc9-invalid-conemu-notifies ()
  "Malformed ConEmu payloads fall through to notification.
Mirrors ghostty-vt's parser: e.g. `9;10;4' and `9;10;abc' are
invalid emulation args and surface as notifications with the raw
payload as body."
  (let ((term (ghostel--new 25 80 1000))
        (calls nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) calls)))
              ((symbol-function 'ghostel--osc-progress)
               (lambda (_s _p) nil)))
      (ghostel--write-input term "\e]9;10;4\e\\")
      (should (equal '(("" . "10;4")) calls))

      (setq calls nil)
      (ghostel--write-input term "\e]9;10;\e\\")
      (should (equal '(("" . "10;")) calls))

      (setq calls nil)
      (ghostel--write-input term "\e]9;10;abc\e\\")
      (should (equal '(("" . "10;abc")) calls))

      ;; Realistic iTerm2 notifications whose body starts with "5" or
      ;; "12" must not be swallowed by the ConEmu wait-input / prompt
      ;; sub-codes (which only accept the bare form).
      (setq calls nil)
      (ghostel--write-input term "\e]9;5 minutes left\e\\")
      (should (equal '(("" . "5 minutes left")) calls))

      (setq calls nil)
      (ghostel--write-input term "\e]9;12 monkeys\e\\")
      (should (equal '(("" . "12 monkeys")) calls)))))

(ert-deftest ghostel-test-osc9-cwd-routing ()
  "OSC 9;9;PATH updates the terminal's working directory.
ConEmu's CWD-reporting alias is routed through libghostty's `setPwd'
\(the same plumbing OSC 7 uses), so `ghostel--get-pwd' reflects the
reported path and no notification fires."
  (let ((term (ghostel--new 25 80 1000))
        (notifs nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) notifs))))
      (ghostel--write-input term "\e]9;9;/tmp/ghostel-cwd\e\\")
      (should (equal "/tmp/ghostel-cwd" (ghostel--get-pwd term)))
      (should (equal nil notifs)))))

(ert-deftest ghostel-test-osc9-progress ()
  "OSC 9;4 progress reports reach `ghostel-progress-function'."
  (let ((term (ghostel--new 25 80 1000))
        (calls nil))
    (cl-letf (((symbol-function 'ghostel--osc-progress)
               (lambda (state progress) (push (list state progress) calls))))
      ;; set, with progress
      (ghostel--write-input term "\e]9;4;1;50\e\\")
      (should (equal '(("set" 50)) calls))

      ;; set without progress defaults to 0 (matches ghostty-vt)
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;1\e\\")
      (should (equal '(("set" 0)) calls))

      ;; remove
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;0\e\\")
      (should (equal '(("remove" nil)) calls))

      ;; remove ignores trailing progress (matches ghostty-vt's "remove
      ;; ignores progress" test)
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;0;100\e\\")
      (should (equal '(("remove" nil)) calls))

      ;; error without progress
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;2\e\\")
      (should (equal '(("error" nil)) calls))

      ;; error with progress
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;2;73\e\\")
      (should (equal '(("error" 73)) calls))

      ;; indeterminate
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;3\e\\")
      (should (equal '(("indeterminate" nil)) calls))

      ;; indeterminate ignores trailing progress
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;3;50\e\\")
      (should (equal '(("indeterminate" nil)) calls))

      ;; pause with progress
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;4;25\e\\")
      (should (equal '(("pause" 25)) calls))

      ;; Trailing semicolon is tolerated (9;4;0;)
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;0;\e\\")
      (should (equal '(("remove" nil)) calls))

      ;; Progress overflow clamps to 100
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;1;999\e\\")
      (should (equal '(("set" 100)) calls))

      ;; Huge numbers beyond u16 still parse and clamp (would overflow
      ;; u16, but parser uses u64).
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;1;99999999999\e\\")
      (should (equal '(("set" 100)) calls))

      ;; Non-numeric progress: value falls back to the state's default
      ;; (0 for set, nil for error/pause).
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;1;foo\e\\")
      (should (equal '(("set" 0)) calls))
      (setq calls nil)
      (ghostel--write-input term "\e]9;4;2;foo\e\\")
      (should (equal '(("error" nil)) calls)))))

(ert-deftest ghostel-test-osc-progress-dispatch ()
  "`ghostel--osc-progress' converts the state string to a symbol."
  (let ((calls nil))
    (let ((ghostel-progress-function
           (lambda (state progress) (push (list state progress) calls))))
      (ghostel--osc-progress "set" 42)
      (should (equal '((set 42)) calls))
      (setq calls nil)
      (ghostel--osc-progress "remove" nil)
      (should (equal '((remove nil)) calls))
      ;; Unknown state strings are dropped without invoking the handler
      ;; (defends against a Zig-side typo polluting the obarray).
      (setq calls nil)
      (ghostel--osc-progress "bogus" 1)
      (should (equal nil calls)))
    ;; nil function → no call, no error
    (let ((ghostel-progress-function nil))
      (should-not (ghostel--osc-progress "set" 10)))))

(ert-deftest ghostel-test-osc777-notification ()
  "OSC 777 `notify;TITLE;BODY' reaches `ghostel-notification-function'."
  (let ((term (ghostel--new 25 80 1000))
        (calls nil))
    (cl-letf (((symbol-function 'ghostel--handle-notification)
               (lambda (title body) (push (cons title body) calls))))
      (ghostel--write-input term "\e]777;notify;Subject;Body text\e\\")
      (should (equal '(("Subject" . "Body text")) calls))

      ;; BEL terminator
      (setq calls nil)
      (ghostel--write-input term "\e]777;notify;T;B\a")
      (should (equal '(("T" . "B")) calls))

      ;; Empty title, empty body
      (setq calls nil)
      (ghostel--write-input term "\e]777;notify;;\e\\")
      (should (equal '(("" . "")) calls))

      ;; Unknown extension is dropped
      (setq calls nil)
      (ghostel--write-input term "\e]777;bogus;a;b\e\\")
      (should (equal nil calls)))))

(ert-deftest ghostel-test-notification-dispatch ()
  "`ghostel--handle-notification' honours `ghostel-notification-function'.
`run-at-time' is stubbed synchronously since the dispatcher defers
the handler off the VT-parser callpath."
  (cl-letf (((symbol-function 'run-at-time)
             (lambda (_secs _rep fn &rest args) (apply fn args))))
    (let ((calls nil))
      (let ((ghostel-notification-function
             (lambda (title body) (push (cons title body) calls))))
        (ghostel--handle-notification "T" "B")
        (should (equal '(("T" . "B")) calls)))
      ;; nil → silently ignored
      (let ((ghostel-notification-function nil))
        (should-not (ghostel--handle-notification "T" "B")))
      ;; Error in handler is demoted to message (does not propagate)
      (let ((ghostel-notification-function (lambda (_t _b) (error "Boom")))
            (inhibit-message t)
            (debug-on-error nil))
        (should-not (condition-case _
                        (progn (ghostel--handle-notification "T" "B") nil)
                      (error t)))))))

(ert-deftest ghostel-test-notification-dispatch-current-buffer ()
  "Dispatcher re-enters the originating buffer before calling the handler.
Even if the user has switched to a different buffer by the time
the deferred timer fires, the handler sees the ghostel buffer
that emitted the escape as `current-buffer'."
  (cl-letf (((symbol-function 'run-at-time)
             (lambda (_secs _rep fn &rest args)
               ;; Simulate the timer firing later, from a different
               ;; buffer.
               (with-temp-buffer
                 (rename-buffer " *unrelated*" t)
                 (apply fn args)))))
    (let ((captured-name nil))
      (with-temp-buffer
        (rename-buffer "*ghostel: origin*" t)
        (let ((ghostel-notification-function
               (lambda (_title _body) (setq captured-name (buffer-name)))))
          (ghostel--handle-notification "" "hi")
          (should (equal captured-name "*ghostel: origin*")))))))

(ert-deftest ghostel-test-notification-dispatch-real-timer ()
  "Async path runs end-to-end through a real `run-at-time'.
Every other dispatcher test stubs `run-at-time' synchronously, so
the closure capture, `buffer-live-p' guard, `with-current-buffer'
re-entry, and `condition-case' all go uncovered unless this test
actually yields the event loop and observes the delayed side effect."
  (let ((captured nil))
    (with-temp-buffer
      (rename-buffer "*ghostel: real-timer*" t)
      (let ((ghostel-notification-function
             (lambda (title body)
               (push (list title body (buffer-name)) captured))))
        (ghostel--handle-notification "T" "B")
        ;; Not fired yet — still scheduled.
        (should (equal nil captured))
        ;; Let the 0s timer run.  `sit-for' yields even in batch mode,
        ;; which triggers pending `run-at-time 0 nil ...' callbacks.
        (with-timeout (1.0 (error "Timer never fired"))
          (while (null captured) (sit-for 0.01)))
        (should (equal '(("T" "B" "*ghostel: real-timer*")) captured))))))

(ert-deftest ghostel-test-notification-dispatch-buffer-killed ()
  "Drop notifications whose originating buffer died before timer firing.
Uses a second notification from a live buffer as a positive
control so we can wait on *something* and then assert the
killed-buffer one did not fire."
  (let ((dead-fired nil)
        (live-fired nil))
    (let* ((dead (generate-new-buffer " *ghostel-test-killed*")))
      (let ((ghostel-notification-function
             (lambda (_t _b) (setq dead-fired t))))
        (with-current-buffer dead
          (ghostel--handle-notification "D" "D")))
      (kill-buffer dead))
    (with-temp-buffer
      (rename-buffer " *ghostel-test-live*" t)
      (let ((ghostel-notification-function
             (lambda (_t _b) (setq live-fired t))))
        (ghostel--handle-notification "L" "L")
        (with-timeout (1.0 (error "Live timer never fired"))
          (while (null live-fired) (sit-for 0.01)))))
    (should live-fired)
    (should (equal nil dead-fired))))

(ert-deftest ghostel-test-osc-progress-dispatch-error-isolated ()
  "Errors in `ghostel-progress-function' are caught and demoted."
  (let ((ghostel-progress-function (lambda (_s _p) (error "Boom")))
        (inhibit-message t)
        (debug-on-error nil))
    (should-not (condition-case _
                    (progn (ghostel--osc-progress "set" 10) nil)
                  (error t)))))

(ert-deftest ghostel-test-default-notify-uses-alert ()
  "Route notifications through `alert' when the package is available.
`alert' is pre-provided so the branch fires under batch mode
without the real package installed."
  (provide 'alert)
  (let ((captured nil))
    (cl-letf (((symbol-function 'alert)
               (lambda (msg &rest kw) (setq captured (cons msg kw)))))
      (ghostel-default-notify "Title" "body text")
      (should captured)
      (should (equal (car captured) "body text"))
      (should (equal (plist-get (cdr captured) :title) "Title")))))

(ert-deftest ghostel-test-default-notify-empty-title-uses-buffer-name ()
  "When TITLE is empty, the alert uses the current buffer's name."
  (provide 'alert)
  (let ((captured nil))
    (cl-letf (((symbol-function 'alert)
               (lambda (msg &rest kw) (setq captured (cons msg kw)))))
      (with-temp-buffer
        (rename-buffer "*ghostel: zsh*" t)
        (ghostel-default-notify "" "hi")
        (should (equal (plist-get (cdr captured) :title) (buffer-name)))))))

(ert-deftest ghostel-test-default-progress-modeline ()
  "`ghostel-default-progress' sets `mode-line-process' per state."
  (with-temp-buffer
    (ghostel-default-progress 'set 42)
    (should (equal " [42%]" mode-line-process))
    (ghostel-default-progress 'indeterminate nil)
    (should (equal " [...]" mode-line-process))
    (ghostel-default-progress 'pause 10)
    (should (equal " [paused 10%]" mode-line-process))
    (ghostel-default-progress 'pause nil)
    (should (equal " [paused]" mode-line-process))
    (ghostel-default-progress 'error 99)
    (should (string-match-p "\\[err 99%\\]" mode-line-process))
    (ghostel-default-progress 'remove nil)
    (should (null mode-line-process))))

(ert-deftest ghostel-test-spinner-progress-errors-without-spinner ()
  "`ghostel-spinner-progress' signals a user-error when spinner.el is absent.
Stubs `require' to refuse loading `spinner' so the test does not depend on
whether spinner.el is actually installed in the test env."
  (cl-letf* ((orig-require (symbol-function #'require))
             ((symbol-function #'require)
              (lambda (feature &optional filename noerror)
                (if (eq feature 'spinner)
                    (if noerror nil
                      (signal 'file-missing (list "stub-no-spinner")))
                  (funcall orig-require feature filename noerror)))))
    (with-temp-buffer
      (should-error (ghostel-spinner-progress 'indeterminate nil)
                    :type 'user-error))))

(ert-deftest ghostel-test-spinner-progress-indeterminate-starts-once ()
  "`ghostel-spinner-progress' starts the spinner once across repeat events.
Multiple `indeterminate' events during one working phase must not stack
spinners — claude-code emits transitions repeatedly.  Verifies that
`spinner-start' is called with the configured TYPE symbol (which is the
form that installs spinner.el's mode-line construct) and that
`ghostel--spinner-active' tracks the started/stopped state."
  (let ((start-calls 0)
        (start-args nil))
    (cl-letf (((symbol-function #'require)
               (lambda (&rest _) t))
              ((symbol-function #'spinner-start)
               (lambda (&rest args)
                 (cl-incf start-calls)
                 (setq start-args args)))
              ((symbol-function #'spinner-stop) #'ignore))
      (with-temp-buffer
        (ghostel-spinner-progress 'indeterminate nil)
        (ghostel-spinner-progress 'indeterminate nil)
        (should (= 1 start-calls))
        (should (equal (list ghostel-spinner-type) start-args))
        (should ghostel--spinner-active)))))

(ert-deftest ghostel-test-spinner-progress-set-stops-and-shows-percent ()
  "On `set', the spinner is stopped and `mode-line-process' is the percent text.
Without the explicit stop, spinner.el's mode-line construct would
remain (rendering empty alongside the percentage)."
  (let ((stop-calls 0))
    (cl-letf (((symbol-function #'require)
               (lambda (&rest _) t))
              ((symbol-function #'spinner-start) #'ignore)
              ((symbol-function #'spinner-stop)
               (lambda (&rest _) (cl-incf stop-calls))))
      (with-temp-buffer
        (ghostel-spinner-progress 'indeterminate nil)
        (ghostel-spinner-progress 'set 50)
        (should (= 1 stop-calls))
        (should-not ghostel--spinner-active)
        (should (equal " [50%]" mode-line-process))))))

(ert-deftest ghostel-test-spinner-progress-remove-clears-modeline ()
  "On `remove', the spinner stops and `mode-line-process' is nil."
  (cl-letf (((symbol-function #'require)
             (lambda (&rest _) t))
            ((symbol-function #'spinner-start) #'ignore)
            ((symbol-function #'spinner-stop) #'ignore))
    (with-temp-buffer
      (ghostel-spinner-progress 'indeterminate nil)
      (ghostel-spinner-progress 'remove nil)
      (should-not ghostel--spinner-active)
      (should (null mode-line-process)))))

(ert-deftest ghostel-test-spinner-stop-helper-clears-state ()
  "`ghostel--spinner-stop' calls `spinner-stop' and clears the active flag.
The sentinel relies on this helper to drop a live spinner when the shell
exits, so a regression here would leak the timer past the buffer's life."
  (let ((stop-calls 0))
    (cl-letf (((symbol-function #'spinner-stop)
               (lambda (&rest _) (cl-incf stop-calls))))
      (with-temp-buffer
        (setq ghostel--spinner-active t)
        (ghostel--spinner-stop)
        (should (= 1 stop-calls))
        (should-not ghostel--spinner-active)
        ;; Idempotent: a second call is a no-op.
        (ghostel--spinner-stop)
        (should (= 1 stop-calls))))))

(ert-deftest ghostel-test-osc-partial-does-not-starve-later ()
  "A partial OSC must not cannibalize or starve a following complete OSC.
Input \"\\e]7;PARTIAL\\e]52;c;aGVsbG8=\\a\" would, under a naive
single-pass scanner, let the OSC 7 payload absorb the OSC 52's BEL
terminator — yielding a garbage PWD dispatch and no clipboard.  The
iterator must treat the intervening \\e] as a partial-OSC boundary,
skip the OSC 7, and still dispatch the OSC 52."
  (let ((term (ghostel--new 25 80 1000))
        (ghostel-enable-osc52 t)
        (kill-ring nil)
        (pwd-before (ghostel--get-pwd (ghostel--new 25 80 1000))))
    (ghostel--write-input term "\e]7;PARTIAL\e]52;c;aGVsbG8=\a")
    ;; OSC 52 dispatched: "hello" in kill-ring.
    (should kill-ring)
    (should (equal "hello" (car kill-ring)))
    ;; OSC 7 NOT dispatched with the garbage payload "PARTIAL\e]52;c;aGVsbG8="
    ;; — the PWD should still be whatever a fresh terminal reports (nil).
    (should (equal pwd-before (ghostel--get-pwd term)))))

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

(ert-deftest ghostel-test-osc51-eval-filter-flush ()
  "The process filter must dispatch OSC 51;E synchronously.
Callers like `b4 prep --edit-cover' delete temp files shortly
after sending the OSC; a delayed dispatch (via the redraw timer)
loses the race with `tempfile.TemporaryDirectory' cleanup, so
`find-file' opens a file whose parent directory is already gone."
  (let ((buf (generate-new-buffer " *ghostel-osc51-flush*"))
        (fake-proc (make-symbol "fake-proc"))
        (dispatched nil))
    (unwind-protect
        (with-current-buffer buf
          (setq ghostel--term (ghostel--new 25 80 1000))
          (setq ghostel--process fake-proc)
          (let ((ghostel-eval-cmds
                 `(("noop" ,(lambda (&rest args)
                              (setq dispatched (cons 'noop args)))))))
            (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                      ((symbol-function 'process-live-p) (lambda (_) t))
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              ;; OSC 51;E must run before `ghostel--filter' returns.
              (ghostel--filter fake-proc "\e]51;Enoop \"hi\"\e\\")
              (should (equal '(noop "hi") dispatched))
              (should (equal nil ghostel--pending-output))

              ;; OSC 51;A (directory tracking, not elisp eval) must NOT
              ;; trigger the sync flush — it's harmless to defer.
              (setq dispatched nil)
              (ghostel--filter fake-proc "\e]51;A/tmp\e\\")
              (should (equal nil dispatched))
              (should ghostel--pending-output)

              ;; The OSC introducer can straddle a filter-call boundary
              ;; (slow producers, SSH, tiny TCP segments).  The first
              ;; chunk alone doesn't match — but the second chunk plus
              ;; the carryover tail of the first must trigger dispatch.
              (setq dispatched nil
                    ghostel--pending-output nil)
              (ghostel--filter fake-proc "prefix\e]51;")
              (should (equal nil dispatched))
              (ghostel--filter fake-proc "Enoop \"split\"\e\\")
              (should (equal '(noop "split") dispatched))
              (should (equal nil ghostel--pending-output)))))
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
;; Test: window-level focus events (issue #140)
;; -----------------------------------------------------------------------

(defun ghostel-test--make-focus-buffer (name)
  "Create a ghostel-mode buffer NAME with a fake term and live process.
Returns the buffer."
  (let ((buf (generate-new-buffer name)))
    (with-current-buffer buf
      (ghostel-mode)
      (setq ghostel--term (vector 'fake-term))
      (setq ghostel--process
            (start-process (concat "ghostel-test-focus-" name)
                           nil "cat"))
      (set-process-query-on-exit-flag ghostel--process nil))
    buf))

(defun ghostel-test--cleanup-focus-buffer (buf)
  "Kill BUF and its fake process."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and ghostel--process (process-live-p ghostel--process))
        (delete-process ghostel--process)))
    (kill-buffer buf)))

(defmacro ghostel-test--with-focus-stub (events-var focus-fn &rest body)
  "Run BODY with `ghostel--focus-event' and `frame-focus-state' stubbed.
EVENTS-VAR names a list that receives (BUFFER . FOCUSED) pairs.
FOCUS-FN is a zero-arg function returning the current `frame-focus-state'."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'ghostel--focus-event)
              (lambda (_term focused)
                (push (cons (current-buffer) focused) ,events-var)
                t))
             ((symbol-function 'frame-focus-state)
              (lambda (&optional _frame) (funcall ,focus-fn))))
     ,@body))

(ert-deftest ghostel-test-focus-window-selection ()
  "Window selection changes flip per-buffer focus state."
  (let* ((events nil)
         (focus-fn (lambda () t))
         (buf (ghostel-test--make-focus-buffer " *ghostel-focus-1*"))
         (other (generate-new-buffer " *other*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test--with-focus-stub events focus-fn
          (delete-other-windows)
          (switch-to-buffer buf)
          (let ((other-win (split-window)))
            (set-window-buffer other-win other)
            ;; ghostel window selected → focus-in
            (ghostel--focus-change)
            (should (equal (car events) (cons buf t)))
            ;; Select the other window → focus-out
            (select-window other-win)
            (setq events nil)
            (ghostel--focus-change)
            (should (equal (car events) (cons buf nil)))
            ;; Select ghostel window again → focus-in
            (select-window (get-buffer-window buf))
            (setq events nil)
            (ghostel--focus-change)
            (should (equal (car events) (cons buf t)))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf)
      (kill-buffer other))))

(ert-deftest ghostel-test-focus-dedup ()
  "Repeat calls with unchanged state do not re-send focus events."
  (let* ((events nil)
         (frame-focused t)
         (focus-fn (lambda () frame-focused))
         (buf (ghostel-test--make-focus-buffer " *ghostel-focus-dedup*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test--with-focus-stub events focus-fn
          (delete-other-windows)
          (switch-to-buffer buf)
          (ghostel--focus-change)          ; focus-in
          (ghostel--focus-change)          ; no-op (dedup)
          (ghostel--focus-change)          ; no-op (dedup)
          (should (equal events (list (cons buf t))))
          ;; Transition to focus-out, then confirm further calls dedup.
          (setq frame-focused nil)
          (ghostel--focus-change)          ; focus-out
          (ghostel--focus-change)          ; no-op (dedup)
          (should (equal events (list (cons buf nil) (cons buf t)))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf))))

(ert-deftest ghostel-test-focus-two-ghostel-buffers ()
  "Only the ghostel buffer in the selected window is focused."
  (let* ((events nil)
         (focus-fn (lambda () t))
         (buf-a (ghostel-test--make-focus-buffer " *ghostel-focus-a*"))
         (buf-b (ghostel-test--make-focus-buffer " *ghostel-focus-b*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test--with-focus-stub events focus-fn
          (delete-other-windows)
          (switch-to-buffer buf-a)
          (let ((win-b (split-window)))
            (set-window-buffer win-b buf-b)
            ;; A selected: A transitions nil→t, B stays nil (dedup).
            (ghostel--focus-change)
            (should (equal events (list (cons buf-a t))))
            ;; Select B: A transitions t→nil, B transitions nil→t.
            (select-window win-b)
            (setq events nil)
            (ghostel--focus-change)
            (should (= (length events) 2))
            (should (member (cons buf-a nil) events))
            (should (member (cons buf-b t) events))
            ;; Back to A: inverse transitions.
            (select-window (get-buffer-window buf-a))
            (setq events nil)
            (ghostel--focus-change)
            (should (= (length events) 2))
            (should (member (cons buf-a t) events))
            (should (member (cons buf-b nil) events))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf-a)
      (ghostel-test--cleanup-focus-buffer buf-b))))

(ert-deftest ghostel-test-focus-frame-blur ()
  "Frame losing focus drives the ghostel buffer to focus-out."
  (let* ((events nil)
         (frame-focused t)
         (focus-fn (lambda () frame-focused))
         (buf (ghostel-test--make-focus-buffer " *ghostel-focus-blur*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (ghostel-test--with-focus-stub events focus-fn
          (delete-other-windows)
          (switch-to-buffer buf)
          (ghostel--focus-change)          ; focus-in
          (should (equal (car events) (cons buf t)))
          (setq frame-focused nil)         ; simulate app blur
          (setq events nil)
          (ghostel--focus-change)
          (should (equal (car events) (cons buf nil)))
          (setq frame-focused t)           ; refocus
          (setq events nil)
          (ghostel--focus-change)
          (should (equal (car events) (cons buf t))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf))))

(ert-deftest ghostel-test-focus-skips-state-update-when-1004-off ()
  "Dropped events (mode 1004 off) do not update cached focus state.
Otherwise, enabling 1004 after a focus change would dedup away the
first real focus event."
  (let* ((events nil)
         (emit-p nil)
         (buf (ghostel-test--make-focus-buffer " *ghostel-focus-gated*"))
         (saved-window-config (current-window-configuration)))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--focus-event)
                   (lambda (_term focused)
                     (when emit-p
                       (push (cons (current-buffer) focused) events))
                     emit-p))
                  ((symbol-function 'frame-focus-state)
                   (lambda (&optional _frame) t)))
          (delete-other-windows)
          (switch-to-buffer buf)
          ;; Mode 1004 off: event is dropped, state must remain nil.
          (ghostel--focus-change)
          (should (null events))
          (with-current-buffer buf
            (should (null ghostel--focus-state)))
          ;; Child now enables mode 1004.  Next focus-change must emit.
          (setq emit-p t)
          (ghostel--focus-change)
          (should (equal events (list (cons buf t)))))
      (set-window-configuration saved-window-config)
      (ghostel-test--cleanup-focus-buffer buf))))

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

            (should (equal 5 (count-lines (point-min) (point-max))))))
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
  (should (null (ghostel--open-link nil)))                 ; open-link returns nil for empty
  (should (null (ghostel--open-link 42))))                 ; open-link returns nil for non-string

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
  ;; Skips existing OSC 8 links (help-echo is the native handler function symbol)
  (with-temp-buffer
    (insert "Visit https://other.com for info")
    (put-text-property 7 26 'help-echo #'ghostel--native-link-help-echo)
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (eq #'ghostel--native-link-help-echo           ; osc8 handler not overwritten
                (get-text-property 7 'help-echo))))
  ;; URL not ending in punctuation
  (with-temp-buffer
    (insert "See https://example.com/path.")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com/path"              ; url strips trailing dot
                   (get-text-property 5 'help-echo))))
  ;; File:line detection with absolute path
  (let ((test-file (locate-library "ghostel")))
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
          (insert (format "Error at %s bad" tilde-path))
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
        (should (null moved))))))                    ; no line → no forward-line

(ert-deftest ghostel-test-detect-urls-skips-active-input ()
  "Link detection rules around prompts and user input (issue #199).
- `ghostel-prompt' (shell-generated decoration): never linkified.
- `ghostel-input' on the cursor's line (active typing): not linkified —
  in tty Emacs RET on a linkified cell hijacks the keystroke.
- `ghostel-input' on other lines (historical typed commands): still
  linkified, so users can follow paths in past commands.
- Output (no marker): always linkified."
  (let ((test-file (locate-library "ghostel")))
    ;; History line → both file ref and URL linkified.  Active line
    ;; (cursor's line) → both skipped.  Same `ghostel-input' coverage
    ;; on both lines, only the cursor's line is protected.
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
    ;; Intra-line partial skip: only the `ghostel-input'-marked span is
    ;; protected, not the whole active line.  A URL outside the span on
    ;; the same line still gets linkified.  No trailing newline — cursor
    ;; stays on the typed line.
    (with-temp-buffer
      (insert "out https://before.example mid https://typed.example tail")
      (let* ((typed (save-excursion
                      (goto-char (point-min))
                      (search-forward "https://typed.example")
                      (cons (match-beginning 0) (match-end 0)))))
        (put-text-property (car typed) (cdr typed) 'ghostel-input t))
      (goto-char (point-max))                                           ; cursor on line 1
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (goto-char (point-min))
      (search-forward "https://before.example")
      (should (equal "https://before.example"
                     (get-text-property (match-beginning 0) 'help-echo))) ; outside span → linked
      (search-forward "https://typed.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo)))) ; inside span → skipped
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
                timer-fn timer-args)
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (_delay repeat fn &rest args)
                         (setq scheduled-count (1+ scheduled-count)
                               timer-fn fn
                               timer-args args)
                         (should (null repeat))
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
                (should timer-fn)
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
        (insert (format "see %s:1 for details" test-file))
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
      (should (assoc "B" markers))                         ; 133;B in mixed stream

      ;; 133;P (explicit prompt start, no fresh-line side effect) — used
      ;; by the zsh `zle-line-init' fallback and forwarded to elisp the
      ;; same way as A so prompt navigation keeps working when the
      ;; PROMPT-wrap was clobbered by a theme.
      (setq markers nil)
      (ghostel--write-input term "\e]133;P\e\\")
      (should (assoc "P" markers))                         ; 133;P bare detected
      (setq markers nil)
      (ghostel--write-input term "\e]133;P;k=i\e\\")
      (let ((p-entry (assoc "P" markers)))
        (should p-entry)                                   ; 133;P with k=i detected
        (should (equal "k=i" (cdr p-entry)))))))           ; param payload preserved

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
;; Test: OSC 133 input cells get ghostel-input property
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc133-input-text-property ()
  "Cells between OSC 133 B and C should be marked `ghostel-input'.
This is what keeps `ghostel--detect-urls' from linkifying the user's
in-progress command line — the renderer marks input cells, the elisp
scanner skips them."
  (let ((buf (generate-new-buffer " *ghostel-test-osc133-input*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-input
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

;; -----------------------------------------------------------------------
;; Test: zsh `zle-line-init' fallback uses 133;P (no fresh-line)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-zsh-line-init-fallback-no-fresh-line ()
  "Use 133;P (not 133;A) in the `zle-line-init' fallback emit.
When ghostel's PROMPT-wrap is bypassed (e.g. a theme like
powerlevel10k overrides PROMPT after our precmd), the
`zle-line-init' fallback in `etc/shell/ghostel.zsh' fires
post-prompt-draw to emit OSC 133 markers directly.  It must use
133;P, NOT 133;A — libghostty's fresh-line behavior on 133;A would
CR+LF the cursor onto a blank row below the prompt char (#230).

The test sources ghostel.zsh in a real zsh subprocess, removes the
PROMPT-wrap function from `precmd_functions' to simulate the wrap
being overwritten, sets a multi-line PROMPT, and verifies the
cursor lands at the end of the prompt char rather than one row
below it."
  (skip-unless (executable-find "zsh"))
  (let* ((root (or (ghostel--resource-root)
                   (file-name-directory (locate-library "ghostel"))))
         (shell-zsh (expand-file-name "etc/shell/ghostel.zsh" root)))
    (skip-unless (file-exists-p shell-zsh))
    (let ((buf (generate-new-buffer " *ghostel-test-line-init-fallback*")))
      (unwind-protect
          (with-current-buffer buf
            (ghostel-mode)
            (setq ghostel--term (ghostel--new 8 80 200))
            (let* ((process-environment
                    (append (list "TERM=xterm-ghostty"
                                  "INSIDE_EMACS=ghostel"
                                  "COLUMNS=80" "LINES=8")
                            process-environment))
                   (proc (make-process
                          :name "ghostel-test-line-init-fallback"
                          :buffer buf
                          :command '("/bin/zsh" "-fi")
                          :connection-type 'pty
                          :filter #'ghostel--filter)))
              (setq ghostel--process proc)
              (set-process-coding-system proc 'binary 'binary)
              (set-process-window-size proc 8 80)
              (set-process-query-on-exit-flag proc nil)
              (unwind-protect
                  (progn
                    ;; Wait for the initial default prompt to land.
                    (ghostel-test--wait-for
                     proc (lambda () ghostel--pending-output) 10)
                    ;; Source ghostel.zsh (registers precmd hooks + the
                    ;; zle-line-init widget).  Then strip the wrap function
                    ;; from `precmd_functions' so PROMPT is left untouched
                    ;; — this exercises the fallback path the same way
                    ;; powerlevel10k's `_p9k_precmd' override does in the
                    ;; wild.  Set a multi-line PROMPT so the regression is
                    ;; visible: cursor must land beside `final-> ', not on
                    ;; the row below it.
                    (process-send-string
                     proc
                     (concat
                      "source " shell-zsh "\n"
                      "precmd_functions=(${precmd_functions:#__ghostel_ensure_prompt_wrap})\n"
                      "PROMPT=$'top-line\\nfinal-> '\n"
                      "\n"))
                    ;; Wait for the multi-line prompt to render.
                    (ghostel-test--wait-for
                     proc
                     (lambda ()
                       (cl-some (lambda (s) (string-match-p "final-> " s))
                                ghostel--pending-output))
                     15)
                    ;; Give zle a beat to enter line-init and emit the OSC.
                    (sleep-for 0.2)
                    (ghostel--flush-pending-output)
                    (let ((inhibit-read-only t))
                      (ghostel--redraw ghostel--term t))
                    (let* ((pos (ghostel--cursor-position ghostel--term))
                           (col (car pos))
                           (row (cdr pos)))
                      ;; Cursor sits right after `final-> ' (8 chars).
                      (should (= 8 col))
                      ;; ...and on the same row as `final-> ', not below it.
                      (save-excursion
                        (goto-char (point-min))
                        (forward-line row)
                        (should
                         (string-prefix-p
                          "final-> "
                          (buffer-substring-no-properties
                           (line-beginning-position)
                           (line-end-position)))))))
                (delete-process proc))))
        (kill-buffer buf)))))

;; -----------------------------------------------------------------------
;; Test: prompt cells get tagged even when a theme overrides PROMPT
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-zsh-prompt-cells-tagged-with-self-reorder-theme ()
  "Tag prompt cells when a self-reordering theme overrides PROMPT.
Prompt themes that re-assert their position at the END of
`precmd_functions' on every run (powerlevel10k's `_p9k_precmd',
and similar) win the snapshot-iteration race and overwrite PROMPT
after `__ghostel_ensure_prompt_wrap' has wrapped it.  Net: rendered
PROMPT lacks our inline markers each cycle.

Mirroring ghostty's zsh integration, when our wrap detects it isn't
last in `precmd_functions' it self-reorders for next cycle AND
emits 133;A via `printf' once per cycle as a fallback.  That printf
fires BEFORE the theme overwrites PROMPT and BEFORE zsh draws it,
so libghostty's cursor enters `.prompt' state before any prompt
cell is written — and prompt cells get `ghostel-prompt' tagged even
though our PROMPT wrap didn't stick.

This test registers a fake-p10k precmd that self-reorders to end
and overrides PROMPT each cycle, runs a few prompt cycles, and
checks that the most recent prompt's `top-line' row carries the
`ghostel-prompt' text property."
  (skip-unless (executable-find "zsh"))
  (let* ((root (or (ghostel--resource-root)
                   (file-name-directory (locate-library "ghostel"))))
         (shell-zsh (expand-file-name "etc/shell/ghostel.zsh" root)))
    (skip-unless (file-exists-p shell-zsh))
    (let ((buf (generate-new-buffer " *ghostel-test-rearrange*")))
      (unwind-protect
          (with-current-buffer buf
            (ghostel-mode)
            (setq ghostel--term (ghostel--new 8 80 200))
            (let* ((process-environment
                    (append (list "TERM=xterm-ghostty"
                                  "INSIDE_EMACS=ghostel"
                                  "COLUMNS=80" "LINES=8")
                            process-environment))
                   (proc (make-process
                          :name "ghostel-test-rearrange"
                          :buffer buf
                          :command '("/bin/zsh" "-fi")
                          :connection-type 'pty
                          :filter #'ghostel--filter)))
              (setq ghostel--process proc)
              (set-process-coding-system proc 'binary 'binary)
              (set-process-window-size proc 8 80)
              (set-process-query-on-exit-flag proc nil)
              (unwind-protect
                  (progn
                    (ghostel-test--wait-for
                     proc (lambda () ghostel--pending-output) 10)
                    ;; Source ghostel.zsh + register a fake p10k that
                    ;; both overrides PROMPT AND self-reorders to end
                    ;; each cycle (this is what `_p9k_precmd' does).
                    ;; Then trigger several cycles and probe PROMPT.
                    (process-send-string
                     proc
                     (concat
                      "source " shell-zsh "\n"
                      "fake_theme() {\n"
                      "  PROMPT=$'top-line\\nfinal-> '\n"
                      "  precmd_functions=(${precmd_functions:#fake_theme})\n"
                      "  precmd_functions+=(fake_theme)\n"
                      "}\n"
                      "precmd_functions+=(fake_theme)\n"
                      ;; Trigger several prompt cycles so the rearrange
                      ;; settles.  Cycle 1 has the bug; cycle 2+ should
                      ;; have the wrap inline in PROMPT.
                      "true\n"
                      "true\n"
                      "true\n"
                      ;; Print a sentinel after the last prompt cycle
                      ;; so the test can find a stable anchor in the
                      ;; rendered buffer to look back from.
                      "print -r -- 'PROBE_DONE'\n"))
                    (ghostel-test--wait-for
                     proc
                     (lambda ()
                       (cl-some (lambda (s)
                                  (string-match-p "PROBE_DONE" s))
                                ghostel--pending-output))
                     15)
                    (sleep-for 0.2)
                    (ghostel--flush-pending-output)
                    (let ((inhibit-read-only t))
                      (ghostel--redraw ghostel--term t))
                    ;; After the rearrange settles, the WRAP fires INLINE
                    ;; with PROMPT expansion (cycle 2+) — so 133;A fires
                    ;; before the prompt content is drawn.  libghostty
                    ;; sets `.prompt' semantic on subsequent cells, and
                    ;; the renderer maps that to `ghostel-prompt' text
                    ;; property.  The most recent prompt's `top-line'
                    ;; row must carry that property.
                    ;;
                    ;; Without the rearrange the fallback fires AFTER
                    ;; the prompt is drawn, so prompt cells are written
                    ;; before the marker — they DON'T get tagged.
                    (save-excursion
                      (goto-char (point-max))
                      (should (search-backward "top-line" nil t))
                      (should (get-text-property (point) 'ghostel-prompt))))
                (delete-process proc))))
        (kill-buffer buf)))))

(ert-deftest ghostel-test-osc133-prompt-stops-at-input ()
  "`ghostel-prompt' must end where `ghostel-input' begins on the row.
Without this, the historical prompt row carries `ghostel-prompt'
across the typed command, and `ghostel--detect-urls-skip-p' refuses
to linkify paths in past commands — even though they are outside the
active input range."
  (let ((buf (generate-new-buffer " *ghostel-test-osc133-prompt-input*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-input
             term "\e]133;A\e\\$ \e]133;B\e\\ls /etc/hosts")
            (ghostel--redraw term)
            (goto-char (point-min))
            (should (search-forward "ls /etc/hosts" nil t))
            (let ((path-beg (- (point) (length "ls /etc/hosts")))
                  (path-end (point)))
              (should (get-text-property 1 'ghostel-prompt))            ; "$"
              (should (get-text-property 2 'ghostel-prompt))            ; " "
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
            (ghostel--write-input
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
            (ghostel--write-input
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
  (let ((buf (generate-new-buffer " *ghostel-test-osc133-input-wide*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-input
             term "\e]133;A\e\\$ \e]133;B\e\\日a")
            (ghostel--redraw term)
            (goto-char (point-min))
            (should (search-forward "日a" nil t))
            ;; "$ " is 2 narrow cells (positions 1-2); "日" is wide
            ;; (1 emacs char at position 3, occupying terminal cols 2-3);
            ;; "a" is narrow (position 4, terminal col 4).
            (should (null (get-text-property 1 'ghostel-input))) ; "$"
            (should (null (get-text-property 2 'ghostel-input))) ; " "
            (should (get-text-property 3 'ghostel-input))         ; 日
            (should (get-text-property 4 'ghostel-input))         ; a
            ;; The newline after "a" is past the input range.
            (should (null (get-text-property 5 'ghostel-input)))))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: ghostel-command-finish-functions hook
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-command-finish-hook ()
  "Test that OSC 133 D fires `ghostel-command-finish-functions'."
  (with-temp-buffer
    (let* ((calls nil)
           (ghostel-command-finish-functions
            (list (lambda (buf exit) (push (cons buf exit) calls)))))
      (ghostel--osc133-marker "A" nil)
      (ghostel--osc133-marker "D" "0")
      (should (equal 1 (length calls)))                       ; hook fired once
      (should (eq (caar calls) (current-buffer)))             ; buffer passed
      (should (equal 0 (cdar calls)))                         ; exit 0 as integer

      (setq calls nil)
      (ghostel--osc133-marker "A" nil)
      (ghostel--osc133-marker "D" "2")
      (should (equal 2 (cdar calls)))                         ; non-zero exit parsed

      ;; Missing param -> exit is nil, hook still fires
      (setq calls nil)
      (ghostel--osc133-marker "A" nil)
      (ghostel--osc133-marker "D" nil)
      (should (equal 1 (length calls)))                       ; hook fired with nil param
      (should (null (cdar calls))))))                         ; exit is nil

(ert-deftest ghostel-test-command-finish-hook-via-vt ()
  "End-to-end: OSC 133 D bytes through VT parser fires the hook."
  (let ((buf (generate-new-buffer " *ghostel-test-finish-vt*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (calls nil)
                 (ghostel-command-finish-functions
                  (list (lambda (_buf exit) (push exit calls)))))
            (ghostel--write-input term "\e]133;A\e\\$ \e]133;B\e\\")
            (ghostel--write-input term "echo hi\r\nhi\r\n")
            (ghostel--write-input term "\e]133;D;0\e\\")
            (should (equal '(0) calls))                       ; exit code flows through
            (ghostel--write-input term "\e]133;A\e\\$ \e]133;B\e\\")
            (ghostel--write-input term "\e]133;D;127\e\\")
            (should (equal '(127 0) calls))))                  ; non-zero exit flows through
      (kill-buffer buf))))

(ert-deftest ghostel-test-command-finish-hook-error-caught ()
  "Errors in `ghostel-command-finish-functions' are demoted to messages.
Bind `debug-on-error' to nil so we test the production code path
\(under `--batch -Q' Emacs sets `debug-on-error' to t, which
intentionally makes `with-demoted-errors' re-signal so a hook
author's debugger can fire)."
  (with-temp-buffer
    (let ((inhibit-message t)
          (debug-on-error nil)
          (ghostel-command-finish-functions
           (list (lambda (_buf _exit) (error "Boom")))))
      (ghostel--osc133-marker "A" nil)
      (should-not (condition-case _ (progn (ghostel--osc133-marker "D" "0") nil)
                    (error t))))))

(ert-deftest ghostel-test-command-finish-hook-error-isolated ()
  "A raising hook must not prevent later hooks from running.
See `ghostel-test-command-finish-hook-error-caught' for why we
bind `debug-on-error' to nil."
  (with-temp-buffer
    (let ((inhibit-message t)
          (debug-on-error nil)
          (later-ran nil))
      (let ((ghostel-command-finish-functions
             (list (lambda (_buf _exit) (error "First boom"))
                   (lambda (_buf _exit) (setq later-ran t)))))
        (ghostel--osc133-marker "A" nil)
        (ghostel--osc133-marker "D" "0")
        (should later-ran)))))                                 ; second hook still fired

;; -----------------------------------------------------------------------
;; Test: ghostel-compile--finalize
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-compile-finalize-scans-errors ()
  "`ghostel-compile--finalize' parses errors in the scan region."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "pre-existing line\n")
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point)))
      (insert "/tmp/foo.c:10:5: error: bad thing\n")
      (insert "done\n"))
    (ghostel-compile--finalize buf 1 (current-time))
    (should (eq 1 ghostel-compile--last-exit))                ; exit recorded
    ;; The error line acquired `compilation-message' somewhere within it,
    ;; while the pre-existing (pre-scan-marker) line did not.
    (cl-flet ((region-has-prop-p (begin end prop)
                (save-excursion
                  (goto-char begin)
                  (let ((found nil))
                    (while (and (not found) (< (point) end))
                      (if (get-text-property (point) prop)
                          (setq found t)
                        (goto-char
                         (or (next-single-property-change
                              (point) prop nil end)
                             end))))
                    found))))
      (save-excursion
        (goto-char (point-min))
        (let ((err-bol (progn (search-forward "/tmp/foo.c") (line-beginning-position)))
              (err-eol (line-end-position)))
          (should (region-has-prop-p err-bol err-eol 'compilation-message))))
      (save-excursion
        (goto-char (point-min))
        (let ((pre-bol (progn (search-forward "pre-existing line")
                              (line-beginning-position)))
              (pre-eol (line-end-position)))
          (should-not (region-has-prop-p pre-bol pre-eol 'compilation-message)))))
    (should (eq buf next-error-last-buffer))))                ; next-error target set

(ert-deftest ghostel-test-compile-finalize-appends-footer ()
  "Finalize appends the plain-text footer matching `M-x compile' format.
The header is pre-rendered into the VT terminal by `--start' before
the process spawns, so finalize only has to append the footer and
parse errors below the scan marker.  This unit test simulates that
pre-rendered state by inserting the header directly into the buffer."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil))
      (insert "-*- mode: ghostel-compile -*-\n"
              "Compilation started at fake-time\n\n"
              "make -j4 test\n")
      (setq ghostel-compile--command "make -j4 test"
            ghostel-compile--start-time (time-subtract (current-time) 2)
            ghostel-compile--scan-marker (copy-marker (point)))
      (insert "output line\n")
      (ghostel-compile--finalize buf 0 (current-time))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        ;; Pre-rendered header is still there, exactly once.
        (should (= 1 (cl-count-if (lambda (line)
                                    (string-match-p "-\\*- mode:" line))
                                  (split-string text "\n"))))
        (should (string-match-p "make -j4 test" text))
        (should (string-match-p "output line" text))
        ;; Footer was appended by finalize.
        (should (string-match-p "Compilation finished at" text))
        (should (string-match-p "duration " text))))))

(ert-deftest ghostel-test-compile-finalize-footer-on-failure ()
  "Non-zero exit produces an \"exited abnormally\" footer in buffer text."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil))
      (insert "boom\n")
      (setq ghostel-compile--command "false"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-min)))
      (ghostel-compile--finalize buf 2 (current-time))
      (should (string-match-p
               "exited abnormally with code 2"
               (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest ghostel-test-compile-finalize-trims-trailing-blank-rows ()
  "Regression: short commands leave a mostly-empty terminal grid.
The ghostel renderer commits ~24 grid rows regardless of how much
output the command produced, so `echo test' would otherwise end up
with the footer ~20 rows below the real output.  Finalize must
trim those trailing blank rows — ending the run with a single
blank separator line before the footer matches `M-x compile'."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil))
      (setq ghostel-compile--command "echo test"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max)))
      ;; Simulate what the grid commits: short output plus ~20
      ;; whitespace-only rows from unused terminal lines.
      (insert "test\n")
      (dotimes (_ 20) (insert "                                     \n"))
      (ghostel-compile--finalize buf 0 (current-time))
      ;; Between the real output line "test" and "Compilation
      ;; finished" there must be at most one blank line (i.e. at most
      ;; two newlines) — not the ~20 trailing grid rows we seeded.
      (goto-char (point-min))
      (re-search-forward "^test$")                              ; real output
      (let ((after-test (point)))
        (re-search-forward "Compilation finished at")
        (goto-char (match-beginning 0))
        (let ((gap (buffer-substring-no-properties after-test (point))))
          (should (<= (cl-count ?\n gap) 2)))))))

(ert-deftest ghostel-test-command-finish-hook-runs-synchronously ()
  "Regression: `ghostel-command-finish-functions' must fire synchronously.
They run inside `ghostel--osc133-marker', not deferred via timers.
Downstream consumers (notably `ghostel-compile') depend on it."
  (let ((ran nil))
    (let ((ghostel-command-finish-functions
           (list (lambda (_b _e) (setq ran t)))))
      (ghostel--osc133-marker "D" "0")
      (should ran))))                                          ; in-stack call

(ert-deftest ghostel-test-command-start-hook-runs-synchronously ()
  "Regression: `ghostel-command-start-functions' must fire synchronously."
  (let ((ran nil))
    (let ((ghostel-command-start-functions
           (list (lambda (_b) (setq ran t)))))
      (ghostel--osc133-marker "C" nil)
      (should ran))))                                          ; in-stack call

(ert-deftest ghostel-test-compile-finalize-colors-errors ()
  "After finalize, error lines carry `compilation-line-number' / error faces."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max)))
      (insert "/tmp/x.c:42:5: error: bad\n"))
    (ghostel-compile--finalize buf 1 (current-time))
    ;; Force font-lock to apply faces.  Older compile.el (Emacs
    ;; 28.x) relies on font-lock keywords to set
    ;; `compilation-line-number' / `compilation-error' faces, so
    ;; in batch mode (no `font-lock-mode' active) the digits stay
    ;; bare unless we explicitly fontify.  Modern compile.el
    ;; (Emacs 30+) puts the properties directly via
    ;; `compilation--put-prop' and doesn't need this — but
    ;; calling `font-lock-ensure' is harmless there.
    (font-lock-ensure (point-min) (point-max))
    ;; The file-name region should carry either a `compilation-message'
    ;; text property or `compilation-error' face via font-lock-face.
    ;; Scan the whole `/tmp/x.c' match instead of pinning a point,
    ;; since compile.el's exact boundaries differ across Emacs versions.
    (goto-char (point-min))
    (re-search-forward "\\(/tmp/x\\.c\\):")
    (let ((file-start (match-beginning 1))
          (file-end (match-end 1))
          (ok nil))
      (save-excursion
        (goto-char file-start)
        (while (and (not ok) (< (point) file-end))
          (when (or (get-text-property (point) 'compilation-message)
                    (memq 'compilation-error
                          (ensure-list (get-text-property
                                        (point) 'font-lock-face))))
            (setq ok t))
          (forward-char 1)))
      (should ok))
    ;; Find the `42' (line-number) digits and check any position in
    ;; that range carries `compilation-line-number' via font-lock-face.
    ;; The exact boundary compile.el uses for line-number face has
    ;; wobbled across Emacs versions (29.x vs master), so scan the
    ;; region instead of pinning a single position.
    (goto-char (point-min))
    (re-search-forward ":\\(42\\):")
    (let ((ln-start (match-beginning 1))
          (ln-end (match-end 1))
          (found nil))
      (save-excursion
        (goto-char ln-start)
        (while (and (not found) (< (point) ln-end))
          (let ((face (ensure-list (get-text-property (point) 'font-lock-face))))
            (when (memq 'compilation-line-number face)
              (setq found t)))
          (forward-char 1)))
      (should found))))

(ert-deftest ghostel-test-compile-finalize-preserves-face-props ()
  "Baked-in per-cell `face' text-properties must survive the mode transition.
The transition is from the live ghostel run into `ghostel-compile-view-mode'.
`compilation-mode' installs font-lock keywords for error highlighting,
and the default `font-lock-unfontify-region-function' strips every
`face' property — wiping the colour of the recorded output on the first
JIT-lock pass.  `ghostel-compile-view-mode' installs a buffer-local
`#'ignore' override to preserve those props."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max)))
      (insert (propertize "RED" 'face '(:foreground "#ff0000")))
      (insert " output\n/tmp/x.c:42:5: error: bad\n"))
    (ghostel-compile--finalize buf 1 (current-time))
    (font-lock-ensure (point-min) (point-max))
    ;; The ghostel-painted face on "RED" must still be present.
    (goto-char (point-min))
    (re-search-forward "RED")
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (should face)
      (should (equal "#ff0000" (plist-get face :foreground))))))

(ert-deftest ghostel-test-compile-finalize-does-not-double-count-errors ()
  "Regression: parsing must not count each error twice.

Using `compilation-parse-errors' directly does not advance
`compilation--parsed', so jit-lock would re-scan and double the
error count.  `compilation--ensure-parse' is the right entry point."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "/tmp/a.c:1:1: error: oops\n"
              "/tmp/b.c:2:2: error: oops\n")
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-min))))
    (ghostel-compile--finalize buf 1 (current-time))
    (should (= 2 compilation-num-errors-found))))             ; not 4

(ert-deftest ghostel-test-compile-finalize-does-not-kill-buffer ()
  "Regression: finalize must not let `ghostel--sentinel' kill the buffer.

Previously, teardown called `delete-process' with the ghostel sentinel
still attached; the sentinel would then invoke `kill-buffer' because
`ghostel-kill-buffer-on-exit' defaults to t.  The visible symptom is a
compile buffer that flashes open and disappears."
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf (generate-new-buffer " *ghostel-test-compile-live*"))
         (inhibit-message t)
         proc)
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq proc (start-process "gh-compile-dummy" buf
                                    "/bin/sh" "-c" "sleep 5"))
          (set-process-query-on-exit-flag proc nil)
          (set-process-sentinel proc #'ghostel--sentinel)
          (setq-local ghostel--process proc
                      ghostel-compile--command "sleep 5"
                      ghostel-compile--start-time (current-time)
                      ghostel-compile--scan-marker (copy-marker (point-max)))
          ;; Finalize with a real process attached: must NOT kill the
          ;; buffer AND must NOT insert the default sentinel's
          ;; "Process NAME killed: N" line into it.
          (ghostel-compile--finalize buf 0 (current-time))
          (should (buffer-live-p buf))                         ; buffer survived
          (should-not (process-live-p proc))                   ; process was stopped
          (should-not (string-match-p
                       "Process .*killed"
                       (buffer-substring-no-properties
                        (point-min) (point-max)))))            ; no noise text
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest ghostel-test-compile-view-mode-n-p-navigate-without-opening ()
  "`n'/`p' walk errors in the buffer without opening source files.
The user wants `n'/`p' to behave like `M-n'/`M-p' in `compilation-mode' —
move point through compile messages without auto-opening files in
another window.  RET/`compile-goto-error' is for opening."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      ;; Simulate the pre-rendered header, then errors below it —
      ;; matches the geometry the real flow leaves for `--finalize'.
      (insert "-*- mode: ghostel-compile -*-\n"
              "Compilation started at fake-time\n\n"
              "make\n")
      (setq ghostel-compile--command "make"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point)))
      (insert "/tmp/aa.c:1:1: error: first\n"
              "blah\n"
              "/tmp/bb.c:2:2: error: second\n"))
    (ghostel-compile--finalize buf 1 (current-time))
    ;; n/p should map to the navigation-only commands (no file open).
    (should (eq (lookup-key (current-local-map) "n")
                #'compilation-next-error))
    (should (eq (lookup-key (current-local-map) "p")
                #'compilation-previous-error))
    ;; Walking n twice must visit BOTH error lines, never opening files.
    (let ((opened nil))
      (cl-letf (((symbol-function 'compilation-find-file)
                 (lambda (&rest _) (setq opened t)
                   (current-buffer))))
        (goto-char (point-min))
        (compilation-next-error 1)
        (let ((p1 (point)))
          (should (save-excursion
                    (beginning-of-line)
                    (looking-at "/tmp/aa\\.c")))
          (compilation-next-error 1)
          (should (/= p1 (point)))                            ; point moved
          (should (save-excursion
                    (beginning-of-line)
                    (looking-at "/tmp/bb\\.c"))))
        (should-not opened)))))                              ; no file opened

(ert-deftest ghostel-test-compile-finalize-leaves-point-at-end ()
  "Regression: finalize must put point at `point-max', past the footer.
The \"Compilation finished at ..., duration ...\" line must be visible
when the window recenters to the bottom.  Point at the start of the
footer (or at the end of output before the footer) leaves the footer
scrolled below the window."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t))
      (insert "line A\nline B\nline C\n")
      (goto-char (point-max))
      (setq ghostel-compile--command "true"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-min))))
    (ghostel-compile--finalize buf 0 (current-time))
    (should (= (point) (point-max)))                           ; past footer
    ;; And the footer text really is the last thing in the buffer.
    (should (string-match-p
             "Compilation finished at.*duration"
             (buffer-substring-no-properties
              (max (point-min) (- (point-max) 200))
              (point-max))))))

(ert-deftest ghostel-test-compile-finalize-switches-major-mode ()
  "With the default option, finalize switches to `ghostel-compile-view-mode'."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-compile--command "true"
          ghostel-compile--start-time (current-time)
          ghostel-compile--scan-marker (copy-marker (point-max)))
    (should (derived-mode-p 'ghostel-mode))                    ; starts as ghostel
    (ghostel-compile--finalize buf 0 (current-time))
    (should (derived-mode-p 'ghostel-compile-view-mode))        ; switched
    (should (derived-mode-p 'compilation-mode))                 ; inherits compile
    (should-not (derived-mode-p 'ghostel-mode))                 ; not ghostel anymore
    (should buffer-read-only)                                   ; read-only
    (should (eq next-error-function #'compilation-next-error-function))
    (should (equal "true" ghostel-compile--command))))          ; state preserved

(ert-deftest ghostel-test-compile-view-mode-recompile-key-binding ()
  "`g' in `ghostel-compile-view-mode-map' is bound to `ghostel-recompile'."
  (should (eq (lookup-key ghostel-compile-view-mode-map (kbd "g"))
              #'ghostel-recompile)))

(ert-deftest ghostel-test-compile-format-duration ()
  "Duration formatting matches `M-x compile's style."
  (should (equal "0.50 s"  (ghostel-compile--format-duration 0.5)))
  (should (equal "5.00 s"  (ghostel-compile--format-duration 5)))
  (should (equal "30.0 s"  (ghostel-compile--format-duration 30)))
  (should (equal "0:02:05" (ghostel-compile--format-duration 125)))
  (should (equal "1:01:05" (ghostel-compile--format-duration 3665))))

(ert-deftest ghostel-test-compile-status-message ()
  "Status message strings match `M-x compile' conventions."
  (should (equal "finished\n" (ghostel-compile--status-message 0)))
  (should (equal "exited abnormally with code 2\n"
                 (ghostel-compile--status-message 2)))
  (should (equal "finished\n" (ghostel-compile--status-message nil))))

(ert-deftest ghostel-test-compile-mode-line-running ()
  "`ghostel-compile--set-mode-line-running' sets `:run' with run face."
  (with-temp-buffer
    (ghostel-compile--set-mode-line-running)
    ;; Expect (:propertize ":run" face compilation-mode-line-run) as head.
    (let ((head (car mode-line-process)))
      (should (eq :propertize (car head)))
      (should (equal ":run" (cadr head)))
      (should (eq 'compilation-mode-line-run
                  (plist-get (cddr head) 'face))))))

(ert-deftest ghostel-test-compile-mode-line-exit ()
  "`ghostel-compile--set-mode-line-exit' uses exit/fail face for 0/non-zero."
  (with-temp-buffer
    (ghostel-compile--set-mode-line-exit 0)
    (let* ((first (car mode-line-process)))
      (should (string-match-p "exit \\[0\\]" first))
      (should (eq 'compilation-mode-line-exit
                  (get-text-property 0 'face first))))
    (ghostel-compile--set-mode-line-exit 1)
    (let* ((first (car mode-line-process)))
      (should (string-match-p "exit \\[1\\]" first))
      (should (eq 'compilation-mode-line-fail
                  (get-text-property 0 'face first))))))

(ert-deftest ghostel-test-compile-finish-hooks-fire ()
  "Both `ghostel-compile-finish-functions' and `compilation-finish-functions' run."
  (ghostel-test--with-compile-buffer buf
    (let* ((ghostel-compile-finished-major-mode nil)
           (g-calls nil)
           (c-calls nil)
           (ghostel-compile-finish-functions
            (list (lambda (b m) (push (cons b m) g-calls))))
           (compilation-finish-functions
            (list (lambda (b m) (push (cons b m) c-calls)))))
      (setq ghostel-compile--command "true"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-max)))
      (ghostel-compile--finalize buf 0 (current-time))
      (should (equal 1 (length g-calls)))                     ; ghostel hook
      (should (eq buf (caar g-calls)))
      (should (equal "finished\n" (cdar g-calls)))
      (should (equal 1 (length c-calls)))                     ; compile hook
      (should (equal "finished\n" (cdar c-calls))))))

(ert-deftest ghostel-test-compile-auto-jump-to-first-error ()
  "With `compilation-auto-jump-to-first-error' set, jump after parsing."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil)
          (compilation-auto-jump-to-first-error t)
          (jumped nil))
      (cl-letf (((symbol-function 'first-error)
                 (lambda (&rest _) (setq jumped t))))
        (setq ghostel-compile--command "make"
              ghostel-compile--start-time (current-time)
              ghostel-compile--scan-marker (copy-marker (point-max)))
        (insert "/tmp/x.c:1:1: error: boom\n")
        (ghostel-compile--finalize buf 1 (current-time))
        (should jumped)))))                                    ; first-error called

(ert-deftest ghostel-test-compile-recompile-uses-original-directory ()
  "`ghostel-recompile' must pass the original `default-directory' to --start.

The user's report: run `ghostel-compile' in /A, switch to a buffer
in /B, switch back, press `g'.  The saved per-buffer directory must
be what `--start' receives."
  (let ((dir-at-call nil)
        (buf (generate-new-buffer " *ghostel-test-recompile-dir*"))
        (inhibit-message t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Simulate the post-finalize state of a previous run.
          (setq ghostel-compile--command "make"
                ghostel-compile--directory "/some/project/")
          (cl-letf (((symbol-function 'ghostel-compile--start)
                     (lambda (_cmd _name dir) (setq dir-at-call dir))))
            ;; Recompile from a buffer whose default-directory is somewhere else.
            (let ((default-directory "/elsewhere/"))
              (ghostel-recompile))
            (should (equal "/some/project/" dir-at-call))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-compile-recompile-reuses-current-buffer ()
  "`ghostel-recompile' from a ghostel-compile buffer re-runs into it.

When the user presses `g' in `*compilation*' (via global-mode) or
any buffer whose `ghostel-compile--command' is set locally, the
rerun must target the SAME buffer — not the default
`ghostel-compile-buffer-name' — so the existing window isn't
displaced by a new one."
  (let ((name-at-call nil)
        (buf (generate-new-buffer "*some-specific-name*"))
        (inhibit-message t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel-compile--command "make"
                ghostel-compile--directory "/proj/")
          (cl-letf (((symbol-function 'ghostel-compile--start)
                     (lambda (_cmd name _dir) (setq name-at-call name))))
            (ghostel-recompile))
          ;; Buffer-name of the CURRENT buffer, not `ghostel-compile-buffer-name'.
          (should (equal "*some-specific-name*" name-at-call)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-compile-recompile-edit-command-prefix-arg ()
  "`ghostel-recompile' with a prefix arg prompts for the command to run.
When EDIT-COMMAND is non-nil it must prompt for the command and run the
edited version, matching the behaviour of \\[recompile]."
  (let ((buf (generate-new-buffer " *ghostel-test-recompile-edit*"))
        (inhibit-message t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel-compile--command "make old"
                ghostel-compile--directory "/some/project/")
          (let ((cmd-at-call nil)
                (prompt-default nil))
            (cl-letf (((symbol-function 'ghostel-compile--start)
                       (lambda (cmd _name _dir) (setq cmd-at-call cmd)))
                      ((symbol-function 'read-shell-command)
                       (lambda (_prompt default &rest _)
                         (setq prompt-default default)
                         "make new")))
              ;; With edit-command t: user is prompted, runs edited cmd.
              (ghostel-recompile t)
              (should (equal "make old" prompt-default))        ; default was the last cmd
              (should (equal "make new" cmd-at-call)))           ; chosen cmd is used
            ;; Without the prefix: no prompt, runs the last cmd verbatim.
            (setq cmd-at-call nil prompt-default nil)
            (cl-letf (((symbol-function 'ghostel-compile--start)
                       (lambda (cmd _name _dir) (setq cmd-at-call cmd)))
                      ((symbol-function 'read-shell-command)
                       (lambda (&rest _) (setq prompt-default t) "never")))
              (ghostel-recompile)
              (should-not prompt-default)                        ; no prompt
              (should (equal "make old" cmd-at-call)))))         ; last cmd re-run
      (kill-buffer buf))))

(ert-deftest ghostel-test-compile-finalize-pins-default-directory ()
  "Finalize must pin `default-directory' to the captured value.
Even if the shell drifted via OSC 7 or the user customized things,
the resulting `view-mode' buffer should report its compile directory
so `ghostel-recompile' (and other tooling) can rely on it."
  (ghostel-test--with-compile-buffer buf
    (setq ghostel-compile--command "make"
          ghostel-compile--directory "/pinned/dir/"
          ghostel-compile--start-time (current-time)
          ghostel-compile--scan-marker (copy-marker (point-max)))
    (setq default-directory "/drifted/somewhere/")
    (ghostel-compile--finalize buf 0 (current-time))
    (should (equal "/pinned/dir/" default-directory))         ; pinned back
    (should (equal "/pinned/dir/" ghostel-compile--directory))))

(ert-deftest ghostel-test-compile-recompile-without-history ()
  "`ghostel-recompile' errors cleanly when nothing has been compiled."
  (let ((compile-command ""))
    (when-let* ((buf (get-buffer ghostel-compile-buffer-name)))
      (kill-buffer buf))
    (should-error (ghostel-recompile) :type 'user-error)))

(ert-deftest ghostel-test-compile-uses-compile-command ()
  "`ghostel-compile' persists the run command to `compile-command'."
  (let ((compile-command "make old"))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) nil))
              ((symbol-function 'save-some-buffers)
               (lambda (&rest _) nil)))
      (ghostel-compile "make new")
      (should (equal "make new" compile-command)))))         ; persisted

(ert-deftest ghostel-test-compile-interactive-uses-compile-history ()
  "`ghostel-compile's prompt uses `compile-history' as the history list."
  (let ((captured nil)
        (compile-history '("old-cmd"))
        (compile-command "make default")
        (compilation-read-command t))
    (cl-letf (((symbol-function 'read-shell-command)
               (lambda (_prompt _default hist-sym &rest _)
                 (setq captured hist-sym)
                 "chosen-cmd"))
              ((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) nil))
              ((symbol-function 'save-some-buffers)
               (lambda (&rest _) nil)))
      (call-interactively #'ghostel-compile)
      ;; History symbol should be (or directly reference) `compile-history'.
      (should (or (eq captured 'compile-history)
                  (and (consp captured)
                       (eq (car captured) 'compile-history)))))))

(ert-deftest ghostel-test-compile-respects-compilation-read-command ()
  "When option `compilation-read-command' is nil, use `compile-command' silently."
  (let ((prompted nil)
        (captured-cmd nil)
        (compile-command "make -C /tmp silent")
        (compilation-read-command nil))
    (cl-letf (((symbol-function 'read-shell-command)
               (lambda (&rest _) (setq prompted t) "never"))
              ((symbol-function 'ghostel-compile--start)
               (lambda (cmd &rest _) (setq captured-cmd cmd) nil))
              ((symbol-function 'save-some-buffers)
               (lambda (&rest _) nil)))
      (call-interactively #'ghostel-compile)
      (should-not prompted)                                    ; no prompt
      (should (equal "make -C /tmp silent" captured-cmd)))))   ; used as-is

(ert-deftest ghostel-test-compile-prepare-buffer-no-window-side-effects ()
  "`ghostel-compile--prepare-buffer' must not touch the caller's window state.
Specifically, it must not change the selected window or mutate its
`window-prev-buffers' history while creating the buffer."
  (let* ((name "*ghostel-test-create*")
         (origin (generate-new-buffer " *ghostel-test-origin*"))
         (saved (current-window-configuration)))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer origin)
          (with-current-buffer origin
            (setq-local default-directory "/tmp/"))
          (let ((start-window (selected-window))
                (start-prev (mapcar #'car (window-prev-buffers)))
                created)
            (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                      ((symbol-function 'ghostel--new)
                       (lambda (&rest _) 'fake-term))
                      ((symbol-function 'ghostel--apply-palette) #'ignore)
                      ((symbol-function 'ghostel--start-process) #'ignore))
              (setq created (ghostel-compile--prepare-buffer name "/tmp/")))
            ;; Buffer was created, named, and initialized.
            (should (buffer-live-p created))
            (should (equal (buffer-name created) name))
            (should (with-current-buffer created
                      (derived-mode-p 'ghostel-mode)))
            ;; Caller-supplied `default-directory' was carried into it.
            (should (equal (buffer-local-value 'default-directory created)
                           "/tmp/"))
            ;; Caller's window and buffer are unchanged.
            (should (eq (selected-window) start-window))
            (should (eq (window-buffer start-window) origin))
            ;; The compile buffer was never popped into the caller's
            ;; window — so it does NOT appear in `window-prev-buffers'.
            (should-not (memq created
                              (mapcar #'car (window-prev-buffers start-window))))
            (should (equal start-prev
                           (mapcar #'car (window-prev-buffers start-window))))))
      (when (get-buffer "*ghostel-test-create*")
        (let ((kill-buffer-query-functions nil))
          (kill-buffer "*ghostel-test-create*")))
      (when (buffer-live-p origin) (kill-buffer origin))
      (set-window-configuration saved))))

(ert-deftest ghostel-test-compile-finalize-is-idempotent ()
  "Calling `ghostel-compile--finalize' twice must not double-insert."
  (ghostel-test--with-compile-buffer buf
    (let ((inhibit-read-only t)
          (ghostel-compile-finished-major-mode nil))
      (insert "output\n")
      (setq ghostel-compile--command "true"
            ghostel-compile--start-time (current-time)
            ghostel-compile--scan-marker (copy-marker (point-min))))
    (ghostel-compile--finalize buf 0 (current-time))
    (let ((after-first (buffer-string)))
      ;; Second call is a no-op thanks to `--finalized'.
      (ghostel-compile--finalize buf 0 (current-time))
      (should (equal after-first (buffer-string))))))

(ert-deftest ghostel-test-compile-global-mode-toggles-advice ()
  "Enabling and disabling `ghostel-compile-global-mode' adds/removes the advice."
  (let ((ghostel-compile-global-mode nil))
    (unwind-protect
        (progn
          (ghostel-compile-global-mode 1)
          (should (advice-member-p
                   #'ghostel-compile--compilation-start-advice
                   'compilation-start))
          (ghostel-compile-global-mode -1)
          (should-not (advice-member-p
                       #'ghostel-compile--compilation-start-advice
                       'compilation-start)))
      (ghostel-compile-global-mode -1))))

(ert-deftest ghostel-test-compile-global-mode-falls-through-for-grep ()
  "`grep-mode' must fall through to the stock `compilation-start'."
  (let ((orig-called nil)
        (ghostel-called nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) (setq ghostel-called t) nil)))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (setq orig-called t) nil)
       "grep foo" 'grep-mode nil nil nil))
    (should orig-called)                                        ; stock path ran
    (should-not ghostel-called)))                              ; ours did not

(ert-deftest ghostel-test-compile-global-mode-routes-to-ghostel-start ()
  "For supported modes, the advice routes COMMAND through `ghostel-compile--start'."
  (let ((captured nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (cmd name dir &optional _finished-mode)
                 (setq captured (list cmd name dir))
                 (generate-new-buffer " *ghostel-test-advice*"))))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (error "Stock path should not run"))
       "make test" nil nil nil nil))
    (should (equal "make test" (nth 0 captured)))              ; command preserved
    ;; Default buffer name for `compilation-mode' is "*compilation*".
    (should (string-match-p "compilation" (nth 1 captured)))))

(ert-deftest ghostel-test-compile-global-mode-threads-subclass-mode ()
  "A custom compile-mode subclass passed as MODE is forwarded to finalize.

The advice must pass a non-`compilation-mode' MODE through to
`ghostel-compile--start' as its FINISHED-MODE argument so the
subclass (with its error-regexp, font-lock keywords, etc.) is the
major mode the buffer ends up in after finalize — and *not*
override with the default `ghostel-compile-view-mode'."
  (let ((captured-finished nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (_cmd _name _dir &optional finished-mode)
                 (setq captured-finished finished-mode)
                 nil)))
      ;; Custom mode → threaded through.
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (error "Stock path should not run"))
       "make" 'my-custom-compile-mode nil nil nil)
      (should (eq 'my-custom-compile-mode captured-finished))
      ;; Plain `compilation-mode' → nil (default view-mode kicks in).
      (setq captured-finished :unchanged)
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (error "Stock path should not run"))
       "make" 'compilation-mode nil nil nil)
      (should-not captured-finished))))

(ert-deftest ghostel-test-compile-global-mode-falls-through-on-continue ()
  "Non-nil CONTINUE must fall through: `--start' recreates the buffer."
  (let ((orig-called nil)
        (ghostel-called nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) (setq ghostel-called t) nil)))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (setq orig-called t) nil)
       "make" 'compilation-mode nil nil t))         ; continue=t
    (should orig-called)
    (should-not ghostel-called)))

(ert-deftest ghostel-test-compile-global-mode-falls-through-on-comint ()
  "MODE=t (comint) must fall through."
  (let ((orig-called nil))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) (error "Should not run"))))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (setq orig-called t) nil)
       "make" t nil nil nil))
    (should orig-called)))

(ert-deftest ghostel-test-compile-global-mode-excluded-custom-mode ()
  "A custom mode added to `ghostel-compile-global-mode-excluded-modes' falls through."
  (let ((orig-called nil)
        (ghostel-compile-global-mode-excluded-modes '(my-fake-grep-mode)))
    (cl-letf (((symbol-function 'ghostel-compile--start)
               (lambda (&rest _) (error "Ghostel path should not run"))))
      (ghostel-compile--compilation-start-advice
       (lambda (&rest _) (setq orig-called t) nil)
       "whatever" 'my-fake-grep-mode nil nil nil))
    (should orig-called)))

(ert-deftest ghostel-test-compile-allows-interactive-input-during-run ()
  "Regression: during a run the buffer must be interactive.

`ghostel-compile--start' must not enable `compilation-minor-mode'
on the live buffer — that minor mode's keymap shadows
`ghostel-mode's self-insert, so letters like `q', `a', `g' would
stop reaching the process (breaking `htop', `less', read prompts
etc.).  And `--spawn' must set `ghostel--process' so
`ghostel--self-insert' has a process to send keystrokes to.

Run a long-lived `cat', verify both conditions, then send bytes
through the process to confirm they land in the buffer."
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-interactive-compile*")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (let ((buf (ghostel-compile--start "cat" buf-name default-directory)))
          (with-current-buffer buf
            ;; Wait for the process to be alive.
            (ghostel-test--wait-for
             ghostel--process
             (lambda () (eq 'run (process-status ghostel--process))))
            ;; The live buffer must be plain `ghostel-mode' — no compile
            ;; minor mode stealing keys.
            (should (eq major-mode 'ghostel-mode))
            (should-not (bound-and-true-p compilation-minor-mode))
            ;; Plain letters route through ghostel-mode's self-insert,
            ;; not through compilation-mode's navigation commands.
            (should (eq (key-binding "q") #'ghostel--self-insert))
            (should (eq (key-binding "a") #'ghostel--self-insert))
            ;; `ghostel--process' is populated, so `ghostel--self-insert'
            ;; has a process to send to.
            (should (process-live-p ghostel--process))
            ;; Round-trip: send a line, expect it back (cat echoes stdin).
            (process-send-string ghostel--process "ghosttel-ping\n")
            (ghostel-test--wait-for
             ghostel--process
             (lambda ()
               (cl-some (lambda (s) (string-match-p "ghosttel-ping" s))
                        ghostel--pending-output)))
            ;; Shut cat down so the test doesn't leak a process.
            (process-send-eof ghostel--process)
            (ghostel-test--wait-for
             ghostel--process
             (lambda () ghostel-compile--finalized) 10)))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-multiline-end-to-end ()
  "A multi-line shell paragraph must run intact under `ghostel-compile'.
The paragraph must land in the buffer unmangled and the run must
report the real exit status.

This is the end-to-end proof for the core PR change: the old design
typed the command into a live shell and each embedded newline was
parsed as a RET press, mangling multi-line scripts.  The new design
spawns `sh -c COMMAND' directly, so the shell parses the paragraph
normally."
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-multiline-compile*")
         (shell-file-name "/bin/sh")
         (script "for i in 1 2 3; do\n  echo line-$i\ndone\nexit 7")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil)))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (let ((buf (ghostel-compile--start script buf-name
                                           default-directory)))
          (with-current-buffer buf
            (ghostel-test--wait-for
             ghostel--process
             (lambda () ghostel-compile--finalized)
             10)
            (should (equal 7 ghostel-compile--last-exit))
            (let ((text (buffer-substring-no-properties
                         (point-min) (point-max))))
              (should (string-match-p "line-1" text))
              (should (string-match-p "line-2" text))
              (should (string-match-p "line-3" text))
              (should (string-match-p "exited abnormally with code 7" text)))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-reconciles-vt-size-to-outwin ()
  "`ghostel-compile--start' must resize the VT to the output window.

`prepare-buffer' sizes the VT from the selected window (the only
dimensions available before `display-buffer').  If the compile
buffer ends up in a smaller window, the PTY's `set-process-window-size'
agrees with the output window but the VT still thinks it has the
width of the selected window, so early output wraps at the wrong column.
`--start' must call `ghostel--set-size' with the output-window
dimensions *before* rendering the header, and `--spawn' must receive
the same dimensions so PTY and VT always agree."
  (let* ((buf-name "*ghostel-test-compile-size*")
         (set-size-calls nil)
         (spawn-calls nil)
         (call-order nil)
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (cl-letf* (((symbol-function 'ghostel--load-module) #'ignore)
                   ((symbol-function 'ghostel--new)
                    (lambda (&rest _) 'fake-term))
                   ((symbol-function 'ghostel--apply-palette) #'ignore)
                   ((symbol-function 'ghostel--set-size)
                    (lambda (_term rows cols)
                      (push 'set-size call-order)
                      (push (list rows cols) set-size-calls)))
                   ((symbol-function 'ghostel-compile--render-header-live)
                    (lambda (&rest _) (push 'render-header call-order)))
                   ((symbol-function 'ghostel--cursor-position)
                    (lambda (_term) (cons 0 0)))
                   ((symbol-function 'ghostel-compile--spawn)
                    (lambda (_cmd buf h w)
                      (push 'spawn call-order)
                      (push (list h w) spawn-calls)
                      (let ((p (start-process "ghostel-test-size-fake"
                                              buf "sleep" "100")))
                        (set-process-sentinel p #'ignore)
                        (set-process-query-on-exit-flag p nil)
                        (with-current-buffer buf
                          (setq ghostel--process p))
                        p))))
          (let ((buf (ghostel-compile--start "true" buf-name
                                             default-directory)))
            (with-current-buffer buf
              ;; The reconcile call happened.
              (should set-size-calls)
              ;; Reconcile must precede the header render *and* the spawn —
              ;; otherwise the header / early command output wraps at the
              ;; pre-reconcile column.  `call-order' is LIFO, so chronological
              ;; order is the reverse.
              (let ((chronological (reverse call-order)))
                (should (equal chronological
                               '(set-size render-header spawn))))
              ;; Final VT size equals what was handed to the process.
              (let ((vt-size (car set-size-calls))
                    (pty-size (car spawn-calls)))
                (should (equal vt-size pty-size)))
              ;; `ghostel--term-rows' tracks the final reconciled height.
              (should (= (car (car set-size-calls)) ghostel--term-rows))
              ;; Clean up the fake process.
              (let ((p ghostel--process))
                (when (process-live-p p)
                  (setq compilation-in-progress
                        (delq p compilation-in-progress))
                  (delete-process p))))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-reconciles-skips-when-no-outwin ()
  "If `display-buffer' returns nil, reconcile is skipped safely.
`allow-no-window' permits `display-buffer' to choose not to show the
buffer at all.  The `(when (and outwin ...))' guard in `--start' must
gate the `ghostel--set-size' call so we don't crash or pass bogus
dimensions when no output window exists."
  (let* ((buf-name "*ghostel-test-compile-no-outwin*")
         (set-size-called nil)
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (cl-letf* (((symbol-function 'ghostel--load-module) #'ignore)
                   ((symbol-function 'ghostel--new)
                    (lambda (&rest _) 'fake-term))
                   ((symbol-function 'ghostel--apply-palette) #'ignore)
                   ((symbol-function 'display-buffer) (lambda (&rest _) nil))
                   ((symbol-function 'ghostel--set-size)
                    (lambda (&rest _) (setq set-size-called t)))
                   ((symbol-function 'ghostel-compile--render-header-live)
                    #'ignore)
                   ((symbol-function 'ghostel--cursor-position)
                    (lambda (_term) (cons 0 0)))
                   ((symbol-function 'ghostel-compile--spawn)
                    (lambda (_cmd buf _h _w)
                      (let ((p (start-process "ghostel-test-nowin-fake"
                                              buf "sleep" "100")))
                        (set-process-sentinel p #'ignore)
                        (set-process-query-on-exit-flag p nil)
                        (with-current-buffer buf
                          (setq ghostel--process p))
                        p))))
          (let ((buf (ghostel-compile--start "true" buf-name
                                             default-directory)))
            (should (buffer-live-p buf))
            (should-not set-size-called)
            (with-current-buffer buf
              (let ((p ghostel--process))
                (when (process-live-p p)
                  (setq compilation-in-progress
                        (delq p compilation-in-progress))
                  (delete-process p))))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

(ert-deftest ghostel-test-compile-kill-compilation-finds-live-buffer ()
  "`kill-compilation' must locate a live ghostel-compile buffer.

During the run the buffer stays in `ghostel-mode' so keystrokes reach
the process, which means `compilation-mode' never runs.  `kill-compilation'
calls `compilation-find-buffer' -> `compilation-buffer-internal-p',
which is `(local-variable-p 'compilation-locs)'.  `prepare-buffer' must
declare that variable buffer-locally so the live buffer qualifies."
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf-name "*ghostel-test-kill-compilation*")
         (inhibit-message t)
         (save-some-buffers-default-predicate (lambda () nil))
         (ghostel-compile-finished-major-mode nil))
    (when (get-buffer buf-name)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf-name)))
    (unwind-protect
        (let ((buf (ghostel-compile--start "cat" buf-name
                                           default-directory)))
          (with-current-buffer buf
            (ghostel-test--wait-for
             ghostel--process
             (lambda () (eq 'run (process-status ghostel--process))))
            ;; The live buffer passes `compilation-buffer-p' — which is
            ;; the gate `kill-compilation' uses.
            (should (compilation-buffer-p buf))
            ;; From inside the buffer, `compilation-find-buffer' returns it.
            (should (eq (compilation-find-buffer) buf))
            ;; Also findable from an arbitrary buffer, via `next-error-find-
            ;; buffer' — that's how `kill-compilation' reaches us when the
            ;; user invokes it from elsewhere.
            (should (with-temp-buffer (eq (compilation-find-buffer) buf)))
            ;; And the buffer has a live process `kill-compilation' would
            ;; deliver SIGINT to.
            (should (process-live-p (get-buffer-process buf)))
            ;; End-to-end: invoke `kill-compilation' from inside the buffer
            ;; and wait for the process to die via SIGINT.  `cat' exits on
            ;; SIGINT, the sentinel finalizes, and `--last-exit' reflects
            ;; a non-zero status (signal-based termination).
            (kill-compilation)
            (ghostel-test--wait-for
             ghostel--process
             (lambda () ghostel-compile--finalized) 10)
            (should ghostel-compile--finalized)
            (should (numberp ghostel-compile--last-exit))
            (should-not (zerop ghostel-compile--last-exit))))
      (when (get-buffer buf-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buf-name))))))

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
  "Resize on alt screen: SIGWINCH-triggered redraw renders correctly.
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
Regression test: fnSetSize used to call `erase-buffer' synchronously,
leaving the buffer visibly empty until the next timer-driven redraw.
Now the erasure is deferred into redraw() under `inhibit-redisplay'."
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
  "After resize + redraw, `window-start' is at the viewport origin.
Without explicit anchoring, erase+rebuild inside redraw() clamps
`window-start' to 1 (top of scrollback), causing a visible jump when
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

(ert-deftest ghostel-test-hidden-buffer-snaps-on-reshow ()
  "Buffer re-shown after output-while-hidden snaps to the viewport (issue #177).
Dispatches through `window-buffer-change-functions' so the hook
wiring — not just `ghostel--reshow-snap' in isolation — is exercised."
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

(ert-deftest ghostel-test-second-window-does-not-disturb-scrollback ()
  "Opening a second window on a ghostel buffer does not yank peer windows.
Issue #177 regression guard for the multi-window case: a window
already scrolled back for reading history must stay put when a new
window opens on the same buffer."
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

;; Declared here so tests can rebind these without byte-compile warnings on
;; non-X/non-PGTK builds where term/x-win.el and term/pgtk-win.el aren't loaded.
(defvar x-preedit-overlay)
(defvar pgtk-preedit-overlay)

(ert-deftest ghostel-test-delayed-redraw-preserves-preedit-anchor ()
  "Active GUI preedit text keeps its point anchor across redraws.
GTK/PGTK input-method candidate windows are anchored to the preedit
overlay at point.  During streaming TUI output, native redraws move
point to the terminal cursor; while preedit text is visible, the
composing window must instead keep the overlay and `window-point' at
the same viewport row and column."
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

(ert-deftest ghostel-test-redraw-anchors-window-start-on-snap-request ()
  "Redraw anchors `window-start' to the viewport when snap is requested.
`ghostel--snap-to-input' sets `ghostel--snap-requested' on typing/paste/
yank/drop.  The next redraw must override a scrolled-up `window-start'
and pull it back to the viewport, then clear the flag."
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

(ert-deftest ghostel-test-clear-scrollback-resets-scroll-state ()
  "`ghostel-clear-scrollback' drops recorded scroll positions.
After the buffer is wiped, the old content no longer exists, so the
next redraw must anchor fresh to the new viewport rather than trying
to restore to a missing line."
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
            (cl-letf (((symbol-function 'ghostel--write-input)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (setq ghostel--process nil)
              (ghostel-clear-scrollback))
            (should-not ghostel--scroll-positions)
            (should-not ghostel--last-anchor-position)))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-copy-mode-exit-resets-scroll-state ()
  "Exiting copy mode drops stale scroll-positions.
Delayed-redraw is short-circuited during copy mode; on exit, whatever
`ghostel--scroll-positions' held is stale.  The exit handler drops it
and requests a snap so the next redraw lands at the live viewport."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-exit*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--copy-mode-active t)
          (setq ghostel--scroll-positions
                (list (cons (selected-window)
                            (list '("stale") '("stale") 0))))
          (setq ghostel--snap-requested nil)
          (setq ghostel--force-next-redraw nil)
          (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                    ((symbol-function 'message) #'ignore))
            (ghostel-copy-mode-exit))
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
  "Test that ghostel-sync-theme reapplies palette and redraw post-processing."
  (let ((palette-calls nil)
        (redraw-calls nil)
        (post-process-calls 0))
    (cl-letf (((symbol-function 'ghostel--apply-palette)
               (lambda (term) (push term palette-calls)))
              ((symbol-function 'ghostel--redraw)
               (lambda (term) (push term redraw-calls)))
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
                (setq ghostel--copy-mode-active nil)
                (setq ghostel-enable-url-detection t))
              ;; `other' is not a ghostel buffer and should be ignored.
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should (memq 'fake-term redraw-calls))
              (should (= post-process-calls 1))

              ;; Verify copy-mode skips redraw.
              (setq palette-calls nil
                    redraw-calls nil
                    post-process-calls 0)
              (with-current-buffer buf
                (setq ghostel--copy-mode-active t))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should-not (memq 'fake-term redraw-calls))
              (should (= post-process-calls 0)))
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

(ert-deftest ghostel-test-apply-palette-ghostel-default-face ()
  "`ghostel--apply-palette' reads default fg/bg from `ghostel-default', not `default'."
  (let ((looked-up nil))
    (cl-letf (((symbol-function 'ghostel--set-default-colors) #'ignore)
              ((symbol-function 'ghostel--set-palette) #'ignore)
              ((symbol-function 'ghostel--face-hex-color)
               (lambda (face _attr)
                 (push face looked-up)
                 "#000000")))
      (ghostel--apply-palette 'fake-term)
      ;; The two default-color lookups must target `ghostel-default',
      ;; never `default' directly — otherwise buffer-local customization
      ;; of the terminal's fg/bg is impossible (issue #178).
      (should (memq 'ghostel-default looked-up))
      (should-not (memq 'default looked-up)))))

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
  "Errors from a dispatched OSC 51;E function are caught, not propagated.
Otherwise they crash the process filter / redraw timer that invoked the
native parser.  Regression for a follow-up to #82 where `dow' with no
args called `dired-other-window' with 0 arguments and signaled up
through the filter."
  (let* ((ghostel-eval-cmds
          `(("boom" ,(lambda (&rest _) (error "Kaboom")))))
         (messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      ;; Must not raise.
      (ghostel--osc51-eval "\"boom\"")
      (should (car messages))
      (should (string-match-p "error calling boom" (car messages)))
      (should (string-match-p "Kaboom" (car messages))))))

(ert-deftest ghostel-test-flush-pending-output-preserves-buffer ()
  "Regression for #82: buffer switches in native callbacks do not leak out.
A buffer switch performed by a synchronous native callback (as OSC 51;E
dispatch does when it calls `find-file-other-window') must not leak out
of `ghostel--flush-pending-output'.  Otherwise callers such as
`ghostel--delayed-redraw' read `ghostel--term' from the wrong buffer and
hand nil to the native module."
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

(ert-deftest ghostel-test-ignore-cursor-change ()
  "Test that `ghostel-ignore-cursor-change' suppresses cursor style updates."
  (let ((buf (generate-new-buffer " *ghostel-test-ignore-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Default: cursor changes are applied
          (let ((ghostel-ignore-cursor-change nil))
            (ghostel--set-cursor-style 2 t)
            (should (equal cursor-type '(hbar . 2))))
          ;; With ignore: cursor changes are suppressed
          (let ((ghostel-ignore-cursor-change t))
            (ghostel--set-cursor-style 1 t)
            (should (equal cursor-type '(hbar . 2)))))  ; unchanged
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: copy-mode hl-line-mode management
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-mode-hl-line ()
  "Test that `global-hl-line-mode' is suppressed and `hl-line-mode' restored in copy-mode."
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
;; Test: ghostel finds renamed buffer by identity (issue #168)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-reuses-identity-match-after-rename ()
  "`ghostel' reuses an identity-matched buffer after a title-tracking rename."
  (let* ((ghostel-buffer-name "*ghostel*")
         (existing (generate-new-buffer ghostel-buffer-name))
         (pre-count (length (buffer-list)))
         popped)
    (unwind-protect
        (progn
          (with-current-buffer existing
            (setq-local ghostel--buffer-identity "*ghostel*"))
          (with-current-buffer existing (rename-buffer "*ghostel: zsh*"))
          (cl-letf (((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--init-buffer) (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (b &rest _) (setq popped b))))
            (ghostel))
          (should (buffer-live-p existing))
          (should (eq popped existing))
          (should (equal "*ghostel: zsh*" (buffer-name existing)))
          (should (= pre-count (length (buffer-list)))))
      (when (buffer-live-p existing) (kill-buffer existing)))))

(ert-deftest ghostel-test-project-reuses-identity-match-after-rename ()
  "`ghostel-project' reuses a project's buffer after title tracking renames it."
  (require 'project)
  (let* ((ghostel-buffer-name "*ghostel*")
         (project-name "*myproj-ghostel*")
         (existing (generate-new-buffer project-name))
         (pre-count (length (buffer-list)))
         popped)
    (unwind-protect
        (progn
          (with-current-buffer existing
            (setq-local ghostel--buffer-identity project-name))
          (with-current-buffer existing (rename-buffer "*ghostel: zsh*"))
          (cl-letf (((symbol-function 'project-current)
                     (lambda (&optional _) '(transient . "/tmp/myproj/")))
                    ((symbol-function 'project-root)
                     (lambda (proj) (cdr proj)))
                    ((symbol-function 'project-prefixed-buffer-name)
                     (lambda (name) (format "*myproj-%s*" name)))
                    ((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--init-buffer) (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (b &rest _) (setq popped b))))
            (ghostel-project))
          (should (buffer-live-p existing))
          (should (eq popped existing))
          (should (equal "*ghostel: zsh*" (buffer-name existing)))
          (should (= pre-count (length (buffer-list)))))
      (when (buffer-live-p existing) (kill-buffer existing)))))

(ert-deftest ghostel-test-init-buffer-sets-identity ()
  "`ghostel--init-buffer' records the identity passed to it."
  (let ((buf (generate-new-buffer " *ghostel-test-identity*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'ghostel--new) (lambda (&rest _) 'fake))
                    ((symbol-function 'ghostel--set-size) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--start-process) (lambda (&rest _) nil)))
            (ghostel--init-buffer buf "*myproj-ghostel*"))
          (should (equal "*myproj-ghostel*"
                         (buffer-local-value 'ghostel--buffer-identity buf))))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: ghostel and ghostel-project return the buffer
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-returns-buffer ()
  "`ghostel' returns the (live) Ghostel buffer."
  (let* ((ghostel-buffer-name "*ghostel-return-test*")
         result)
    (cl-letf (((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
              ((symbol-function 'ghostel--init-buffer) (lambda (&rest _) nil))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (setq result (ghostel)))
    (should (bufferp result))
    (should (buffer-live-p result))
    (should (string-match-p "ghostel-return-test" (buffer-name result)))
    (kill-buffer result)))

(ert-deftest ghostel-test-project-returns-buffer ()
  "`ghostel-project' returns the (live) Ghostel buffer."
  (require 'project)
  (let* ((ghostel-buffer-name "*ghostel*")
         result)
    (cl-letf (((symbol-function 'project-current)
               (lambda (&optional _) '(transient . "/tmp/retproj/")))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'project-prefixed-buffer-name)
               (lambda (name) (format "*retproj-%s*" name)))
              ((symbol-function 'ghostel--load-module) (lambda (&rest _) nil))
              ((symbol-function 'ghostel--init-buffer) (lambda (&rest _) nil))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (setq result (ghostel-project)))
    (should (bufferp result))
    (should (buffer-live-p result))
    (should (string-match-p "retproj" (buffer-name result)))
    (kill-buffer result)))

(ert-deftest ghostel-test-first-creation-respects-display-buffer-alist ()
  "First `ghostel' creation exposes `ghostel-mode' to display rules."
  (let ((saved (current-window-configuration))
        (origin (generate-new-buffer " *ghostel-test-origin*"))
        (ghostel-buffer-name "*ghostel-test-display*"))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer origin)
          (let ((display-buffer-alist
                 `((,(lambda (buf _action)
                       (with-current-buffer buf
                         (derived-mode-p 'ghostel-mode)))
                    (display-buffer-pop-up-window)))))
            (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                      ((symbol-function 'ghostel--new)
                       (lambda (&rest _) 'fake-term))
                      ((symbol-function 'ghostel--set-size) #'ignore)
                      ((symbol-function 'ghostel--apply-palette) #'ignore)
                      ((symbol-function 'ghostel--start-process) #'ignore))
              (ghostel)))
          (let ((created (get-buffer ghostel-buffer-name)))
            (should (buffer-live-p created))
            (should (with-current-buffer created
                      (derived-mode-p 'ghostel-mode)))
            (should (get-buffer-window origin))
            (should (get-buffer-window created))
            (should (not (eq (get-buffer-window origin)
                             (get-buffer-window created))))))
      (when (get-buffer ghostel-buffer-name)
        (kill-buffer ghostel-buffer-name))
      (when (buffer-live-p origin)
        (kill-buffer origin))
      (set-window-configuration saved))))

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
  "`ghostel-copy-mode-end-of-buffer' skips trailing blank rows."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-nav*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--copy-mode-active t)
                (ghostel--term 'fake-term)
                (inhibit-read-only t))
            (insert (mapconcat #'number-to-string (number-sequence 1 20) "\n"))
            (insert "   \n\n")
            (goto-char (point-min))
            (ghostel-copy-mode-end-of-buffer)
            (should (looking-back "20" (line-beginning-position)))))
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
        (captured-latest nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "C:/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--read-module-download-version)
                 (lambda () "0.8.0"))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional version latest-release)
                   (setq captured-version version
                         captured-latest latest-release)
                   ;; Bail before `module-load' — its mock can't be
                   ;; intercepted from native-compiled callers in Emacs 31.
                   (throw 'ghostel-test-bail nil)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (catch 'ghostel-test-bail
          (ghostel-download-module '(4)))
        (should (equal "0.8.0" captured-version))
        (should-not captured-latest)))))

(ert-deftest ghostel-test-download-module-prefix-empty-uses-latest ()
  "Prefix download treats blank input as a request for the latest release."
  (let ((captured-version :unset)
        (captured-latest nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "C:/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--read-module-download-version)
                 (lambda () nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional version latest-release)
                   (setq captured-version version
                         captured-latest latest-release)
                   ;; Bail before `module-load' — its mock can't be
                   ;; intercepted from native-compiled callers in Emacs 31.
                   (throw 'ghostel-test-bail nil)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (catch 'ghostel-test-bail
          (ghostel-download-module '(4)))
        (should (null captured-version))
        (should captured-latest)))))

(ert-deftest ghostel-test-compile-module-invokes-zig-build ()
  "Source compilation runs zig build directly."
  (let ((default-directory nil)
        (messages nil)
        (warnings nil)
        (process-invocation nil))
    (let ((native-comp-enable-subr-trampolines nil))
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
    (let ((native-comp-enable-subr-trampolines nil))
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
  "Test that version check warns when module is below minimum.
At load time (PROMPT-USER nil) the warning fires but `ghostel--ensure-module'
must NOT be called — that path can prompt or download (issue #231).
At an interactive entry point (PROMPT-USER t) it does run."
  (let ((ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.1.0")))
      (let ((warned nil)
            (ensure-called nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (setq warned t)))
                  ((symbol-function 'ghostel--ensure-module)
                   (lambda (dir) (setq ensure-called dir))))
          (ghostel--check-module-version "/tmp")
          (should warned)
          (should-not ensure-called)))
      (let ((warned nil)
            (ensure-called nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (setq warned t)))
                  ((symbol-function 'ghostel--ensure-module)
                   (lambda (dir) (setq ensure-called dir))))
          (ghostel--check-module-version "/tmp" t)
          (should warned)
          (should (equal "/tmp" ensure-called)))))))

(ert-deftest ghostel-test-load-module-no-prompt-at-load-time ()
  "Loading ghostel must never trigger the auto-install path (issue #231).
At load time `ghostel--load-module' must not invoke
`ghostel--ensure-module' or any of its install paths.  Module
installation only happens at interactive entry points
\(`ghostel', `ghostel-download-module', `ghostel-module-compile').

The early-out in `ghostel--load-module' bails when the module is
already loaded, so this test temporarily hides
`ghostel--new' and the `ghostel-module' feature flag to force the
missing-file code path, then restores them."
  (let* ((tmp (make-temp-file "ghostel-test-no-mod" t))
         (ghostel-module-auto-install 'ask)
         (calls '())
         (had-feat (featurep 'ghostel-module))
         (saved-new (and (fboundp 'ghostel--new)
                         (symbol-function 'ghostel--new))))
    (unwind-protect
        (progn
          (when had-feat
            (setq features (delq 'ghostel-module features)))
          (when saved-new
            (fmakunbound 'ghostel--new))
          (cl-letf (((symbol-function 'ghostel--resource-root)
                     (lambda () tmp))
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (&rest _) (push 'ensure calls)))
                    ((symbol-function 'read-char-choice)
                     (lambda (&rest _) (push 'prompt calls) ?s))
                    ((symbol-function 'ghostel--download-module)
                     (lambda (&rest _) (push 'download calls) nil))
                    ((symbol-function 'ghostel--compile-module)
                     (lambda (&rest _) (push 'compile calls) nil))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) nil)))
            (ghostel--load-module)
            (ghostel--load-module nil)))
      (delete-directory tmp t)
      (when saved-new
        (fset 'ghostel--new saved-new))
      (when had-feat
        (cl-pushnew 'ghostel-module features)))
    (should (null calls))))

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
;; Test: platform tag arch normalization
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-platform-tag-normalizes-arch ()
  "Test that amd64/arm64 arch names are normalized in platform tags."
  ;; amd64 -> x86_64
  (let ((system-configuration "amd64-pc-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "x86_64-linux")))
  ;; arm64 -> aarch64
  (let ((system-configuration "arm64-apple-darwin23.1.0")
        (system-type 'darwin))
    (should (equal (ghostel--module-platform-tag) "aarch64-macos")))
  ;; x86_64 unchanged
  (let ((system-configuration "x86_64-pc-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "x86_64-linux")))
  ;; aarch64 unchanged
  (let ((system-configuration "aarch64-unknown-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "aarch64-linux"))))

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
                 (lambda (_delay _repeat _fn &rest _args)
                   ;; Return a fake timer but call function for test
                   'fake-timer)))
        (setq ghostel--process 'fake)
        (ghostel--send-string "a")
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
        (ghostel--send-string "a")
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

(ert-deftest ghostel-test-flush-output-drains-coalesced-first ()
  "`ghostel--flush-output' drains the coalesce buffer before its own write.
This is the chokepoint for every direct PTY write from the Zig side
\(key/mouse encoders, OSC query responses, focus events, VT write-back),
so flushing here covers them all in one place."
  (with-temp-buffer
    (let ((ghostel--process 'fake)
          (ghostel--input-buffer '("s" "l"))
          (ghostel--input-timer nil)
          (sent nil))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_proc str) (push str sent))))
        (ghostel--flush-output "\r")
        ;; Buffered "ls" must reach the PTY *before* the encoder's "\r".
        (should (equal (nreverse sent) '("ls" "\r")))
        (should-not ghostel--input-buffer)))))

(ert-deftest ghostel-test-send-encoded-preserves-input-order ()
  "End-to-end: RET via the encoder cannot overtake buffered self-insert bytes.
The encode-key stub mimics Zig by calling `ghostel--flush-output', which is
where the ordering invariant lives."
  (with-temp-buffer
    (let* ((ghostel--term 'fake)
           (ghostel--process 'fake)
           (ghostel--input-buffer '("s" "l"))
           (ghostel--input-timer nil)
           (ghostel--last-send-time nil)
           (sent nil))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string)
                 (lambda (_proc str) (push str sent)))
                ;; Mimic Zig: the real encoder calls ghostel--flush-output
                ;; with the encoded bytes; let the production wrapper run.
                ((symbol-function 'ghostel--encode-key)
                 (lambda (_term _key _mods &optional _utf8)
                   (ghostel--flush-output "\r")
                   t)))
        (ghostel--send-encoded "return" "")
        (should (equal (nreverse sent) '("ls" "\r")))
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
  "Self-insert snaps to the viewport when `ghostel-scroll-on-input' is non-nil.
The delayed redraw reads `ghostel--snap-requested' to anchor
`window-start'; `ghostel--snap-to-input' must set that flag.  Moving
buffer-point here would cause Emacs' redisplay to scroll ahead of our
redraw and produce visible flicker, so point is left alone."
  (let ((ghostel--term 'fake)
        (ghostel--force-next-redraw nil)
        (ghostel--snap-requested nil)
        (ghostel-scroll-on-input t)
        (sent-key nil))
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent-key str))))
      (with-temp-buffer
        (insert "scrollback\nscrollback\nscrollback\n")
        (goto-char (point-min))
        (let ((last-command-event ?a))
          (cl-letf (((symbol-function 'this-command-keys) (lambda () "a")))
            (ghostel--self-insert)))
        (should ghostel--force-next-redraw)
        (should ghostel--snap-requested)
        (should (equal "a" sent-key))))))

(ert-deftest ghostel-test-scroll-on-input-send-event ()
  "Send-event snaps to the viewport when `ghostel-scroll-on-input' is non-nil."
  (let ((ghostel--term 'fake)
        (ghostel--force-next-redraw nil)
        (ghostel--snap-requested nil)
        (ghostel-scroll-on-input t))
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (_key _mods &optional _utf8) nil)))
      (with-temp-buffer
        (insert "scrollback\nscrollback\nscrollback\n")
        (goto-char (point-min))
        (let ((last-command-event (aref (kbd "<return>") 0)))
          (ghostel--send-event))
        (should ghostel--force-next-redraw)
        (should ghostel--snap-requested)))))

(ert-deftest ghostel-test-scroll-on-input-disabled ()
  "Self-insert does not scroll when `ghostel-scroll-on-input' is nil."
  (let ((ghostel--term 'fake)
        (ghostel--force-next-redraw nil)
        (ghostel-scroll-on-input nil))
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (_str) nil)))
      (with-temp-buffer
        (insert "scrollback\nscrollback\nscrollback\n")
        (goto-char (point-min))
        (let ((start (point)))
          (cl-letf (((symbol-function 'this-command-keys) (lambda () "a")))
            (let ((last-command-event ?a))
              (ghostel--self-insert)))
          (should-not ghostel--force-next-redraw)
          (should (= (point) start)))))))

(ert-deftest ghostel-test-scroll-on-input-paste ()
  "Paste via `ghostel--paste-text' snaps to the viewport via snap flag."
  (let ((ghostel--term 'fake)
        (ghostel--process 'fake-proc)
        (ghostel--force-next-redraw nil)
        (ghostel--snap-requested nil)
        (ghostel-scroll-on-input t)
        (sent-text nil))
    (cl-letf (((symbol-function 'ghostel--bracketed-paste-p)
               (lambda () nil))
              ((symbol-function 'process-live-p)
               (lambda (_p) t))
              ((symbol-function 'process-send-string)
               (lambda (_p s) (setq sent-text s))))
      (with-temp-buffer
        (insert "scrollback\nscrollback\nscrollback\n")
        (goto-char (point-min))
        (ghostel--paste-text "hello")
        (should ghostel--force-next-redraw)
        (should ghostel--snap-requested)
        (should (equal "hello" sent-text))))))

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
  (let* ((event-buf (window-buffer (selected-window)))
         (fake-up-event `(wheel-up (,(selected-window) 1 (10 . 5) 0)))
         (fake-down-event `(wheel-down (,(selected-window) 1 (10 . 5) 0)))
         (unread-command-events nil))
    (with-current-buffer event-buf
      (setq-local ghostel--term 'fake)
      (setq-local ghostel--process 'fake)
      (setq-local ghostel--copy-mode-active nil)
      (setq-local ghostel--scroll-intercept-active t)
      (setq-local pre-command-hook nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--mouse-event)
                   (lambda (_term _action _button _row _col _mods) nil))
                  ((symbol-function 'process-live-p) (lambda (_p) t)))
          ;; Test wheel-up re-dispatch
          (ghostel--scroll-intercept-up fake-up-event)
          (should-not (buffer-local-value
                       'ghostel--scroll-intercept-active event-buf))
          (should (equal fake-up-event (car unread-command-events)))
          ;; Running the buffer-local pre-command-hook in event-buf
          ;; re-enables the intercept and removes the one-shot hook.
          (with-current-buffer event-buf
            (run-hooks 'pre-command-hook))
          (should (buffer-local-value
                   'ghostel--scroll-intercept-active event-buf))
          (should-not (buffer-local-value 'pre-command-hook event-buf))
          (setq unread-command-events nil)
          ;; Test wheel-down re-dispatch
          (ghostel--scroll-intercept-down fake-down-event)
          (should-not (buffer-local-value
                       'ghostel--scroll-intercept-active event-buf))
          (should (equal fake-down-event (car unread-command-events)))
          (with-current-buffer event-buf
            (run-hooks 'pre-command-hook))
          (should (buffer-local-value
                   'ghostel--scroll-intercept-active event-buf)))
      (with-current-buffer event-buf
        (kill-local-variable 'ghostel--term)
        (kill-local-variable 'ghostel--process)
        (kill-local-variable 'ghostel--copy-mode-active)
        (kill-local-variable 'ghostel--scroll-intercept-active)
        (kill-local-variable 'pre-command-hook)))))

(ert-deftest ghostel-test-scroll-intercept-unselected-window ()
  "Wheel events on an unselected ghostel window must not loop.

Regression test: previously `ghostel--redispatch-scroll-event' set
the buffer-local intercept flag in `current-buffer', which for wheel
events on an unselected window is the *selected* window's buffer —
not the ghostel buffer.  The flag therefore stayed t in the ghostel
buffer and the re-dispatched event was intercepted again, hanging
Emacs until `C-g'."
  (let ((ghostel-buf (generate-new-buffer " *ghostel-test-unsel*"))
        (other-buf (generate-new-buffer " *other-test-unsel*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((ghostel-win (split-window))
                 (_ (set-window-buffer ghostel-win ghostel-buf))
                 (_ (with-current-buffer ghostel-buf
                      (setq-local ghostel--term 'fake)
                      (setq-local ghostel--process 'fake)
                      (setq-local ghostel--copy-mode-active nil)
                      (setq-local ghostel--scroll-intercept-active t)))
                 ;; Simulate a wheel event on an unselected ghostel window:
                 ;; current-buffer is the *other* buffer while the event's
                 ;; posn-window points at the ghostel window.
                 (fake-event `(wheel-up (,ghostel-win 1 (10 . 5) 0)))
                 (unread-command-events nil))
            (set-buffer other-buf)
            (cl-letf (((symbol-function 'ghostel--mouse-event)
                       (lambda (_term _action _button _row _col _mods) nil))
                      ((symbol-function 'process-live-p) (lambda (_p) t)))
              (ghostel--scroll-intercept-up fake-event)
              ;; Flag must be cleared in the *ghostel* buffer — otherwise
              ;; the next key lookup in that buffer loops.
              (should-not (buffer-local-value
                           'ghostel--scroll-intercept-active ghostel-buf))
              ;; Event pushed back for the user's scroll handler.
              (should (equal fake-event (car unread-command-events)))
              ;; The re-enable hook lives on the ghostel buffer's
              ;; pre-command-hook; running it there flips the flag back.
              (with-current-buffer ghostel-buf
                (run-hooks 'pre-command-hook))
              (should (buffer-local-value
                       'ghostel--scroll-intercept-active ghostel-buf)))))
      (kill-buffer ghostel-buf)
      (kill-buffer other-buf))))

(ert-deftest ghostel-test-scroll-intercept-forwards-from-unselected-window ()
  "Terminal mouse tracking must receive wheel events from an unselected window.
`ghostel--forward-scroll-event' reads buffer-local `ghostel--term'
and friends, which requires the command to run in the event's buffer
rather than the selected window's buffer."
  (let ((ghostel-buf (generate-new-buffer " *ghostel-test-fwd-unsel*"))
        (other-buf (generate-new-buffer " *other-test-fwd-unsel*"))
        (mouse-event-args nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((ghostel-win (split-window))
                 (_ (set-window-buffer ghostel-win ghostel-buf))
                 (_ (with-current-buffer ghostel-buf
                      (setq-local ghostel--term 'fake)
                      (setq-local ghostel--process 'fake)
                      (setq-local ghostel--copy-mode-active nil)
                      (setq-local ghostel--scroll-intercept-active t)))
                 (fake-event `(wheel-up (,ghostel-win 1 (10 . 5) 0)))
                 (unread-command-events nil))
            (set-buffer other-buf)
            ;; Sanity: in `other-buf' these are all nil — the bug was
            ;; that forward-scroll read them from current-buffer.
            (should-not ghostel--term)
            (cl-letf (((symbol-function 'ghostel--mouse-event)
                       (lambda (_term action button row col mods)
                         (setq mouse-event-args
                               (list action button row col mods))
                         t))
                      ((symbol-function 'process-live-p) (lambda (_p) t)))
              (ghostel--scroll-intercept-up fake-event)
              ;; Mouse event should have been forwarded using the
              ;; ghostel buffer's state, not the other buffer's.
              (should mouse-event-args)
              (should (equal 4 (nth 1 mouse-event-args))) ; button 4
              ;; Not re-dispatched.
              (should-not unread-command-events))))
      (kill-buffer ghostel-buf)
      (kill-buffer other-buf))))

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

(ert-deftest ghostel-test-c-g-binding ()
  "`ghostel-mode-map' binds the quit key to a dedicated send handler."
  (should (eq (lookup-key ghostel-mode-map (kbd "C-g"))
              #'ghostel-send-C-g)))

(ert-deftest ghostel-test-c-g-exits-copy-mode ()
  "The quit key is bound in `ghostel-copy-mode-map' to exit copy mode."
  (should (eq (lookup-key ghostel-copy-mode-map (kbd "C-g"))
              #'ghostel-copy-mode-exit)))

(ert-deftest ghostel-test-inhibit-quit ()
  "`ghostel-mode' should set `inhibit-quit' buffer-locally."
  (let ((buf (generate-new-buffer " *ghostel-test-inhibit-quit*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (should (eq inhibit-quit t))
          (should (local-variable-p 'inhibit-quit)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-c-g-deactivates-mark ()
  "The quit-key send handler clears an active region and `quit-flag'.
`keyboard-quit' is bypassed because `inhibit-quit' is set, so both
side effects have to happen explicitly inside the command."
  (let ((buf (generate-new-buffer " *ghostel-test-c-g-mark*"))
        (sent nil)
        ;; `region-active-p' and `deactivate-mark' both gate on
        ;; `transient-mark-mode', which is off in batch mode by default.
        (transient-mark-mode t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (insert "hello world")
          (goto-char (point-min))
          (set-mark (point))
          (goto-char (point-max))
          (should (region-active-p))
          (setq quit-flag t)
          (cl-letf (((symbol-function 'ghostel--send-string)
                     (lambda (s) (push s sent))))
            (ghostel-send-C-g))
          (should-not (region-active-p))
          (should-not quit-flag)
          (should (equal sent (list (string 7)))))
      (kill-buffer buf))))

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
  (should (eq (lookup-key ghostel-mode-map (kbd "M-y")) #'ghostel-yank-pop))
  ;; M-DEL must be bound so TTY Alt-Backspace ([27 127]) routes through
  ;; ghostel--send-event instead of global backward-kill-word.
  (should (eq (lookup-key ghostel-mode-map (kbd "M-DEL")) #'ghostel--send-event)))

(ert-deftest ghostel-test-special-key-modifier-bindings ()
  "Modified special keys are bound unless in `ghostel-keymap-exceptions'.
Covers e.g. C-<return>, C-M-<down>, S-<f1>."
  (dolist (key '("<return>" "<tab>" "<backspace>" "<escape>"
                 "<up>" "<down>" "<right>" "<left>"
                 "<home>" "<end>" "<prior>" "<next>"
                 "<deletechar>" "<insert>"
                 "<f1>" "<f2>" "<f3>" "<f4>" "<f5>" "<f6>"
                 "<f7>" "<f8>" "<f9>" "<f10>" "<f11>" "<f12>"))
    (dolist (mod '("" "S-" "C-" "M-" "C-S-" "M-S-" "C-M-"))
      (let* ((key-str (concat mod key))
             (binding (ignore-errors (lookup-key ghostel-mode-map (kbd key-str)))))
        (if (member key-str ghostel-keymap-exceptions)
            (should-not (eq binding #'ghostel--send-event))
          (when binding
            (should (eq binding #'ghostel--send-event))))))))

(ert-deftest ghostel-test-special-key-exceptions-honored ()
  "Keymap construction honors `ghostel-keymap-exceptions' for special keys.
Regression test for issue #210."
  (let ((ghostel-keymap-exceptions '("C-<return>" "C-M-<down>" "<f1>"))
        (map (make-sparse-keymap)))
    (dolist (key '("<return>" "<f1>" "<down>"))
      (unless (member key ghostel-keymap-exceptions)
        (define-key map (kbd key) #'ghostel--send-event))
      (dolist (mod '("C-" "C-M-"))
        (let ((key-str (concat mod key)))
          (unless (member key-str ghostel-keymap-exceptions)
            (ignore-errors
              (define-key map (kbd key-str) #'ghostel--send-event))))))
    ;; Exceptions should not be bound to ghostel--send-event
    (should-not (eq (lookup-key map (kbd "C-<return>")) #'ghostel--send-event))
    (should-not (eq (lookup-key map (kbd "C-M-<down>")) #'ghostel--send-event))
    (should-not (eq (lookup-key map (kbd "<f1>")) #'ghostel--send-event))
    ;; Non-exceptions should remain bound
    (should (eq (lookup-key map (kbd "<return>")) #'ghostel--send-event))
    (should (eq (lookup-key map (kbd "C-M-<return>")) #'ghostel--send-event))
    (should (eq (lookup-key map (kbd "C-<f1>")) #'ghostel--send-event))
    (should (eq (lookup-key map (kbd "C-<down>")) #'ghostel--send-event))))

(ert-deftest ghostel-test-send-event-tty-esc-prefix ()
  "Re-inject meta when the key arrives via ESC prefix (TTY Emacs).
In TTY Emacs, M-<key> is delivered as two events ([27 KEY]) via
`esc-map'.  `last-command-event' is just KEY with no meta modifier,
but `this-command-keys-vector' retains the ESC prefix."
  (let (captured-key captured-mods)
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key captured-mods mods))))
      (cl-flet ((sim-tty (keys-vec event expected-key expected-mods)
                  (setq captured-key nil captured-mods nil)
                  (cl-letf (((symbol-function 'this-command-keys-vector)
                             (lambda () keys-vec)))
                    (let ((last-command-event event))
                      (ghostel--send-event)))
                  (should (equal expected-key captured-key))
                  (should (equal expected-mods captured-mods))))
        ;; M-b in TTY: ESC then b → re-inject meta
        (sim-tty (vector 27 ?b)   ?b  "b" "meta")
        (sim-tty (vector 27 ?f)   ?f  "f" "meta")
        (sim-tty (vector 27 ?d)   ?d  "d" "meta")
        ;; M-DEL in TTY: ESC then 127 → backspace + meta
        (sim-tty (vector 27 127)  127 "backspace" "meta")
        ;; Already-meta event (shouldn't double-add meta)
        (sim-tty (vector 27 ?b)   (aref (kbd "M-b") 0) "b" "meta")))))

;; -----------------------------------------------------------------------
;; Test: ghostel-yank-pop DWIM
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-yank-pop-after-yank ()
  "`yank-pop' after yank should cycle the kill ring."
  (let* ((pasted nil)
         (erased nil)
         (kill-ring '("first" "second" "third"))
         (kill-ring-yank-pointer kill-ring)
         (ghostel--yank-index 0)
         (last-command 'ghostel-yank)
         (ghostel--process (start-process "true" nil "true")))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-send-string)
               (lambda (_proc str) (setq erased str))))
      (ghostel-yank-pop)
      ;; Should have erased the previous paste (5 backspaces for "first")
      (should (= (length erased) 5))
      ;; Should have pasted the next kill ring entry
      (should (equal (car pasted) "second")))))

(ert-deftest ghostel-test-yank-pop-no-preceding-yank ()
  "`yank-pop' without preceding yank should use `completing-read'."
  (let* ((pasted nil)
         (kill-ring '("alpha" "beta"))
         (last-command 'ghostel--self-insert))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'completing-read)
               (lambda (_prompt coll &rest _) (car coll))))
      (ghostel-yank-pop)
      (should (equal (car pasted) "alpha")))))

;; -----------------------------------------------------------------------
;; Test: ghostel-xterm-paste
;; -----------------------------------------------------------------------

;; Declared here so tests can let-bind it without byte-compile warnings
;; when xterm.el hasn't been loaded in the batch environment.
(defvar xterm-store-paste-on-kill-ring)

(ert-deftest ghostel-test-xterm-paste-forwards-to-paste-text ()
  "`ghostel-xterm-paste' forwards the event payload via `ghostel--paste-text'."
  (let ((pasted nil)
        (ghostel--copy-mode-active nil)
        (xterm-store-paste-on-kill-ring nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted))))
      (ghostel-xterm-paste '(xterm-paste "hello world"))
      (should (equal pasted '("hello world"))))))

(ert-deftest ghostel-test-xterm-paste-rejects-wrong-event ()
  "`ghostel-xterm-paste' signals when the event isn't an xterm-paste."
  (let ((ghostel--copy-mode-active nil))
    (should-error (ghostel-xterm-paste '(mouse-1 "oops")))))

(ert-deftest ghostel-test-xterm-paste-no-text-is-noop ()
  "`ghostel-xterm-paste' with a nil payload does not forward or touch the kill ring."
  (let ((called nil)
        (kill-ring '("preexisting"))
        (kill-ring-yank-pointer nil)
        (ghostel--copy-mode-active nil)
        (xterm-store-paste-on-kill-ring t))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (_text) (setq called t))))
      (ghostel-xterm-paste '(xterm-paste nil))
      (should-not called)
      (should (equal kill-ring '("preexisting"))))))

(ert-deftest ghostel-test-xterm-paste-stores-on-kill-ring ()
  "When `xterm-store-paste-on-kill-ring' is non-nil, push the paste onto the kill ring."
  (let ((pasted nil)
        (kill-ring nil)
        (kill-ring-yank-pointer nil)
        (ghostel--copy-mode-active nil)
        (xterm-store-paste-on-kill-ring t))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted))))
      (ghostel-xterm-paste '(xterm-paste "clip"))
      (should (equal pasted '("clip")))
      (should (equal (car kill-ring) "clip")))))

(ert-deftest ghostel-test-xterm-paste-skips-kill-ring-when-disabled ()
  "When `xterm-store-paste-on-kill-ring' is nil, the kill ring is untouched."
  (let ((pasted nil)
        (kill-ring '("preexisting"))
        (kill-ring-yank-pointer nil)
        (ghostel--copy-mode-active nil)
        (xterm-store-paste-on-kill-ring nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted))))
      (ghostel-xterm-paste '(xterm-paste "clip"))
      (should (equal pasted '("clip")))
      (should (equal kill-ring '("preexisting"))))))

(ert-deftest ghostel-test-xterm-paste-exits-copy-mode ()
  "`ghostel-xterm-paste' exits copy mode before forwarding."
  (let ((pasted nil)
        (exit-called nil)
        (ghostel--copy-mode-active t)
        (xterm-store-paste-on-kill-ring nil))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-copy-mode-exit)
               (lambda () (setq exit-called t))))
      (ghostel-xterm-paste '(xterm-paste "payload"))
      (should exit-called)
      (should (equal pasted '("payload"))))))

(ert-deftest ghostel-test-xterm-paste-bound-in-keymaps ()
  "`ghostel-xterm-paste' is bound to the [xterm-paste] event in both keymaps."
  (should (eq (lookup-key ghostel-mode-map [xterm-paste])
              #'ghostel-xterm-paste))
  (should (eq (lookup-key ghostel-copy-mode-map [xterm-paste])
              #'ghostel-xterm-paste)))

(ert-deftest ghostel-test-xterm-paste-copy-mode-and-kill-ring ()
  "All three side effects (exit copy mode, `kill-ring', forward) fire together."
  (let ((pasted nil)
        (exit-called nil)
        (kill-ring nil)
        (kill-ring-yank-pointer nil)
        (ghostel--copy-mode-active t)
        (xterm-store-paste-on-kill-ring t))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel-copy-mode-exit)
               (lambda () (setq exit-called t))))
      (ghostel-xterm-paste '(xterm-paste "combo"))
      (should exit-called)
      (should (equal pasted '("combo")))
      (should (equal (car kill-ring) "combo")))))

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
  "Send-next-key sends the prefix key as raw byte 24 (not intercepted by Emacs)."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?\C-x)))
        (ghostel-send-next-key))
      (should (equal (string 24) sent-key)))))

(ert-deftest ghostel-test-send-next-key-control-h ()
  "Send-next-key sends the help key as raw byte 8."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?\C-h)))
        (ghostel-send-next-key))
      (should (equal (string 8) sent-key)))))

(ert-deftest ghostel-test-send-next-key-regular-char ()
  "Send-next-key sends a regular character as-is."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?a)))
        (ghostel-send-next-key))
      (should (equal "a" sent-key)))))

(ert-deftest ghostel-test-send-next-key-meta-x ()
  "Send-next-key routes meta-x through the encoder with meta modifier."
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
  "Send-next-key routes function keys through the encoder."
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
;; Test: public send-string / send-key API
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-send-string-routes-to-send-string ()
  "`ghostel-send-string' forwards its argument to `ghostel--send-string'."
  (with-temp-buffer
    (ghostel-mode)
    (let (sent)
      (cl-letf (((symbol-function 'ghostel--send-string)
                 (lambda (str) (setq sent str))))
        (ghostel-send-string "hello")
        (should (equal sent "hello"))))))

(ert-deftest ghostel-test-send-string-errors-outside-ghostel-buffer ()
  "`ghostel-send-string' signals `user-error' when not in a ghostel buffer."
  (with-temp-buffer
    (should-error (ghostel-send-string "x") :type 'user-error)))

(ert-deftest ghostel-test-send-key-routes-to-send-encoded ()
  "`ghostel-send-key' forwards key-name and mods to `ghostel--send-encoded'."
  (with-temp-buffer
    (ghostel-mode)
    (let (captured-key captured-mods)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &optional _utf8)
                   (setq captured-key key captured-mods mods))))
        (ghostel-send-key "return" "ctrl")
        (should (equal captured-key "return"))
        (should (equal captured-mods "ctrl"))))))

(ert-deftest ghostel-test-send-key-nil-mods-becomes-empty-string ()
  "`ghostel-send-key' passes an empty string when MODS is omitted."
  (with-temp-buffer
    (ghostel-mode)
    (let (captured-mods)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (_key mods &optional _utf8)
                   (setq captured-mods mods))))
        (ghostel-send-key "up")
        (should (equal captured-mods ""))))))

(ert-deftest ghostel-test-send-key-errors-outside-ghostel-buffer ()
  "`ghostel-send-key' signals `user-error' when not in a ghostel buffer."
  (with-temp-buffer
    (should-error (ghostel-send-key "a") :type 'user-error)))

(ert-deftest ghostel-test-send-key-obsolete-alias-still-works ()
  "The obsolete `ghostel--send-key' alias routes to `ghostel--send-string'.
External packages may still call the old internal name."
  (let (sent)
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent str))))
      (with-no-warnings
        (ghostel--send-key "payload"))
      (should (equal sent "payload")))))

(ert-deftest ghostel-test-paste-string-routes-to-paste-text ()
  "`ghostel-paste-string' forwards its argument to `ghostel--paste-text'."
  (with-temp-buffer
    (ghostel-mode)
    (let (received)
      (cl-letf (((symbol-function 'ghostel--paste-text)
                 (lambda (str) (setq received str))))
        (ghostel-paste-string "hello world")
        (should (equal received "hello world"))))))

(ert-deftest ghostel-test-paste-string-errors-outside-ghostel-buffer ()
  "`ghostel-paste-string' signals `user-error' when not in a ghostel buffer."
  (with-temp-buffer
    (should-error (ghostel-paste-string "x") :type 'user-error)))

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
  "Initial terminal size must be baked into the `stty' wrapper, not env vars.
Setting `LINES'/`COLUMNS' env vars freezes ncurses apps like htop at
start-up size and breaks live resize."
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 43
                    ghostel--term-cols 137)
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
                (should (member "TERM=xterm-ghostty" captured-env))
                (should (member "TERM_PROGRAM=ghostty" captured-env))
                ;; Match by regex so version bumps don't break the test —
                ;; the contract is "exported and parseable as semver",
                ;; not a literal string.
                (should (seq-some (lambda (s)
                                    (string-match-p
                                     "\\`TERM_PROGRAM_VERSION=[0-9]+\\.[0-9]+\\.[0-9]+\\'"
                                     s))
                                  captured-env))
                (should (seq-some (lambda (s) (string-prefix-p "TERMINFO=" s))
                                  captured-env))
                (should (member "COLORTERM=truecolor" captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-start-process-respects-ghostel-term-opt-out ()
  "Setting `ghostel-term' to xterm-256color drops the Ghostty advertisement.
TERMINFO and TERM_PROGRAM must not leak through when the user opts
out — otherwise outbound `ssh' (or any consumer of those vars) would
falsely conclude that ghostty is the controlling terminal."
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 25
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               (ghostel-term "xterm-256color")
               (default-directory "/tmp/")
               (proc (ghostel--start-process)))
          (unwind-protect
              (progn
                (should (member "TERM=xterm-256color" captured-env))
                (should (member "COLORTERM=truecolor" captured-env))
                (should-not (seq-some (lambda (s) (string-prefix-p "TERMINFO=" s))
                                      captured-env))
                (should-not (member "TERM_PROGRAM=ghostty" captured-env))
                (should-not (seq-some (lambda (s)
                                        (string-prefix-p "TERM_PROGRAM_VERSION=" s))
                                      captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-start-process-ssh-install-exports-env ()
  "`ghostel-ssh-install-terminfo' must export GHOSTEL_SSH_INSTALL_TERMINFO=1.
The bundled bash/zsh/fish integration scripts gate the outbound
`ssh' install-and-cache wrapper on this env var, so the elisp custom
is the single source of truth.

The `auto' default follows `ghostel-tramp-shell-integration': enabled
when that's non-nil, off otherwise.  Setting it to t forces on,
setting it to nil forces off."
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 25
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               ;; Without this, the per-iteration `delete-process' fires
               ;; the sentinel which kills our `with-temp-buffer' buffer,
               ;; flipping `current-buffer' (and its `default-directory')
               ;; for subsequent iterations.
               (ghostel-kill-buffer-on-exit nil)
               (default-directory "/tmp/"))
          ;; auto + tramp-shell-integration nil → not exported.
          (setq captured-env nil)
          (let* ((ghostel-ssh-install-terminfo 'auto)
                 (ghostel-tramp-shell-integration nil)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should-not (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                    captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; auto + tramp-shell-integration t → exported.
          (setq captured-env nil)
          (let* ((ghostel-ssh-install-terminfo 'auto)
                 (ghostel-tramp-shell-integration t)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; Forced on.
          (setq captured-env nil)
          (let* ((ghostel-ssh-install-terminfo t)
                 (ghostel-tramp-shell-integration nil)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; Forced off (overrides tramp-shell-integration).
          (setq captured-env nil)
          (let* ((ghostel-ssh-install-terminfo nil)
                 (ghostel-tramp-shell-integration t)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should-not (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                    captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; Local TERM opt-out (`ghostel-term' /= xterm-ghostty)
          ;; suppresses the SSH-install advertisement even when forced
          ;; on — otherwise outbound ssh would falsely claim ghostty
          ;; while the local buffer is plain xterm-256color.
          (setq captured-env nil)
          (let* ((ghostel-term "xterm-256color")
                 (ghostel-ssh-install-terminfo t)
                 (ghostel-tramp-shell-integration t)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should-not (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                    captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; Bundled terminfo missing (e.g. broken install): the env
          ;; helper falls back to TERM=xterm-256color *and* must
          ;; suppress GHOSTEL_SSH_INSTALL_TERMINFO so the wrapper
          ;; doesn't try to advertise xterm-ghostty over ssh.
          (setq captured-env nil)
          (cl-letf (((symbol-function #'ghostel--terminfo-directory)
                     (lambda () nil))
                    ;; Suppress the one-shot fallback warning during
                    ;; the test so it doesn't pollute output.
                    (ghostel--terminfo-warned t))
            (let* ((ghostel-term "xterm-ghostty")
                   (ghostel-ssh-install-terminfo t)
                   (ghostel-tramp-shell-integration t)
                   (proc (ghostel--start-process)))
              (unwind-protect
                  (progn
                    (should (member "TERM=xterm-256color" captured-env))
                    (should-not (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                        captured-env)))
                (when (process-live-p proc) (delete-process proc))))))))))

(ert-deftest ghostel-test-remote-term-preamble ()
  "`ghostel--remote-term-preamble' embeds an `infocmp' probe.
The probe runs *on the remote* (inside the per-spawn wrapper), so
TERM is decided after env propagation — sidestepping
`tramp-local-environment-variable-p', which would otherwise strip
`TERM=' entries that match the local default top-level
`process-environment' and leave the remote shell to inherit
TERM=dumb (issue #224).

A single probe path covers every case: auto-integration (TERMINFO=
already in env, points at the pushed terminfo dir),
manually-installed (system, `~/.terminfo', or co-located with the
shell-integration scripts under `~/.local/share/ghostel/terminfo'),
and absent (fall back to `xterm-256color' so echo works)."
  (let* ((ghostel-term "xterm-ghostty")
         (preamble (ghostel--remote-term-preamble)))
    ;; Default value for the case infocmp fails.
    (should (string-match-p "\\bTERM=xterm-256color;" preamble))
    ;; Probe and conditional upgrade.
    (should (string-match-p "infocmp xterm-ghostty" preamble))
    (should (string-match-p "\\bTERM=xterm-ghostty;" preamble))
    (should (string-match-p "TERM_PROGRAM=ghostty;" preamble))
    (should (string-match-p "TERM_PROGRAM_VERSION=" preamble))
    ;; Co-located bundle gets prepended to TERMINFO_DIRS — so a
    ;; user can `scp` the terminfo dir alongside the shell
    ;; scripts and the probe finds it without `tic` or
    ;; ~/.terminfo gymnastics.
    (should (string-match-p
             "~/\\.local/share/ghostel/terminfo/x/xterm-ghostty"
             preamble))
    (should (string-match-p
             "~/\\.local/share/ghostel/terminfo/78/xterm-ghostty"
             preamble))
    (should (string-match-p
             (regexp-quote
              "TERMINFO_DIRS=~/.local/share/ghostel/terminfo")
             preamble))
    ;; Existing TERMINFO_DIRS must be preserved (prepend, not
    ;; replace) so a system-configured search list still works.
    (should (string-match-p (regexp-quote "${TERMINFO_DIRS:+:$TERMINFO_DIRS}")
                            preamble))
    ;; Order is load-bearing: the TERMINFO_DIRS prepend must run
    ;; BEFORE the `infocmp' probe, otherwise ncurses won't find the
    ;; co-located bundle and the probe falls back to xterm-256color.
    (should (< (string-match (regexp-quote
                              "TERMINFO_DIRS=~/.local/share/ghostel/terminfo")
                             preamble)
               (string-match "infocmp xterm-ghostty" preamble)))
    ;; Always exported.
    (should (string-match-p "COLORTERM=truecolor" preamble))
    (should (string-match-p "export TERM COLORTERM" preamble)))
  ;; Customized `ghostel-term' is honored verbatim — no probe, no
  ;; ghostty advertisement, no TERMINFO_DIRS munging.
  (let* ((ghostel-term "xterm-256color")
         (preamble (ghostel--remote-term-preamble)))
    (should-not (string-match-p "infocmp" preamble))
    (should-not (string-match-p "TERM_PROGRAM=ghostty" preamble))
    (should-not (string-match-p "TERMINFO_DIRS" preamble))
    (should (string-match-p "TERM=xterm-256color" preamble))
    (should (string-match-p "COLORTERM=truecolor" preamble)))
  (let* ((ghostel-term "screen-256color")
         (preamble (ghostel--remote-term-preamble)))
    (should-not (string-match-p "infocmp" preamble))
    (should (string-match-p "TERM=screen-256color" preamble))))

(ert-deftest ghostel-test-spawn-pty-uses-remote-term-preamble ()
  "`ghostel--spawn-pty' embeds the remote preamble in the wrapper script.
The preamble runs on the remote, so TERM is set after TRAMP's
env propagation — sidestepping `tramp-local-environment-variable-p'
which would otherwise strip `TERM=' entries that match the local
default toplevel and leave the remote shell with TERM=dumb (#224).

Local spawns must not get the preamble; their TERM still rides in
`process-environment' via `ghostel--terminal-env'."
  ;; First cl-letf of `make-process' in a fresh Emacs would trigger
  ;; native-comp of a subr trampoline; disable to keep the test
  ;; portable across machines without a working gccjit toolchain.
  (let ((native-comp-enable-subr-trampolines nil))
    (with-temp-buffer
      (setq-local ghostel--term-rows 25 ghostel--term-cols 80
                  ;; The wrapped `make-process' below still calls the
                  ;; real one via apply; needs a directory it can chdir
                  ;; into.  /tmp is the safe default already used by
                  ;; sibling tests.
                  default-directory "/tmp/")
      (let ((ghostel-term "xterm-ghostty")
            (ghostel-kill-buffer-on-exit nil)
            (orig-make-process (symbol-function #'make-process)))
        ;; Remote spawn → preamble in wrapper, TERM/TERMINFO not
        ;; added by ghostel.  Use a clean `process-environment' so
        ;; the assertion is about ghostel's contribution, not the
        ;; test runner's ambient env.
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (captured-env nil)
               (captured-cmd nil))
          (cl-letf (((symbol-function #'make-process)
                     (lambda (&rest plist)
                       (setq captured-env process-environment)
                       (setq captured-cmd (plist-get plist :command))
                       (apply orig-make-process plist))))
            (let ((proc (ghostel--spawn-pty
                         "/bin/sh" nil 25 80 "-ixon" nil t)))
              (unwind-protect
                  (let ((script (nth 2 captured-cmd)))
                    (should (string-match-p "infocmp xterm-ghostty" script))
                    (should (string-match-p "export TERM COLORTERM" script))
                    ;; Ghostel must not push the local TERMINFO path —
                    ;; it points at a dir the remote can't read and
                    ;; (per terminfo(5)) suppresses system lookups.
                    (should-not (seq-some
                                 (lambda (s) (string-prefix-p "TERMINFO=" s))
                                 captured-env))
                    ;; TERM also stays out of env — wrapper handles it.
                    (should-not (member "TERM=xterm-ghostty" captured-env)))
                (when (process-live-p proc) (delete-process proc))))))
        ;; Local spawn → no preamble, env-driven TERM.
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (captured-env nil)
               (captured-cmd nil))
          (cl-letf (((symbol-function #'make-process)
                     (lambda (&rest plist)
                       (setq captured-env process-environment)
                       (setq captured-cmd (plist-get plist :command))
                       (apply orig-make-process plist))))
            (let ((proc (ghostel--spawn-pty
                         "/bin/sh" nil 25 80 "-ixon" nil nil)))
              (unwind-protect
                  (let ((script (nth 2 captured-cmd)))
                    (should-not (string-match-p "infocmp" script))
                    (should (member "TERM=xterm-ghostty" captured-env)))
                (when (process-live-p proc) (delete-process proc))))))))))

(ert-deftest ghostel-test-tramp-inside-emacs-preserves-ghostel-prefix ()
  "TRAMP rewrites INSIDE_EMACS but must preserve the user-set prefix.
The README's manual remote-integration gate
  [[ \"${INSIDE_EMACS%%,*}\" = \\='ghostel\\=' ]]
relies on `tramp-inside-emacs' appending `,tramp:VER' to the
existing `INSIDE_EMACS' value rather than wholly overwriting it.
If TRAMP ever changes that contract, the gate silently stops
matching on TRAMP-launched ghostel remotes — this canary catches it."
  (require 'tramp)
  (let ((process-environment
         (cons "INSIDE_EMACS=ghostel" process-environment)))
    (let ((rewritten (tramp-inside-emacs)))
      (should (string-prefix-p "ghostel," rewritten))
      (should (string-match-p ",tramp:" rewritten)))))

(ert-deftest ghostel-test-environment-precedes-internal-env ()
  "`ghostel-environment' entries must come before ghostel's own env vars.
When a user sets TERM via `ghostel-environment', it must win over the
internal `TERM=xterm-ghostty' so a `process-environment' lookup (which
returns the first match) resolves to the user's value."
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        ;; `ghostel--start-process' reads dims from these buffer-locals
        ;; (set by `ghostel--init-buffer' in the real flow).
        (setq-local ghostel--term-rows 25
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               (ghostel-environment '("TERM=dumb" "MY_VAR=42"))
               (default-directory "/tmp/")
               (proc (ghostel--start-process)))
          (unwind-protect
              (let ((term-idx (seq-position captured-env "TERM=dumb"))
                    (default-term-idx
                     (seq-position captured-env "TERM=xterm-ghostty")))
                (should (member "MY_VAR=42" captured-env))
                (should term-idx)
                (should default-term-idx)
                (should (< term-idx default-term-idx)))
            (when (process-live-p proc) (delete-process proc))))))))

(ert-deftest ghostel-test-environment-applies-to-compile ()
  "`ghostel-compile--spawn' must prepend `ghostel-environment'.
The splice lives in the compile spawn (separate from `ghostel--spawn-pty'),
so this path needs its own coverage — without it, users setting
`CC=clang' would see it take effect in shells but silently miss for
compile jobs.  Also pins the position: `compilation-environment'
entries must precede `ghostel-environment', and both must precede
ghostel's own `INSIDE_EMACS=...,compile' marker."
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (let* ((default-directory "/tmp/")
               (compilation-environment '("COMPENV=first"))
               (ghostel-environment '("CC=clang"))
               (proc (ghostel-compile--spawn "true" (current-buffer) 24 80)))
          (unwind-protect
              (let ((compenv-idx (seq-position captured-env "COMPENV=first"))
                    (cc-idx      (seq-position captured-env "CC=clang"))
                    (inside-idx  (cl-position-if
                                  (lambda (s)
                                    (string-prefix-p "INSIDE_EMACS=" s))
                                  captured-env)))
                (should compenv-idx)
                (should cc-idx)
                (should inside-idx)
                (should (< compenv-idx cc-idx))
                (should (< cc-idx inside-idx)))
            (when (process-live-p proc) (delete-process proc))))))))

(ert-deftest ghostel-test-compile-prepare-buffer-sets-dir-before-mode ()
  "`default-directory' must be set before `ghostel-mode' in prepare-buffer.
The mode's `hack-dir-local-variables' call must resolve dir-locals
against the target directory.  If the order flips, per-project
`ghostel-environment' overrides silently miss for compile.  Also
pins that `default-directory' survives the mode switch — if somebody
drops the `permanent-local' property upstream this test catches it."
  (let ((captured-default-directory nil)
        (target "/tmp/"))
    (cl-letf (((symbol-function 'hack-dir-local-variables)
               (lambda ()
                 (setq captured-default-directory default-directory)))
              ((symbol-function 'ghostel--load-module) #'ignore)
              ((symbol-function 'ghostel--new) (lambda (&rest _) 'fake-term))
              ((symbol-function 'ghostel--apply-palette) #'ignore))
      (let ((buf (ghostel-compile--prepare-buffer
                  " *ghostel-prepare-test*" target)))
        (unwind-protect
            (progn
              (should (equal captured-default-directory target))
              (with-current-buffer buf
                (should (equal default-directory target))))
          (kill-buffer buf))))))

(ert-deftest ghostel-test-environment-honors-dir-locals ()
  "End-to-end: a real `.dir-locals.el' populates `ghostel-environment'.
Covers the whole pipeline (`hack-dir-local-variables' reading the
file, the safety gate, and buffer-local assignment) — not just the
final `setq-local'."
  (let* ((dir (file-name-as-directory (make-temp-file "ghostel-dl-" t)))
         (dl  (expand-file-name ".dir-locals.el" dir))
         (buf (generate-new-buffer " *ghostel-dl-test*")))
    (unwind-protect
        (progn
          (with-temp-file dl
            (insert
             "((ghostel-mode . ((ghostel-environment . (\"FOO=1\" \"BAR=2\")))))"))
          (with-current-buffer buf
            (setq-local default-directory dir)
            (ghostel-mode)
            (should (local-variable-p 'ghostel-environment))
            (should (equal ghostel-environment '("FOO=1" "BAR=2")))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-environment-rejects-unsafe-dir-locals ()
  "An unsafe `ghostel-environment' value in dir-locals must be rejected.
Guards against a malicious `.dir-locals.el' that tries to smuggle a
non-list/non-string value past the usual `safe-local-variable-p'
machinery."
  (let ((buf (generate-new-buffer " *ghostel-unsafe-test*")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'hack-dir-local-variables)
                     (lambda ()
                       (setq-local dir-local-variables-alist
                                   '((ghostel-environment . "not-a-list"))))))
            (ghostel-mode))
          (should-not (local-variable-p 'ghostel-environment)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-terminfo-directory-finds-bundled ()
  "`ghostel--terminfo-directory' must locate the bundled compiled entries.
The package ships compiled terminfo for both macOS (78/) and Linux (x/)
layouts; if neither is present after install, the lookup must return
nil so the fallback warning fires."
  (let ((dir (ghostel--terminfo-directory)))
    (should dir)
    (should (file-directory-p dir))
    (should (or (file-readable-p (expand-file-name "78/xterm-ghostty" dir))
                (file-readable-p (expand-file-name "x/xterm-ghostty" dir))))))

(ert-deftest ghostel-test-start-process-local-bash-integration-keeps-early-echo ()
  "Local bash integration must keep `stty echo' in the wrapper.
Old bash versions can initialize readline before the ENV-injected
integration script runs, so input echo must be enabled before exec."
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 25
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/bash")
               (ghostel-shell-integration t)
               (default-directory "/tmp/")
               (proc (ghostel--start-process)))
          (unwind-protect
              (let ((cmd (process-command proc)))
                (should (equal '("/bin/sh" "-c") (seq-take cmd 2)))
                (should (string-match-p "stty .* -ixon echo\\b" (nth 2 cmd)))
                (should (string-match-p "exec /bin/bash --posix" (nth 2 cmd)))
                (should (member "GHOSTEL_BASH_INJECT=1" captured-env))
                (should (seq-some (lambda (s) (string-prefix-p "ENV=" s))
                                  captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-spawn-pty-disables-adaptive-read-buffering ()
  "`ghostel--spawn-pty' must disable adaptive read buffering.
It must also raise `read-process-output-max'.  Before Emacs 31 the
former defaulted to t and throttled bursty TUI redraws."
  (let ((captured-adaptive 'unset)
        (captured-max nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-adaptive process-adaptive-read-buffering
                       captured-max read-process-output-max)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (let ((proc (ghostel--spawn-pty "/bin/sh" nil 24 80
                                        "-ixon" nil nil)))
          (unwind-protect
              (progn
                (should (null captured-adaptive))
                (should (>= captured-max (* 1024 1024))))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-compile-spawn-disables-adaptive-read-buffering ()
  "`ghostel-compile--spawn' must disable adaptive read buffering.
It must also raise `read-process-output-max'.  Same reason as
`ghostel--spawn-pty' (issue #85)."
  (let ((captured-adaptive 'unset)
        (captured-max nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-adaptive process-adaptive-read-buffering
                       captured-max read-process-output-max)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (let ((proc (ghostel-compile--spawn "true" (current-buffer) 24 80)))
          (unwind-protect
              (progn
                (should (null captured-adaptive))
                (should (>= captured-max (* 1024 1024))))
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
                   (lambda (_term h w &rest _) (setq set-size-args (list h w))))
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
                 (lambda (_term _h _w &rest _) (setq set-size-called t)))
                ((symbol-function 'process-buffer)
                 (lambda (_proc) nil))
                ((default-value 'window-adjust-process-window-size-function)
                 (lambda (_proc _wins) nil)))
        (let ((result (ghostel--window-adjust-process-window-size
                       'fake-proc nil)))
          (should (null result))
          (should-not set-size-called))))))

(ert-deftest ghostel-test-resize-noop-same-dims ()
  "Resize to identical dims returns nil and skips set-size."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size)
                   (lambda (_term _h _w) (setq set-size-called t)))
                  ((symbol-function 'ghostel--delayed-redraw) #'ignore)
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 40))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (null result))
            (should-not set-size-called)))))))

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
  "SIGWINCH reaches child processes via the resize handler.
Exercises `ghostel--window-adjust-process-window-size', the full
path Emacs takes: call the adjust-window-size-function, get
\(width . height), then call `set-process-window-size'."
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
                         (lambda (_t _h _w &rest _) nil))
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


;; -----------------------------------------------------------------------
;; Test: ghostel-exec public API
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-exec-errors-on-live-process ()
  "`ghostel-exec' signals `user-error' if BUFFER has a live process."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq ghostel--process 'fake-process))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'process-live-p)
                     (lambda (p) (eq p 'fake-process))))
            (should-error (ghostel-exec buf "ls" nil) :type 'user-error)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-calls-spawn-pty-with-expected-args ()
  "`ghostel-exec' forwards PROGRAM, ARGS, size, stty flags, and remote-p."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*"))
        captured)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                  ((symbol-function 'ghostel--new)
                   (lambda (&rest _) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette) #'ignore)
                  ((symbol-function 'ghostel--spawn-pty)
                   (lambda (&rest args) (setq captured args) 'fake-proc)))
          (ghostel-exec buf "less" '("/etc/hosts"))
          ;; Signature: program args height width stty-flags extra-env remote-p
          (should (equal (nth 0 captured) "less"))
          (should (equal (nth 1 captured) '("/etc/hosts")))
          (should (numberp (nth 2 captured)))
          (should (numberp (nth 3 captured)))
          (should (equal (nth 4 captured) "erase '^?' iutf8 -ixon echo"))
          (should (null (nth 5 captured)))
          ;; Local default-directory — no TRAMP — so remote-p must be nil.
          (should (null (nth 6 captured))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-threads-remote-p-from-tramp-dir ()
  "`ghostel-exec' derives remote-p from BUFFER's `default-directory'."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*"))
        captured)
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local default-directory "/ssh:somehost:/home/user/"))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--new)
                     (lambda (&rest _) 'fake-term))
                    ((symbol-function 'ghostel--set-size) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore)
                    ((symbol-function 'ghostel--spawn-pty)
                     (lambda (&rest args) (setq captured args) 'fake-proc)))
            (ghostel-exec buf "ls" nil)
            (should (nth 6 captured))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-exec-uses-default-size-when-buffer-not-displayed ()
  "`ghostel-exec' on an undisplayed buffer uses the 80x24 default.
Falling back to (selected-window) sized the PTY from whatever window
happened to be focused at call time, which rarely matches where the
buffer eventually shows up."
  (let ((buf (generate-new-buffer "ghostel-exec-test"))
        captured)
    (unwind-protect
        (progn
          ;; Sanity: the buffer is not displayed in any window.
          (should-not (get-buffer-window buf t))
          (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                    ((symbol-function 'ghostel--new)
                     (lambda (&rest args) (setq captured args) 'fake-term))
                    ((symbol-function 'ghostel--set-size) #'ignore)
                    ((symbol-function 'ghostel--apply-palette) #'ignore)
                    ((symbol-function 'ghostel--spawn-pty)
                     (lambda (&rest _) 'fake-proc)))
            (ghostel-exec buf "ls" nil)
            ;; ghostel--new is called as (height width max-scrollback).
            (should (equal (nth 0 captured) 24))
            (should (equal (nth 1 captured) 80))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-pre-spawn-hook-injects-into-process-environment ()
  "Hook `setenv' calls reach the spawned process via `process-environment'.
`ghostel-pre-spawn-hook' fires with `process-environment' dynamically
bound to the about-to-be-spawned env, so hook functions that call
`setenv' inject entries the child process actually inherits.

Contract relied on by integrations like with-editor: drive a real
`/bin/sh' through `ghostel--start-process', have the hook `setenv' a
sentinel value, and verify the value reached `make-process'.  Also
verifies the hook fires in the spawning buffer with `default-directory'
intact (with-editor's `with-editor--setup' reads `default-directory')."
  (let ((captured-env nil)
        captured-buffer
        captured-default-directory
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 24
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               (default-directory "/tmp/")
               (test-buffer (current-buffer))
               (ghostel-pre-spawn-hook
                (list (lambda ()
                        (setq captured-buffer (current-buffer))
                        (setq captured-default-directory default-directory)
                        (setenv "GHOSTEL_PRE_SPAWN_TEST" "ok"))))
               (proc (ghostel--start-process)))
          (unwind-protect
              (progn
                (should (eq captured-buffer test-buffer))
                (should (equal captured-default-directory "/tmp/"))
                (should (member "GHOSTEL_PRE_SPAWN_TEST=ok" captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

;; -----------------------------------------------------------------------
;; Test: ghostel-eshell integration
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-eshell-visual-command-mode-toggles-advice ()
  "Enabling/disabling the mode adds/removes the `eshell-exec-visual' advice."
  (let ((was-on ghostel-eshell-visual-command-mode))
    (unwind-protect
        (progn
          (ghostel-eshell-visual-command-mode -1)
          (should-not (advice-member-p #'ghostel-eshell--exec-visual
                                       'eshell-exec-visual))
          (ghostel-eshell-visual-command-mode 1)
          (should (advice-member-p #'ghostel-eshell--exec-visual
                                   'eshell-exec-visual))
          (ghostel-eshell-visual-command-mode -1)
          (should-not (advice-member-p #'ghostel-eshell--exec-visual
                                       'eshell-exec-visual)))
      (ghostel-eshell-visual-command-mode (if was-on 1 -1)))))

(ert-deftest ghostel-test-eshell/ghostel-dispatches-to-exec-visual ()
  "`eshell/ghostel' forwards its arguments to `eshell-exec-visual'."
  (let (captured)
    (cl-letf (((symbol-function 'eshell-exec-visual)
               (lambda (&rest args) (setq captured args))))
      (eshell/ghostel "vim" "file.txt")
      (should (equal captured '("vim" "file.txt"))))))

;; -----------------------------------------------------------------------
;; Test: ghostel-debug-keypress rendering
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-debug-keypress-renders-capture ()
  "`ghostel--debug-kp-show' writes a paste-friendly report.
Drives the renderer with a synthetic state plist that mimics a captured
RET keystroke.  Asserts the report includes the event, every recorded
send, and the coalesce-buffer state."
  (let* ((target (generate-new-buffer " *ghostel-test-debug-kp*"))
         (state (list :buffer target
                      :event ?\C-m
                      :keys [13]
                      :command 'ghostel--send-event
                      :binding 'ghostel--send-event
                      :calls (list (cons :flush-output "\r")
                                   (cons :send-string "ls")))))
    (unwind-protect
        (progn
          (ghostel--debug-kp-show state)
          (with-current-buffer "*ghostel-debug-keypress*"
            (let ((content (buffer-string)))
              (should (string-match-p "^=== ghostel-debug-keypress ===" content))
              (should (string-match-p "last-input-event:" content))
              (should (string-match-p "Sends during this command" content))
              ;; Calls were collected newest-first; renderer reverses them.
              (should (string-match-p "1\\. send-string: \"ls\"" content))
              (should (string-match-p "hex: 6c 73" content))
              (should (string-match-p "2\\. flush-output:" content))
              (should (string-match-p "hex: 0d" content))
              (should (string-match-p "Coalesce buffer" content)))))
      (kill-buffer target)
      (when (get-buffer "*ghostel-debug-keypress*")
        (kill-buffer "*ghostel-debug-keypress*")))))

(ert-deftest ghostel-test-debug-info-environment-section ()
  "`ghostel-debug-info' renders the Environment section.
The section shows the spawn env ghostel hands the shell (TERM,
COLORTERM, INSIDE_EMACS, …) plus pass-through LANG/LC_*."
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t)
        (ghostel--terminfo-warned t))
    (unwind-protect
        (save-window-excursion
          (with-temp-buffer
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (let ((content (buffer-string)))
                (should (string-match-p "--- Environment ---" content))
                (should (string-match-p "Spawn env" content))
                (should (string-match-p "INSIDE_EMACS=ghostel" content))
                (should (string-match-p "^  TERM=" content))
                (should (string-match-p "COLORTERM=" content))
                (should (string-match-p "Pass-through" content))
                (should (string-match-p "LANG=" content))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))


;;; Cell pixel scale (DPI heuristic + reported dimensions)

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


;;; Kitty graphics — display callbacks and clear

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


;;; Kitty graphics — end-to-end through libghostty (native module)

(ert-deftest ghostel-test-kitty-graphics-emit-end-to-end ()
  "A kitty transmit-and-place escape reaches `ghostel--kitty-display-image'.
Smoke test for the C boundary: feeds a 1x1 RGB transmission, redraws,
and checks that the elisp callback receives the expected geometry and
unibyte image data.  Without this, protocol-level regressions in the
Zig glue (placement iterator, render-info query, RGBA→PPM conversion)
slip past the unit tests."
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


(defconst ghostel-test--elisp-tests
  '(ghostel-test-focus-window-selection
    ghostel-test-focus-dedup
    ghostel-test-focus-two-ghostel-buffers
    ghostel-test-focus-frame-blur
    ghostel-test-focus-skips-state-update-when-1004-off
    ghostel-test-raw-key-sequences
    ghostel-test-modifier-number
    ghostel-test-send-event
    ghostel-test-raw-key-modified-specials
    ghostel-test-update-directory
    ghostel-test-list-buffers-directory
    ghostel-test-compile-view-list-buffers-directory
    ghostel-test-filter-soft-wraps
    ghostel-test-prompt-navigation
    ghostel-test-sync-theme
    ghostel-test-apply-palette-default-colors
    ghostel-test-apply-palette-ghostel-default-face
    ghostel-test-osc51-eval
    ghostel-test-osc51-eval-unknown
    ghostel-test-osc51-eval-catches-errors
    ghostel-test-osc-progress-dispatch
    ghostel-test-osc-progress-dispatch-error-isolated
    ghostel-test-notification-dispatch
    ghostel-test-notification-dispatch-current-buffer
    ghostel-test-notification-dispatch-real-timer
    ghostel-test-notification-dispatch-buffer-killed
    ghostel-test-default-notify-uses-alert
    ghostel-test-default-notify-empty-title-uses-buffer-name
    ghostel-test-default-progress-modeline
    ghostel-test-spinner-progress-errors-without-spinner
    ghostel-test-spinner-progress-indeterminate-starts-once
    ghostel-test-spinner-progress-set-stops-and-shows-percent
    ghostel-test-spinner-progress-remove-clears-modeline
    ghostel-test-spinner-stop-helper-clears-state
    ghostel-test-flush-pending-output-preserves-buffer
    ghostel-test-copy-mode-cursor
    ghostel-test-ignore-cursor-change
    ghostel-test-copy-mode-hl-line
    ghostel-test-project-buffer-name
    ghostel-test-project-universal-arg
    ghostel-test-reuses-identity-match-after-rename
    ghostel-test-project-reuses-identity-match-after-rename
    ghostel-test-init-buffer-sets-identity
    ghostel-test-first-creation-respects-display-buffer-alist
    ghostel-test-returns-buffer
    ghostel-test-project-returns-buffer
    ghostel-test-copy-all
    ghostel-test-copy-mode-buffer-navigation
    ghostel-test-compile-module-invokes-zig-build
    ghostel-test-module-compile-command-uses-zig-build
    ghostel-test-module-download-url-uses-requested-version
    ghostel-test-module-download-url-uses-latest-release
    ghostel-test-download-module-defaults-to-minimum-version
    ghostel-test-download-module-prefix-uses-requested-version
    ghostel-test-download-module-prefix-empty-uses-latest
    ghostel-test-module-version-match
    ghostel-test-module-version-mismatch
    ghostel-test-module-version-newer-than-minimum
    ghostel-test-load-module-no-prompt-at-load-time
    ghostel-test-platform-tag-normalizes-arch
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
    ghostel-test-scroll-on-input-paste
    ghostel-test-scroll-intercept-forwards-mouse-tracking
    ghostel-test-scroll-intercept-fallthrough
    ghostel-test-scroll-intercept-unselected-window
    ghostel-test-scroll-intercept-forwards-from-unselected-window
    ghostel-test-control-key-bindings
    ghostel-test-c-g-binding
    ghostel-test-c-g-exits-copy-mode
    ghostel-test-inhibit-quit
    ghostel-test-meta-key-bindings
    ghostel-test-special-key-modifier-bindings
    ghostel-test-special-key-exceptions-honored
    ghostel-test-send-event-tty-esc-prefix
    ghostel-test-yank-pop-after-yank
    ghostel-test-yank-pop-no-preceding-yank
    ghostel-test-xterm-paste-forwards-to-paste-text
    ghostel-test-xterm-paste-rejects-wrong-event
    ghostel-test-xterm-paste-no-text-is-noop
    ghostel-test-xterm-paste-stores-on-kill-ring
    ghostel-test-xterm-paste-skips-kill-ring-when-disabled
    ghostel-test-xterm-paste-exits-copy-mode
    ghostel-test-xterm-paste-bound-in-keymaps
    ghostel-test-xterm-paste-copy-mode-and-kill-ring
    ghostel-test-copy-mode-recenter
    ghostel-test-send-next-key-control-x
    ghostel-test-send-next-key-control-h
    ghostel-test-send-next-key-regular-char
    ghostel-test-send-next-key-meta-x
    ghostel-test-send-next-key-function-key
    ghostel-test-send-string-routes-to-send-string
    ghostel-test-send-key-obsolete-alias-still-works
    ghostel-test-send-string-errors-outside-ghostel-buffer
    ghostel-test-send-key-routes-to-send-encoded
    ghostel-test-send-key-nil-mods-becomes-empty-string
    ghostel-test-send-key-errors-outside-ghostel-buffer
    ghostel-test-paste-string-routes-to-paste-text
    ghostel-test-paste-string-errors-outside-ghostel-buffer
    ghostel-test-local-host-p
    ghostel-test-update-directory-remote
    ghostel-test-get-shell-local
    ghostel-test-fish-auto-inject-loads-integration
    ghostel-test-tramp-inside-emacs-preserves-ghostel-prefix
    ghostel-test-remote-term-preamble
    ghostel-test-spawn-pty-uses-remote-term-preamble
    ghostel-test-resize-window-adjust
    ghostel-test-resize-nil-size
    ghostel-test-resize-noop-same-dims
    ghostel-test-sigwinch-reaches-shell-basic
    ghostel-test-sigwinch-reaches-shell-ghostel-style
    ghostel-test-sigwinch-reaches-child-process
    ghostel-test-sigwinch-via-ghostel-resize-handler
    ghostel-test-command-finish-hook
    ghostel-test-command-finish-hook-error-caught
    ghostel-test-command-finish-hook-error-isolated
    ghostel-test-command-finish-hook-runs-synchronously
    ghostel-test-command-start-hook-runs-synchronously
    ghostel-test-compile-finalize-scans-errors
    ghostel-test-compile-finalize-appends-footer
    ghostel-test-compile-finalize-footer-on-failure
    ghostel-test-compile-finalize-trims-trailing-blank-rows
    ghostel-test-compile-finalize-colors-errors
    ghostel-test-compile-finalize-preserves-face-props
    ghostel-test-compile-finalize-does-not-double-count-errors
    ghostel-test-compile-finalize-does-not-kill-buffer
    ghostel-test-compile-view-mode-n-p-navigate-without-opening
    ghostel-test-compile-finalize-leaves-point-at-end
    ghostel-test-compile-finalize-pins-default-directory
    ghostel-test-compile-recompile-uses-original-directory
    ghostel-test-compile-recompile-reuses-current-buffer
    ghostel-test-compile-recompile-edit-command-prefix-arg
    ghostel-test-compile-finalize-switches-major-mode
    ghostel-test-compile-view-mode-recompile-key-binding
    ghostel-test-compile-format-duration
    ghostel-test-compile-status-message
    ghostel-test-compile-mode-line-running
    ghostel-test-compile-mode-line-exit
    ghostel-test-compile-finish-hooks-fire
    ghostel-test-compile-auto-jump-to-first-error
    ghostel-test-compile-recompile-without-history
    ghostel-test-compile-uses-compile-command
    ghostel-test-compile-interactive-uses-compile-history
    ghostel-test-compile-respects-compilation-read-command
    ghostel-test-compile-prepare-buffer-no-window-side-effects
    ghostel-test-compile-finalize-is-idempotent
    ghostel-test-compile-global-mode-toggles-advice
    ghostel-test-compile-global-mode-falls-through-for-grep
    ghostel-test-compile-global-mode-routes-to-ghostel-start
    ghostel-test-compile-global-mode-threads-subclass-mode
    ghostel-test-compile-global-mode-falls-through-on-continue
    ghostel-test-compile-global-mode-falls-through-on-comint
    ghostel-test-compile-global-mode-excluded-custom-mode
    ghostel-test-compile-reconciles-vt-size-to-outwin
    ghostel-test-compile-reconciles-skips-when-no-outwin
    ghostel-test-viewport-start-skips-trailing-newline
    ghostel-test-anchor-window-no-clamp-without-pending-wrap
    ghostel-test-delayed-redraw-preserves-preedit-anchor
    ghostel-test-preedit-window-fallback
    ghostel-test-exec-errors-on-live-process
    ghostel-test-exec-calls-spawn-pty-with-expected-args
    ghostel-test-exec-threads-remote-p-from-tramp-dir
    ghostel-test-exec-uses-default-size-when-buffer-not-displayed
    ghostel-test-environment-precedes-internal-env
    ghostel-test-environment-applies-to-compile
    ghostel-test-environment-honors-dir-locals
    ghostel-test-environment-rejects-unsafe-dir-locals
    ghostel-test-delayed-redraw-defers-plain-link-detection
    ghostel-test-delayed-redraw-coalesces-plain-link-detection
    ghostel-test-detect-urls-allows-read-only-buffers
    ghostel-test-url-detection
    ghostel-test-zero-delay-runs-plain-link-detection-synchronously
    ghostel-test-sentinel-cancels-plain-link-detection-timer
    ghostel-test-compile-prepare-buffer-sets-dir-before-mode
    ghostel-test-eshell-visual-command-mode-toggles-advice
    ghostel-test-eshell/ghostel-dispatches-to-exec-visual
    ghostel-test-terminfo-directory-finds-bundled
    ghostel-test-debug-keypress-renders-capture
    ghostel-test-debug-info-environment-section
    ghostel-test-uri-at-pos-prefers-string-help-echo
    ghostel-test-uri-at-pos-calls-native-for-function-help-echo
    ghostel-test-native-link-help-echo-calls-uri-at-pos
    ghostel-test-detect-cell-pixel-scale-standard-dpi
    ghostel-test-detect-cell-pixel-scale-hidpi
    ghostel-test-detect-cell-pixel-scale-fractional
    ghostel-test-detect-cell-pixel-scale-low-dpi-clamped
    ghostel-test-detect-cell-pixel-scale-zero-mm-returns-nil
    ghostel-test-detect-cell-pixel-scale-non-graphic-returns-nil
    ghostel-test-cell-pixel-scale-numeric-override
    ghostel-test-cell-pixel-scale-numeric-override-floor-1
    ghostel-test-cell-pixel-scale-auto-falls-back-to-1
    ghostel-test-reported-cell-dims-multiply-frame-by-scale
    ghostel-test-kitty-display-image-tags-region
    ghostel-test-kitty-display-image-empty-line-uses-overlay
    ghostel-test-kitty-clear-strips-only-tagged-regions
    ghostel-test-kitty-clear-removes-overlays
    ghostel-test-kitty-clear-noop-when-inactive
    ghostel-test-kitty-clear-strips-orphan-fragment-after-eviction
    ghostel-test-kitty-clear-strips-collapsed-overlay-stack
    ghostel-test-kitty-clear-preserves-intact-image-at-top
    ghostel-test-kitty-clear-resets-sticky-flag-when-empty
    ghostel-test-kitty-clear-preserves-scrollback-overlays
    ghostel-test-kitty-display-image-skips-scrollback-rows
    ghostel-test-kitty-display-virtual-tags-placeholder-line
    ghostel-test-kitty-display-image-records-error
    ghostel-test-kitty-display-image-rejects-source-rect
    ghostel-test-kitty-display-image-clamps-negative-vp-col
    ghostel-test-kitty-display-image-fully-off-screen-skipped)
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
