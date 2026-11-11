#!/usr/bin/env bash
# Runs every FV-LIQ check of the liquidation area. Exits non-zero on any violation that
# is not an expected finding counterexample, any solver timeout, any vacuous premise and
# any Quint result that differs from its expectation.
#
#   QNT_SAMPLES (default 10000) and QNT_STEPS (default 25) set the Quint simulation size.
set -uo pipefail
cd "$(dirname "$0")"
ROOT=../../..
PY="$ROOT/spec/05-verification/.venv/bin/python"
QUINT="$ROOT/spec/05-verification/node_modules/.bin/quint"
SAMPLES=${QNT_SAMPLES:-10000}
STEPS=${QNT_STEPS:-25}
fail=0

for f in fv_liq_01_settlement_math.py fv_liq_02_aave_sizing.py fv_liq_03_flow.py fv_liq_04_budget.py \
         fv_liq_05_escrow_coverage.py fv_liq_06_examples.py fv_liq_07_system.py; do
  echo "=== $f"
  if ! "$PY" -u "$f"; then echo "!!! $f failed"; fail=1; fi
done

# Quint: ID | step | invariant | expectation (hold: no violation; violate: a counterexample must be found;
# witness: the negated condition must be violated, showing the traces reach the behaviour).
CHECKS=$(cat <<'EOF'
FV-LIQ-08a | stepLive | liveInvariants | hold
FV-LIQ-08b | stepHalt | safetyInvariants | hold
FV-LIQ-08c | stepHalt | solvencyPerAsset | violate
FV-LIQ-08w1 | stepHalt | not(lastLiq.ok) | witness
FV-LIQ-08w2 | stepHalt | ASSETS.forall(s => deficit.get(s) == 0) | witness
FV-LIQ-08w3 | stepHalt | ASSETS.forall(s => covered.get(s) == 0) | witness
FV-LIQ-08w4 | stepLive | escrowBalance == 0 | witness
FV-LIQ-08w5 | stepHalt | not(lastLiq.ok and lastLiq.whilePaused) | witness
FV-LIQ-08w6 | stepHalt | not(lastLiq.ok and lastLiq.acctFrozen) | witness
EOF
)
while IFS='|' read -r id step inv expect; do
  id=$(echo "$id" | xargs); step=$(echo "$step" | xargs); inv=$(echo "$inv" | xargs); expect=$(echo "$expect" | xargs)
  out=$("$QUINT" run liquidation.qnt --step "$step" --invariant "$inv" --max-samples "$SAMPLES" --max-steps "$STEPS" 2>&1)
  if echo "$out" | grep -q "No violation found"; then got=hold; else got=violate; fi
  want=$([ "$expect" = hold ] && echo hold || echo violate)
  seed=$(echo "$out" | grep -o "seed=0x[0-9a-f]*" | head -1)
  if [ "$got" = "$want" ]; then echo "[PASS] $id $step / $inv: $expect ($SAMPLES traces x $STEPS steps, randomized, $seed)"
  else echo "[FAIL] $id $step / $inv: expected $expect, got $got ($seed)"; fail=1; fi
done <<< "$CHECKS"

if [ $fail -ne 0 ]; then echo "LIQUIDATION AREA: FAILURES"; exit 1; fi
echo "LIQUIDATION AREA: all checks passed"
