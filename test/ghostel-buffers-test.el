;;; ghostel-buffers-test.el --- Tests for ghostel: multi-buffer navigation -*- lexical-binding: t; -*-

;;; Commentary:

;; Cycle commands, list pickers, project-scoped variants, and the
;; public `ghostel-create' API.
;; All tests are pure elisp — no native module required.

;;; Code:

(require 'ghostel-test-helpers)

(defun ghostel-buffers-test--make (name &optional dir identity)
  "Create a fake ghostel-mode buffer for tests.
NAME is the buffer name.  Optional DIR sets `default-directory'
and IDENTITY sets `ghostel-identity'.  The buffer claims
`ghostel-mode' via `major-mode' without invoking the mode
function (which would require the native module)."
  (let ((buf (generate-new-buffer name)))
    (with-current-buffer buf
      (setq major-mode 'ghostel-mode)
      (when dir (setq default-directory dir))
      (when identity (setq-local ghostel-identity identity)))
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

(ert-deftest ghostel-test-other-switches-to-other-buffer ()
  "`ghostel-other' pops to another ghostel buffer when one exists."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*")
                                    (b "*ghostel-b*"))
    (let (popped ghostel-called)
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buf &rest _) (setq popped buf)))
                ((symbol-function 'ghostel)
                 (lambda (&optional _) (setq ghostel-called t))))
        (with-current-buffer a (ghostel-other))
        (should (eq popped b))
        (should-not ghostel-called)))))

(ert-deftest ghostel-test-other-from-non-ghostel-buffer ()
  "From a non-ghostel buffer, `ghostel-other' pops to an existing terminal."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*"))
    (let ((other (generate-new-buffer "*scratch-y*")) popped)
      (unwind-protect
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buf &rest _) (setq popped buf))))
            (with-current-buffer other (ghostel-other))
            (should (eq popped a)))
        (kill-buffer other)))))

(ert-deftest ghostel-test-other-sole-buffer-creates-fresh ()
  "In the only ghostel buffer, `ghostel-other' forces a fresh terminal."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*"))
    (let (ghostel-arg)
      (cl-letf (((symbol-function 'ghostel)
                 (lambda (&optional arg) (setq ghostel-arg arg))))
        (with-current-buffer a (ghostel-other))
        (should ghostel-arg)
        (should-not (numberp ghostel-arg))))))

(ert-deftest ghostel-test-other-no-buffers-creates-default ()
  "With zero ghostel buffers, `ghostel-other' calls `ghostel' without arg."
  (let ((called 'not-called))
    (cl-letf (((symbol-function 'ghostel)
               (lambda (&optional arg) (setq called arg))))
      (ghostel-other))
    (should-not called)
    (should-not (eq called 'not-called))))

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

;;; Completion annotations

(ert-deftest ghostel-test-annotate-buffer-title ()
  "`ghostel-annotate-buffer' caps the title at `ghostel-annotation-title-width'."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*"))
    (with-current-buffer a (setq-local ghostel--title "make test"))
    (should (equal "  make test" (ghostel-annotate-buffer (buffer-name a))))
    (with-current-buffer a (setq-local ghostel--title (make-string 60 ?x)))
    (let* ((ghostel-annotation-title-width 30)
           (annotation (ghostel-annotate-buffer (buffer-name a))))
      (should (<= (string-width annotation) 32))
      (should (string-suffix-p (truncate-string-ellipsis) annotation)))
    (let* ((ghostel-annotation-title-width nil)
           (annotation (ghostel-annotate-buffer (buffer-name a))))
      (should (equal (concat "  " (make-string 60 ?x)) annotation)))))

(ert-deftest ghostel-test-annotate-buffer-no-title ()
  "`ghostel-annotate-buffer' returns nil without a title or buffer."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*"))
    (should-not (ghostel-annotate-buffer (buffer-name a))))
  (should-not (ghostel-annotate-buffer "*ghostel-no-such-buffer*")))

(ert-deftest ghostel-test-read-buffer-annotates ()
  "`ghostel--read-buffer' exposes `ghostel-annotate-buffer' to completion."
  (ghostel-buffers-test--with-bufs ((a "*ghostel-a*"))
    (let (captured)
      (cl-letf (((symbol-function 'read-buffer)
                 (lambda (_prompt default &rest _)
                   (setq captured (plist-get completion-extra-properties
                                             :annotation-function))
                   default)))
        (ghostel--read-buffer "Ghostel buffer: " (list a))
        (should (eq captured #'ghostel-annotate-buffer))))))

;;; Project-scope helpers

(defun ghostel-buffers-test--proj-stub (root)
  "Return a `project-current' stub: project rooted at ROOT, else nil."
  (lambda (&optional _maybe-prompt &rest rest)
    (let ((dir (or (car rest) default-directory)))
      (when (and dir (string-prefix-p root (expand-file-name dir)))
        (cons 'transient root)))))

(ert-deftest ghostel-test-project-buffers-default-directory ()
  "Scope `default-directory' matches buffers under the project root."
  (let* ((root (make-temp-file "ghostel-myproj" t))
         (root (file-name-as-directory root))
         (outside-root (file-name-as-directory
                        (make-temp-file "ghostel-other" t))))
    (ghostel-buffers-test--with-bufs
        ((inside "*ghostel-in*" (expand-file-name "src/" root))
         (outside "*ghostel-out*" outside-root)
         (also-in "*ghostel-also*" root))
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
  "Scope `identity' matches term slots tagged with the project root."
  (let* ((root (make-temp-file "ghostel-myproj" t))
         (root (file-name-as-directory root))
         (outside-root (file-name-as-directory
                        (make-temp-file "ghostel-other" t)))
         (ghostel-buffer-name "*ghostel*"))
    (ghostel-buffers-test--with-bufs
        ((tagged "*ghostel-tagged*" outside-root
                 `((kind . term)
                   (project-root . ,(ghostel--normalize-root root))
                   (instance . 1)))
         (untagged "*ghostel-untag*" root nil))
      (cl-letf (((symbol-function 'project-current)
                 (ghostel-buffers-test--proj-stub root))
                ((symbol-function 'project-root) (lambda (p) (cdr p))))
        (let ((default-directory root)
              (ghostel-project-buffer-scope 'identity))
          (let ((bufs (ghostel-project-buffer-list)))
            (should (memq tagged bufs))
            (should-not (memq untagged bufs))))))))

(ert-deftest ghostel-test-project-buffers-both ()
  "Scope `both' unions `default-directory' and identity matches; no duplicates."
  (let* ((root (make-temp-file "ghostel-myproj" t))
         (root (file-name-as-directory root))
         (outside-root (file-name-as-directory
                        (make-temp-file "ghostel-other" t)))
         (ghostel-buffer-name "*ghostel*"))
    (ghostel-buffers-test--with-bufs
        ((by-dir "*ghostel-d*" root nil)
         (by-id "*ghostel-i*" outside-root
                `((kind . term)
                  (project-root . ,(ghostel--normalize-root root))
                  (instance . 1)))
         (both "*ghostel-b*" (expand-file-name "sub/" root)
               `((kind . term)
                 (project-root . ,(ghostel--normalize-root root))
                 (instance . 2)))
         (neither "*ghostel-n*" outside-root nil))
      (cl-letf (((symbol-function 'project-current)
                 (ghostel-buffers-test--proj-stub root))
                ((symbol-function 'project-root) (lambda (p) (cdr p))))
        (let ((default-directory root)
              (ghostel-project-buffer-scope 'both))
          (let ((bufs (ghostel-project-buffer-list)))
            (should (memq by-dir bufs))
            (should (memq by-id bufs))
            (should (memq both bufs))
            (should-not (memq neither bufs))
            (should (= 1 (cl-count both bufs)))))))))

;;; Structured identity

(ert-deftest ghostel-test-identity-equal-order-insensitive ()
  "`ghostel--identity-equal' ignores pair order but not content."
  (should (ghostel--identity-equal
           '((kind . term) (instance . 1))
           '((instance . 1) (kind . term))))
  (should-not (ghostel--identity-equal
               '((kind . term) (instance . 1))
               '((kind . term) (instance . 2))))
  (should-not (ghostel--identity-equal
               '((kind . term) (instance . 1))
               '((kind . term) (instance . 1) (project-root . "~/a/b/")))))

(ert-deftest ghostel-test-identity-match-p-subset ()
  "`ghostel-identity-match-p' matches subsets, including composed contexts."
  (let ((id '((kind . term) (project-root . "~/d/b/") (instance . 3))))
    (should (ghostel-identity-match-p '((kind . term)) id))
    (should (ghostel-identity-match-p '((project-root . "~/d/b/")) id))
    (should (ghostel-identity-match-p
             '((kind . term) (project-root . "~/d/b/")) id))
    (should (ghostel-identity-match-p nil id))
    (should-not (ghostel-identity-match-p '((project-root . "~/a/b/")) id))
    (should-not (ghostel-identity-match-p '((kind . compile)) id))
    (should-not (ghostel-identity-match-p '((kind . term)) nil))))

(ert-deftest ghostel-test-project-buffers-same-name-projects-distinct ()
  "Two projects sharing a directory basename do not conflate.
This is the bug class where `ghostel-project' reused another
project's terminal because both rendered the same buffer name."
  (let* ((parent-a (file-name-as-directory (make-temp-file "ghostel-pa" t)))
         (parent-b (file-name-as-directory (make-temp-file "ghostel-pb" t)))
         (root-a (file-name-as-directory (expand-file-name "b" parent-a)))
         (root-b (file-name-as-directory (expand-file-name "b" parent-b))))
    (make-directory root-a)
    (make-directory root-b)
    (ghostel-buffers-test--with-bufs
        ((in-a "*b-ghostel*"
               root-a
               `((kind . term)
                 (project-root . ,(ghostel--normalize-root root-a))
                 (instance . 1)))
         (in-b "*b-ghostel*"
               root-b
               `((kind . term)
                 (project-root . ,(ghostel--normalize-root root-b))
                 (instance . 1))))
      ;; Slot reuse: each root finds exactly its own buffer.
      (should (eq in-a (ghostel--find-buffer-by-identity
                        (buffer-local-value 'ghostel-identity in-a))))
      (should (eq in-b (ghostel--find-buffer-by-identity
                        (buffer-local-value 'ghostel-identity in-b))))
      ;; Identity scope from project A sees only A's terminal.
      (cl-letf (((symbol-function 'project-current)
                 (ghostel-buffers-test--proj-stub root-a))
                ((symbol-function 'project-root) (lambda (p) (cdr p))))
        (let ((default-directory root-a)
              (ghostel-project-buffer-scope 'identity))
          (let ((bufs (ghostel-project-buffer-list)))
            (should (memq in-a bufs))
            (should-not (memq in-b bufs))))))))

(ert-deftest ghostel-test-project-buffers-identity-includes-numbered ()
  "Identity scope includes numbered instances of the project's slots."
  (let* ((root (file-name-as-directory (make-temp-file "ghostel-num" t))))
    (ghostel-buffers-test--with-bufs
        ((first "*num-ghostel*" root
                `((kind . term)
                  (project-root . ,(ghostel--normalize-root root))
                  (instance . 1)))
         (second "*num-ghostel*<2>" root
                 `((kind . term)
                   (project-root . ,(ghostel--normalize-root root))
                   (instance . 2))))
      (cl-letf (((symbol-function 'project-current)
                 (ghostel-buffers-test--proj-stub root))
                ((symbol-function 'project-root) (lambda (p) (cdr p))))
        (let ((default-directory root)
              (ghostel-project-buffer-scope 'identity))
          (let ((bufs (ghostel-project-buffer-list)))
            (should (memq first bufs))
            (should (memq second bufs))))))))

(ert-deftest ghostel-test-project-buffers-identity-excludes-other-kinds ()
  "Identity scope skips non-term kinds tagged with the same project."
  (let* ((root (file-name-as-directory (make-temp-file "ghostel-kind" t))))
    (ghostel-buffers-test--with-bufs
        ((term "*kind-ghostel*" root
               `((kind . term)
                 (project-root . ,(ghostel--normalize-root root))
                 (instance . 1)))
         (compile "*kind-compile*" root
                  `((kind . compile)
                    (project-root . ,(ghostel--normalize-root root)))))
      (cl-letf (((symbol-function 'project-current)
                 (ghostel-buffers-test--proj-stub root))
                ((symbol-function 'project-root) (lambda (p) (cdr p))))
        (let ((default-directory root)
              (ghostel-project-buffer-scope 'identity))
          (let ((bufs (ghostel-project-buffer-list)))
            (should (memq term bufs))
            (should-not (memq compile bufs))))))))

(ert-deftest ghostel-test-normalize-root-remote-unchanged ()
  "Remote roots are not expanded or abbreviated during normalization."
  (should (equal "/ssh:user@host:/tmp/proj/"
                 (ghostel--normalize-root "/ssh:user@host:/tmp/proj/")))
  (should (equal "/ssh:user@host:/tmp/proj/"
                 (ghostel--normalize-root "/ssh:user@host:/tmp/proj"))))

(ert-deftest ghostel-test-find-buffer-skips-non-ghostel-mode ()
  "A slot identity surviving a major-mode change no longer claims the slot."
  (let ((buf (generate-new-buffer "*ghostel-was*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-mode 'ghostel-mode)
            (setq-local ghostel-identity '((kind . term) (instance . 1))))
          (should (eq (ghostel--find-buffer-by-identity
                       '((kind . term) (instance . 1)))
                      buf))
          (with-current-buffer buf (fundamental-mode))
          ;; The permanent-local identity survives the mode change ...
          (should (equal (buffer-local-value 'ghostel-identity buf)
                         '((kind . term) (instance . 1))))
          ;; ... but the buffer no longer claims the slot.
          (should-not (ghostel--find-buffer-by-identity
                       '((kind . term) (instance . 1)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-next-instance ()
  "`ghostel--next-instance' returns 1 + the highest instance per context."
  (should (= 1 (ghostel--next-instance '((kind . term)))))
  (ghostel-buffers-test--with-bufs
      ((_a "*ghostel*" nil '((kind . term) (instance . 1)))
       (_b "*ghostel*<3>" nil '((kind . term) (instance . 3)))
       (_c "*p-ghostel*" nil '((kind . term)
                               (project-root . "~/p/")
                               (instance . 7))))
    ;; Global slots and project slots are separate contexts.
    (should (= 4 (ghostel--next-instance '((kind . term)))))
    (should (= 8 (ghostel--next-instance
                  '((kind . term) (project-root . "~/p/")))))
    (should (= 1 (ghostel--next-instance
                  '((kind . term) (project-root . "~/q/")))))))

(ert-deftest ghostel-test-project-next-without-project-errors ()
  "`ghostel-project-next' errors when there is no current project."
  (cl-letf (((symbol-function 'project-current)
             (lambda (&optional maybe-prompt &rest _)
               (when maybe-prompt (user-error "No project")))))
    (should-error (ghostel-project-next) :type 'user-error)))

;;; Public create API

(defmacro ghostel-buffers-test--with-create-stubs (&rest body)
  "Run BODY with the native entry points and process spawn stubbed.
Same stub set as the buffer-naming tests: `ghostel-create' runs its
full buffer setup, but no module or process is involved."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'ghostel--new)
              (lambda (&rest _args) 'fake-term))
             ((symbol-function 'ghostel--set-size) #'ignore)
             ((symbol-function 'ghostel--apply-palette)
              (lambda (&rest _args) nil))
             ((symbol-function 'ghostel--start-process)
              (lambda () nil)))
     ,@body))

(ert-deftest ghostel-test-create-default-name-and-identity ()
  "`ghostel-create' defaults NAME and keys the identity to it."
  (ghostel-buffers-test--with-create-stubs
    (let ((ghostel-buffer-name "*ghostel-create-default*")
          buf)
      (unwind-protect
          (progn
            (setq buf (ghostel-create))
            (should (equal (buffer-name buf) ghostel-buffer-name))
            (should (equal (buffer-local-value 'ghostel-identity buf)
                           '((kind . term)
                             (name . "*ghostel-create-default*")
                             (instance . 1)))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest ghostel-test-create-always-fresh-uniquified ()
  "`ghostel-create' never reuses; the second buffer gets the next slot.
The default identity keys the requested NAME with the next free
instance, so `ghostel''s slot arithmetic can find the buffer."
  (ghostel-buffers-test--with-create-stubs
    (let (a b)
      (unwind-protect
          (progn
            (setq a (ghostel-create "*ghostel-fresh*")
                  b (ghostel-create "*ghostel-fresh*"))
            (should-not (eq a b))
            (should (equal (buffer-name b) "*ghostel-fresh*<2>"))
            (should (equal (buffer-local-value 'ghostel-identity b)
                           '((kind . term)
                             (name . "*ghostel-fresh*")
                             (instance . 2))))
            (should (eq b (ghostel--find-buffer-by-identity
                           '((kind . term)
                             (name . "*ghostel-fresh*")
                             (instance . 2))))))
        (dolist (buf (list a b))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest ghostel-test-create-identity-override-verbatim ()
  "A non-nil IDENTITY is stored verbatim, like `ghostel-exec's."
  (ghostel-buffers-test--with-create-stubs
    (let ((identity '((kind . term) (tab . "work") (instance . 1)))
          buf)
      (unwind-protect
          (progn
            (setq buf (ghostel-create "*ghostel-tab*" nil identity))
            (should (eq (buffer-local-value 'ghostel-identity buf) identity)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest ghostel-test-create-suffix-matches-instance-after-kill ()
  "The NAME<N> suffix follows the allocated instance, not name collisions.
After killing instance 1 its plain name is free again, but the next
slot is 3; the new buffer must be named for its instance so `ghostel'
still reaches every slot by number."
  (ghostel-buffers-test--with-create-stubs
    (let (a b c)
      (unwind-protect
          (progn
            (setq a (ghostel-create "*ghostel-refill*")
                  b (ghostel-create "*ghostel-refill*"))
            (kill-buffer a)
            (setq c (ghostel-create "*ghostel-refill*"))
            (should (equal (buffer-name c) "*ghostel-refill*<3>"))
            (should (equal (alist-get 'instance
                                      (buffer-local-value 'ghostel-identity c))
                           3)))
        (dolist (buf (list a b c))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(ert-deftest ghostel-test-create-empty-name-uses-default ()
  "An empty NAME falls back to `ghostel-buffer-name'."
  (ghostel-buffers-test--with-create-stubs
    (let ((ghostel-buffer-name "*ghostel-create-empty*")
          buf)
      (unwind-protect
          (progn
            (setq buf (ghostel-create ""))
            (should (equal (buffer-name buf) ghostel-buffer-name)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(provide 'ghostel-buffers-test)
;;; ghostel-buffers-test.el ends here
