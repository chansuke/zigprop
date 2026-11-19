/-
Shortlex order on choice sequences and the shrink acceptance rule
(design §2 and §6, Must-fix 2 and 4).

The runner stores the re-recorded consumed value sequence of the best
counterexample so far, and accepts a candidate only when its sequence
is strictly smaller in shortlex order (length first, then
lexicographic). The theorems below establish that shortlex is a strict
partial order — irreflexive, transitive, asymmetric — which is what
guarantees that acceptance can never cycle back to a previous state.
(Termination of the loop itself is enforced by the evaluation budget,
modelled in the TLA+ specification.)
-/

namespace ZigpropFormal

/-- Shortlex order on choice value sequences: shorter is smaller;
at equal length, lexicographic on the values. -/
def shortlex (a b : List Nat) : Prop :=
  a.length < b.length ∨ (a.length = b.length ∧ List.Lex (· < ·) a b)

theorem shortlex_irrefl (a : List Nat) : ¬ shortlex a a := by
  intro h
  cases h with
  | inl h => exact Nat.lt_irrefl _ h
  | inr h =>
    exact List.lex_irrefl (fun x hx => Nat.lt_irrefl x hx) a h.2

theorem shortlex_trans {a b c : List Nat} (h₁ : shortlex a b) (h₂ : shortlex b c) :
    shortlex a c := by
  rcases h₁ with h₁ | ⟨h₁len, h₁lex⟩ <;> rcases h₂ with h₂ | ⟨h₂len, h₂lex⟩
  · exact Or.inl (by omega)
  · exact Or.inl (by omega)
  · exact Or.inl (by omega)
  · exact Or.inr ⟨by omega, List.lex_trans Nat.lt_trans h₁lex h₂lex⟩

/-- Acceptance is asymmetric: a shrunk state can never grow back. -/
theorem shortlex_asymm {a b : List Nat} (h : shortlex a b) : ¬ shortlex b a :=
  fun h' => shortlex_irrefl a (shortlex_trans h h')

/-- An accepted candidate is genuinely different from the current one. -/
theorem shortlex_ne {a b : List Nat} (h : shortlex a b) : a ≠ b := by
  intro he
  subst he
  exact shortlex_irrefl a h

/-- Shortlex-smaller sequences are no longer than the original: the
stored counterexample's length never grows across acceptances. -/
theorem shortlex_length_le {a b : List Nat} (h : shortlex a b) :
    a.length ≤ b.length := by
  cases h with
  | inl h => exact Nat.le_of_lt h
  | inr h => exact Nat.le_of_eq h.1

end ZigpropFormal
