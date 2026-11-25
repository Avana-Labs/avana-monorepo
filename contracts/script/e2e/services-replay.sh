#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Indexer replay of a local rehearsal into a local Convex deployment.
#
#   start <manifest.json>    Starts the indexer (PGlite, schema `live`) on the manifest right after the manifest step
#                            and leaves it running while the scenarios run, so it reads every block while
#                            the node still serves its state. Ponder keeps every log, block and pinned read it fetched
#                            in its sync store (schema `ponder_sync`), but not a read that reverts or returns no data:
#                            the indexer reads the node through rpc-recorder.ts, which keeps those for the replay.
#   finish <manifest.json>   After the last rehearsal step: mines two hourly sampler blocks a day apart (so a daily
#                            position bucket and an hourly market-debt bucket close) and 70 blocks past anvil's
#                            finality, lets the live indexer reach the head and stops it. Then the replay: a second
#                            indexer in a fresh schema (`replay`) indexes every block from the manifest's start blocks
#                            again, served from the sync store, and must reach the head with no error line. Its tables
#                            must hold the same rows as the live pass (replay-check.ts --indexer). Then a fresh local
#                            Convex deployment of services/convex imports the replay's export and series, samples the
#                            chain, tracks one intent per rehearsal transaction kind, and replay-check.ts compares
#                            Convex with the chain: markets, accounts and positions, market debt, liquidations,
#                            payouts and intents.
#   stop                     Stops a live indexer an aborted run left behind.
#
# Exit 0: pass; 3: not run (a dependency is missing); anything else: failure.
# Environment: RPC_ANVIL (default http://127.0.0.1:8545). E2E_REPLAY_PORT (default 42070),
# E2E_REPLAY_KEEP=1 keeps the local Convex deployment running after `finish` (stop it with Ctrl-C on its process).

set -uo pipefail
CMD="${1:-}"
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
CONTRACTS="$REPO/contracts"
RPC="${RPC_ANVIL:-http://127.0.0.1:8545}"
PORT="${E2E_REPLAY_PORT:-42070}"
# The indexer reads the node through rpc-recorder.ts, which keeps each pinned read's answer for the replay.
RECORDER_PORT="${E2E_REPLAY_RPC_PORT:-8549}"
INDEXER_RPC="http://127.0.0.1:${RECORDER_PORT}"
INDEXER_DIR="$REPO/services/indexer"
CONVEX_DIR="$REPO/services/convex"
PGLITE="$INDEXER_DIR/.ponder/pglite"
STATE="$CONTRACTS/deployments-local/anvil/replay"
EXPORT_KEY_ID=replay
E2E="$(cd "$(dirname "$0")" && pwd)"

for t in node openssl curl cast; do command -v "$t" >/dev/null || { echo "not run: $t missing"; exit 3; }; done
[ -x "$REPO/node_modules/.bin/ponder" ] && [ -x "$REPO/node_modules/.bin/convex" ] || { echo "not run: npm ci at the repo root first"; exit 3; }

status_block() { # The block the indexer's checkpoint has reached, 0 when it does not answer.
  curl -sf "http://127.0.0.1:${PORT}/status" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(Object.values(JSON.parse(s))[0].block.number)}catch{console.log(0)}})'
}

start_indexer() { # schema log
  # The subshell's PID is the handle: stop_indexer stops its children (ponder) and then it.
  (cd "$INDEXER_DIR" && AVANA_MANIFEST="$MANIFEST" CHAIN_ID_MAINNET=31337 RPC_MAINNET="$INDEXER_RPC" RPC_MAINNET_FALLBACK="$INDEXER_RPC" RPC_MAINNET_WS="${RPC/http/ws}" \
    INDEXER_NETWORK_SET=production INDEXER_DATABASE=pglite DATABASE_SCHEMA="$1" PONDER_TELEMETRY_DISABLED=true \
    INDEXER_EXPORT_KEYS="$EXPORT_KEY_ID:$(cat "$STATE/export-secret")" \
    exec "$REPO/node_modules/.bin/ponder" start --port "$PORT" --log-format json > "$2" 2>&1) &
  echo $! > "$STATE/indexer.pid"
}

stop_indexer() {
  [ -f "$STATE/indexer.pid" ] || return 0
  local p
  p="$(cat "$STATE/indexer.pid")"
  pkill -P "$p" 2>/dev/null
  kill "$p" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.2; done
  rm -f "$STATE/indexer.pid"
  # PGlite takes one process at a time; ponder may outlive the subshell for a moment.
  for _ in $(seq 1 25); do pgrep -f "ponder.*start --port $PORT" >/dev/null 2>&1 || break; sleep 0.2; done
}

start_recorder() {
  curl -sf "$INDEXER_RPC" >/dev/null && return 0
  (exec node "$E2E/rpc-recorder.ts" "$RECORDER_PORT" "$RPC" "$STATE/rpc-record.jsonl" >> "$STATE/rpc-recorder.log" 2>&1) &
  echo $! > "$STATE/recorder.pid"
  for _ in $(seq 1 50); do curl -sf "$INDEXER_RPC" >/dev/null && return 0; sleep 0.2; done
  echo "rpc-recorder: not answering on port $RECORDER_PORT"; tail -5 "$STATE/rpc-recorder.log"
  return 1
}

stop_recorder() {
  [ -f "$STATE/recorder.pid" ] || return 0
  local p
  p="$(cat "$STATE/recorder.pid")"
  pkill -P "$p" 2>/dev/null
  kill "$p" 2>/dev/null
  rm -f "$STATE/recorder.pid"
}

wait_ready() { # log seconds
  for _ in $(seq 1 $(($2 / 2))); do
    curl -sf "http://127.0.0.1:${PORT}/ready" >/dev/null && return 0
    sleep 2
  done
  echo "indexer: not ready after $2 s"; tail -30 "$1"
  return 1
}

# Ponder indexes a block after the head only when a newer block arrives, which an idle anvil node never mines: mine
# empty blocks until its checkpoint reaches the head this call started from.
wait_head() { # label
  local head at=0
  head="$(cast block-number --rpc-url "$RPC")"
  for _ in $(seq 1 150); do
    at="$(status_block)"
    [ "$at" -ge "$head" ] && break
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null
    sleep 2
  done
  echo "indexer ($1): indexed through block $at of head $head"
  [ "$at" -ge "$head" ]
}

# Ponder's warning, error and fatal lines (a reorg past finality, a failed read, a handler error), as JSON lines. Two
# kinds of warning are the node's and not the indexer's, and are only counted: Ponder calls any plain-HTTP RPC URL a
# public one, the local node included; and a busy anvil answers some requests after Ponder's timeout, which Ponder
# retries (each such request is then answered, or the indexer stops with an error line).
classify() { # log mode: mode "errors" prints the lines that count as errors, "tolerated" the number of the others
  node -e '
    const [file, mode] = process.argv.slice(1);
    const node = new Set(["All JSON-RPC providers are inactive", "All JSON-RPC providers are inactive due to rate limiting",
      "No new block received within expected time", "JSON-RPC request unexpectedly surpassed timeout"]);
    let tolerated = 0;
    for (const line of require("fs").readFileSync(file, "utf8").split(String.fromCharCode(10))) {
      if (!/"level":(40|50|60)[,}]/.test(line)) continue;
      let j; try { j = JSON.parse(line) } catch { if (mode === "errors") console.log(line); continue }
      const timeout = j.msg === "Received JSON-RPC error" && /took too long to respond/.test(j.error?.message ?? "");
      if (j.level === 40 && (j.msg.startsWith("Detected public RPC URL") || node.has(j.msg) || timeout)) tolerated++;
      else if (mode === "errors") console.log(line);
    }
    if (mode === "tolerated") console.log(tolerated);
  ' "$1" "$2" || echo "the log check failed on $1"
}
error_lines() {
  classify "$1" errors
}
errors_in() {
  error_lines "$1" | wc -l | tr -d ' '
}

case "$CMD" in
  start)
    MANIFEST="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    stop_indexer
    stop_recorder
    rm -rf "$STATE" "$PGLITE"
    mkdir -p "$STATE" && chmod 700 "$STATE"
    start_recorder || exit 1
    # The export's HMAC secret for this run only (not a signing key): a random value in a file only the user reads.
    (umask 077 && openssl rand -base64 32 | tr -d '\r\n' > "$STATE/export-secret")
    cast block-number --rpc-url "$RPC" > "$STATE/start-head"
    start_indexer live "$STATE/indexer-live.log"
    wait_ready "$STATE/indexer-live.log" 300 && wait_head live || { stop_indexer; stop_recorder; exit 1; }
    echo "indexer (live): running on port $PORT, $(errors_in "$STATE/indexer-live.log") error or warning lines, $(classify "$STATE/indexer-live.log" tolerated) node timeouts or notices"
    ;;

  finish)
    MANIFEST="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    [ -f "$STATE/indexer.pid" ] || { echo "no live indexer: run 'start' after the manifest step"; exit 1; }
    curl -sf "http://127.0.0.1:${PORT}/ready" >/dev/null || { echo "indexer (live): not answering"; tail -30 "$STATE/indexer-live.log"; stop_indexer; exit 1; }
    start_recorder || { stop_indexer; exit 1; }
    # Two sampler blocks a day apart: the first sample's daily (positions) and hourly (market debt) buckets close
    # when the second lands. The sampler runs every SAMPLE_EVERY blocks from its start block (ponder.config.ts).
    START="$(node -e 'const m=require(process.argv[1]);const l=Math.min(...m.aave.lendSpokes.map(s=>s.startBlock));process.stdout.write(String(Math.max(m.avana.accessManager.startBlock,l)))' "$MANIFEST")"
    SAMPLE_EVERY=300 # 3,600 s / anvil's 12 s block time (services/common/src/chains.ts)
    to_sample() {
      local head next
      head="$(cast block-number --rpc-url "$RPC")"
      next=$(( START + ((head - START) / SAMPLE_EVERY + 1) * SAMPLE_EVERY ))
      cast rpc anvil_mine $((next - head)) --rpc-url "$RPC" >/dev/null && echo "$next"
    }
    # A day on the clock; no feed needs a new round after it (Aave V4's AaveOracle has no age limit).
    advance_day() {
      cast rpc evm_increaseTime 90000 --rpc-url "$RPC" >/dev/null && cast rpc evm_mine --rpc-url "$RPC" >/dev/null
    }
    advance_day || { echo "evm_increaseTime or evm_mine refused"; stop_indexer; exit 1; }
    S1="$(to_sample)"
    advance_day || { echo "evm_increaseTime or evm_mine refused"; stop_indexer; exit 1; }
    S2="$(to_sample)"
    cast rpc anvil_mine 70 --rpc-url "$RPC" >/dev/null
    echo "$S1" > "$STATE/sample-block"
    echo "samples at blocks $S1 and $S2; head $(cast block-number --rpc-url "$RPC")"
    ok=1
    wait_head live || ok=0
    LIVE_ERRORS="$(errors_in "$STATE/indexer-live.log")"
    echo "indexer (live): $LIVE_ERRORS error or warning lines, $(classify "$STATE/indexer-live.log" tolerated) node timeouts or notices"
    stop_indexer
    [ $ok -eq 1 ] || { tail -30 "$STATE/indexer-live.log"; exit 1; }

    # The replay: every block again from the start blocks, in a schema the live pass never wrote.
    start_indexer replay "$STATE/indexer-replay.log"
    wait_ready "$STATE/indexer-replay.log" 900 && wait_head replay || ok=0
    REPLAY_ERRORS="$(errors_in "$STATE/indexer-replay.log")"
    echo "indexer (replay): $REPLAY_ERRORS error or warning lines, $(classify "$STATE/indexer-replay.log" tolerated) node timeouts or notices"
    [ "$REPLAY_ERRORS" -eq 0 ] || { error_lines "$STATE/indexer-replay.log" | head -10 | cut -c1-600; ok=0; }

    if [ $ok -eq 1 ]; then
      # Convex: a fresh anonymous local deployment (no account), started like services-smoke.sh does.
      CONVEX_MADE=""
      for f in .gitignore convex/tsconfig.json; do [ -e "$CONVEX_DIR/$f" ] || CONVEX_MADE="$CONVEX_MADE $CONVEX_DIR/$f"; done
      rm -rf "$CONVEX_DIR/.convex" "$CONVEX_DIR/.env.local"
      (cd "$CONVEX_DIR" && CONVEX_AGENT_MODE=anonymous exec "$REPO/node_modules/.bin/convex" dev --codegen disable --typecheck disable \
        --tail-logs always > "$STATE/convex.log" 2>&1) &
      CONVEX_PID=$!
      convex_wait() { for _ in $(seq 1 90); do grep -qE "Convex functions ready|$1" "$STATE/convex.log" 2>/dev/null && break; sleep 2; done; }
      convex_wait "SIWE_JWT_ISSUER is used in auth config"
      if ! grep -q "Convex functions ready" "$STATE/convex.log" && grep -q "SIWE_JWT_ISSUER is used in auth config" "$STATE/convex.log"; then
        (cd "$CONVEX_DIR" && CONVEX_AGENT_MODE=anonymous "$REPO/node_modules/.bin/convex" env set SIWE_JWT_ISSUER http://127.0.0.1:3000) \
          >> "$STATE/convex.log" 2>&1 && touch "$CONVEX_DIR/convex/auth.config.ts"
        convex_wait "Convex functions ready"
      fi
      if grep -q "Convex functions ready" "$STATE/convex.log"; then
        RPC_ANVIL="$RPC" CHAIN_ID_MAINNET=31337 E2E_EXPORT_URL="http://127.0.0.1:${PORT}" E2E_EXPORT_KEY_ID="$EXPORT_KEY_ID" \
          E2E_EXPORT_SECRET="$(cat "$STATE/export-secret")" E2E_SAMPLE_BLOCK="$S1" \
          node "$E2E/replay-check.ts" "$MANIFEST" "$REPO" 2>&1 | tee "$STATE/replay-check.log"
        [ "${PIPESTATUS[0]}" -eq 0 ] || ok=0
      else
        echo "convex: local deployment did not start"; tail -30 "$STATE/convex.log"; ok=0
      fi
      if [ "${E2E_REPLAY_KEEP:-}" = 1 ]; then
        echo "convex: kept running (pid $CONVEX_PID, dashboard in $STATE/convex.log)"
      else
        pkill -P "$CONVEX_PID" 2>/dev/null; kill "$CONVEX_PID" 2>/dev/null
        pkill -f "convex-local-backend.*$CONVEX_DIR" 2>/dev/null
        wait "$CONVEX_PID" 2>/dev/null
        rm -rf "$CONVEX_DIR/.convex" "$CONVEX_DIR/.env.local" $CONVEX_MADE
      fi
    fi
    stop_indexer
    echo "rpc-recorder: $(curl -sf "$INDEXER_RPC")"
    stop_recorder
    # The live pass and the replay must hold the same rows (read once both have stopped: PGlite takes one process).
    if [ $ok -eq 1 ]; then
      node "$E2E/replay-check.ts" --indexer "$REPO" "$PGLITE" live replay 2>&1 | tee -a "$STATE/replay-check.log"
      [ "${PIPESTATUS[0]}" -eq 0 ] || ok=0
    fi
    [ $ok -eq 1 ]
    ;;

  stop)
    stop_indexer
    stop_recorder
    ;;

  *)
    echo "usage: services-replay.sh start|finish <manifest.json> | stop"; exit 2
    ;;
esac
