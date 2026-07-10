;;; ghostel-module-test.el --- Tests for ghostel: module -*- lexical-binding: t; -*-

;;; Commentary:

;; Native module download, install, sidecar versioning, platform tag.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-module-download-url-uses-requested-version ()
  "Requested download versions are decoupled from the package version."
  (let ((ghostel-github-release-url "https://example.invalid/releases"))
    (cl-letf (((symbol-function 'ghostel--module-asset-name)
               (lambda () "ghostel-module-x86_64-linux.so")))
      (should (equal "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-linux.so"
                     (ghostel--module-download-url "0.7.1"))))))

(ert-deftest ghostel-test-module-download-url-uses-latest-release ()
  "A nil download version uses the latest release asset."
  (let ((ghostel-github-release-url "https://example.invalid/releases"))
    (cl-letf (((symbol-function 'ghostel--module-asset-name)
               (lambda () "ghostel-module-x86_64-linux.so")))
      (should (equal "https://example.invalid/releases/latest/download/ghostel-module-x86_64-linux.so"
                     (ghostel--module-download-url nil))))))

(ert-deftest ghostel-test-install-support-assets-downloads-windows-assets ()
  "Support asset installation downloads the Windows asset mapping."
  (let* ((ghostel-github-release-url "https://example.invalid/releases")
         (dir (make-temp-file "ghostel-support-" t))
         (downloads nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--windows-support-assets)
                   (lambda ()
                     '(("support-a.dll" . "support-a.dll")
                       ("support-b.exe" . "x64/support-b.exe"))))
                  ((symbol-function 'ghostel--download-file)
                   (lambda (url dest)
                     (push (list url dest) downloads)
                     url))
                  ((symbol-function 'message) (lambda (&rest _))))
          (ghostel--install-support-assets dir "0.9.0")
          (should (equal
                   (list
                    (list "https://example.invalid/releases/download/v0.9.0/support-b.exe"
                          (expand-file-name "x64/support-b.exe" dir))
                    (list "https://example.invalid/releases/download/v0.9.0/support-a.dll"
                          (expand-file-name "support-a.dll" dir)))
                   downloads)))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-download-module-defaults-to-minimum-version ()
  "Automatic downloads pin to the minimum supported native module version."
  (let* ((ghostel--minimum-module-version "0.7.1")
         (captured-version :unset)
         (download-dest nil)
         (dir (make-temp-file "ghostel-dl-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--module-download-url)
                   (lambda (&optional version)
                     (setq captured-version version)
                     "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-linux.so"))
                  ((symbol-function 'ghostel--download-file)
                   (lambda (_url dest)
                     (setq download-dest dest)
                     t))
                  ((symbol-function 'message)
                   (lambda (&rest _))))
          (should (ghostel--download-module dir))
          (should (equal "0.7.1" captured-version))
          (should (equal (downcase (expand-file-name
                                    (concat "ghostel-module" module-file-suffix)
                                    dir))
                         (downcase download-dest))))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-download-module-prefix-uses-requested-version ()
  "Prefix downloads pass the requested release version through unchanged."
  (let ((ghostel--minimum-module-version "0.7.1")
        (captured-version :unset)
        (captured-latest nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "C:/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--read-module-download-version)
                 (lambda () "0.8.0"))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional version latest-release)
                   (setq captured-version version
                         captured-latest latest-release)
                   ;; Bail before `module-load' — its mock can't be
                   ;; intercepted from native-compiled callers in Emacs 31.
                   (throw 'ghostel-test-bail nil)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (catch 'ghostel-test-bail
          (ghostel-download-module '(4)))
        (should (equal "0.8.0" captured-version))
        (should-not captured-latest)))))

(ert-deftest ghostel-test-download-module-prefix-empty-uses-latest ()
  "Prefix download treats blank input as a request for the latest release."
  (let ((captured-version :unset)
        (captured-latest nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "C:/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--read-module-download-version)
                 (lambda () nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional version latest-release)
                   (setq captured-version version
                         captured-latest latest-release)
                   ;; Bail before `module-load' — its mock can't be
                   ;; intercepted from native-compiled callers in Emacs 31.
                   (throw 'ghostel-test-bail nil)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (catch 'ghostel-test-bail
          (ghostel-download-module '(4)))
        (should (null captured-version))
        (should captured-latest)))))

(ert-deftest ghostel-test-download-file-is-atomic ()
  "`ghostel--download-file' writes via a temp sibling and renames into place.
The destination inode must change so any Emacs that has the previous
file mmap'd keeps a valid mapping (issue #247)."
  (let* ((dir (make-temp-file "ghostel-dl-" t))
         (dest (expand-file-name "ghostel-module.so" dir)))
    (unwind-protect
        (progn
          (with-temp-file dest (insert "old-payload"))
          (set-file-modes dest #o644)
          (let ((old-inode (file-attribute-inode-number (file-attributes dest))))
            (cl-letf (((symbol-function 'url-retrieve-synchronously)
                       (lambda (&rest _)
                         (let ((buf (generate-new-buffer " *ghostel-fake-http*")))
                           (with-current-buffer buf
                             (set-buffer-multibyte nil)
                             (insert "HTTP/1.1 200 OK\r\n\r\nnew-payload"))
                           buf))))
              (should (ghostel--download-file "https://example.invalid/x" dest)))
            (should (equal "new-payload"
                           (with-temp-buffer
                             (set-buffer-multibyte nil)
                             (insert-file-contents-literally dest)
                             (buffer-string))))
            (let ((new-inode (file-attribute-inode-number (file-attributes dest))))
              (should-not (equal old-inode new-inode)))
            ;; No stale temp files left behind on success.
            (dolist (f (directory-files dir nil "\\." t))
              (should-not (string-match-p "\\.tmp\\." f)))))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-download-module-creates-missing-directory ()
  "`ghostel--download-module' creates DIR before writing the module."
  (let* ((parent (make-temp-file "ghostel-dl-parent-" t))
         (dir (expand-file-name "sub/dir/" parent))
         (asset "ghostel-module-x86_64-linux.so"))
    (unwind-protect
        (progn
          (should-not (file-exists-p dir))
          (cl-letf (((symbol-function 'ghostel--module-asset-name)
                     (lambda () asset))
                    ((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _)
                       (let ((buf (generate-new-buffer " *ghostel-fake-http*")))
                         (with-current-buffer buf
                           (set-buffer-multibyte nil)
                           (insert "HTTP/1.1 200 OK\r\n\r\npayload"))
                         buf))))
            (should (ghostel--download-module dir nil t)))
          (should (file-directory-p dir))
          (should (file-exists-p (expand-file-name
                                  (concat "ghostel-module" module-file-suffix)
                                  dir))))
      (when (file-exists-p parent)
        (delete-directory parent t)))))

(ert-deftest ghostel-test-download-file-cleans-up-on-failure ()
  "A failed HTTP response leaves no stale temp file behind."
  (let* ((dir (make-temp-file "ghostel-dl-" t))
         (dest (expand-file-name "ghostel-module.so" dir)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _)
                       (let ((buf (generate-new-buffer " *ghostel-fake-http*")))
                         (with-current-buffer buf
                           (set-buffer-multibyte nil)
                           (insert "HTTP/1.1 404 Not Found\r\n\r\nnope"))
                         buf))))
            (should-not (ghostel--download-file "https://example.invalid/x" dest)))
          (should-not (file-exists-p dest))
          (dolist (f (directory-files dir nil "\\." t))
            (should-not (string-match-p "\\.tmp\\." f))))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-module-directory-defaults-to-resource-root ()
  "When `ghostel-module-directory' is nil, the resource root is used."
  (let ((ghostel-module-directory nil))
    (cl-letf (((symbol-function 'ghostel--resource-root)
               (lambda () "/pkg/ghostel/")))
      (should (equal (downcase (file-name-as-directory
                                (expand-file-name "/pkg/ghostel/")))
                     (downcase (ghostel--module-directory)))))))

(ert-deftest ghostel-test-module-directory-honours-custom-value ()
  "When set, `ghostel-module-directory' takes precedence."
  (let ((ghostel-module-directory "~/custom/ghostel/"))
    (cl-letf (((symbol-function 'ghostel--resource-root)
               (lambda () "/pkg/ghostel/")))
      (should (equal (downcase (file-name-as-directory
                                (expand-file-name "~/custom/ghostel/")))
                     (downcase (ghostel--module-directory)))))))

(ert-deftest ghostel-test-module-build-dir-is-reset ()
  "The temporary build directory is reset before use."
  (let* ((dir (make-temp-file "ghostel-test-build-dir" t))
         (build-dir (expand-file-name ".ghostel-build/" dir))
         (stale (expand-file-name "stale" build-dir)))
    (unwind-protect
        (progn
          (make-directory build-dir t)
          (with-temp-file stale (insert "stale"))
          (should (equal (file-name-as-directory build-dir)
                         (ghostel--make-module-build-dir dir)))
          (should (file-directory-p build-dir))
          (should-not (file-exists-p stale)))
      (delete-directory dir t))))

(ert-deftest ghostel-test-download-module-targets-custom-directory ()
  "Interactive download writes into `ghostel-module-directory' when set."
  (let ((ghostel-module-directory "/custom/dir/")
        (captured-dir nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/pkg/ghostel/"))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'make-directory)
                 (lambda (&rest _)))
                ((symbol-function 'ghostel--read-module-download-version)
                 (lambda () nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (dir &optional _v _l)
                   (setq captured-dir dir)
                   (throw 'ghostel-test-bail nil)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (catch 'ghostel-test-bail
          (ghostel-download-module nil))
        (should (equal (downcase (file-name-as-directory
                                  (expand-file-name "/custom/dir/")))
                       (downcase captured-dir)))))))

(ert-deftest ghostel-test-load-module-looks-in-custom-directory ()
  "`ghostel--load-module' loads the module from `ghostel-module-directory'."
  (let* ((ghostel-module-directory "/custom/dir/")
         (loaded-path nil)
         (had-feat (featurep 'ghostel-module))
         (saved-new (and (fboundp 'ghostel--new)
                         (symbol-function 'ghostel--new))))
    (unwind-protect
        (progn
          (when had-feat
            (setq features (delq 'ghostel-module features)))
          (when saved-new
            (fmakunbound 'ghostel--new))
          (cl-letf (((symbol-function 'ghostel--resource-root)
                     (lambda () "/pkg/ghostel/"))
                    ((symbol-function 'file-exists-p)
                     (lambda (path)
                       (string-prefix-p (expand-file-name "/custom/dir/") path)))
                    ((symbol-function 'module-load)
                     (lambda (path) (setq loaded-path path)))
                    ((symbol-function 'ghostel--check-module-version)
                     (lambda (&rest _))))
            (ghostel--load-module)))
      (when saved-new
        (fset 'ghostel--new saved-new))
      (when had-feat
        (cl-pushnew 'ghostel-module features)))
    (should loaded-path)
    (should (string-prefix-p (expand-file-name "/custom/dir/")
                             loaded-path))))

(ert-deftest ghostel-test-compile-module-invokes-zig-build-with-prefix ()
  "Source compilation runs zig build in the resource root."
  (let ((default-directory nil)
        (messages nil)
        (warnings nil)
        (process-invocation nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "C:/ghostel/"))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) "C:/ghostel/.ghostel-build/"))
                ((symbol-function 'file-exists-p)
                 (lambda (_) t))
                ((symbol-function 'file-directory-p)
                 (lambda (_) nil))
                ((symbol-function 'rename-file)
                 (lambda (&rest _)))
                ((symbol-function 'delete-file)
                 (lambda (&rest _)))
                ((symbol-function 'make-directory)
                 (lambda (&rest _)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages)))
                ((symbol-function 'display-warning)
                 (lambda (&rest args)
                   (push args warnings)))
                ((symbol-function 'process-file)
                 (lambda (program infile buffer display &rest args)
                   (setq process-invocation
                         (list program infile buffer display args default-directory))
                   0)))
        (ghostel--compile-module "C:/ghostel/")
        (should (equal
                 '("zig" nil "*ghostel-build*" nil
                   ("build" "--prefix" "C:/ghostel/.ghostel-build/"
                    "-Doptimize=ReleaseFast" "-Dcpu=baseline")
                   "C:/ghostel/")
                 process-invocation))
        (should-not warnings)))))

(ert-deftest ghostel-test-compile-module-moves-to-dest-dir ()
  "Compilation moves the produced module and sidecar into DEST-DIR.
The sync `ghostel--compile-module' path goes through
`ghostel--install-module-pair', which pre-deletes any stale dest
sidecar so a partially-completed install never leaves a fresh
module beside a stale sidecar (issue #256 follow-up B1)."
  (let ((rename-args nil)
        (made-dirs nil)
        (deleted nil)
        (warnings nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/src/ghostel/"))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) "/custom/dir/.ghostel-build/"))
                ((symbol-function 'file-exists-p)
                 (lambda (_) t))
                ((symbol-function 'file-directory-p)
                 (lambda (_) nil))
                ((symbol-function 'make-directory)
                 (lambda (dir &rest _) (push dir made-dirs)))
                ((symbol-function 'delete-file)
                 (lambda (path) (push path deleted)))
                ((symbol-function 'rename-file)
                 (lambda (from to &optional _ok)
                   (push (list from to) rename-args)))
                ((symbol-function 'message) (lambda (&rest _)))
                ((symbol-function 'display-warning)
                 (lambda (&rest args) (push args warnings)))
                ((symbol-function 'process-file)
                 (lambda (&rest _) 0)))
        (ghostel--compile-module "/custom/dir/")
        (should-not warnings)
        (should (equal 1 (length deleted)))
        (should (equal (downcase (expand-file-name
                                  "ghostel-module.version"
                                  "/custom/dir/"))
                       (downcase (car deleted))))
        (should (equal 2 (length rename-args)))
        (let ((module-args (cadr rename-args))
              (sidecar-args (car rename-args)))
          (should (equal (downcase (expand-file-name
                                    (concat "ghostel-module" module-file-suffix)
                                    "/custom/dir/.ghostel-build/"))
                         (downcase (nth 0 module-args))))
          (should (equal (downcase (expand-file-name
                                    (concat "ghostel-module" module-file-suffix)
                                    "/custom/dir/"))
                         (downcase (nth 1 module-args))))
          (should (equal (downcase (expand-file-name
                                    "ghostel-module.version"
                                    "/custom/dir/.ghostel-build/"))
                         (downcase (nth 0 sidecar-args))))
          (should (equal (downcase (expand-file-name
                                    "ghostel-module.version"
                                    "/custom/dir/"))
                         (downcase (nth 1 sidecar-args)))))
        (should (member "/custom/dir/" made-dirs))))))

(ert-deftest ghostel-test-compile-module-warns-when-build-missing ()
  "When the build returns success but no module file appears, warn."
  (let ((warnings nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/src/ghostel/"))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) "/src/ghostel/.ghostel-build/"))
                ((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'file-directory-p)
                 (lambda (_) nil))
                ((symbol-function 'message) (lambda (&rest _)))
                ((symbol-function 'display-warning)
                 (lambda (&rest args) (push args warnings)))
                ((symbol-function 'process-file)
                 (lambda (&rest _) 0)))
        (ghostel--compile-module "/src/ghostel/")
        (should warnings)))))

(ert-deftest ghostel-test-module-compile-command-uses-zig-build-prefix ()
  "Interactive compilation uses zig build directly."
  (let ((compile-invocation nil)
        (finish-args nil)
        (default-directory nil)
        (ghostel-module-directory nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/src/ghostel/"))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) "/src/ghostel/.ghostel-build/"))
                ((symbol-function 'ghostel--install-built-module-on-finish)
                 (lambda (buf build-dir dest-dir)
                   (setq finish-args (list buf build-dir dest-dir))))
                ((symbol-function 'compilation-start)
                 (lambda (command &optional mode name-function &rest _)
                   (setq compile-invocation
                         (list command mode name-function default-directory))
                   (current-buffer))))
        (ghostel-module-compile)
        (should (equal (concat "zig build --prefix /src/ghostel/.ghostel-build/ "
                               "-Doptimize=ReleaseFast -Dcpu=baseline")
                       (nth 0 compile-invocation)))
        (should (eq #'ghostel-module-compilation-mode (nth 1 compile-invocation)))
        (should (eq #'ghostel--module-compilation-buffer-name
                    (nth 2 compile-invocation)))
        (should (equal "/src/ghostel/" (nth 3 compile-invocation)))
        (should (equal (list (current-buffer)
                             "/src/ghostel/.ghostel-build/"
                             "/src/ghostel/")
                       finish-args))))))

(ert-deftest ghostel-test-module-compile-installs-when-dest-differs ()
  "Interactive compile installs the built module into `ghostel-module-directory'.
A `compilation-finish-functions' handler runs
`ghostel--install-module-pair', which pre-deletes any existing dest
sidecar and then renames the module and sidecar into place."
  (let ((compile-invocation nil)
        (finish-args nil)
        (default-directory nil)
        (ghostel-module-directory "/custom/dir/"))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/src/ghostel/"))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) "/custom/dir/.ghostel-build/"))
                ((symbol-function 'ghostel--install-built-module-on-finish)
                 (lambda (buf build-dir dest-dir)
                   (setq finish-args (list buf build-dir dest-dir))))
                ((symbol-function 'compilation-start)
                 (lambda (command &optional mode name-function &rest _)
                   (setq compile-invocation
                         (list command mode name-function default-directory))
                   (current-buffer))))
        (ghostel-module-compile)
        (should (equal (concat "zig build --prefix /custom/dir/.ghostel-build/ "
                               "-Doptimize=ReleaseFast -Dcpu=baseline")
                       (nth 0 compile-invocation)))
        (should (eq #'ghostel-module-compilation-mode (nth 1 compile-invocation)))
        (should (eq #'ghostel--module-compilation-buffer-name
                    (nth 2 compile-invocation)))
        (should (equal "/src/ghostel/" (nth 3 compile-invocation)))
        (should (equal (list (current-buffer)
                             "/custom/dir/.ghostel-build/"
                             "/custom/dir/")
                       finish-args))))))

(ert-deftest ghostel-test-module-compile-recompile-installs-built-module ()
  "`ghostel-module-compile' installs artifacts again after `recompile'."
  (let* ((root (make-temp-file "ghostel-module-recompile" t))
         (dest-dir (file-name-as-directory (expand-file-name "module" root)))
         (counter (expand-file-name "counter" root))
         (module-name (concat "ghostel-module" module-file-suffix))
         (final (expand-file-name module-name dest-dir))
         (final-sidecar (expand-file-name "ghostel-module.version" dest-dir))
         (compile-buffer-name " *ghostel-module-recompile*")
         (compilation-ask-about-save nil)
         (ghostel-module-directory dest-dir)
         (ghostel-module-compile-command
          (format "sh -c %s sh %%s"
                  (shell-quote-argument
                   (format (concat "n=$(($(cat %s 2>/dev/null || echo 0)+1)); "
                                   "printf \"$n\" > %s; "
                                   "mkdir -p \"$1\"; "
                                   "printf \"module-$n\" > \"$1/%s\"; "
                                   "printf \"$n\" > \"$1/ghostel-module.version\"")
                           (shell-quote-argument counter)
                           (shell-quote-argument counter)
                           module-name)))))
    (cl-labels ((read-file (file)
                  (and (file-exists-p file)
                       (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string))))
                (wait-for-module (contents)
                  (ghostel-test--wait-until
                   (lambda () (equal contents (read-file final)))
                   nil 5)))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () root))
                ((symbol-function 'ghostel--module-compilation-buffer-name)
                 (lambda (_mode-name) compile-buffer-name)))
        (unwind-protect
            (let ((inhibit-message t))
              (ghostel-module-compile)
              (wait-for-module "module-1")
              (should (equal "1" (read-file final-sidecar)))
              (with-current-buffer compile-buffer-name
                (recompile))
              (wait-for-module "module-2")
              (should (equal "2" (read-file final-sidecar))))
          (when-let* ((buf (get-buffer compile-buffer-name)))
            (kill-buffer buf))
          (delete-directory root t))))))

(ert-deftest ghostel-test-module-version-match ()
  "Test that version check does nothing when module meets minimum."
  (let ((warned nil)
        (ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.2.0"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (ghostel--check-module-version "/tmp")
      (should-not warned))))

(ert-deftest ghostel-test-module-version-mismatch ()
  "Test that version check warns when module is below minimum.
At load time (PROMPT-USER nil) the warning fires but `ghostel--ensure-module'
must NOT be called — that path can prompt or download (issue #231).
At an interactive entry point (PROMPT-USER t) it does run."
  (let ((ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.1.0")))
      (let ((warned nil)
            (ensure-called nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (setq warned t)))
                  ((symbol-function 'ghostel--ensure-module)
                   (lambda (dir) (setq ensure-called dir))))
          (ghostel--check-module-version "/tmp")
          (should warned)
          (should-not ensure-called)))
      (let ((warned nil)
            (ensure-called nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (setq warned t)))
                  ((symbol-function 'ghostel--ensure-module)
                   (lambda (dir) (setq ensure-called dir))))
          (ghostel--check-module-version "/tmp" t)
          (should warned)
          (should (equal "/tmp" ensure-called)))))))

(ert-deftest ghostel-test-load-module-no-prompt-at-load-time ()
  "Loading ghostel must never trigger the auto-install path (issue #231).
At load time `ghostel--load-module' must not invoke
`ghostel--ensure-module' or any of its install paths.  Module
installation only happens at interactive entry points
\(`ghostel', `ghostel-download-module', `ghostel-module-compile').

The early-out in `ghostel--load-module' bails when the module is
already loaded, so this test temporarily hides
`ghostel--new' and the `ghostel-module' feature flag to force the
missing-file code path, then restores them."
  (let* ((tmp (make-temp-file "ghostel-test-no-mod" t))
         (ghostel-module-auto-install 'ask)
         (calls '())
         (had-feat (featurep 'ghostel-module))
         (saved-new (and (fboundp 'ghostel--new)
                         (symbol-function 'ghostel--new))))
    (unwind-protect
        (progn
          (when had-feat
            (setq features (delq 'ghostel-module features)))
          (when saved-new
            (fmakunbound 'ghostel--new))
          (cl-letf (((symbol-function 'ghostel--resource-root)
                     (lambda () tmp))
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (&rest _) (push 'ensure calls)))
                    ((symbol-function 'read-char-choice)
                     (lambda (&rest _) (push 'prompt calls) ?s))
                    ((symbol-function 'ghostel--download-module)
                     (lambda (&rest _) (push 'download calls) nil))
                    ((symbol-function 'ghostel--compile-module)
                     (lambda (&rest _) (push 'compile calls) nil))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) nil)))
            (ghostel--load-module)
            (ghostel--load-module nil)))
      (delete-directory tmp t)
      (when saved-new
        (fset 'ghostel--new saved-new))
      (when had-feat
        (cl-pushnew 'ghostel-module features)))
    (should (null calls))))

(ert-deftest ghostel-test-module-version-newer-than-minimum ()
  "Test that version check does nothing when module exceeds minimum."
  (let ((warned nil)
        (ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.3.0"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (ghostel--check-module-version "/tmp")
      (should-not warned))))

(ert-deftest ghostel-test-sidecar-read-missing ()
  "Reading a missing sidecar returns nil."
  (let ((tmp (make-temp-file "ghostel-test-sidecar" t)))
    (unwind-protect
        (should (null (ghostel--read-module-sidecar-version tmp)))
      (delete-directory tmp t))))

(ert-deftest ghostel-test-sidecar-read-empty ()
  "Reading an empty sidecar returns nil."
  (let ((tmp (make-temp-file "ghostel-test-sidecar" t)))
    (unwind-protect
        (progn
          (with-temp-file (ghostel--module-sidecar-path tmp))
          (should (null (ghostel--read-module-sidecar-version tmp))))
      (delete-directory tmp t))))

(ert-deftest ghostel-test-sidecar-round-trip ()
  "Writing then reading the sidecar returns the same version string."
  (let ((tmp (make-temp-file "ghostel-test-sidecar" t)))
    (unwind-protect
        (progn
          (ghostel--write-module-sidecar-version tmp "1.2.3")
          (should (equal "1.2.3" (ghostel--read-module-sidecar-version tmp))))
      (delete-directory tmp t))))

(ert-deftest ghostel-test-sidecar-trims-whitespace ()
  "Trailing whitespace in the sidecar is trimmed by the reader."
  (let ((tmp (make-temp-file "ghostel-test-sidecar" t)))
    (unwind-protect
        (progn
          (with-temp-file (ghostel--module-sidecar-path tmp)
            (insert "  0.9.1  \n\n"))
          (should (equal "0.9.1" (ghostel--read-module-sidecar-version tmp))))
      (delete-directory tmp t))))

(ert-deftest ghostel-test-release-version-from-url ()
  "Parsing a /releases/download/vX.Y.Z/asset URL extracts the version."
  (should (equal
           "0.25.0"
           (ghostel--release-version-from-url
            "https://github.com/owner/repo/releases/download/v0.25.0/ghostel-module-x86_64-linux.so")))
  ;; latest-style URL (server hasn't redirected) — no version embedded.
  (should (null
           (ghostel--release-version-from-url
            "https://github.com/owner/repo/releases/latest/download/ghostel-module-x86_64-linux.so")))
  (should (null (ghostel--release-version-from-url nil))))

(ert-deftest ghostel-test-load-module-skips-stale-sidecar-at-load-time ()
  "When the sidecar reports a stale version, `module-load' must NOT run.
At load time PROMPT-USER is nil so we only warn and skip — no
prompt, no install, no `module-load' of the stale binary."
  (let* ((tmp (make-temp-file "ghostel-test-load-stale" t))
         (mod (expand-file-name (concat "ghostel-module" module-file-suffix)
                                tmp))
         (ghostel--minimum-module-version "0.25.0")
         (load-calls nil)
         (ensure-calls nil)
         (warned nil)
         (had-feat (featurep 'ghostel-module))
         (saved-new (and (fboundp 'ghostel--new)
                         (symbol-function 'ghostel--new))))
    (unwind-protect
        (progn
          (when had-feat
            (setq features (delq 'ghostel-module features)))
          (when saved-new
            (fmakunbound 'ghostel--new))
          (with-temp-file mod (insert "stub"))
          (ghostel--write-module-sidecar-version tmp "0.20.0")
          (cl-letf (((symbol-function 'ghostel--module-directory)
                     (lambda () (file-name-as-directory tmp)))
                    ((symbol-function 'module-load)
                     (lambda (path) (push path load-calls)))
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (dir) (push dir ensure-calls)))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) (setq warned t))))
            (ghostel--load-module)
            (should warned)
            (should (null load-calls))
            (should (null ensure-calls))))
      (delete-directory tmp t)
      (when saved-new
        (fset 'ghostel--new saved-new))
      (when had-feat
        (cl-pushnew 'ghostel-module features)))))

(ert-deftest ghostel-test-load-module-prompts-on-stale-sidecar ()
  "Interactive entry with a stale sidecar runs `ghostel--ensure-module'.
After install refreshes the sidecar, the fresh module is loaded
in-process so no Emacs restart is needed."
  (let* ((tmp (make-temp-file "ghostel-test-load-stale-i" t))
         (mod (expand-file-name (concat "ghostel-module" module-file-suffix)
                                tmp))
         (ghostel--minimum-module-version "0.25.0")
         (load-calls nil)
         (ensure-calls nil)
         (had-feat (featurep 'ghostel-module))
         (saved-new (and (fboundp 'ghostel--new)
                         (symbol-function 'ghostel--new))))
    (unwind-protect
        (progn
          (when had-feat
            (setq features (delq 'ghostel-module features)))
          (when saved-new
            (fmakunbound 'ghostel--new))
          (with-temp-file mod (insert "stub"))
          (ghostel--write-module-sidecar-version tmp "0.20.0")
          (cl-letf (((symbol-function 'ghostel--module-directory)
                     (lambda () (file-name-as-directory tmp)))
                    ((symbol-function 'module-load)
                     (lambda (path) (push path load-calls)))
                    ;; Simulate a successful install: rewrite the sidecar
                    ;; to the current minimum, leaving the .so in place.
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (dir)
                       (push dir ensure-calls)
                       (ghostel--write-module-sidecar-version
                        dir ghostel--minimum-module-version)))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) nil)))
            (ghostel--load-module t)
            (should (equal 1 (length ensure-calls)))
            (should (equal (list mod) load-calls))))
      (delete-directory tmp t)
      (when saved-new
        (fset 'ghostel--new saved-new))
      (when had-feat
        (cl-pushnew 'ghostel-module features)))))

(ert-deftest ghostel-test-load-module-prompts-when-loaded-but-stale ()
  "Stale already-loaded module triggers a prompt at interactive entry.
Issue #256: when no sidecar existed at startup the elisp loader
still mapped the stale .so, and the previous version check ran
with PROMPT-USER nil so only a bare warning was surfaced.  After
the fix `M-x ghostel' must offer the install dialog."
  (let* ((tmp (make-temp-file "ghostel-test-loaded-stale" t))
         (ghostel--minimum-module-version "0.25.0")
         (warned nil)
         (ensure-calls nil)
         (had-feat (featurep 'ghostel-module)))
    (unwind-protect
        (progn
          ;; Pretend the (stale) module is already loaded.
          (cl-pushnew 'ghostel-module features)
          (cl-letf (((symbol-function 'ghostel--module-directory)
                     (lambda () (file-name-as-directory tmp)))
                    ((symbol-function 'ghostel--module-version)
                     (lambda () "0.20.0"))
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (dir) (push dir ensure-calls)))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) (setq warned t))))
            (ghostel--load-module t)
            (should warned)
            (should (equal 1 (length ensure-calls)))))
      (delete-directory tmp t)
      (unless had-feat
        (setq features (delq 'ghostel-module features))))))

(ert-deftest ghostel-test-load-module-no-prompt-on-loaded-stale-at-load-time ()
  "Even with a stale loaded module, the load-time call must NOT prompt.
The interactive prompt is gated on PROMPT-USER; load-time
auto-execution (e.g. byte-compile) only warns."
  (let* ((tmp (make-temp-file "ghostel-test-loaded-stale-load" t))
         (ghostel--minimum-module-version "0.25.0")
         (ensure-calls nil)
         (had-feat (featurep 'ghostel-module)))
    (unwind-protect
        (progn
          (cl-pushnew 'ghostel-module features)
          (cl-letf (((symbol-function 'ghostel--module-directory)
                     (lambda () (file-name-as-directory tmp)))
                    ((symbol-function 'ghostel--module-version)
                     (lambda () "0.20.0"))
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (dir) (push dir ensure-calls)))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) nil)))
            (ghostel--load-module)
            (should (null ensure-calls))))
      (delete-directory tmp t)
      (unless had-feat
        (setq features (delq 'ghostel-module features))))))

(ert-deftest ghostel-test-install-module-pair-deletes-stale-sidecar ()
  "Existing dest sidecar is removed before the new module is moved.
`ghostel--install-module-pair' keeps the invariant that a fresh
module is never paired with a stale sidecar."
  (let* ((src (make-temp-file "ghostel-test-pair-src" t))
         (dst (make-temp-file "ghostel-test-pair-dst" t))
         (built-mod (expand-file-name "ghostel-module.so" src))
         (final-mod (expand-file-name "ghostel-module.so" dst))
         (built-sidecar (expand-file-name "ghostel-module.version" src))
         (final-sidecar (expand-file-name "ghostel-module.version" dst)))
    (unwind-protect
        (progn
          (with-temp-file built-mod (insert "new-so"))
          (with-temp-file built-sidecar (insert "0.99.0\n"))
          (with-temp-file final-mod (insert "old-so"))
          (with-temp-file final-sidecar (insert "0.10.0\n"))
          (let ((old-inode (file-attribute-inode-number
                            (file-attributes final-mod))))
            (ghostel--install-module-pair built-mod final-mod
                                          built-sidecar final-sidecar)
            (should (file-exists-p final-mod))
            (should (equal "new-so" (with-temp-buffer
                                      (insert-file-contents final-mod)
                                      (buffer-string))))
            (should-not (equal old-inode
                               (file-attribute-inode-number
                                (file-attributes final-mod)))))
          (should (equal "0.99.0" (ghostel--read-module-sidecar-version dst)))
          (should-not (file-exists-p built-mod))
          (should-not (file-exists-p built-sidecar)))
      (delete-directory src t)
      (delete-directory dst t))))

(ert-deftest ghostel-test-install-module-pair-sidecar-failure-leaves-absent ()
  "A sidecar rename failure leaves the dest in `absent' state.
The pre-delete in `ghostel--install-module-pair' guarantees that if
the second rename fails, the destination has a fresh module but
NO sidecar — which the loader treats as backward-compat live check,
not as `refuse to map'."
  (let* ((src (make-temp-file "ghostel-test-pair-fail-src" t))
         (dst (make-temp-file "ghostel-test-pair-fail-dst" t))
         (built-mod (expand-file-name "ghostel-module.so" src))
         (final-mod (expand-file-name "ghostel-module.so" dst))
         (built-sidecar (expand-file-name "ghostel-module.version" src))
         (final-sidecar (expand-file-name "ghostel-module.version" dst))
         (real-rename (symbol-function 'rename-file)))
    (unwind-protect
        (progn
          (with-temp-file built-mod (insert "new-so"))
          (with-temp-file built-sidecar (insert "0.99.0\n"))
          (with-temp-file final-sidecar (insert "0.10.0\n"))
          (cl-letf (((symbol-function 'rename-file)
                     (lambda (from to &optional ok)
                       (if (string-suffix-p ".version" from)
                           (signal 'file-error '("simulated sidecar rename failure"))
                         (funcall real-rename from to ok)))))
            (should-error
             (ghostel--install-module-pair built-mod final-mod
                                           built-sidecar final-sidecar)
             :type 'file-error))
          ;; Fresh module landed.
          (should (file-exists-p final-mod))
          (should (equal "new-so" (with-temp-buffer
                                    (insert-file-contents final-mod)
                                    (buffer-string))))
          ;; Stale sidecar was pre-deleted, new sidecar rename failed —
          ;; net result is `absent', not `stale'.
          (should-not (file-exists-p final-sidecar)))
      (delete-directory src t)
      (delete-directory dst t))))

(ert-deftest ghostel-test-download-module-deletes-stale-sidecar-on-failure ()
  "A failed download leaves no stale sidecar behind.
The download path pre-deletes the dest sidecar so that even if
`ghostel--download-file' fails, the loader falls back to the live
version check on whatever module is on disk instead of refusing
to map it based on stale sidecar metadata."
  (let* ((dir (make-temp-file "ghostel-test-dl-fail" t))
         (sidecar (ghostel--module-sidecar-path dir)))
    (unwind-protect
        (progn
          (with-temp-file sidecar (insert "0.10.0\n"))
          (cl-letf (((symbol-function 'ghostel--download-file)
                     (lambda (&rest _) nil))
                    ((symbol-function 'message) (lambda (&rest _))))
            (should-not (ghostel--download-module dir)))
          (should-not (file-exists-p sidecar)))
      (delete-directory dir t))))

(ert-deftest ghostel-test-build-emits-sidecar-version ()
  "`zig build' writes a sidecar matching the live module version.
Runs in the native test suite so the build has already produced
both the .so/.dylib and ghostel-module.version next to it."
  :tags '(native)
  (let* ((dir (ghostel--module-directory))
         (sidecar (ghostel--read-module-sidecar-version dir)))
    (should (stringp sidecar))
    (should (equal sidecar (ghostel--module-version)))))

(ert-deftest ghostel-test-platform-tag-normalizes-arch ()
  "Test that amd64/arm64 arch names are normalized in platform tags."
  ;; amd64 -> x86_64
  (let ((system-configuration "amd64-pc-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "x86_64-linux")))
  ;; arm64 -> aarch64
  (let ((system-configuration "arm64-apple-darwin23.1.0")
        (system-type 'darwin))
    (should (equal (ghostel--module-platform-tag) "aarch64-macos")))
  ;; x86_64 unchanged
  (let ((system-configuration "x86_64-pc-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "x86_64-linux")))
  ;; aarch64 unchanged
  (let ((system-configuration "aarch64-unknown-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "aarch64-linux"))))

(provide 'ghostel-module-test)
;;; ghostel-module-test.el ends here
