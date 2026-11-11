#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Gambit expression mutants of the layer-gate targets, each run against its Foundry tests (security-slow.sh `gambit`).
#
# For every implementation file that `script/mutation-targets.py gambit` lists from security/mutation-layers.json,
# Gambit (tools/bin/gambit) writes at most the layer's mutant cap, drawn with the fixed seed from the configured
# operators and checked to compile with the project's solc. The file's tests (`forge test -j 2 --fail-fast
# --match-path <tests>`) first run once on the unmutated code, then once per mutant with the mutant copied over the
# file, all in an isolated copy of src/ and test/ under out-security/gambit/root, so the workspace is never mutated.
# Each mutant ends as
#
#   killed    a test failed
#   survived  every matched test passed
#   timeout   the run took longer than GAMBIT_TIMEOUT seconds (counted with the survivors: a slow suite must not hide
#             a surviving mutant)
#   invalid   the mutant did not compile under forge (counted with neither)
#
# Reports, per layer and contract: out-security/gambit/<layer>/<Contract>/status.tsv (mutant id and result),
# gambit/gambit_results.json and gambit/mutants/<id>/ (each mutant's diff and source), and <id>.log (its test run);
# per layer: out-security/gambit/<layer>/survivors.txt. security-gate.py then gates every survived or timed-out
# mutant against security/gambit-triage.json (out-security/gambit/gate.txt): a mutant whose fingerprint is not
# accepted there with a reason fails the run. Fix it with a test that kills it, or accept it at the layer gate review
# with the reason the change cannot be observed.
#
# Budgets (environment, with defaults): MUTATE_LAYERS and MUTATE_CONTRACTS (space-separated, as for `mutate`; empty:
# all), GAMBIT_TIMEOUT=300 seconds per mutant test run, GAMBIT_FUZZ_RUNS (default MUTATE_FUZZ_RUNS, else 256).
#
# Usage, from contracts/:  script/security-gambit.sh

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=out-security/gambit
PY="$ROOT/.venv/bin/python"
GAMBIT="$ROOT/tools/bin/gambit"
export PATH="$ROOT/tools/bin:$ROOT/.venv/bin:$HOME/.foundry/bin:$PATH"

GAMBIT_TIMEOUT=${GAMBIT_TIMEOUT:-300}
GAMBIT_FUZZ_RUNS=${GAMBIT_FUZZ_RUNS:-${MUTATE_FUZZ_RUNS:-256}}
TRIAGE=security/gambit-triage.json

if [ ! -x "$GAMBIT" ]; then
  echo "missing Gambit: run script/install-security-tools.sh --python --gambit" >&2
  exit 1
fi
command -v forge >/dev/null 2>&1 || { echo "missing forge" >&2; exit 1; }

# with_timeout <seconds> <command...>: the command's exit code, or 124 when it ran longer than <seconds>. GNU timeout
# where present (Linux CI), else a perl wrapper (macOS ships no timeout) that runs the command in its own process
# group and stops the whole group, so no child outlives the run.
with_timeout() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 10 "$secs" "$@"
    return $?
  fi
  perl -e '
    my $secs = shift;
    my $pid = fork() // exit 127;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; waitpid($pid, 0); exit 124 };
    alarm $secs;
    waitpid($pid, 0);
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);' "$secs" "$@"
}

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
  for f in dependencies foundry.toml remappings.txt out-aave; do
    [ -e "$f" ] && ln -s "$ROOT/$f" "$root/$f"
  done
  ln -s "$solc" "$root/bin/solc"
}

# run_tests <root> <tests glob> <log>: forge test in the isolated copy; exit code as with_timeout.
run_tests() {
  (cd "$1" && export FOUNDRY_FUZZ_RUNS="$GAMBIT_FUZZ_RUNS" &&
    with_timeout "$GAMBIT_TIMEOUT" forge test -j 2 --fail-fast --match-path "$2" >"$3" 2>&1)
}

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
  ids=$(cut -d, -f1 "$dir/gambit/mutants.log" 2>/dev/null)
  if [ -z "$ids" ]; then
    echo "  no mutant generated"
    continue
  fi

  # The unmutated file must pass its tests first, or a failing suite would count every mutant as killed. This run
  # also compiles the isolated copy, so it gets no per-mutant timeout.
  if ! (cd "$root" && FOUNDRY_FUZZ_RUNS="$GAMBIT_FUZZ_RUNS" forge test -j 2 --match-path "$tests" \
    >"$dir/baseline.log" 2>&1); then
    status=1
    echo "gambit: the tests of $name fail without a mutant (see $dir/baseline.log)"
    continue
  fi

  cp "$root/$file" "$dir/original.sol"
  killed=0 survived=0 timeouts=0 invalid=0
  for id in $ids; do
    cp "$dir/gambit/mutants/$id/$file" "$root/$file"
    run_tests "$root" "$tests" "$dir/$id.log"
    rc=$?
    cp "$dir/original.sol" "$root/$file"
    if [ $rc -eq 0 ]; then
      result=survived survived=$((survived + 1))
    elif [ $rc -eq 124 ]; then
      result=timeout timeouts=$((timeouts + 1))
    elif grep -qE 'Compiler run failed|Error \([0-9]+\):' "$dir/$id.log"; then
      result=invalid invalid=$((invalid + 1))
    else
      result=killed killed=$((killed + 1))
    fi
    printf '%s\t%s\n' "$id" "$result" >>"$dir/status.tsv"
    if [ $result = survived ] || [ $result = timeout ]; then
      echo "$name: $result $(grep -m1 "^$id," "$dir/gambit/mutants.log")" >>"$ROOT/$OUT/$layer/survivors.txt"
    fi
  done
  echo "  killed $killed, survived $survived, timeout $timeouts, invalid $invalid"
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
