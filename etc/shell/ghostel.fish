# Ghostel shell integration for fish
# Source this from your config.fish.
#
# Local `config.fish' (anchored regex — TRAMP appends `,tramp:VER'):
#   string match -qr '^ghostel(,|$)' -- "$INSIDE_EMACS"; and source /path/to/ghostel/etc/shell/ghostel.fish
#
# Remote `config.fish' (also gates on TERM, since ssh propagates it
# natively and INSIDE_EMACS does not without server-side AcceptEnv):
#   if string match -qr '^ghostel(,|$)' -- "$INSIDE_EMACS"; or test "$TERM" = 'xterm-ghostty'
#       source ~/.local/share/ghostel/etc/shell/ghostel.fish
#   end
# See the README "Manual setup" section for the full rationale.

# Idempotency guard — skip if already loaded (e.g. auto-injected).
functions -q __ghostel_osc7; and return

# Report working directory to the terminal via OSC 7.
# In fish 3.0+, $hostname is gethostname(2) verbatim, matching
# Emacs `system-name'. The local-host check needs exactly this,
# not an FQDN-canonicalized value like zsh's $HOST.
# The path is percent-encoded (string escape --style=url, fish 2.7+)
# so `#', `?', and `%' survive the file:// URI parse.
function __ghostel_osc7 --on-event fish_prompt
    printf '\e]7;file://%s%s\a' "$hostname" (string escape --style=url "$PWD")
end

# --- Semantic prompt markers (OSC 133) ---
#
# fish 4.0+ with the `mark-prompt' feature flag enabled (the
# default) emits OSC 133 natively (A/C/D; B since 4.3; C carries the
# URL-encoded command line) — defining handlers there would double
# every marker.  The handlers below cover the rest: fish < 4 (the
# flag is unknown there) and fish 4+ with native marking disabled
# (`set -Ua fish_features no-mark-prompt').
#
# The handlers mirror ghostty's:
#   - 133;A on `fish_prompt' (start of prompt).
#   - 133;C on `fish_preexec' (start of command output).
#   - 133;D on `fish_postexec' (end of command).
#
# Note: no 133;B — fish has no "after fish_prompt" event, and ghostty
# does without it.  Cells from 133;A to 133;C carry the `prompt'
# semantic state in libghostty, which the link-skip logic treats the
# same as `input' for skip purposes.
if not status test-feature mark-prompt 2>/dev/null
    set -g __ghostel_prompt_state ""

    # Emit "command finished" (D) for the previous command, then
    # "prompt start" (A) for the new prompt.
    function __ghostel_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
        # Close a section whose command never reached fish_postexec
        # (e.g. cancelled): C was emitted but its D was not.  A wider
        # guard would re-emit D after every normal command, firing
        # `ghostel-command-finish-functions' twice per cycle.
        if test "$__ghostel_prompt_state" = "pre-exec"
            printf '\e]133;D\a'
        end
        set -g __ghostel_prompt_state prompt-start
        printf '\e]133;A\a'
    end

    # Emit "command output start" (C) before command runs.
    function __ghostel_mark_output_start --on-event fish_preexec
        set -g __ghostel_prompt_state pre-exec
        printf '\e]133;C\a'
    end

    # Emit "command finished" (D) with exit status after command runs.
    function __ghostel_mark_output_end --on-event fish_postexec
        set -g __ghostel_prompt_state post-exec
        printf '\e]133;D;%s\a' $status
    end
end

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
function __ghostel_ssh_push
    set -l _install_args $argv[1]
    set -e argv[1]
    COPYFILE_DISABLE=1 command tar c --format ustar -f - \
            -C "$EMACS_GHOSTEL_PATH" etc/shell etc/terminfo \
        | command ssh -o SendEnv=INSIDE_EMACS $argv "sh -c 'mkdir -p ~/.local/share/ghostel && tar xf - -C ~/.local/share/ghostel && sh ~/.local/share/ghostel/etc/shell/remote/install.sh $_install_args'"
end

# Hash of everything __ghostel_ssh_push ships.
function __ghostel_ssh_hash
    command find "$EMACS_GHOSTEL_PATH/etc/shell" "$EMACS_GHOSTEL_PATH/etc/terminfo" -type f -exec cksum '{}' + \
        | LC_ALL=C command sort | command cksum | command awk '{print $1}'
end

function ghostel_ssh
    if test -n "$GHOSTEL_SSH_KEEP_TERM"; or not isatty stdin; or not test -r "$EMACS_GHOSTEL_PATH/etc/shell/remote/login.sh"
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

    # Count positionals (host + remote command) and spot modes that
    # open no login session.  Valued flags skip their argument.
    set -l _positional 0
    set -l _skip 0
    set -l _plain 0
    for _arg in $argv
        if test $_skip -eq 1
            set _skip 0
            continue
        end
        switch $_arg
            case '-G' '-N' '-s' '-W*' '-O*'
                set _plain 1
            case '-b' '-B' '-c' '-D' '-E' '-e' '-F' '-I' '-i' '-J' '-L' '-l' '-m' '-o' '-P' '-p' '-Q' '-R' '-S' '-w'
                set _skip 1
            case '-*'
            case '*'
                set _positional (math $_positional + 1)
        end
    end
    if test $_plain -eq 1
        command ssh $argv
        return
    end

    set -l _target "$_user@$_host:$_port"
    set -l _hash (__ghostel_ssh_hash)
    set -l _cache_dir (test -n "$XDG_CACHE_HOME"; and echo "$XDG_CACHE_HOME/ghostel"; or echo "$HOME/.cache/ghostel")
    set -l _cache "$_cache_dir/ssh-terminfo-cache"
    set -l _key "$_target:$_hash"
    set -l _state ""
    if test -r "$_cache"
        if grep -Fxq "$_key ok" "$_cache" 2>/dev/null
            set _state ok
        else if grep -Fxq "$_key skip" "$_cache" 2>/dev/null
            set _state skip
        end
    end

    # A remote command runs plainly with the cached TERM.
    if test $_positional -gt 1
        if test "$_state" = ok
            TERM=xterm-ghostty command ssh -o SendEnv=INSIDE_EMACS $argv
        else
            TERM=xterm-256color command ssh -o SendEnv=INSIDE_EMACS $argv
        end
        return
    end

    if test -z "$_state"
        command mkdir -p "$_cache_dir" 2>/dev/null
        if __ghostel_ssh_push "" $argv >/dev/null 2>&1
            set _state ok
        else
            echo "ghostel: could not push shell integration to $_host (no tar on the remote, or home not writable?), using plain ssh with xterm-256color." >&2
            set _state skip
        end
        echo "$_key $_state" >> "$_cache"
    end

    if test "$_state" = ok
        # Falls back to a plain login shell when the pushed files are
        # gone (rebuilt host) so a stale ok entry never locks you out.
        set -l _login 'f=~/.local/share/ghostel/etc/shell/remote/login.sh; [ -r "$f" ] && exec sh "$f"; echo "ghostel: $f missing on this host, run M-x ghostel-ssh-clear-terminfo-cache to push again" >&2; exec "${SHELL:-sh}" -l'
        TERM=xterm-ghostty command ssh -t -o SendEnv=INSIDE_EMACS $argv "sh -c '$_login'"
    else
        TERM=xterm-256color command ssh -o SendEnv=INSIDE_EMACS $argv
    end
end

if test -n "$GHOSTEL_SSH_INSTALL_TERMINFO"
    function ssh
        ghostel_ssh $argv
    end
end

# Install ghostel's shell integration and xterm-ghostty terminfo on a
# remote host, permanently: the same push as ghostel_ssh, plus a hook
# in the login shell's startup (see etc/shell/remote/install.sh) so a
# plain `ssh HOST' loads the integration.
# Usage: ghostel_ssh_install [SSH-OPTIONS] HOST  (also `ghostel ssh-install').
function ghostel_ssh_install
    if not test -r "$EMACS_GHOSTEL_PATH/etc/shell/remote/install.sh"
        echo "ghostel: EMACS_GHOSTEL_PATH does not point at a ghostel install" >&2
        return 1
    end
    __ghostel_ssh_push --hook $argv
    or return
    # Drop the ghostel_ssh cache: a remembered `skip' for this host would
    # otherwise keep hiding the files just installed.
    set -l _cache_dir (test -n "$XDG_CACHE_HOME"; and echo "$XDG_CACHE_HOME/ghostel"; or echo "$HOME/.cache/ghostel")
    command rm -f "$_cache_dir/ssh-terminfo-cache"
end

# Subcommand front end: `ghostel cmd|ssh|ssh-install|help ...'.
function ghostel
    set -l _sub $argv[1]
    set -l _rest $argv[2..-1]
    switch "$_sub"
        case cmd
            ghostel_cmd $_rest
        case ssh
            ghostel_ssh $_rest
        case ssh-install
            ghostel_ssh_install $_rest
        case '' help -h --help
            printf '%s\n' \
                'Usage: ghostel cmd FUNCTION [ARGS...]       call an Emacs function (see ghostel-eval-cmds)' \
                '       ghostel ssh [SSH-ARGS...]            ssh with xterm-ghostty terminfo on the remote' \
                '       ghostel ssh-install [SSH-OPTS] HOST  install shell integration + terminfo on HOST'
        case '*'
            echo "ghostel: unknown subcommand '$_sub'" >&2
            ghostel help >&2
            return 2
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
    printf '\e]52;e;%s\e\\' "$payload"
end
