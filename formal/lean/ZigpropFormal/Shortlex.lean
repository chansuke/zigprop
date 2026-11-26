/-
Shortlex order on choice sequences and the shrink acceptance rule
(design §2 and §6, Must-fix 2 and 4).

The runner stores the re-recorded consumed value sequence of the best
counterexample so far, and accepts a candidate only when its sequence
is strictly smaller in shortlex order (length first, then
lexicographic). The theorems below establish that shortlex is a strict
partial order — irreflexive, transitive, asymmetric — which is what
guarantees that acceptance can never cycle back to a previous state.

`shortlex_wf` proves that shortlex is also well-founded on `List Nat`:
no infinite sequence of strictly smaller sequences exists in this
model. That is a statement about `Nat` values. `Bridge.lean` proves
that a `UInt64` model of the implementation's skip-filtered key
comparison equals shortlex on the filtered, `toNat`-mapped keys
(`keyLess_iff_shortlex`). That the Zig code is that model is argued,
not proved, so the implementation's shrink loop still stops because
of the evaluation budget.
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

/-- Lexicographic order restricted to sequences of equal length.
`List.Lex` alone is not well-founded: `[1] > [0, 1] > [0, 0, 1] > …`. -/
def lexSameLen (a b : List Nat) : Prop :=
  a.length = b.length ∧ List.Lex (· < ·) a b

/-- Every sequence of length `n` is accessible for `lexSameLen`, by
induction on `n`: a sequence `x :: t` is reached through the pair
`(x, t)` under `Prod.Lex` of `<` on the head and the length-`n` order on
the tail. -/
theorem lexSameLen_acc (n : Nat) : ∀ l : List Nat, l.length = n → Acc lexSameLen l := by
  induction n with
  | zero =>
    intro l hl
    have : l = [] := List.eq_nil_of_length_eq_zero hl
    subst this
    exact Acc.intro _ fun y hy => nomatch hy.2
  | succ n ih =>
    let rn : List Nat → List Nat → Prop := fun a b => a.length = n ∧ lexSameLen a b
    have hrn : ∀ b, Acc rn b := by
      intro b
      exact if hb : b.length = n then Subrelation.accessible (fun h => h.2) (ih b hb)
        else Acc.intro _ fun y hy => absurd (hy.2.1.symm.trans hy.1) hb
    have key : ∀ p : Nat × List Nat, Acc (Prod.Lex (· < ·) rn) p →
        ∀ x t, p = (x, t) → t.length = n → Acc lexSameLen (x :: t) := by
      intro p hp
      induction hp with
      | intro p _ ihp =>
        intro x t hpx hlen
        subst hpx
        refine Acc.intro _ fun y hy => ?_
        match y, hy with
        | [], ⟨h, _⟩ => exact Nat.noConfusion h
        | y0 :: yt, ⟨h, hlex⟩ =>
          have htail : yt.length = t.length := Nat.succ.inj h
          have hyt : yt.length = n := htail.trans hlen
          cases hlex with
          | rel hlt => exact ihp (y0, yt) (Prod.Lex.left _ _ hlt) y0 yt rfl hyt
          | cons hl => exact ihp (_, yt) (Prod.Lex.right _ ⟨hyt, htail, hl⟩) _ yt rfl hyt
    intro l hl
    match l, hl with
    | x :: t, hl => exact key (x, t) (Prod.lexAccessible (Nat.lt_wfRel.wf.apply x) hrn t) x t rfl (Nat.succ.inj hl)

theorem lexSameLen_wf : WellFounded lexSameLen :=
  WellFounded.intro fun l => lexSameLen_acc l.length l rfl

/-- Lexicographic order on the sequences of one fixed length is
well-founded. -/
theorem lex_wf_of_length (n : Nat) :
    WellFounded (fun a b : {l : List Nat // l.length = n} => List.Lex (· < ·) a.1 b.1) :=
  Subrelation.wf (fun {a b} h => ⟨a.2.trans b.2.symm, h⟩) (InvImage.wf Subtype.val lexSameLen_wf)

/-- Shortlex is well-founded on `List Nat`: it is a subrelation of
`Prod.Lex` of `<` on the length and `lexSameLen` on the sequence. -/
theorem shortlex_wf : WellFounded shortlex := by
  have wfp : WellFounded (Prod.Lex (· < ·) lexSameLen : Nat × List Nat → Nat × List Nat → Prop) :=
    WellFounded.intro fun p => Prod.lexAccessible (Nat.lt_wfRel.wf.apply p.1) lexSameLen_wf.apply p.2
  refine Subrelation.wf (r := InvImage (Prod.Lex (· < ·) lexSameLen) fun l => (l.length, l)) ?_ (InvImage.wf _ wfp)
  intro a b h
  cases h with
  | inl h => exact Prod.Lex.left _ _ h
  | inr h => exact Prod.lex_def.mpr (Or.inr ⟨h.1, h⟩)

end ZigpropFormal
