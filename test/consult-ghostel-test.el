;;; consult-ghostel-test.el --- Tests for consult-ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L <consult> -L lisp -L extensions/consult-ghostel \
;;     -l ert -l test/consult-ghostel-test.el -f consult-ghostel-test-run
;;
;; `consult-ghostel' source plists and their item/enabled/arrange logic,
;; against the real consult.  The interactive commands run
;; `consult--multi' in the minibuffer and are covered by live testing,
;; not here.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'consult)
(require 'ghostel)
(require 'consult-ghostel)

(defun consult-ghostel-test--fake-buffer (name)
  "Return a buffer NAME claiming `ghostel-mode' without the native module."
  (let ((buf (generate-new-buffer name)))
    (with-current-buffer buf
      (setq major-mode 'ghostel-mode))
    buf))

(ert-deftest consult-ghostel-test-source-properties ()
  "Sources carry the consult properties that drive preview and create-on-miss."
  (dolist (src (list consult-ghostel-source consult-ghostel-project-source))
    (should (eq (plist-get src :category) 'buffer))
    (should (eq (plist-get src :state) 'consult--buffer-state))
    (should (eq (plist-get src :annotate) 'ghostel-annotate-buffer))
    (should (functionp (plist-get src :new))))
  ;; Hidden variants inherit those and add `:hidden'.
  (dolist (src (list consult-ghostel-source-hidden
                     consult-ghostel-project-source-hidden))
    (should (plist-get src :hidden))
    (should (eq (plist-get src :category) 'buffer))
    (should (eq (plist-get src :state) 'consult--buffer-state))
    (should (eq (plist-get src :annotate) 'ghostel-annotate-buffer))
    (should (functionp (plist-get src :new)))))

(ert-deftest consult-ghostel-test-hidden-sources-independent ()
  "Hidden variants share no structure with the base sources.
A shared tail would make `consult-customize' on one variable mutate
the other."
  (should-not (eq (last consult-ghostel-source-hidden)
                  (last consult-ghostel-source)))
  (should-not (eq (last consult-ghostel-project-source-hidden)
                  (last consult-ghostel-project-source))))

(ert-deftest consult-ghostel-test-annotate-title ()
  "Source `:annotate' returns the terminal title for a buffer object.
`consult--multi' passes the pair's buffer object, not the candidate name."
  (let ((buf (consult-ghostel-test--fake-buffer " *consult-ghostel-ann*")))
    (unwind-protect
        (let ((fun (plist-get consult-ghostel-source :annotate)))
          (should-not (funcall fun buf))
          (with-current-buffer buf
            (setq ghostel--title "make -j8"))
          (should (equal (funcall fun buf) "  make -j8")))
      (kill-buffer buf))))

(ert-deftest consult-ghostel-test-marginalia-annotate ()
  "The marginalia wrapper prepends the title to marginalia's annotation."
  (let ((buf (consult-ghostel-test--fake-buffer " *consult-ghostel-marg*")))
    (unwind-protect
        (cl-letf (((symbol-function 'marginalia-annotate-buffer)
                   (lambda (_) " orig")))
          (should (equal (consult-ghostel-marginalia-annotate buf) " orig"))
          (with-current-buffer buf
            (setq ghostel--title "make -j8"))
          (should (equal (consult-ghostel-marginalia-annotate buf)
                         "  make -j8 orig")))
      (kill-buffer buf))))

(ert-deftest consult-ghostel-test-marginalia-registered ()
  "Loading with marginalia present registers the wrapper for both categories."
  (skip-unless (featurep 'marginalia))
  (dolist (category '(buffer project-buffer))
    (should (memq #'consult-ghostel-marginalia-annotate
                  (alist-get category marginalia-annotators)))))

(ert-deftest consult-ghostel-test-bookmark-narrow-registered ()
  "Loading adds a Ghostel group for ghostel's bookmark handler."
  (should (member '(?g "Ghostel" ghostel-bookmark-handler)
                  consult-bookmark-narrow)))

(ert-deftest consult-ghostel-test-hidden-sources-registered ()
  "Loading registers the hidden sources in the global consult lists."
  (should (memq 'consult-ghostel-source-hidden consult-buffer-sources))
  (should (memq 'consult-ghostel-project-source-hidden
                consult-project-buffer-sources)))

(ert-deftest consult-ghostel-test-source-items ()
  "`consult-ghostel-source' :items returns (name . buffer) pairs."
  (let ((a (consult-ghostel-test--fake-buffer "*consult-ghostel-a*"))
        (b (consult-ghostel-test--fake-buffer "*consult-ghostel-b*")))
    (unwind-protect
        (let* ((items (funcall (plist-get consult-ghostel-source :items)))
               (bufs (mapcar #'cdr items)))
          (should (memq a bufs))
          (should (memq b bufs))
          (should (equal (car (rassq a items)) (buffer-name a))))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest consult-ghostel-test-pairs-current-last ()
  "`consult-ghostel--pairs' preserves the set and puts current buffer last."
  (let ((a (generate-new-buffer "*consult-ghostel-arrange-a*"))
        (b (generate-new-buffer "*consult-ghostel-arrange-b*")))
    (unwind-protect
        (with-current-buffer a
          (let ((ordered (mapcar #'cdr (consult-ghostel--pairs (list a b)))))
            ;; Same set, no dupes/drops.
            (should (equal (sort (mapcar #'buffer-name ordered) #'string<)
                           (sort (list (buffer-name a) (buffer-name b))
                                 #'string<)))
            ;; Current buffer is last (you rarely switch to where you are).
            (should (eq (car (last ordered)) a))))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest consult-ghostel-test-new-empty-string ()
  "`:new' forwards a blank (empty-submission) name to `ghostel-create' verbatim."
  (let (created)
    (cl-letf (((symbol-function 'ghostel-create)
               (lambda (name &rest _) (setq created name) (current-buffer))))
      (funcall (plist-get consult-ghostel-source :new) "")
      (should (equal created "")))))

(ert-deftest consult-ghostel-test-project-items-need-project-el ()
  "The project source yields nothing when project.el finds no project.
`ghostel-project-buffer-list' would otherwise prompt for one during
candidate collection (e.g. under a projectile-only root)."
  (cl-letf (((symbol-function 'consult--project-root)
             (lambda (&optional _) "/consult-ghostel-nonexistent/"))
            ((symbol-function 'project-current)
             (lambda (&rest _) nil)))
    (should-not
     (funcall (plist-get consult-ghostel-project-source :items)))))

(ert-deftest consult-ghostel-test-project-source-no-project ()
  "Project source is disabled and yields no items (no error) outside a project."
  (require 'project)
  (let ((project-find-functions nil))
    (should-not (funcall (plist-get consult-ghostel-project-source :enabled)))
    (should-not (funcall (plist-get consult-ghostel-project-source :items)))))

(ert-deftest consult-ghostel-test-project-command-no-project-errors ()
  "`consult-ghostel-project' refuses cleanly outside a project.
Without the guard, `consult--multi' with zero enabled sources opens an
empty picker and crashes on submit."
  (require 'project)
  (let ((project-find-functions nil)
        (default-directory temporary-file-directory))
    (should-error (consult-ghostel-project) :type 'user-error)))

(ert-deftest consult-ghostel-test-prefix-delegates-to-ghostel ()
  "A prefix argument bypasses the picker and calls `ghostel' with it."
  (let (called)
    (cl-letf (((symbol-function 'ghostel)
               (lambda (&optional arg) (setq called arg)))
              ((symbol-function 'consult--multi)
               (lambda (&rest _) (error "Picker entered"))))
      (consult-ghostel '(4)))
    (should (equal called '(4)))))

(ert-deftest consult-ghostel-test-project-prefix-delegates ()
  "A prefix argument calls `ghostel-project', skipping the project guard.
`ghostel-project' prompts for a project itself when there is none."
  (require 'project)
  (let ((project-find-functions nil)
        (default-directory temporary-file-directory)
        called)
    (cl-letf (((symbol-function 'ghostel-project)
               (lambda (&optional arg) (setq called arg)))
              ((symbol-function 'consult--multi)
               (lambda (&rest _) (error "Picker entered"))))
      (consult-ghostel-project 3))
    (should (equal called 3))))

(ert-deftest consult-ghostel-test-new-source-actions ()
  "The \"New\" sources create like a prefixed `ghostel'/`ghostel-project'."
  (let (calls)
    (cl-letf (((symbol-function 'ghostel)
               (lambda (&optional arg) (push (cons 'ghostel arg) calls)))
              ((symbol-function 'ghostel-project)
               (lambda (&optional arg) (push (cons 'ghostel-project arg) calls))))
      (funcall (plist-get consult-ghostel-source-new :action) "x")
      (funcall (plist-get consult-ghostel-project-source-new :action) "x"))
    (should (equal calls '((ghostel-project . t) (ghostel . t))))))

(ert-deftest consult-ghostel-test-pickers-include-new-source ()
  "Both pickers pass their \"New\" source to `consult--multi'."
  (let (got)
    (cl-letf (((symbol-function 'consult--multi)
               (lambda (sources &rest _) (setq got sources) nil)))
      (consult-ghostel)
      (should (memq 'consult-ghostel-source-new got))
      (cl-letf (((symbol-function 'consult--project-root)
                 (lambda (&optional _) "/tmp/")))
        (consult-ghostel-project))
      (should (memq 'consult-ghostel-project-source-new got)))))

(ert-deftest consult-ghostel-test-project-new-identity ()
  "Project create-on-miss allocates in `ghostel-project's slot family.
The identity carries no `name' key, so `ghostel-project' finds and
reuses the buffer; the submitted name only names the buffer."
  (let (spawned)
    (cl-letf (((symbol-function 'ghostel-create)
               (lambda (name _display &optional identity)
                 (setq spawned (cons name identity)) (current-buffer)))
              ((symbol-function 'project-current)
               (lambda (&rest _) '(transient . "/tmp/cg-proj/")))
              ((symbol-function 'project-root)
               (lambda (_) "/tmp/cg-proj/")))
      (funcall (plist-get consult-ghostel-project-source :new) "*pbuild*")
      (should (equal (car spawned) "*pbuild*"))
      (should (equal (cdr spawned)
                     `((kind . term)
                       (project-root . ,(ghostel--normalize-root
                                         "/tmp/cg-proj/"))
                       (instance . 1)))))))

(ert-deftest consult-ghostel-test-project-new-shares-slot-family ()
  "Create-on-miss numbers instances in `ghostel-project's own sequence.
An empty submission gets `ghostel-project's default buffer name with
the instance suffix."
  (let ((existing (generate-new-buffer " *cg-proj-existing*"))
        spawned)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel-create)
                   (lambda (name _display &optional identity)
                     (setq spawned (cons name identity)) (current-buffer)))
                  ((symbol-function 'ghostel--load-module) #'ignore)
                  ((symbol-function 'project-current)
                   (lambda (&rest _) '(transient . "/tmp/cg-proj/")))
                  ((symbol-function 'project-root)
                   (lambda (_) "/tmp/cg-proj/"))
                  ((symbol-function 'ghostel--project-buffer-name)
                   (lambda (_) "*P*")))
          (with-current-buffer existing
            (setq-local ghostel-identity
                        `((kind . term)
                          (project-root . ,(ghostel--normalize-root
                                            "/tmp/cg-proj/"))
                          (instance . 1))))
          (funcall (plist-get consult-ghostel-project-source :new) "")
          (should (equal (car spawned) "*P*<2>"))
          (should (= (alist-get 'instance (cdr spawned)) 2)))
      (kill-buffer existing))))

;;; Shell command history

(ert-deftest consult-ghostel-test-history-input-region ()
  "The pending input spans prompt end to cursor on the cursor's row."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t) "echo fo")
    (setq-local ghostel--cursor-char-pos (point-max))
    (should (equal (consult-ghostel--input-region)
                   (cons 3 (point-max))))))

(ert-deftest consult-ghostel-test-history-input-region-wrapped ()
  "A cursor on a continuation row still finds the prompt rows above."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t) "echo wraps")
    (insert (propertize "\n" 'ghostel-wrap t) "over")
    (setq-local ghostel--cursor-char-pos (point-max))
    (should (equal (consult-ghostel--input-region)
                   (cons 3 (point-max))))))

(ert-deftest consult-ghostel-test-history-replaces-input ()
  "Selecting aborts the pending line with Ctrl-C and pastes the entry.
Wrap newlines inside the pending input are buffer artifacts and stay
out of the `:initial' text."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t) "echo wraps")
    (insert (propertize "\n" 'ghostel-wrap t) "over")
    (setq-local ghostel--cursor-char-pos (point-max))
    (let (keys pasted read-args)
      (cl-letf (((symbol-function 'ghostel-shell-history)
                 (lambda () '("make -j8" "ls")))
                ((symbol-function 'ghostel-send-key)
                 (lambda (key &optional mods) (push (cons key mods) keys)))
                ((symbol-function 'ghostel-paste-string)
                 (lambda (s) (setq pasted s)))
                ((symbol-function 'consult--read)
                 (lambda (cands &rest opts)
                   (setq read-args (cons cands opts))
                   "make -j8")))
        (consult-ghostel-history))
      (should (equal (car read-args) '("make -j8" "ls")))
      (should (equal (plist-get (cdr read-args) :initial) "echo wrapsover"))
      (should (equal keys '(("c" . "ctrl"))))
      (should (equal pasted "make -j8")))))

(ert-deftest consult-ghostel-test-history-blank-line-skips-abort ()
  "A blank pending line is pasted into directly, without the Ctrl-C."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t))
    (setq-local ghostel--cursor-char-pos (point-max))
    (let (keys pasted)
      (cl-letf (((symbol-function 'ghostel-shell-history)
                 (lambda () '("ls")))
                ((symbol-function 'ghostel-send-key)
                 (lambda (key &optional mods) (push (cons key mods) keys)))
                ((symbol-function 'ghostel-paste-string)
                 (lambda (s) (setq pasted s)))
                ((symbol-function 'consult--read)
                 (lambda (&rest _) "ls")))
        (consult-ghostel-history))
      (should-not keys)
      (should (equal pasted "ls")))))

(ert-deftest consult-ghostel-test-history-prefix-completes-in-place ()
  "A pending line that prefixes the entry gets only the rest pasted."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t) "bre")
    (setq-local ghostel--cursor-char-pos (point-max))
    (let (keys pasted)
      (cl-letf (((symbol-function 'ghostel-shell-history)
                 (lambda () '("brew update")))
                ((symbol-function 'ghostel-send-key)
                 (lambda (key &optional mods) (push (cons key mods) keys)))
                ((symbol-function 'ghostel-paste-string)
                 (lambda (s) (setq pasted s)))
                ((symbol-function 'consult--read)
                 (lambda (&rest _) "brew update")))
        (consult-ghostel-history))
      (should-not keys)
      (should (equal pasted "w update")))))

(ert-deftest consult-ghostel-test-history-wrapped-prefix-completes ()
  "Prefix comparison joins the pending line across soft wraps."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t) "echo wraps")
    (insert (propertize "\n" 'ghostel-wrap t) "over")
    (setq-local ghostel--cursor-char-pos (point-max))
    (let (keys pasted)
      (cl-letf (((symbol-function 'ghostel-shell-history)
                 (lambda () '("echo wrapsoverflow")))
                ((symbol-function 'ghostel-send-key)
                 (lambda (key &optional mods) (push (cons key mods) keys)))
                ((symbol-function 'ghostel-paste-string)
                 (lambda (s) (setq pasted s)))
                ((symbol-function 'consult--read)
                 (lambda (&rest _) "echo wrapsoverflow")))
        (consult-ghostel-history))
      (should-not keys)
      (should (equal pasted "flow")))))

(ert-deftest consult-ghostel-test-history-exact-entry-sends-nothing ()
  "An entry equal to the pending line sends no bytes at all."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t) "ls")
    (setq-local ghostel--cursor-char-pos (point-max))
    (let (keys pasted)
      (cl-letf (((symbol-function 'ghostel-shell-history)
                 (lambda () '("ls")))
                ((symbol-function 'ghostel-send-key)
                 (lambda (key &optional mods) (push (cons key mods) keys)))
                ((symbol-function 'ghostel-paste-string)
                 (lambda (s) (setq pasted s)))
                ((symbol-function 'consult--read)
                 (lambda (&rest _) "ls")))
        (consult-ghostel-history))
      (should-not keys)
      (should-not pasted))))

(ert-deftest consult-ghostel-test-history-input-after-cursor-aborts ()
  "Input beyond the cursor still counts as a pending line to abort."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t) "echo")
    (setq-local ghostel--cursor-char-pos 3)
    (let (keys)
      (cl-letf (((symbol-function 'ghostel-shell-history)
                 (lambda () '("ls")))
                ((symbol-function 'ghostel-send-key)
                 (lambda (key &optional mods) (push (cons key mods) keys)))
                ((symbol-function 'ghostel-paste-string) #'ignore)
                ((symbol-function 'consult--read)
                 (lambda (&rest _) "ls")))
        (consult-ghostel-history))
      (should (equal keys '(("c" . "ctrl")))))))

(ert-deftest consult-ghostel-test-history-refuses-while-running ()
  "The command refuses to run while a shell command is running.
Its Ctrl-C line abort would interrupt the command."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--command-running t)
    (should-error (consult-ghostel-history) :type 'user-error)))

(ert-deftest consult-ghostel-test-history-line-mode-inserts ()
  "In line mode the entry replaces the editable input region in-buffer."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'line)
    (insert "$ old")
    (setq-local ghostel--line-input-start (copy-marker 3))
    (setq-local ghostel--line-input-end (copy-marker (point-max) t))
    (cl-letf (((symbol-function 'ghostel-shell-history)
               (lambda () '("new one")))
              ((symbol-function 'consult--read)
               (lambda (&rest _) "new one")))
      (consult-ghostel-history))
    (should (equal (buffer-string) "$ new one"))
    (should (= (marker-position ghostel--line-input-end) (point-max)))))

(ert-deftest consult-ghostel-test-history-multiline-pastes ()
  "A multi-line entry arrives intact through the paste.
Sent raw, its embedded newlines would act as Enter."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (setq-local ghostel--input-mode 'semi-char)
    (insert (propertize "$ " 'ghostel-prompt t))
    (setq-local ghostel--cursor-char-pos (point-max))
    (let ((entry "for f in *\necho $f\nend")
          pasted)
      (cl-letf (((symbol-function 'ghostel-shell-history)
                 (lambda () (list entry)))
                ((symbol-function 'ghostel-send-key) #'ignore)
                ((symbol-function 'ghostel-paste-string)
                 (lambda (s) (setq pasted s)))
                ((symbol-function 'consult--read)
                 (lambda (&rest _) entry)))
        (consult-ghostel-history))
      (should (equal pasted entry)))))

(ert-deftest consult-ghostel-test-history-requires-ghostel-buffer ()
  "Outside a ghostel buffer the command refuses to run."
  (with-temp-buffer
    (should-error (consult-ghostel-history) :type 'user-error)))

;;; consult-line over logical lines

(ert-deftest consult-ghostel-test-line-candidates-advice-installed ()
  "The logical-line candidate builder advises `consult--line-candidates'."
  (should (advice-member-p #'consult-ghostel--line-candidates
                           'consult--line-candidates))
  (should (advice-member-p #'consult-ghostel--line-point-placement
                           'consult--line-point-placement)))

(defun consult-ghostel-test--insert-rows (rows)
  "Insert ROWS, a list of (STRING . WRAPPED-P) conses.
A non-nil WRAPPED-P marks the row's newline as a soft wrap joining
it to the next row."
  (dolist (row rows)
    (insert (car row))
    (insert (if (cdr row) (propertize "\n" 'ghostel-wrap t) "\n"))))

(defun consult-ghostel-test--strip-tofu (cand)
  "Return CAND's text without properties and trailing tofu chars.
`consult--location-candidate' appends an invisible disambiguation
char to every candidate string."
  (let ((s (substring-no-properties cand)))
    (while (and (> (length s) 0)
                (>= (aref s (1- (length s))) consult--tofu-char))
      (setq s (substring s 0 -1)))
    s))

(defun consult-ghostel-test--candidates (rows curr-line)
  "Return candidate strings for ROWS with point context CURR-LINE."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    (consult-ghostel-test--insert-rows rows)
    (mapcar #'consult-ghostel-test--strip-tofu
            (consult-ghostel--line-candidates
             (lambda (&rest _) (error "Fallback must not run")) nil
             curr-line))))

(ert-deftest consult-ghostel-test-line-candidates-join-wraps ()
  "Rows joined by wrap newlines become one candidate, spliced."
  (should (equal (consult-ghostel-test--candidates
                  '(("alpha" . t) ("beta" . nil) ("gamma" . nil)) 1)
                 '("alphabeta" "gamma"))))

(ert-deftest consult-ghostel-test-line-candidates-default-on-continuation ()
  "Point on a continuation row defaults to the containing logical line.
The default candidate is returned first."
  (should (equal (car (consult-ghostel-test--candidates
                       '(("one" . nil) ("two" . t) ("2cont" . nil)
                         ("three" . nil))
                       3))                ; row 3 = continuation of "two2cont"
                 "two2cont")))

(ert-deftest consult-ghostel-test-line-candidates-row-cap ()
  "Wrap joining is bounded like core's, by `ghostel--soft-wrap-row-limit'.
The cap is the number of wrap newlines crossed, so a capped candidate
holds limit + 1 rows - the same logical line the link scanner sees."
  (let* ((rows (append (make-list 60 '("x" . t)) '(("end" . nil))))
         (strs (consult-ghostel-test--candidates rows 1))
         (cap (1+ ghostel--soft-wrap-row-limit)))
    (should (equal (mapcar #'length strs)
                   (list cap (+ (- 60 cap) 3))))))

(ert-deftest consult-ghostel-test-line-counter-empty-continuation-row ()
  "An empty continuation row still counts toward the line numbers.
Otherwise the counter drifts and the default candidate lands one
logical line too far."
  (should (equal (car (consult-ghostel-test--candidates
                       '(("aaaa" . t) ("" . nil) ("bbb" . nil)
                         ("ccc" . nil))
                       3))               ; row 3 = "bbb"
                 "bbb")))

(ert-deftest consult-ghostel-test-wrap-corrected-dest-clamped ()
  "A position with no wrap chunks (buffer shrank under the candidate)
falls back to the position itself instead of returning nil."
  (with-temp-buffer
    (insert "text")
    (should (= (consult-ghostel--wrap-corrected-dest (point-max) 2)
               (point-max)))))

(ert-deftest consult-ghostel-test-point-placement-gates-on-joined ()
  "Candidates without the wrap-joined property fall through to ORIG.
`consult-line-multi' candidates are per-row even in ghostel buffers."
  (with-temp-buffer
    (insert "row\n")
    (let ((cand (consult--location-candidate
                 "row" (cons (current-buffer) 1) 1 1))
          orig-args)
      (consult-ghostel--line-point-placement
       (lambda (&rest args) (setq orig-args args) nil)
       cand (list cand) cand)
      (should orig-args))))

(ert-deftest consult-ghostel-test-wrap-corrected-dest ()
  "Buffer destinations skip the wrap newlines spliced from candidates."
  (with-temp-buffer
    (setq major-mode 'ghostel-mode)
    ;; Buffer: a(1) b(2) c(3) d(4) wrap-\n(5) e(6) f(7) g(8) h(9) \n(10)
    ;; Candidate string: "abcdefgh".
    (consult-ghostel-test--insert-rows '(("abcd" . t) ("efgh" . nil)))
    ;; String offset 6 is ?g, buffer position 8.
    (should (= (consult-ghostel--wrap-corrected-dest 1 6) 8))
    ;; String offset 4 is ?e just past the wrap; the newline is skipped.
    (should (= (consult-ghostel--wrap-corrected-dest 1 4) 6))
    ;; Offset 0 stays put.
    (should (= (consult-ghostel--wrap-corrected-dest 1 0) 1))))

(defun consult-ghostel-test-run ()
  "Run all consult-ghostel tests."
  (ert-run-tests-batch-and-exit "^consult-ghostel-test-"))

;;; consult-ghostel-test.el ends here
