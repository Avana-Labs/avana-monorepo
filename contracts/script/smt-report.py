#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Report the SMTChecker results of one target from a forge build's build-info files.

forge prints only errors and warnings; the model checker's results also come as info messages (a target proved safe),
which only the solc output in the build-info files keeps. Reads every <build>/build-info/*.json, takes each solc job
whose input holds <source>, and prints one line per model-checker message about that source (severity, error code,
line, message), then the counts. Exit status:
  1  no solc job compiled <source>, more than one did (the source would be analysed twice), the model checker reported
     that no solver ran (7649 CHC, 8158 BMC), it reported no result for <source> at all, or found a counterexample
  0  otherwise; unproved targets ("might happen here") are listed and counted, not failed

Usage, from contracts/:  script/smt-report.py <build dir> <source> [<summary file>]
"""
import glob
import json
import os
import sys

NO_SOLVER = {"7649", "8158"}


def line_of(text, offset):
    return text.count("\n", 0, max(offset, 0)) + 1


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    build, source = argv[0], argv[1]
    summary = argv[2] if len(argv) == 3 else None
    with open(source, encoding="utf8") as fh:
        text = fh.read()
    jobs = 0
    rows = []
    for path in sorted(glob.glob(os.path.join(build, "build-info", "*.json"))):
        with open(path, encoding="utf8") as fh:
            info = json.load(fh)
        if source not in info.get("input", {}).get("sources", {}):
            continue
        jobs += 1
        for e in info.get("output", {}).get("errors", []):
            msg, code = e.get("message", ""), str(e.get("errorCode", ""))
            loc = e.get("sourceLocation") or {}
            ours = loc.get("file") == source
            # Results about the source, and summary lines with no location (solc's per-job counts).
            if code in NO_SOLVER or ((ours or not loc.get("file")) and ("CHC" in msg or "BMC" in msg)):
                line = line_of(text, loc.get("start", -1)) if ours else 0
                rows.append((e.get("severity", "?"), code, line, msg.replace("\n", " ")))
    no_solver = [r for r in rows if r[1] in NO_SOLVER]
    cex = [r for r in rows if "happens here" in r[3] and "might happen" not in r[3]]
    unproved = [r for r in rows if "might happen here" in r[3]]
    safe = [r for r in rows if "is safe" in r[3] or "proved safe" in r[3]]
    chc = [r for r in rows if "CHC" in r[3]]
    out = [f"{sev} {code} {source}:{line}: {msg}" for sev, code, line, msg in rows]
    counts = (
        f"{source}: solc jobs {jobs}; CHC results {len(chc)}; proved safe {len(safe)}; unproved {len(unproved)}; "
        f"counterexamples {len(cex)}; solver missing {len(no_solver)}"
    )
    print("\n".join(out))
    print(counts)
    if summary:
        with open(summary, "a", encoding="utf8") as fh:
            fh.write(f"{counts}\n\n")
            if unproved or cex:
                fh.write("```\n" + "\n".join(o for o in out if "happen" in o) + "\n```\n")
    errors = []
    if jobs != 1:
        errors.append(f"{jobs} solc jobs compiled {source} (expected 1)")
    if no_solver:
        errors.append("solc found no solver (warning 7649 or 8158): nothing was checked")
    if not chc:
        errors.append(f"no CHC result for {source}: the model checker did not run on it")
    if cex:
        errors.append(f"{len(cex)} counterexample(s)")
    for e in errors:
        print(f"::error::{e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
