#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Test depth per contract folder: non-comment, non-blank Solidity lines of tests per line of contract code.

Target: at least 6x per folder and repo-wide (the depth of Aave V4's own suite). Interfaces are not counted as
contract code. A test file belongs to the folder of the longest contract name its file name starts with
(`MarketRegistry.Routes.unit.t.sol` -> policy/market-registry). Shared fixtures and mocks in test/utils/ are
not counted. Report only by default; `--min X` exits 1 when the repo-wide ratio is below X.

Usage: script/check-test-depth.py [--min 6] [--folder policy/market-registry]
"""
import argparse
import collections
import glob
import os
import re
import sys

TARGET = 6.0


def code_lines(path):
    n, in_block = 0, False
    with open(path, errors="ignore") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if in_block:
                in_block = "*/" not in s
                continue
            if s.startswith("/*"):
                in_block = "*/" not in s
                continue
            if s.startswith("//") or s.startswith("*"):
                continue
            n += 1
    return n


def folder_of(path):
    parts = path.split("/")
    # The two LPVaults share their custody and market code in amm/concentrated-liquidity and are tested through
    # their integration contracts, so the AMM folders are measured together.
    if len(parts) > 2 and parts[1] == "amm":
        return "amm (LP vaults)"
    return "/".join(parts[1:3]) if len(parts) > 3 else parts[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=float, default=None)
    ap.add_argument("--folder", default=None)
    a = ap.parse_args()
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

    src, owner = collections.Counter(), {}
    for p in glob.glob("src/**/*.sol", recursive=True):
        name = os.path.basename(p)[:-4]
        if re.match(r"^I[A-Z]", name):
            continue
        src[folder_of(p)] += code_lines(p)
        owner[name] = folder_of(p)
    names = sorted(owner, key=len, reverse=True)

    tests, unmatched = collections.Counter(), 0
    for p in glob.glob("test/**/*.sol", recursive=True):
        if "/utils/" in p:
            continue
        base, n = os.path.basename(p), code_lines(p)
        hit = next((owner[c] for c in names if re.match(rf"^{re.escape(c)}[._A-Z]", base)), None)
        if hit:
            tests[hit] += n
        else:
            unmatched += n

    rows = [f for f in sorted(src, key=lambda f: -src[f]) if not a.folder or f == a.folder]
    print(f"{'folder':42} {'code':>6} {'tests':>7} {'ratio':>6} {'to 6x':>7}")
    for f in rows:
        r = tests[f] / src[f] if src[f] else 0.0
        print(f"{f:42} {src[f]:>6} {tests[f]:>7} {r:>6.1f} {max(0, round(TARGET * src[f]) - tests[f]):>7}")
    total_src, total_tests = sum(src.values()), sum(tests.values()) + unmatched
    ratio = total_tests / total_src if total_src else 0.0
    print(f"{'repo (incl. ' + str(unmatched) + ' unmatched test lines)':42} {total_src:>6} {total_tests:>7} {ratio:>6.1f}")
    if a.min is not None and ratio < a.min:
        sys.exit(1)


if __name__ == "__main__":
    main()
