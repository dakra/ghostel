# Ghostel shell integration for fish
# Source this from your config.fish.
#
# Local `config.fish' (anchored regex — TRAMP appends `,tramp:VER'):
#   string match -qr '^ghostel(,|$)' -- "$INSIDE_EMACS"; and source /path/to/ghostel/etc/shell/ghostel.fish
#
# Remote `config.fish' (also gates on TERM, since ssh propagates it
# natively and INSIDE_EMACS does not without server-side AcceptEnv):
#   if string match -qr '^ghostel(,|$)' -- "$INSIDE_EMACS"; or test "$TERM" = 'xterm-ghostty'
#       source ~/.local/share/ghostel/ghostel.fish
#   end
# See the README "Manual setup" section for the full rationale.

# Idempotency guard — skip if already loaded (e.g. auto-injected).
functions -q __ghostel_osc7; and return

# Emit an OSC sequence with the given body (the part between `\e]' and
# the ST `\e\\').  Inside tmux, wrap the OSC in DCS-passthrough so tmux
# forwards the body to the outer terminal — requires `set -g
# allow-passthrough on' in tmux.conf (tmux 3.3+).
function __ghostel_emit_osc
    if set -q TMUX
        # Fish single-quote eats `\\' (escape) so printf-format `\\' must
        # be written `\\\\' here.  `\e' passes through to printf as-is.
        printf '\ePtmux;\e\e]%s\e\e\\\\\e\\\\' "$argv[1]"
    else
        printf '\e]%s\e\\\\' "$argv[1]"
    end
end

# Report working directory to the terminal via OSC 7
function __ghostel_osc7 --on-event fish_prompt
    __ghostel_emit_osc "7;file://"(hostname)"$PWD"
end

# --- Semantic prompt markers (OSC 133) ---

set -g __ghostel_prompt_shown 0

function __ghostel_postexec --on-event fish_postexec
    set -g __ghostel_last_status $status
end

# Emit "command finished" (D) + "prompt start" (A) before the prompt.
function __ghostel_prompt_start --on-event fish_prompt
    if test "$__ghostel_prompt_shown" = 1
        __ghostel_emit_osc "133;D;$__ghostel_last_status"
    end
    __ghostel_emit_osc "133;A"
end

# Emit "prompt end / command start" (B) after the prompt.
function __ghostel_prompt_end --on-event fish_prompt
    __ghostel_emit_osc "133;B"
    set -g __ghostel_prompt_shown 1
end

# Emit "command output start" (C) before command runs.
function __ghostel_preexec --on-event fish_preexec
    __ghostel_emit_osc "133;C"
end

# Outbound `ssh' wrapper.  See etc/ghostel.bash for the full design
# notes — this is the fish port of the same install-and-cache logic.
if test -n "$GHOSTEL_SSH_INSTALL_TERMINFO"
    function ssh
        if test -n "$GHOSTEL_SSH_KEEP_TERM"; or not command -q infocmp
            command ssh $argv
            return
        end

        set -l _user ""
        set -l _host ""
        set -l _port ""
        for line in (command ssh -G $argv 2>/dev/null)
            set -l parts (string split -m 1 ' ' -- $line)
            switch $parts[1]
                case user
                    set _user $parts[2]
                case hostname
                    set _host $parts[2]
                case port
                    set _port $parts[2]
            end
            if test -n "$_user"; and test -n "$_host"; and test -n "$_port"
                break
            end
        end

        if test -z "$_host"
            command ssh $argv
            return
        end

        set -l _target "$_user@$_host:$_port"
        set -l _hash (infocmp -0 -x xterm-ghostty 2>/dev/null | cksum 2>/dev/null | awk '{print $1}')
        set -l _cache_dir (test -n "$XDG_CACHE_HOME"; and echo "$XDG_CACHE_HOME/ghostel"; or echo "$HOME/.cache/ghostel")
        set -l _cache "$_cache_dir/ssh-terminfo-cache"
        set -l _key "$_target:$_hash"

        if test -r "$_cache"
            if grep -Fxq "$_key ok" "$_cache" 2>/dev/null
                TERM=xterm-ghostty command ssh $argv
                return
            end
            if grep -Fxq "$_key skip" "$_cache" 2>/dev/null
                TERM=xterm-256color command ssh $argv
                return
            end
        end

        # Skip install when user passed a remote command.
        set -l _positional 0
        set -l _skip 0
        for _arg in $argv
            if test $_skip -eq 1
                set _skip 0
                continue
            end
            switch $_arg
                case '-b' '-c' '-D' '-E' '-e' '-F' '-I' '-i' '-J' '-L' '-l' '-m' '-O' '-o' '-P' '-p' '-Q' '-R' '-S' '-W' '-w'
                    set _skip 1
                case '-*'
                case '*'
                    set _positional (math $_positional + 1)
            end
        end

        if test $_positional -gt 1
            TERM=xterm-256color command ssh $argv
            return
        end

        command mkdir -p "$_cache_dir" 2>/dev/null
        # Lock keyed on (target, hash) — see etc/ghostel.bash.
        set -l _lock "$_cache_dir/.lock.$_target.$_hash"
        if not command mkdir "$_lock" 2>/dev/null
            TERM=xterm-256color command ssh $argv
            return
        end
        if infocmp -0 -x xterm-ghostty 2>/dev/null \
                | command ssh $argv '
                    infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                    command -v tic >/dev/null 2>&1 || exit 1
                    mkdir -p "$HOME/.terminfo" && tic -x - >/dev/null 2>&1
                  ' >/dev/null 2>&1
            echo "$_key ok" >> "$_cache"
            command rmdir "$_lock" 2>/dev/null
            TERM=xterm-ghostty command ssh $argv
        else
            echo "ghostel: failed to install xterm-ghostty terminfo on $_host (no \`tic' on remote?), using xterm-256color." >&2
            echo "$_key skip" >> "$_cache"
            command rmdir "$_lock" 2>/dev/null
            TERM=xterm-256color command ssh $argv
        end
    end
end

# Call an Emacs Elisp function from the shell.
# Usage: ghostel_cmd FUNCTION [ARGS...]
# The function must be in `ghostel-eval-cmds'.
function ghostel_cmd
    set -l payload ""
    for arg in $argv
        set arg (string replace -a '\\' '\\\\' -- $arg)
        set arg (string replace -a '"' '\\"' -- $arg)
        set payload "$payload\"$arg\" "
    end
    __ghostel_emit_osc "51;E$payload"
end
