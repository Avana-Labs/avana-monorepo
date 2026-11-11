#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Lists the targets of the slow security tier from a `forge build --build-info` output directory, so the runners
need no list of files: every harness and every src/ contract found in the build is a target.

    security-targets.py harnesses <build> <dir> [<dir> ...]
        Name and source path of every contract named `*Properties` declared in a file under one of the folders.
    security-targets.py assertion-sigs <build> <contract>
        Signature of every state-changing function of the contract that is not a `property_` function: the entry
        points of assertion mode.
    security-targets.py code <build> <contract> <file>
        Writes the runtime code of the contract (hex, no 0x) to <file>.
    security-targets.py runtime-code <build> <out-dir>
        Writes the runtime code of every contract and library compiled from src/ that has code to <out-dir>/<Name>.hex
        and prints "<Name><TAB><hex file>" per line. Interfaces have no code and are skipped.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def artifacts(build: Path):
    for path in sorted(build.glob("*.sol/*.json")):
        data = json.loads(path.read_text(encoding="utf8"))
        source = data.get("ast", {}).get("absolutePath", "")
        yield path.stem, source, data


def canonical(param: dict) -> str:
    kind = param["type"]
    if kind.startswith("tuple"):
        return "(" + ",".join(canonical(c) for c in param["components"]) + ")" + kind[len("tuple") :]
    return kind


def harnesses(build: Path, folders: list[str]) -> None:
    prefixes = tuple(f.rstrip("/") + "/" for f in folders)
    for name, source, _ in artifacts(build):
        if source.startswith(prefixes) and name.endswith("Properties"):
            print(f"{name}\t{source}")


def assertion_sigs(build: Path, contract: str) -> None:
    for name, _, data in artifacts(build):
        if name != contract:
            continue
        for item in data["abi"]:
            if item.get("type") != "function" or item["name"].startswith("property_"):
                continue
            if item.get("stateMutability") in ("view", "pure"):
                continue
            print(f"{item['name']}({','.join(canonical(p) for p in item['inputs'])})")
        return


def code(build: Path, contract: str, target: Path) -> None:
    for name, _, data in artifacts(build):
        if name == contract:
            target.write_text(data["deployedBytecode"]["object"].removeprefix("0x"), encoding="utf8")
            return
    raise SystemExit(f"security-targets: {contract} is not in {build}")


def runtime_code(build: Path, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for name, source, data in artifacts(build):
        runtime = data.get("deployedBytecode", {}).get("object", "0x")
        if not source.startswith("src/") or runtime in ("", "0x"):
            continue
        hex_file = out / f"{name}.hex"
        hex_file.write_text(runtime.removeprefix("0x"), encoding="utf8")
        print(f"{name}\t{hex_file}")


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    command, build = sys.argv[1], Path(sys.argv[2])
    if command == "harnesses":
        harnesses(build, sys.argv[3:])
    elif command == "assertion-sigs":
        assertion_sigs(build, sys.argv[3])
    elif command == "code" and len(sys.argv) == 5:
        code(build, sys.argv[3], Path(sys.argv[4]))
    elif command == "runtime-code":
        runtime_code(build, Path(sys.argv[3]))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
