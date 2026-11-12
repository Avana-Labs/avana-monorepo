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
# `forge build` (default profile), `FOUNDRY_PROFILE=aave forge build`, `FOUNDRY_PROFILE=univ3 forge build`,
# `FOUNDRY_PROFILE=slipstream-v1 forge build` and `FOUNDRY_PROFILE=slipstream-main forge build`.
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
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SAFE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
mkdir -p "$LOG"
echo '{}' > "$STATUS"

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
for a in out/AvanaTimelock.sol/AvanaTimelock.json out-aave/HubInstance.sol/HubInstance.json \
  out-univ3/UniswapV3Factory.sol/UniswapV3Factory.json out-univ3-periphery/NonfungiblePositionManager.sol/NonfungiblePositionManager.json \
  out-slipstream-v1/CLFactory.sol/CLFactory.json out-aerodrome/Voter.sol/Voter.json; do
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
# manifest, services and scenario steps can be rerun on the same deployment (E2E_STEPS="manifest services scenarios").
STATE="$OUT/anvil-state.json"
[[ " $STEPS " == *" deploy "* ]] && rm -f "$STATE"
anvil --port "$PORT" --chain-id 31337 --auto-impersonate --code-size-limit 49152 --gas-limit 60000000 \
  --timestamp 1794500000 --state "$STATE" > "$LOG/anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 50); do cast block-number --rpc-url "$RPC_ANVIL" >/dev/null 2>&1 && break; sleep 0.2; done

run_script() { # step script sender [env...]
  local step="$1" script="$2" sender="$3"; shift 3
  # One script run deploys hundreds of contracts: lift the simulation's per-call gas cap (Foundry's gas_limit, 2^30
  # by default) as well as the block gas limit.
  if env FOUNDRY_GAS_LIMIT=30000000000 "$@" forge script "script/deploy/$script" --rpc-url "$RPC_ANVIL" --broadcast --unlocked --sender "$sender" \
    --slow --non-interactive --disable-block-gas-limit --memory-limit 1073741824 > "$LOG/$step.log" 2>&1; then
    record "$step" pass "$(grep -E 'BLOCKED|output' "$LOG/$step.log" | head -3 | tr '\n' ' ')"
    return 0
  fi
  record "$step" fail "see $LOG/$step.log: $(grep -E 'Error|revert' "$LOG/$step.log" | head -2 | tr '\n' ' ')"
  return 1
}

if [[ " $STEPS " == *" deploy "* ]]; then
  # A fresh deployment: no output of an earlier run may stand in for this one's.
  rm -f "$OUT"/{aave,world,avana,coverage,manifest,aave-payload,scenarios}.json "$OUT"/operation-*.json
  rm -rf broadcast/*/31337 cache/*.s.sol/31337
  run_script 00-factories 00_Factories.s.sol "$DEPLOYER" &&
    run_script 01-aave-v4 01_DeployAaveV4.s.sol "$DEPLOYER" &&
    run_script 02-world 02_DeployWorld.s.sol "$DEPLOYER" &&
    run_script 03-avana 03_DeployAvana.s.sol "$DEPLOYER" &&
    run_script 04-access 04_ConfigureAccess.s.sol "$SAFE" AVANA_SCHEDULE=1 &&
    cast rpc evm_increaseTime 432001 --rpc-url "$RPC_ANVIL" >/dev/null && cast rpc evm_mine --rpc-url "$RPC_ANVIL" >/dev/null &&
    run_script 05-execute 05_ExecuteOperations.s.sol "$DEPLOYER" &&
    run_script 06-aave-payload 06_AaveDeploymentPayload.s.sol "$DEPLOYER"
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
  if [ -f "$OUT/manifest.json" ]; then
    script/e2e/services-smoke.sh "$OUT/manifest.json" > "$LOG/services.log" 2>&1
    rc=$?
    case $rc in
      0) record services pass "$(grep -E '^(keeper|indexer):' "$LOG/services.log" | tr '\n' ' ')" ;;
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
