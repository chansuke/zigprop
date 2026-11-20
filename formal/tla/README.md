# TLA+ model of the runner and shrink loop

`ZigpropRunner.tla` is a finite abstract model of zigprop's runner and
shrink protocol (design v2, §5–§7, with one v0.3 header note and P4 from
design v2.1). A choice sequence is abstracted to its shortlex rank, a
number where smaller means simpler. `nc` is the number of pairs outside
class 3 in the stored counterexample.

## Scope

The model checks properties of the acceptance rules stated over these
numbers. It does not show that the implementation follows the rules.
TLC does not see `tryAccept`, `tryRatchet`, the key comparison, or how
pairs are counted and rewritten. `formal/manifest.zon` records which
implementation functions this model corresponds to, and the lint rule
`formal-drift` reports when they change. `tests/meta9.zig` observes the
implementation's acceptances through the accept hook.

## Configurations

| Configuration | Purpose | Expected result |
|---|---|---|
| `ZigpropRunner.cfg` | The protocol with failing ranks {2, 3, 5} | No error |
| `ZigpropRunnerEmpty.cfg` | No rank fails: the run must pass | No error |
| `ZigpropRunnerZero.cfg` | Only rank 0 fails: the first failure is already minimal | No error |
| `ZigpropRunnerNoDiscard.cfg` | No discards tolerated | No error |
| `ZigpropRunnerRatchet.cfg` | P4's lateral move with the decrease check, budget with room above the measure bound | No error |
| `ZigpropRunnerRatchetBad.cfg` | The same without the decrease check | `AcceptsBoundedByMeasure` is violated |

The first four set `MaxNC = 0`, so `ShrinkRatchet` is never enabled.
Their state counts grew where a run can accept more than once
(`ZigpropRunner.cfg` 589 → 814 distinct states, `ZigpropRunnerNoDiscard.cfg`
205 → 280), because the new `accepts` counter tells apart runs that reach
the same state with different numbers of acceptances. With a TLC `VIEW`
of the pre-ratchet variables only, both give the pre-ratchet counts again
(589 and 205).

All invariants: `TypeOK`, `BestAlwaysFails`, `BestOnlyAfterFailure`,
`OutcomeConsistency`, and, for the two ratchet configurations,
`AcceptsBoundedByMeasure`. All configurations except `RatchetBad` also
check the liveness property `Termination`.

## Run

Use the checksum-pinned `tla2tools.jar` (see `.github/workflows/formal.yml`)
and Java 21:

```sh
cd formal/tla
java -jar tla2tools.jar -config ZigpropRunnerRatchet.cfg ZigpropRunner.tla
```

TLC writes its state files to `formal/tla/states`. Pass
`-metadir <dir>` to put them elsewhere. When TLC finds a violation, it
also writes `ZigpropRunner_TTrace_<n>.tla` and `.bin` next to the spec.
Do not commit them.

## Why `tryRatchet` must check that `nc` goes down

`AcceptsBoundedByMeasure` says that the number of acceptances is at most
the measure bound, independently of the budget. In
`ZigpropRunnerRatchet.cfg` the bound is (3 + 1) × (2 + 1) − 1 = 11, and
TLC reaches 11 acceptances, so the bound is tight. `MaxBudget = 16`
leaves room for more than 11 acceptances, so the budget alone does not
make the check hold. The measure bounds acceptances only, not the run:
`ShrinkReject` also spends a budget unit and leaves the measure
unchanged, so a run can exhaust the budget with no acceptance at all.

Without the decrease check, a lateral move may keep `nc` unchanged. Then
nothing the measure sees changes, and only the budget stops the
acceptances. TLC finds this counterexample in
`ZigpropRunnerRatchetBad.cfg` (TLC2 Version 2026.11.19.180144,
`Error: Invariant AcceptsBoundedByMeasure is violated.`). The trace below
keeps the variables that change. In every state `cases = 0`,
`discards = 0`, `outcome = "none"` and `clean_finish = FALSE`.

| State | Action | phase | best | nc | budget | accepts | evaluated | changed |
|---|---|---|---|---|---|---|---|---|
| 1 | Initial predicate | regressions | 4 (None) | 0 | 16 | 0 | FALSE | FALSE |
| 2 | RegressionFail | shrinking | 1 | 0 | 16 | 0 | FALSE | FALSE |
| 3 | ShrinkAccept | shrinking | 0 | 1 | 15 | 1 | TRUE | TRUE |
| 4–13 | ShrinkRatchet (10 times) | shrinking | 0 | 1 | 14 → 5 | 2 → 11 | TRUE | TRUE |
| 14 | ShrinkRatchet | shrinking | 0 | 0 | 4 | 12 | TRUE | TRUE |

States 4 to 13 are lateral moves from (0, 1) to (0, 1). Each one spends a
budget unit and counts as an acceptance, but the measure does not move.
State 14 is the 12th acceptance, one more than the 11 that the measure
allows. This is the deterministic evidence that `tryRatchet` has to
require a decrease. A ratchet that accepts an equal count is bounded by
the budget alone.
