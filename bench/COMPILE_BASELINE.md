# Compile-budget baseline

Recorded 2026-11-20 at d3236b0 plus the compile-budget change
(verification pipeline M5). Conditions: Zig 0.17.1, Linux x86_64,
development VM with 4 shared / throttled vCPUs. Indicative only. The
gate is that `zig build compile-budget` finishes within 120 s; the time
itself is a measurement, not a gate (design v0.3 §8.3).

What is timed: `zig build compile-budget`, which compiles and runs
`tests/compile_budget.zig` (Debug) with an emptied local cache. The
global cache (std, compiler_rt) is warm. Wall-clock time of the whole
command, build runner included, three consecutive runs.

| run | wall time |
|---|---|
| 1 | 3.58 s |
| 2 | 3.54 s |
| 3 | 3.30 s |

The step's own duration in `--summary all` is 4 s (rounded).

Detection check, run once: the same step against the c007748^ tree
(v0.2.0, before the C1 fix) was cut off by `timeout 120` (exit code
124; 2 min 6 s for the whole command).
