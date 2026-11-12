#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Starts the indexer and the keeper (observe mode) on a local rehearsal chain with the given release manifest and checks
# that each one loaded it: the indexer reaches `/ready`, indexes from the manifest's start blocks to the chain head
# (PGlite store, INDEXER_NETWORK_SET=local) and, once stopped, holds every Hub and every Lend, CDP and Coverage Spoke of
# the manifest (indexer-check.ts); the keeper loads the manifest, reads its operator helper on chain, backfills the
# AaveAdapter's proxies and serves `keeper_mode{chain="anvil",mode="observe"}` on its metrics port.
# Exit 0: both ran; 3: not run (a dependency is missing); anything else: failure.
# Usage: script/e2e/services-smoke.sh <manifest.json>   (RPC_ANVIL set by the caller, default http://127.0.0.1:8545)

set -uo pipefail
MANIFEST="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
# E2E_SERVICES_ROOT runs the services of another checkout (with its own npm install) against this world.
REPO="${E2E_SERVICES_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
RPC="${RPC_ANVIL:-http://127.0.0.1:8545}"
WORK="$(mktemp -d)"
INDEXER_PORT="${E2E_INDEXER_PORT:-42069}"
METRICS_PORT="${E2E_METRICS_PORT:-9464}"
KILL_PORT="${E2E_KILL_PORT:-9465}"
PIDS=""
# Each service runs in a subshell; stop the subshells' children (ponder, tsx) as well as the subshells.
trap 'for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT

for t in node openssl curl; do command -v "$t" >/dev/null || { echo "not run: $t missing"; exit 3; }; done
[ -x "$REPO/node_modules/.bin/ponder" ] && [ -x "$REPO/node_modules/.bin/tsx" ] || { echo "not run: npm ci at the repo root first"; exit 3; }

export AVANA_MANIFEST="$MANIFEST" RPC_ANVIL="$RPC" RPC_ANVIL_FALLBACK="$RPC" RPC_ANVIL_WS="${RPC/http/ws}"

# Indexer: PGlite store in services/indexer/.ponder/pglite (ponder.config.ts), emptied first so no earlier run's rows
# can pass the check.
PGLITE="$REPO/services/indexer/.ponder/pglite"
rm -rf "$PGLITE"
(cd "$REPO/services/indexer" && INDEXER_NETWORK_SET=local DATABASE_SCHEMA=e2e PONDER_TELEMETRY_DISABLED=true \
  INDEXER_EXPORT_KEYS="e2e:$(openssl rand -base64 32)" \
  "$REPO/node_modules/.bin/ponder" start --port "$INDEXER_PORT" > "$WORK/indexer.log" 2>&1) &
PIDS="$PIDS $!"
ready=0
for _ in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:${INDEXER_PORT}/ready" >/dev/null; then ready=1; break; fi
  sleep 2
done
if [ $ready -eq 1 ]; then
  echo "indexer: ready on the manifest ($(grep -ciE 'error' "$WORK/indexer.log") error lines)"
  # `/ready` means the finalized range is indexed; the blocks after it (the timelock execution, the Aave payload) are
  # indexed live, and Ponder takes them up only when a new block arrives, which an idle anvil node never mines. Mine
  # empty blocks until Ponder's checkpoint reaches the head the deployment ended at.
  head="$(cast block-number --rpc-url "$RPC")"
  at=0
  for _ in $(seq 1 90); do
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null
    at="$(curl -sf "http://127.0.0.1:${INDEXER_PORT}/status" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(Object.values(JSON.parse(s))[0].block.number)}catch{console.log(0)}})')"
    [ "$at" -ge "$head" ] && break
    sleep 2
  done
  echo "indexer: indexed through block $at of head $head"
  [ "$at" -ge "$head" ] || ready=0
else
  echo "indexer: not ready after 180 s"; tail -30 "$WORK/indexer.log"
fi

# Keeper: observe mode (no KMS key), a throwaway mutual-TLS kill switch.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
(cd "$REPO/services/keeper" && KEEPER_NETWORK_SET=local KEEPER_MODE=observe KEEPER_ROLE=primary KEEPER_SHARD=0 \
  KEEPER_SHARD_COUNT=1 KEEPER_KILL_SWITCH_PORT="$KILL_PORT" KEEPER_KILL_SWITCH_TLS_CERT="$WORK/cert.pem" \
  KEEPER_KILL_SWITCH_TLS_KEY="$WORK/key.pem" KEEPER_KILL_SWITCH_CLIENT_CA="$WORK/cert.pem" \
  KEEPER_HALT_STATE_PATH="$WORK/halt" KEEPER_METRICS_PORT="$METRICS_PORT" KEEPER_INDEXER_URL="http://127.0.0.1:${INDEXER_PORT}" \
  "$REPO/node_modules/.bin/tsx" src/main.ts > "$WORK/keeper.log" 2>&1) &
PIDS="$PIDS $!"
up=0
for _ in $(seq 1 45); do
  if curl -sf "http://127.0.0.1:${METRICS_PORT}/metrics" > "$WORK/metrics.txt" 2>/dev/null; then up=1; break; fi
  sleep 2
done
sleep 10
if [ $up -eq 1 ] && ! grep -q '"keeper.fatal"' "$WORK/keeper.log"; then
  echo "keeper: $(tr '\n' ' ' < "$WORK/metrics.txt")"
else
  echo "keeper: did not stay up"; tail -30 "$WORK/keeper.log"
fi
echo "--- indexer log (tail)"; tail -15 "$WORK/indexer.log"
echo "--- keeper log (tail)"; tail -15 "$WORK/keeper.log"
# PGlite takes one process at a time: stop the services, then read the indexer's store.
for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
for p in $PIDS; do wait "$p" 2>/dev/null; done
PIDS=""
indexed=0
if [ $ready -eq 1 ]; then
  node "$(dirname "$0")/indexer-check.ts" "$MANIFEST" "$REPO" "$PGLITE" && indexed=1
fi
[ $ready -eq 1 ] && [ $indexed -eq 1 ] && [ $up -eq 1 ] && ! grep -q '"keeper.fatal"' "$WORK/keeper.log"
