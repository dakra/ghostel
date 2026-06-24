;;; ghostel-modes-test.el --- Tests for ghostel: modes -*- lexical-binding: t; -*-

;;; Commentary:

;; Input mode state + char/emacs/copy mode transitions, fake cursor,
;; copy-mode cursor + hl-line.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-emacs-mode-preserves-point ()
  "In Emacs mode, point stays put while the terminal keeps running.
The delayed redraw path always preserves point in Emacs mode,
unlike semi-char mode where it tracks the terminal cursor."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
				      (set-window-buffer (selected-window) buf)
				      ;; Write some rows and redraw to populate the buffer.
				      (dotimes (i 10)
					(ghostel--write-vt term
							   (format "row-%02d\r\n" i)))
				      (ghostel-test--redraw term t)
				      ;; Enter emacs mode and navigate to the top.
				      (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
					(ghostel-emacs-mode))
				      (goto-char (point-min))
				      (let ((mark (point)))
					;; More output streams in. Run the delayed redraw
					;; synchronously (as the timer would).
					(dotimes (i 5)
					  (ghostel--write-vt term
							     (format "new-%02d\r\n" i)))
					(ghostel--redraw-now buf)
					;; Point still at point-min — emacs mode preserved it.
					(should (= (point) mark)))
				      ;; New rows are visible in the buffer.
				      (let ((content (buffer-substring-no-properties
						      (point-min) (point-max))))
					(should (string-match-p "new-04" content)))))

(ert-deftest ghostel-test-copy-mode-freezes-redraws ()
  "In copy mode, `ghostel--redraw-now' is a no-op."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (buf term 5 80 1000)
				      (dotimes (i 3)
					(ghostel--write-vt term
							   (format "initial-%d\r\n" i)))
				      (ghostel-test--redraw term t)
				      (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
					(ghostel-copy-mode))
				      (let ((snapshot (buffer-substring-no-properties
						       (point-min) (point-max))))
					;; Feed more output and attempt a redraw.
					(dotimes (i 3)
					  (ghostel--write-vt term
							     (format "frozen-%d\r\n" i)))
					(ghostel--redraw-now buf)
					;; Buffer is unchanged — copy mode gated the redraw.
					(should (equal snapshot
						       (buffer-substring-no-properties
							(point-min) (point-max)))))
				      ;; Exiting copy mode lets the redraw catch up.
				      (cl-letf (((symbol-function 'ghostel--anchor-window) #'ignore))
					(ghostel-readonly-exit))
				      (ghostel-test--redraw term t)
				      (let ((content (buffer-substring-no-properties
						      (point-min) (point-max))))
					(should (string-match-p "frozen-2" content)))))

(ert-deftest ghostel-test-copy-mode-cursor ()
  "Test that copy-mode restores cursor visibility when terminal hid it."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Simulate a terminal app hiding the cursor
          (setq-local ghostel--cursor-style nil)
          (ghostel--apply-cursor-style)
          (should (null cursor-type))                       ; cursor hidden
          ;; Enter copy mode — cursor should become visible
          (let ((ghostel--redraw-timer nil))
            (cl-letf (((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-copy-mode)
              (should (eq ghostel--input-mode 'copy))         ; in copy mode
              (should cursor-type)                            ; cursor visible
              (should (equal cursor-type (default-value 'cursor-type))) ; uses user default
              ;; Exit copy mode — cursor should be hidden again
              (ghostel-readonly-exit)
              (should (eq ghostel--input-mode 'semi-char))    ; exited copy mode
              (should (null cursor-type)))))                 ; cursor hidden again
      (kill-buffer buf))))

(ert-deftest ghostel-test-copy-mode-hl-line ()
  "Test that `global-hl-line-mode' is suppressed and `hl-line-mode' restored in copy-mode."
  (let ((buf (generate-new-buffer " *ghostel-test-hl-line*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (require 'hl-line)
          ;; Simulate global-hl-line-mode being active.
          (let ((global-hl-line-mode t))
            ;; Suppress should opt this buffer out.
            (ghostel--suppress-interfering-modes)
            (should ghostel--saved-hl-line-mode)
            ;; Buffer-local global-hl-line-mode must be nil — this is the
            ;; mechanism that prevents global-hl-line-highlight (on
            ;; post-command-hook) from creating overlays in this buffer.
            (should-not global-hl-line-mode))
          ;; Enter copy mode — local hl-line-mode should be enabled
          (let ((ghostel--redraw-timer nil))
            (cl-letf (((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-copy-mode)
              (should (bound-and-true-p hl-line-mode))
              ;; Exit copy mode — local hl-line-mode disabled again
              (ghostel-readonly-exit)
              (should-not (bound-and-true-p hl-line-mode)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (kill-local-variable 'global-hl-line-mode))
        (kill-buffer buf)))))

(ert-deftest ghostel-test-fake-cursor-style-resolution ()
  "`ghostel--fake-cursor-style' maps `cursor-in-non-selected-windows'."
  (with-temp-buffer
    (let ((cursor-in-non-selected-windows nil))
      (should (null (ghostel--fake-cursor-style))))
    (let ((cursor-in-non-selected-windows 'hollow))
      (should (eq 'hollow (ghostel--fake-cursor-style))))
    (let ((cursor-in-non-selected-windows 'box))
      (should (eq 'box (ghostel--fake-cursor-style))))
    (let ((cursor-in-non-selected-windows '(box . 4)))
      (should (eq 'box (ghostel--fake-cursor-style))))
    ;; bar / hbar fall back to hollow
    (let ((cursor-in-non-selected-windows 'bar))
      (should (eq 'hollow (ghostel--fake-cursor-style))))
    (let ((cursor-in-non-selected-windows '(bar . 2)))
      (should (eq 'hollow (ghostel--fake-cursor-style))))
    (let ((cursor-in-non-selected-windows 'hbar))
      (should (eq 'hollow (ghostel--fake-cursor-style))))
    ;; t with a saved box cursor-type → hollow
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((cursor-in-non-selected-windows t))
      (should (eq 'hollow (ghostel--fake-cursor-style))))
    ;; t with no saved cursor-type → nil (terminal hid the cursor)
    (setq-local ghostel--saved-cursor-type nil)
    (let ((cursor-in-non-selected-windows t))
      (should (null (ghostel--fake-cursor-style))))))

(ert-deftest ghostel-test-fake-cursor-overlay-when-point-off-cursor ()
  "Overlay appears at the live cursor position when point is elsewhere."
  (with-temp-buffer
    (insert "abcdef\nghijkl")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 5)
      (goto-char 1)
      (ghostel--fake-cursor-update)
      (should ghostel--fake-cursor-overlay)
      (should (= 5 (overlay-start ghostel--fake-cursor-overlay)))
      (should (= 6 (overlay-end ghostel--fake-cursor-overlay)))
      (should (eq 'ghostel-fake-cursor
                  (overlay-get ghostel--fake-cursor-overlay 'face))))))

(ert-deftest ghostel-test-fake-cursor-cleared-when-point-coincides ()
  "Overlay is removed when point lands on the live cursor position."
  (with-temp-buffer
    (insert "abcdef\nghijkl")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 5)
      (goto-char 1)
      (ghostel--fake-cursor-update)
      (should ghostel--fake-cursor-overlay)
      (goto-char 5)
      (ghostel--fake-cursor-update)
      (should-not ghostel--fake-cursor-overlay))))

(ert-deftest ghostel-test-fake-cursor-disabled-by-defcustom ()
  "No overlay is created when `ghostel-readonly-fake-cursor' is nil."
  (with-temp-buffer
    (insert "abcdef")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor nil)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 5)
      (goto-char 1)
      (ghostel--fake-cursor-update)
      (should-not ghostel--fake-cursor-overlay))))

(ert-deftest ghostel-test-fake-cursor-disabled-by-cinsw ()
  "No overlay when `cursor-in-non-selected-windows' resolves to nil."
  (with-temp-buffer
    (insert "abcdef")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows nil))
      (setq-local ghostel--cursor-char-pos 5)
      (goto-char 1)
      (ghostel--fake-cursor-update)
      (should-not ghostel--fake-cursor-overlay))))

(ert-deftest ghostel-test-fake-cursor-not-in-semi-char ()
  "No overlay outside copy / Emacs mode."
  (with-temp-buffer
    (insert "abcdef")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 5)
      (dolist (mode '(semi-char char line))
        (setq-local ghostel--input-mode mode)
        (goto-char 1)
        (ghostel--fake-cursor-update)
        (should-not ghostel--fake-cursor-overlay)))))

(ert-deftest ghostel-test-fake-cursor-box-style-uses-box-face ()
  "`box' resolution paints with the solid face."
  (with-temp-buffer
    (insert "abcdef")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'box))
      (setq-local ghostel--cursor-char-pos 5)
      (goto-char 1)
      (ghostel--fake-cursor-update)
      (should (eq 'ghostel-fake-cursor-box
                  (overlay-get ghostel--fake-cursor-overlay 'face))))))

(ert-deftest ghostel-test-fake-cursor-eol-uses-after-string ()
  "At end-of-line / end-of-buffer, the overlay uses an after-string."
  (with-temp-buffer
    (insert "abc")                    ; eob = 4
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 4)
      (goto-char 1)
      (ghostel--fake-cursor-update)
      (should ghostel--fake-cursor-overlay)
      (let ((after (overlay-get ghostel--fake-cursor-overlay 'after-string)))
        (should (stringp after))
        (should (eq 'ghostel-fake-cursor
                    (get-text-property 0 'face after))))
      (should (null (overlay-get ghostel--fake-cursor-overlay 'face))))))

(ert-deftest ghostel-test-fake-cursor-cleared-on-leave-readonly ()
  "`ghostel--leave-readonly-state' clears the overlay and the hook."
  (with-temp-buffer
    (insert "abcdef")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 5)
      (goto-char 1)
      (add-hook 'pre-redisplay-functions #'ghostel--fake-cursor-update nil t)
      (ghostel--fake-cursor-update)
      (should ghostel--fake-cursor-overlay)
      (should (memq #'ghostel--fake-cursor-update pre-redisplay-functions))
      (ghostel--leave-readonly-state)
      (should-not ghostel--fake-cursor-overlay)
      (should-not (memq #'ghostel--fake-cursor-update pre-redisplay-functions)))))

(ert-deftest ghostel-test-fake-cursor-toggles-between-eol-and-mid-line ()
  "Same overlay flips between `face' and `after-string' as it crosses EOL."
  (with-temp-buffer
    (insert "abcdef\nghijkl")          ; eol of line 1 = 7
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 3)
      (goto-char 1)
      ;; Mid-line: face set, no after-string.
      (ghostel--fake-cursor-update)
      (let ((ov ghostel--fake-cursor-overlay))
        (should ov)
        (should (eq 'ghostel-fake-cursor (overlay-get ov 'face)))
        (should-not (overlay-get ov 'after-string))
        ;; Move live cursor to EOL: same overlay flips to after-string.
        (setq ghostel--cursor-char-pos 7)
        (ghostel--fake-cursor-update)
        (should (eq ov ghostel--fake-cursor-overlay))
        (should-not (overlay-get ov 'face))
        (should (stringp (overlay-get ov 'after-string)))
        ;; Move back to mid-line: flips back.
        (setq ghostel--cursor-char-pos 4)
        (ghostel--fake-cursor-update)
        (should (eq ov ghostel--fake-cursor-overlay))
        (should (eq 'ghostel-fake-cursor (overlay-get ov 'face)))
        (should-not (overlay-get ov 'after-string))))))

(ert-deftest ghostel-test-fake-cursor-reuses-overlay-across-positions ()
  "Successive updates with different positions reuse one overlay."
  (with-temp-buffer
    (insert "abcdef")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 3)
      (goto-char 1)
      (ghostel--fake-cursor-update)
      (let ((ov ghostel--fake-cursor-overlay))
        (should ov)
        (should (= 3 (overlay-start ov)))
        (setq ghostel--cursor-char-pos 5)
        (ghostel--fake-cursor-update)
        (should (eq ov ghostel--fake-cursor-overlay))
        (should (= 5 (overlay-start ov)))))))

(ert-deftest ghostel-test-fake-cursor-clears-when-term-nil ()
  "Overlay is cleared when `ghostel--term' becomes nil (process exit)."
  (with-temp-buffer
    (insert "abcdef")
    (setq-local ghostel--term 'fake)
    (setq-local ghostel--input-mode 'copy)
    (setq-local ghostel--saved-cursor-type 'box)
    (let ((ghostel-readonly-fake-cursor t)
          (cursor-in-non-selected-windows 'hollow))
      (setq-local ghostel--cursor-char-pos 5)
      (goto-char 1)
      (ghostel--fake-cursor-update)
      (should ghostel--fake-cursor-overlay)
      (setq-local ghostel--term nil)
      (setq-local ghostel--cursor-char-pos nil)
      (ghostel--fake-cursor-update)
      (should-not ghostel--fake-cursor-overlay))))

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

(ert-deftest ghostel-test-copy-mode-buffer-navigation ()
  "`ghostel-readonly-end-of-buffer' skips trailing blank rows."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-nav*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--input-mode 'copy)
                (ghostel--term 'fake-term))
            (ghostel-test--with-rendered-output
              (insert (mapconcat #'number-to-string (number-sequence 1 20) "\n"))
              (insert "   \n\n"))
            (goto-char (point-min))
            (ghostel-readonly-end-of-buffer)
            (should (looking-back "20" (line-beginning-position)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-input-mode-default-is-semi-char ()
  "A fresh `ghostel-mode' buffer starts in semi-char mode."
  (let ((buf (generate-new-buffer " *ghostel-test-mode-default*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (should (eq ghostel--input-mode 'semi-char))
          (should (eq (current-local-map) ghostel-semi-char-mode-map))
          (should (null mode-line-process))
          (should (ghostel--terminal-input-mode-p))
          (should buffer-read-only)
          (should (ghostel--terminal-live-p))
          (should-not (ghostel--terminal-frozen-p)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-default-buffer-is-protected ()
  "Renderer-owned ghostel buffers reject ordinary editing commands."
  (let ((buf (generate-new-buffer " *ghostel-test-mode-protected*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered "one\ntwo\n")
          (goto-char (point-min))
          (should-error (transpose-lines 1) :type 'buffer-read-only))
      (kill-buffer buf))))

(ert-deftest ghostel-test-input-mode-predicates ()
  "The ghostel--*-p predicates reflect the current `ghostel--input-mode'."
  (let ((ghostel--input-mode 'semi-char))
    (should (ghostel--terminal-input-mode-p))
    (should (ghostel--terminal-live-p))
    (should-not (ghostel--terminal-frozen-p)))
  (let ((ghostel--input-mode 'char))
    (should (ghostel--terminal-input-mode-p))
    (should (ghostel--terminal-live-p))
    (should-not (ghostel--terminal-frozen-p)))
  (let ((ghostel--input-mode 'emacs))
    (should-not (ghostel--terminal-input-mode-p))
    (should (ghostel--terminal-live-p)))
  (let ((ghostel--input-mode 'copy))
    (should-not (ghostel--terminal-input-mode-p))
    (should-not (ghostel--terminal-live-p))
    (should (ghostel--terminal-frozen-p)))
  ;; Line mode keeps the terminal live: redraws still run, with the
  ;; snapshot/restore path preserving the user's in-progress input.
  (let ((ghostel--input-mode 'line))
    (should-not (ghostel--terminal-input-mode-p))
    (should (ghostel--terminal-live-p))
    (should-not (ghostel--terminal-frozen-p))))

(ert-deftest ghostel-test-char-mode-enter-exit ()
  "Char mode swaps the local map, sets mode-line, and \\`M-RET' exits."
  (let ((buf (generate-new-buffer " *ghostel-test-char-mode*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-char-mode)
              (should (eq ghostel--input-mode 'char))
              (should (eq (current-local-map) ghostel-char-mode-map))
              (should (equal mode-line-process ":Char"))
              ;; Switch back via the same function that M-RET invokes.
              (ghostel-semi-char-mode)
              (should (eq ghostel--input-mode 'semi-char))
              (should (eq (current-local-map) ghostel-semi-char-mode-map))
              (should (null mode-line-process)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-emacs-mode-enter-exit ()
  "Emacs mode swaps map, updates the mode line, and exits cleanly."
  (let ((buf (generate-new-buffer " *ghostel-test-emacs-mode*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-emacs-mode)
              (should (eq ghostel--input-mode 'emacs))
              (should (eq (current-local-map)
                          (if ghostel-readonly-fast-exit
                              ghostel-readonly-fast-exit-mode-map
                            ghostel-readonly-mode-map)))
              (should (equal mode-line-process ":Emacs"))
              (ghostel-semi-char-mode)
              (should (eq ghostel--input-mode 'semi-char))
              (should (null mode-line-process)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mode-line-tag-make ()
  "`ghostel--mode-line-tag-make' propertizes the tag for every input mode."
  (dolist (case '((char  ":Char"  "char-mode")
                  (line  ":Line"  "line-mode")
                  (copy  ":Copy"  "copy-mode")
                  (emacs ":Emacs" "emacs-mode")))
    (pcase-let* ((`(,mode ,label ,needle) case)
                 (tag (ghostel--mode-line-tag-make mode label)))
      ;; `equal' is property-blind, so existing string assertions still hold.
      (should (equal tag label))
      ;; mouse-face + local-map are static properties.
      (should (eq (get-text-property 0 'mouse-face tag) 'mode-line-highlight))
      (should (eq (get-text-property 0 'local-map tag)
                  ghostel--mode-line-tag-mouse-map))
      ;; help-echo is a function (re-renders on each hover).
      (let* ((he (get-text-property 0 'help-echo tag))
             (text (funcall he nil tag 0)))
        (should (functionp he))
        (should (stringp text))
        (should (string-match-p (regexp-quote needle) text))
        (should (string-match-p "mouse-1" text))))))

(ert-deftest ghostel-test-mode-line-tag-help-echo-respects-fast-exit ()
  "Copy/Emacs tooltips list `q'/`C-g' only when `ghostel-readonly-fast-exit' is on."
  (let ((ghostel-readonly-fast-exit t))
    (dolist (mode '(copy emacs))
      (let ((text (ghostel--mode-line-tag-help-echo-text mode)))
        (should (string-match-p "\\bq\\b" text))
        (should (string-match-p "C-g" text)))))
  (let ((ghostel-readonly-fast-exit nil))
    (dolist (mode '(copy emacs))
      (let ((text (ghostel--mode-line-tag-help-echo-text mode)))
        ;; Without fast-exit, q is not an exit key — must not appear.
        (should-not (string-match-p "\\bq\\b" text))
        ;; The way out is the semi-char-mode binding (C-c C-j by default).
        (should (string-match-p "C-c C-j" text))))))

(ert-deftest ghostel-test-mode-line-tag-integration ()
  "Entering char/copy/emacs sets `mode-line-process' to the propertized tag."
  (let ((buf (generate-new-buffer " *ghostel-test-mode-line-tag*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (dolist (case '((ghostel-char-mode  . ":Char")
                              (ghostel-emacs-mode . ":Emacs")
                              (ghostel-copy-mode  . ":Copy")))
                (funcall (car case))
                (should (equal mode-line-process (cdr case)))
                (should (functionp (get-text-property 0 'help-echo
                                                      mode-line-process)))
                (ghostel-semi-char-mode)
                (should (null mode-line-process))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mode-line-tag-mouse-exit ()
  "`mouse-1' on the tag exits char/line to semi-char and copy/emacs to previous."
  (let ((buf (generate-new-buffer " *ghostel-test-mode-line-tag-mouse*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (set-window-buffer (selected-window) buf)
          (let ((ghostel--term 'fake)
                (event `(mouse-1 (,(selected-window) mode-line (0 . 0) 0))))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore)
                      ((symbol-function 'ghostel-force-redraw) #'ignore))
              ;; Char mode → semi-char on click.
              (ghostel-char-mode)
              (should (eq ghostel--input-mode 'char))
              (ghostel--mode-line-tag-mouse-exit event)
              (should (eq ghostel--input-mode 'semi-char))
              ;; Emacs mode → semi-char (its previous mode) on click.
              (ghostel-emacs-mode)
              (should (eq ghostel--input-mode 'emacs))
              (ghostel--mode-line-tag-mouse-exit event)
              (should (eq ghostel--input-mode 'semi-char))
              ;; Copy mode → semi-char on click.  Freezes the terminal,
              ;; so the readonly exit path resumes redraws (stubbed).
              (ghostel-copy-mode)
              (should (eq ghostel--input-mode 'copy))
              (ghostel--mode-line-tag-mouse-exit event)
              (should (eq ghostel--input-mode 'semi-char)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-emacs-mode-is-unfrozen ()
  "Emacs mode leaves the terminal live so redraws keep running."
  (let ((buf (generate-new-buffer " *ghostel-test-emacs-live*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-emacs-mode)
              ;; Terminal is live in emacs mode — unlike copy mode.
              (should (ghostel--terminal-live-p))
              (should-not (ghostel--terminal-frozen-p)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-emacs-mode-does-not-forward-typing ()
  "Sticky read-only modes do NOT forward typed chars to the shell.
With `ghostel-readonly-fast-exit' set to nil, self-insert, `RET',
`TAB', `DEL' fall through to the global map; the buffer's
`read-only' state then signals `text-read-only'.  This makes Emacs
mode a true \"look but don't touch\" view — keystrokes cannot
accidentally reach the shell while you read or search the
scrollback."
  (let ((buf (generate-new-buffer " *ghostel-test-emacs-noforward*"))
        (ghostel-readonly-fast-exit nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel-emacs-mode)
              (should (eq ghostel--input-mode 'emacs))
              ;; Self-insert is NOT remapped to the ghostel version.
              (should-not (eq (key-binding "a") #'ghostel--self-insert))
              ;; TAB, DEL fall through to the read-only barrier.  RET
              ;; is bound to follow links at point but is a no-op
              ;; everywhere else — typing RET on a non-link cell does
              ;; not reach the shell.
              (should (eq (lookup-key ghostel-readonly-mode-map (kbd "RET"))
                          #'ghostel-open-link-at-point))
              (should-not (lookup-key ghostel-readonly-mode-map (kbd "TAB")))
              (should-not (lookup-key ghostel-readonly-mode-map (kbd "DEL")))
              ;; Navigation keys fall through to the global map —
              ;; `C-n' etc. are not bound locally.
              (should-not (lookup-key ghostel-readonly-mode-map (kbd "C-n")))
              (should-not (lookup-key ghostel-readonly-mode-map (kbd "C-p")))
              ;; C-y (paste) is allowed — explicit, deliberate action.
              (should (eq (lookup-key ghostel-readonly-mode-map (kbd "C-y"))
                          #'ghostel-yank))
              ;; Still reachable via C-c C-j (inherited from `ghostel-mode-map').
              (should (eq (lookup-key ghostel-readonly-mode-map (kbd "C-c C-j"))
                          #'ghostel-semi-char-mode)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-copy-mode-restores-previous-mode ()
  "Exiting copy mode returns to whatever mode the user was in beforehand."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-restore*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel-detect-password-prompts nil)
                (ghostel--redraw-timer nil))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              ;; semi-char → copy → semi-char
              (ghostel-copy-mode)
              (should (eq ghostel--input-mode 'copy))
              (ghostel-readonly-exit)
              (should (eq ghostel--input-mode 'semi-char))
              ;; char → copy → char
              (ghostel-char-mode)
              (ghostel-copy-mode)
              (should (eq ghostel--input-mode 'copy))
              (ghostel-readonly-exit)
              (should (eq ghostel--input-mode 'char))
              ;; emacs → copy → emacs
              (ghostel-emacs-mode)
              (ghostel-copy-mode)
              (should (eq ghostel--input-mode 'copy))
              (ghostel-readonly-exit)
              (should (eq ghostel--input-mode 'emacs)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-copy-to-emacs-transition ()
  "Copy → Emacs unfreezes the terminal."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-to-emacs*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel-detect-password-prompts nil)
                (ghostel--redraw-timer nil))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-copy-mode)
              (should (eq ghostel--input-mode 'copy))
              (ghostel-emacs-mode)
              (should (eq ghostel--input-mode 'emacs))
              (should (ghostel--terminal-live-p))
              (ghostel-semi-char-mode)
              (should (eq ghostel--input-mode 'semi-char)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-emacs-to-copy-transition ()
  "Emacs → copy freezes the terminal."
  (let ((buf (generate-new-buffer " *ghostel-test-emacs-to-copy*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel--redraw-timer (run-at-time 999 nil #'ignore)))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (unwind-protect
                  (progn
                    (ghostel-emacs-mode)
                    (should (eq ghostel--input-mode 'emacs))
                    (ghostel-copy-mode)
                    (should (eq ghostel--input-mode 'copy))
                    (should (ghostel--terminal-frozen-p))
                    (should (null ghostel--redraw-timer)))
                (when (and ghostel--redraw-timer
                           (timerp ghostel--redraw-timer))
                  (cancel-timer ghostel--redraw-timer))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mode-switch-keybindings ()
  "Mode-switch keys are bound to the right mode commands."
  (should (eq (lookup-key ghostel-mode-map (kbd "C-c C-e"))
              #'ghostel-emacs-mode))
  (should (eq (lookup-key ghostel-mode-map (kbd "C-c C-j"))
              #'ghostel-semi-char-mode))
  (should (eq (lookup-key ghostel-mode-map (kbd "C-c M-d"))
              #'ghostel-char-mode))
  (should (eq (lookup-key ghostel-mode-map (kbd "C-c C-l"))
              #'ghostel-line-mode))
  (should (eq (lookup-key ghostel-mode-map (kbd "C-c M-l"))
              #'ghostel-clear-scrollback))
  (should (eq (lookup-key ghostel-mode-map (kbd "C-c C-t"))
              #'ghostel-copy-mode)))

(ert-deftest ghostel-test-readonly-fast-exit-switch-keybindings ()
  "Fast-exit copy/Emacs mode keeps the full mode-switch matrix (issue #342).
The mode-switch keys stay bound to their mode commands rather than being
repurposed as exit shortcuts, while the quit keys stay bound to the fast exit."
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "C-c C-e"))
              #'ghostel-emacs-mode))
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "C-c C-t"))
              #'ghostel-copy-mode))
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "C-c C-j"))
              #'ghostel-semi-char-mode))
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "C-c M-d"))
              #'ghostel-char-mode))
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "C-c C-l"))
              #'ghostel-line-mode))
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "q"))
              #'ghostel-readonly-exit))
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "C-g"))
              #'ghostel-readonly-exit)))

(ert-deftest ghostel-test-emacs-mode-toggles-off ()
  "`ghostel-emacs-mode' is a toggle: calling it while in Emacs mode exits.
Exiting returns to whatever mode the user was in beforehand, mirroring
`ghostel-copy-mode'."
  (let ((buf (generate-new-buffer " *ghostel-test-emacs-toggle*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel-detect-password-prompts nil)
                (ghostel--redraw-timer nil))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              ;; semi-char → emacs → (toggle) semi-char
              (ghostel-emacs-mode)
              (should (eq ghostel--input-mode 'emacs))
              (ghostel-emacs-mode)
              (should (eq ghostel--input-mode 'semi-char))
              ;; char → emacs → (toggle) char
              (ghostel-char-mode)
              (ghostel-emacs-mode)
              (should (eq ghostel--input-mode 'emacs))
              (ghostel-emacs-mode)
              (should (eq ghostel--input-mode 'char)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-prompt-nav-enters-emacs-mode ()
  "`ghostel-next-prompt' auto-enters Emacs mode, not copy mode."
  (let ((buf (generate-new-buffer " *ghostel-test-prompt-nav*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore)
                      ((symbol-function 'ghostel--navigate-next-prompt)
                       (lambda (_n) nil))
                      ((symbol-function 'ghostel--navigate-previous-prompt)
                       (lambda (_n) nil)))
              (ghostel-next-prompt 1)
              (should (eq ghostel--input-mode 'emacs))
              (ghostel-semi-char-mode)
              (ghostel-previous-prompt 1)
              (should (eq ghostel--input-mode 'emacs)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mode-mutual-exclusivity ()
  "Entering any mode exits the others cleanly."
  (let ((buf (generate-new-buffer " *ghostel-test-mutex*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              ;; A round-trip through every mode returns to semi-char.
              (ghostel-char-mode)  (should (eq ghostel--input-mode 'char))
              (ghostel-emacs-mode) (should (eq ghostel--input-mode 'emacs))
              (ghostel-copy-mode)  (should (eq ghostel--input-mode 'copy))
              (ghostel-char-mode)  (should (eq ghostel--input-mode 'char))
              (ghostel-semi-char-mode)
              (should (eq ghostel--input-mode 'semi-char)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mark-activation-enters-copy-mode ()
  "Activating the mark in semi-char enters copy mode; the region survives."
  (let ((buf (generate-new-buffer " *ghostel-test-mark-copy*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel-detect-password-prompts nil)
                (ghostel--redraw-timer nil)
                (ghostel-mark-activation-input-mode 'copy)
                ;; Batch Emacs has no transient-mark-mode, which makes
                ;; the `deactivate-mark' on exit a no-op.
                (transient-mark-mode t))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-test--insert-rendered "some terminal output")
              (goto-char 5)
              ;; Any mark-activating command works; C-SPC's is the canonical one.
              (set-mark-command nil)
              (should (eq ghostel--input-mode 'copy))
              (should (= (mark) 5))
              (should mark-active)
              ;; Exiting returns to semi-char and drops the region.
              (ghostel-readonly-exit)
              (should (eq ghostel--input-mode 'semi-char))
              (should-not mark-active))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mark-activation-enters-emacs-mode ()
  "With `ghostel-mark-activation-input-mode' set to `emacs', Emacs mode."
  (let ((buf (generate-new-buffer " *ghostel-test-mark-emacs*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel--redraw-timer nil)
                (ghostel-mark-activation-input-mode 'emacs))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (set-mark-command nil)
              (should (eq ghostel--input-mode 'emacs))
              (should (= (mark) (point)))
              (should mark-active))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mark-activation-nil-stays-semi-char ()
  "With `ghostel-mark-activation-input-mode' nil, no mode switch happens."
  (let ((buf (generate-new-buffer " *ghostel-test-mark-nil*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel-mark-activation-input-mode nil))
            (set-mark-command nil)
            (should (eq ghostel--input-mode 'semi-char))
            (should mark-active)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mark-activation-only-in-semi-char ()
  "Mark activation in char or copy mode does not switch (or toggle) modes."
  (let ((buf (generate-new-buffer " *ghostel-test-mark-other-modes*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel--redraw-timer nil)
                (ghostel-mark-activation-input-mode 'copy))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              ;; Char mode: marking must not yank the user out of the TUI.
              (ghostel-char-mode)
              (push-mark (point) t t)
              (should (eq ghostel--input-mode 'char))
              (ghostel-semi-char-mode)
              ;; Copy mode: marking must not toggle copy mode back off.
              (ghostel-copy-mode)
              (push-mark (point) t t)
              (should (eq ghostel--input-mode 'copy)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mark-activation-mouse-knob-wins ()
  "A mouse drag follows `ghostel-mouse-drag-input-mode', not the mark knob."
  (let ((buf (generate-new-buffer " *ghostel-test-mark-mouse*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel--redraw-timer nil)
                (ghostel-mouse-drag-input-mode 'emacs)
                (ghostel-mark-activation-input-mode 'copy))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore)
                      ((symbol-function 'ghostel--mouse-tracking-active-p)
                       (lambda () nil))
                      ;; The real mouse-set-region activates the mark.
                      ((symbol-function 'mouse-set-region)
                       (lambda (_event) (push-mark (point) t t))))
              ;; A real drag selecting a region (distinct start/end points).
              ;; `this-command' is what the command loop binds when dispatching
              ;; the drag; `ghostel--mark-activated' reads it to stay out of
              ;; mouse gestures, so the test must set it like a real dispatch.
              (let ((this-command 'ghostel-mouse-drag-or-set-region))
                (ghostel-mouse-drag-or-set-region
                 `(drag-mouse-1 (,(selected-window) 1 (1 . 1) 0)
                                (,(selected-window) 5 (5 . 1) 0))))
              ;; The mouse knob picked the mode — the hook stayed out.
              (should (eq ghostel--input-mode 'emacs)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-mark-activation-ignores-focus-click ()
  "A focus click on an unselected window must not freeze into copy mode.
Selecting a previously-unselected window via `mouse-drag-region' leaves an
empty region active; the command loop finalizes that activation after the
press handler returns, with `this-command' still the press command.
`ghostel--mark-activated' must ignore it so the focus click stays in
semi-char."
  (let ((buf (generate-new-buffer " *ghostel-test-mark-focus-click*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term 'fake)
                (ghostel--redraw-timer nil)
                (ghostel-mark-activation-input-mode 'copy)
                ;; The deferred activation runs with `this-command' bound to
                ;; the press command that triggered the click gesture.
                (this-command 'ghostel-mouse-press-or-copy-mode))
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                      ((symbol-function 'ghostel--anchor-window) #'ignore))
              (ghostel-test--insert-rendered "some terminal output")
              ;; An empty region (point == mark), like a window-selecting click.
              (push-mark (point) t t)
              (should (eq ghostel--input-mode 'semi-char)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-ctrl-space-keybindings ()
  "Char mode captures both Ctrl+Space events; semi-char only TTY `C-@'.
GUI `C-SPC' must stay unbound in semi-char so it falls through to the
global mark command, whose activation `ghostel--mark-activated' handles."
  (should-not (lookup-key ghostel-semi-char-mode-map (kbd "C-SPC")))
  (should (functionp (lookup-key ghostel-semi-char-mode-map (kbd "C-@"))))
  (dolist (key '("C-SPC" "C-@"))
    (should (functionp (lookup-key ghostel-char-mode-map (kbd key))))))

(ert-deftest ghostel-test-line-mode-enters-without-osc133 ()
  "Line mode enters successfully in a REPL with no shell integration.
Reproduces the python3 case: no `ghostel-prompt' chars anywhere,
but the cursor is at the end of the REPL's prompt."
  (let ((buf (generate-new-buffer " *ghostel-test-line-nointegration*"))
        (sent nil)
        (encoded nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (ghostel-test--insert-rendered ">>> \n")
          (setq ghostel--term 'fake)
          (setq ghostel--term-rows 1)
          (setq ghostel--process 'fake-proc)
          (cl-letf (((symbol-function 'ghostel--mode-enabled)
                     (lambda (&rest _) nil))
                    (ghostel--cursor-char-pos 4)
                    ((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'ghostel--write-pty)
                     (lambda (_term s) (setq sent s)))
                    ((symbol-function 'ghostel--send-encoded)
                     (lambda (key _mods &optional _utf8)
                       (setq encoded key)))
                    ((symbol-function 'ghostel--redraw) #'ignore)
                    ((symbol-function 'ghostel--invalidate) #'ignore))
            (ghostel-line-mode)
            (should (eq ghostel--input-mode 'line))
            (should-not buffer-read-only)
            (goto-char (marker-position ghostel--line-input-end))
            (insert "1+1")
            (ghostel-line-mode-send)
            (should-not buffer-read-only)
            (ghostel-semi-char-mode)
            (should buffer-read-only)
            (should (equal sent "1+1"))
            (should (equal encoded "return"))))
      (kill-buffer buf))))

;;; Auto-leave: switch out of semi-char when point leaves the input point

(defmacro ghostel-test--with-auto-leave-buffer (&rest body)
  "Run BODY in a fresh semi-char `ghostel-mode' buffer set up for auto-leave.
Inserts \"echo hi\", parks the live cursor at `point-max', and stubs the
window-touching helpers `ghostel--invalidate' / `ghostel--anchor-window'
so copy/Emacs mode entry runs without a live terminal or window."
  (declare (indent 0) (debug t))
  `(let ((buf (generate-new-buffer " *ghostel-test-auto-leave*")))
     (unwind-protect
         (with-current-buffer buf
           (ghostel-mode)
           (ghostel-test--insert-rendered "echo hi")
           (setq-local ghostel--term 'fake)
           (setq-local ghostel--cursor-char-pos (point-max))
           (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                     ((symbol-function 'ghostel--anchor-window) #'ignore))
             ,@body))
       (kill-buffer buf))))

(ert-deftest ghostel-test-auto-leave-switches-to-copy ()
  "Point leaving the live cursor in semi-char enters copy mode (the default)."
  (ghostel-test--with-auto-leave-buffer
    (let ((ghostel-point-leave-input-mode 'copy))
      (goto-char (point-min))
      (ghostel-maybe-leave-input)
      (should (eq ghostel--input-mode 'copy)))))

(ert-deftest ghostel-test-auto-leave-switches-to-emacs ()
  "With the custom set to `emacs', point leaving enters Emacs mode."
  (ghostel-test--with-auto-leave-buffer
    (let ((ghostel-point-leave-input-mode 'emacs))
      (goto-char (point-min))
      (ghostel-maybe-leave-input)
      (should (eq ghostel--input-mode 'emacs)))))

(ert-deftest ghostel-test-auto-leave-stays-when-point-on-cursor ()
  "Point coinciding with the live cursor keeps the buffer in semi-char."
  (ghostel-test--with-auto-leave-buffer
    (let ((ghostel-point-leave-input-mode 'copy))
      (goto-char ghostel--cursor-char-pos)
      (ghostel-maybe-leave-input)
      (should (eq ghostel--input-mode 'semi-char)))))

(ert-deftest ghostel-test-auto-leave-disabled-by-nil ()
  "A nil custom disables the auto-switch even when point has moved."
  (ghostel-test--with-auto-leave-buffer
    (let ((ghostel-point-leave-input-mode nil))
      (goto-char (point-min))
      (ghostel-maybe-leave-input)
      (should (eq ghostel--input-mode 'semi-char)))))

(ert-deftest ghostel-test-auto-leave-only-from-semi-char ()
  "The check is a no-op when not in semi-char (e.g. already in copy mode)."
  (ghostel-test--with-auto-leave-buffer
    (let ((ghostel-point-leave-input-mode 'copy))
      (setq-local ghostel--input-mode 'copy)
      (goto-char (point-min))
      (ghostel-maybe-leave-input)
      (should (eq ghostel--input-mode 'copy)))))

(ert-deftest ghostel-test-auto-leave-skips-kbd-macro ()
  "Executing a keyboard macro does not switch mode mid-playback."
  (ghostel-test--with-auto-leave-buffer
    (let ((ghostel-point-leave-input-mode 'copy)
          (executing-kbd-macro [?x]))
      (goto-char (point-min))
      (ghostel-maybe-leave-input)
      (should (eq ghostel--input-mode 'semi-char)))))

(ert-deftest ghostel-test-auto-leave-preserves-point ()
  "Switching modes leaves point where the jump landed it."
  (ghostel-test--with-auto-leave-buffer
    (let ((ghostel-point-leave-input-mode 'copy))
      (goto-char 3)
      (ghostel-maybe-leave-input)
      (should (eq ghostel--input-mode 'copy))
      (should (= (point) 3)))))

(ert-deftest ghostel-test-auto-leave-isearch-hook-registered ()
  "`ghostel-mode' wires the leave check into `isearch-mode-end-hook'."
  (let ((buf (generate-new-buffer " *ghostel-test-auto-leave-hook*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (should (memq #'ghostel-maybe-leave-input
                        (buffer-local-value 'isearch-mode-end-hook buf))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-anchor-window-emacs-mode-force ()
  "`ghostel--anchor-window' anchors an Emacs-mode window only when FORCE is set.
Auto-follow callers leave FORCE nil, so a buffer reading its scrollback in
Emacs mode keeps its position.  Deliberate callers (paste/yank) pass FORCE to
snap to the live cursor."
  (let ((buf (generate-new-buffer " *ghostel-test-anchor-force*"))
        (previous-buffer (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (let ((rows (max 1 (window-body-height))))
              (ghostel-test--with-rendered-output
                (dotimes (i (+ rows 20))
                  (insert (format "row-%02d\n" i)))))
            (setq ghostel--input-mode 'emacs)
            (setq ghostel--cursor-char-pos (point-max))
            (goto-char (point-min))
            (set-window-start (selected-window) (point-min) t)
            ;; Without FORCE: Emacs mode keeps its reading position.
            (ghostel--anchor-window (selected-window))
            (should (= (window-start (selected-window)) (point-min)))
            ;; With FORCE: a deliberate anchor scrolls to the live cursor.
            (ghostel--anchor-window (selected-window) t)
            (should (> (window-start (selected-window)) (point-min)))))
      (set-window-buffer (selected-window) previous-buffer)
      (kill-buffer buf))))

(provide 'ghostel-modes-test)
;;; ghostel-modes-test.el ends here
