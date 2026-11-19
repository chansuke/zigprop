# Verification map

Correspondence table between the design properties currently
enumerated and their evidence — mathematical models, finite model
checking, and implementation tests. Completeness of the enumeration
and fidelity of the models to the implementation are **not**
guaranteed; the known-gaps section is part of the map. Wording was
tightened after an external gap review (Codex / GPT-6.1-Sol,
2026-11-19); several claims were narrowed to what the evidence
actually shows, and the TLA+ model was remodelled where it diverged
from the design.

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
| 9 | `fixed_point` / `budget_exhausted` semantics (MF4) | The TLA+ model encodes pass rounds: `fixed_point` is reported only after a full round with no acceptance (`clean_finish`), `budget_exhausted` only at budget 0 before such a round completes. TLC-checked on 4 configurations |
| 10 | Termination | In the finite abstract model, under weak fairness on progress transitions and assuming each individual evaluation terminates, all runs reach `done` (TLC, 4 configurations). Implementation and user-callback termination are out of scope |
| 11 | `gave_up` semantics | In the model, `gave_up` holds exactly when discards exceed the budget (`MaxDiscards + 1`) before enough valid cases; pass/fail attempts are blocked after the exceed. A `MaxDiscards = 0` configuration is checked |
| 12 | Performance | Single-run microbenchmarks of some Source operations with pre-reserved recording capacity are recorded as a baseline (`bench/BASELINE.md`). Allocation behaviour, generators, runner and shrink performance are unmeasured |
| 13 | Integer distribution (§4.1) | The all-zero draw sequence yields value 0 for every integer type tested (u1/i1 through u64/i64); i8 generation over 300 fixed attempts reaches all of {-128, 127, 0, -1, 1, -127, 126} (`tests/meta2.zig`). Class frequencies and uniformity are not measured |
| 14 | Generation of composite types (§4) | Deterministic per seed and replay-faithful for a struct mixing ints, optional and slice (recorded sequences match exactly); slice lengths respect `max_len`; the element budget converts nested expansion into `error.InvalidGeneration`; enums with explicit tag values generate only named fields (`tests/meta2.zig`) |
| 15 | Runner classification and regressions (§5, §7) | Meta tests cover: passed case counting, failure snapshot surviving the attempt arena and replaying to a failing value, same-seed reproducibility of the failure (attempt + choices), gave_up at exactly `max_discards + 1` discards, regression fail short-circuit, passing/stale regression counting, `error.InvalidConfig` rejection. The TLA+ model (rows 8–11) covers the same protocol abstractly |
| 17 | §9 validation targets (measured 2026-11-19, `zig build validation`) | **T2 RLE: criterion MET** — discovered 10/10, shrunk to exactly a single run of length 256 on 10/10 seeds; the hand-written loop found failures but never the minimal input. **T1 varint: criterion NOT MET (pre-v2.1)** — discovered 10/10 but only 4/10 shrank to exactly 2^28; the other 6 converged to 4294967294 (2^32−2), a boundary-set element. Diagnosis: the D1 class draw disconnects choice-value shortlex from value simplicity — the boundary class cannot reach 2^28, and a class 3→1 decrease is shortlex-"smaller" while jumping to a huge value. Both correct codecs passed 10/10 (control). Superseded by row 18 after the v2.1 fix. Full data: the author's validation note of 2026-11-19 |
| 18 | Rank-normalized acceptance + P4 re-expression (design v2.1, §4.1/§6) | Source records a canonical key per choice (default = value); integer generation annotates its pair with the value's rank and skips the pair's second position; acceptance compares filtered key sequences by shortlex, and P4 accepts a key-equal rewrite of an integer pair into the full-domain class. Pinned by tests/meta4.zig (annotation shape; a boundary-class regression shrinks to exactly 2^28; a full-domain regression is not diverted). **§9 re-measured 2026-11-19 after the fix: T1 discovered 10/10, exact 2^28 10/10 — criterion MET; T2 unchanged, 10/10 exact, MET; controls 10/10.** Termination rests on the lexicographic measure (key shortlex, number of non-canonical pairs); no new formal proof — the Lean/TLA+ artifacts predate v2.1 and are not re-verified against it (see known gaps) |
| 16 | Shrinking (§6) | On the dedicated single-draw encoding, shrink reaches the exact minimum 10 for the property `x < 10` (design §8), from both random search and a regression entry; an already-minimal entry stays `fixed_point`. Budget accounting is cross-checked against an external generator-call counter, and the budget boundary is pinned both ways (exact fit = `fixed_point`, one less = `budget_exhausted`; an acceptance on the last unit still reports exhaustion next). Acceptance replaces the stored sequence only with a strictly shortlex-smaller re-recorded one (code-level rule in `tryAccept`); the `[]u8` test observes the final sequence no larger than the original and still failing. P1's unaligned chunk positions are pinned by a dedicated test. Post-review fixes (Sol, 2026-11-19): initialization OOM leak, budget control via flag instead of an error name, sticky-error priority over `InvalidGeneration`, P1 position stepping (`tests/meta3.zig`). The §9 mutant targets (varint / RLE across 10 seeds) are milestone 4 |

## Layers

- **Unit / meta tests** (`zig build test`, CI: ci.yml) — the
  implementation as written, on every push.
- **Lean** (`formal/lean`, CI: formal.yml) — the arithmetic core
  (normalization, zigzag, shortlex) as mathematics, independent of
  the implementation. Core-only Lean, no Mathlib; CI runs an axiom
  audit (`check-axioms.sh`) that fails on `sorryAx`; the sorry grep
  is an auxiliary check only.
- **TLA+ / TLC** (`formal/tla`, CI: formal.yml) — the runner/shrink
  *protocol* as a state machine, with choice sequences abstracted to
  shortlex ranks. Four configurations cover the empty failing set,
  rank 0, and a zero discard budget.
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
- Shortlex well-foundedness is not proved in Lean; the strict-order
  properties are. Loop termination in the implementation rests on
  the evaluation budget, modelled in TLA+ as a protocol property.
- Random-mode draw correctness (uniformity of `intRangeLessThan`
  usage), OOM paths beyond the sticky-error unit test, and replay
  exhaustion interplay are only partially tested.
- The GitHub Actions workflows ran for the first time on
  2026-11-19, after the repository went public: CI and Formal
  verification both passed (the Benchmarks workflow is on-demand
  and has not run yet). Actions are pinned by full commit SHA.
- Cross-platform behaviour (macOS, 32-bit `usize` in `length`) is
  untested.
- The v2.1 acceptance rule (key sequences, P4 re-expression) has no
  Lean/TLA+ counterpart yet: the formal artifacts model the v2
  protocol, whose rank abstraction happens to match the key view,
  but they were not re-checked against the v2.1 passes.
- The `regressions.zon` file itself is not parsed at runtime in
  Phase 0 (entries are passed via `Config.regressions`); its schema
  is the `Regression` struct, validated only by use in tests.
| 19 | v0.2 M1: float generation (design v0.2 §1) — sign-interleaved magnitude rank; purpose-built class mix (small ints / boundary / dyadic grid / full domain); NaN patterns collapse to infinity and pairs are keyed by the produced value's canonical rank | meta tests (tests/meta5.zig) | f16 class-3 mapping is exhaustive over all 65536 ranks (each non-NaN pattern produced once, NaN payloads collapse onto the infinities, keys equal produced ranks); f32/f64 landmark ranks, boundary and grid classes pinned; a class-0 regression shrinks to exactly 1.0; `x - x == 0` discovers and shrinks to infinity. Golden replay tests pin the pre-v0.2 generation paths (§0/SF5) |
| 20 | v0.2 M2: tagged union generation (design v0.2 §2) — tag index draw then payload draws; named variants only for non-exhaustive tags; untagged unions rejected at compile time | meta tests (tests/meta6.zig) | Draw shape and zero-draw form pinned by replay; the corrected §2.2 rule (MF4) is pinned both ways: a two-key .big failure shrinks to the one-key .none despite declaration order, and two one-key void variants shrink to the smaller tag index; nested union values format readably with {any} (NTH2) |
| 21 | v0.2 M3: recursive types (design v0.2 §3) — comptime ancestor tracking with an unfolding cap of 16, runtime depth budget (Limits.max_depth, default 8, validated against the cap), compositional cut forms | meta tests (tests/meta7.zig) | The file compiling at all is the §3.2 prerequisite (self / mutual / union-mediated recursion terminate at comptime); max_depth = 0 cuts every recursive occurrence with no length draw in cut form; depth restored across siblings and on the error path (both pinned by replay); a tree failure shrinks path-locally; max_depth above the cap is InvalidConfig. Two implementation bugs were caught by these tests during development: a defer scoped inside the depth-check block restored the depth immediately, and counting channel types (slices) as occurrences cut a value's own kids slice |
| 22 | v0.2 M4: pre-registered validation targets T3/T4 (design v0.2 §4), seeds 0-9, max_cases 200 | `zig build validation` | T3 (f32 codec, mutant drops mantissa low byte): discovered 10/10, subnormal reach 10/10 (the gate), and the exact mathematical minimum rank 2 (least positive subnormal) attained 10/10 with 17-40 shrink evaluations; the hand loop's best rank over 200 samples was ~1.2M-46M. T4 (recursive JSON-like union, mutant truncates every list to 2): discovered 10/10, exact structural minimum list[int 0, int 0, int 0] 10/10 with 102-305 evaluations; the no-shrink hand loop's best key length was 8-73. Correct-codec controls passed 10/10 for both. Both criteria MET |
