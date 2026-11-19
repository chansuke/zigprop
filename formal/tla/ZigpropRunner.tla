--------------------------- MODULE ZigpropRunner ---------------------------
(***************************************************************************)
(* Abstract model of zigprop's runner and shrink loop (design v2, §5-§6). *)
(*                                                                          *)
(* Choice sequences are abstracted to their shortlex rank: a natural      *)
(* number where smaller means simpler. `Failing` is the abstract set of   *)
(* ranks whose replay makes the property fail. The model checks the       *)
(* protocol rules of the runner, not the concrete generators:             *)
(*                                                                          *)
(*  - a counterexample is stored only after a confirmed failure;          *)
(*  - shrink accepts a candidate only if it fails AND is strictly         *)
(*    smaller, and every shrink evaluation spends one budget unit;        *)
(*  - pass / discard never replace the stored counterexample;             *)
(*  - the run reports fixed_point only when no smaller failing            *)
(*    candidate exists, and budget_exhausted only at budget 0;            *)
(*  - gave_up happens only when the discard budget runs out before        *)
(*    enough valid cases were found.                                      *)
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

VARIABLES phase, best, budget, cases, discards, outcome

vars == <<phase, best, budget, cases, discards, outcome>>

Outcomes == {"none", "passed", "failed_fixed_point",
             "failed_budget_exhausted", "gave_up"}

TypeOK ==
    /\ phase \in {"searching", "shrinking", "done"}
    /\ best \in 0..None
    /\ budget \in 0..MaxBudget
    /\ cases \in 0..MaxCases
    /\ discards \in 0..MaxDiscards
    /\ outcome \in Outcomes

Init ==
    /\ phase = "searching"
    /\ best = None
    /\ budget = MaxBudget
    /\ cases = 0
    /\ discards = 0
    /\ outcome = "none"

\* ------------------------- random search phase -------------------------

AttemptPass ==
    /\ phase = "searching"
    /\ cases < MaxCases
    /\ cases' = cases + 1
    /\ UNCHANGED <<phase, best, budget, discards, outcome>>

AttemptDiscard ==
    /\ phase = "searching"
    /\ discards < MaxDiscards
    /\ discards' = discards + 1
    /\ UNCHANGED <<phase, best, budget, cases, outcome>>

AttemptFail ==
    /\ phase = "searching"
    /\ cases < MaxCases
    /\ \E r \in Failing :
        /\ best' = r
        /\ phase' = "shrinking"
        /\ UNCHANGED <<budget, cases, discards, outcome>>

FinishPassed ==
    /\ phase = "searching"
    /\ cases = MaxCases
    /\ phase' = "done"
    /\ outcome' = "passed"
    /\ UNCHANGED <<best, budget, cases, discards>>

FinishGaveUp ==
    /\ phase = "searching"
    /\ discards = MaxDiscards
    /\ cases < MaxCases
    /\ phase' = "done"
    /\ outcome' = "gave_up"
    /\ UNCHANGED <<best, budget, cases, discards>>

\* ----------------------------- shrink phase ----------------------------

ShrinkAccept ==
    /\ phase = "shrinking"
    /\ budget > 0
    /\ \E r \in Failing :
        /\ r < best
        /\ best' = r
        /\ budget' = budget - 1
        /\ UNCHANGED <<phase, cases, discards, outcome>>

ShrinkReject ==
    /\ phase = "shrinking"
    /\ budget > 0
    /\ budget' = budget - 1
    /\ UNCHANGED <<phase, best, cases, discards, outcome>>

FinishFixedPoint ==
    /\ phase = "shrinking"
    /\ ~ \E r \in Failing : r < best
    /\ phase' = "done"
    /\ outcome' = "failed_fixed_point"
    /\ UNCHANGED <<best, budget, cases, discards>>

FinishBudgetExhausted ==
    /\ phase = "shrinking"
    /\ budget = 0
    /\ \E r \in Failing : r < best
    /\ phase' = "done"
    /\ outcome' = "failed_budget_exhausted"
    /\ UNCHANGED <<best, budget, cases, discards>>

DoneStep ==
    /\ phase = "done"
    /\ UNCHANGED vars

Next ==
    \/ AttemptPass
    \/ AttemptDiscard
    \/ AttemptFail
    \/ FinishPassed
    \/ FinishGaveUp
    \/ ShrinkAccept
    \/ ShrinkReject
    \/ FinishFixedPoint
    \/ FinishBudgetExhausted
    \/ DoneStep

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ------------------------------ invariants -----------------------------

\* A stored counterexample is always a confirmed failure (design §5:
\* the Report is built only from the last confirmed failing state).
BestAlwaysFails ==
    best # None => best \in Failing

\* Nothing is stored while still searching.
BestOnlyAfterFailure ==
    phase = "searching" => best = None

\* The reported outcome is consistent with the state it was reached in.
OutcomeConsistency ==
    /\ (phase = "done") <=> (outcome # "none")
    /\ outcome = "passed" => best = None
    /\ outcome \in {"failed_fixed_point", "failed_budget_exhausted"}
        => best \in Failing
    /\ outcome = "failed_fixed_point"
        => ~ \E r \in Failing : r < best
    /\ outcome = "failed_budget_exhausted" => budget = 0
    /\ outcome = "gave_up" => discards = MaxDiscards /\ cases < MaxCases

\* ------------------------------ liveness -------------------------------

\* Under weak fairness on progress, every run eventually finishes.
Termination == <>(phase = "done")

=============================================================================
