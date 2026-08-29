;;; ghostel-dnd-test.el --- Tests for ghostel: drag-and-drop -*- lexical-binding: t; -*-

;;; Commentary:

;; File drops routed through `dnd-protocol-alist' (the X11/pgtk path):
;; buffer-local registration, shell quoting, multi-file drops, refusal
;; of non-local URIs, and the dead-terminal fallback.  The dnd layer is
;; driven directly, so these run without a window system or a live PTY.
;;
;; `ghostel--drop' (the NS/w32 keymap path) is driven with synthetic
;; events; a native test checks the bytes reaching the child process.

;;; Code:

(require 'ghostel-test-helpers)
(require 'dnd)
(require 'url-util)

(defun ghostel-dnd-test--dispatch (urls)
  "Dispatch URLS through the dnd layer as the X11/pgtk port would.
Return everything pasted through `ghostel--paste-text',
concatenated."
  (let ((sent ""))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (setq sent (concat sent text))))
              ((symbol-function 'ghostel--on-user-input) #'ignore))
      (if (fboundp 'dnd-handle-multiple-urls)
          (dnd-handle-multiple-urls (selected-window) urls 'private)
        (dolist (url urls)
          (dnd-handle-one-url (selected-window) 'private url))))
    sent))

(defmacro ghostel-dnd-test--with-mode-buffer (&rest body)
  "Run BODY in a `ghostel-mode' buffer shown in the selected window.
The buffer must be displayed so its buffer-local
`dnd-protocol-alist' is in effect when the dnd layer re-selects
the drop window.  A live placeholder process is installed as
`ghostel--process'."
  (declare (indent 0) (debug t))
  `(let ((buf (generate-new-buffer " *ghostel-dnd-test*")))
     (unwind-protect
         (progn
           (with-current-buffer buf
             (ghostel-mode)
             (setq ghostel--process
                   (start-process "ghostel-dnd-test" nil "sleep" "30")))
           (set-window-buffer (selected-window) buf)
           (with-current-buffer buf ,@body))
       (with-current-buffer buf
         (when (process-live-p ghostel--process)
           (delete-process ghostel--process)))
       (kill-buffer buf))))

(ert-deftest ghostel-test-dnd-protocol-alist-registered ()
  "`ghostel-mode' registers a buffer-local file-drop handler.
The first `dnd-protocol-alist' entry matching a file URL must be
ours, and the global value must stay untouched."
  (with-temp-buffer
    (ghostel-mode)
    (should (local-variable-p 'dnd-protocol-alist))
    (should (eq (cl-loop for (re . fn) in dnd-protocol-alist
                         when (string-match re "file:///tmp/x") return fn)
                'ghostel--dnd-handle-file))
    (should-not (rassq 'ghostel--dnd-handle-file
                       (default-value 'dnd-protocol-alist)))))

(ert-deftest ghostel-test-dnd-file-drop-sends-path ()
  "A file URL dispatched through the dnd layer pastes the path."
  (ghostel-dnd-test--with-mode-buffer
    (let* ((file (make-temp-file "ghostel-dnd"))
           (sent (unwind-protect
                     (ghostel-dnd-test--dispatch (list (concat "file://" file)))
                   (delete-file file))))
      (should (equal sent (concat file " "))))))

(ert-deftest ghostel-test-dnd-file-drop-shell-quotes ()
  "A dropped path containing spaces and quotes arrives shell-quoted."
  (ghostel-dnd-test--with-mode-buffer
    (let* ((dir (make-temp-file "ghostel-dnd" t))
           (file (expand-file-name "it's a file" dir))
           (sent (unwind-protect
                     (progn
                       (write-region "" nil file nil 'silent)
                       (ghostel-dnd-test--dispatch
                        (list (concat "file://"
                                      (url-hexify-string
                                       file url-path-allowed-chars)))))
                   (delete-directory dir t))))
      (should (equal sent (concat (shell-quote-argument file) " "))))))

(ert-deftest ghostel-test-dnd-multi-file-drop-space-separated ()
  "Two dropped URLs produce both paths, space-separated."
  (ghostel-dnd-test--with-mode-buffer
    (let* ((a (make-temp-file "ghostel-dnd-a"))
           (b (make-temp-file "ghostel-dnd-b"))
           (sent (unwind-protect
                     (ghostel-dnd-test--dispatch
                      (list (concat "file://" a) (concat "file://" b)))
                   (delete-file a)
                   (delete-file b))))
      (should (equal sent (concat a " " b " "))))))

(ert-deftest ghostel-test-dnd-hostname-qualified-uri-accepted ()
  "A file://<local hostname>/path URI resolves and pastes the path."
  (ghostel-dnd-test--with-mode-buffer
    (let* ((file (make-temp-file "ghostel-dnd"))
           (sent (unwind-protect
                     (ghostel-dnd-test--dispatch
                      (list (concat "file://" (downcase (system-name)) file)))
                   (delete-file file))))
      (should (equal sent (concat file " "))))))

(ert-deftest ghostel-test-dnd-nonexistent-path-sent ()
  "A local URI naming a nonexistent file still pastes the path."
  (ghostel-dnd-test--with-mode-buffer
    (let ((file (make-temp-name "/nonexistent-")))
      (should (equal (ghostel-dnd-test--dispatch (list (concat "file://" file)))
                     (concat file " "))))))

(ert-deftest ghostel-test-dnd-non-local-uri-refused ()
  "A URI on a foreign host sends nothing and opens nothing.
The handler still consumes the drop (returns `private') so the dnd
layer runs no default handler such as `find-file'."
  (ghostel-dnd-test--with-mode-buffer
    (let ((opened nil))
      (cl-letf (((symbol-function 'dnd-open-local-file)
                 (lambda (&rest args) (setq opened args))))
        (should (equal (ghostel-dnd-test--dispatch
                        '("file://otherhost/no/such/file"))
                       ""))
        (should-not opened)))))

(ert-deftest ghostel-test-dnd-dead-terminal-opens-file ()
  "A drop into a dead terminal opens the file instead of pasting."
  (ghostel-dnd-test--with-mode-buffer
    (delete-process ghostel--process)
    (should-not (process-live-p ghostel--process))
    (let* ((file (make-temp-file "ghostel-dnd"))
           (opened nil))
      (unwind-protect
          (cl-letf (((symbol-function 'dnd-open-local-file)
                     (lambda (uri _action) (setq opened uri) 'private)))
            (should (equal (ghostel-dnd-test--dispatch
                            (list (concat "file://" file)))
                           ""))
            (should (equal opened (concat "file://" file))))
        (delete-file file)))))

;;; `ghostel--drop' — the NS/w32 keymap path

(defun ghostel-test--drop-event (type &rest objects)
  "Build a synthetic NS-shaped drag-n-drop event with TYPE and OBJECTS:
\(drag-n-drop POSN (TYPE OPERATIONS . OBJECTS))."
  (list 'drag-n-drop nil
        (cons type (cons '(ns-drag-operation-copy) objects))))

(ert-deftest ghostel-test-drop-file-pastes-quoted-joined-paths ()
  "A file drop pastes shell-quoted paths, space-joined, space-terminated."
  (let ((pasted nil)
        (event (ghostel-test--drop-event 'file "/tmp/a b.png" "/tmp/c d.png")))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel--ensure-ghostel-buffer) #'ignore)
              ((symbol-function 'ghostel--on-user-input) #'ignore))
      (ghostel--drop event)
      (should (equal pasted
                     (list (concat (shell-quote-argument "/tmp/a b.png") " "
                                   (shell-quote-argument "/tmp/c d.png") " ")))))))

(ert-deftest ghostel-test-drop-text-pastes-newline-joined-strings ()
  "A text drop (TYPE not `file') pastes the strings joined with newlines."
  (let ((pasted nil)
        (event (ghostel-test--drop-event 'string "hello" "world")))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (text) (push text pasted)))
              ((symbol-function 'ghostel--ensure-ghostel-buffer) #'ignore)
              ((symbol-function 'ghostel--on-user-input) #'ignore))
      (ghostel--drop event)
      (should (equal pasted '("hello\nworld"))))))

(ert-deftest ghostel-test-drop-ignores-movement-and-nil-events ()
  "A DND movement event (`lambda' payload) or a nil-data event is a no-op."
  (let ((calls 0))
    (cl-letf (((symbol-function 'ghostel--paste-text)
               (lambda (_text) (setq calls (1+ calls))))
              ((symbol-function 'ghostel--on-user-input) #'ignore))
      (ghostel--drop (list 'drag-n-drop nil 'lambda))
      (ghostel--drop (list 'drag-n-drop nil nil))
      (should (= calls 0)))))

(ert-deftest ghostel-test-drop-targets-posn-window-buffer ()
  "The paste runs in the buffer of the event's window, not the selected one."
  (let ((target (generate-new-buffer " *ghostel-dnd-target*"))
        (pasted-in nil))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) target)
          (cl-letf (((symbol-function 'ghostel--paste-text)
                     (lambda (_text) (setq pasted-in (current-buffer))))
                    ((symbol-function 'ghostel--ensure-ghostel-buffer) #'ignore)
                    ((symbol-function 'ghostel--on-user-input) #'ignore))
            (with-temp-buffer
              (ghostel--drop
               (list 'drag-n-drop (list (selected-window))
                     (cons 'file (cons '(ns-drag-operation-copy)
                                       (list "/tmp/x.png"))))))
            (should (eq pasted-in target))))
      (kill-buffer target))))

(ert-deftest ghostel-test-drop-bound-in-keymaps ()
  "`<drag-n-drop>' is bound to `ghostel--drop' in both terminal-input maps."
  (should (eq (lookup-key ghostel-char-mode-map (kbd "<drag-n-drop>"))
              #'ghostel--drop))
  (should (eq (lookup-key ghostel-mode-map (kbd "<drag-n-drop>"))
              #'ghostel--drop)))

(ert-deftest ghostel-test-drop-bound-on-window-decorations ()
  "Decoration-area drops resolve to `ghostel--drop' via the emulation map."
  (dolist (area '(mode-line header-line left-fringe right-fringe))
    (should (eq (lookup-key ghostel--dnd-area-map
                            (vector area 'drag-n-drop))
                #'ghostel--drop)))
  (should (eq (cdr (assq 'ghostel--term ghostel--emulation-alist))
              ghostel--dnd-area-map))
  (should (memq 'ghostel--emulation-alist emulation-mode-map-alists)))

(ert-deftest ghostel-test-drop-file-bracketed-paste ()
  "A dropped file is wrapped in bracketed-paste markers when mode 2004 is on."
  :tags '(native posix)
  (let ((python (executable-find "python3")))
    (unless python (ert-skip "python3 not available"))
    (ghostel-test--with-pty-matrix backend
      (let* ((quoted (concat (shell-quote-argument "/tmp/a b.png") " "))
             (payload (concat "\e[200~" quoted "\e[201~")))
        (ghostel-test--with-exec-buffer
            (buf proc python
                 (ghostel-test--pty-byte-recorder-args (length payload)))
          (ghostel-test--wait-for-text "GHOSTEL_RECORDER_READY" proc 5)
          (ghostel--write-vt ghostel--term "\e[?2004h")
          (ghostel--drop (ghostel-test--drop-event 'file "/tmp/a b.png"))
          (should (equal (ghostel-test--hex-encode-string payload)
                         (ghostel-test--wait-for-marker-payload
                          "GHOSTEL_INPUT_HEX:"
                          (lambda (hex) (= (length hex) (* 2 (length payload))))
                          proc 5))))))))

(provide 'ghostel-dnd-test)
;;; ghostel-dnd-test.el ends here
