--------------------------- MODULE ZigpropRunner ---------------------------
(***************************************************************************)
(* Abstract model of zigprop's runner and shrink loop (design v2, §5-§7). *)
(*                                                                          *)
(* Choice sequences are abstracted to their shortlex rank: a natural      *)
(* number where smaller means simpler. `Failing` is the abstract set of   *)
(* ranks whose replay makes the property fail. This is a finite           *)
(* abstraction, not a proven refinement of shortlex on sequences: TLC     *)
(* checks the protocol rules below, not the sequence comparison itself.   *)
(* v0.3 passes are ShrinkAccept instances; stale is in RegressionPass.    *)
(* P4's lateral move (design v2.1) is ShrinkRatchet: the rank stays and   *)
(* `nc`, the number of pairs outside class 3, goes down. `nc` is a number *)
(* here; the model does not check that the implementation counts pairs or *)
(* rewrites them this way (see formal/tla/README.md).                     *)
(* v0.4 assumption (not modelled): P(C) is a function of C also when the  *)
(* property draws: the structure of its draws is deterministic (D48).     *)
(*                                                                          *)
(* Protocol rules modelled:                                               *)
(*  - regressions replay first; a failing regression enters shrinking     *)
(*    directly, otherwise the run moves on to random search;              *)
(*  - a counterexample is stored only after a confirmed failure;          *)
(*  - outcomes are pass / fail / discard / infrastructure error; only     *)
(*    fail replaces the stored counterexample. Infrastructure errors      *)
(*    abort the run immediately (outcome "aborted");                      *)
(*  - discards are tolerated up to MaxDiscards; the discard that exceeds  *)
(*    the budget ends the search with gave_up. Pass/fail attempts are     *)
(*    blocked once the budget is exceeded;                                *)
(*  - shrink proceeds in pass rounds. A round is a sequence of            *)
(*    evaluations (each spends one budget unit); a candidate is           *)
(*    accepted only if it fails AND is strictly smaller. The run          *)
(*    reports fixed_point only when a whole round completes with no       *)
(*    acceptance, and budget_exhausted only when the budget runs out      *)
(*    before such a round completes. Shrink discards consume budget       *)
(*    only, never the search discard counter (no action below touches     *)
(*    `discards` outside the search phase).                               *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxRank,     \* ranks are 0..MaxRank
    Failing,     \* subset of 0..MaxRank: ranks that fail the property
    MaxBudget,   \* shrink evaluation budget
    MaxCases,    \* valid cases to find before reporting "passed"
    MaxDiscards, \* discards tolerated before reporting "gave_up"
    MaxNC,       \* pairs outside class 3 are 0..MaxNC (0 disables P4)
    RatchetChecksDecrease \* TRUE: P4 accepts only a smaller nc

ASSUME Failing \subseteq 0..MaxRank
ASSUME RatchetChecksDecrease \in BOOLEAN

None == MaxRank + 1  \* sentinel: no counterexample stored

\* nc: pairs outside class 3 in the stored counterexample.
\* accepts: shrink acceptances so far (ShrinkAccept and ShrinkRatchet).
VARIABLES phase, best, budget, cases, discards, outcome,
          evaluated, changed, clean_finish, nc, accepts

vars == <<phase, best, budget, cases, discards, outcome,
          evaluated, changed, clean_finish, nc, accepts>>

Outcomes == {"none", "passed", "failed_fixed_point",
             "failed_budget_exhausted", "gave_up", "aborted"}

TypeOK ==
    /\ phase \in {"regressions", "searching", "shrinking", "done"}
    /\ best \in 0..None
    /\ budget \in 0..MaxBudget
    /\ cases \in 0..MaxCases
    /\ discards \in 0..(MaxDiscards + 1)
    /\ outcome \in Outcomes
    /\ evaluated \in BOOLEAN
    /\ changed \in BOOLEAN
    /\ clean_finish \in BOOLEAN
    /\ nc \in 0..MaxNC
    /\ accepts \in 0..MaxBudget  \* every acceptance spends one budget unit

Init ==
    /\ phase = "regressions"
    /\ best = None
    /\ budget = MaxBudget
    /\ cases = 0
    /\ discards = 0
    /\ outcome = "none"
    /\ evaluated = FALSE
    /\ changed = FALSE
    /\ clean_finish = FALSE
    /\ nc = 0
    /\ accepts = 0

\* --------------------------- regressions phase --------------------------

\* A confirmed failure stores a counterexample with any nc.
RegressionFail ==
    /\ phase = "regressions"
    /\ \E r \in Failing, n \in 0..MaxNC :
        /\ best' = r
        /\ nc' = n
        /\ phase' = "shrinking"
        /\ UNCHANGED <<budget, cases, discards, outcome,
                       evaluated, changed, clean_finish, accepts>>

RegressionPass ==
    /\ phase = "regressions"
    /\ phase' = "searching"
    /\ UNCHANGED <<best, budget, cases, discards, outcome,
                   evaluated, changed, clean_finish, nc, accepts>>

\* ------------------------- random search phase --------------------------

AttemptPass ==
    /\ phase = "searching"
    /\ cases < MaxCases
    /\ discards <= MaxDiscards
    /\ cases' = cases + 1
    /\ UNCHANGED <<phase, best, budget, discards, outcome,
                   evaluated, changed, clean_finish, nc, accepts>>

AttemptDiscard ==
    /\ phase = "searching"
    /\ discards <= MaxDiscards
    /\ discards' = discards + 1
    /\ UNCHANGED <<phase, best, budget, cases, outcome,
                   evaluated, changed, clean_finish, nc, accepts>>

AttemptFail ==
    /\ phase = "searching"
    /\ cases < MaxCases
    /\ discards <= MaxDiscards
    /\ \E r \in Failing, n \in 0..MaxNC :
        /\ best' = r
        /\ nc' = n
        /\ phase' = "shrinking"
        /\ UNCHANGED <<budget, cases, discards, outcome,
                       evaluated, changed, clean_finish, accepts>>

FinishPassed ==
    /\ phase = "searching"
    /\ cases = MaxCases
    /\ phase' = "done"
    /\ outcome' = "passed"
    /\ UNCHANGED <<best, budget, cases, discards,
                   evaluated, changed, clean_finish, nc, accepts>>

FinishGaveUp ==
    /\ phase = "searching"
    /\ discards = MaxDiscards + 1
    /\ cases < MaxCases
    /\ phase' = "done"
    /\ outcome' = "gave_up"
    /\ UNCHANGED <<best, budget, cases, discards,
                   evaluated, changed, clean_finish, nc, accepts>>

\* ----------------------------- shrink phase -----------------------------

\* P1-P3, P5, P6, P1b (tryAccept): the rank goes down; the new
\* counterexample's nc is anything, it may grow.
ShrinkAccept ==
    /\ phase = "shrinking"
    /\ budget > 0
    /\ \E r \in Failing, n \in 0..MaxNC :
        /\ r < best
        /\ best' = r
        /\ nc' = n
        /\ budget' = budget - 1
        /\ evaluated' = TRUE
        /\ changed' = TRUE
        /\ accepts' = accepts + 1
        /\ UNCHANGED <<phase, cases, discards, outcome, clean_finish>>

\* P4 (tryRatchet): a key-equal rewrite, so the rank stays. With the
\* decrease check nc goes down; without it nc may stay, a lateral move
\* that changes nothing the measure sees.
ShrinkRatchet ==
    /\ phase = "shrinking"
    /\ budget > 0
    /\ best # None
    /\ nc > 0
    /\ \E n \in (IF RatchetChecksDecrease THEN 0..(nc - 1) ELSE 0..nc) :
        /\ nc' = n
        /\ budget' = budget - 1
        /\ evaluated' = TRUE
        /\ changed' = TRUE
        /\ accepts' = accepts + 1
        /\ UNCHANGED <<phase, best, cases, discards, outcome, clean_finish>>

ShrinkReject ==
    /\ phase = "shrinking"
    /\ budget > 0
    /\ budget' = budget - 1
    /\ evaluated' = TRUE
    /\ UNCHANGED <<phase, best, cases, discards, outcome,
                   changed, clean_finish, nc, accepts>>

StartNextRound ==
    /\ phase = "shrinking"
    /\ evaluated = TRUE
    /\ changed = TRUE
    /\ evaluated' = FALSE
    /\ changed' = FALSE
    /\ UNCHANGED <<phase, best, budget, cases, discards, outcome,
                   clean_finish, nc, accepts>>

FinishFixedPoint ==
    /\ phase = "shrinking"
    /\ evaluated = TRUE
    /\ changed = FALSE
    /\ phase' = "done"
    /\ outcome' = "failed_fixed_point"
    /\ clean_finish' = TRUE
    /\ UNCHANGED <<best, budget, cases, discards, evaluated, changed,
                   nc, accepts>>

FinishBudgetExhausted ==
    /\ phase = "shrinking"
    /\ budget = 0
    /\ ~ (evaluated = TRUE /\ changed = FALSE)
    /\ phase' = "done"
    /\ outcome' = "failed_budget_exhausted"
    /\ UNCHANGED <<best, budget, cases, discards,
                   evaluated, changed, clean_finish, nc, accepts>>

\* ------------------------- infrastructure errors ------------------------

InfraError ==
    /\ phase \in {"regressions", "searching", "shrinking"}
    /\ phase' = "done"
    /\ outcome' = "aborted"
    /\ UNCHANGED <<best, budget, cases, discards,
                   evaluated, changed, clean_finish, nc, accepts>>

DoneStep ==
    /\ phase = "done"
    /\ UNCHANGED vars

Next ==
    \/ RegressionFail
    \/ RegressionPass
    \/ AttemptPass
    \/ AttemptDiscard
    \/ AttemptFail
    \/ FinishPassed
    \/ FinishGaveUp
    \/ ShrinkAccept
    \/ ShrinkRatchet
    \/ ShrinkReject
    \/ StartNextRound
    \/ FinishFixedPoint
    \/ FinishBudgetExhausted
    \/ InfraError
    \/ DoneStep

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ------------------------------ invariants ------------------------------

\* A stored counterexample is always a confirmed failure (design §5:
\* the Report is built only from the last confirmed failing state).
BestAlwaysFails ==
    best # None => best \in Failing

\* Nothing is stored before a failure has been confirmed.
BestOnlyAfterFailure ==
    phase \in {"regressions", "searching"} => best = None

\* The reported outcome is consistent with the state it was reached in.
OutcomeConsistency ==
    /\ (phase = "done") <=> (outcome # "none")
    /\ outcome = "passed" => best = None
    /\ outcome \in {"failed_fixed_point", "failed_budget_exhausted"}
        => best \in Failing
    /\ outcome = "failed_fixed_point" => clean_finish = TRUE
    /\ outcome = "failed_budget_exhausted" => budget = 0
    /\ outcome = "gave_up"
        => discards = MaxDiscards + 1 /\ cases < MaxCases

\* Acceptances are bounded by the measure (rank, nc), not by the budget.
\* Derivation: shrinking starts only after a confirmed failure, so best
\* is a failing rank in 0..MaxRank whenever ShrinkAccept or ShrinkRatchet
\* is enabled; the sentinel None never takes part in an acceptance
\* (BestAlwaysFails, BestOnlyAfterFailure). The measure therefore takes
\* (MaxRank + 1) * (MaxNC + 1) values. ShrinkAccept lowers the rank and
\* ShrinkRatchet (with the decrease check) keeps the rank and lowers nc,
\* so each acceptance moves the pair strictly down in lexicographic order.
\* A strictly descending chain through N values has at most N - 1 steps.
AcceptsBoundedByMeasure ==
    accepts <= (MaxRank + 1) * (MaxNC + 1) - 1

\* One below the bound. ZigpropRunnerRatchetTight.cfg expects TLC to
\* violate it, which shows the bound above is reached, not just respected.
AcceptsBelowMeasureBound ==
    accepts <= (MaxRank + 1) * (MaxNC + 1) - 2

\* ------------------------------ liveness --------------------------------

\* Under weak fairness on progress, every run eventually finishes.
\* Scope: this is a statement about the finite abstract model with
\* atomic evaluations; it assumes each individual evaluation (the
\* user's property and generators) terminates.
Termination == <>(phase = "done")

=============================================================================
