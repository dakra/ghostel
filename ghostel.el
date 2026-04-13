;;; ghostel.el --- Terminal emulator powered by libghostty -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.13.0
;; Keywords: terminals
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Ghostel is an Emacs terminal emulator powered by libghostty-vt, the
;; terminal emulation library extracted from the Ghostty project.  A
;; native Zig dynamic module handles VT parsing, terminal state, and
;; rendering, while this Elisp layer manages the shell process, keymap,
;; buffer, and user-facing commands.
;;
;; Usage:
;;
;;   M-x ghostel          Open a new terminal
;;   M-x ghostel-other    Switch to next terminal or create one
;;
;; Key bindings in the terminal buffer:
;;
;;   Most keys are sent directly to the shell.  Keys in
;;   `ghostel-keymap-exceptions' (C-c, C-x, M-x, etc.) pass through
;;   to Emacs.  Terminal control keys use a C-c prefix:
;;
;;   C-c C-c   Interrupt        C-c C-z   Suspend
;;   C-c C-d   EOF              C-c C-\   Quit
;;   C-c C-t   Copy mode        C-c C-y   Paste
;;   C-c C-l   Clear scrollback C-c C-q   Send next key literally
;;   C-y       Yank             M-y       Yank-pop
;;
;; Copy mode (C-c C-t) freezes the display and enables standard Emacs
;; navigation.  Set mark with C-SPC, select text, then M-w to copy.
;; Soft-wrapped newlines and trailing whitespace are stripped
;; automatically.
;;
;; Shell integration:
;;
;;   For directory tracking (OSC 7), source the appropriate script
;;   from etc/ in your shell configuration:
;;
;;     # bash (~/.bashrc)
;;     [[ "$INSIDE_EMACS" = 'ghostel' ]] && \
;;       source "$EMACS_GHOSTEL_PATH/etc/ghostel.bash"
;;
;;     # zsh (~/.zshrc)
;;     [[ "$INSIDE_EMACS" = 'ghostel' ]] && \
;;       source "$EMACS_GHOSTEL_PATH/etc/ghostel.zsh"
;;
;; Building the native module (requires Zig 0.15.2+):
;;
;;   Run zig build from the project root,
;;   or M-x ghostel-module-compile from within Emacs.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'term)
(require 'tramp)
(require 'url-parse)
(require 'face-remap)


;;; Customization

(defgroup ghostel nil
  "Terminal emulator powered by libghostty."
  :group 'terminals
  :prefix "ghostel-")

(defcustom ghostel-shell (or (getenv "SHELL") "/bin/sh")
  "Shell program to run in the terminal."
  :type 'string)

(defcustom ghostel-tramp-shells
  '(("ssh" login-shell)
    ("scp" login-shell)
    ("docker" "/bin/sh"))
  "Shell to use for remote TRAMP connections, per method.
Each entry is (TRAMP-METHOD SHELL [FALLBACK]).  TRAMP-METHOD is a
method string such as \"ssh\" or \"docker\", or t as a catch-all default.

SHELL is either a path string like \"/bin/bash\" or the symbol
`login-shell' to auto-detect the remote user's login shell via
`getent passwd'.  FALLBACK, when present, is used when login-shell
detection fails."
  :type '(alist :key-type (choice string (const t))
                :value-type
                (list (choice string (const login-shell))
                      (choice (const :tag "No fallback" nil) string))))

(defcustom ghostel-max-scrollback (* 5 1024 1024)  ; 5MB
  "Maximum scrollback size in bytes.
5 MB holds roughly 5,000 rows on a typical 80-column terminal
\(fewer on wider terminals — the cost scales with column count).

The full scrollback is materialized into the Emacs buffer so that
`isearch', `consult-line', and other buffer-based commands work
across history.  Each materialized row also lives in the Emacs
buffer with text properties for color/style/links, so the
practical Emacs heap cost is roughly equal to the libghostty
allocation, and large values noticeably slow down sustained
high-throughput output (e.g. `cat huge.log')."
  :type 'integer)

(defcustom ghostel-timer-delay 0.033
  "Delay in seconds before redrawing after output (roughly 30fps).
When `ghostel-adaptive-fps' is non-nil, this serves as the base
delay between frames during sustained output."
  :type 'number)

(defcustom ghostel-adaptive-fps t
  "Use adaptive frame rate for terminal redraw.
When non-nil, use a shorter initial delay for responsive interactive
feedback and stop the timer entirely when idle.  When nil, use the
fixed `ghostel-timer-delay' unconditionally."
  :type 'boolean)

(defcustom ghostel-immediate-redraw-threshold 256
  "Maximum bytes of output to trigger an immediate redraw.
When output arrives within `ghostel-immediate-redraw-interval'
seconds of the last keystroke and is smaller than this threshold,
redraw immediately instead of waiting for the timer.  This
eliminates the 16-33ms timer delay for interactive typing echo.
Set to 0 to disable immediate redraws."
  :type 'integer)

(defcustom ghostel-immediate-redraw-interval 0.05
  "Maximum seconds since last keystroke for immediate redraw.
Output arriving within this interval of a `ghostel--send-key'
call is considered interactive echo and redrawn immediately
when the output size is below `ghostel-immediate-redraw-threshold'."
  :type 'number)

(defcustom ghostel-input-coalesce-delay 0.003
  "Delay in seconds to coalesce rapid keystrokes before sending.
When non-zero, keystrokes are buffered for up to this many seconds
and sent as a single write to the PTY.  This reduces per-key
syscall overhead during fast typing.  Set to 0 to disable."
  :type 'number)

(defcustom ghostel-full-redraw nil
  "When non-nil, always perform full redraws instead of incremental updates.
Full redraws are more robust with TUI apps like Claude Code that do
aggressive partial screen updates, but may use more CPU."
  :type 'boolean)

(defcustom ghostel-buffer-name "*ghostel*"
  "Default buffer name for ghostel terminals."
  :type 'string)

(defcustom ghostel-enable-title-tracking t
  "Automatically rename the buffer when the terminal title changes.
When non-nil, OSC 2 title sequences update the buffer name to
\"*ghostel: TITLE*\".  Set to nil to keep the buffer name fixed."
  :type 'boolean)

(defcustom ghostel-kill-buffer-on-exit t
  "Kill the buffer when the shell process exits."
  :type 'boolean)

(defcustom ghostel-exit-functions nil
  "Hook run when the terminal process exits.
Each function is called with two arguments: the buffer and the
exit event string."
  :type 'hook)

(defcustom ghostel-eval-cmds '(("find-file" find-file)
                               ("find-file-other-window" find-file-other-window)
                               ("dired" dired)
                               ("dired-other-window" dired-other-window)
                               ("message" message))
  "Whitelisted Emacs functions callable from the terminal via OSC 51.
Each entry is (NAME FUNCTION) where NAME is the string sent from
the shell and FUNCTION is the Elisp function to invoke.
All arguments are passed as strings."
  :type '(alist :key-type string :value-type function))

(defcustom ghostel-enable-osc52 nil
  "Allow terminal applications to set the clipboard via OSC 52.
When non-nil, programs running in the terminal can copy text to the
Emacs kill ring and system clipboard using OSC 52 escape sequences.
This is useful for remote SSH sessions where the application cannot
access the local clipboard directly.

Disabled by default for security: a malicious escape sequence in
command output could silently overwrite your clipboard."
  :type 'boolean)

(defcustom ghostel-enable-url-detection t
  "Automatically detect and linkify URLs in terminal output.
When non-nil, plain-text URLs (http:// and https://) are made
clickable even if the program did not use OSC 8 hyperlink escapes."
  :type 'boolean)

(defcustom ghostel-enable-file-detection t
  "Automatically detect and linkify file:line references in terminal output.
When non-nil, patterns like /path/to/file.el:42 are made clickable,
opening the file at the given line in another window."
  :type 'boolean)

(defcustom ghostel-module-auto-install 'ask
  "What to do when the native module is missing at load time.
\\=`ask'      — prompt with a choice to download, compile, or skip (default).
\\=`download' — download a pre-built binary from GitHub releases.
\\=`compile'  — build from source via `ghostel-module-compile'.
nil         — do nothing; the user must install the module manually."
  :type '(choice (const :tag "Ask interactively" ask)
                 (const :tag "Download pre-built binary" download)
                 (const :tag "Compile from source" compile)
                 (const :tag "Do nothing" nil)))

(defcustom ghostel-shell-integration t
  "Automatically inject shell integration on startup.
When non-nil, ghostel modifies the shell invocation to automatically
load shell integration scripts without requiring changes to the user's
shell configuration files.  Supports bash, zsh, and fish."
  :type 'boolean)

(defcustom ghostel-tramp-shell-integration nil
  "Inject shell integration for remote TRAMP sessions.
When non-nil, ghostel writes integration scripts to a temporary
file on the remote host and configures the shell to source them.
Set to t for all supported shells, or a list of symbols
\(e.g. \\='(bash zsh)) for specific shells only."
  :type '(choice (const :tag "Disabled" nil)
                 (const :tag "All shells" t)
                 (repeat :tag "Specific shells"
                         (choice (const bash) (const zsh) (const fish)))))

(defcustom ghostel-tramp-default-method nil
  "TRAMP method for constructing remote paths from OSC 7 directory reports.
When directory tracking (OSC 7) reports a hostname that does not match
the local machine and `default-directory' has no existing remote prefix,
this method is used to build the TRAMP path (e.g. \"/ssh:host:/path\").
When nil, falls back to `tramp-default-method'."
  :type '(choice (const :tag "Use tramp-default-method" nil)
                 string))

(defcustom ghostel-keymap-exceptions
  '("C-c" "C-x" "C-u" "C-h" "C-g" "M-x" "M-o" "M-:" "C-\\")
  "Key sequences that should not be sent to the terminal.
These keys pass through to Emacs instead."
  :type '(repeat string))

(defcustom ghostel-scroll-on-input t
  "Automatically scroll to the bottom when typing in the terminal.
When non-nil, any character typed while the viewport is scrolled
into the scrollback will first jump to the bottom of the terminal
before sending the input."
  :type 'boolean)

;;; ANSI color faces

(defface ghostel-color-black
  '((t :inherit term-color-black))
  "Face used to render black color code.")

(defface ghostel-color-red
  '((t :inherit term-color-red))
  "Face used to render red color code.")

(defface ghostel-color-green
  '((t :inherit term-color-green))
  "Face used to render green color code.")

(defface ghostel-color-yellow
  '((t :inherit term-color-yellow))
  "Face used to render yellow color code.")

(defface ghostel-color-blue
  '((t :inherit term-color-blue))
  "Face used to render blue color code.")

(defface ghostel-color-magenta
  '((t :inherit term-color-magenta))
  "Face used to render magenta color code.")

(defface ghostel-color-cyan
  '((t :inherit term-color-cyan))
  "Face used to render cyan color code.")

(defface ghostel-color-white
  '((t :inherit term-color-white))
  "Face used to render white color code.")

(defface ghostel-color-bright-black
  `((t :inherit ,(if (facep 'term-color-bright-black)
                     'term-color-bright-black
                   'term-color-black)))
  "Face used to render bright black color code.")

(defface ghostel-color-bright-red
  `((t :inherit ,(if (facep 'term-color-bright-red)
                     'term-color-bright-red
                   'term-color-red)))
  "Face used to render bright red color code.")

(defface ghostel-color-bright-green
  `((t :inherit ,(if (facep 'term-color-bright-green)
                     'term-color-bright-green
                   'term-color-green)))
  "Face used to render bright green color code.")

(defface ghostel-color-bright-yellow
  `((t :inherit ,(if (facep 'term-color-bright-yellow)
                     'term-color-bright-yellow
                   'term-color-yellow)))
  "Face used to render bright yellow color code.")

(defface ghostel-color-bright-blue
  `((t :inherit ,(if (facep 'term-color-bright-blue)
                     'term-color-bright-blue
                   'term-color-blue)))
  "Face used to render bright blue color code.")

(defface ghostel-color-bright-magenta
  `((t :inherit ,(if (facep 'term-color-bright-magenta)
                     'term-color-bright-magenta
                   'term-color-magenta)))
  "Face used to render bright magenta color code.")

(defface ghostel-color-bright-cyan
  `((t :inherit ,(if (facep 'term-color-bright-cyan)
                     'term-color-bright-cyan
                   'term-color-cyan)))
  "Face used to render bright cyan color code.")

(defface ghostel-color-bright-white
  `((t :inherit ,(if (facep 'term-color-bright-white)
                     'term-color-bright-white
                   'term-color-white)))
  "Face used to render bright white color code.")

(defvar ghostel-color-palette
  [ghostel-color-black
   ghostel-color-red
   ghostel-color-green
   ghostel-color-yellow
   ghostel-color-blue
   ghostel-color-magenta
   ghostel-color-cyan
   ghostel-color-white
   ghostel-color-bright-black
   ghostel-color-bright-red
   ghostel-color-bright-green
   ghostel-color-bright-yellow
   ghostel-color-bright-blue
   ghostel-color-bright-magenta
   ghostel-color-bright-cyan
   ghostel-color-bright-white]
  "Color palette for the terminal (vector of 16 face names).")

(defcustom ghostel-github-release-url
  "https://github.com/dakra/ghostel/releases"
  "Base URL for Ghostel GitHub releases.
Customize this when downloading pre-built modules from a fork or mirror."
  :type 'string)

(defconst ghostel--minimum-module-version "0.13.0"
  "Minimum native module version required by this Elisp version.
Bump this only when the Elisp code requires a newer native module
\(e.g. new Zig-exported function or changed calling convention).")


;; Declare native module functions for the byte compiler

(declare-function ghostel--cursor-position "ghostel-module")
(declare-function ghostel--encode-key "ghostel-module")
(declare-function ghostel--focus-event "ghostel-module")
(declare-function ghostel--mode-enabled "ghostel-module")
(declare-function ghostel--copy-all-text "ghostel-module")
(declare-function ghostel--module-version "ghostel-module")
(declare-function ghostel--mouse-event "ghostel-module")
(declare-function ghostel--new "ghostel-module")
(declare-function ghostel--redraw "ghostel-module" (term &optional full))
(declare-function ghostel--scroll-bottom "ghostel-module")
(declare-function ghostel--set-default-colors "ghostel-module")
(declare-function ghostel--set-palette "ghostel-module")
(declare-function ghostel--set-size "ghostel-module")
(declare-function ghostel--write-input "ghostel-module")


;;; Automatic download and compilation of native module

(defun ghostel--module-platform-tag ()
  "Return platform tag for the current system, e.g. \"x86_64-linux\".
Returns nil if the platform is not recognized."
  (let* ((arch (car (split-string system-configuration "-")))
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

(defun ghostel--download-module (dir &optional version latest-release)
  "Download a pre-built module into DIR.
When VERSION is non-nil, download that release tag.
When LATEST-RELEASE is non-nil, use the latest release asset URL.
Returns non-nil on success."
  (condition-case err
      (let* ((requested-version (unless latest-release
                                  (or version ghostel--minimum-module-version)))
             (url (ghostel--module-download-url requested-version)))
        (when url
          (unless (string-prefix-p "https://" url)
            (error "Refusing non-HTTPS download URL: %s" url))
          (let ((dest (expand-file-name
                       (concat "ghostel-module" module-file-suffix) dir)))
            (message "ghostel: downloading native module from %s..." url)
            (when (ghostel--download-file url dest)
              (message "ghostel: native module downloaded successfully")
              t))))
    (error
     (message "ghostel: download failed: %s" (error-message-string err))
     nil)))

(defun ghostel--compile-module (dir)
  "Compile the native module from source in DIR.
Runs synchronously and returns non-nil on success."
  (let ((default-directory dir))
    (message "ghostel: compiling native module with zig build (this may take a moment)...")
    (condition-case err
        (let ((ret (process-file "zig" nil "*ghostel-build*" nil
                                 "build" "-Doptimize=ReleaseFast" "-Dcpu=baseline")))
          (if (eq ret 0)
              (progn (message "ghostel: native module compiled successfully") t)
            (display-warning 'ghostel
                             "Module compilation failed.  See *ghostel-build* buffer for details.")
            nil))
      (file-missing
       (display-warning 'ghostel
                        (format "zig executable not found while compiling in %s" dir))
       nil)
      (error
       (display-warning 'ghostel (error-message-string err))
       nil))))

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
  "Download URL to DEST.  Return non-nil on success."
  (condition-case nil
      (let ((url-request-method "GET")
            (url-show-status nil))
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
                          (write-region start (point-max) dest nil 'silent)
                          (set-file-modes dest #o755)
                          t)))))
              (when (buffer-live-p buf)
                (kill-buffer buf))))))
    (error nil)))

(defun ghostel-download-module (&optional prompt-for-version)
  "Interactively download the pre-built native module for this platform.
With PROMPT-FOR-VERSION, prompt for a release tag to download.
Leaving the prompt empty downloads the latest release."
  (interactive "P")
  (let* ((dir (file-name-directory (or load-file-name
                                       (locate-library "ghostel")
                                       buffer-file-name)))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir))
         (version (when prompt-for-version
                    (ghostel--read-module-download-version)))
         (latest-release (and prompt-for-version (null version))))
    (when (and (file-exists-p mod)
               (not (yes-or-no-p "Module already exists.  Re-download? ")))
      (user-error "Cancelled"))
    (if (ghostel--download-module dir version latest-release)
        (progn
          (module-load mod)
          (message "ghostel: module loaded successfully"))
      (user-error "Download failed.  Try M-x ghostel-module-compile to build from source"))))

(defun ghostel-module-compile ()
  "Compile the ghostel native module by running zig build.
The output is shown in a *ghostel-build* compilation buffer."
  (interactive)
  (let ((default-directory (file-name-directory (or (locate-library "ghostel")
                                                    default-directory))))
    (compile "zig build -Doptimize=ReleaseFast -Dcpu=baseline" t)))


(defun ghostel--check-module-version (dir)
  "Check if the loaded module is older than required.
When the module version is below `ghostel--minimum-module-version',
offer to update using `ghostel-module-auto-install'.
DIR is the module directory."
  (let ((mod-ver (and (fboundp 'ghostel--module-version)
                      (ghostel--module-version))))
    (when (or (null mod-ver)
              (version< mod-ver ghostel--minimum-module-version))
      (display-warning 'ghostel
                       (format "Module version %s is older than required %s"
                               (or mod-ver "unknown")
                               ghostel--minimum-module-version))
      (unless noninteractive
        (ghostel--ensure-module dir)))))

;; Load the native module
(unless (featurep 'ghostel-module)
  (let* ((dir (file-name-directory (or load-file-name buffer-file-name)))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir)))
    (unless (or (file-exists-p mod) noninteractive)
      (ghostel--ensure-module dir))
    (if (file-exists-p mod)
        (condition-case err
            (progn
              (module-load mod)
              (ghostel--check-module-version dir))
          (error
           (display-warning 'ghostel
                            (format "Failed to load native module: %s\nTry M-x ghostel-module-compile to rebuild"
                                    (error-message-string err)))))
      (display-warning 'ghostel
                       (concat "Native module not found: " mod
                               "\nRun M-x ghostel-download-module or M-x ghostel-module-compile")))))

;;; Internal variables

(defvar-local ghostel--term nil
  "Handle to the native terminal instance.")

(defvar-local ghostel--term-rows nil
  "Row count of the native terminal, for viewport/scrollback arithmetic.
Updated whenever the terminal is created or resized.")

(defvar-local ghostel--copy-mode-active nil
  "Non-nil when copy mode is active.")

(defvar-local ghostel--process nil
  "The shell process.")

(defvar-local ghostel--redraw-timer nil
  "Timer for delayed redraw.")

(defvar-local ghostel--force-next-redraw nil
  "When non-nil, redraw regardless of synchronized output mode.")

(defvar-local ghostel--has-wide-chars nil
  "Set by the native renderer when wide characters are present.
Cleared before each redraw; checked afterwards to decide whether
pixel-based trailing-space compensation is needed.")


(defvar-local ghostel--last-send-time nil
  "Time of the last `ghostel--send-key' call, for immediate-redraw detection.")

(defvar-local ghostel--input-buffer nil
  "Accumulated keystrokes waiting to be flushed to the PTY.")

(defvar-local ghostel--input-timer nil
  "Timer for flushing coalesced input.")

(defvar-local ghostel--last-directory nil
  "Last known working directory from OSC 7, used for dedup.")

(defvar-local ghostel--managed-buffer-name nil
  "Last buffer name managed by Ghostel title tracking.
Nil means title tracking has not claimed the buffer yet.  Clearing this
variable re-enables automatic renaming for the next title update.")

(defvar-local ghostel--prompt-positions nil
  "List of prompt positions as (buffer-line . exit-status) pairs.
Used for prompt navigation and optional re-application after full redraws.")

(defvar-local ghostel--scroll-intercept-active nil
  "Non-nil when ghostel's scroll-event intercept is active.
Used as the activation key in `emulation-mode-map-alists'.")



;;; Scroll intercept via emulation-mode-map-alists
;;
;; We need highest-priority interception of wheel events so that terminal
;; mouse tracking (vim, htop, etc.) receives scroll events.  When mouse
;; tracking is off, we fall through to whatever scroll package the user
;; has configured (ultra-scroll, pixel-scroll-precision-mode, etc.).

(defun ghostel--scroll-intercept-up (event)
  "Intercept wheel-up EVENT for terminal mouse tracking.
If the terminal is tracking mouse events, forward as button 4.
Otherwise, re-dispatch EVENT through the normal event loop so the
user's scroll package handles it."
  (interactive "e")
  (unless (ghostel--forward-scroll-event event 4)
    (ghostel--redispatch-scroll-event event)))

(defun ghostel--scroll-intercept-down (event)
  "Intercept wheel-down EVENT for terminal mouse tracking.
If the terminal is tracking mouse events, forward as button 5.
Otherwise, re-dispatch EVENT through the normal event loop so the
user's scroll package handles it."
  (interactive "e")
  (unless (ghostel--forward-scroll-event event 5)
    (ghostel--redispatch-scroll-event event)))

(defun ghostel--redispatch-scroll-event (event)
  "Re-dispatch scroll EVENT through the event loop without our intercept.
Temporarily disables the emulation-map intercept and pushes the event
back as unread input.  The next key-lookup therefore skips our map and
finds the user's scroll handler.  A `pre-command-hook' re-enables the
intercept before that handler runs, so subsequent events are intercepted
again."
  (setq ghostel--scroll-intercept-active nil)
  (push event unread-command-events)
  ;; pre-command-hook fires *after* key lookup but *before* the command,
  ;; so the re-dispatched event is looked up with our intercept disabled
  ;; and the intercept is back on before the next event after that.
  (add-hook 'pre-command-hook #'ghostel--reenable-scroll-intercept nil t))

(defun ghostel--reenable-scroll-intercept ()
  "Re-enable the scroll-event intercept after a re-dispatched event."
  (setq ghostel--scroll-intercept-active t)
  (remove-hook 'pre-command-hook #'ghostel--reenable-scroll-intercept t))

(defvar ghostel--scroll-intercept-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-4]    #'ghostel--scroll-intercept-up)
    (define-key map [mouse-5]    #'ghostel--scroll-intercept-down)
    (define-key map [wheel-up]   #'ghostel--scroll-intercept-up)
    (define-key map [wheel-down] #'ghostel--scroll-intercept-down)
    map)
  "Keymap for `emulation-mode-map-alists' to intercept scroll events.
Active only in ghostel buffers where `ghostel--scroll-intercept-active'
is non-nil.")

(defvar ghostel--emulation-alist
  `((ghostel--scroll-intercept-active . ,ghostel--scroll-intercept-map))
  "Alist for `emulation-mode-map-alists'.")

(unless (memq 'ghostel--emulation-alist emulation-mode-map-alists)
  (push 'ghostel--emulation-alist emulation-mode-map-alists))



;;; Keymap

(defvar ghostel-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Self-insert characters
    (define-key map [remap self-insert-command] #'ghostel--self-insert)
    ;; Special keys — routed through the ghostty key encoder which
    ;; respects terminal modes and handles all modifier combinations.
    ;; Use angle-bracket forms so modifier prefixes compose correctly.
    (dolist (key '("<return>" "<tab>" "<backspace>" "<escape>"
                   "<up>" "<down>" "<right>" "<left>"
                   "<home>" "<end>" "<prior>" "<next>"
                   "<deletechar>" "<insert>"
                   "<f1>" "<f2>" "<f3>" "<f4>" "<f5>" "<f6>"
                   "<f7>" "<f8>" "<f9>" "<f10>" "<f11>" "<f12>"))
      (define-key map (kbd key) #'ghostel--send-event)
      (dolist (mod '("S-" "C-" "M-" "C-S-" "M-S-" "C-M-"))
        (ignore-errors
          (define-key map (kbd (concat mod key)) #'ghostel--send-event))))
    ;; Bare aliases for unmodified keys (RET=\r, TAB=\t, DEL=\x7f)
    (define-key map (kbd "RET") #'ghostel--send-event)
    (define-key map (kbd "TAB") #'ghostel--send-event)
    (define-key map (kbd "DEL") #'ghostel--send-event)
    ;; Emacs reports S-TAB as <backtab>
    (define-key map (kbd "<backtab>") #'ghostel--send-event)
    ;; Control keys — bind all C-<letter> to send ASCII control codes,
    ;; except keys in ghostel-keymap-exceptions and special cases.
    ;; C-i = TAB and C-m = RET are equivalent to <tab>/<return> (bound above).
    (let ((skip '(?i ?m ?y)))  ; i=TAB, m=RET already bound; y=ghostel-yank below
      (dolist (c (number-sequence ?a ?z))
        (let ((key-str (format "C-%c" c)))
          (unless (or (member key-str ghostel-keymap-exceptions)
                      (memq c skip))
            (define-key map (kbd key-str)
                        (let ((code (- c 96)))
                          (lambda () (interactive)
                            (ghostel--send-key (string code)))))))))
    ;; Meta keys — bind all M-<letter> so they reach the terminal
    ;; instead of running Emacs commands like forward-word.
    (dolist (c (number-sequence ?a ?z))
      (let ((key-str (format "M-%c" c)))
        (unless (member key-str ghostel-keymap-exceptions)
          (define-key map (kbd key-str) #'ghostel--send-event))))
    ;; C-@ (NUL, same as C-SPC) — used by programs like Emacs-in-terminal
    (define-key map (kbd "C-@")
                (lambda () (interactive) (ghostel--send-key "\x00")))
    ;; C-y: yank from Emacs kill ring into the terminal
    (define-key map (kbd "C-y")       #'ghostel-yank)
    (when (eq system-type 'darwin)
      (define-key map (kbd "s-v")     #'ghostel-yank))
    (define-key map (kbd "M-y")       #'ghostel-yank-pop)
    ;; Terminal control via C-c prefix (pass through to Emacs, then handled here)
    (define-key map (kbd "C-c C-c")   #'ghostel-send-C-c)
    (define-key map (kbd "C-c C-z")   #'ghostel-send-C-z)
    (define-key map (kbd "C-c C-\\")  #'ghostel-send-C-backslash)
    (define-key map (kbd "C-c C-d")   #'ghostel-send-C-d)
    (define-key map (kbd "C-c C-t")   #'ghostel-copy-mode)
    (define-key map (kbd "C-c M-w")   #'ghostel-copy-all)
    (define-key map (kbd "C-c C-y")   #'ghostel-paste)
    (define-key map (kbd "C-c C-l")   #'ghostel-clear-scrollback)
    (define-key map (kbd "C-c C-q")   #'ghostel-send-next-key)
    ;; Prompt navigation (OSC 133)
    (define-key map (kbd "C-c C-n")   #'ghostel-next-prompt)
    (define-key map (kbd "C-c C-p")   #'ghostel-previous-prompt)
    ;; Mouse click events (for terminal mouse tracking)
    (define-key map (kbd "<down-mouse-1>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-1>")       #'ghostel--mouse-release)
    (define-key map (kbd "<down-mouse-2>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-2>")       #'ghostel--mouse-release)
    (define-key map (kbd "<down-mouse-3>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-3>")       #'ghostel--mouse-release)
    (define-key map (kbd "<drag-mouse-1>")  #'ghostel--mouse-drag)
    (define-key map (kbd "<drag-mouse-2>")  #'ghostel--mouse-drag)
    (define-key map (kbd "<drag-mouse-3>")  #'ghostel--mouse-drag)
    ;; Drag and drop
    (define-key map [drag-n-drop]           #'ghostel--drop)
    map)
  "Keymap for `ghostel-mode'.")


;;; Key sending

(defun ghostel-send-next-key ()
  "Read the next key event and send it to the terminal.
This is an escape hatch for sending keys that are normally
intercepted by Emacs (e.g., interrupt or prefix keys).
Uses `read-event' so that prefix keys return immediately instead
of waiting for a continuation keystroke."
  (interactive)
  (let ((event (read-event "Send key: ")))
    (cond
     ;; Control character (C-@=0, C-a=1 through C-_=31)
     ((and (integerp event) (<= event 31))
      (ghostel--send-key (string event)))
     ;; ASCII (32-127)
     ((and (integerp event) (<= event 127))
      (ghostel--send-key (string event)))
     ;; Non-ASCII character without modifier bits — send as UTF-8
     ((and (integerp event) (< event #x400000))
      (ghostel--send-key (encode-coding-string (string event) 'utf-8)))
     ;; Modified key (M-x, C-M-a, etc.) or function key — use encoder
     (t
      (let* ((base (event-basic-type event))
             (mods (event-modifiers event))
             (key-name (cond
                        ((eq base 'backtab) "tab")
                        ((integerp base)
                         (and (< base 128) (string base)))
                        ((eq base 'deletechar) "delete")
                        ((and base (symbolp base)) (symbol-name base))
                        ((and (null base) (symbolp event))
                         (replace-regexp-in-string
                          "\\`\\(?:[CMSHs]-\\)*" "" (symbol-name event)))
                        (t nil)))
             (mods (if (eq base 'backtab) (cons 'shift mods) mods))
             (mod-str (mapconcat
                       #'identity
                       (delq nil
                             (mapcar
                              (lambda (m)
                                (pcase m
                                  ('shift "shift") ('control "ctrl")
                                  ('meta "meta") ('alt "alt")
                                  ('hyper "hyper") ('super "super")))
                              mods))
                       ",")))
        (if key-name
            (ghostel--send-encoded key-name mod-str)
          (message "ghostel: unrecognized key %S" event)))))))

(defun ghostel--send-key (key)
  "Send KEY string to the terminal process.
Records the send time for immediate-redraw detection and optionally
coalesces rapid keystrokes when `ghostel-input-coalesce-delay' > 0."
  (when (and ghostel--process (process-live-p ghostel--process))
    (setq ghostel--last-send-time (current-time))
    (if (and (> ghostel-input-coalesce-delay 0)
             (= (length key) 1))
        ;; Coalesce single-char keystrokes
        (progn
          (push key ghostel--input-buffer)
          (unless ghostel--input-timer
            (setq ghostel--input-timer
                  (run-with-timer ghostel-input-coalesce-delay nil
                                  #'ghostel--flush-input (current-buffer)))))
      ;; Multi-byte or coalescing disabled: send immediately
      (when ghostel--input-timer
        (cancel-timer ghostel--input-timer)
        (setq ghostel--input-timer nil)
        ;; Flush any buffered input first
        (when ghostel--input-buffer
          (process-send-string ghostel--process
                               (apply #'concat (nreverse ghostel--input-buffer)))
          (setq ghostel--input-buffer nil)))
      (process-send-string ghostel--process key))))

(defun ghostel--flush-input (buffer)
  "Flush coalesced input in BUFFER to the PTY."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ghostel--input-timer nil)
      (when (and ghostel--input-buffer ghostel--process
                 (process-live-p ghostel--process))
        (process-send-string ghostel--process
                             (apply #'concat (nreverse ghostel--input-buffer)))
        (setq ghostel--input-buffer nil)))))

(defun ghostel--send-encoded (key-name mods &optional utf8)
  "Encode KEY-NAME with MODS via the terminal's key encoder and send.
KEY-NAME is a string like \"a\", \"return\", \"up\".
MODS is a string like \"ctrl\", \"shift,ctrl\", or \"\".
UTF8 is optional text generated by the key.
Falls back to raw escape sequences if the encoder doesn't produce output."
  (when ghostel--term
    (if (ghostel--encode-key ghostel--term key-name mods utf8)
        ;; Encoder sent via ghostel--flush-output; record send time for
        ;; immediate-redraw detection (ghostel--flush-output doesn't do this).
        (setq ghostel--last-send-time (current-time))
      (let ((seq (ghostel--raw-key-sequence key-name mods)))
        (when seq (ghostel--send-key seq))))))

(defun ghostel--raw-key-sequence (key-name mods)
  "Build a raw escape sequence for KEY-NAME with MODS.
Returns the sequence string, or nil for unknown keys."
  (let ((mod-num (ghostel--modifier-number mods)))
    (cond
     ;; Ctrl + single letter
     ((and (= (length key-name) 1)
           (<= ?a (aref key-name 0)) (<= (aref key-name 0) ?z)
           (> (logand mod-num 4) 0))        ; ctrl bit
      (string (- (aref key-name 0) 96)))    ; ctrl-a=1, ctrl-z=26
     ;; Meta + single letter → ESC + char
     ((and (= (length key-name) 1)
           (<= ?a (aref key-name 0)) (<= (aref key-name 0) ?z)
           (> (logand mod-num 2) 0))        ; alt/meta bit
      (format "\e%c" (aref key-name 0)))
     ;; Simple special keys (CSI u encoding for modified variants)
     ((string= key-name "backspace") (if (> mod-num 0) (format "\e[127;%du" (1+ mod-num)) "\x7f"))
     ((string= key-name "return")    (if (> mod-num 0) (format "\e[13;%du" (1+ mod-num)) "\r"))
     ((string= key-name "tab")       (if (> mod-num 0) (format "\e[9;%du" (1+ mod-num)) "\t"))
     ((string= key-name "escape")    (if (> mod-num 0) (format "\e[27;%du" (1+ mod-num)) "\e"))
     ((string= key-name "space")     (if (> mod-num 0) (format "\e[32;%du" (1+ mod-num)) " "))
     ;; Cursor keys
     ((string= key-name "up")    (ghostel--csi-letter "A" mod-num))
     ((string= key-name "down")  (ghostel--csi-letter "B" mod-num))
     ((string= key-name "right") (ghostel--csi-letter "C" mod-num))
     ((string= key-name "left")  (ghostel--csi-letter "D" mod-num))
     ((string= key-name "home")  (ghostel--csi-letter "H" mod-num))
     ((string= key-name "end")   (ghostel--csi-letter "F" mod-num))
     ;; Tilde keys
     ((string= key-name "insert") (ghostel--csi-tilde 2 mod-num))
     ((string= key-name "delete") (ghostel--csi-tilde 3 mod-num))
     ((string= key-name "prior")  (ghostel--csi-tilde 5 mod-num))
     ((string= key-name "next")   (ghostel--csi-tilde 6 mod-num))
     ;; Function keys (F1-F4 use SS3, F5-F12 use tilde)
     ((string= key-name "f1")  (if (> mod-num 0) (format "\e[1;%dP" (1+ mod-num)) "\eOP"))
     ((string= key-name "f2")  (if (> mod-num 0) (format "\e[1;%dQ" (1+ mod-num)) "\eOQ"))
     ((string= key-name "f3")  (if (> mod-num 0) (format "\e[1;%dR" (1+ mod-num)) "\eOR"))
     ((string= key-name "f4")  (if (> mod-num 0) (format "\e[1;%dS" (1+ mod-num)) "\eOS"))
     ((string= key-name "f5")  (ghostel--csi-tilde 15 mod-num))
     ((string= key-name "f6")  (ghostel--csi-tilde 17 mod-num))
     ((string= key-name "f7")  (ghostel--csi-tilde 18 mod-num))
     ((string= key-name "f8")  (ghostel--csi-tilde 19 mod-num))
     ((string= key-name "f9")  (ghostel--csi-tilde 20 mod-num))
     ((string= key-name "f10") (ghostel--csi-tilde 21 mod-num))
     ((string= key-name "f11") (ghostel--csi-tilde 23 mod-num))
     ((string= key-name "f12") (ghostel--csi-tilde 24 mod-num))
     (t nil))))

(defun ghostel--modifier-number (mods)
  "Convert MODS string to a bitmask: shift=1, alt=2, ctrl=4."
  (let ((n 0))
    (when (string-match-p "shift" mods) (setq n (logior n 1)))
    (when (string-match-p "alt\\|meta" mods) (setq n (logior n 2)))
    (when (string-match-p "ctrl\\|control" mods) (setq n (logior n 4)))
    n))

(defun ghostel--csi-letter (letter mod-num)
  "Format CSI cursor-key sequence for LETTER with MOD-NUM modifier."
  (if (> mod-num 0)
      (format "\e[1;%d%s" (1+ mod-num) letter)
    (format "\e[%s" letter)))

(defun ghostel--csi-tilde (param mod-num)
  "Format CSI tilde sequence for PARAM with MOD-NUM modifier."
  (if (> mod-num 0)
      (format "\e[%d;%d~" param (1+ mod-num))
    (format "\e[%d~" param)))

(defun ghostel--self-insert ()
  "Send the last typed character to the terminal."
  (interactive)
  (when (and ghostel-scroll-on-input ghostel--term)
    (ghostel--scroll-bottom ghostel--term)
    (setq ghostel--force-next-redraw t))
  (let* ((keys (this-command-keys))
         (char (aref keys (1- (length keys))))
         (str (if (and (characterp char) (< char 128))
                  (string char)
                (encode-coding-string (string char) 'utf-8))))
    (ghostel--send-key str)))

(defun ghostel--send-event ()
  "Send the current key event to the terminal via the key encoder.
Extracts the base key name and modifiers from `last-command-event'
and routes through the ghostty key encoder, which respects terminal
modes (application cursor keys, Kitty keyboard protocol, etc.)."
  (interactive)
  (when (and ghostel-scroll-on-input ghostel--term)
    (ghostel--scroll-bottom ghostel--term)
    (setq ghostel--force-next-redraw t))
  (let* ((event last-command-event)
         (base (event-basic-type event))
         (mods (event-modifiers event))
         (key-name (cond
                    ;; backtab is Emacs's name for S-TAB
                    ((eq base 'backtab) "tab")
                    ;; Integer base (character key)
                    ((integerp base)
                     (and (< base 128) (string base)))
                    ((eq base 'deletechar) "delete")
                    ;; Normal function key symbol
                    ((and base (symbolp base)) (symbol-name base))
                    ;; Modified return/tab/backspace/escape: event-basic-type
                    ;; returns nil but modifiers are extracted correctly.
                    ;; Strip modifier prefixes from the symbol name.
                    ((and (null base) (symbolp event))
                     (replace-regexp-in-string
                      "\\`\\(?:[CMSHs]-\\)*" "" (symbol-name event)))
                    (t nil)))
         ;; backtab needs shift added back since it's baked into the name
         (mods (if (eq base 'backtab) (cons 'shift mods) mods))
         (mod-str (mapconcat
                   (lambda (m)
                     (pcase m
                       ('shift "shift") ('control "ctrl")
                       ('meta "meta") ('hyper "hyper")
                       ('super "super") (_ nil)))
                   mods ",")))
    (when key-name
      (ghostel--send-encoded key-name mod-str))))


;;; Terminal control commands (C-c prefix)

(defun ghostel-send-C-c ()
  "Send interrupt signal to the terminal."
  (interactive)
  (ghostel--send-encoded "c" "ctrl"))

(defun ghostel-send-C-z ()
  "Send suspend signal to the terminal."
  (interactive)
  (ghostel--send-encoded "z" "ctrl"))

(defun ghostel-send-C-backslash ()
  "Send C-\\ (quit) to the terminal."
  (interactive)
  (ghostel--send-key "\x1c"))

(defun ghostel-send-C-d ()
  "Send EOF to the terminal."
  (interactive)
  (ghostel--send-encoded "d" "ctrl"))


;;; Paste / yank

(defvar-local ghostel--yank-index 0
  "Current kill ring index for `ghostel-yank-pop'.")

(defun ghostel--bracketed-paste-p ()
  "Return non-nil if the terminal has bracketed paste mode (2004) enabled."
  (and ghostel--term
       (ghostel--mode-enabled ghostel--term 2004)))

(defun ghostel--paste-text (text)
  "Send TEXT to the terminal, using bracketed paste if the terminal wants it."
  (when (and text ghostel--process (process-live-p ghostel--process))
    (process-send-string ghostel--process
                         (if (ghostel--bracketed-paste-p)
                             (concat "\e[200~" text "\e[201~")
                           text))))

(defun ghostel-paste ()
  "Paste text from the Emacs kill ring into the terminal.
Uses bracketed paste mode so that shells can distinguish
pasted text from typed input."
  (interactive)
  (ghostel--paste-text (current-kill 0)))

(defun ghostel-yank ()
  "Yank the most recent kill into the terminal.
Use `ghostel-yank-pop' afterwards to cycle through older kills."
  (interactive)
  (setq ghostel--yank-index 0)
  (ghostel--paste-text (current-kill 0))
  (setq this-command 'ghostel-yank))

(defun ghostel-yank-pop ()
  "Replace the just-yanked text with the next kill ring entry.
Must be called after `ghostel-yank' or `ghostel-yank-pop'.
Sends backspaces to erase the previous yank, then pastes the next entry."
  (interactive)
  (unless (memq last-command '(ghostel-yank ghostel-yank-pop))
    (user-error "Previous command was not a yank"))
  (let* ((prev-text (current-kill ghostel--yank-index t))
         (prev-len (length prev-text)))
    (setq ghostel--yank-index (1+ ghostel--yank-index))
    ;; Erase previous paste: send backspaces
    (when (and ghostel--process (process-live-p ghostel--process))
      (process-send-string ghostel--process
                           (make-string prev-len ?\x7f)))
    ;; Paste the next entry
    (ghostel--paste-text (current-kill ghostel--yank-index t))
    (setq this-command 'ghostel-yank-pop)))


;;; Drag and drop

(defun ghostel--drop (event)
  "Handle a drag-and-drop EVENT into the terminal.
Dropped files insert their path (shell-quoted); dropped text is
pasted using bracketed paste."
  (interactive "e")
  (when (and ghostel--process (process-live-p ghostel--process))
    ;; On macOS (NS port) the event structure is:
    ;;   (drag-n-drop POSN (TYPE OPERATIONS . OBJECTS))
    ;; where (nth 2 event) carries the drop data, not the position.
    (let ((arg (nth 2 event)))
      (when (and arg (not (eq arg 'lambda)))
        (let ((type (car arg))
              (objects (cddr arg)))
          (if (eq type 'file)
              (ghostel--send-key
               (mapconcat #'shell-quote-argument objects " "))
            (ghostel--paste-text
             (mapconcat #'identity objects "\n"))))))))


;;; Scrollback / clearing

(defun ghostel-clear-scrollback ()
  "Clear the screen and scrollback buffer."
  (interactive)
  (when ghostel--term
    ;; Flush pending process output first so it doesn't recreate
    ;; scrollback after the clear.
    (ghostel--flush-pending-output)
    ;; CSI H = home, CSI 2 J = erase screen, CSI 3 J = erase scrollback.
    (ghostel--write-input ghostel--term "\e[H\e[2J\e[3J")
    (ghostel--scroll-bottom ghostel--term)
    (setq ghostel--force-next-redraw t)
    (ghostel--invalidate)
    ;; Send form-feed to the shell so it redraws its prompt.
    (when (and ghostel--process (process-live-p ghostel--process))
      (process-send-string ghostel--process "\f"))))

(defun ghostel-clear ()
  "Clear the visible screen, preserving scrollback history."
  (interactive)
  (when ghostel--term
    ;; Flush pending process output first so it renders before the clear.
    (ghostel--flush-pending-output)
    (ghostel--write-input ghostel--term "\e[H\e[2J")
    (setq ghostel--force-next-redraw t)
    (ghostel--invalidate)
    ;; Send form-feed to the shell so it redraws its prompt.
    (when (and ghostel--process (process-live-p ghostel--process))
      (process-send-string ghostel--process "\f"))))

(defun ghostel--forward-scroll-event (event button)
  "Try to forward a scroll EVENT as mouse BUTTON to the terminal.
Return non-nil if the event was forwarded (mouse tracking is active)."
  (when (and event ghostel--term ghostel--process
             (process-live-p ghostel--process)
             (not ghostel--copy-mode-active))
    (let* ((posn (event-start event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            0  ; press
                            button
                            row col
                            (ghostel--mouse-mods event)))))


(defun ghostel-copy-mode-previous-line ()
  "Move to the previous line in copy mode."
  (interactive)
  (let ((col (current-column)))
    (forward-line -1)
    (move-to-column col)))

(defun ghostel-copy-mode-next-line ()
  "Move to the next line in copy mode."
  (interactive)
  (let ((col (current-column)))
    (forward-line 1)
    (move-to-column col)))

(defun ghostel-copy-mode-beginning-of-buffer ()
  "Move to the top of the buffer (oldest scrollback) in copy mode."
  (interactive)
  (goto-char (point-min)))

(defun ghostel-copy-mode-end-of-buffer ()
  "Move to the bottom of the buffer (current viewport) in copy mode."
  (interactive)
  (goto-char (point-max))
  (skip-chars-backward " \t\n"))

(defun ghostel-copy-mode-end-of-line ()
  "Move to the last non-whitespace character on the line."
  (interactive)
  (end-of-line)
  (skip-chars-backward " \t"))

(defun ghostel-copy-mode-recenter ()
  "Recenter the current line in the window."
  (interactive)
  (recenter))


;;; Mouse input

(defun ghostel--mouse-button-number (event)
  "Return the ghostty mouse button number for EVENT."
  (pcase (event-basic-type event)
    ('mouse-1 1)
    ('mouse-2 3)
    ('mouse-3 2)
    (_ 0)))

(defun ghostel--mouse-mods (event)
  "Return ghostty modifier bitmask for mouse EVENT."
  (let ((mods (event-modifiers event))
        (result 0))
    (when (memq 'shift mods) (setq result (logior result 1)))
    (when (memq 'control mods) (setq result (logior result 4)))
    (when (memq 'meta mods) (setq result (logior result 2)))
    result))

(defun ghostel--mouse-press (event)
  "Handle mouse button press EVENT for terminal mouse tracking."
  (interactive "e")
  (select-window (posn-window (event-start event)))
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-start event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            0  ; press
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))

(defun ghostel--mouse-release (event)
  "Handle mouse button release EVENT for terminal mouse tracking."
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-end event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            1  ; release
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))

(defun ghostel--mouse-drag (event)
  "Handle mouse drag EVENT as motion for terminal mouse tracking."
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-end event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            2  ; motion
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))


;;; Copy mode

(defvar ghostel-copy-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Normal letter keys exit copy mode and send the key to the terminal
    (define-key map [remap self-insert-command] #'ghostel-copy-mode-exit-and-send)
    (define-key map (kbd "C-c C-t") #'ghostel-copy-mode-exit)
    (define-key map (kbd "M-w") #'ghostel-copy-mode-copy)
    (define-key map (kbd "C-w") #'ghostel-copy-mode-copy)
    ;; Prompt navigation works in copy mode too
    (define-key map (kbd "C-c C-n") #'ghostel-next-prompt)
    (define-key map (kbd "C-c C-p") #'ghostel-previous-prompt)
    (define-key map (kbd "C-n")             #'ghostel-copy-mode-next-line)
    (define-key map (kbd "C-p")             #'ghostel-copy-mode-previous-line)
    (define-key map (kbd "M-<")             #'ghostel-copy-mode-beginning-of-buffer)
    (define-key map (kbd "M->")             #'ghostel-copy-mode-end-of-buffer)
    (define-key map (kbd "C-e")             #'ghostel-copy-mode-end-of-line)
    (define-key map (kbd "C-l")             #'ghostel-copy-mode-recenter)
    (define-key map (kbd "C-c C-l")         #'ghostel-copy-mode-exit-and-clear)
    map)
  "Keymap for `ghostel-copy-mode'.
Standard Emacs navigation works.
Set mark, navigate to select, then \\[ghostel-copy-mode-copy] to copy.")

(defvar-local ghostel--saved-local-map nil
  "Saved keymap before entering copy mode.")

(defvar-local ghostel--saved-cursor-type nil
  "Saved `cursor-type' before entering copy mode.")

(defvar-local ghostel--saved-hl-line-mode nil
  "Non-nil if line highlighting was active when `ghostel-mode' suppressed it.
Covers both `global-hl-line-mode' and buffer-local `hl-line-mode'.")

(defun ghostel-copy-mode ()
  "Enter copy mode for selecting and copying terminal text.
Live terminal output is paused; standard Emacs navigation, search,
and marking work across the full scrollback that is already rendered
in the buffer.  Press \\`q' or \\[ghostel-copy-mode-exit] to exit."
  (interactive)
  (if ghostel--copy-mode-active
      (ghostel-copy-mode-exit)
    (setq ghostel--copy-mode-active t)
    (when ghostel--redraw-timer
      (cancel-timer ghostel--redraw-timer)
      (setq ghostel--redraw-timer nil))
    ;; Ensure cursor is visible for navigation
    (setq ghostel--saved-cursor-type cursor-type)
    (setq cursor-type (default-value 'cursor-type))
    (setq ghostel--saved-local-map (current-local-map))
    (use-local-map ghostel-copy-mode-map)
    (when ghostel--saved-hl-line-mode
      (hl-line-mode 1))
    (setq buffer-read-only t)
    (setq mode-line-process ":Copy")
    (force-mode-line-update)
    (message "Copy mode: C-SPC to mark, navigate to select, M-w to copy, q to exit")))

(defun ghostel-copy-mode-exit ()
  "Exit copy mode and return to terminal mode."
  (interactive)
  (when ghostel--copy-mode-active
    (setq ghostel--copy-mode-active nil)
    (setq cursor-type ghostel--saved-cursor-type)
    (deactivate-mark)
    (use-local-map ghostel--saved-local-map)
    (when ghostel--saved-hl-line-mode
      (hl-line-mode -1))
    (setq buffer-read-only nil)
    (setq mode-line-process nil)
    (force-mode-line-update)
    ;; Jump out of any scrollback position so the redraw is allowed to
    ;; position point at the terminal cursor (otherwise
    ;; `ghostel--delayed-redraw' would preserve our scrollback marker).
    (goto-char (point-max))
    (ghostel--invalidate)
    (message "Copy mode exited")))

(defun ghostel-copy-mode-exit-and-clear ()
  "Exit copy mode and clear the scrollback."
  (interactive)
  (ghostel-copy-mode-exit)
  (ghostel-clear-scrollback))

(defun ghostel-copy-mode-exit-and-send ()
  "Exit copy mode and send the key that triggered exit to the terminal."
  (interactive)
  (ghostel-copy-mode-exit)
  (when ghostel--term
    (ghostel--self-insert)))

(defun ghostel--filter-soft-wraps (text)
  "Remove newlines from TEXT that were inserted by soft line wrapping.
These are newlines with the `ghostel-wrap' text property."
  (let ((result "")
        (pos 0)
        (len (length text)))
    (while (< pos len)
      (if (and (eq (aref text pos) ?\n)
               (get-text-property pos 'ghostel-wrap text))
          (setq pos (1+ pos))
        (setq result (concat result (substring text pos (1+ pos)))
              pos (1+ pos))))
    result))

(defun ghostel--clean-copy-text (text)
  "Clean TEXT for copying: remove soft-wrap newlines, strip trailing whitespace."
  (let* ((unwrapped (ghostel--filter-soft-wraps text))
         (lines (split-string unwrapped "\n"))
         (trimmed (mapcar (lambda (line) (string-trim-right line)) lines)))
    (mapconcat #'identity trimmed "\n")))

(defun ghostel-copy-mode-copy ()
  "Copy the selected region and exit copy mode.
Soft-wrapped newlines are removed and trailing whitespace is
stripped so the copied text matches the original terminal content."
  (interactive)
  (when (use-region-p)
    (let ((text (ghostel--clean-copy-text
                 (buffer-substring (region-beginning) (region-end)))))
      (kill-new text)
      (message "Copied to kill ring")))
  (ghostel-copy-mode-exit))

(defun ghostel-copy-all ()
  "Copy the entire scrollback buffer to the kill ring."
  (interactive)
  (when ghostel--term
    (let ((text (ghostel--copy-all-text ghostel--term)))
      (when (and text (> (length text) 0))
        (kill-new text)
        (message "Copied %d characters to kill ring" (length text))))))


;;; Hyperlinks (OSC 8)

(defvar ghostel-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'ghostel-open-link-at-click)
    (define-key map [mouse-2] #'ghostel-open-link-at-click)
    (define-key map (kbd "RET") #'ghostel-open-link-at-point)
    map)
  "Keymap for clickable hyperlinks in ghostel buffers.")

(defun ghostel--open-link (url)
  "Open URL, dispatching by scheme.
file:// URIs open in Emacs; http(s) and other schemes use `browse-url'.
fileref: URIs (from auto-detected file:line patterns) open the file
at the given line in another window."
  (when (and url (stringp url))
    (cond
     ((string-match "\\`fileref:\\(.*\\):\\([0-9]+\\)\\'" url)
      (let ((file (match-string 1 url))
            (line (string-to-number (match-string 2 url))))
        (when (file-exists-p file)
          (find-file-other-window file)
          (goto-char (point-min))
          (forward-line (1- line)))))
     ((string-match "\\`file://\\(?:localhost\\)?\\(/.*\\)" url)
      (find-file (url-unhex-string (match-string 1 url))))
     ((string-match-p "\\`[a-z]+://" url)
      (browse-url url)))))

(defun ghostel-open-link-at-click (event)
  "Open the hyperlink at the mouse click EVENT position."
  (interactive "e")
  (ghostel--open-link
   (get-text-property (posn-point (event-start event)) 'help-echo)))

(defun ghostel-open-link-at-point ()
  "Open the hyperlink at point."
  (interactive)
  (ghostel--open-link (get-text-property (point) 'help-echo)))

(defun ghostel--detect-urls (&optional begin end)
  "Scan a buffer region for plain-text URLs and file:line references.
BEGIN and END default to `point-min' and `point-max' respectively.
Skips regions that already have a `help-echo' property (e.g. from OSC 8).
Bounding the scan keeps streaming output from re-scanning the entire
materialized scrollback on every redraw."
  (let ((begin (or begin (point-min)))
        (end (or end (point-max))))
    (save-excursion
      ;; Pass 1: http(s) URLs
      (when ghostel-enable-url-detection
        (goto-char begin)
        (while (re-search-forward
                "https?://[^ \t\n\r\"<>]*[^ \t\n\r\"<>.,;:!?)>]"
                end t)
          (let ((beg (match-beginning 0))
                (mend (match-end 0)))
            (unless (get-text-property beg 'help-echo)
              (let ((url (match-string-no-properties 0)))
                (put-text-property beg mend 'help-echo url)
                (put-text-property beg mend 'mouse-face 'highlight)
                (put-text-property beg mend 'keymap ghostel-link-map))))))
      ;; Pass 2: file:line references (e.g. "./foo.el:42" or "/tmp/bar.rs:10")
      (when ghostel-enable-file-detection
        (goto-char begin)
        (while (re-search-forward
                "\\(?:\\./\\|/\\)[^ \t\n\r:\"<>]+:[0-9]+"
                end t)
          (let ((beg (match-beginning 0))
                (mend (match-end 0)))
            (unless (get-text-property beg 'help-echo)
              (let* ((text (match-string-no-properties 0))
                     (sep (string-match ":[0-9]+\\'" text))
                     (path (substring text 0 sep))
                     (line (substring text (1+ sep)))
                     (abs-path (expand-file-name path)))
                (when (file-exists-p abs-path)
                  (put-text-property beg mend 'help-echo
                                     (concat "fileref:" abs-path ":" line))
                  (put-text-property beg mend 'mouse-face 'highlight)
                  (put-text-property beg mend 'keymap ghostel-link-map))))))))))


(defun ghostel--compensate-wide-chars ()
  "Shrink trailing spaces on lines where wide-char glyphs cause pixel overflow.
Emoji glyphs often render wider than `char-width' times `frame-char-width'
pixels, making the display engine treat the line as wider than the window
even though `string-width' equals the terminal column count.  For each
overflowing line we replace the trailing whitespace with a single stretch
glyph of exactly the remaining pixel width."
  (let ((win (get-buffer-window)))
    (when (and win (display-graphic-p))
      (let ((win-w (window-body-width win t))
            (inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((bol (line-beginning-position))
                   (eol (line-end-position))
                   (spaces-start (save-excursion
                                   (goto-char eol)
                                   (skip-chars-backward " " bol)
                                   (point)))
                   (avail (- eol spaces-start)))
              (when (> avail 0)
                ;; Strip stale compensation so pixel measurement is accurate.
                (remove-text-properties spaces-start eol '(display nil))
                (let* ((content-pw (car (window-text-pixel-size win bol spaces-start)))
                       (remaining (max 0 (- win-w content-pw)))
                       (natural-pw (* avail (frame-char-width (window-frame win)))))
                  ;; Only compensate when we would shrink the trailing spaces;
                  ;; never widen them as that could introduce truncation on
                  ;; lines that fit naturally.
                  (when (< remaining natural-pw)
                    (put-text-property spaces-start eol 'display
                                       `(space :width (,remaining)))))))
            (forward-line 1)))))))


;;; Prompt navigation (OSC 133)

(defun ghostel--osc133-marker (type param)
  "Handle an OSC 133 semantic prompt marker from the Zig module.
TYPE is a single character string: A, B, C, or D.
PARAM is the exit status string for type D, or nil.
Note: the `ghostel-prompt' text property is applied by the native
render loop (which queries libghostty's per-row semantic state),
not here.  This handler only tracks prompt positions and exit status."
  (pcase type
    ("A"
     ;; Prompt start — record line number.
     (push (cons (count-lines (point-min) (point-max)) nil)
           ghostel--prompt-positions))
    ("D"
     ;; Command finished — store exit status on the most recent entry.
     (when (and ghostel--prompt-positions param)
       (setcdr (car ghostel--prompt-positions)
               (string-to-number param))))))

(defun ghostel--prompt-input-start ()
  "From the start of a prompt line, move past the prompt marker to user input.
Skips to end of line, then backs up past trailing whitespace to find
the last non-whitespace+whitespace boundary (e.g. after `$ ' or `# ')."
  (let ((bol (point)))
    (end-of-line)
    (skip-chars-backward " \t" bol)       ; skip trailing padding
    (skip-chars-backward "^ \t" bol)      ; skip last word (user input)
    (when (> (point) bol)
      (skip-chars-backward " \t" bol)     ; skip space before user input
      (skip-chars-forward " \t"           ; move forward past that space
                          (line-end-position)))
    ;; If we landed on the last visible char (no command follows),
    ;; step past it and the trailing space (e.g. "# " → past both).
    (when (looking-at-p "\\S-\\s-*$")
      (forward-char 2))))

(defun ghostel--navigate-next-prompt (&optional n)
  "Move point to the start of the Nth next prompt region."
  (let ((pos (point)))
    (dotimes (_ (or n 1))
      ;; First skip past the current prompt region if we're inside one.
      (let ((next (next-single-property-change pos 'ghostel-prompt)))
        (when next
          (if (get-text-property next 'ghostel-prompt)
              ;; Landed on the next prompt.
              (setq pos next)
            ;; In a gap — find the next prompt, or stay put.
            (let ((found (next-single-property-change next 'ghostel-prompt)))
              (when found
                (setq pos found)))))))
    (when (and pos (/= pos (point)))
      (goto-char pos)
      (ghostel--prompt-input-start))))

(defun ghostel--navigate-previous-prompt (&optional n)
  "Move point to the start of the Nth previous prompt region."
  (let ((pos (point)))
    (dotimes (_ (or n 1))
      ;; If inside a prompt, first skip backward past it.
      (when (or (get-text-property pos 'ghostel-prompt)
                (and (= pos (point-max))
                     (> pos (point-min))
                     (get-text-property (1- pos) 'ghostel-prompt)))
        (setq pos (or (previous-single-property-change pos 'ghostel-prompt)
                      (point-min))))
      ;; Now search backward for the previous prompt.
      (let ((prev (previous-single-property-change pos 'ghostel-prompt)))
        (cond
         (prev
          (setq pos prev)
          ;; If we landed at the end of a prompt, step to its start.
          (when (get-text-property (max (1- pos) (point-min)) 'ghostel-prompt)
            (setq pos (or (previous-single-property-change pos 'ghostel-prompt)
                          (point-min)))))
         ;; No property change before pos, but a prompt may start at point-min.
         ((and (> pos (point-min))
               (get-text-property (point-min) 'ghostel-prompt))
          (setq pos (point-min))))))
    (when (and pos (/= pos (point)))
      (goto-char pos)
      (ghostel--prompt-input-start))))

(defun ghostel-next-prompt (&optional n)
  "Enter copy mode and move to the Nth next prompt."
  (interactive "p")
  (unless ghostel--copy-mode-active
    (ghostel-copy-mode))
  (ghostel--navigate-next-prompt n))

(defun ghostel-previous-prompt (&optional n)
  "Enter copy mode and move to the Nth previous prompt."
  (interactive "p")
  (unless ghostel--copy-mode-active
    (ghostel-copy-mode))
  (ghostel--navigate-previous-prompt n))


;;; Callbacks from native module

(defun ghostel--osc51-eval (str)
  "Handle an OSC 51;E command from the terminal.
STR is the payload after the E sub-command.
Parses the command and arguments, looks up the command in
`ghostel-eval-cmds', and calls it if whitelisted."
  (let* ((parts (split-string-and-unquote str))
         (command (car parts))
         (args (cdr parts))
         (entry (assoc command ghostel-eval-cmds)))
    (if entry
        ;; Catch errors from the dispatched function: this callback runs
        ;; synchronously inside the native VT parser, so any unhandled
        ;; error propagates back up through `ghostel--write-input' and
        ;; crashes the process filter / redraw timer.
        (condition-case err
            (apply (cadr entry) args)
          (error
           (message "ghostel: error calling %s: %s"
                    command (error-message-string err))))
      (message "ghostel: unknown eval command %S (add to `ghostel-eval-cmds' to allow)"
               command))))

(defun ghostel--osc52-handle (_selection base64-data)
  "Handle an OSC 52 clipboard set request.
SELECTION is the target (e.g. \"c\" for clipboard).
BASE64-DATA is the base64-encoded text.
Only acts when `ghostel-enable-osc52' is non-nil."
  (when ghostel-enable-osc52
    (let ((text (ignore-errors (base64-decode-string base64-data))))
      (when (and text (> (length text) 0))
        (kill-new text)
        (when (fboundp 'gui-set-selection)
          (gui-set-selection 'CLIPBOARD text))))))

(defun ghostel--flush-output (data)
  "Write DATA back to the shell process (response from terminal)."
  (when (and ghostel--process (process-live-p ghostel--process))
    (process-send-string ghostel--process data)))

(defvar-local ghostel--face-cookie nil
  "Cookie from `face-remap-add-relative' for the terminal default face.")

(defun ghostel--set-buffer-face (fg bg)
  "Set the buffer's default face to FG foreground and BG background.
This ensures terminal text is visible regardless of the Emacs theme."
  (when ghostel--face-cookie
    (face-remap-remove-relative ghostel--face-cookie))
  (setq ghostel--face-cookie
        (face-remap-add-relative 'default
                                 :foreground fg
                                 :background bg)))

(defun ghostel--set-title (title)
  "Update the buffer name with TITLE from the terminal.
Only acts when `ghostel-enable-title-tracking' is non-nil and the
buffer has not been manually renamed by the user."
  (when (and ghostel-enable-title-tracking
             (or (null ghostel--managed-buffer-name)
                 (equal (buffer-name) ghostel--managed-buffer-name)))
    (let ((new-name (format "*ghostel: %s*" title)))
      (rename-buffer new-name t)
      ;; Keep the actual name because `rename-buffer' may uniquify it.
      (setq ghostel--managed-buffer-name (buffer-name)))))

(defun ghostel--set-cursor-style (style visible)
  "Set the cursor style based on terminal state.
STYLE is one of: 0=bar, 1=block, 2=underline, 3=hollow-block.
VISIBLE is t or nil.
Skipped when copy mode is active because copy mode manages its own cursor."
  (unless ghostel--copy-mode-active
    (setq cursor-type
          (if visible
              (pcase style
                (0 '(bar . 2))       ; bar
                (1 'box)             ; block
                (2 '(hbar . 2))      ; underline
                (3 'hollow)          ; hollow block
                (_ 'box))
            nil))))

(defun ghostel--update-directory (dir)
  "Update `default-directory' from terminal's OSC 7 report.
DIR may be a file:// URL or a plain path.  When the hostname in a
file:// URL does not match the local machine, construct a TRAMP path."
  (when (and dir (not (equal dir ghostel--last-directory)))
    (setq ghostel--last-directory dir)
    (let (path)
      (if (string-prefix-p "file://" dir)
          (let* ((url (url-generic-parse-url dir))
                 (host (url-host url))
                 (filename (url-filename url)))
            (if (ghostel--local-host-p host)
                (setq path filename)
              ;; Remote host — construct a TRAMP path.
              ;; Reuse the full remote prefix from default-directory
              ;; when available (preserves multi-hop, method, user).
              (let ((prefix (file-remote-p default-directory)))
                (setq path (if prefix
                               (concat prefix filename)
                             (format "/%s:%s:%s"
                                     (or ghostel-tramp-default-method
                                         tramp-default-method)
                                     host filename))))))
        (setq path dir))
      (when (and path (not (string= path "")))
        (if (file-remote-p path)
            ;; Trust the shell's report; skip file-directory-p to avoid
            ;; synchronous TRAMP connections on every cd.
            (setq default-directory (file-name-as-directory path))
          (when (file-directory-p path)
            (setq default-directory (file-name-as-directory path))))))))


;;; Palette

(defun ghostel--face-hex-color (face attr)
  "Extract hex color string from FACE's ATTR (:foreground or :background).
Falls back to \"#000000\" if the color cannot be resolved."
  (or (let ((color (face-attribute face attr nil 'default)))
        (when (and (stringp color) (not (string= color "unspecified")))
          (let ((rgb (color-values color)))
            (if rgb
                (apply #'format "#%02x%02x%02x"
                       (mapcar (lambda (c) (ash c -8)) rgb))
              ;; Batch mode: color-values returns nil without a display.
              ;; If the color is already "#RRGGBB", use it directly.
              (and (string-prefix-p "#" color) (= (length color) 7)
                   color)))))
      "#000000"))

(defun ghostel--apply-palette (term)
  "Apply colors from `ghostel-color-palette' faces and default fg/bg to TERM."
  (when term
    (ghostel--set-default-colors
     term
     (ghostel--face-hex-color 'default :foreground)
     (ghostel--face-hex-color 'default :background))
    (when ghostel-color-palette
      (let ((colors
             (mapconcat
              (lambda (face)
                (ghostel--face-hex-color face :foreground))
              ghostel-color-palette
              "")))
        (ghostel--set-palette term colors)))))


;;; Theme synchronization

(defun ghostel-sync-theme ()
  "Re-apply terminal color palette in all ghostel buffers.
Call this after changing the Emacs theme so terminals match."
  (interactive)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'ghostel-mode) ghostel--term)
        (ghostel--apply-palette ghostel--term)
        (when (not ghostel--copy-mode-active)
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term)))))))

(defun ghostel--on-theme-change (&rest _args)
  "Hook function to sync terminal colors after theme change."
  (ghostel-sync-theme))

(if (boundp 'enable-theme-functions)
    ;; Emacs 29+
    (add-hook 'enable-theme-functions #'ghostel--on-theme-change)
  ;; Emacs < 29 fallback
  (advice-add 'load-theme :after #'ghostel--on-theme-change))


;;; Focus events

(defun ghostel--focus-change ()
  "Notify ghostel terminals in the selected frame about focus change.
Only send the event if the terminal has enabled focus reporting (mode 1004)."
  (let ((focused (frame-focus-state)))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (derived-mode-p 'ghostel-mode)
                   ghostel--term
                   ghostel--process
                   (process-live-p ghostel--process))
          (ghostel--focus-event ghostel--term focused))))))

(defvar-local ghostel--pending-output nil
  "Accumulated output chunks waiting to be fed to the terminal.
When non-nil, a list of unibyte strings (in reverse order) that
will be concatenated and passed to `ghostel--write-input' at the
next redraw.  Batching writes reduces per-call overhead in the
VT parser.")


;;; Process management

(defun ghostel--filter (process output)
  "Process filter: feed PTY output to the terminal.
PROCESS is the shell process, OUTPUT is the raw byte string.
Output is accumulated and fed to the terminal in a single batch
when the redraw timer fires, reducing per-call VT parser overhead.

For interactive echo (small output arriving shortly after a keystroke),
the redraw is performed immediately to minimize typing latency."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when ghostel--term
        ;; Accumulate output for batched write-input at redraw time.
        (push output ghostel--pending-output)
        ;; Respond to OSC 4/10/11 color queries immediately: programs like
        ;; `duf' read stdin with a tight timeout and give up if the reply
        ;; waits for the redraw timer.  Flushing runs the extractor in the
        ;; native module, which writes the reply back through the PTY
        ;; before this filter returns.
        (when (string-match-p
               "\e\\]\\(?:4;[0-9]+;\\?\\|10;\\?\\|11;\\?\\)" output)
          (ghostel--flush-pending-output))
        ;; Immediate redraw for interactive echo: small output arriving
        ;; within `ghostel-immediate-redraw-interval' of last keystroke.
        (if (and (> ghostel-immediate-redraw-threshold 0)
                 ghostel--last-send-time
                 (<= (length output) ghostel-immediate-redraw-threshold)
                 (< (float-time (time-subtract (current-time)
                                               ghostel--last-send-time))
                    ghostel-immediate-redraw-interval))
            (progn
              ;; Cancel pending timer — we're drawing now.
              (when ghostel--redraw-timer
                (cancel-timer ghostel--redraw-timer)
                (setq ghostel--redraw-timer nil))
              (ghostel--delayed-redraw (current-buffer)))
          ;; Bulk output: batch and schedule as before.
          (ghostel--invalidate))))))

(defun ghostel--sentinel (process event)
  "Process sentinel: clean up when shell exits.
PROCESS is the shell process, EVENT describes the state change."
  (let ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        ;; Flush any pending output before cleanup.
        (when ghostel--term
          (ghostel--flush-pending-output))
        (when ghostel--redraw-timer
          (cancel-timer ghostel--redraw-timer)
          (setq ghostel--redraw-timer nil))
        (when ghostel--input-timer
          (cancel-timer ghostel--input-timer)
          (setq ghostel--input-timer nil))
        (remove-function after-focus-change-function #'ghostel--focus-change)
        (run-hook-with-args 'ghostel-exit-functions buf event)
        (if ghostel-kill-buffer-on-exit
            (kill-buffer buf)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert "\n[Process exited]\n")))))))

(defun ghostel--detect-shell (shell)
  "Return shell type symbol (bash, zsh, fish) from SHELL path, or nil."
  (let ((base (file-name-nondirectory shell)))
    (cond
     ((string-match-p "bash" base) 'bash)
     ((string-match-p "zsh" base) 'zsh)
     ((string-match-p "fish" base) 'fish))))

(defun ghostel--local-host-p (host)
  "Return non-nil if HOST refers to the local machine."
  (or (null host)
      (string= host "")
      (eq t (compare-strings host nil nil "localhost" nil nil t))
      (eq t (compare-strings host nil nil (system-name) nil nil t))
      (eq t (compare-strings
             host nil nil
             (car (split-string (system-name) "\\.")) nil nil t))))

(defun ghostel--tramp-get-shell (method)
  "Get the shell for TRAMP METHOD from `ghostel-tramp-shells'.
METHOD is a TRAMP method string or t for the default."
  (let* ((specs (cdr (assoc method ghostel-tramp-shells)))
         (first (car specs))
         (second (cadr specs)))
    (if (eq first 'login-shell)
        (let* ((entry (ignore-errors
                        (with-output-to-string
                          (with-current-buffer standard-output
                            (unless (= 0 (process-file-shell-command
                                          "getent passwd $LOGNAME"
                                          nil (current-buffer) nil))
                              (error "Unexpected return value"))
                            (when (> (count-lines (point-min) (point-max)) 1)
                              (error "Unexpected output"))))))
               (shell (when entry
                        (nth 6 (split-string entry ":" nil "[ \t\n\r]+")))))
          (or shell second))
      first)))

(defun ghostel--get-shell ()
  "Get the shell to run, respecting TRAMP remote connections.
When `default-directory' is a remote TRAMP path, consult
`ghostel-tramp-shells' for the appropriate shell."
  (if (file-remote-p default-directory)
      (with-parsed-tramp-file-name default-directory nil
        (or (ghostel--tramp-get-shell method)
            (ghostel--tramp-get-shell t)
            (with-connection-local-variables shell-file-name)
            ghostel-shell))
    ghostel-shell))

(defun ghostel--read-local-file (path)
  "Return the contents of local file PATH as a string."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun ghostel--write-remote-file (tramp-path content)
  "Write CONTENT to TRAMP-PATH on the remote host."
  (with-temp-buffer
    (insert content)
    (write-region (point-min) (point-max) tramp-path nil 'silent)))

(defun ghostel--cleanup-temp-paths (files dirs)
  "Delete temporary FILES and DIRS created for remote shell integration.
Directories are removed recursively so any contents written into them,
such as a per-session `.zshenv', are cleaned up as well."
  (dolist (f files)
    (ignore-errors (delete-file f)))
  (dolist (d dirs)
    (ignore-errors (delete-directory d t))))

(defun ghostel--setup-remote-integration (shell-type)
  "Set up shell integration on the remote host for SHELL-TYPE.
Reads the local integration script, writes it (with any necessary
preamble) to a temporary file on the remote host, and returns a
plist (:env :args :stty :temp-files :temp-dirs) for
`ghostel--start-process'.
Returns nil on failure."
  (condition-case err
      (let* ((remote-prefix (file-remote-p default-directory))
             (ghostel-dir (file-name-directory
                           (or (locate-library "ghostel")
                               load-file-name buffer-file-name
                               default-directory)))
             (ext (symbol-name shell-type))
             (integration (ghostel--read-local-file
                           (expand-file-name
                            (format "etc/ghostel.%s" ext) ghostel-dir))))
        (pcase shell-type
          ;; Bash: --rcfile replaces normal rc loading, so we source
          ;; startup files explicitly before the integration.
          ('bash
           (let* ((temp (make-temp-file
                         (concat remote-prefix "ghostel-") nil ".bash"))
                  (path (file-remote-p temp 'localname)))
             (ghostel--write-remote-file temp
                                         (concat
                                          "# Source standard startup files\n"
                                          "if shopt -q login_shell 2>/dev/null; then\n"
                                          "  [ -r /etc/profile ] && . /etc/profile\n"
                                          "  for __gf in ~/.bash_profile ~/.bash_login ~/.profile; do\n"
                                          "    [ -r \"$__gf\" ] && { . \"$__gf\"; break; }; done\n"
                                          "  unset __gf\n"
                                          "else\n"
                                          "  for __gf in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do\n"
                                          "    [ -r \"$__gf\" ] && { . \"$__gf\"; break; }; done\n"
                                          "  unset __gf\n"
                                          "  [ -r ~/.bashrc ] && . ~/.bashrc\n"
                                          "fi\n"
                                          integration))
             (list :env nil :args (list "--rcfile" path)
                   :stty "erase '^?' iutf8 -ixon echo" :temp-files (list temp))))
          ;; Zsh: ZDOTDIR replaces .zshenv search, so we restore it,
          ;; source the user's .zshenv, then load integration.
          ('zsh
           (let* ((temp-dir (make-temp-file
                             (concat remote-prefix "ghostel-") t))
                  (temp-zshenv (concat (file-name-as-directory temp-dir)
                                       ".zshenv"))
                  (remote-dir (file-remote-p temp-dir 'localname)))
             (ghostel--write-remote-file temp-zshenv
                                         (concat
                                          "if [[ -n \"${GHOSTEL_ZSH_ZDOTDIR+X}\" ]]; then\n"
                                          "    'builtin' 'export' ZDOTDIR=\"$GHOSTEL_ZSH_ZDOTDIR\"\n"
                                          "    'builtin' 'unset' 'GHOSTEL_ZSH_ZDOTDIR'\n"
                                          "else\n"
                                          "    'builtin' 'unset' 'ZDOTDIR'\n"
                                          "fi\n"
                                          "{\n"
                                          "    'builtin' 'typeset' _ghostel_file="
                                          "\"${ZDOTDIR-$HOME}/.zshenv\"\n"
                                          "    [[ ! -r \"$_ghostel_file\" ]] || "
                                          "'builtin' 'source' '--' \"$_ghostel_file\"\n"
                                          "} always {\n"
                                          "    if [[ -o 'interactive' ]]; then\n"
                                          integration "\n"
                                          "    fi\n"
                                          "    'builtin' 'unset' '_ghostel_file'\n"
                                          "}\n"))
             (list :env (list (format "ZDOTDIR=%s" remote-dir))
                   :args nil :stty "erase '^?' iutf8 -ixon"
                   :temp-dirs (list temp-dir))))
          ;; Fish: -C runs after config, so just source the script.
          ('fish
           (let* ((temp (make-temp-file
                         (concat remote-prefix "ghostel-") nil ".fish"))
                  (path (file-remote-p temp 'localname)))
             (ghostel--write-remote-file temp integration)
             (list :env nil
                   :args (list "-C" (format "source %s"
                                            (shell-quote-argument path)))
                   :stty "erase '^?' iutf8 -ixon" :temp-files (list temp))))))
    (error
     (message "ghostel: remote shell integration failed: %s"
              (error-message-string err))
     nil)))

(defun ghostel--start-process ()
  "Start the shell process with a PTY.
When `default-directory' is a remote TRAMP path, spawn the shell
on the remote host."
  (let* ((height (max 1 (window-body-height)))
         (width (max 1 (window-max-chars-per-line)))
         (remote-p (file-remote-p default-directory))
         (shell (ghostel--get-shell))
         (ghostel-dir (file-name-directory
                       (or (locate-library "ghostel")
                           load-file-name buffer-file-name
                           default-directory)))
         ;; Detect shell type when integration is enabled.
         ;; For remote, also check ghostel-tramp-shell-integration.
         (shell-type (and ghostel-shell-integration
                          (or (not remote-p)
                              (let ((st (ghostel--detect-shell shell)))
                                (and st
                                     (or (eq ghostel-tramp-shell-integration t)
                                         (and (listp ghostel-tramp-shell-integration)
                                              (memq st ghostel-tramp-shell-integration)))
                                     st)))
                          (ghostel--detect-shell shell)))
         ;; For remote sessions, set up integration via temp files.
         (remote-integration
          (when (and remote-p shell-type)
            (ghostel--setup-remote-integration shell-type)))
         (integration-env
          (if remote-integration
              (plist-get remote-integration :env)
            (and (not remote-p)
                 (pcase shell-type
                   ('bash
                    (let ((inject-script (expand-file-name
                                          "etc/shell-integration/bash/ghostel-inject.bash"
                                          ghostel-dir))
                          (env (list "GHOSTEL_BASH_INJECT=1")))
                      (when (file-readable-p inject-script)
                        (let ((old-env (getenv "ENV")))
                          (when old-env
                            (push (format "GHOSTEL_BASH_ENV=%s" old-env) env)))
                        (push (format "ENV=%s" inject-script) env)
                        (unless (getenv "HISTFILE")
                          (push (format "HISTFILE=%s/.bash_history"
                                        (expand-file-name "~"))
                                env)
                          (push "GHOSTEL_BASH_UNEXPORT_HISTFILE=1" env))
                        env)))
                   ('zsh
                    (let ((zsh-dir (expand-file-name
                                    "etc/shell-integration/zsh" ghostel-dir)))
                      (when (file-directory-p zsh-dir)
                        (let ((env nil)
                              (old-zdotdir (getenv "ZDOTDIR")))
                          (when old-zdotdir
                            (push (format "GHOSTEL_ZSH_ZDOTDIR=%s" old-zdotdir) env))
                          (push (format "ZDOTDIR=%s" zsh-dir) env)
                          env))))
                   ('fish
                    (let ((integ-dir (expand-file-name
                                      "etc/shell-integration" ghostel-dir)))
                      (when (file-directory-p integ-dir)
                        (let ((xdg (or (getenv "XDG_DATA_DIRS")
                                       "/usr/local/share:/usr/share")))
                          (list
                           (format "XDG_DATA_DIRS=%s:%s" integ-dir xdg)
                           (format "GHOSTEL_SHELL_INTEGRATION_XDG_DIR=%s"
                                   integ-dir))))))))))
         ;; Wrap the shell in /bin/sh -c so we can configure the PTY
         ;; before the shell reads its terminal attributes:
         ;;  - erase '^?': Emacs PTYs leave VERASE undefined, but
         ;;    shells like fish check VERASE at startup to decide
         ;;    whether \x7f means backspace.
         ;;  - iutf8: kernel-level UTF-8 awareness so backspace
         ;;    correctly erases multi-byte characters.
         ;;  - -ixon: disable XON/XOFF flow control so C-q and C-s
         ;;    pass through to the application instead of being
         ;;    swallowed by the PTY line discipline.
         ;;  - echo: bash-only — readline buffers its own echo, so
         ;;    we need PTY-level echo.  When bash integration is
         ;;    active, the integration script handles echo.
         ;; The clear-screen hides the stty output.  exec replaces
         ;; the wrapper so only the shell process remains.
         (shell-args (cond
                      (remote-integration
                       (plist-get remote-integration :args))
                      ((and (eq shell-type 'bash) integration-env)
                       (list "--posix"))
                      (t nil)))
         (stty-flags (cond
                      (remote-integration
                       (plist-get remote-integration :stty))
                      ((and (eq (ghostel--detect-shell shell) 'bash)
                            (not integration-env))
                       "erase '^?' iutf8 -ixon echo")
                      (t "erase '^?' iutf8 -ixon")))
         (shell-command
          (list "/bin/sh" "-c"
                (concat "stty " stty-flags
                        (format " rows %d columns %d" height width)
                        " 2>/dev/null; "
                        "printf '\\033[H\\033[2J'; exec "
                        (shell-quote-argument shell)
                        (and shell-args
                             (concat " "
                                     (mapconcat #'shell-quote-argument
                                                shell-args " "))))))
         (process-environment
          (append
           (list
            "INSIDE_EMACS=ghostel"
            "TERM=xterm-256color"
            "COLORTERM=truecolor")
           (unless remote-p
             (list (format "EMACS_GHOSTEL_PATH=%s" ghostel-dir)))
           integration-env
           process-environment))
         (proc (make-process
                :name "ghostel"
                :buffer (current-buffer)
                :command shell-command
                :connection-type 'pty
                :file-handler remote-p
                :filter #'ghostel--filter
                :sentinel #'ghostel--sentinel)))
    (when remote-integration
      (ghostel--cleanup-temp-paths
       (plist-get remote-integration :temp-files)
       (plist-get remote-integration :temp-dirs)))
    (setq ghostel--process proc)
    ;; Raw binary I/O — no encoding/decoding by Emacs
    (set-process-coding-system proc 'binary 'binary)
    ;; Set the PTY's actual window size (ioctl TIOCSWINSZ) so that
    ;; the shell's line editor (readline/ZLE) can render properly.
    (set-process-window-size proc height width)
    (set-process-query-on-exit-flag proc nil)
    (process-put proc 'adjust-window-size-function
                 #'ghostel--window-adjust-process-window-size)
    proc))


;;; Rendering

(defvar-local ghostel--last-output-time nil
  "Time of the last process output, for adaptive frame rate.")

(defun ghostel--invalidate ()
  "Schedule a redraw after a short delay.
With `ghostel-adaptive-fps', use a shorter delay for the first
frame after idle to improve interactive responsiveness."
  (unless ghostel--redraw-timer
    (let ((delay (if (and ghostel-adaptive-fps ghostel--last-output-time)
                     (let ((idle-secs (float-time
                                       (time-subtract (current-time)
                                                      ghostel--last-output-time))))
                       ;; If idle for more than 100ms, use a short delay
                       ;; for snappy first-frame response.
                       (if (> idle-secs 0.1)
                           (min 0.016 ghostel-timer-delay)
                         ghostel-timer-delay))
                   ghostel-timer-delay)))
      (setq ghostel--last-output-time (current-time))
      (setq ghostel--redraw-timer
            (run-with-timer delay nil
                            #'ghostel--delayed-redraw
                            (current-buffer))))))

(defun ghostel--flush-pending-output ()
  "Feed any accumulated output to the terminal in a single batch."
  (when ghostel--pending-output
    (let ((combined (apply #'concat (nreverse ghostel--pending-output))))
      (setq ghostel--pending-output nil)
      ;; An OSC 51;E callback dispatched synchronously from the native
      ;; parser (e.g. `find-file-other-window') can change the current
      ;; buffer via `select-window'.  Isolate that so callers keep
      ;; reading buffer-locals — notably `ghostel--term' — from the
      ;; ghostel buffer after this returns.
      (save-current-buffer
        (ghostel--write-input ghostel--term combined)))))

(defun ghostel--delayed-redraw (buffer)
  "Perform the actual redraw in BUFFER.
If point is currently inside the materialized scrollback (above the
viewport), save and restore it so scrolling up to read history is not
interrupted by live output updating the terminal cursor."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ghostel--redraw-timer nil)
      (when (and ghostel--term (not ghostel--copy-mode-active))
        ;; Flush accumulated output before rendering.
        (ghostel--flush-pending-output)
        ;; Skip during synchronized output unless forced by scroll/resize.
        (unless (and (not ghostel--force-next-redraw)
                     (ghostel--mode-enabled ghostel--term 2026))
          (setq ghostel--force-next-redraw nil)
          (setq ghostel--has-wide-chars nil)
          (let* ((rows (or ghostel--term-rows 0))
                 ;; Compute the viewport start — first char of the last
                 ;; `rows` lines — to decide whether point is currently
                 ;; in the scrollback region above it. Bounded O(rows).
                 (viewport-start
                  (when (> rows 0)
                    (save-excursion
                      (goto-char (point-max))
                      (forward-line (- (1- rows)))
                      (line-beginning-position))))
                 ;; Preserve point only when reading scrollback.
                 (saved-marker
                  (when (and viewport-start (< (point) viewport-start))
                    (copy-marker (point) t)))
                 (inhibit-read-only t)
                 (inhibit-redisplay t)
                 (inhibit-modification-hooks t))
            (ghostel--redraw ghostel--term ghostel-full-redraw)
            (when saved-marker
              (goto-char saved-marker)
              (set-marker saved-marker nil)))
          (when ghostel--has-wide-chars
            (ghostel--compensate-wide-chars))
          ;; Native redraw updates buffer-point via `goto-char', which
          ;; only propagates to `window-point' for the selected window.
          ;; If an OSC 51;E callback moved selection elsewhere (e.g.
          ;; `find-file-other-window'), the ghostel window's
          ;; window-point is stale and the terminal cursor will display
          ;; at the wrong place when the user reselects it.  Sync it.
          ;;
          ;; Also anchor window-start to the viewport origin when point
          ;; is in the viewport.  Without this, a resize (which erases
          ;; and rebuilds the buffer inside redraw) leaves window-start
          ;; clamped to 1 and Emacs's auto-scroll produces a visible
          ;; jump.  Skip the anchor when point is in scrollback so that
          ;; users reading history are not yanked back to the bottom.
          (let* ((pt (point))
                 (tr (or ghostel--term-rows 0))
                 (vs (when (> tr 0)
                       (save-excursion
                         (goto-char (point-max))
                         (forward-line (- (1- tr)))
                         (line-beginning-position)))))
            (dolist (win (get-buffer-window-list buffer nil t))
              (when (and vs (>= pt vs))
                (set-window-start win vs t))
              (set-window-point win pt))))))))

(defun ghostel-force-redraw ()
  "Force a full terminal redraw (for debugging)."
  (interactive)
  (when ghostel--term
    (setq ghostel--has-wide-chars nil)
    (let ((inhibit-read-only t))
      (ghostel--redraw ghostel--term ghostel-full-redraw))
    (when ghostel--has-wide-chars
      (ghostel--compensate-wide-chars))))


;;; Window resize

(defun ghostel--window-adjust-process-window-size (process windows)
  "Resize the terminal to match the new Emacs window dimensions.
PROCESS is the shell process, WINDOWS is the list of windows."
  (let* ((adjust-fn (default-value 'window-adjust-process-window-size-function))
         (adjust-fn (if (and (functionp adjust-fn)
                             (not (eq adjust-fn
                                      #'ghostel--window-adjust-process-window-size)))
                        adjust-fn
                      #'window-adjust-process-window-size-smallest))
         (size (funcall adjust-fn process windows))
         (width (car size))
         (height (cdr size))
         (buffer (process-buffer process)))
    (when (and size (buffer-live-p buffer))
      (with-current-buffer buffer
        (when ghostel--term
          (ghostel--set-size ghostel--term (max 1 height) (max 1 width))
          (setq ghostel--term-rows height)
          (setq ghostel--force-next-redraw t)
          ;; Redraw synchronously so the buffer is updated before
          ;; Emacs displays the stale content at the new window size.
          (when ghostel--redraw-timer
            (cancel-timer ghostel--redraw-timer)
            (setq ghostel--redraw-timer nil))
          (ghostel--delayed-redraw buffer))))
    ;; Return size — Emacs calls set-process-window-size (SIGWINCH)
    ;; after this function returns, matching eat/vterm timing.
    size))



;;; Major mode

(define-derived-mode ghostel-mode fundamental-mode "Ghostel"
  "Major mode for Ghostel terminal emulator."
  (buffer-disable-undo)
  (font-lock-mode -1)
  (setq buffer-read-only nil)
  (setq-local scroll-margin 0)
  (setq-local auto-hscroll-mode nil)
  (setq-local hscroll-margin 0)
  (setq-local truncate-lines t)
  (setq-local scroll-conservatively 101)
  (setq-local line-spacing 0)
  (add-function :after after-focus-change-function #'ghostel--focus-change)
  (ghostel--suppress-interfering-modes)
  (setq ghostel--scroll-intercept-active t))

(defun ghostel--suppress-interfering-modes ()
  "Disable global minor modes that interfere with ghostel.
Suppresses `global-hl-line-mode' (and buffer-local `hl-line-mode') to
prevent redraw flicker."
  ;; global-hl-line-mode: opt this buffer out by setting the variable
  ;; buffer-locally to nil (as documented in the hl-line.el commentary).
  (when (bound-and-true-p global-hl-line-mode)
    (setq ghostel--saved-hl-line-mode t)
    (setq-local global-hl-line-mode nil)
    (when (fboundp 'global-hl-line-unhighlight)
      (global-hl-line-unhighlight)))
  ;; Buffer-local hl-line-mode
  (when (bound-and-true-p hl-line-mode)
    (setq ghostel--saved-hl-line-mode t)
    (hl-line-mode -1)))


;;; Entry point

;;;###autoload
(defun ghostel (&optional arg)
  "Start a new Ghostel terminal.  If the buffer already exists, switch to it.
With a non-numeric prefix arg, create a new buffer.
With a numeric prefix ARG, switch to the buffer with that number or
create it if it doesn't exist yet.
The name of the buffer is determined by the value of `ghostel-buffer-name'."
  (interactive "P")
  (unless (fboundp 'ghostel--new)
    (let ((dir (file-name-directory (locate-library "ghostel"))))
      (ghostel--ensure-module dir)
      (let ((mod (expand-file-name
                  (concat "ghostel-module" module-file-suffix) dir)))
        (if (file-exists-p mod)
            (module-load mod)
          (user-error "Ghostel native module not available")))))
  (let ((buffer (cond ((numberp arg)
                       (get-buffer-create (format "%s<%d>"
                                                  ghostel-buffer-name
                                                  arg)))
                      (arg
                       (generate-new-buffer ghostel-buffer-name))
                      (t
                       (get-buffer-create ghostel-buffer-name)))))
    (pop-to-buffer buffer (append display-buffer--same-window-action
                                  '((category . comint))))
    (unless (derived-mode-p 'ghostel-mode)
      (ghostel-mode)
      (setq ghostel--managed-buffer-name (buffer-name))
      (let* ((height (window-body-height))
             (width (window-max-chars-per-line)))
        (setq ghostel--term
              (ghostel--new height width ghostel-max-scrollback))
        (setq ghostel--term-rows height)
        (ghostel--apply-palette ghostel--term))
      (ghostel--start-process))))

;;;###autoload
(defun ghostel-project (&optional arg)
  "Start a new Ghostel terminal in the current project's root.
The buffer name is prefixed with the project name.
If a buffer already exists for this project, switch to it.
Otherwise create a new Ghostel buffer.  ARG is passed through to
`ghostel' and accepts the same universal argument conventions.
To add this to `project-switch-commands':
  (add-to-list \\='project-switch-commands \\='(ghostel-project \"Ghostel\") t)"
  (interactive "P")
  (let ((default-directory (project-root (project-current t)))
        (ghostel-buffer-name (project-prefixed-buffer-name
                              (string-trim ghostel-buffer-name "*" "*"))))
    (ghostel arg)))

(defun ghostel-other ()
  "Switch to the next ghostel terminal buffer, or create one."
  (interactive)
  (let* ((bufs (cl-remove-if-not
                (lambda (b)
                  (with-current-buffer b
                    (derived-mode-p 'ghostel-mode)))
                (buffer-list)))
         (current (current-buffer))
         (others (cl-remove current bufs)))
    (if others
        (pop-to-buffer (car others) (append display-buffer--same-window-action
                                            '((category . comint))))
      (ghostel))))

(provide 'ghostel)

;;; ghostel.el ends here
