;;; ghostel-tmux-integration-test.el --- End-to-end ghostel-tmux test -*- lexical-binding: t; -*-

;;; Commentary:

;; End-to-end integration test for ghostel-tmux.  Spawns a fake `tmux'
;; shell script that emits a hand-crafted but wire-accurate control-mode
;; transcript, then asserts that ghostel-tmux materializes the pane buffer
;; and renders the expected text.  Also feeds real bytes through the
;; native VT parser and verifies the Elisp DCS callback dispatch.
;; Requires the native module.

;;; Code:

(require 'ghostel-test-helpers)
(require 'ghostel-tmux)

;; ---------------------------------------------------------------------------
;; Fake tmux fixture
;; ---------------------------------------------------------------------------
;;
;; The wire format below was observed against tmux 3.4 in a docker
;; container.  Lines end with CRLF.  %output payloads use octal escape
;; encoding for control bytes.  The fake replies to each stdin command
;; line with its own `%begin'/`%end' block, mirroring real control-mode
;; pairing (one reply block per command line, in wire order).

(defconst ghostel-tmux-integration-test--script
  "#!/bin/sh
printf '\\033P1000p%%begin 1 0 0\\r\\n'
printf '%%end 1 0 0\\r\\n'
printf '%%session-changed $0 0\\r\\n'
i=1
while IFS= read -r line; do
  i=$((i+1))
  case \"$line\" in
    display-message*)
      printf '%%begin %d %d 1\\r\\n3.4\\r\\n%%end %d %d 1\\r\\n' $i $i $i $i ;;
    list-windows*)
      printf '%%begin %d %d 1\\r\\n@0\\tmain\\tbd5b,80x24,0,0,0\\r\\n%%end %d %d 1\\r\\n' $i $i $i $i ;;
    capture-pane*)
      printf '%%begin %d %d 1\\r\\nHISTORY_LINE_ONE\\r\\nVISIBLE_PROMPT$ \\r\\n%%end %d %d 1\\r\\n' $i $i $i $i
      printf '%%output %%0 BANNER_FROM_LIVE\\r\\n' ;;
    *)
      printf '%%begin %d %d 1\\r\\n%%end %d %d 1\\r\\n' $i $i $i $i ;;
  esac
done
"
  "Body of the fake tmux executable used by the integration test.")

(defun ghostel-tmux-integration-test--make-fake-tmux ()
  "Write the fake-tmux script to a tempfile and return its path."
  (let ((path (make-temp-file "ghostel-tmux-fake-" nil ".sh")))
    (with-temp-file path
      (insert ghostel-tmux-integration-test--script))
    (set-file-modes path #o755)
    path))

(defmacro ghostel-tmux-integration-test--with-host (spec &rest body)
  "Run BODY in a fresh ghostel buffer with a live terminal attached.
SPEC is (BUFFER TERM)."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,term) spec))
    `(let ((,buffer (generate-new-buffer " *ghostel-tmux-int*")))
       (unwind-protect
           (progn
             (ghostel--init-buffer ,buffer 24 80)
             (with-current-buffer ,buffer
               (let ((,term ghostel--term))
                 ,@body)))
         (when (buffer-live-p ,buffer)
           (kill-buffer ,buffer))))))

(defun ghostel-tmux-integration-test--drain ()
  "Fire the deferred callbacks queued by `ghostel--defer'."
  (accept-process-output nil 0.05))

;; ---------------------------------------------------------------------------
;; Tests
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-integration-attach-renders-pane ()
  "A dedicated controller against fake tmux materializes a rendered pane."
  :tags '(native)
  (let* ((fake (ghostel-tmux-integration-test--make-fake-tmux))
         (ghostel-tmux-program fake)
         (ghostel-tmux-history-lines 100)
         created-buf)
    (unwind-protect
        (progn
          ;; Override the session picker to skip list-sessions.
          (cl-letf (((symbol-function 'ghostel-tmux--read-session)
                     (lambda () "0")))
            (ghostel-tmux-attach "0"))
          ;; Wait until we see a pane buffer created and rendered.
          (let ((deadline (+ (float-time)
                             (* 5.0 ghostel-test--timeout-scale))))
            (catch 'done
              (while (< (float-time) deadline)
                (let ((bufs (cl-remove-if-not
                             (lambda (b)
                               (string-prefix-p "*ghostel-tmux:0:"
                                                (buffer-name b)))
                             (buffer-list))))
                  (when (and bufs
                             (with-current-buffer (car bufs)
                               (and ghostel-tmux--initialized
                                    ghostel--term)))
                    (setq created-buf (car bufs))
                    (throw 'done t)))
                (accept-process-output nil 0.1))))
          (should created-buf)
          ;; Force a redraw and assert that the rendered buffer holds at
          ;; least one of the pieces of text we fed in.
          (with-current-buffer created-buf
            (ghostel-test--redraw ghostel--term t)
            (let ((text (buffer-substring-no-properties (point-min)
                                                        (point-max))))
              (should (or (string-match-p "HISTORY_LINE_ONE" text)
                          (string-match-p "VISIBLE_PROMPT" text)
                          (string-match-p "BANNER_FROM_LIVE" text))))))
      (when (file-exists-p fake) (delete-file fake))
      (when (and created-buf (buffer-live-p created-buf))
        (kill-buffer created-buf))
      ;; Kill any controller buffer + child process we left behind.
      (dolist (b (buffer-list))
        (when (string-prefix-p " *ghostel-tmux-control:" (buffer-name b))
          (with-current-buffer b
            (when (and ghostel-tmux--controller-process
                       (process-live-p ghostel-tmux--controller-process))
              (delete-process ghostel-tmux--controller-process)))
          (kill-buffer b))))))

;; ---------------------------------------------------------------------------
;; Native DCS handling: feed real bytes through libghostty's parser and
;; verify that the core `ghostel--tmux-dcs-*' callbacks are dispatched
;; with the right payloads.  The callbacks are deferred like every other
;; native effect, so each write is followed by a drain.
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-tmux-integration-native-dcs-basic ()
  "A complete DCS frame dispatches enter, body data, and exit."
  :tags '(native)
  (ghostel-tmux-integration-test--with-host (host term)
    (let (entered exited fed)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter)
                 (lambda () (setq entered t)))
                ((symbol-function 'ghostel--tmux-dcs-data)
                 (lambda (data) (push data fed)))
                ((symbol-function 'ghostel--tmux-dcs-exit)
                 (lambda () (setq exited t))))
        ;; DCS with a body, surrounded by VT.
        (ghostel--write-vt term "before\n\eP1000pHELLO\e\\after")
        (ghostel-tmux-integration-test--drain)
        (should entered)
        (should exited)
        (should (equal (apply #'concat (nreverse fed)) "HELLO"))))))

(ert-deftest ghostel-tmux-integration-native-dcs-mid-line-triggers ()
  "A mid-line introducer enters DCS."
  :tags '(native)
  ;; A `\\eP1000p' anywhere in the byte stream enters DCS.
  ;; Line-anchored variants break the common case where shell
  ;; integration emits `\\e]133;C\\a' (OSC 133;C) between the prompt
  ;; newline and tmux's introducer.  False-positive risk on raw
  ;; binary files containing the literal 7-byte `\\eP1000p' is
  ;; theoretical; `M-x ghostel-tmux-reset' recovers.
  (ghostel-tmux-integration-test--with-host (host term)
    (let (entered)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter)
                 (lambda () (setq entered t)))
                ((symbol-function 'ghostel--tmux-dcs-data) #'ignore)
                ((symbol-function 'ghostel--tmux-dcs-exit) #'ignore))
        (ghostel--write-vt term "binary garbage \eP1000p more")
        (ghostel-tmux-integration-test--drain)
        (should entered)))))

(ert-deftest ghostel-tmux-integration-native-dcs-after-osc-133-triggers ()
  "A DCS right after an OSC 133;C still triggers detection."
  :tags '(native)
  ;; Shell-integration preexec emits OSC 133;C immediately before
  ;; `tmux -CC' starts.  The wire ends up as:
  ;; `\\r\\n\\e]133;C\\a\\eP1000p...' — the byte before `\\eP1000p' is
  ;; `\\a', not `\\n'.  Line-anchored detection would reject this,
  ;; making `tmux' a silent no-op in any ghostel buffer with
  ;; shell-integration enabled.
  (ghostel-tmux-integration-test--with-host (host term)
    (let (entered)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter)
                 (lambda () (setq entered t)))
                ((symbol-function 'ghostel--tmux-dcs-data) #'ignore)
                ((symbol-function 'ghostel--tmux-dcs-exit) #'ignore))
        (ghostel--write-vt term "prompt\r\n\e]133;C\a\eP1000p")
        (ghostel-tmux-integration-test--drain)
        (should entered)))))

(ert-deftest ghostel-tmux-integration-native-dcs-cross-chunk ()
  "DCS framing works when split across `ghostel--write-vt' calls."
  :tags '(native)
  ;; tmux control mode keeps the DCS open for the whole session, so
  ;; body bytes must stream incrementally.  Any ESC ends the string, so
  ;; exit fires on the ESC of the `\\e\\\\' terminator.
  (ghostel-tmux-integration-test--with-host (host term)
    (let (entered exited fed)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter)
                 (lambda () (setq entered t)))
                ((symbol-function 'ghostel--tmux-dcs-data)
                 (lambda (data) (push data fed)))
                ((symbol-function 'ghostel--tmux-dcs-exit)
                 (lambda () (setq exited t))))
        ;; Four chunks: prefix+partial-START, partial-START-tail+body,
        ;; body+partial-END, partial-END-tail+suffix.
        (ghostel--write-vt term "before\n\eP10")
        (ghostel-tmux-integration-test--drain)
        (should-not entered)
        (ghostel--write-vt term "00pBO")
        (ghostel-tmux-integration-test--drain)
        (should entered)
        (should-not exited)
        (should (equal (apply #'concat (reverse fed)) "BO"))
        (ghostel--write-vt term "DY\e")
        (ghostel-tmux-integration-test--drain)
        (should exited)
        (should (equal (apply #'concat (reverse fed)) "BODY"))
        (ghostel--write-vt term "\\after")
        (ghostel-tmux-integration-test--drain)
        ;; "after" is plain VT (delivered to libghostty's parser, not
        ;; the dcs-data callback).
        (should (equal (apply #'concat (reverse fed)) "BODY"))))))

(ert-deftest ghostel-tmux-integration-native-dcs-c1-bytes-survive ()
  "C1/high bytes inside a DCS body reach the data callback intact."
  :tags '(native)
  ;; tmux passes UTF-8 raw, including continuation bytes in the C1 range
  ;; (`\\xC3\\x97' = U+00D7).  The vt100.net state machine would treat
  ;; 0x97 as an exit; libghostty keeps 0x80-0xFF as DCS payload.
  (ghostel-tmux-integration-test--with-host (host term)
    (let ((body (encode-coding-string
                 "%output %0 hello × world\r\n" 'utf-8))
          entered exited fed)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter)
                 (lambda () (setq entered t)))
                ((symbol-function 'ghostel--tmux-dcs-data)
                 (lambda (data) (push data fed)))
                ((symbol-function 'ghostel--tmux-dcs-exit)
                 (lambda () (setq exited t))))
        (ghostel--write-vt term (concat "\eP1000p" body))
        (ghostel-tmux-integration-test--drain)
        (should entered)
        (should-not exited)
        ;; Body bytes after the 0x97 (and 0xC3) must NOT be lost.
        (should (equal (encode-coding-string (apply #'concat (reverse fed)) 'utf-8)
                       body))))))

(ert-deftest ghostel-tmux-integration-native-dcs-open-streams-before-exit ()
  "Body data from an unterminated frame streams per write chunk."
  :tags '(native)
  ;; tmux `-CC' emits one long-lived DCS for the session, so data from
  ;; an unterminated frame must still be delivered as each chunk arrives.
  (ghostel-tmux-integration-test--with-host (host term)
    (let (entered exited fed)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter)
                 (lambda () (setq entered t)))
                ((symbol-function 'ghostel--tmux-dcs-data)
                 (lambda (data) (push data fed)))
                ((symbol-function 'ghostel--tmux-dcs-exit)
                 (lambda () (setq exited t))))
        (ghostel--write-vt term "\eP1000p%begin 1 1 0\n")
        (ghostel-tmux-integration-test--drain)
        (should entered)
        (should-not exited)
        (should (equal (apply #'concat (reverse fed)) "%begin 1 1 0\n"))
        (ghostel--write-vt term "%output %1 hi\n")
        (ghostel-tmux-integration-test--drain)
        (should-not exited)
        (should (equal (apply #'concat (reverse fed))
                       "%begin 1 1 0\n%output %1 hi\n"))))))

(ert-deftest ghostel-tmux-integration-native-dcs-reset ()
  "`ghostel--tmux-dcs-reset' drops a wedged frame so VT flows again."
  :tags '(native)
  ;; When the elisp protocol parser breaks mid-DCS, the VT parser must
  ;; be forced back to ground — otherwise it keeps consuming bytes as
  ;; DCS body and elisp drops them.
  (ghostel-tmux-integration-test--with-host (host term)
    (let (entered post-reset-vt)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter)
                 (lambda () (setq entered t)))
                ((symbol-function 'ghostel--tmux-dcs-data) #'ignore)
                ((symbol-function 'ghostel--tmux-dcs-exit) #'ignore))
        ;; Open a DCS but never close it.
        (ghostel--write-vt term "\eP1000pHELLO")
        (ghostel-tmux-integration-test--drain)
        (should entered)
        ;; Bytes after the dangling open are body bytes; drop the frame
        ;; so the next bytes flow as VT again.
        (ghostel--tmux-dcs-reset term)
        ;; Feed something the term can render so we can verify it
        ;; reached the VT engine.
        (ghostel--write-vt term "POST\r\n")
        (ghostel-test--redraw term t)
        (setq post-reset-vt
              (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "POST" post-reset-vt)))))

(ert-deftest ghostel-tmux-integration-native-dcs-body-round-trips ()
  "Control chars and UTF-8 in a DCS body reach Elisp byte-for-byte."
  :tags '(native)
  (ghostel-tmux-integration-test--with-host (host term)
    (let ((body (encode-coding-string "a\001b\tc×d" 'utf-8))
          captured)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter) #'ignore)
                ((symbol-function 'ghostel--tmux-dcs-data)
                 (lambda (data) (setq captured data)))
                ((symbol-function 'ghostel--tmux-dcs-exit) #'ignore))
        (ghostel--write-vt term (concat "\eP1000p" body "\e\\"))
        (ghostel-tmux-integration-test--drain))
      (should (equal (encode-coding-string captured 'utf-8) body)))))

(ert-deftest ghostel-tmux-integration-native-osc-shaped-bytes-in-dcs-no-leak ()
  "OSC-shaped bytes inside a DCS body never trigger a query reply."
  :tags '(native)
  ;; DCS body bytes bypass libghostty's parser entirely, so a sequence
  ;; inside the body that *looks like* an OSC color query can never
  ;; fire a spurious response on the outbound channel.
  ;;
  ;; Note: this test must avoid raw ESC bytes inside the body — the VT
  ;; spec exits DCS on any ESC, so anything starting `\\e]' would not
  ;; be \"inside\" the DCS anyway.  Real tmux escapes such bytes to
  ;; literal octal text (`\\033]4;0;?'), which is exactly the harmless
  ;; shape we're feeding here.
  (ghostel-tmux-integration-test--with-host (host term)
    (let (out)
      (cl-letf (((symbol-function 'ghostel--tmux-dcs-enter) #'ignore)
                ((symbol-function 'ghostel--tmux-dcs-data) #'ignore)
                ((symbol-function 'ghostel--tmux-dcs-exit) #'ignore)
                ((symbol-function 'ghostel--pty-out)
                 (lambda (data) (push data out))))
        (ghostel--write-vt term "\eP1000p]10;?\x07HELLO\e\\")
        (should (null out))))))

(provide 'ghostel-tmux-integration-test)

;;; ghostel-tmux-integration-test.el ends here
