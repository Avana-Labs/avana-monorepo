#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Mythril on the runtime bytecode of every contract and library compiled from src/ (settings in
# security/mythril.conf). Interfaces have no code and are not analyzed. Writes out-security/mythril/<Name>.json per
# contract and out-security/mythril.json ({"<Name>": <report>}), then gates the combined report with
# security/mythril-triage.json at low and above.
#
# Usage, from contracts/:  script/security-mythril.sh <forge-out-dir with build-info>

set -uo pipefail

cd "$(dirname "$0")/.."
BUILD=${1:?usage: security-mythril.sh <forge-out-dir>}
OUT=out-security/mythril
MYTH=.venv-mythril/bin/myth
PY=.venv/bin/python
# shellcheck source=../security/mythril.conf
. security/mythril.conf

if [ ! -x "$MYTH" ]; then
  echo "missing Mythril: run script/install-security-tools.sh --python" >&2
  exit 1
fi

rm -rf "$OUT" && mkdir -p "$OUT"
# Name and runtime code of every src/ artifact with code, one "name<TAB>hexfile" line each.
targets=$("$PY" script/security-targets.py runtime-code "$BUILD" "$OUT") || exit 1

if [ -z "$targets" ]; then
  echo "mythril: skipped, no contract or library under src/ compiles to runtime code"
  exit 0
fi

status=0
while IFS=$'\t' read -r name hex; do
  echo "=== mythril $name"
  "$MYTH" analyze --bin-runtime -f "$hex" -o json -m "$MYTHRIL_MODULES" \
    -t "$MYTHRIL_TX_COUNT" --execution-timeout "$MYTHRIL_EXECUTION_TIMEOUT" \
    --solver-timeout "$MYTHRIL_SOLVER_TIMEOUT" --max-depth "$MYTHRIL_MAX_DEPTH" \
    >"$OUT/$name.json" 2>"$OUT/$name.log"
  # myth exits 1 when it reports issues; a missing or non-JSON report is a tool error.
  if ! "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT/$name.json" 2>/dev/null; then
    cat "$OUT/$name.log"
    echo "mythril: no report for $name" >&2
    status=1
  fi
done <<<"$targets"
[ $status -eq 0 ] || exit 1

"$PY" - "$OUT" <<'PYEOF'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
combined = {p.stem: json.loads(p.read_text()) for p in sorted(out.glob("*.json"))}
(out.parent / "mythril.json").write_text(json.dumps(combined, indent=1))
PYEOF
"$PY" script/security-gate.py mythril out-security/mythril.json --triage security/mythril-triage.json \
  --fail-on low --summary out-security/mythril-gate.txt
