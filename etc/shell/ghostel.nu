# Ghostel shell integration for nushell
# Source this from your `config.nu'.
#
# Local `config.nu' (nushell `source' needs a parse-time-constant path,
# so use an absolute path — the file is inert until `ghostel_cmd' is
# called or `ssh' is wrapped, so an unconditional source is fine):
#   source /path/to/ghostel/etc/shell/ghostel.nu
#
# Remote `config.nu' (over ssh), pointing at the installed copy:
#   source ~/.local/share/ghostel/ghostel.nu
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

# Outbound `ssh' wrapper.  Activated when the elisp side sets
# `ghostel-ssh-install-terminfo' (which exports
# GHOSTEL_SSH_INSTALL_TERMINFO).  See etc/shell/ghostel.bash for the
# full design notes — this is the nushell port of the same
# install-and-cache logic: on first connection to a host it installs
# xterm-ghostty terminfo via `tic', caches the outcome under
# $XDG_CACHE_HOME/ghostel/ssh-terminfo-cache (key includes a hash of the
# local terminfo), and connects with TERM=xterm-ghostty.  Failures cache
# a skip marker and downgrade to xterm-256color.
#
# Always defined and gated at runtime (like ghostty's nushell wrapper):
# nushell `def' cannot be conditionally defined by a runtime env var.
# Per-call escape hatch: prefix with GHOSTEL_SSH_KEEP_TERM=1 to bypass.
def --wrapped ssh [...args] {
    # Feature off, escape hatch, or no local infocmp: pass through.
    if (($env.GHOSTEL_SSH_INSTALL_TERMINFO? | is-empty)
        or (not ($env.GHOSTEL_SSH_KEEP_TERM? | is-empty))
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
    let install = "infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
command -v tic >/dev/null 2>&1 || exit 1
mkdir -p \"$HOME/.terminfo\" && tic -x - >/dev/null 2>&1"
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

# Auto-inject `-CC' for `tmux new'/`tmux attach' so tmux runs in
# control mode and ghostel-tmux's auto-detection takes over.  Always
# defined and gated at runtime (like the `ssh' wrapper above: nushell
# `def' cannot be conditionally defined by a runtime env var).  Bypass
# at any time with `^tmux ...' or by setting GHOSTEL_TMUX_NO_CC.
def --wrapped tmux [...args] {
    # Wrapper disabled, or the user already passed -C/-CC: run as-is.
    if ((not ($env.GHOSTEL_TMUX_NO_CC? | is-empty))
        or ("-C" in $args) or ("-CC" in $args)) {
        ^tmux ...$args
        return
    }
    # Bare `tmux' defaults to new-session, which benefits from -CC.
    if ($args | is-empty) {
        ^tmux -CC
        return
    }
    # Find the first non-flag argument (the subcommand), skipping
    # values for flags that take arguments.  See tmux(1) §OPTIONS.
    mut subcmd = ""
    mut skip = false
    for arg in $args {
        if $skip {
            $skip = false
            continue
        }
        if ($arg in ["-c" "-f" "-L" "-S" "-T"]) {
            $skip = true
        } else if ($arg | str starts-with "-") {
            # flag without an argument
        } else {
            $subcmd = $arg
            break
        }
    }
    if ($subcmd in ["" "new" "new-session" "attach" "attach-session" "a"]) {
        ^tmux -CC ...$args
    } else {
        ^tmux ...$args
    }
}
