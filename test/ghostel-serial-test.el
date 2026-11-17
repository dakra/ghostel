;;; ghostel-serial-test.el --- Tests for serial consoles -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tests for byte decoding and the bridged serial terminal lifecycle.

;;; Code:

(require 'ert)
(require 'ghostel-serial)
(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-serial-decodes-split-utf8 ()
  "Decode valid UTF-8 split at any byte and preserve ASCII control bytes."
  (let ((bytes (encode-coding-string "a\0€界😀z" 'utf-8-unix)))
    (dotimes (offset (1+ (length bytes)))
      (let ((ghostel-serial--pending ""))
        (should (equal bytes
                       (concat (ghostel-serial--decode (substring bytes 0 offset))
                               (ghostel-serial--decode (substring bytes offset)))))
        (should (equal ghostel-serial--pending ""))))))

(ert-deftest ghostel-test-serial-flushes-bytes-according-to-policy ()
  "Flush a partial UTF-8 sequence and render malformed bytes by policy."
  (dolist (case '((replacement "��" "�") (hex "<E2><82>" "<FF>")
                  (latin-1 "â\u0082" "ÿ")))
    (pcase-let ((`(,ghostel-serial-invalid-byte-policy ,partial ,invalid) case))
      (let ((ghostel-serial--pending ""))
        (should (equal (ghostel-serial--decode (unibyte-string #xff))
                       (encode-coding-string invalid 'utf-8-unix)))
        (should (equal (ghostel-serial--decode (unibyte-string #xe2 #x82)) ""))
        (should (equal (ghostel-serial--decode "" t)
                       (encode-coding-string partial 'utf-8-unix)))
        (should (equal ghostel-serial--pending ""))))))

(ert-deftest ghostel-test-serial-rejects-non-scalar-utf8-on-every-boundary ()
  "Reject overlong, surrogate, and out-of-range encodings in any chunks."
  (let ((ghostel-serial-invalid-byte-policy 'hex)
        (bytes (unibyte-string #xc0 #xaf #xed #xa0 #x80 #xf4 #x90 #x80 #x80
                               #xf5 #x80 #x80 #x80)))
    (dotimes (offset (1+ (length bytes)))
      (let ((ghostel-serial--pending ""))
        (should (equal "<C0><AF><ED><A0><80><F4><90><80><80><F5><80><80><80>"
                       (concat (ghostel-serial--decode (substring bytes 0 offset))
                               (ghostel-serial--decode (substring bytes offset) t))))))))

(ert-deftest ghostel-test-serial-reconnect-keeps-the-log ()
  "Reopen a serial bridge without losing output or changing outbound bytes."
  :tags '(native)
  (let ((buffer nil)
        (ghostel-serial-invalid-byte-policy 'hex)
        opens sent)
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'make-serial-process)
                     (lambda (&rest args)
                       (push args opens)
                       (make-pipe-process :name "ghostel-serial-test"
                                          :buffer (plist-get args :buffer)
                                          :noquery t)))
                    ((symbol-function 'process-send-string)
                     (lambda (_process bytes) (push bytes sent))))
            (setq buffer (ghostel-serial "/dev/ghostel-test" 57600))
            (with-current-buffer buffer
              (let ((old ghostel-serial--process))
                (should (eq (plist-get (car opens) :coding) 'no-conversion))
                (should-not desktop-save-buffer)
                (ghostel-serial--filter old (concat "\e[?2004hBoot: \e[" (unibyte-string #xe2)))
                (funcall ghostel--pty-out-function (unibyte-string 0 255))
                (should (equal sent (list (unibyte-string 0 255))))
                (ghostel-serial-disconnect)
                (should buffer-read-only)
                (should-not (process-live-p old))
                (should (string-match-p "Boot: <E2>" (ghostel-test--terminal-text)))
                (ghostel-serial-reconnect)
                (should (process-live-p ghostel-serial--process))
                (should (eq (plist-get (car opens) :speed) 57600))
                (should (string-match-p "Boot: <E2>" (ghostel-test--terminal-text)))
                (cl-letf (((symbol-function 'ghostel--on-user-input) #'ignore))
                  (ghostel--paste-text "test"))
                (should (equal (car sent) "test"))
                (should (= (length opens) 2))
                (let ((reopened ghostel-serial--process))
                  (fundamental-mode)
                  (should-not (process-live-p reopened)))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

;;; ghostel-serial-test.el ends here
