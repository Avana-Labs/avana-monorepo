#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Prints the name of every deployable contract under src/ that inherits OpenZeppelin `Initializable` (directly or
through `UUPSUpgradeable`), one per line, from the Slither view of a `forge build --build-info` output directory.

    security-list-upgradeable.py <forge-out-dir>
"""

import sys

from slither import Slither

UPGRADEABLE_BASES = {"Initializable", "UUPSUpgradeable"}


def main() -> int:
    slither = Slither(".", foundry_ignore_compile=True, foundry_out_directory=sys.argv[1])
    names = set()
    for contract in slither.contracts:
        if contract.is_interface or contract.is_library or contract.is_abstract:
            continue
        if not contract.source_mapping.filename.relative.startswith("src/"):
            continue
        if UPGRADEABLE_BASES & {base.name for base in contract.inheritance}:
            names.add(contract.name)
    for name in sorted(names):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
