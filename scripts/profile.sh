#!/bin/sh
# Profile the benchmark binary. Uses perf when available (Linux),
# otherwise falls back to a plain timed run.
# Usage: scripts/profile.sh [--smoke]
set -e
cd "$(dirname "$0")/.."
export PATH="$HOME/workspace/tools/bin:$PATH"

zig build -Doptimize=ReleaseFast bench-bin
BIN=$(find zig-out -name 'zigprop-bench' -type f | head -1)
echo "binary: $BIN"

if command -v perf >/dev/null 2>&1; then
    echo "== perf stat =="
    perf stat -e cycles,instructions,cache-misses,branch-misses -- "$BIN" "$@"
    echo
    echo "For a flamegraph:"
    echo "  perf record -g -- $BIN"
    echo "  perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg"
else
    echo "perf not found; running plain timed bench (see docs/profiling.md)"
    time "$BIN" "$@"
fi
