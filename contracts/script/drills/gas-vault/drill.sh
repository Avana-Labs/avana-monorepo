#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# AvanaGasVault testnet drill (docs/keeper-gas.md, Testnet drills): one action per run, signed by that action's role.
# From contracts/:
#
#   script/drills/gas-vault/drill.sh <network> <action> [--broadcast]
#   script/drills/gas-vault/drill.sh <network> all [--broadcast]       (every action in the drill's order)
#
# <network>: sepolia, base-sepolia or anvil. <action>, in the drill's order:
#   deploy (deployer), fund (treasury), add-signer (timelock), top-up (deployer: the empty signer to its target),
#   drain (signer), top-up (cut to what is left of the 24 h cap: the ToppedUp M-36 pages on), drain, check-cap (read
#   only: a third top-up is quoted at 0), pause (guardian), unpause (timelock), remove-signer (guardian), withdraw
#   (timelock: everything back to the treasury).
#
# Without --broadcast forge only simulates the one action against the chain as it is (so `all` without --broadcast
# stops at the first action that needs an earlier one) and writes nothing under the network's outputs: a simulated
# deploy goes to deployments-local/<network>-dry-run/. With --broadcast the transaction is sent.
#
# Signing: each role signs from its own encrypted Foundry keystore held outside the repository, never a raw key.
# On anvil every role is an unlocked account (anvil --auto-impersonate) and RPC_ANVIL is the node.

set -euo pipefail
cd "$(dirname "$0")/../../.."
network="${1:?usage: drill.sh <sepolia|base-sepolia|anvil> <action|all> [--broadcast]}"
action="${2:?usage: drill.sh <network> <action|all> [--broadcast]}"
broadcast="${3:-}"
[ -z "$broadcast" ] || [ "$broadcast" = --broadcast ] || { echo "third argument must be --broadcast or nothing" >&2; exit 2; }

case "$network" in
  sepolia) rpc="${RPC_SEPOLIA:?set RPC_SEPOLIA}"; chain=11155111 ;;
  base-sepolia) rpc="${RPC_BASE_SEPOLIA:?set RPC_BASE_SEPOLIA}"; chain=84532 ;;
  anvil) rpc="${RPC_ANVIL:-http://127.0.0.1:8545}"; chain=31337 ;;
  *) echo "network must be sepolia, base-sepolia or anvil" >&2; exit 2 ;;
esac
[ "$(cast chain-id --rpc-url "$rpc")" = "$chain" ] || { echo "the RPC endpoint is not chain $chain" >&2; exit 2; }

for r in DEPLOYER TREASURY TIMELOCK GUARDIAN SIGNER; do
  v="DRILL_$r"
  [[ "${!v:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "set $v to the $r address" >&2; exit 2; }
done
[ "$(printf '%s\n' "$DRILL_DEPLOYER" "$DRILL_TREASURY" "$DRILL_TIMELOCK" "$DRILL_GUARDIAN" "$DRILL_SIGNER" | tr A-F a-f | sort -u | wc -l)" = 5 ] ||
  { echo "the five drill addresses must differ" >&2; exit 2; }
export DRILL_DEPLOYER DRILL_TREASURY DRILL_TIMELOCK DRILL_GUARDIAN DRILL_SIGNER

# Without --broadcast the outputs go to a separate folder, so a simulation never replaces a deployed drill vault.
out_network="$network"
[ -z "$broadcast" ] && out_network="$network-dry-run"
if [ -z "$broadcast" ] && [ "$action" != deploy ] && [ -f "deployments-local/$network/gas-vault-drill.json" ]; then
  mkdir -p "deployments-local/$out_network"
  cp "deployments-local/$network/gas-vault-drill.json" "deployments-local/$out_network/gas-vault-drill.json"
fi

run() { # action
  local fn role
  case "$1" in
    deploy) fn="deploy()"; role=deployer ;;
    fund) fn="fund()"; role=treasury ;;
    add-signer) fn="addSigner()"; role=timelock ;;
    top-up) fn="topUp()"; role=deployer ;;
    drain) fn="drain()"; role=signer ;;
    check-cap) fn="checkCap()"; role=deployer ;;
    pause) fn="pause()"; role=guardian ;;
    unpause) fn="unpause()"; role=timelock ;;
    remove-signer) fn="removeSigner()"; role=guardian ;;
    withdraw) fn="withdraw()"; role=timelock ;;
    *) echo "unknown action $1" >&2; exit 2 ;;
  esac
  local up="${role^^}" sender
  sender="DRILL_$up"
  local signer=()
  if [ "$network" = anvil ]; then
    signer=(--unlocked --sender "${!sender}")
  else
    local account="DRILL_ACCOUNT_$up"
    signer=(--account "${!account:-gas-drill-$role}" --sender "${!sender}")
    [ -n "${DRILL_PASSWORD_FILE:-}" ] && signer+=(--password-file "$DRILL_PASSWORD_FILE")
  fi
  echo "== $1 as $role (${!sender})"
  AVANA_NETWORK="$out_network" forge script script/drills/gas-vault/GasVaultDrill.s.sol --sig "$fn" --rpc-url "$rpc" \
    "${signer[@]}" ${broadcast:+--broadcast --slow} --non-interactive
}

if [ "$action" = all ]; then
  for a in deploy fund add-signer top-up drain top-up drain check-cap pause unpause remove-signer withdraw; do
    run "$a"
  done
else
  run "$action"
fi
