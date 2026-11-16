#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Group the hevm targets of the slow tier into N batches of about equal run time, one CI job each.

Reads the legs of `script/ci-shards.py hevm <build>` on stdin ({"target": ..., "id": ...} each) and prints N legs
{"batch": "<k>", "targets": "<target> <target> ...", "id": "batch-<k>"}; HEVM_TARGETS takes the targets string. A
target's weight is its seconds in script/hevm-timings.json (the job times of run 43677588077, one job per target, each
capped at 7,200 s: the entry points that ran longer, CollateralizationProperties.pledge, RiskModuleProperties.charge and
an AvanaTimelockProperties entry point, now end at HEVM_ENTRY_TIMEOUT); a target with no entry weighs the median.
Targets are taken heaviest first and each goes to the batch with the least total so far (ties to the lower batch),
so the split is deterministic and every target lands in exactly one batch. A batch with no target is left out.

Usage, from contracts/:  script/ci-shards.py hevm <build> | script/hevm-batches.py <N>
"""
import json
import os
import statistics
import sys

TIMINGS = os.path.join("script", "hevm-timings.json")


def main(argv):
    if len(argv) != 1 or not argv[0].isdigit() or int(argv[0]) < 1:
        print(__doc__, file=sys.stderr)
        return 2
    n = int(argv[0])
    targets = [leg["target"] for leg in json.load(sys.stdin)]
    with open(TIMINGS, encoding="utf8") as fh:
        known = json.load(fh)
    default = statistics.median(known.values()) if known else 1
    weight = {t: known.get(t, default) for t in targets}
    loads = [0.0] * n
    batches = [[] for _ in range(n)]
    for t in sorted(targets, key=lambda t: (-weight[t], t)):
        k = min(range(n), key=lambda i: (loads[i], i))
        loads[k] += weight[t]
        batches[k].append(t)
    legs = []
    for k, batch in enumerate(batches, start=1):
        if batch:
            legs.append({"batch": str(k), "targets": " ".join(sorted(batch)), "id": f"batch-{k}"})
            print(f"hevm batch {k}: {len(batch)} targets, about {loads[k - 1] / 3600:.1f} h", file=sys.stderr)
    print(json.dumps(legs, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
