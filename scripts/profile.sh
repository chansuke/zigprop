#!/bin/sh
# Profile the benchmark binary. Uses perf when available (Linux),
# otherwise falls back to a plain timed run.
# Usage: scripts/profile.sh [--smoke]
set -e
cd "$(dirname "$0")/.."
if ! command -v zig >/dev/null 2>&1; then
    # Local fallback for the development VM's install location.
    export PATH="$HOME/workspace/tools/bin:$PATH"
fi

zig build bench-bin
BIN="zig-out/bin/zigprop-bench"
echo "binary: $BIN"

if command -v perf >/dev/null 2>&1; then
    echo "== perf stat =="
    if perf stat -e cycles,instructions,cache-misses,branch-misses -- "$BIN" "$@"; then
        echo
        echo "For a flamegraph:"
        echo "  perf record -g -- $BIN"
        echo "  perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg"
        exit 0
    fi
    echo "perf failed (permissions or unsupported events); falling back to a plain run"
fi
echo "running plain bench (see docs/profiling.md)"
"$BIN" "$@"
