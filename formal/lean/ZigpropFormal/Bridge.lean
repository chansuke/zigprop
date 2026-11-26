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

## Replay normalization: `Source.draw` in `src/source.zig`

`normalizeU` transcribes the `.replay` branch's last line,
`if (bound == 0) raw else raw % bound`, over `u64`. The dynamic bounds
of `Case.index` and `Case.choose` (`src/shrink.zig:133`, `:151`) reach
the same line through `Source.index` and `Source.range`, whose
`self.draw(bound, .uniform)` is at `src/source.zig:289` (design
§6.2). The model does not capture the `.random` branch (`sample`), the
`self.pos` bookkeeping and the exhaustion case, or the draw limit
(`limit_exceeded`).

## Signed rank map: `rankToValue` / `valueToRank` in `src/gen.zig`

`valueToRankI` transcribes the signed branch of `valueToRank`
(`value >= 0` gives `2 * value`, otherwise `-2 * value - 1`), and
`rankToValueI` the signed branch of `rankToValue` (`rank % 2 == 0`
gives `rank / 2`, otherwise `-(rank / 2) - 1`). Zig computes through
`i128`; the models use `Int`, which is exact because for `W ≤ 64` the
intermediates have magnitude at most `2^64`, far inside `i128`
(`valueToRank_i128_bound`; `rankToValue`'s `-(rank / 2) - 1` with a
`u64` rank is at least `-2^63 - 1`). `i128` wrap-around is outside the
model. The unsigned branches, `@intCast` safety as Zig checks it, and
float ranks (`floatRankToValue`) are not modelled.
-/

import ZigpropFormal.Shortlex
import ZigpropFormal.Normalize
import ZigpropFormal.Zigzag

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

/-- Model of the replay rule in `Source.draw`, over `u64`. -/
def normalizeU (b v : UInt64) : UInt64 :=
  if b = 0 then v else v % b

/-- The normalize bridge: the `UInt64` model agrees with `normalize`
on the `toNat` images, for every bound and value. -/
theorem normalizeU_toNat (b v : UInt64) :
    (normalizeU b v).toNat = normalize b.toNat v.toNat := by
  unfold normalizeU normalize
  by_cases hb : b = 0
  · subst hb
    simp
  · have hn : b.toNat ≠ 0 := fun h => hb (UInt64.toNat_inj.mp (h.trans UInt64.toNat_zero.symm))
    simp [hb, hn, UInt64.toNat_mod]

/-- Every `UInt64` replay-normalized value is a valid choice for its
bound (`normalize_always_valid` through the bridge). -/
theorem normalizeU_valid (b v : UInt64) : Valid b.toNat (normalizeU b v).toNat := by
  rw [normalizeU_toNat]
  exact normalize_always_valid b.toNat v.toNat

/-- `2^W = 2 * 2^(W-1)` for `W ≥ 1`. -/
theorem pow_eq_two_mul_pred {W : Nat} (hW : 1 ≤ W) : 2 ^ W = 2 * 2 ^ (W - 1) := by
  have : W = (W - 1) + 1 := by omega
  rw [this, Nat.pow_succ, Nat.add_sub_cancel, Nat.mul_comm]

/-- `2^(W-1)` computed in `Int` is the cast of the `Nat` power. -/
theorem int_pow_pred (W : Nat) : ((2 : Int) ^ (W - 1)) = ((2 ^ (W - 1) : Nat) : Int) := by
  rw [Int.natCast_pow]
  rfl

/-- Rank bound: a signed width-`W` value has a rank below `2^W`. -/
theorem zigzagEncode_lt_pow (W : Nat) (hW : 1 ≤ W ∧ W ≤ 64) (x : Int)
    (hlo : -(2 ^ (W - 1) : Int) ≤ x) (hhi : x < 2 ^ (W - 1)) : zigzagEncode x < 2 ^ W := by
  rw [pow_eq_two_mul_pred hW.1]
  rw [int_pow_pred] at hlo hhi
  generalize 2 ^ (W - 1) = p at hlo hhi ⊢
  cases x with
  | ofNat n => show 2 * n < 2 * p; rw [Int.ofNat_eq_natCast] at hhi; omega
  | negSucc n => show 2 * n + 1 < 2 * p; rw [Int.negSucc_eq] at hlo; omega

/-- Decode range: a rank below `2^W` decodes to a signed width-`W`
value. -/
theorem zigzagDecode_range (W : Nat) (hW : 1 ≤ W ∧ W ≤ 64) (r : Nat) (hr : r < 2 ^ W) :
    -(2 ^ (W - 1) : Int) ≤ zigzagDecode r ∧ zigzagDecode r < 2 ^ (W - 1) := by
  rw [pow_eq_two_mul_pred hW.1] at hr
  rw [int_pow_pred]
  generalize 2 ^ (W - 1) = p at hr ⊢
  have h2 := Nat.div_add_mod r 2
  unfold zigzagDecode
  by_cases h : r % 2 = 0
  · simp only [h, ite_true, Int.ofNat_eq_natCast]
    exact ⟨by omega, by omega⟩
  · simp only [h, ite_false, Int.negSucc_eq]
    exact ⟨by omega, by omega⟩

/-- Model of the signed branch of `valueToRank` in `src/gen.zig`, with
the `i128` intermediate as `Int`. -/
def valueToRankI (x : Int) : Int :=
  if x ≥ 0 then 2 * x else -2 * x - 1

/-- Model of the signed branch of `rankToValue` in `src/gen.zig`, with
the `u64` rank as `Nat` and the `i128` intermediate as `Int`. -/
def rankToValueI (r : Nat) : Int :=
  if r % 2 = 0 then ((r / 2 : Nat) : Int) else -((r / 2 : Nat) : Int) - 1

/-- The Zig encode model is `zigzagEncode`, on all of `Int`. -/
theorem valueToRankI_eq (x : Int) : valueToRankI x = (zigzagEncode x : Int) := by
  unfold valueToRankI
  cases x with
  | ofNat n =>
    show (if (n : Int) ≥ 0 then 2 * (n : Int) else -2 * (n : Int) - 1) = ((2 * n : Nat) : Int)
    split <;> omega
  | negSucc n =>
    show (if Int.negSucc n ≥ 0 then 2 * Int.negSucc n else -2 * Int.negSucc n - 1) =
      ((2 * n + 1 : Nat) : Int)
    rw [Int.negSucc_eq]
    split <;> omega

/-- The Zig decode model is `zigzagDecode`, on all of `Nat`. -/
theorem rankToValueI_eq (r : Nat) : rankToValueI r = zigzagDecode r := by
  unfold rankToValueI zigzagDecode
  by_cases h : r % 2 = 0
  · simp only [h, ite_true, Int.ofNat_eq_natCast]
  · simp only [h, ite_false, Int.negSucc_eq]
    omega

/-- The rank of a signed width-`W` value, `W ≤ 64`, lies in `u64`'s
range `[0, 2^64)`, so `valueToRank`'s `@intCast` to `u64` loses
nothing. -/
theorem valueToRankI_fits_u64 (W : Nat) (hW : 1 ≤ W ∧ W ≤ 64) (x : Int)
    (hlo : -(2 ^ (W - 1) : Int) ≤ x) (hhi : x < 2 ^ (W - 1)) :
    0 ≤ valueToRankI x ∧ valueToRankI x < 2 ^ 64 := by
  rw [valueToRankI_eq]
  have h := zigzagEncode_lt_pow W hW x hlo hhi
  have hp : 2 ^ W ≤ 2 ^ 64 := Nat.pow_le_pow_right (by decide) hW.2
  have : (2 : Int) ^ 64 = ((2 ^ 64 : Nat) : Int) := by rw [Int.natCast_pow]; rfl
  rw [this]
  exact ⟨by omega, by omega⟩

/-- The products in `valueToRank` stay inside `i128` for a signed
width-`W` value, `W ≤ 64`: their magnitudes are at most `2^64`. -/
theorem valueToRank_i128_bound (W : Nat) (hW : 1 ≤ W ∧ W ≤ 64) (x : Int)
    (hlo : -(2 ^ (W - 1) : Int) ≤ x) (hhi : x < 2 ^ (W - 1)) :
    -(2 ^ 127 : Int) ≤ 2 * x ∧ 2 * x < 2 ^ 127 ∧
      -(2 ^ 127 : Int) ≤ -2 * x - 1 ∧ -2 * x - 1 < 2 ^ 127 := by
  have hp : 2 ^ (W - 1) ≤ 2 ^ 63 := Nat.pow_le_pow_right (by decide) (by omega)
  rw [int_pow_pred] at hlo hhi
  have : (2 : Int) ^ 127 = ((2 ^ 127 : Nat) : Int) := by rw [Int.natCast_pow]; rfl
  rw [this]
  exact ⟨by omega, by omega, by omega, by omega⟩

end ZigpropFormal
