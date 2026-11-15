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
#   3. mutation-report.py lists the multi-line survivor and removal with their first and last lines.
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

# mutation-report.py on a run of one slither-mutate job and one Necessist job.
mkdir -p "$TMP/art/mutate-2.1-Foo-1/2.1" "$TMP/art/necessist-2.1-Foo.t/"
cp "$TMP/mutate.log" "$TMP/art/mutate-2.1-Foo-1/2.1/Foo.log"
cp "$TMP/necessist.log" "$TMP/art/necessist-2.1-Foo.t/2.1.log"
cat >"$TMP/jobs.json" <<'JSON'
{"jobs": [
  {"name": "mutate 2.1 Foo (group 1)", "status": "completed", "conclusion": "success"},
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

exit $fail
