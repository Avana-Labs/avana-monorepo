#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Test depth per contract folder: non-comment, non-blank Solidity lines of tests per line of contract code.

Target: at least 6x per folder and repo-wide (the depth of Aave V4's own suite); the Lens folder 2x (TARGETS).
Interfaces are not counted as contract code. A test file belongs to the folder of the longest contract name its file
name starts with (`MarketRegistry.Routes.unit.t.sol` -> policy/market-registry). Shared fixtures and mocks in
test/utils/ are not counted. The ratio counts lines, not assertions: it shows where tests are thin, not that they are
strong (mutation testing does that).

Report only by default; CI runs `--enforce`, which exits 1 when a folder is below its target and is not in EXEMPT
(each entry with its reason; none today). `--min X` exits 1 when the repo-wide ratio is below X. `--markdown` prints the table as Markdown with a
verdict per folder, for a CI job summary.

Usage: script/check-test-depth.py [--min 6] [--folder policy/market-registry] [--enforce] [--markdown]
"""
import argparse
import collections
import glob
import os
import re
import sys

TARGET = 6.0
# Folders with a target other than TARGET.
TARGETS = {"lens/lens": 2.0}
# Folders the target does not apply to: folder -> reason. Empty: every folder is measured (decided 2026-11-12).
EXEMPT: dict = {}


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
    ap.add_argument("--enforce", action="store_true", help="exit 1 on a folder below its target and not exempt")
    ap.add_argument("--markdown", action="store_true", help="print a Markdown table with a verdict per folder")
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
    below = []
    out = []
    if a.markdown:
        out += ["### Test depth (test lines per contract line)", "",
                "| Folder | Code | Tests | Ratio | Target | Verdict |", "|---|---:|---:|---:|---:|---|"]
    else:
        out.append(f"{'folder':42} {'code':>6} {'tests':>7} {'ratio':>6} {'target':>6} {'to target':>9}  verdict")
    for f in rows:
        r = tests[f] / src[f] if src[f] else 0.0
        t = TARGETS.get(f, TARGET)
        if f in EXEMPT:
            verdict = f"exempt: {EXEMPT[f]}"
        elif r + 1e-9 >= t:
            verdict = "meets target"
        else:
            verdict = "BELOW TARGET"
            below.append(f)
        gap = max(0, round(t * src[f]) - tests[f])
        if a.markdown:
            out.append(f"| {f} | {src[f]} | {tests[f]} | {r:.1f} | {t:.0f}x | {verdict} |")
        else:
            out.append(f"{f:42} {src[f]:>6} {tests[f]:>7} {r:>6.1f} {t:>5.0f}x {gap:>9}  {verdict}")
    total_src, total_tests = sum(src.values()), sum(tests.values()) + unmatched
    ratio = total_tests / total_src if total_src else 0.0
    label = f"repo (incl. {unmatched} unmatched test lines)"
    if a.markdown:
        out.append(f"| {label} | {total_src} | {total_tests} | {ratio:.1f} | {TARGET:.0f}x | "
                   f"{'meets target' if ratio >= TARGET else 'BELOW TARGET'} |")
        out += ["", f"{len(below)} of {len(rows)} folders below their target"
                + (f": {', '.join(below)}." if below else ".")
                + (" Enforced." if a.enforce else " Report only (not enforced).")]
    else:
        out.append(f"{label:42} {total_src:>6} {total_tests:>7} {ratio:>6.1f}")
        out.append(f"{len(below)} of {len(rows)} folders below their target"
                   + (f": {', '.join(below)}" if below else "") + ("" if a.enforce else " (report only)"))
    print("\n".join(out))
    if a.min is not None and ratio < a.min:
        sys.exit(1)
    if a.enforce and below:
        sys.exit(1)


if __name__ == "__main__":
    main()
