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
    security-targets.py creation-code <build> <contract> <file>
        Writes the creation code of the contract (hex, no 0x) to <file>.
    security-targets.py runtime-code <build> <out-dir> [<self-address>]
        Writes the runtime code of every contract and library compiled from src/ that has code to <out-dir>/<Name>.hex
        and prints "<Name><TAB><hex file>" per line. Interfaces have no code and are skipped. Every immutable of an
        address or contract type is filled in, as a constructor fills it, with an address of its own (`FILL_BASE` + k,
        k = 1, 2, ... in the order of the AST IDs), except those that hold the contract's own address (`SELF_NAMES`),
        which get <self-address> (default 0, where Mythril runs the code); other immutables keep the zero solc leaves
        in the runtime code. The build needs its build-info/ folder (`forge build --build-info`).

Why the fill: solc leaves immutables as zero words in `deployedBytecode`, and Mythril runs runtime code at address 0.
With zero immutables every call the contract makes to another contract it was constructed with (the Lock, the Hub, the
ParameterStore, ...) calls the analysed contract itself, and its dispatcher's revert is reported as a requirement
violation in a nested call (SWC-123) that no deployment reaches: constructors are given the addresses of deployed
contracts (they reject a zero address or check the code behind it). A filled address holds no code in Mythril's world,
so the call returns symbolic data, as a call to an unknown contract does.
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


def code(build: Path, contract: str, target: Path, kind: str = "deployedBytecode") -> None:
    for name, _, data in artifacts(build):
        if name == contract:
            target.write_text(data[kind]["object"].removeprefix("0x"), encoding="utf8")
            return
    raise SystemExit(f"security-targets: {contract} is not in {build}")


FILL_BASE = 0xA7A4000000000000000000000000000000000000
DECL = '"nodeType":"VariableDeclaration"'
IMMUTABLE = '"mutability":"immutable"'
TYPE = '"typeDescriptions":{"typeIdentifier":"'
NAME = '"name":"'
# Immutables that hold the contract's own address (`_SELF = address(this)` in Lock, ParameterStoreStorage,
# MarketRegistryStorage, LPVaultSwapStorage and LPOracleLogicBase; OpenZeppelin's UUPS `__self` and EIP712
# `_cachedThis`): left at zero, which is the analysed contract's own address in Mythril, so a guard that compares
# `address(this)` with them sees the contract called directly, as deployed. hevm runs the code at another address,
# which `runtime-code` takes as its third argument.
SELF_NAMES = {"_SELF", "__self", "_cachedThis"}


class Unit:
    """One compilation unit (one build-info file): its text, searched for the deployed code of an artifact, and the
    type of each immutable it declares, by AST ID. An artifact's `ast` may come from another unit than its bytecode
    when a file is compiled in several, so the declarations are read from the build info, not from the artifact. The
    file is scanned as text: each immutable is a VariableDeclaration node whose `"mutability":"immutable"` follows its
    `{"id":N,"nodeType":"VariableDeclaration"` opening and precedes its own `typeDescriptions`."""

    def __init__(self, path: Path) -> None:
        self.text = path.read_text(encoding="utf8")
        self.types: dict[int, tuple[str, str]] = {}
        at = self.text.find(IMMUTABLE)
        while at != -1:
            decl = self.text.rfind(DECL, 0, at)
            opening = self.text.rfind('{"id":', 0, decl)
            kind = self.text.find(TYPE, at)
            if decl == -1 or opening == -1 or kind == -1:
                raise SystemExit(f"security-targets: unreadable immutable declaration in {path}")
            ast_id = int(self.text[opening + len('{"id":') : self.text.index(",", opening)])
            kind += len(TYPE)
            name = self.text.find(NAME, at) + len(NAME)
            self.types[ast_id] = (self.text[kind : self.text.index('"', kind)], self.text[name : self.text.index('"', name)])
            at = self.text.find(IMMUTABLE, at + 1)


def is_address_type(type_identifier: str) -> bool:
    return type_identifier in ("t_address", "t_address_payable") or type_identifier.startswith("t_contract$")


def fill_immutables(name: str, runtime: str, data: dict, units: list[Unit], self_address: int) -> str:
    refs = data.get("deployedBytecode", {}).get("immutableReferences", {}) or {}
    if not refs:
        return runtime
    homes = [u for u in units if f'"object":"{runtime}"' in u.text]
    found = [{int(i): u.types.get(int(i)) for i in refs} for u in homes]
    if not found or any(None in f.values() for f in found) or any(f != found[0] for f in found):
        raise SystemExit(f"security-targets: the immutables of {name} have no single declaration in the build info")
    code = bytearray(bytes.fromhex(runtime))
    for k, ast_id in enumerate(sorted(found[0])):
        type_identifier, variable = found[0][ast_id]
        if not is_address_type(type_identifier):
            continue
        word = (self_address if variable in SELF_NAMES else FILL_BASE + k + 1).to_bytes(32, "big")
        for ref in refs[str(ast_id)]:
            start, length = ref["start"], ref["length"]
            code[start : start + length] = word[32 - length :]
    return code.hex()


def runtime_code(build: Path, out: Path, self_address: int = 0) -> None:
    out.mkdir(parents=True, exist_ok=True)
    units = [Unit(p) for p in sorted((build / "build-info").glob("*.json"))]
    for name, source, data in artifacts(build):
        runtime = data.get("deployedBytecode", {}).get("object", "0x")
        if not source.startswith("src/") or runtime in ("", "0x"):
            continue
        hex_file = out / f"{name}.hex"
        hex_file.write_text(fill_immutables(name, runtime.removeprefix("0x"), data, units, self_address), encoding="utf8")
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
    elif command == "creation-code" and len(sys.argv) == 5:
        code(build, sys.argv[3], Path(sys.argv[4]), "bytecode")
    elif command == "runtime-code" and len(sys.argv) in (4, 5):
        runtime_code(build, Path(sys.argv[3]), int(sys.argv[4], 16) if len(sys.argv) == 5 else 0)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
