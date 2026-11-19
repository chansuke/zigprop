# zigprop

Property-based testing for Zig, built on integrated shrinking over
recorded choice sequences.

**Status: Phase 0 prototype (not released).** The design is specified
in [docs/design-v2.md](docs/design-v2.md), and
[docs/verification.md](docs/verification.md) maps its claims to tests,
Lean proofs, TLA+ model checking and benchmarks. Implementation
proceeds milestone by milestone:

1. ✅ Source + primitives (range / boolean / index / length), replay,
   per-attempt seed derivation — with meta tests
2. ⬜ Comptime generation (bool, integers, enum, optional, arrays,
   slices, structs) + runner (`check` / `checkCustom`)
3. ⬜ Shrinking (chunk deletion / zeroing / power-of-two decrease)
4. ⬜ Mutant validation targets (varint, RLE) against pre-registered
   criteria

- License: MIT
- Zig: developed and CI-tested against the latest stable (0.17.1);
  `minimum_zig_version = "0.17.0"` is the consumer floor within the
  0.17 line. Master is CI early-warning only
- Zero dependencies
