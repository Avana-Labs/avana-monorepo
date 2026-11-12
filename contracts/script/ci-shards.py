#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Lists the CI legs of the long-running checks as JSON arrays for a GitHub Actions matrix (`include`), so every
harness, Halmos test contract, Certora conf, invariant file, SMTChecker contract, src/ contract and mutation target
in the repository gets its own job without a list in the workflow: a new one joins on the next run. Each leg is one
JSON object on one line; the whole array is printed on one line. A list longer than GitHub's 256 legs per matrix
fails, so no target is ever dropped.

    ci-shards.py certora                      {"conf": "<Name>"} per certora/conf/<Name>.conf
    ci-shards.py halmos                       {"contract": "<Name>", "file": "<path>"} per non-abstract contract named
                                              *HalmosTest in a src/, test/ or script/ file that holds a check_ function
    ci-shards.py invariant                    {"file": "<path>"} per test/invariant/**/*.t.sol (the invariant profile)
    ci-shards.py smt                          {"contract": "<Name>"} per entry of [profile.smt.model_checker] contracts
    ci-shards.py smt-only <Name>              prints foundry.toml with that contracts map reduced to <Name>
    ci-shards.py echidna <build>              {"harness": "<Name>"} per *Properties harness in test/invariant/echidna/
    ci-shards.py medusa <build>               the same over test/invariant/echidna/ and test/invariant/medusa/
    ci-shards.py hevm <build>                 {"target": "harness:<Name>" | "src:<Name>" | "test", "id": <target with
                                              ":" as "-">}: each harness's
                                              assertion entry points, each src/ contract with runtime code, and
                                              `hevm test` when test/symbolic/ holds a prove_ function
    ci-shards.py mythril <build>              {"group": "<k>", "contracts": "<A B ...>"}: the src/ contracts with
                                              runtime code, sorted by name, in groups of MYTHRIL_GROUP (8)
    ci-shards.py mutate [--layers L]          {"layer": "<l>", "contract": "<Name>"} per implementation file of
                                              security/mutation-layers.json (the slither-mutate and Gambit legs)
    ci-shards.py mutator-groups               {"group": "<k>", "mutators": "<A,B,...>"}: slither-mutate's mutators in
                                              three groups, each run as its own job per contract
    ci-shards.py mutators-check               reads `slither-mutate --list-mutators` on stdin and fails when a
                                              mutator is in no group
    ci-shards.py certora-mutate [--layers L]  {"conf": "<Name>"} per Certora conf with a `mutations` section whose
                                              verified contract's file is in a folder of the selected layers (every
                                              such conf when no layer is given)
    ci-shards.py necessist [--layers L]       {"layer": "<l>", "test": "<path>"} per test file of each layer
    ci-shards.py campaign <build> <layer> <echidna|medusa>
                                              {"harness": "<Name>", "segment": <k>} for every harness of the layer
                                              (or of no layer: `other`) and every segment 1..CAMPAIGN_SEGMENTS (8)
    ci-shards.py campaign-harnesses <build> <layer>
                                              {"harness": "<Name>", "echidna": true|false} per harness of the layer

`<build>` is the slow-tier build (out-security/build/all). A harness belongs to the layer of
security/mutation-layers.json whose src/ folder holds <Subject>.sol for harness <Subject>Properties, else a file
whose name starts with <Subject>, else the longest file name that <Subject> starts with; a harness that matches no
layer belongs to `other`.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAX_LEGS = 256
ECHIDNA_DIR = "test/invariant/echidna"
MEDUSA_DIR = "test/invariant/medusa"
CONTRACT = re.compile(r"^\s*(abstract\s+)?contract\s+(\w+)", re.M)


def emit(legs: list[dict], what: str) -> int:
    if len(legs) > MAX_LEGS:
        print(f"ci-shards: {what} has {len(legs)} legs, above GitHub's {MAX_LEGS} per matrix", file=sys.stderr)
        return 1
    print(json.dumps(legs, separators=(",", ":")))
    return 0


def targets(*args: str) -> list[list[str]]:
    out = subprocess.run(
        [sys.executable, str(ROOT / "script/security-targets.py"), *args], check=True, capture_output=True, text=True
    ).stdout
    return [line.split("\t") for line in out.splitlines() if line.strip()]


def harnesses(build: str, *dirs: str) -> list[str]:
    return sorted({row[0] for row in targets("harnesses", build, *dirs)})


def src_contracts(build: str) -> list[str]:
    scratch = ROOT / "out-security/ci-shards"
    return sorted({row[0] for row in targets("runtime-code", build, str(scratch))})


def mutation(what: str, layers: str) -> list[list[str]]:
    out = subprocess.run(
        [sys.executable, str(ROOT / "script/mutation-targets.py"), what, "--layers", layers],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line.split("\t") for line in out.splitlines() if line.strip()]


def halmos() -> list[dict]:
    legs = []
    for top in ("src", "test", "script"):
        for sol in sorted((ROOT / top).rglob("*.sol")):
            text = sol.read_text(encoding="utf8")
            if not re.search(r"function\s+check_", text):
                continue
            for m in CONTRACT.finditer(text):
                if not m.group(1) and m.group(2).endswith("HalmosTest"):
                    legs.append({"contract": m.group(2), "file": str(sol.relative_to(ROOT))})
    return legs


SMT_LINE = re.compile(r'^contracts = \{(.*)\}[ \t]*$', re.M)
SMT_ENTRY = re.compile(r'"([^"]+)"\s*=\s*\[\s*"(\w+)"\s*\]')


def smt_entries() -> tuple[str, list[tuple[str, str]]]:
    text = (ROOT / "foundry.toml").read_text(encoding="utf8")
    section = text.split("[profile.smt.model_checker]", 1)
    if len(section) != 2:
        raise SystemExit("ci-shards: foundry.toml has no [profile.smt.model_checker]")
    m = SMT_LINE.search(section[1])
    if not m:
        raise SystemExit("ci-shards: [profile.smt.model_checker] has no one-line contracts map")
    return text, SMT_ENTRY.findall(m.group(1))


def smt_only(name: str) -> int:
    text, entries = smt_entries()
    keep = [(path, c) for path, c in entries if c == name]
    if len(keep) != 1:
        print(f"ci-shards: {name} is not in [profile.smt.model_checker] contracts", file=sys.stderr)
        return 1
    head, tail = text.split("[profile.smt.model_checker]", 1)
    line = 'contracts = { "%s" = ["%s"] }' % keep[0]
    sys.stdout.write(head + "[profile.smt.model_checker]" + SMT_LINE.sub(lambda _: line, tail, count=1))
    return 0


# slither-mutate runs its mutators in this order and, unless --comprehensive, skips lines where an earlier mutator left
# a mutant uncaught. A group starts without that list, so the groups together test every mutant of a single run and
# more: no mutant is dropped. CR (one mutant per statement) is the largest group on its own with RR.
MUTATOR_GROUPS = [
    "CR,RR",
    "AOR,ASOR,BOR,LOR,ROR,UOR",
    "FHR,LIR,MIA,MVIE,MVIV,MWA,SBR",
]


def mutators_check(table: str) -> int:
    listed = set(re.findall(r"^\|\s*\d+\s*\|\s*([A-Z]+)\s*\|", table, re.M))
    grouped = {m for g in MUTATOR_GROUPS for m in g.split(",")}
    if not listed:
        print("ci-shards: no mutator in the slither-mutate --list-mutators output", file=sys.stderr)
        return 1
    missing = sorted(listed - grouped)
    if missing:
        print(f"ci-shards: slither-mutate mutators in no group of MUTATOR_GROUPS: {', '.join(missing)}", file=sys.stderr)
        return 1
    print(f"every slither-mutate mutator is in a group: {', '.join(sorted(listed))}")
    return 0


def certora_confs(layers: str) -> list[dict]:
    selected = set(layers.split())
    folders = [d for layer, dirs in layer_folders().items() if layer in selected for d in dirs]
    legs = []
    for conf in sorted((ROOT / "certora/conf").glob("*.conf")):
        text = conf.read_text(encoding="utf8")
        # A conf without a `mutations` section verifies code Avana does not own (Hub.conf: the unmodified Aave V4
        # Hub), so it has no mutants; its rules still run in the certora job of contracts.yml.
        if '"mutations"' not in text:
            continue
        if selected:
            verify = re.search(r'"verify"\s*:\s*"(\w+):', text)
            files = re.findall(r'"([^":]+\.sol):(\w+)"', text)
            paths = [ROOT / f for f, name in files if verify and name == verify.group(1)]
            if not any(path.parent in folders for path in paths):
                continue
        legs.append({"conf": conf.stem})
    return legs


def layer_folders() -> dict[str, list[Path]]:
    config = json.loads((ROOT / "security/mutation-layers.json").read_text(encoding="utf8"))
    return {layer: [ROOT / e["src"] for e in entries] for layer, entries in config["layers"].items()}


def harness_layer(harness: str, folders: dict[str, list[Path]]) -> str:
    subject = harness.removesuffix("Properties")
    stems = [(layer, sol.stem) for layer, dirs in folders.items() for d in dirs for sol in sorted(d.glob("*.sol"))]
    for layer, stem in stems:
        if stem == subject:
            return layer
    for layer, stem in stems:
        if stem.startswith(subject):
            return layer
    best = max(((len(stem), layer) for layer, stem in stems if subject.startswith(stem)), default=None)
    return best[1] if best else "other"


def campaign_harnesses(build: str, layer: str) -> list[dict]:
    folders = layer_folders()
    if layer != "other" and layer not in folders:
        raise SystemExit(f"ci-shards: layer {layer} is not in security/mutation-layers.json")
    echidna = set(harnesses(build, ECHIDNA_DIR))
    return [
        {"harness": h, "echidna": h in echidna}
        for h in harnesses(build, ECHIDNA_DIR, MEDUSA_DIR)
        if harness_layer(h, folders) == layer
    ]


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    what, rest = argv[0], argv[1:]
    layers = ""
    if "--layers" in rest:
        i = rest.index("--layers")
        layers = rest[i + 1] if i + 1 < len(rest) else ""
        rest = rest[:i] + rest[i + 2 :]
    if what == "certora":
        return emit([{"conf": p.stem} for p in sorted((ROOT / "certora/conf").glob("*.conf"))], what)
    if what == "halmos":
        return emit(halmos(), what)
    if what == "invariant":
        files = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "test/invariant").rglob("*.t.sol"))
        return emit([{"file": f} for f in files], what)
    if what == "smt":
        return emit([{"contract": c} for _, c in smt_entries()[1]], what)
    if what == "smt-only" and len(rest) == 1:
        return smt_only(rest[0])
    if what == "echidna" and len(rest) == 1:
        return emit([{"harness": h} for h in harnesses(rest[0], ECHIDNA_DIR)], what)
    if what == "medusa" and len(rest) == 1:
        return emit([{"harness": h} for h in harnesses(rest[0], ECHIDNA_DIR, MEDUSA_DIR)], what)
    if what == "hevm" and len(rest) == 1:
        legs = [{"target": f"harness:{h}"} for h in harnesses(rest[0], ECHIDNA_DIR, MEDUSA_DIR)]
        legs += [{"target": f"src:{c}"} for c in src_contracts(rest[0])]
        symbolic = ROOT / "test/symbolic"
        if any(re.search(r"function\s+prove_", p.read_text(encoding="utf8")) for p in symbolic.rglob("*.sol")):
            legs.append({"target": "test"})
        for leg in legs:
            leg["id"] = leg["target"].replace(":", "-")
        return emit(legs, what)
    if what == "mythril" and len(rest) == 1:
        size = int(os.environ.get("MYTHRIL_GROUP", "8"))
        names = src_contracts(rest[0])
        groups = [names[i : i + size] for i in range(0, len(names), size)]
        return emit([{"group": str(k + 1), "contracts": " ".join(g)} for k, g in enumerate(groups)], what)
    if what == "mutate":
        return emit([{"layer": r[0], "contract": r[1]} for r in mutation("contracts", layers)], what)
    if what == "mutator-groups":
        return emit([{"group": str(k + 1), "mutators": g} for k, g in enumerate(MUTATOR_GROUPS)], what)
    if what == "mutators-check":
        return mutators_check(sys.stdin.read())
    if what == "certora-mutate":
        return emit(certora_confs(layers), what)
    if what == "necessist":
        return emit([{"layer": r[0], "test": r[1]} for r in mutation("tests", layers)], what)
    if what == "campaign-harnesses" and len(rest) == 2:
        return emit(campaign_harnesses(rest[0], rest[1]), what)
    if what == "campaign" and len(rest) == 3:
        build, layer, tool = rest[:3]
        segments = int(os.environ.get("CAMPAIGN_SEGMENTS", "8"))
        names = [h["harness"] for h in campaign_harnesses(build, layer) if tool == "medusa" or h["echidna"]]
        return emit([{"harness": h, "segment": k} for h in names for k in range(1, segments + 1)], what)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
