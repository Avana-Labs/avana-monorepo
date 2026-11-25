#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Regression test of script/mutation-records.py, which security-slow.sh and mutation-report.py use to read the
# slither-mutate and Necessist logs: a mutant or removed statement that spans several log lines comes through whole.
#
#   1. survivors: a one-line and a multi-line uncaught mutant each give one line; the multi-line one, read back,
#      is the whole mutant (first line to "--> UNCAUGHT"); a caught multi-line mutant is left out.
#   2. necessist: a one-line and a multi-line passing removal each give one line, the multi-line one whole; a
#      failed removal is left out.
#   3. mutation-report.py lists the multi-line survivor (from a shard report of script/mutation-slither.py) and
#      removal with their first and last lines.
#   4. A timed-out mutant is its own outcome: mutation-report.py counts it as timed out, never as killed, and lists
#      it with the survivors; script/mutation-test.py names a run past its budget `timeout`, a compiler error in a
#      src/ file `invalid` and one only in a test file `killed` (with --test-compile-kills, as slither-mutate counted
#      it), `invalid` without.
#   5. gambit: the mutants of a Gambit outdir come from gambit_results.json, one line each with its id and mutated
#      file, also when the mutated text spans lines and holds a quote, `&` or a comma (Gambit's mutants.log then
#      spans several lines, and a line-by-line read took "&" and a quote for mutant ids); a malformed results file
#      fails instead of naming no mutant.
#
# Usage, from contracts/:  script/mutation-records.test.sh

set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/mutate.log" <<'LOG'
INFO:Slither-Mutate:Mutating contract Foo
INFO:Slither-Mutate:[ROR] Line 10: 'a > b' ==> 'a >= b' --> UNCAUGHT
INFO:Slither-Mutate:[CR] Line 20: 'require(
            x > 0,
            "bad\n"
        )' ==> '//require(
            x > 0,
            "bad\n"
        )' --> UNCAUGHT
INFO:Slither-Mutate:[CR] Line 30: 'emit Done(
            1
        )' ==> '//emit Done(
            1
        )' --> CAUGHT
INFO:Slither-Mutate:Revert mutants: 0 caught of 0
INFO:Slither-Mutate:Comment mutants: 1 caught of 3
LOG

cat >"$TMP/necessist.log" <<'LOG'
3 candidates in 1 test file
test/Foo.t.sol:5:9-5:20: `vm.prank(a);` passed
test/Foo.t.sol:7:9-9:11: `vm.expectRevert(
            abi.encodeWithSelector(E.selector)
        );` passed
test/Foo.t.sol:12:9-13:10: `foo(
        );` failed
LOG

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

# read_back <file> <line> <expected file>: line <line> of <file>, unescaped, equals <expected file>.
read_back() {
  python3 - "$@" <<'PY'
import sys
rows = open(sys.argv[1], encoding="utf8").read().splitlines()
row = rows[int(sys.argv[2]) - 1]
out, i = [], 0
while i < len(row):
    if row[i] == "\\" and i + 1 < len(row):
        out.append("\n" if row[i + 1] == "n" else row[i + 1])
        i += 2
    else:
        out.append(row[i])
        i += 1
want = open(sys.argv[3], encoding="utf8").read().rstrip("\n")
got = "".join(out)
if got != want:
    sys.exit(f"got:\n{got}\nwant:\n{want}")
PY
}

lines_are() { # <file> <count>
  local n
  n=$(wc -l <"$1" | tr -d ' ')
  [ "$n" = "$2" ] || { echo "$n line(s), expected $2"; cat "$1"; return 1; }
}

python3 script/mutation-records.py survivors "$TMP/mutate.log" "Foo: " >"$TMP/survivors.txt"
sed -n '3,9p' "$TMP/mutate.log" | sed '1s/^/Foo: /' >"$TMP/want-survivor"
check "survivors: one line per uncaught mutant, caught one left out" lines_are "$TMP/survivors.txt" 2
check "survivors: one-line mutant as logged" grep -qxF "Foo: INFO:Slither-Mutate:[ROR] Line 10: 'a > b' ==> 'a >= b' --> UNCAUGHT" "$TMP/survivors.txt"
check "survivors: multi-line mutant whole" read_back "$TMP/survivors.txt" 2 "$TMP/want-survivor"

python3 script/mutation-records.py necessist "$TMP/necessist.log" >"$TMP/necessist.txt"
sed -n '3,5p' "$TMP/necessist.log" >"$TMP/want-removal"
check "necessist: one line per passing removal, failed one left out" lines_are "$TMP/necessist.txt" 2
check "necessist: one-line removal as logged" grep -qxF 'test/Foo.t.sol:5:9-5:20: `vm.prank(a);` passed' "$TMP/necessist.txt"
check "necessist: multi-line removal whole" read_back "$TMP/necessist.txt" 2 "$TMP/want-removal"

# A Gambit outdir as Gambit 2.1 writes it: mutant 2 replaces an `&` that starts a continuation line, so its
# mutants.log record spans two lines and its second line begins with spaces, `&` and a quote.
mkdir -p "$TMP/gambit/mutants/1/src" "$TMP/gambit/mutants/2/src"
cat >"$TMP/gambit/mutants.log" <<'LOG'
1,BinaryOpMutation,src/Foo.sol,10:9, | ,-
2,BinaryOpMutation,src/Foo.sol,12:20,"
            & ",+
LOG
cat >"$TMP/gambit/gambit_results.json" <<'JSON'
[
  {"description": "BinaryOpMutation", "diff": "--- original\n+++ mutant\n@@ -10,1 +10,2 @@\n-        x = a | b;\n+        /// BinaryOpMutation(`|` |==> `-`) of: `x = a | b;`\n+        x = a-b;\n", "id": "1", "name": "mutants/1/src/Foo.sol", "original": "src/Foo.sol", "sourceroot": "."},
  {"description": "BinaryOpMutation", "diff": "--- original\n+++ mutant\n@@ -12,2 +12,3 @@\n-        y = f(\"a, b\") & c\n-            & d;\n+        /// BinaryOpMutation(`&` |==> `+`) of: `& d`\n+        y = f(\"a, b\") & c\n+            + d;\n", "id": "2", "name": "mutants/2/src/Foo.sol", "original": "src/Foo.sol", "sourceroot": "."}
]
JSON
python3 script/mutation-records.py gambit "$TMP/gambit" >"$TMP/gambit.txt"
check "gambit: one line per mutant of gambit_results.json" lines_are "$TMP/gambit.txt" 2
check "gambit: ids and mutated files" test "$(cut -f1,2 "$TMP/gambit.txt" | tr '\t\n' ' |')" = \
  "1 mutants/1/src/Foo.sol|2 mutants/2/src/Foo.sol|"
check "gambit: a multi-line mutant whole, from its diff" grep -qxF \
  $'2\tmutants/2/src/Foo.sol\t2,BinaryOpMutation,src/Foo.sol,line 12,y = f("a, b") & c & d;,y = f("a, b") & c + d;' \
  "$TMP/gambit.txt"
printf '[{"id": "&", "name": "mutants/&/src/Foo.sol"}]' >"$TMP/gambit/gambit_results.json"
check "gambit: a malformed mutant entry fails" bash -c '! python3 script/mutation-records.py gambit "$1"' _ "$TMP/gambit"
printf 'not json' >"$TMP/gambit/gambit_results.json"
check "gambit: an unreadable results file fails" bash -c '! python3 script/mutation-records.py gambit "$1"' _ "$TMP/gambit"

# mutation-report.py on a run of one slither-mutate shard and one Necessist job. The shard report holds one mutant of
# each outcome; its texts are escaped as script/mutation-slither.py writes them (backslash, newline, tab).
mkdir -p "$TMP/art/mutate-2.1-Foo-1/2.1/Foo" "$TMP/art/necessist-2.1-Foo.t/"
{
  printf 'index\tmutator\tkind\tline\toutcome\tseconds\toriginal\treplacement\n'
  printf '%s\n' '0	CR	comment	20	survived	1.0	require(\n            x > 0,\n            "bad\\n"\n        )	//require(\n            x > 0,\n            "bad\\n"\n        )'
  printf '%s\n' '1	RR	revert	30	killed	1.0	{ emit Done(1); }	{ revert(); }'
  printf '%s\n' '2	MIA	tweak	40	timeout	600.0	a > b	true'
  printf '%s\n' '3	LIR	tweak	50	invalid	0.5	1	0'
} >"$TMP/art/mutate-2.1-Foo-1/2.1/Foo/shard-1.tsv"
cp "$TMP/necessist.log" "$TMP/art/necessist-2.1-Foo.t/2.1.log"
cat >"$TMP/jobs.json" <<'JSON'
{"jobs": [
  {"name": "mutate 2.1 Foo (shard 1 of 1)", "status": "completed", "conclusion": "success"},
  {"name": "necessist 2.1 test/Foo.t.sol", "status": "completed", "conclusion": "success"}
]}
JSON
python3 script/mutation-report.py "$TMP/art" "$TMP/jobs.json" 1 0000000 "$TMP/report" >/dev/null
# The report writes each newline of a table cell as a space, so the source indentation stays as a run of spaces.
check "mutation-report: multi-line survivor listed whole" \
  grep -qE '^\| slither-mutate \| 2\.1 \| Foo \| line 20 \(CR\) \| `require\( +x > 0, +"bad\\n" +\)` → `//require\( +x > 0, +"bad\\n" +\)` \| survived \|$' \
  "$TMP/report/survivors.md"
check "mutation-report: multi-line removal listed whole" \
  grep -qE '^\| 2\.1 \| `test/Foo\.t\.sol:7:9-9:11` \| `vm\.expectRevert\( +abi\.encodeWithSelector\(E\.selector\) +\);` \|$' \
  "$TMP/report/survivors.md"
check "mutation-report: two survivors, two removals" grep -qF '| 2.1 | `test/Foo.t.sol` | 3 | 2 |' "$TMP/report/README.md"
check "mutation-report: the timed-out mutant listed as timeout" \
  grep -qF '| slither-mutate | 2.1 | Foo | line 40 (MIA) | `a > b` → `true` | timeout |' "$TMP/report/survivors.md"
# Contract, layer, counted (killed + survived + timed out), killed, survived, timed out, not compiled, kill rate.
check "mutation-report: a timeout counts as timed out, not killed" \
  grep -qF '| Foo | 2.1 | 3 | 1 | 1 | 1 | 1 | 33.3 % |' "$TMP/report/README.md"
# The same with the job list left out (`-`): every report folder counts as a finished job.
python3 script/mutation-report.py "$TMP/art" - 1 0000000 "$TMP/report2" >/dev/null
check "mutation-report: without a job list" grep -qF '| Foo | 2.1 | 3 | 1 | 1 | 1 | 1 | 33.3 % |' "$TMP/report2/README.md"

# script/mutation-test.py outcomes from forge's exit code and output.
outcomes() {
  python3 - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("mt", "script/mutation-test.py")
mt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mt)
test_err = "Compiler run failed:\nError (9582): Member not found\n  --> test/unit/Foo.t.sol:12:9:\n"
src_err = "Compiler run failed:\nError (7576): Undeclared identifier\n  --> src/Foo.sol:3:5:\n"
cases = [
    ((None, "", True), "timeout"),
    ((None, "", False), "timeout"),
    ((0, "Suite result: ok", True), "survived"),
    ((1, "[FAIL: assertion failed] test_x()", True), "killed"),
    ((1, test_err, True), "killed"),
    ((1, test_err, False), "invalid"),
    ((1, src_err, True), "invalid"),
    ((1, src_err + test_err, True), "invalid"),
]
bad = [f"{args[:2]!r} -> {mt.classify(*args)}, want {want}" for args, want in cases if mt.classify(*args) != want]
sys.exit("\n".join(bad) if bad else 0)
PY
}
check "mutation-test: timeout, survived, killed and invalid outcomes" outcomes

exit $fail
