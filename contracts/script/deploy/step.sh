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
#   07-deploy-first-loss-reserves     the Avana Umbrella of each (Hub, debt asset)
#   08-aave-loss-layers-aip       AAVE  DAO deficit offsets and both loss layers' roles, caps and minimums
#   07-fund-first-loss-reserves       Avana Labs funds each Umbrella to its minimum
#   09-listing-setup              tokens, feeds, CDP Spokes, First-Loss Reserves, credit lines (timelock, normal delay)
#   09-execute-listing-setup
#   09-debt-oracles               GHO's fixed source and the DebtOracle of every other debt asset
#   10-aave-debt-reserves-aip     AAVE  debt-reserve price sources, borrowable
#   09-market-metadata            the listing metadata file (market and debt-reserve pages); its hash is the next salt
#   09-listing-markets            LPOracles, swap routes, the listing batch (timelock, normal delay)
#   09-execute-listing-markets
#   10-aave-markets-aip           AAVE  vault-token assets and collateral reserves
#   09-listing-activate           LPOracles poked, activateMarket (timelock, short delay)
#   09-execute-listing-activate
#   12-gas-vault                  the chain's AvanaGasVault (treasury = feeRecipient, checked on chain; no role granted)
#   12-gas-vault-signers          addSigner of each configured keeper signer (timelock, normal delay)
#   12-execute-gas-vault-signers
#   12-fund-gas-vault             the treasury funds the vault to gasVault.fundWei (Ethereum and Base: printed for the Safe)
#
# Changes to a live deployment (deploy recipe B8), any time after the first deployment:
#   11-changes <file>             a JSON list of changes, each checked against its on-chain limit, run as one timelock
#                                 operation, one guardian or risk-steward call, one AAVE AIP, or under a delegated Aave
#                                 role (script/deploy/changes.ts; the format is at its top). Exit 2: refused by a limit
#                                 check; 3: not available on this deployment (a role Aave has not granted)
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

set -euo pipefail
cd "$(dirname "$0")/../.."
step="${1:?usage: script/deploy/step.sh <step>; the steps are listed at the top of this file}"
: "${AVANA_NETWORK:?set AVANA_NETWORK (anvil, sepolia, ethereum, base)}"
: "${AVANA_RPC_URL:?set AVANA_RPC_URL}"
CONFIG="${AVANA_CONFIG:-script/deploy/config/$AVANA_NETWORK.json}"
config() { node -e 'const c=require(process.argv[1]);console.log(process.argv[2].split(".").reduce((o,k)=>o[k],c))' "./$CONFIG" "$1"; }

# Not a forge script: an operator's changes (deploy recipe B8), from a changes file.
if [ "$step" = 11-changes ]; then
  exec env AVANA_NETWORK="$AVANA_NETWORK" AVANA_RPC_URL="$AVANA_RPC_URL" node script/deploy/changes.ts "${2:?usage: step.sh 11-changes <file>}"
fi

# Not a forge script: the listing metadata file, written from the config's page text and the chain's IDs.
if [ "$step" = 09-market-metadata ]; then
  exec env AVANA_NETWORK="$AVANA_NETWORK" AVANA_RPC_URL="$AVANA_RPC_URL" node script/deploy/market-metadata.ts
fi

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
  07-deploy-first-loss-reserves) script=07_DeployAvanaFirstLossReserves.s.sol; envs+=(AVANA_COVERAGE_STEP=deploy) ;;
  08-aave-loss-layers-aip) script=08_AaveLossLayersPayload.s.sol ;;
  07-fund-first-loss-reserves) script=07_DeployAvanaFirstLossReserves.s.sol; envs+=(AVANA_COVERAGE_STEP=fund) ;;
  09-listing-setup) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=setup); schedule=1 ;;
  09-execute-listing-setup) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-setup) ;;
  09-debt-oracles) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=oracles) ;;
  10-aave-debt-reserves-aip) script=10_AaveListingPayload.s.sol; envs+=(AVANA_AAVE_STEP=debt) ;;
  09-listing-markets) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=markets); schedule=1 ;;
  09-execute-listing-markets) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-markets) ;;
  10-aave-markets-aip) script=10_AaveListingPayload.s.sol; envs+=(AVANA_AAVE_STEP=vault-tokens) ;;
  09-listing-activate) script=09_ListMarkets.s.sol; envs+=(AVANA_LISTING_STEP=activate); schedule=1 ;;
  09-execute-listing-activate) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=listing-activate) ;;
  12-gas-vault) script=12_DeployGasVault.s.sol; envs+=(AVANA_GAS_VAULT_STEP=deploy) ;;
  12-gas-vault-signers) script=12_DeployGasVault.s.sol; envs+=(AVANA_GAS_VAULT_STEP=signers); schedule=1 ;;
  12-execute-gas-vault-signers) script=05_ExecuteOperations.s.sol; envs+=(AVANA_OPERATIONS=gas-vault-signers) ;;
  12-fund-gas-vault) script=12_DeployGasVault.s.sol; envs+=(AVANA_GAS_VAULT_STEP=fund) ;;
  *) echo "unknown step $step; the steps are listed at the top of script/deploy/step.sh" >&2; exit 2 ;;
esac

local_net=0
case "$(cast chain-id --rpc-url "$AVANA_RPC_URL")" in 31337 | 31338) local_net=1 ;; esac
if [ $local_net -eq 1 ]; then
  sender="$deployer"
  # 04 broadcasts as the Safe itself; the other scheduling steps broadcast as the deployer and schedule as the Safe.
  [ "$step" = 04-access-operations ] && sender="$(config governance.governanceSafe)"
  [ $schedule -eq 1 ] && envs+=(AVANA_SCHEDULE=1)
  signer=(--unlocked --sender "$sender")
  if [ -n "${AVANA_DEPLOYER_KEYSTORE:-}" ]; then
    signer+=(--keystore "$AVANA_DEPLOYER_KEYSTORE" --password-file "${AVANA_DEPLOYER_PASSWORD_FILE:?set AVANA_DEPLOYER_PASSWORD_FILE}")
  fi
  if [ "$step" = 02-test-world ] && [ -n "${AVANA_OCR_KEYSTORE_DIR:-}" ]; then
    for i in 0 1 2 3; do signer+=(--keystore "$AVANA_OCR_KEYSTORE_DIR/ocr-$i"); done
    for i in 0 1 2 3; do signer+=(--password-file "$AVANA_OCR_KEYSTORE_DIR/password"); done
  fi
else
  read -r -a signer <<< "${AVANA_SIGNER_FLAGS:?set AVANA_SIGNER_FLAGS, for example --account deployer --sender 0x…}"
fi

# One script run can deploy hundreds of contracts: lift the simulation's per-call gas cap (Foundry's gas_limit, 2^30
# by default) as well as the block gas limit. AVANA_FORGE_FLAGS adds flags (the rehearsal's --start-fresh on resume).
read -r -a extra <<< "${AVANA_FORGE_FLAGS:-}"
# Off anvil the scripts check that HEAD is the AVANA_RELEASE tag with git (DeployInputs._requireReleaseCheckout).
[ $local_net -eq 0 ] && extra+=(--ffi)
exec env FOUNDRY_GAS_LIMIT=30000000000 ${envs[@]+"${envs[@]}"} forge script "script/deploy/$script" --rpc-url "$AVANA_RPC_URL" \
  --broadcast "${signer[@]}" --slow --non-interactive --disable-block-gas-limit --memory-limit 1073741824 ${extra[@]+"${extra[@]}"}
