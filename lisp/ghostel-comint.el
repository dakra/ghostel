;;; ghostel-comint.el --- libghostty VT parser as a comint preoutput filter -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Replace comint's built-in ANSI handling with a full libghostty-vt parser.
;; Activates as a per-buffer minor mode (`ghostel-comint-mode'),
;; or globally for every comint buffer via `ghostel-comint-global-mode'.
;;
;; What this gets you over the stock `ansi-color-process-output':
;;
;;   - Full SGR semantics from libghostty: 8 / 16 / 256 / truecolor,
;;     italic, faint, strikethrough, overline, inverse, invisible,
;;     curly / dotted / dashed / double underline (including the
;;     colon-separator forms `\e[4:3m'), underline color (`\e[58…m').
;;   - OSC 8 hyperlinks render as clickable links (mouse-2 opens via
;;     `browse-url').
;;   - OSC 7 (working-directory report) updates `default-directory'
;;     without needing `shell-dirtrack-mode' or shell integration.
;;   - DCS / APC / SS3 sequences are consumed (they would otherwise
;;     leak bytes into the buffer).
;;
;; What it does NOT do:
;;
;;   - Render cursor-positioning sequences.  Comint is a line-append
;;     buffer; CSI cursor / erase / mode-set sequences are silently
;;     dropped.  Programs like `htop' or `less' won't work — those
;;     need a real ghostel terminal (M-x ghostel).
;;   - Replace `comint-carriage-motion'.  CR / BS / TAB are passed
;;     through to comint, which handles them via its own filter.
;;
;; Usage:
;;
;;   (add-hook 'shell-mode-hook #'ghostel-comint-mode)
;;
;;   Or, to enable it for every comint-derived mode:
;;
;;   (ghostel-comint-global-mode 1)

;;; Code:

(require 'comint)
(require 'ghostel)

(declare-function ghostel--comint-make-state "ghostel-module")
(declare-function ghostel--comint-filter "ghostel-module")
(declare-function ghostel--comint-set-palette "ghostel-module")


;;; Internal state

(defvar-local ghostel-comint--state nil
  "Opaque ghostel comint-filter state (a user-ptr from the native module).
Created on `ghostel-comint-mode' activation, freed by the Emacs GC
when the buffer dies.  Holds the cumulative SGR state so colour
sequences split across multiple PTY chunks are reassembled correctly.")


;;; Palette plumbing

(defun ghostel-comint--apply-palette (state)
  "Push ghostel's current face palette into STATE.
Mirrors `ghostel--apply-palette' (which targets a Terminal) but writes
to a comint stream-filter state instead, so SGR colours rendered through
the filter match the colours a regular ghostel terminal would show."
  (when (and state ghostel-color-palette)
    (let ((colors
           (mapconcat (lambda (face)
                        (ghostel--face-hex-color face :foreground))
                      ghostel-color-palette
                      "")))
      (ghostel--comint-set-palette state colors))))


;;; OSC 7 dirtrack callback

(defun ghostel-comint--update-dir (uri)
  "Update `default-directory' from an OSC 7 URI emitted by the VT stream.
Called from the native filter on every OSC 7 / OSC 9;9 report.
Forwards to `ghostel--update-directory' so the same TRAMP / hostname
resolution logic ghostel-mode uses applies here too."
  (when (and (stringp uri) (not (string-empty-p uri)))
    (ghostel--update-directory uri)))


;;; The filter

(defun ghostel-comint--face-to-font-lock-face (string)
  "Rename every `face' text property in STRING to `font-lock-face'.
Returns STRING.

When `font-lock-mode' is enabled in a buffer, font-lock's fontify pass
strips and overwrites the `face' property — so a comint preoutput filter
that sets `face' will see its colours wiped on the next redisplay (this
is what bites users when bat-style truecolor output goes grey in
`shell-mode').  `font-lock-face' is not managed by font-lock, so it
survives.  Emacs aliases `font-lock-face' to `face' (via
`char-property-alias-alist') as long as `font-lock-mode' is on, so the
text still displays with the requested face.

xterm-color and ansi-color do the same swap.  This is only a partial
shield: where font-lock's own keywords match (e.g. shell-mode treats
`[+-]flag' patterns as comments), `face' wins and our colour is lost.
For full coverage disable `font-lock-mode' in the comint buffer."
  (let ((pos 0)
        (len (length string)))
    (while (< pos len)
      (let ((next (next-single-property-change pos 'face string len))
            (face (get-text-property pos 'face string)))
        (when face
          (remove-text-properties pos next '(face nil) string)
          (put-text-property pos next 'font-lock-face face string))
        (setq pos next))))
  string)

(defun ghostel-comint-filter (string)
  "Preoutput filter: hand STRING to ghostel's VT parser, return propertized text.
Suitable for `comint-preoutput-filter-functions'.

When the host buffer has `font-lock-mode' enabled, protects the
terminal colours from font-lock's unfontify pass."
  (unless ghostel-comint--state
    (ghostel--load-module)
    (setq ghostel-comint--state (ghostel--comint-make-state))
    (ghostel-comint--apply-palette ghostel-comint--state))
  (let ((result (ghostel--comint-filter ghostel-comint--state string)))
    (if font-lock-mode
        (ghostel-comint--face-to-font-lock-face result)
      result)))


;;; Minor modes

;;;###autoload
(define-minor-mode ghostel-comint-mode
  "Replace comint's ANSI handling with ghostel's libghostty-vt parser.

Adds `ghostel-comint-filter' as the first entry of the buffer-local
`comint-preoutput-filter-functions', and removes
`ansi-color-process-output' from `comint-output-filter-functions' so the
two don't double-process bytes.


For performance, xterm-color recommends disabling font-locking in
shell-mode buffers — the same advice applies here.  Add this to your
`shell-mode-hook' if `compilation-shell-minor-mode' isn't required:

  (font-lock-mode -1)
  (setq-local font-lock-function (lambda (_) nil))"
  :lighter " G-comint"
  :group 'ghostel
  (cond
   (ghostel-comint-mode
    (remove-hook 'comint-output-filter-functions
                 #'ansi-color-process-output t)
    (add-hook 'comint-preoutput-filter-functions
              #'ghostel-comint-filter nil t)
    ;; Show the OSC 8 hyperlink URI at point in eldoc.
    (add-hook 'eldoc-documentation-functions #'ghostel--eldoc-link nil t)
    ;; Enable eldoc explicitly (when the user has `global-eldoc-mode' activated)
    ;; because in pre-existing buffers, e.g. when `ghostel-comint-global-mode'
    ;; sweeps `buffer-list', the global mode's auto-enable has already run.
    (when (bound-and-true-p global-eldoc-mode)
      (eldoc-mode 1)))
   (t
    (remove-hook 'comint-preoutput-filter-functions
                 #'ghostel-comint-filter t)
    (remove-hook 'eldoc-documentation-functions #'ghostel--eldoc-link t)
    ;; Don't re-add ansi-color-process-output — the user may have
    ;; deliberately disabled it for other reasons.  Leave their config
    ;; as-is and let them re-add it via `shell-mode-hook' if needed.
    (setq ghostel-comint--state nil))))

;;;###autoload
(define-minor-mode ghostel-comint-global-mode
  "Enable `ghostel-comint-mode' in every comint-derived buffer.

Adds `ghostel-comint-mode' to `comint-mode-hook' and turns it on in
all existing comint buffers."
  :global t
  :group 'ghostel
  (cond
   (ghostel-comint-global-mode
    (add-hook 'comint-mode-hook #'ghostel-comint-mode)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (derived-mode-p 'comint-mode)
                   (not ghostel-comint-mode))
          (ghostel-comint-mode 1)))))
   (t
    (remove-hook 'comint-mode-hook #'ghostel-comint-mode)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when ghostel-comint-mode
          (ghostel-comint-mode -1)))))))


(provide 'ghostel-comint)

;;; ghostel-comint.el ends here
