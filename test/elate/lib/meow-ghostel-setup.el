;;; meow-ghostel-setup.el --- Shared elate startup for the meow-ghostel matrix -*- lexical-binding: t; -*-

;; Loaded from a scenario's session.eval:
;;   (load ".../test/elate/lib/meow-ghostel-setup.el")
;; then the scenario (or the ELATE_GHOSTEL_SHELL env var) picks `ghostel-shell'.
;;
;; Sets up meow + ghostel + meow-ghostel from THIS checkout (self-locating, so
;; the scenarios keep working if the repo moves).  `meow' is resolved from the
;; usual local checkout or the Makefile's cache clone ($XDG_CACHE_HOME/meow).
;; The keybindings are meow's documented qwerty suggestion
;; (KEYBINDING_QWERTY.org) — meow ships no defaults.

;;; Code:

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (repo (expand-file-name "../../../" here))   ; test/elate/lib/ -> repo root
       ;; Resolve `meow' by ABSOLUTE path — elate sandboxes $HOME, so `~'
       ;; points at the fake home.  Primary: ELATE_MEOW_DIR, then the sibling
       ;; checkout, then the Makefile's cache clone ($XDG_CACHE_HOME/meow).
       (meow (seq-find
              #'file-directory-p
              (delq nil
                    (list (getenv "ELATE_MEOW_DIR")
                          (expand-file-name "../meow" repo)
                          (and (getenv "XDG_CACHE_HOME")
                               (expand-file-name "meow" (getenv "XDG_CACHE_HOME"))))))))
  (unless meow
    (error "meow checkout not found (set ELATE_MEOW_DIR, or place it at %s)"
           (expand-file-name "../meow" repo)))
  (add-to-list 'load-path meow)
  (add-to-list 'load-path (expand-file-name "lisp" repo))
  (add-to-list 'load-path (expand-file-name "extensions/meow-ghostel" repo)))

(require 'meow)

(defun meow-setup ()
  "Meow's documented qwerty layout (KEYBINDING_QWERTY.org)."
  (setq meow-cheatsheet-layout meow-cheatsheet-layout-qwerty)
  (meow-motion-define-key
   '("j" . meow-next)
   '("k" . meow-prev)
   '("<escape>" . ignore))
  (meow-leader-define-key
   '("j" . "H-j")
   '("k" . "H-k")
   '("1" . meow-digit-argument)
   '("2" . meow-digit-argument)
   '("3" . meow-digit-argument)
   '("4" . meow-digit-argument)
   '("5" . meow-digit-argument)
   '("6" . meow-digit-argument)
   '("7" . meow-digit-argument)
   '("8" . meow-digit-argument)
   '("9" . meow-digit-argument)
   '("0" . meow-digit-argument)
   '("/" . meow-keypad-describe-key)
   '("?" . meow-cheatsheet))
  (meow-normal-define-key
   '("0" . meow-expand-0)
   '("9" . meow-expand-9)
   '("8" . meow-expand-8)
   '("7" . meow-expand-7)
   '("6" . meow-expand-6)
   '("5" . meow-expand-5)
   '("4" . meow-expand-4)
   '("3" . meow-expand-3)
   '("2" . meow-expand-2)
   '("1" . meow-expand-1)
   '("-" . negative-argument)
   '(";" . meow-reverse)
   '("," . meow-inner-of-thing)
   '("." . meow-bounds-of-thing)
   '("[" . meow-beginning-of-thing)
   '("]" . meow-end-of-thing)
   '("a" . meow-append)
   '("A" . meow-open-below)
   '("b" . meow-back-word)
   '("B" . meow-back-symbol)
   '("c" . meow-change)
   '("d" . meow-delete)
   '("D" . meow-backward-delete)
   '("e" . meow-next-word)
   '("E" . meow-next-symbol)
   '("f" . meow-find)
   '("g" . meow-cancel-selection)
   '("G" . meow-grab)
   '("h" . meow-left)
   '("H" . meow-left-expand)
   '("i" . meow-insert)
   '("I" . meow-open-above)
   '("j" . meow-next)
   '("J" . meow-next-expand)
   '("k" . meow-prev)
   '("K" . meow-prev-expand)
   '("l" . meow-right)
   '("L" . meow-right-expand)
   '("m" . meow-join)
   '("n" . meow-search)
   '("o" . meow-block)
   '("O" . meow-to-block)
   '("p" . meow-yank)
   '("q" . meow-quit)
   '("Q" . meow-goto-line)
   '("r" . meow-replace)
   '("R" . meow-swap-grab)
   '("s" . meow-kill)
   '("t" . meow-till)
   '("u" . meow-undo)
   '("U" . meow-undo-in-selection)
   '("v" . meow-visit)
   '("w" . meow-mark-word)
   '("W" . meow-mark-symbol)
   '("x" . meow-line)
   '("X" . meow-goto-line)
   '("y" . meow-save)
   '("Y" . meow-sync-grab)
   '("z" . meow-pop-selection)
   '("'" . repeat)
   '("<escape>" . ignore)))

(meow-setup)
(meow-global-mode 1)

(require 'ghostel)
(require 'meow-ghostel)
(add-hook 'ghostel-mode-hook #'meow-ghostel-mode)

;; macOS `login(1)' would reset HOME/SHELL from the passwd DB, ignoring the
;; elate sandbox HOME; disable it so the sandbox stays isolated.
(setq ghostel-macos-login-shell nil
      ring-bell-function 'ignore)

;; Shell override via env var, so one setup file serves every matrix entry.
(when-let* ((sh (getenv "ELATE_GHOSTEL_SHELL")))
  (setq ghostel-shell sh))

(provide 'meow-ghostel-setup)
;;; meow-ghostel-setup.el ends here
