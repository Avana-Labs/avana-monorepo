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
SEGMENT = re.compile(r"invariant campaign segment: (test/\S+?\.t\.sol), part \d+ of (\d+)")
SCALE = {"s": 1.0, "ms": 1e-3, "µs": 1e-6, "ns": 1e-9}


def parse(path):
    """(whole-file times, segment times): a suite run under script/test-shard.sh's `invariant campaign segment: <file>,
    part k of m` header is one segment of m, recorded as (seconds, m)."""
    times, segments, current, seg_of = {}, {}, None, None
    with open(path, errors="replace") as fh:
        for line in fh:
            m = SEGMENT.search(line)
            if m:
                seg_of = (m.group(1), int(m.group(2)))
                continue
            m = RAN.search(line)
            if m:
                current = m.group(1)
                continue
            m = RESULT.search(line)
            if m and current:
                t = float(m.group(1)) * SCALE[m.group(2)]
                if seg_of and seg_of[0] == current:
                    segments.setdefault(current, []).append((t, seg_of[1]))
                else:
                    times[current] = times.get(current, 0.0) + t
                current = None
    return times, segments


def main(paths):
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        with open(TIMINGS) as fh:
            timings = json.load(fh)
    except FileNotFoundError:
        timings = {}
    measured, segments = {}, {}
    for p in paths:
        times, segs = parse(p)
        for f, t in times.items():
            measured[f] = measured.get(f, 0.0) + t
        for f, s in segs.items():
            segments.setdefault(f, []).extend(s)
    # A segmented campaign weighs the mean of its finished segments times its segment count, so a segment that was
    # cancelled (its shard timed out) does not shrink the campaign's weight.
    for f, s in segments.items():
        measured[f] = sum(t for t, _ in s) / len(s) * s[0][1]
    timings.update({f: round(t, 1) for f, t in measured.items()})
    timings = {f: t for f, t in sorted(timings.items()) if os.path.exists(f)}
    with open(TIMINGS, "w", newline="\n") as fh:
        json.dump(timings, fh, indent=2)
        fh.write("\n")
    print(f"{len(measured)} files measured, {len(timings)} recorded in {TIMINGS}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
