# zigprop

Property-based testing for Zig, built on integrated shrinking over
recorded choice sequences.

**Status: Phase 0 complete, not yet released.** The pre-registered
validation criteria ([docs/design-v2.md](docs/design-v2.md) §9) are
met for both targets: failures shrink to the exact minimal
counterexample (2^28 for a varint decoder that stops after 4 bytes;
a single run of length 256 for an RLE decoder that truncates run
lengths to u8). [docs/verification.md](docs/verification.md) maps
every design claim to its evidence: tests, Lean proofs, TLA+ model
checking and benchmarks.

## Usage

```zig
const std = @import("std");
const zigprop = @import("zigprop");

const prop = struct {
    fn run(xs: []const u32) bool {
        std.mem.sort(u32, @constCast(xs), {}, std.sort.asc(u32));
        return std.sort.isSorted(u32, xs, {}, std.sort.asc(u32));
    }
};

test "sorting sorts" {
    try zigprop.checkOrError(std.testing.allocator, []const u32, prop.run, .{});
}
```

On failure, `checkOrError` prints the seed, the original value and
the shrunk value, and returns `error.PropertyFailed`. Values are
generated from the type — bool, integers, enums, optionals, arrays,
slices and structs — and custom generators plug into `checkCustom`.

## Development

Milestones 1–4 (Source and primitives; comptime generation and the
runner; shrinking; the §9 mutant validation) and the design v2.1 fix
(rank-normalized shrink acceptance) are complete. Run the tests with
`zig build test` (54 tests) and the validation targets with
`zig build validation`.

- License: MIT
- Zig: developed and CI-tested against the latest stable (0.17.1);
  `minimum_zig_version = "0.17.0"` is the consumer floor within the
  0.17 line. Master is CI early-warning only
- Zero dependencies
