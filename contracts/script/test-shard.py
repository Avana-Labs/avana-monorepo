#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Split the Foundry suite into N shards of about equal run time.

Every test file under test/ (fork and differential excluded, as in the default profile) is weighted by its measured
CPU time in script/test-timings.json (measured at the ci profile); a file with no entry (a new file) weighs the median of
the known files of its kind (invariant suites apart from the rest, since one invariant suite can outweigh a hundred
unit files). When FOUNDRY_INVARIANT_RUNS or FOUNDRY_INVARIANT_DEPTH lowers the invariant work (the short check on a
pull request), files under test/invariant/ are scaled by the ratio of runs x depth to the ci profile's 10,000 x 100.
Files are taken heaviest first and each goes to the shard with the least total so far (ties to the lower shard number),
so the split is deterministic and every file lands in exactly one shard.

Usage, from contracts/:
  script/test-shard.py <K> <N>            print shard K's files, one per line
  script/test-shard.py --summary <N>      print each shard's file count and estimated seconds
"""
import json
import os
import statistics
import sys

TIMINGS = os.path.join("script", "test-timings.json")
CI_INVARIANT_WORK = 10_000 * 100  # runs x depth of the ci profile the timings were measured at


def test_files():
    out = []
    for root, _dirs, files in os.walk("test"):
        if root.startswith(("test/fork", "test/differential")):
            continue
        out += [os.path.join(root, f) for f in files if f.endswith(".t.sol")]
    return sorted(out)


def shards(n):
    files = test_files()
    try:
        with open(TIMINGS) as fh:
            known = json.load(fh)
    except FileNotFoundError:
        known = {}
    def is_inv(f):
        return f.startswith("test/invariant/")

    defaults = {}
    for kind in (True, False):
        seen = [known[f] for f in files if f in known and is_inv(f) == kind]
        defaults[kind] = statistics.median(seen) if seen else 1.0
    weight = {f: float(known.get(f, defaults[is_inv(f)])) for f in files}
    runs = int(os.environ.get("FOUNDRY_INVARIANT_RUNS", 10_000))
    depth = int(os.environ.get("FOUNDRY_INVARIANT_DEPTH", 100))
    scale = min(1.0, runs * depth / CI_INVARIANT_WORK)
    for f in files:
        if f.startswith("test/invariant/"):
            weight[f] *= scale
    loads = [0.0] * n
    assigned = [[] for _ in range(n)]
    for f in sorted(files, key=lambda f: (-weight[f], f)):
        k = min(range(n), key=lambda i: (loads[i], i))
        loads[k] += weight[f]
        assigned[k].append(f)
    return [sorted(a) for a in assigned], loads


def main(argv):
    if len(argv) == 2 and argv[0] == "--summary":
        n = int(argv[1])
        assigned, loads = shards(n)
        for k in range(n):
            print(f"shard {k + 1}: {len(assigned[k])} files, about {loads[k]:.0f} s")
        return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    k, n = int(argv[0]), int(argv[1])
    if not 1 <= k <= n:
        print(f"shard {k} is outside 1..{n}", file=sys.stderr)
        return 2
    assigned, _ = shards(n)
    print("\n".join(assigned[k - 1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
