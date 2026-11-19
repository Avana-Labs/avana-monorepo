#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Size report of the Avana core: the code lines of each of the seven core contracts, the core total and the policy
# part (AaveAdapter + RiskModule).
#
#   each core contract  at most 800 code lines
#   core total          at most 4,000 code lines (the AMM parts are not counted)
#   policy part         at most 1,500 code lines (AaveAdapter + RiskModule)
#
# A code line is neither blank nor comment-only. A core contract is its folder: the contract, its interface, its
# storage and its own libraries (every .sol file under the folder). Every other .sol file under src/ must sit in a
# folder outside the core count (the AMM parts, the role ids, the external interfaces); a file in neither fails the
# report, so new code cannot land outside the count unnoticed.
#
# Prints one line per core contract and the outside folders, then the totals; exits 1 when a limit is exceeded or a
# file is unassigned. script/check-core-size.test.sh checks the counting and each limit on fixture folders.
#
# Usage, from contracts/:  script/check-core-size.sh [src-dir]

set -euo pipefail

SRC_DIR="${1:-src}"
if [ ! -d "$SRC_DIR" ]; then
  echo "check-core-size: no such directory: $SRC_DIR" >&2
  exit 2
fi

python3 - "$SRC_DIR" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])

MAX_CONTRACT = 800
MAX_CORE = 4_000
MAX_POLICY = 1_500

# Core contract -> its folder under src/.
CORE = {
    "AaveAdapter": "policy/aave-adapter",
    "RiskModule": "policy/risk-module",
    "LPVault": "custody/lp-vault",
    "VaultToken": "vault-token",
    "LPOracle": "oracle",
    "LiquidationModule": "liquidation/liquidation-module",
    "FirstLossReserve": "coverage/first-loss-reserve",
}
POLICY = ("AaveAdapter", "RiskModule")
# Folders outside the core count.
OUTSIDE = {
    "AMM parts": "amm",
    "role ids": "governance",
    "external interfaces": "interfaces/external",
}


def code_lines(path):
    text = path.read_text(encoding="utf-8")
    # Block comments become blank lines, so a line holding only a comment is not counted.
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return sum(1 for line in text.splitlines() if re.sub(r"//.*", "", line).strip())


def files_in(folder):
    d = src / folder
    return sorted(d.rglob("*.sol")) if d.is_dir() else []


failed = []
assigned = set()
counts = {}
for name, folder in CORE.items():
    files = files_in(folder)
    if not files:
        failed.append(f"{name}: no .sol file under {src / folder}")
    assigned.update(files)
    counts[name] = sum(code_lines(f) for f in files)

outside = {}
for label, folder in OUTSIDE.items():
    files = files_in(folder)
    assigned.update(files)
    outside[label] = sum(code_lines(f) for f in files)

unassigned = sorted(set(src.rglob("*.sol")) - assigned)
for f in unassigned:
    failed.append(f"{f}: in no core contract folder and no folder outside the count")

core = sum(counts.values())
policy = sum(counts[n] for n in POLICY)

print(f"{'core contract':<22} {'folder':<34} {'code lines':>10} {'limit':>6}")
for name, folder in CORE.items():
    flag = ""
    if counts[name] > MAX_CONTRACT:
        flag = "  OVER"
        failed.append(f"{name}: {counts[name]} code lines, over {MAX_CONTRACT}")
    print(f"{name:<22} {'src/' + folder:<34} {counts[name]:>10,} {MAX_CONTRACT:>6,}{flag}")
print()
for label, folder in OUTSIDE.items():
    print(f"{'(' + label + ')':<22} {'src/' + folder:<34} {outside[label]:>10,} {'-':>6}")
print()
flag = "  OVER" if core > MAX_CORE else ""
print(f"{'core total':<57} {core:>10,} {MAX_CORE:>6,}{flag}")
if flag:
    failed.append(f"core total: {core} code lines, over {MAX_CORE}")
flag = "  OVER" if policy > MAX_POLICY else ""
print(f"{'policy (AaveAdapter + RiskModule)':<57} {policy:>10,} {MAX_POLICY:>6,}{flag}")
if flag:
    failed.append(f"policy part: {policy} code lines, over {MAX_POLICY}")

if failed:
    for line in failed:
        print(f"check-core-size: {line}")
    sys.exit(1)
print("check-core-size: every limit met")
PY
