#!/usr/bin/env bash
# ghostel-bench — benchmark ghostel vs vterm vs eat vs term (and optionally ghostty)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTEL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EMACS="${EMACS:-emacs}"

# Defaults
MODE="all"
SIZE=""
ITERS=""
MIN_DURATION=""
CASE=""
INCLUDE_VTERM="t"
INCLUDE_EAT="t"
INCLUDE_TERM="t"
GHOSTTY=false
OUTPUT=""

# Try to find vterm and eat
VTERM_DIR=""
EAT_DIR=""

for dir in "$GHOSTEL_DIR/../vterm" \
           "$HOME/.emacs.d/lib/vterm" \
           "$HOME/.emacs.d/elpa/vterm"*/ \
           "$HOME/.emacs.d/straight/build/vterm"; do
    if [ -f "$dir/vterm.el" ] 2>/dev/null; then
        VTERM_DIR="$(cd "$dir" && pwd)"
        break
    fi
done

for dir in "$GHOSTEL_DIR/../eat" \
           "$HOME/.emacs.d/lib/eat" \
           "$HOME/.emacs.d/elpa/eat"*/ \
           "$HOME/.emacs.d/straight/build/eat"; do
    if [ -f "$dir/eat.el" ] 2>/dev/null; then
        EAT_DIR="$(cd "$dir" && pwd)"
        break
    fi
done

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --quick          Quick run (100KB data, 3 iterations, single size)
  --e2e            Run only the end-to-end backend benchmarks (composes
                   with --quick, --size, --iterations)
  --backends       Run only the native-vs-Emacs PTY comparison (composes
                   with --quick, --size, --iterations)
  --typing         Run only the typing-latency comparison (native vs Emacs
                   PTY); --quick uses fewer keystrokes
  --case CASE      Run exactly one benchmark case, e.g.
                   backend/plain/native or e2e/urls/ghostel
  --no-vterm       Skip vterm benchmarks
  --no-eat         Skip eat benchmarks
  --no-term        Skip Emacs built-in term benchmarks
  --ghostty        Generate data files for ghostty comparison
  --output FILE    Tee output to FILE
  --size N         Data size in bytes (default: 1048576)
  --iterations N   Override iteration count (default: 5)
  --min-duration S Target at least S seconds for auto-scaled fast cases
  --vterm-dir DIR  Path to vterm package directory
  --eat-dir DIR    Path to eat package directory
  -h, --help       Show this help

Examples:
  $(basename "$0")                # Full benchmark
  $(basename "$0") --quick        # Quick sanity check
  $(basename "$0") --e2e          # Only the end-to-end section
  $(basename "$0") --quick --e2e  # Quick end-to-end-only run
  $(basename "$0") --backends     # Only native-vs-Emacs PTY comparison
  $(basename "$0") --typing       # Only typing-latency comparison
  $(basename "$0") --case backend/plain/native
  $(basename "$0") --case tui-partial/40x120
  $(basename "$0") --ghostty      # Include ghostty comparison data
EOF
    exit 0
}

SECTION="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)      MODE="quick"; shift ;;
        --e2e)        SECTION="e2e"; shift ;;
        --backends)   SECTION="backends"; shift ;;
        --typing)     SECTION="typing"; shift ;;
        --case)       if [ $# -lt 2 ]; then echo "ERROR: --case requires an argument" >&2; exit 1; fi; CASE="$2"; shift 2 ;;
        --no-vterm)   INCLUDE_VTERM="nil"; shift ;;
        --no-eat)     INCLUDE_EAT="nil"; shift ;;
        --no-term)    INCLUDE_TERM="nil"; shift ;;
        --ghostty)    GHOSTTY=true; shift ;;
        --output)     OUTPUT="$2"; shift 2 ;;
        --size)       SIZE="$2"; shift 2 ;;
        --iterations) ITERS="$2"; shift 2 ;;
        --min-duration) MIN_DURATION="$2"; shift 2 ;;
        --vterm-dir)  VTERM_DIR="$2"; shift 2 ;;
        --eat-dir)    EAT_DIR="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            echo "Unknown option: $1"; usage ;;
    esac
done

if [ -n "$CASE" ] && [[ ! "$CASE" =~ ^[A-Za-z0-9_./-]+$ ]]; then
    echo "ERROR: invalid benchmark case syntax: $CASE" >&2
    exit 1
fi

# Verify ghostel module exists
MODULE=""
for ext in dylib so; do
    if [ -f "$GHOSTEL_DIR/ghostel-module.$ext" ]; then
        MODULE="$GHOSTEL_DIR/ghostel-module.$ext"
        break
    fi
done
if [ -z "$MODULE" ]; then
    echo "ERROR: ghostel native module not found. Run zig build -Doptimize=ReleaseFast first."
    exit 1
fi
echo "ghostel module: $MODULE"

# Verify vterm
if [ "$INCLUDE_VTERM" = "t" ]; then
    if [ -z "$VTERM_DIR" ]; then
        echo "WARNING: vterm not found, skipping (use --vterm-dir to specify)"
        INCLUDE_VTERM="nil"
    else
        echo "vterm: $VTERM_DIR"
    fi
fi

# Verify eat
if [ "$INCLUDE_EAT" = "t" ]; then
    if [ -z "$EAT_DIR" ]; then
        echo "WARNING: eat not found, skipping (use --eat-dir to specify)"
        INCLUDE_EAT="nil"
    else
        echo "eat: $EAT_DIR"
    fi
fi

# Build load-path
LOAD_PATH="-L $GHOSTEL_DIR/lisp"
[ "$INCLUDE_VTERM" = "t" ] && LOAD_PATH="$LOAD_PATH -L $VTERM_DIR"
[ "$INCLUDE_EAT" = "t" ] && LOAD_PATH="$LOAD_PATH -L $EAT_DIR"

# Build eval expression
EVAL="(progn"
[ -n "$SIZE" ] && EVAL="$EVAL (setq ghostel-bench-data-size $SIZE)"
[ -n "$ITERS" ] && EVAL="$EVAL (setq ghostel-bench-iterations $ITERS)"
[ -n "$MIN_DURATION" ] && EVAL="$EVAL (setq ghostel-bench-min-duration $MIN_DURATION)"
EVAL="$EVAL (setq ghostel-bench-include-vterm $INCLUDE_VTERM)"
EVAL="$EVAL (setq ghostel-bench-include-eat $INCLUDE_EAT)"
EVAL="$EVAL (setq ghostel-bench-include-term $INCLUDE_TERM)"
if [ -n "$CASE" ]; then
    if [ "$MODE" = "quick" ]; then
        EVAL="$EVAL (setq ghostel-bench-data-size (* 100 1024) ghostel-bench-iterations 2 ghostel-bench-typing-count 50)"
    fi
    EVAL="$EVAL (ghostel-bench-run-one \"$CASE\"))"
elif [ "$SECTION" = "e2e" ]; then
    if [ "$MODE" = "quick" ]; then
        EVAL="$EVAL (setq ghostel-bench-data-size (* 100 1024) ghostel-bench-iterations 2)"
    fi
    EVAL="$EVAL (ghostel-bench-run-e2e))"
elif [ "$SECTION" = "backends" ]; then
    if [ "$MODE" = "quick" ]; then
        EVAL="$EVAL (setq ghostel-bench-data-size (* 100 1024) ghostel-bench-iterations 2)"
    fi
    EVAL="$EVAL (ghostel-bench-run-backends))"
elif [ "$SECTION" = "typing" ]; then
    if [ "$MODE" = "quick" ]; then
        EVAL="$EVAL (setq ghostel-bench-typing-count 50)"
    fi
    EVAL="$EVAL (ghostel-bench-typing-latency))"
elif [ "$MODE" = "quick" ]; then
    EVAL="$EVAL (ghostel-bench-run-quick))"
else
    EVAL="$EVAL (ghostel-bench-run-all))"
fi

echo ""

# Run benchmarks
CMD="$EMACS --batch -Q $LOAD_PATH -l $SCRIPT_DIR/ghostel-bench.el --eval '$EVAL'"

if [ -n "$OUTPUT" ]; then
    eval "$CMD" 2>&1 | grep -v '^info(' | tee "$OUTPUT"
else
    eval "$CMD" 2>&1 | grep -v '^info('
fi

# Ghostty comparison
if $GHOSTTY; then
    echo ""
    echo "=== Ghostty Native Comparison ==="
    echo ""

    DATA_SIZE="${SIZE:-1048576}"

    # Generate plain ASCII test data (matches ghostel-bench--gen-plain-ascii)
    BENCH_FILE="/tmp/ghostel-bench-plain.bin"
    python3 -c "
import sys
line = b'A' * 78 + b'\r\n'
total = 0
target = $DATA_SIZE
with open('$BENCH_FILE', 'wb') as f:
    while total < target:
        f.write(line)
        total += len(line)
" 2>/dev/null || {
        # Fallback without python
        dd if=/dev/zero bs=1 count="$DATA_SIZE" 2>/dev/null | tr '\0' 'A' > "$BENCH_FILE"
    }

    FILE_SIZE=$(wc -c < "$BENCH_FILE" | tr -d ' ')
    echo "Generated: $BENCH_FILE ($FILE_SIZE bytes)"
    echo ""
    echo "To compare with ghostty, run this INSIDE a ghostty terminal:"
    echo ""
    echo "  time cat $BENCH_FILE"
    echo ""
    echo "This measures ghostty's VT parse + GPU render for the same data."
    echo "(Note: apples-to-oranges vs Emacs buffer rendering, but useful context.)"
fi
