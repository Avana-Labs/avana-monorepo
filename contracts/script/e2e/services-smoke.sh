#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Starts the indexer and the bot runner (services/keeper, halted) on a local rehearsal chain with the given release
# manifest and checks that each one loaded it: the indexer reaches `/ready`, indexes from the manifest's start blocks to
# the chain head (PGlite store, INDEXER_DATABASE=pglite) and, once stopped, holds every Spoke and loss layer on its Hub,
# every market, debt reserve and keeper of the manifest (indexer-check.ts); the bot runner loads the manifest, starts one
# LiquidationBot per integration, reads the indexer's bot stream and serves `keeper_halted 1` on its metrics port. Then a
# local Convex deployment of services/convex (anonymous, no account) takes the manifest (deployments:setFromManifest),
# imports the indexer's export and samples the chain, and every market and debt reserve of the manifest must have its
# page with the numbers read on chain (convex-check.ts).
# The bot runner signs as the run's keeper: the encrypted keystore e2e-local.sh generates (E2E_DRILL_KEYSTORE and
# E2E_DRILL_KEYSTORE_PASSWORD_FILE); without it the bot runner step fails.
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

# The services run on the production set with the node standing in for Ethereum (CHAIN_ID_MAINNET).
export AVANA_MANIFEST="$MANIFEST" CHAIN_ID_MAINNET=31337 RPC_MAINNET="$RPC" RPC_MAINNET_FALLBACK="$RPC" RPC_MAINNET_WS="${RPC/http/ws}"

# Indexer: PGlite store in services/indexer/.ponder/pglite (ponder.config.ts), emptied first so no earlier run's rows
# can pass the check.
PGLITE="$REPO/services/indexer/.ponder/pglite"
rm -rf "$PGLITE"
(cd "$REPO/services/indexer" && INDEXER_NETWORK_SET=production INDEXER_DATABASE=pglite DATABASE_SCHEMA=e2e PONDER_TELEMETRY_DISABLED=true \
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
  # `/ready` means the finalized range is indexed; the blocks after it (the governance operations executed, the Aave payload) are
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

# Bot runner: halted (no halt file, so it fails closed: it discovers and reports and sends nothing), the indexer's bot
# stream with the export key from a file, a throwaway mutual-TLS kill switch.
# MSYS2_ARG_CONV_EXCL: Git Bash on Windows would rewrite the subject "/CN=localhost" as a Windows path and openssl would
# reject it; the variable is ignored elsewhere.
MSYS2_ARG_CONV_EXCL="/CN=" openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" -keyout "$WORK/key.pem"   -out "$WORK/cert.pem" > "$WORK/openssl.log" 2>&1 || { echo "keeper: openssl could not make the kill switch certificate"; tail -5 "$WORK/openssl.log"; }
(umask 077 && printf '%s:%s' "$EXPORT_KEY_ID" "$EXPORT_SECRET" > "$WORK/indexer-key")
up=0
if [ -z "${E2E_DRILL_KEYSTORE:-}" ] || [ -z "${E2E_DRILL_KEYSTORE_PASSWORD_FILE:-}" ]; then
  echo "keeper: no keeper keystore (E2E_DRILL_KEYSTORE, made by e2e-local.sh)"
else
  (cd "$REPO/services/keeper" && LIQUIDATION_BOT_RPC_URL="$RPC" LIQUIDATION_BOT_CHAIN_ID=31337 \
    LIQUIDATION_BOT_KEYSTORE="$E2E_DRILL_KEYSTORE" LIQUIDATION_BOT_PASSWORD_FILE="$E2E_DRILL_KEYSTORE_PASSWORD_FILE" \
    KEEPER_KILL_SWITCH_PORT="$KILL_PORT" KEEPER_KILL_SWITCH_TLS_CERT="$WORK/cert.pem" \
    KEEPER_KILL_SWITCH_TLS_KEY="$WORK/key.pem" KEEPER_KILL_SWITCH_CLIENT_CA="$WORK/cert.pem" \
    KEEPER_HALT_STATE_PATH="$WORK/halt" KEEPER_METRICS_PORT="$METRICS_PORT" KEEPER_INDEXER_URL="http://127.0.0.1:${INDEXER_PORT}" \
    KEEPER_INDEXER_KEY_FILE="$WORK/indexer-key" \
    "$REPO/node_modules/.bin/tsx" src/main.ts > "$WORK/keeper.log" 2>&1) &
  PIDS="$PIDS $!"
  for _ in $(seq 1 45); do
    if curl -sf "http://127.0.0.1:${METRICS_PORT}/metrics" > "$WORK/metrics.txt" 2>/dev/null; then up=1; break; fi
    sleep 2
  done
  sleep 10
  curl -sf "http://127.0.0.1:${METRICS_PORT}/metrics" > "$WORK/metrics.txt" 2>/dev/null
  if [ $up -eq 1 ] && ! grep -q '"message":"fatal"' "$WORK/keeper.log" && grep -q '^keeper_halted 1' "$WORK/metrics.txt"; then
    echo "keeper: $(tr '\n' ' ' < "$WORK/metrics.txt")"
  else
    up=0
    echo "keeper: did not stay up halted"; tail -30 "$WORK/keeper.log"
  fi
  # The bot runner read the indexer's bot stream: a pass that fell back to RPC discovery fails the step.
  if grep -q 'bot stream failed' "$WORK/keeper.log"; then
    echo "keeper: indexer stream: $(grep -m2 'bot stream failed' "$WORK/keeper.log" | cut -c1-300 | tr '\n' ' ')"
    up=0
  else
    echo "keeper: indexer stream read"
  fi
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
  rm -rf "$CONVEX_DIR/.convex" "$CONVEX_DIR/.env.local"
  (cd "$CONVEX_DIR" && CONVEX_AGENT_MODE=anonymous "$REPO/node_modules/.bin/convex" dev --codegen disable --typecheck disable \
    --tail-logs always > "$WORK/convex.log" 2>&1) &
  PIDS="$PIDS $!"
  convex_wait() { for _ in $(seq 1 90); do grep -qE "Convex functions ready|$1" "$WORK/convex.log" 2>/dev/null && break; sleep 2; done; }
  convex_wait "SIWE_JWT_ISSUER is used in auth config"
  # The auth config names the SIWE JWT issuer, a deployment variable the CLI requires before it pushes. A fresh local
  # deployment has none: set the web app's local origin and touch the file so `convex dev` pushes again.
  if ! grep -q "Convex functions ready" "$WORK/convex.log" && grep -q "SIWE_JWT_ISSUER is used in auth config" "$WORK/convex.log"; then
    (cd "$CONVEX_DIR" && CONVEX_AGENT_MODE=anonymous "$REPO/node_modules/.bin/convex" env set SIWE_JWT_ISSUER http://127.0.0.1:3000) \
      >> "$WORK/convex.log" 2>&1 && touch "$CONVEX_DIR/convex/auth.config.ts"
    convex_wait "Convex functions ready"
  fi
  if grep -q "Convex functions ready" "$WORK/convex.log"; then
    RPC_ANVIL="$RPC" CHAIN_ID_MAINNET=31337 E2E_EXPORT_URL="http://127.0.0.1:${INDEXER_PORT}" E2E_EXPORT_KEY_ID="$EXPORT_KEY_ID" \
      E2E_EXPORT_SECRET="$EXPORT_SECRET" \
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
[ $ready -eq 1 ] && [ $indexed -eq 1 ] && [ $up -eq 1 ] && [ $pages -eq 1 ] && ! grep -q '"message":"fatal"' "$WORK/keeper.log"
