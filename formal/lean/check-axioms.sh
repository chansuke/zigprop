#!/bin/sh
# Audit the axioms the key theorems depend on. Fails if any theorem
# depends on sorryAx (i.e. an admitted proof) — the build alone does
# not surface that. Run locally or in CI after `lake build`.
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
EOF
trap 'rm -f AxiomsAudit.lean' EXIT

out=$(lake env lean AxiomsAudit.lean 2>&1)
echo "$out"
if echo "$out" | grep -q 'sorryAx'; then
    echo "FAIL: a key theorem depends on sorryAx" >&2
    exit 1
fi
echo "axiom audit passed (no sorryAx)"
