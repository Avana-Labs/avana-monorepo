#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Quint simulator runs for quint/avana.qnt (random traces, invariant checked at
# every state). Called by ../run_all.sh. Each line in CHECKS is one run:
#
#   ID | invariant (definition name or expression) | step relation | expectation [| init]
#
# expectation:
#   hold     no violation may be found (a violation fails this script)
#   witness  reachability check: the simulator must reach the state, which shows
#            the random traces exercise seizures, deficits, reconciliation, rescue
#            top-ups, timelock operations, etc.
#            (a miss is a warning in the default quick mode, a failure in full mode)
#
# Modes:
#   default        quick: 500 traces x 20 steps per check
#   QUINT_FULL=1   full: 10,000 traces x 20 steps per check
# Overrides: QNT_SAMPLES, QNT_STEPS, QNT_JOBS (default: CPU count),
# QNT_ONLY=<regex> (check IDs), QNT_LOGS (log folder; default: a fresh temp folder).
set -uo pipefail
cd "$(dirname "$0")"

if [ "${QUINT_FULL:-0}" = 1 ]; then QUICK=0; DEFAULT_SAMPLES=10000; else QUICK=1; DEFAULT_SAMPLES=500; fi
SAMPLES=${QNT_SAMPLES:-$DEFAULT_SAMPLES}
STEPS=${QNT_STEPS:-20}
JOBS=${QNT_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
ONLY=${QNT_ONLY:-.}
LOGS=${QNT_LOGS:-$(mktemp -d "${TMPDIR:-/tmp}/quint-avana.XXXXXX")}
mkdir -p "$LOGS"
QUINT="npx --no-install quint"

CHECKS=$(cat <<'EOF'
QNT-ALL-H | honestInvariants | step | hold
QNT-ALL-X | hostileInvariants | stepAll | hold
QNT-ALL-XH | hostileInvariants | stepAll | hold | initHostileSwap
QNT-ALL-HS | honestInvariants | step | hold | initStressed
QNT-ALL-XS | hostileInvariants | stepAll | hold | initStressedHostileSwap
QNT-ALL-HR | honestInvariants | step | hold | initRouteOutage
QNT-ALL-HC | honestInvariants | step | hold | initCrash
QNT-ALL-A | adapterInvariants | stepHostileAdapter | hold | initStressedHostileAdapter
QNT-01 | qnt01_oneRecordPerNft | stepAll | hold
QNT-02 | qnt02_recordCustody | stepAll | hold
QNT-03 | qnt03_supplyEqualsBacking | stepAll | hold
QNT-04 | qnt04_allowedHolders | stepAll | hold
QNT-05 | qnt05_liquidityCoversCredit | stepAll | hold
QNT-06 | qnt06_hubBalanceEqualsSupplied | stepAll | hold
QNT-07 | qnt07_perProxyLedger | stepAll | hold
QNT-08 | qnt08_proxyBinding | stepAll | hold
QNT-09 | qnt09_onlySwapSeizes | stepAll | hold
QNT-10 | qnt10_debitMatchesSeizure | stepAll | hold
QNT-11 | qnt11_feesToDepositor | stepAll | hold
QNT-12 | qnt12_rescueOnlyUncredited | stepAll | hold
QNT-13 | qnt13_hostileBounded | stepHostileAdapter | hold
QNT-14 | qnt14_repayAlwaysOpen | stepAll | hold
QNT-15 | qnt15_debtFreeWithdrawOpen | stepAll | hold
QNT-16 | qnt16_feeCollectionOpen | stepAll | hold
QNT-17 | qnt17_partialRepayOpen | stepAll | hold
QNT-18 | qnt18_noBorrowOnStale | step | hold
QNT-19 | qnt19_noBorrowWhenFrozen | step | hold
QNT-20 | qnt20_borrowFloorAndCap | step | hold
QNT-21 | qnt21_nonceUnique | stepAll | hold
QNT-22 | qnt22_noLiquidationOnStale | stepHostilePolicy | hold
QNT-23 | qnt23_noHealthySeizure | stepAll | hold
QNT-24 | qnt24_graceRespected | stepHostilePolicy | hold
QNT-25 | qnt25_topUpStates | step | hold
QNT-26 | qnt26_settlementConservation | stepHostilePolicy | hold
QNT-27 | qnt27_recoveryFloor | stepHostilePolicy | hold
QNT-28 | qnt28_callerFundsGap | stepAll | hold
QNT-29 | qnt29_gapOnlyOnSeizure | stepAll | hold
QNT-30 | qnt30_deficitCoverage | stepAll | hold
QNT-31 | qnt31_hubAccounting | stepAll | hold
QNT-32 | qnt32_avanaHaltBounded | stepHostilePolicy | hold
QNT-33 | qnt33_avanaRestrictionsExpire | stepAll | hold
QNT-34 | qnt34_keeperFloor | stepAll | hold
QNT-35 | qnt35_nftOwnership | stepAll | hold
QNT-36 | qnt36_liquidationLive | stepHostilePolicy | hold
QNT-37 | qnt37_pendingBacksTokens | stepAll | hold
QNT-38 | qnt38_policyGates | step | hold
QNT-39 | qnt39_repayNeverOverspends | stepAll | hold
QNT-40 | qnt40_callerFundsOwnGap | stepAll | hold
QNT-41 | qnt41_escrowSolvent | stepAll | hold
QNT-42 | qnt42_paramsOnlyRevert | stepHostilePolicy | hold
QNT-43 | qnt43_payoutEscrowed | stepAll | hold
QNT-44 | qnt44_pauseState | stepAll | hold
QNT-45 | qnt45_breakers | step | hold
QNT-46 | qnt46_addressFreeze | stepAll | hold
QNT-47 | qnt47_rescue | stepAll | hold
QNT-48 | qnt48_backingGap | stepAll | hold
QNT-49 | qnt49_removalRecredit | stepAll | hold
QNT-50 | qnt50_repayWithCollateral | stepAll | hold
QNT-51 | qnt51_accountIsolation | stepAll | hold
QNT-52 | qnt52_timelockDelays | stepAll | hold
QNT-53 | qnt53_restrictedCancel | stepAll | hold
QNT-54 | qnt54_standby | stepAll | hold
QNT-55 | qnt55_conservativeValuation | stepAll | hold
QNT-56 | qnt56_reportsAlertOnly | stepAll | hold
QNT-57 | qnt57_waterfall | stepHostilePolicy | hold
QNT-58 | qnt58_topUpSplit | stepAll | hold
W-SEIZE | s.g.seizers.size() == 0 | step | witness
W-SURPLUS | s.feeRecipient == 0 | step | witness
W-ZEROREC | s.recs.keys().forall(i => s.recs.get(i).credited > 0) | step | witness
W-DEFICIT | ASSETS.forall(a => s.deficitEver.get(a) == 0) | step | witness | initStressed
W-COVER | ASSETS.forall(a => s.coveredEver.get(a) == 0) | step | witness | initStressed
W-WITHDRAW | s.recs.keys().forall(i => s.recs.get(i).open) | step | witness
W-TWOMKT | PROXIES.forall(p => proxyMarkets(s, p).size() < 2) | step | witness
W-GRACE | MARKETS.forall(m => s.recoveredAt.get(m) < 0) | step | witness
W-DISAGREE | MARKETS.forall(m => not(disagreeExpiredForLiq(s, m))) | step | witness
W-STRAY | TOKEN_IDS.forall(t => s.strayProven.get(t) == "") | step | witness
W-KEEP | MARKETS.forall(m => s.bal.get((m, "LPVAULTSWAP")) == 0) | stepHostileSwap | witness | initStressedHostileSwap
W-PERM | not(la.act == "LPVaultSwap.liquidate" and not(KEEPERS_ALL.contains(la.who))) | step | witness
W-INKIND | la.act != "env.payoutRefusal" | step | witness
W-ESCROW | HOLDERS.forall(h => s.escrowCredited.get(h) == 0) | step | witness | initStressed
W-3PREPAY | not(la.act == "repay" or la.act == "repayAll") or PROXIES.filter(p => P_WALLET.get(p) == la.who).contains(la.tgt) | step | witness
W-PENDING | MARKETS.forall(m => s.pending.get(m) == 0) | stepHostileSwap | witness | initStressedHostileSwap
W-ORPHAN | not(Set("pledge", "withdraw", "removeLiquidity", "recredit").contains(la.act) and MARKETS.exists(m => s.orphan.get(m) > 0)) | stepHostileSwap | witness | initStressedHostileSwap
W-RESCUE | s.recs.keys().forall(i => s.recs.get(i).rescue == 0) | step | witness | initStressed
W-REMOVE | la.act != "removeLiquidity" | step | witness | initStressed
W-RECREDIT | la.act != "recredit" | step | witness | initStressed
W-RWC | la.act != "repayWithCollateral" | step | witness | initStressed
W-USDTLIQ | not(la.act == "LPVaultSwap.liquidate" and la.tgt == "USDT") | step | witness | initStressed
W-SHORTFALL | s.g.shortfallPaid == 0 | step | witness | initCrash
W-AUTOINKIND | la.act != "LPVaultSwap.reportRecoveryShortfall" | step | witness | initCrash
W-SURGE | MARKETS.forall(m => s.seizeWin.get(m) * 100 <= SURGE_PCT * (creditedMarket(s, m) + s.seizeWin.get(m))) | step | witness | initStressed
W-STANDBY | la.act != "guardian.useStandbyRoute" | step | witness
W-FROZENEXIT | not((la.act == "withdraw" or la.act == "repay") and s.frozen.contains(la.who)) | step | witness | initStressed
W-TLEXEC | s.ops.keys().forall(i => s.ops.get(i).status != "Done") | step | witness
W-DAOPROP | s.ops.keys().forall(i => s.ops.get(i).status != "Done" or s.ops.get(i).proposer != "AAVE_EXEC") | step | witness
W-DAOCANCEL | s.ops.keys().forall(i => s.ops.get(i).status != "Cancelled" or not(daoOnly(s.ops.get(i).calls))) | step | witness
EOF
)

status=0
pids=()
run_one() {
  local id="$1" inv="$2" step="$3" expect="$4" init="${5:-init}" log="$LOGS/$1.log" start end res
  start=$(date +%s)
  $QUINT run --max-samples="$SAMPLES" --max-steps="$STEPS" --init="$init" --step="$step" --invariant="$inv" avana.qnt >"$log" 2>&1
  end=$(date +%s)
  if grep -q '^\[ok\]' "$log"; then res=hold
  elif grep -q '^\[violation\]' "$log"; then res=violated
  else res=error; fi
  local verdict
  case "$expect:$res" in
    hold:hold) verdict="PASS  holds within bounds" ;;
    witness:violated) verdict="PASS  state reached" ;;
    witness:hold) if [ "$QUICK" = 1 ]; then verdict="PASS  WARNING: state not reached in quick mode"; else verdict="FAIL  state not reached (coverage too low)"; fi ;;
    hold:violated) verdict="FAIL  NEW COUNTEREXAMPLE" ;;
    *) verdict="FAIL  quint error" ;;
  esac
  printf '%-10s %-8s %-18s %4ss  %s  (%s)\n' "$id" "$expect" "$step" "$((end - start))" "$verdict" "$log"
  [[ "$verdict" == PASS* ]]
}

echo "quint run ($( [ $QUICK = 1 ] && echo quick || echo full ) mode): $SAMPLES samples x $STEPS steps per check, $JOBS parallel; logs in $LOGS"
while IFS='|' read -r id inv step expect init; do
  id=$(echo "$id" | xargs); inv=$(echo "$inv" | sed 's/^ *//; s/ *$//'); step=$(echo "$step" | xargs); expect=$(echo "$expect" | xargs); init=$(echo "${init:-init}" | xargs)
  [ -z "$id" ] && continue
  echo "$id" | grep -Eq "$ONLY" || continue
  run_one "$id" "$inv" "$step" "$expect" "$init" &
  pids+=($!)
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
done <<< "$CHECKS"
for p in "${pids[@]}"; do wait "$p" || status=1; done
[ $status -eq 0 ] && echo "quint run: all checks as expected" || echo "quint run: FAILURES (see logs above)"
exit $status
