#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""List the full-depth test units of the contracts a hotfix changes, as a JSON matrix for CI.

Reads the changed paths (relative to the repository root, one per line) on stdin. A changed file under contracts/src/
marks its folder; the folder's contracts are the base names of its .sol files. The units are every invariant
(`<file>::<invariant>`) of each test/invariant/ file whose name starts with one of those contract names, so a pull
request labelled `hotfix` runs the touched contracts' invariant campaigns at the full ci profile (10,000 runs at depth
100), one invariant per job, beside the usual short set (which already runs their unit and fuzz tests at 10,000 runs).

Usage, from contracts/:  git diff --name-only <base>...HEAD | script/hotfix-units.py
"""
import glob
import json
import os
import re
import sys

INVARIANT = re.compile(r"function\s+(invariant_\w+)\s*\(")


def main():
    names = set()
    for line in sys.stdin:
        path = line.strip()
        if not (path.startswith("contracts/src/") and path.endswith(".sol")):
            continue
        folder = os.path.dirname(path[len("contracts/") :])
        for f in glob.glob(os.path.join(folder, "*.sol")):
            names.add(os.path.basename(f)[: -len(".sol")])
    units = []
    for f in sorted(glob.glob("test/invariant/*.t.sol")):
        if os.path.basename(f).split(".")[0] not in names:
            continue
        with open(f) as fh:
            for inv in sorted(set(INVARIANT.findall(fh.read()))):
                units.append({"file": f, "invariant": inv})
    print(json.dumps(units))
    return 0


if __name__ == "__main__":
    sys.exit(main())
