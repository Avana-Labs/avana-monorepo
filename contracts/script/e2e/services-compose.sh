#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# Runs the services' container images (services/compose.yaml with services/compose.anvil.yaml) against a local anvil
# rehearsal and checks that each one works from its image: the indexer replays the deployment from the manifest's start
# blocks and reaches the chain head (`/ready`, its progress at the head); the keeper loads the manifest in observe mode,
# serves `keeper_mode{chain="anvil",mode="observe"}` on its metrics port and reads the indexer's keeper stream; the
# monitor answers `/healthz` with a successful round on the chain and receives the keeper's heartbeats. Every secret
# (export key, monitor tokens, kill-switch certificate, database password) is generated for the run and removed after.
# Exit 0: all three ran; 3: not run (docker, the manifest or the node is missing); anything else: failure.
# Usage: script/e2e/services-compose.sh <manifest.json>   (RPC_ANVIL on the host, default http://127.0.0.1:8545)
#        script/e2e/services-compose.sh --build            builds the images only (no node needed), so e2e-local.sh
#                                                          finds a Docker problem before its deploy, not after it.
#        E2E_COMPOSE_KEEP=1 leaves the stack running.

set -uo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
COMPOSE=(docker compose -p avana-rehearsal -f "$REPO/services/compose.yaml" -f "$REPO/services/compose.anvil.yaml")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [ "${1:-}" = "--build" ]; then
  command -v docker >/dev/null || { echo "not run: docker missing"; exit 3; }
  docker info >/dev/null 2>&1 || { echo "not run: the docker daemon is not running (start Docker Desktop)"; exit 3; }
  # The build reads no environment file, but compose.yaml and compose.anvil.yaml need these set to load.
  touch "$WORK/indexer.env" "$WORK/keeper.env" "$WORK/monitor.env"
  export AVANA_COMPOSE_ENV="$WORK" KEEPER_TLS_DIR="$WORK" POSTGRES_PASSWORD=unused
  "${COMPOSE[@]}" build > "$WORK/build.log" 2>&1 || { echo "docker compose build failed"; tail -30 "$WORK/build.log"; exit 1; }
  echo "images built"
  exit 0
fi
[ -f "${1:-}" ] || { echo "not run: give the rehearsal manifest (contracts/deployments-local/<network>/manifest.json)"; exit 3; }
MANIFEST_DIR="$(cd "$(dirname "$1")" && pwd)"
NETWORK="$(basename "$MANIFEST_DIR")"
MANIFEST_FILE="$(basename "$1")"
[ "$MANIFEST_DIR" = "$REPO/contracts/deployments-local/$NETWORK" ] || { echo "not run: the manifest must be under contracts/deployments-local/<network>/"; exit 3; }
RPC="${RPC_ANVIL:-http://127.0.0.1:8545}"
# The containers reach the host's node through host.docker.internal.
RPC_IN="${RPC/127.0.0.1/host.docker.internal}"
RPC_IN="${RPC_IN/localhost/host.docker.internal}"
# The monitor refuses a fallback equal to its primary. A rehearsal has one node, so the fallback reaches the same node
# through a second host name (anvil-fallback, compose.anvil.yaml).
RPC_FB="${RPC_IN/host.docker.internal/anvil-fallback}"

for t in docker openssl curl node; do command -v "$t" >/dev/null || { echo "not run: $t missing"; exit 3; }; done
docker info >/dev/null 2>&1 || { echo "not run: the docker daemon is not running (start Docker Desktop)"; exit 3; }
curl -sf -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$RPC" >/dev/null \
  || { echo "not run: no node answers on $RPC"; exit 3; }

cleanup() {
  if [ -z "${E2E_COMPOSE_KEEP:-}" ]; then "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

secret() { openssl rand -hex 24; }
EXPORT_SECRET="$(openssl rand -base64 32)"
KEEPER_TOKEN="$(secret)"
mkdir -p "$WORK/tls"
# MSYS2_ARG_CONV_EXCL: Git Bash would rewrite "/CN=localhost" as a Windows path.
MSYS2_ARG_CONV_EXCL="/CN=" openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
  -keyout "$WORK/tls/server.key" -out "$WORK/tls/server.pem" >/dev/null 2>&1 || { echo "openssl could not make the kill-switch certificate"; exit 1; }
cp "$WORK/tls/server.pem" "$WORK/tls/client-ca.pem"
chmod 644 "$WORK/tls/"*

cat > "$WORK/indexer.env" <<EOF
INDEXER_NETWORK_SET=local
AVANA_MANIFEST=/local/$MANIFEST_FILE
RPC_ANVIL=$RPC_IN
RPC_ANVIL_FALLBACK=$RPC_FB
RPC_ANVIL_WS=${RPC_IN/http/ws}
DATABASE_SCHEMA=rehearsal
INDEXER_EXPORT_KEYS=keeper:$EXPORT_SECRET
PONDER_TELEMETRY_DISABLED=true
EOF
cat > "$WORK/keeper.env" <<EOF
KEEPER_NETWORK_SET=local
AVANA_MANIFEST=/local/$MANIFEST_FILE
RPC_ANVIL=$RPC_IN
RPC_ANVIL_FALLBACK=$RPC_FB
RPC_ANVIL_WS=${RPC_IN/http/ws}
KEEPER_MODE=observe
KEEPER_ROLE=primary
KEEPER_SHARD=0
KEEPER_SHARD_COUNT=1
KEEPER_INDEXER_KEY=keeper:$EXPORT_SECRET
KEEPER_MONITOR_URL=http://monitor:9470
KEEPER_MONITOR_INSTANCE_ANVIL=anvil-primary
KEEPER_MONITOR_TOKEN_ANVIL=$KEEPER_TOKEN
EOF
ROUTES=""
for r in ON_CALL GOVERNANCE_SAFE_SIGNERS EMERGENCY_GUARDIAN_SIGNERS AAVE_PROTOCOL_GUARDIAN OPERATORS EMERGENCY_GUARDIAN GUARDIANS \
  RISK_PROVIDERS GOVERNANCE STANDBY_KEEPER KEEPER_ON_CALL AVANA_LABS AAVE_DAO AAVE COVERAGE_ROLE ENGINEERING CANCELLERS SIGNERS; do
  ROUTES="${ROUTES}MONITOR_ROUTE_$r=log
"
done
cat > "$WORK/monitor.env" <<EOF
MONITOR_NETWORK_SET=local
AVANA_MANIFEST=/local/$MANIFEST_FILE
RPC_ANVIL=$RPC_IN
RPC_ANVIL_FALLBACK=$RPC_FB
MONITOR_INTERVAL_SECONDS=12
MONITOR_CHANNELS=log:log
${ROUTES}MONITOR_STATUS_TOKEN=$(secret)
MONITOR_KEEPER_INSTANCES=anvil-primary:anvil
MONITOR_KEEPER_TOKEN_ANVIL_PRIMARY=$KEEPER_TOKEN
EOF

export AVANA_COMPOSE_ENV="$WORK" AVANA_NETWORK="$NETWORK" KEEPER_TLS_DIR="$WORK/tls" POSTGRES_PASSWORD="$(secret)"
echo "building the images and starting the stack"
"${COMPOSE[@]}" up -d --build > "$WORK/up.log" 2>&1 || { echo "docker compose up failed"; tail -30 "$WORK/up.log"; exit 1; }

status=0
rpc() { curl -sf -X POST -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":[]}" "$RPC"; }
head="$(rpc eth_blockNumber | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(Number(BigInt(JSON.parse(s).result))))')"
indexed() { curl -sf http://127.0.0.1:42069/status | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(Object.values(JSON.parse(s))[0].block.number)}catch{console.log(0)}})'; }

# Indexer: replays from the manifest's start blocks to the head the node had when the stack started. `/ready` means the
# finalized range is indexed; the blocks after it are indexed live, and Ponder takes them up only when a new block
# arrives, which an idle anvil node never mines, so empty blocks are mined until its checkpoint reaches that head.
ready=0
for _ in $(seq 1 180); do
  if curl -sf http://127.0.0.1:42069/ready >/dev/null; then ready=1; break; fi
  sleep 5
done
at=0
if [ $ready -eq 1 ]; then
  for _ in $(seq 1 90); do
    rpc evm_mine >/dev/null
    at="$(indexed)"
    [ "${at:-0}" -ge "$head" ] && break
    sleep 2
  done
fi
if [ $ready -eq 1 ] && [ "${at:-0}" -ge "$head" ]; then echo "indexer: replayed to block $at (head $head) PASS"
else echo "indexer: not ready or behind (ready=$ready, block ${at:-?}, head $head) FAIL"; status=1; fi

# Keeper: observe mode on its metrics port, and the indexer stream read without a discovery mismatch.
mode=""
for _ in $(seq 1 60); do
  mode="$(curl -sf http://127.0.0.1:9464/metrics | grep -o 'keeper_mode{chain="anvil",mode="observe"} 1' || true)"
  [ -n "$mode" ] && break
  sleep 5
done
klog="$("${COMPOSE[@]}" logs keeper 2>&1)"
if [ -n "$mode" ] && ! grep -q '"keeper.discoveryMismatch"' <<<"$klog"; then echo "keeper: observe mode, stream read PASS"
else echo "keeper: metrics='${mode:-none}', discovery mismatch logged: $(grep -c '"keeper.discoveryMismatch"' <<<"$klog") FAIL"; status=1; fi

# Monitor: a successful round on the chain (/healthz 200) and the keeper's heartbeats.
healthy=0
for _ in $(seq 1 60); do
  if curl -sf http://127.0.0.1:9470/healthz >/dev/null; then healthy=1; break; fi
  sleep 5
done
mlog="$("${COMPOSE[@]}" logs monitor 2>&1)"
if [ $healthy -eq 1 ]; then echo "monitor: healthy PASS"; else echo "monitor: /healthz not 200 FAIL"; status=1; fi

if [ $status -ne 0 ]; then
  for s in indexer keeper monitor; do echo "--- $s (last 40 lines)"; "${COMPOSE[@]}" logs --tail 40 "$s" 2>&1; done
fi
exit $status
