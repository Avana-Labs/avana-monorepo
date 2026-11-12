#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Per-file branch-coverage gate of src/, read from a `forge coverage --report lcov` file.

    coverage-gate.py <lcov.info> --config security/coverage-thresholds.json [--update] [--summary <file>]

Config (JSON):

    {
      "target": 80,
      "files": {"src/lock/lock/Lock.sol": 100, ...}
    }

Every file under src/ that has at least one branch in the lcov report needs an entry in `files`, its minimum branch
coverage in whole percent. A file fails when its measured branch coverage (branches hit / branches found, in percent)
is below its minimum; a file with branches but no entry fails too, so every file with branches has a minimum. An
entry naming a file without branches in the report fails, so no entry outlives its file. Minimums never
exceed 100 and are whole numbers. The gate prints each file with its measured value, its minimum, and whether the
minimum is below `target`.

--update rewrites `files`: a file without an entry gets the measured value rounded down; an existing minimum is raised
to the measured value rounded down when that is higher and is never lowered; entries of files without branches are
removed. Run it after adding tests, review the diff, and commit it.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read_lcov(path: Path) -> dict[str, tuple[int, int]]:
    """{source file: (branches found, branches hit)} for files under src/."""
    out: dict[str, tuple[int, int]] = {}
    current = None
    found = hit = 0
    for raw in path.read_text(encoding="utf8").splitlines():
        if raw.startswith("SF:"):
            current = raw[3:].strip()
            if current.startswith(str(ROOT) + "/"):
                current = current[len(str(ROOT)) + 1 :]
            found = hit = 0
        elif raw.startswith("BRF:"):
            found = int(raw[4:])
        elif raw.startswith("BRH:"):
            hit = int(raw[4:])
        elif raw == "end_of_record" and current is not None:
            if current.startswith("src/"):
                f, h = out.get(current, (0, 0))
                out[current] = (f + found, h + hit)
            current = None
    return out


def percent(found: int, hit: int) -> float:
    return 100.0 * hit / found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("lcov", type=Path)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()

    measured = {f: v for f, v in read_lcov(args.lcov).items() if v[0] > 0}
    if not measured:
        print("coverage-gate: the lcov report holds no branch of a src/ file", file=sys.stderr)
        return 1
    config = json.loads(args.config.read_text(encoding="utf8")) if args.config.exists() else {}
    target = int(config.get("target", 80))
    minimums: dict[str, int] = dict(config.get("files", {}))

    if args.update:
        updated = {}
        for f, (found, hit) in sorted(measured.items()):
            floor = math.floor(percent(found, hit))
            updated[f] = max(floor, minimums.get(f, floor))
        config["target"] = target
        config["files"] = updated
        args.config.write_text(json.dumps(config, indent=2) + "\n", encoding="utf8")
        minimums = updated
        print(f"coverage-gate: wrote {len(updated)} minimum(s) to {args.config}")

    lines = [f"branch coverage of src/ (minimum per file; target {target} %)"]
    failures = 0
    for f in sorted(set(measured) | set(minimums)):
        if f not in measured:
            lines.append(f"  FAIL  {f}: listed with minimum {minimums[f]} % but has no branch in the report")
            failures += 1
            continue
        found, hit = measured[f]
        value = percent(found, hit)
        if f not in minimums:
            lines.append(f"  FAIL  {f}: {value:6.2f} % ({hit}/{found}), no minimum listed in {args.config}")
            failures += 1
            continue
        minimum = minimums[f]
        if not isinstance(minimum, int) or not 0 <= minimum <= 100:
            lines.append(f"  FAIL  {f}: minimum {minimum!r} is not a whole percent between 0 and 100")
            failures += 1
            continue
        below = "  (minimum below target)" if minimum < target else ""
        if value + 1e-9 < minimum:
            lines.append(f"  FAIL  {f}: {value:6.2f} % ({hit}/{found}) < minimum {minimum} %{below}")
            failures += 1
        else:
            lines.append(f"  ok    {f}: {value:6.2f} % ({hit}/{found}) >= minimum {minimum} %{below}")
    total_found = sum(v[0] for v in measured.values())
    total_hit = sum(v[1] for v in measured.values())
    lines.append(f"total: {percent(total_found, total_hit):.2f} % ({total_hit}/{total_found}) over {len(measured)} file(s)")
    lines.append(f"coverage-gate: {'FAIL' if failures else 'pass'} ({failures} failing file(s))")
    text = "\n".join(lines)
    print(text)
    if args.summary:
        args.summary.write_text(text + "\n", encoding="utf8")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
