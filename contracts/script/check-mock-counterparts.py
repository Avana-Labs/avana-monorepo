#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Every mocked external has a fork test on the chain where it runs (TEST-005).

script/mock-counterparts.json lists each external Avana's unit tests may mock (Chainlink aggregators and the Base
sequencer-uptime feed, each AMM integration's position manager, factory and pools, the Aave V3 Pool behind the core
flash source and the flash liquidation helper, the GSM, the PSM, the swap-route pools), the mocks of it under
contracts/test (`<path>:<Contract>`), and, per chain, the fork tests (TEST rows) any one of which covers it.

The script fails (exit 1) when
  - a contract under contracts/test (fork/ excepted) defines a function of a listed external (`latestRoundData`,
    `positions`, `slot0`, `flashLoan`, `getIsSeized`, `buyGem`, `exchange`, ...) and the registry lists it neither as a
    mock of an external nor under "not_external" with its reason;
  - a registry entry names a contract that no longer exists;
  - an external with at least one mock, or one a test fakes with `vm.mockCall` on such a function, has on some chain
    of its entry no fork test: a Foundry test function under contracts/test/fork/ whose name carries `TEST_NNN` for
    one of the listed rows, with its own `TEST-NNN verifies:` tag directly above it (evidence.scan_tags), and whose
    body, or else its file, reads that chain's RPC variable (RPC_MAINNET, RPC_BASE).

Usage, from the repository root:  python3 contracts/script/check-mock-counterparts.py [--markdown]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "docs" / "spec" / "05-verification"))
import evidence as ev  # noqa: E402  (tag placement and own-row rule of the traceability tools)
import trace as tr  # noqa: E402  (docs/spec/05-verification/trace.py, first on the path; its main() is guarded)

TEST = ROOT / "contracts" / "test"
FORK = TEST / "fork"
REGISTRY = Path(__file__).resolve().parent / "mock-counterparts.json"
DECL = re.compile(r"^\s*(?:abstract\s+)?(contract|library|interface)\s+(\w+)")
FN = re.compile(r"^\s*function\s+(\w+)\s*\(")


def declarations() -> dict[str, set[str]]:
    """`<path>:<Contract>` -> the functions it defines, for every contract under contracts/test outside fork/."""
    out: dict[str, set[str]] = {}
    for path in sorted(TEST.rglob("*.sol")):
        if FORK in path.parents:
            continue
        rel = str(path.relative_to(TEST))
        current = None
        for line in ev._strip_comments(path.read_text(errors="ignore")).splitlines():
            d = DECL.match(line)
            if d:
                current = f"{rel}:{d.group(2)}" if d.group(1) == "contract" else None
                if current:
                    out.setdefault(current, set())
                continue
            f = FN.match(line)
            if f and current:
                out[current].add(f.group(1))
    return out


def mock_calls(functions: dict[str, str]) -> dict[str, list[str]]:
    """External -> `<path>:vm.mockCall(<fn>)` for every vm.mockCall on a function of that external."""
    out: dict[str, list[str]] = {}
    for path in sorted(TEST.rglob("*.sol")):
        if FORK in path.parents:
            continue
        code = ev._strip_comments(path.read_text(errors="ignore"))
        for m in re.finditer(r"vm\.mockCall\s*\((.*?)\)\s*;", code, re.S):
            for fn in set(re.findall(r"\b(\w+)\s*(?:\.selector|\()", m.group(1))) & set(functions):
                out.setdefault(functions[fn], []).append(f"{path.relative_to(TEST)}:vm.mockCall({fn})")
    return out


def _body(lines: list[str], i: int) -> str:
    depth, out, started = 0, [], False
    for line in lines[i:]:
        out.append(line)
        depth += line.count("{") - line.count("}")
        started = started or "{" in line
        if started and depth <= 0:
            break
    return "\n".join(out)


def fork_tests(chains: dict[str, str]) -> dict[str, list[tuple[str, str]]]:
    """TEST id -> (chain, `<file>:<function>`) of every counting fork test of it."""
    out: dict[str, list[tuple[str, str]]] = {}
    on, _ = ev.scan_tags(tr.TARGET)
    for tag in on:
        if tag["kind"] != "foundry" or tag["excluded"] or not tag["file"].startswith("test/fork/"):
            continue
        path = ev.CONTRACTS / tag["file"]
        text = ev._strip_comments(path.read_text(errors="ignore"))
        lines = text.splitlines()
        i = next((k for k, ln in enumerate(lines) if re.match(rf"^\s*function\s+{tag['fn']}\s*\(", ln)), None)
        body = _body(lines, i) if i is not None else ""
        for chain, var in chains.items():
            if var in body or (not any(v in body for v in chains.values()) and var in text):
                out.setdefault(tag["check"], []).append((chain, f"{tag['file'][5:]}:{tag['fn']}"))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--markdown", action="store_true", help="print the result as a Markdown table")
    args = ap.parse_args()
    reg = json.loads(REGISTRY.read_text())
    chains, externals, exempt = reg["chains"], reg["externals"], reg.get("not_external", {})
    decls = declarations()
    functions = {fn: name for name, e in externals.items() for fn in e["functions"]}
    errors: list[str] = []

    listed = {m: name for name, e in externals.items() for m in e["mocks"]}
    for key in sorted(set(listed) | set(exempt)):
        if key not in decls:
            errors.append(f"{REGISTRY.name}: {key} names no contract under contracts/test")
    for key, fns in sorted(decls.items()):
        hit = sorted(fns & set(functions))
        if hit and key not in listed and key not in exempt:
            errors.append(f"contracts/test/{key} defines {', '.join(hit)} of {functions[hit[0]]} and is not in "
                          f"{REGISTRY.name}: list it as a mock of its external or under not_external with the reason")

    calls = mock_calls(functions)
    found = fork_tests(chains)
    rows = []
    for name, e in externals.items():
        mocks = [m for m in e["mocks"] if m in decls] + calls.get(name, [])
        if not mocks:
            continue
        for chain, tests in e["fork_tests"].items():
            hits = [(t, where) for t in tests for c, where in found.get(t, []) if c == chain]
            status = f"{hits[0][0]} {hits[0][1]}" if hits else "MISSING"
            rows.append((name, chain, len(mocks), ", ".join(tests), status))
            if not hits:
                errors.append(f"{name} on {chain}: {len(mocks)} mock(s) and no fork test of {' or '.join(tests)} "
                              f"under contracts/test/fork/ reading {chains[chain]}")

    if args.markdown:
        print("| External | Chain | Mocks | Fork test (any of) | Found |\n|---|---|---:|---|---|")
        for r in rows:
            print(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]} |")
    else:
        for r in rows:
            print(f"{r[0]:22} {r[1]:9} {r[2]:>3} mocks  needs {r[3]:20} {r[4]}")
    for e in errors:
        print(f"ERROR  {e}", file=sys.stderr)
    print(f"mock counterparts: {len(rows)} (external, chain) pairs, {sum(r[4] == 'MISSING' for r in rows)} without a "
          f"fork test, {len(errors)} errors", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
