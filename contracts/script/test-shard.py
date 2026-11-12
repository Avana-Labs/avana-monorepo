#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Split the Foundry suite into N shards of about equal run time.

The units are every test file under test/ (fork and differential excluded, as in the default profile). A file of
test/invariant/ is one invariant campaign: Foundry runs all invariants of a test contract in one campaign of
runs x depth handler calls, checking each invariant after every call, so the calls, not the invariants, take the time;
running each invariant on its own (`--match-test`) would repeat the whole campaign once per invariant. A campaign whose
measured time is above SEGMENT_SECONDS is split into m segments `<file>@<k>/<m>`: each runs ceil(runs / m) of the
campaign's runs at the same depth, with its own seed, so together they run at least the campaign's runs at its depth,
and each fits in a shard. A file's weight is its measured CPU time in script/test-timings.json (measured at the ci
profile); a file with no entry (a new file) weighs the median of the known files of its kind. When
FOUNDRY_INVARIANT_RUNS or FOUNDRY_INVARIANT_DEPTH lowers the invariant work (the short check on a pull request), the
invariant units are scaled by the ratio of runs x depth to the ci profile's 10,000 x 100. Units are taken heaviest
first and each goes to the shard with the least total so far (ties to the lower shard number), so the split is
deterministic and every unit lands in exactly one shard.

Usage, from contracts/:
  script/test-shard.py <K> <N>            print shard K's units, one per line
  script/test-shard.py --summary <N>      print each shard's unit count and estimated seconds
  script/test-shard.py --runs             print the invariant runs of the active profile (FOUNDRY_INVARIANT_RUNS, else
                                          foundry.toml's [profile.<FOUNDRY_PROFILE>.invariant] runs, else default's)
"""
import json
import math
import os
import re
import statistics
import sys

TIMINGS = os.path.join("script", "test-timings.json")
CI_INVARIANT_WORK = 10_000 * 100  # runs x depth of the ci profile the timings were measured at
# A campaign above 30 minutes of measured CPU time is split, so every unit leaves room in a 60-minute shard.
SEGMENT_SECONDS = 1800


def is_inv(f):
    return f.startswith("test/invariant/")


def test_files():
    out = []
    for root, _dirs, files in os.walk("test"):
        if root.startswith(("test/fork", "test/differential")):
            continue
        out += [os.path.join(root, f) for f in files if f.endswith(".t.sol")]
    return sorted(out)


def profile_runs():
    """Invariant runs of the active profile: FOUNDRY_INVARIANT_RUNS, else [profile.<FOUNDRY_PROFILE>.invariant] runs in
    foundry.toml, else [profile.default.invariant] runs."""
    if os.environ.get("FOUNDRY_INVARIANT_RUNS"):
        return int(os.environ["FOUNDRY_INVARIANT_RUNS"])
    with open("foundry.toml") as fh:
        toml = fh.read()
    for profile in (os.environ.get("FOUNDRY_PROFILE", "default"), "default"):
        m = re.search(r"^\[profile\." + re.escape(profile) + r"\.invariant\]\n(?:(?!^\[).*\n)*?runs\s*=\s*([\d_]+)", toml, re.M)
        if m:
            return int(m.group(1).replace("_", ""))
    raise SystemExit("test-shard: no invariant runs in foundry.toml")


def units():
    """Every unit with its weight in seconds."""
    files = test_files()
    try:
        with open(TIMINGS) as fh:
            known = json.load(fh)
    except FileNotFoundError:
        known = {}
    defaults = {}
    for kind in (True, False):
        seen = [known[f] for f in files if f in known and is_inv(f) == kind]
        defaults[kind] = statistics.median(seen) if seen else 1.0
    runs = int(os.environ.get("FOUNDRY_INVARIANT_RUNS", 10_000))
    depth = int(os.environ.get("FOUNDRY_INVARIANT_DEPTH", 100))
    scale = min(1.0, runs * depth / CI_INVARIANT_WORK)
    out = {}
    for f in files:
        w = float(known.get(f, defaults[is_inv(f)]))
        if not is_inv(f):
            out[f] = w
            continue
        w *= scale
        m = max(1, math.ceil(w / SEGMENT_SECONDS))
        if m == 1:
            out[f] = w
        else:
            for k in range(1, m + 1):
                out[f"{f}@{k}/{m}"] = w / m
    return out


def shards(n):
    weight = units()
    loads = [0.0] * n
    assigned = [[] for _ in range(n)]
    for u in sorted(weight, key=lambda u: (-weight[u], u)):
        k = min(range(n), key=lambda i: (loads[i], i))
        loads[k] += weight[u]
        assigned[k].append(u)
    return [sorted(a) for a in assigned], loads


def main(argv):
    if argv == ["--runs"]:
        print(profile_runs())
        return 0
    if len(argv) == 2 and argv[0] == "--summary":
        n = int(argv[1])
        assigned, loads = shards(n)
        for k in range(n):
            print(f"shard {k + 1}: {len(assigned[k])} units, about {loads[k]:.0f} s")
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
