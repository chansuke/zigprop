# zigprop

Property-based testing for Zig, built on integrated shrinking over
recorded choice sequences.

**Status: the latest release is v0.4.0.** v0.4 adds interactive draws —
`case.generate(T)`, `case.index(n)`, `case.choose(E, enabled)` and
`case.steps(max)` — so a property can draw values that depend on what
it has already done, and model-based stateful testing is documented as
a recipe on top of them. The public API only grows: nothing from v0.3
is changed or removed, and `generator_version` stays 2. v0.3 settles
the public API: the breaking
changes below land in one go, and no further breaks are planned.
Every pre-registered validation target is met on all 10 registered
seeds. That covers Phase 0's T1/T2
([docs/design-v2.md](docs/design-v2.md) §9), v0.2's T3/T4
([docs/design-v0.2.md](docs/design-v0.2.md) §4), v0.3's T5–T9
([docs/design-v0.3.md](docs/design-v0.3.md) §8) and v0.4's T10–T14
([docs/design-v0.4.md](docs/design-v0.4.md) §4).
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

### Drawing inside the property (v0.4, unreleased)

A property can draw more values while it runs, so a later draw can
depend on what earlier steps did. The draws land in the same choice
sequence as the generated value, so they shrink, replay and persist
with it.

- `case.generate(T)` draws a T through the same path as the value's
  generation.
- `case.index(n)` draws an index in `[0, n)`.
- `case.choose(E, enabled)` picks one tag from a `std.EnumSet(E)`.
  It always makes exactly one draw, keyed by the tag's position among
  the enabled tags in declaration order.
- `case.steps(max)` draws a step count once. `next()` then opens one
  step at a time, and the shrinker deletes steps the same way it
  deletes slice elements.
- `index(0)`, an empty `choose` set and a draw past the element budget
  discard the case. A property that returns `error.InvalidGeneration`
  itself still fails.
- `T = void` generates nothing, so a property that draws everything
  itself takes `void` as its input.

The recipe for a stateful test (model-based testing) needs no
framework:

1. Choose the operation with `choose`, from the operations the model
   allows in its current state.
2. Draw the payload for that operation against the model.
3. Give each check its own error name.

This is the slot-map target T10 as it runs in `validation/main.zig`.
`SlotMap` (capacity 4, generation-checked handles) and `SlotModel`
are defined there.

```zig
const Op = enum { insert, remove, get };

fn slotMapProp(cfg: *const Cfg, case: *zigprop.Case, _: void) anyerror!bool {
    const a = case.allocator;
    var sut: SlotMap = .{ .mutant = cfg.mutant };
    var model: SlotModel = .{};
    var s = case.steps(16);
    while (s.next()) {
        var en: std.EnumSet(Op) = .empty;
        if (model.live.items.len < SlotMap.cap) en.insert(.insert);
        if (model.live.items.len > 0) en.insert(.remove);
        if (model.issued.items.len > 0) en.insert(.get);
        switch (try case.choose(Op, en)) {
            .insert => {
                const v = try case.generate(u8);
                const h = sut.insert(v).?;
                if (model.wasIssued(h)) return error.HandleReused;
                try model.insert(a, h, v);
            },
            .remove => {
                const h = model.live.items[try case.index(model.live.items.len)];
                if (!sut.remove(h)) return error.RemoveMismatch;
                model.remove(h);
            },
            .get => {
                const h = model.issued.items[try case.index(model.issued.items.len)];
                if (!std.meta.eql(sut.get(h), model.get(h))) return error.GetMismatch;
            },
        }
    }
    return true;
}

// try zigprop.checkWithOrError(gpa, void, *const Cfg, &cfg, null, slotMapProp, .{});
```

- **One error name per check.** Shrinking accepts only candidates that
  fail with the same kind, so a separate name keeps the shrink on the
  violation it found. With a bare `return false`, every check is the
  same `returned_false`, and the shrink can slide from one violation
  to another.
- **Determinism contract.** The property must be a deterministic
  function of its context, the values it draws and `case.allocator`.
  Build the system under test and the model inside the property on
  every evaluation (`case.allocator` is the evaluation's arena), and
  carry no state across evaluations. A property that breaks this can
  report a sequence that does not fail again. When the property drew
  on the shrunk sequence, `Report.Failed.reproduced` records one
  replay of it under regression conditions. A single replay catches
  only some violations (validation target T13).
- A failure prints a `drawn:` section after `shrunk:`. It shows one
  line per step and marks the last step as where the property failed.
  The values are rebuilt from the choices, so the property is not
  called again. The state of the model and the system under test at
  the failure is not shown. Replay the printed entry to inspect it.
- A regression entry recorded from a drawing property carries
  `.property_draws = true` in its fingerprint and keeps every limit.
  A reordered `Op` enum with the same draw shape is a known miss: the
  entry replays as a different operation sequence and passes.

What this does and does not show:

- No user scenario backs it yet. The slot map in this repository is a
  bug the designer planted, not a report from a real user.
- The v0.3 way of writing the same test, a `[]const Cmd` whose indices
  are read modulo the live handles (B2 in design v0.4 §4), finds the
  same bug just as often and shrinks to the same minimal key sequence
  (T10's measurements). In-property draws do not find more bugs. They
  avoid the trap of blind encodings, which never hit a live handle
  (B1: 0/10). They also give keys bounded by the state, a display of
  only what ran, and draws whose number and type depend on state.

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
targets with `zig build validation` (T1–T9e, then v0.4's T10–T14). Formatting is checked
with
`zig fmt --check src tests bench validation build.zig build.zig.zon`.

- License: MIT
- Zig: developed and CI-tested against the latest stable (0.17.1).
  `minimum_zig_version = "0.17.0"` is the consumer floor within the
  0.17 line. Master is CI early-warning only.
- Zero dependencies
