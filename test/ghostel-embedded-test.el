;;; ghostel-embedded-test.el --- Embedded terminal session tests  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for the region-relative embedded terminal layer: rendering into a
;; host-buffer region, live presentation, input activation and freezing.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-embedded)

(defun ghostel-test--embedded-setup (rows cols &optional before)
  "Create a host buffer with an embedded terminal of ROWS x COLS.
BEFORE defaults to \"before\\n\" and is inserted above the region.
Returns (BUFFER SESSION)."
  (let ((buffer (generate-new-buffer " *ghostel-test-embedded*")))
    (with-current-buffer buffer
      (insert (or before "before\n"))
      (list buffer (ghostel--embedded-start buffer nil rows cols)))))

(defun ghostel-test--embedded-region-text (session)
  "Return SESSION's region text without properties."
  (buffer-substring-no-properties (ghostel-embedded-start session)
                                  (ghostel-embedded-end session)))

(defun ghostel-test--embedded-prefix (session)
  "Return the host text above SESSION's region."
  (buffer-substring-no-properties (point-min) (ghostel-embedded-start session)))

(ert-deftest ghostel-test-embedded-renders-into-region ()
  "Output fed to an embedded session lands between the region markers."
  :tags '(native)
  (pcase-let ((`(,buffer ,session) (ghostel-test--embedded-setup 3 20)))
    (unwind-protect
        (with-current-buffer buffer
          (ghostel--embedded-feed session "hello\r\nworld")
          (should (ghostel--embedded-redraw-now session))
          (should (equal (ghostel-test--embedded-prefix session) "before\n"))
          (should (equal (string-trim-right
                          (ghostel-test--embedded-region-text session))
                         "hello\nworld")))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-embedded-applies-faces ()
  "SGR attributes reach the host buffer as face properties."
  :tags '(native)
  (pcase-let ((`(,buffer ,session) (ghostel-test--embedded-setup 3 20)))
    (unwind-protect
        (with-current-buffer buffer
          (ghostel--embedded-feed session "\e[31mred\e[0m plain")
          (ghostel--embedded-redraw-now session)
          (let ((start (marker-position (ghostel-embedded-start session))))
            (should (get-text-property start 'face))
            (should-not (get-text-property (+ start 3) 'face))))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-embedded-cursor-follows-output ()
  "Point tracks the terminal cursor while a command streams output."
  :tags '(native)
  (pcase-let ((`(,buffer ,session) (ghostel-test--embedded-setup 3 20)))
    (unwind-protect
        (with-current-buffer buffer
          (ghostel--embedded-feed session "abc")
          (ghostel--embedded-redraw-now session)
          (should (= (point)
                     (+ (marker-position (ghostel-embedded-start session)) 3))))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-embedded-follow-keeps-visible-prompt-still ()
  "Short output does not scroll a window that already shows the prompt."
  :tags '(native)
  (let ((orig (window-buffer (selected-window))))
    (pcase-let ((`(,buffer ,session)
                 (ghostel-test--embedded-setup
                  3 20
                  (concat (mapconcat #'identity (make-list 20 "x") "\n")
                          "\n"))))
      (unwind-protect
          (with-current-buffer buffer
            (set-window-buffer (selected-window) buffer)
            (goto-char (ghostel-embedded-start session))
            (forward-line -2)
            (set-window-start (selected-window) (point))
            (ghostel--embedded-feed session "abc")
            (let ((before (window-start)))
              (ghostel--embedded-redraw-now session)
              ;; The prompt sits near the top with room below it; the
              ;; window must not scroll to pin the cursor to the bottom.
              (should (= (window-start) before))))
        (set-window-buffer (selected-window) orig)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-embedded-emacs-mode-cursor-overlay ()
  "Emacs mode draws a cursor overlay where the terminal cursor is."
  :tags '(native)
  (pcase-let ((`(,buffer ,session) (ghostel-test--embedded-setup 3 20)))
    (unwind-protect
        (with-current-buffer buffer
          (ghostel--embedded-feed session "abc")
          (ghostel--embedded-redraw-now session)
          (goto-char (point-min))
          ;; Entering emacs mode refreshes the cursor while point roams.
          (ghostel-embedded-emacs-mode)
          (should (overlayp ghostel--embedded-cursor-overlay))
          (should (= (overlay-start ghostel--embedded-cursor-overlay)
                     (+ (marker-position (ghostel-embedded-start session)) 3))))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-embedded-resize ()
  "Resizing updates the session grid and keeps rendering into the region."
  :tags '(native)
  (pcase-let ((`(,buffer ,session) (ghostel-test--embedded-setup 3 20)))
    (unwind-protect
        (with-current-buffer buffer
          (ghostel--embedded-feed session "1\r\n2\r\n3\r\n4")
          (ghostel--embedded-redraw-now session)
          (ghostel--embedded-resize session 2 10 t)
          (should (= (ghostel-embedded-rows session) 2))
          (should (= (ghostel-embedded-cols session) 10))
          (should (string-match-p "4"
                                  (ghostel-test--embedded-region-text session))))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-embedded-region-is-read-only ()
  "The live region is read-only while the host text stays editable."
  :tags '(native)
  (pcase-let ((`(,buffer ,session) (ghostel-test--embedded-setup 3 20)))
    (unwind-protect
        (with-current-buffer buffer
          (ghostel--embedded-feed session "abc")
          (ghostel--embedded-redraw-now session)
          (should (get-text-property (ghostel-embedded-start session)
                                     'read-only))
          (should-not buffer-read-only)
          ;; Host text above the region remains editable.
          (goto-char (point-min))
          (insert "top\n")
          (should (equal (ghostel-test--embedded-prefix session)
                         "top\nbefore\n"))
          ;; The terminal's own rows are protected.
          (should-error
           (delete-region (ghostel-embedded-start session)
                          (1+ (marker-position
                               (ghostel-embedded-start session))))
           :type 'text-read-only))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-embedded-alt-screen-discarded ()
  "Finishing discards an alternate-screen frame and keeps the normal screen."
  :tags '(native)
  (pcase-let ((`(,buffer ,session) (ghostel-test--embedded-setup 3 20)))
    (unwind-protect
        (with-current-buffer buffer
          (ghostel--embedded-feed session "keep")
          (ghostel--embedded-redraw-now session)
          (ghostel--embedded-feed session "\e[?1049h\e[2J\e[HTUI")
          (ghostel--embedded-redraw-now session)
          (should (string-match-p "TUI"
                                  (ghostel-test--embedded-region-text session)))
          (ghostel--embedded-finish session)
          (let ((text (ghostel-test--embedded-region-text session)))
            (should (string-match-p "keep" text))
            (should-not (string-match-p "TUI" text))))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-embedded-finish-freezes ()
  "Finishing trims blank rows, restores state and releases the terminal."
  :tags '(native)
  (pcase-let ((`(,buffer ,session) (ghostel-test--embedded-setup 5 20)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((original-map (current-local-map)))
            (ghostel--embedded-activate-input session)
            (should (eq (current-local-map) ghostel-embedded-semi-char-map))
            (should (eq ghostel--term (ghostel-embedded-term session)))
            (ghostel--embedded-feed session "frozen\r\noutput")
            (ghostel--embedded-redraw-now session)
            (goto-char (point-min))
            (ghostel--embedded-finish session)
            (should-not ghostel--embedded-session)
            (should-not ghostel--term)
            (should (eq (current-local-map) original-map))
            ;; Semi-char mode: point lands at the end of the frozen
            ;; region, where the host's next prompt goes.
            (should (= (point)
                       (marker-position (ghostel-embedded-end session))))
            (should-not ghostel--embedded-cursor-overlay)
            (should-not
             (get-text-property (ghostel-embedded-start session)
                                'read-only))
            (should (equal
                     (ghostel-test--embedded-region-text session)
                     "frozen\noutput\n"))
            ;; Idempotent.
            (ghostel--embedded-finish session)))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-embedded-resize-request ()
  "A text-area resize request resizes an embedded terminal."
  :tags '(native)
  (with-temp-buffer
    (let ((session (ghostel--embedded-start (current-buffer) 1 24 80)))
      (unwind-protect
          (progn
            (ghostel--resize-request 10 40)
            (should (= (ghostel-embedded-rows session) 10))
            (should (= (ghostel-embedded-cols session) 40))
            ;; A zero dimension keeps the current value.
            (ghostel--resize-request 0 60)
            (should (= (ghostel-embedded-rows session) 10))
            (should (= (ghostel-embedded-cols session) 60)))
        (ghostel--embedded-finish session)))))

(ert-deftest ghostel-test-resize-request-without-embedded ()
  "A text-area request outside an embedded session is ignored."
  (with-temp-buffer
    (should-not ghostel--resize-request-function)
    (ghostel--resize-request 10 40)
    (should-not ghostel--resize-request-function)))

(ert-deftest ghostel-test-embedded-viewport-start ()
  "The viewport top is the last ROWS lines of the region."
  :tags '(native)
  (with-temp-buffer
    (let ((session (ghostel--embedded-start (current-buffer) 1 3 20)))
      (unwind-protect
          (progn
            (ghostel--embedded-feed session "1\r\n2\r\n3\r\n4\r\n5")
            (ghostel--embedded-redraw-now session t)
            (let ((start (ghostel--embedded-viewport-start session)))
              (should start)
              (save-excursion
                (goto-char start)
                (should (equal (buffer-substring-no-properties
                                (line-beginning-position)
                                (line-end-position))
                               "3")))))
        (ghostel--embedded-finish session)))))

(ert-deftest ghostel-test-embedded-host-settings ()
  "The host buffer gets a terminal's row and scroll settings while live."
  (with-temp-buffer
    (should-not truncate-lines)
    (should auto-hscroll-mode)
    (let ((session (ghostel--embedded-start (current-buffer) 1 3 20)))
      (should truncate-lines)
      (should-not auto-hscroll-mode)
      (should-not default-text-properties)
      (should (= scroll-conservatively 101))
      (should (equal line-spacing ghostel-line-spacing))
      (ghostel--embedded-finish session)
      (should-not truncate-lines)
      (should auto-hscroll-mode)
      (should (= scroll-conservatively 0))
      (should-not (local-variable-p 'truncate-lines)))))

(provide 'ghostel-embedded-test)
;;; ghostel-embedded-test.el ends here
