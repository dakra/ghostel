;;; ghostel-status.el --- Program status, bell and notifications for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; What a program running in the terminal reports about itself outside
;; the grid: the bell (BEL), desktop notifications (OSC 9, OSC 777) and
;; program status (OSC 7501, with ConEmu OSC 9;4 progress mapped onto
;; it).  The native module calls `ghostel--bell',
;; `ghostel--handle-notification', `ghostel--osc-program-status',
;; `ghostel--osc-progress' and `ghostel--program-status-reset'.
;;
;; Across terminals, `ghostel-status-buffers' lists those needing
;; attention most urgent first, `ghostel-status-next' switches to them
;; in turn and `ghostel-status-indicator-mode' counts them in every
;; mode line.

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'subr-x)

(declare-function alert "alert")
(declare-function spinner-start "spinner")
(declare-function spinner-stop "spinner")
(declare-function ghostel--buffer-focused-p "ghostel")
(declare-function ghostel--cycle "ghostel")
(declare-function ghostel-buffer-list "ghostel")
(declare-function ghostel--defer "ghostel")
(declare-function ghostel--mode-line-refresh "ghostel")
(declare-function ghostel--run-hook-safely "ghostel")
(declare-function ghostel--update-title "ghostel")


;;; Customization

(defcustom ghostel-bell-functions '(ghostel-ding)
  "Hook run when the terminal receives BEL.
Each function is called with no arguments and the terminal buffer
current.  Remove `ghostel-ding' to silence the bell."
  :type 'hook
  :group 'ghostel)

(define-obsolete-variable-alias 'ghostel-notification-function
  'ghostel-notification-functions "0.58.0")

(defcustom ghostel-notification-functions '(ghostel-default-notify)
  "Hook run for OSC 9 / OSC 777 desktop notifications.
Each function is called with two string arguments, TITLE and BODY,
with the originating terminal buffer current.  TITLE is empty for
iTerm2-style OSC 9.  The hook runs asynchronously via `run-at-time',
so handlers may block or spawn processes without stalling the
terminal."
  :type 'hook
  :group 'ghostel)

(defcustom ghostel-program-status-functions
  '(ghostel-status-mode-line ghostel-status-notify)
  "Hook run after a program status record changes.
Each function is called with ID, OLD and NEW, the terminal buffer
current.  ID is the record's id string, \"\" for the program itself.
OLD and NEW are the record plists before and after the change: OLD
is nil for a new record, NEW for a removed one.  A record has
`:state' (`idle', `working', `done', `blocked' or `error') and the
keys the program sent: `:kind' (`permission', `question' or
`auth'), `:progress' (0-100), `:app', `:title' and `:msg'.
Runs on the terminal output path, so keep handlers cheap."
  :type 'hook
  :group 'ghostel)

(defcustom ghostel-status-notify-states '(blocked done error)
  "States that need your attention.
A record entering one runs `ghostel-notification-functions' unless its
buffer is the one you are looking at; a terminal holding one counts in
`ghostel-status-buffers', `ghostel-status-next' and
`ghostel-status-indicator-mode'."
  :type '(set (const blocked) (const done) (const error)
              (const working) (const idle))
  :group 'ghostel)

(defcustom ghostel-status-acknowledge 'input
  "When a terminal's `done' and `error' records are dropped.
`input' when you send input to the terminal, `seen' as soon as it is
the buffer you are looking at, nil only by the command
`ghostel-status-acknowledge' or the program itself."
  :type '(choice (const :tag "On input" input)
                 (const :tag "When seen" seen)
                 (const :tag "Never" nil))
  :group 'ghostel)

(defcustom ghostel-status-mode-line-labels
  '((working . "...") (blocked . "blocked") (done . "done") (error . "error"))
  "Label per program status state, in mode lines and picker annotations.
`working' with a percentage shows the percentage instead, `blocked'
with a kind appends it.  A state without an entry shows nothing."
  :type '(alist :key-type symbol :value-type string)
  :group 'ghostel)

(defcustom ghostel-spinner-type 'progress-bar
  "Spinner shown while a program works without a percentage.
A key of `spinner-types' from spinner.el, or nil for the plain
`working' label.  Ignored when spinner.el is not installed."
  :type '(choice (const :tag "Plain text" nil) symbol)
  :group 'ghostel)


;;; Bell

(defun ghostel-ding ()
  "Beep without terminating a running keyboard macro."
  (ding t))

(defun ghostel--bell ()
  "Run `ghostel-bell-functions' for a BEL from the native VT parser."
  (ghostel--run-hook-safely 'ghostel-bell-functions))


;;; Notifications

(defun ghostel-default-notify (title body)
  "Default handler for OSC 9 / OSC 777 notifications.
Uses the `alert' package (https://github.com/jwiegley/alert) when
available - it picks a sensible backend per platform (osascript on
macOS, libnotify on Linux, Growl, terminal-notifier, etc.).  Falls
back to `message' when alert isn't installed.  TITLE is the
notification summary; when empty (iTerm2-style OSC 9) the buffer
name is used.  BODY is the notification text.

Runs with the originating ghostel buffer current, so an empty
TITLE falls back to that buffer's name."
  (let ((summary (if (or (null title) (string-empty-p title))
                     (buffer-name)
                   title)))
    (if (and (require 'alert nil t) (fboundp 'alert))
        (alert body :title summary)
      (message "%s: %s" summary body))))

(defun ghostel-tty-forward-notify (title body)
  "Forward OSC 9 / OSC 777 notifications to the outer terminal.
On a tty frame, re-emit TITLE and BODY as OSC 9 (empty TITLE) or
OSC 777 to the frame showing this buffer, else the selected frame.
On a GUI frame, fall back to `ghostel-default-notify'.
Use in place of `ghostel-default-notify' in
`ghostel-notification-functions'."
  (let ((frame (window-frame (get-buffer-window nil t))))
    (if (tty-type frame)
        (send-string-to-terminal
         (if (string-empty-p title)
             (format "\e]9;%s\e\\" body)
           (format "\e]777;notify;%s;%s\e\\" title body))
         frame)
      (ghostel-default-notify title body))))

(defun ghostel--handle-notification (title body)
  "Run `ghostel-notification-functions' with TITLE and BODY.
Deferred via `ghostel--defer' so a slow backend (DBus, osascript)
does not block terminal output."
  (ghostel--defer #'ghostel--run-hook-safely
                  'ghostel-notification-functions title body))


;;; Program status records

(defconst ghostel-status--max-records 256
  "Records kept per terminal; past this the least recently updated goes.")

(defvar-local ghostel-program-status nil
  "Program status records, most recently updated first.
Each element is (ID . RECORD); see `ghostel-program-status-functions'.")

(defvar-local ghostel-status--osc7501-seen nil
  "Non-nil once an OSC 7501 report arrived; OSC 9;4 is then ignored until RIS.")

(defvar-local ghostel-status--title nil
  "Title of the root program status record, or nil.")

(defun ghostel-status--change (id old new)
  "Run the hook for record ID changing from OLD to NEW."
  (when (string-empty-p id)
    (let ((title (plist-get new :title)))
      (unless (equal title ghostel-status--title)
        (setq ghostel-status--title title)
        (ghostel--update-title))))
  (ghostel--run-hook-safely 'ghostel-program-status-functions id old new))

(defun ghostel-status--set (id record)
  "Replace record ID with RECORD, evicting the oldest past the cap."
  (let ((old (cdr (assoc id ghostel-program-status))))
    (setq ghostel-program-status
          (cons (cons id record)
                (assoc-delete-all id ghostel-program-status)))
    (when (> (length ghostel-program-status) ghostel-status--max-records)
      (let ((evicted (car (last ghostel-program-status))))
        (setq ghostel-program-status (butlast ghostel-program-status))
        (ghostel-status--change (car evicted) (cdr evicted) nil)))
    (ghostel-status--change id old record)
    (when (memq (plist-get record :state) '(done error))
      (ghostel-status--acknowledge-seen))))

(defun ghostel-status--remove-if (pred)
  "Remove every (ID . RECORD) entry satisfying PRED."
  (let ((removed (cl-remove-if-not pred ghostel-program-status)))
    (when removed
      (setq ghostel-program-status
            (cl-remove-if pred ghostel-program-status))
      (dolist (entry removed)
        (ghostel-status--change (car entry) (cdr entry) nil)))))

(defun ghostel-status--clear (id)
  "Remove record ID and its children; \"\" removes every record."
  (let ((prefix (concat id "/")))
    (ghostel-status--remove-if
     (lambda (entry)
       (or (string-empty-p id)
           (equal (car entry) id)
           (string-prefix-p prefix (car entry)))))))

(defun ghostel-status--drop-running ()
  "Remove `working' and `blocked' records, at a new prompt or process exit."
  (ghostel-status--remove-if
   (lambda (entry) (memq (plist-get (cdr entry) :state) '(working blocked)))))

(defun ghostel-status-acknowledge ()
  "Drop the `done' and `error' records of the current terminal."
  (interactive)
  (ghostel-status--remove-if
   (lambda (entry) (memq (plist-get (cdr entry) :state) '(done error)))))

(defun ghostel-status--acknowledge-on-input ()
  "Acknowledge on user input unless `ghostel-status-acknowledge' is nil."
  (when ghostel-status-acknowledge
    (ghostel-status-acknowledge)))

(defun ghostel-status--acknowledge-seen ()
  "Acknowledge when `ghostel-status-acknowledge' is `seen' and you look at it."
  (when (and (eq ghostel-status-acknowledge 'seen)
             ghostel-program-status
             (ghostel--buffer-focused-p (current-buffer)))
    (ghostel-status-acknowledge)))

(defun ghostel-status--kill-buffer ()
  "Drop every record of the terminal being killed, so nothing counts it."
  (ghostel-status--clear ""))


;;; Terminals needing attention

(defconst ghostel-status--urgency '(blocked error done working idle)
  "States most urgent first.")

(defun ghostel-status-buffer-state (buffer)
  "Return BUFFER's most urgent state in `ghostel-status-notify-states', or nil."
  (let ((states (mapcar (lambda (entry) (plist-get (cdr entry) :state))
                        (buffer-local-value 'ghostel-program-status buffer))))
    (seq-find (lambda (state) (and (memq state ghostel-status-notify-states)
                                   (memq state states)))
              ghostel-status--urgency)))

(defun ghostel-status-buffers ()
  "Return the terminals needing attention, most urgent first.
Those with a `ghostel-status-buffer-state', ordered by it, equal states
in `ghostel-buffer-list' order."
  (let ((rank (lambda (buf)
                (cl-position (ghostel-status-buffer-state buf)
                             ghostel-status--urgency))))
    (sort (cl-remove-if-not #'ghostel-status-buffer-state (ghostel-buffer-list))
          (lambda (a b) (< (funcall rank a) (funcall rank b))))))

(defun ghostel-status-next ()
  "Switch to the next terminal needing attention, most urgent first.
Repeating walks the terminals in that order and wraps; a terminal
dropped by `ghostel-status-acknowledge' leaves the walk."
  (interactive)
  (ghostel--cycle (ghostel-status-buffers) +1
                  "No terminal needs attention"
                  "Only this terminal needs attention"))

(defun ghostel-status-app (id)
  "Return the app of record ID, inherited from the nearest ancestor that has one."
  (or (plist-get (cdr (assoc id ghostel-program-status)) :app)
      (and (not (string-empty-p id))
           (ghostel-status-app (string-trim-right id "/?[^/]*")))))

(defun ghostel-status--record (state &rest props)
  "Return a record plist with STATE and the non-nil values in PROPS."
  `(:state ,state ,@(cl-loop for (key value) on props by #'cddr
                             when value append (list key value))))

(defconst ghostel-status--states '(idle working done blocked error clear)
  "OSC 7501 states accepted from the native module.")

(defconst ghostel-status--kinds '(permission question auth)
  "OSC 7501 kinds accepted from the native module.")

(defun ghostel--osc-program-status (state id kind progress app title msg)
  "Apply an OSC 7501 report from the native module.
STATE is the state name.  ID, KIND, APP, TITLE and MSG are strings or
nil; PROGRESS is an integer or nil."
  (when-let* ((state (car (memq (intern-soft state) ghostel-status--states))))
    (setq ghostel-status--osc7501-seen t)
    (let ((id (or id "")))
      (if (eq state 'clear)
          (ghostel-status--clear id)
        (ghostel-status--set
         id (ghostel-status--record state
                                    :kind (car (memq (intern-soft kind)
                                                     ghostel-status--kinds))
                                    :progress progress :app app
                                    :title title :msg msg))))))

(defun ghostel--osc-progress (state progress)
  "Apply a ConEmu OSC 9;4 report from the native module to the root record.
STATE is the ConEmu state name, PROGRESS an integer 0-100 or nil.
Ignored once the program has used OSC 7501, until the next full reset."
  (unless ghostel-status--osc7501-seen
    (pcase state
      ("remove" (ghostel-status--clear ""))
      ("set" (ghostel-status--set
              "" (ghostel-status--record 'working :progress (or progress 0))))
      ("indeterminate" (ghostel-status--set "" (ghostel-status--record 'working)))
      ("error" (ghostel-status--set "" (ghostel-status--record 'error)))
      ("pause" (ghostel-status--set
                "" (ghostel-status--record 'blocked :progress progress))))))

(defun ghostel--program-status-reset ()
  "Accept OSC 9;4 again after a full reset (RIS).
libghostty reports `clear' for every record on RIS by itself."
  (setq ghostel-status--osc7501-seen nil))


;;; Mode line

(defvar-local ghostel--mode-line-status nil
  "Mode-line text for the program status, or nil.")

(defvar-local ghostel--spinner-active nil
  "Non-nil while spinner.el animates `mode-line-process' in this buffer.")

(defvar ghostel-status--spinner-available (locate-library "spinner")
  "Non-nil when spinner.el was on `load-path' at load time.")

(defun ghostel-status--shown ()
  "Return the (ID . RECORD) entries the mode line shows, newest first.
The `blocked' and `error' records when there are any, else the root."
  (or (cl-remove-if-not
       (lambda (entry) (memq (plist-get (cdr entry) :state) '(blocked error)))
       ghostel-program-status)
      (when-let* ((root (assoc "" ghostel-program-status)))
        (list root))))

(defun ghostel-status--describe (entry)
  "Return the message, title or app of the (ID . RECORD) ENTRY, or nil."
  (or (plist-get (cdr entry) :msg)
      (plist-get (cdr entry) :title)
      (ghostel-status-app (car entry))))

(defun ghostel-status--label (entries &optional tip)
  "Return the mode-line text for the (ID . RECORD) list ENTRIES, or nil.
The first entry's record gives the state; the others only add to the
count.  TIP is the list of help-echo lines, by default what
`ghostel-status--describe' says of each entry."
  (let* ((record (cdar entries))
         (tip (or tip (delq nil (mapcar #'ghostel-status--describe entries))))
         (state (plist-get record :state))
         (progress (plist-get record :progress))
         (kind (plist-get record :kind))
         (label (alist-get state ghostel-status-mode-line-labels))
         (text (pcase state
                 ('working (if progress (format "%d%%" progress) label))
                 ('blocked (if (and label kind) (format "%s: %s" label kind) label))
                 (_ label))))
    (when text
      ;; The mode line reads "%]" as a construct; a bare percent is lost.
      (propertize (format " [%s%s]" (string-replace "%" "%%" text)
                          (if (cdr entries) (format " ×%d" (length entries)) ""))
                  'face (pcase state
                          ('blocked 'warning)
                          ('error 'error)
                          ('done 'success))
                  'help-echo (and tip (string-join tip "\n"))))))

(defun ghostel-status-mode-line (_id _old _new)
  "Show the program status in `mode-line-process'.
A `blocked' or `error' record anywhere takes precedence, with a count
when there are several; otherwise the root record shows.  Working
without a percentage runs a spinner when `ghostel-spinner-type' names
one and spinner.el is installed."
  (let* ((shown (ghostel-status--shown))
         (record (cdar shown)))
    (if (and (eq (plist-get record :state) 'working)
             (null (plist-get record :progress))
             ghostel-spinner-type
             ghostel-status--spinner-available
             (require 'spinner nil t))
        (unless ghostel--spinner-active
          (setq ghostel--mode-line-status nil
                ghostel--spinner-active t)
          (spinner-start ghostel-spinner-type))
      (when ghostel--spinner-active
        (ignore-errors (spinner-stop))
        (setq ghostel--spinner-active nil))
      (setq ghostel--mode-line-status (ghostel-status--label shown)))
    (ghostel--mode-line-refresh)))


;;; Notifications for status changes

(defun ghostel-status-notify (id old new)
  "Notify when record ID enters a `ghostel-status-notify-states' state as NEW.
Nothing is sent when OLD already had that state or the buffer is the
one being looked at."
  (let ((state (plist-get new :state)))
    (when (and (memq state ghostel-status-notify-states)
               (not (eq state (plist-get old :state)))
               (not (ghostel--buffer-focused-p (current-buffer))))
      (ghostel--handle-notification
       (or (plist-get new :title) (ghostel-status-app id) "")
       (or (plist-get new :msg)
           (if-let* ((kind (plist-get new :kind)))
               (format "%s: %s" state kind)
             (symbol-name state)))))))


;;; Indicator across terminals

(defvar ghostel-status--indicator nil
  "Mode-line text of `ghostel-status-indicator-mode', or nil.")
(put 'ghostel-status--indicator 'risky-local-variable t)

(defun ghostel-status--indicator-click (event)
  "Run `ghostel-status-next' in the window whose mode line got EVENT."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (ghostel-status-next)))

(defvar ghostel-status--indicator-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'ghostel-status--indicator-click)
    map)
  "Keymap of the indicator; a click runs `ghostel-status-next'.")

(defun ghostel-status--indicator-text ()
  "Return one label per attention state across all terminals, or nil."
  (let (parts)
    (pcase-dolist (`(,state . ,bufs)
                   (seq-group-by #'ghostel-status-buffer-state
                                 (ghostel-status-buffers)))
      (let ((entries (mapcar (lambda (buf)
                               (cl-find state
                                        (buffer-local-value 'ghostel-program-status buf)
                                        :key (lambda (entry)
                                               (plist-get (cdr entry) :state))))
                             bufs)))
        (push (ghostel-status--label
               entries
               (cl-mapcar (lambda (buf entry)
                            (format "%s: %s" (buffer-name buf)
                                    (or (with-current-buffer buf
                                          (ghostel-status--describe entry))
                                        state)))
                          bufs entries))
              parts)))
    (when parts
      (propertize (apply #'concat (nreverse parts))
                  'mouse-face 'mode-line-highlight
                  'local-map ghostel-status--indicator-map))))

(defun ghostel-status--update-indicator (&rest _)
  "Recompute the indicator; a member of `ghostel-program-status-functions'."
  (let ((text (ghostel-status--indicator-text)))
    (unless (equal-including-properties text ghostel-status--indicator)
      (setq ghostel-status--indicator text)
      (force-mode-line-update t))))

;;;###autoload
(define-minor-mode ghostel-status-indicator-mode
  "Count the terminals needing attention in every mode line.
One label per state in `ghostel-status-notify-states', as in the
terminal's own mode line, after × the number of terminals; hovering
names them.  A click runs `ghostel-status-next'.  Hidden while no
terminal needs attention."
  :global t
  :group 'ghostel
  (if ghostel-status-indicator-mode
      (progn
        (require 'ghostel)  ; Mode is autoloaded, ghostel may not be loaded yet.
        (add-hook 'ghostel-program-status-functions
                  #'ghostel-status--update-indicator)
        (or global-mode-string (setq global-mode-string '("")))
        (unless (memq 'ghostel-status--indicator global-mode-string)
          (setq global-mode-string
                (append global-mode-string '(ghostel-status--indicator))))
        (ghostel-status--update-indicator))
    (remove-hook 'ghostel-program-status-functions
                 #'ghostel-status--update-indicator)
    (setq global-mode-string
          (delq 'ghostel-status--indicator global-mode-string))
    (force-mode-line-update t)))

(provide 'ghostel-status)
;;; ghostel-status.el ends here
