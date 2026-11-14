#!/usr/bin/env bash
# Runs every custody-area check (FV-CUS-*). Exits non-zero if any check is
# VIOLATED, VACUOUS or UNKNOWN, if a Quint run disagrees with its expected result, or if a
# cited spec ID is undefined. A check registered as an open finding (common.open_finding)
# prints as OPEN with its counterexample and does not fail the run.
#   ./run.sh            all Z3 checks + Quint runs (10,000 samples each)
#   QUINT_SAMPLES=n ./run.sh   change the Quint sample count
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
PY="$ROOT/docs/spec/05-verification/.venv/bin/python"
QUINT="$ROOT/docs/spec/05-verification/node_modules/.bin/quint"
SAMPLES="${QUINT_SAMPLES:-10000}"
cd "$HERE"
fail=0
for m in fv_backing fv_list fv_exposure fv_pending fv_hub fv_token fv_lpvault fv_arith fv_lpvalue fv_solvency fv_amm; do
  echo "=== $m"
  "$PY" "$m.py" || fail=1
done

echo "=== custody.qnt FV-CUS-QNT-01 (conforming calls + unsettled seizures; invariant inv, gap 0; $SAMPLES samples)"
if "$QUINT" run custody.qnt --invariant=inv --max-samples="$SAMPLES" --max-steps=20 --seed=0x1 >/tmp/fv-cus-qnt01.$$ 2>&1; then
  echo "[VERIFIED*] FV-CUS-QNT-01 no violation in $SAMPLES randomized runs of 20 steps"
else
  echo "[VIOLATED ] FV-CUS-QNT-01"; tail -40 /tmp/fv-cus-qnt01.$$; fail=1
fi
echo "=== custody.qnt FV-CUS-QNT-02 (adds burnSeized and settlePending without the other side; invariant invOneSided; $SAMPLES samples)"
if "$QUINT" run custody.qnt --step=stepOrphan --invariant=invOneSided --max-samples="$SAMPLES" --max-steps=20 --seed=0x1 >/tmp/fv-cus-qnt02.$$ 2>&1; then
  echo "[VERIFIED*] FV-CUS-QNT-02 no violation in $SAMPLES randomized runs of 20 steps"
else
  echo "[VIOLATED ] FV-CUS-QNT-02"; tail -40 /tmp/fv-cus-qnt02.$$; fail=1
fi
rm -f /tmp/fv-cus-qnt01.$$ /tmp/fv-cus-qnt02.$$
echo "=== spec ID check"
"$PY" check_ids.py || fail=1
echo
if [ "$fail" -ne 0 ]; then
  echo "custody: at least one check is not verified (see the VIOLATED, VACUOUS or UNKNOWN lines above)"
  exit 1
fi
echo "custody: all checks verified (any OPEN line above is a registered open finding, see report.md section 10)"
