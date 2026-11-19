# zigprop

Property-based testing for Zig, built on integrated shrinking over
recorded choice sequences.

**Status: Phase 0 prototype (not released).** The design is specified in
`zigprop-phase0-design-2026-11-19.md` (kept in the author's research
notes); implementation proceeds milestone by milestone:

1. ✅ Source + primitives (range / boolean / index / length), replay,
   per-attempt seed derivation — with meta tests
2. ⬜ Comptime generation (bool, integers, enum, optional, arrays,
   slices, structs) + runner (`check` / `checkCustom`)
3. ⬜ Shrinking (chunk deletion / zeroing / power-of-two decrease)
4. ⬜ Mutant validation targets (varint, RLE) against pre-registered
   criteria

- License: MIT
- Zig: latest stable only (`minimum_zig_version = "0.17.0"`)
- Zero dependencies
