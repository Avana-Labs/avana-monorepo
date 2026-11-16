#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Whole records of slither-mutate and Necessist logs, for security-slow.sh and mutation-report.py.

A mutant or removed statement that spans several source lines spans several log lines, and only its last line carries
the outcome, so a line-by-line grep keeps only that last line. Each record here runs from its first line to the line
that ends with its outcome:

    slither-mutate  from "INFO:Slither-Mutate:[<mutator>] Line <n>: '" to " --> CAUGHT" or " --> UNCAUGHT"
    Necessist       from "<file>:<line>:<col>-<line>:<col>: `" to "` <outcome>" (passed, failed, timed-out, ...)

Gambit's mutants.log is CSV whose original and replacement fields may span several lines (a quoted field holding a
newline), so it is never read line by line: the mutants come from gambit_results.json, read with a JSON parser.

Usage:

    mutation-records.py survivors <log> [<prefix>]   each uncaught mutant, as "<prefix><record>"
    mutation-records.py necessist <log>              each removal that left the tests passing
    mutation-records.py gambit <gambit outdir>       each Gambit mutant, as "<id>\\t<mutant file>\\t<record>": the
                                                     mutated file's path relative to the outdir, and "<id>,<operator>,
                                                     <file>,line <n>,<original>,<replacement>" from the mutant's diff

Each record is printed on one line, so `wc -l` counts records: inside a record a backslash is written "\\\\" and a
newline "\\n", which keeps the text whole and exact. script/mutation-records.test.sh checks multi-line records.
"""

import json
import re
import sys
from pathlib import Path
from typing import Iterator

MUTANT_START = re.compile(r"INFO:Slither-Mutate:\[\w+\] Line \d+: '")
MUTANT_END = re.compile(r" --> (?:UN)?CAUGHT$")
MUTANT = re.compile(r"INFO:Slither-Mutate:\[(\w+)\] Line (\d+): '(.*)' ==> '(.*)' --> UNCAUGHT$", re.S)

NECESSIST_START = re.compile(r"\S+:\d+:\d+-\d+:\d+: `")
NECESSIST_END = re.compile(r"` (?:passed|failed|timed-out|nonbuildable|skipped|inconclusive)$")
NECESSIST_PASSED = re.compile(r"(\S+:\d+:\d+-\d+:\d+): `(.*)` passed$", re.S)


def records(text: str, start: re.Pattern, end: re.Pattern) -> Iterator[str]:
    """Each record of `text` from a line matching `start` to the first line, that one included, ending with `end`.
    A new start line drops an unfinished record."""
    cur = None
    for line in text.splitlines():
        if start.match(line):
            cur = line
        elif cur is None:
            continue
        else:
            cur += "\n" + line
        if end.search(line):
            yield cur
            cur = None


def uncaught(text: str) -> list[tuple[str, str, str, str, str]]:
    """(record, mutator, line, original, mutant) of each uncaught slither-mutate mutant."""
    out = []
    for rec in records(text, MUTANT_START, MUTANT_END):
        m = MUTANT.match(rec)
        if m:
            out.append((rec, *m.groups()))
    return out


def necessist_passed(text: str) -> list[tuple[str, str, str]]:
    """(record, location, statement) of each Necessist removal that left the tests passing."""
    out = []
    for rec in records(text, NECESSIST_START, NECESSIST_END):
        m = NECESSIST_PASSED.match(rec)
        if m:
            out.append((rec, *m.groups()))
    return out


def one_line(record: str) -> str:
    return record.replace("\\", "\\\\").replace("\n", "\\n")


def diff_lines(diff: str) -> tuple[int | None, str, str]:
    """First original line number, original lines and mutated lines of a Gambit diff, each line whitespace-normalized;
    the `///` comment Gambit adds above each mutated line is dropped."""
    old: list[str] = []
    new: list[str] = []
    line: int | None = None
    first: int | None = None
    for raw in diff.splitlines():
        if raw.startswith("@@"):
            m = re.match(r"@@ -(\d+)", raw)
            line = int(m.group(1)) if m else None
        elif raw.startswith(("---", "+++")):
            continue
        elif raw.startswith("-"):
            old.append(" ".join(raw[1:].split()))
            if first is None:
                first = line
            line = line + 1 if line is not None else None
        elif raw.startswith("+"):
            text = " ".join(raw[1:].split())
            if not text.startswith("///"):
                new.append(text)
        elif line is not None:
            line += 1
    return first, " ".join(old), " ".join(new)


def gambit_mutants(outdir: Path) -> list[dict]:
    """Each mutant of a Gambit outdir, from its gambit_results.json: `id`, `path` (the mutated file, relative to the
    outdir), `operator`, `file`, `line`, `original` and `replacement` (from the diff). Raises SystemExit when the file
    is missing or malformed, or an entry lacks its id or file, so a caller never runs a mutant it could not name."""
    results = outdir / "gambit_results.json"
    try:
        entries = json.loads(results.read_text(encoding="utf8"))
    except (OSError, ValueError) as e:
        raise SystemExit(f"mutation-records: cannot read {results}: {e}")
    if not isinstance(entries, list):
        raise SystemExit(f"mutation-records: {results} is not a list of mutants")
    out = []
    for e in entries:
        mid, path = str(e.get("id", "")), str(e.get("name", ""))
        if not re.fullmatch(r"\d+", mid) or not path or "\t" in path or "\n" in path:
            raise SystemExit(f"mutation-records: malformed mutant entry in {results}: {e!r}")
        line, old, new = diff_lines(str(e.get("diff", "")))
        out.append(
            {
                "id": mid,
                "path": path,
                "operator": str(e.get("description", "")),
                "file": str(e.get("original", "")),
                "line": line,
                "original": old,
                "replacement": new,
            }
        )
    return out


def gambit_record(m: dict) -> str:
    return one_line(f"{m['id']},{m['operator']},{m['file']},line {m['line']},{m['original']},{m['replacement']}")


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] not in ("survivors", "necessist", "gambit"):
        print(__doc__, file=sys.stderr)
        return 2
    if sys.argv[1] == "gambit":
        for m in gambit_mutants(Path(sys.argv[2])):
            print(f"{m['id']}\t{m['path']}\t{gambit_record(m)}")
        return 0
    text = Path(sys.argv[2]).read_text(encoding="utf8", errors="replace")
    if sys.argv[1] == "survivors":
        prefix = sys.argv[3] if len(sys.argv) > 3 else ""
        rows = [prefix + one_line(r[0]) for r in uncaught(text)]
    else:
        rows = [one_line(r[0]) for r in necessist_passed(text)]
    for row in rows:
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
