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
    (ghostel--write-input term "hello")
    (should (equal "hello" (ghostel-test--row0 term)))        ; text appears
    (should (equal '(5 . 0) (ghostel-test--cursor term)))     ; cursor after text

    ;; Newline (CRLF — the Zig module normalizes bare LF)
    (ghostel--write-input term " world\nline2")
    (let ((state (ghostel--copy-all-text term)))
      (should (string-match-p "hello world" state))  ; row0 has full first line
      (should (string-match-p "line2" state)))))      ; row1 has line2

(ert-deftest ghostel-test-write-input-normalizes-bare-lf-on-primary ()
  "On the primary screen, bare LF is normalized to CRLF.
Emacs PTYs lack ONLCR, so a bare \\n from subprocess output needs an
inserted \\r to land at column 0 of the next row."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "abc\ndef")
    ;; Inserted \r resets the column; "def" lands at (3 . 1), not (6 . 1).
    (should (equal '(3 . 1) (ghostel-test--cursor term)))))

(ert-deftest ghostel-test-write-input-preserves-bare-lf-on-alt-screen-1049 ()
  "On the alternate screen (DECSET 1049), bare LF preserves the column.
Apps that target the alt screen (tmux, vim, less) emit VT-correct LF
that moves the cursor down with the column preserved; prepending CR
would corrupt their layout, e.g. tmux pane border erasure misfires."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e[?1049h")
    (ghostel--write-input term "abc\ndef")
    ;; Bare LF: column preserved, so "def" lands at (6 . 1).
    (should (equal '(6 . 1) (ghostel-test--cursor term)))))

(ert-deftest ghostel-test-write-input-preserves-bare-lf-on-alt-screen-1047 ()
  "Alt-screen detection covers DECSET 1047 as well as 1049."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e[?1047h")
    (ghostel--write-input term "abc\ndef")
    (should (equal '(6 . 1) (ghostel-test--cursor term)))))

(ert-deftest ghostel-test-write-input-preserves-bare-lf-on-alt-screen-47 ()
  "Alt-screen detection covers the legacy DECSET 47 mode.
Detection is via `screens.active_key', so the three alt-screen entry
modes (47 / 1047 / 1049) are handled uniformly."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e[?47h")
    (ghostel--write-input term "abc\ndef")
    (should (equal '(6 . 1) (ghostel-test--cursor term)))))

(ert-deftest ghostel-test-write-input-renormalizes-after-leaving-alt-screen ()
  "Leaving the alternate screen restores CRLF normalization on primary."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e[?1049h")
    (ghostel--write-input term "\e[?1049l") ; back to primary
    (ghostel--write-input term "abc\ndef")
    (should (equal '(3 . 1) (ghostel-test--cursor term)))))

(ert-deftest ghostel-test-backspace ()
  "Test backspace (BS) processing by the terminal."
  :tags '(native)
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

(ert-deftest ghostel-test-cursor-movement ()
  "Test CSI cursor movement sequences."
  :tags '(native)
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

(ert-deftest ghostel-test-cursor-position ()
  "Test `ghostel--cursor-pos' set to correct (COL . ROW)."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--redraw term)

    ;; Origin
    (should (equal '(0 . 0) ghostel--cursor-pos))

    ;; After writing text
    (ghostel--write-input term "hello")
    (ghostel--redraw term)
    (should (equal '(5 . 0) ghostel--cursor-pos))

    ;; After cursor movement
    (ghostel--write-input term "\e[3D")
    (ghostel--redraw term)
    (should (equal '(2 . 0) ghostel--cursor-pos))

    ;; After newline — cursor on row 1
    (ghostel--write-input term "\nworld")
    (ghostel--redraw term)
    (should (equal '(5 . 1) ghostel--cursor-pos))

    ;; Absolute positioning
    (ghostel--write-input term "\e[4;6H")
    (ghostel--redraw term)
    (should (equal '(5 . 3) ghostel--cursor-pos))))

(ert-deftest ghostel-test-erase ()
  "Test CSI erase sequences."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello world")
    (ghostel--write-input term "\e[6D")   ; cursor left 6 (on 'w')
    (ghostel--write-input term "\e[K")    ; erase to end of line
    (should (equal "hello" (ghostel-test--row0 term)))    ; erase to EOL

    (ghostel--write-input term "\e[2K")
    (should (equal "" (ghostel-test--row0 term)))))       ; erase whole line

(ert-deftest ghostel-test-resize ()
  "Test terminal resize."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    (ghostel--set-size term 10 40)
    (should (equal "hello" (ghostel-test--row0 term)))    ; content survives resize
    ;; Write long text to verify new width
    (ghostel--write-input term "\r\n")
    (ghostel--write-input term (make-string 40 ?x))
    (let ((state (ghostel--copy-all-text term)))
      (should (string-match-p "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" state))))) ; 40 x's on row

(ert-deftest ghostel-test-resize-window-adjust ()
  "Window adjust resizes the VT, marks redraw state, and returns dimensions."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                   (lambda (_term h w) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--redraw-now)
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
      (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                 (lambda (_term _h _w) (setq set-size-called t)))
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
        (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                   (lambda (_term _h _w) (setq set-size-called t)))
                  ((symbol-function 'ghostel--redraw-now) #'ignore)
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 40))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (null result))
            (should-not set-size-called)))))))

(ert-deftest ghostel-test-resize-rows-only-during-minibuffer-suppressed ()
  "Rows-only resize while a minibuffer is active is deferred (#268).
fish (and other shells with `fish_handle_reflow' on) clears and
re-emits its prompt on every SIGWINCH.  A `consult-buffer'/`M-x'
cycle shrinks then re-grows the body and would otherwise produce
two prompt repaints in quick succession — visible as flicker."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-called nil)
          (redraw-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                   (lambda (_term _h _w) (setq set-size-called t)))
                  ((symbol-function 'ghostel--redraw-now)
                   (lambda (_buf) (setq redraw-called t)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((symbol-function 'active-minibuffer-window)
                   (lambda () 'fake-mini-win))
                  ((symbol-function 'ghostel--alt-screen-p)
                   (lambda (_term) nil))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 32))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (null result))
            (should-not set-size-called)
            (should-not redraw-called)
            (should (= 40 ghostel--term-rows))
            (should (= 120 ghostel--term-cols))))))))

(ert-deftest ghostel-test-resize-rows-only-during-minibuffer-on-alt-screen-still-resizes ()
  "Alt-screen TUIs bypass the minibuffer deferral and resize normally.
vim/htop/less re-render against $LINES and would draw with stale
dimensions otherwise."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                   (lambda (_term h w) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--redraw-now)
                   (lambda (_buf) (setq redraw-called t)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((symbol-function 'active-minibuffer-window)
                   (lambda () 'fake-mini-win))
                  ((symbol-function 'ghostel--alt-screen-p)
                   (lambda (_term) t))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 32))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (equal '(120 . 32) result))
            (should (equal '(32 120) set-size-args))
            (should ghostel--force-next-redraw)
            (should redraw-called)
            (should (= 32 ghostel--term-rows))
            (should (= 120 ghostel--term-cols))))))))

(ert-deftest ghostel-test-resize-rows-only-outside-minibuffer-still-resizes ()
  "Rows-only resize with no minibuffer active goes through the normal path.
Genuine vertical resizes like `C-x 2' must still propagate to the
shell so $LINES stays accurate."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                   (lambda (_term h w) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--redraw-now)
                   (lambda (_buf) (setq redraw-called t)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((symbol-function 'active-minibuffer-window)
                   (lambda () nil))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 32))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (equal '(120 . 32) result))
            (should (equal '(32 120) set-size-args))
            (should ghostel--force-next-redraw)
            (should redraw-called)
            (should (= 32 ghostel--term-rows))
            (should (= 120 ghostel--term-cols))))))))

(ert-deftest ghostel-test-resize-cols-change-during-minibuffer-still-resizes ()
  "Cols change during a minibuffer still goes through the normal path.
The deferral only applies to rows-only deltas; a column change means
real reflow that the shell needs to know about regardless of
minibuffer state."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (redraw-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                   (lambda (_term h w) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--redraw-now)
                   (lambda (_buf) (setq redraw-called t)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((symbol-function 'active-minibuffer-window)
                   (lambda () 'fake-mini-win))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(100 . 40))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (equal '(100 . 40) result))
            (should (equal '(40 100) set-size-args))
            (should ghostel--force-next-redraw)
            (should redraw-called)
            (should (= 40 ghostel--term-rows))
            (should (= 100 ghostel--term-cols))))))))

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
                    ((symbol-function 'ghostel--write-input)
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

(ert-deftest ghostel-test-ignore-cursor-change ()
  "Test that `ghostel-ignore-cursor-change' suppresses cursor style updates."
  (let ((buf (generate-new-buffer " *ghostel-test-ignore-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Default: cursor changes are applied
          (let ((ghostel-ignore-cursor-change nil))
            (setq cursor-type 'box)
            (ghostel--set-cursor-style 2 t)
            (should (equal cursor-type '(hbar . 2))))
          ;; With ignore: cursor changes are suppressed
          (let ((ghostel-ignore-cursor-change t))
            (setq cursor-type 'box)
            (ghostel--set-cursor-style 1 t)
            (should (equal cursor-type 'box))))  ; unchanged
      (kill-buffer buf))))

(provide 'ghostel-terminal-test)
;;; ghostel-terminal-test.el ends here
