# Benchmark baseline

Recorded 2026-11-19 on the development VM (shared/throttled CPU —
indicative only, not a regression gate). ReleaseFast, 2,000,000
iterations each, recorded-list capacity reserved up front.

| benchmark | ns/op | ops/s |
|---|---|---|
| range random bound=1000 | 25.0 | 39,995,144 |
| range random full domain | 19.2 | 51,949,559 |
| range replay bound=1000 | 20.0 | 50,114,757 |
| deriveSeed | 1.5 | 656,481,789 |

Reading: the bounded draw costs ~5 ns/op over the raw draw (rejection
sampling in `intRangeLessThan`); replay normalization costs about the
same as a raw draw. Recording itself is not the bottleneck at this
scale.
