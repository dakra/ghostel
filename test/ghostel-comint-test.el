;;; ghostel-comint-test.el --- Tests for ghostel-comint -*- lexical-binding: t; -*-

;;; Commentary:

;; Stream-filter tests for ghostel-comint.  All tagged `(native)' since
;; they exercise the Zig comint_filter / libghostty Stream wrapper.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-comint)

(declare-function ghostel--comint-make-state "ghostel-module")
(declare-function ghostel--comint-filter "ghostel-module")
(declare-function ghostel--comint-set-palette "ghostel-module")

(defmacro ghostel-comint-test--with-state (var &rest body)
  "Bind VAR to a fresh comint filter state and evaluate BODY.
The state is given a predictable palette so test assertions do not
depend on the user's `ghostel-color-palette' faces."
  (declare (indent 1))
  `(let ((,var (ghostel--comint-make-state)))
     ;; Standard 16-color palette (xterm-ish) so tests don't depend on
     ;; the user's ghostel-color-palette faces.
     (ghostel--comint-set-palette
      ,var
      (concat "#000000" "#cd0000" "#00cd00" "#cdcd00"
              "#0000ee" "#cd00cd" "#00cdcd" "#e5e5e5"
              "#7f7f7f" "#ff0000" "#00ff00" "#ffff00"
              "#5c5cff" "#ff00ff" "#00ffff" "#ffffff"))
     ,@body))

(defun ghostel-comint-test--feed (state &rest chunks)
  "Concatenate the results of feeding each of CHUNKS into STATE."
  (mapconcat (lambda (chunk) (ghostel--comint-filter state chunk))
             chunks
             ""))

(defun ghostel-comint-test--face-at (string pos)
  "Return the `face' text property at POS in STRING."
  (get-text-property pos 'face string))


;;; SGR coverage

(ert-deftest ghostel-comint-test-sgr-basic ()
  "SGR 31 / 0 colours the right text and stops at reset.
After reset, the unstyled run carries no face at all so the comint
buffer's default fg/bg shows through (xterm-color behavior)."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let* ((out (ghostel-comint-test--feed
                 state "\e[31mhello\e[0m world\n"))
           (face-hello (ghostel-comint-test--face-at out 0))
           (face-world (ghostel-comint-test--face-at out 7)))
      (should (equal out "hello world\n"))
      (should (equal (plist-get face-hello :foreground) "#cd0000"))
      ;; Default fg should not be painted explicitly — buffer default
      ;; shows through.
      (should (null (plist-get face-hello :background)))
      (should (null face-world)))))

(ert-deftest ghostel-comint-test-sgr-overline ()
  "SGR 53 / 55 emits `:overline t' on / off."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let* ((out (ghostel-comint-test--feed
                 state "\e[53mtop\e[55m off"))
           (face-on (ghostel-comint-test--face-at out 0))
           (face-off (ghostel-comint-test--face-at out 3)))
      (should (equal out "top off"))
      (should (eq (plist-get face-on :overline) t))
      (should (null face-off)))))

(ert-deftest ghostel-comint-test-sgr-inverse-uses-inverse-video ()
  "SGR 7 emits `:inverse-video t' rather than swapping fg/bg manually.
That way an unstyled-but-inverted run swaps against the comint
buffer's actual default face, not against ghostel-default colours."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let* ((out (ghostel-comint-test--feed
                 state "\e[7mflip\e[0m"))
           (face (ghostel-comint-test--face-at out 0)))
      (should (equal out "flip"))
      (should (eq (plist-get face :inverse-video) t))
      ;; No manual swap: neither fg nor bg should be set since the
      ;; SGR didn't pick concrete colours.
      (should (null (plist-get face :foreground)))
      (should (null (plist-get face :background))))))

(ert-deftest ghostel-comint-test-sgr-256 ()
  "256-color SGR (`\\e[38;5;Nm') sets the expected palette entry.
Index 202 in the 6x6x6 cube is (r=5, g=1, b=0) which libghostty
computes as `(if r==0 0 else r*40+55)' per channel, giving #ff5f00."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let* ((out (ghostel-comint-test--feed
                 state "\e[38;5;202morange\e[0m"))
           (face (ghostel-comint-test--face-at out 0)))
      (should (equal out "orange"))
      (should (equal (plist-get face :foreground) "#ff5f00")))))

(ert-deftest ghostel-comint-test-sgr-truecolor ()
  "Truecolor SGR sets exactly the requested RGB."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let* ((out (ghostel-comint-test--feed
                 state "\e[38;2;255;128;0mrgb\e[0m"))
           (face (ghostel-comint-test--face-at out 0)))
      (should (equal out "rgb"))
      (should (equal (plist-get face :foreground) "#ff8000")))))

(ert-deftest ghostel-comint-test-sgr-curly-underline ()
  "Colon-separator SGR `\\e[4:3m' yields curly underline (wave style)."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let* ((out (ghostel-comint-test--feed
                 state "\e[4:3mtypo\e[0m"))
           (face (ghostel-comint-test--face-at out 0)))
      (should (equal out "typo"))
      (should (equal (plist-get (plist-get face :underline) :style) 'wave)))))

(ert-deftest ghostel-comint-test-sgr-italic-and-strikethrough ()
  "Italic (3) and strikethrough (9) both reach the face plist."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let* ((out (ghostel-comint-test--feed
                 state "\e[3;9mboth\e[0m"))
           (face (ghostel-comint-test--face-at out 0)))
      (should (equal out "both"))
      (should (eq (plist-get face :slant) 'italic))
      (should (eq (plist-get face :strike-through) t)))))


;;; State persistence across chunks

(ert-deftest ghostel-comint-test-sgr-carryover ()
  "SGR state persists across separate filter calls."
  :tags '(native)
  (ghostel-comint-test--with-state state
    ;; First chunk: just the colour, no text.
    (let ((first (ghostel--comint-filter state "\e[31m")))
      (should (equal first "")))
    ;; Second chunk: text alone — must still come out red.
    (let* ((out (ghostel--comint-filter state "red\n"))
           (face (ghostel-comint-test--face-at out 0)))
      (should (equal out "red\n"))
      (should (equal (plist-get face :foreground) "#cd0000")))))


;;; Non-SGR escapes are dropped

(ert-deftest ghostel-comint-test-cursor-sequences-stripped ()
  "Cursor / erase escapes leave no bytes in the output."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (should (equal (ghostel--comint-filter state "\e[2J\e[Hhello\n")
                   "hello\n"))))

(ert-deftest ghostel-comint-test-dcs-stripped ()
  "DCS sequences are consumed without leaking their payload."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (should (equal (ghostel--comint-filter state "\ePxyz\e\\after\n")
                   "after\n"))))


;;; C0 control passthrough

(ert-deftest ghostel-comint-test-cr-passthrough ()
  "Raw CR is forwarded so `comint-carriage-motion' can handle it."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (should (equal (ghostel--comint-filter state "Hello\rWorld\n")
                   "Hello\rWorld\n"))))

(ert-deftest ghostel-comint-test-bs-tab-passthrough ()
  "Backspace and tab are forwarded as raw bytes."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (should (equal (ghostel--comint-filter state "a\b\tb")
                   "a\b\tb"))))


;;; OSC 8 hyperlinks

(ert-deftest ghostel-comint-test-osc8-hyperlink ()
  "OSC 8 wraps text with help-echo (URI) and a clickable mouse-face."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let* ((out (ghostel-comint-test--feed
                 state
                 "\e]8;;https://example.com\e\\link\e]8;;\e\\"))
           (help (get-text-property 0 'help-echo out))
           (mouse (get-text-property 0 'mouse-face out))
           (keymap (get-text-property 0 'keymap out)))
      (should (equal out "link"))
      (should (equal help "https://example.com"))
      (should (eq mouse 'highlight))
      (should (eq keymap ghostel-link-map)))))


;;; OSC 7 dirtrack

(ert-deftest ghostel-comint-test-osc7-dirtrack ()
  "OSC 7 updates `default-directory' through `ghostel-comint--update-dir'."
  :tags '(native)
  (let ((calls nil))
    (cl-letf (((symbol-function 'ghostel-comint--update-dir)
               (lambda (uri) (push uri calls))))
      (ghostel-comint-test--with-state state
        (ghostel--comint-filter
         state "\e]7;file://localhost/tmp/foo\e\\")))
    (should (equal calls '("file://localhost/tmp/foo")))))


;;; font-lock interaction

(ert-deftest ghostel-comint-test-font-lock-face-swap ()
  "Filter rewrites `face' to `font-lock-face' when `font-lock-mode' is on.
Without the swap, font-lock's unfontify pass strips our colours on the
next redisplay (see `ghostel-comint--face-to-font-lock-face' for the
why).

We can't actually run `font-lock-mode' in a batch test — it's a no-op
under `noninteractive' (see `font-lock-mode' definition in font-core.el).
So we bind the buffer-local `font-lock-mode' variable directly to t and
just check that the swap happens — which is the only behavior under our
control.  The wider claim (that `font-lock-face' survives where `face'
gets stripped) is verified by the standalone batch test in the commit
notes."
  :tags '(native)
  (with-temp-buffer
    (setq-local font-lock-mode t)
    (ghostel-comint-test--with-state state
      (setq ghostel-comint--state state)
      (let ((out (ghostel-comint-filter "\e[31mred\e[0m")))
        (should (equal out "red"))
        ;; Face has been moved off; font-lock-face holds our colour.
        (should (null (get-text-property 0 'face out)))
        (should (equal (plist-get (get-text-property 0 'font-lock-face out)
                                  :foreground)
                       "#cd0000"))))))

(ert-deftest ghostel-comint-test-no-font-lock-leaves-face-alone ()
  "When `font-lock-mode' is off, filter keeps the property name as `face'."
  :tags '(native)
  (with-temp-buffer
    ;; font-lock-mode is buffer-local and defaults to nil.
    (should (not font-lock-mode))
    (ghostel-comint-test--with-state state
      (setq ghostel-comint--state state)
      (let ((out (ghostel-comint-filter "\e[31mred\e[0m")))
        (should (equal out "red"))
        (should (equal (plist-get (get-text-property 0 'face out)
                                  :foreground)
                       "#cd0000"))
        (should (null (get-text-property 0 'font-lock-face out)))))))


;;; Multi-byte content

(ert-deftest ghostel-comint-test-multibyte ()
  "Multi-byte glyphs round-trip through the parser."
  :tags '(native)
  (ghostel-comint-test--with-state state
    (let ((out (ghostel-comint-test--feed
                state "\e[32m✓\e[0m done\n")))
      (should (equal out "✓ done\n"))
      (should (equal (plist-get
                      (ghostel-comint-test--face-at out 0)
                      :foreground)
                     "#00cd00")))))

(provide 'ghostel-comint-test)
;;; ghostel-comint-test.el ends here
