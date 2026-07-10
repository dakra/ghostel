;;; ghostel-debug-test.el --- Tests for ghostel: debug -*- lexical-binding: t; -*-

;;; Commentary:

;; `ghostel-debug-keypress` rendering and `ghostel-debug-info` sections.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-debug-keypress-renders-capture ()
  "`ghostel--debug-kp-show' writes a paste-friendly report.
Drives the renderer with a synthetic state plist that mimics a captured
RET keystroke.  Asserts the report includes the event and every recorded
send."
  (let* ((target (generate-new-buffer " *ghostel-test-debug-kp*"))
         (state (list :buffer target
                      :event ?\C-m
                      :keys [13]
                      :command 'ghostel--send-event
                      :binding 'ghostel--send-event
                      :calls (list (cons :write-pty "\r")
                                   (cons :send-string "ls")))))
    (unwind-protect
        (progn
          (ghostel--debug-kp-show state)
          (with-current-buffer "*ghostel-debug-keypress*"
            (let ((content (buffer-string)))
              (should (string-match-p "^=== ghostel-debug-keypress ===" content))
              (should (string-match-p "last-input-event:" content))
              (should (string-match-p "Sends during this command" content))
              ;; Calls were collected newest-first; renderer reverses them.
              (should (string-match-p "1\\. send-string: \"ls\"" content))
              (should (string-match-p "hex: 6c 73" content))
              (should (string-match-p "2\\. write-pty:" content))
              (should (string-match-p "hex: 0d" content)))))
      (kill-buffer target)
      (when (get-buffer "*ghostel-debug-keypress*")
        (kill-buffer "*ghostel-debug-keypress*")))))

(ert-deftest ghostel-test-debug-glyph-at-point-renders-font-and-glyph-metrics ()
  "`ghostel-debug-glyph-at-point' reports text, font, and glyph metrics."
  (let ((font (list 'mock-font))
        (glyph (vector 0 1 ?λ 123 12 -1 11 9 4 nil))
        (metrics ["Mock" "mock.ttf" 16 20 10 5 7 8 (opentype)])
        (display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t))
    (unwind-protect
        (with-temp-buffer
          (insert (propertize "λ" 'face 'bold 'display '(raise 0.1)))
          (goto-char (point-min))
          (cl-letf (((symbol-function 'font-at)
                     (lambda (_pos &optional _window _string) font))
                    ((symbol-function 'query-font)
                     (lambda (actual-font)
                       (should (eq actual-font font))
                       metrics))
                    ((symbol-function 'find-composition)
                     (lambda (&rest _) nil))
                    ((symbol-function 'composition-get-gstring)
                     (lambda (_from _to actual-font &optional _string)
                       (should (eq actual-font font))
                       (vector (vector font ?λ) nil glyph)))
                    ((symbol-function 'font-shape-gstring)
                     (lambda (gstring _direction) gstring)))
            (ghostel-debug-glyph-at-point))
          (with-current-buffer "*ghostel-debug-glyph*"
            (let ((content (buffer-string)))
              (should (string-match-p "^=== ghostel-debug-glyph-at-point ===" content))
              (should (string-match-p "Text properties:.*face bold" content))
              (should (string-match-p "Pixel size:.*16" content))
              (should (string-match-p "Size:.*20" content))
              (should (string-match-p "Ascent:.*10" content))
              (should (string-match-p "Descent:.*5" content))
              (should (string-match-p "--- Renderer metrics ---" content))
              (should (string-match-p "Sources:.*query-font\\[2,4,5\\].*first glyph\\[4\\]" content))
              (should (string-match-p "Total height:.*15" content))
              (should (string-match-p "Glyph 0 (gstring element 2)" content))
              (should (string-match-p "Width:.*12" content))
              (should (string-match-p "Left bearing:.*-1" content)))))
      (when (get-buffer "*ghostel-debug-glyph*")
        (kill-buffer "*ghostel-debug-glyph*")))))

(ert-deftest ghostel-test-debug-glyph-at-point-prefers-composition-gstring ()
  "`ghostel-debug-glyph-at-point' uses the composition gstring when present."
  (let* ((font (list 'mock-font))
         (glyph (vector 0 1 ?é 77 6 0 6 7 2 nil))
         (gstring (vector (vector font ?é) 99 glyph))
         (display-buffer-overriding-action '(display-buffer-no-window))
         (inhibit-message t))
    (unwind-protect
        (with-temp-buffer
          (insert "é")
          (goto-char (point-min))
          (cl-letf (((symbol-function 'find-composition)
                     (lambda (pos limit _string detail-p)
                       (should detail-p)
                       (list pos limit gstring)))
                    ((symbol-function 'font-at)
                     (lambda (&rest _)
                       (error "font-at should not be used for compositions")))
                    ((symbol-function 'query-font)
                     (lambda (actual-font)
                       (should (eq actual-font font))
                       ["Mock" nil 10 12 7 2 5 5 nil])))
            (ghostel-debug-glyph-at-point))
          (with-current-buffer "*ghostel-debug-glyph*"
            (let ((content (buffer-string)))
              (should (string-match-p "Source:.*composition" content))
              (should (string-match-p "ID:.*99" content))
              (should (string-match-p "Total height:.*9" content)))))
      (when (get-buffer "*ghostel-debug-glyph*")
        (kill-buffer "*ghostel-debug-glyph*")))))

(ert-deftest ghostel-test-debug-info-environment-section ()
  "`ghostel-debug-info' renders the Environment section.
The section shows the spawn env ghostel hands the shell (TERM,
COLORTERM, INSIDE_EMACS, …) plus pass-through LANG/LC_*.  In a
non-ghostel buffer (no `default-directory' override), the local-spawn
branch fires and emits the full TERM/COLORTERM line set."
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t)
        (ghostel--terminfo-warned t))
    (unwind-protect
        (save-window-excursion
          (with-temp-buffer
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (let ((content (buffer-string)))
                (should (string-match-p "--- Environment ---" content))
                (should (string-match-p "Spawn env (set by ghostel, local spawn)"
                                        content))
                (should (string-match-p "INSIDE_EMACS=ghostel" content))
                (should (string-match-p "^  TERM=" content))
                (should (string-match-p "COLORTERM=" content))
                (should (string-match-p "Pass-through" content))
                (should (string-match-p "LANG=" content))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))

(ert-deftest ghostel-test-debug-info-environment-section-remote-labeling ()
  "Remote ghostel buffer → Environment section hides local-spawn vars.
For a remote ghostel buffer the on-remote `/bin/sh -c' preamble owns
TERM/TERMINFO/TERM_PROGRAM/COLORTERM (issue #224 fix), so showing the
local `(ghostel--terminal-env)' as if it were the spawn env is
misleading.  Verify the new label fires and TERM/COLORTERM lines are
suppressed; INSIDE_EMACS still shows because it's pushed regardless."
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t))
    (unwind-protect
        (save-window-excursion
          (ghostel-test--with-compile-buffer buf
            (setq-local default-directory "/ssh:host.example.com:/tmp/")
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (let ((content (buffer-string)))
                (should (string-match-p
                         "Spawn env (set by ghostel, remote spawn)"
                         content))
                (should (string-match-p "INSIDE_EMACS=ghostel" content))
                ;; Local-only entries must not appear under "Spawn env".
                ;; The Pass-through section still shows LANG.
                (should-not (string-match-p "^  TERM=" content))
                (should-not (string-match-p "^  TERMINFO=" content))
                (should-not (string-match-p "^  COLORTERM=" content))
                ;; The clarifying note pointing the user to the wrapper.
                (should (string-match-p
                         "set by the on-remote /bin/sh -c preamble"
                         content))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))

(ert-deftest ghostel-test-debug-info-tramp-section-on-remote ()
  "`ghostel-debug-info' adds a TRAMP section for remote ghostel buffers.
TRAMP knobs that load-bear in `make-process' dispatch (and that
silently misbehave for #224-class bugs) belong in the standard report."
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t))
    (unwind-protect
        (save-window-excursion
          (ghostel-test--with-compile-buffer buf
            (setq-local default-directory "/ssh:host.example.com:/tmp/")
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (let ((content (buffer-string)))
                (should (string-match-p "^--- TRAMP ---" content))
                (should (string-match-p "tramp-version:" content))
                (should (string-match-p "tramp-terminal-type:" content))
                (should (string-match-p "direct-async (global):" content))
                (should (string-match-p "direct-async (effective):" content))
                (should (string-match-p "Would dispatch direct-async:" content))
                (should (string-match-p "Multi-hop length:" content))
                (should (string-match-p
                         "TERM (connection shell):" content))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))

(ert-deftest ghostel-test-debug-info-tramp-section-absent-locally ()
  "Local ghostel buffer → no TRAMP section.
Avoids cluttering local-only reports with TRAMP irrelevancies."
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t))
    (unwind-protect
        (save-window-excursion
          (ghostel-test--with-compile-buffer buf
            (setq-local default-directory "/tmp/")
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (should-not (string-match-p "^--- TRAMP ---"
                                          (buffer-string))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))

(ert-deftest ghostel-test-debug-info-spawn-capture-absent ()
  "`ghostel-debug-info' notes the missing capture in plain ghostel buffers.
The hint must point users to `ghostel-debug-ghostel' so they know how
to capture spawn-time diagnostics on the next reproduction."
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t))
    (unwind-protect
        (save-window-excursion
          (ghostel-test--with-compile-buffer buf
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (let ((content (buffer-string)))
                (should (string-match-p "^--- Spawn capture ---" content))
                (should (string-match-p "no capture" content))
                (should (string-match-p "ghostel-debug-ghostel" content))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))

(ert-deftest ghostel-test-debug-info-spawn-capture-renders ()
  "`ghostel-debug-info' renders the spawn capture when present.
Drives the renderer with a synthesized capture plist that mimics what
`ghostel-debug-ghostel' would have stashed for a remote spawn.  Asserts
the wrapper script, geometry, env delta, and PTY-output / send-key
sections all materialize."
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t))
    (unwind-protect
        (save-window-excursion
          (ghostel-test--with-compile-buffer buf
            (let* ((t-sp (current-time))
                   (t0 (time-add t-sp 0.123))   ; +123ms elisp prep
                   (t1 (time-add t0 0.010))     ; +10ms first PTY byte
                   (t2 (time-add t0 0.500))
                   (t3 (time-add t0 0.700)))
              (setq-local ghostel-debug--spawn-capture
                          (list :time t0
                                :start-process-time t-sp
                                :default-directory "/ssh:host.example.com:/tmp/"
                                :remote-p t
                                :program "/bin/bash"
                                :program-args nil
                                :cols 80 :rows 24
                                :extra-env nil
                                :process-environment
                                '("INSIDE_EMACS=ghostel"
                                  "TERM=xterm-ghostty"
                                  "PATH=/usr/bin")
                                :command
                                '("/bin/sh" "-c"
                                  "TERM=xterm-256color; if infocmp xterm-ghostty >/dev/null 2>&1; then TERM=xterm-ghostty; fi; export TERM; exec /bin/bash")
                                ;; Mimic TRAMP's legacy-async dispatch:
                                ;; the local bridge process differs from
                                ;; the wrapper ghostel built.
                                :executed-command '("/bin/sh" "-i")
                                :filter-events
                                (list (cons t1 "\e]0;hostname\007$ "))
                                :filter-cap 16384
                                :filter-bytes (length "\e]0;hostname\007$ ")
                                :filter-truncated nil
                                :send-keys
                                (list (cons t2 "l")
                                      (cons t3 "s"))
                                :send-cap 64
                                :send-truncated nil)))
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (let ((content (buffer-string)))
                (should (string-match-p "^--- Spawn capture ---" content))
                (should (string-match-p "Captured at:" content))
                (should (string-match-p "Remote-p:            yes" content))
                (should (string-match-p "Program:             /bin/bash"
                                        content))
                (should (string-match-p "Geometry:            80x24" content))
                ;; The wrapper script — load-bearing for #224.
                (should (string-match-p "Wrapper command sent" content))
                (should (string-match-p "infocmp xterm-ghostty" content))
                ;; The legacy-async divergence section — :executed-command
                ;; differs from :command, so the renderer must surface it.
                (should (string-match-p
                         "Local process command (`process-command'):"
                         content))
                (should (string-match-p "    -i" content))
                (should (string-match-p
                         "TRAMP rewrote the command for legacy-async"
                         content))
                ;; Env delta header.
                (should (string-match-p "process-environment at spawn"
                                        content))
                ;; Phase timings: T0 baseline, +123ms spawn-pty entry,
                ;; +133ms first PTY byte (123 + 10 from t-sp).
                (should (string-match-p "^Phase timings:" content))
                (should (string-match-p
                         "T0 +ghostel--start-process entered" content))
                (should (string-match-p
                         "\\+123ms +ghostel--spawn-pty entered" content))
                (should (string-match-p
                         "\\+133ms +first PTY byte received" content))
                ;; Unified RECV/SEND timeline.
                (should (string-match-p "^Timeline (RECV cap=" content))
                (should (string-match-p "RECV  \"" content))
                (should (string-match-p "SEND  \"l\"" content))
                (should (string-match-p "SEND  \"s\"" content))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))

(ert-deftest ghostel-test-debug-capture-filter-bounded ()
  "`ghostel-debug--capture-filter' records timestamped events and caps total bytes.
Each call appends a (TS . CHUNK) event up to :filter-cap total bytes.
Once the cap is hit, :filter-truncated is set and further chunks are
dropped (so steady-state shell output doesn't accumulate unboundedly)."
  (ghostel-test--with-compile-buffer buf
    (setq-local ghostel-debug--spawn-capture
                (list :filter-events nil
                      :filter-cap 16
                      :filter-bytes 0
                      :filter-truncated nil))
    (let ((proc (make-pipe-process :name "ghostel-test-capture"
                                   :buffer buf :noquery t)))
      (unwind-protect
          (cl-flet ((events-bytes ()
                      (mapconcat #'cdr
                                 (plist-get ghostel-debug--spawn-capture
                                            :filter-events)
                                 "")))
            (ghostel-debug--capture-filter proc "0123456789")
            (should (= 1 (length (plist-get ghostel-debug--spawn-capture
                                            :filter-events))))
            (should (equal (events-bytes) "0123456789"))
            (should (= 10 (plist-get ghostel-debug--spawn-capture
                                     :filter-bytes)))
            (should-not (plist-get ghostel-debug--spawn-capture
                                   :filter-truncated))
            ;; This chunk overflows the 16-byte cap (10 + 10 = 20):
            ;; the first 6 bytes fit, the rest is dropped and the
            ;; truncated flag flips on.
            (ghostel-debug--capture-filter proc "ABCDEFGHIJ")
            (should (= 2 (length (plist-get ghostel-debug--spawn-capture
                                            :filter-events))))
            (should (equal (events-bytes) "0123456789ABCDEF"))
            (should (= 16 (plist-get ghostel-debug--spawn-capture
                                     :filter-bytes)))
            (should (plist-get ghostel-debug--spawn-capture
                               :filter-truncated))
            ;; Further chunks no-op against the cap — no new event,
            ;; total bytes unchanged.
            (ghostel-debug--capture-filter proc "more")
            (should (= 2 (length (plist-get ghostel-debug--spawn-capture
                                            :filter-events))))
            (should (= 16 (plist-get ghostel-debug--spawn-capture
                                     :filter-bytes))))
        (delete-process proc)))))

(ert-deftest ghostel-test-debug-capture-send-bounded ()
  "`ghostel-debug--capture-send-string' caps :send-keys and flags truncation."
  (ghostel-test--with-compile-buffer buf
    (setq-local ghostel-debug--spawn-capture
                (list :send-keys nil
                      :send-cap 2
                      :send-truncated nil))
    (ghostel-debug--capture-send-string "a")
    (ghostel-debug--capture-send-string "b")
    (should (= 2 (length (plist-get ghostel-debug--spawn-capture
                                    :send-keys))))
    (should-not (plist-get ghostel-debug--spawn-capture :send-truncated))
    (ghostel-debug--capture-send-string "c")
    (should (= 2 (length (plist-get ghostel-debug--spawn-capture
                                    :send-keys))))
    (should (plist-get ghostel-debug--spawn-capture :send-truncated))))

(ert-deftest ghostel-test-debug-info-phase-timings-without-start-time ()
  "Phase timings still render when `:start-process-time' is absent.
Spawn-captures created via direct `ghostel--spawn-pty' calls (not
through `ghostel--start-process') have no elisp-prep baseline; the
section must degrade gracefully and still report the spawn-pty/first-
byte delta."
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t))
    (unwind-protect
        (save-window-excursion
          (ghostel-test--with-compile-buffer buf
            (let* ((t0 (current-time))
                   (t1 (time-add t0 0.042)))
              (setq-local ghostel-debug--spawn-capture
                          (list :time t0
                                :start-process-time nil
                                :default-directory "/tmp/"
                                :remote-p nil
                                :program "/bin/sh"
                                :program-args nil
                                :cols 80 :rows 24
                                :extra-env nil
                                :process-environment process-environment
                                :command '("/bin/sh" "-c" "exec /bin/sh")
                                ;; Local spawn — no TRAMP rewriting,
                                ;; so the executed cmd matches.
                                :executed-command
                                '("/bin/sh" "-c" "exec /bin/sh")
                                :filter-events (list (cons t1 "$ "))
                                :filter-cap 16384
                                :filter-bytes 2
                                :filter-truncated nil
                                :send-keys nil
                                :send-cap 64
                                :send-truncated nil)))
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (let ((content (buffer-string)))
                (should (string-match-p "^Phase timings:" content))
                ;; No T0 baseline line when start-process-time is nil.
                (should-not (string-match-p
                             "ghostel--start-process entered" content))
                ;; spawn-pty is the baseline (T0); first byte is +42ms.
                (should (string-match-p
                         "T0 +ghostel--spawn-pty entered" content))
                (should (string-match-p
                         "\\+42ms +first PTY byte received" content))
                ;; :command and :executed-command match (local spawn,
                ;; no TRAMP rewriting), so the divergence section must
                ;; be suppressed.
                (should-not (string-match-p
                             "Local process command" content))
                (should-not (string-match-p
                             "TRAMP rewrote" content))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))

(ert-deftest ghostel-test-debug-ghostel-installs-spawn-pty-advice ()
  "`ghostel-debug-ghostel' wires up self-removing advice on `ghostel--spawn-pty'.
Confirms the around-advice fires (capturing arguments into a buffer-
local plist) and that it removes itself after the spawn so subsequent
plain `ghostel' calls aren't instrumented.  Stubs out `make-process'
so no actual shell is spawned."
  (let ((native-comp-enable-subr-trampolines nil)
        (display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t)
        (ghostel-use-native-pty nil)
        (orig-make-process (symbol-function #'make-process))
        (executed-command (ghostel-test--shell-command "")))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 ;; Return a dummy process object so the advice still
                 ;; records :command from (process-command proc).
                 (apply orig-make-process
                        (plist-put plist :command executed-command)))))
      (let* ((buf (generate-new-buffer " *ghostel-test-debug-ghostel*"))
             ;; Stub `ghostel' to call `ghostel--spawn-pty' synchronously
             ;; in `buf' — mimics the path through `ghostel--start-process'
             ;; without dragging in module load, buffer init, etc.
             (calls 0))
        (cl-letf (((symbol-function #'ghostel--spawn-pty)
                   (lambda (&rest _args)
                     (make-process :name "ghostel-test"
                                   :buffer buf
                                   :command '("/bin/sh" "-c" "exec /bin/sh")
                                   :connection-type 'pipe
                                   :noquery t)))
                  ((symbol-function #'ghostel)
                   (lambda (&rest _arg)
                     (with-current-buffer buf
                       (setq-local ghostel--term-rows 24)
                       (setq-local ghostel--term-cols 80)
                       (cl-incf calls)
                       (ghostel--spawn-pty "/bin/sh" nil nil nil)))))
          (unwind-protect
              (progn
                (ghostel-debug-ghostel)
                ;; Both advices should have removed themselves (or been
                ;; stripped by the unwind-protect cleanup if they never
                ;; fired — either way they must not linger).
                (should-not (advice-member-p
                             #'ghostel-debug--capture-spawn-pty
                             'ghostel--spawn-pty))
                (should-not (advice-member-p
                             #'ghostel-debug--capture-start-process
                             'ghostel--start-process))
                ;; And the buffer-local capture should be populated.
                (let ((cap (buffer-local-value
                            'ghostel-debug--spawn-capture buf)))
                  (should cap)
                  (should (eq 80 (plist-get cap :cols)))
                  (should (eq 24 (plist-get cap :rows)))
                  (should (equal "/bin/sh" (plist-get cap :program)))
                  ;; :command is the wrapper ghostel passed to make-process
                  ;; — captured via cl-letf* on make-process *before* the
                  ;; test stub substitutes :command.  So it must be the
                  ;; ghostel wrapper (("/bin/sh" "-c" "<...>")), not the
                  ;; substituted '("true").
                  (let ((cmd (plist-get cap :command)))
                    (should (consp cmd))
                    (should (equal "/bin/sh" (car cmd)))
                    (should (equal "-c" (cadr cmd))))
                  ;; :executed-command is what process-command returns,
                  ;; which is the test-substituted portable no-op command.
                  (should (equal executed-command
                                 (plist-get cap :executed-command)))))
            (when (buffer-live-p buf)
              (let ((p (buffer-local-value 'ghostel--process buf)))
                (when (processp p)
                  (set-process-sentinel p #'ignore)
                  (delete-process p)))
              (kill-buffer buf))))))))

(ert-deftest ghostel-test-debug-capture-start-process-records-time ()
  "`ghostel-debug--capture-start-process' stashes its entry time and self-removes.
The stashed value is consumed by `ghostel-debug--capture-spawn-pty'
and folded into the capture as `:start-process-time'.  Without that
two-step, the spawn-capture would have no baseline for the elisp-prep
delta in the phase timings section."
  (let ((buf (generate-new-buffer " *ghostel-test-start-proc-cap*"))
        (orig (lambda (&rest _) 'fake-result)))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--start-process) orig))
          (advice-add 'ghostel--start-process :around
                      #'ghostel-debug--capture-start-process)
          (with-current-buffer buf
            (let ((t-before (current-time)))
              (ghostel--start-process)
              ;; Advice removed itself after one call.
              (should-not
               (advice-member-p
                #'ghostel-debug--capture-start-process
                'ghostel--start-process))
              ;; Buffer-local stash holds a timestamp at or after t-before.
              (let ((stashed ghostel-debug--pending-start-process-time))
                (should stashed)
                (should-not (time-less-p stashed t-before))))))
      (advice-remove 'ghostel--start-process
                     #'ghostel-debug--capture-start-process)
      (kill-buffer buf))))

(ert-deftest ghostel-test-debug-redraw-advices-tolerate-force ()
  "Debug redraw/latency advices accept and forward `ghostel--redraw-now's FORCE.
Regression for #460: adding the optional FORCE argument made the :around
log advice and the :after latency advice receive an extra argument.  Both
must tolerate it without `wrong-number-of-arguments', and the :around must
forward FORCE to the real redraw."
  (let ((log-buf (generate-new-buffer " *ghostel-test-redraw-advice*"))
        (recorded nil))
    (unwind-protect
        (let ((ghostel-debug--log-buffer log-buf)
              (ghostel-debug--latency-active nil))
          (cl-letf* (((symbol-function 'ghostel--redraw-now)
                      (lambda (_buffer &optional force) (push force recorded)))
                     ;; Stub the snapshot so the log body needs no live terminal.
                     ((symbol-function 'ghostel-debug--snapshot)
                      (lambda (_buffer)
                        (list :sync nil :force nil :buf-size 0 :trailing-nl nil
                              :point 1 :cursor nil :cursor-char nil
                              :term-rows 0 :vs 1 :wins nil))))
            (advice-add 'ghostel--redraw-now :around #'ghostel-debug--log-redraw)
            (advice-add 'ghostel--redraw-now :after #'ghostel-debug--latency-on-render)
            (with-temp-buffer
              (ghostel--redraw-now (current-buffer) t)
              (ghostel--redraw-now (current-buffer)))
            ;; Both calls returned without an arity error, and FORCE was
            ;; forwarded: newest-first push records the bare then forced call.
            (should (equal recorded '(nil t)))))
      (advice-remove 'ghostel--redraw-now #'ghostel-debug--log-redraw)
      (advice-remove 'ghostel--redraw-now #'ghostel-debug--latency-on-render)
      (kill-buffer log-buf))))


(ert-deftest ghostel-test-vt-warnings-do-not-leak-to-stderr ()
  "VT-parser warnings must not reach the module's stderr (#425).
In `emacs -nw' the module's stderr is the controlling tty, so a stray
write (e.g. lazygit triggering \"unimplemented mode: 9001\") paints raw
bytes onto the screen outside Emacs's redisplay and lingers near the
mode line.  A release build must stay silent on stderr; logs are
available only via `ghostel-debug-start'.  Spawns a child batch Emacs
that feeds the offending sequence and asserts its stderr is clean."
  :tags '(native)
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lisp (file-name-directory (locate-library "ghostel")))
         (stderr-file (make-temp-file "ghostel-stderr"))
         ;; Replicate the parent's `load-path' so the bare `-Q' child can load
         ;; ghostel and its deps (e.g. compat on Emacs < 30, which CI supplies
         ;; via -L); `\e' is a real ESC byte parsed as the VT set/reset of 9001.
         (code (format
                (concat "(progn (setq load-path '%S) (require 'ghostel)"
                        " (let ((tm (ghostel--new 25 80 1000)))"
                        " (ghostel--write-vt tm \"\e[?9001h\")"
                        " (ghostel--write-vt tm \"\e[?9001l\")))")
                load-path)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (call-process emacs nil (list t stderr-file) nil
                                      "--batch" "-Q" "-L" lisp
                                      "--eval" code)))
            (should (equal 0 status)))
          (let ((stderr (with-temp-buffer
                          (insert-file-contents stderr-file)
                          (buffer-string))))
            (should-not (string-match-p "unimplemented mode" stderr))
            (should-not (string-match-p "warning(stream)" stderr))))
      (delete-file stderr-file))))

(ert-deftest ghostel-test-vt-log-still-routes-to-debug-buffer ()
  "With `vt-log' enabled, parser warnings still reach the debug buffer.
Guards that silencing stderr (#425) didn't break the opt-in diagnosis
path: `ghostel--enable-vt-log' must route libghostty logs to
`ghostel-debug--log-buffer' via `ghostel--debug-log-vt'."
  :tags '(native)
  (skip-unless (fboundp 'ghostel--enable-vt-log))
  (let ((ghostel-debug--log-buffer (generate-new-buffer " *ghostel-vt-log*")))
    (unwind-protect
        (progn
          (ghostel--enable-vt-log)
          (let ((term (ghostel--new 25 80 1000)))
            (ghostel--write-vt term "\e[?9001h"))
          (with-current-buffer ghostel-debug--log-buffer
            (should (string-match-p "unimplemented mode: 9001"
                                    (buffer-string)))))
      (ghostel--disable-vt-log)
      (kill-buffer ghostel-debug--log-buffer))))

(ert-deftest ghostel-test-debug-info-survives-key-probe ()
  "The key-encoding probe must not wipe the report.
`ghostel--new' is buffer-affine and erases the current buffer on init;
a probe created with *ghostel-debug* current silently truncated the
report to the tail of the key-encoding table."
  :tags '(native)
  (let ((display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t)
        (ghostel--terminfo-warned t))
    (unwind-protect
        (save-window-excursion
          (with-temp-buffer
            (ghostel-debug-info)
            (with-current-buffer "*ghostel-debug*"
              (let ((content (buffer-string)))
                ;; Sections inserted before the probe survive it.
                (should (string-match-p "--- System ---" content))
                (should (string-match-p "--- Environment ---" content))
                (should (string-match-p
                         (regexp-quote "--- Key encoding (legacy mode) ---")
                         content))
                ;; Encoder-handled chords report actual bytes, not
                ;; "(no output)" (the native encoder bypasses the elisp
                ;; `ghostel--write-pty' the old capture hooked into).
                (should (string-match-p "Backspace +→ 0x7f" content))
                (should (string-match-p "C-h +→ 0x08" content))))))
      (when (get-buffer "*ghostel-debug*")
        (kill-buffer "*ghostel-debug*")))))

(ert-deftest ghostel-test-encode-key-returns-bytes ()
  "`ghostel--encode-key' returns the encoded bytes as a unibyte string.
nil means the encoder produced nothing (plain Meta+letter without utf8
defers to the elisp raw fallback)."
  :tags '(native)
  (with-temp-buffer
    (let ((probe (ghostel--new 25 80 100)))
      (should (equal (ghostel--encode-key probe "backspace" "" nil) "\x7f"))
      (should-not (ghostel--encode-key probe "f" "meta" nil)))))

(provide 'ghostel-debug-test)
;;; ghostel-debug-test.el ends here
