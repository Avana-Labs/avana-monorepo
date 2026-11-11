#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Runtime-size margin check of every deployable src/ contract and library against EIP-170 (24,576 bytes).
#
# A contract fails when its runtime code is larger than 24,576 bytes minus its margin. The margin is the
# `default` of security/size-margins.json, or the contract's own entry there; a margin keeps room for the
# next fix of a contract that is already close to the limit. Sizes come from the artifacts in out/, so run
# `forge build` first. A contract compiled under several compiler profiles (compilation_restrictions) is
# measured on its smallest artifact, the one its restriction deploys.
#
# Writes out-security/sizes.json ({"<Contract>": <runtime bytes>}). With --base <file> (a sizes.json of
# the base branch) it also prints each change in size.
#
# Usage, from contracts/:  script/check-sizes.sh [--base <sizes.json>]

set -euo pipefail

BASE=""
if [ "${1:-}" = "--base" ]; then
  BASE="${2:?usage: check-sizes.sh [--base <sizes.json>]}"
fi

mkdir -p out-security
python3 - "$BASE" <<'PY'
import glob
import json
import sys

EIP170 = 24_576
base_path = sys.argv[1]

with open("security/size-margins.json") as f:
    cfg = json.load(f)
default_margin = int(cfg["default"])
margins = {k: int(v["margin"]) for k, v in cfg.get("contracts", {}).items()}

sizes = {}
for path in glob.glob("out/**/*.json", recursive=True):
    if "/build-info/" in path:
        continue
    try:
        with open(path) as f:
            art = json.load(f)
    except (OSError, ValueError):
        continue
    meta = art.get("metadata")
    if isinstance(meta, str):
        meta = json.loads(meta)
    target = ((meta or {}).get("settings") or {}).get("compilationTarget") or {}
    if not target:
        continue
    src, name = next(iter(target.items()))
    if not src.startswith("src/"):
        continue
    code = ((art.get("deployedBytecode") or {}).get("object") or "").removeprefix("0x")
    if not code:
        continue
    size = len(code) // 2
    sizes[name] = min(size, sizes.get(name, size))

with open("out-security/sizes.json", "w") as f:
    json.dump(dict(sorted(sizes.items())), f, indent=2)
    f.write("\n")

unknown = sorted(set(margins) - set(sizes))
base = {}
if base_path:
    try:
        with open(base_path) as f:
            base = json.load(f)
    except (OSError, ValueError):
        print(f"check-sizes: base {base_path} not readable; no diff printed")

failed = 0
print(f"{'contract':<40} {'runtime':>8} {'limit':>8} {'headroom':>9} {'vs base':>8}")
for name, size in sorted(sizes.items(), key=lambda kv: -kv[1]):
    limit = EIP170 - margins.get(name, default_margin)
    delta = ""
    if name in base:
        d = size - int(base[name])
        delta = f"{d:+d}" if d else "0"
    elif base:
        delta = "new"
    flag = ""
    if size > limit:
        failed += 1
        flag = "  OVER"
    print(f"{name:<40} {size:>8} {limit:>8} {limit - size:>9} {delta:>8}{flag}")
for name in unknown:
    print(f"check-sizes: security/size-margins.json names {name}, which has no src/ artifact")
if failed:
    print(f"check-sizes: {failed} contract(s) over EIP-170 minus margin")
    sys.exit(1)
print(f"check-sizes: {len(sizes)} contracts within EIP-170 minus margin")
PY
