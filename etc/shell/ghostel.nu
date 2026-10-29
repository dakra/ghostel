# Ghostel shell integration for nushell
# Source this from your `config.nu'.
#
# Local `config.nu' (nushell `source' needs a parse-time-constant path,
# so use an absolute path — the file is inert until `ghostel_cmd' is
# called or `ssh' is wrapped, so an unconditional source is fine):
#   source /path/to/ghostel/etc/shell/ghostel.nu
#
# Remote `config.nu' (over ssh), pointing at the installed copy:
#   source ~/.local/share/ghostel/etc/shell/ghostel.nu
# See the README "Manual setup" section for the full rationale.
#
# Unlike the bash/zsh/fish integrations, this file does NOT emit OSC 7
# (cwd) or OSC 133 (semantic prompt marks) itself.  Nushell reports
# those natively via `$env.config.shell_integration' (osc2/osc7/osc133,
# all on by default) and derives OSC 7's host from gethostname(2) — so
# it already matches Emacs `(system-name)' the way our bash/zsh
# capture-once logic does, without the $HOSTNAME pollution worry.  We
# only add the ghostel-specific pieces: the `ghostel_cmd' elisp bridge
# and the outbound `ssh' terminfo-install wrapper.
#
# No idempotency guard is needed: this file only (re)defines commands
# and never appends to hooks or the prompt, so sourcing it more than
# once is harmless.  (Do not disable `$env.config.shell_integration.osc7'
# or `.osc133' in your config or directory tracking and prompt
# navigation will stop working inside ghostel.)

# Call an Emacs Elisp function from the shell.
# Usage: ghostel_cmd FUNCTION [ARGS...]
# The function must be in `ghostel-eval-cmds'.
def ghostel_cmd [...args] {
    mut payload = ""
    for arg in $args {
        let a = ($arg
                 | str replace --all "\\" "\\\\"
                 | str replace --all "\"" "\\\"")
        $payload = $payload + "\"" + $a + "\" "
    }
    print -n $"\u{1b}]52;e;($payload)\u{1b}\\"
}

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
def __ghostel_ssh_push [install_args: string, ...args] {
    with-env {COPYFILE_DISABLE: "1"} {
        ^tar c --format ustar -f - -C $env.EMACS_GHOSTEL_PATH etc/shell etc/terminfo
            | ^ssh -o SendEnv=INSIDE_EMACS ...$args $"sh -c 'mkdir -p ~/.local/share/ghostel && tar xf - -C ~/.local/share/ghostel && sh ~/.local/share/ghostel/etc/shell/remote/install.sh ($install_args)'"
    }
}

# Hash of everything __ghostel_ssh_push ships.
def __ghostel_ssh_hash [] {
    let etc = $"($env.EMACS_GHOSTEL_PATH)/etc"
    with-env {LC_ALL: "C"} {
        (do { ^find $"($etc)/shell" $"($etc)/terminfo" -type f -exec cksum '{}' + | ^sort | ^cksum } | complete).stdout
            | split row " " | first | str trim
    }
}

def --wrapped ghostel_ssh [...args] {
    let login = $"($env.EMACS_GHOSTEL_PATH? | default '')/etc/shell/remote/login.sh"
    if ((not ($env.GHOSTEL_SSH_KEEP_TERM? | is-empty)) or (not ($login | path exists))) {
        ^ssh ...$args
        return
    }

    # Resolve the canonical target (normalises ssh_config aliases).
    mut user = ""
    mut host = ""
    mut port = ""
    let cfg = (do { ^ssh -G ...$args } | complete)
    for line in ($cfg.stdout | lines) {
        let parts = ($line | split row " ")
        if ($parts | length) < 2 { continue }
        let k = ($parts | first)
        let v = ($parts | get 1)
        if $k == "user" { $user = $v }
        if $k == "hostname" { $host = $v }
        if $k == "port" { $port = $v }
        if ($user != "" and $host != "" and $port != "") { break }
    }

    # No host (e.g. `ssh -V`, `ssh -h`): pass through.
    if ($host == "") {
        ^ssh ...$args
        return
    }

    # Count positionals (host + remote command) and spot modes that
    # open no login session.  Valued flags skip their argument.
    mut positional = 0
    mut skip = false
    mut plain = false
    for arg in $args {
        if $skip {
            $skip = false
            continue
        }
        if ($arg in ["-G" "-N" "-s"]) or ($arg | str starts-with "-W") or ($arg | str starts-with "-O") {
            $plain = true
        } else if ($arg in ["-b" "-B" "-c" "-D" "-E" "-e" "-F" "-I" "-i" "-J" "-L" "-l" "-m" "-o" "-P" "-p" "-Q" "-R" "-S" "-w"]) {
            $skip = true
        } else if ($arg | str starts-with "-") {
            # flag without an argument
        } else {
            $positional = $positional + 1
        }
    }
    if $plain {
        ^ssh ...$args
        return
    }

    let target = $"($user)@($host):($port)"
    let hash = (__ghostel_ssh_hash)
    let cache_dir = (if ($env.XDG_CACHE_HOME? | is-empty) {
        $"($env.HOME)/.cache/ghostel"
    } else {
        $"($env.XDG_CACHE_HOME)/ghostel"
    })
    let cache = ($cache_dir | path join "ssh-terminfo-cache")
    let key = $"($target):($hash)"
    mut state = ""
    if ($cache | path exists) {
        let entries = (open $cache | lines)
        if ($"($key) ok" in $entries) {
            $state = "ok"
        } else if ($"($key) skip" in $entries) {
            $state = "skip"
        }
    }

    # A remote command runs plainly with the cached TERM.
    if ($positional > 1) {
        if $state == "ok" {
            with-env {TERM: "xterm-ghostty"} { ^ssh -o SendEnv=INSIDE_EMACS ...$args }
        } else {
            with-env {TERM: "xterm-256color"} { ^ssh -o SendEnv=INSIDE_EMACS ...$args }
        }
        return
    }

    if $state == "" {
        mkdir $cache_dir
        let res = (do { __ghostel_ssh_push "" ...$args } | complete)
        if ($res.exit_code == 0) {
            $state = "ok"
        } else {
            print -e $"ghostel: could not push shell integration to ($host) \(no tar on the remote, or home not writable?\), using plain ssh with xterm-256color."
            $state = "skip"
        }
        $"($key) ($state)\n" | save --append $cache
    }

    if $state == "ok" {
        # Falls back to a plain login shell when the pushed files are
        # gone (rebuilt host) so a stale ok entry never locks you out.
        let login_cmd = 'f=~/.local/share/ghostel/etc/shell/remote/login.sh; [ -r "$f" ] && exec sh "$f"; echo "ghostel: $f missing on this host, run M-x ghostel-ssh-clear-terminfo-cache to push again" >&2; exec "${SHELL:-sh}" -l'
        with-env {TERM: "xterm-ghostty"} { ^ssh -t -o SendEnv=INSIDE_EMACS ...$args $"sh -c '($login_cmd)'" }
    } else {
        with-env {TERM: "xterm-256color"} { ^ssh -o SendEnv=INSIDE_EMACS ...$args }
    }
}

# Shadow `ssh' when the elisp side sets `ghostel-ssh-install-terminfo'
# (exported as GHOSTEL_SSH_INSTALL_TERMINFO).  Always defined and gated
# at runtime: nushell `def' cannot be conditionally defined by a
# runtime env var.
def --wrapped ssh [...args] {
    if ($env.GHOSTEL_SSH_INSTALL_TERMINFO? | is-empty) {
        ^ssh ...$args
    } else {
        ghostel_ssh ...$args
    }
}

# Install ghostel's shell integration and xterm-ghostty terminfo on a
# remote host, permanently: the same push as ghostel_ssh, plus a hook
# in the login shell's startup (see etc/shell/remote/install.sh) so a
# plain `ssh HOST' loads the integration.
# Usage: ghostel_ssh_install [SSH-OPTIONS] HOST  (also `ghostel ssh-install').
def --wrapped ghostel_ssh_install [...args] {
    let install = $"($env.EMACS_GHOSTEL_PATH? | default '')/etc/shell/remote/install.sh"
    if not ($install | path exists) {
        error make { msg: "ghostel: EMACS_GHOSTEL_PATH does not point at a ghostel install" }
    }
    __ghostel_ssh_push "--hook" ...$args
    # Drop the ghostel_ssh cache: a remembered `skip' for this host would
    # otherwise keep hiding the files just installed.
    let cache_dir = (if ($env.XDG_CACHE_HOME? | is-empty) {
        $"($env.HOME)/.cache/ghostel"
    } else {
        $"($env.XDG_CACHE_HOME)/ghostel"
    })
    rm -f ($cache_dir | path join "ssh-terminfo-cache")
}

# Subcommand front end: `ghostel cmd|ssh|ssh-install ...'.
def ghostel [] {
    print 'Usage: ghostel cmd FUNCTION [ARGS...]       call an Emacs function (see ghostel-eval-cmds)
       ghostel ssh [SSH-ARGS...]            ssh with xterm-ghostty terminfo on the remote
       ghostel ssh-install [SSH-OPTS] HOST  install shell integration + terminfo on HOST'
}
def --wrapped "ghostel cmd" [...args] { ghostel_cmd ...$args }
def --wrapped "ghostel ssh" [...args] { ghostel_ssh ...$args }
def --wrapped "ghostel ssh-install" [...args] { ghostel_ssh_install ...$args }
def "ghostel help" [] { ghostel }
