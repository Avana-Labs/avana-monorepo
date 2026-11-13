#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Runs one named deployment step, the same command the deployment recipe lists and the local rehearsal
# (script/e2e/e2e-local.sh) calls. From contracts/:
#
#   AVANA_NETWORK=anvil AVANA_RPC_URL=http://127.0.0.1:8545 script/deploy/step.sh <step>
#   make step-<step>            (the same, with the environment of contracts/.env)
#
# Steps, in order (the Aave side is marked AAVE; on Ethereum and Base it is the Aave DAO's, and its scripts only
# write the AIP actions):
#   00-factories                  Safe Singleton Factory and AvanaCreate3Factory
#   01-aave-v4                    AAVE  Aave V4 and its config engine (test networks only)
#   02-test-world                       tokens, Chainlink OCR2 feeds, Uniswap v3, Slipstream, Aave V3 (test networks)
#   03-avana                      every Avana contract
#   04-access-operations          writes, and on anvil schedules as the Safe, the guardian-roles and chain-wiring
#   05-execute-access-operations  executes them once the timelock delay has passed
#   06-aave-deployment-aip        AAVE  debt assets, Lend and CDP Spokes, bootstrap supply, FLASH_BORROWER
#   07-deploy-coverage-spokes     the Avana Umbrella of each (Hub, debt asset)
#   08-aave-loss-layers-aip       AAVE  DAO deficit offsets and both loss layers' roles, caps and minimums
#   07-fund-coverage-spokes       Avana Labs funds each Umbrella to its minimum
#   09-listing-setup              tokens, feeds, CDP Spokes, Coverage Spokes, credit lines (timelock, normal delay)
#   09-execute-listing-setup
#   09-debt-oracles               GHO's fixed source and the DebtOracle of every other debt asset
#   10-aave-debt-reserves-aip     AAVE  debt-reserve price sources, borrowable
#   09-listing-markets            LPOracles, swap routes, the listing batch (timelock, normal delay)
#   09-execute-listing-markets
#   10-aave-markets-aip           AAVE  vault-token assets and collateral reserves
#   09-listing-activate           LPOracles poked, activateMarket (timelock, short delay)
#   09-execute-listing-activate
#
# Signing: on anvil every sender is unlocked (anvil --auto-impersonate): the deployer is AVANA_DEPLOYER (default the
# first anvil account) and the Safe, the Aave executor's PayloadsController and the faucet come from the network
# config. Elsewhere AVANA_SIGNER_FLAGS gives forge's signer flags (for example `--account deployer --sender 0x…`),
# and the timelock operations are written for the governance Safe instead of scheduled.

set -euo pipefail
cd "$(dirname "$0")/../.."
step="${1:?usage: script/deploy/step.sh <step>; the steps are listed at the top of this file}"
: "${AVANA_NETWORK:?set AVANA_NETWORK (anvil, sepolia, ethereum, base)}"
: "${AVANA_RPC_URL:?set AVANA_RPC_URL}"
CONFIG="script/deploy/config/$AVANA_NETWORK.json"
config() { node -e 'const c=require(process.argv[1]);console.log(process.argv[2].split(".").reduce((o,k)=>o[k],c))' "./$CONFIG" "$1"; }

deployer="${AVANA_DEPLOYER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
schedule=0
envs=()
case "$step" in
  00-factories) script=00_Factories.s.sol ;;
  01-aave-v4) script=01_DeployAaveV4.s.sol ;;
  02-test-world) script=02_DeployWorld.s.sol ;;
  03-avana) script=03_DeployAvana.s.sol ;;
  04-access-operations) script=04_ConfigureAccess.s.sol; schedule=1 ;;
  05-execute-access-operations) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=guardian-roles,chain-wiring) ;;
  06-aave-deployment-aip) script=06_AaveDeploymentPayload.s.sol ;;
  07-deploy-coverage-spokes) script=07_DeployCoverageSpokes.s.sol; envs+=(AVANA_COVERAGE_STEP=deploy) ;;
  08-aave-loss-layers-aip) script=08_AaveLossLayersPayload.s.sol ;;
  07-fund-coverage-spokes) script=07_DeployCoverageSpokes.s.sol; envs+=(AVANA_COVERAGE_STEP=fund) ;;
  09-listing-setup) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=setup); schedule=1 ;;
  09-execute-listing-setup) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-setup) ;;
  09-debt-oracles) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=oracles) ;;
  10-aave-debt-reserves-aip) script=10_AaveListingPayload.s.sol; envs+=(AVANA_AAVE_STEP=debt) ;;
  09-listing-markets) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=markets); schedule=1 ;;
  09-execute-listing-markets) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-markets) ;;
  10-aave-markets-aip) script=10_AaveListingPayload.s.sol; envs+=(AVANA_AAVE_STEP=vault-tokens) ;;
  09-listing-activate) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=activate); schedule=1 ;;
  09-execute-listing-activate) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-activate) ;;
  *) echo "unknown step $step; the steps are listed at the top of script/deploy/step.sh" >&2; exit 2 ;;
esac

if [ "$AVANA_NETWORK" = anvil ]; then
  sender="$deployer"
  # 04 broadcasts as the Safe itself; the other scheduling steps broadcast as the deployer and schedule as the Safe.
  [ "$step" = 04-access-operations ] && sender="$(config governance.governanceSafe)"
  [ $schedule -eq 1 ] && envs+=(AVANA_SCHEDULE=1)
  signer=(--unlocked --sender "$sender")
else
  read -r -a signer <<< "${AVANA_SIGNER_FLAGS:?set AVANA_SIGNER_FLAGS, for example --account deployer --sender 0x…}"
fi

# One script run can deploy hundreds of contracts: lift the simulation's per-call gas cap (Foundry's gas_limit, 2^30
# by default) as well as the block gas limit. AVANA_FORGE_FLAGS adds flags (the rehearsal's --start-fresh on resume).
read -r -a extra <<< "${AVANA_FORGE_FLAGS:-}"
exec env FOUNDRY_GAS_LIMIT=30000000000 ${envs[@]+"${envs[@]}"} forge script "script/deploy/$script" --rpc-url "$AVANA_RPC_URL" \
  --broadcast "${signer[@]}" --slow --non-interactive --disable-block-gas-limit --memory-limit 1073741824 ${extra[@]+"${extra[@]}"}
