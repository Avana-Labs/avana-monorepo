#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Record each test file's CPU time from `forge test` output into script/test-timings.json.

Reads one or more `forge test` logs (for example the ten `tests (ci profile, shard K/10)` job logs), sums the CPU time
of every suite of a file, and merges the result into script/test-timings.json: files in the logs get their new time,
other files keep theirs, and files that no longer exist are dropped. script/test-shard.py reads the file to balance the
shards.

Usage, from contracts/:  script/update-test-timings.py <log>...
"""
import json
import os
import re
import sys

TIMINGS = os.path.join("script", "test-timings.json")
RAN = re.compile(r"Ran \d+ tests? for (test/\S+?\.t\.sol):\S+")
RESULT = re.compile(r"Suite result: .*?finished in [^(]*\(([\d.]+)(ms|s|µs|ns) CPU time\)")
SCALE = {"s": 1.0, "ms": 1e-3, "µs": 1e-6, "ns": 1e-9}


def parse(path):
    times, current = {}, None
    with open(path, errors="replace") as fh:
        for line in fh:
            m = RAN.search(line)
            if m:
                current = m.group(1)
                continue
            m = RESULT.search(line)
            if m and current:
                times[current] = times.get(current, 0.0) + float(m.group(1)) * SCALE[m.group(2)]
                current = None
    return times


def main(paths):
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        with open(TIMINGS) as fh:
            timings = json.load(fh)
    except FileNotFoundError:
        timings = {}
    measured = {}
    for p in paths:
        for f, t in parse(p).items():
            measured[f] = measured.get(f, 0.0) + t
    timings.update({f: round(t, 1) for f, t in measured.items()})
    timings = {f: t for f, t in sorted(timings.items()) if os.path.exists(f)}
    with open(TIMINGS, "w") as fh:
        json.dump(timings, fh, indent=2)
        fh.write("\n")
    print(f"{len(measured)} files measured, {len(timings)} recorded in {TIMINGS}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
