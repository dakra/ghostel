#!/usr/bin/env bash
set -euo pipefail

version="${1:-${EMACS_VERSION:-}}"
if [[ -z "$version" ]]; then
  echo "usage: $0 <emacs-version> or set EMACS_VERSION" >&2
  exit 2
fi

if [[ -z "${NIX_EMACS_CI_REF:-}" ]]; then
  echo "NIX_EMACS_CI_REF must name the pinned purcell/nix-emacs-ci revision" >&2
  exit 2
fi

attr="emacs-${version//./-}"
flake_ref="github:purcell/nix-emacs-ci?rev=${NIX_EMACS_CI_REF}#${attr}"

echo "Installing ${attr} from purcell/nix-emacs-ci@${NIX_EMACS_CI_REF}"
nix profile install --accept-flake-config "$flake_ref"
emacs --version
