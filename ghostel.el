;;; ghostel.el --- Terminal emulator powered by libghostty -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus
;; URL: https://github.com/dakra/ghostel
;; Version: 0.1.0
;; Keywords: terminals
;; Package-Requires: ((emacs "27.1"))
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
;; Building the native module:
;;
;;   Run ./build.sh from the project root, or M-x ghostel-module-compile
;;   from within Emacs.  Requires Zig 0.14+ and the vendored ghostty
;;   submodule.

;;; Code:

(require 'cl-lib)
(require 'term)
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

(defcustom ghostel-max-scrollback 10000
  "Maximum number of scrollback lines."
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

(defcustom ghostel-full-redraw nil
  "When non-nil, always perform full redraws instead of incremental updates.
Full redraws are more robust with TUI apps like Claude Code that do
aggressive partial screen updates, but may use more CPU."
  :type 'boolean)

(defcustom ghostel-buffer-name "*ghostel*"
  "Default buffer name for ghostel terminals."
  :type 'string)

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

(defcustom ghostel-keymap-exceptions
  '("C-c" "C-x" "C-u" "C-h" "C-g" "M-x" "M-o" "M-:" "C-\\")
  "Key sequences that should not be sent to the terminal.
These keys pass through to Emacs instead."
  :type '(repeat string))

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

(defvar ghostel-github-release-url
  "https://github.com/dakra/ghostel/releases"
  "Base URL for ghostel GitHub releases.")


;; Declare native module functions for the byte compiler

(declare-function ghostel--encode-key "ghostel-module")
(declare-function ghostel--focus-event "ghostel-module")
(declare-function ghostel--mode-enabled "ghostel-module")
(declare-function ghostel--mouse-event "ghostel-module")
(declare-function ghostel--new "ghostel-module")
(declare-function ghostel--redraw "ghostel-module" (term &optional full))
(declare-function ghostel--scroll "ghostel-module")
(declare-function ghostel--scroll-bottom "ghostel-module")
(declare-function ghostel--scroll-top "ghostel-module")
(declare-function ghostel--set-palette "ghostel-module")
(declare-function ghostel--set-size "ghostel-module")
(declare-function ghostel--write-input "ghostel-module")
(declare-function package-desc-version "package" (pkg-desc))
(declare-function package-version-join "package" (vlist))
(declare-function global-hl-line-unhighlight "hl-line")


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

(defun ghostel--module-download-url ()
  "Return the download URL for the current platform's pre-built module."
  (let ((asset-name (ghostel--module-asset-name)))
    (when asset-name
      (let ((version (ghostel--package-version)))
        (if version
            (format "%s/download/v%s/%s"
                    ghostel-github-release-url version asset-name)
          (format "%s/latest/download/%s"
                  ghostel-github-release-url asset-name))))))

(defun ghostel--download-module (dir)
  "Download a pre-built module into DIR.
Returns non-nil on success."
  (condition-case err
      (let ((url (ghostel--module-download-url)))
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
  (let ((default-directory dir)
        (script (expand-file-name "build.sh" dir)))
    (if (file-executable-p script)
        (progn
          (message "ghostel: compiling native module (this may take a moment)...")
          (let ((ret (call-process script nil "*ghostel-build*" nil)))
            (if (eq ret 0)
                (progn (message "ghostel: native module compiled successfully") t)
              (display-warning 'ghostel
                               "Module compilation failed.  See *ghostel-build* buffer for details.")
              nil)))
      (display-warning 'ghostel
                       (format "build.sh not found in %s.\nClone with submodules and run ./build.sh manually." dir))
      nil)))

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

(defun ghostel--ask-install-action (_dir)
  "Prompt the user to choose how to install the missing native module.
Returns \\='download, \\='compile, or nil."
  (let* ((url (or (ghostel--module-download-url) "GitHub releases"))
         (choice (read-char-choice
                  (format "Ghostel native module not found.

  [d] Download pre-built binary from:
      %s
  [c] Compile from source (requires Zig)
  [s] Skip — install manually later

Choice: " url)
                  '(?d ?c ?s))))
    (pcase choice
      (?d 'download)
      (?c 'compile)
      (?s nil))))

(defun ghostel--package-version ()
  "Return ghostel package version string, or nil.
Returns nil without error when `package.el' is unavailable."
  (when (and (require 'package nil t)
             (boundp 'package-alist))
    (let ((pkg (car (alist-get 'ghostel package-alist))))
      (when pkg
        (package-version-join (package-desc-version pkg))))))

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

(defun ghostel-download-module ()
  "Interactively download the pre-built native module for this platform."
  (interactive)
  (let* ((dir (file-name-directory (or load-file-name
                                       (locate-library "ghostel")
                                       buffer-file-name)))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir)))
    (when (and (file-exists-p mod)
               (not (yes-or-no-p "Module already exists.  Re-download? ")))
      (user-error "Cancelled"))
    (if (ghostel--download-module dir)
        (progn
          (module-load mod)
          (message "ghostel: module loaded successfully"))
      (user-error "Download failed.  Try M-x ghostel-module-compile to build from source"))))

(defun ghostel-module-compile ()
  "Compile the ghostel native module by running build.sh.
The output is shown in a *ghostel-build* compilation buffer."
  (interactive)
  (let ((default-directory (file-name-directory (or (locate-library "ghostel")
                                                    default-directory))))
    (compile (expand-file-name "build.sh") t)))

;; Load the native module
(unless (featurep 'ghostel-module)
  (let* ((dir (file-name-directory (or load-file-name buffer-file-name)))
         (mod (expand-file-name
               (concat "ghostel-module" module-file-suffix) dir)))
    (unless (or (file-exists-p mod) noninteractive)
      (ghostel--ensure-module dir))
    (if (file-exists-p mod)
        (condition-case err
            (module-load mod)
          (error
           (display-warning 'ghostel
                            (format "Failed to load native module: %s\nTry M-x ghostel-module-compile to rebuild"
                                    (error-message-string err)))))
      (unless ghostel-module-auto-install
        (display-warning 'ghostel
                         (concat "Native module not found: " mod
                                 "\nRun M-x ghostel-download-module or M-x ghostel-module-compile"))))))


;;; Internal variables

(defvar-local ghostel--term nil
  "Handle to the native terminal instance.")

(defvar-local ghostel--copy-mode-active nil
  "Non-nil when copy mode is active.")

(defvar-local ghostel--process nil
  "The shell process.")

(defvar-local ghostel--redraw-timer nil
  "Timer for delayed redraw.")

(defvar-local ghostel--force-next-redraw nil
  "When non-nil, redraw regardless of synchronized output mode.")

(defvar-local ghostel--resize-timer nil
  "Timer for debounced SIGWINCH on alt screen.")


(defvar-local ghostel--last-directory nil
  "Last known working directory from OSC 7, used for dedup.")

(defvar-local ghostel--prompt-positions nil
  "List of prompt positions as (buffer-line . exit-status) pairs.
Used for prompt navigation and optional re-application after full redraws.")


(defvar ghostel--buffer-counter 0
  "Counter for generating unique terminal buffer names.")


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
    ;; Control keys
    (define-key map (kbd "C-d")       (lambda () (interactive) (ghostel--send-key "\x04")))
    (define-key map (kbd "C-a")       (lambda () (interactive) (ghostel--send-key "\x01")))
    (define-key map (kbd "C-e")       (lambda () (interactive) (ghostel--send-key "\x05")))
    (define-key map (kbd "C-k")       (lambda () (interactive) (ghostel--send-key "\x0b")))
    (define-key map (kbd "C-l")       (lambda () (interactive) (ghostel--send-key "\x0c")))
    (define-key map (kbd "C-n")       (lambda () (interactive) (ghostel--send-key "\x0e")))
    (define-key map (kbd "C-p")       (lambda () (interactive) (ghostel--send-key "\x10")))
    (define-key map (kbd "C-r")       (lambda () (interactive) (ghostel--send-key "\x12")))
    (define-key map (kbd "C-w")       (lambda () (interactive) (ghostel--send-key "\x17")))
    (define-key map (kbd "C-y")       #'ghostel-yank)
    (define-key map (kbd "M-y")       #'ghostel-yank-pop)
    (define-key map (kbd "C-z")       (lambda () (interactive) (ghostel--send-key "\x1a")))
    ;; Terminal control via C-c prefix (pass through to Emacs, then handled here)
    (define-key map (kbd "C-c C-c")   #'ghostel-send-C-c)
    (define-key map (kbd "C-c C-z")   #'ghostel-send-C-z)
    (define-key map (kbd "C-c C-\\")  #'ghostel-send-C-backslash)
    (define-key map (kbd "C-c C-d")   #'ghostel-send-C-d)
    (define-key map (kbd "C-c C-t")   #'ghostel-copy-mode)
    (define-key map (kbd "C-c C-y")   #'ghostel-paste)
    (define-key map (kbd "C-c C-l")   #'ghostel-clear-scrollback)
    (define-key map (kbd "C-c C-q")   #'ghostel-send-next-key)
    ;; Prompt navigation (OSC 133)
    (define-key map (kbd "C-c C-n")   #'ghostel-next-prompt)
    (define-key map (kbd "C-c C-p")   #'ghostel-previous-prompt)
    ;; Mouse wheel for scrollback
    (define-key map (kbd "<mouse-4>")       #'ghostel--scroll-up)
    (define-key map (kbd "<mouse-5>")       #'ghostel--scroll-down)
    (define-key map (kbd "<wheel-up>")      #'ghostel--scroll-up)
    (define-key map (kbd "<wheel-down>")    #'ghostel--scroll-down)
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
intercepted by Emacs (e.g., interrupt or prefix keys)."
  (interactive)
  (let* ((key (read-key-sequence "Send key: "))
         (char (aref key 0)))
    (cond
     ;; Control character
     ((and (integerp char) (<= char 31))
      (ghostel--send-key (string char)))
     ;; Regular character
     ((and (integerp char) (< char 128))
      (ghostel--send-key (string char)))
     ;; Multi-byte character
     ((integerp char)
      (ghostel--send-key (encode-coding-string (string char) 'utf-8)))
     ;; Function key / special key — look up in keymap
     (t
      (let* ((binding (key-binding key)))
        (if (and binding (commandp binding))
            (call-interactively binding)
          (message "ghostel: unrecognized key %S" key)))))))

(defun ghostel--send-key (key)
  "Send KEY string to the terminal process."
  (when (and ghostel--process (process-live-p ghostel--process))
    (process-send-string ghostel--process key)))

(defun ghostel--send-encoded (key-name mods &optional utf8)
  "Encode KEY-NAME with MODS via the terminal's key encoder and send.
KEY-NAME is a string like \"a\", \"return\", \"up\".
MODS is a string like \"ctrl\", \"shift,ctrl\", or \"\".
UTF8 is optional text generated by the key.
Falls back to raw escape sequences if the encoder doesn't produce output."
  (when ghostel--term
    (unless (ghostel--encode-key ghostel--term key-name mods utf8)
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
    (let ((payload (car (last (nth 1 event)))))
      (cond
       ;; File drop — payload is a filename string from the drop event
       ((and (stringp payload) (file-exists-p payload))
        (ghostel--send-key (shell-quote-argument payload)))
       ;; URI list (e.g. from file managers that drop file:// URIs)
       ((and (stringp payload) (string-prefix-p "file://" payload))
        (let ((path (url-filename (url-generic-parse-url payload))))
          (ghostel--send-key (shell-quote-argument path))))
       ;; Text drop
       ((stringp payload)
        (ghostel--paste-text payload))
       ;; dnd-protocol-alist style: list of files
       ((and (listp payload) (cl-every #'stringp payload))
        (ghostel--send-key
         (mapconcat #'shell-quote-argument payload " ")))))))


;;; Scrollback / clearing

(defun ghostel-clear-scrollback ()
  "Clear the scrollback buffer."
  (interactive)
  (when (and ghostel--process (process-live-p ghostel--process))
    ;; CSI 3 J = erase scrollback
    (process-send-string ghostel--process "\e[3J")
    (ghostel--invalidate)))

(defun ghostel-clear ()
  "Clear the screen and scrollback buffer."
  (interactive)
  (when (and ghostel--process (process-live-p ghostel--process))
    ;; CSI H = cursor home, CSI 2 J = erase screen, CSI 3 J = erase scrollback
    (process-send-string ghostel--process "\e[H\e[2J\e[3J")
    (ghostel--invalidate)))

(defun ghostel--scroll-up (&optional _event)
  "Scroll the terminal viewport up (into scrollback)."
  (interactive "e")
  (when ghostel--term
    (ghostel--scroll ghostel--term -3)
    (if ghostel--copy-mode-active
        (let ((inhibit-read-only t))
          (ghostel--redraw ghostel--term ghostel-full-redraw))
      (setq ghostel--force-next-redraw t)
      (ghostel--invalidate))))

(defun ghostel--scroll-down (&optional _event)
  "Scroll the terminal viewport down."
  (interactive "e")
  (when ghostel--term
    (ghostel--scroll ghostel--term 3)
    (if ghostel--copy-mode-active
        (let ((inhibit-read-only t))
          (ghostel--redraw ghostel--term ghostel-full-redraw))
      (setq ghostel--force-next-redraw t)
      (ghostel--invalidate))))

(defun ghostel-copy-mode-scroll-up ()
  "Scroll the terminal viewport up by a page in copy mode."
  (interactive)
  (when ghostel--term
    (let ((height (count-lines (point-min) (point-max))))
      (ghostel--scroll ghostel--term (- 2 height))
      (let ((inhibit-read-only t))
        (ghostel--redraw ghostel--term ghostel-full-redraw)))))

(defun ghostel-copy-mode-scroll-down ()
  "Scroll the terminal viewport down by a page in copy mode."
  (interactive)
  (when ghostel--term
    (let ((height (count-lines (point-min) (point-max))))
      (ghostel--scroll ghostel--term (- height 2))
      (let ((inhibit-read-only t))
        (ghostel--redraw ghostel--term ghostel-full-redraw)))))

(defun ghostel-copy-mode-previous-line ()
  "Move to the previous line, scrolling the viewport if at the top."
  (interactive)
  (let ((col (current-column)))
    (if (= (line-number-at-pos) 1)
        (when ghostel--term
          (ghostel--scroll ghostel--term -1)
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term ghostel-full-redraw))
          (goto-char (point-min)))
      (forward-line -1))
    (move-to-column col)))

(defun ghostel-copy-mode-next-line ()
  "Move to the next line, scrolling the viewport if at the bottom."
  (interactive)
  (let ((col (current-column)))
    (if (>= (line-number-at-pos) (line-number-at-pos (point-max)))
        (when ghostel--term
          (ghostel--scroll ghostel--term 1)
          (let ((inhibit-read-only t))
            (ghostel--redraw ghostel--term ghostel-full-redraw))
          (goto-char (point-max))
          (beginning-of-line))
      (forward-line 1))
    (move-to-column col)))

(defun ghostel-copy-mode-beginning-of-buffer ()
  "Scroll to the top of scrollback in copy mode."
  (interactive)
  (when ghostel--term
    (ghostel--scroll-top ghostel--term)
    (let ((inhibit-read-only t))
      (ghostel--redraw ghostel--term ghostel-full-redraw))
    (goto-char (point-min))))

(defun ghostel-copy-mode-end-of-buffer ()
  "Scroll to the bottom of scrollback in copy mode."
  (interactive)
  (when ghostel--term
    (ghostel--scroll-bottom ghostel--term)
    (let ((inhibit-read-only t))
      (ghostel--redraw ghostel--term ghostel-full-redraw))
    (goto-char (point-max))))

(defun ghostel-copy-mode-end-of-line ()
  "Move to the last non-whitespace character on the line."
  (interactive)
  (end-of-line)
  (skip-chars-backward " \t"))


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
    ;; Scrollback
    (define-key map (kbd "<mouse-4>")       #'ghostel--scroll-up)
    (define-key map (kbd "<mouse-5>")       #'ghostel--scroll-down)
    (define-key map (kbd "<wheel-up>")      #'ghostel--scroll-up)
    (define-key map (kbd "<wheel-down>")    #'ghostel--scroll-down)
    (define-key map (kbd "M-v")             #'ghostel-copy-mode-scroll-up)
    (define-key map (kbd "C-v")             #'ghostel-copy-mode-scroll-down)
    (define-key map (kbd "C-n")             #'ghostel-copy-mode-next-line)
    (define-key map (kbd "C-p")             #'ghostel-copy-mode-previous-line)
    (define-key map (kbd "M-<")             #'ghostel-copy-mode-beginning-of-buffer)
    (define-key map (kbd "M->")             #'ghostel-copy-mode-end-of-buffer)
    (define-key map (kbd "C-e")             #'ghostel-copy-mode-end-of-line)
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
The display is frozen and standard Emacs navigation keys work.
Set mark, navigate to select, then \\[ghostel-copy-mode-copy] to copy.
Press \\`q' or \\[ghostel-copy-mode-exit] to exit without copying."
  (interactive)
  (if ghostel--copy-mode-active
      (ghostel-copy-mode-exit)
    ;; Freeze display
    (setq ghostel--copy-mode-active t)
    (when ghostel--redraw-timer
      (cancel-timer ghostel--redraw-timer)
      (setq ghostel--redraw-timer nil))
    ;; Ensure cursor is visible for navigation
    (setq ghostel--saved-cursor-type cursor-type)
    (setq cursor-type (default-value 'cursor-type))
    ;; Switch to copy mode keymap (standard Emacs keys work by default)
    (setq ghostel--saved-local-map (current-local-map))
    (use-local-map ghostel-copy-mode-map)
    (when ghostel--saved-hl-line-mode
      (hl-line-mode 1))
    (setq buffer-read-only t)
    (setq mode-name "Ghostel:Copy")
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
    (setq mode-name "Ghostel")
    (force-mode-line-update)
    (ghostel--invalidate)
    (message "Copy mode exited")))

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

(defun ghostel--detect-urls ()
  "Scan the buffer for plain-text URLs and file:line references.
Skips regions that already have a `help-echo' property (e.g. from OSC 8)."
  (save-excursion
    ;; Pass 1: http(s) URLs
    (when ghostel-enable-url-detection
      (goto-char (point-min))
      (while (re-search-forward
              "https?://[^ \t\n\r\"<>]*[^ \t\n\r\"<>.,;:!?)>]"
              nil t)
        (let ((beg (match-beginning 0))
              (end (match-end 0)))
          (unless (get-text-property beg 'help-echo)
            (let ((url (match-string-no-properties 0)))
              (put-text-property beg end 'help-echo url)
              (put-text-property beg end 'mouse-face 'highlight)
              (put-text-property beg end 'keymap ghostel-link-map))))))
    ;; Pass 2: file:line references (e.g. "./foo.el:42" or "/tmp/bar.rs:10")
    (when ghostel-enable-file-detection
      (goto-char (point-min))
      (while (re-search-forward
              "\\(?:\\./\\|/\\)[^ \t\n\r:\"<>]+:[0-9]+"
              nil t)
        (let ((beg (match-beginning 0))
              (end (match-end 0)))
          (unless (get-text-property beg 'help-echo)
            (let* ((text (match-string-no-properties 0))
                   (sep (string-match ":[0-9]+\\'" text))
                   (path (substring text 0 sep))
                   (line (substring text (1+ sep)))
                   (abs-path (expand-file-name path)))
              (when (file-exists-p abs-path)
                (put-text-property beg end 'help-echo
                                   (concat "fileref:" abs-path ":" line))
                (put-text-property beg end 'mouse-face 'highlight)
                (put-text-property beg end 'keymap ghostel-link-map)))))))))


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
        (apply (cadr entry) args)
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
  "Update the buffer name with TITLE from the terminal."
  (rename-buffer (format "*ghostel: %s*" title) t))

(defun ghostel--set-cursor-style (style visible)
  "Set the cursor style based on terminal state.
STYLE is one of: 0=bar, 1=block, 2=underline, 3=hollow-block.
VISIBLE is t or nil."
  (setq cursor-type
        (if visible
            (pcase style
              (0 '(bar . 2))       ; bar
              (1 'box)             ; block
              (2 '(hbar . 2))      ; underline
              (3 'hollow)          ; hollow block
              (_ 'box))
          nil)))

(defun ghostel--update-directory (dir)
  "Update `default-directory' from terminal's OSC 7 report.
DIR may be a file:// URL or a plain path."
  (when (and dir (not (equal dir ghostel--last-directory)))
    (setq ghostel--last-directory dir)
    (let ((path (if (string-prefix-p "file://" dir)
                    (url-filename (url-generic-parse-url dir))
                  dir)))
      (when (and path (file-directory-p path))
        (setq default-directory (file-name-as-directory path))))))


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
  "Apply colors from `ghostel-color-palette' faces to TERM."
  (when (and term ghostel-color-palette)
    (let ((colors
           (mapconcat
            (lambda (face)
              (ghostel--face-hex-color face :foreground))
            ghostel-color-palette
            "")))
      (ghostel--set-palette term colors))))


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
when the redraw timer fires, reducing per-call VT parser overhead."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when ghostel--term
        ;; Accumulate output for batched write-input at redraw time.
        (push output ghostel--pending-output)
        ;; Schedule redraw (which will flush pending output first).
        (ghostel--invalidate)))))

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
        (when ghostel--resize-timer
          (cancel-timer ghostel--resize-timer)
          (setq ghostel--resize-timer nil))
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

(defun ghostel--start-process ()
  "Start the shell process with a PTY."
  (let* ((height (max 1 (window-body-height)))
         (width (max 1 (window-max-chars-per-line)))
         (ghostel-dir (file-name-directory
                       (or (locate-library "ghostel")
                           load-file-name buffer-file-name
                           default-directory)))
         (shell-type (and ghostel-shell-integration
                          (ghostel--detect-shell ghostel-shell)))
         (integration-env
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
                            integ-dir))))))))
         ;; Only add --posix when bash injection actually succeeded.
         (shell-command (if (and (eq shell-type 'bash) integration-env)
                            (list ghostel-shell "--posix")
                          (list ghostel-shell)))
         (process-environment
          (append
           (list
            "INSIDE_EMACS=ghostel"
            (format "EMACS_GHOSTEL_PATH=%s" ghostel-dir)
            "TERM=xterm-256color"
            "COLORTERM=truecolor"
            (format "COLUMNS=%d" width)
            (format "LINES=%d" height))
           integration-env
           process-environment))
         (proc (make-process
                :name "ghostel"
                :buffer (current-buffer)
                :command shell-command
                :connection-type 'pty
                :filter #'ghostel--filter
                :sentinel #'ghostel--sentinel)))
    (setq ghostel--process proc)
    ;; Raw binary I/O — no encoding/decoding by Emacs
    (set-process-coding-system proc 'binary 'binary)
    ;; Set the PTY's actual window size (ioctl TIOCSWINSZ) so that
    ;; the shell's line editor (readline/ZLE) can render properly.
    (set-process-window-size proc height width)
    (set-process-query-on-exit-flag proc nil)
    ;; iutf8: kernel-level UTF-8 awareness so backspace correctly
    ;; erases multi-byte characters.  Useful for all shells.
    ;; stty echo: bash-only — readline buffers its own echo, so we
    ;; need PTY-level echo.  When bash integration is active, the
    ;; integration script handles echo; we still set iutf8 here.
    ;; Leading space keeps it out of history (HISTCONTROL=ignorespace).
    ;; The clear-screen sequence (\e[H\e[2J) hides the command itself.
    (let ((stty-cmd (if (and (eq (ghostel--detect-shell ghostel-shell) 'bash)
                             (not integration-env))
                        "stty iutf8 echo"
                      "stty iutf8")))
      (process-send-string
       proc (concat " " stty-cmd "; printf '\\e[H\\e[2J'\n")))
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
      (ghostel--write-input ghostel--term combined))))

(defun ghostel--delayed-redraw (buffer)
  "Perform the actual redraw in BUFFER."
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
          (let ((inhibit-read-only t)
                (inhibit-redisplay t)
                (inhibit-modification-hooks t))
            (ghostel--redraw ghostel--term ghostel-full-redraw)
            (ghostel--pin-window-start)))))))

(defun ghostel--pin-window-start ()
  "Pin the window so terminal row 1 stays at the top."
  (let ((win (get-buffer-window)))
    (when win
      (set-window-start win (point-min)))))

(defun ghostel-force-redraw ()
  "Force a full terminal redraw (for debugging)."
  (interactive)
  (when ghostel--term
    (let ((inhibit-read-only t))
      (ghostel--redraw ghostel--term ghostel-full-redraw)
      (ghostel--pin-window-start))))


;;; Window resize

(defun ghostel--window-adjust-process-window-size (process windows)
  "Resize the terminal to match the new Emacs window dimensions.
PROCESS is the shell process, WINDOWS is the list of windows."
  (let* ((window (car windows))
         (width (window-max-chars-per-line window))
         (height (window-body-height window)))
    (when ghostel--term
      (if (ghostel--mode-enabled ghostel--term 1049)
          ;; Alt screen: debounce the entire resize (terminal + SIGWINCH)
          ;; so we never interrupt a BSU/ESU cycle mid-render.
          (progn
            (when ghostel--resize-timer
              (cancel-timer ghostel--resize-timer))
            (setq ghostel--resize-timer
                  (run-with-timer 0.05 nil
                                  #'ghostel--resize-settled
                                  (current-buffer) process height width)))
        ;; Primary screen: resize + SIGWINCH + render immediately.
        (ghostel--set-size ghostel--term height width)
        (when (process-live-p process)
          (set-process-window-size process height width))
        (setq ghostel--force-next-redraw t)
        (ghostel--invalidate)))
    (cons width height)))

(defun ghostel--resize-settled (buffer process height width)
  "Resize terminal in BUFFER and send SIGWINCH after debounce settles.
Renders synchronously before returning to the event loop so the
reflowed content is visible before the app's BSU can arrive.
PROCESS is the shell, HEIGHT and WIDTH the final dimensions."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ghostel--resize-timer nil)
      (when ghostel--term
        (ghostel--set-size ghostel--term height width)
        (when (and process (process-live-p process))
          (set-process-window-size process height width))
        ;; Render NOW, before returning to the event loop.
        ;; The app's BSU response can't arrive until we return.
        (let ((inhibit-read-only t)
              (inhibit-redisplay t)
              (inhibit-modification-hooks t))
          (ghostel--redraw ghostel--term ghostel-full-redraw)
          (ghostel--pin-window-start))))))



;;; Major mode

(define-derived-mode ghostel-mode fundamental-mode "Ghostel"
  "Major mode for Ghostel terminal emulator."
  (buffer-disable-undo)
  (font-lock-mode -1)
  (setq buffer-read-only nil)
  (setq-local scroll-margin 0)
  (setq-local hscroll-margin 0)
  (setq-local truncate-lines t)
  (setq-local scroll-conservatively 101)
  (setq-local line-spacing 0)
  (setq-local window-adjust-process-window-size-function
              #'ghostel--window-adjust-process-window-size)
  (add-function :after after-focus-change-function #'ghostel--focus-change))

(defun ghostel--suppress-hl-line-mode ()
  "Disable hl-line highlighting to prevent redraw flicker.
Handles both `global-hl-line-mode' (which manages its own overlay via
`post-command-hook', independent of the buffer-local `hl-line-mode')
and buffer-local `hl-line-mode'."
  ;; global-hl-line-mode: opt this buffer out by setting the variable
  ;; buffer-locally to nil (as documented in the hl-line.el commentary).
  (when (bound-and-true-p global-hl-line-mode)
    (setq ghostel--saved-hl-line-mode t)
    (setq-local global-hl-line-mode nil)
    (global-hl-line-unhighlight))
  ;; Buffer-local hl-line-mode
  (when (bound-and-true-p hl-line-mode)
    (setq ghostel--saved-hl-line-mode t)
    (hl-line-mode -1)))

(add-hook 'ghostel-mode-hook #'ghostel--suppress-hl-line-mode)


;;; Entry point

;;;###autoload
(defun ghostel ()
  "Create a new Ghostel terminal buffer."
  (interactive)
  (let* ((index (cl-incf ghostel--buffer-counter))
         (buf-name (if (= index 1)
                       ghostel-buffer-name
                     (format "%s<%d>" ghostel-buffer-name index)))
         (buffer (generate-new-buffer buf-name)))
    (with-current-buffer buffer
      (ghostel-mode)
      (let* ((height (window-body-height))
             (width (window-max-chars-per-line)))
        (setq ghostel--term
              (ghostel--new height width ghostel-max-scrollback))
        (ghostel--apply-palette ghostel--term))
      (ghostel--start-process))
    (switch-to-buffer buffer)))

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
        (switch-to-buffer (car others))
      (ghostel))))

(provide 'ghostel)

;;; ghostel.el ends here
