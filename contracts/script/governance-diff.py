#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Write the diff.md of a governance operation folder from its before.json and after.json.

The operation's fork test (contracts/test/governance/<Title>.fork.t.sol, run with FOUNDRY_PROFILE=governance) writes
before.json and after.json: the ParameterStore values, MarketRegistry state and role map read at the pinned block
before and after the operation executes through the AvanaTimelock. This script lists every leaf value that differs,
one row per JSON path, so a reviewer sees exactly what the operation changes.

Usage, from contracts/:  python3 script/governance-diff.py ../docs/governance/operations/<YYYYMMDD_Chain_Title>
Writes <folder>/diff.md; exits 1 if either JSON file is missing.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def flatten(node, path="", out=None):
    out = {} if out is None else out
    if isinstance(node, dict):
        for k in sorted(node):
            flatten(node[k], f"{path}.{k}" if path else k, out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            flatten(v, f"{path}[{i}]", out)
    else:
        out[path] = node
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    folder = Path(sys.argv[1])
    try:
        before = flatten(json.loads((folder / "before.json").read_text()))
        after = flatten(json.loads((folder / "after.json").read_text()))
    except FileNotFoundError as e:
        print(f"governance-diff: {e.filename} not found; run the operation's fork test first")
        return 1
    rows = []
    for key in sorted(set(before) | set(after)):
        b, a = before.get(key, "(absent)"), after.get(key, "(absent)")
        if b != a:
            rows.append(f"| `{key}` | `{json.dumps(b) if b != '(absent)' else b}` | `{json.dumps(a) if a != '(absent)' else a}` |")
    lines = [f"# {folder.name}: state change", ""]
    if rows:
        lines += ["| Path | Before | After |", "|---|---|---|", *rows]
    else:
        lines.append("The operation changes no recorded value.")
    (folder / "diff.md").write_text("\n".join(lines) + "\n")
    print(f"governance-diff: {len(rows)} changed value(s) written to {folder / 'diff.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
