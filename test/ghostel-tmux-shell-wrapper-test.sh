#!/usr/bin/env bash
# Tests for the `tmux' wrapper installed by etc/shell/ghostel.bash and
# etc/shell/ghostel.nu (the nushell cases are skipped when `nu' is not
# installed).  Verifies that `-CC' is auto-injected for attaching
# subcommands and pass-through for everything else, including hairy
# flag-with-value combinations.
#
# Run: bash test/ghostel-tmux-shell-wrapper-test.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAKE_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_DIR"' EXIT

# Fake `tmux' that prints its argv to stdout and exits 0.
cat > "$FAKE_DIR/tmux" <<'EOF'
#!/bin/sh
echo "TMUX-CALLED-WITH:$*"
EOF
chmod +x "$FAKE_DIR/tmux"

PASS=0
FAIL=0

run_one() {
    local label="$1" expected="$2"
    shift 2
    local got
    got=$(PATH="$FAKE_DIR:$PATH" bash --noprofile --norc -c "
        unset PROMPT_COMMAND
        source '$REPO/etc/shell/ghostel.bash' 2>/dev/null
        unset PROMPT_COMMAND
        trap - DEBUG
        tmux $*
    " 2>&1 | sed -n 's/.*TMUX-CALLED-WITH:\(.*\)/\1/p')
    if [[ "$got" == "$expected" ]]; then
        printf '  PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        expected: %q\n        got:      %q\n' \
            "$label" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

echo "ghostel-tmux shell wrapper tests"
echo

# Bare and attaching subcommands → -CC injected.
run_one "bare tmux"                 "-CC"                       ""
run_one "tmux new"                  "-CC new"                   "new"
run_one "tmux new -s foo"           "-CC new -s foo"            "new -s foo"
run_one "tmux attach"               "-CC attach"                "attach"
run_one "tmux attach -t foo"        "-CC attach -t foo"         "attach -t foo"
run_one "tmux a -t bar"             "-CC a -t bar"              "a -t bar"
run_one "tmux new-session -A -s x"  "-CC new-session -A -s x"   "new-session -A -s x"
run_one "tmux attach-session"       "-CC attach-session"        "attach-session"

# Already has -CC or -C → don't double up.
run_one "tmux -CC new"              "-CC new"                   "-CC new"
run_one "tmux -C ls"                "-C ls"                     "-C ls"

# Non-attaching subcommands → pass through.
run_one "tmux ls"                   "ls"                        "ls"
run_one "tmux kill-server"          "kill-server"               "kill-server"
run_one "tmux capture-pane -p"      "capture-pane -p"           "capture-pane -p"
run_one "tmux source-file foo"      "source-file foo"           "source-file foo"

# Flags-with-values: -L socket, -S path, -c cmd, -f file, -T features.
run_one "tmux -L sock new"          "-CC -L sock new"           "-L sock new"
run_one "tmux -S /tmp/x new -s y"   "-CC -S /tmp/x new -s y"    "-S /tmp/x new -s y"
run_one "tmux -L sock ls"           "-L sock ls"                "-L sock ls"
run_one "tmux -f cfg new"           "-CC -f cfg new"            "-f cfg new"
run_one "tmux -T 256 new"           "-CC -T 256 new"            "-T 256 new"

# Boolean global flags (-N takes no value) must not eat the subcommand.
run_one "tmux -N new"               "-CC -N new"                "-N new"
run_one "tmux -N ls"                "-N ls"                     "-N ls"

# Bypass via `command tmux'
got_bypass=$(PATH="$FAKE_DIR:$PATH" bash --noprofile --norc -c "
    unset PROMPT_COMMAND
    source '$REPO/etc/shell/ghostel.bash' 2>/dev/null
    unset PROMPT_COMMAND
    trap - DEBUG
    command tmux new
" 2>&1 | sed -n 's/.*TMUX-CALLED-WITH:\(.*\)/\1/p')
if [[ "$got_bypass" == "new" ]]; then
    printf '  PASS  %s\n' "command tmux new bypasses wrapper"
    PASS=$((PASS + 1))
else
    printf '  FAIL  %s\n        got: %q\n' \
        "command tmux new bypasses wrapper" "$got_bypass"
    FAIL=$((FAIL + 1))
fi

# --------------------------------------------------------------------------
# Nushell wrapper (etc/shell/ghostel.nu) — same matrix, skipped without `nu'.
# --------------------------------------------------------------------------

if command -v nu >/dev/null 2>&1; then
    echo
    echo "nushell wrapper tests"
    echo

    run_one_nu() {
        local label="$1" expected="$2" invocation="$3"
        local got
        got=$(env -u GHOSTEL_TMUX_NO_CC PATH="$FAKE_DIR:$PATH" \
            nu --no-config-file -c \
            "source '$REPO/etc/shell/ghostel.nu'; $invocation" \
            2>&1 | sed -n 's/.*TMUX-CALLED-WITH:\(.*\)/\1/p')
        if [[ "$got" == "$expected" ]]; then
            printf '  PASS  %s\n' "$label"
            PASS=$((PASS + 1))
        else
            printf '  FAIL  %s\n        expected: %q\n        got:      %q\n' \
            "$label" "$expected" "$got"
            FAIL=$((FAIL + 1))
        fi
    }

    run_one_nu "nu: bare tmux"           "-CC"                    "tmux"
    run_one_nu "nu: tmux new"            "-CC new"                "tmux new"
    run_one_nu "nu: tmux attach -t foo"  "-CC attach -t foo"      "tmux attach -t foo"
    run_one_nu "nu: tmux a -t bar"       "-CC a -t bar"           "tmux a -t bar"
    run_one_nu "nu: tmux -CC new"        "-CC new"                "tmux -CC new"
    run_one_nu "nu: tmux -C ls"          "-C ls"                  "tmux -C ls"
    run_one_nu "nu: tmux ls"             "ls"                     "tmux ls"
    run_one_nu "nu: tmux kill-server"    "kill-server"            "tmux kill-server"
    run_one_nu "nu: tmux -L sock new"    "-CC -L sock new"        "tmux -L sock new"
    run_one_nu "nu: tmux -L sock ls"     "-L sock ls"             "tmux -L sock ls"
    run_one_nu "nu: tmux -N ls"          "-N ls"                  "tmux -N ls"
    run_one_nu "nu: tmux -T 256 new"     "-CC -T 256 new"         "tmux -T 256 new"
    run_one_nu "nu: ^tmux new bypasses wrapper" "new"             "^tmux new"

    got_nocc=$(GHOSTEL_TMUX_NO_CC=1 PATH="$FAKE_DIR:$PATH" \
        nu --no-config-file -c \
        "source '$REPO/etc/shell/ghostel.nu'; tmux new" \
        2>&1 | sed -n 's/.*TMUX-CALLED-WITH:\(.*\)/\1/p')
    if [[ "$got_nocc" == "new" ]]; then
        printf '  PASS  %s\n' "nu: GHOSTEL_TMUX_NO_CC=1 disables wrapper"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        got: %q\n' \
            "nu: GHOSTEL_TMUX_NO_CC=1 disables wrapper" "$got_nocc"
        FAIL=$((FAIL + 1))
    fi
else
    echo
    echo "nushell wrapper tests: SKIPPED (no \`nu' in PATH)"
fi

echo
echo "$PASS passed, $FAIL failed"
exit "$FAIL"
