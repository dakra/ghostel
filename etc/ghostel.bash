# Ghostel shell integration for bash
# Source this from your .bashrc:
#   [[ "$INSIDE_EMACS" = 'ghostel' ]] && source /path/to/ghostel/etc/ghostel.bash

# Idempotency guard — skip if already loaded (e.g. auto-injected).
[[ "$(type -t __ghostel_osc7)" = "function" ]] && return

# Enable PTY echo.  Bash's readline buffers its own echo output so it
# never reaches the Emacs process filter.  PTY-level echo makes the
# kernel echo input immediately.
builtin command stty echo 2>/dev/null

# Report working directory to the terminal via OSC 7
__ghostel_osc7() {
    printf '\e]7;file://%s%s\e\\' "$HOSTNAME" "$PWD"
}

# --- Semantic prompt markers (OSC 133) ---

# Emit "command finished" (D) for the previous command, then "prompt start" (A).
# D is skipped on the very first prompt (no previous command).
__ghostel_prompt_start() {
    if [[ -n "$__ghostel_prompt_shown" ]]; then
        printf '\e]133;D;%s\e\\' "$__ghostel_last_status"
    fi
    printf '\e]133;A\e\\'
}

# Emit "prompt end / command start" (B).
__ghostel_prompt_end() {
    printf '\e]133;B\e\\'
    __ghostel_prompt_shown=1
}

# Emit "command output start" (C) via the DEBUG trap.
# Guard: skip when running inside PROMPT_COMMAND itself.
__ghostel_in_prompt_command=0
__ghostel_preexec() {
    [[ "$__ghostel_in_prompt_command" = 1 ]] && return
    printf '\e]133;C\e\\'
}

__ghostel_wrapped_prompt_command() {
    # Capture $? FIRST.  A bare assignment such as
    # `__ghostel_in_prompt_command=1' on its own line counts as a
    # successful command and resets $? to 0 in bash, so any later
    # `$?' read here would always see 0 and we'd report `:exit [0]'
    # for every command.  `local' with `=$?' evaluates `$?' before
    # invoking the local builtin, preserving the real exit status.
    local __ghostel_status=$?
    __ghostel_in_prompt_command=1
    __ghostel_last_status=$__ghostel_status
    __ghostel_prompt_start
    __ghostel_osc7
    eval "${__ghostel_original_prompt_command:-}"
    __ghostel_prompt_end
    __ghostel_in_prompt_command=0
}

# Preserve any existing PROMPT_COMMAND.
__ghostel_original_prompt_command="${PROMPT_COMMAND:+$PROMPT_COMMAND}"
PROMPT_COMMAND="__ghostel_wrapped_prompt_command"

trap '__ghostel_preexec' DEBUG

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
