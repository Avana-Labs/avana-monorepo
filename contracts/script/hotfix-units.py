#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""List the full-depth test units of the contracts a hotfix changes, as a JSON matrix for CI.

Reads the changed paths (relative to the repository root, one per line) on stdin. A changed file under contracts/src/
marks its folder; the folder's contracts are the base names of its .sol files. The units are the invariant campaigns
of each test/invariant/ file whose name starts with one of those contract names, as script/test-shard.py splits them
at the ci profile (a file, or `<file>@<k>/<m>` segments of a campaign longer than SEGMENT_SECONDS), so a pull request
labelled `hotfix` runs the touched contracts' invariant campaigns at the full ci profile (10,000 runs at depth 100),
one unit per job (`script/test-shard.sh --unit`), beside the usual short set (which already runs their unit and fuzz
tests at 10,000 runs).

Usage, from contracts/:  git diff --name-only <base>...HEAD | FOUNDRY_PROFILE=ci script/hotfix-units.py
"""
import glob
import importlib.util
import json
import os
import sys


def shard_units():
    spec = importlib.util.spec_from_file_location("test_shard", os.path.join("script", "test-shard.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.units()


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
    for unit in sorted(shard_units()):
        f = unit.split("@")[0]
        if f.startswith("test/invariant/") and os.path.basename(f).split(".")[0] in names:
            units.append({"unit": unit})
    print(json.dumps(units))
    return 0


if __name__ == "__main__":
    sys.exit(main())
