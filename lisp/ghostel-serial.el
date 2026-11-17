;;; ghostel-serial.el --- Serial consoles in Ghostel -*- lexical-binding: t; -*-

;; Author: Arthur Heymans <arthur@aheymans.xyz>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `ghostel-serial' opens a local serial port without spawning a shell or
;; PTY.  Disconnecting leaves a read-only log; reconnecting reuses it.
;; The transport and malformed-byte policies are inspired by Ebb's serial
;; frontend.  Terminal input and replies are sent as raw bytes.

;;; Code:

(require 'ghostel)
(require 'seq)

(defgroup ghostel-serial nil
  "Local serial consoles in Ghostel."
  :group 'ghostel)

(defcustom ghostel-serial-speed 115200
  "Default baud rate for new serial buffers."
  :type 'integer)

(defcustom ghostel-serial-invalid-byte-policy 'replacement
  "How to display malformed UTF-8 bytes received from the serial port."
  :type '(choice (const :tag "Replacement character" replacement)
                 (const :tag "Hex marker" hex)
                 (const :tag "Latin-1" latin-1)))

(defcustom ghostel-serial-break-function nil
  "Function to send a break, called with the live serial process.
Emacs has no portable serial break primitive; nil disables the command."
  :type '(choice (const :tag "Disabled" nil) function))

(defvar-local ghostel-serial--port nil)
(defvar-local ghostel-serial--speed nil)
(defvar-local ghostel-serial--process nil)
(defvar-local ghostel-serial--pending "")

(defun ghostel-serial--utf8-prefix-end (bytes)
  "Return the length of BYTES excluding a potentially incomplete UTF-8 tail."
  (let* ((end (length bytes))
         (start (1- end)))
    (while (and (>= start 0) (< (- end start) 4)
                (<= #x80 (aref bytes start) #xbf))
      (cl-decf start))
    (let* ((lead (and (>= start 0) (aref bytes start)))
           (width (cond ((null lead) 0)
                        ((<= #xc2 lead #xdf) 2)
                        ((<= #xe0 lead #xef) 3)
                        ((<= #xf0 lead #xf4) 4)
                        (t 0))))
      (if (< (- end start) width) start end))))

(defconst ghostel-serial--raw-byte-regexp
  (concat "[" (string (unibyte-char-to-multibyte #x80)) "-"
          (string (unibyte-char-to-multibyte #xff)) "]"))

(defun ghostel-serial--decode (bytes &optional final)
  "Decode BYTES and retain a split UTF-8 tail, or flush it if FINAL."
  (let* ((bytes (concat ghostel-serial--pending bytes))
         (end (if final (length bytes) (ghostel-serial--utf8-prefix-end bytes)))
         (text (decode-coding-string (substring bytes 0 end) 'utf-8-unix)))
    (setq ghostel-serial--pending (substring bytes end))
    (encode-coding-string
     (replace-regexp-in-string
      ghostel-serial--raw-byte-regexp
      (lambda (raw)
        (let ((byte (multibyte-char-to-unibyte (aref raw 0))))
          (pcase ghostel-serial-invalid-byte-policy
            ('hex (format "<%02X>" byte))
            ('latin-1 (string byte))
            (_ "�"))))
      text t t)
     'utf-8-unix)))

(defun ghostel-serial--send (bytes)
  "Write BYTES unchanged to the connected serial port."
  (when (process-live-p ghostel-serial--process)
    (process-send-string ghostel-serial--process bytes)))

(defun ghostel-serial--filter (process bytes)
  "Display BYTES received from the current serial PROCESS."
  (when-let* ((buffer (process-buffer process)))
    (with-current-buffer buffer
      (when (eq process ghostel-serial--process)
        (ghostel-write-output (ghostel-serial--decode bytes))))))

(defun ghostel-serial--end ()
  "Finish decoding and leave a read-only terminal snapshot."
  (setq ghostel-serial--process nil)
  (ghostel-write-output (ghostel-serial--decode "" t))
  ;; An incomplete escape sequence belongs to the old connection.
  (ghostel-write-output (unibyte-string ?\C-x))
  (ghostel-end-terminal))

(defun ghostel-serial--sentinel (process _event)
  "Finish the current serial PROCESS if it disconnected."
  (unless (process-live-p process)
    (when-let* ((buffer (process-buffer process)))
      (with-current-buffer buffer
        (when (eq process ghostel-serial--process)
          (ghostel-serial--end))))))

(defun ghostel-serial--open ()
  "Attach the current terminal to its configured serial port."
  (setq ghostel-serial--process
        (make-serial-process :port ghostel-serial--port
                             :speed ghostel-serial--speed
                             :buffer (current-buffer)
                             :coding 'no-conversion :noquery t
                             :filter #'ghostel-serial--filter
                             :sentinel #'ghostel-serial--sentinel))
  (setq ghostel--pty-out-function #'ghostel-serial--send)
  (ghostel--sync-read-only))

;;;###autoload
(defun ghostel-serial (port &optional speed)
  "Open local serial PORT at SPEED in a Ghostel buffer.
SPEED defaults to `ghostel-serial-speed'.  Reuse the same buffer and its
log if the port was already opened.  Return the terminal buffer."
  (interactive (list (if (eq system-type 'windows-nt)
                         (read-string "Serial port: " "COM1")
                       (read-file-name "Serial port: " "/dev/"))
                     (read-number "Baud rate: " ghostel-serial-speed)))
  (when (file-remote-p port) (user-error "Serial port must be local"))
  (unless (fboundp 'make-serial-process) (user-error "Emacs lacks serial support"))
  (ghostel-ensure-module)
  (let ((speed (or speed ghostel-serial-speed))
        (buffer (seq-find (lambda (candidate)
                            (equal port (buffer-local-value
                                         'ghostel-serial--port candidate)))
                          (ghostel-buffer-list))))
    (unless buffer
      (let ((default-directory (file-name-as-directory (expand-file-name "~")))
            (ghostel-kitty-graphics-storage-limit 0))
        (setq buffer (ghostel-make-terminal (format "*ghostel serial %s*" port))))
      (with-current-buffer buffer
        (setq ghostel-serial--port port ghostel-serial--speed speed)))
    (with-current-buffer buffer
      (if (process-live-p ghostel-serial--process)
          (unless (= speed ghostel-serial--speed)
            (serial-process-configure :process ghostel-serial--process :speed speed)
            (setq ghostel-serial--speed speed))
        (setq ghostel-serial--speed speed)
        (ghostel-serial--open)))
    (pop-to-buffer-same-window buffer)
    buffer))

;;;###autoload
(defun ghostel-serial-disconnect ()
  "Close the current serial port without erasing its terminal log."
  (interactive)
  (unless ghostel-serial--port (user-error "Not a Ghostel serial buffer"))
  (when-let* ((process ghostel-serial--process))
    (unwind-protect
        (delete-process process)
      (when (eq process ghostel-serial--process)
        (ghostel-serial--end)))))

;;;###autoload
(defun ghostel-serial-reconnect ()
  "Reopen the serial port and keep the existing terminal log."
  (interactive)
  (ghostel-serial-disconnect)
  (ghostel-serial--open))

;;;###autoload
(defun ghostel-serial-send-break ()
  "Send a serial break using `ghostel-serial-break-function'."
  (interactive)
  (unless (process-live-p ghostel-serial--process)
    (user-error "Serial port is not connected"))
  (unless ghostel-serial-break-function
    (user-error "Customize ghostel-serial-break-function to send a break"))
  (funcall ghostel-serial-break-function ghostel-serial--process))

(provide 'ghostel-serial)
;;; ghostel-serial.el ends here
