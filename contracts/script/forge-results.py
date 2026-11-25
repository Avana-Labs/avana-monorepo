#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Counts of a run's results, read from `forge test --json-file` output.

Usage, from contracts/:  script/forge-results.py --counts <file.json>...   prints "<passed> <skipped> <failed>"
                         script/forge-results.py <file.json>...            prints one line per test and the totals

A file that is missing or empty counts as no result. The fork job uses the counts to tell a run in which every test
skipped (pinned block 0, no RPC) from one that ran.
"""
import json
import sys
from pathlib import Path


def results(paths):
    for p in paths:
        path = Path(p)
        if not path.is_file() or not path.stat().st_size:
            continue
        data = json.loads(path.read_text())
        for suite, body in data.items():
            for name, r in (body.get("test_results") or {}).items():
                yield suite, name, (r or {}).get("status", "")


def main(argv):
    counts = "--counts" in argv
    paths = [a for a in argv if a != "--counts"]
    n = {"Success": 0, "Skipped": 0, "Failure": 0}
    for suite, name, status in results(paths):
        n[status] = n.get(status, 0) + 1
        if not counts:
            print(f"{status:8} {suite}.{name}")
    if counts:
        print(n["Success"], n["Skipped"], n["Failure"])
    else:
        print(f"passed {n['Success']}, skipped {n['Skipped']}, failed {n['Failure']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
