;;; ghostel-bench.el --- Performance benchmarks for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Compare terminal emulator performance: ghostel (incremental & full
;; redraw), vterm, eat, and Emacs built-in term.
;;
;; Two process-based scenarios cover what users actually experience:
;;
;;   * `e2e/*' — drives ghostel's *real* `ghostel-mode' pipeline:
;;     `ghostel--filter' → `ghostel--invalidate' →
;;     `ghostel--delayed-redraw' → `ghostel--schedule-link-detection'
;;     plus window anchoring and wide-char compensation.  Uses the
;;     same input source as `pty/*' (a real `cat' subprocess) but
;;     installs the production filter/sentinel and waits for full
;;     quiescence (redraw timer drained, link-detection timer drained)
;;     before stopping the clock.
;;
;;   * `pty/*' — engine-only baseline: real subprocess, but a stripped
;;     filter that batches output and calls `ghostel--write-input' /
;;     `ghostel--redraw' (the native functions) directly.  Skips
;;     link detection, anchoring, preedit, and wide-char compensation.
;;     The delta `e2e/* - pty/*' is the cost of the lisp-side pipeline.
;;
;; Synthetic micro-benchmarks follow for isolating bottlenecks.
;;
;; Run via:  bench/run-bench.sh          (recommended)
;;       or: emacs --batch -Q -L . -L ../vterm -L ../eat \
;;             -l bench/ghostel-bench.el \
;;             --eval '(ghostel-bench-run-all)'

;;; Code:

(require 'cl-lib)

;; ---------------------------------------------------------------------------
;; Configuration
;; ---------------------------------------------------------------------------

(defvar ghostel-bench-data-size (* 1024 1024)
  "Size of test data in bytes (default 1 MB).")

(defvar ghostel-bench-iterations 3
  "Number of iterations per benchmark.")

(defvar ghostel-bench-terminal-sizes '((24 . 80) (40 . 120))
  "List of (ROWS . COLS) to benchmark.")

(defvar ghostel-bench-scrollback 1000
  "Scrollback lines for terminal creation.")

(defvar ghostel-bench-include-vterm t
  "When non-nil, include vterm in benchmarks.")

(defvar ghostel-bench-include-eat t
  "When non-nil, include eat in benchmarks.")

(defvar ghostel-bench-include-term t
  "When non-nil, include Emacs built-in term in benchmarks.
Always available since term is built into Emacs.")

(defvar ghostel-bench-chunk-size 4096
  "Chunk size for streaming benchmarks.")

;; ---------------------------------------------------------------------------
;; Results accumulator
;; ---------------------------------------------------------------------------

(defvar ghostel-bench--results nil
  "List of result plists from benchmark runs.")

;; ---------------------------------------------------------------------------
;; Data generators
;; ---------------------------------------------------------------------------

(defun ghostel-bench--gen-plain-ascii (size)
  "Generate SIZE bytes of printable ASCII with CRLF every 80 chars."
  (let* ((line (concat (make-string 78 ?A) "\r\n"))
         (line-len (length line))
         (repeats (/ size line-len))
         (parts (make-list repeats line)))
    (apply #'concat parts)))

(defun ghostel-bench--gen-sgr-styled (size)
  "Generate ~SIZE bytes with SGR color escapes every ~10 chars."
  (let ((parts nil)
        (total 0))
    (while (< total size)
      (let* ((color (% (/ total 10) 256))
             (esc (format "\e[38;5;%dm" color))
             (text "abcdefghij")
             (chunk (concat esc text)))
        (push chunk parts)
        (setq total (+ total (length chunk)))))
    (let ((result (apply #'concat (nreverse parts))))
      (substring result 0 (min (length result) size)))))

(defun ghostel-bench--gen-unicode (size)
  "Generate ~SIZE bytes of CJK UTF-8 text as a multibyte string."
  (let* ((chars-needed (/ size 3))
         (line-chars 26)
         (lines (/ chars-needed line-chars))
         (parts nil))
    (dotimes (l lines)
      (dotimes (c line-chars)
        (push (string (+ #x4e00 (% (+ (* l 7) c) 256))) parts))
      (push "\r\n" parts))
    (apply #'concat (nreverse parts))))

(defun ghostel-bench--gen-scroll-lines (size cols)
  "Generate ~SIZE bytes of COLS-wide short lines with CRLF."
  (let* ((text-width (max 10 (min 40 (- cols 2))))
         (line (concat (make-string text-width ?#) "\r\n"))
         (line-len (length line))
         (repeats (/ size line-len))
         (parts (make-list repeats line)))
    (apply #'concat parts)))

(defun ghostel-bench--gen-urls-and-paths (size)
  "Generate ~SIZE bytes of output containing URLs and file:line refs.
Simulates compiler output or build logs with linkifiable content."
  (let ((lines '("/usr/src/app/main.c:42: error: undeclared identifier\r\n"
                 "  at Object.<anonymous> (/home/user/project/index.js:17:5)\r\n"
                 "See https://example.com/docs/errors/E0042 for details\r\n"
                 "PASS ./tests/test_utils.py:88 test_parse_url\r\n"
                 "warning: unused variable at ./src/render.zig:156:13\r\n"
                 "Download: https://cdn.example.org/releases/v2.1.0/pkg.tar.gz\r\n"
                 "  File \"/opt/lib/python3/site.py\", line 73, in main\r\n"
                 "More info: https://github.com/user/repo/issues/42\r\n"
                 "  --> retroact-macros/src/lib.rs:43:4\r\n"
                 "pkg/server/handler.go:128:5: undefined: Foo\r\n"
                 "ERROR in src/components/Button.tsx:17 TS2304: Cannot find name\r\n"))
        (parts nil)
        (total 0))
    (while (< total size)
      (let ((line (nth (% (/ total 60) (length lines)) lines)))
        (push line parts)
        (setq total (+ total (length line)))))
    (apply #'concat (nreverse parts))))

(defun ghostel-bench--gen-mixed-emoji-cjk-ascii (size)
  "Generate ~SIZE bytes of mixed emoji, CJK, and ASCII as in a chat log.
Includes multi-codepoint grapheme clusters: skin-tone modifiers, ZWJ
sequences, flag pairs, and keycap sequences."
  (let ((lines
         ;; Multi-codepoint clusters exercised:
         ;;   👋🏽 = wave + medium skin tone (U+1F44B U+1F3FD)
         ;;   👨‍💻 = man ZWJ laptop (U+1F468 U+200D U+1F4BB)
         ;;   🇯🇵 = flag Japan (U+1F1EF U+1F1F5)
         ;;   🇰🇷 = flag Korea (U+1F1F0 U+1F1F7)
         ;;   1️⃣  = digit-1 + VS-16 + combining enclosing keycap
         ;;   👍🏾 = thumbs-up + medium-dark skin tone (U+1F44D U+1F3FE)
         ;;   🧑‍🤝‍🧑 = couple holding hands ZWJ sequence
         '("User1: hello! 👋🏽 how are you doing today?\r\n"
           "User2: 我很好，谢谢！Working on some 代码 right now 👨‍💻\r\n"
           "User1: nice! step 1️⃣ — any bugs? 🐛🔍\r\n"
           "User2: 有一个问题... the output looks like: [ERROR] 失败 at line 42\r\n"
           "User3: こんにちは 🇯🇵！I saw that too — emoji widths were off 😅\r\n"
           "User1: 맞아요 🇰🇷, fixed it ✅ 🎉 shipping tomorrow\r\n"
           "User2: great! 太好了！ ping me at 9am 🕘 東京時間\r\n"
           "User3: ack 👍🏾 🧑‍🤝‍🧑 see you then — 明日また！\r\n"))
        (parts nil)
        (total 0))
    (while (< total size)
      (let ((line (nth (% (/ total 50) (length lines)) lines)))
        (push line parts)
        (setq total (+ total (string-bytes line)))))
    (apply #'concat (nreverse parts))))

(defun ghostel-bench--gen-tui-frame (rows cols)
  "Generate a single TUI-style frame: clear + fill ROWS x COLS."
  (let ((parts (list "\e[2J\e[H")))
    (dotimes (r rows)
      (push (format "\e[%d;1H" (1+ r)) parts)
      (push (format "\e[%sm" (if (cl-evenp r) "44" "42")) parts)
      (push (make-string cols (if (cl-evenp r) ?- ?=)) parts))
    (push "\e[0m" parts)
    (apply #'concat (nreverse parts))))

;; ---------------------------------------------------------------------------
;; Benchmark buffer helper
;; ---------------------------------------------------------------------------

(defmacro ghostel-bench--with-bench-buffer (&rest body)
  "Like `with-temp-buffer', but display the buffer in the selected window.
Ensures redraw paths that require a live window (wide-char compensation,
anchoring) actually run, matching real `ghostel-mode' conditions."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (when (window-live-p (selected-window))
       (set-window-buffer (selected-window) (current-buffer)))
     ,@body))

;; ---------------------------------------------------------------------------
;; Data encoding helper
;; ---------------------------------------------------------------------------

(defun ghostel-bench--encode-for-backend (data backend)
  "Encode DATA for BACKEND.
Native backends (ghostel, vterm) and term need unibyte strings.
Eat works with multibyte strings directly."
  (if (eq backend 'eat)
      (if (multibyte-string-p data) data
        (decode-coding-string data 'utf-8))
    (if (multibyte-string-p data)
        (encode-coding-string data 'utf-8)
      data)))

;; ---------------------------------------------------------------------------
;; Timing harness
;; ---------------------------------------------------------------------------

(defun ghostel-bench--measure (name data-size iterations body-fn)
  "Run BODY-FN ITERATIONS times, record results under NAME.
DATA-SIZE is the byte count processed per iteration (for MB/s).
Automatically increases iterations if the operation is too fast
for reliable measurement."
  (garbage-collect)
  (funcall body-fn)  ; warm up
  (garbage-collect)
  (let ((actual-iters iterations))
    ;; Auto-scale fast operations
    (let ((trial-start (float-time)))
      (dotimes (_ (min 3 iterations))
        (funcall body-fn))
      (let ((trial-time (- (float-time) trial-start)))
        (when (< trial-time 0.01)
          (setq actual-iters (max iterations
                                  (* 10 (ceiling (/ 0.5 (max trial-time 1e-6)))))))))
    (garbage-collect)
    (let ((start (float-time)))
      (dotimes (_ actual-iters)
        (funcall body-fn))
      (let* ((elapsed (- (float-time) start))
             (per-iter (/ elapsed actual-iters))
             (throughput (if (> elapsed 0)
                             (/ (* data-size actual-iters) elapsed (expt 1024.0 2))
                           0.0))
             (result (list :name name
                           :iterations actual-iters
                           :total-time elapsed
                           :per-iter-ms (* per-iter 1000.0)
                           :data-size data-size
                           :throughput-mbs throughput)))
        (push result ghostel-bench--results)
        (message "  %-50s %5d  %8.3f  %10.2f  %8.1f"
                 name actual-iters elapsed (* per-iter 1000.0) throughput)
        result))))

;; ---------------------------------------------------------------------------
;; Terminal creation helpers
;; ---------------------------------------------------------------------------

(defun ghostel-bench--make-ghostel (rows cols)
  "Create a ghostel terminal for benchmarking.
`ghostel-bench-scrollback' is in lines (matching vterm/term),
but `ghostel--new' takes bytes — convert at ~1 KB per row."
  (ghostel--new rows cols (* ghostel-bench-scrollback 1024)))

(defun ghostel-bench--make-vterm (rows cols)
  "Create a vterm terminal for benchmarking."
  (vterm--new rows cols ghostel-bench-scrollback nil nil nil nil nil))

(defun ghostel-bench--make-eat (rows cols)
  "Create an eat terminal at point in current buffer for benchmarking."
  (let ((term (eat-term-make (current-buffer) (point))))
    (eat-term-resize term cols rows)
    (eat-term-set-parameter term 'input-function (lambda (_term _str)))
    term))

(defun ghostel-bench--make-term (rows cols)
  "Set up current buffer for term-mode benchmarking.
Returns a dummy `cat' process for use with `term-emulate-terminal'.
The caller must call `delete-process' when done."
  (term-mode)
  (setq term-width cols)
  (setq term-height rows)
  (setq term-buffer-maximum-size ghostel-bench-scrollback)
  (let ((proc (start-process "term-bench" (current-buffer) "cat")))
    (set-process-query-on-exit-flag proc nil)
    proc))

;; =========================================================================
;; SECTION 1: Real subprocess benchmarks
;;
;; Two flavors share the same input source (a real `cat' subprocess
;; with the same data file), but route output very differently:
;;
;;   * `e2e/*' uses ghostel's production `ghostel--filter' /
;;     `ghostel--sentinel' and waits for full quiescence (redraw
;;     timer + link-detection timer drained).
;;
;;   * `pty/*' uses a stripped-down filter that calls the native
;;     `ghostel--write-input' / `ghostel--redraw' directly, skipping
;;     `ghostel--delayed-redraw' (link detection, anchoring, preedit,
;;     wide-char compensation).
;;
;; Both connection types are `pipe' so the file's literal CRLF bytes
;; reach the terminal unchanged (a PTY would re-translate LF→CRLF).
;; =========================================================================

(defun ghostel-bench--write-data-file (gen-fn)
  "Write data from GEN-FN to a temp file, return path."
  (let ((file (make-temp-file "ghostel-bench-" nil ".bin")))
    (with-temp-file file
      (let ((data (funcall gen-fn ghostel-bench-data-size)))
        (set-buffer-multibyte nil)
        (insert (if (multibyte-string-p data)
                    (encode-coding-string data 'utf-8)
                  data))))
    file))

(defun ghostel-bench--e2e-ghostel (data-file detect-p)
  "Benchmark ghostel processing `cat DATA-FILE' through the REAL pipeline.

Installs the production `ghostel--filter' and `ghostel--sentinel' on a
`cat' subprocess so output is routed through `ghostel--invalidate' and
`ghostel--delayed-redraw' — the same code path a live shell drives.
The buffer is attached to the selected window so window-anchoring,
preedit, and wide-char paths in `ghostel--delayed-redraw' actually run.

When DETECT-P is non-nil, plain-text URL and file:line detection runs
post-redraw via `ghostel--schedule-link-detection'; the wall clock
includes the link-detection timer firing.

After cat exits, `ghostel--sentinel' flushes any pending output but
cancels the redraw timer without firing `ghostel--delayed-redraw'
\(production behavior: the user's next interaction triggers redraw).
For benchmarking we explicitly drive one final `ghostel--delayed-redraw'
post-sentinel so the full pipeline — including link detection on the
final batch — runs at least once per iteration.  This matches what
`pty/*' does (a final redraw post-exit) and makes the e2e/pty delta
attributable to the lisp-side pipeline.

The bench buffer is killed at the end; cat exits cleanly so the
sentinel runs once.  `ghostel-kill-buffer-on-exit' is forced nil so
the sentinel does not kill the buffer out from under us before we can
drive the post-exit timers."
  (let* ((rows 24) (cols 80)
         (buf (generate-new-buffer " *ghostel-e2e-bench*"))
         (ghostel-kill-buffer-on-exit nil)
         (ghostel-enable-url-detection (and detect-p t))
         (ghostel-enable-file-detection (and detect-p t))
         ;; Zero the debounce so we measure work, not idle wait.  The
         ;; debounce is a UX feature (coalesce detection across rapid
         ;; output bursts); for a long-running `cat' it is amortized
         ;; against the streaming time, but for a 100 KB iteration the
         ;; fixed 100 ms wait dominates and makes throughput look ~30x
         ;; worse than users actually experience.
         (ghostel-plain-link-detection-delay 0)
         (done nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term
                (ghostel--new rows cols
                              (* ghostel-bench-scrollback 1024)))
          (setq ghostel--term-rows rows ghostel--term-cols cols)
          ;; Display the buffer in a window so anchoring / wide-char paths
          ;; in `ghostel--delayed-redraw' have a window to act on.  In
          ;; --batch this is a non-displaying terminal window, but
          ;; `get-buffer-window-list' still returns it.
          (when (window-live-p (selected-window))
            (set-window-buffer (selected-window) buf))
          (let ((proc (make-process
                       :name "ghostel-e2e-bench"
                       :buffer buf
                       :command (list "cat" (expand-file-name data-file))
                       :connection-type 'pipe
                       :coding 'binary
                       :noquery t
                       :filter #'ghostel--filter
                       :sentinel (lambda (proc event)
                                   (ghostel--sentinel proc event)
                                   (setq done t)))))
            (setq ghostel--process proc)
            (set-process-window-size proc rows cols)
            (while (not done)
              (accept-process-output proc 30))
            ;; Force one final delayed-redraw so the pipeline runs
            ;; against the post-sentinel state (sentinel flushed pending
            ;; output to the native module but did not redraw).  This
            ;; mirrors `pty/*' and ensures link detection runs at least
            ;; once per iteration.
            (ghostel--delayed-redraw buf)
            ;; Drive timers until link detection drains.  After cat exits
            ;; there is no process to wake `accept-process-output', but
            ;; passing nil polls timers; `sit-for' would also work.
            (let ((deadline (+ (float-time) 30)))
              (while (and (or ghostel--redraw-timer
                              ghostel--plain-link-detection-timer)
                          (< (float-time) deadline))
                (accept-process-output nil 0.01)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defun ghostel-bench--e2e-vterm (data-file)
  "Benchmark vterm processing `cat DATA-FILE' through `vterm--filter'.

Routes through the production `vterm--filter', which decodes the byte
stream, splits on control sequences, carries undecoded multibyte tails
across reads, and calls `vterm--update' synchronously per filter call.
That is the per-chunk lisp work the `pty/*' harness skips."
  (let* ((rows 24) (cols 80)
         (buf (generate-new-buffer " *vterm-e2e-bench*"))
         (done nil))
    (unwind-protect
        (with-current-buffer buf
          (setq-local vterm--term (ghostel-bench--make-vterm rows cols))
          (setq-local vterm--undecoded-bytes nil)
          (let ((proc (make-process
                       :name "vterm-e2e-bench"
                       :buffer buf
                       :command (list "cat" (expand-file-name data-file))
                       :connection-type 'pipe
                       :coding 'binary
                       :noquery t
                       :filter #'vterm--filter
                       :sentinel (lambda (_p _e) (setq done t)))))
            (set-process-window-size proc rows cols)
            (while (not done)
              (accept-process-output proc 30))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defun ghostel-bench--e2e-eat (data-file)
  "Benchmark eat processing `cat DATA-FILE' through `eat--filter'.

Routes through the production `eat--filter' (deferred queue with
`eat-minimum-latency'/`eat-maximum-latency') and `eat--sentinel'.
The sentinel does the final flush, drains the queue, and cancels
the prompt-annotation correction timer — so once the sentinel has
fired, the buffer is fully painted with no outstanding timers."
  (let* ((rows 24) (cols 80)
         (buf (generate-new-buffer " *eat-e2e-bench*"))
         (done nil))
    (unwind-protect
        (with-current-buffer buf
          (setq-local eat-terminal (ghostel-bench--make-eat rows cols))
          (let ((proc (make-process
                       :name "eat-e2e-bench"
                       :buffer buf
                       :command (list "cat" (expand-file-name data-file))
                       :connection-type 'pipe
                       :coding 'binary
                       :noquery t
                       :filter #'eat--filter
                       :sentinel (lambda (proc event)
                                   (eat--sentinel proc event)
                                   (setq done t)))))
            (set-process-window-size proc rows cols)
            (while (not done)
              (accept-process-output proc 30))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defun ghostel-bench--run-e2e-scenarios ()
  "Run end-to-end benchmarks through each backend's real filter.

For ghostel, exercises the full `ghostel-mode' pipeline including
`ghostel--delayed-redraw' and link detection.  For vterm and eat,
exercises their production `*--filter' (decode loop, control-seq
split or output queue, per-chunk update) — the per-chunk lisp work
the `pty/*' harness skips, for fair comparison.  `term' installs
`term-emulate-terminal' directly as its process filter without
batching, so `pty/*/term' is already e2e for term."
  (message "\n--- End-to-End (real backend pipelines, cat %s) ---"
           (ghostel-bench--human-size ghostel-bench-data-size))
  (message "  ghostel: filter / invalidate / delayed-redraw / link-detection")
  (message "  vterm:   vterm--filter (decode + control-seq split + update)")
  (message "  eat:     eat--filter + eat--sentinel (queue drain on exit)")
  (message "  term:    see pty/*/term — `term-emulate-terminal' IS the filter")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "MB/s")
  (message "  %s" (make-string 90 ?-))
  ;; --- Plain ASCII ---
  (let ((data-file (ghostel-bench--write-data-file
                    #'ghostel-bench--gen-plain-ascii)))
    (unwind-protect
        (progn
          (message "  [plain ASCII data]")
          (ghostel-bench--measure
           "e2e/plain/ghostel" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--e2e-ghostel data-file t)))
          (ghostel-bench--measure
           "e2e/plain/ghostel-nodetect" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--e2e-ghostel data-file nil)))
          (when ghostel-bench-include-vterm
            (ghostel-bench--measure
             "e2e/plain/vterm" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--e2e-vterm data-file))))
          (when ghostel-bench-include-eat
            (ghostel-bench--measure
             "e2e/plain/eat" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--e2e-eat data-file))))
          (when ghostel-bench-include-term
            (ghostel-bench--measure
             "e2e/plain/term" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-term data-file)))))
      (delete-file data-file)))
  ;; --- URL & file-path heavy data: where detection cost actually shows up ---
  (let ((data-file (ghostel-bench--write-data-file
                    #'ghostel-bench--gen-urls-and-paths)))
    (unwind-protect
        (progn
          (message "  [URL & file-path heavy data]")
          (ghostel-bench--measure
           "e2e/urls/ghostel" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--e2e-ghostel data-file t)))
          (ghostel-bench--measure
           "e2e/urls/ghostel-nodetect" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--e2e-ghostel data-file nil)))
          (when ghostel-bench-include-vterm
            (ghostel-bench--measure
             "e2e/urls/vterm" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--e2e-vterm data-file))))
          (when ghostel-bench-include-eat
            (ghostel-bench--measure
             "e2e/urls/eat" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--e2e-eat data-file))))
          (when ghostel-bench-include-term
            (ghostel-bench--measure
             "e2e/urls/term" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-term data-file)))))
      (delete-file data-file)))
  ;; --- Mixed emoji/CJK/ASCII: exercises wide-char and grapheme-cluster paths ---
  (let ((data-file (ghostel-bench--write-data-file
                    #'ghostel-bench--gen-mixed-emoji-cjk-ascii)))
    (unwind-protect
        (progn
          (message "  [mixed emoji/CJK/ASCII data]")
          (ghostel-bench--measure
           "e2e/mixed/ghostel" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--e2e-ghostel data-file t)))
          (ghostel-bench--measure
           "e2e/mixed/ghostel-nodetect" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--e2e-ghostel data-file nil)))
          (when ghostel-bench-include-vterm
            (ghostel-bench--measure
             "e2e/mixed/vterm" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--e2e-vterm data-file))))
          (when ghostel-bench-include-eat
            (ghostel-bench--measure
             "e2e/mixed/eat" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--e2e-eat data-file))))
          (when ghostel-bench-include-term
            (ghostel-bench--measure
             "e2e/mixed/term" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-term data-file)))))
      (delete-file data-file))))

(defun ghostel-bench--pty-ghostel (data-file full-redraw &optional no-detect)
  "Benchmark ghostel processing `cat DATA-FILE' through a real PTY.
FULL-REDRAW controls `ghostel-full-redraw'.
When NO-DETECT is non-nil, disable URL and file detection."
  (ghostel-bench--with-bench-buffer
	(let* ((rows 24) (cols 80)
           (term (ghostel-bench--make-ghostel rows cols))
           (ghostel-enable-url-detection (not no-detect))
           (ghostel-enable-file-detection (not no-detect))
           (inhibit-read-only t)
           (redraw-timer nil)
           (pending nil)
           (done nil)
           ;; Wire up the same filter/timer loop as real ghostel-mode,
           ;; batching writes to reduce per-call VT parser overhead.
           (proc (make-process
                  :name "ghostel-bench"
                  :buffer (current-buffer)
                  :command (list "cat" (expand-file-name data-file))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter (lambda (_proc output)
                            (push output pending)
                            (unless redraw-timer
                              (setq redraw-timer
                                    (run-with-timer
                                     0.033 nil
                                     (lambda ()
                                       (setq redraw-timer nil)
                                       (let ((inhibit-read-only t))
                                         (when pending
                                           (ghostel--write-input
                                            term
                                            (apply #'concat (nreverse pending)))
                                           (setq pending nil))
                                         (ghostel--redraw term full-redraw)))))))
                  :sentinel (lambda (_proc _event)
                              (setq done t)))))
      (set-process-window-size proc rows cols)
      ;; Run Emacs event loop until process exits
      (while (not done)
        (accept-process-output proc 30))
      ;; Flush any pending output and redraw
      (when redraw-timer (cancel-timer redraw-timer))
      (when pending
        (ghostel--write-input term (apply #'concat (nreverse pending)))
        (setq pending nil))
      (ghostel--redraw term full-redraw))))

(defun ghostel-bench--pty-vterm (data-file)
  "Benchmark vterm processing `cat DATA-FILE' through a real PTY."
  (ghostel-bench--with-bench-buffer
	(let* ((rows 24) (cols 80)
           (term (ghostel-bench--make-vterm rows cols))
           (redraw-timer nil)
           (done nil)
           (proc (make-process
                  :name "vterm-bench"
                  :buffer (current-buffer)
                  :command (list "cat" (expand-file-name data-file))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter (lambda (_proc output)
                            (vterm--write-input term output)
                            (unless redraw-timer
                              (setq redraw-timer
                                    (run-with-timer
                                     0.033 nil
                                     (lambda ()
                                       (setq redraw-timer nil)
                                       (vterm--redraw term))))))
                  :sentinel (lambda (_proc _event)
                              (setq done t)))))
      (set-process-window-size proc rows cols)
      (while (not done)
        (accept-process-output proc 30))
      (when redraw-timer (cancel-timer redraw-timer))
      (vterm--redraw term))))

(defun ghostel-bench--pty-eat (data-file)
  "Benchmark eat processing `cat DATA-FILE' through a real PTY."
  (ghostel-bench--with-bench-buffer
	(let* ((rows 24) (cols 80)
           (term (ghostel-bench--make-eat rows cols))
           (inhibit-read-only t)
           (redraw-timer nil)
           (done nil)
           (proc (make-process
                  :name "eat-bench"
                  :buffer (current-buffer)
                  :command (list "cat" (expand-file-name data-file))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter (lambda (_proc output)
                            (let ((inhibit-read-only t))
                              (eat-term-process-output
                               term
                               (decode-coding-string output 'utf-8)))
                            (unless redraw-timer
                              (setq redraw-timer
                                    (run-with-timer
                                     0.033 nil
                                     (lambda ()
                                       (setq redraw-timer nil)
                                       (let ((inhibit-read-only t))
                                         (eat-term-redisplay term)))))))
                  :sentinel (lambda (_proc _event)
                              (setq done t)))))
      (set-process-window-size proc rows cols)
      (while (not done)
        (accept-process-output proc 30))
      (when redraw-timer (cancel-timer redraw-timer))
      (eat-term-redisplay term)
      (eat-term-delete term))))

(defun ghostel-bench--pty-term (data-file)
  "Benchmark Emacs built-in term processing `cat DATA-FILE' through a pipe.
Uses `term-emulate-terminal' directly as the process filter, which is
how real `M-x term' works — no timer batching since term does parse
and render in a single call."
  (ghostel-bench--with-bench-buffer
	(term-mode)
	(setq term-width 80 term-height 24)
	(setq term-buffer-maximum-size ghostel-bench-scrollback)
	(let* ((inhibit-read-only t)
           (done nil)
           (proc (make-process
                  :name "term-bench"
                  :buffer (current-buffer)
                  :command (list "cat" (expand-file-name data-file))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter #'term-emulate-terminal
                  :sentinel (lambda (_proc _event)
                              (setq done t)))))
      (set-process-window-size proc 24 80)
      (while (not done)
        (accept-process-output proc 30)))))

(defun ghostel-bench--run-pty-scenarios ()
  "Run real PTY benchmarks — the most representative test."
  (message "\n--- Real-World PTY Benchmark (cat %s through process pipe) ---"
           (ghostel-bench--human-size ghostel-bench-data-size))
  (message "  Uses the same filter + timer redraw loop as actual terminal usage.")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "MB/s")
  (message "  %s" (make-string 90 ?-))
  ;; --- Plain ASCII data ---
  (let ((data-file (ghostel-bench--write-data-file
                    #'ghostel-bench--gen-plain-ascii)))
    (unwind-protect
        (progn
          (message "  [plain ASCII data]")
          ;; ghostel incremental
          (ghostel-bench--measure
           "pty/plain/ghostel-incr" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file nil)))
          ;; ghostel full
          (ghostel-bench--measure
           "pty/plain/ghostel-full" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file t)))
          ;; ghostel default, no URL/file detection
          (ghostel-bench--measure
           "pty/plain/ghostel-nodetect" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file ghostel-full-redraw t)))
          ;; vterm
          (when ghostel-bench-include-vterm
            (ghostel-bench--measure
             "pty/plain/vterm" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-vterm data-file))))
          ;; eat
          (when ghostel-bench-include-eat
            (ghostel-bench--measure
             "pty/plain/eat" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-eat data-file))))
          ;; term
          (when ghostel-bench-include-term
            (ghostel-bench--measure
             "pty/plain/term" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-term data-file)))))
      (delete-file data-file)))
  ;; --- URL/path-heavy data ---
  (let ((data-file (ghostel-bench--write-data-file
                    #'ghostel-bench--gen-urls-and-paths)))
    (unwind-protect
        (progn
          (message "  [URL & file-path heavy data]")
          ;; ghostel default (detection on)
          (ghostel-bench--measure
           "pty/urls/ghostel" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file ghostel-full-redraw)))
          ;; ghostel no detection
          (ghostel-bench--measure
           "pty/urls/ghostel-nodetect" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file ghostel-full-redraw t)))
          ;; vterm (baseline)
          (when ghostel-bench-include-vterm
            (ghostel-bench--measure
             "pty/urls/vterm" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-vterm data-file))))
          ;; eat (baseline)
          (when ghostel-bench-include-eat
            (ghostel-bench--measure
             "pty/urls/eat" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-eat data-file))))
          ;; term (baseline)
          (when ghostel-bench-include-term
            (ghostel-bench--measure
             "pty/urls/term" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-term data-file)))))
      (delete-file data-file)))
  ;; --- Mixed emoji/CJK/ASCII: exercises wide-char and grapheme-cluster paths ---
  (let ((data-file (ghostel-bench--write-data-file
                    #'ghostel-bench--gen-mixed-emoji-cjk-ascii)))
    (unwind-protect
        (progn
          (message "  [mixed emoji/CJK/ASCII data]")
          ;; ghostel incremental
          (ghostel-bench--measure
           "pty/mixed/ghostel-incr" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file nil)))
          ;; ghostel full
          (ghostel-bench--measure
           "pty/mixed/ghostel-full" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file t)))
          ;; ghostel default, no URL/file detection
          (ghostel-bench--measure
           "pty/mixed/ghostel-nodetect" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file ghostel-full-redraw t)))
          ;; vterm
          (when ghostel-bench-include-vterm
            (ghostel-bench--measure
             "pty/mixed/vterm" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-vterm data-file))))
          ;; eat
          (when ghostel-bench-include-eat
            (ghostel-bench--measure
             "pty/mixed/eat" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-eat data-file))))
          ;; term
          (when ghostel-bench-include-term
            (ghostel-bench--measure
             "pty/mixed/term" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-term data-file)))))
      (delete-file data-file))))

;; =========================================================================
;; SECTION 2: Streaming benchmark — chunked write + periodic redraw
;; =========================================================================

(defun ghostel-bench--run-stream-scenarios ()
  "Run streaming benchmarks (chunked input with periodic redraws).
Simulates how data flows in practice: many small writes to the
terminal engine with periodic redraws, all in a tight loop."
  (message "\n--- Streaming (chunked write + periodic redraw, no PTY) ---")
  (message "  4KB chunks, redraw every 16 chunks (~64KB)")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "MB/s")
  (message "  %s" (make-string 90 ?-))
  (let* ((raw-data (ghostel-bench--gen-plain-ascii ghostel-bench-data-size))
         (chunk-size ghostel-bench-chunk-size)
         (redraw-every 16))
    ;; ghostel incremental
    (ghostel-bench--with-bench-buffer
      (let* ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
             (data-len (length data))
             (term (ghostel-bench--make-ghostel 24 80))
             (inhibit-read-only t))
        (ghostel-bench--measure
         "stream/ghostel-incr" (string-bytes data) ghostel-bench-iterations
         (lambda ()
           (let ((offset 0) (chunk-count 0))
             (while (< offset data-len)
               (let ((end (min (+ offset chunk-size) data-len)))
                 (ghostel--write-input term (substring data offset end))
                 (setq offset end)
                 (cl-incf chunk-count)
                 (when (zerop (% chunk-count redraw-every))
                   (ghostel--redraw term nil)))))))))
    ;; ghostel full
    (ghostel-bench--with-bench-buffer
      (let* ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
             (data-len (length data))
             (term (ghostel-bench--make-ghostel 24 80))
             (inhibit-read-only t))
        (ghostel-bench--measure
         "stream/ghostel-full" (string-bytes data) ghostel-bench-iterations
         (lambda ()
           (let ((offset 0) (chunk-count 0))
             (while (< offset data-len)
               (let ((end (min (+ offset chunk-size) data-len)))
                 (ghostel--write-input term (substring data offset end))
                 (setq offset end)
                 (cl-incf chunk-count)
                 (when (zerop (% chunk-count redraw-every))
                   (ghostel--redraw term t)))))))))
    ;; ghostel default, no detection
    (ghostel-bench--with-bench-buffer
      (let* ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
             (data-len (length data))
             (term (ghostel-bench--make-ghostel 24 80))
             (ghostel-enable-url-detection nil)
             (ghostel-enable-file-detection nil)
             (inhibit-read-only t))
        (ghostel-bench--measure
         "stream/ghostel-nodetect" (string-bytes data) ghostel-bench-iterations
         (lambda ()
           (let ((offset 0) (chunk-count 0))
             (while (< offset data-len)
               (let ((end (min (+ offset chunk-size) data-len)))
                 (ghostel--write-input term (substring data offset end))
                 (setq offset end)
                 (cl-incf chunk-count)
                 (when (zerop (% chunk-count redraw-every))
                   (ghostel--redraw term ghostel-full-redraw)))))))))
    ;; vterm
    (when ghostel-bench-include-vterm
      (ghostel-bench--with-bench-buffer
		(let* ((data (ghostel-bench--encode-for-backend raw-data 'vterm))
               (data-len (length data))
               (term (ghostel-bench--make-vterm 24 80)))
          (ghostel-bench--measure
           "stream/vterm" (string-bytes data) ghostel-bench-iterations
           (lambda ()
             (let ((offset 0) (chunk-count 0))
               (while (< offset data-len)
                 (let ((end (min (+ offset chunk-size) data-len)))
                   (vterm--write-input term (substring data offset end))
                   (setq offset end)
                   (cl-incf chunk-count)
                   (when (zerop (% chunk-count redraw-every))
                     (vterm--redraw term))))))))))
    ;; eat
    (when ghostel-bench-include-eat
      (ghostel-bench--with-bench-buffer
		(let* ((data (ghostel-bench--encode-for-backend raw-data 'eat))
               (data-len (length data))
               (term (ghostel-bench--make-eat 24 80))
               (inhibit-read-only t))
          (ghostel-bench--measure
           "stream/eat" (string-bytes data) ghostel-bench-iterations
           (lambda ()
             (let ((offset 0) (chunk-count 0))
               (while (< offset data-len)
                 (let ((end (min (+ offset chunk-size) data-len)))
                   (eat-term-process-output term (substring data offset end))
                   (setq offset end)
                   (cl-incf chunk-count)
                   (when (zerop (% chunk-count redraw-every))
                     (eat-term-redisplay term)))))))
          (eat-term-delete term))))
    ;; term
    (when ghostel-bench-include-term
      (ghostel-bench--with-bench-buffer
		(let* ((data (ghostel-bench--encode-for-backend raw-data 'term))
               (data-len (length data))
               (proc (ghostel-bench--make-term 24 80))
               (inhibit-read-only t))
          (ghostel-bench--measure
           "stream/term" (string-bytes data) ghostel-bench-iterations
           (lambda ()
             (let ((offset 0))
               (while (< offset data-len)
                 (let ((end (min (+ offset chunk-size) data-len)))
                   (term-emulate-terminal proc (substring data offset end))
                   (setq offset end))))))
          (delete-process proc))))))

;; =========================================================================
;; SECTION 3: TUI frame benchmark (full-screen rewrites)
;; =========================================================================

(defun ghostel-bench--run-tui-scenarios ()
  "Benchmark TUI-style full-screen rewrites.
Measures how fast each backend can update a full screen of styled
content — relevant for apps like htop, vim, claude-code."
  (message "\n--- TUI Frame Rendering (full-screen rewrites) ---")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "fps")
  (message "  %s" (make-string 90 ?-))
  (let ((tui-iterations (* ghostel-bench-iterations 20)))
    (dolist (size ghostel-bench-terminal-sizes)
      (let* ((rows (car size))
             (cols (cdr size))
             (raw-frame (ghostel-bench--gen-tui-frame rows cols))
             (label (format "%dx%d" rows cols)))
        ;; ghostel incremental
        (ghostel-bench--with-bench-buffer
          (let ((frame (ghostel-bench--encode-for-backend raw-frame 'ghostel))
                (term (ghostel-bench--make-ghostel rows cols))
                (inhibit-read-only t))
            (let ((result
                   (ghostel-bench--measure
                    (format "tui-frame/ghostel-incr/%s" label)
                    (string-bytes frame) tui-iterations
                    (lambda ()
                      (ghostel--write-input term frame)
                      (ghostel--redraw term nil)))))
              (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))))
        ;; ghostel full
        (ghostel-bench--with-bench-buffer
          (let ((frame (ghostel-bench--encode-for-backend raw-frame 'ghostel))
                (term (ghostel-bench--make-ghostel rows cols))
                (inhibit-read-only t))
            (let ((result
                   (ghostel-bench--measure
                    (format "tui-frame/ghostel-full/%s" label)
                    (string-bytes frame) tui-iterations
                    (lambda ()
                      (ghostel--write-input term frame)
                      (ghostel--redraw term t)))))
              (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))))
        ;; vterm
        (when ghostel-bench-include-vterm
          (ghostel-bench--with-bench-buffer
			(let ((frame (ghostel-bench--encode-for-backend raw-frame 'vterm))
                  (term (ghostel-bench--make-vterm rows cols)))
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-frame/vterm/%s" label)
                      (string-bytes frame) tui-iterations
                      (lambda ()
                        (vterm--write-input term frame)
                        (vterm--redraw term)))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms)))))))
        ;; eat
        (when ghostel-bench-include-eat
          (ghostel-bench--with-bench-buffer
			(let ((frame (ghostel-bench--encode-for-backend raw-frame 'eat))
                  (term (ghostel-bench--make-eat rows cols))
                  (inhibit-read-only t))
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-frame/eat/%s" label)
                      (string-bytes frame) tui-iterations
                      (lambda ()
                        (eat-term-process-output term frame)
                        (eat-term-redisplay term)))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))
              (eat-term-delete term))))
        ;; term
        (when ghostel-bench-include-term
          (ghostel-bench--with-bench-buffer
			(let* ((frame (ghostel-bench--encode-for-backend raw-frame 'term))
                   (proc (ghostel-bench--make-term rows cols))
                   (inhibit-read-only t))
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-frame/term/%s" label)
                      (string-bytes frame) tui-iterations
                      (lambda ()
                        (term-emulate-terminal proc frame)))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))
              (delete-process proc))))))))

;; =========================================================================
;; SECTION 3b: TUI partial-update — static screen + status-line update
;; =========================================================================

(defun ghostel-bench--run-tui-partial-scenarios ()
  "Benchmark partial-update workload (status-line update over static screen).
The `tui-frame' scenario rewrites every row per iteration, so it cannot
distinguish backends that honor per-row dirty tracking from those that
re-render unconditionally.  Here the static screen is rendered once and
only the bottom row is rewritten per iteration — the workload that
status bars, prompt redraws, and most TUI updates actually produce."
  (message "\n--- TUI Partial Update (bottom-row update over static screen) ---")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "fps")
  (message "  %s" (make-string 90 ?-))
  (let ((partial-iters (* ghostel-bench-iterations 1000)))
    (dolist (size ghostel-bench-terminal-sizes)
      (let* ((rows (car size))
             (cols (cdr size))
             (label (format "%dx%d" rows cols))
             (static-frame (ghostel-bench--gen-tui-frame rows cols))
             (status-template (format "\e[%d;1H\e[1;33;41m%%-%ds\e[0m" rows cols)))
        ;; ghostel incremental
        (ghostel-bench--with-bench-buffer
          (let* ((static (ghostel-bench--encode-for-backend static-frame 'ghostel))
                 (term (ghostel-bench--make-ghostel rows cols))
                 (ghostel-enable-url-detection nil)
                 (ghostel-enable-file-detection nil)
                 (inhibit-read-only t)
                 (counter 0))
            (ghostel--write-input term static)
            (ghostel--redraw term t)
            (let ((result
                   (ghostel-bench--measure
                    (format "tui-partial/ghostel-incr/%s" label)
                    cols partial-iters
                    (lambda ()
                      (cl-incf counter)
                      (ghostel--write-input
                       term (format status-template (format "status #%d" counter)))
                      (ghostel--redraw term nil)))))
              (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))))
        ;; ghostel full
        (ghostel-bench--with-bench-buffer
          (let* ((static (ghostel-bench--encode-for-backend static-frame 'ghostel))
                 (term (ghostel-bench--make-ghostel rows cols))
                 (ghostel-enable-url-detection nil)
                 (ghostel-enable-file-detection nil)
                 (inhibit-read-only t)
                 (counter 0))
            (ghostel--write-input term static)
            (ghostel--redraw term t)
            (let ((result
                   (ghostel-bench--measure
                    (format "tui-partial/ghostel-full/%s" label)
                    cols partial-iters
                    (lambda ()
                      (cl-incf counter)
                      (ghostel--write-input
                       term (format status-template (format "status #%d" counter)))
                      (ghostel--redraw term t)))))
              (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))))
        ;; vterm
        (when ghostel-bench-include-vterm
          (ghostel-bench--with-bench-buffer
			(let* ((static (ghostel-bench--encode-for-backend static-frame 'vterm))
                   (term (ghostel-bench--make-vterm rows cols))
                   (counter 0))
              (vterm--write-input term static)
              (vterm--redraw term)
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-partial/vterm/%s" label)
                      cols partial-iters
                      (lambda ()
                        (cl-incf counter)
                        (vterm--write-input
                         term (format status-template (format "status #%d" counter)))
                        (vterm--redraw term)))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms)))))))
        ;; eat
        (when ghostel-bench-include-eat
          (ghostel-bench--with-bench-buffer
			(let* ((static (ghostel-bench--encode-for-backend static-frame 'eat))
                   (term (ghostel-bench--make-eat rows cols))
                   (inhibit-read-only t)
                   (counter 0))
              (eat-term-process-output term static)
              (eat-term-redisplay term)
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-partial/eat/%s" label)
                      cols partial-iters
                      (lambda ()
                        (cl-incf counter)
                        (eat-term-process-output
                         term (ghostel-bench--encode-for-backend
                               (format status-template (format "status #%d" counter))
                               'eat))
                        (eat-term-redisplay term)))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))
              (eat-term-delete term))))
        ;; term
        (when ghostel-bench-include-term
          (ghostel-bench--with-bench-buffer
			(let* ((static (ghostel-bench--encode-for-backend static-frame 'term))
                   (proc (ghostel-bench--make-term rows cols))
                   (inhibit-read-only t)
                   (counter 0))
              (term-emulate-terminal proc static)
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-partial/term/%s" label)
                      cols partial-iters
                      (lambda ()
                        (cl-incf counter)
                        (term-emulate-terminal
                         proc (ghostel-bench--encode-for-backend
                               (format status-template (format "status #%d" counter))
                               'term))))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))
              (delete-process proc))))))))

;; =========================================================================
;; SECTION 4: Engine micro-benchmarks (bulk parse/render, single call)
;; =========================================================================

(defun ghostel-bench--run-for-backends (name raw-data rows cols iters render-p)
  "Run benchmark NAME with RAW-DATA on all backends.
ROWS and COLS specify terminal size.  ITERS is iteration count.
When RENDER-P is non-nil, also call redraw after write-input."
  (let ((label (format "%dx%d" rows cols)))
    ;; When rendering, prefix each iteration with a unique line so that
    ;; dirty tracking cannot optimize away the redraw.
    ;; ghostel incremental
    (ghostel-bench--with-bench-buffer
      (let ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
            (term (ghostel-bench--make-ghostel rows cols))
            (inhibit-read-only t)
            (counter 0))
        (ghostel-bench--measure
         (format "%s/ghostel-incr/%s" name label)
         (string-bytes data) iters
         (if render-p
             (lambda ()
               (setq counter (1+ counter))
               (ghostel--write-input term (format "\e[H%d\r\n" counter))
               (ghostel--write-input term data)
               (ghostel--redraw term nil))
           (lambda () (ghostel--write-input term data))))))
    ;; ghostel full
    (when render-p
      (ghostel-bench--with-bench-buffer
		(let ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
              (term (ghostel-bench--make-ghostel rows cols))
              (inhibit-read-only t)
              (counter 0))
          (ghostel-bench--measure
           (format "%s/ghostel-full/%s" name label)
           (string-bytes data) iters
           (lambda ()
             (setq counter (1+ counter))
             (ghostel--write-input term (format "\e[H%d\r\n" counter))
             (ghostel--write-input term data)
             (ghostel--redraw term t))))))
    ;; vterm
    (when ghostel-bench-include-vterm
      (ghostel-bench--with-bench-buffer
		(let ((data (ghostel-bench--encode-for-backend raw-data 'vterm))
              (term (ghostel-bench--make-vterm rows cols))
              (counter 0))
          (ghostel-bench--measure
           (format "%s/vterm/%s" name label)
           (string-bytes data) iters
           (if render-p
               (lambda ()
                 (setq counter (1+ counter))
                 (vterm--write-input term (format "\e[H%d\r\n" counter))
                 (vterm--write-input term data)
                 (vterm--redraw term))
             (lambda () (vterm--write-input term data)))))))
    ;; eat
    (when ghostel-bench-include-eat
      (ghostel-bench--with-bench-buffer
		(let ((data (ghostel-bench--encode-for-backend raw-data 'eat))
              (term (ghostel-bench--make-eat rows cols))
              (inhibit-read-only t)
              (counter 0))
          (ghostel-bench--measure
           (format "%s/eat/%s" name label)
           (string-bytes data) iters
           (if render-p
               (lambda ()
                 (setq counter (1+ counter))
                 (eat-term-process-output
                  term (decode-coding-string
                        (format "\e[H%d\r\n" counter) 'utf-8))
                 (eat-term-process-output term data)
                 (eat-term-redisplay term))
             (lambda () (eat-term-process-output term data))))
          (eat-term-delete term))))
    ;; term
    (when ghostel-bench-include-term
      (ghostel-bench--with-bench-buffer
		(let* ((data (ghostel-bench--encode-for-backend raw-data 'term))
               (proc (ghostel-bench--make-term rows cols))
               (inhibit-read-only t)
               (counter 0))
          (ghostel-bench--measure
           (format "%s/term/%s" name label)
           (string-bytes data) iters
           (if render-p
               (lambda ()
                 (setq counter (1+ counter))
                 (term-emulate-terminal proc (format "\e[H%d\r\n" counter))
                 (term-emulate-terminal proc data))
             (lambda () (term-emulate-terminal proc data))))
          (delete-process proc))))))

(defun ghostel-bench--run-engine-scenarios ()
  "Run engine micro-benchmarks.
These dump all data in a single write-input call and do one redraw.
Useful for isolating engine overhead but NOT representative of
real-world performance (see PTY and streaming benchmarks for that)."
  (message "\n--- Engine Micro-Benchmarks (single bulk call, NOT real-world) ---")
  (message "  NOTE: These show per-call engine cost.  For real-world performance,")
  (message "  see the PTY and Streaming results above.")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "MB/s")
  (message "  %s" (make-string 90 ?-))
  (let ((scenarios
         `(("plain"   . ghostel-bench--gen-plain-ascii)
           ("styled"  . ghostel-bench--gen-sgr-styled)
           ("unicode" . ghostel-bench--gen-unicode)
           ("mixed"   . ghostel-bench--gen-mixed-emoji-cjk-ascii))))
    (dolist (scenario scenarios)
      (let* ((name (car scenario))
             (gen-fn (cdr scenario))
             (raw-data (funcall gen-fn ghostel-bench-data-size)))
        (ghostel-bench--run-for-backends
         (format "engine/%s" name) raw-data 24 80
         ghostel-bench-iterations t)))))

;; ---------------------------------------------------------------------------
;; Header / summary
;; ---------------------------------------------------------------------------

(defun ghostel-bench--human-size (bytes)
  "Format BYTES as a human-readable string."
  (cond
   ((>= bytes (* 1024 1024)) (format "%.1f MB" (/ bytes (expt 1024.0 2))))
   ((>= bytes 1024) (format "%.0f KB" (/ bytes 1024.0)))
   (t (format "%d B" bytes))))

(defun ghostel-bench--print-header ()
  "Print benchmark header."
  (message "")
  (message "=== Ghostel Performance Benchmark Suite ===")
  (message "")
  (message "  Date:       %s" (format-time-string "%Y-%m-%d %H:%M:%S"))
  (message "  Emacs:      %s" emacs-version)
  (message "  Data size:  %s" (ghostel-bench--human-size ghostel-bench-data-size))
  (message "  Iterations: %d" ghostel-bench-iterations)
  (message "  Scrollback: %d" ghostel-bench-scrollback)
  (message "  Backends:   ghostel-incr, ghostel-full%s%s%s"
           (if ghostel-bench-include-vterm ", vterm" "")
           (if ghostel-bench-include-eat ", eat" "")
           (if ghostel-bench-include-term ", term" ""))
  (message ""))

(defun ghostel-bench--print-summary ()
  "Print summary with end-to-end and engine-only results highlighted."
  (message "\n=== Summary ===")
  (let ((e2e-results
         (cl-remove-if-not
          (lambda (r) (string-prefix-p "e2e/" (plist-get r :name)))
          ghostel-bench--results))
        (pty-results
         (cl-remove-if-not
          (lambda (r) (string-prefix-p "pty/" (plist-get r :name)))
          ghostel-bench--results)))
    (when e2e-results
      (message "\n  End-to-end ghostel-mode pipeline (cat %s):"
               (ghostel-bench--human-size ghostel-bench-data-size))
      (dolist (r (sort (copy-sequence e2e-results)
                       (lambda (a b) (string< (plist-get a :name)
                                              (plist-get b :name)))))
        (message "    %-40s %8.0f ms  %6.1f MB/s"
                 (plist-get r :name)
                 (plist-get r :per-iter-ms)
                 (plist-get r :throughput-mbs))))
    (when pty-results
      (message "\n  Engine-only throughput (cat %s, no delayed-redraw):"
               (ghostel-bench--human-size ghostel-bench-data-size))
      (dolist (r (sort (copy-sequence pty-results)
                       (lambda (a b) (string< (plist-get a :name)
                                              (plist-get b :name)))))
        (message "    %-40s %8.0f ms  %6.1f MB/s"
                 (plist-get r :name)
                 (plist-get r :per-iter-ms)
                 (plist-get r :throughput-mbs)))))
  (message "\nDone."))

;; ---------------------------------------------------------------------------
;; Entry points
;; ---------------------------------------------------------------------------

(defun ghostel-bench--load-backends ()
  "Load available backends, adjusting include flags."
  (require 'ghostel)
  (when ghostel-bench-include-vterm
    (condition-case err
        (require 'vterm)
      (error
       (message "WARNING: vterm not available, skipping (%s)" (error-message-string err))
       (setq ghostel-bench-include-vterm nil))))
  (when ghostel-bench-include-eat
    (condition-case err
        (require 'eat)
      (error
       (message "WARNING: eat not available, skipping (%s)" (error-message-string err))
       (setq ghostel-bench-include-eat nil))))
  (when ghostel-bench-include-term
    (condition-case err
        (require 'term)
      (error
       (message "WARNING: term not available, skipping (%s)" (error-message-string err))
       (setq ghostel-bench-include-term nil)))))

(defun ghostel-bench-run-all ()
  "Run all benchmarks and print results."
  (ghostel-bench--load-backends)
  (setq ghostel-bench--results nil)
  (ghostel-bench--print-header)
  (ghostel-bench--run-e2e-scenarios)
  (ghostel-bench--run-pty-scenarios)
  (ghostel-bench--run-stream-scenarios)
  (ghostel-bench--run-tui-scenarios)
  (ghostel-bench--run-tui-partial-scenarios)
  (ghostel-bench--run-engine-scenarios)
  (ghostel-bench--print-summary))

(defun ghostel-bench-run-quick ()
  "Run a quick subset: smaller data, fewer iterations, single size."
  (setq ghostel-bench-data-size (* 100 1024))  ; 100 KB
  (setq ghostel-bench-iterations 2)
  (setq ghostel-bench-terminal-sizes '((24 . 80)))
  (ghostel-bench-run-all))

(defun ghostel-bench-run-e2e ()
  "Run only the end-to-end backend benchmarks.
Compares production filter pipelines (ghostel/vterm/eat/term) on the
same `cat' input, without the engine-only `pty/*' or synthetic
sections.  Honors `ghostel-bench-data-size', `-iterations', and the
backend-include flags."
  (ghostel-bench--load-backends)
  (setq ghostel-bench--results nil)
  (ghostel-bench--print-header)
  (ghostel-bench--run-e2e-scenarios)
  (ghostel-bench--print-summary))


;; ---------------------------------------------------------------------------
;; Typing latency benchmark
;; ---------------------------------------------------------------------------

(defvar ghostel-bench-typing-count 50
  "Number of keystrokes to send in the typing latency benchmark.")

(defun ghostel-bench-typing-latency ()
  "Benchmark per-keystroke typing latency through a real PTY.
Spawns a shell, types characters one at a time, and measures the
round-trip time from send to the echo appearing in the terminal.
Reports min/median/p99/max for PTY, render, and total latency."
  (interactive)
  (ghostel-bench--load-backends)
  (let* ((count ghostel-bench-typing-count)
         (results (ghostel-bench--typing-latency-ghostel count)))
    (ghostel-bench--typing-report "ghostel" results)
    results))

(defun ghostel-bench--typing-latency-ghostel (count)
  "Send COUNT single-character keystrokes and measure round-trip latency.
Returns a list of (PTY-MS RENDER-MS TOTAL-MS) for each keystroke."
  (let* ((buf (generate-new-buffer " *ghostel-typing-bench*"))
         (rows 24) (cols 80)
         (results nil))
    (with-current-buffer buf
      (let* ((term (ghostel-bench--make-ghostel rows cols))
             (inhibit-read-only t)
             (pending nil)
             (echo-received nil)
             (echo-time nil)
             ;; Start a cat process that echoes stdin
             (proc (make-process
                    :name "ghostel-typing-bench"
                    :buffer buf
                    :command (list "cat")
                    :connection-type 'pty
                    :coding 'binary
                    :noquery t
                    :filter (lambda (_proc output)
                              (push output pending)
                              (setq echo-time (current-time))
                              (setq echo-received t))
                    :sentinel #'ignore)))
        (set-process-window-size proc rows cols)
        ;; Wait for cat to be ready
        (sleep-for 0.1)
        ;; Type characters one at a time
        (dotimes (i count)
          (let* ((ch (string (+ ?a (% i 26))))
                 (send-time (current-time))
                 render-time)
            (setq echo-received nil echo-time nil)
            ;; Send character
            (process-send-string proc ch)
            ;; Wait for echo
            (let ((deadline (+ (float-time) 1.0)))
              (while (and (not echo-received)
                          (< (float-time) deadline))
                (accept-process-output proc 0.001)))
            ;; Feed to terminal and render
            (when pending
              (ghostel--write-input term (apply #'concat (nreverse pending)))
              (setq pending nil))
            (ghostel--redraw term nil)
            (setq render-time (current-time))
            ;; Record latencies
            (when echo-time
              (push (list (* 1000 (float-time (time-subtract echo-time send-time)))
                          (* 1000 (float-time (time-subtract render-time echo-time)))
                          (* 1000 (float-time (time-subtract render-time send-time))))
                    results))))
        ;; Cleanup
        (delete-process proc)))
    (kill-buffer buf)
    (nreverse results)))

(defun ghostel-bench--typing-report (label results)
  "Print a typing latency report for LABEL with RESULTS.
RESULTS is a list of (PTY-MS RENDER-MS TOTAL-MS)."
  (let ((n (length results)))
    (message "\n=== Typing Latency Benchmark: %s (%d keystrokes) ===" label n)
    (message "%-20s %8s %8s %8s %8s" "Phase" "Min" "Median" "P99" "Max")
    (message "%s" (make-string 56 ?-))
    (dolist (phase '(("PTY latency" 0) ("Render latency" 1) ("Total (e2e)" 2)))
      (let* ((name (car phase))
             (idx (cadr phase))
             (vals (sort (mapcar (lambda (r) (nth idx r)) results) #'<)))
        (when vals
          (message "%-20s %7.2fms %7.2fms %7.2fms %7.2fms"
                   name
                   (car vals)
                   (nth (/ n 2) vals)
                   (nth (min (1- n) (floor (* n 0.99))) vals)
                   (car (last vals))))))
    (message "")))

(provide 'ghostel-bench)

;;; ghostel-bench.el ends here
