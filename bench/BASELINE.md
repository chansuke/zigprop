# Benchmark baseline

Recorded 2026-11-19, commit after the ReleaseFast module fix.
Conditions: Zig 0.17.1, Linux x86_64, development VM with a shared /
throttled CPU — indicative only, not a regression gate. All modules
(harness and library) are ReleaseFast. 2,000,000 iterations each,
recorded-list capacity reserved up front (allocation growth is not
measured), single run, no warm-up separation.

| benchmark | ns/op | ops/s |
|---|---|---|
| range random bound=1000 | 20.0 | 50,095,661 |
| range random full domain | 18.6 | 53,657,155 |
| range replay bound=1000 | 18.3 | 54,533,865 |

| deriveSeed | 1.4 | 734,757,367 |

Notes: the three `range` variants are within ~10% of each other in
this setup. Attributing the small differences (rejection sampling,
modulo, recording) needs isolated micro-measurements that have not
been done; treat the ordering as noise-level. An earlier baseline
(25.0 ns/op for the bounded draw) was measured with the library
module accidentally compiled in Debug mode and is superseded.
