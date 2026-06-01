;;; ghostel-links-test.el --- Tests for ghostel: links -*- lexical-binding: t; -*-

;;; Commentary:

;; Hyperlink behavior across sources: renderer-backed OSC 8 links,
;; plain-text URL/file detection, opening links, and link navigation.

;;; Code:

(require 'ghostel-test-helpers)

;;; OSC 8 hyperlinks

(ert-deftest ghostel-test-osc8-renders-uri-help-echo ()
  "OSC8 links set `help-echo' directly to the URI string."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf term 5 80 1000)
                                      (let ((inhibit-read-only t))
                                        (ghostel--write-input term "\e]8;;https://example.com\e\\link text\e]8;;\e\\")
                                        (ghostel--redraw term t)
                                        (goto-char (point-min))
                                        (let* ((end (search-forward "link text" nil t))
                                               (link-pos (- end (length "link text"))))
                                          (should end)
                                          (should (equal "https://example.com"
                                                         (get-text-property link-pos 'help-echo)))
                                          (should (keymapp (get-text-property link-pos 'keymap)))))))

(ert-deftest ghostel-test-osc8-no-help-echo-outside-link ()
  "Non-link cells do not carry an OSC8 `help-echo' URI."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf term 5 80 1000)
                                      (let ((inhibit-read-only t))
                                        (ghostel--write-input term "plain text")
                                        (ghostel--redraw term t)
                                        (goto-char (point-min))
                                        (should (null (get-text-property (point) 'help-echo))))))

(ert-deftest ghostel-test-osc8-shared-id-emits-link-id-property ()
  "OSC 8 chunks sharing `id=foo' carry equal `ghostel-link-id' text properties.
Distinct ids and implicit (no-id) links each get unique values, so elisp
`equal' can dedupe only the matching chunks."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf term 5 80 1000)
                                      (let ((inhibit-read-only t))
                                        (ghostel--write-input
                                         term
                                         (concat
                                          "\e]8;id=A;https://shared.example\e\\foo\e]8;;\e\\ "
                                          "\e]8;id=B;https://other.example\e\\bar\e]8;;\e\\ "
                                          "\e]8;id=A;https://shared.example\e\\baz\e]8;;\e\\ "
                                          "\e]8;;https://implicit.example\e\\qux\e]8;;\e\\ "
                                          "\e]8;;https://implicit.example\e\\zot\e]8;;\e\\"))
                                        (ghostel--redraw term t)
                                        (goto-char (point-min))
                                        (let ((foo (progn (search-forward "foo") (- (point) 3)))
                                              (bar (progn (search-forward "bar") (- (point) 3)))
                                              (baz (progn (search-forward "baz") (- (point) 3)))
                                              (qux (progn (search-forward "qux") (- (point) 3)))
                                              (zot (progn (search-forward "zot") (- (point) 3))))
                                          ;; Same explicit id → equal property value.
                                          (should (equal "A" (get-text-property foo 'ghostel-link-id)))
                                          (should (equal "A" (get-text-property baz 'ghostel-link-id)))
                                          (should (equal "B" (get-text-property bar 'ghostel-link-id)))
                                          ;; Implicit links are integers; two separate OSC 8 sequences
                                          ;; without `id=' get distinct counters (ghostty bumps the
                                          ;; implicit counter on every startHyperlink), so they never
                                          ;; equal each other and dedupe never kicks in for them.
                                          (should (integerp (get-text-property qux 'ghostel-link-id)))
                                          (should (integerp (get-text-property zot 'ghostel-link-id)))
                                          (should-not (equal (get-text-property qux 'ghostel-link-id)
                                                             (get-text-property zot 'ghostel-link-id)))))))

(ert-deftest ghostel-test-osc8-shared-id-navigation-dedupes ()
  "`ghostel-next/previous-hyperlink' stop once per OSC 8 id (issue #125).
Feeds the scenario from the issue: a single logical URL emitted as two
OSC 8 chunks with `id=wrap', separated by intervening text on a new
row.  Navigation should land on the link only once, not on each chunk."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf term 5 80 1000)
                                      (let ((inhibit-read-only t))
                                        (ghostel--write-input
                                         term
                                         (concat
                                          "\e]8;id=wrap;https://wrapped.example\e\\http://exa\e]8;;\e\\\r\n"
                                          "│ middle text │\r\n"
                                          "\e]8;id=wrap;https://wrapped.example\e\\mple.com\e]8;;\e\\\r\n"
                                          "\e]8;id=other;https://other.example\e\\next\e]8;;\e\\"))
                                        (ghostel--redraw term t)
                                        (goto-char (point-min))
                                        (let ((chunk1 (progn (search-forward "http://exa") (- (point) 10)))
                                              (chunk2 (progn (search-forward "mple.com") (- (point) 8)))
                                              (other (progn (search-forward "next") (- (point) 4))))
                                          ;; Same id on both chunks.
                                          (should (equal "wrap" (get-text-property chunk1 'ghostel-link-id)))
                                          (should (equal "wrap" (get-text-property chunk2 'ghostel-link-id)))
                                          (should (equal "other" (get-text-property other 'ghostel-link-id)))
                                          ;; From inside chunk1, forward skips chunk2 (same id), lands on `next'.
                                          (should (equal other (ghostel--find-next-link chunk1)))
                                          ;; From inside chunk2, forward also lands on `next' (no skip,
                                          ;; since `other' has a different id).
                                          (should (equal other (ghostel--find-next-link chunk2)))
                                          ;; From inside chunk2, backward skips chunk1 (same id), no link left.
                                          (should (null (ghostel--find-previous-link chunk2)))
                                          ;; From inside `next', backward walks back over chunk2 (same id)
                                          ;; and lands on chunk1, the URL's first chunk.
                                          (should (equal chunk1 (ghostel--find-previous-link other)))))))

(ert-deftest ghostel-test-osc8-help-echo-two-links ()
  "OSC8 links store the correct URI string on each `help-echo'."
  :tags '(native)
  (ghostel-test--with-terminal-buffer (_buf term 5 80 1000)
                                      (let ((inhibit-read-only t))
                                        (ghostel--write-input
                                         term
                                         (concat "\e]8;;https://first.example\e\\first\e]8;;\e\\"
                                                 " and "
                                                 "\e]8;;https://second.example\e\\second\e]8;;\e\\"))
                                        (ghostel--redraw term t)
                                        (goto-char (point-min))
                                        (let* ((first-end (search-forward "first" nil t))
                                               (first-pos (- first-end (length "first")))
                                               (second-end (search-forward "second" nil t))
                                               (second-pos (- second-end (length "second"))))
                                          (should first-end)
                                          (should second-end)
                                          (should (equal "https://first.example"
                                                         (get-text-property first-pos 'help-echo)))
                                          (should (equal "https://second.example"
                                                         (get-text-property second-pos 'help-echo)))))))


;;; Hyperlinks and URL rendering

(ert-deftest ghostel-test-hyperlinks ()
  "Test hyperlink keymap and helpers."
  :tags '(native)
  (should (keymapp ghostel-link-map))                      ; ghostel-link-map is a keymap
  (should (lookup-key ghostel-link-map [mouse-1]))         ; mouse-1 bound in link map
  (should (lookup-key ghostel-link-map [mouse-2]))         ; mouse-2 bound in link map
  ;; RET is intentionally NOT bound in the text-property link map: a
  ;; binding there outranks the local map and hijacks RET away from the
  ;; PTY when a typed substring is misdetected as a link.  The
  ;; RET-follows-link affordance lives in the read-only and line-mode
  ;; maps so it works in copy, Emacs, and line modes without
  ;; intercepting RET in semi-char/char.
  (should (null (lookup-key ghostel-link-map (kbd "RET"))))
  (should (eq #'ghostel-open-link-at-point
              (lookup-key ghostel-readonly-mode-map (kbd "RET"))))
  (should (eq #'ghostel-open-link-at-point
              (lookup-key ghostel-readonly-mode-map (kbd "<return>"))))
  (should (eq #'ghostel-line-mode-send-or-open-link
              (lookup-key ghostel-line-mode-map (kbd "RET"))))
  (should (eq #'ghostel-line-mode-send-or-open-link
              (lookup-key ghostel-line-mode-map (kbd "<return>"))))
  (should (commandp #'ghostel-open-link-at-point))         ; open-link-at-point is interactive
  (should (null (ghostel--open-link nil)))                 ; open-link returns nil for empty
  (should (null (ghostel--open-link 42))))

(ert-deftest ghostel-test-uri-at-pos-returns-string-help-echo ()
  "`ghostel--uri-at-pos' returns a string `help-echo'."
  (with-temp-buffer
    (insert "click here")
    (put-text-property 1 11 'help-echo "https://static.example.com")
    (goto-char 5)
    (should (equal "https://static.example.com"
                   (ghostel--uri-at-pos (point))))))

(ert-deftest ghostel-test-uri-at-pos-ignores-non-string-help-echo ()
  "`ghostel--uri-at-pos' ignores non-string `help-echo' values."
  (with-temp-buffer
    (insert "click here")
    (put-text-property 1 11 'help-echo #'ignore)
    (goto-char 5)
    (should (null (ghostel--uri-at-pos (point))))))

(ert-deftest ghostel-test-url-detection ()
  "Test automatic URL detection in plain text."
  ;; Test buffers add a trailing newline so point lands on an empty line
  ;; below the test content; the cursor-row skip in `ghostel--detect-urls'
  ;; then leaves the test content untouched.
  ;; Basic URL detection
  (with-temp-buffer
    (insert "Visit https://example.com for info\n")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com"                   ; url help-echo
                   (get-text-property 7 'help-echo)))
    (should (get-text-property 7 'mouse-face))             ; url mouse-face
    (should (get-text-property 7 'keymap)))                ; url keymap
  ;; Disabled detection
  (with-temp-buffer
    (insert "Visit https://example.com for info\n")
    (let ((ghostel-enable-url-detection nil))
      (ghostel--detect-urls))
    (should (null (get-text-property 7 'help-echo))))      ; url detection disabled
  ;; Skips existing links.
  (with-temp-buffer
    (insert "Visit https://other.com for info\n")
    (put-text-property 7 26 'help-echo "https://osc8.example")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://osc8.example"                 ; existing link not overwritten
                   (get-text-property 7 'help-echo))))
  ;; URL not ending in punctuation
  (with-temp-buffer
    (insert "See https://example.com/path.\n")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com/path"              ; url strips trailing dot
                   (get-text-property 5 'help-echo))))
  ;; File:line detection with absolute path
  (let ((test-file (locate-library "ghostel")))
    (with-temp-buffer
      (insert (format "Error at %s:42 bad\n" test-file))
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (let ((he (get-text-property 10 'help-echo)))
        (should (and he (string-prefix-p "fileref:" he)))  ; file:line help-echo set
        (should (and he (string-suffix-p ":42" he)))))     ; file:line contains line number
    ;; File:line for non-existent file produces no link
    (with-temp-buffer
      (insert "Error at /no/such/file.el:10 bad\n")
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; nonexistent file: no help-echo
    ;; File detection disabled
    (with-temp-buffer
      (insert (format "Error at %s:42 bad\n" test-file))
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; file detection disabled
    ;; ghostel--open-link dispatches fileref:
    (let ((opened nil))
      (cl-letf (((symbol-function 'find-file-other-window)
                 (lambda (f) (setq opened f))))
        (ghostel--open-link (format "fileref:%s:10" test-file)))
      (should (equal test-file opened)))                   ; fileref opens correct file
    ;; Helper: find the first fileref help-echo anywhere in the buffer.
    (cl-flet ((find-fileref ()
                (save-excursion
                  (let ((pos (point-min)) found)
                    (while (and (not found) pos (< pos (point-max)))
                      (let ((he (get-text-property pos 'help-echo)))
                        (when (and he (string-prefix-p "fileref:" he))
                          (setq found he)))
                      (setq pos (next-single-property-change
                                 pos 'help-echo nil (point-max))))
                    found))))
      ;; Bare relative path (Rust/Go/TS compiler output)
      (let ((dir (file-name-directory test-file))
            (rel "ghostel.el"))
        ;; Nonexistent bare relative path: no link
        (with-temp-buffer
          (setq default-directory dir)
          (insert (format "   --> wrapped/%s:43\n" rel))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (should (null (find-fileref))))           ; nonexistent bare path skipped
        ;; Existing bare relative path: linkified with line AND column preserved
        (with-temp-buffer
          (setq default-directory (file-name-directory (directory-file-name dir)))
          (insert (format "  --> %s/%s:43:4\n"
                          (file-name-nondirectory (directory-file-name dir))
                          rel))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (let ((he (find-fileref)))
            (should (and he (string-prefix-p "fileref:" he)))
            (should (and he (string-suffix-p ":43:4" he)))))) ; col preserved
      ;; Path embedded in punctuation (Python traceback style) must match
      (with-temp-buffer
        (insert (format "  at foo (%s:10:5)\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (let ((he (find-fileref)))
          (should (and he (string-prefix-p "fileref:" he)))   ; paren-wrapped path matched
          (should (and he (string-suffix-p ":10:5" he)))
          ;; Trailing `)' must NOT be absorbed into the path
          (should (and he (not (string-suffix-p ")" he))))))
      ;; Wrapper chars (backtick, paren, bracket, brace, quotes) around a
      ;; path-only reference must not bleed into the match.
      (dolist (wrap '(("`" . "`") ("(" . ")") ("[" . "]") ("{" . "}")
                      ("'" . "'") ("\"" . "\"")))
        (with-temp-buffer
          (insert (format "see %s%s%s here\n" (car wrap) test-file (cdr wrap)))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (let ((he (find-fileref)))
            (should (and he (string-prefix-p "fileref:" he)))
            (should (and he (string-suffix-p test-file he)))    ; no wrapper tail
            (should (and he (not (string-suffix-p (cdr wrap) he)))))))
      ;; Tilde-prefixed paths are detected and linkified.
      (let* ((tilde-path "~/.emacs.d/init.el:42")
             (tilde-file (expand-file-name ".emacs.d/init.el" (expand-file-name "~"))))
        ;; Existing tilde path is linkified.
        (with-temp-buffer
          (insert (format "Error at %s bad\n" tilde-path))
          (cl-letf (((symbol-function 'file-exists-p)
                     (lambda (f) (equal f tilde-file))))
            (let ((ghostel-enable-url-detection t))
              (ghostel--detect-urls))
            (let ((he (find-fileref)))
              (should (and he (string-prefix-p "fileref:" he)))
              (should (and he (string-suffix-p ":42" he)))))))
      ;; Bare filename without a slash must NOT match (avoids FS stat storms)
      (with-temp-buffer
        (setq default-directory (file-name-directory test-file))
        (insert "main.go:12:5: undefined: foo\n")
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (null (find-fileref))))            ; bare filename skipped
      ;; TRAMP `default-directory' disables file detection entirely — otherwise
      ;; every candidate would trigger a remote stat per redraw.
      (with-temp-buffer
        (setq default-directory "/ssh:example.com:/tmp/")
        (insert (format "see %s here\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (null (find-fileref))))            ; TRAMP → detection skipped
      ;; Custom path regex can opt into broader matching (bare filenames)
      (with-temp-buffer
        (setq default-directory (file-name-directory test-file))
        (insert "ghostel.el:42 here\n")
        (let ((ghostel-enable-url-detection t)
              (ghostel-file-detection-path-regex
               "[[:alnum:]_.][^ \t\n\r:\"<>]*"))
          (ghostel--detect-urls))
        (should (find-fileref)))                   ; custom path regex opts in
      ;; Path-only reference (no `:line' suffix): /absolute and ./relative
      ;; both linkify when the file exists.
      (with-temp-buffer
        (insert (format "see %s here\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (let ((he (find-fileref)))
          (should (and he (string-prefix-p "fileref:" he)))
          (should (and he (not (string-match-p ":[0-9]+\\'" he)))))) ; no line
      ;; Path-only reference for a nonexistent file is not linkified.
      (with-temp-buffer
        (insert "see /no/such/path/exists here\n")
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (null (find-fileref))))
      ;; ghostel--open-link with :line:col positions the cursor
      (let ((opened nil) (col-arg nil))
        (cl-letf (((symbol-function 'find-file-other-window)
                   (lambda (f) (setq opened f)))
                  ((symbol-function 'move-to-column)
                   (lambda (c &optional _force) (setq col-arg c))))
          (ghostel--open-link (format "fileref:%s:10:7" test-file)))
        (should (equal test-file opened))
        (should (equal 6 col-arg)))                  ; :col 7 → column 6 (0-indexed)
      ;; ghostel--open-link with path-only fileref opens the file without
      ;; moving point past `point-min'.
      (let ((opened nil) (moved nil))
        (cl-letf (((symbol-function 'find-file-other-window)
                   (lambda (f) (setq opened f)))
                  ((symbol-function 'forward-line)
                   (lambda (&rest _) (setq moved t))))
          (ghostel--open-link (format "fileref:%s" test-file)))
        (should (equal test-file opened))
        (should (null moved))))))

(ert-deftest ghostel-test-detect-urls-skips-active-input ()
  "Link detection rules around prompts and user input (issue #199).
- `ghostel-prompt' (shell-generated decoration): never linkified.
- The cursor's line (active typing): not linkified — in tty Emacs RET
  on a linkified cell hijacks the keystroke, and the cursor-row skip
  works for both OSC 133 shells and markerless REPLs (Gemini CLI etc).
- Other lines (historical typed commands, output): linkified, so users
  can follow paths in past commands and program output."
  :tags '(native)
  (let ((test-file (locate-library "ghostel")))
    ;; History line → both file ref and URL linkified.  Active line
    ;; (cursor's line) → both skipped, regardless of whether the cells
    ;; carry `ghostel-input' or not.
    (with-temp-buffer
      (let ((default-directory (file-name-directory test-file)))
        (insert (format "$ ls %s https://hist.example\n" test-file)) ; line 1: history
        (insert (format "$ cat %s https://live.example" test-file))  ; line 2: active
        (put-text-property (point-min) (point-max) 'ghostel-input t)
        (goto-char (point-max))                                       ; cursor on line 2
        (let ((ghostel-enable-url-detection t)
              (ghostel-enable-file-detection t))
          (ghostel--detect-urls))
        (goto-char (point-min))
        (search-forward test-file nil t)
        (let ((he (get-text-property (match-beginning 0) 'help-echo)))
          (should (and he (string-prefix-p "fileref:" he)))) ; history file → linked
        (search-forward "https://hist.example")
        (should (equal "https://hist.example"
                       (get-text-property (match-beginning 0) 'help-echo))) ; history URL → linked
        (search-forward test-file nil t)
        (should (null (get-text-property (match-beginning 0) 'help-echo))) ; active file → skipped
        (search-forward "https://live.example")
        (should (null (get-text-property (match-beginning 0) 'help-echo))))) ; active URL → skipped
    ;; Cursor-row skip is unconditional: a URL on the cursor's line is
    ;; not linkified even when no `ghostel-input' marker covers it.  This
    ;; is what protects RET in REPLs like Gemini CLI or raw shells that
    ;; emit no OSC 133 sequences.  No trailing newline — cursor stays on
    ;; the typed line.
    (with-temp-buffer
      (insert "out https://before.example mid https://typed.example tail")
      (goto-char (point-max))                                           ; cursor on line 1
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (goto-char (point-min))
      (search-forward "https://before.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo))) ; cursor row → skipped
      (search-forward "https://typed.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo)))) ; cursor row → skipped
    ;; No OSC 133 markers at all (e.g. Gemini CLI prompt or a raw shell):
    ;; output on previous lines is still linkified, only the cursor row
    ;; is protected.
    (with-temp-buffer
      (insert "history https://past.example\n") ; line 1: previous output
      (insert "> https://typed.example tail")   ; line 2: REPL prompt with cursor
      (goto-char (point-max))                   ; cursor on line 2
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (goto-char (point-min))
      (search-forward "https://past.example")
      (should (equal "https://past.example"
                     (get-text-property (match-beginning 0) 'help-echo))) ; history → linked
      (search-forward "https://typed.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo)))) ; cursor row → skipped
    ;; `ghostel-prompt' (prompt prefix) is never linkified — neither on
    ;; the active line nor in scrollback.  Path appears in the prompt's
    ;; cwd display; output below is plain text and stays linkifiable.
    (with-temp-buffer
      (let ((default-directory (file-name-directory test-file)))
        (insert (format "%s λ ls\n" test-file))           ; line 1: prompt prefix
        (insert (format "%s\n" test-file))                ; line 2: output
        (insert (format "%s λ " test-file))               ; line 3: live prompt
        ;; Prompt rows carry `ghostel-prompt' on the prefix; output does not.
        (save-excursion
          (goto-char (point-min))
          (let ((eol (line-end-position)))
            (put-text-property (point-min) eol 'ghostel-prompt t))
          (forward-line 2)
          (put-text-property (point) (point-max) 'ghostel-prompt t))
        (goto-char (point-max))
        (let ((ghostel-enable-url-detection nil)
              (ghostel-enable-file-detection t))
          (ghostel--detect-urls))
        (goto-char (point-min))
        (search-forward test-file nil t)                  ; line 1: prompt prefix
        (should (null (get-text-property (match-beginning 0) 'help-echo)))
        (search-forward test-file nil t)                  ; line 2: output
        (should (get-text-property (match-beginning 0) 'help-echo))
        (search-forward test-file nil t)                  ; line 3: live prompt prefix
        (should (null (get-text-property (match-beginning 0) 'help-echo)))))))

(ert-deftest ghostel-test-delayed-redraw-defers-plain-link-detection ()
  "Redraw-triggered plain-text link detection should run after redraw."
  (let ((buf (generate-new-buffer " *ghostel-test-delayed-link*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term t)
                (ghostel--input-mode 'emacs)
                (ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (scheduled-count 0)
                timer-delay timer-repeat timer-fn timer-args)
            ;; FIXME: `ghostel--redraw' is stubbed because `ghostel--term'
            ;; here is the placeholder symbol `t', not a real native handle,
            ;; so the real renderer would crash.  The test still observes the
            ;; intended side effect (link-detection timer scheduling) via the
            ;; `run-with-timer' mock below.  A cleaner rewrite would require
            ;; spinning up a real terminal fixture.
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (delay repeat fn &rest args)
                         (setq scheduled-count (1+ scheduled-count)
                               timer-delay delay
                               timer-repeat repeat
                               timer-fn fn
                               timer-args args)
                         'ghostel-test-link-timer))
                      ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                      ((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--window-anchored-p) #'ignore)
                      ((symbol-function 'ghostel--viewport-start)
                       (lambda () nil)))
              (set-window-buffer (selected-window) buf)
              (let ((inhibit-read-only t))
                (insert "see https://example.com here\n"))
              (ghostel--delayed-redraw buf)
              (goto-char (point-min))
              (let* ((url "https://example.com")
                     (url-end (search-forward url nil t))
                     (url-beg (- url-end (length url))))
                (should url-end)
                (should (null (get-text-property url-beg 'help-echo)))
                (should (= scheduled-count 1))
                (should (numberp timer-delay))
                (should (> timer-delay 0))
                (should (null timer-repeat))
                (should timer-fn)
                ;; Move point off the URL line so the cursor-row skip in
                ;; `ghostel--detect-urls' doesn't mask the URL when the
                ;; queued detection runs.
                (goto-char (point-max))
                (apply timer-fn timer-args)
                (should (equal url
                               (get-text-property url-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-delayed-redraw-coalesces-plain-link-detection ()
  "Multiple redraws before the timer fires should share one detection pass."
  (let ((buf (generate-new-buffer " *ghostel-test-coalesced-link*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term t)
                (ghostel--input-mode 'emacs)
                (ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (scheduled-count 0)
                timer-repeat timer-fn timer-args)
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (_delay repeat fn &rest args)
                         (setq scheduled-count (1+ scheduled-count)
                               timer-repeat repeat
                               timer-fn fn
                               timer-args args)
                         'ghostel-test-link-timer))
                      ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                      ((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--window-anchored-p) #'ignore)
                      ((symbol-function 'ghostel--viewport-start)
                       (lambda () nil)))
              (set-window-buffer (selected-window) buf)
              (let ((inhibit-read-only t))
                (insert "first https://first.example\n"))
              (ghostel--delayed-redraw buf)
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (insert "second https://second.example\n"))
              (ghostel--delayed-redraw buf)
              (goto-char (point-min))
              (let* ((first-url "https://first.example")
                     (first-end (search-forward first-url nil t))
                     (first-beg (- first-end (length first-url)))
                     (second-url "https://second.example")
                     (second-end (search-forward second-url nil t))
                     (second-beg (- second-end (length second-url))))
                (should first-end)
                (should second-end)
                (should (null (get-text-property first-beg 'help-echo)))
                (should (null (get-text-property second-beg 'help-echo)))
                (should (= scheduled-count 1))
                (should (null timer-repeat))
                (should timer-fn)
                ;; Move point off the URL lines so the cursor-row skip in
                ;; `ghostel--detect-urls' doesn't mask either URL when the
                ;; queued detection runs.
                (goto-char (point-max))
                (apply timer-fn timer-args)
                (should (equal first-url
                               (get-text-property first-beg 'help-echo)))
                (should (equal second-url
                               (get-text-property second-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-detect-urls-allows-read-only-buffers ()
  "Plain-text link detection should still work in read-only buffers."
  (let* ((root (ghostel--resource-root))
         (test-file (file-relative-name
                     (expand-file-name "lisp/ghostel.el" root)
                     root)))
    (with-temp-buffer
      (let ((default-directory root))
        (insert (format "see %s:1 for details\n" test-file))
        (setq buffer-read-only t)
        (let ((ghostel-enable-url-detection nil)
              (ghostel-enable-file-detection t))
          (should (eq 'ok
                      (ignore-errors
                        (ghostel--detect-urls)
                        'ok)))
          (should (string-prefix-p
                   "fileref:"
                   (get-text-property 5 'help-echo))))))))

(ert-deftest ghostel-test-zero-delay-runs-plain-link-detection-synchronously ()
  "With delay set to 0, plain-link detection runs without scheduling a timer."
  (let ((buf (generate-new-buffer " *ghostel-test-zero-delay-link*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (ghostel-plain-link-detection-delay 0)
                (timer-scheduled nil)
                (inhibit-read-only t))
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (&rest _)
                         (setq timer-scheduled t)
                         'ghostel-test-zero-delay-timer)))
              (insert "see https://example.com here\n")
              (ghostel--queue-plain-link-detection (point-min) (point-max))
              (should-not timer-scheduled)
              (should-not ghostel--plain-link-detection-timer)
              (goto-char (point-min))
              (let* ((url "https://example.com")
                     (url-end (search-forward url nil t))
                     (url-beg (- url-end (length url))))
                (should url-end)
                (should (equal url
                               (get-text-property url-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-sentinel-cancels-plain-link-detection-timer ()
  "Process exit should cancel queued plain-text link detection timers."
  (let ((buf (generate-new-buffer " *ghostel-test-sentinel-links*")))
    (unwind-protect
        (let ((proc (make-pipe-process :name "ghostel-test-sentinel-links"
                                       :buffer buf
                                       :noquery t)))
          (with-current-buffer buf
            (setq ghostel-kill-buffer-on-exit nil
                  ghostel--plain-link-detection-timer
                  (run-with-timer 60 nil #'ignore))
            (ghostel--sentinel proc "finished\n")
            (should-not ghostel--plain-link-detection-timer))
          (when (process-live-p proc)
            (delete-process proc)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when ghostel--plain-link-detection-timer
            (cancel-timer ghostel--plain-link-detection-timer)))
        (kill-buffer buf)))))

(ert-deftest ghostel-test-hyperlink-navigation ()
  "Test `ghostel-next-hyperlink' / `ghostel-previous-hyperlink' search."
  :tags '(native)
  ;; Buffer layout (1-indexed positions):
  ;;   "AAA [LINK1] BBB [LINK2] CCC"
  ;;    123 4      5 6 7      8 9...
  (cl-flet ((setup ()
              (let ((buf (generate-new-buffer " *hyperlink-nav-test*")))
                (with-current-buffer buf
                  (insert "AAA ")                    ; 1..4
                  (let ((l1 (point)))                ; 5
                    (insert "LINK1")                 ; 5..9
                    (put-text-property l1 (point) 'help-echo "https://one"))
                  (insert " BBB ")                   ; 10..14
                  (let ((l2 (point)))                ; 15
                    (insert "LINK2")                 ; 15..19
                    (put-text-property l2 (point) 'help-echo "https://two"))
                  (insert " CCC"))                   ; 20..23
                buf)))
    ;; Forward from before any link lands on first link.
    (let ((buf (setup)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal 5 (ghostel--find-next-link (point-min))))
            (should (equal 5 (ghostel--find-next-link 2)))
            ;; From inside link1, skip to link2.
            (should (equal 15 (ghostel--find-next-link 5)))
            (should (equal 15 (ghostel--find-next-link 7)))
            ;; From inside link2, nothing after.
            (should (null (ghostel--find-next-link 15)))
            (should (null (ghostel--find-next-link 17)))
            (should (null (ghostel--find-next-link (point-max)))))
        (kill-buffer buf)))
    ;; Backward.
    (let ((buf (setup)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal 15 (ghostel--find-previous-link (point-max))))
            (should (equal 15 (ghostel--find-previous-link 22)))
            ;; From inside link2, find link1.
            (should (equal 5 (ghostel--find-previous-link 15)))
            (should (equal 5 (ghostel--find-previous-link 17)))
            ;; From inside link1, nothing before.
            (should (null (ghostel--find-previous-link 5)))
            (should (null (ghostel--find-previous-link 7)))
            (should (null (ghostel--find-previous-link (point-min)))))
        (kill-buffer buf)))
    ;; Empty buffer: no links at all.
    (with-temp-buffer
      (should (null (ghostel--find-next-link (point-min))))
      (should (null (ghostel--find-previous-link (point-max)))))
    ;; Buffer with no links but some text.
    (with-temp-buffer
      (insert "just some text with no links")
      (should (null (ghostel--find-next-link (point-min))))
      (should (null (ghostel--find-previous-link (point-max)))))
    ;; Commands are interactive.
    (should (commandp #'ghostel-next-hyperlink))
    (should (commandp #'ghostel-previous-hyperlink))))

(ert-deftest ghostel-test-hyperlink-navigation-skips-shared-id ()
  "Multiple help-echo runs sharing `ghostel-link-id' navigate as one logical link.
Reproduces the wrapped-OSC8-in-a-box case from issue #125 at the elisp
helper layer (no native module needed).  Layout puts two same-id runs
back-to-back (no different-id link between them) so the dedup loop has
to step past more than one run before landing on a different id."
  ;; Buffer (1-indexed):
  ;;   "AAA A1 BBB A2 CCC other DDD"
  ;;        ^5..6  ^12..13  ^19..23
  ;; A1 and A2 carry id "shared"; `other' carries id "other".
  (let ((buf (generate-new-buffer " *hyperlink-shared-id*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "AAA ")                ; 1..4
          (let ((p (point)))             ; 5
            (insert "A1")                ; 5..6
            (put-text-property p (point) 'help-echo "https://shared")
            (put-text-property p (point) 'ghostel-link-id "shared"))
          (insert " BBB ")               ; 7..11
          (let ((p (point)))             ; 12
            (insert "A2")                ; 12..13
            (put-text-property p (point) 'help-echo "https://shared")
            (put-text-property p (point) 'ghostel-link-id "shared"))
          (insert " CCC ")               ; 14..18
          (let ((p (point)))             ; 19
            (insert "other")             ; 19..23
            (put-text-property p (point) 'help-echo "https://other")
            (put-text-property p (point) 'ghostel-link-id "other"))
          (insert " DDD")                ; 24..27

          ;; Forward from inside A1: dedup loop must step PAST A2 (shared id)
          ;; before landing on `other'.  This is the path that proves the
          ;; loop actually iterates more than once.
          (should (equal 19 (ghostel--find-next-link 5)))
          ;; Forward from inside A2 also dedupes; lands on `other'.
          (should (equal 19 (ghostel--find-next-link 12)))
          ;; Outside any link, skip-id is nil → no dedup, lands on A1.
          (should (equal 5 (ghostel--find-next-link (point-min))))
          ;; Between A1 and A2 (no link), skip-id is nil → lands on A2.
          (should (equal 12 (ghostel--find-next-link 8)))
          ;; Forward from inside `other' has nothing left.
          (should (null (ghostel--find-next-link 19)))

          ;; Backward from inside A2: must step PAST A1 (shared id) → nil.
          (should (null (ghostel--find-previous-link 12)))
          ;; Backward from inside `other': lands on A1 (the URL's first chunk,
          ;; not A2 the last chunk) by walking back over same-id runs.
          (should (equal 5 (ghostel--find-previous-link 19)))
          ;; Outside any link, skip-id is nil → lands on the last link.
          (should (equal 19 (ghostel--find-previous-link (point-max)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-hyperlink-navigation-previous-lands-at-url-start ()
  "`ghostel--find-previous-link' lands at the URL's first chunk, not its last.
For a wrapped OSC 8 URL emitted as two chunks sharing `ghostel-link-id',
backward navigation from below the URL should skip the second chunk and
land on the start of the first chunk."
  ;; Buffer:
  ;;   "AAA U1 BBB U2 CCC DDD"
  ;;        ^5..6 ^12..13
  ;; U1 and U2 carry id "wrapped"; nothing else carries a link-id.
  (let ((buf (generate-new-buffer " *hyperlink-url-start*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "AAA ")                ; 1..4
          (let ((p (point)))             ; 5
            (insert "U1")
            (put-text-property p (point) 'help-echo "https://wrapped")
            (put-text-property p (point) 'ghostel-link-id "wrapped"))
          (insert " BBB ")
          (let ((p (point)))             ; 12
            (insert "U2")
            (put-text-property p (point) 'help-echo "https://wrapped")
            (put-text-property p (point) 'ghostel-link-id "wrapped"))
          (insert " CCC DDD")
          ;; From past the URL, backward lands on U1 (not U2).
          (should (equal 5 (ghostel--find-previous-link (point-max))))
          ;; Forward still lands on U1 naturally (URL start).
          (should (equal 5 (ghostel--find-next-link (point-min)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-hyperlink-navigation-shared-id-no-link-id-property ()
  "Runs without `ghostel-link-id' (auto-detected URL, fileref) are never deduped.
The dedup must only kick in when both ends carry a non-nil link id."
  (with-temp-buffer
    (insert "AAA URL1 BBB URL2 CCC")
    ;; Plain-text URL detection sets only help-echo, no link-id.
    (put-text-property 5 9 'help-echo "https://one")
    (put-text-property 14 18 'help-echo "https://two")
    ;; From inside URL1, URL2 is still found (no skip).
    (should (equal 14 (ghostel--find-next-link 5)))
    (should (equal 5 (ghostel--find-previous-link 14)))))

(ert-deftest ghostel-test-hyperlink-navigation-wrap ()
  "Test that `ghostel--goto-hyperlink' wraps and errors cleanly."
  :tags '(native)
  ;; Wrap: from past the last link, next jumps back to first.
  (with-temp-buffer
    (insert "AAA LINK1 BBB LINK2 CCC")
    (put-text-property 5 10 'help-echo "https://one")
    (put-text-property 15 20 'help-echo "https://two")
    (goto-char (point-max))
    ;; No link after point — wraps to link1.
    (let ((inhibit-message t))
      (ghostel--goto-hyperlink 'next))
    (should (equal 5 (point)))
    ;; At point-min, going backward wraps to the last link.
    (goto-char (point-min))
    (let ((inhibit-message t))
      (ghostel--goto-hyperlink 'previous))
    (should (equal 15 (point))))
  ;; No links at all → user-error.
  (with-temp-buffer
    (insert "no links here at all")
    (should-error (ghostel--goto-hyperlink 'next) :type 'user-error)
    (should-error (ghostel--goto-hyperlink 'previous) :type 'user-error)))

(ert-deftest ghostel-test-scrollback-preserves-url-properties ()
  "Verify delayed plain-link properties survive scrollback promotion.
When libghostty pushes a row into scrollback, the redraw promotes the
existing buffer text instead of fetching a fresh copy from libghostty,
so any text properties the row earned while it was the viewport stay
attached."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-url*")))
    (unwind-protect
        (with-current-buffer buf
          (set-window-buffer (selected-window) (current-buffer))
          (ghostel-mode)
          (let* ((term (ghostel--new 5 80 1000))
                 (ghostel--term term)
                 (ghostel--term-rows 5)
                 (ghostel-plain-link-detection-delay 0)
                 (inhibit-read-only t)
                 (ghostel-enable-url-detection t)
                 (ghostel-enable-file-detection nil))
            ;; Write a row with a URL while it's in the viewport.
            (ghostel--write-input term "see https://example.com here\r\n")
            ;; Run the supported redraw path; zero delay keeps the deferred
            ;; post-processing deterministic while still exercising it.
            (ghostel--delayed-redraw buf)
            ;; Sanity: delayed plain-link detection applied a help-echo while
            ;; the row is visible.
            (goto-char (point-min))
            (let ((url-pos (search-forward "https://example.com" nil t)))
              (should url-pos)
              (should (equal "https://example.com"
                             (get-text-property (- url-pos 19) 'help-echo))))
            ;; Now scroll the URL row off the active screen.
            (dotimes (_ 6) (ghostel--write-input term "filler\r\n"))
            (ghostel--delayed-redraw buf)
            ;; The URL row now lives in the scrollback region of the buffer.
            (goto-char (point-min))
            (let ((url-pos (search-forward "https://example.com" nil t)))
              (should url-pos)
              ;; The clickable text properties survived the scroll because
              ;; promotion preserved the buffer text instead of re-fetching
              ;; from libghostty.
              (should (equal "https://example.com"
                             (get-text-property (- url-pos 19) 'help-echo))))))
      (kill-buffer buf))))


(provide 'ghostel-links-test)
;;; ghostel-links-test.el ends here
