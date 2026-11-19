# Verification map

Every load-bearing claim of the Phase 0 design (v2) is tied to the
cheapest evidence that can actually falsify it. This file is the index;
keep it current when claims or evidence change.

| # | Design claim | Evidence | Where |
|---|---|---|---|
| 1 | A recorded choice is always valid: `bound == 0 or value < bound` (MF1) | Lean proof `normalize_always_valid`; meta test over bounds {1,2,3,7,1000,2^63,0} | `formal/lean/ZigpropFormal/Normalize.lean`, `tests/meta.zig` |
| 2 | The sentinel bound 0 passes values through; normalization is idempotent | Lean `normalize_sentinel`, `normalize_idempotent`; replay normalization meta test | Normalize.lean, `tests/meta.zig` |
| 3 | Replay of a recorded sequence regenerates the same values and the same sequence | Meta test (300 mixed-bound draws) | `tests/meta.zig` |
| 4 | Same seed + attempt reproduces a run; different attempts diverge | Meta tests; `deriveSeed` outputs pinned to fixed values | `tests/meta.zig`, `src/source.zig` |
| 5 | `deriveSeed` is the specified SplitMix64 mix | Fixed-value unit tests (constants are the spec) | `src/source.zig` |
| 6 | Signed generation: small rank ⇔ small magnitude; the zigzag encoding is a bijection (D1, MF7) | Lean `zigzagDecode_encode`, `zigzagEncode_decode`, `zigzagDecode_natAbs_le`, `zigzagEncode_le` | `formal/lean/ZigpropFormal/Zigzag.lean` |
| 7 | Shrink acceptance cannot cycle; stored length never grows (MF2, MF4) | Lean `shortlex_irrefl / _trans / _asymm / _length_le` | `formal/lean/ZigpropFormal/Shortlex.lean` |
| 8 | A counterexample is stored only after a confirmed failure; discard/pass never replace it (MF5) | TLA+ invariant `BestAlwaysFails`, `BestOnlyAfterFailure` (TLC, 3 configs) | `formal/tla/ZigpropRunner.tla` |
| 9 | `fixed_point` is reported only when no smaller failing candidate exists; `budget_exhausted` only at budget 0 (MF4) | TLA+ invariant `OutcomeConsistency` | ZigpropRunner.tla |
| 10 | Every run terminates (budget/case/discard counters are finite) | TLA+ property `Termination` under weak fairness | ZigpropRunner.tla |
| 11 | `gave_up` only on discard-budget exhaustion | TLA+ invariant `OutcomeConsistency` | ZigpropRunner.tla |
| 12 | Core throughput is understood before optimizing | Benchmarks + recorded baseline | `bench/`, `docs/profiling.md` |

## Layers

- **Unit / meta tests** (`zig build test`, CI: ci.yml) — the
  implementation as written, on every push.
- **Lean** (`formal/lean`, CI: formal.yml) — the arithmetic core
  (normalization, zigzag, shortlex) as mathematics, independent of the
  implementation. Core-only Lean, no Mathlib; `sorry`/`admit` are
  rejected in CI; key theorems depend only on `propext` and
  `Quot.sound`.
- **TLA+ / TLC** (`formal/tla`, CI: formal.yml) — the runner/shrink
  *protocol* as a state machine, with choice sequences abstracted to
  shortlex ranks. Three configurations check the empty and
  rank-0 failing sets as edge cases.
- **Benchmarks** (`zig build bench`, CI: smoke in ci.yml, full in
  bench.yml) — performance evidence, not correctness gates.

## Known gaps (honest list)

- The Lean model works over `Nat`; the implementation works over
  `u64`. The bridge (no overflow in normalization: `%` and the sentinel
  never overflow) is argued in the design, not machine-checked.
- Shortlex well-foundedness is *not* proved in Lean; the strict-order
  properties are. Loop termination in the implementation rests on the
  evaluation budget (finitely many evaluations), which the TLA+ model
  checks as a protocol property.
- The TLA+ model abstracts generators away: it cannot see distribution
  bugs (§4.1) or comptime generation bugs (§4). Those are milestone 2+
  test territory.
- Generator and runner claims (§4, §5 implementation) get their rows
  when milestones 2–3 land.
