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

(ert-deftest ghostel-test-text-scale-change-forces-size-adjustment ()
  "Text-scale changes use a forced size adjustment."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--input-mode 'semi-char)
          (adjust-args nil))
      (cl-letf (((symbol-function 'get-buffer-window)
                 (lambda (&rest _) 'fake-window))
                ((symbol-function 'ghostel--adjust-size)
                 (lambda (&rest args) (setq adjust-args args))))
        (ghostel--text-scale-changed)
        (should (equal '(fake-window t) adjust-args))))))

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
        invalidate-called)
    (unwind-protect
        (with-current-buffer ghostel-buf
          (setq-local ghostel--event-buf nil)
          (cl-letf (((symbol-function 'process-buffer) (lambda (_) ghostel-buf))
                    ((symbol-function 'ghostel--invalidate)
                     (lambda () (setq invalidate-called (current-buffer)))))
            (ghostel--events-filter
             'fake-proc
             (format "(set-buffer %S)(setq-local ghostel-test--event-buffer-ok t)"
                     (buffer-name other-buf))))
          (should (eq (current-buffer) ghostel-buf))
          (should (eq invalidate-called ghostel-buf))
          (should (bound-and-true-p ghostel-test--event-buffer-ok))
          (should-not (local-variable-p 'ghostel-test--event-buffer-ok
                                        other-buf)))
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

(provide 'ghostel-terminal-test)
;;; ghostel-terminal-test.el ends here
