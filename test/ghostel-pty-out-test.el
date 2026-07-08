;;; ghostel-pty-out-test.el --- Tests for ghostel: outbound PTY hook -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel--pty-out' routing: processless terminals deliver encoder
;; output and query replies to `ghostel--pty-out-function'.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-test--with-processless-term (captured &rest body)
  "Run BODY in a processless ghostel buffer capturing outbound bytes.
CAPTURED is bound to a string accumulating everything the terminal
writes through `ghostel--pty-out-function'."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer " *ghostel-test-pty-out*"))
         (,captured ""))
     (unwind-protect
         (progn
           (ghostel--init-buffer buf 24 80)
           (with-current-buffer buf
             (setq ghostel--pty-out-function
                   (lambda (data) (setq ,captured (concat ,captured data))))
             ,@body))
       (kill-buffer buf))))

(ert-deftest ghostel-test-pty-out-hook-receives-encoded-keys ()
  "Key encoder output in a processless buffer reaches the hook."
  :tags '(native)
  (ghostel-test--with-processless-term captured
    (ghostel--send-encoded "a" "" "a")
    (ghostel--send-encoded "c" "ctrl")
    (should (equal captured "a\C-c"))))

(ert-deftest ghostel-test-pty-out-hook-receives-paste ()
  "Paste encoder output in a processless buffer reaches the hook."
  :tags '(native)
  (ghostel-test--with-processless-term captured
    (ghostel--encode-paste ghostel--term "plain")
    (should (equal captured "plain"))))

(ert-deftest ghostel-test-pty-out-hook-receives-bracketed-paste ()
  "Bracketed paste wrapping applies before the hook sees the bytes."
  :tags '(native)
  (ghostel-test--with-processless-term captured
    (ghostel--write-vt ghostel--term "\e[?2004h")
    (ghostel--encode-paste ghostel--term "wrapped")
    (should (equal captured "\e[200~wrapped\e[201~"))))

(ert-deftest ghostel-test-pty-out-hook-receives-query-replies ()
  "Terminal query replies (DA1) route through the hook."
  :tags '(native)
  (ghostel-test--with-processless-term captured
    ;; DA1 query; libghostty replies through the write-pty effect.
    (ghostel--write-vt ghostel--term "\e[c")
    (should (string-prefix-p "\e[?62" captured))))

(ert-deftest ghostel-test-pty-out-processless-without-hook-is-silent ()
  "A processless buffer without a hook drops output without error."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-pty-out*")))
    (unwind-protect
        (progn
          (ghostel--init-buffer buf 24 80)
          (with-current-buffer buf
            (ghostel--send-encoded "a" "")
            (should-not ghostel--pty-out-function)))
      (kill-buffer buf))))

(provide 'ghostel-pty-out-test)
;;; ghostel-pty-out-test.el ends here
