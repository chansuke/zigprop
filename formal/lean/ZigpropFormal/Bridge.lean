/-
Bridges between the `Nat`/`Int` models and the `u64` implementation
(design v0.4 §6.2).

The other files state their facts over `Nat` and `Int`. The Zig code
works over `u64`. This file transcribes the Zig functions below into
`UInt64`-typed Lean models and proves that each model agrees with the
`Nat`/`Int` model it corresponds to. Everything here is proved about
the Lean models. That the Zig functions implement these models is a
hand argument (written out below) plus drift detection: the functions
are hashed in `formal/manifest.zon`, and the `formal-drift` lint rule
reports any change to them. The Lean↔Zig correspondence itself is not
proved.

## Key comparison: `keyShortlexLess` in `src/shrink.zig`

The Zig function receives each side as two parallel slices, `keys`
and `skip`. The model takes each side as one `List (UInt64 × Bool)` of
(key, skip flag) pairs, so the two slices have equal length by
construction. In the implementation they have equal length because
`Source.record` appends one key and one skip flag per recorded choice
and `Source.annotatePair` only overwrites entries in place. The one
exception is an allocation failure between the two appends, which sets
`sticky_error`, so the attempt ends as an error and is never compared.

`filteredLen(skip)` counts the clear flags; it is `(filt side).length`.
`keyShortlexLess` maps to `keyLess`, statement by statement:

- `if (la != lb) return la < lb;` is the first branch of `keyLess`.
- `while (true)` is the recursion of `keyLoop`. One Lean call is one
  step of the loop body: one skipped entry, one exhaustion test, or one
  key comparison.
- `while (ia < a_keys.len and a_skip[ia]) ia += 1;` is the first case
  of `keyLoop` (`a`'s head is skipped: drop it). It comes first, so all
  of `a`'s skips are taken before any of `b`'s, as in Zig.
- `while (ib < b_keys.len and b_skip[ib]) ib += 1;` is the second case
  (`a`'s head is not skipped or `a` is empty, `b`'s head is skipped).
- `if (ia >= a_keys.len) return false;` is the third case (`a` empty).
- `a_keys[ia]` with `b` exhausted (`ib == b_keys.len`): the Zig code
  has no `ib` bound check, so it would index past `b_keys`. The model
  returns `none` for this case. `keyLoop_eq_some` proves that `none` is
  never returned when the filtered lengths are equal, which is the
  only way `keyLess` calls `keyLoop`. Each comparison step consumes one
  unskipped entry from each side, so equal filtered lengths stay equal
  and `b` cannot run out before `a`.
- `if (a_keys[ia] != b_keys[ib]) return a_keys[ia] < b_keys[ib];` is
  the `x ≠ y` branch of the last case.
- `ia += 1; ib += 1;` is the recursive call on both tails.

The model does not capture Zig's integer index types, a bounds-check
panic as such (it is the `none` result), or slices whose key and skip
lengths differ. This mapping is argued by hand, not proved.
-/

import ZigpropFormal.Shortlex

namespace ZigpropFormal

/-- The keys of the entries whose skip flag is clear, in order. -/
def filt : List (UInt64 × Bool) → List UInt64
  | [] => []
  | (_, true) :: t => filt t
  | (k, false) :: t => k :: filt t

/-- Model of the two-pointer loop of `keyShortlexLess`. `none` is the
step where Zig would index past `b_keys`. -/
def keyLoop (a b : List (UInt64 × Bool)) : Option Bool :=
  match a, b with
  | (_, true) :: a', b => keyLoop a' b
  | a, (_, true) :: b' => keyLoop a b'
  | [], _ => some false
  | (_, false) :: _, [] => none
  | (x, false) :: a', (y, false) :: b' =>
    if x ≠ y then some (decide (x < y)) else keyLoop a' b'
termination_by a.length + b.length

/-- Model of `keyShortlexLess`: filtered lengths first, then the loop.
`getD false` is never taken (`keyLoop_eq_some`). -/
def keyLess (a b : List (UInt64 × Bool)) : Bool :=
  if (filt a).length ≠ (filt b).length then decide ((filt a).length < (filt b).length)
  else (keyLoop a b).getD false

/-- The loop's result on skip-free key lists: lexicographic, and false
when the first list runs out. -/
def lexB : List UInt64 → List UInt64 → Bool
  | [], _ => false
  | _ :: _, [] => false
  | x :: a, y :: b => if x ≠ y then decide (x < y) else lexB a b

/-- At equal filtered lengths the loop never reaches the step past
`b_keys`, and it computes `lexB` on the filtered keys. -/
theorem keyLoop_eq_some (a b : List (UInt64 × Bool))
    (h : (filt a).length = (filt b).length) :
    keyLoop a b = some (lexB (filt a) (filt b)) := by
  induction a, b using keyLoop.induct with
  | case1 _ a b ih => rw [keyLoop]; exact ih h
  | case2 a k b ha ih =>
    rw [keyLoop.eq_2 a k b ha]
    exact ih h
  | case3 b hb => rw [keyLoop.eq_3 b hb]; cases filt b <;> rfl
  | case4 x a => exact absurd h (by simp [filt])
  | case5 x a y b hne => rw [keyLoop]; simp [filt, lexB, hne]
  | case6 x a y b hxy ih =>
    rw [keyLoop]
    have h' : (filt a).length = (filt b).length := by
      simp only [filt, List.length_cons] at h
      omega
    simp [filt, lexB, hxy, ih h']

/-- Splits a lexicographic comparison of two non-empty lists at the
head. -/
theorem lex_cons_cons {p q : Nat} {s t : List Nat} (h : List.Lex (· < ·) (p :: s) (q :: t)) :
    p < q ∨ (p = q ∧ List.Lex (· < ·) s t) := by
  cases h with
  | cons h => exact Or.inr ⟨rfl, h⟩
  | rel h => exact Or.inl h

/-- At equal lengths, `lexB` is `List.Lex` on the `toNat` images. -/
theorem lexB_iff_lex (la lb : List UInt64) (h : la.length = lb.length) :
    lexB la lb = true ↔ List.Lex (· < ·) (la.map UInt64.toNat) (lb.map UInt64.toNat) := by
  induction la generalizing lb with
  | nil =>
    match lb, h with
    | [], _ => exact ⟨(fun h => nomatch h), (fun h => nomatch h)⟩
  | cons x a ih =>
    match lb, h with
    | y :: b, h =>
      have hab : a.length = b.length := Nat.succ.inj h
      by_cases hxy : x = y
      · subst hxy
        have hl : lexB (x :: a) (x :: b) = lexB a b := by simp [lexB]
        rw [hl, ih b hab]
        constructor
        · exact List.Lex.cons
        · intro hl
          cases lex_cons_cons hl with
          | inl hlt => exact absurd hlt (Nat.lt_irrefl _)
          | inr hl => exact hl.2
      · have hl : lexB (x :: a) (y :: b) = decide (x < y) := by simp [lexB, hxy]
        rw [hl, decide_eq_true_iff, UInt64.lt_iff_toNat_lt]
        constructor
        · exact List.Lex.rel
        · intro hl
          cases lex_cons_cons hl with
          | inl hlt => exact hlt
          | inr hl => exact absurd (UInt64.toNat_inj.mp hl.1) hxy

/-- The key-comparison bridge: the model of `keyShortlexLess` holds
exactly when the filtered, `toNat`-mapped key lists are in shortlex
order. -/
theorem keyLess_iff_shortlex (a b : List (UInt64 × Bool)) :
    keyLess a b = true ↔
      shortlex ((filt a).map UInt64.toNat) ((filt b).map UInt64.toNat) := by
  unfold shortlex
  rw [List.length_map, List.length_map]
  by_cases hl : (filt a).length = (filt b).length
  · have hk : keyLess a b = lexB (filt a) (filt b) := by
      simp [keyLess, hl, keyLoop_eq_some a b hl]
    rw [hk, lexB_iff_lex _ _ hl]
    constructor
    · exact fun h => Or.inr ⟨hl, h⟩
    · intro h
      cases h with
      | inl h => exact absurd h (by omega)
      | inr h => exact h.2
  · have hk : keyLess a b = decide ((filt a).length < (filt b).length) := by
      simp [keyLess, hl]
    rw [hk, decide_eq_true_iff]
    constructor
    · exact Or.inl
    · intro h
      cases h with
      | inl h => exact h
      | inr h => exact absurd h.1 hl

/-- With no skip flags set, filtering keeps every key. -/
theorem filt_unskipped (xs : List UInt64) : filt (xs.map fun k => (k, false)) = xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih => simp only [List.map, filt, ih]

/-- With no annotations, the model of `keyShortlexLess` is exactly
shortlex on the values (the Zig doc comment's claim). -/
theorem keyLess_unskipped_iff_shortlex (xs ys : List UInt64) :
    keyLess (xs.map fun k => (k, false)) (ys.map fun k => (k, false)) = true ↔
      shortlex (xs.map UInt64.toNat) (ys.map UInt64.toNat) := by
  rw [keyLess_iff_shortlex, filt_unskipped, filt_unskipped]

end ZigpropFormal
