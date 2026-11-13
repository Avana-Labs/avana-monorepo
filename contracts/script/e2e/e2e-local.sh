#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Local end-to-end rehearsal of an Avana deployment (deployments/README.md): a fresh anvil node, then every deploy step
# in order, the first two timelock operations scheduled as the governance Safe and executed after the 5-day delay, the
# release manifest produced and verified against the chain, the keeper and the indexer started on that manifest, and
# the scenario runner. Each step is recorded in deployments-local/anvil/e2e-status.json as pass, fail or not-run
# (with the reason): a missing tool or build artifact is reported as not-run, never as a pass.
#
# Usage, from contracts/:   script/e2e/e2e-local.sh            (all steps)
#                           E2E_STEPS="deploy manifest" script/e2e/e2e-local.sh
# Needs: anvil, forge, cast, node >= 22.12 with the workspace installed (npm ci at the repo root), and the builds
# `make build build-aave build-external` (the default and aave profiles, Uniswap v3, Slipstream, Aerodrome, Aave V3 and
# the Chainlink OCR2 aggregator and proxy).
# No key or RPC secret is used: anvil runs with --auto-impersonate and every script broadcasts with --unlocked.

set -uo pipefail
cd "$(dirname "$0")/../.."
CONTRACTS="$PWD"
REPO="$(cd .. && pwd)"
export AVANA_NETWORK=anvil
PORT="${E2E_PORT:-8545}"
export RPC_ANVIL="http://127.0.0.1:${PORT}"
OUT="$CONTRACTS/deployments-local/anvil"
LOG="$OUT/logs"
STATUS="$OUT/e2e-status.json"
STEPS="${E2E_STEPS:-deploy manifest services scenarios}"
# E2E_RESUME=<step name> reloads the anvil state the last run saved (anvil-state.json) and runs the deploy steps from
# that one on, keeping the earlier outputs: a failed step is fixed and rerun without redeploying the whole world.
RESUME="${E2E_RESUME:-}"
# A resumed run reruns a step whose earlier broadcast stopped part-way: that record is archived, not continued.
FRESH=""
[ -n "$RESUME" ] && FRESH="--start-fresh"
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SAFE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
mkdir -p "$LOG"
[ -n "$RESUME" ] && [ -f "$STATUS" ] || echo '{}' > "$STATUS"

record() { # step outcome detail
  node -e 'const fs=require("fs");const [f,s,o,d]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(f));j[s]={outcome:o,detail:d};fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n")' "$STATUS" "$1" "$2" "$3"
  printf '%-8s %-28s %s\n' "$(echo "$2" | tr a-z A-Z)" "$1" "$3"
}
need_tool() { command -v "$1" >/dev/null 2>&1; }
need_file() { [ -e "$1" ]; }

# ─── Prerequisites: a missing one marks the dependent steps not-run ───
MISSING=""
for t in anvil forge cast node; do need_tool "$t" || MISSING="$MISSING tool:$t"; done
need_file "$REPO/node_modules/viem" || MISSING="$MISSING npm-workspace(npm ci)"
for a in out/AvanaTimelock.sol/AvanaTimelock.json out/AvanaAaveV4Payload.sol/AvanaAaveV4Payload.json \
  out/AaveGovernanceExecutorStandIn.sol/AaveGovernanceExecutorStandIn.json out-aave/HubInstance.sol/HubInstance.json \
  out-aave/AaveV4ConfigEngine.sol/AaveV4ConfigEngine.json \
  out-univ3/UniswapV3Factory.sol/UniswapV3Factory.json out-univ3-periphery/NonfungiblePositionManager.sol/NonfungiblePositionManager.json \
  out-slipstream-v1/CLFactory.sol/CLFactory.json out-aerodrome/Voter.sol/Voter.json \
  out-aave-v3/AaveV3PoolBatch.sol/AaveV3PoolBatch.json \
  out-chainlink-ocr2/AccessControlledOCR2Aggregator.sol/AccessControlledOCR2Aggregator.json \
  out-chainlink-proxy/EACAggregatorProxy.sol/EACAggregatorProxy.json external/multicall3/Multicall3.runtime.hex; do
  need_file "$a" || MISSING="$MISSING build:$a"
done
if [ -n "$MISSING" ]; then
  for s in $STEPS; do record "$s" not-run "missing:$MISSING"; done
  exit 0
fi

ANVIL_PID=""
cleanup() { [ -n "$ANVIL_PID" ] && kill -INT "$ANVIL_PID" 2>/dev/null && wait "$ANVIL_PID" 2>/dev/null; [ -n "${SERVICE_PIDS:-}" ] && kill $SERVICE_PIDS 2>/dev/null; true; }
trap cleanup EXIT
# The chain state is saved to anvil-state.json when the node stops; a run without the deploy step reloads it, so the
# manifest and scenario steps can be rerun on the same deployment (E2E_STEPS="manifest scenarios"). A reloaded node
# holds only the latest state while the indexer reads contracts at past blocks (BlockOutOfRangeError), and anvil's
# --preserve-historical-states writes a 7 GB file for this world, so the services step runs only with the deploy step.
STATE="$OUT/anvil-state.json"
[[ " $STEPS " == *" deploy "* ]] && [ -z "$RESUME" ] && rm -f "$STATE"
anvil --port "$PORT" --chain-id 31337 --auto-impersonate --code-size-limit 49152 --gas-limit 60000000 \
  --timestamp 1794500000 --state "$STATE" > "$LOG/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 50); do cast block-number --rpc-url "$RPC_ANVIL" >/dev/null 2>&1 && break; sleep 0.2; done

# While resuming, a step before the resume point is skipped (its earlier outcome stays in the status file).
skipped() { # step
  [ -z "$RESUME" ] && return 1
  [ "$1" = "$RESUME" ] && { RESUME=""; return 1; }
  return 0
}

run_script() { # step (a name of script/deploy/step.sh)
  local step="$1"
  skipped "$step" && return 0
  if AVANA_NETWORK=anvil AVANA_RPC_URL="$RPC_ANVIL" AVANA_DEPLOYER="$DEPLOYER" AVANA_FORGE_FLAGS="$FRESH" \
    script/deploy/step.sh "$step" > "$LOG/$step.log" 2>&1; then
    record "$step" pass "$(grep -E 'BLOCKED|output' "$LOG/$step.log" | head -3 | tr '\n' ' ')"
    return 0
  fi
  record "$step" fail "see $LOG/$step.log: $(grep -E 'Error|revert' "$LOG/$step.log" | head -2 | tr '\n' ' ')"
  return 1
}

# Multicall3 at its canonical address, as on every public network (external/multicall3/README.md); the code hash must
# be the one recorded there.
MULTICALL3=0xcA11bde05977b3631167028862bE2a173976CA11
MULTICALL3_CODEHASH=0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891
place_multicall3() {
  skipped multicall3 && return 0
  cast rpc anvil_setCode "$MULTICALL3" "$(tr -d '\n' < external/multicall3/Multicall3.runtime.hex)" --rpc-url "$RPC_ANVIL" >/dev/null ||
    { record multicall3 fail "anvil_setCode refused"; return 1; }
  local h
  h="$(cast keccak "$(cast code "$MULTICALL3" --rpc-url "$RPC_ANVIL")")"
  if [ "$h" = "$MULTICALL3_CODEHASH" ]; then
    record multicall3 pass "code hash $h at $MULTICALL3"
  else
    record multicall3 fail "code hash $h at $MULTICALL3, expected $MULTICALL3_CODEHASH"
    return 1
  fi
}

# The timelock delays pass on anvil by moving the clock; every feed then publishes a fresh round, as a live
# Chainlink network does within its heartbeat, so the oracles read Live after each wait.
advance() { # seconds name
  skipped "$2" && return 0
  cast rpc evm_increaseTime "$1" --rpc-url "$RPC_ANVIL" >/dev/null && cast rpc evm_mine --rpc-url "$RPC_ANVIL" >/dev/null &&
    node script/e2e/refresh-feeds.ts --network anvil >> "$LOG/feeds.log" 2>&1 ||
    { record "advance-$1" fail "see $LOG/feeds.log"; return 1; }
}

# Aave governance v3's executor at the network's Aave DAO account, as on Ethereum: Aave V4's deployment (01) makes that
# account admin, and every Aave-side AIP then runs as `executeTransaction(payload, 0, "execute()", "", true)` from the
# PayloadsController (a stand-in account here). The stand-in's owner sits in storage slot 0.
place_executor() {
  skipped place-executor && return 0
  local dao controller code
  dao="$(node -e 'console.log(require("./script/deploy/config/anvil.json").aaveLocal.aaveDao)')"
  controller="$(node -e 'console.log(require("./script/deploy/config/anvil.json").aaveLocal.payloadsController)')"
  code="$(node -e 'console.log(require("./out/AaveGovernanceExecutorStandIn.sol/AaveGovernanceExecutorStandIn.json").deployedBytecode.object)')"
  cast rpc anvil_setCode "$dao" "$code" --rpc-url "$RPC_ANVIL" >/dev/null &&
    cast rpc anvil_setStorageAt "$dao" 0x0 "$(cast abi-encode 'f(address)' "$controller")" --rpc-url "$RPC_ANVIL" >/dev/null &&
    [ "$(cast call "$dao" 'owner()(address)' --rpc-url "$RPC_ANVIL")" = "$(cast to-check-sum-address "$controller")" ] &&
    record place-executor pass "executor stand-in at $dao, owner $controller" ||
    { record place-executor fail "could not place the executor stand-in at $dao"; return 1; }
}

if [[ " $STEPS " == *" deploy "* ]]; then
  # A fresh deployment: no output of an earlier run may stand in for this one's.
  [ -z "$RESUME" ] && rm -f "$OUT"/{aave,world,avana,coverage,deficit-offsets,manifest,scenarios,listing-oracles,listing-markets,listing-metadata}.json \
    "$OUT"/operation-*.json "$OUT"/aip-*.json
  [ -z "$RESUME" ] && rm -rf broadcast/*/31337 cache/*.s.sol/31337 "$OUT/listing-content"
  place_multicall3 &&
    run_script 00-factories &&
    run_script 01-aave-v4 &&
    place_executor &&
    run_script 02-test-world &&
    run_script 03-avana &&
    run_script 04-access-operations &&
    advance 432001 wait-access-operations &&
    run_script 05-execute-access-operations &&
    run_script 06-aave-deployment-aip &&
    run_script 07-deploy-coverage-spokes &&
    run_script 08-aave-loss-layers-aip &&
    run_script 07-fund-coverage-spokes &&
    run_script 09-listing-setup &&
    advance 432001 wait-listing-setup &&
    run_script 09-execute-listing-setup &&
    run_script 09-debt-oracles &&
    run_script 10-aave-debt-reserves-aip &&
    run_script 09-market-metadata &&
    run_script 09-listing-markets &&
    advance 432001 wait-listing-markets &&
    run_script 09-execute-listing-markets &&
    run_script 10-aave-markets-aip &&
    run_script 09-listing-activate &&
    advance 43201 wait-listing-activate &&
    run_script 09-execute-listing-activate
fi

if [[ " $STEPS " == *" manifest "* ]]; then
  if [ ! -f "$OUT/avana.json" ]; then
    record manifest not-run "no deploy output ($OUT/avana.json)"
  elif (cd "$REPO/packages/protocol" && node src/manifest/cli.ts produce --network anvil --rpc-env RPC_ANVIL) > "$LOG/manifest.log" 2>&1 &&
    (cd "$REPO/packages/protocol" && node src/manifest/cli.ts verify --manifest "$OUT/manifest.json" --rpc-env RPC_ANVIL) > "$LOG/verify.log" 2>&1 &&
    (cd "$REPO/packages/protocol" && node src/manifest/cli.ts table --manifest "$OUT/manifest.json" --out "$OUT/CONTRACTS.md") >> "$LOG/manifest.log" 2>&1; then
    record manifest pass "$(tail -1 "$LOG/verify.log")"
  else
    record manifest fail "see $LOG/manifest.log and $LOG/verify.log: $(tail -1 "$LOG/verify.log" 2>/dev/null)"
  fi
fi

if [[ " $STEPS " == *" services "* ]]; then
  if [[ " $STEPS " != *" deploy "* ]]; then
    record services not-run "the indexer reads past blocks, which a node reloaded from anvil-state.json does not hold: run it with the deploy step"
  elif [ -f "$OUT/manifest.json" ]; then
    script/e2e/services-smoke.sh "$OUT/manifest.json" > "$LOG/services.log" 2>&1
    rc=$?
    case $rc in
      0) record services pass "$(grep -E '^(keeper|indexer):|^convex: [0-9]' "$LOG/services.log" | tr '\n' ' ')" ;;
      3) record services not-run "$(tail -1 "$LOG/services.log")" ;;
      *) record services fail "see $LOG/services.log: $(tail -2 "$LOG/services.log" | tr '\n' ' ')" ;;
    esac
  else
    record services not-run "no manifest"
  fi
fi

if [[ " $STEPS " == *" scenarios "* ]]; then
  if [ -f "$OUT/manifest.json" ]; then
    if node script/e2e/scenarios/run.ts --network anvil > "$LOG/scenarios.log" 2>&1; then
      record scenarios pass "$(tail -1 "$LOG/scenarios.log")"
    else
      record scenarios fail "see $LOG/scenarios.log: $(tail -2 "$LOG/scenarios.log" | tr '\n' ' ')"
    fi
  else
    record scenarios not-run "no manifest"
  fi
fi

cat "$STATUS"
node -e 'const j=require(process.argv[1]);process.exit(Object.values(j).some(s=>s.outcome==="fail")?1:0)' "$STATUS"
