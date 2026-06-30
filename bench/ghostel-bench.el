;;; ghostel-bench.el --- Performance benchmarks for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Compare terminal emulator performance: ghostel (incremental & full
;; redraw), vterm, eat, and Emacs built-in term.
;;
;; Two process-based scenarios cover what users actually experience:
;;
;;   * `e2e/*' — cross-emulator comparison.  Drives each backend's real
;;     production filter on the same `cat' input: for ghostel the full
;;     `ghostel-mode' pipeline (`ghostel--filter' → `ghostel--invalidate'
;;     → `ghostel--redraw-now' → `ghostel--schedule-link-detection' plus
;;     anchoring and wide-char compensation), and `vterm--filter' /
;;     `eat--filter' / `term-emulate-terminal' for the others.  Every
;;     backend here uses an Emacs-owned process, so for ghostel this is
;;     the Emacs PTY path; see `backend/*' for the native PTY path.
;;
;;   * `backend/*' — ghostel-only native-vs-Emacs PTY comparison through
;;     the real `ghostel--start-process' dispatch (a real PTY both ways).
;;     This is the only section that exercises the native Zig-owned PTY
;;     (background-thread reads), and the `time cat bigfile' a user sees.
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
;; SECTION 1: End-to-end cross-emulator benchmark
;;
;; `e2e/*' shares one input source (a real `cat' subprocess with the same
;; data file) across backends and routes it through each one's production
;; filter: ghostel's `ghostel--filter' / `ghostel--sentinel' (waiting for
;; full quiescence — redraw + link-detection timers drained), plus
;; `vterm--filter' / `eat--filter' / `term-emulate-terminal'.
;;
;; The process is `pipe' (not a PTY) so the file's literal CRLF bytes
;; reach the terminal unchanged (a PTY would re-translate LF→CRLF), which
;; keeps all backends on equal footing.  For ghostel this is therefore the
;; Emacs PTY path; the native PTY path is measured by `backend/*' below.
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
`ghostel--redraw-now' — the same code path a live shell drives.
The buffer is attached to the selected window so window-anchoring,
preedit, and wide-char paths in `ghostel--redraw-now' actually run.

When DETECT-P is non-nil, plain-text URL and file:line detection runs
post-redraw via `ghostel--schedule-link-detection'; the wall clock
includes the link-detection timer firing.

After cat exits, `ghostel--sentinel' flushes any pending output but
cancels the redraw timer without firing `ghostel--redraw-now'
\(production behavior: the user's next interaction triggers redraw).
For benchmarking we explicitly drive one final `ghostel--redraw-now'
post-sentinel so the full pipeline — including link detection on the
final batch — runs at least once per iteration.

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
          ;; in `ghostel--redraw-now' have a window to act on.  In
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
            ;; output to the native module but did not redraw).  Ensures
            ;; link detection runs at least once per iteration.
            (ghostel--redraw-now buf)
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
across reads, and calls `vterm--update' synchronously per filter call."
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
`ghostel--redraw-now' and link detection (the Emacs PTY path; see
`backend/*' for native).  For vterm and eat, exercises their production
`*--filter' (decode loop, control-seq split or output queue, per-chunk
update).  `term' installs `term-emulate-terminal' directly as its
process filter, which both parses and renders in one call."
  (message "\n--- End-to-End (real backend pipelines, cat %s) ---"
           (ghostel-bench--human-size ghostel-bench-data-size))
  (message "  ghostel: filter / invalidate / delayed-redraw / link-detection")
  (message "  vterm:   vterm--filter (decode + control-seq split + update)")
  (message "  eat:     eat--filter + eat--sentinel (queue drain on exit)")
  (message "  term:    `term-emulate-terminal' IS the filter (parse + render)")
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
             (lambda () (ghostel-bench--e2e-term data-file)))))
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
             (lambda () (ghostel-bench--e2e-term data-file)))))
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
             (lambda () (ghostel-bench--e2e-term data-file)))))
      (delete-file data-file))))

(defun ghostel-bench--e2e-term (data-file)
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

;; =========================================================================
;; SECTION 1b: Backend comparison — native vs Emacs PTY (real spawn)
;;
;; The e2e/* section installs a filter on a `pipe' process, so for
;; ghostel it only ever exercises the Emacs PTY path.  This section
;; spawns `cat' through ghostel's real `ghostel--start-process' dispatch
;; and toggles `ghostel-use-native-pty', so it is the only place that
;; measures the native Zig-owned PTY (background-thread reads fed straight
;; into libghostty-vt, invalidating Emacs only when the read would block)
;; against the Emacs-owned PTY (per-chunk `ghostel--filter' on the main
;; thread).  Real PTY both ways — identical line-discipline translation,
;; so the comparison is apples-to-apples — and the full `ghostel-mode'
;; render pipeline runs, so the wall clock is the `time cat bigfile' a
;; user actually sees.  ghostel-only: vterm/eat/term have no such split.
;; =========================================================================

(defun ghostel-bench--spawn-cat (data-file native-p)
  "Stream `cat DATA-FILE' through ghostel's real spawn path on one backend.
NATIVE-P selects the native Zig PTY (t) or the Emacs PTY (nil).  Returns
after the child exits and the final redraw drains, so the measured time
covers the full read -> libghostty -> buffer pipeline."
  (let* ((rows 24) (cols 80)
         (buf (generate-new-buffer " *ghostel-backend-bench*"))
         (ghostel-use-native-pty native-p)
         (ghostel-kill-buffer-on-exit nil)
         (ghostel-shell-integration nil)
         (ghostel-macos-login-shell nil)
         (ghostel-enable-url-detection nil)
         (ghostel-enable-file-detection nil)
         (ghostel-shell
          (list "/bin/sh" "-c"
                (format "exec cat %s"
                        (shell-quote-argument (expand-file-name data-file))))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new rows cols
                                            (* ghostel-bench-scrollback 1024))
                ghostel--term-rows rows
                ghostel--term-cols cols)
          (when (window-live-p (selected-window))
            (set-window-buffer (selected-window) buf))
          (ghostel--start-process)
          (let ((deadline (+ (float-time) 120)))
            (while (and ghostel--process
                        (process-live-p ghostel--process)
                        (< (float-time) deadline))
              (accept-process-output ghostel--process 0.05))
            ;; Include the final frame; drain any pending redraw timer.
            (when (buffer-live-p buf)
              (ghostel--redraw-now buf)
              (while (and ghostel--redraw-timer (< (float-time) deadline))
                (accept-process-output nil 0.01)))))
      (when (buffer-live-p buf)
        (when ghostel--term
          (ignore-errors (ghostel--kill-native-process ghostel--term)))
        (kill-buffer buf)))))

(defun ghostel-bench--run-backend-scenarios ()
  "Compare the native and Emacs PTY backends on identical `cat' input.
Both legs use a real PTY and the full render pipeline, so this is the
`time cat bigfile' the user experiences on each backend.  Reports the
native-vs-Emacs ratio per data shape."
  (message "\n--- Backend Comparison (native vs Emacs PTY, real spawn; cat %s) ---"
           (ghostel-bench--human-size ghostel-bench-data-size))
  (message "  native: Zig-owned PTY, background-thread reads, redraw on FD-block")
  (message "  emacs:  Emacs-owned PTY, per-chunk `ghostel--filter' on main thread")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "MB/s")
  (message "  %s" (make-string 90 ?-))
  (dolist (scenario '(("plain" . ghostel-bench--gen-plain-ascii)
                      ("mixed" . ghostel-bench--gen-mixed-emoji-cjk-ascii)))
    (let ((name (car scenario))
          (data-file (ghostel-bench--write-data-file (cdr scenario)))
          (native nil)
          (emacs nil))
      (unwind-protect
          (progn
            (message "  [%s data]" name)
            (setq native
                  (ghostel-bench--measure
                   (format "backend/%s/native" name)
                   ghostel-bench-data-size ghostel-bench-iterations
                   (lambda () (ghostel-bench--spawn-cat data-file t))))
            (setq emacs
                  (ghostel-bench--measure
                   (format "backend/%s/emacs" name)
                   ghostel-bench-data-size ghostel-bench-iterations
                   (lambda () (ghostel-bench--spawn-cat data-file nil))))
            (when (> (plist-get native :per-iter-ms) 0)
              (message "    ^ native is %.2fx the Emacs path"
                       (/ (plist-get emacs :per-iter-ms)
                          (plist-get native :per-iter-ms)))))
        (delete-file data-file)))))

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
                 (ghostel--write-vt term (substring data offset end))
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
                 (ghostel--write-vt term (substring data offset end))
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
                 (ghostel--write-vt term (substring data offset end))
                 (setq offset end)
                 (cl-incf chunk-count)
                 (when (zerop (% chunk-count redraw-every))
                   (ghostel--redraw term nil)))))))))
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
                      (ghostel--write-vt term frame)
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
                      (ghostel--write-vt term frame)
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
            (ghostel--write-vt term static)
            (ghostel--redraw term t)
            (let ((result
                   (ghostel-bench--measure
                    (format "tui-partial/ghostel-incr/%s" label)
                    cols partial-iters
                    (lambda ()
                      (cl-incf counter)
                     (ghostel--write-vt
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
            (ghostel--write-vt term static)
            (ghostel--redraw term t)
            (let ((result
                   (ghostel-bench--measure
                    (format "tui-partial/ghostel-full/%s" label)
                    cols partial-iters
                    (lambda ()
                      (cl-incf counter)
                     (ghostel--write-vt
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
               (ghostel--write-vt term (format "\e[H%d\r\n" counter))
               (ghostel--write-vt term data)
               (ghostel--redraw term nil))
           (lambda () (ghostel--write-vt term data))))))
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
             (ghostel--write-vt term (format "\e[H%d\r\n" counter))
             (ghostel--write-vt term data)
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
real-world performance (see the end-to-end and backend benchmarks)."
  (message "\n--- Engine Micro-Benchmarks (single bulk call, NOT real-world) ---")
  (message "  NOTE: These show per-call engine cost.  For real-world performance,")
  (message "  see the End-to-End and Backend results above.")
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
        (backend-results
         (cl-remove-if-not
          (lambda (r) (string-prefix-p "backend/" (plist-get r :name)))
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
    (when backend-results
      (message "\n  Native vs Emacs PTY backend (cat %s, real spawn):"
               (ghostel-bench--human-size ghostel-bench-data-size))
      (dolist (r (sort (copy-sequence backend-results)
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
  (ghostel-bench--run-backend-scenarios)
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
  "Run only the end-to-end cross-emulator benchmarks.
Compares production filter pipelines (ghostel/vterm/eat/term) on the
same `cat' input, without the synthetic or backend sections.  Honors
`ghostel-bench-data-size', `-iterations', and the backend-include flags."
  (ghostel-bench--load-backends)
  (setq ghostel-bench--results nil)
  (ghostel-bench--print-header)
  (ghostel-bench--run-e2e-scenarios)
  (ghostel-bench--print-summary))

(defun ghostel-bench-run-backends ()
  "Run only the native-vs-Emacs PTY backend comparison.
Honors `ghostel-bench-data-size' and `-iterations'.  ghostel-only; the
backend-include flags do not apply."
  (require 'ghostel)
  (setq ghostel-bench--results nil)
  (ghostel-bench--print-header)
  (ghostel-bench--run-backend-scenarios)
  (ghostel-bench--print-summary))


;; ---------------------------------------------------------------------------
;; Typing latency benchmark
;; ---------------------------------------------------------------------------

(defvar ghostel-bench-typing-count 1000
  "Number of keystrokes recorded in the typing latency benchmark.")

(defvar ghostel-bench-typing-warmup 30
  "Keystrokes sent before recording, to prime caches and discard cold-start cost.")

(defun ghostel-bench-typing-latency ()
  "Compare per-keystroke typing latency on the native and Emacs PTY backends.
Types `ghostel-bench-typing-count' characters one at a time through the real
`ghostel--send-string' path against a raw `cat' that echoes each byte, and
measures the round trip from send to the echoed character appearing in the
rendered buffer — the full interactive-echo path (`ghostel--invalidate' fires
an immediate `ghostel--redraw-now' because the keystroke is recent).

This is the one place the backend ordering can invert relative to throughput:
the native path reads off a background thread and signals Emacs through the
event pipe, so a single tiny echo carries an extra IPC hop the Emacs filter
\(which reads on the main thread) does not."
  (interactive)
  (require 'ghostel)
  (let ((count ghostel-bench-typing-count))
    (message "\n--- Typing Latency (real pipeline, send -> rendered; %d keystrokes) ---"
             count)
    (message "  %-8s  %5s  %8s  %8s  %8s  %8s" "BACKEND" "n" "min" "median" "p99" "max")
    (message "  %s" (make-string 56 ?-))
    (ghostel-bench--typing-report
     "native" (ghostel-bench--typing-latency-spawn count t))
    (ghostel-bench--typing-report
     "emacs" (ghostel-bench--typing-latency-spawn count nil))
    (message "")))

(defun ghostel-bench--typing-latency-spawn (count native-p)
  "Type COUNT chars through the real pipeline on one backend; return latencies.
NATIVE-P selects the native Zig PTY (t) or the Emacs PTY (nil).  Each element
is the milliseconds from `ghostel--send-string' to the echoed character
showing up in the rendered ghostel buffer."
  (let* ((rows 24) (cols 80)
         (buf (generate-new-buffer " *ghostel-typing-bench*"))
         (ghostel-use-native-pty native-p)
         (ghostel-kill-buffer-on-exit nil)
         (ghostel-shell-integration nil)
         (ghostel-macos-login-shell nil)
         (ghostel-enable-url-detection nil)
         (ghostel-enable-file-detection nil)
         ;; Raw `cat' echoes each byte once with no line-discipline buffering,
         ;; so single keystrokes round-trip immediately (not line-buffered).
         (ghostel-shell '("/bin/sh" "-c"
                          "stty raw -echo; printf GHOSTEL_TYPING_READY; exec cat"))
         (results nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new rows cols
                                            (* ghostel-bench-scrollback 1024))
                ghostel--term-rows rows
                ghostel--term-cols cols)
          (when (window-live-p (selected-window))
            (set-window-buffer (selected-window) buf))
          (ghostel--start-process)
          ;; Wait for `cat' to be up (grid shows the READY marker).
          (let ((deadline (+ (float-time) 5)))
            (while (and (not (string-search
                              "GHOSTEL_TYPING_READY"
                              (or (ghostel--copy-all-text ghostel--term) "")))
                        (< (float-time) deadline))
              (accept-process-output ghostel--process 0.01)))
          (cl-flet ((tap (ch)
                      ;; Send CH; return ms until the redraw materializes the
                      ;; echo.  `buffer-chars-modified-tick' bumps on every
                      ;; redraw, so detection is O(1) and unaffected by line
                      ;; wrapping or how large the buffer has grown — unlike
                      ;; rescanning the buffer, whose cost would creep into
                      ;; the measurement as more text accumulates.
                      (let ((tick (buffer-chars-modified-tick))
                            (send-time (current-time))
                            (deadline (+ (float-time) 2)))
                        (ghostel--send-string ch)
                        (while (and (= (buffer-chars-modified-tick) tick)
                                    (< (float-time) deadline))
                          (accept-process-output ghostel--process 0.001))
                        (* 1000 (float-time
                                 (time-subtract (current-time) send-time))))))
              ;; Warm up native trampolines, redraw caches, and the echo path;
              ;; these samples are discarded so cold-start cost doesn't skew
              ;; the tail.
              (dotimes (i ghostel-bench-typing-warmup)
                (tap (string (+ ?a (% i 26)))))
              ;; Collect once up front and defer GC during the run so a stray
              ;; collection doesn't land in the middle of a measurement.
              (garbage-collect)
              (let ((gc-cons-threshold (max gc-cons-threshold
                                            (* 256 1024 1024))))
                (dotimes (i count)
                  (push (tap (string (+ ?a (% i 26)))) results)))))
      (when (buffer-live-p buf)
        (when ghostel--term
          (ignore-errors (ghostel--kill-native-process ghostel--term)))
        (kill-buffer buf)))
    (nreverse results)))

(defun ghostel-bench--typing-report (label latencies)
  "Print a one-line min/median/p99/max summary of LATENCIES (ms) for LABEL."
  (let* ((n (length latencies))
         (vals (sort (copy-sequence latencies) #'<)))
    (if (zerop n)
        (message "  %-8s  (no samples)" label)
      (message "  %-8s  %5d  %6.2fms  %6.2fms  %6.2fms  %6.2fms"
               label n
               (car vals)
               (nth (/ n 2) vals)
               (nth (min (1- n) (floor (* n 0.99))) vals)
               (car (last vals))))))

(provide 'ghostel-bench)

;;; ghostel-bench.el ends here
