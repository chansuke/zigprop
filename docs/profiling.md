# Profiling zigprop

The hot path of zigprop is the Source layer: every generated value is a
series of recorded draws, and shrinking re-runs generation per candidate.
Profile that layer first; optimize elsewhere only with evidence.

## Benchmarks

```sh
zig build bench              # full run (2M iterations per benchmark)
zig build bench -Dsmoke      # CI-sized run (binary flag: --smoke)
scripts/profile.sh           # perf stat when perf is available
```

The benchmark binary is built in ReleaseFast and installed as
`zig-out/bin/zigprop-bench` by the `bench-bin` step.

Current benchmarks:

| name | what it isolates |
|---|---|
| `range random bound=1000` | unbiased bounded draw + recording |
| `range random full domain` | raw u64 draw (sentinel bound) + recording |
| `range replay bound=1000` | replay normalization (`% bound`) + re-recording |
| `deriveSeed` | per-attempt seed derivation (SplitMix64 mix) |

Baselines are recorded in `bench/BASELINE.md` per machine; treat them as
indicative, not as regression gates. CI runs the smoke mode only to keep
the harness working.

## perf / flamegraphs (Linux)

```sh
perf record -g -- zig-out/bin/zigprop-bench
perf report
# or: perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

## Where time should go (design expectations)

- Recording appends one `Choice` (16 bytes) per draw; with capacity
  reserved it is a store and a length increment.
- `intRangeLessThan` rejection sampling is expected to accept on the
  first draw almost always for small bounds.
- If `range replay` is much slower than `range random`, suspect the
  modulo; if both are slow, suspect recording/allocation.
