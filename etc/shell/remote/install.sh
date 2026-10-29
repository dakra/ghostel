#!/bin/sh
# Remote half of `ghostel ssh' and `ghostel ssh-install'.  Runs on the
# target host after etc/shell and etc/terminfo were unpacked into
# ~/.local/share/ghostel.  Copies the terminfo into ~/.terminfo (ncurses
# searches it without any TERMINFO setup).  With --hook, also hooks the
# login shell's startup so a plain `ssh HOST' from ghostel loads the
# integration.  Safe to re-run.
set -eu

dir=$HOME/.local/share/ghostel

for d in "$dir"/etc/terminfo/*/; do
    sub=$(basename "$d")
    mkdir -p "$HOME/.terminfo/$sub"
    cp "$d"* "$HOME/.terminfo/$sub/"
done
echo "ghostel: installed xterm-ghostty terminfo into ~/.terminfo"

[ "${1:-}" = --hook ] || exit 0

# hook FILE: write stdin to FILE between marker lines, replacing an
# earlier block.
hook() {
    if [ -f "$1" ]; then
        awk '/^# >>> ghostel >>>$/{s=1} !s; /^# <<< ghostel <<<$/{s=0}' "$1" > "$1.ghostel" || exit 1
        [ -n "$(tail -c1 "$1.ghostel")" ] && echo >> "$1.ghostel"
        mv "$1.ghostel" "$1" || exit 1
    fi
    { echo '# >>> ghostel >>>'; cat; echo '# <<< ghostel <<<'; } >> "$1" || exit 1
    echo "ghostel: hooked $1"
}

case ${SHELL##*/} in
    bash)
        hook "$HOME/.bashrc" <<'EOT'
if [[ "${INSIDE_EMACS%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
    source ~/.local/share/ghostel/etc/shell/ghostel.bash
fi
EOT
        ;;
    zsh)
        hook "${ZDOTDIR:-$HOME}/.zshrc" <<'EOT'
if [[ "${${INSIDE_EMACS-}%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
    source ~/.local/share/ghostel/etc/shell/ghostel.zsh
fi
EOT
        ;;
    fish)
        f=${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/ghostel.fish
        mkdir -p "${f%/*}"
        cat > "$f" <<'EOT'
if string match -qr '^ghostel(,|$)' -- "$INSIDE_EMACS"; or test "$TERM" = 'xterm-ghostty'
    source ~/.local/share/ghostel/etc/shell/ghostel.fish
end
EOT
        echo "ghostel: wrote $f"
        ;;
    nu)
        # $nu.data-dir is platform-specific (~/Library/Application Support
        # on macOS), so ask nu; fall back to the XDG default.
        # shellcheck disable=SC2016
        f=$(nu -n -c 'print $nu.data-dir' 2>/dev/null \
            || echo "${XDG_DATA_HOME:-$HOME/.local/share}/nushell")/vendor/autoload/ghostel.nu
        mkdir -p "${f%/*}"
        echo 'source ~/.local/share/ghostel/etc/shell/ghostel.nu' > "$f"
        echo "ghostel: wrote $f"
        ;;
    *)
        echo "ghostel: unsupported login shell '$SHELL'; scripts are in $dir/etc/shell, source one from your shell config" >&2
        exit 1
        ;;
esac
