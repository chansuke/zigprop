import ZigpropFormal.Shortlex

/-
The v2.1 termination measure of the shrink loop (design v2.1, §4.1/§6;
docs/verification.md rows 16 and 18).

The measure of a stored counterexample is the pair (key sequence,
number of pairs outside class 3), compared lexicographically: shortlex
on the keys first, then `<` on the count. `measureLt_wf` proves that
this order is well-founded on `List Nat × Nat`, so in this model no
infinite sequence of acceptances that each lower the measure exists
(`no_infinite_descent`).

What is proved: the well-foundedness of the measure over `Nat`.

What is not proved:
- that the implementation's acceptances lower this measure.
  `accept_decreases` and `ratchet_decreases` only restate their
  hypothesis as a measure decrease. That `tryAccept` accepts only a
  shortlex-smaller key sequence, and that `tryRatchet` keeps the keys
  and lowers the count, is observed by the accept hook in
  `tests/meta9.zig`, not proved;
- the bridge from the implementation's `u64` keys to `Nat`.

The implementation's shrink loop therefore still stops because of the
evaluation budget.
-/

namespace ZigpropFormal

/-- The v2.1 measure order: (keys, count) with shortlex on the keys,
then `<` on the count of pairs outside class 3. -/
def measureLt (a b : List Nat × Nat) : Prop :=
  shortlex a.1 b.1 ∨ (a.1 = b.1 ∧ a.2 < b.2)

/-- The measure order is well-founded: it is `Prod.Lex shortlex (· < ·)`. -/
theorem measureLt_wf : WellFounded measureLt := by
  have wfp : WellFounded (Prod.Lex shortlex (· < ·) : List Nat × Nat → List Nat × Nat → Prop) :=
    WellFounded.intro fun p => Prod.lexAccessible (shortlex_wf.apply p.1) (Nat.lt_wfRel.wf.apply) p.2
  exact Subrelation.wf (fun h => Prod.lex_def.mpr h) wfp

/-- A shortlex-smaller key sequence lowers the measure, whatever the
counts. This restates the hypothesis. It does not prove that
`tryAccept` (P1–P3, P5, P6, P1b) accepts only such candidates. -/
theorem accept_decreases {k k' : List Nat} {c c' : Nat} (h : shortlex k' k) :
    measureLt (k', c') (k, c) := Or.inl h

/-- Equal keys with a smaller count lower the measure. This restates
the hypothesis. It does not prove that `tryRatchet` (P4) keeps the keys
and lowers the count. -/
theorem ratchet_decreases {k : List Nat} {c c' : Nat} (h : c' < c) :
    measureLt (k, c') (k, c) := Or.inr ⟨rfl, h⟩

/-- No infinite sequence of measures decreases at every step. -/
theorem no_infinite_descent (f : Nat → List Nat × Nat) :
    ¬ ∀ i, measureLt (f (i + 1)) (f i) := by
  intro h
  have : ∀ x, Acc measureLt x → ∀ i, f i ≠ x := by
    intro x hx
    induction hx with
    | intro x _ ih =>
      intro i hi
      exact ih (f (i + 1)) (hi ▸ h i) (i + 1) rfl
  exact this (f 0) (measureLt_wf.apply _) 0 rfl

end ZigpropFormal
