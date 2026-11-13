#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Branch-coverage gate of src/: `forge coverage --report lcov` in the `coverage` profile (optimizer and via-IR off, so
# source maps are exact; fork, differential, Halmos and invariant suites excluded), then script/coverage-gate.py
# against the per-file minimums in security/coverage-thresholds.json.
#
# Fails when a test fails, when a src/ file with branches is below its minimum or has no minimum, when a minimum is below
# the config's floor (80 % branch coverage for every file; a minimum may be higher, never lower), or when the config
# lists a file that has no branch in the report. A branch that cannot be reached leaves a file's denominator only
# through the config's `unreachable` list, with its function, branch, reason and tests. Reports in
# out-security/coverage/ (lcov.info, summary.txt, run.log).
#
# Exact-gas assertions (`*exactCycleCost*`) are skipped here: their expected values hold for the optimized build, and
# coverage compiles without the optimizer. They run in every other test profile.
#
# The via-IR compilation restriction on Collateralization.sol does not apply: forge coverage disables via-IR and the
# optimizer for every file, and EIP-170 is not enforced in coverage runs.
#
# Usage, from contracts/:
#   script/check-coverage.sh                 run coverage, then the gate
#   script/check-coverage.sh --lcov <file>   gate an existing lcov report
#   script/check-coverage.sh --update        run coverage, raise minimums to the measured values (never lowers them,
#                                            never writes one below the floor)
# Environment: COVERAGE_JOBS (default 2), COVERAGE_NO_MATCH_TEST (default 'exactCycleCost').

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=out-security/coverage
CONFIG=security/coverage-thresholds.json
export PATH="$ROOT/.venv/bin:$HOME/.foundry/bin:$PATH"
PY="$ROOT/.venv/bin/python"
[ -x "$PY" ] || PY=python3

lcov=""
update=()
while [ $# -gt 0 ]; do
  case "$1" in
    --lcov) lcov=$2; shift 2 ;;
    --update) update=(--update); shift ;;
    *) echo "check-coverage: unknown option $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"
if [ -z "$lcov" ]; then
  lcov="$OUT/lcov.info"
  rm -f "$lcov"
  FOUNDRY_PROFILE=coverage forge coverage --report lcov --report summary --report-file "$lcov" \
    -j "${COVERAGE_JOBS:-2}" --no-match-test "${COVERAGE_NO_MATCH_TEST:-exactCycleCost}" \
    --no-match-coverage '^(test|script|dependencies)/' >"$OUT/run.log" 2>&1
  rc=$?
  grep -E '^Ran [0-9]+ test suites|^\[FAIL|Encountered' "$OUT/run.log" || true
  if [ $rc -ne 0 ] || [ ! -s "$lcov" ]; then
    tail -n 40 "$OUT/run.log"
    echo "check-coverage: forge coverage failed (exit $rc); see $OUT/run.log" >&2
    exit 1
  fi
fi

"$PY" script/coverage-gate.py "$lcov" --config "$CONFIG" --summary "$OUT/summary.txt" ${update[@]+"${update[@]}"}
