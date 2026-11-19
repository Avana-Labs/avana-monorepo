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
#   03-avana                      Avana's AccessManager and one core stack per integration (LPVault, RiskModule,
#                                 LiquidationModule, AaveAdapter, FlashloanRepay, operator FlashLiquidators), every
#                                 role, the admin handed to the governance Safe
#   06-aave-deployment-aip        AAVE  debt assets, Lend and CDP Spokes, bootstrap supply, FLASH_BORROWER
#   07-deploy-first-loss-reserves     Avana's First-Loss Reserve and the DAO Deficit Offset of each (Hub, debt asset)
#   08-aave-loss-layers-aip       AAVE  both layers on their Hub, deficit eliminator, roles (withdraw 14 days), minimums
#   07-fund-first-loss-reserves       Avana Labs funds its reserves to their minimums
#   09-listing-setup              CDP Spokes, debt reserves, fee, coverage ratio, keepers (timelock, governance delay)
#   09-execute-listing-setup
#   09-listing-markets            listPool: each pool as a Full range and a Custom range market (timelock)
#   09-execute-listing-markets
#   09-vault-tokens               each market's VaultToken and LPOracle, their roles (the DAO as admin)
#   10-aave-markets-aip           AAVE  adapters as position managers, debt reserves borrowable, vault-token reserves
#   09-listing-activate           activateMarket for each market (timelock)
#   09-execute-listing-activate
#
# Signing: on anvil every sender is unlocked (anvil --auto-impersonate): the deployer is AVANA_DEPLOYER (default the
# first anvil account) and the Safe, the Aave executor's PayloadsController and the faucet come from the network
# config. 02-test-world also signs the feeds' first OCR2 reports as the four oracles of AVANA_OCR_ORACLES, from the
# encrypted keystores ocr-0 … ocr-3 and the password file in AVANA_OCR_KEYSTORE_DIR (script/e2e/e2e-local.sh generates
# them). Elsewhere AVANA_SIGNER_FLAGS gives forge's signer flags (for example `--account deployer --sender 0x…`, plus
# the oracles' `--keystore` and `--password-file` for 02), and the timelock operations are written for the governance
# Safe instead of scheduled.
# A run is local when the RPC's chain ID is a local node's (31337, 31338), whatever the network's name: the local stack
# (script/local/stack.ts) names its chains `ethereum` and `base`, as on the real networks. On a local chain the deployer
# signs from its encrypted Foundry keystore when AVANA_DEPLOYER_KEYSTORE and AVANA_DEPLOYER_PASSWORD_FILE are set
# (AVANA_DEPLOYER is its address); the governance roles stay unlocked senders.
# Elsewhere, with AVANA_KEYSTORE_PATHS (encrypted keystore files, `;`-separated) and AVANA_KEYSTORE_PASSWORD_FILE (their
# shared password), every account a step signs as is loaded from those keystores, AVANA_DEPLOYER is the default sender,
# and with AVANA_SCHEDULE_OPERATIONS=1 the timelock operations are scheduled by the governance Safe's keystore, as on
# anvil (script/testnet/testnet.ts sets all four).
# The RPC reaches forge through the foundry.toml endpoint avana_step (AVANA_RPC_URL) and cast through ETH_RPC_URL,
# never a command-line argument. AVANA_VERIFY=1 verifies each step's contracts on the explorer after its broadcast
# (forge script --resume --verify, ETHERSCAN_API_KEY); a failed verification is reported and does not fail the step.

set -euo pipefail
cd "$(dirname "$0")/../.."
step="${1:?usage: script/deploy/step.sh <step>; the steps are listed at the top of this file}"
: "${AVANA_NETWORK:?set AVANA_NETWORK (anvil, sepolia, ethereum, base)}"
: "${AVANA_RPC_URL:?set AVANA_RPC_URL}"
export ETH_RPC_URL="$AVANA_RPC_URL"

deployer="${AVANA_DEPLOYER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
schedule=0
envs=()
case "$step" in
  00-factories) script=00_Factories.s.sol ;;
  01-aave-v4) script=01_DeployAaveV4.s.sol ;;
  02-test-world) script=02_DeployWorld.s.sol ;;
  03-avana) script=03_DeployAvana.s.sol ;;
  06-aave-deployment-aip) script=06_AaveDeploymentPayload.s.sol ;;
  07-deploy-first-loss-reserves) script=07_DeployFirstLossReserves.s.sol; envs+=(AVANA_COVERAGE_STEP=deploy) ;;
  08-aave-loss-layers-aip) script=08_AaveLossLayersPayload.s.sol ;;
  07-fund-first-loss-reserves) script=07_DeployFirstLossReserves.s.sol; envs+=(AVANA_COVERAGE_STEP=fund) ;;
  09-listing-setup) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=setup); schedule=1 ;;
  09-execute-listing-setup) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-setup) ;;
  09-listing-markets) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=markets); schedule=1 ;;
  09-execute-listing-markets) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-markets) ;;
  09-vault-tokens) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=vault-tokens); schedule=1 ;;
  10-aave-markets-aip) script=10_AaveListingPayload.s.sol ;;
  09-listing-activate) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=activate); schedule=1 ;;
  09-execute-listing-activate) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-activate) ;;
  *) echo "unknown step $step; the steps are listed at the top of script/deploy/step.sh" >&2; exit 2 ;;
esac

local_net=0
case "$(cast chain-id)" in 31337 | 31338) local_net=1 ;; esac
if [ $local_net -eq 1 ]; then
  sender="$deployer"
  # The scheduling steps broadcast as the deployer and schedule as the Safe (09-vault-tokens: send as the DAO).
  [ $schedule -eq 1 ] && envs+=(AVANA_SCHEDULE=1)
  signer=(--unlocked --sender "$sender")
  if [ -n "${AVANA_DEPLOYER_KEYSTORE:-}" ]; then
    signer+=(--keystore "$AVANA_DEPLOYER_KEYSTORE" --password-file "${AVANA_DEPLOYER_PASSWORD_FILE:?set AVANA_DEPLOYER_PASSWORD_FILE}")
  fi
  if [ "$step" = 02-test-world ] && [ -n "${AVANA_OCR_KEYSTORE_DIR:-}" ]; then
    for i in 0 1 2 3; do signer+=(--keystore "$AVANA_OCR_KEYSTORE_DIR/ocr-$i"); done
    for i in 0 1 2 3; do signer+=(--password-file "$AVANA_OCR_KEYSTORE_DIR/password"); done
  fi
elif [ -n "${AVANA_KEYSTORE_PATHS:-}" ]; then
  : "${AVANA_DEPLOYER:?set AVANA_DEPLOYER to the address of the deployer keystore}"
  : "${AVANA_KEYSTORE_PASSWORD_FILE:?set AVANA_KEYSTORE_PASSWORD_FILE}"
  signer=(--sender "$deployer")
  IFS=';' read -r -a keystores <<< "$AVANA_KEYSTORE_PATHS"
  for k in "${keystores[@]}"; do signer+=(--keystore "$k" --password-file "$AVANA_KEYSTORE_PASSWORD_FILE"); done
  [ $schedule -eq 1 ] && [ "${AVANA_SCHEDULE_OPERATIONS:-0}" = 1 ] && envs+=(AVANA_SCHEDULE=1)
else
  read -r -a signer <<< "${AVANA_SIGNER_FLAGS:?set AVANA_SIGNER_FLAGS, for example --account deployer --sender 0x…}"
fi

# One script run can deploy hundreds of contracts: lift the simulation's per-call gas cap (Foundry's gas_limit, 2^30
# by default) as well as the block gas limit. AVANA_FORGE_FLAGS adds flags (the rehearsal's --start-fresh on resume).
read -r -a extra <<< "${AVANA_FORGE_FLAGS:-}"
# Off anvil the scripts check that HEAD is the AVANA_RELEASE tag with git (DeployInputs._requireReleaseCheckout).
ffi=()
[ $local_net -eq 0 ] && ffi=(--ffi)
run() {
  env FOUNDRY_GAS_LIMIT=30000000000 ${envs[@]+"${envs[@]}"} forge script "script/deploy/$script" --rpc-url avana_step "${signer[@]}" --slow \
    --non-interactive --disable-block-gas-limit --memory-limit 1073741824 "$@"
}
run --broadcast ${extra[@]+"${extra[@]}"} ${ffi[@]+"${ffi[@]}"}
[ "${AVANA_VERIFY:-0}" = 1 ] || exit 0
# The broadcast passed: verify what it deployed from the run's broadcast record (--resume sends nothing again).
if ! run --resume --verify --retries 10 --delay 15 ${ffi[@]+"${ffi[@]}"}; then
  echo "VERIFY FAILED for $step: rerun it with AVANA_VERIFY=1 once the explorer has indexed the contracts" >&2
fi
