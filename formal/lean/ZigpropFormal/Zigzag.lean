/-
The zigzag rank encoding for signed integers (design §4.1).

Signed values are generated through a rank in `Nat`: rank 0 ↦ 0,
1 ↦ -1, 2 ↦ 1, 3 ↦ -2, … so that smaller ranks mean smaller absolute
values, which is what makes choice-level shrinking (toward 0) agree
with value-level shrinking (toward 0). The theorems below pin the
encoding as a bijection and bound the decoded magnitude by the rank.
-/

namespace ZigpropFormal

/-- Rank of a signed value: `2n` for `n ≥ 0`, `2n+1` for `-(n+1)`. -/
def zigzagEncode : Int → Nat
  | Int.ofNat n => 2 * n
  | Int.negSucc n => 2 * n + 1

/-- Inverse of `zigzagEncode`: even ranks are non-negative, odd ranks
are negative. -/
def zigzagDecode (r : Nat) : Int :=
  if r % 2 = 0 then Int.ofNat (r / 2) else Int.negSucc (r / 2)

theorem zigzagDecode_encode (x : Int) : zigzagDecode (zigzagEncode x) = x := by
  cases x with
  | ofNat n =>
    show zigzagDecode (2 * n) = Int.ofNat n
    unfold zigzagDecode
    rw [if_pos (by omega)]
    congr 1
    omega
  | negSucc n =>
    show zigzagDecode (2 * n + 1) = Int.negSucc n
    unfold zigzagDecode
    rw [if_neg (by omega)]
    congr 1
    omega

theorem zigzagEncode_decode (r : Nat) : zigzagEncode (zigzagDecode r) = r := by
  unfold zigzagDecode
  by_cases h : r % 2 = 0
  · rw [if_pos h]
    show 2 * (r / 2) = r
    have h2 := Nat.div_add_mod r 2
    omega
  · rw [if_neg h]
    have h1 : r % 2 = 1 := by omega
    show 2 * (r / 2) + 1 = r
    have h2 := Nat.div_add_mod r 2
    omega

/-- Small ranks decode to small magnitudes: shrinking a rank toward 0
never increases the decoded value's absolute value beyond the rank. -/
theorem zigzagDecode_natAbs_le (r : Nat) : (zigzagDecode r).natAbs ≤ r := by
  unfold zigzagDecode
  by_cases h : r % 2 = 0
  · rw [if_pos h]
    have h2 := Nat.div_add_mod r 2
    show r / 2 ≤ r
    omega
  · rw [if_neg h]
    have h1 : r % 2 = 1 := by omega
    have h2 := Nat.div_add_mod r 2
    simp only [Int.natAbs_negSucc]
    omega

/-- The decoded magnitude is exactly the rank rounded up to halves:
rank `2k` ↦ `k`, rank `2k+1` ↦ `k+1`. -/
theorem zigzagDecode_natAbs (r : Nat) : (zigzagDecode r).natAbs = (r + 1) / 2 := by
  unfold zigzagDecode
  by_cases h : r % 2 = 0
  · rw [if_pos h]
    have h2 := Nat.div_add_mod r 2
    show r / 2 = (r + 1) / 2
    omega
  · rw [if_neg h]
    have h1 : r % 2 = 1 := by omega
    have h2 := Nat.div_add_mod r 2
    rw [Int.natAbs_negSucc]
    omega

/-- Magnitude is monotone in the rank: lowering a rank never raises
the decoded value's magnitude. This is the property that makes
rank-level shrinking agree with value-level shrinking. -/
theorem zigzagDecode_natAbs_mono {r₁ r₂ : Nat} (h : r₁ ≤ r₂) :
    (zigzagDecode r₁).natAbs ≤ (zigzagDecode r₂).natAbs := by
  rw [zigzagDecode_natAbs, zigzagDecode_natAbs]
  omega

/-- The rank of a value is at most twice its magnitude. -/
theorem zigzagEncode_le (x : Int) : zigzagEncode x ≤ 2 * x.natAbs := by
  cases x with
  | ofNat n => simp [zigzagEncode]
  | negSucc n =>
    show 2 * n + 1 ≤ 2 * (Int.negSucc n).natAbs
    rw [Int.natAbs_negSucc]
    omega

end ZigpropFormal
