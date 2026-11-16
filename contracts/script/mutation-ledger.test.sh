#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Test of script/mutation-ledger.py, which lets the nightly mutation gate skip targets that did not change:
#
#   1. keys: the same tree gives the same keys; a target's key covers the files its file imports, so editing an
#      imported file (not the target itself) changes it.
#   2. current: a target is current only when the ledger holds a passed report of every shard under today's key.
#   3. merge: keeps only today's key of each target.
#
# Usage, from contracts/:  script/mutation-ledger.test.sh

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { # <description> <command...>: passes when the command exits 0
  local d=$1
  shift
  if "$@" >"$TMP/out" 2>&1; then
    echo "ok   $d"
  else
    echo "FAIL $d"
    sed 's/^/     /' "$TMP/out"
    fail=1
  fi
}

python3 script/mutation-ledger.py keys --contracts TimelockSelectors >"$TMP/keys.json"
python3 script/mutation-ledger.py keys --contracts TimelockSelectors >"$TMP/keys2.json"
check "keys: the same tree gives the same keys" cmp "$TMP/keys.json" "$TMP/keys2.json"
check "keys: slither-mutate, Gambit and Necessist entries" python3 -c "
import json, sys
k = json.load(open(sys.argv[1]))
assert 'mutate:2.1:TimelockSelectors' in k and 'gambit:2.1:TimelockSelectors' in k, k
assert any(e.startswith('necessist:2.1:test/unit/AvanaTimelock') for e in k), k
" "$TMP/keys.json"

# An import closure outside the project tree: a.sol imports b.sol, which imports c.sol.
mkdir -p "$TMP/sol"
printf 'import "./b.sol";\ncontract A {}\n' >"$TMP/sol/a.sol"
printf 'import {C} from "./c.sol";\ncontract B {}\n' >"$TMP/sol/b.sol"
printf 'contract C {}\n' >"$TMP/sol/c.sol"
closure_key() {
  python3 - "$TMP/sol/a.sol" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("ml", "script/mutation-ledger.py")
ml = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ml)
files, loose = ml.Closure().files(Path(sys.argv[1]))
assert sorted(p.name for p in files) == ["a.sol", "b.sol", "c.sol"], sorted(files)
print(ml.digest(set(files), sorted(loose)))
PY
}
before=$(closure_key)
printf 'contract C { uint256 x; }\n' >"$TMP/sol/c.sol"
after=$(closure_key)
check "keys: editing an imported file changes the key" test "$before" != "$after"

# A run of two shards of TimelockSelectors: one passed shard is not enough, both are.
key=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['mutate:2.1:TimelockSelectors'])" "$TMP/keys.json")
shard() { # <k>: a passed report of shard k of 2, as a mutate job uploads it
  local d="$TMP/reports/mutate-2.1-TimelockSelectors-$1/2.1/TimelockSelectors"
  mkdir -p "$d"
  printf 'index\tmutator\tkind\tline\toutcome\tseconds\toriginal\treplacement\n' >"$d/shard-$1.tsv"
  python3 script/mutation-ledger.py done "$d" mutate:2.1:TimelockSelectors "$key" --shard "$1" --shards 2
}
is_current() { python3 script/mutation-ledger.py current "$TMP/ledger" "$TMP/keys.json" | grep -q "mutate:2.1:TimelockSelectors"; }
mkdir -p "$TMP/ledger/mutate/2.1/TimelockSelectors/0ld"
shard 1
python3 script/mutation-ledger.py merge "$TMP/ledger" "$TMP/reports" "$TMP/keys.json" >/dev/null
check "current: one of two shards passed, not current" bash -c "$(declare -f is_current); TMP=$TMP; ! is_current"
shard 2
python3 script/mutation-ledger.py merge "$TMP/ledger" "$TMP/reports" "$TMP/keys.json" >/dev/null
check "current: both shards passed, current" bash -c "$(declare -f is_current); TMP=$TMP; is_current"
check "merge: an earlier key of the target is dropped" test ! -e "$TMP/ledger/mutate/2.1/TimelockSelectors/0ld"
check "current: another key is not current" bash -c "
python3 -c \"import json; k=json.load(open('$TMP/keys.json')); k['mutate:2.1:TimelockSelectors']='other'; json.dump(k, open('$TMP/keys3.json','w'))\"
! python3 script/mutation-ledger.py current '$TMP/ledger' '$TMP/keys3.json' | grep -q TimelockSelectors"

exit $fail
