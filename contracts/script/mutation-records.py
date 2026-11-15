#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Whole records of slither-mutate and Necessist logs, for security-slow.sh and mutation-report.py.

A mutant or removed statement that spans several source lines spans several log lines, and only its last line carries
the outcome, so a line-by-line grep keeps only that last line. Each record here runs from its first line to the line
that ends with its outcome:

    slither-mutate  from "INFO:Slither-Mutate:[<mutator>] Line <n>: '" to " --> CAUGHT" or " --> UNCAUGHT"
    Necessist       from "<file>:<line>:<col>-<line>:<col>: `" to "` <outcome>" (passed, failed, timed-out, ...)

Usage:

    mutation-records.py survivors <log> [<prefix>]   each uncaught mutant, as "<prefix><record>"
    mutation-records.py necessist <log>              each removal that left the tests passing

Each record is printed on one line, so `wc -l` counts records: inside a record a backslash is written "\\\\" and a
newline "\\n", which keeps the text whole and exact. script/mutation-records.test.sh checks multi-line records.
"""

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


def main() -> int:
    if len(sys.argv) < 3 or sys.argv[1] not in ("survivors", "necessist"):
        print(__doc__, file=sys.stderr)
        return 2
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
