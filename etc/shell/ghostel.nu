# Ghostel shell integration for nushell
# Source this from your `config.nu'.
#
# Local `config.nu' (nushell `source' needs a parse-time-constant path,
# so use an absolute path — the file is inert until `ghostel_cmd' is
# called or `ssh' is wrapped, so an unconditional source is fine):
#   source /path/to/ghostel/etc/shell/ghostel.nu
#
# Remote `config.nu' (over ssh), pointing at the installed copy:
#   source ~/.local/share/ghostel/shell/ghostel.nu
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

# Outbound `ssh' with xterm-ghostty terminfo on the remote.  See
# etc/shell/ghostel.bash for the design notes — this is the nushell
# port.  Per-call escape hatch: prefix with GHOSTEL_SSH_KEEP_TERM=1.
def --wrapped ghostel_ssh [...args] {
    # Escape hatch, or no local infocmp: pass through.
    if ((not ($env.GHOSTEL_SSH_KEEP_TERM? | is-empty))
        or (which infocmp | is-empty)) {
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
    let args = [-o SendEnv=INSIDE_EMACS] ++ $args

    let target = $"($user)@($host):($port)"
    let hash = ((do { ^infocmp -0 -x xterm-ghostty | ^cksum } | complete).stdout
                | split row " " | first | str trim)
    let cache_dir = (if ($env.XDG_CACHE_HOME? | is-empty) {
        $"($env.HOME)/.cache/ghostel"
    } else {
        $"($env.XDG_CACHE_HOME)/ghostel"
    })
    let cache = ($cache_dir | path join "ssh-terminfo-cache")
    let key = $"($target):($hash)"

    # Cache hit?
    if ($cache | path exists) {
        let entries = (open $cache | lines)
        if ($"($key) ok" in $entries) {
            with-env {TERM: "xterm-ghostty"} { ^ssh ...$args }
            return
        }
        if ($"($key) skip" in $entries) {
            with-env {TERM: "xterm-256color"} { ^ssh ...$args }
            return
        }
    }

    # Skip install when the user passed a remote command — combining our
    # install script with their command via the same ssh invocation is
    # fragile.  The next interactive `ssh HOST' will trigger install.
    mut positional = 0
    mut skip = false
    for arg in $args {
        if $skip {
            $skip = false
            continue
        }
        if ($arg in ["-b" "-c" "-D" "-E" "-e" "-F" "-I" "-i" "-J" "-L" "-l" "-m" "-O" "-o" "-P" "-p" "-Q" "-R" "-S" "-W" "-w"]) {
            $skip = true
        } else if ($arg | str starts-with "-") {
            # flag without an argument
        } else {
            $positional = $positional + 1
        }
    }
    if ($positional > 1) {
        with-env {TERM: "xterm-256color"} { ^ssh ...$args }
        return
    }

    # Combined probe + install in a single setup ssh invocation.
    # Mkdir-as-lock (external `mkdir' fails if the dir exists) so
    # concurrent first-time `ssh HOST' from two ghostel buffers don't
    # both spawn a setup connection.  Lock keyed on (target, hash) so
    # different targets run in parallel.
    mkdir $cache_dir
    let lock = ($cache_dir | path join $".lock.($target).($hash)")
    if ((do { ^mkdir $lock } | complete).exit_code != 0) {
        with-env {TERM: "xterm-256color"} { ^ssh ...$args }
        return
    }
    # Wrapped in `sh -c': the remote login shell parses the command.
    let install = "sh -c 'infocmp xterm-ghostty >/dev/null 2>&1 && exit 0; command -v tic >/dev/null 2>&1 || exit 1; mkdir -p \"$HOME/.terminfo\" && tic -x - >/dev/null 2>&1'"
    let res = (do { ^infocmp -0 -x xterm-ghostty | ^ssh ...$args $install } | complete)
    if ($res.exit_code == 0) {
        $"($key) ok\n" | save --append $cache
        ^rmdir $lock
        with-env {TERM: "xterm-ghostty"} { ^ssh ...$args }
    } else {
        print -e $"ghostel: failed to install xterm-ghostty terminfo on ($host) \(no tic on remote?\), using xterm-256color."
        $"($key) skip\n" | save --append $cache
        ^rmdir $lock
        with-env {TERM: "xterm-256color"} { ^ssh ...$args }
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
# remote host, permanently: scripts + terminfo go to
# ~/.local/share/ghostel, terminfo is copied into ~/.terminfo, and the
# login shell's startup file is hooked (see etc/shell/remote-install.sh).
# Usage: ghostel_ssh_install [SSH-OPTIONS] HOST  (also `ghostel ssh-install').
def --wrapped ghostel_ssh_install [...args] {
    let etc = $"($env.EMACS_GHOSTEL_PATH? | default '')/etc"
    if not ($"($etc)/shell/remote-install.sh" | path exists) {
        error make { msg: "ghostel: EMACS_GHOSTEL_PATH does not point at a ghostel install" }
    }
    with-env {COPYFILE_DISABLE: "1"} { ^tar c --format ustar -f - -C $etc shell/ghostel.bash shell/ghostel.zsh shell/ghostel.fish shell/ghostel.nu shell/remote-install.sh terminfo
        | ^ssh -o SendEnv=INSIDE_EMACS ...$args "sh -c 'mkdir -p ~/.local/share/ghostel && tar xf - -C ~/.local/share/ghostel && sh ~/.local/share/ghostel/shell/remote-install.sh'" }
    # Drop the ghostel_ssh cache: a remembered `skip' for this host would
    # otherwise keep hiding the terminfo just installed.
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
