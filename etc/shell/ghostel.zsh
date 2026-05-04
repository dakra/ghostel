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

# Report working directory to the terminal via OSC 7
__ghostel_osc7() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    builtin printf '\e]7;file://%s%s\a' "$HOST" "$PWD"
}

# --- Semantic prompt markers (OSC 133) ---
#
# Marker layout mirrors ghostty's zsh integration:
#   - mark1 = `%{\e]133;A;cl=line\a%}'  — primary prompt start
#   - mark2 = `%{\e]133;P;k=s\a%}'      — continuation (multi-line, PS2)
#   - markB = `%{\e]133;B\a%}'          — input boundary
# `%{...%}' marks the OSC sequence as zero-width to zsh's prompt
# expansion.  BEL terminates the OSC.

__ghostel_save_status() {
    builtin local cmd_status=$?
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    __ghostel_last_status=$cmd_status
}

# Emit "command finished" (D) for the previous command.  Marks A/B/P
# are embedded in PROMPT itself by `__ghostel_ensure_prompt_wrap' so
# they fire in lockstep with prompt rendering (including
# `zle reset-prompt', SIGWINCH, etc).
__ghostel_prompt_start() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    if [[ -n "$__ghostel_prompt_shown" ]]; then
        builtin printf '\e]133;D;%s\a' "$__ghostel_last_status"
    fi
    __ghostel_prompt_shown=1
}

# Restore the unmarked PROMPT/PROMPT2 if nothing else has modified them
# since our precmd added marks.  This ensures other preexec hooks see
# a clean PROMPT without our marks; if PROMPT was modified (e.g. by an
# async theme update), leave it alone.  Then emit "command output
# start" (C).
__ghostel_preexec() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    if [[ -n ${__ghostel_marked_prompt+x} && "$PROMPT" == "$__ghostel_marked_prompt" ]]; then
        PROMPT=$__ghostel_saved_prompt
        PROMPT2=$__ghostel_saved_prompt2
    fi
    builtin printf '\e]133;C\a'
}

# Wrap PROMPT/PROMPT2 with semantic prompt markers.  Mirrors ghostty's
# `_ghostty_precmd' wrap logic: only wrap when we're already last in
# `precmd_functions' (so our marks aren't immediately overwritten by a
# later hook).  Otherwise self-reorder for next cycle and emit mark1
# directly via printf as a one-shot fallback.
__ghostel_ensure_prompt_wrap() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases

    builtin local mark1=$'%{\e]133;A;cl=line\a%}'
    if [[ -o prompt_percent ]]; then
        builtin typeset -g precmd_functions
        if [[ ${precmd_functions[-1]} == __ghostel_ensure_prompt_wrap ]]; then
            # Restore PROMPT/PROMPT2 to their pre-mark state if nothing
            # else has modified them since we last added marks.  Avoids
            # exposing PROMPT with our marks to other hooks (themes
            # like Pure pattern-match $PROMPT to strip/rebuild and
            # break if they see our markers).  If PROMPT was modified
            # (theme, async update), keep the modified version.
            builtin local ps1_changed=0
            if [[ -n ${__ghostel_saved_prompt+x} ]]; then
                if [[ $PROMPT == $__ghostel_marked_prompt ]]; then
                    PROMPT=$__ghostel_saved_prompt
                    PROMPT2=$__ghostel_saved_prompt2
                elif [[ $PROMPT != $__ghostel_saved_prompt ]]; then
                    ps1_changed=1
                fi
            fi

            # Save the clean PROMPT/PROMPT2 before adding marks.
            __ghostel_saved_prompt=$PROMPT
            __ghostel_saved_prompt2=$PROMPT2

            builtin local mark2=$'%{\e]133;P;k=s\a%}'
            builtin local markB=$'%{\e]133;B\a%}'

            # Trailing bare `%' would combine with `{' in markB to form
            # a `%{' prompt escape and swallow the marker.  Double it.
            [[ $PROMPT == *[^%]% || $PROMPT == % ]] && PROMPT=$PROMPT%
            PROMPT=${mark1}${PROMPT}${markB}

            # Multiline prompt: inject mark2 (k=s) after each newline so
            # libghostty distinguishes primary vs continuation rows.
            # Skip if PROMPT changed in this cycle — injecting marks
            # into newlines breaks pattern matching in themes that
            # strip/rebuild the prompt (e.g. Pure).
            if (( ! ps1_changed )) && [[ $PROMPT == *$'\n'* ]]; then
                PROMPT=${PROMPT//$'\n'/$'\n'${mark2}}
            fi

            [[ $PROMPT2 == *[^%]% || $PROMPT2 == % ]] && PROMPT2=$PROMPT2%
            PROMPT2=${mark2}${PROMPT2}${markB}

            __ghostel_marked_prompt=$PROMPT
        else
            # Not last in precmd_functions — a later hook will overwrite
            # PROMPT after we wrap it.  Move ourselves to the end for
            # next cycle, and emit mark1 once via printf so the upcoming
            # prompt is still tagged.  `$mark1[3,-3]' strips the leading
            # `%{' and trailing `%}' to print just the OSC bytes.
            precmd_functions=(${precmd_functions:#__ghostel_ensure_prompt_wrap} __ghostel_ensure_prompt_wrap)
            if ! builtin zle; then
                builtin printf '%s' $mark1[3,-3]
            fi
        fi
    elif ! builtin zle; then
        # Without prompt_percent we cannot patch PROMPT.  Emit mark1
        # directly when not invoked from zle.
        builtin printf '%s' $mark1[3,-3]
    fi
}

# ZLE line-init fallback: emit prompt markers directly if PROMPT lost
# them between precmd and this redraw (e.g. another plugin regenerated
# PROMPT after our precmd ran).  Use 133;P, NOT 133;A: the fallback
# fires from `zle-line-init' AFTER the prompt has been drawn, so the
# cursor is past column 0 — libghostty CR+LFs on 133;A when cursor !=
# col 0, pushing the input cursor onto a blank line below the prompt
# char.  133;P is the side-effect-free prompt-start marker.  Also
# emit 133;B to mark the input area.
__ghostel_zle_line_init_hook() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    [[ "$PROMPT" != *$'%{\e]133;A'* ]] && \
        builtin printf '\e]133;P;k=i\a\e]133;B\a'
}

# One-shot installer: registered as a precmd, runs once on the first
# prompt fire (after `.zshrc' has finished and any user/theme
# `zle-line-init' widget is in place).  Chains our hook to whatever
# existing widget is registered, then removes itself from precmd_functions.
#
# Mirrors ghostty's zsh integration:
#   - If the widget is already managed by `add-zle-hook-widget'
#     (oh-my-zsh, prezto and others wrap zle-line-init this way),
#     register through that framework instead of overwriting — blindly
#     rebinding the widget detaches the framework's dispatcher chain.
#   - Otherwise, save any existing widget under a leading-dot name (works
#     around zsh-syntax-highlighting bugs) and append a tail invocation
#     of the original to our hook function's body so it still runs after
#     us.  `flag' picks `-N' vs. `-Nw' — the former preserves $WIDGET
#     for user-defined widgets, the latter is needed for builtins.
__ghostel_install_zle_hook() {
    builtin emulate -L zsh -o no_warn_create_global -o no_aliases
    builtin local hook=line-init
    builtin local func=__ghostel_zle_line_init_hook
    builtin local widget=zle-$hook
    builtin local orig_widget flag
    if [[ ${widgets[$widget]} == user:azhw:* ]] && \
           (( $+functions[add-zle-hook-widget] )); then
        add-zle-hook-widget $hook $func
    else
        if (( $+widgets[$widget] )); then
            orig_widget=._ghostel_orig_$widget
            builtin zle -A $widget $orig_widget
            if [[ ${widgets[$widget]} == user:* ]]; then
                flag=
            else
                flag=w
            fi
            functions[$func]+="
                builtin zle $orig_widget -N$flag -- \"\$@\""
        fi
        builtin zle -N $widget $func
    fi
    precmd_functions=(${precmd_functions:#__ghostel_install_zle_hook})
}

precmd_functions=(__ghostel_save_status __ghostel_prompt_start __ghostel_osc7 "${precmd_functions[@]}")
precmd_functions+=(__ghostel_ensure_prompt_wrap __ghostel_install_zle_hook)
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
    printf '\e]51;E%s\e\\' "$payload"
}
