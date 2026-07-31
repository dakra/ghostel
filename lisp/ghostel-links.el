;;; ghostel-links.el --- Hyperlinks and link detection for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Everything that turns terminal output into navigable links:
;;
;; - `ghostel-link-map', opening links (OSC 8, `fileref:', URLs), and
;;   hyperlink navigation (`ghostel-next-hyperlink' and friends).
;; - Plain-text URL and file:line detection over logical lines: rows the
;;   terminal soft-wrapped are joined before matching, and every row of a
;;   match carries the whole target.
;; - thing-at-point providers, a `file-name-at-point-functions' member,
;;   and `ghostel-find-file-at-point', so `thing-at-point', embark,
;;   the find-file `M-n' default, and ffap-style commands see whole
;;   targets across soft-wrapped rows.
;;
;; `ghostel.el' requires this file eagerly (the renderer attaches
;; `ghostel-link-map' to OSC 8 spans as it renders) and calls
;; `ghostel-links-setup' from its mode setup.  Core state this code
;; reads lives in `ghostel.el'; this file only forward-declares it, so
;; the require introduces no cycle.

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'seq)
(require 'text-property-search)
(require 'thingatpt)

(declare-function ghostel--enter-readonly-input-mode "ghostel")
(defvar ghostel--input-mode)
(defvar ghostel--cursor-char-pos)


;;; Options

(defcustom ghostel-enable-url-detection t
  "Automatically detect and linkify URLs in terminal output.
When non-nil, plain-text URLs (http:// and https://) are made
clickable even if the program did not use OSC 8 hyperlink escapes."
  :type 'boolean
  :group 'ghostel)

(defcustom ghostel-enable-file-detection t
  "Automatically detect and linkify file:line references in terminal output.
When non-nil, patterns like /path/to/file.el:42 are made clickable,
opening the file at the given line in another window.  Automatically
disabled when `default-directory' is a TRAMP path, because each
candidate would require a remote `file-exists-p' round-trip per
redraw."
  :type 'boolean
  :group 'ghostel)

(defcustom ghostel-plain-link-detection-delay 0.1
  "Delay in seconds before redraw-triggered plain-text link detection runs.
Redraws queue URL/file detection through
`ghostel--schedule-link-detection' so multiple updates can be
coalesced into a single scan.  Set to 0 to scan immediately after each
redraw.  Native OSC-8 hyperlinks remain applied during redraw."
  :type 'number
  :group 'ghostel)

(defcustom ghostel-file-detection-path-regex
  "[~[:alnum:]_.-]*/[^] \t\n\r:\"<>(){}[`']+"
  "Regex matching the PATH portion of a file:line[:col] reference.
This is the middle of the full detection pattern; ghostel wraps it
with a fixed leading path-boundary anchor (line start or any
non-path character) and a fixed `:LINE[:COL]' tail, so any match
is guaranteed to end in `:DIGITS'.

The matched path is resolved against `default-directory'; linkification
only applies when that file exists.  The default matches absolute
paths, explicit `./' paths, tilde-prefixed paths like `~/file.el',
and bare relative paths containing at least one `/' (e.g. compiler
output like `src/main.rs').  Paths embedded in punctuation like
`(/home/user/index.js:17:5)' are supported via the fixed anchor.

Performance: each match triggers a filesystem check on every redraw.
Broadening this pattern (for example to match bare `file.go' without
a `/') will cause `file-exists-p' to be called for every matching
token, which can be expensive on slow or network filesystems (NFS,
FUSE).  The default uses non-backtracking character classes so the
per-redraw scan stays cheap."
  :type 'regexp
  :group 'ghostel)

(defconst ghostel--file-detection-leading-anchor
  "\\(?:^\\|[^[:alnum:]_./~-]\\)"
  "Fixed anchor placed before `ghostel-file-detection-path-regex'.")

(defconst ghostel--file-detection-tail
  "\\(?::[0-9]+\\(?::[0-9]+\\)?\\)?"
  "Fixed optional `:LINE[:COL]' tail.
When absent, the match is linkified as a bare file/directory
reference opened at its start.")

(defconst ghostel--url-regex
  "https?://[^ \t\n\r\"<>]*[^ \t\n\r\"<>.,;:!?)>]"
  "Regex matching a plain-text http(s) URL.")

(defconst ghostel--fileref-regex
  "\\`fileref:\\(.*?\\)\\(?::\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\)?\\'"
  "Match a `fileref:' URI into path (group 1), line (2), and column (3).")


;;; Internal state

(defvar-local ghostel--link-id-counter 0
  "Source of `ghostel-link-id' values for detected multi-row links.
Counts up so an id stays unique after scrollback eviction shifts
buffer positions.")

(defvar-local ghostel--plain-link-detection-timer nil
  "Timer for delayed redraw-triggered plain-text link detection.")

(defvar-local ghostel--plain-link-detection-begin nil
  "Queued start bound for redraw-triggered plain-text link detection.
A marker: scrollback eviction deletes from the buffer start between
the queue and the scan, which would leave a plain position pointing
at unrelated text.")

(defvar-local ghostel--plain-link-detection-end nil
  "Queued end bound for redraw-triggered plain-text link detection.
A marker, for the reason given at `ghostel--plain-link-detection-begin'.")

(defconst ghostel--link-detection-chunk 100000
  "Characters `ghostel--run-queued-plain-link-detection' scans per tick.
A single redraw can materialize megabytes of output at once; scanning
all of it in one pass would block Emacs for as long as that takes.
The drain takes this much from the newest end of the queued range and
re-arms for the rest.")


;;; Hyperlinks (OSC 8)

(defvar-keymap ghostel-link-map
  :doc "Keymap for clickable hyperlinks in ghostel buffers.
Mouse clicks on a linkified cell open the link in any input mode.

RET not bound here so a misdetected link inside a typed command in
semi-char/char mode never hijacks the key away from the PTY."
  "<mouse-1>" #'ghostel-open-link-at-click
  "<mouse-2>" #'ghostel-open-link-at-click)

(defun ghostel--uri-at-pos (pos)
  "Return the URI string stored in POS's `help-echo', or nil."
  (let ((uri (get-text-property pos 'help-echo)))
    (and (stringp uri) uri)))

(defun ghostel--eldoc-link (callback &rest _)
  "Report the hyperlink URI at point via eldoc CALLBACK.
For `eldoc-documentation-functions'."
  (when-let* (((eq (get-text-property (point) 'keymap) ghostel-link-map))
              (uri (ghostel--uri-at-pos (point)))
              (link (if (string-prefix-p "fileref:" uri)
                        (substring uri (length "fileref:"))
                      uri)))
    (funcall callback link :thing "Link" :face 'link)))

(defun ghostel--open-link (url)
  "Open URL, dispatching by scheme.
file:// URIs open in Emacs; http(s) and other schemes use `browse-url'.
fileref: URIs (from auto-detected file[:line[:col]] patterns) open
the file at the given position in another window.  A fileref without
a line suffix opens at the start of the file or directory."
  (when (and url (stringp url))
    (cond
     ((string-match ghostel--fileref-regex url)
      (let ((file (match-string 1 url))
            (line (and (match-string 2 url)
                       (string-to-number (match-string 2 url))))
            (col (and (match-string 3 url)
                      (string-to-number (match-string 3 url)))))
        (when (file-exists-p file)
          (find-file-other-window file)
          (when line
            (goto-char (point-min))
            (forward-line (1- (max 1 line)))
            (when col (move-to-column (max 0 (1- col))))))))
     ((string-match "\\`file://\\(?:localhost\\)?\\(/.*\\)" url)
      (find-file (url-unhex-string (match-string 1 url))))
     ((string-match-p "\\`[a-z]+://" url)
      (browse-url url)))))

(defun ghostel-open-link-at-click (event)
  "Open the hyperlink at the mouse click EVENT position."
  (interactive "e")
  (ghostel--open-link (ghostel--uri-at-pos (posn-point (event-start event)))))

(defun ghostel-open-link-at-point ()
  "Open the hyperlink at point."
  (interactive)
  (ghostel--open-link (ghostel--uri-at-pos (point))))

(defun ghostel--find-link-1 (direction from)
  "Return the start of the next/previous hyperlink from FROM, or nil.
DIRECTION is `next' or `previous'.

Treats runs sharing a `ghostel-link-id' as one logical link: if FROM is
inside such a run, other runs with that id are skipped; for `previous',
the result is walked back to the earliest same-id run so a wrapped URL
lands at its start, not its last chunk."
  (let ((search-fn (if (eq direction 'next)
                       #'text-property-search-forward
                     #'text-property-search-backward))
        (skip-id (get-text-property from 'ghostel-link-id)))
    (save-excursion
      (goto-char from)
      (catch 'found
        (while-let ((match (funcall search-fn 'help-echo nil
                                    (lambda (_ v) v) t)))
          (let* ((pos (prop-match-beginning match))
                 (id (get-text-property pos 'ghostel-link-id)))
            (unless (and skip-id (equal skip-id id))
              (when (and (eq direction 'previous) id)
                (catch 'walked
                  (while-let ((earlier (text-property-search-backward
                                        'help-echo nil
                                        (lambda (_ v) v) t)))
                    (let ((earlier-pos (prop-match-beginning earlier)))
                      (if (equal id (get-text-property
                                     earlier-pos 'ghostel-link-id))
                          (setq pos earlier-pos)
                        (throw 'walked nil))))))
              (throw 'found pos))))))))

(defun ghostel--find-next-link (from)
  "Return start position of the first hyperlink after FROM, or nil.
A hyperlink is any region with a non-nil `help-echo' property.
Covers OSC 8 links, auto-detected URLs, and `fileref:' references."
  (ghostel--find-link-1 'next from))

(defun ghostel--find-previous-link (from)
  "Return start position of the first hyperlink before FROM, or nil."
  (ghostel--find-link-1 'previous from))

(defun ghostel--goto-hyperlink (direction)
  "Jump to the next/previous hyperlink.  DIRECTION is `next' or `previous'.
Wraps around when no link is found in the requested direction.
Signals `user-error' if the buffer has no hyperlinks at all."
  (let* ((search (if (eq direction 'next)
                     #'ghostel--find-next-link
                   #'ghostel--find-previous-link))
         (target (funcall search (point))))
    (unless target
      (let ((wrap-from (if (eq direction 'next) (point-min) (point-max))))
        (setq target (funcall search wrap-from))
        (when target (message "Wrapped"))))
    (if target
        (goto-char target)
      (user-error "No hyperlinks in buffer"))))

(defun ghostel-next-hyperlink (&optional n)
  "Enter `ghostel-readonly-default-mode' and move to the Nth next hyperlink.
A hyperlink is any OSC 8 link, auto-detected URL, or `file:line'
reference in the buffer.  Wraps to `point-min' when no link is found
after point.  Press RET to follow the link at point."
  (interactive "p")
  (unless (memq ghostel--input-mode '(copy emacs))
    (ghostel--enter-readonly-input-mode 'default))
  (dotimes (_ (or n 1))
    (ghostel--goto-hyperlink 'next)))

(defun ghostel-previous-hyperlink (&optional n)
  "Enter `ghostel-readonly-default-mode' and move to the Nth previous hyperlink.
Wraps to `point-max' when no link is found before point."
  (interactive "p")
  (unless (memq ghostel--input-mode '(copy emacs))
    (ghostel--enter-readonly-input-mode 'default))
  (dotimes (_ (or n 1))
    (ghostel--goto-hyperlink 'previous)))

(eldoc-add-command #'ghostel-next-hyperlink #'ghostel-previous-hyperlink)

(defvar-keymap ghostel-hyperlink-repeat-map
  :doc "Repeat map for `ghostel-next-hyperlink' / `ghostel-previous-hyperlink'.
Active after either command when `repeat-mode' is enabled, so a
bare \\`n'/\\`p' or \\`C-n'/\\`C-p' keeps navigating."
  :repeat t
  "n"   #'ghostel-next-hyperlink
  "p"   #'ghostel-previous-hyperlink
  "C-n" #'ghostel-next-hyperlink
  "C-p" #'ghostel-previous-hyperlink)

(defconst ghostel--soft-wrap-row-limit 50
  "How many rows `ghostel--detect-urls' joins into one logical line.
Output like a minified JSON blob is a single line megabytes long;
joining all of it would cost more than any link is worth, and would hand the
patterns a match candidate long enough to overflow the regexp matcher.
Past the limit a row break is kept and joining starts over,
so a link straddling that break resolves to one side of it.")

(defun ghostel--soft-wrap-line-beginning (pos limit)
  "Return the start of POS's logical line, crossing soft-wrap newlines.
A line the terminal split to fit its width continues on the next
buffer line; the newline between them carries `ghostel-wrap'.
LIMIT caps how many rows the search walks back."
  (save-excursion
    (goto-char pos)
    (beginning-of-line)
    (let ((rows 0))
      (while (and (< rows limit)
                  (> (point) (point-min))
                  (get-text-property (1- (point)) 'ghostel-wrap))
        (forward-line -1)
        (setq rows (1+ rows))))
    (point)))

(defun ghostel--soft-wrap-line-end (pos limit)
  "Return the end of POS's logical line, crossing soft-wrap newlines.
LIMIT caps how many rows the search walks forward."
  (save-excursion
    (goto-char pos)
    (end-of-line)
    (let ((rows 0))
      (while (and (< rows limit)
                  (get-text-property (point) 'ghostel-wrap))
        (forward-line 1)
        (end-of-line)
        (setq rows (1+ rows))))
    (point)))

(defun ghostel--wrap-joined-region (begin end limit)
  "Return (STRING . CHUNKS) for BEGIN..END with soft-wrap newlines removed.
STRING is the region's text as the terminal program wrote it, so a
value split across rows matches as one token.  CHUNKS maps it back:
a vector of (STRING-OFFSET . BUFFER-POS) pairs, one per row, ascending.

LIMIT bounds how many rows may be joined into one line, which keeps a
megabyte-long line of output from becoming one unbroken token for the
regexps to chew through.  The count is per logical line: a hard
newline in the region ends one line and starts the next from zero."
  (let ((chunks nil)
        (parts nil)
        (offset 0)
        (rows 0)
        (pos begin))
    (while (< pos end)
      (let* ((wrap (text-property-not-all pos end 'ghostel-wrap nil))
             (wrapped (and wrap (eq (char-after wrap) ?\n)))
             (join (and wrapped (< rows limit)))
             (piece (buffer-substring-no-properties
                     pos (cond (join wrap)
                               (wrapped (1+ wrap))
                               (t end)))))
        (push (cons offset pos) chunks)
        (push piece parts)
        ;; A hard newline inside PIECE ended the logical line the count was
        ;; for; the row being joined now is the first of a new one.
        (setq rows (cond ((not join) 0)
                         ((string-search "\n" piece) 1)
                         (t (1+ rows)))
              offset (+ offset (length piece))
              pos (if wrapped (1+ wrap) end))))
    (cons (string-join (nreverse parts))
          (vconcat (nreverse chunks)))))

(defun ghostel--wrap-offset-to-pos (offset chunks)
  "Return the buffer position for STRING OFFSET given CHUNKS.
CHUNKS is the map returned by `ghostel--wrap-joined-region'.
Binary search, so a region with thousands of rows stays cheap to map."
  (unless (zerop (length chunks))
    (let ((low 0)
          (high (1- (length chunks))))
      (while (< low high)
        (let ((mid (/ (+ low high 1) 2)))
          (if (<= (car (aref chunks mid)) offset)
              (setq low mid)
            (setq high (1- mid)))))
      (let ((chunk (aref chunks low)))
        (+ (cdr chunk) (- offset (car chunk)))))))

(defun ghostel--wrap-fragments (beg end)
  "Return the buffer ranges covering BEG..END, split at soft-wrap newlines.
Each element is a (START . STOP) cons; the wrap newlines themselves
are left out so link properties never cover a row break."
  (let ((fragments nil)
        (pos beg))
    (while (< pos end)
      (let ((wrap (text-property-not-all pos end 'ghostel-wrap nil)))
        (if (and wrap (eq (char-after wrap) ?\n))
            (progn
              (when (< pos wrap) (push (cons pos wrap) fragments))
              (setq pos (1+ wrap)))
          (push (cons pos end) fragments)
          (setq pos end))))
    (nreverse fragments)))

(defun ghostel--url-link-p (pos)
  "Non-nil when POS carries a URL link this scan attached.
The file pattern also matches the `//host/path' half of a URL, so the file
pass has to recognise a URL link to leave it alone, including one an earlier
scan attached, when URL detection has since been switched off."
  (let ((echo (get-text-property pos 'help-echo)))
    (and (ghostel--detected-link-p pos)
         (stringp echo)
         (not (string-prefix-p "fileref:" echo)))))

(defun ghostel--range-overlaps-p (beg end ranges)
  "Non-nil when BEG..END overlaps any (START . STOP) cons in RANGES."
  (and (seq-find (lambda (range)
                   (and (< beg (cdr range)) (> end (car range))))
                 ranges)
       t))

(defun ghostel--linkify (fragments uri raw)
  "Mark FRAGMENTS as a hyperlink to URI.
FRAGMENTS is the buffer ranges of one match, as `ghostel--wrap-fragments'
returns them.  RAW is the text the match was made of, kept so a later
scan can tell this link from one whose text has since changed.
A range broken by soft wraps is marked one row at a time, with a
shared `ghostel-link-id' so link navigation treats the rows as one
link.  The id is a cons, which never `equal's an OSC 8 id (those
are strings or integers)."
  (let ((props (list 'help-echo uri
                     'mouse-face 'highlight
                     'keymap ghostel-link-map
                     'ghostel-link-text raw
                     'ghostel-link-id (cons 'ghostel-detected
                                            (cl-incf ghostel--link-id-counter)))))
    (pcase-dolist (`(,start . ,stop) fragments)
      (add-text-properties start stop props))))

(defun ghostel--detected-link-p (pos)
  "Non-nil when the link at POS is one this scan attached earlier."
  (eq (car-safe (get-text-property pos 'ghostel-link-id)) 'ghostel-detected))

(defun ghostel--foreign-link-p (beg end)
  "Non-nil when BEG..END overlaps a link this scan did not attach.
An OSC 8 span keeps its own target even where a path pattern also
matches, so the whole range is checked, not just its first cell."
  (let ((pos beg)
        (foreign nil))
    (while (and (not foreign) (< pos end))
      (let ((echo (get-text-property pos 'help-echo)))
        (when (and echo (not (ghostel--detected-link-p pos)))
          (setq foreign t))
        (setq pos (next-single-property-change pos 'help-echo nil end))))
    foreign))

(defun ghostel--skip-match-p (fragments raw active-bounds)
  "Return non-nil if the link over FRAGMENTS should not be applied.
RAW is the text this match is made of.  Leaves alone what another
source owns (an OSC 8 span), the prompt, the line the cursor is on,
and a match whose link already covers this same text.  A match whose
text changed, or that is only partly marked, is re-applied: the
renderer repaints the rows that changed, so the rows of a wrapped
link that did not change would otherwise keep pointing at text they
no longer hold.  The test is on the text rather than on the resolved
target, so a `cd' — which moves `default-directory' under output that
never changed — leaves existing links pointing where they did.
ACTIVE-BOUNDS is a (BOL . EOL) cons covering the cursor's line."
  (let ((skip nil)
        (current t))
    (pcase-dolist (`(,start . ,stop) fragments)
      (when (or (get-text-property start 'ghostel-prompt)
                (and active-bounds
                     (>= start (car active-bounds))
                     (<= start (cdr active-bounds)))
                (ghostel--foreign-link-p start stop))
        (setq skip t))
      (unless (and (ghostel--detected-link-p start)
                   (equal raw (get-text-property start 'ghostel-link-text)))
        (setq current nil)))
    (or skip current)))

(defun ghostel--drop-stranded-links (begin end matched urls files)
  "Remove this scan's links in BEGIN..END that no match covers.
MATCHED is the list of (START . STOP) ranges the scan matched, whatever
it then did with them.  A row repainted on its own can leave the other
rows of a wrapped link behind, pointing at text that is gone.
URLS and FILES say which patterns ran: a link of a kind that was not
scanned for is unexamined, not stranded."
  (let ((pos begin))
    (while (setq pos (text-property-not-all pos end 'ghostel-link-id nil))
      (let* ((stop (next-single-property-change pos 'ghostel-link-id nil end))
             (echo (get-text-property pos 'help-echo))
             (scanned (if (and (stringp echo)
                               (string-prefix-p "fileref:" echo))
                          files
                        urls)))
        (when (and scanned
                   (ghostel--detected-link-p pos)
                   (not (ghostel--range-overlaps-p pos stop matched)))
          (remove-text-properties pos stop
                                  '(help-echo nil mouse-face nil keymap nil
                                              ghostel-link-id nil
                                              ghostel-link-text nil)))
        (setq pos stop)))))

(defun ghostel--detect-urls (&optional begin end)
  "Scan a buffer region for plain-text URLs and file:line references.
BEGIN and END default to `point-min' and `point-max' respectively.
Skips regions that already have a `help-echo' property (e.g. from OSC 8)
and the user's active input on the current prompt line.
Bounding the scan keeps streaming output from re-scanning the entire
materialized scrollback on every redraw.
Binds `inhibit-read-only' and suppresses modification hooks so the scan
can attach text properties when called from the deferred-detection timer
outside the redraw scope.

Returns the (BEGIN . END) actually covered, which the caller-supplied
bounds widened to whole logical lines."
  (let* (;; Whole logical lines: a value the terminal split across rows is
         ;; only recognisable once the rows are joined, and starting mid-line
         ;; would let the `^' anchor below match where there is no line start.
         (begin (ghostel--soft-wrap-line-beginning
                 (or begin (point-min)) ghostel--soft-wrap-row-limit))
         (end (ghostel--soft-wrap-line-end
               (or end (point-max)) ghostel--soft-wrap-row-limit))
         (inhibit-read-only t)
         (inhibit-modification-hooks t)
         ;; `ghostel--cursor-char-pos' is the live terminal cursor after a redraw;
         ;; its line is the prompt the user is currently editing.  Capture as
         ;; buffer-position bounds so the per-match skip check is O(1).
         (active-pos (or ghostel--cursor-char-pos (point)))
         (active-bounds (cons (ghostel--soft-wrap-line-beginning
                               active-pos ghostel--soft-wrap-row-limit)
                              (ghostel--soft-wrap-line-end
                               active-pos ghostel--soft-wrap-row-limit)))
         (joined (ghostel--wrap-joined-region
                  begin end ghostel--soft-wrap-row-limit))
         (text (car joined))
         (chunks (cdr joined))
         ;; Disable file detection over TRAMP
         (files (and ghostel-enable-file-detection
                     (not (file-remote-p default-directory))))
         ;; Every range a pattern matched, whether or not it was linkified.
         ;; What no pattern covers any more is a leftover to clear.
         (matched nil)
         (url-ranges nil))
    ;; Pass 1: http(s) URLs
    (when ghostel-enable-url-detection
      (let ((offset 0))
        (while (string-match ghostel--url-regex text offset)
          (setq offset (match-end 0))
          (let* ((beg (ghostel--wrap-offset-to-pos (match-beginning 0) chunks))
                 (mend (ghostel--wrap-offset-to-pos (match-end 0) chunks))
                 (url (match-string-no-properties 0 text))
                 (fragments (ghostel--wrap-fragments beg mend))
                 (range (cons beg mend)))
            (push range url-ranges)
            (push range matched)
            (unless (ghostel--skip-match-p fragments url active-bounds)
              (ghostel--linkify fragments url url))))))
    ;; Pass 2: file:line[:col] references (e.g. "./foo.el:42",
    ;; "/tmp/bar.rs:10", or bare relative paths like "src/main.rs:42:4"
    ;; from compiler output).  The full regex is assembled from fixed anchor
    ;; + user-tunable path + fixed `:LINE[:COL]' tail so group 1 (path) and
    ;; group 2 (line[:col]) are always present — no nil-guarding needed in
    ;; the hot loop.  A small hash memoizes `file-exists-p' so repeated paths
    ;; in a redraw (common in multi-line compiler diagnostics) don't re-stat.
    (when files
      (let ((full-regex (concat ghostel--file-detection-leading-anchor
                                "\\(" ghostel-file-detection-path-regex "\\)"
                                "\\(" ghostel--file-detection-tail "\\)"))
            (seen (make-hash-table :test 'equal))
            (offset 0))
        (while (string-match full-regex text offset)
          (setq offset (match-end 2))
          (let* ((beg (ghostel--wrap-offset-to-pos (match-beginning 1) chunks))
                 (mend (ghostel--wrap-offset-to-pos (match-end 2) chunks))
                 (path (match-string-no-properties 1 text))
                 (loc (match-string-no-properties 2 text))
                 (raw (concat path loc))
                 (fragments (ghostel--wrap-fragments beg mend)))
            ;; A URL owns its whole span: its `//host/path' half also looks
            ;; like a path, and re-marking it would replace the link with a
            ;; local file — and stat that file on every scan.
            (unless (or (ghostel--range-overlaps-p beg mend url-ranges)
                        ;; With the URL pass switched off nothing recorded a
                        ;; range, so fall back to the link already there.
                        ;; When it did run its ranges are the whole truth,
                        ;; and a leftover URL link is about to be cleared.
                        (and (not ghostel-enable-url-detection)
                             (ghostel--url-link-p beg)))
              (if (ghostel--skip-match-p fragments raw active-bounds)
                  ;; Whatever is there stays; it must not count as stranded.
                  (push (cons beg mend) matched)
                (let* ((abs-path (expand-file-name path))
                       (cached (gethash abs-path seen 'unset))
                       (exists (if (eq cached 'unset)
                                   (puthash abs-path (file-exists-p abs-path) seen)
                                 cached)))
                  ;; A candidate that names no file leaves the range
                  ;; uncovered, so a link left over from the text it used
                  ;; to hold is cleared.
                  (when exists
                    (push (cons beg mend) matched)
                    (ghostel--linkify
                     fragments
                     (if (> (length loc) 0)
                         (concat "fileref:" abs-path ":" (substring loc 1))
                       (concat "fileref:" abs-path))
                     raw)))))))))
    (ghostel--drop-stranded-links
     begin end matched ghostel-enable-url-detection files)
    (cons begin end)))


;;; thing-at-point and ffap across soft-wrapped rows

(defun ghostel--wrap-pos-to-offset (pos chunks)
  "Return the string offset for buffer POS given CHUNKS.
Inverse of `ghostel--wrap-offset-to-pos'.  A POS on a wrap newline
maps to the offset of the next row's first character, since the
newline itself is not part of the joined string."
  (let ((i (1- (length chunks))))
    (while (and (> i 0) (> (cdr (aref chunks i)) pos))
      (setq i (1- i)))
    (let ((chunk (aref chunks i)))
      (+ (car chunk) (- pos (cdr chunk))))))

(defun ghostel--logical-line-at-point ()
  "Return (STRING . CHUNKS) for point's logical line, or nil if unwrapped.
STRING is the line's text with soft-wrap newlines removed and CHUNKS
maps its offsets back to buffer positions, as returned by
`ghostel--wrap-joined-region'.  Nil when no soft wrap is involved, so
callers can fall back to ordinary single-line behavior."
  (let ((bol (line-beginning-position))
        (eol (line-end-position)))
    (when (or (get-text-property eol 'ghostel-wrap)
              (and (> bol (point-min))
                   (get-text-property (1- bol) 'ghostel-wrap)))
      (let ((begin (ghostel--soft-wrap-line-beginning
                    (point) ghostel--soft-wrap-row-limit))
            (end (ghostel--soft-wrap-line-end
                  (point) ghostel--soft-wrap-row-limit)))
        (ghostel--wrap-joined-region begin end ghostel--soft-wrap-row-limit)))))

(defun ghostel--joined-token-at-point (chars)
  "Return the run of CHARS around point on the joined logical line, or nil.
CHARS is a `skip-chars' style set.  Nil when point's line has no soft
wrap or no such run touches point."
  (when-let* ((joined (ghostel--logical-line-at-point)))
    (let* ((text (car joined))
           (class (concat "[" chars "]"))
           (len (length text))
           (start (min (ghostel--wrap-pos-to-offset (point) (cdr joined)) len))
           (end start))
      (while (and (> start 0)
                  (string-match-p class (char-to-string (aref text (1- start)))))
        (setq start (1- start)))
      (while (and (< end len)
                  (string-match-p class (char-to-string (aref text end))))
        (setq end (1+ end)))
      (and (< start end) (substring text start end)))))

(defun ghostel--link-uri-at-point ()
  "Return the URI of the ghostel link at point, or nil.
The `keymap' check tells ghostel's own links from a foreign
`help-echo' some other source put in the buffer."
  (and (eq (get-text-property (point) 'keymap) ghostel-link-map)
       (ghostel--uri-at-pos (point))))

(defun ghostel--fileref-file-at-point ()
  "Return the absolute file name of the detected file link at point.
Nil when point is not on a `fileref:' link.  The name was resolved
against `default-directory' and checked for existence when the link
was detected.  Suitable for `file-name-at-point-functions'."
  (let ((uri (ghostel--link-uri-at-point)))
    (and uri
         (string-match ghostel--fileref-regex uri)
         (match-string 1 uri))))

(defun ghostel--thing-at-point-filename ()
  "Return the file name at point, crossing soft-wrapped rows.
For `thing-at-point-provider-alist'.  On a detected file link the
name is the link's text without its `:LINE[:COL]' tail; elsewhere on
a wrapped line, the filename-character run around point."
  (let ((uri (ghostel--link-uri-at-point)))
    (if (and uri (string-prefix-p "fileref:" uri))
        (let ((raw (get-text-property (point) 'ghostel-link-text)))
          ;; OSC 8 spans have no link text; the detection regexes
          ;; guarantee a detected path holds no colon before the tail.
          (when raw
            (if (string-match "\\(?::[0-9]+\\)\\{1,2\\}\\'" raw)
                (substring raw 0 (match-beginning 0))
              raw)))
      (ghostel--joined-token-at-point thing-at-point-file-name-chars))))

(defun ghostel--thing-at-point-url ()
  "Return the URL at point, crossing soft-wrapped rows.
For `thing-at-point-provider-alist'.  On a URL link (OSC 8 or
detected) this is the link target; elsewhere on a wrapped line, the
URL match around point."
  (let ((uri (ghostel--link-uri-at-point)))
    (cond
     ((and uri (not (string-prefix-p "fileref:" uri))) uri)
     (uri nil)                          ; file link: not a URL
     (t (when-let* ((joined (ghostel--logical-line-at-point)))
          (let* ((text (car joined))
                 (off (ghostel--wrap-pos-to-offset (point) (cdr joined)))
                 (start 0)
                 (found nil))
            (while (and (not found)
                        (string-match ghostel--url-regex text start)
                        (<= (match-beginning 0) off))
              (if (<= off (match-end 0))
                  (setq found (match-string 0 text))
                (setq start (match-end 0))))
            found))))))

(defun ghostel--link-bounds (pos)
  "Return (BEG . END) covering every fragment of the link at POS, or nil.
Fragments of a soft-wrapped link share a `ghostel-link-id' but never
cover the wrap newline between them, so the span is extended across
single newlines whose neighbor continues the same link."
  (let* ((echo (get-text-property pos 'help-echo))
         (id (get-text-property pos 'ghostel-link-id))
         (same (lambda (p)
                 (and (equal echo (get-text-property p 'help-echo))
                      (equal id (get-text-property p 'ghostel-link-id)))))
         (beg pos)
         (end pos))
    (when (stringp echo)
      (while (cond ((and (> beg (point-min)) (funcall same (1- beg)))
                    (setq beg (1- beg)))
                   ((and id (> beg (1+ (point-min)))
                         (get-text-property (1- beg) 'ghostel-wrap)
                         (funcall same (- beg 2)))
                    (setq beg (- beg 2)))))
      (while (cond ((and (< end (point-max)) (funcall same end))
                    (setq end (1+ end)))
                   ((and id (< (1+ end) (point-max))
                         (get-text-property end 'ghostel-wrap)
                         (funcall same (1+ end)))
                    (setq end (1+ end)))))
      (cons beg end))))

(defun ghostel--bounds-of-file-link-at-point ()
  "Bounds of the detected file link at point, or nil.
For `bounds-of-thing-at-point-provider-alist'."
  (and (ghostel--fileref-file-at-point)
       (ghostel--link-bounds (point))))

(defun ghostel--bounds-of-url-link-at-point ()
  "Bounds of the URL link at point, or nil.
For `bounds-of-thing-at-point-provider-alist'."
  (let ((uri (ghostel--link-uri-at-point)))
    (and uri
         (not (string-prefix-p "fileref:" uri))
         (ghostel--link-bounds (point)))))

(declare-function find-file-at-point "ffap")

(defun ghostel-find-file-at-point ()
  "Open the hyperlink at point, or fall back to `find-file-at-point'.
A detected file reference opens at its recorded line and column even
when the path is split across soft-wrapped rows, which plain `ffap'
resolves to only the fragment before the row break.  A detected
file deleted since detection falls back as well."
  (interactive)
  (let* ((uri (ghostel--link-uri-at-point))
         (file (and uri
                    (string-match ghostel--fileref-regex uri)
                    (match-string 1 uri))))
    (if (and uri (or (not file) (file-exists-p file)))
        (ghostel--open-link uri)
      (require 'ffap)
      (call-interactively #'find-file-at-point))))

(defun ghostel--clear-plain-link-detection-bounds ()
  "Drop the queued detection bounds, releasing their markers."
  (when ghostel--plain-link-detection-begin
    (set-marker ghostel--plain-link-detection-begin nil))
  (when ghostel--plain-link-detection-end
    (set-marker ghostel--plain-link-detection-end nil))
  (setq ghostel--plain-link-detection-begin nil
        ghostel--plain-link-detection-end nil))

(defun ghostel--run-queued-plain-link-detection (buffer)
  "Scan one chunk of BUFFER's queued plain-text link detection range.
Takes `ghostel--link-detection-chunk' characters off the newest end of
the range, so what is on screen is linkified first and a backlog is
caught up on afterwards, then re-arms while anything is left."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ghostel--plain-link-detection-timer nil)
      (let ((begin ghostel--plain-link-detection-begin)
            (end ghostel--plain-link-detection-end))
        (when (and begin end (<= (marker-position begin) (marker-position end)))
          (let* ((stop (marker-position end))
                 (start (max (marker-position begin)
                             (- stop ghostel--link-detection-chunk)))
                 ;; The scan widens to whole logical lines; resume from where
                 ;; it really started rather than rescanning that line.
                 (next (car (ghostel--detect-urls start stop))))
            (if (<= next (marker-position begin))
                (ghostel--clear-plain-link-detection-bounds)
              (set-marker end next)
              (setq ghostel--plain-link-detection-timer
                    (run-with-timer ghostel-plain-link-detection-delay nil
                                    #'ghostel--run-queued-plain-link-detection
                                    buffer)))))))))

(defun ghostel--queue-plain-link-detection (begin end)
  "Coalesce redraw-triggered plain-text link detection for BEGIN..END."
  (when (and begin end (<= begin end))
    (if ghostel--plain-link-detection-begin
        (when (< begin ghostel--plain-link-detection-begin)
          (set-marker ghostel--plain-link-detection-begin begin))
      (setq ghostel--plain-link-detection-begin (copy-marker begin)))
    (if ghostel--plain-link-detection-end
        (when (> end ghostel--plain-link-detection-end)
          (set-marker ghostel--plain-link-detection-end end))
      (setq ghostel--plain-link-detection-end (copy-marker end)))
    (unless ghostel--plain-link-detection-timer
      (if (<= ghostel-plain-link-detection-delay 0)
          (ghostel--run-queued-plain-link-detection (current-buffer))
        (setq ghostel--plain-link-detection-timer
              (run-with-timer ghostel-plain-link-detection-delay nil
                              #'ghostel--run-queued-plain-link-detection
                              (current-buffer)))))))


;;; Mode setup

(defun ghostel-links-setup ()
  "Wire the link integrations into the current ghostel buffer."
  ;; Show the hyperlink URI at point in eldoc.
  (add-hook 'eldoc-documentation-functions #'ghostel--eldoc-link nil t)
  ;; Serve whole targets to thing-at-point (and through it embark,
  ;; `existing-filename', etc.) and to the find-file `M-n' default,
  ;; which otherwise see only the fragment of a soft-wrapped row.
  (setq-local thing-at-point-provider-alist
              (append '((filename . ghostel--thing-at-point-filename)
                        (existing-filename . ghostel--fileref-file-at-point)
                        (url . ghostel--thing-at-point-url))
                      thing-at-point-provider-alist))
  (when (boundp 'bounds-of-thing-at-point-provider-alist)
    (setq-local bounds-of-thing-at-point-provider-alist
                (append '((filename . ghostel--bounds-of-file-link-at-point)
                          (existing-filename . ghostel--bounds-of-file-link-at-point)
                          (url . ghostel--bounds-of-url-link-at-point))
                        bounds-of-thing-at-point-provider-alist)))
  (add-hook 'file-name-at-point-functions #'ghostel--fileref-file-at-point nil t))

(provide 'ghostel-links)
;;; ghostel-links.el ends here
