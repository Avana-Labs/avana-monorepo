#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
# Runtime-size margin check of every deployable src/ contract and library against EIP-170 (24,576 bytes).
#
# A contract fails when its runtime code is larger than 24,576 bytes minus its margin. The margin is the
# `default` of security/size-margins.json, or the contract's own entry there; a margin keeps room for the
# next fix of a contract that is already close to the limit. Sizes come from the artifacts in out/, so run
# `forge build` first.
#
# Each contract is measured on the artifact of the compiler profile it is deployed with. A contract whose
# source file matches a `compilation_restrictions` entry of foundry.toml is deployed with that restriction's
# settings (via_ir, optimizer_runs), so its artifact with those settings is measured. Every other contract is
# deployed with the default profile, so its default-profile artifact is measured, even when the same file is
# also compiled under a restricted profile because a restricted file imports it (for example
# ParameterStoreAdminRiskLogic, which the LPOracle harness pulls into the 200-run `lporacle` profile). A
# contract with no artifact for its deployment profile fails the check.
#
# Writes out-security/sizes.json ({"<Contract>": <runtime bytes>}). With --base <file> (a sizes.json of
# the base branch) it also prints each change in size. script/check-sizes.test.sh checks the profile rule
# on fixture artifacts.
#
# Usage, from contracts/:  script/check-sizes.sh [--base <sizes.json>]
# Test inputs (check-sizes.test.sh): CHECK_SIZES_OUT (artifact folder, default out), CHECK_SIZES_CONFIG (a
# `forge config --json` file, default: run it), CHECK_SIZES_MARGINS (default security/size-margins.json),
# CHECK_SIZES_REPORT (default out-security/sizes.json).

set -euo pipefail

BASE=""
if [ "${1:-}" = "--base" ]; then
  BASE="${2:?usage: check-sizes.sh [--base <sizes.json>]}"
fi

OUT_DIR="${CHECK_SIZES_OUT:-out}"
MARGINS="${CHECK_SIZES_MARGINS:-security/size-margins.json}"
REPORT="${CHECK_SIZES_REPORT:-out-security/sizes.json}"
mkdir -p "$(dirname "$REPORT")"
if [ -n "${CHECK_SIZES_CONFIG:-}" ]; then
  CONFIG="$(cat "$CHECK_SIZES_CONFIG")"
else
  CONFIG="$(forge config --json)"
fi

CONFIG="$CONFIG" python3 - "$BASE" "$OUT_DIR" "$MARGINS" "$REPORT" <<'PY'
import glob
import json
import os
import re
import sys

EIP170 = 24_576
base_path, out_dir, margins_path, report_path = sys.argv[1:5]

with open(margins_path) as f:
    cfg = json.load(f)
default_margin = int(cfg["default"])
margins = {k: int(v["margin"]) for k, v in cfg.get("contracts", {}).items()}

foundry = json.loads(os.environ["CONFIG"])
DEFAULT = ("default", int(foundry["optimizer_runs"]), bool(foundry.get("via_ir")))
profiles = [DEFAULT] + [
    (p["name"], int(p["optimizer_runs"]), bool(p.get("via_ir")))
    for p in foundry.get("additional_compiler_profiles") or []
]


def glob_regex(pattern):
    """Foundry path glob: `**` crosses folders, `*` and `?` stay inside one."""
    out = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(out + r"\Z")


restrictions = [
    (r["paths"], glob_regex(r["paths"]), r.get("optimizer_runs"), r.get("via_ir"))
    for r in foundry.get("compilation_restrictions") or []
]


def deployment(src):
    """The (label, runs, via_ir) a source file is deployed with."""
    for paths, rx, runs, via_ir in restrictions:
        if rx.match(src):
            return (f"restricted {paths}", runs, via_ir)
    return ("default", DEFAULT[1], DEFAULT[2])


def profile_name(runs, via_ir):
    for name, p_runs, p_ir in profiles:
        if (p_runs, p_ir) == (runs, via_ir):
            return name
    return f"runs={runs},via_ir={via_ir}"


# (source, contract) -> list of (size, runs, via_ir)
artifacts = {}
for path in glob.glob(f"{out_dir}/**/*.json", recursive=True):
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
    settings = (meta or {}).get("settings") or {}
    target = settings.get("compilationTarget") or {}
    if not target:
        continue
    src, name = next(iter(target.items()))
    if not src.startswith("src/"):
        continue
    code = ((art.get("deployedBytecode") or {}).get("object") or "").removeprefix("0x")
    if not code:
        continue
    runs = int((settings.get("optimizer") or {}).get("runs", 200))
    via_ir = bool(settings.get("viaIR"))
    artifacts.setdefault((src, name), []).append((len(code) // 2, runs, via_ir))

sizes = {}
profile_of = {}
missing = []
for (src, name), arts in sorted(artifacts.items()):
    label, runs, via_ir = deployment(src)
    matching = [
        size for size, a_runs, a_ir in arts
        if (runs is None or a_runs == runs) and (via_ir is None or a_ir == bool(via_ir))
    ]
    if not matching:
        built = ", ".join(profile_name(r, i) for _, r, i in arts)
        missing.append(f"{name} ({src}): no artifact for its deployment profile ({label}); built: {built}")
        continue
    size = max(matching)
    if name in sizes:
        # Two src/ contracts with one name: keep the larger, the check stays on the safe side.
        size = max(size, sizes[name])
    sizes[name] = size
    profile_of[name] = profile_name(runs if runs is not None else DEFAULT[1], bool(via_ir))

with open(report_path, "w") as f:
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
print(f"{'contract':<40} {'profile':<18} {'runtime':>8} {'limit':>8} {'headroom':>9} {'vs base':>8}")
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
    print(f"{name:<40} {profile_of[name]:<18} {size:>8} {limit:>8} {limit - size:>9} {delta:>8}{flag}")
for name in unknown:
    print(f"check-sizes: security/size-margins.json names {name}, which has no src/ artifact")
for line in missing:
    print(f"check-sizes: {line}")
if failed or missing:
    if failed:
        print(f"check-sizes: {failed} contract(s) over EIP-170 minus margin")
    sys.exit(1)
print(f"check-sizes: {len(sizes)} contracts within EIP-170 minus margin")
PY
