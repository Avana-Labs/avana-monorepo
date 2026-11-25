#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Regression test of the `reviewedFiles` check of script/security-gate.py, on an empty Slither report and fixture
# triage files whose entry records the hashes of two fixture files:
#
#   1. Both files as reviewed: the gate passes and reopens no review.
#   2. One file changed, or gone: the gate passes, prints "review reopened" for that file only, and a ::warning.
#   3. CRLF line endings of a reviewed file hash as LF: no review reopened.
#   4. A hash that is not a SHA-256: triage error, the gate fails.
#
# Usage, from contracts/:  script/security-gate.test.sh

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The gate resolves a reviewed path against contracts/; an absolute path stays as it is. pwd -W gives the Windows form
# of the path under Git Bash, where Python does not read /tmp paths.
DIR="$(cd "$TMP" && (pwd -W 2>/dev/null || pwd))"

echo '{"success": true, "error": null, "results": {"detectors": []}}' >"$TMP/slither.json"
printf 'contract A {}\n' >"$TMP/A.sol"
printf 'contract B {}\n' >"$TMP/B.sol"

triage() { # <out> <hash of A> <hash of B>: the repository's excluded detectors and one accepted entry
  python3 - "$@" "$DIR" <<'PY'
import json
import sys

out, a, b, d = sys.argv[1:5]
real = json.load(open("../.github/security/slither-triage.json", encoding="utf8"))
entry = {"fingerprint": "0123456789abcdef", "check": "assembly", "file": "src/A.sol", "reason": "fixture",
         "reviewedFiles": {f"{d}/A.sol": a, f"{d}/B.sol": b}}
json.dump({"excluded_detectors": real["excluded_detectors"], "accepted": [entry]}, open(out, "w"))
PY
}

A=$(sha256sum "$TMP/A.sol" | cut -c1-64)
B=$(sha256sum "$TMP/B.sol" | cut -c1-64)

fail=0
expect() { # <description> <expected exit> <triage> <grep -c "review reopened" count> [<pattern that must appear>]
  local got=0 n
  python3 script/security-gate.py slither "$TMP/slither.json" --triage "$3" --fail-on informational >"$TMP/log" 2>&1 ||
    got=$?
  n=$(grep -c '^  review reopened' "$TMP/log" || true)
  if [ "$got" = "$2" ] && [ "$n" = "$4" ] && { [ -z "${5:-}" ] || grep -qF -- "$5" "$TMP/log"; }; then
    echo "ok   $1"
  else
    echo "FAIL $1 (exit $got, expected $2; $n review(s) reopened, expected $4)"
    sed 's/^/     /' "$TMP/log"
    fail=1
  fi
}

triage "$TMP/t.json" "$A" "$B"
expect "files as reviewed: pass, no review reopened" 0 "$TMP/t.json" 0

printf 'contract B { uint256 x; }\n' >"$TMP/B.sol"
expect "changed file: pass, its review reopened" 0 "$TMP/t.json" 1 "B.sol changed since the review"
expect "changed file: ::warning annotation" 0 "$TMP/t.json" 1 "::warning title=slither triage review reopened::"

rm "$TMP/B.sol"
expect "missing file: pass, its review reopened" 0 "$TMP/t.json" 1 "the file no longer exists"

printf 'contract B {}\n' >"$TMP/B.sol"
printf 'contract A {}\r\n' >"$TMP/A.sol"
expect "CRLF checkout of a reviewed file: no review reopened" 0 "$TMP/t.json" 0

triage "$TMP/bad.json" "$A" "not-a-hash"
expect "malformed hash: triage error, fail" 1 "$TMP/bad.json" 0 "TRIAGE ERROR reviewedFiles hash of"

exit $fail
