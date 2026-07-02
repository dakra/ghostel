#!/usr/bin/env bash
# Emit synthetic coding-agent output for testing Ghostel bottom anchoring.
# Stop with Ctrl-C.

set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: tools/agent-output.sh

Environment:
  LINES=N       Stop after roughly N output lines (default: 0, run forever)
  DELAY=S       Sleep between chunks, in seconds (default: 0.04)
  SYNC=0        Disable DEC 2026 synchronized spinner/status updates
  NO_COLOR=1    Disable ANSI colours
EOF
  exit 0
fi

limit="${LINES:-0}"
delay="${DELAY:-0.04}"
sync="${SYNC:-1}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  dim=$'\033[2m'
  bold=$'\033[1m'
  reset=$'\033[0m'
  blue=$'\033[34m'
  green=$'\033[32m'
  yellow=$'\033[33m'
  cyan=$'\033[36m'
  red=$'\033[31m'
else
  dim=''
  bold=''
  reset=''
  blue=''
  green=''
  yellow=''
  cyan=''
  red=''
fi

line_count=0
turn=1

trap 'printf "\n%sinterrupted%s\n" "$dim" "$reset"; exit 130' INT

emit() {
  printf '%b\n' "$*"
  ((++line_count))
  sleep "$delay"
}

spinner() {
  local frame="$1" status="$2"
  if [[ "$sync" == 1 ]]; then
    printf '\033[?2026h\r\033[K%b %s\n\033[K  ⎿  %s\033[A\r\033[?2026l' \
      "${cyan}${frame}${reset}" "Working…" "$status"
  else
    printf '\r\033[K%b %s' "${cyan}${frame}${reset}" "$status"
  fi
  sleep "$delay"
}

keep_going() {
  [[ "$limit" == 0 || "$line_count" -lt "$limit" ]]
}

prompts=(
  'fix bottom anchoring after text-scale-adjust'
  'inspect why the terminal jumps after C-x C-+'
  'add a small regression test for resize follow mode'
  'simplify window anchoring helpers'
)

files=(
  'lisp/ghostel.el'
  'test/ghostel-scroll-test.el'
  'test/ghostel-terminal-test.el'
  'test/ghostel-modes-test.el'
)

frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

emit "${bold}agent anchor output demo${reset} ${dim}(Ctrl-C to stop)${reset}"
emit "${dim}LINES=${limit} DELAY=${delay} SYNC=${sync}${reset}"
emit ''

while keep_going; do
  prompt="${prompts[$((RANDOM % ${#prompts[@]}))]}"
  emit "${blue}╭─ user${reset}"
  emit "${blue}│${reset} ${prompt}"
  emit "${blue}╰────${reset}"

  for i in 0 1 2 3 4; do
    spinner "${frames[$(((turn + i) % ${#frames[@]}))]}" "reading context ${i}/4"
  done
  printf '\r\033[K'

  emit "${yellow}●${reset} I'll keep this narrow and verify the anchoring path."

  for step in 1 2 3 4 5 6; do
    file="${files[$((RANDOM % ${#files[@]}))]}"
    case $(((turn + step) % 4)) in
      0)
        emit "${cyan}◇ read${reset} ${file} ${dim}:$((RANDOM % 5000 + 1))${reset}"
        ;;
      1)
        emit "${yellow}\$${reset} rg -n \"anchor|resize|text-scale\" ${file}"
        emit "${dim}  → matched $((RANDOM % 9 + 1)) lines in $((RANDOM % 80 + 10))ms${reset}"
        ;;
      2)
        emit "${dim}diff --git a/${file} b/${file}${reset}"
        emit "${green}+  (ghostel--anchor-window window)${reset}"
        emit "${red}-  (set-window-start window (point-min))${reset}"
        ;;
      *)
        emit "${green}✓${reset} checked ${file}"
        ;;
    esac
    keep_going || break
  done

  emit "${green}✔${reset} turn ${turn} complete ${dim}($((RANDOM % 1800 + 400)) tokens)${reset}"
  emit ''
  ((turn++))
done
