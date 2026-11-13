#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Test of script/upgrade-operation.py (TEST-263): an upgrade operation is built only after a completed, successful
# slow-tier run of security-slow.yml on the implementation's commit. `gh` and `forge` are stand-ins on PATH that
# answer from fixture files and log their calls; nothing reaches the network.
#
#   1. No successful run on the commit: refused, forge never runs, nothing on stdout.
#   2. `gh` fails (no auth, no network): refused.
#   3. The API answers with a successful run of another commit only: refused.
#   4. A successful campaign run (slow-gate green, tool jobs skipped, campaign jobs green): refused.
#   5. A successful run whose slow-gate job is missing: refused.
#   6. A malformed proxy address or an unknown commit: refused before gh is asked.
#   7. A slow-tier run (slow-gate on the second page of jobs): passes; gh is asked for head_sha=<sha>&status=success,
#      and forge runs the Foundry script with the commit, the run id, the proxy and the implementation.
#
# Usage, from contracts/:  script/upgrade-operation.test.sh

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHA="$(git rev-parse HEAD)"
OTHER="0123456789abcdef0123456789abcdef01234567"
PROXY=0x1111111111111111111111111111111111111111
IMPL=0x2222222222222222222222222222222222222222

mkdir -p "$TMP/bin" "$TMP/fx"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/gh.calls"
[ -f "$FAKE/fx/fail" ] && { echo "gh: not authenticated" >&2; exit 4; }
case "$2" in
  *"/workflows/security-slow.yml/runs?"*) cat "$FAKE/fx/runs.json" ;;
  *"/actions/runs/"*"/jobs?"*)
    id="${2#*/actions/runs/}"; id="${id%%/*}"; page="${2##*page=}"
    f="$FAKE/fx/jobs-$id-$page.json"
    if [ -f "$f" ]; then cat "$f"; else echo '{"jobs": []}'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
cat >"$TMP/bin/forge" <<'SH'
#!/usr/bin/env bash
{ echo "args=$*"; env | grep '^AVANA_UPGRADE_' | sort; } >>"$FAKE/forge.calls"
echo "schedule calldata 0x01d5062a"
SH
chmod +x "$TMP/bin/gh" "$TMP/bin/forge"

runs() { # <head_sha> <run id> ...
  local sha="$1"; shift
  python3 - "$sha" "$@" >"$TMP/fx/runs.json" <<'PY'
import json, sys
sha, ids = sys.argv[1], sys.argv[2:]
print(json.dumps({"total_count": len(ids), "workflow_runs": [
    {"id": int(i), "run_number": n + 1, "head_sha": sha, "status": "completed", "conclusion": "success",
     "path": ".github/workflows/security-slow.yml", "html_url": f"https://github.com/runs/{i}"}
    for n, i in enumerate(ids)]}))
PY
}

jobs() { # <run id> <page> <name>=<conclusion> ...
  local id="$1" page="$2"; shift 2
  python3 - "$@" >"$TMP/fx/jobs-$id-$page.json" <<'PY'
import json, sys
print(json.dumps({"jobs": [{"name": a.rsplit("=", 1)[0], "conclusion": a.rsplit("=", 1)[1]} for a in sys.argv[1:]]}))
PY
}

reset() { rm -f "$TMP"/fx/* "$TMP/gh.calls" "$TMP/forge.calls"; }

fail=0
expect() { # <description> <pass|refuse> [args...]
  local desc="$1" want="$2" got=pass; shift 2
  FAKE="$TMP" PATH="$TMP/bin:$PATH" script/upgrade-operation.py --proxy-name RiskModule --proxy "$PROXY" \
    --implementation-name RiskModule --implementation "$IMPL" --commit "$SHA" "$@" >"$TMP/out" 2>"$TMP/err" || got=refuse
  if [ "$got" != "$want" ]; then
    echo "FAIL $desc (expected $want, got $got)"; sed 's/^/     /' "$TMP/err"; fail=1; return
  fi
  if [ "$want" = refuse ]; then
    if [ -s "$TMP/out" ] || [ -f "$TMP/forge.calls" ]; then
      echo "FAIL $desc (refused but printed or ran forge)"; fail=1; return
    fi
    grep -q REFUSED "$TMP/err" || { echo "FAIL $desc (no REFUSED message)"; fail=1; return; }
  fi
  echo "ok   $desc"
}

reset; runs "$SHA"
expect "no successful run on the commit is refused" refuse

reset; touch "$TMP/fx/fail"
expect "a gh failure is refused" refuse

reset; runs "$OTHER" 7
jobs 7 1 "slow-gate=success" "mythril group 1=success"
expect "a successful run of another commit is refused" refuse

reset; runs "$SHA" 8
jobs 8 1 "slow-gate=success" "echidna LockProperties=skipped" "campaign echidna LockProperties property 1/8=success"
expect "a successful campaign run is refused" refuse

reset; runs "$SHA" 9
jobs 9 1 "slow-tier build=success" "mythril group 1=success"
expect "a run without a green slow-gate is refused" refuse

reset; runs "$SHA" 10
jobs 10 1 "slow-gate=success" "mythril group 1=success"
expect "a malformed proxy address is refused" refuse --proxy 0x1234
grep -q . "$TMP/gh.calls" 2>/dev/null && { echo "FAIL gh was asked for a malformed address"; fail=1; }
reset; runs "$SHA" 10
expect "an unknown commit is refused" refuse --commit "$OTHER"

reset; runs "$SHA" 11 12
jobs 12 1 "slow-gate=failure"
filler=(); for k in $(seq 1 100); do filler+=("hevm target-$k=success"); done
jobs 11 1 "${filler[@]}"
jobs 11 2 "slow-gate=success" "campaign corpus LockProperties=skipped"
expect "a slow-tier run on the commit passes" pass
grep -q "actions/workflows/security-slow.yml/runs?head_sha=$SHA&status=success" "$TMP/gh.calls" \
  || { echo "FAIL gh was not asked for successful runs on the commit"; fail=1; }
for want in "args=script script/upgrade/UpgradeOperation.s.sol" "AVANA_UPGRADE_COMMIT=$SHA" \
  "AVANA_UPGRADE_SLOW_RUN=11" "AVANA_UPGRADE_PROXY=$PROXY" "AVANA_UPGRADE_IMPLEMENTATION=$IMPL" \
  "AVANA_UPGRADE_PROXY_NAME=RiskModule" "AVANA_UPGRADE_DELAY=432000"; do
  grep -qxF "$want" "$TMP/forge.calls" || { echo "FAIL forge call lacks $want"; fail=1; }
done
grep -q "0x01d5062a" "$TMP/out" || { echo "FAIL the pass path printed no calldata"; fail=1; }

exit "$fail"
