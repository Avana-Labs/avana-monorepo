#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Lists the CI legs of the long-running checks as JSON arrays for a GitHub Actions matrix (`include`), so every
harness, Halmos test contract, Certora conf, invariant file, SMTChecker contract, src/ contract and mutation target
in the repository gets its own job without a list in the workflow: a new one joins on the next run. Each leg is one
JSON object on one line; the whole array is printed on one line. A list longer than GitHub's 256 legs per matrix
fails, so no target is ever dropped.

    ci-shards.py certora                      {"conf": "<Name>"} per certora/conf/<Name>.conf
    ci-shards.py halmos                       {"contract": "<Name>", "check": "<function>", "file": "<path>"} per check_
                                              and invariant_ function (Halmos's default test prefixes) of each
                                              non-abstract contract named *HalmosTest in a src/, test/ or script/ file;
                                              a test function in any other contract fails the listing, since no job
                                              would run it, and so does any entry of ../.github/security/halmos-bounds.json
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
    ci-shards.py mutate --totals F [--keys F] [--chunks N]
                                              the slither-mutate legs: each target of --totals ({"mutate:<layer>:
                                              <Contract>": mutants}, from script/mutation-slither.py list) split into
                                              shards of at most MUTANTS_PER_JOB (40) mutants, {"layer", "contract",
                                              "shard", "shards", "key"} each, dealt round-robin into N lists (one
                                              matrix job each), the largest shards first; above 256 legs per list
                                              the shards grow. Prints {"chunks": [[...], ...], "mutants": n,
                                              "per_job": p}. --keys: the targets' keys (script/mutation-ledger.py)
    ci-shards.py gambit [--layers L] [--contracts C] [--keys F] [--skip F]
                                              {"layer", "contract", "key"} per implementation file (the Gambit legs)
    ci-shards.py mutators-check               reads `slither-mutate --list-mutators` on stdin and fails when a
                                              mutator is neither run (SLITHER_MUTATORS) nor left to Gambit
                                              (GAMBIT_COVERED)
    ci-shards.py certora-mutate [--layers L]  {"conf": "<Name>"} per Certora conf with a `mutations` section whose
                                              verified contract's file is listed in the selected layers (every
                                              such conf when no layer is given)
    ci-shards.py necessist [--layers L] [--contracts C] [--keys F] [--skip F]
                                              {"layer": "<l>", "test": "<path> [<path> ...]", "keys": "<key> ..."}
                                              per test file of each layer; above 256 legs, k files of one layer per
                                              leg (necessist_legs)
    ci-shards.py campaign <build> <layer> <echidna|medusa>
                                              {"harness": "<Name>", "segment": <k>} for every harness of the layer
                                              (or of no layer: `other`) and every segment 1..CAMPAIGN_SEGMENTS (8)
    ci-shards.py campaign-harnesses <build> <layer>
                                              {"harness": "<Name>", "echidna": true|false} per harness of the layer

`<build>` is the slow-tier build (out-security/build/all). A harness belongs to the layer of
../.github/security/mutation-layers.json whose entries list <Subject>.sol for harness <Subject>Properties (a file of the entry's
src/ folder that its `files` globs, if any, select), else a file whose name starts with <Subject>, else the longest file
name that <Subject> starts with; a harness that matches no layer belongs to `other`.
"""

from __future__ import annotations

import fnmatch
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


def necessist_legs(rows: list[list[str]]) -> list[dict]:
    """One leg per test file; above MAX_LEGS, each layer's files are run k to a leg (space-separated, as
    NECESSIST_TESTS takes them), with the smallest k that fits, so no file is dropped and a leg stays in one layer."""
    by_layer: dict[str, list[str]] = {}
    for layer, test in rows:
        by_layer.setdefault(layer, []).append(test)
    k = 1
    while sum(-(-len(t) // k) for t in by_layer.values()) > MAX_LEGS:
        k += 1
    return [
        {"layer": layer, "test": " ".join(tests[i : i + k])}
        for layer, tests in by_layer.items()
        for i in range(0, len(tests), k)
    ]


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


def mutation(what: str, layers: str, contracts: str = "") -> list[list[str]]:
    out = subprocess.run(
        [sys.executable, str(ROOT / "script/mutation-targets.py"), what, "--layers", layers, "--contracts", contracts],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line.split("\t") for line in out.splitlines() if line.strip()]


HALMOS_TEST = re.compile(r"^\s*function\s+((?:check|invariant)_\w*)\s*\(", re.M)


def halmos() -> list[dict]:
    """One leg per Halmos test function, so each runs in its own job with the job's whole time budget. A test function
    belongs to the contract declared last above it in its file; one in a contract that is abstract or not named
    *HalmosTest would never run in a job of its own, so the listing fails instead of dropping it."""
    legs = []
    stray = []
    for top in ("src", "test", "script"):
        for sol in sorted((ROOT / top).rglob("*.sol")):
            text = sol.read_text(encoding="utf8")
            if not HALMOS_TEST.search(text):
                continue
            decls = list(CONTRACT.finditer(text))
            for t in HALMOS_TEST.finditer(text):
                owner = [m for m in decls if m.start() < t.start()]
                path = str(sol.relative_to(ROOT))
                if owner and not owner[-1].group(1) and owner[-1].group(2).endswith("HalmosTest"):
                    legs.append({"contract": owner[-1].group(2), "check": t.group(1), "file": path})
                elif top == "test" and "halmos" in sol.parts:
                    stray.append(f"{path}: {t.group(1)}")
    if stray:
        raise SystemExit("ci-shards: Halmos test functions outside a non-abstract *HalmosTest contract: " + ", ".join(stray))
    # Every check must run to completion; ../.github/security/halmos-bounds.json may list none (script/halmos-outcome.py check).
    bounds = json.loads((ROOT / "../.github/security/halmos-bounds.json").read_text(encoding="utf8")).get("bounded")
    if bounds != []:
        raise SystemExit("ci-shards: ../.github/security/halmos-bounds.json must hold an empty `bounded` list; a check that does "
                         "not run to completion fails instead of being listed")
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


# The slither-mutate mutators the gate runs (script/mutation-slither.py): CR and RR (statement and revert mutants) and
# the tweaks that Gambit has no operator for. Every mutant of them is tested; no line is skipped because another
# mutant on it survived.
SLITHER_MUTATORS = "CR,FHR,LIR,MIA,MVIE,MVIV,MWA,RR,SBR"
# The operator replacements (arithmetic, assignment, bitwise, logical, relational, unary) are Gambit's
# binary-op-mutation, assignment-mutation and unary-operator-mutation (../.github/security/mutation-layers.json `gambit`), so
# slither-mutate does not test them a second time.
GAMBIT_COVERED = "AOR,ASOR,BOR,LOR,ROR,UOR"
MUTANTS_PER_JOB = int(os.environ.get("MUTANTS_PER_JOB", "40"))


def mutators_check(table: str) -> int:
    listed = set(re.findall(r"^\|\s*\d+\s*\|\s*([A-Z]+)\s*\|", table, re.M))
    known = set(SLITHER_MUTATORS.split(",")) | set(GAMBIT_COVERED.split(","))
    if not listed:
        print("ci-shards: no mutator in the slither-mutate --list-mutators output", file=sys.stderr)
        return 1
    missing = sorted(listed - known)
    if missing:
        print("ci-shards: slither-mutate mutators neither in SLITHER_MUTATORS nor in GAMBIT_COVERED: "
              + ", ".join(missing), file=sys.stderr)
        return 1
    print(f"slither-mutate mutators run: {SLITHER_MUTATORS}; left to Gambit: {GAMBIT_COVERED}")
    return 0


def load(path: str | None, default):
    return json.loads(Path(path).read_text(encoding="utf8")) if path else default


def mutate_plan(totals: dict[str, int], keys: dict, chunks: int) -> dict:
    """The slither-mutate legs: each target in shards of at most `per_job` mutants (MUTANTS_PER_JOB, raised in steps
    of 10 until the legs fit `chunks` matrices of MAX_LEGS), dealt round-robin into `chunks` lists, the largest
    shards first, so every list starts with its longest jobs. A target without a mutant gets no leg."""
    sizes = [(entry, n) for entry, n in sorted(totals.items()) if n > 0]
    per_job = MUTANTS_PER_JOB
    while sum(-(-n // per_job) for _, n in sizes) > MAX_LEGS * chunks:
        per_job += 10
    legs = []
    for entry, n in sizes:
        _, layer, name = entry.split(":", 2)
        shards = -(-n // per_job)
        legs += [(n / shards, {"layer": layer, "contract": name, "shard": k, "shards": shards,
                               "key": keys.get(entry, "")}) for k in range(1, shards + 1)]
    legs.sort(key=lambda x: -x[0])
    out: list[list[dict]] = [[] for _ in range(chunks)]
    for j, (_, leg) in enumerate(legs):
        out[j % chunks].append(leg)
    return {"chunks": out, "mutants": sum(n for _, n in sizes), "per_job": per_job}


def certora_confs(layers: str) -> list[dict]:
    selected = set(layers.split())
    files_of_layers = {p for layer, files in layer_files().items() if layer in selected for p in files}
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
            if not any(path in files_of_layers for path in paths):
                continue
        legs.append({"conf": conf.stem})
    return legs


def layer_files() -> dict[str, list[Path]]:
    """The .sol files of each layer: those of each entry's src/ folder (not its subfolders) that its `files` globs,
    if any, select."""
    config = json.loads((ROOT / "../.github/security/mutation-layers.json").read_text(encoding="utf8"))
    out: dict[str, list[Path]] = {}
    for layer, entries in config["layers"].items():
        out[layer] = [
            sol
            for e in entries
            for sol in sorted((ROOT / e["src"]).glob("*.sol"))
            if any(fnmatch.fnmatchcase(sol.stem, g) for g in e.get("files", ["*"]))
        ]
    return out


def harness_layer(harness: str, files: dict[str, list[Path]]) -> str:
    subject = harness.removesuffix("Properties")
    stems = [(layer, sol.stem) for layer, sols in files.items() for sol in sols]
    for layer, stem in stems:
        if stem == subject:
            return layer
    for layer, stem in stems:
        if stem.startswith(subject):
            return layer
    best = max(((len(stem), layer) for layer, stem in stems if subject.startswith(stem)), default=None)
    return best[1] if best else "other"


def campaign_harnesses(build: str, layer: str) -> list[dict]:
    files = layer_files()
    if layer != "other" and layer not in files:
        raise SystemExit(f"ci-shards: layer {layer} is not in ../.github/security/mutation-layers.json")
    echidna = set(harnesses(build, ECHIDNA_DIR))
    return [
        {"harness": h, "echidna": h in echidna}
        for h in harnesses(build, ECHIDNA_DIR, MEDUSA_DIR)
        if harness_layer(h, files) == layer
    ]


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    what, rest = argv[0], argv[1:]
    opts = {}
    for flag in ("--layers", "--contracts", "--keys", "--skip", "--totals", "--chunks"):
        if flag in rest:
            i = rest.index(flag)
            opts[flag] = rest[i + 1] if i + 1 < len(rest) else ""
            rest = rest[:i] + rest[i + 2 :]
    layers = opts.get("--layers", "")
    contracts = opts.get("--contracts", "")
    keys = load(opts.get("--keys") or None, {})
    skip = set(load(opts.get("--skip") or None, []))
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
        plan = mutate_plan(load(opts.get("--totals") or None, {}), keys, int(opts.get("--chunks") or 1))
        for k, chunk in enumerate(plan["chunks"], 1):
            if len(chunk) > MAX_LEGS:
                print(f"ci-shards: mutate list {k} has {len(chunk)} legs, above GitHub's {MAX_LEGS}", file=sys.stderr)
                return 1
        print(json.dumps(plan, separators=(",", ":")))
        return 0
    if what == "gambit":
        legs = [{"layer": r[0], "contract": r[1], "key": keys.get(f"gambit:{r[0]}:{r[1]}", "")}
                for r in mutation("contracts", layers, contracts) if f"gambit:{r[0]}:{r[1]}" not in skip]
        return emit(legs, what)
    if what == "mutators-check":
        return mutators_check(sys.stdin.read())
    if what == "certora-mutate":
        return emit(certora_confs(layers), what)
    if what == "necessist":
        rows = [[layer, f.replace("\\", "/")] for layer, f in mutation("tests", layers, contracts)]
        legs = necessist_legs([r for r in rows if f"necessist:{r[0]}:{r[1]}" not in skip])
        for leg in legs:
            leg["keys"] = " ".join(keys.get(f"necessist:{leg['layer']}:{f}", "-") for f in leg["test"].split())
        return emit(legs, what)
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
