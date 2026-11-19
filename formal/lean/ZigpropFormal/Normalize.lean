/-
Replay normalization and the recorded-choice validity invariant
(design §2, Must-fix 1).

Mirrors `Source.range` in `src/source.zig`: the sentinel bound 0 passes
the raw value through; any other bound reduces the recorded value
modulo the requested bound. The central fact is that a normalized value
always satisfies the choice validity invariant, for every bound —
including the sentinel, which the original design's invariant
(`value < bound`) could not express.
-/

namespace ZigpropFormal

/-- Replay normalization: sentinel bound 0 is the identity, any other
bound reduces modulo the bound. -/
def normalize (bound value : Nat) : Nat :=
  if bound = 0 then value else value % bound

/-- The validity invariant of a recorded choice (design §2, MF1). -/
def Valid (bound value : Nat) : Prop :=
  bound = 0 ∨ value < bound

theorem normalize_sentinel (value : Nat) : normalize 0 value = value :=
  rfl

theorem normalize_valid_of_pos {bound value : Nat} (hb : 0 < bound) :
    normalize bound value < bound := by
  unfold normalize
  rw [if_neg (show bound ≠ 0 by omega)]
  exact Nat.mod_lt value hb

/-- Every normalized value is a valid choice, whatever the bound. This
is what makes arbitrary shrink candidates safe to replay. -/
theorem normalize_always_valid (bound value : Nat) :
    Valid bound (normalize bound value) := by
  by_cases hb : bound = 0
  · exact Or.inl hb
  · exact Or.inr (normalize_valid_of_pos (Nat.pos_of_ne_zero hb))

/-- Normalizing an already-normalized value changes nothing. -/
theorem normalize_idempotent {bound value : Nat} (hb : bound ≠ 0) :
    normalize bound (normalize bound value) = normalize bound value := by
  unfold normalize
  rw [if_neg hb, if_neg hb, Nat.mod_mod]

/-- Idempotence for every bound, including the sentinel. -/
theorem normalize_idempotent_all (bound value : Nat) :
    normalize bound (normalize bound value) = normalize bound value := by
  by_cases hb : bound = 0
  · subst hb
    rfl
  · exact normalize_idempotent hb

end ZigpropFormal
