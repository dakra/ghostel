#!/bin/sh
# Remote half of `ghostel ssh-install'.  Runs on the target host after
# `ghostel_ssh_install' unpacked the integration scripts and compiled
# terminfo into ~/.local/share/ghostel.  Copies the terminfo into
# ~/.terminfo (ncurses searches it without any TERMINFO setup) and
# hooks the login shell's startup so a plain `ssh HOST' from ghostel
# loads the integration.  Safe to re-run.
set -eu

dir=$HOME/.local/share/ghostel

for d in "$dir"/terminfo/*/; do
    sub=$(basename "$d")
    mkdir -p "$HOME/.terminfo/$sub"
    cp "$d"* "$HOME/.terminfo/$sub/"
done
echo "ghostel: installed xterm-ghostty terminfo into ~/.terminfo"

# append_once FILE: append stdin to FILE between marker lines, unless
# the markers are already there.
append_once() {
    if [ -r "$1" ] && grep -Fq '# >>> ghostel >>>' "$1"; then
        echo "ghostel: $1 already hooked"
        cat >/dev/null
        return
    fi
    { printf '\n# >>> ghostel >>>\n'; cat; printf '# <<< ghostel <<<\n'; } >> "$1" || exit 1
    echo "ghostel: hooked $1"
}

case ${SHELL##*/} in
    bash)
        append_once "$HOME/.bashrc" <<'EOF'
if [[ "${INSIDE_EMACS%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
    source ~/.local/share/ghostel/shell/ghostel.bash
fi
EOF
        ;;
    zsh)
        append_once "${ZDOTDIR:-$HOME}/.zshrc" <<'EOF'
if [[ "${${INSIDE_EMACS-}%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
    source ~/.local/share/ghostel/shell/ghostel.zsh
fi
EOF
        ;;
    fish)
        f=${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/ghostel.fish
        mkdir -p "${f%/*}"
        cat > "$f" <<'EOF'
if string match -qr '^ghostel(,|$)' -- "$INSIDE_EMACS"; or test "$TERM" = 'xterm-ghostty'
    source ~/.local/share/ghostel/shell/ghostel.fish
end
EOF
        echo "ghostel: wrote $f"
        ;;
    nu)
        # $nu.data-dir is platform-specific (~/Library/Application Support
        # on macOS), so ask nu; fall back to the XDG default.
        # shellcheck disable=SC2016
        f=$(nu -c 'print $nu.data-dir' 2>/dev/null \
            || echo "${XDG_DATA_HOME:-$HOME/.local/share}/nushell")/vendor/autoload/ghostel.nu
        mkdir -p "${f%/*}"
        echo 'source ~/.local/share/ghostel/shell/ghostel.nu' > "$f"
        echo "ghostel: wrote $f"
        ;;
    *)
        echo "ghostel: unsupported login shell '$SHELL'; scripts are in $dir/shell, source one from your shell config" >&2
        exit 1
        ;;
esac
