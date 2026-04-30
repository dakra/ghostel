# Ghostel shell integration for zsh
# Source this from your .zshrc.
#
# The `${var-}' fallback inside the trim is for users with `setopt
# nounset' — zsh errors on `${unset%%pat}' without it (bash doesn't).
#
# Local `~/.zshrc' (prefix match — TRAMP appends `,tramp:VER'):
#   [[ "${${INSIDE_EMACS-}%%,*}" = 'ghostel' ]] && source /path/to/ghostel/etc/shell/ghostel.zsh
#
# Remote `~/.zshrc' (also gates on TERM, since ssh propagates it
# natively and INSIDE_EMACS does not without server-side AcceptEnv):
#   if [[ "${${INSIDE_EMACS-}%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
#       source ~/.local/share/ghostel/ghostel.zsh
#   fi
# See the README "Manual setup" section for the full rationale.

# Idempotency guard — skip if already loaded (e.g. auto-injected).
(( $+functions[__ghostel_osc7] )) && return

# Emit an OSC sequence with the given body (the part between `\e]' and
# the ST `\e\\').  Inside tmux, wrap the OSC in DCS-passthrough so tmux
# forwards the body to the outer terminal — requires `set -g
# allow-passthrough on' in tmux.conf (tmux 3.3+).
__ghostel_emit_osc() {
    if [[ -n "$TMUX" ]]; then
        printf '\ePtmux;\e\e]%s\e\e\\\e\\' "$1"
    else
        printf '\e]%s\e\\' "$1"
    fi
}

# Report working directory to the terminal via OSC 7
__ghostel_osc7() {
    __ghostel_emit_osc "7;file://$HOST$PWD"
}

# --- Semantic prompt markers (OSC 133) ---

__ghostel_save_status() {
    __ghostel_last_status="$?"
}

# Emit "command finished" (D) + "prompt start" (A).
__ghostel_prompt_start() {
    if [[ -n "$__ghostel_prompt_shown" ]]; then
        __ghostel_emit_osc "133;D;$__ghostel_last_status"
    fi
    __ghostel_emit_osc "133;A"
}

# Emit "prompt end / command start" (B).
__ghostel_prompt_end() {
    __ghostel_emit_osc "133;B"
    __ghostel_prompt_shown=1
}

# Emit "command output start" (C).
__ghostel_preexec() {
    __ghostel_emit_osc "133;C"
}

precmd_functions=(__ghostel_save_status __ghostel_prompt_start __ghostel_osc7 "${precmd_functions[@]}" __ghostel_prompt_end)
preexec_functions=(__ghostel_preexec "${preexec_functions[@]}")

# Outbound `ssh' wrapper.  See etc/ghostel.bash for the full design
# notes — this is the zsh port of the same install-and-cache logic.
if [[ -n "$GHOSTEL_SSH_INSTALL_TERMINFO" ]]; then
    # `function NAME { … }' rather than `NAME() { … }' so a user alias
    # on `ssh' (aliases expand at parse time in zsh, and bash when the
    # alias is already active while sourcing this file) can't turn the
    # definition into a parse error.
    function ssh {
        if [[ -n "$GHOSTEL_SSH_KEEP_TERM" ]] || \
               ! command -v infocmp >/dev/null 2>&1; then
            command ssh "$@"
            return
        fi

        local _user="" _host="" _port="" _k _v
        while IFS=' ' read -r _k _v; do
            case "$_k" in
                user)     _user=$_v ;;
                hostname) _host=$_v ;;
                port)     _port=$_v ;;
            esac
            [[ -n $_user && -n $_host && -n $_port ]] && break
        done < <(command ssh -G "$@" 2>/dev/null)

        if [[ -z $_host ]]; then
            command ssh "$@"
            return
        fi

        local _target="$_user@$_host:$_port"
        local _hash
        _hash=$(infocmp -0 -x xterm-ghostty 2>/dev/null \
                    | cksum 2>/dev/null | awk '{print $1}')
        local _cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ghostel"
        local _cache="$_cache_dir/ssh-terminfo-cache"
        local _key="$_target:$_hash"

        if [[ -r $_cache ]]; then
            if grep -Fxq "$_key ok" "$_cache" 2>/dev/null; then
                TERM=xterm-ghostty command ssh "$@"
                return
            fi
            if grep -Fxq "$_key skip" "$_cache" 2>/dev/null; then
                TERM=xterm-256color command ssh "$@"
                return
            fi
        fi

        local _positional=0 _skip=0 _arg
        for _arg in "$@"; do
            if (( _skip )); then _skip=0; continue; fi
            case "$_arg" in
                -[bcDEeFIiJLlmOoPpQRSWw]) _skip=1 ;;
                -*) ;;
                *) ((_positional++)) ;;
            esac
        done

        if (( _positional > 1 )); then
            TERM=xterm-256color command ssh "$@"
            return
        fi

        command mkdir -p "$_cache_dir" 2>/dev/null
        # Lock keyed on (target, hash) — see etc/ghostel.bash.
        local _lock="$_cache_dir/.lock.$_target.$_hash"
        if ! command mkdir "$_lock" 2>/dev/null; then
            TERM=xterm-256color command ssh "$@"
            return
        fi
        {
            if infocmp -0 -x xterm-ghostty 2>/dev/null \
                    | command ssh "$@" '
                        infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                        command -v tic >/dev/null 2>&1 || exit 1
                        mkdir -p "$HOME/.terminfo" && tic -x - >/dev/null 2>&1
                      ' >/dev/null 2>&1; then
                print -r -- "$_key ok" >> "$_cache"
                TERM=xterm-ghostty command ssh "$@"
            else
                print -r -- "ghostel: failed to install xterm-ghostty terminfo on $_host \
(no \`tic' on remote?), using xterm-256color." >&2
                print -r -- "$_key skip" >> "$_cache"
                TERM=xterm-256color command ssh "$@"
            fi
        } always {
            command rmdir "$_lock" 2>/dev/null
        }
    }
fi

# Call an Emacs Elisp function from the shell.
# Usage: ghostel_cmd FUNCTION [ARGS...]
# The function must be in `ghostel-eval-cmds'.
ghostel_cmd() {
    local payload="" arg
    while (( $# )); do
        arg="${1//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        payload="$payload\"$arg\" "
        shift
    done
    __ghostel_emit_osc "51;E$payload"
}
