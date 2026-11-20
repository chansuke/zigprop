# zigprop

Property-based testing for Zig, built on integrated shrinking over
recorded choice sequences.

**Status: the latest release is v0.3.1.** v0.3.1 is a patch release: it
fixes compilation on 32-bit targets (v0.3.0 did not compile there) and
changes nothing in the public API. v0.3 settles the public API: the breaking
changes below land in one go, and no further breaks are planned.
Every pre-registered validation target is met on all 10 registered
seeds. That covers Phase 0's T1/T2
([docs/design-v2.md](docs/design-v2.md) §9), v0.2's T3/T4
([docs/design-v0.2.md](docs/design-v0.2.md) §4) and v0.3's T5–T9
([docs/design-v0.3.md](docs/design-v0.3.md) §8).
[docs/verification.md](docs/verification.md) maps the design
claims it enumerates to their evidence (tests, validation targets,
Lean proofs, TLA+ model checking, benchmarks) and lists the known
gaps, including what is argued rather than tested.

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

Values are generated from the type: bool, integers, floats
(f16/f32/f64), enums, tagged unions, optionals, arrays, slices,
structs, and recursive types built from them.

The entry points:

- `checkWith(gpa, T, Ctx, ctx, generator, property, config)` is the
  general form. `ctx` is handed to the property and to an optional
  custom generator (`null` means generate from the type). The
  property is `fn (Ctx, *zigprop.Case, T) anyerror!bool`, and
  `case.allocator` is the attempt's arena.
- `check(gpa, T, property, config)` and
  `checkCustom(gpa, T, generator, property, config)` are the simple
  forms, with a plain `fn (T) bool` property. Their signatures are
  unchanged from v0.2.
- Each of the three has an `*OrError` wrapper for test blocks:
  `checkOrError`, `checkCustomOrError` and `checkWithOrError`.
- `forAll` is reserved and deliberately not defined.

The non-wrapper forms return a `Report` (`passed`, `failed` or
`gave_up`; always call `deinit`) and never print.

The wrappers print and return `error.PropertyFailed` on a failure,
or `error.GaveUp` when the discard budget ran out. The printout
names the failure's origin (seed and attempt, or the regression
entry), the failure kind, the original and shrunk values, and a
regression entry to paste.

### Failures and errors

- A property that returns `false` fails with kind `returned_false`.
- A property that returns an error fails with kind
  `returned_error(e)`, whatever the error's name (`OutOfMemory`
  included). It never escapes into `check`'s error set.
- Shrinking keeps the kind: a candidate is accepted only if it fails
  in the same way.
- Displays are regenerated from the final choice sequences without
  calling the property again, so a property that mutates its input
  cannot corrupt the reported value. A type that declares `format` is
  shown with `{f}`, anything else with `{any}`. `{any}` does not use
  the `format` of types nested inside the value.
- Known limitation: errors returned by a **custom generator** are not
  failures. Apart from `error.InvalidGeneration`, which discards the
  case, they propagate out of `check` / `checkCustom` / `checkWith`
  as errors, in the same error set as the library's own (such as
  `error.InvalidConfig`). They cannot be told apart from those by
  name (design v0.3 §10 F3).

### Custom generators

A generator draws through `GenContext` methods: `range`, `boolean`,
`index`, `length`, `generate` and `countElement`.

```zig
fn genSmall(ctx: *zigprop.GenContext) anyerror!u32 {
    return @intCast(ctx.range(1000));
}
// try zigprop.checkCustomOrError(gpa, u32, genSmall, prop, .{});
```

### Regressions

Paste the printed entry into `tests/regressions.zon` under
`.entries`. The entry is printed in `zig fmt`'s form, so the file
stays fmt-clean. Then hand the entries to `Config`:

```zig
test "sorting sorts" {
    const file: zigprop.RegressionFile = @import("regressions.zon");
    try zigprop.checkWithOrError(std.testing.allocator, []const u32, void, {}, null, sortsCorrectly, .{
        .regressions = file.entries,
        .regression_id = "sorting",
    });
}
```

Each entry records its `gen_version` and a **fingerprint**: a
structural hash of the generated type, plus the `Limits` that can
affect it. Field and type names are not part of the hash, and
`max_len` / `max_depth` count only when the type contains a slice or
recursion.

An entry that no longer matches is reported as **stale** rather than
replayed as if it still meant the same input. Causes:

- another generator version;
- a different fingerprint;
- a replay that was discarded;
- a replay that passed without consuming the whole entry.

A real failure is always reported as a failure. Entries without a
fingerprint (hand-written, or from v0.2) still replay and are counted
as `unverified`.

The wrappers print every stale entry. With
`Config.fail_on_stale = true` (default `false`) they also return
`error.StaleRegression` once the property passes.

Known miss: a change inside a custom generator that keeps the same
draw shape is not detected.

## What changed in v0.3

- **Recursive types: channel-relative cuts.** At the depth limit,
  only the fields and variants that lead back to the recursive type
  are cut. Everything else in a cut value is generated normally. A cut
  union picks among its admissible variants with a tag draw, instead
  of always taking the first.
- **Distributions (random mode only).** One integer class is
  log-uniform over the bit width, so mid-range values such as
  2^21–2^28 are drawn regularly. Floats gain a class of
  moderate-magnitude normal values. This change alone does not
  change what a recorded sequence replays to.
- **Shrinking.** Two new passes:
  - subtree promotion: a failing node replaces its ancestor;
  - element deletion: a slice element is removed together with its
    length.

  Larger chunk deletion runs at the fixed point, and the shrinker
  stops as soon as the budget runs out. The passes use span
  annotations that generation records as metadata only. Acceptance
  is unchanged. A candidate must still fail, and its key sequence must
  be strictly smaller. The one exception, as before, is the
  re-expression pass's key-equal move.
- **Regressions.** Fingerprints, stale detection, a typed
  `RegressionFile`, and pasteable entries (see above).
- **API.** `checkWith`, `Case`, failure kinds, named report payloads
  (`Report.Passed` / `Failed` / `GaveUp`, `Origin`,
  `RegressionSummary`), and a core that never prints.

### Breaking changes (no compatibility layer)

| | v0.2 | v0.3 |
|---|---|---|
| Custom generators | `ctx.src.range(256)`, `ctx.src.length(n)` | `ctx.range(256)`, `ctx.length(n)` (`GenContext` has methods only) |
| Internals | `zigprop.Source`, `deriveSeed`, `shrink`, `ShrinkResult` | `zigprop.internal.*`, with no stability promise |
| Report fields | `regressions_passed`, `stale_regressions`, `seed`, `attempt_index`, `regression_index` | `regressions.passed`, `regressions.stale`, `origin.random.{seed, attempt_index}`, `origin.regression.index` |
| Stale warnings | printed by the core | in the `Report`, printed only by `*OrError` |
| Displays | formatted after the property ran | regenerated from the choice sequence |
| `generator_version` | 1 | **2** |

`generator_version = 2` means every entry recorded by v0.2 is now
stale (`gen_version_mismatch`) and is not replayed: the cut change
alters what a recorded sequence generates for recursive types. There
is no migration tool. Re-run the test and paste the newly printed
entry.

`Config`'s existing fields, `Limits` and the ZON file format are
unchanged.

## Development

Run the tests with `zig build test` (152 tests) and the validation
targets with `zig build validation` (T1–T9). Formatting is checked
with
`zig fmt --check src tests bench validation build.zig build.zig.zon`.

- License: MIT
- Zig: developed and CI-tested against the latest stable (0.17.1).
  `minimum_zig_version = "0.17.0"` is the consumer floor within the
  0.17 line. Master is CI early-warning only.
- Zero dependencies
