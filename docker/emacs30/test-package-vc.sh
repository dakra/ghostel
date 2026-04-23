#!/usr/bin/env bash
# Reproduce `package-vc-install ghostel` on Emacs 30 inside a disposable
# container.  The ghostel repo is mounted read-only at /repo so the test
# uses the exact branch currently checked out on the host.
#
# Usage:
#   docker/emacs30/test-package-vc.sh                # ghostel, current HEAD
#   docker/emacs30/test-package-vc.sh <branch>       # specific branch
#   docker/emacs30/test-package-vc.sh <branch> evil  # evil-ghostel too
#
# Re-runs reuse the built image (`ghostel-emacs30`); rebuild with
#   docker build -t ghostel-emacs30 docker/emacs30
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRANCH="${1:-$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)}"
WITH_EVIL="${2:-}"

if ! docker image inspect ghostel-emacs30 >/dev/null 2>&1; then
    docker build -t ghostel-emacs30 "$REPO_ROOT/docker/emacs30"
fi

# package-vc uses vc-git-clone, which reads the source's .git directory.
# If REPO_ROOT is a git submodule or worktree (.git is a file pointing
# outside the mount), the container can't follow it.  Materialize a
# self-contained clone on the host and mount that instead.
CLONE_DIR=$(mktemp -d -t ghostel-clone)
trap 'rm -rf "$CLONE_DIR"' EXIT
git clone --quiet --local --no-hardlinks --branch "$BRANCH" \
    "$REPO_ROOT" "$CLONE_DIR"

# Wrap all forms in (progn ...) so --eval accepts them as a single
# expression; single-quoted heredoc keeps the elisp verbatim.
SCRIPT=$(cat <<'ELISP'
(progn
  (require 'package)
  (require 'package-vc)
  (setq package-archives
        '(("gnu"    . "https://elpa.gnu.org/packages/")
          ("nongnu" . "https://elpa.nongnu.org/nongnu/")
          ("melpa"  . "https://melpa.org/packages/")))
  (package-initialize)
  (package-refresh-contents)

  (message "\n===== installing ghostel from /repo (branch %s, lisp-dir=%s) =====" (getenv "GHOSTEL_BRANCH") (getenv "GHOSTEL_LISP_DIR"))
  (let ((spec `(ghostel :url "/repo" :branch ,(getenv "GHOSTEL_BRANCH"))))
    (when (equal (getenv "GHOSTEL_LISP_DIR") "lisp")
      (setq spec (append spec '(:lisp-dir "lisp"))))
    (condition-case err
        (package-vc-install spec)
      (error (message "package-vc-install signalled: %S" err))))

  (message "\n===== post-install diagnostics =====")
  (message "load-path entries containing 'ghostel': %S"
           (seq-filter (lambda (p) (string-match-p "ghostel" p)) load-path))
  (message "locate-library ghostel -> %s" (locate-library "ghostel"))
  (message "(require 'ghostel): ...")
  (condition-case err
      (progn (require 'ghostel) (message "  OK, ghostel feature provided"))
    (error (message "  FAIL: %S" err)))

  (when (equal (getenv "WITH_EVIL") "evil")
    (message "\n===== installing evil + evil-ghostel =====")
    (package-install 'evil)
    (package-vc-install
     `(evil-ghostel :url "/repo"
                    :branch ,(getenv "GHOSTEL_BRANCH")
                    :lisp-dir "extensions/evil-ghostel"))))
ELISP
)

docker run --rm \
    -v "$CLONE_DIR:/repo:ro" \
    -e "GHOSTEL_BRANCH=$BRANCH" \
    -e "WITH_EVIL=$WITH_EVIL" \
    -e "GHOSTEL_LISP_DIR=${GHOSTEL_LISP_DIR:-}" \
    ghostel-emacs30 \
    emacs --batch --eval "$SCRIPT"
