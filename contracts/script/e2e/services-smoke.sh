#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Starts the indexer and the keeper (observe mode) on a local rehearsal chain with the given release manifest and checks
# that each one loaded it: the indexer reaches `/ready`, indexes from the manifest's start blocks to the chain head
# (PGlite store, INDEXER_NETWORK_SET=local) and, once stopped, holds every Hub and every Lend, CDP and First-Loss Reserve of
# the manifest (indexer-check.ts); the keeper loads the manifest, reads its operator helper on chain, backfills the
# AaveAdapter's proxies and serves `keeper_mode{chain="anvil",mode="observe"}` on its metrics port. Then a local Convex
# deployment of services/convex (anonymous, no account) imports the indexer's export and samples the chain, and every
# listed market and debt reserve must have its page with data and with the text of its listing metadata file
# (convex-check.ts), served from deployments-local/<network>/listing-content as the listing content URL.
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
CONTENT_PORT="${E2E_CONTENT_PORT:-8788}"
CONVEX_DIR="$REPO/services/convex"
EXPORT_KEY_ID=e2e
EXPORT_SECRET="$(openssl rand -base64 32)"
PIDS=""
# Files the Convex CLI writes on its first local run; removed afterwards unless they were there before.
CONVEX_MADE=""
for f in .gitignore convex/tsconfig.json; do [ -e "$CONVEX_DIR/$f" ] || CONVEX_MADE="$CONVEX_MADE $CONVEX_DIR/$f"; done
stop_all() {
  # Each service runs in a subshell; stop the subshells' children (ponder, tsx, convex) as well as the subshells.
  for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  pkill -f "convex-local-backend.*$CONVEX_DIR" 2>/dev/null
  for p in $PIDS; do wait "$p" 2>/dev/null; done
  PIDS=""
}
trap 'stop_all; rm -rf "$WORK" "$CONVEX_DIR/.convex" "$CONVEX_DIR/.env.local" $CONVEX_MADE' EXIT

for t in node openssl curl; do command -v "$t" >/dev/null || { echo "not run: $t missing"; exit 3; }; done
[ -x "$REPO/node_modules/.bin/ponder" ] && [ -x "$REPO/node_modules/.bin/tsx" ] && [ -x "$REPO/node_modules/.bin/convex" ] || { echo "not run: npm ci at the repo root first"; exit 3; }

export AVANA_MANIFEST="$MANIFEST" RPC_ANVIL="$RPC" RPC_ANVIL_FALLBACK="$RPC" RPC_ANVIL_WS="${RPC/http/ws}"

# Indexer: PGlite store in services/indexer/.ponder/pglite (ponder.config.ts), emptied first so no earlier run's rows
# can pass the check.
PGLITE="$REPO/services/indexer/.ponder/pglite"
rm -rf "$PGLITE"
(cd "$REPO/services/indexer" && INDEXER_NETWORK_SET=local DATABASE_SCHEMA=e2e PONDER_TELEMETRY_DISABLED=true \
  INDEXER_EXPORT_KEYS="$EXPORT_KEY_ID:$EXPORT_SECRET" \
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
# MSYS2_ARG_CONV_EXCL: Git Bash on Windows would rewrite the subject "/CN=localhost" as a Windows path and openssl would
# reject it; the variable is ignored elsewhere.
MSYS2_ARG_CONV_EXCL="/CN=" openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" -keyout "$WORK/key.pem"   -out "$WORK/cert.pem" > "$WORK/openssl.log" 2>&1 || { echo "keeper: openssl could not make the kill switch certificate"; tail -5 "$WORK/openssl.log"; }
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

# Convex: the export serves only finalized blocks, and anvil finalizes 64 blocks behind its head. Mine past that and
# let the indexer follow, then run a fresh local deployment and check every listed page.
pages=0
if [ $ready -eq 1 ]; then
  cast rpc anvil_mine 70 --rpc-url "$RPC" >/dev/null
  head="$(cast block-number --rpc-url "$RPC")"
  for _ in $(seq 1 60); do
    at="$(curl -sf "http://127.0.0.1:${INDEXER_PORT}/status" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(Object.values(JSON.parse(s))[0].block.number)}catch{console.log(0)}})')"
    [ "$at" -ge "$head" ] && break
    sleep 2
  done
  CONTENT="$(dirname "$MANIFEST")/listing-content"
  (node -e 'const [dir,port]=process.argv.slice(1);const fs=require("fs"),p=require("path");require("http").createServer((q,r)=>{const f=p.join(dir,p.basename(q.url));fs.readFile(f,(e,b)=>{if(e){r.writeHead(404);r.end();}else{r.writeHead(200,{"content-type":"application/json"});r.end(b);}})}).listen(+port,"127.0.0.1")' "$CONTENT" "$CONTENT_PORT" > "$WORK/content.log" 2>&1) &
  PIDS="$PIDS $!"
  rm -rf "$CONVEX_DIR/.convex" "$CONVEX_DIR/.env.local"
  (cd "$CONVEX_DIR" && CONVEX_AGENT_MODE=anonymous "$REPO/node_modules/.bin/convex" dev --codegen disable --typecheck disable \
    --tail-logs always > "$WORK/convex.log" 2>&1) &
  PIDS="$PIDS $!"
  for _ in $(seq 1 90); do grep -q "Convex functions ready" "$WORK/convex.log" 2>/dev/null && break; sleep 2; done
  if grep -q "Convex functions ready" "$WORK/convex.log"; then
    RPC_ANVIL="$RPC" E2E_EXPORT_URL="http://127.0.0.1:${INDEXER_PORT}" E2E_EXPORT_KEY_ID="$EXPORT_KEY_ID" \
      E2E_EXPORT_SECRET="$EXPORT_SECRET" E2E_LISTING_CONTENT_URL="http://127.0.0.1:${CONTENT_PORT}" \
      node "$(dirname "$0")/convex-check.ts" "$MANIFEST" "$REPO" > "$WORK/convex-check.log" 2>&1 && pages=1
    cat "$WORK/convex-check.log"
  else
    echo "convex: local deployment did not start"
  fi
  [ $pages -eq 1 ] || { echo "--- convex log (tail)"; tail -30 "$WORK/convex.log"; }
fi

echo "--- indexer log (tail)"; tail -15 "$WORK/indexer.log"
echo "--- keeper log (tail)"; tail -15 "$WORK/keeper.log"
# PGlite takes one process at a time: stop the services, then read the indexer's store.
stop_all
indexed=0
if [ $ready -eq 1 ]; then
  node "$(dirname "$0")/indexer-check.ts" "$MANIFEST" "$REPO" "$PGLITE" && indexed=1
fi
[ $ready -eq 1 ] && [ $indexed -eq 1 ] && [ $up -eq 1 ] && [ $pages -eq 1 ] && ! grep -q '"keeper.fatal"' "$WORK/keeper.log"
