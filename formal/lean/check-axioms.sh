#!/bin/sh
# Audit the axioms the key theorems depend on. The build alone does not
# surface them. Run locally or in CI after `lake build`.
#
# Fails if any listed theorem depends on an axiom outside the allowlist
# below (sorryAx, i.e. an admitted proof, is the case the build cannot
# catch; Classical.choice is the one the M8 change removed and that new
# proofs must not bring back).
#
# Allowlist: propext and Quot.sound. It is exactly the set the original
# 13 theorems depend on (measured 2026-11-26 with Lean 4.36.0); a new
# theorem may use no more than they do.
set -eu
cd "$(dirname "$0")"

cat > AxiomsAudit.lean << 'EOF'
import ZigpropFormal
#print axioms ZigpropFormal.normalize_always_valid
#print axioms ZigpropFormal.normalize_idempotent_all
#print axioms ZigpropFormal.zigzagDecode_encode
#print axioms ZigpropFormal.zigzagEncode_decode
#print axioms ZigpropFormal.zigzagDecode_natAbs_mono
#print axioms ZigpropFormal.shortlex_trans
#print axioms ZigpropFormal.shortlex_asymm
#print axioms ZigpropFormal.lex_wf_of_length
#print axioms ZigpropFormal.shortlex_wf
#print axioms ZigpropFormal.measureLt_wf
#print axioms ZigpropFormal.accept_decreases
#print axioms ZigpropFormal.ratchet_decreases
#print axioms ZigpropFormal.no_infinite_descent
#print axioms ZigpropFormal.keyLoop_eq_some
#print axioms ZigpropFormal.lex_cons_cons
#print axioms ZigpropFormal.lexB_iff_lex
#print axioms ZigpropFormal.keyLess_iff_shortlex
#print axioms ZigpropFormal.filt_unskipped
#print axioms ZigpropFormal.keyLess_unskipped_iff_shortlex
#print axioms ZigpropFormal.normalizeU_toNat
#print axioms ZigpropFormal.normalizeU_valid
EOF
trap 'rm -f AxiomsAudit.lean' EXIT

if ! out=$(lake env lean AxiomsAudit.lean 2>&1); then
    echo "$out"
    echo "FAIL: the audit file does not elaborate" >&2
    exit 1
fi
echo "$out"

if echo "$out" | grep -q 'sorryAx'; then
    echo "FAIL: a key theorem depends on sorryAx" >&2
    exit 1
fi

# One report per #print line, so a theorem cannot drop out unnoticed.
want=$(grep -c '^#print axioms' AxiomsAudit.lean)
got=$(echo "$out" | grep -c -e 'depends on axioms' -e 'does not depend on any axioms' || true)
if [ "$got" -ne "$want" ]; then
    echo "FAIL: expected $want axiom reports, got $got" >&2
    exit 1
fi

# Every axiom inside the bracketed lists, which Lean may wrap across lines.
bad=$(echo "$out" | tr '\n' ' ' | tr '[' '\n' | sed -n 's/\].*//p' | tr ',' '\n' |
    tr -d ' \t' | grep -v -x -e propext -e Quot.sound || true)
if [ -n "$bad" ]; then
    echo "FAIL: axioms outside the allowlist (propext, Quot.sound): $bad" >&2
    exit 1
fi
echo "axiom audit passed (only propext and Quot.sound)"
