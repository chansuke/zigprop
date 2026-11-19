# zigprop

Property-based testing for Zig, built on integrated shrinking over
recorded choice sequences.

**Status: v0.2.1 released.** The Phase 0
pre-registered validation criteria
([docs/design-v2.md](docs/design-v2.md) §9) are met for both
targets: failures shrink to the exact minimal counterexample
(2^28 for a varint decoder that stops after 4 bytes; a single run
of length 256 for an RLE decoder that truncates run lengths to
u8). v0.2 adds floats (f16/f32/f64), tagged unions and recursive
types, and its pre-registered validation targets
([docs/design-v0.2.md](docs/design-v0.2.md) §4) are also met:
the float codec target reaches the exact minimum (rank 2, the
least positive subnormal) and the recursive-union target the
exact structural minimum, each on all 10 registered seeds.
[docs/verification.md](docs/verification.md) maps
every design claim to its evidence: tests, Lean proofs, TLA+
model checking and benchmarks.

## Usage

```zig
const std = @import("std");
const zigprop = @import("zigprop");

fn sortsCorrectly(_: void, case: *zigprop.Case, xs: []const u32) !bool {
    // Sort a copy in the per-case arena; the generated input is left
    // as it was, so a failure reports the value that was generated.
    const copy = try case.allocator.dupe(u32, xs);
    std.mem.sort(u32, copy, {}, std.sort.asc(u32));
    return std.sort.isSorted(u32, copy, {}, std.sort.asc(u32));
}

test "sorting sorts" {
    try zigprop.checkWithOrError(std.testing.allocator, []const u32, void, {}, null, sortsCorrectly, .{});
}
```

On failure, `checkWithOrError` prints where the failure came from
(seed and attempt, or the regression entry), the failure kind, the
original and shrunk values, and a regression entry to paste into
`tests/regressions.zon`, and returns `error.PropertyFailed`. A
property may return an error: that is a failure too, and shrinking
keeps its kind. Values are generated from the type — bool, integers,
floats (f16/f32/f64), enums, tagged unions, optionals, arrays,
slices, structs and recursive types built from them — and custom
generators plug into `checkCustom` / `checkWith`. The simple forms
`check`, `checkCustom` and `checkOrError` take a plain
`fn (T) bool` property.

## Development

Milestones 1–4 (Source and primitives; comptime generation and the
runner; shrinking; the §9 mutant validation) and the design v2.1 fix
(rank-normalized shrink acceptance) are complete. Run the tests with
`zig build test` (89 tests) and the validation targets with
`zig build validation`.

- License: MIT
- Zig: developed and CI-tested against the latest stable (0.17.1);
  `minimum_zig_version = "0.17.0"` is the consumer floor within the
  0.17 line. Master is CI early-warning only
- Zero dependencies
