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
    MaxDiscards  \* discards tolerated before reporting "gave_up"

ASSUME Failing \subseteq 0..MaxRank

None == MaxRank + 1  \* sentinel: no counterexample stored

VARIABLES phase, best, budget, cases, discards, outcome,
          evaluated, changed, clean_finish

vars == <<phase, best, budget, cases, discards, outcome,
          evaluated, changed, clean_finish>>

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

\* --------------------------- regressions phase --------------------------

RegressionFail ==
    /\ phase = "regressions"
    /\ \E r \in Failing :
        /\ best' = r
        /\ phase' = "shrinking"
        /\ UNCHANGED <<budget, cases, discards, outcome,
                       evaluated, changed, clean_finish>>

RegressionPass ==
    /\ phase = "regressions"
    /\ phase' = "searching"
    /\ UNCHANGED <<best, budget, cases, discards, outcome,
                   evaluated, changed, clean_finish>>

\* ------------------------- random search phase --------------------------

AttemptPass ==
    /\ phase = "searching"
    /\ cases < MaxCases
    /\ discards <= MaxDiscards
    /\ cases' = cases + 1
    /\ UNCHANGED <<phase, best, budget, discards, outcome,
                   evaluated, changed, clean_finish>>

AttemptDiscard ==
    /\ phase = "searching"
    /\ discards <= MaxDiscards
    /\ discards' = discards + 1
    /\ UNCHANGED <<phase, best, budget, cases, outcome,
                   evaluated, changed, clean_finish>>

AttemptFail ==
    /\ phase = "searching"
    /\ cases < MaxCases
    /\ discards <= MaxDiscards
    /\ \E r \in Failing :
        /\ best' = r
        /\ phase' = "shrinking"
        /\ UNCHANGED <<budget, cases, discards, outcome,
                       evaluated, changed, clean_finish>>

FinishPassed ==
    /\ phase = "searching"
    /\ cases = MaxCases
    /\ phase' = "done"
    /\ outcome' = "passed"
    /\ UNCHANGED <<best, budget, cases, discards,
                   evaluated, changed, clean_finish>>

FinishGaveUp ==
    /\ phase = "searching"
    /\ discards = MaxDiscards + 1
    /\ cases < MaxCases
    /\ phase' = "done"
    /\ outcome' = "gave_up"
    /\ UNCHANGED <<best, budget, cases, discards,
                   evaluated, changed, clean_finish>>

\* ----------------------------- shrink phase -----------------------------

ShrinkAccept ==
    /\ phase = "shrinking"
    /\ budget > 0
    /\ \E r \in Failing :
        /\ r < best
        /\ best' = r
        /\ budget' = budget - 1
        /\ evaluated' = TRUE
        /\ changed' = TRUE
        /\ UNCHANGED <<phase, cases, discards, outcome, clean_finish>>

ShrinkReject ==
    /\ phase = "shrinking"
    /\ budget > 0
    /\ budget' = budget - 1
    /\ evaluated' = TRUE
    /\ UNCHANGED <<phase, best, cases, discards, outcome,
                   changed, clean_finish>>

StartNextRound ==
    /\ phase = "shrinking"
    /\ evaluated = TRUE
    /\ changed = TRUE
    /\ evaluated' = FALSE
    /\ changed' = FALSE
    /\ UNCHANGED <<phase, best, budget, cases, discards, outcome,
                   clean_finish>>

FinishFixedPoint ==
    /\ phase = "shrinking"
    /\ evaluated = TRUE
    /\ changed = FALSE
    /\ phase' = "done"
    /\ outcome' = "failed_fixed_point"
    /\ clean_finish' = TRUE
    /\ UNCHANGED <<best, budget, cases, discards, evaluated, changed>>

FinishBudgetExhausted ==
    /\ phase = "shrinking"
    /\ budget = 0
    /\ ~ (evaluated = TRUE /\ changed = FALSE)
    /\ phase' = "done"
    /\ outcome' = "failed_budget_exhausted"
    /\ UNCHANGED <<best, budget, cases, discards,
                   evaluated, changed, clean_finish>>

\* ------------------------- infrastructure errors ------------------------

InfraError ==
    /\ phase \in {"regressions", "searching", "shrinking"}
    /\ phase' = "done"
    /\ outcome' = "aborted"
    /\ UNCHANGED <<best, budget, cases, discards,
                   evaluated, changed, clean_finish>>

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

\* ------------------------------ liveness --------------------------------

\* Under weak fairness on progress, every run eventually finishes.
\* Scope: this is a statement about the finite abstract model with
\* atomic evaluations; it assumes each individual evaluation (the
\* user's property and generators) terminates.
Termination == <>(phase = "done")

=============================================================================
