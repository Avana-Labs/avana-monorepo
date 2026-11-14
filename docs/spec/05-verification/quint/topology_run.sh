#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Quint simulator runs for quint/topology.qnt (multi-Hub, multi-Spoke topology of the
# AMM-neutral proposal; report: audit/design-review/amm-neutral/state-machine.md).
# Runs on the nightly path (../run_all.sh --nightly), or by hand from any directory. The quick
# path runs only the deterministic scenarios of topology_tests.qnt (QNT-TOPO-T00 … T19).
# Each ID below simulates one invariant of topology.qnt (QNT-TOPO-01 … X2) or a reachability witness.
#
#   ID | invariant | step relation | expectation | init
#
# expectation:
#   hold     no violation may be found (a violation fails this script)
#   finding  a known finding (AMMN-SM-NN): the simulator is expected to find the
#            counterexample; a miss is a warning, because topology_tests.qnt replays it
#   witness  reachability check (the state must be reached; a miss is a warning)
#
# Defaults: 1,000 traces x 25 steps per check. Overrides: QNT_SAMPLES, QNT_STEPS,
# QNT_JOBS (default: CPU count), QNT_ONLY (regex on IDs), QNT_LOGS (log folder).
set -uo pipefail
cd "$(dirname "$0")"

SAMPLES=${QNT_SAMPLES:-1000}
STEPS=${QNT_STEPS:-25}
JOBS=${QNT_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
ONLY=${QNT_ONLY:-.}
LOGS=${QNT_LOGS:-$(mktemp -d "${TMPDIR:-/tmp}/quint-topology.XXXXXX")}
mkdir -p "$LOGS"
QUINT="npx --no-install quint"

CHECKS=$(cat <<'LIST'
P-01 | topo01_custody | stepFaulty | hold | initProposalLoaded
P-02 | topo02_supplyEqualsCredit | stepFaulty | hold | initProposalLoaded
P-02b | topo02b_perProxy | step | finding | initProposalLoaded
P-03 | topo03_noCrossRouting | step | finding | initProposalLoaded
P-04 | topo04_hubDebtWithinCaps | step | finding | initProposalLoaded
P-04g | topo04g_drawGate | step | hold | initProposalLoaded
P-05 | topo05_crossHubCap | step | finding | initProposalLoaded
P-06 | topo06_lossAttribution | stepFaulty | hold | initProposalLoaded
P-07 | topo07_stopsNeverReachExits | step | finding | initProposalLoaded
P-08 | topo08_migration | step | finding | initProposalLoaded
P-09 | topo09_delistingNeverStrands | step | finding | initProposalLoaded
P-10 | topo10_shockIsolation | step | finding | initProposalLoaded
P-10p | topo10p_poolShockIsolation | step | hold | initProposalLoaded
P-X1 | topoX1_fundingPause | step | finding | initProposalLoaded
P-X2 | topoX2_tokenCap | step | finding | initProposal
F-ALL | allFixed | step | hold | initFixedLoaded
F-ALL0 | allFixed | step | hold | initFixed
F-ALLF | allFixedAnySwap | stepFaulty | hold | initFixedLoaded
F-01 | topo01_custody | stepFaulty | hold | initFixedLoaded
F-02 | topo02_supplyEqualsCredit | stepFaulty | hold | initFixedLoaded
F-03 | topo03_noCrossRouting | stepFaulty | hold | initFixedLoaded
F-04 | topo04_hubDebtWithinCaps | step | finding | initFixedLoaded
F-05 | topo05_crossHubCap | step | hold | initFixedLoaded
F-06 | topo06_lossAttribution | stepFaulty | hold | initFixedLoaded
F-07 | topo07_stopsNeverReachExits | stepFaulty | hold | initFixedLoaded
F-08 | topo08_migration | stepFaulty | hold | initFixedLoaded
F-09 | topo09_delistingNeverStrands | stepFaulty | hold | initFixedLoaded
F-10 | topo10_shockIsolation | step | finding | initFixedLoaded
W-LIQ | la.act != "LPVaultSwap.liquidate" | step | witness | initFixedLoaded
W-DEFICIT | tuples(HUBS, ASSETS, SPOKES).forall(k => s.deficit.get(k) == 0) | step | witness | initFixedLoaded
W-XDEFICIT | s.deficit.get(("STABLE", "USDC", "S3")) == 0 | step | witness | initFixedCrash
W-COVER | la.act != "AvanaFirstLossReserve.coverDeficit" | step | witness | initFixedCrash
F-ALLC | allFixed | step | hold | initFixedCrash
W-MIGRATE | la.act != "migrateProxy" | step | witness | initFixedLoaded
W-MIGPAUSE | not(la.act == "migrateProxy" and HUBS.exists(h => s.pause.get(h) != "None")) | step | witness | initFixedLoaded
W-PENDING | MARKETS.forall(m => s.pending.get(m) == 0) | stepFaulty | witness | initFixedLoaded
W-SETTLE | la.act != "settlePending" | stepFaulty | witness | initFixedLoaded
W-OFFEXIT | not(la.act == "withdraw" and s.offboarding.size() > 0) | step | witness | initFixedLoaded
W-PAUSEREPAY | not(la.act == "repay" and HUBS.exists(h => s.pause.get(h) == "Paused")) | step | witness | initFixedLoaded
W-PAUSELIQ | not(la.act == "LPVaultSwap.liquidate" and HUBS.exists(h => s.pause.get(h) == "Paused")) | step | witness | initFixedLoaded
LIST
)

status=0
pids=()
run_one() {
  local id="$1" inv="$2" step="$3" expect="$4" init="$5" log="$LOGS/$1.log" start end res verdict
  start=$(date +%s)
  $QUINT run --max-samples="$SAMPLES" --max-steps="$STEPS" --init="$init" --step="$step" --invariant="$inv" topology.qnt >"$log" 2>&1
  end=$(date +%s)
  if grep -q '^\[ok\]' "$log"; then res=hold
  elif grep -q '^\[violation\]' "$log"; then res=violated
  else res=error; fi
  case "$expect:$res" in
    hold:hold) verdict="PASS  holds within bounds" ;;
    finding:violated) verdict="PASS  counterexample found" ;;
    finding:hold) verdict="PASS  WARNING: counterexample not reached (see topology_tests.qnt)" ;;
    witness:violated) verdict="PASS  state reached" ;;
    witness:hold) verdict="PASS  WARNING: state not reached" ;;
    hold:violated) verdict="FAIL  NEW COUNTEREXAMPLE" ;;
    *) verdict="FAIL  quint error" ;;
  esac
  printf '%-10s %-8s %-11s %-19s %4ss  %s  (%s)\n' "$id" "$expect" "$step" "$init" "$((end - start))" "$verdict" "$log"
  [[ "$verdict" == PASS* ]]
}

echo "quint run (topology): $SAMPLES samples x $STEPS steps per check, $JOBS parallel; logs in $LOGS"
while IFS='|' read -r id inv step expect init; do
  id=$(echo "$id" | xargs); inv=$(echo "$inv" | sed 's/^ *//; s/ *$//'); step=$(echo "$step" | xargs); expect=$(echo "$expect" | xargs); init=$(echo "$init" | xargs)
  [ -z "$id" ] && continue
  echo "$id" | grep -Eq "$ONLY" || continue
  run_one "$id" "$inv" "$step" "$expect" "$init" &
  pids+=($!)
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
done <<< "$CHECKS"
for p in "${pids[@]}"; do wait "$p" || status=1; done
[ $status -eq 0 ] && echo "quint run (topology): all checks as expected" || echo "quint run (topology): FAILURES (see logs above)"
exit $status
