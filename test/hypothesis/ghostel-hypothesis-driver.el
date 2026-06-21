;;; ghostel-hypothesis-driver.el --- Batch runner for Hypothesis render tests -*- lexical-binding: t; -*-

;;; Commentary:

;; This file implements a small JSON-lines protocol used by
;; test/test_hypothesis_render.py.  Keeping one Emacs process alive makes
;; Hypothesis shrinking practical while still exercising the native renderer.

;;; Code:

(require 'base64)
(require 'json)
(require 'subr-x)
(require 'ghostel-test-helpers)

(defun ghostel-hypothesis--get (object key)
  "Return KEY from JSON hash table OBJECT."
  (gethash key object))

(defun ghostel-hypothesis--snapshot ()
  "Return current buffer text without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun ghostel-hypothesis--response (&rest pairs)
  "Return a JSON response object built from PAIRS.
PAIRS is a plist whose keys are encoded without the leading colon."
  (let (alist)
    (while pairs
      (let* ((key (pop pairs))
             (value (pop pairs))
             (name (substring (symbol-name key) 1)))
        (push (cons name value) alist)))
    (json-encode (nreverse alist))))

(defun ghostel-hypothesis-run-case (case)
  "Run one render consistency CASE and return a JSON-encodable alist.
CASE is parsed from Python JSON.  It has `rows', `cols', optional
`scrollback', and `ops'.  Each op is a write operation with base64 data,
a resize operation with delta_rows/delta_cols, or a redraw operation.
After all ops, a final incremental redraw is compared with a full redraw."
  (let* ((rows (ghostel-hypothesis--get case "rows"))
         (cols (ghostel-hypothesis--get case "cols"))
         (ops (ghostel-hypothesis--get case "ops"))
         (max-scrollback (or (ghostel-hypothesis--get case "scrollback")
                             (* 1024 1024)))
         (buf (generate-new-buffer " *ghostel-hypothesis-render*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new rows cols max-scrollback 0))
                 (ghostel--term term)
                 (ghostel--term-rows rows)
                 (ghostel--term-cols cols)
                 (ghostel-enable-url-detection nil)
                 (ghostel-enable-file-detection nil)
                 (ghostel-full-redraw nil)
                 (inhibit-read-only t))
            (dotimes (i (length ops))
              (let* ((op (aref ops i))
                     (kind (ghostel-hypothesis--get op "op")))
                (cond
                 ((equal kind "write")
                  (ghostel--write-vt
                   term
                   (base64-decode-string
                    (ghostel-hypothesis--get op "data"))))
                 ((equal kind "resize")
                  (let* ((delta-rows (ghostel-hypothesis--get op "delta_rows"))
                         (delta-cols (ghostel-hypothesis--get op "delta_cols"))
                         (new-rows (max 1 (+ ghostel--term-rows delta-rows)))
                         (new-cols (max 1 (+ ghostel--term-cols delta-cols))))
                    (ghostel--set-size term new-rows new-cols)
                    (setq ghostel--term-rows new-rows)
                    (setq ghostel--term-cols new-cols)))
                 ((equal kind "redraw")
                  (ghostel--redraw term nil))
                 (t
                  (error "unknown op: %S" kind)))))
            ;; First make the buffer reflect all pending terminal state via the
            ;; incremental path; then a full redraw must be a no-op for content.
            (ghostel--redraw term nil)
            (let ((incremental (ghostel-hypothesis--snapshot)))
              (ghostel--redraw term t)
              (let ((full (ghostel-hypothesis--snapshot)))
                (if (equal incremental full)
                    `((ok . t))
                  `((ok . :json-false)
                    (kind . "mismatch")
                    (incremental . ,(base64-encode-string
                                     (encode-coding-string incremental 'utf-8 t) t))
                    (full . ,(base64-encode-string
                              (encode-coding-string full 'utf-8 t) t))))))))
      (kill-buffer buf))))

(defun ghostel-hypothesis--read-case-file (file)
  "Read a Hypothesis CASE from JSON FILE."
  (json-parse-string (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))
                     :object-type 'hash-table
                     :array-type 'array
                     :null-object nil
                     :false-object :json-false))

(defun ghostel-hypothesis-replay-file (file)
  "Replay one Hypothesis render CASE from JSON FILE and exit Emacs.
This is intended for debugger launches: run a single saved case in a
plain batch Emacs process, without the Python/Hypothesis driver."
  (let ((json-object-type 'hash-table)
        (json-array-type 'array)
        (json-key-type 'string)
        (json-false :json-false)
        (inhibit-message t))
    (condition-case err
        (let ((result (ghostel-hypothesis-run-case
                       (ghostel-hypothesis--read-case-file file))))
          (princ (json-encode result))
          (terpri)
          (kill-emacs (if (eq t (cdr (assoc 'ok result))) 0 1)))
      (error
       (princ (ghostel-hypothesis--response
               :ok :json-false
               :kind "error"
               :error (error-message-string err)))
       (terpri)
       (kill-emacs 1)))))

(defun ghostel-hypothesis-serve ()
  "Serve render consistency cases over stdin/stdout as JSON lines."
  (let ((json-object-type 'hash-table)
        (json-array-type 'array)
        (json-key-type 'string)
        (json-false :json-false)
        (inhibit-message t))
    (princ (ghostel-hypothesis--response :ready t))
    (terpri)
    (while t
      (let ((line (condition-case nil
                      (read-from-minibuffer "")
                    (end-of-file nil))))
        (unless line
          (kill-emacs 0))
        (unless (string-empty-p line)
          (condition-case err
              (let* ((case (json-parse-string line
                                              :object-type 'hash-table
                                              :array-type 'array
                                              :null-object nil
                                              :false-object :json-false))
                     (result (ghostel-hypothesis-run-case case)))
                (princ (json-encode result)))
            (error
             (princ (ghostel-hypothesis--response
                     :ok :json-false
                     :kind "error"
                     :error (error-message-string err)))))
          (terpri))))))

(provide 'ghostel-hypothesis-driver)
;;; ghostel-hypothesis-driver.el ends here
