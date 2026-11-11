#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Runs every spec-stage verification check. Exit code is non-zero if any check fails.
#
#   ./run_all.sh            quick path: every Z3, SymPy and simulation script (z3/amm-pricing included),
#                           the Hypothesis suite, Quint typecheck and tests of every model (topology
#                           included), the Quint simulator checks of quint/run.sh, then trace.py
#   ./run_all.sh --nightly  the quick path, then the topology simulator runs of quint/topology_run.sh
#                           (1,000 traces x 25 steps per check; QNT_SAMPLES / QNT_STEPS override)
set -uo pipefail
cd "$(dirname "$0")"
nightly=0
for a in "$@"; do
  case "$a" in
    --nightly) nightly=1 ;;
    *) echo "usage: $0 [--nightly]" >&2; exit 2 ;;
  esac
done
[ -x .venv/bin/python ] || { python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt; }
[ -d node_modules ] || npm install --silent
status=0
summary=()
run() {
  local name="$1" rc
  shift
  echo; echo "=== $name"
  "$@"; rc=$?
  summary+=("$(printf '%3d  %s' "$rc" "$name")")
  [ $rc -eq 0 ] || status=1
}
# Z3, SymPy and simulation scripts all run on this folder's .venv; modules named _*.py are imported, not run.
# z3/amm-pricing/ holds the pricing proofs each AMM integration needs before listing (MATH-AMM-<P>-PRICE-NN).
for f in $(find z3 sympy simulation -name '*.py' -not -name '_*' -not -path '*/.venv/*' -not -path '*/__pycache__/*' | sort); do
  run "$f" .venv/bin/python "$f"
done
# hypothesis/test_hyp_amm_pricing.py (HYP-AMM-<P>-…) runs with the rest of the suite.
run "hypothesis" .venv/bin/python -m pytest -q hypothesis
# Every model: avana.qnt with avana_tests.qnt, topology.qnt with topology_tests.qnt (QNT-TOPO-T00 … T19).
for f in $(find quint -name '*.qnt' | sort); do
  run "quint typecheck $f" npx quint typecheck "$f"
  run "quint test $f" npx quint test "$f"
done
# Quint simulator runs (bounded random traces) are listed per model in quint/README.md and run by quint/run.sh.
[ -x quint/run.sh ] && run "quint simulate" quint/run.sh
if [ $nightly -eq 1 ]; then
  run "quint simulate (topology)" quint/topology_run.sh
fi
run "traceability (trace.py)" .venv/bin/python trace.py
echo; echo "=== summary (exit status per step)"
printf '%s\n' "${summary[@]}"
exit $status
