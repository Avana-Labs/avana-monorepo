#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Gambit expression mutants of the layer-gate targets, each run against its Foundry tests (security-slow.sh `gambit`).
#
# For every implementation file that `script/mutation-targets.py gambit` lists from security/mutation-layers.json,
# Gambit (tools/bin/gambit) writes at most the layer's mutant cap, drawn with the fixed seed from the configured
# operators and checked to compile with the project's solc. The file's tests first run once on the unmutated code, then
# once per mutant with the mutant copied over the file, each run by script/mutation-test.py (one `forge test -j 2
# --fail-fast --match-path <tests>` in the `mutation` profile of foundry.toml, which compiles src/ and the matched
# tests only, then the optimized-only tests in the default profile for a mutant the rest let through), all in an
# isolated copy of src/ and test/ under out-security/gambit/root, so the workspace is never mutated. Each mutant ends as
#
#   killed    a test failed
#   survived  every matched test passed
#   timeout   compile and tests took longer than GAMBIT_TIMEOUT seconds, or the default-profile run longer than
#             GAMBIT_OPTIMIZED_TIMEOUT (counted with the survivors: a slow suite must not hide a surviving mutant)
#   invalid   the mutant did not compile under forge (counted with neither)
#   error     the mutant could not be applied (its file missing or identical to the original); the run fails
#
# The mutants are read from gambit/gambit_results.json (script/mutation-records.py gambit), never from mutants.log,
# whose CSV fields can span lines.
#
# Reports, per layer and contract: out-security/gambit/<layer>/<Contract>/status.tsv (mutant id and result),
# gambit/gambit_results.json and gambit/mutants/<id>/ (each mutant's diff and source), and <id>.log (its test run);
# per layer: out-security/gambit/<layer>/survivors.txt. security-gate.py then gates every survived or timed-out
# mutant against security/gambit-triage.json (out-security/gambit/gate.txt): a mutant whose fingerprint is not
# accepted there with a reason fails the run. Fix it with a test that kills it, or accept it at the layer gate review
# with the reason the change cannot be observed.
#
# Budgets (environment, with defaults): MUTATE_LAYERS and MUTATE_CONTRACTS (space-separated, as for `mutate`; empty:
# all), GAMBIT_TIMEOUT=600 seconds per mutant (its compile and tests), GAMBIT_OPTIMIZED_TIMEOUT=1800 seconds for the
# default-profile run of the optimized-only tests, GAMBIT_FUZZ_RUNS (default MUTATE_FUZZ_RUNS, else 256).
#
# Usage, from contracts/:  script/security-gambit.sh

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=out-security/gambit
PY="$ROOT/.venv/bin/python"
GAMBIT="$ROOT/tools/bin/gambit"
export PATH="$ROOT/tools/bin:$ROOT/.venv/bin:$HOME/.foundry/bin:$PATH"

GAMBIT_TIMEOUT=${GAMBIT_TIMEOUT:-600}
GAMBIT_OPTIMIZED_TIMEOUT=${GAMBIT_OPTIMIZED_TIMEOUT:-1800}
GAMBIT_FUZZ_RUNS=${GAMBIT_FUZZ_RUNS:-${MUTATE_FUZZ_RUNS:-256}}
TRIAGE=security/gambit-triage.json

if [ ! -x "$GAMBIT" ]; then
  echo "missing Gambit: run script/install-security-tools.sh --python --gambit" >&2
  exit 1
fi
command -v forge >/dev/null 2>&1 || { echo "missing forge" >&2; exit 1; }

# solc_bin: the solc of foundry.toml's solc_version, from Foundry's svm cache (macOS or Linux) or tools/bin.
solc_bin() {
  local v d
  v=$(sed -nE 's/^solc_version *= *"([0-9.]+)".*/\1/p' foundry.toml | head -n1)
  for d in "$HOME/Library/Application Support/svm" "${XDG_DATA_HOME:-$HOME/.local/share}/svm" "$HOME/.svm"; do
    [ -x "$d/$v/solc-$v" ] && { echo "$d/$v/solc-$v"; return 0; }
  done
  [ -x "$ROOT/tools/bin/solc-$v" ] && { echo "$ROOT/tools/bin/solc-$v"; return 0; }
  echo "missing solc $v: run forge build once so Foundry installs it" >&2
  return 1
}

# isolated_root <dir>: a project copy whose src/ and test/ this script edits in place, with its own out/ and cache/,
# as in security-slow.sh.
isolated_root() {
  local root=$1 f solc
  solc=$(solc_bin) || return 1
  rm -rf "$root" && mkdir -p "$root/bin"
  cp -R src test "$root/"
  for f in dependencies foundry.toml remappings.txt out-aave out-univ3 out-univ3-periphery out-slipstream-v1 \
    out-slipstream-main out-aerodrome; do
    [ -e "$f" ] && ln -s "$ROOT/$f" "$root/$f"
  done
  ln -s "$solc" "$root/bin/solc"
}

# Every forge run of this script builds in the `mutation` profile (script/mutation-test.py sets the default profile
# for the optimized-only tests itself).
export FOUNDRY_PROFILE=mutation

list=$("$PY" script/mutation-targets.py gambit --layers "${MUTATE_LAYERS:-}" --contracts "${MUTATE_CONTRACTS:-}") ||
  exit 1
if [ -z "$list" ]; then
  echo "gambit: skipped, no implementation file in the selected layers of security/mutation-layers.json"
  exit 0
fi

root="$ROOT/$OUT/root"
rm -rf "$OUT" && mkdir -p "$OUT"
isolated_root "$root" || exit 1
remaps=()
while IFS= read -r line; do
  [ -n "$line" ] && remaps+=("$line")
done <remappings.txt

status=0
while IFS=$'\t' read -r layer name file tests cap seed ops; do
  dir="$ROOT/$OUT/$layer/$name"
  mkdir -p "$dir"
  : >"$dir/status.tsv"
  echo "=== gambit $name ($file), layer $layer, up to $cap mutants, tests $tests"
  # Operators come comma-separated from mutation-targets.py; Gambit takes them as separate words.
  # shellcheck disable=SC2086
  if ! (cd "$root" && "$GAMBIT" mutate --filename "$file" --contract "$name" --solc "$root/bin/solc" \
    --solc_remappings "${remaps[@]}" --outdir "$dir/gambit" --num_mutants "$cap" --seed "$seed" \
    --mutations ${ops//,/ } >"$dir/gambit.log" 2>&1); then
    status=1
    echo "gambit: mutant generation failed on $name (see $dir/gambit.log)"
    continue
  fi
  # The mutants come from gambit_results.json through a JSON parser: mutants.log is CSV whose quoted fields can span
  # lines, so reading it line by line takes a continuation line ("&", a quote) for a mutant id.
  if ! mutants=$("$PY" script/mutation-records.py gambit "$dir/gambit"); then
    status=1
    echo "gambit: cannot read the mutants of $name (see $dir/gambit/gambit_results.json)"
    continue
  fi
  if [ -z "$mutants" ]; then
    echo "  no mutant generated"
    continue
  fi

  # The unmutated file must pass its tests first, or a failing suite would count every mutant as killed. This run
  # also compiles the isolated copy, so it gets no per-mutant timeout.
  if ! (cd "$root" && FOUNDRY_FUZZ_RUNS="$GAMBIT_FUZZ_RUNS" "$PY" "$ROOT/script/mutation-test.py" baseline "$tests" \
    "$dir/baseline.log"); then
    status=1
    echo "gambit: the tests of $name fail without a mutant (see $dir/baseline.log)"
    continue
  fi

  cp "$root/$file" "$dir/original.sol"
  killed=0 survived=0 timeouts=0 invalid=0 errors=0
  # The list is read on its own descriptor, so no command in the loop can consume it from stdin.
  while IFS=$'\t' read -r id path record <&3; do
    # A mutant that cannot be applied (its file missing, or identical to the original) is an error, never a
    # survivor: the tests would run on the unmutated code.
    if ! cp "$dir/gambit/$path" "$root/$file" || cmp -s "$dir/original.sol" "$root/$file"; then
      cp "$dir/original.sol" "$root/$file"
      status=1
      errors=$((errors + 1))
      echo "gambit: mutant $id of $name could not be applied from $dir/gambit/$path"
      printf '%s\t%s\n' "$id" error >>"$dir/status.tsv"
      continue
    fi
    result=$(cd "$root" && FOUNDRY_FUZZ_RUNS="$GAMBIT_FUZZ_RUNS" "$PY" "$ROOT/script/mutation-test.py" run "$tests" \
      "$dir/$id.log" --timeout "$GAMBIT_TIMEOUT" --optimized-timeout "$GAMBIT_OPTIMIZED_TIMEOUT")
    cp "$dir/original.sol" "$root/$file"
    case $result in
      survived) survived=$((survived + 1)) ;;
      timeout) timeouts=$((timeouts + 1)) ;;
      invalid) invalid=$((invalid + 1)) ;;
      killed) killed=$((killed + 1)) ;;
      *)
        status=1
        echo "gambit: mutant $id of $name has no outcome (see $dir/$id.log)"
        continue
        ;;
    esac
    printf '%s\t%s\n' "$id" "$result" >>"$dir/status.tsv"
    if [ $result = survived ] || [ $result = timeout ]; then
      echo "$name: $result $record" >>"$ROOT/$OUT/$layer/survivors.txt"
    fi
  done 3<<<"$mutants"
  echo "  killed $killed, survived $survived, timeout $timeouts, invalid $invalid, error $errors"
  # The isolated copy must hold the original file again before the next target.
  if ! cmp -s "$dir/original.sol" "$root/$file"; then
    status=1
    echo "gambit: $file was not restored in the isolated copy; recreating it"
    isolated_root "$root" || exit 1
  fi
done <<<"$list"

for f in "$OUT"/*/survivors.txt; do
  [ -f "$f" ] && echo "survivors: $(wc -l <"$f" | tr -d ' ') in $f"
done

if ls "$OUT"/*/*/status.tsv >/dev/null 2>&1; then
  "$PY" script/security-gate.py gambit "$OUT" --triage "$TRIAGE" --fail-on high --summary "$OUT/gate.txt" || status=1
fi
exit $status
