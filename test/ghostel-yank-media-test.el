;;; ghostel-yank-media-test.el --- Tests for ghostel: yank-media -*- lexical-binding: t; -*-

;;; Commentary:

;; Clipboard-image paste via `yank-media': handler registration, raw
;; byte round-trip to a temp file, extension mapping, remote-path
;; handling, and the dead-terminal guard.  The handler is called
;; directly (the `yank-media' dispatch needs a GUI clipboard), so
;; these run without a window system or a live PTY.

;;; Code:

(require 'ghostel-test-helpers)

(defvar yank-media--registered-handlers)

(defmacro ghostel-yank-media-test--with-mode-buffer (&rest body)
  "Run BODY in a `ghostel-mode' buffer with a live placeholder process.
Paths passed to `ghostel--dnd-send-files' are collected in `sent-files';
shell quoting itself is covered by the dnd tests."
  (declare (indent 0) (debug t))
  `(let ((buf (generate-new-buffer " *ghostel-yank-media-test*"))
         (sent-files nil))
     (unwind-protect
         (with-current-buffer buf
           (ghostel-mode)
           (setq ghostel--process
                 (start-process "ghostel-yank-media-test" nil "sleep" "30"))
           (cl-letf (((symbol-function 'ghostel--dnd-send-files)
                      (lambda (files)
                        (setq sent-files (append sent-files files)))))
             ,@body))
       (with-current-buffer buf
         (when (process-live-p ghostel--process)
           (delete-process ghostel--process)))
       (kill-buffer buf))))

(ert-deftest ghostel-test-yank-media-handler-registered ()
  "`ghostel-mode' registers a buffer-local image handler."
  (skip-unless (fboundp 'yank-media-handler))
  (with-temp-buffer
    (ghostel-mode)
    (should (local-variable-p 'yank-media--registered-handlers))
    (should (eq (cdr (assoc "image/.*" yank-media--registered-handlers))
                'ghostel--yank-media-data))
    (should (eq (cdr (assoc 'application/pdf yank-media--registered-handlers))
                'ghostel--yank-media-data))
    (should-not (assoc "image/.*"
                       (default-value 'yank-media--registered-handlers)))))

(ert-deftest ghostel-test-yank-media-image-round-trip ()
  "PNG bytes are written raw to a .png temp file and its path sent."
  (skip-unless (fboundp 'yank-media-handler))
  (ghostel-yank-media-test--with-mode-buffer
    (let* ((data (apply #'unibyte-string
                        (append '(#x89 ?P ?N ?G ?\r ?\n 0 #xff #x80)
                                (number-sequence 0 255))))
           ;; A dos-EOL write default must not corrupt the bytes.
           (buffer-file-coding-system 'utf-8-dos)
           (path (progn (ghostel--yank-media-data 'image/png data)
                        (car sent-files))))
      (unwind-protect
          (progn
            (should (equal (length sent-files) 1))
            (should (string-suffix-p ".png" path))
            (should (file-exists-p path))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally path)
              (should (equal (buffer-string) data))))
        (when (and path (file-exists-p path))
          (delete-file path))))))

(ert-deftest ghostel-test-yank-media-image-extension ()
  "The temp-file extension follows the MIME subtype."
  (skip-unless (fboundp 'yank-media-handler))
  (ghostel-yank-media-test--with-mode-buffer
    (let ((path (progn (ghostel--yank-media-data
                        'image/jpeg (unibyte-string #xff #xd8))
                       (car sent-files))))
      (unwind-protect
          (should (string-match-p "\\.jpe?g\\'" path))
        (when (and path (file-exists-p path))
          (delete-file path))))))

(ert-deftest ghostel-test-yank-media-pdf-round-trip ()
  "PDF bytes are written raw to a .pdf temp file and its path sent."
  (skip-unless (fboundp 'yank-media-handler))
  (ghostel-yank-media-test--with-mode-buffer
    (let* ((data (apply #'unibyte-string
                        (append (string-to-list "%PDF-1.4\n")
                                '(0 #xff #x80 #x0a) '(?% ?% ?E ?O ?F))))
           (path (progn (ghostel--yank-media-data 'application/pdf data)
                        (car sent-files))))
      (unwind-protect
          (progn
            (should (string-suffix-p ".pdf" path))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally path)
              (should (equal (buffer-string) data))))
        (when (and path (file-exists-p path))
          (delete-file path))))))

(ert-deftest ghostel-test-yank-media-image-remote-sends-localname ()
  "For a remote temp file the shell receives the localname."
  (skip-unless (fboundp 'yank-media-handler))
  (ghostel-yank-media-test--with-mode-buffer
    (cl-letf (((symbol-function 'make-temp-file)
               (lambda (&rest _) "/ssh:host:/tmp/ghostel-clipboard-x.png")))
      (ghostel--yank-media-data 'image/png (unibyte-string 1 2)))
    (should (equal sent-files '("/tmp/ghostel-clipboard-x.png")))))

(ert-deftest ghostel-test-yank-media-autoselect-any-image ()
  "Autoselect picks a non-preferred image flavor like TIFF-only clipboards."
  (skip-unless (and (require 'yank-media nil t)
                    (boundp 'yank-media-preferred-types)
                    (fboundp 'yank-media-autoselect-function)))
  (with-temp-buffer
    (ghostel-mode)
    ;; A TIFF-only clipboard (Qt apps on macOS) must autoselect.
    (should (equal (yank-media-autoselect-function '(image/tiff))
                   '(image/tiff)))
    ;; Stock priorities still win when several flavors are offered.
    (should (equal (yank-media-autoselect-function '(image/tiff image/png))
                   '(image/png)))
    ;; PDF autoselects alone, images beat it when both are offered.
    (should (equal (yank-media-autoselect-function '(application/pdf))
                   '(application/pdf)))
    (should (equal (yank-media-autoselect-function
                    '(application/pdf image/tiff))
                   '(image/tiff application/pdf)))
    ;; The catch-all is buffer-local; other modes keep stock behavior.
    (should (> (length yank-media-preferred-types)
               (length (default-value 'yank-media-preferred-types))))))

(ert-deftest ghostel-test-yank-media-image-dead-terminal ()
  "A dead terminal signals `user-error' and sends nothing."
  (skip-unless (fboundp 'yank-media-handler))
  (ghostel-yank-media-test--with-mode-buffer
    (delete-process ghostel--process)
    (should-error (ghostel--yank-media-data 'image/png (unibyte-string 1 2))
                  :type 'user-error)
    (should-not sent-files)))

(provide 'ghostel-yank-media-test)
;;; ghostel-yank-media-test.el ends here
