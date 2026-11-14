#!/usr/bin/env bash
# Runs every FV-C (control) check. Exit code is non-zero if any property is Violated or Unknown, if a
# Quint invariant expected to hold fails, or if a cited spec ID is undefined. A violation registered as an
# open finding (common.open_finding) prints as [OPN] with its counterexample and does not fail the run.
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../../../.. && pwd)"
PY="$ROOT/docs/spec/05-verification/.venv/bin/python"
QUINT="$ROOT/docs/spec/05-verification/node_modules/.bin/quint"
status=0
mkdir -p results
for f in fv_ctl_access.py fv_ctl_timelock.py fv_ctl_pause.py fv_ctl_gates.py fv_ctl_params.py fv_ctl_registry.py \
         fv_ctl_oracle.py fv_ctl_upgrade_lens.py fv_ctl_breakers.py fv_ctl_amm.py; do
  echo; echo "=== $f"
  "$PY" "$f" || status=1
done
echo; echo "=== Quint governance.qnt (randomized simulation, 10,000 samples x 12 steps per invariant)"
"$QUINT" typecheck governance.qnt || status=1
: > results/quint.txt
for m in gov; do
  for inv in execWaitedNormalDelay pauseTransitionsLegal upgradesGuardianCancellable adminOnlyTimelock \
             normalDelayInBounds restoringNotGuardianCancellable; do
    out=$("$QUINT" run --main "$m" --max-samples 10000 --max-steps 12 --invariant "$inv" --seed 0x1 governance.qnt 2>&1)
    if echo "$out" | grep -q "No violation found"; then r="no violation (10,000 samples)"; else r="VIOLATED"; status=1; fi
    printf '[quint] FV-CTL-98 %-4s %-32s %s\n' "$m" "$inv" "$r" | tee -a results/quint.txt
  done
done
echo; echo "=== spec ID check"
"$PY" check_ids.py || status=1
echo; echo "=== open findings (violations recorded in report.md section 13.3; they do not fail the run)"
grep -h '"status": "Violated (open finding' results/fv_ctl_*.json | sed 's/^ *//' || true
echo; [ $status -eq 0 ] && echo "ALL CHECKS PASS (open findings listed above)" || echo "VIOLATIONS PRESENT (see the findings in report.md)"
exit $status
