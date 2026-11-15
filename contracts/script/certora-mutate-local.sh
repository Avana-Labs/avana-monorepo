#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# certoraMutate with a locally built Prover. certoraMutate itself submits every mutant to the Certora cloud and collects
# the results from its API (it needs CERTORAKEY and cloud quota), so this script does the same steps locally: for each
# conf named on the command line it reads the conf's `mutations.gambit` entries, generates that many Gambit mutants per
# file (fixed seed 0, the conf's solc and packages as remappings), and runs `certoraRun.py` on the conf once per
# mutant, with the mutant copied over the file in an isolated copy of contracts/ (the workspace is never mutated).
# Each mutant ends as
#
#   caught       some rule was violated (FAIL in output.json, FAILURE or VIOLATED elsewhere) or failed its sanity
#                check (SANITY_FAIL)
#   survived     at least one rule verified and none failed, timed out or ended unknown, and the Prover exited 0
#   timeout      the run took longer than CERTORA_MUTANT_TIMEOUT seconds, or a rule timed out with none violated
#   invalid      the mutant did not compile
#   error        the Prover wrote no report (see the mutant's log)
#
# The unmutated conf runs first; a conf that does not verify unmutated is skipped, since every mutant would count as
# caught. Reports: out-security/certora-mutate/<Conf>/status.tsv (file, mutant id, result), the Gambit output under
# gambit/, one log per run, and summary.tsv (conf, mutants, caught, survived, timeout, invalid, error).
#
# Environment (defaults): CERTORA=$HOME/certora-build (the built Prover), CERTORA_VENV=$HOME/CertoraProver/.venv,
# GAMBIT=tools/bin/gambit (script/install-security-tools.sh --gambit), CERTORA_MUTANT_TIMEOUT=3600 seconds per run,
# CERTORA_MUTANTS (overrides every entry's num_mutants, for a short trial).
#
# Usage, from contracts/:  script/certora-mutate-local.sh Lock AvanaTimelock ...
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export CERTORA="${CERTORA:-$HOME/certora-build}"
export PATH="$CERTORA:$HOME/bin:$PATH"
unset CERTORAKEY
VENV="${CERTORA_VENV:-$HOME/CertoraProver/.venv}"
GAMBIT="${GAMBIT:-$ROOT/tools/bin/gambit}"
TIMEOUT="${CERTORA_MUTANT_TIMEOUT:-3600}"
OUT="$ROOT/out-security/certora-mutate"
root="$OUT/root"

[ $# -gt 0 ] || { echo "usage: script/certora-mutate-local.sh <Conf> [<Conf> ...]" >&2; exit 2; }
[ -x "$GAMBIT" ] || { echo "missing Gambit at $GAMBIT: run script/install-security-tools.sh --python --gambit" >&2; exit 2; }
[ -f "$VENV/bin/activate" ] || { echo "missing the Prover venv at $VENV" >&2; exit 2; }
# shellcheck disable=SC1091
. "$VENV/bin/activate"
command -v certoraRun.py >/dev/null || { echo "certoraRun.py not on PATH (CERTORA=$CERTORA)" >&2; exit 2; }

mkdir -p "$OUT"
# The isolated copy: sources, specs, confs and dependencies; no build output.
rsync -a --delete --exclude 'out*' --exclude 'cache*' --exclude 'emv-*' --exclude '.certora_internal' \
  --exclude '.venv' --exclude 'node_modules' ./ "$root/"

# conf_info <conf>: the solc, then one "--solc_remappings" value per package, then "MUT <file> <n>" per gambit entry.
conf_info() {
  python3 -I - "$1" "${CERTORA_MUTANTS:-}" <<'PY'
import json, re, sys
d = json.loads(re.sub(r"(?m)^\s*//.*$", "", open(sys.argv[1], encoding="utf8").read()))
print(d.get("solc", "solc"))
for p in d.get("packages", []):
    print("MAP " + p)
for g in d.get("mutations", {}).get("gambit", []):
    print("MUT %s %s" % (g["filename"], sys.argv[2] or g.get("num_mutants", 10)))
PY
}

# verdict <run dir> <log> <rc>: the result of one Prover run.
verdict() {
  local rc=$3
  [ "$rc" -eq 124 ] && { echo timeout; return; }
  if grep -qE 'Compiler run failed|Error \([0-9]+\):|Failed to compile|solc had an error' "$2"; then
    echo invalid; return
  fi
  local report
  report=$(find "$1" -maxdepth 3 -path '*/emv-*/Reports/output.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  [ -n "$report" ] || { echo error; return; }
  python3 -I - "$report" "$rc" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf8"))
rc = int(sys.argv[2])
leaves = []
def walk(x):
    if isinstance(x, dict):
        for v in x.values():
            walk(v)
    elif isinstance(x, list):
        for v in x:
            walk(v)
    elif isinstance(x, str):
        leaves.append(x.upper())
walk(d.get("rules", d))
# output.json writes a violated rule as FAIL; FAILURE and VIOLATED are kept for other report versions.
statuses = [v for v in leaves if v in ("SUCCESS", "FAIL", "FAILURE", "VIOLATED", "SANITY_FAIL", "TIMEOUT", "UNKNOWN")]
if any(v in ("FAIL", "FAILURE", "VIOLATED", "SANITY_FAIL") for v in statuses):
    print("caught")
elif "TIMEOUT" in statuses:
    print("timeout")
elif statuses and all(v == "SUCCESS" for v in statuses) and rc == 0:
    print("survived")
else:
    print("error")
PY
}

# prove <conf> <log>: one Prover run in the isolated copy; prints the verdict.
prove() {
  rm -rf "$root"/emv-* "$root/.certora_internal"
  (cd "$root" && timeout -k 60 "$TIMEOUT" certoraRun.py "certora/conf/$1.conf" --msg "local mutation $1") >"$2" 2>&1
  verdict "$root" "$2" $?
}

: >"$OUT/summary.tsv.new"
for conf in "$@"; do
  dir="$OUT/$conf"
  rm -rf "$dir"
  mkdir -p "$dir"
  : >"$dir/status.tsv"
  mapfile -t info < <(conf_info "certora/conf/$conf.conf")
  solc="${info[0]}"
  remaps=()
  for line in "${info[@]:1}"; do
    [[ $line == MAP\ * ]] && remaps+=("${line#MAP }")
  done
  echo "=== $conf: unmutated run"
  base=$(prove "$conf" "$dir/baseline.log")
  if [ "$base" != survived ]; then
    echo "  the unmutated conf does not verify ($base, see $dir/baseline.log); skipped"
    printf '%s\tskipped (unmutated: %s)\n' "$conf" "$base" >>"$OUT/summary.tsv.new"
    continue
  fi
  declare -A n=([caught]=0 [survived]=0 [timeout]=0 [invalid]=0 [error]=0)
  mkdir -p "$dir/gambit"
  total=0
  for line in "${info[@]:1}"; do
    [[ $line == MUT\ * ]] || continue
    read -r _ file count <<<"$line"
    gdir="$dir/gambit/$(basename "$file" .sol)"
    if ! (cd "$root" && "$GAMBIT" mutate --filename "$file" --num_mutants "$count" --seed 0 --solc "$solc" \
      --solc_remappings "${remaps[@]}" --outdir "$gdir") >"$gdir.log" 2>&1; then
      echo "  gambit failed on $file (see $gdir.log)"
      continue
    fi
    cp "$root/$file" "$gdir/original.sol"
    for id in $(cut -d, -f1 "$gdir/mutants.log" 2>/dev/null); do
      cp "$gdir/mutants/$id/$file" "$root/$file"
      result=$(prove "$conf" "$gdir/$id.log")
      cp "$gdir/original.sol" "$root/$file"
      n[$result]=$((n[$result] + 1))
      total=$((total + 1))
      printf '%s\t%s\t%s\t%s\n' "$file" "$id" "$result" "$(grep -m1 "^$id," "$gdir/mutants.log")" >>"$dir/status.tsv"
      echo "  $file mutant $id: $result"
    done
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$conf" "$total" "${n[caught]}" "${n[survived]}" "${n[timeout]}" \
    "${n[invalid]}" "${n[error]}" >>"$OUT/summary.tsv.new"
  echo "  $conf: $total mutants, caught ${n[caught]}, survived ${n[survived]}, timeout ${n[timeout]}, invalid ${n[invalid]}, error ${n[error]}"
  unset n
done
mv "$OUT/summary.tsv.new" "$OUT/summary.tsv"
echo "summary: $OUT/summary.tsv"
