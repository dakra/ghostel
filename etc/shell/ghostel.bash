# Ghostel shell integration for bash
# Source this from your .bashrc.
#
# Local `~/.bashrc' (prefix match — TRAMP appends `,tramp:VER'):
#   [[ "${INSIDE_EMACS%%,*}" = 'ghostel' ]] && source /path/to/ghostel/etc/shell/ghostel.bash
#
# Remote `~/.bashrc' (also gates on TERM, since ssh propagates it
# natively and INSIDE_EMACS does not without server-side AcceptEnv):
#   if [[ "${INSIDE_EMACS%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
#       source ~/.local/share/ghostel/ghostel.bash
#   fi
# See the README "Manual setup" section for the full rationale.

# Idempotency guard — skip if already loaded (e.g. auto-injected).
[[ "$(type -t __ghostel_osc7)" = "function" ]] && return

# Enable PTY echo.  Bash's readline buffers its own echo output so it
# never reaches the Emacs process filter.  PTY-level echo makes the
# kernel echo input immediately.
builtin command stty echo 2>/dev/null

# Report working directory to the terminal via OSC 7
__ghostel_osc7() {
    printf '\e]7;file://%s%s\a' "$HOSTNAME" "$PWD"
}

# --- Semantic prompt markers (OSC 133) ---
#
# Marker layout mirrors ghostty's bash integration:
#   - 133;A emitted via printf at end of PROMPT_COMMAND (once per
#     cycle, with redraw=last;cl=line;aid=$BASHPID).
#   - PS1 wrapped with 133;P;k=i (initial-prompt) at start and 133;B
#     (input boundary) at end.
#   - PS1 newlines (the bash `\n' escape) get 133;P;k=s injected.
#   - PS2 wrapped with 133;P;k=s at start and 133;B at end.
#
# Why not embed 133;A inline in PS1?  133;A has fresh-line behavior
# (CR+LF when cursor is not at column 0).  bash readline redraws PS1
# on every keystroke that changes display state — embedding 133;A
# would CR+LF on every redraw, eating the prompt.  133;P is the
# side-effect-free equivalent.
#
# `\[ \]' mark the OSC sequence as zero-width for readline's line-wrap
# math; `\a' is BEL — used everywhere here because `${var//pat/repl}'
# eats backslashes in the replacement, which would break ST (`\e\\').

# Emit "command finished" (D) for the previous command.
# D is skipped on the very first prompt (no previous command).
__ghostel_prompt_start() {
    if [[ -n "$__ghostel_prompt_shown" ]]; then
        printf '\e]133;D;%s\a' "$__ghostel_last_status"
    fi
    __ghostel_prompt_shown=1
}

# Emit "command output start" (C) via the DEBUG trap, and restore the
# unmarked PS1/PS2 so the user's command (and any other DEBUG-trap
# observers) doesn't see our markers.
# Guard: skip when running inside PROMPT_COMMAND itself.
__ghostel_in_prompt_command=0
__ghostel_preexec() {
    [[ "$__ghostel_in_prompt_command" = 1 ]] && return
    if [[ -n "${__ghostel_marked_ps1+x}" && "$PS1" == "$__ghostel_marked_ps1" ]]; then
        PS1=$__ghostel_saved_ps1
        PS2=$__ghostel_saved_ps2
    fi
    printf '\e]133;C\a'
}

# Wrap PS1/PS2 with the inline markers and emit 133;A separately.
# Re-wrap each PROMPT_COMMAND cycle: a prompt theme or `.bashrc'
# loaded after this file commonly reassigns PS1, stripping our wrap.
__ghostel_wrapped_prompt_command() {
    # Capture $? FIRST.  A bare assignment counts as a successful
    # command and resets $? to 0; `local' with `=$?' evaluates `$?'
    # before invoking the local builtin, preserving the exit status.
    local __ghostel_status=$?
    __ghostel_in_prompt_command=1
    __ghostel_last_status=$__ghostel_status

    if [[ -n "${__ghostel_marked_ps1+x}" && "$PS1" == "$__ghostel_marked_ps1" ]]; then
        PS1=$__ghostel_saved_ps1
        PS2=$__ghostel_saved_ps2
    fi

    __ghostel_prompt_start
    __ghostel_osc7

    eval "${__ghostel_original_prompt_command:-}"

    local __ghostel_p_initial='\[\e]133;P;k=i\a\]'
    if [[ "$PS1" != *"$__ghostel_p_initial"* ]]; then
        __ghostel_saved_ps1=$PS1
        __ghostel_saved_ps2=$PS2
        local __ghostel_p_secondary='\[\e]133;P;k=s\a\]'
        local __ghostel_b='\[\e]133;B\a\]'
        PS1="${__ghostel_p_initial}${PS1}${__ghostel_b}"
        # Inject 133;P;k=s after the bash `\n' PS1 escape so each
        # continuation row of a multiline prompt is tagged.  Skip
        # literal newlines ($'\n') — they may live inside $(...)
        # command substitutions where escape sequences would break
        # syntax.
        if [[ "$PS1" == *"\n"* ]]; then
            PS1="${PS1//\\n/\\n${__ghostel_p_secondary}}"
        fi
        # PS2 (continuation): k=s + B.
        PS2="${__ghostel_p_secondary}${PS2}${__ghostel_b}"
        __ghostel_marked_ps1=$PS1
        __ghostel_marked_ps2=$PS2
    fi

    # Emit 133;A once per cycle (with cl=line for click-events and
    # redraw=last so libghostty knows the prompt-redraw boundary).
    # `aid=$BASHPID' tags this prompt with the current shell PID.
    printf '\e]133;A;redraw=last;cl=line;aid=%s\a' "$BASHPID"

    __ghostel_in_prompt_command=0
}

# Preserve any existing PROMPT_COMMAND.
__ghostel_original_prompt_command="${PROMPT_COMMAND:+$PROMPT_COMMAND}"
PROMPT_COMMAND="__ghostel_wrapped_prompt_command"

trap '__ghostel_preexec' DEBUG

# Outbound `ssh' wrapper.  Activated when the elisp side sets
# `ghostel-ssh-install-terminfo' (which exports
# GHOSTEL_SSH_INSTALL_TERMINFO).
#
# On first connection to a host the wrapper probes whether
# xterm-ghostty terminfo is present, installs it via `tic' if not,
# caches the outcome under $XDG_CACHE_HOME/ghostel/ssh-terminfo-cache
# (key includes a hash of the local terminfo so libghostty bumps
# auto-invalidate the cache), and connects with TERM=xterm-ghostty.
# Subsequent connections hit the cache.  Failures (no `tic' on remote,
# no write access) cache a skip marker and downgrade to xterm-256color.
#
# Per-call escape hatch: prefix `ssh' with GHOSTEL_SSH_KEEP_TERM=1 to
# bypass the wrapper entirely.
if [[ -n "$GHOSTEL_SSH_INSTALL_TERMINFO" ]]; then
    # `function NAME { … }' rather than `NAME() { … }' so a user alias
    # on `ssh' (aliases expand at parse time in zsh, and bash when the
    # alias is already active while sourcing this file) can't turn the
    # definition into a parse error.
    function ssh {
        # Escape hatch + need infocmp locally to do anything useful.
        if [[ -n "$GHOSTEL_SSH_KEEP_TERM" ]] || \
               ! builtin command -v infocmp >/dev/null 2>&1; then
            builtin command ssh "$@"
            return
        fi

        # Resolve the canonical target (normalises ssh_config aliases).
        local _user="" _host="" _port="" _k _v
        while IFS=' ' read -r _k _v; do
            case "$_k" in
                user)     _user=$_v ;;
                hostname) _host=$_v ;;
                port)     _port=$_v ;;
            esac
            [[ -n $_user && -n $_host && -n $_port ]] && break
        done < <(builtin command ssh -G "$@" 2>/dev/null)

        # No host (e.g. `ssh -V`, `ssh -h`): pass through.
        if [[ -z $_host ]]; then
            builtin command ssh "$@"
            return
        fi

        local _target="$_user@$_host:$_port"
        local _hash
        _hash=$(infocmp -0 -x xterm-ghostty 2>/dev/null \
                    | cksum 2>/dev/null | awk '{print $1}')
        local _cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ghostel"
        local _cache="$_cache_dir/ssh-terminfo-cache"
        local _key="$_target:$_hash"

        # Cache hit?
        if [[ -r $_cache ]]; then
            if grep -Fxq "$_key ok" "$_cache" 2>/dev/null; then
                TERM=xterm-ghostty builtin command ssh "$@"
                return
            fi
            if grep -Fxq "$_key skip" "$_cache" 2>/dev/null; then
                TERM=xterm-256color builtin command ssh "$@"
                return
            fi
        fi

        # Skip install when the user passed a remote command — combining
        # our install script with their command via the same ssh
        # invocation is fragile.  The next interactive `ssh HOST' will
        # trigger install.
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
            TERM=xterm-256color builtin command ssh "$@"
            return
        fi

        # Combined probe + install in a single setup ssh invocation.
        # Mkdir-as-lock so concurrent first-time `ssh HOST' from two
        # ghostel buffers don't both spawn a setup connection.
        builtin command mkdir -p "$_cache_dir" 2>/dev/null
        # Lock keyed on (target, hash) so concurrent calls to the same
        # target serialize, but different targets run in parallel.
        local _lock="$_cache_dir/.lock.$_target.$_hash"
        if ! builtin command mkdir "$_lock" 2>/dev/null; then
            TERM=xterm-256color builtin command ssh "$@"
            return
        fi
        # No `trap RETURN' — bash's RETURN trap is shell-global and
        # would clobber any pre-existing user trap.  Cleanup is
        # explicit at each return point.
        if infocmp -0 -x xterm-ghostty 2>/dev/null \
                | builtin command ssh "$@" '
                    infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                    command -v tic >/dev/null 2>&1 || exit 1
                    mkdir -p "$HOME/.terminfo" && tic -x - >/dev/null 2>&1
                  ' >/dev/null 2>&1; then
            builtin echo "$_key ok" >> "$_cache"
            builtin command rmdir "$_lock" 2>/dev/null
            TERM=xterm-ghostty builtin command ssh "$@"
        else
            builtin echo "ghostel: failed to install xterm-ghostty terminfo on $_host \
(no \`tic' on remote?), using xterm-256color." >&2
            builtin echo "$_key skip" >> "$_cache"
            builtin command rmdir "$_lock" 2>/dev/null
            TERM=xterm-256color builtin command ssh "$@"
        fi
    }
fi

# Call an Emacs Elisp function from the shell.
# Usage: ghostel_cmd FUNCTION [ARGS...]
# The function must be in `ghostel-eval-cmds'.
ghostel_cmd() {
    local payload=""
    while [ $# -gt 0 ]; do
        payload="$payload\"$(printf '%s' "$1" | sed -e 's|\\|\\\\|g' -e 's|"|\\"|g')\" "
        shift
    done
    printf '\e]51;E%s\e\\' "$payload"
}
