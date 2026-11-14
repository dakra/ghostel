;;; ghostel-terminal-test.el --- Tests for ghostel: terminal -*- lexical-binding: t; -*-

;;; Commentary:

;; Core VT primitives: terminal lifecycle, write-input, cursor mvmt, erase, resize.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-create ()
  "Test terminal creation and basic properties."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (should term)                                         ; create returns non-nil
    (should (equal "" (ghostel-test--row0 term)))         ; row0 is blank
    (should (equal '(0 . 0) (ghostel-test--cursor term))) ; cursor at origin
    ))

(ert-deftest ghostel-test-write-input ()
  "Test feeding text to the terminal."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "hello")
    (should (equal "hello" (ghostel-test--row0 term)))        ; text appears
    (should (equal '(5 . 0) (ghostel-test--cursor term)))     ; cursor after text

    ;; CRLF starts a fresh line at column 0.
    (ghostel--write-vt term " world\r\nline2")
    (let ((state (ghostel--copy-all-text term)))
      (should (string-match-p "hello world" state))  ; row0 has full first line
      (should (string-match-p "line2" state)))))      ; row1 has line2

(ert-deftest ghostel-test-write-pty-without-process-is-noop ()
  "PTY input is a no-op when there is no process."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (ghostel--process nil))
    (should (ghostel--write-pty term "input"))))

(ert-deftest ghostel-test-write-pty-preserves-quit ()
  "PTY input preserves keyboard quit from the Emacs process."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (ghostel--process 'fake-process))
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_process _string) (signal 'quit nil))))
      (should (eq 'quit
                  (condition-case nil
                      (ghostel--write-pty term "input")
                    (quit 'quit)))))))

(ert-deftest ghostel-test-write-input-preserves-bare-lf-on-primary ()
  "On the primary screen, a bare LF preserves the column.
The emulator never synthesizes a CR: cooked-mode \\n is turned into
CRLF by the PTY's ONLCR (on by default in the line discipline), and
raw-mode apps that emit bare LF mean a column-preserving linefeed.
Synthesizing a CR collapsed inline TUIs that position with
column-preserving LF + relative CUB to the left margin (issue #388,
the Antigravity CLI logo)."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "abc\ndef")
    ;; Column preserved, so "def" lands at (6 . 1), not (3 . 1).
    (should (equal '(6 . 1) (ghostel-test--cursor term)))))

(ert-deftest ghostel-test-write-input-preserves-bare-lf-on-alt-screen-1049 ()
  "Bare LF preserves the column on the alternate screen (DECSET 1049).
Apps that target the alt screen, such as tmux, vim and less, emit
VT-correct LF that moves the cursor down with the column preserved,
the same as the primary screen now does."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "\e[?1049h")
    (ghostel--write-vt term "abc\ndef")
    ;; Bare LF: column preserved, so "def" lands at (6 . 1).
    (should (equal '(6 . 1) (ghostel-test--cursor term)))))

(ert-deftest ghostel-test-write-input-preserves-bare-lf-on-alt-screen-1047 ()
  "Alt-screen detection covers DECSET 1047 as well as 1049."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "\e[?1047h")
    (ghostel--write-vt term "abc\ndef")
    (should (equal '(6 . 1) (ghostel-test--cursor term)))))

(ert-deftest ghostel-test-write-input-preserves-bare-lf-on-alt-screen-47 ()
  "Alt-screen detection covers the legacy DECSET 47 mode.
Detection is via `screens.active_key', so the three alt-screen entry
modes (47 / 1047 / 1049) are handled uniformly."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "\e[?47h")
    (ghostel--write-vt term "abc\ndef")
    (should (equal '(6 . 1) (ghostel-test--cursor term)))))


(ert-deftest ghostel-test-backspace ()
  "Test backspace (BS) processing by the terminal."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "hello")
    (should (equal "hello" (ghostel-test--row0 term)))        ; before BS

    ;; BS + space + BS erases last character
    (ghostel--write-vt term "\b \b")
    (should (equal "hell" (ghostel-test--row0 term)))         ; after 1 BS
    (should (equal '(4 . 0) (ghostel-test--cursor term)))     ; cursor after BS

    ;; Multiple backspaces
    (ghostel--write-vt term "\b \b\b \b")
    (should (equal "he" (ghostel-test--row0 term)))))         ; after 3 BS total

(ert-deftest ghostel-test-cursor-movement ()
  "Test CSI cursor movement sequences."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "abcdef")
    (ghostel--write-vt term "\e[3D")
    (should (equal '(3 . 0) (ghostel-test--cursor term)))     ; cursor left 3

    (ghostel--write-vt term "\e[1C")
    (should (equal '(4 . 0) (ghostel-test--cursor term)))     ; cursor right 1

    (ghostel--write-vt term "\e[H")
    (should (equal '(0 . 0) (ghostel-test--cursor term)))     ; cursor home

    ;; Cursor to specific position (row 3, col 5 — 1-based in CSI)
    (ghostel--write-vt term "\e[4;6H")
    (should (equal '(5 . 3) (ghostel-test--cursor term)))))   ; cursor to (5,3)

(ert-deftest ghostel-test-cursor-position ()
  "Test `ghostel--cursor-pos' set to correct (COL . ROW)."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--redraw term)

    ;; Origin
    (should (equal '(0 . 0) ghostel--cursor-pos))

    ;; After writing text
    (ghostel--write-vt term "hello")
    (ghostel--redraw term)
    (should (equal '(5 . 0) ghostel--cursor-pos))

    ;; After cursor movement
    (ghostel--write-vt term "\e[3D")
    (ghostel--redraw term)
    (should (equal '(2 . 0) ghostel--cursor-pos))

    ;; After CRLF — cursor on row 1 at column 0
    (ghostel--write-vt term "\r\nworld")
    (ghostel--redraw term)
    (should (equal '(5 . 1) ghostel--cursor-pos))

    ;; Absolute positioning
    (ghostel--write-vt term "\e[4;6H")
    (ghostel--redraw term)
    (should (equal '(5 . 3) ghostel--cursor-pos))))

(ert-deftest ghostel-test-redraw-publishes-cursor-style-buffer-locals ()
  "Native redraw publishes cursor style data without applying it."
  :tags '(native)
  (with-temp-buffer
    (let ((term (ghostel--new 25 80 1000)))
      (setq-local cursor-type 'box)
      (ghostel--write-vt term "\e[?25l")
      (ghostel--redraw term)
      (should-not ghostel--cursor-style)
      (should (equal cursor-type 'box)))))

(ert-deftest ghostel-test-erase ()
  "Test CSI erase sequences."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "hello world")
    (ghostel--write-vt term "\e[6D")   ; cursor left 6 (on 'w')
    (ghostel--write-vt term "\e[K")    ; erase to end of line
    (should (equal "hello" (ghostel-test--row0 term)))    ; erase to EOL

    (ghostel--write-vt term "\e[2K")
    (should (equal "" (ghostel-test--row0 term)))))       ; erase whole line

(ert-deftest ghostel-test-resize ()
  "Test terminal resize."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-vt term "hello")
    (ghostel--set-size term 10 40)
    (should (equal "hello" (ghostel-test--row0 term)))    ; content survives resize
    ;; Write long text to verify new width
    (ghostel--write-vt term "\r\n")
    (ghostel--write-vt term (make-string 40 ?x))
    (let ((state (ghostel--copy-all-text term)))
      (should (string-match-p "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" state))))) ; 40 x's on row

(ert-deftest ghostel-test-size-reports-before-first-redraw ()
  "Size reports carry the seeded cell geometry before the first redraw.
Programs started by `ghostel-exec' query CSI 14/16 t before anything
has been rendered."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (ghostel--process 'fake-process)
        (replies nil))
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_process string) (push string replies))))
      ;; Seed the cell geometry as `ghostel--init-buffer' does;
      ;; nothing below triggers a redraw.
      (ghostel--set-size term 25 80 9 23)
      (ghostel--write-vt term "\e[16t\e[14t\e[18t")
      ;; Compare the concatenation so PTY write batching can't split
      ;; or join the three replies differently across backends.
      (should (equal (concat "\e[6;23;9t"    ; cell size in px
                             "\e[4;575;720t" ; text area in px: 25*23 x 80*9
                             "\e[8;25;80t")  ; text area in cells
                     (apply #'concat (nreverse replies))))
      ;; A pending grid resize leaves all three replies on the current grid.
      (setq replies nil)
      (ghostel--set-size term 30 100 9 23)
      (ghostel--write-vt term "\e[16t\e[14t\e[18t")
      (should (equal "\e[6;23;9t\e[4;575;720t\e[8;25;80t"
                     (apply #'concat (nreverse replies)))))))

(defun ghostel-test--mouse-presses (modes cells &optional cell-size)
  "Return the concatenated reports for left presses at CELLS.
CELLS is a list of (COL . ROW).  MODES is written first to an 80x25
terminal whose cells are CELL-SIZE, a cons (WIDTH . HEIGHT) in pixels,
one pixel square when nil."
  (let ((term (ghostel--new 25 80 1000))
        (ghostel--process 'fake-process)
        (replies nil))
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_process string) (push string replies))))
      (when cell-size
        (ghostel--set-size term 25 80 (car cell-size) (cdr cell-size)))
      (ghostel--write-vt term modes)
      (dolist (cell cells)
        (ghostel--mouse-event term 0 1 (cdr cell) (car cell) 0))
      (apply #'concat (nreverse replies)))))

(ert-deftest ghostel-test-mouse-report-cells ()
  "SGR mouse reports carry 1-based cells whatever the cell size in pixels."
  :tags '(native)
  (should (equal "\e[<0;1;1M\e[<0;41;11M\e[<0;80;25M"
                 (ghostel-test--mouse-presses
                  "\e[?1000h\e[?1006h" '((0 . 0) (40 . 10) (79 . 24))
                  '(9 . 20))))
  (should (equal "\e[32;41;11M"
                 (ghostel-test--mouse-presses
                  "\e[?1000h\e[?1015h" '((40 . 10)) '(9 . 20)))))

(ert-deftest ghostel-test-mouse-report-after-column-mode-switch ()
  "Mouse reports keep their cells when DECCOLM widens the grid in-band."
  :tags '(native)
  (should (equal "\e[<0;11;6M\e[<0;132;6M"
                 (ghostel-test--mouse-presses
                  "\e[?40h\e[?3h\e[?1000h\e[?1006h" '((10 . 5) (131 . 5))))))

(ert-deftest ghostel-test-mouse-report-pixels ()
  "SGR-Pixels mouse reports carry the pixel at the centre of the cell."
  :tags '(native)
  (should (equal "\e[<0;4;10M\e[<0;364;210M\e[<0;715;490M"
                 (ghostel-test--mouse-presses
                  "\e[?1000h\e[?1006h\e[?1016h" '((0 . 0) (40 . 10) (79 . 24))
                  '(9 . 20))))
  ;; A one-pixel cell reports itself.
  (should (equal "\e[<0;40;10M"
                 (ghostel-test--mouse-presses
                  "\e[?1000h\e[?1006h\e[?1016h" '((40 . 10))))))

(ert-deftest ghostel-test-mouse-report-clamps-to-grid ()
  "A mouse position outside the grid reports the nearest cell."
  :tags '(native)
  (should (equal "\e[<0;80;25M\e[<0;1;1M"
                 (ghostel-test--mouse-presses
                  "\e[?1000h\e[?1006h" '((85 . 30) (-1 . -1)) '(9 . 20))))
  (should (equal "\e[<0;715;490M\e[<0;4;10M"
                 (ghostel-test--mouse-presses
                  "\e[?1000h\e[?1006h\e[?1016h" '((85 . 30) (-1 . -1))
                  '(9 . 20)))))

(defmacro ghostel-test--with-resize-stubs (size &rest body)
  "Run BODY with resize stubs returning SIZE for process window size."
  (declare (indent 1))
  `(let ((cur-buf (current-buffer)))
     (cl-letf (((symbol-function 'ghostel--window-anchored-p)
                (lambda (&rest _) nil))
               ((symbol-function 'window-old-body-pixel-height)
                (lambda (_window) nil))
               ((symbol-function 'ghostel--windows)
                (lambda (&rest _) '(fake-win)))
               ((symbol-function 'process-buffer)
                (lambda (_proc) cur-buf))
               ((symbol-function 'window-buffer)
                (lambda (&optional _window) cur-buf))
               ((default-value 'window-adjust-process-window-size-function)
                (lambda (_proc _wins) ,size)))
       ,@body)))

(ert-deftest ghostel-test-resize-window-adjust ()
  "Window adjust resizes the VT and marks redraw state."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term h w) (setq set-size-args (list h w))))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq redraw-called t))))
        (ghostel-test--with-resize-stubs '(120 . 40)
		  (ghostel--adjust-size 'fake-window))
        (should (equal '(40 120) set-size-args))
        (should ghostel--force-next-redraw)
        (should redraw-called)))))

(ert-deftest ghostel-test-resize-nil-size ()
  "When the default function returns nil, no resize happens."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (set-size-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term _h _w) (setq set-size-called t))))
        (ghostel-test--with-resize-stubs nil
		  (ghostel--adjust-size 'fake-window))
        (should-not set-size-called)))))

(ert-deftest ghostel-test-resize-noop-same-dims ()
  "Resize to identical dims skips set-size."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term _h _w) (setq set-size-called t)))
                ((symbol-function 'ghostel--redraw-now) #'ignore))
        (ghostel-test--with-resize-stubs '(120 . 40)
		  (ghostel--adjust-size 'fake-window))
        (should-not set-size-called)))))

(ert-deftest ghostel-test-resize-function-replaces-set-size ()
  "Without a process, `ghostel--resize-function' receives the fitted size."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (resized nil)
          (received nil))
      (setq-local ghostel--resize-function
                  (lambda (size) (setq received size)))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (&rest _) (setq resized t)))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buffer) (setq resized t))))
        (ghostel-test--with-resize-stubs '(120 . 40)
          (ghostel--adjust-size 'fake-window)))
      (should (equal '(120 . 40) received))
      (should-not resized))))

(ert-deftest ghostel-test-resize-force-same-dims-still-runs ()
  "Forced resize runs even when rows and cols are unchanged."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (term h w) (setq set-size-args (list term h w))))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (buffer)
                   (should (eq buffer (current-buffer)))
                   (setq redraw-called ghostel--force-next-redraw))))
        (ghostel-test--with-resize-stubs '(120 . 40)
		  (ghostel--adjust-size 'fake-window t))
        (should (equal '(fake 40 120) set-size-args))
        (should ghostel--force-next-redraw)
        (should redraw-called)))))

(ert-deftest ghostel-test-resize-window-buffer-not-current ()
  "Resize works when WINDOW's buffer is not the current buffer.
Buffer-local `window-size-change-functions' are run by redisplay with
an arbitrary buffer current, so `ghostel--adjust-size' must resolve
the terminal from WINDOW's buffer rather than the ambient current
buffer.  Regression test: a split from another window (or any
programmatic resize) silently skipped the resize, leaving the grid at
its old size."
  (with-temp-buffer
    (let ((set-size-args nil))
      (setq-local ghostel--term 'fake
                  ghostel--process 'fake-proc
                  ghostel--force-next-redraw nil)
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term h w) (setq set-size-args (list h w))))
                ((symbol-function 'ghostel--redraw-now) #'ignore))
        (ghostel-test--with-resize-stubs '(120 . 40)
          (with-temp-buffer            ; unrelated buffer is current
            (ghostel--adjust-size 'fake-window))))
      (should (equal '(40 120) set-size-args))
      (should ghostel--force-next-redraw))))

(ert-deftest ghostel-test-windows-excludes-daemon-dummy-frame ()
  "`ghostel--windows' drops windows on the daemon's dummy initial frame.
Killing a buffer can substitute a ghostel buffer into that invisible
80x24 frame, which then clamps the PTY size (#504)."
  (let ((buf (generate-new-buffer " *ghostel-test-dummy-frame*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-mode 'ghostel-mode))
          (set-window-buffer (selected-window) buf)
          (should (memq (selected-window) (ghostel--windows buf t)))
          (cl-letf (((symbol-function 'daemonp) (lambda () t)))
            ;; Selected frame plays the daemon's initial frame.
            (let ((terminal-frame (selected-frame)))
              (should-not (ghostel--windows buf t)))
            ;; Some other frame is the dummy one: window stays.
            (let ((terminal-frame 'other-frame))
              (should (memq (selected-window) (ghostel--windows buf t))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-local-font-scale-refits-anchored-window ()
  "Local font scaling resizes and re-anchors previously anchored windows."
  (let ((buf (generate-new-buffer " *ghostel-test-local-font-scale*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (let ((ghostel--term 'fake)
                  (ghostel--input-mode 'semi-char)
                  (phase 'before)
                  (adjust-args nil)
                  (anchor-args nil))
              (cl-letf (((symbol-function 'ghostel--window-anchored-p)
                         (lambda (window &optional _body-pixel-height)
                           (and (eq window (selected-window))
                                (eq phase 'before))))
                        ((symbol-function 'ghostel--terminal-live-p)
                         (lambda () t))
                        ((symbol-function 'ghostel--adjust-size)
                         (lambda (&rest args) (setq adjust-args args)))
                        ((symbol-function 'ghostel--anchor-window)
                         (lambda (&rest args) (setq anchor-args args))))
                (should (eq 'scaled
                            (ghostel--around-local-font-scale
                             (lambda ()
                               (setq phase 'after)
                               'scaled))))
                (should (equal (list (selected-window) t) adjust-args))
                (should (equal (list (selected-window)) anchor-args))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-resize-rows-only-during-minibuffer-suppressed ()
  "Rows-only resize while a minibuffer is active is deferred (#268).
fish (and other shells with `fish_handle_reflow' on) clears and
re-emits its prompt on every SIGWINCH.  A `consult-buffer'/`M-x'
cycle shrinks then re-grows the body and would otherwise produce
two prompt repaints in quick succession — visible as flicker."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-called nil)
          (redraw-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term _h _w) (setq set-size-called t)))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq redraw-called t)))
                ((symbol-function 'active-minibuffer-window)
                 (lambda () 'fake-mini-win))
                ((symbol-function 'ghostel--alt-screen-p)
                 (lambda (_term) nil)))
        (ghostel-test--with-resize-stubs '(120 . 32)
		  (ghostel--adjust-size 'fake-window))
        (should-not set-size-called)
        (should-not redraw-called)
        (should (= 40 ghostel--term-rows))
        (should (= 120 ghostel--term-cols))))))

(ert-deftest ghostel-test-resize-rows-only-during-minibuffer-on-alt-screen-still-resizes ()
  "Alt-screen TUIs bypass the minibuffer deferral and resize normally.
vim/htop/less re-render against $LINES and would draw with stale
dimensions otherwise."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term h w) (setq set-size-args (list h w))))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq redraw-called t)))
                ((symbol-function 'active-minibuffer-window)
                 (lambda () 'fake-mini-win))
                ((symbol-function 'ghostel--alt-screen-p)
                 (lambda (_term) t)))
        (ghostel-test--with-resize-stubs '(120 . 32)
		  (ghostel--adjust-size 'fake-window))
        (should (equal '(32 120) set-size-args))
        (should ghostel--force-next-redraw)
        (should redraw-called)))))

(ert-deftest ghostel-test-resize-rows-only-outside-minibuffer-still-resizes ()
  "Rows-only resize with no minibuffer active goes through the normal path.
Genuine vertical resizes like `C-x 2' must still propagate to the
shell so $LINES stays accurate."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term h w) (setq set-size-args (list h w))))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq redraw-called t)))
                ((symbol-function 'active-minibuffer-window)
                 (lambda () nil)))
        (ghostel-test--with-resize-stubs '(120 . 32)
		  (ghostel--adjust-size 'fake-window))
        (should (equal '(32 120) set-size-args))
        (should ghostel--force-next-redraw)
        (should redraw-called)))))

(ert-deftest ghostel-test-resize-cols-change-during-minibuffer-still-resizes ()
  "Cols change during a minibuffer still goes through the normal path.
The deferral only applies to rows-only deltas; a column change means
real reflow that the shell needs to know about regardless of
minibuffer state."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term h w) (setq set-size-args (list h w))))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq redraw-called t)))
                ((symbol-function 'active-minibuffer-window)
                 (lambda () 'fake-mini-win)))
        (ghostel-test--with-resize-stubs '(100 . 40)
		  (ghostel--adjust-size 'fake-window))
        (should (equal '(40 100) set-size-args))
        (should ghostel--force-next-redraw)
        (should redraw-called)))))

(ert-deftest ghostel-test-cleanup-temp-paths-handles-files-and-dirs ()
  "`ghostel--cleanup-temp-paths' deletes files and recursively deletes dirs.
Mirrors the real zsh case where the directory still contains a
`.zshenv' at cleanup time."
  :tags '(native)
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

(ert-deftest ghostel-test-filter-write-input-preserves-buffer ()
  "Regression for #82: buffer switches in native callbacks do not leak out.
A buffer switch performed by a synchronous native callback (as OSC 52;e
dispatch does when it calls `find-file-other-window') must not affect
later `ghostel--filter' logic.  Otherwise the filter reads buffer-local
state from the wrong buffer after feeding output to the native module."
  (let ((ghostel-buf (generate-new-buffer " *ghostel-test-filter-buf*"))
        (other-buf (generate-new-buffer " *ghostel-test-filter-other*"))
        invalidate-called)
    (unwind-protect
        (with-current-buffer ghostel-buf
          (setq-local ghostel--term 'fake-handle)
          (cl-letf (((symbol-function 'process-buffer) (lambda (_) ghostel-buf))
                    ((symbol-function 'ghostel--write-vt)
                     (lambda (_term _data)
                       ;; Simulate `find-file-other-window' flipping
                       ;; the current buffer via `select-window'.
                       (set-buffer other-buf)))
                    ((symbol-function 'ghostel--invalidate)
                     (lambda () (setq invalidate-called (current-buffer)))))
            (ghostel--filter 'fake-proc "payload"))
          (should (eq (current-buffer) ghostel-buf))
          (should (eq invalidate-called ghostel-buf)))
      (kill-buffer ghostel-buf)
      (kill-buffer other-buf))))

(ert-deftest ghostel-test-events-filter-preserves-buffer ()
  "Native event callbacks do not leak buffer switches into invalidation."
  (let ((ghostel-buf (generate-new-buffer " *ghostel-test-events-buf*"))
        (other-buf (generate-new-buffer " *ghostel-test-events-other*"))
        (pipe (make-pipe-process :name "ghostel-test-events" :noquery t))
        invalidate-called)
    (unwind-protect
        (with-current-buffer ghostel-buf
          (cl-letf (((symbol-function 'process-buffer) (lambda (_) ghostel-buf))
                    ((symbol-function 'ghostel--invalidate)
                     (lambda () (setq invalidate-called (current-buffer)))))
            (ghostel--events-filter
             pipe
             (format "(set-buffer %S)(setq-local ghostel-test--event-buffer-ok t)"
                     (buffer-name other-buf))))
          (should (eq (current-buffer) ghostel-buf))
          (should (eq invalidate-called ghostel-buf))
          (should (bound-and-true-p ghostel-test--event-buffer-ok))
          (should-not (local-variable-p 'ghostel-test--event-buffer-ok
                                        other-buf)))
      (delete-process pipe)
      (kill-buffer ghostel-buf)
      (kill-buffer other-buf))))

(ert-deftest ghostel-test-apply-cursor-style-from-render-state ()
  "Apply cursor style from buffer-local render state."
  (let ((buf (generate-new-buffer " *ghostel-test-apply-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq cursor-type 'box)
          (setq-local ghostel--cursor-style 0)
          (ghostel--apply-cursor-style)
          (should (equal cursor-type '(bar . 2)))
          (setq-local ghostel--cursor-style 2)
          (ghostel--apply-cursor-style)
          (should (equal cursor-type '(hbar . 2)))
          (setq-local ghostel--cursor-style nil)
          (ghostel--apply-cursor-style)
          (should (null cursor-type)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-ignore-cursor-change ()
  "Test that `ghostel-ignore-cursor-change' suppresses cursor style updates."
  (let ((buf (generate-new-buffer " *ghostel-test-ignore-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Default: cursor changes are applied
          (let ((ghostel-ignore-cursor-change nil))
            (setq cursor-type 'box)
            (setq-local ghostel--cursor-style 2)
            (ghostel--apply-cursor-style)
            (should (equal cursor-type '(hbar . 2))))
          ;; With ignore: cursor changes are suppressed
          (let ((ghostel-ignore-cursor-change t))
            (setq cursor-type 'box)
            (setq-local ghostel--cursor-style 1)
            (ghostel--apply-cursor-style)
            (should (equal cursor-type 'box))))  ; unchanged
      (kill-buffer buf))))

(ert-deftest ghostel-test-cursor-blink ()
  "A blinking cursor request starts the blink timer; steady cancels it."
  (let ((buf (generate-new-buffer " *ghostel-test-cursor-blink*")))
    (unwind-protect
        ;; Pretend we are on a graphical display and the user has the
        ;; global blink off, so `ghostel--cursor-blink-start' engages.
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
          (with-current-buffer buf
            (ghostel-mode)
            (let ((blink-cursor-mode nil))
              ;; Blinking block requested -> timer running, box shape,
              ;; and both blink hooks installed buffer-locally.
              (setq ghostel--cursor-blinking t)
              (setq ghostel--cursor-style 1)
              (ghostel--apply-cursor-style)
              (should (equal cursor-type 'box))
              (should (timerp ghostel--cursor-blink-timer))
              (should (memq #'ghostel--cursor-blink-restore-window
                            window-buffer-change-functions))
              (should (memq #'ghostel--cursor-blink-stop kill-buffer-hook))
              ;; Steady request -> timer cancelled and hooks removed.
              (setq ghostel--cursor-blinking nil)
              (setq ghostel--cursor-style 1)
              (ghostel--apply-cursor-style)
              (should-not ghostel--cursor-blink-timer)
              (should-not (memq #'ghostel--cursor-blink-restore-window
                                window-buffer-change-functions))
              (should-not (memq #'ghostel--cursor-blink-stop kill-buffer-hook))
              ;; Blinking again, then hidden cursor -> cancelled, hooks gone.
              (setq ghostel--cursor-blinking t)
              (setq ghostel--cursor-style 0)
              (ghostel--apply-cursor-style)
              (should (timerp ghostel--cursor-blink-timer))
              (setq ghostel--cursor-style nil)
              (ghostel--apply-cursor-style)
              (should-not ghostel--cursor-blink-timer)
              (should-not (memq #'ghostel--cursor-blink-restore-window
                                window-buffer-change-functions)))))
      ;; `kill-buffer' runs the buffer-local `kill-buffer-hook' that
      ;; `ghostel--cursor-blink-start' installs, cancelling any timer.
      (kill-buffer buf))))


(ert-deftest ghostel-test-write-vt-accepts-raw-byte-chars ()
  "A string holding raw-byte chars reaches the terminal as those bytes."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf term 5 80 1000)
    (let ((inhibit-read-only t))
      (ghostel--write-vt term (concat "a" (string #x3fffe6) "b\r\n"))
      (ghostel--redraw term t)
      (should (string-match-p "\\`a.b$" (buffer-substring-no-properties
                                        (point-min) (line-end-position)))))))

(defun ghostel-test--snapshot-fixture ()
  "Return the snapshot bytes of ghostty's testdata at the pinned commit."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "fixtures/snapshot-unknown-records-v1.hex"
                       (file-name-directory
                        (locate-library "ghostel-terminal-test"))))
    (apply #'unibyte-string
           (mapcar (lambda (byte) (string-to-number byte 16))
                   (split-string
                    (replace-regexp-in-string "#.*" "" (buffer-string)))))))

(ert-deftest ghostel-test-snapshot-restore ()
  "A snapshot restores the screen and the terminal keeps accepting output."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--restore-snapshot term (ghostel-test--snapshot-fixture))
    (should (equal "B\n\nC" (ghostel--copy-all-text term)))
    (ghostel--write-vt term "!")
    (should (string-match-p "!" (ghostel--copy-all-text term)))))

(ert-deftest ghostel-test-snapshot-restore-applies-buffer-settings ()
  "`ghostel-restore-snapshot' reapplies colors and schedules a full redraw."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buffer term 25 80 1000)
    (let (applied)
      (cl-letf (((symbol-function 'ghostel--apply-palette)
                 (lambda (arg) (push arg applied)))
                ((symbol-function 'ghostel--invalidate) #'ignore))
        (ghostel-restore-snapshot (ghostel-test--snapshot-fixture)))
      (should (equal (list term) applied))
      (should ghostel--force-next-redraw))))

(ert-deftest ghostel-test-snapshot-restore-read-only-buffer ()
  "`ghostel-restore-snapshot' replaces a read-only buffer's text."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buffer term 25 80 1000)
    (let ((inhibit-read-only t))
      (insert "old"))
    (setq buffer-read-only t)
    (ghostel-restore-snapshot (ghostel-test--snapshot-fixture))
    (should-not (string-match-p "old" (buffer-string)))
    (should-not ghostel--repair-pending)))

(ert-deftest ghostel-test-snapshot-restore-keeps-cell-size ()
  "`ghostel-restore-snapshot' keeps the terminal's cell size in pixels."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buffer term 25 80 1000)
    (let (sent)
      (setq ghostel--pty-out-function (lambda (data) (push data sent)))
      (cl-letf (((symbol-function 'ghostel--reported-cell-width) (lambda () 9))
                ((symbol-function 'ghostel--reported-cell-height) (lambda () 18)))
        (ghostel-restore-snapshot (ghostel-test--snapshot-fixture)))
      (ghostel--write-vt term "\e[16t")
      (should (equal "\e[6;18;9t" (car sent))))))

(ert-deftest ghostel-test-snapshot-rejects-bad-data ()
  "Anything but exactly one snapshot signals an error."
  :tags '(native)
  (let ((snapshot (ghostel-test--snapshot-fixture))
        (term (ghostel--new 25 80 1000)))
    (should-error (ghostel--restore-snapshot term "not a snapshot"))
    (should-error (ghostel--restore-snapshot term (substring snapshot 0 100)))
    (should-error (ghostel--restore-snapshot term (concat snapshot "tail")))))

(ert-deftest ghostel-test-snapshot-restore-without-scrollback ()
  "A terminal without scrollback drops the snapshot's history."
  :tags '(native)
  (let ((term (ghostel--new 25 80 0)))
    (ghostel--restore-snapshot term (ghostel-test--snapshot-fixture))
    (should (equal "C" (ghostel--copy-all-text term)))))

(ert-deftest ghostel-test-snapshot-restore-keeps-own-scrollback-limit ()
  "A restored terminal keeps the scrollback limit it was created with."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--restore-snapshot term (ghostel-test--snapshot-fixture))
    ;; The fixture's 2x2 terminal holds thousands of rows per page.
    (dotimes (i 30000) (ghostel--write-vt term (format "line %d\r\n" i)))
    (should (< (length (split-string (ghostel--copy-all-text term) "\n"))
               10000))))

(ert-deftest ghostel-test-init-buffer-clears-bridge-functions ()
  "Reinitializing a buffer drops the functions of its previous bridge."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buffer term 25 80 1000)
    (setq ghostel--pty-out-function #'ignore
          ghostel--resize-function #'ignore
          ghostel--send-files-function #'ignore)
    (ghostel--init-buffer buffer 25 80)
    (should-not ghostel--pty-out-function)
    (should-not ghostel--resize-function)
    (should-not ghostel--send-files-function)))

(ert-deftest ghostel-test-pty-out-function-receives-output ()
  "Outbound bytes reach `ghostel--pty-out-function' when there is no process."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buffer term 25 80 1000)
    (let (sent)
      (setq ghostel--pty-out-function (lambda (data) (push data sent)))
      (ghostel--write-pty term "typed")
      ;; A DA1 query is answered through the same hook.
      (ghostel--write-vt term "\e[c")
      (should (equal "typed" (car (last sent))))
      (should (string-prefix-p "\e[?" (car sent)))
      ;; The hook also counts as a live terminal for insert forwarding.
      (ghostel--sync-read-only)
      (should-not buffer-read-only))))

(ert-deftest ghostel-test-paste-is-one-pty-write ()
  "A paste reaches `ghostel--pty-out-function' in a single call."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buffer term 25 80 1000)
    (let (sent)
      (setq ghostel--pty-out-function (lambda (data) (push data sent)))
      (ghostel--write-vt term "\e[?2004h")
      (ghostel-paste-string "one\ntwo")
      (should (equal '("\e[200~one\ntwo\e[201~") sent))
      (setq sent nil)
      (ghostel-paste-string "")
      (should (equal '("\e[200~\e[201~") sent))
      (setq sent nil)
      (ghostel--write-vt term "\e[?2004l")
      (ghostel-paste-string "one\ntwo")
      (should (equal '("one\rtwo") sent))
      (setq sent nil)
      (ghostel-paste-string "")
      (should-not sent))))

(provide 'ghostel-terminal-test)
;;; ghostel-terminal-test.el ends here
