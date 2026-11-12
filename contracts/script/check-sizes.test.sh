#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Regression test of script/check-sizes.sh on fixture artifacts: each contract is measured on the artifact of the
# profile it is deployed with, never on its smallest artifact.
#
#   1. A contract with no compilation restriction, 25,000 bytes in the default profile and 20,000 bytes in a
#      restricted profile that also compiles it, fails (the default-profile artifact is the deployed one).
#   2. The same artifacts pass when foundry.toml restricts the contract's file to the 200-run profile.
#   3. A restricted contract whose restricted artifact is missing fails (fail closed).
#   4. A default-profile contract within the margin passes.
#
# Usage, from contracts/:  script/check-sizes.test.sh

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

artifact() { # <file> <source> <name> <runs> <bytes>
  mkdir -p "$(dirname "$1")"
  python3 - "$@" <<'PY'
import json
import sys

path, src, name, runs, size = sys.argv[1:6]
meta = {"settings": {"compilationTarget": {src: name}, "optimizer": {"enabled": True, "runs": int(runs)}}}
with open(path, "w") as f:
    json.dump({"metadata": meta, "deployedBytecode": {"object": "0x" + "00" * int(size)}}, f)
PY
}

config() { # <file> <restrictions json>
  cat >"$1" <<JSON
{"optimizer_runs": 10000, "via_ir": false,
 "additional_compiler_profiles": [{"name": "lporacle", "optimizer": true, "via_ir": false, "optimizer_runs": 200}],
 "compilation_restrictions": $2}
JSON
}

echo '{"default": 1024, "contracts": {}}' >"$TMP/margins.json"
artifact "$TMP/out/Big.sol/Big.json" src/big/Big.sol Big 10000 25000
artifact "$TMP/out/Big.sol/Big.lporacle.json" src/big/Big.sol Big 200 20000
config "$TMP/unrestricted.json" '[]'
config "$TMP/restricted.json" '[{"paths": "src/big/Big*.sol", "via_ir": false, "optimizer_runs": 200}]'

run() { # <out dir> <config>
  CHECK_SIZES_OUT="$1" CHECK_SIZES_CONFIG="$2" CHECK_SIZES_MARGINS="$TMP/margins.json" \
    CHECK_SIZES_REPORT="$TMP/sizes.json" script/check-sizes.sh >"$TMP/log" 2>&1
}

fail=0
expect() { # <description> <expected status: pass|fail> <out dir> <config>
  local got=pass
  run "$3" "$4" || got=fail
  if [ "$got" = "$2" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1 (expected $2, got $got)"
    sed 's/^/     /' "$TMP/log"
    fail=1
  fi
}

expect "default-profile contract over the margin fails although a restricted artifact fits" fail \
  "$TMP/out" "$TMP/unrestricted.json"
grep -q '"Big": 25000' "$TMP/sizes.json" || { echo "FAIL report does not hold the default-profile size"; fail=1; }

expect "restricted contract is measured on its restricted artifact" pass "$TMP/out" "$TMP/restricted.json"
grep -q '"Big": 20000' "$TMP/sizes.json" || { echo "FAIL report does not hold the restricted size"; fail=1; }

rm "$TMP/out/Big.sol/Big.lporacle.json"
expect "restricted contract without its restricted artifact fails" fail "$TMP/out" "$TMP/restricted.json"

artifact "$TMP/small/Small.sol/Small.json" src/small/Small.sol Small 10000 23552
expect "default-profile contract at the limit passes" pass "$TMP/small" "$TMP/unrestricted.json"

exit "$fail"
