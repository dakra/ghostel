#!/usr/bin/env bash
# Simulate continuously scrolling agent-style TUI output with jittery timing.
# Stop with Ctrl-C.

set -u

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  dim=$'\033[2m'
  bold=$'\033[1m'
  reset=$'\033[0m'
  blue=$'\033[34m'
  green=$'\033[32m'
  yellow=$'\033[33m'
  magenta=$'\033[35m'
  cyan=$'\033[36m'
  red=$'\033[31m'
else
  dim=''
  bold=''
  reset=''
  blue=''
  green=''
  yellow=''
  magenta=''
  cyan=''
  red=''
fi

rand_between() {
  local min="$1" max="$2"
  echo $((min + RANDOM % (max - min + 1)))
}

sleep_ms() {
  local ms="$1"
  sleep "$(printf '%d.%03d' "$((ms / 1000))" "$((ms % 1000))")"
}

pause_ms() {
  sleep_ms "$(rand_between "${MIN_DELAY_MS:-35}" "${MAX_DELAY_MS:-420}")"
}

say() {
  printf '%b\n' "$*"
  pause_ms
}

choose() {
  local name="$1" len idx
  eval "len=\${#${name}[@]}"
  idx=$((RANDOM % len))
  eval "printf '%s' \"\${${name}[${idx}]}\""
}

spinner_tick() {
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  printf '%b\r' "${cyan}${frames[$((RANDOM % ${#frames[@]}))]}${reset} $1"
  sleep_ms "$(rand_between 45 160)"
}

trap 'printf "\n%binterrupted%b\n" "$dim" "$reset"; exit 130' INT

prompts=(
  "add keyboard navigation to the diagnostics panel"
  "trace why the terminal buffer stops repainting after resize"
  "write a regression test for OSC 8 links"
  "simplify the renderer invalidation path"
  "check whether wide emoji alignment is stable"
  "make the compile buffer follow VS Code-like behavior"
)

files=(
  "lisp/ghostel.el"
  "lisp/ghostel-comint.el"
  "lisp/ghostel-compile.el"
  "src/Renderer.zig"
  "src/GhostelTerm.zig"
  "test/ghostel-render-test.el"
  "test/ghostel-terminal-test.el"
)

tools=(read bash grep edit write emacs-eval)

thoughts=(
  "Need to verify the invariant before changing anything."
  "The failure path looks narrower than the symptom suggests."
  "I'll inspect the call site and keep this change local."
  "This should be a display rule, not command-specific advice."
  "The surrounding code already has the right abstraction."
  "Let's prove the root cause with one targeted check."
)

commands=(
  "rg \"display-buffer\" lisp test"
  "emacs --batch -Q -l test.el"
  "zig build test"
  "make test TEST=test/ghostel-render-test.el"
  "git diff -- lisp/ghostel.el"
  "rg \"osc8\|hyperlink\" -n"
)

edits=(
  "+  (setq-local truncate-lines t)"
  "-  (redisplay)"
  "+  (ghostel-render-invalidate term start end)"
  "+  (add-hook 'window-size-change-functions #'ghostel--resize nil t)"
  "-  ;; TODO: temporary workaround"
  "+  (should (equal (ghostel-test-cursor) '(12 . 4)))"
)

statuses=("ok" "done" "cached" "changed" "passed" "skipped")

printf '%b\n' "${bold}ghostel-agent demo${reset} ${dim}(continuous synthetic output; Ctrl-C to stop)${reset}"
printf '%b\n\n' "${dim}delay=${MIN_DELAY_MS:-35}-${MAX_DELAY_MS:-420}ms${reset}"

turn=1
while true; do
  prompt="$(choose prompts)"
  say "${blue}╭─ user${reset}"
  say "${blue}│${reset} $prompt"
  say "${blue}╰────${reset}"

  for _ in 1 2 3; do
    spinner_tick "thinking"
  done
  printf '%*s\r' "80" ""

  say "${magenta}●${reset} $(choose thoughts)"

  step_count="$(rand_between 3 7)"
  for ((step = 1; step <= step_count; step++)); do
    case $((RANDOM % 5)) in
      0)
        tool="$(choose tools)"
        file="$(choose files)"
        say "${cyan}◇ tool:${reset} ${bold}${tool}${reset} ${dim}${file}${reset}"
        ;;
      1)
        cmd="$(choose commands)"
        say "${yellow}\$${reset} $cmd"
        say "${dim}  → $(choose statuses) in $(rand_between 18 900)ms${reset}"
        ;;
      2)
        file="$(choose files)"
        say "${green}✓${reset} inspected ${file}"
        ;;
      3)
        file="$(choose files)"
        say "${dim}diff --git a/${file} b/${file}${reset}"
        say "${green}$(choose edits)${reset}"
        ;;
      *)
        say "${red}!${reset} warning: simulated flaky timing reproduced once"
        say "${green}✓${reset} narrowed to a deterministic path"
        ;;
    esac
  done

  say "${green}✔${reset} turn ${turn} complete ${dim}($(rand_between 120 2400) tokens, $(rand_between 1 6) files touched)${reset}"
  say ""
  ((turn++))
done
