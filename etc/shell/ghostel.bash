# Ghostel shell integration for bash
# Source this from your .bashrc.
#
# Local `~/.bashrc' (prefix match — TRAMP appends `,tramp:VER'):
#   [[ "${INSIDE_EMACS%%,*}" = 'ghostel' ]] && source /path/to/ghostel/etc/shell/ghostel.bash
#
# Remote `~/.bashrc' (also gates on TERM, since ssh propagates it
# natively and INSIDE_EMACS does not without server-side AcceptEnv):
#   if [[ "${INSIDE_EMACS%%,*}" = 'ghostel' || "$TERM" = 'xterm-ghostty' ]]; then
#       source ~/.local/share/ghostel/etc/shell/ghostel.bash
#   fi
# See the README "Manual setup" section for the full rationale.

# Idempotency guard — skip if already loaded (e.g. auto-injected).
[[ "$(builtin type -t __ghostel_osc7)" = "function" ]] && return

# Old bash (e.g. macOS system bash 3.2) rejects process substitution `<(...)`
# at parse time under POSIX mode; the `ssh` wrapper below uses it.
# Exit POSIX mode first so sourcing succeeds regardless of the caller's mode.
builtin set +o posix

# Enable PTY echo.  Bash's readline buffers its own echo output so it
# never reaches the Emacs process filter.  PTY-level echo makes the
# kernel echo input immediately.
builtin command stty echo 2>/dev/null

# Capture gethostname(2) for OSC 7.  $HOSTNAME is inherited from the environment;
# toolbox/container runtimes export it with a value that disagrees with the
# kernel hostname - so Emacs' (system-name), which calls gethostname(2), would
# see a mismatch and ghostel would misclassify the buffer as remote, switching
# on TRAMP.  Bash captures gethostname(2) at startup into the value behind the
# \H prompt escape; ${var@P} (bash 4.4+) reads it back without forking.
# On bash <4.4 the @P transform is unavailable, so fall back to $HOSTNAME.
if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
    __ghostel_bash44=1
    __ghostel_host=$'\\H'
    __ghostel_host=${__ghostel_host@P}
else
    __ghostel_bash44=""
    __ghostel_host=$HOSTNAME
fi

# Report working directory via OSC 7.  kitty's kitty-shell-cwd://
# scheme carries the path verbatim; ghostty and kitty parse it too
# when this script runs under them.
__ghostel_osc7() {
    printf '\e]7;kitty-shell-cwd://%s%s\a' "$__ghostel_host" "$PWD"
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
    if [[ -n "${__ghostel_prompt_shown:-}" ]]; then
        printf '\e]133;D;%s\a' "$__ghostel_last_status"
    fi
    __ghostel_prompt_shown=1
}

# Restore the unmarked PS1/PS2 while they still carry our wrap, so
# the running command doesn't see our markers.
__ghostel_restore_prompt() {
    if [[ -n "${__ghostel_marked_ps1+x}" && "$PS1" == "$__ghostel_marked_ps1" ]]; then
        PS1=$__ghostel_saved_ps1
        PS2=$__ghostel_saved_ps2
    fi
}

# Emit "command output start" (C) and restore the prompt, for the
# bash < 4.4 DEBUG-trap adapter.  On bash >= 4.4, C is emitted via
# PS0 instead (see the version gate below): an interactive bash
# expands PS0 exactly once after reading a complete command line and
# before executing it, so a compound line (`sleep 7; false') emits a
# single C.
__ghostel_preexec() {
    __ghostel_restore_prompt
    printf '\e]133;C\a'
}

# DEBUG-trap adapter for bash < 4.4 (no PS0).  DEBUG fires before
# every simple command, so `__ghostel_preexec_armed' — set once per
# cycle at the end of PROMPT_COMMAND — limits C to the first command
# of each line.  Guards: skip inside PROMPT_COMMAND itself, and skip
# hooks appended to the bash-5.1+ PROMPT_COMMAND array after this
# file loaded (e.g. systemd's osc-context profile.d script) — they
# run as separate top-level commands, matched fragment-by-fragment,
# split on `;'/newline like bash-preexec does.  Known limitation
# (shared with bash-preexec): a user-typed command byte-identical to
# a fragment is skipped too.  Subshells inherit the trap but must not
# emit C: their disarm cannot reach the parent shell.  A readline
# `bind -x' handler runs through DEBUG while still at the prompt;
# READLINE_LINE is set only during such handlers (bash 4.0+), so skip
# them and keep the armed C for the real command.  bash 3.x has no
# such discriminator: there a `bind -x' keypress consumes the C.
__ghostel_preexec_armed=""
__ghostel_in_prompt_command=0
__ghostel_debug_preexec() {
    [[ -z "$__ghostel_preexec_armed" ]] && return
    [[ -n "${READLINE_LINE+x}" ]] && return
    [[ "${BASH_SUBSHELL:-0}" != 0 ]] && return
    [[ "$__ghostel_in_prompt_command" = 1 ]] && return
    local __ghostel_frags __ghostel_f IFS=$';\n'
    read -rd '' -a __ghostel_frags <<< "${PROMPT_COMMAND[*]:-}"
    for __ghostel_f in ${__ghostel_frags[@]+"${__ghostel_frags[@]}"}; do
        __ghostel_f="${__ghostel_f#"${__ghostel_f%%[![:space:]]*}"}"
        __ghostel_f="${__ghostel_f%"${__ghostel_f##*[![:space:]]}"}"
        [[ -n "$__ghostel_f" && "$BASH_COMMAND" == "$__ghostel_f" ]] && return
    done
    __ghostel_preexec_armed=""
    __ghostel_preexec
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

    __ghostel_restore_prompt

    __ghostel_prompt_start

    # Run the captured PROMPT_COMMAND hooks, restoring $? before each
    # so hooks that report the last command's exit status (systemd's
    # osc-context, vte) see the user command's status, not ours.
    local __ghostel_cmd
    for __ghostel_cmd in ${__ghostel_original_prompt_commands[@]+"${__ghostel_original_prompt_commands[@]}"}; do
        __ghostel_set_status "$__ghostel_last_status"
        eval "$__ghostel_cmd"
    done

    # OSC 7 must fire AFTER the user/system PROMPT_COMMAND so we win the race
    # against competing OSC 7 emitters.  Fedora's /etc/profile.d/vte.sh
    # registers __vte_prompt_command which emits OSC 7 with $HOSTNAME
    # (which may be polluted by container/toolbox runtimes; See #276).
    __ghostel_osc7

    local __ghostel_p_initial='\[\e]133;P;k=i\a\]'
    local __ghostel_p_secondary='\[\e]133;P;k=s\a\]'
    local __ghostel_b='\[\e]133;B\a\]'
    # PS1 may still carry a previous cycle's wrap — e.g.
    # `source venv/bin/activate' prepends to the marked PS1 when the
    # pre-command restore was skipped (bash < 5.3).  Strip embedded
    # markers so the wrap below re-anchors at the prompt start.
    PS1=${PS1//"$__ghostel_p_initial"/}
    PS1=${PS1//"$__ghostel_p_secondary"/}
    PS1=${PS1//"$__ghostel_b"/}
    PS2=${PS2//"$__ghostel_p_secondary"/}
    PS2=${PS2//"$__ghostel_b"/}
    __ghostel_saved_ps1=$PS1
    __ghostel_saved_ps2=$PS2
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

    # Emit 133;A once per cycle (with cl=line for click-events and
    # redraw=last so libghostty knows the prompt-redraw boundary).
    # `aid=$BASHPID' tags this prompt with the current shell PID.
    printf '\e]133;A;redraw=last;cl=line;aid=%s\a' "${BASHPID:-}"

    __ghostel_in_prompt_command=0

    # Append the C hook to PS0 (self-healing if something overwrote
    # PS0), or arm the DEBUG-trap adapter on bash < 4.4.  The restore
    # funsub rides along only while `promptvars' is on: with it off,
    # bash still decodes PS0 backslash escapes but prints the
    # `${ ...; }' text literally before every command.
    if [[ -z "$__ghostel_preexec_ps0" ]]; then
        __ghostel_preexec_armed=1
    else
        local __ghostel_ps0_hook=$__ghostel_preexec_ps0
        if [[ -n "$__ghostel_preexec_funsub" ]] && shopt -q promptvars; then
            __ghostel_ps0_hook+=$__ghostel_preexec_funsub
        fi
        if [[ "$__ghostel_ps0_hook" != "${__ghostel_installed_ps0:-}" ||
                  "${PS0:-}" != *"$__ghostel_ps0_hook"* ]]; then
            [[ -n "${__ghostel_installed_ps0:-}" ]] &&
                PS0=${PS0//"$__ghostel_installed_ps0"/}
            PS0=${PS0:-}$__ghostel_ps0_hook
            __ghostel_installed_ps0=$__ghostel_ps0_hook
        fi
    fi
}

# Restore $? for a hook about to run: `return N' makes N the visible
# exit status of the next command.
__ghostel_set_status() { return "${1:-0}"; }

# Preserve any existing PROMPT_COMMAND — scalar, or bash-5.1+ array as
# populated by e.g. systemd's osc-context profile.d script.  Capture
# every element, then unset (dropping array-ness) so the wrapper is
# the sole element and sees the user command's $?.
__ghostel_original_prompt_commands=()
[[ -n "${PROMPT_COMMAND[*]:-}" ]] &&
    __ghostel_original_prompt_commands=("${PROMPT_COMMAND[@]}")
builtin unset PROMPT_COMMAND
PROMPT_COMMAND="__ghostel_wrapped_prompt_command"

if [[ -n $__ghostel_bash44 ]]; then
    # C as literal prompt text: PS0 backslash escapes are decoded
    # even with `promptvars' off, and a literal needs no per-command
    # fork.
    __ghostel_preexec_ps0='\e]133;C\a'
    __ghostel_preexec_funsub=""
    if ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))); then
        # Function substitution (bash 5.3+) runs in the current
        # shell, so the pre-command prompt restore takes effect.  On
        # older bash the restore is skipped: the running command sees
        # the marked PS1, and the next prompt cycle strips the
        # markers back out.  Joined onto PS0 per prompt cycle while
        # `promptvars' is on (see `__ghostel_wrapped_prompt_command').
        __ghostel_preexec_funsub='${ __ghostel_restore_prompt; }'
    fi
else
    __ghostel_preexec_ps0=""
    __ghostel_preexec_funsub=""
    trap '__ghostel_debug_preexec' DEBUG
fi
__ghostel_installed_ps0=""

# Outbound `ssh' with ghostel's shell integration and xterm-ghostty
# terminfo on the remote, for this session only.
# Usage: ghostel_ssh [SSH-ARGS...]  (also `ghostel ssh').
#
# On first contact with a host one setup connection pushes etc/shell
# and etc/terminfo to ~/.local/share/ghostel on the remote (mirroring
# the repo layout) and copies the terminfo into ~/.terminfo; the
# outcome is cached under $XDG_CACHE_HOME/ghostel/ssh-terminfo-cache,
# keyed by target and a hash of the pushed files so a ghostel update
# re-pushes.  The real connection then starts the remote login shell
# through etc/shell/remote/login.sh, which injects the integration the
# way a local spawn does.  No rc file on the remote is touched; see
# ghostel_ssh_install for that.  A failed push caches a skip marker
# and falls back to plain ssh with TERM=xterm-256color.  INSIDE_EMACS
# is offered via SendEnv so a remote whose sshd accepts it can gate on
# that instead of TERM.
#
# Pass-through (plain ssh, nothing pushed): no host (`ssh -V'), a
# remote command (`ssh HOST cmd'; the cached TERM still applies), and
# the -G/-N/-O/-s/-W modes.  Prefix with GHOSTEL_SSH_KEEP_TERM=1 to
# bypass the wrapper entirely.
#
# When the elisp side sets `ghostel-ssh-install-terminfo' (exported as
# GHOSTEL_SSH_INSTALL_TERMINFO) plain `ssh' is shadowed by this function.

# __ghostel_ssh_push INSTALL-ARGS SSH-ARGS...: tar etc/shell and
# etc/terminfo into ~/.local/share/ghostel on the remote and run
# etc/shell/remote/install.sh INSTALL-ARGS there.  Stdin is the tar
# stream, so this is never the interactive connection.
function __ghostel_ssh_push {
    local _install_args=$1
    shift
    COPYFILE_DISABLE=1 builtin command tar c --format ustar -f - \
            -C "$EMACS_GHOSTEL_PATH" etc/shell etc/terminfo \
        | builtin command ssh -o SendEnv=INSIDE_EMACS "$@" "sh -c 'mkdir -p ~/.local/share/ghostel && tar xf - -C ~/.local/share/ghostel && sh ~/.local/share/ghostel/etc/shell/remote/install.sh $_install_args'"
}

# Hash of everything __ghostel_ssh_push ships.
function __ghostel_ssh_hash {
    builtin command find "$EMACS_GHOSTEL_PATH/etc/shell" "$EMACS_GHOSTEL_PATH/etc/terminfo" -type f -exec cksum {} + \
        | LC_ALL=C builtin command sort | builtin command cksum | builtin command awk '{print $1}'
}

function ghostel_ssh {
    if [[ -n "${GHOSTEL_SSH_KEEP_TERM:-}" ]] || [[ ! -t 0 ]] || \
           [[ ! -r "${EMACS_GHOSTEL_PATH:-}/etc/shell/remote/login.sh" ]]; then
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

    # Count positionals (host + remote command) and spot modes that
    # open no login session.  Valued flags skip their argument.
    local _positional=0 _skip=0 _plain=0 _arg
    for _arg in "$@"; do
        if (( _skip )); then _skip=0; continue; fi
        case "$_arg" in
            -G|-N|-s|-W*|-O*) _plain=1 ;;
            -[bBcDEeFIiJLlmoPpQRSw]) _skip=1 ;;
            -*) ;;
            *) ((_positional++)) ;;
        esac
    done
    if (( _plain )); then
        builtin command ssh "$@"
        return
    fi

    local _target="$_user@$_host:$_port"
    local _hash
    _hash=$(__ghostel_ssh_hash)
    local _cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ghostel"
    local _cache="$_cache_dir/ssh-terminfo-cache"
    local _key="$_target:$_hash"
    local _state=""
    if [[ -r $_cache ]]; then
        if builtin command grep -Fxq "$_key ok" "$_cache" 2>/dev/null; then
            _state=ok
        elif builtin command grep -Fxq "$_key skip" "$_cache" 2>/dev/null; then
            _state=skip
        fi
    fi

    # A remote command runs plainly with the cached TERM: pushing files
    # first would delay it on every new host.
    if (( _positional > 1 )); then
        if [[ $_state == ok ]]; then
            TERM=xterm-ghostty builtin command ssh -o SendEnv=INSIDE_EMACS "$@"
        else
            TERM=xterm-256color builtin command ssh -o SendEnv=INSIDE_EMACS "$@"
        fi
        return
    fi

    if [[ -z $_state ]]; then
        builtin command mkdir -p "$_cache_dir" 2>/dev/null
        if __ghostel_ssh_push "" "$@" >/dev/null 2>&1; then
            _state=ok
        else
            builtin echo "ghostel: could not push shell integration to $_host \
(no tar on the remote, or home not writable?), using plain ssh with xterm-256color." >&2
            _state=skip
        fi
        builtin echo "$_key $_state" >> "$_cache"
    fi

    if [[ $_state == ok ]]; then
        # Falls back to a plain login shell when the pushed files are
        # gone (rebuilt host) so a stale ok entry never locks you out.
        local _login='f=~/.local/share/ghostel/etc/shell/remote/login.sh; [ -r "$f" ] && exec sh "$f"; echo "ghostel: $f missing on this host, run M-x ghostel-ssh-clear-terminfo-cache to push again" >&2; exec "${SHELL:-sh}" -l'
        TERM=xterm-ghostty builtin command ssh -t -o SendEnv=INSIDE_EMACS "$@" "sh -c '$_login'"
    else
        TERM=xterm-256color builtin command ssh -o SendEnv=INSIDE_EMACS "$@"
    fi
}

# `function NAME { … }' rather than `NAME() { … }' so a user alias
# on `ssh' (aliases expand at parse time in zsh, and bash when the
# alias is already active while sourcing this file) can't turn the
# definition into a parse error.
if [[ -n "${GHOSTEL_SSH_INSTALL_TERMINFO:-}" ]]; then
    function ssh { ghostel_ssh "$@"; }
fi

# Install ghostel's shell integration and xterm-ghostty terminfo on a
# remote host, permanently: the same push as ghostel_ssh, plus a hook
# in the login shell's startup (see etc/shell/remote/install.sh) so a
# plain `ssh HOST' loads the integration.
# Usage: ghostel_ssh_install [SSH-OPTIONS] HOST  (also `ghostel ssh-install').
function ghostel_ssh_install {
    if [[ ! -r "${EMACS_GHOSTEL_PATH:-}/etc/shell/remote/install.sh" ]]; then
        builtin echo "ghostel: EMACS_GHOSTEL_PATH does not point at a ghostel install" >&2
        return 1
    fi
    __ghostel_ssh_push --hook "$@" || return
    # Drop the ghostel_ssh cache: a remembered `skip' for this host would
    # otherwise keep hiding the files just installed.
    builtin command rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/ghostel/ssh-terminfo-cache"
}

# Subcommand front end: `ghostel cmd|ssh|ssh-install|help ...'.
ghostel() {
    local _sub=${1-help}
    [[ $# -gt 0 ]] && shift
    case "$_sub" in
        cmd) ghostel_cmd "$@" ;;
        ssh) ghostel_ssh "$@" ;;
        ssh-install) ghostel_ssh_install "$@" ;;
        help|-h|--help)
            builtin printf '%s\n' \
                'Usage: ghostel cmd FUNCTION [ARGS...]       call an Emacs function (see ghostel-eval-cmds)' \
                '       ghostel ssh [SSH-ARGS...]            ssh with xterm-ghostty terminfo on the remote' \
                '       ghostel ssh-install [SSH-OPTS] HOST  install shell integration + terminfo on HOST'
            ;;
        *)
            builtin echo "ghostel: unknown subcommand '$_sub'" >&2
            ghostel help >&2
            return 2
            ;;
    esac
}

# Call an Emacs Elisp function from the shell.
# Usage: ghostel_cmd FUNCTION [ARGS...]
# The function must be in `ghostel-eval-cmds'.
ghostel_cmd() {
    local payload=""
    while [ $# -gt 0 ]; do
        payload="$payload\"$(printf '%s' "$1" | sed -e 's|\\|\\\\|g' -e 's|"|\\"|g')\" "
        shift
    done
    printf '\e]52;e;%s\e\\' "$payload"
}
