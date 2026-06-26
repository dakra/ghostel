;;; ghostel-module-install.el --- Native module download/compile/load for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provisioning for Ghostel's native module (`ghostel-module', the compiled
;; libghostty .so/.dylib): downloading a pre-built binary from GitHub releases
;; compiling from source via `zig build', maintainingthe on-disk version sidecar,
;; and loading the module — including the version checks that decide whether
;; an on-disk module is fresh enough to map.
;;
;; `ghostel.el' requires this file and calls `ghostel--load-module' at load time.

;;; Code:

(require 'compat)
(require 'url-parse)

(declare-function ghostel--module-version "ghostel-module")


;;; Customization

(defcustom ghostel-module-directory nil
  "Directory holding the ghostel native module.
When nil (the default), the module is read from and written to the
ghostel package directory.  Set this to a path outside your package
manager's tree (for example, \"~/.config/emacs/ghostel/\") so that
rebuilds or re-installs by the package manager do not delete or
overwrite the module file while Emacs has it loaded."
  :type '(choice (const :tag "Use package directory" nil)
                 (directory :tag "Custom directory"))
  :group 'ghostel)

(defcustom ghostel-module-auto-install 'ask
  "What to do when the native module is missing at first interactive use.
This setting is consulted only when the user invokes an interactive
entry point such as `\\[ghostel]', not when `ghostel.el' is loaded
or byte-compiled - loading the file never prompts or downloads.
\\=`ask'      - prompt with a choice to download, compile, or skip (default).
\\=`download' - download a pre-built binary from GitHub releases.
\\=`compile'  - build from source via `ghostel-module-compile'.
nil        - do nothing; the user must install the module manually."
  :type '(choice (const :tag "Ask interactively" ask)
                 (const :tag "Download pre-built binary" download)
                 (const :tag "Compile from source" compile)
                 (const :tag "Do nothing" nil))
  :group 'ghostel)

(defcustom ghostel-github-release-url
  "https://github.com/dakra/ghostel/releases"
  "Base URL for Ghostel GitHub releases.
Customize this when downloading pre-built modules from a fork or mirror."
  :type 'string
  :group 'ghostel)


;;; Native module download, compilation, and loading

(defconst ghostel--minimum-module-version "0.39.0"
  "Minimum native module version required by this Elisp version.
Bump this only when the Elisp code requires a newer native module
\(e.g. new Zig-exported function or changed calling convention).")

(defun ghostel--module-platform-tag ()
  "Return platform tag for the current system, e.g. \"x86_64-linux\".
Returns nil if the platform is not recognized."
  (let* ((raw-arch (car (split-string system-configuration "-")))
         (arch (pcase raw-arch
                 ("amd64" "x86_64")
                 ("arm64" "aarch64")
                 (_ raw-arch)))
         (os (cond
              ((eq system-type 'darwin) "macos")
              ((eq system-type 'gnu/linux) "linux")
              (t nil))))
    (when os
      (format "%s-%s" arch os))))

(defun ghostel--module-asset-name ()
  "Return the expected release asset file name for the current platform."
  (let ((tag (ghostel--module-platform-tag)))
    (when tag
      (format "ghostel-module-%s%s" tag module-file-suffix))))

(defun ghostel--module-download-url (&optional version)
  "Return the download URL for the current platform's pre-built module.
When VERSION is nil, use the latest release download URL."
  (let ((asset-name (ghostel--module-asset-name)))
    (when asset-name
      (if version
          (format "%s/download/v%s/%s"
                  ghostel-github-release-url version asset-name)
        (format "%s/latest/download/%s"
                ghostel-github-release-url asset-name)))))

(defun ghostel--release-version-from-url (url)
  "Return the release version embedded in URL, or nil.
GitHub's `/releases/latest/download/<asset>' redirect resolves to
`/releases/download/v<X.Y.Z>/<asset>'; extract the X.Y.Z segment."
  (when (and url
             (string-match "/releases/download/v\\([0-9]+\\.[0-9]+\\.[0-9]+\\)/"
                           url))
    (match-string 1 url)))

(defun ghostel--download-module (dir &optional version latest-release)
  "Download a pre-built module into DIR.
When VERSION is non-nil, download that release tag.
When LATEST-RELEASE is non-nil, use the latest release asset URL.
On success, also writes the sidecar version file alongside the module.
Returns non-nil on success."
  (condition-case err
      (let* ((requested-version (unless latest-release
                                  (or version ghostel--minimum-module-version)))
             (url (ghostel--module-download-url requested-version)))
        (when url
          (unless (string-prefix-p "https://" url)
            (error "Refusing non-HTTPS download URL: %s" url))
          (make-directory dir t)
          (let ((dest (expand-file-name
                       (concat "ghostel-module" module-file-suffix) dir))
                (sidecar (ghostel--module-sidecar-path dir)))
            ;; Drop any pre-existing sidecar so that, if the download or the
            ;; subsequent sidecar write fails partway, the loader sees `absent'
            ;; rather than `stale' (refuse to map a fresh module).
            (when (file-exists-p sidecar)
              (delete-file sidecar))
            (message "ghostel: downloading native module from %s..." url)
            (when-let* ((final-url (ghostel--download-file url dest)))
              ;; Resolve the version that was actually fetched.  For an
              ;; explicit version we trust the request; for `latest' we
              ;; parse the URL the server redirected us to.  If parsing
              ;; fails we fall back to the minimum so the sidecar still
              ;; reflects a safe lower bound.
              (let ((resolved (or requested-version
                                  (ghostel--release-version-from-url final-url)
                                  ghostel--minimum-module-version)))
                (ghostel--write-module-sidecar-version dir resolved))
              (message "ghostel: native module downloaded successfully")
              t))))
    (error
     (message "ghostel: download failed: %s" (error-message-string err))
     nil)))

(defun ghostel--compile-module (dest-dir)
  "Compile the native module from source and install it in DEST-DIR.
The build runs in `ghostel--resource-root' (which holds build.zig);
on success the produced module and its sidecar are moved into DEST-DIR."
  (let* ((source-dir (ghostel--resource-root))
         (default-directory source-dir))
    (message "ghostel: compiling native module with zig build (this may take a moment)...")
    (condition-case err
        (let ((ret (process-file "zig" nil "*ghostel-build*" nil
                                 "build" "-Doptimize=ReleaseFast" "-Dcpu=baseline")))
          (if (not (eq ret 0))
              (display-warning 'ghostel
                               "Module compilation failed.  See *ghostel-build* buffer for details.")
            (let* ((file-name (concat "ghostel-module" module-file-suffix))
                   (built (expand-file-name file-name source-dir))
                   (final (expand-file-name file-name dest-dir)))
              (cond
               ((not (file-exists-p built))
                (display-warning 'ghostel
                                 (format "Build succeeded but module not produced at %s"
                                         built)))
               ((equal built final)
                (message "ghostel: native module compiled successfully"))
               (t
                (ghostel--install-module-pair
                 built final
                 (expand-file-name "ghostel-module.version" source-dir)
                 (expand-file-name "ghostel-module.version" dest-dir))
                (message "ghostel: native module compiled successfully"))))))
      (file-missing
       (display-warning 'ghostel
                        (format "zig executable not found while compiling in %s" source-dir)))
      (error
       (display-warning 'ghostel (error-message-string err))))))

(defun ghostel--ensure-module (dir)
  "Ensure the native module exists in DIR.
Behavior is controlled by `ghostel-module-auto-install'."
  (let ((action ghostel-module-auto-install))
    (when (eq action 'ask)
      (setq action (ghostel--ask-install-action dir)))
    (pcase action
      ('download (ghostel--download-module dir))
      ('compile  (ghostel--compile-module dir))
      (_         nil))))

(defun ghostel--read-module-download-version ()
  "Prompt for a release tag to download, or nil for the latest release."
  (let ((version (read-string
                  (format "Ghostel module version (>= %s, empty for latest): "
                          ghostel--minimum-module-version))))
    (unless (string= version "")
      (when (version< version ghostel--minimum-module-version)
        (user-error "Version %s is older than minimum supported version %s"
                    version ghostel--minimum-module-version))
      version)))

(defun ghostel--ask-install-action (_dir)
  "Prompt the user to choose how to install the missing native module.
Returns \\='download, \\='compile, or nil."
  (let* ((url (or (ghostel--module-download-url ghostel--minimum-module-version)
                  "GitHub releases"))
         (choice (read-char-choice
                  (format "Ghostel native module not found.

  [d] Download pre-built binary from:
      %s
  [c] Compile from source via build.sh
  [s] Skip — install manually later

Choice: " url)
                  '(?d ?c ?s))))
    (pcase choice
      (?d 'download)
      (?c 'compile)
      (?s nil))))

(defun ghostel--download-file (url dest)
  "Download URL to DEST atomically.  Return the final URL on success, else nil.
The returned URL reflects any HTTP redirects followed during the
fetch, which lets callers resolve a `latest' alias to the actual
release tag.  Writes to a sibling temp file in the same directory
and renames it into place once the download succeeds.  Renaming
swaps the directory entry to a new inode, so any process (notably
a running Emacs) that has the previous DEST file mmap'd keeps a
valid mapping to the old file content.  Writing to DEST directly
would truncate the existing inode and corrupt that mapping."
  (let* ((url-request-method "GET")
         (url-show-status nil)
         (tmp (make-temp-name (concat dest ".tmp.")))
         (final-url nil))
    (unwind-protect
        (let ((buf (url-retrieve-synchronously url t t 30)))
          (when buf
            (unwind-protect
                (with-current-buffer buf
                  (set-buffer-multibyte nil)
                  (goto-char (point-min))
                  (when (re-search-forward "^HTTP/[0-9.]+ 200" nil t)
                    (when (re-search-forward "\r?\n\r?\n" nil t)
                      (let ((coding-system-for-write 'binary)
                            (start (point)))
                        (when (< start (point-max))
                          (write-region start (point-max) tmp nil 'silent)
                          (set-file-modes tmp #o755)
                          (rename-file tmp dest t)
                          ;; `url-current-object' tracks the URL of the
                          ;; final response after redirect-following, so
                          ;; latest-asset URLs resolve to /download/vX.Y.Z/.
                          (setq final-url
                                (or (and (boundp 'url-current-object)
                                         url-current-object
                                         (url-recreate-url url-current-object))
                                    url)))))))
              (when (buffer-live-p buf)
                (kill-buffer buf)))))
      (unless final-url
        (when (file-exists-p tmp)
          (ignore-errors (delete-file tmp)))))
    final-url))

(defun ghostel--package-directory ()
  "Return the directory ghostel is loaded from, or nil."
  (let ((src (or (locate-library "ghostel")
                 load-file-name buffer-file-name)))
    (and src (file-name-directory src))))

(defun ghostel--resource-root ()
  "Return the root directory holding shipped resources (etc/, vendor/).
Prefers whichever layout is actually on disk:
- dev / `package-vc-install': ghostel.el lives under `lisp/', so the
  resource root is the parent of the Lisp directory.
- MELPA-style flat install: `:files' flattens sources into the
  package root, so the resource root equals the Lisp directory.
Falls back to the Lisp directory itself when neither layout is
detectable (e.g. a standalone ghostel.el on `load-path' without the
shipped resources), so callers always get a sensible
`default-directory' to work in."
  (when-let* ((lisp-dir (ghostel--package-directory)))
    (or (and (file-directory-p (expand-file-name "etc" lisp-dir)) lisp-dir)
        (let ((parent (file-name-as-directory
                       (expand-file-name ".." lisp-dir))))
          (and (file-directory-p (expand-file-name "etc" parent)) parent))
        lisp-dir)))

(defun ghostel--module-directory ()
  "Return the absolute directory where the native module lives.
Honours `ghostel-module-directory' when set, otherwise falls back to
the shipped resource root."
  (when-let* ((dir (or ghostel-module-directory
                       (ghostel--resource-root))))
    (file-name-as-directory (expand-file-name dir))))

(defun ghostel--module-sidecar-path (dir)
  "Return the path of the module version sidecar inside DIR.
The sidecar is a one-line file holding the version string of the
neighbouring native module.  It is written by `build.zig' at compile
time and by `ghostel--download-module' after a successful download,
so the loader can check the on-disk version without `module-load'."
  (expand-file-name "ghostel-module.version" dir))

(defun ghostel--read-module-sidecar-version (dir)
  "Return the version string recorded in DIR's sidecar, or nil.
A missing or empty file returns nil; the result is otherwise trimmed."
  (let ((path (ghostel--module-sidecar-path dir)))
    (when (file-readable-p path)
      (let ((s (with-temp-buffer
                 (insert-file-contents path)
                 (string-trim (buffer-string)))))
        (and (not (string-empty-p s)) s)))))

(defun ghostel--write-module-sidecar-version (dir version)
  "Write VERSION to DIR's sidecar atomically."
  (make-directory dir t)
  (let* ((dest (ghostel--module-sidecar-path dir))
         (tmp (make-temp-name (concat dest ".tmp."))))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (concat version "\n") nil tmp nil 'silent)
          (rename-file tmp dest t)
          (setq tmp nil))
      (when (and tmp (file-exists-p tmp))
        (ignore-errors (delete-file tmp))))))

(defun ghostel--install-module-pair (built-mod final-mod
                                               built-sidecar final-sidecar)
  "Move BUILT-MOD and BUILT-SIDECAR into FINAL-MOD and FINAL-SIDECAR.
The destination sidecar is removed before the module is moved, so every
failure path ends in `sidecar absent' rather than `sidecar stale'.
The loader treats the former as backward-compat (load and run a live
version check); the latter as `refuse to map', which would leave the
user stuck with a fresh module they cannot load."
  (make-directory (file-name-directory final-mod) t)
  (when (file-exists-p final-sidecar)
    (delete-file final-sidecar))
  (rename-file built-mod final-mod t)
  (when (file-exists-p built-sidecar)
    (rename-file built-sidecar final-sidecar t)))

(defun ghostel-download-module (&optional prompt-for-version)
  "Interactively download the pre-built native module for this platform.
With PROMPT-FOR-VERSION, prompt for a release tag to download.
Leaving the prompt empty downloads the latest release."
  (interactive "P")
  (let* ((dir (ghostel--module-directory))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir))
         (version (when prompt-for-version
                    (ghostel--read-module-download-version)))
         (latest-release (and prompt-for-version (null version))))
    (when (and (file-exists-p mod)
               (not (yes-or-no-p "Module already exists.  Re-download? ")))
      (user-error "Cancelled"))
    (if (ghostel--download-module dir version latest-release)
        (if (featurep 'ghostel-module)
            (message "ghostel: module downloaded.  Restart Emacs to load the new version")
          (module-load mod)
          (message "ghostel: module loaded successfully"))
      (user-error "Download failed.  Try M-x ghostel-module-compile to build from source"))))

(defun ghostel--install-built-module-on-finish (compile-buf source-dir dest-dir)
  "Move the built module from SOURCE-DIR into DEST-DIR when COMPILE-BUF finishes.
Registers a one-shot `compilation-finish-functions' handler that
filters on COMPILE-BUF and removes itself on first match.  Used so the
interactive `ghostel-module-compile' honours `ghostel-module-directory'.
The sidecar version file written by `build.zig' is moved alongside the module."
  (let* ((file-name (concat "ghostel-module" module-file-suffix))
         (sidecar "ghostel-module.version")
         handler)
    (setq handler
          (lambda (buf status)
            (when (eq buf compile-buf)
              (remove-hook 'compilation-finish-functions handler)
              (when (string-match-p "finished" status)
                (let ((built (expand-file-name file-name source-dir))
                      (final (expand-file-name file-name dest-dir))
                      (built-sidecar (expand-file-name sidecar source-dir))
                      (final-sidecar (expand-file-name sidecar dest-dir)))
                  (when (file-exists-p built)
                    (condition-case err
                        (progn
                          (ghostel--install-module-pair
                           built final built-sidecar final-sidecar)
                          (message "ghostel: module installed at %s" final))
                      (error
                       (display-warning
                        'ghostel
                        (format "Build succeeded but installing into %s failed: %s"
                                dest-dir (error-message-string err)))))))))))
    (add-hook 'compilation-finish-functions handler)))

(defun ghostel-module-compile ()
  "Compile the ghostel native module by running zig build.
The output is shown in a `*compilation*' buffer.
When `ghostel-module-directory' points outside the package tree, the
produced module is moved into that directory once the build finishes."
  (interactive)
  (let* ((source-dir (ghostel--resource-root))
         (dest-dir (ghostel--module-directory))
         (default-directory source-dir)
         (compile-buf (compile "zig build -Doptimize=ReleaseFast -Dcpu=baseline" t)))
    (unless (equal (file-name-as-directory (expand-file-name source-dir))
                   (file-name-as-directory (expand-file-name dest-dir)))
      (ghostel--install-built-module-on-finish compile-buf source-dir dest-dir))))


(defun ghostel--check-module-version (dir &optional prompt-user)
  "Check if the loaded module is older than required.
When the module version is below `ghostel--minimum-module-version',
warn unconditionally and, when PROMPT-USER is non-nil, offer to
update using `ghostel-module-auto-install'.  DIR is the module
directory.  At load time PROMPT-USER is nil so a stale module never
triggers an interactive prompt."
  (let ((mod-ver (and (fboundp 'ghostel--module-version)
                      (ghostel--module-version))))
    (when (or (null mod-ver)
              (version< mod-ver ghostel--minimum-module-version))
      (display-warning 'ghostel
                       (format "Module version %s is older than required %s"
                               (or mod-ver "unknown")
                               ghostel--minimum-module-version))
      (when prompt-user
        (ghostel--ensure-module dir)))))

(defun ghostel--load-module (&optional prompt-user)
  "Ensure the ghostel native module is loaded.
When PROMPT-USER is non-nil (called from an interactive command like
`ghostel'), missing or stale modules trigger
`ghostel-module-auto-install' and load failures signal `user-error'
so the calling flow aborts.  Otherwise (load time, including
byte-compilation and Emacs 31's `user-lisp/' auto-compile), this
function never prompts, downloads, or compiles - it only loads an
existing module file and warns if one is missing or stale.  Module
installation only happens on an explicit user action: `M-x ghostel',
`M-x ghostel-download-module', or `M-x ghostel-module-compile'.

Before calling `module-load' the sidecar file
`ghostel-module.version' (written by `build.zig' and the downloader)
is consulted.  When the sidecar reports a version older than
`ghostel--minimum-module-version' the .so is NOT mapped into this
process — that lets the freshly installed module be loaded in
place after a subsequent `ghostel--ensure-module' call, avoiding an
extra restart.

The guard also honours `ghostel--new' being already `fboundp', which
covers the pure-Elisp test path where `cl-letf' stubs the native
entry points so tests run without the module present."
  (let* ((dir (ghostel--module-directory))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir))
         (sidecar-ver (ghostel--read-module-sidecar-version dir)))
    (unless (or (featurep 'ghostel-module)
                (fboundp 'ghostel--new))
      (cond
       ;; Sidecar tells us the on-disk module is too old.  Refuse to map
       ;; it so a subsequent install can `module-load' the fresh file in
       ;; this same Emacs process.
       ((and sidecar-ver
             (version< sidecar-ver ghostel--minimum-module-version))
        (display-warning
         'ghostel
         (format "Module version %s on disk is older than required %s"
                 sidecar-ver ghostel--minimum-module-version))
        (when prompt-user
          (ghostel--ensure-module dir)
          (let ((new-ver (ghostel--read-module-sidecar-version dir)))
            (when (and (file-exists-p mod)
                       new-ver
                       (not (version< new-ver
                                      ghostel--minimum-module-version)))
              (condition-case err
                  (module-load mod)
                (error
                 (user-error "Failed to load ghostel native module: %s"
                             (error-message-string err))))))))
       ;; Module file missing.
       ((not (file-exists-p mod))
        (cond
         (prompt-user
          (ghostel--ensure-module dir)
          (when (file-exists-p mod)
            (condition-case err
                (module-load mod)
              (error
               (user-error "Failed to load ghostel native module: %s"
                           (error-message-string err))))))
         (t
          (display-warning
           'ghostel
           (concat "Native module not found: " mod
                   "\nRun M-x ghostel-download-module or M-x ghostel-module-compile")))))
       ;; File exists and the sidecar (when present) is fresh.  Load it.
       ;; When the sidecar is absent (existing installs predating it),
       ;; fall back to a live version check post-load.  We skip the live
       ;; check here when PROMPT-USER is non-nil; the tail below runs it
       ;; instead, avoiding a double prompt.
       (t
        (condition-case err
            (progn
              (module-load mod)
              (unless prompt-user
                (ghostel--check-module-version dir nil)))
          (error
           (if prompt-user
               (user-error "Failed to load ghostel native module: %s"
                           (error-message-string err))
             (display-warning
              'ghostel
              (format "Failed to load native module: %s\nTry M-x ghostel-module-compile to rebuild"
                      (error-message-string err)))))))))
    ;; Surface the version check at every interactive entry point — not
    ;; just when this call loaded the module.  Otherwise a stale .so
    ;; mapped in by an earlier load (e.g. sidecar absent at startup) is
    ;; silently kept and the user only ever sees the bare warning.
    (when (and prompt-user (featurep 'ghostel-module))
      (ghostel--check-module-version dir t))))

(provide 'ghostel-module-install)
;;; ghostel-module-install.el ends here
