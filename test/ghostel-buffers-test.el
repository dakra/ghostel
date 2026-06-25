;;; ghostel-buffers-test.el --- Tests for ghostel: multi-buffer navigation -*- lexical-binding: t; -*-

;;; Commentary:

;; Cycle commands, list pickers, and project-scoped variants.
;; All tests are pure elisp — no native module required.

;;; Code:

(require 'ghostel-test-helpers)

(defun ghostel-buffers-test--make (name &optional dir identity)
  "Create a fake ghostel-mode buffer for tests.
NAME is the buffer name.  Optional DIR sets `default-directory'
and IDENTITY sets `ghostel--buffer-identity'.  The buffer claims
`ghostel-mode' via `major-mode' without invoking the mode
function (which would require the native module)."
  (let ((buf (generate-new-buffer name)))
    (with-current-buffer buf
      (setq major-mode 'ghostel-mode)
      (when dir (setq default-directory dir))
      (when identity (setq-local ghostel--buffer-identity identity)))
    buf))

(defmacro ghostel-buffers-test--with-bufs (bindings &rest body)
  "Run BODY with fake ghostel buffers from BINDINGS, killing them after.
Each BINDING is (VAR NAME [DIR [IDENTITY]])."
  (declare (indent 1))
  `(let ,(mapcar (lambda (b)
                   `(,(car b) (ghostel-buffers-test--make ,@(cdr b))))
                 bindings)
     (unwind-protect (progn ,@body)
       ,@(mapcar (lambda (b) `(when (buffer-live-p ,(car b))
                                (kill-buffer ,(car b))))
                 bindings))))

(ert-deftest ghostel-test-all-buffers-sorted ()
  "`ghostel-buffer-list' returns ghostel buffers sorted by name."
  (ghostel-buffers-test--with-bufs ((c "*ghostel-c*")
                                    (a "*ghostel-a*")
                                    (b "*ghostel-b*"))
    (let ((bufs (ghostel-buffer-list)))
      (should (equal (mapcar #'buffer-name bufs)
                     '("*ghostel-a*" "*ghostel-b*" "*ghostel-c*"))))))

(ert-deftest ghostel-test-all-buffers-excludes-non-ghostel ()
  "`ghostel-buffer-list' skips buffers without `ghostel-mode'."
  (ghostel-buffers-test--with-bufs ((g "*ghostel-x*"))
    (let ((other (generate-new-buffer "*not-ghostel*")))
      (unwind-protect
          (let ((bufs (ghostel-buffer-list)))
            (should (memq g bufs))
            (should-not (memq other bufs)))
        (kill-buffer other)))))

(ert-deftest ghostel-test-next-cycles-and-wraps ()
  "`ghostel-next' advances forward and wraps from last to first."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*")
                                    (b "*ghostel-b*")
                                    (c "*ghostel-c*"))
    (let (popped)
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf &rest _) (setq popped buf))))
        (with-current-buffer a (ghostel-next))
        (should (eq popped b))
        (with-current-buffer b (ghostel-next))
        (should (eq popped c))
        (with-current-buffer c (ghostel-next))
        (should (eq popped a))))))

(ert-deftest ghostel-test-previous-cycles-and-wraps ()
  "`ghostel-previous' advances backward and wraps from first to last."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*")
                                    (b "*ghostel-b*")
                                    (c "*ghostel-c*"))
    (let (popped)
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf &rest _) (setq popped buf))))
        (with-current-buffer c (ghostel-previous))
        (should (eq popped b))
        (with-current-buffer b (ghostel-previous))
        (should (eq popped a))
        (with-current-buffer a (ghostel-previous))
        (should (eq popped c))))))

(ert-deftest ghostel-test-cycle-non-ghostel-current ()
  "From a non-ghostel buffer, `ghostel-next' jumps to first; `-previous' to last."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*")
                                    (b "*ghostel-b*"))
    (let ((other (generate-new-buffer "*scratch-x*")) popped)
      (unwind-protect
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buf &rest _) (setq popped buf))))
            (with-current-buffer other (ghostel-next))
            (should (eq popped a))
            (with-current-buffer other (ghostel-previous))
            (should (eq popped b)))
        (kill-buffer other)))))

(ert-deftest ghostel-test-cycle-single-buffer-no-op ()
  "Cycling with one buffer that is current is a no-op, with a clean message."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*"))
    (let (popped captured-msg)
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf &rest _) (setq popped buf)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq captured-msg (apply #'format fmt args)))))
        (with-current-buffer a (ghostel-next))
        (should-not popped)
        (should (equal captured-msg "Only one ghostel buffer"))
        (setq captured-msg nil)
        (with-current-buffer a (ghostel-previous))
        (should-not popped)
        (should (equal captured-msg "Only one ghostel buffer"))))))

(ert-deftest ghostel-test-cycle-no-buffers-errors ()
  "`ghostel-next'/`-previous' with zero ghostel buffers signals `user-error'."
  (should-error (ghostel-next) :type 'user-error)
  (should-error (ghostel-previous) :type 'user-error))

(ert-deftest ghostel-test-list-buffers-predicate ()
  "`ghostel-list-buffers' offers only ghostel buffers to `read-buffer'."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*")
                                    (b "*ghostel-b*"))
    (let ((other (generate-new-buffer "*not-ghostel*")) captured-pred)
      (unwind-protect
          (cl-letf (((symbol-function 'read-buffer)
                     (lambda (_prompt _default _require-match pred)
                       (setq captured-pred pred)
                       (buffer-name a)))
                    ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
            (ghostel-list-buffers)
            (should captured-pred)
            (should (funcall captured-pred (buffer-name a)))
            (should (funcall captured-pred (buffer-name b)))
            (should-not (funcall captured-pred (buffer-name other))))
        (kill-buffer other)))))

(ert-deftest ghostel-test-list-buffers-default-is-next ()
  "`ghostel-list-buffers' defaults to the forward-cycle buffer."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*")
                                    (b "*ghostel-b*")
                                    (c "*ghostel-c*"))
    (let (captured-default)
      (cl-letf (((symbol-function 'read-buffer)
                 (lambda (_prompt default &rest _)
                   (setq captured-default default)
                   (buffer-name a)))
                ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
        (with-current-buffer b (ghostel-list-buffers))
        (should (equal captured-default (buffer-name c)))))))

(ert-deftest ghostel-test-list-buffers-no-buffers-errors ()
  "`ghostel-list-buffers' signals `user-error' when none exist."
  (should-error (ghostel-list-buffers) :type 'user-error))

;;; Project-scope helpers

(defun ghostel-buffers-test--proj-stub (root)
  "Return a `project-current' stub: project rooted at ROOT, else nil."
  (lambda (&optional _maybe-prompt &rest rest)
    (let ((dir (or (car rest) default-directory)))
      (when (and dir (string-prefix-p root (expand-file-name dir)))
        (cons 'transient root)))))

(ert-deftest ghostel-test-project-buffers-default-directory ()
  "Scope `default-directory' matches buffers under the project root."
  (let ((root "/tmp/myproj/"))
    (ghostel-buffers-test--with-bufs
        ((inside "*ghostel-in*" "/tmp/myproj/src/")
         (outside "*ghostel-out*" "/tmp/other/")
         (also-in "*ghostel-also*" "/tmp/myproj/"))
      (cl-letf (((symbol-function 'project-current)
                 (ghostel-buffers-test--proj-stub root))
                ((symbol-function 'project-root) (lambda (p) (cdr p)))
                ((symbol-function 'project-prefixed-buffer-name)
                 (lambda (name) (format "*myproj-%s*" name))))
        (let ((default-directory root)
              (ghostel-project-buffer-scope 'default-directory))
          (let ((bufs (ghostel-project-buffer-list)))
            (should (memq inside bufs))
            (should (memq also-in bufs))
            (should-not (memq outside bufs))))))))

(ert-deftest ghostel-test-project-buffers-identity ()
  "Scope `identity' matches buffers whose identity is the project-prefixed name."
  (let ((root "/tmp/myproj/")
        (ghostel-buffer-name "*ghostel*"))
    (ghostel-buffers-test--with-bufs
        ((tagged "*ghostel-tagged*" "/tmp/other/" "*myproj-ghostel*")
         (untagged "*ghostel-untag*" "/tmp/myproj/" nil))
      (cl-letf (((symbol-function 'project-current)
                 (ghostel-buffers-test--proj-stub root))
                ((symbol-function 'project-root) (lambda (p) (cdr p)))
                ((symbol-function 'project-prefixed-buffer-name)
                 (lambda (name) (format "*myproj-%s*" name))))
        (let ((default-directory root)
              (ghostel-project-buffer-scope 'identity))
          (let ((bufs (ghostel-project-buffer-list)))
            (should (memq tagged bufs))
            (should-not (memq untagged bufs))))))))

(ert-deftest ghostel-test-project-buffers-both ()
  "Scope `both' unions `default-directory' and identity matches; no duplicates."
  (let ((root "/tmp/myproj/")
        (ghostel-buffer-name "*ghostel*"))
    (ghostel-buffers-test--with-bufs
        ((by-dir "*ghostel-d*" "/tmp/myproj/" nil)
         (by-id "*ghostel-i*" "/tmp/other/" "*myproj-ghostel*")
         (both "*ghostel-b*" "/tmp/myproj/sub/" "*myproj-ghostel*")
         (neither "*ghostel-n*" "/tmp/other/" nil))
      (cl-letf (((symbol-function 'project-current)
                 (ghostel-buffers-test--proj-stub root))
                ((symbol-function 'project-root) (lambda (p) (cdr p)))
                ((symbol-function 'project-prefixed-buffer-name)
                 (lambda (name) (format "*myproj-%s*" name))))
        (let ((default-directory root)
              (ghostel-project-buffer-scope 'both))
          (let ((bufs (ghostel-project-buffer-list)))
            (should (memq by-dir bufs))
            (should (memq by-id bufs))
            (should (memq both bufs))
            (should-not (memq neither bufs))
            (should (= 1 (cl-count both bufs)))))))))

(ert-deftest ghostel-test-project-next-without-project-errors ()
  "`ghostel-project-next' errors when there is no current project."
  (cl-letf (((symbol-function 'project-current)
             (lambda (&optional maybe-prompt &rest _)
               (when maybe-prompt (user-error "No project")))))
    (should-error (ghostel-project-next) :type 'user-error)))

(provide 'ghostel-buffers-test)
;;; ghostel-buffers-test.el ends here
