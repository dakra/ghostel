;;; ghostel-tmux-integration-test.el --- End-to-end ghostel-tmux test -*- lexical-binding: t; -*-

;;; Commentary:

;; End-to-end integration test for ghostel-tmux.  Spawns a fake `tmux'
;; shell script that emits a hand-crafted but wire-accurate control-mode
;; transcript, then asserts that ghostel-tmux materializes the pane buffer
;; and renders the expected text.  Requires the native module.

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
    'capture-pane'*' -S '*)
      printf '%%begin %d %d 1\\r\\nHISTORY_LINE_ONE\\r\\n%%end %d %d 1\\r\\n' $i $i $i $i ;;
    capture-pane*)
      printf '%%begin %d %d 1\\r\\nVISIBLE_PROMPT$ \\r\\n%%end %d %d 1\\r\\n' $i $i $i $i
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


(provide 'ghostel-tmux-integration-test)

;;; ghostel-tmux-integration-test.el ends here
