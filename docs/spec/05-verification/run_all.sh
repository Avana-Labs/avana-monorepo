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
#   ./run_all.sh <part>     one part of the quick path (with --nightly, the quint part adds the topology runs):
#                             z3/<folder>  every script of that z3/ folder
#                             z3, sympy, simulation   the scripts of that folder outside a z3/ subfolder
#                             hypothesis   the Hypothesis suite
#                             quint        Quint typecheck and tests of every model, then quint/run.sh
#                             trace        trace.py
#                           The parts together run exactly the quick path; CI runs one part per job.
#   ./run_all.sh --list     prints the parts, one per line
set -uo pipefail
cd "$(dirname "$0")"
nightly=0
list=0
part=""
usage() { echo "usage: $0 [--nightly] [--list | <part>]" >&2; exit 2; }
for a in "$@"; do
  case "$a" in
    --nightly) nightly=1 ;;
    --list) list=1 ;;
    -*) usage ;;
    *) [ -z "$part" ] || usage; part=$a ;;
  esac
done

# Z3, SymPy and simulation scripts all run on this folder's .venv; modules named _*.py are imported, not run.
# z3/amm-pricing/ holds the pricing proofs each AMM integration needs before listing (MATH-AMM-<P>-PRICE-NN).
scripts() { find z3 sympy simulation -name '*.py' -not -name '_*' -not -path '*/.venv/*' -not -path '*/__pycache__/*' | sort; }

# part_of <script>: z3/<folder> for a script under a z3/ subfolder, else its top folder.
part_of() {
  local top sub rest
  IFS=/ read -r top sub rest <<<"$1"
  if [ "$top" = z3 ] && [ -n "$rest" ]; then echo "z3/$sub"; else echo "$top"; fi
}

parts() {
  local f p seen=" "
  for f in $(scripts); do
    p=$(part_of "$f")
    [[ "$seen" == *" $p "* ]] || { seen+="$p "; echo "$p"; }
  done
  printf '%s\n' hypothesis quint trace
}

if [ $list -eq 1 ]; then
  [ -z "$part" ] || usage
  parts
  exit 0
fi
if [ -n "$part" ]; then
  all=$(parts)
  if ! grep -qxF -- "$part" <<<"$all"; then
    echo "run_all.sh: no such part: $part (parts: $(tr '\n' ' ' <<<"$all"))" >&2
    exit 2
  fi
fi
# want <part>: true when no part is selected or <part> is the selected one.
want() { [ -z "$part" ] || [ "$part" = "$1" ]; }

[ -x .venv/bin/python ] || { python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt; }
if want quint; then [ -d node_modules ] || npm install --silent; fi
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
for f in $(scripts); do
  want "$(part_of "$f")" || continue
  run "$f" .venv/bin/python "$f"
done
# hypothesis/test_hyp_amm_pricing.py (HYP-AMM-<P>-…) runs with the rest of the suite.
want hypothesis && run "hypothesis" .venv/bin/python -m pytest -q hypothesis
if want quint; then
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
fi
want trace && run "traceability (trace.py)" .venv/bin/python trace.py
echo; echo "=== summary (exit status per step)"
printf '%s\n' "${summary[@]}"
exit $status
