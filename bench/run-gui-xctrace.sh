#!/usr/bin/env bash
# Run one ghostel benchmark case inside GUI Emacs while recording an xctrace
# Time Profiler trace attached to that Emacs process.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTEL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -x /Applications/Emacs.app/Contents/MacOS/Emacs ]; then
    DEFAULT_EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs
else
    DEFAULT_EMACS=emacs
fi

EMACS_BIN="${EMACS_GUI:-${EMACS:-$DEFAULT_EMACS}}"
EMACSCLIENT="${EMACSCLIENT:-emacsclient}"
TEMPLATE="Time Profiler"
CASE=""
SIZE=""
ITERS=""
MIN_DURATION=""
COUNT=""
OUTPUT_DIR="$GHOSTEL_DIR/bench/profiles"
OPEN_TRACE=false
REDISPLAY="nil"
INCLUDE_VTERM="t"
INCLUDE_EAT="t"
INCLUDE_TERM="t"
VTERM_DIR=""
EAT_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --case CASE [OPTIONS]

Options:
  --case CASE       Benchmark case to run, e.g. backend/plain/native
                   or e2e/urls/ghostel
  --quick           100KB data, 2 iterations, 50 typing samples
  --size N          Data size in bytes
  --iterations N    Iteration count floor
  --min-duration S  Target at least S seconds for auto-scaled fast cases
  --count N         Typing sample count
  --redisplay       Force GUI redisplay after each measured iteration
  --template NAME   xctrace template (default: Time Profiler)
  --output-dir DIR  Directory for .trace and .log files
  --open            Open the resulting .trace in Instruments
  --emacs PATH      GUI Emacs executable
  --emacsclient PATH
  --vterm-dir DIR   Path to vterm package directory
  --eat-dir DIR     Path to eat package directory
  --no-vterm        Skip/disable vterm
  --no-eat          Skip/disable eat
  --no-term         Skip/disable term
  -h, --help        Show this help

Examples:
  $(basename "$0") --case backend/plain/native
  $(basename "$0") --case e2e/urls/ghostel --size 1048576 --iterations 5
  $(basename "$0") --case tui-partial/40x120 --min-duration 10
  $(basename "$0") --case backend/mixed/native --redisplay
EOF
    exit 0
}

need_arg() {
    if [ $# -lt 2 ] || [ -z "${2-}" ]; then
        echo "ERROR: $1 requires an argument" >&2
        exit 1
    fi
}

QUICK=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --case)        need_arg "$1" "${2-}"; CASE="$2"; shift 2 ;;
        --quick)       QUICK=true; shift ;;
        --size)        need_arg "$1" "${2-}"; SIZE="$2"; shift 2 ;;
        --iterations)  need_arg "$1" "${2-}"; ITERS="$2"; shift 2 ;;
        --min-duration) need_arg "$1" "${2-}"; MIN_DURATION="$2"; shift 2 ;;
        --count)       need_arg "$1" "${2-}"; COUNT="$2"; shift 2 ;;
        --redisplay)   REDISPLAY="t"; shift ;;
        --template)    need_arg "$1" "${2-}"; TEMPLATE="$2"; shift 2 ;;
        --output-dir)  need_arg "$1" "${2-}"; OUTPUT_DIR="$2"; shift 2 ;;
        --open)        OPEN_TRACE=true; shift ;;
        --emacs)       need_arg "$1" "${2-}"; EMACS_BIN="$2"; shift 2 ;;
        --emacsclient) need_arg "$1" "${2-}"; EMACSCLIENT="$2"; shift 2 ;;
        --vterm-dir)   need_arg "$1" "${2-}"; VTERM_DIR="$2"; shift 2 ;;
        --eat-dir)     need_arg "$1" "${2-}"; EAT_DIR="$2"; shift 2 ;;
        --no-vterm)    INCLUDE_VTERM="nil"; shift ;;
        --no-eat)      INCLUDE_EAT="nil"; shift ;;
        --no-term)     INCLUDE_TERM="nil"; shift ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$CASE" ]; then
    echo "ERROR: --case is required" >&2
    usage
fi
if [[ ! "$CASE" =~ ^[A-Za-z0-9_./-]+$ ]]; then
    echo "ERROR: invalid benchmark case syntax: $CASE" >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "ERROR: xcrun not found" >&2
    exit 1
fi
if ! command -v notifyutil >/dev/null 2>&1; then
    echo "ERROR: notifyutil not found" >&2
    exit 1
fi
if ! command -v "$EMACSCLIENT" >/dev/null 2>&1; then
    echo "ERROR: emacsclient not found: $EMACSCLIENT" >&2
    exit 1
fi

TMPDIR="$(mktemp -d "/tmp/ghostel-gui-xctrace.XXXXXX")"
cleanup() {
    local status=$?
    if [ -n "${NOTIFY_PID:-}" ] && kill -0 "$NOTIFY_PID" 2>/dev/null; then
        kill "$NOTIFY_PID" 2>/dev/null || true
    fi
    if [ -n "${EMACS_PID:-}" ] && kill -0 "$EMACS_PID" 2>/dev/null; then
        kill "$EMACS_PID" 2>/dev/null || true
    fi
    if [ -n "${XCTRACE_PID:-}" ] && kill -0 "$XCTRACE_PID" 2>/dev/null; then
        kill "$XCTRACE_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
    exit "$status"
}
trap cleanup EXIT INT TERM

if ! xcrun xctrace list templates >/dev/null 2>"$TMPDIR/xctrace-check.err"; then
    echo "ERROR: xctrace is not usable. It usually requires full Xcode, not only Command Line Tools." >&2
    cat "$TMPDIR/xctrace-check.err" >&2
    exit 1
fi

# Verify ghostel module exists before launching Emacs.
MODULE=""
for ext in dylib so; do
    if [ -f "$GHOSTEL_DIR/ghostel-module.$ext" ]; then
        MODULE="$GHOSTEL_DIR/ghostel-module.$ext"
        break
    fi
done
if [ -z "$MODULE" ]; then
    echo "ERROR: ghostel native module not found. Run zig build -Doptimize=ReleaseFast first." >&2
    exit 1
fi

# Try to find optional comparison backends.
if [ "$INCLUDE_VTERM" = "t" ] && [ -z "$VTERM_DIR" ]; then
    for dir in "$GHOSTEL_DIR/../vterm" \
               "$HOME/.emacs.d/lib/vterm" \
               "$HOME/.emacs.d/elpa/vterm"*/ \
               "$HOME/.emacs.d/straight/build/vterm"; do
        if [ -f "$dir/vterm.el" ] 2>/dev/null; then
            VTERM_DIR="$(cd "$dir" && pwd)"
            break
        fi
    done
fi
if [ "$INCLUDE_EAT" = "t" ] && [ -z "$EAT_DIR" ]; then
    for dir in "$GHOSTEL_DIR/../eat" \
               "$HOME/.emacs.d/lib/eat" \
               "$HOME/.emacs.d/elpa/eat"*/ \
               "$HOME/.emacs.d/straight/build/eat"; do
        if [ -f "$dir/eat.el" ] 2>/dev/null; then
            EAT_DIR="$(cd "$dir" && pwd)"
            break
        fi
    done
fi
[ "$INCLUDE_VTERM" = "t" ] && [ -z "$VTERM_DIR" ] && INCLUDE_VTERM="nil"
[ "$INCLUDE_EAT" = "t" ] && [ -z "$EAT_DIR" ] && INCLUDE_EAT="nil"

mkdir -p "$OUTPUT_DIR"
SAFE_CASE="${CASE//\//-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="$OUTPUT_DIR/$STAMP-$SAFE_CASE"
TRACE_PATH="$BASE.trace"
BENCH_LOG="$BASE.log"
EMACS_LOG="$BASE.emacs.log"
XCTRACE_LOG="$BASE.xctrace.log"
SERVER_SOCKET="$TMPDIR/server"
NOTIFY="com.ghostel.xctrace.started.$STAMP.$$"

elisp_string() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

GHOSTEL_LISP_EL="$(elisp_string "$GHOSTEL_DIR/lisp")"
BENCH_FILE_EL="$(elisp_string "$SCRIPT_DIR/ghostel-bench.el")"
CASE_EL="$(elisp_string "$CASE")"
BENCH_LOG_EL="$(elisp_string "$BENCH_LOG")"
VTERM_DIR_EL="$(elisp_string "$VTERM_DIR")"
EAT_DIR_EL="$(elisp_string "$EAT_DIR")"
SERVER_SOCKET_EL="$(elisp_string "$SERVER_SOCKET")"

SERVER_EVAL="(progn (setq enable-dir-local-variables nil) (require 'server) (setq server-name $SERVER_SOCKET_EL) (server-start))"
pushd "$TMPDIR" >/dev/null
"$EMACS_BIN" -Q -L "$GHOSTEL_DIR/lisp" --eval "$SERVER_EVAL" >"$EMACS_LOG" 2>&1 &
EMACS_PID=$!
popd >/dev/null

for _ in $(seq 1 200); do
    if "$EMACSCLIENT" -s "$SERVER_SOCKET" --eval t >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "$EMACS_PID" 2>/dev/null; then
        echo "ERROR: GUI Emacs exited before its server became ready; see $EMACS_LOG" >&2
        cat "$EMACS_LOG" >&2
        exit 1
    fi
    sleep 0.1
done
if ! "$EMACSCLIENT" -s "$SERVER_SOCKET" --eval t >/dev/null 2>&1; then
    echo "ERROR: timed out waiting for GUI Emacs server; see $EMACS_LOG" >&2
    cat "$EMACS_LOG" >&2
    exit 1
fi

notifyutil -1 "$NOTIFY" >/dev/null &
NOTIFY_PID=$!

xcrun xctrace record \
    --template "$TEMPLATE" \
    --output "$TRACE_PATH" \
    --attach "$EMACS_PID" \
    --no-prompt \
    --notify-tracing-started "$NOTIFY" \
    >"$XCTRACE_LOG" 2>&1 &
XCTRACE_PID=$!

TRACING_STARTED=false
for _ in $(seq 1 300); do
    if ! kill -0 "$NOTIFY_PID" 2>/dev/null; then
        TRACING_STARTED=true
        break
    fi
    if ! kill -0 "$XCTRACE_PID" 2>/dev/null; then
        wait "$XCTRACE_PID" || true
        echo "ERROR: xctrace exited before tracing started" >&2
        cat "$XCTRACE_LOG" >&2
        exit 1
    fi
    sleep 0.1
done
if [ "$TRACING_STARTED" != true ]; then
    echo "ERROR: timed out waiting for xctrace to start" >&2
    cat "$XCTRACE_LOG" >&2
    exit 1
fi
wait "$NOTIFY_PID" 2>/dev/null || true
NOTIFY_PID=""

RUN_EVAL="
(condition-case err
    (progn
      (setq enable-dir-local-variables nil)
      (add-to-list 'load-path $GHOSTEL_LISP_EL)
      (when (> (length $VTERM_DIR_EL) 0)
        (add-to-list 'load-path $VTERM_DIR_EL))
      (when (> (length $EAT_DIR_EL) 0)
        (add-to-list 'load-path $EAT_DIR_EL))
      (load $BENCH_FILE_EL nil t)
      (setq ghostel-bench-include-vterm $INCLUDE_VTERM
            ghostel-bench-include-eat $INCLUDE_EAT
            ghostel-bench-include-term $INCLUDE_TERM
            ghostel-bench-force-gui-redisplay $REDISPLAY)
      $(if $QUICK; then echo "(setq ghostel-bench-data-size (* 100 1024) ghostel-bench-iterations 2 ghostel-bench-typing-count 50)"; fi)
      $(if [ -n "$SIZE" ]; then echo "(setq ghostel-bench-data-size $SIZE)"; fi)
      $(if [ -n "$ITERS" ]; then echo "(setq ghostel-bench-iterations $ITERS)"; fi)
      $(if [ -n "$MIN_DURATION" ]; then echo "(setq ghostel-bench-min-duration $MIN_DURATION)"; fi)
      $(if [ -n "$COUNT" ]; then echo "(setq ghostel-bench-typing-count $COUNT)"; fi)
      (ghostel-bench-run-one $CASE_EL)
      (with-current-buffer \"*Messages*\"
        (write-region (point-min) (point-max) $BENCH_LOG_EL nil 'silent))
      'ok)
  (error
   (message \"ERROR: %s\" (error-message-string err))
   (with-current-buffer \"*Messages*\"
     (write-region (point-min) (point-max) $BENCH_LOG_EL nil 'silent))
   (error \"%s\" (error-message-string err))))"

set +e
"$EMACSCLIENT" -s "$SERVER_SOCKET" --eval "$RUN_EVAL"
BENCH_STATUS=$?
set -e

"$EMACSCLIENT" -s "$SERVER_SOCKET" --eval '(kill-emacs 0)' >/dev/null 2>&1 || true
wait "$EMACS_PID" 2>/dev/null || true
EMACS_PID=""

set +e
wait "$XCTRACE_PID"
XCTRACE_STATUS=$?
set -e

if [ "$BENCH_STATUS" -ne 0 ]; then
    echo "ERROR: benchmark failed; see $BENCH_LOG" >&2
    exit "$BENCH_STATUS"
fi
if [ "$XCTRACE_STATUS" -ne 0 ]; then
    echo "ERROR: xctrace failed; see $XCTRACE_LOG" >&2
    exit "$XCTRACE_STATUS"
fi

echo "trace: $TRACE_PATH"
echo "bench log: $BENCH_LOG"
echo "emacs log: $EMACS_LOG"
echo "xctrace log: $XCTRACE_LOG"

if $OPEN_TRACE; then
    open -a Instruments "$TRACE_PATH"
fi
