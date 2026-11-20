# Verification map

Correspondence table between the design properties currently
enumerated and their evidence — mathematical models, finite model
checking, and implementation tests. Completeness of the enumeration
and fidelity of the models to the implementation are **not**
guaranteed; the known-gaps section is part of the map. Wording was
tightened after an external gap review (Codex / GPT-6.1-Sol,
2026-11-19); several claims were narrowed to what the evidence
actually shows, and the TLA+ model was remodelled where it diverged
from the design. Rows 24–33 and the v0.3 validation record cover
design v0.3 (`docs/design-v0.3.md`, M1–M7).

| # | Property | Evidence, scoped to what it actually establishes |
|---|---|---|
| 1 | Recorded choices are valid | In the Lean `Nat` model, normalization always yields a valid choice. For Source's normal random draws, recorded validity is checked for the enumerated bounds {1,2,3,7,1000,2^63,0} over finite samples (`formal/lean/ZigpropFormal/Normalize.lean`, `tests/meta.zig`) |
| 2 | Sentinel and replay normalization | The sentinel is the identity; normalization is idempotent for all bounds (Lean `normalize_idempotent_all`). Zig replay checks one bound-change case and one sentinel case (`tests/meta.zig`) |
| 3 | Replay fidelity | For one fixed bound sequence and draw count (300 draws), a normal replay reproduces the returned values and the re-recorded sequence (`tests/meta.zig`) |
| 4 | Determinism | The same derived seed and bound sequence reproduce the same finite Source sequence; one example pair of attempts (seed 42, attempts 0/1) is shown to diverge on one bound sequence (`tests/meta.zig`) |
| 5 | `deriveSeed` matches its specification | Outputs for 7 fixed inputs (including wrapping boundaries) are pinned by tests. Equivalence for all inputs is not proved; the pinned constants in `src/source.zig` are the spec |
| 6 | Zigzag rank encoding (D1, MF7) | Over unbounded `Int`/`Nat`, the encoding is a bijection with the specified sign order, the exact magnitude formula `(r+1)/2`, and magnitude monotonicity in the rank (Lean `Zigzag.lean`). The connection to finite integer types (rank ranges, minimum values) is not proved |
| 7 | Shortlex acceptance cannot cycle (MF2, MF4) | Over `List Nat`, shortlex is a strict partial order and acceptance never grows the stored length (Lean `Shortlex.lean`). That the implementation applies it to re-recorded consumed values is milestone-3 test territory, not yet verified |
| 8 | Counterexamples are stored only after confirmed failure (MF5) | In the finite abstract model (now including the regressions phase and infrastructure-error aborts), a stored rank always belongs to the fixed `Failing` set (TLA+ `BestAlwaysFails`). Evaluation handling and Report construction in the implementation are not yet verified |
| 9 | `fixed_point` / `budget_exhausted` semantics (MF4) | The TLA+ model encodes pass rounds: `fixed_point` is reported only after a full round with no acceptance (`clean_finish`), `budget_exhausted` only at budget 0 before such a round completes. TLC checks this on 5 configurations (`ZigpropRunner`, `Empty`, `Zero`, `NoDiscard`, `Ratchet`); the sixth, `RatchetBad`, is expected to fail (Layers) |
| 10 | Termination | In the finite abstract model, under weak fairness on progress transitions and assuming each individual evaluation terminates, all runs reach `done` (TLC, the same 5 configurations). Implementation and user-callback termination are out of scope |
| 11 | `gave_up` semantics | In the model, `gave_up` holds exactly when discards exceed the budget (`MaxDiscards + 1`) before enough valid cases; pass/fail attempts are blocked after the exceed. A `MaxDiscards = 0` configuration is checked |
| 12 | Performance | Single-run microbenchmarks of some Source operations with pre-reserved recording capacity are recorded as a baseline (`bench/BASELINE.md`). Allocation behaviour, generators, runner and shrink performance are unmeasured |
| 13 | Integer distribution (§4.1) | The all-zero draw sequence yields value 0 for every integer type tested (u1/i1 through u64/i64); i8 generation over 300 fixed attempts reaches all of {-128, 127, 0, -1, 1, -127, 126} (`tests/meta2.zig`). Class frequencies and uniformity are not measured |
| 14 | Generation of composite types (§4) | Deterministic per seed and replay-faithful for a struct mixing ints, optional and slice (recorded sequences match exactly); slice lengths respect `max_len`; the element budget converts nested expansion into `error.InvalidGeneration`; enums with explicit tag values generate only named fields (`tests/meta2.zig`) |
| 15 | Runner classification and regressions (§5, §7) | Meta tests cover: passed case counting, failure snapshot surviving the attempt arena and replaying to a failing value, same-seed reproducibility of the failure (attempt + choices), gave_up at exactly `max_discards + 1` discards, regression fail short-circuit, passing/stale regression counting, `error.InvalidConfig` rejection. The TLA+ model (rows 8–11) covers the same protocol abstractly |
| 16 | Shrinking (§6) | On the dedicated single-draw encoding, shrink reaches the exact minimum 10 for the property `x < 10` (design §8), from both random search and a regression entry; an already-minimal entry stays `fixed_point`. Budget accounting is cross-checked against an external generator-call counter, and the budget boundary is pinned both ways (exact fit = `fixed_point`, one less = `budget_exhausted`; an acceptance on the last unit still reports exhaustion next). Acceptance has two code paths, both requiring the re-recorded candidate to fail (since v0.3: with the same failure kind, row 28): `tryAccept`, used by every pass except P4, replaces the stored sequence only with one whose key sequence is strictly shortlex-smaller; `tryRatchet`, used by P4 only (design v2.1 / row 18), accepts a key-equal sequence of the same length that rewrites one integer or float pair from another class into class 3, a one-way move. The termination measure is the pair (key shortlex, number of pairs outside class 3). Lean proves that this order is well-founded over `List Nat × Nat` (`measureLt_wf` in `formal/lean/ZigpropFormal/Measure.lean`); that `tryAccept` and `tryRatchet` lower it is observed by the accept hook in `tests/meta9.zig`, not proved (known gaps). The `[]u8` test observes the final sequence no larger than the original and still failing. P1's unaligned chunk positions are pinned by a dedicated test. Post-review fixes (Sol, 2026-11-19): initialization OOM leak, budget control via flag instead of an error name, sticky-error priority over `InvalidGeneration`, P1 position stepping (`tests/meta3.zig`). The §9 mutant targets are rows 17/18; the v0.3 passes are row 26 |
| 17 | §9 validation targets (measured 2026-11-19, `zig build validation`) | **T2 RLE: criterion MET** — discovered 10/10, shrunk to exactly a single run of length 256 on 10/10 seeds; the hand-written loop found failures but never the minimal input. **T1 varint: criterion NOT MET (pre-v2.1)** — discovered 10/10 but only 4/10 shrank to exactly 2^28; the other 6 converged to 4294967294 (2^32−2), a boundary-set element. Diagnosis: the D1 class draw disconnects choice-value shortlex from value simplicity — the boundary class cannot reach 2^28, and a class 3→1 decrease is shortlex-"smaller" while jumping to a huge value. Both correct codecs passed 10/10 (control). Superseded by row 18 after the v2.1 fix. Full data: the author's validation note of 2026-11-19 |
| 18 | Rank-normalized acceptance + P4 re-expression (design v2.1, §4.1/§6) | Source records a canonical key per choice (default = value); integer generation annotates its pair with the value's rank and skips the pair's second position; acceptance compares filtered key sequences by shortlex, and P4 accepts a key-equal rewrite of an integer pair into the full-domain class. Pinned by tests/meta4.zig (annotation shape; a boundary-class regression shrinks to exactly 2^28; a full-domain regression is not diverted). **§9 re-measured 2026-11-19 after the fix: T1 discovered 10/10, exact 2^28 10/10 — criterion MET; T2 unchanged, 10/10 exact, MET; controls 10/10.** Termination rests on the lexicographic measure (key shortlex, number of non-canonical pairs). Lean proves the measure well-founded over `Nat` (`formal/lean/ZigpropFormal/Measure.lean`), not that the implementation's acceptances lower it; TLA+ models P4 only as the abstract `ShrinkRatchet` (see known gaps) |
| 19 | v0.2 M1: float generation (design v0.2 §1) — sign-interleaved magnitude rank; purpose-built class mix (small ints / boundary / dyadic grid / full domain); NaN patterns collapse to infinity and pairs are keyed by the produced value's canonical rank | Meta tests (`tests/meta5.zig`): f16 class-3 mapping is exhaustive over all 65536 ranks (each non-NaN pattern produced once, NaN payloads collapse onto the infinities, keys equal produced ranks); f32/f64 landmark ranks, boundary and grid classes pinned; a class-0 regression (choice 31 = +16; the class-0 list has no −0, so index 2k−1 is +k and 2k is −k) fails as a regression (`regression_index` asserted) and shrinks to exactly 1.0, while the passing entry (choice 32 = −16) is counted in `regressions_passed`; `x - x == 0` discovers and shrinks to infinity. Golden replay tests pin the pre-v0.2 generation paths (§0/SF5) |
| 20 | v0.2 M2: tagged union generation (design v0.2 §2) — tag index draw then payload draws; named variants only for non-exhaustive tags; untagged unions rejected at compile time | Meta tests (`tests/meta6.zig`): draw shape and zero-draw form pinned by replay; the corrected §2.2 rule (MF4) is pinned both ways: a two-key .big failure shrinks to the one-key .none despite declaration order, and two one-key void variants shrink to the smaller tag index; nested union values format readably with {any} (NTH2) |
| 21 | v0.2 M3: recursive types (design v0.2 §3) — canonical comptime unfolding state (the set of container types entered on the path, sorted by `@typeName`, plus a re-entry counter n capped at 16), runtime depth budget (Limits.max_depth, default 8, validated against the cap), compositional cut forms | Meta tests (`tests/meta7.zig`, `tests/meta8.zig`): the files compiling at all are the §3.2 prerequisite — self / mutual / union-mediated recursion (meta7) and types with several routes back to themselves (JSON-like list + obj→Pair, AST-like add + let→body, a struct with two self slices; meta8) terminate at comptime and compile quickly, because paths reaching a type with the same set and count share one instantiation; at max_depth = 0 every recursive occurrence below the root is generated in its cut form. The cut form changed in v0.3 (row 32): only the channels that reach the cut type are cut (a slice is empty with no length draw; a union draws `index(m)` among its admissible variants, with no draw when m = 1); every other field is generated normally in the post-limit state. Under v0.2 every field of a cut value took its zero form with no draws; depth restored across siblings and on the error path (both pinned by replay); a tree failure shrinks path-locally; max_depth above the cap is InvalidConfig. Two implementation bugs were caught by these tests during development: a defer scoped inside the depth-check block restored the depth immediately, and counting channel types (slices) as occurrences cut a value's own kids slice |
| 22 | v0.2 M4: pre-registered validation targets T3/T4 (design v0.2 §4), seeds 0-9, max_cases 200 | `zig build validation`: T3 (f32 codec, mutant drops mantissa low byte): discovered 10/10, subnormal reach 10/10 (the gate), and the exact mathematical minimum rank 2 (least positive subnormal) attained 10/10 with 17-40 shrink evaluations; the hand loop's best rank over 200 samples was ~1.2M-46M. Attainment 10/10 is confirmed, but the registered design did not isolate which shrink path dominates (boundary-class index descent vs P3 rank descent). T4 (recursive JSON-like union, mutant truncates every list to 2): discovered 10/10, exact structural minimum list[int 0, int 0, int 0] 10/10 with 102-305 evaluations; the no-shrink hand loop's best key length was 8-73. Correct-codec controls passed 10/10 for both. Both criteria MET |
| 23 | v0.2.1 fix batch (review of v0.2.0, 2026-11-19) — C1: comptime unfolding re-keyed from the ancestor path tuple to the canonical (set, n) state, so multi-path recursive types compile; I1: `cutExists` accepts void and zero-length arrays, making the void branch of the union cut live (design §3.3); I3: the vacuous float regression test repaired; `max_cases = 0` rejected as InvalidConfig | `tests/meta8.zig` (multi-path compile tests; void-variant cut with zero draws pinned by replay; an all-void union field no longer fails the cut; zero-length-array variants chosen as cut), the corrected class-0 test and the new passing-regression test in `tests/meta5.zig`, `regression_index != null` asserted on every regression-driven failure test (meta3/4/5/6/7), and the `max_cases = 0` test in `tests/meta2.zig`. Golden replay pins unchanged |
| 24 | v0.3 M1: golden extension (design v0.3 §7.4, D35): replay (R) and random (S) pins for every shape, recorded before any generation change | `tests/meta10.zig` (147 (R) and 40 (S) pins at M1: every integer width and class, the W = 8/16/17 boundaries, f16/f32/f64 in every class with five NaN patterns and ±0 compared bit-exactly, enums, optionals, arrays, nested slices, struct, union) and `tests/meta10_rec.zig` (the recursive-cut group, kept in its own file because M7 rewrites it). Recorded from unchanged v0.2.1 sources (commit 98c49e9). History: unchanged through M2–M5. At M6 the (R) pins changed in bound fields only (amendment A1). For this record that was re-checked with a word diff of `tests/meta10.zig` between 96c3773 and 87b6347: the (R) section has exactly 51 float class-draw bounds 4 → 5 and 7 integer class-2 bounds 65536 → R (u17, u32, u64, i17, i32, i64 and S3's u32 field), and no value, key, skip or consumed token changed. M7 did not touch `tests/meta10.zig`. At M7 (17dc373), the move to `generator_version` 2 re-recorded 2 (S) pins in `tests/meta10_rec.zig`, `random_json#1` and `random_json#3` (value, choices, keys, skips); this record was missing until pin-guard's history check found the gap (verification pipeline M4, 2026-11-20). Display strings are not pinned (§7.4; v0.2 §0's claim was retracted in M1, F1). Kind: pinned by tests |
| 25 | v0.3 M2: span annotations (§3.2, D18): one element span per slice element (with its length draw's position), one occurrence span per struct/union generation (with a type id), metadata only | `tests/meta9.zig` "spans: …" (5 tests: shapes, cut occurrences, union occurrences, stable type ids, well-formed spans under random generation). M2 exit (commit 053d923): every M1 pin passed unmodified, meta3's evaluation counts unchanged, T1–T4 per-seed evaluation counts identical to v0.2.1, so spans did not change generation or shrinking. Kind: pinned by tests |
| 26 | v0.3 M3: new shrink passes (§3, D17, D19–D22): P6 subtree promotion, P5 element deletion with the length draw lowered, P1b (chunk sizes 7, 6, 5, 3 at the fixed point), round P6 → P5 → P1 → P4 → P2 → P3 (+P1b), early exit after budget exhaustion (a flag, not an error); every new pass accepts only through `tryAccept` (row 16) | `tests/meta7.zig`: the tree failure now shrinks to `{7, []}`, keys `[14, 0]` (v0.2's `{0, [{7, []}]}` retracted in the test comment). `tests/meta9.zig`: P5 `[1, 7, 3]` → `[7]`, P6 lifts a deeply nested failing node, P1b deletes a size-3 chunk, the acceptance-monotonicity hook over T6/T7 shapes on seeds 0–9 (every non-lateral acceptance strictly shortlex-smaller), the internal pass mask, early exit (1 evaluation, then `budget_exhausted`). meta3 passed unchanged at M3, evaluation counts included. Termination of the new passes is **argued only** (§3.4: each acceptance decreases the row-16 measure, and the budget bounds the loop). Kind: pinned by tests; termination argued |
| 27 | v0.3 T6/T7 (§8.2; gates: found ≥ 8/10 and minimal ≥ 8/10, control 10/10) | T6 (tree, a node with value 7 miscounted, `max_len = 4`, `max_depth = 3`): found 10/10, minimal `{7, []}` 10/10, control 10/10: **MET**. T7 (`[]const u8`, an element 7 mis-summed): found 10/10, minimal `[7]` 10/10, control 10/10: **MET**. Measurement only: v0.2.1 (M0-e) T6 minimal 0/10 (7 never landed at the root), T7 minimal **8/10**. The registered prediction that v0.2.1 stops at `[0, …, 0, 7]` was wrong on 8 of the 10 seeds (amendment A2), so **T7's gate does not separate v0.3 from v0.2.1 on this seed set**; it is kept as registered. Ablations: P6 off still minimal 10/10 on T6 (P5 and P1b also lift these trees); P5 off minimal 8/10 at M3, 10/10 since M6's distribution change. So neither ablation isolates its pass on these seeds; only T6's v0.2.1 baseline (0/10) separates. Total evaluations T6 837, T7 555. Kind: gate; ablations and baselines measured only |
| 28 | v0.3 M4b: the new API (§5, D26–D32, D36): `checkWith` with a context and `*Case`, properties returning `anyerror!bool`, `Failure` kinds with P(C) = "fails with the same kind", every property error a failure whatever its name, named Report payloads and `Origin`, display regenerated without calling the property, `*OrError` ×3, the pasteable `regressionEntry`, the typed `RegressionFile`; the core never prints | `tests/meta12.zig` (14 tests: property errors never reach `check`'s error set, kind-preserving shrink, `returned_false`, context passing, regression and random origins, report ownership, OrError mapping, a mutating property cannot corrupt the original display, `{f}` vs `{any}`, the printed entry round-trips through `tests/meta12_entry.zon`, the empty and multi-choice entry forms, the `regressions.zon` import), and the same import in `tests/meta11.zig`. CI greps `src/` for `std.debug.print` outside the wrappers. T9 (T4 through `checkWith`, `case.allocator`, no globals): found 10/10, exact 10/10, shrunk choices identical to T4's on 10/10 seeds, 0 leaking seeds under `DebugAllocator`, control 10/10 with 0 leaks, no container-level T9 buffer: **MET**. T9e (decoder returns `error.UnexpectedLength`): found 10/10, failure `returned_error(UnexpectedLength)` 10/10, 245 hook-observed acceptances with 0 kind violations, 0 leaks: **MET**. A `{any}` display never uses a nested type's custom `format`, only a top-level one (M0-d). `tests/api_surface.zig` pins the names of zigprop's pub declarations (`internal` by name only), the `Report` and `Failure` tag names, and the `Config` and `Limits` field names with whether each has a default; it fixes names and shapes, not behaviour. Kind: pinned by tests; gate |
| 29 | v0.3 M5: structural fingerprint and stale detection (§4, D23–D25): FNV-1a over a canonical serialization (names and comptime fields excluded, recursion by back-reference), `max_len` kept only when a slice is reachable and `max_depth` only when a recursive type is, both kept for custom generators; the §4.5 decision table; `fail_on_stale` (default false) honored only by `*OrError` | `tests/meta11.zig` (16 tests: golden hashes for 12 types, rename invariance and shape sensitivity, limit normalization, reachability predicates, every decision-table row, `fail_on_stale`, the known miss pinned, a version-1 file without fingerprints). T8 (entries printed by `regressionEntry` for T1/T6/T7 failures on seeds 0–9, parsed back): every row 10/10, **MET**. Two deviations, both reported at M5: row (f) "variant added" uses T4's `Value` entries, since T1/T6/T7 have no union; row (j) uses a custom single-draw generator over T1's type and mutant. Row (j) is the **known miss**: a custom generator's mapping change with the same draw shape is not detected (10/10 missed, as documented). Kind: pinned by tests; gate |
| 30 | v0.3 M6: distribution (§2, D14–D16), random mode only: integer class 2 is log-uniform (one `{bound = R, value = rank}` choice, replayed as `range(R)`), floats gain class 4 (moderate magnitudes; class draw `range(5)`; canonical form still class 3); replay meaning unchanged, `generator_version` stayed 1 at M6 | `tests/meta10.zig`: class 2 replays as the rank for every width u1…u64 and i1…i64; a log-uniform width histogram for u64/i64 (65 × 1000 draws; 99.9% applied to the whole histogram, Bonferroni per bin [875, 1125] and chi-square < 104.7). The per-bin 99.9% interval [897, 1103] fails on this seed (width 14 = 1106, chi-square 73.4); the whole-histogram reading was chosen after seeing that, and is reported as such. Also: class 4 is finite, normal and within the exponent range for f16/f32/f64, with both signs; P4 ratchets class-2 and class-4 pairs to class 3 with equal keys. M6 exit: (R) pins changed only in bounds (row 24, re-checked); 13 meta10 and 3 meta10_rec (S) pins re-recorded after review (pin-guard counts 15 in meta10: the other 2, `random_f32#0/#1`, changed only in a class-draw bound in `choices`, 4 → 5); F2's fixed-seed tests re-run (meta5's seed-42 golden re-recorded; the passing class-0 regression test no longer relies on seed 0's first cases). Kind: pinned by tests |
| 31 | v0.3 T5/T5s (§8.2; gates: found ≥ 8/10 and minimal ≥ 8/10, control 10/10) and T5-F | T5 (u64 LEB128, the 4th byte of a 4-byte encoding ignored): found 10/10, minimal 2^21 = 2097152 10/10, control 10/10: **MET**. T5s (i64 zigzag, same mutant): found 10/10, minimal 2^20 = 1048576 10/10, control 10/10: **MET**. v0.2.1 (M0-e): found 0/10 on both, as predicted, so the discovery comes from the distribution change. Measurement only: 1780 evaluations and 10 P4 acceptances in total, for each of T5 and T5s. T5-F (no gate): 415/2000 f64 values with exponent in [−20, 20] and non-zero low 20 mantissa bits on v0.3, vs 8/2000 on v0.2.1 (scratch run at M6). Kind: gate; T5-F measured only |
| 32 | v0.3 M7: cut scope (§1.3, D12, D13): `reaches`, one `admissible` function shared by the existence check and the cut, `cutRel`; at a cut only the channels reaching the cut type stop, others generate post-limit (∅, cap); a cut union draws `index(m)` among its admissible variants | `tests/meta9.zig` "cut: …" (5 tests): the all-zero replay of the cut form agrees with `cutExistsRel` on 17 types, with the admissible sets and reachability edges of the zoo; Tree2's non-recursive fields are generated at the cut; a cut Json draws its tag among 4 admissible variants (`.str` and empty `.list` both observed); an independent recursive type below a cut nests at most one level (Tree3/Other); custom generators calling `generate` stay bounded for max_depth 0–3 (the `depth ≥ n` invariant, H1). `tests/meta8.zig` cut tests rewritten for v2 (void and zero-length-array variants chosen by a tag draw; non-reaching fields generated). The m = 1 "no tag draw" path (`src/gen.zig`) is pinned by `tests/meta9.zig` "cut: a single admissible variant (m = 1) draws no tag", and m = 0 is pinned unreachable for the listed types by "cut: every union a cut of a listed type meets has an admissible variant (m = 0 unreachable)". T4 held (10/10, 10/10). meta8 compile step, measured at M8 (1-s resolution, from `zig build --summary all`): 3 s when compiled alone, with the std cache warm; 4 s and 7 s in two fresh-cache full builds, which compile all 15 test binaries in parallel. M0-a measured 2 s, sequentially, on v0.2.1 and on the prototype. Termination of cut-form generation and of the comptime unfolding are **argued only** (§1.3). Kind: pinned by tests; termination argued |
| 33 | v0.3 M7: `generator_version = 2` (§7.1–7.3, D34): v1 entries are stale as `gen_version_mismatch` and are not replayed; no migration tool, no v1 switch | `tests/meta11.zig`: a v1-recorded entry that would fail if replayed is not replayed under version 2, and with `fail_on_stale` the wrapper returns `error.StaleRegression`; the version-1 ZON file's 3 entries are now all stale (before M7: 3 passed, 2 unverified). `tests/meta2.zig` "regressions: passing entries are counted, stale versions skipped" now uses a `gen_version = 1` entry. Printed entries carry `.gen_version = 2` (`tests/meta12.zig`, `tests/meta12_entry.zon`). The retired v1 recursive-cut pins are kept as comments in `tests/meta10_rec.zig`. Kind: pinned by tests |

## v0.3 validation record (final M8 run, 2026-11-19)

`zig build validation`, seeds 0–9, `max_cases = 200`, `shrink_budget = 2000`, at the M8 commit. Every §8.3 gate:

| Target | Gate | Result |
|---|---|---|
| T1 varint u32 (4-byte truncation) | found ≥ 8, 2^28 exact ≥ 8, control 10/10 | 10/10, 10/10, 10/10: **MET** (shrink evaluations 208–508) |
| T2 RLE (run length truncated to u8) | found ≥ 8, single run of 256 ≥ 8, control 10/10 | 10/10, 10/10, 10/10: **MET** (27–76) |
| T3 f32 codec (mantissa low byte dropped) | found ≥ 8, subnormal ≥ 8, control 10/10 | 10/10, 10/10, 10/10: **MET**; exact rank 2 10/10 (measured; 17–37) |
| T4 recursive union (lists truncated to 2) | found ≥ 8, `list[int 0 ×3]` ≥ 8, control 10/10 | 10/10, 10/10, 10/10: **MET** (145–176; v0.2.1: 102–305) |
| T5 u64 mid-range varint | found ≥ 8, 2^21 ≥ 8, control 10/10 | 10/10, 10/10, 10/10: **MET** |
| T5s i64 zigzag mid-range varint | found ≥ 8, 2^20 ≥ 8, control 10/10 | 10/10, 10/10, 10/10: **MET** |
| T6 tree, subtree promotion | found ≥ 8, `{7, []}` ≥ 8, control 10/10 | 10/10, 10/10, 10/10: **MET** |
| T7 slice, element deletion | found ≥ 8, `[7]` ≥ 8, control 10/10 | 10/10, 10/10, 10/10: **MET** (non-discriminating, row 27) |
| T8 (a)–(j), 21 row instances | each 10/10 | all 10/10: **MET**; (j) is the documented miss |
| T9 T4 via `checkWith` | found ≥ 8, exact ≥ 8, choices = T4's on every seed, 0 leaks, no global buffer | 10/10, 10/10, 10/10, 0, none: **MET** |
| T9e error path | found ≥ 8, kind reported on every discovery, 0 kind violations, 0 leaks | 10/10, 10/10, 0 of 245, 0: **MET** |

Measurement only (§8.3): evaluation counts and P4 acceptances (rows 27, 31, above); T5-F (row 31); T6/T7 ablations and v0.2.1 values (row 27); meta8 compile time (row 32). **Not measured:** T4's discard count (the harness does not print it) and the span bookkeeping overhead in the benchmarks.

Which milestone moved which number (per the milestone commits): M2, M4a, M4b and M5 left T1–T4 unchanged (M4a's and M4b's validation output was byte-identical to the previous milestone's). M3 left T1 and T3 unchanged, added one evaluation per seed to T2 (one P1b candidate) and changed T4 to 141–182 evaluations. M6 moved the per-seed numbers of T3, T4, T6 and T7 (M6 commit message). M7's effect on per-seed numbers was not recorded, because the session that implemented it was lost before reporting. The T9e acceptance count went from 243 (M4b, unchanged at M5) to 245 at M6 or M7. No gate result fell below its gate at any milestone, according to the milestone commits and the director's re-run of M7.

## Layers

- **Unit / meta tests** (`zig build test`, CI: ci.yml) — the
  implementation as written, on every push.
- **Lean** (`formal/lean`, CI: formal.yml) — the arithmetic core
  (normalization, zigzag, shortlex, the v2.1 measure) as
  mathematics, independent of the implementation. Core-only Lean, no Mathlib; CI runs an axiom
  audit (`check-axioms.sh`) that fails on `sorryAx`; the sorry grep
  is an auxiliary check only.
- **TLA+ / TLC** (`formal/tla`, CI: formal.yml) — the runner/shrink
  *protocol* as a state machine, with choice sequences abstracted to
  shortlex ranks. Six configurations: four cover the base protocol,
  the empty failing set, rank 0, and a zero discard budget;
  `Ratchet` adds P4's lateral move with the decrease check, and
  `RatchetBad` drops the check and must violate
  `AcceptsBoundedByMeasure`.
- **Benchmarks** (`zig build bench`, CI: smoke in ci.yml, full in
  bench.yml) — performance evidence, not correctness gates.

## Known gaps (honest list)

- The Lean model works over `Nat`/`Int`; the implementation works
  over `u64` and finite integer types. The bridge (no overflow in
  normalization; rank ranges for finite types) is argued in the
  design, not machine-checked. This applies to zigzag as well as
  normalization.
- The TLA+ rank abstraction is **not** a proven refinement of
  shortlex on choice sequences: TLC checks the protocol given the
  abstraction, not the sequence comparison, re-recording, or bounds
  handling of the implementation.
- The TLA+ model does not include the internal accept hook: the
  `before_choices` and `after_choices` fields that the verification
  pipeline's M8 added to `AcceptEvent` (reported from `shrinkWith`) are
  not reflected on the formal side.
- Lean proves shortlex and the v2.1 measure (key shortlex, pairs
  outside class 3) well-founded over `Nat` (`shortlex_wf`,
  `measureLt_wf`), with no `sorry`. It does not prove that the
  implementation's acceptances lower the measure, or that its `u64`
  keys compare like the `Nat` model. Loop termination in the
  implementation still rests on the evaluation budget, modelled in
  TLA+ as a protocol property.
- Random-mode draw correctness (uniformity of `intRangeLessThan`
  usage) and replay exhaustion interplay are only partially tested.
- OOM: `tests/oom.zig` fails each allocation of a run in turn, both
  from that point on and as a single transient failure, and requires
  `error.OutOfMemory` or the result of the run without failures
  (variant, origin, choices, shrunk choices, failure kind, evaluations,
  shrink outcome), with no leaks. `zig build test` covers `check` on
  `[]const u8` and `checkWith` on a recursive type; `zig build oom-full`
  adds `check` on a recursive type, `u32` and a recursive union,
  `checkWith` on `[]const u8`, `checkWithOrError`, and the regression
  replay path. Each case is one seed with small limits and budget, so
  other sizes, seeds, custom generators and the remaining entry points
  (`checkCustom`, `checkOrError`, `checkCustomOrError`) are not covered.
  A swallowed failure that leaves the result unchanged is not detected.
- The GitHub Actions workflows ran for the first time on
  2026-11-19, after the repository went public: CI and Formal
  verification both passed (the Benchmarks workflow is on-demand
  and has not run yet). Actions are pinned by full commit SHA.
- Cross-platform behaviour: macOS runs in CI (a macos-latest job,
  green at the v0.3.0 release). 32-bit `usize`: ci.yml has a
  non-blocking `test-32bit` job (`zig build test -Dtarget=x86-linux`)
  that has not run on Actions yet. Locally (2026-11-20, zig 0.17.1) all
  17 x86-linux test binaries compile, after two `u64`-into-`usize`
  fixes (`src/shrink.zig` `passChunks`, `tests/meta10.zig`), but this
  machine cannot run 32-bit executables at all (each binary, like a
  trivial test, exits with SIGILL), so no 32-bit test has run.
- The v2.1 acceptance rule (key sequences, P4 re-expression) is only
  partly mirrored formally. Lean proves shortlex well-founded
  (`shortlex_wf`) and the measure (key shortlex, pairs outside
  class 3) well-founded (`measureLt_wf`); `accept_decreases` and
  `ratchet_decreases` show that a shortlex-smaller key sequence, or
  equal keys with a smaller count, lowers the measure, which only
  restates their hypotheses. TLA+ models P4's lateral move as
  `ShrinkRatchet` over a rank and a count `nc`: TLC checks on
  `ZigpropRunnerRatchet.cfg` that acceptances stay within the
  measure bound, and `ZigpropRunnerRatchetBad.cfg` is the expected
  violation without the decrease check. Still without a formal
  counterpart: that `tryAccept` and `tryRatchet` accept only
  candidates meeting those hypotheses; the skip-filtered key
  sequences that `keyShortlexLess` compares, and their `u64`/`Nat`
  bridge; the rank annotation of integer pairs; and P4's rewrite
  itself (which pairs it counts and how it rewrites them).
- `regressions.zon` is imported at comptime as a typed
  `RegressionFile` (v0.3 D31; import tests in meta11/meta12) and
  passed via `Config.regressions`. It is not parsed at runtime, and
  entries are not appended automatically: both were decided out
  (D31, D32).
- v0.3: termination of the new shrink passes (P5, P6, P1b) and of
  cut-form generation is **argued only** (design v0.3 §3.4, §1.3), as
  is termination of the comptime unfolding. The tests show only that
  the listed types compile and that the measured runs finish.
- v0.3: the structural fingerprint does not detect a change inside a
  custom generator, or a change of meaning that keeps the same shape.
  T8 (j) pins this as a known miss.
- v0.3: the TLA+ and Lean artifacts were not re-checked. The new
  passes' acceptances are instances of `ShrinkAccept`, failure kinds
  read as a constant `Failing_k`, and a stale entry is observationally
  a `RegressionPass` (design v0.3 §11; one line in the TLA+ header).
  P4's lateral move is modelled abstractly as `ShrinkRatchet`, which
  keeps the rank and lowers a number `nc` of pairs outside class 3:
  `formal/tla/ZigpropRunnerRatchet.cfg` checks that acceptances are
  bounded by the measure (rank, `nc`) with the budget above that bound,
  and `formal/tla/ZigpropRunnerRatchetBad.cfg` shows the violation
  without the decrease check (`formal/tla/README.md`). The model does
  not check that `tryRatchet` counts or rewrites pairs that way. The
  Lean core (normalization, zigzag, shortlex) is unchanged by v0.3.
- v0.3: T7's gate, and on the current distribution both the T6 P6-off
  and the T7 P5-off ablations, do not separate their pass from the
  alternatives on the registered seeds (row 27).
