#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Lists the layer-gate targets of security-slow.sh `mutate` and `necessist` from security/mutation-layers.json.

    mutation-targets.py contracts [--layers "2.1 2.4"] [--contracts "Lock ProxyManager"]
        "<layer><TAB><contract><TAB><file><TAB><tests glob>" for every implementation file (a contract, or a library
        with functions; its name is the file name) in each listed src/ folder.
    mutation-targets.py tests [--layers ...] [--contracts ...]
        "<layer><TAB><test file>" for every test file matched by the `tests` glob of an entry with at least one
        selected implementation file, each file once per layer.
    mutation-targets.py gambit [--layers ...] [--contracts ...]
        "<layer><TAB><contract><TAB><file><TAB><tests glob><TAB><mutant cap><TAB><seed><TAB><operators>" for every
        implementation file, for security-gambit.sh. The cap, seed and comma-separated Gambit operators come from the
        `gambit` object of security/mutation-layers.json; the cap is the layer's entry in `num_mutants`, else its
        `default`.

An empty --layers or --contracts selects everything.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = re.compile(r"^\s*(abstract\s+)?contract\s", re.M)
LIBRARY = re.compile(r"^\s*library\s", re.M)
FUNCTION = re.compile(r"^\s*function\s", re.M)


def braces(pattern: str) -> list[str]:
    """Expands the first {a,b} group recursively, as forge --match-path globs do."""
    m = re.search(r"\{([^{}]*)\}", pattern)
    if not m:
        return [pattern]
    out = []
    for alt in m.group(1).split(","):
        out.extend(braces(pattern[: m.start()] + alt + pattern[m.end() :]))
    return out


def implementations(folder: Path) -> list[Path]:
    out = []
    for sol in sorted(folder.glob("*.sol")):
        text = sol.read_text(encoding="utf8")
        if CONTRACT.search(text) or (LIBRARY.search(text) and FUNCTION.search(text)):
            out.append(sol)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("what", choices=["contracts", "tests", "gambit"])
    parser.add_argument("--layers", default="")
    parser.add_argument("--contracts", default="")
    parser.add_argument("--config", type=Path, default=ROOT / "security/mutation-layers.json")
    args = parser.parse_args()
    layers = set(args.layers.split())
    names = set(args.contracts.split())
    config = json.loads(args.config.read_text(encoding="utf8"))
    gambit = config.get("gambit", {})
    if args.what == "gambit" and not (gambit.get("mutations") and "seed" in gambit and "default" in gambit.get("num_mutants", {})):
        print("mutation-targets: security/mutation-layers.json needs gambit.seed, gambit.mutations and"
              " gambit.num_mutants.default", file=sys.stderr)
        return 1
    for layer, entries in config["layers"].items():
        if layers and layer not in layers:
            continue
        seen: set[str] = set()
        for entry in entries:
            folder = ROOT / entry["src"]
            if not folder.is_dir():
                print(f"mutation-targets: {entry['src']} (layer {layer}) is not a folder", file=sys.stderr)
                return 1
            globs = entry.get("files", ["*"])
            files = [
                f
                for f in implementations(folder)
                if (not names or f.stem in names) and any(fnmatch.fnmatchcase(f.stem, g) for g in globs)
            ]
            if not files:
                continue
            if args.what == "contracts":
                for f in files:
                    print(f"{layer}\t{f.stem}\t{f.relative_to(ROOT)}\t{entry['tests']}")
                continue
            if args.what == "gambit":
                cap = gambit["num_mutants"].get(layer, gambit["num_mutants"]["default"])
                ops = ",".join(gambit["mutations"])
                for f in files:
                    print(f"{layer}\t{f.stem}\t{f.relative_to(ROOT)}\t{entry['tests']}\t{cap}\t{gambit['seed']}\t{ops}")
                continue
            for pattern in braces(entry["tests"]):
                for test in sorted(ROOT.glob(pattern)):
                    rel = str(test.relative_to(ROOT))
                    if test.suffix == ".sol" and rel not in seen:
                        seen.add(rel)
                        print(f"{layer}\t{rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
