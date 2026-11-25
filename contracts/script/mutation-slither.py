#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""slither-mutate's mutants of the mutation-gate targets, listed once and tested one shard per CI job
(mutation-gate.yml `mutants` and `mutate` jobs, security-slow.sh `mutate`).

slither-mutate tests a contract's mutants in one process, with no way to run part of them, and compiles each mutant
twice (a `forge build --build-info` of the file, then `forge test`); a large contract needed more than a job's 4 hours.
Here `list` runs Slither once over the project (pinned slither-analyzer in requirements.txt; the `mutation` profile
build) and writes every mutant of slither-mutate's own mutators for each target, in a fixed order (mutators by name,
each mutator's patches by source offset); `run` then tests the mutants of one target whose index i has
i mod <shards> = <shard> - 1, each with script/mutation-test.py (one compile, tests in the `mutation` profile, the
optimized-only tests in the default profile for a survivor). `run` needs no Slither. Every mutant is tested exactly
once across the shards, and a mutant's outcome never depends on another's: unlike slither-mutate without
--comprehensive, no line is skipped because a CR or RR mutant on it survived.

Mutators: script/ci-shards.py SLITHER_MUTATORS (CR, RR and the non-operator tweaks); the operator replacements
(AOR, ASOR, BOR, LOR, ROR, UOR) are Gambit's binary-op, unary-op and assignment mutants and run there. A mutator
that fails on a contract yields no mutant there, as in slither-mutate; the failure is recorded in the list.

    mutation-slither.py list <out dir> [--layers L] [--contracts C] [--skip F] [--mutators A,B]
        runs from the project (or isolated copy) root; writes <out dir>/<layer>/<Contract>.json (file, contract,
        layer, tests, mutators, the file's SHA-256, mutator errors and the mutants: mutator, byte offsets, line,
        original and replacement text) for every implementation file of ../.github/security/mutation-layers.json, except the
        "mutate:<layer>:<Contract>" entries of the JSON list in --skip, and prints {"<entry>": <mutants>}
    mutation-slither.py run <list json> <out dir> [--shard K --shards N] [--timeout S] [--optimized-timeout S]
        runs from the isolated copy's root
    mutation-slither.py count <file> <contract> [--mutators A,B]
        prints the number of mutants of one contract (a Slither run on that file alone)

`run` writes to <out dir>: shard-<K>.tsv (index, mutator, kind, line, outcome, seconds, original, replacement; the
two texts with backslash, newline and tab escaped), shard-<K>.json (totals, outcome counts, seconds), shard-<K>.log
(one line per mutant in slither-mutate's own format, plus TIMEOUT and INVALID lines), baseline.log and
mutants/<index>.log (each mutant's forge output). Exit 1 when the file differs from the listed one, the tests fail
without a mutant or a mutant cannot be restored; survivors and timeouts are a report, not a failure.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import inspect
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _module(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = _module("mutation_test", "mutation-test.py")
KIND = {"RR": "revert", "CR": "comment"}
LOG_KIND = {"killed": "CAUGHT", "survived": "UNCAUGHT", "timeout": "TIMEOUT", "invalid": "INVALID"}


def default_mutators() -> str:
    return _module("ci_shards", "ci-shards.py").SLITHER_MUTATORS


def mutator_classes(names: list[str]):
    from slither.tools.mutator.mutators import all_mutators
    from slither.tools.mutator.mutators.abstract_mutator import AbstractMutator

    found = {}
    for attr in dir(all_mutators):
        cls = getattr(all_mutators, attr)
        if inspect.isclass(cls) and issubclass(cls, AbstractMutator) and cls is not AbstractMutator:
            found[cls.NAME] = cls
    missing = [n for n in names if n not in found]
    if missing:
        raise SystemExit(f"mutation-slither: slither-mutate has no mutator {', '.join(missing)}")
    return [found[n] for n in sorted(names)]


def find(sl, file: str, contract: str):
    want = Path(file).resolve()
    for cu in sl.compilation_units:
        for c in cu.contracts:
            if c.name == contract and Path(c.source_mapping.filename.absolute).resolve() == want:
                return cu, c
    raise SystemExit(f"mutation-slither: Slither found no contract {contract} in {file}")


def mutants(sl, file: str, contract: str, names: list[str]) -> tuple[list[dict], list[str]]:
    """Every mutant of the contract (mutator, byte offsets, line, the two texts) in a fixed order, and the mutators
    that failed on it."""
    unit, target = find(sl, file, contract)
    want = Path(file).resolve()
    rows, errors = [], []
    for cls in mutator_classes(names):
        m = cls(unit, 0, "", None, target, None, False, Path("."), [])
        try:
            patches = m._mutate().get("patches", {})
        except Exception as e:  # noqa: BLE001 - as slither-mutate's AbstractMutator.mutate
            errors.append(f"{cls.NAME}: {e}")
            print(f"mutation-slither: {cls.NAME} mutator failed in {contract}: {e}", file=sys.stderr)
            continue
        for path, plist in patches.items():
            if Path(path).resolve() != want:
                raise SystemExit(f"mutation-slither: {cls.NAME} patched {path}, not {file}")
            for p in sorted(plist, key=lambda p: (p["start"], p["end"], p["new_string"])):
                rows.append({"mutator": cls.NAME, "start": p["start"], "end": p["end"], "line": p["line_number"],
                             "old": p["old_string"], "new": p["new_string"]})
    return rows, errors


def list_all(args) -> int:
    from slither import Slither

    targets = _module("mutation_targets", "mutation-targets.py")
    skip = set(json.loads(Path(args.skip).read_text(encoding="utf8"))) if args.skip else set()
    rows = []
    for line in targets_list(args.layers, args.contracts):
        layer, name, file, tests = line
        if f"mutate:{layer}:{name}" not in skip:
            rows.append((layer, name, file.replace("\\", "/"), tests))
    totals: dict[str, int] = {}
    if rows:
        start = time.monotonic()
        sl = Slither(".")
        print(f"mutation-slither: Slither read the project in {time.monotonic() - start:.0f} s", file=sys.stderr)
        names = args.mutators.split(",")
        for layer, name, file, tests in rows:
            found, errors = mutants(sl, file, name, names)
            record = {"layer": layer, "contract": name, "file": file, "tests": tests,
                      "mutators": ",".join(sorted(names)), "sha256": hashlib.sha256(Path(file).read_bytes()).hexdigest(),
                      "errors": errors, "mutants": found}
            out = args.out / layer
            out.mkdir(parents=True, exist_ok=True)
            (out / f"{name}.json").write_text(json.dumps(record, indent=0) + "\n", encoding="utf8")
            totals[f"mutate:{layer}:{name}"] = len(found)
    del targets
    print(json.dumps(totals, indent=0, sort_keys=True))
    return 0


def targets_list(layers: str, contracts: str) -> list[list[str]]:
    import subprocess

    out = subprocess.run([sys.executable, str(HERE / "mutation-targets.py"), "contracts", "--layers", layers,
                          "--contracts", contracts], check=True, capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.splitlines() if line.strip()]


def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def run(args) -> int:
    record = json.loads(args.list.read_text(encoding="utf8"))
    out = args.out
    (out / "mutants").mkdir(parents=True, exist_ok=True)
    rows, file, tests, name = record["mutants"], record["file"], record["tests"], record["contract"]
    k, n = args.shard, args.shards
    picked = [i for i in range(len(rows)) if i % n == k - 1]
    tag = f"shard-{k}"
    summary = {"layer": record["layer"], "contract": name, "file": file, "mutators": record["mutators"], "shard": k,
               "shards": n, "total": len(rows), "selected": len(picked), "mutator_errors": record["errors"],
               "counts": {o: 0 for o in LOG_KIND}, "seconds": 0.0}
    path = Path(file)
    original = path.read_bytes()
    if hashlib.sha256(original).hexdigest() != record["sha256"]:
        print(f"mutation-slither: {file} is not the file the mutants were listed from")
        return 1
    log = (out / f"{tag}.log").open("w", encoding="utf8")
    tsv = (out / f"{tag}.tsv").open("w", encoding="utf8")
    tsv.write("index\tmutator\tkind\tline\toutcome\tseconds\toriginal\treplacement\n")
    log.write(f"{name} ({file}): {len(rows)} mutants ({record['mutators']}), shard {k} of {n}: {len(picked)}\n")
    for e in record["errors"]:
        log.write(f"mutator failed, no mutant from it: {e}\n")
    status = 0
    (out / "baseline.log").write_text("", encoding="utf8")
    begin = time.monotonic()
    if picked and not RUNNER.baseline(tests, out / "baseline.log", optimized=False):
        log.write("Test suite fails without a mutant\n")
        print(f"mutation-slither: the tests of {name} fail without a mutant (see {out / 'baseline.log'})")
        status = 1
        picked = []
    summary["baseline_seconds"] = round(time.monotonic() - begin, 1)
    optimized: list[bool] = []

    def optimized_ready() -> bool:
        # The default-profile build is long (via-IR units), so it runs only once a mutant survives: once per job,
        # on the original file, then the mutant goes back in.
        if not optimized:
            mutant = path.read_bytes()
            path.write_bytes(original)
            try:
                optimized.append(RUNNER.optimized_baseline(tests, out / "baseline.log"))
            finally:
                path.write_bytes(mutant)
        return optimized[0]

    begin = time.monotonic()
    for i in picked:
        r = rows[i]
        start = time.monotonic()
        try:
            path.write_bytes(original[: r["start"]] + r["new"].encode("utf8") + original[r["end"] :])
            outcome = RUNNER.run(tests, out / "mutants" / f"{i}.log", args.timeout, args.optimized_timeout, True,
                                 optimized_ready)
        except RuntimeError as e:
            print(f"mutation-slither: {e} (see {out / 'baseline.log'})")
            log.write(f"Test suite fails without a mutant: {e}\n")
            status = 1
            break
        finally:
            path.write_bytes(original)
        secs = time.monotonic() - start
        summary["counts"][outcome] += 1
        kind = KIND.get(r["mutator"], "tweak")
        tsv.write(f"{i}\t{r['mutator']}\t{kind}\t{r['line']}\t{outcome}\t{secs:.1f}\t{escape(r['old'])}\t"
                  f"{escape(r['new'])}\n")
        log.write(f"INFO:Slither-Mutate:[{r['mutator']}] Line {r['line']}: '{r['old']}' ==> '{r['new']}' --> "
                  f"{LOG_KIND[outcome]}\n")
        log.flush()
        tsv.flush()
        print(f"  {i} {r['mutator']} line {r['line']}: {outcome} ({secs:.0f} s)", flush=True)
    summary["seconds"] = round(time.monotonic() - begin, 1)
    if path.read_bytes() != original:
        status = 1
        print(f"mutation-slither: {file} was not restored")
    c = summary["counts"]
    tested = sum(c.values())
    log.write(f"killed {c['killed']}, survived {c['survived']}, timeout {c['timeout']}, invalid {c['invalid']} "
              f"in {summary['seconds']} s\n")
    log.close()
    tsv.close()
    (out / f"{tag}.json").write_text(json.dumps(summary, indent=1) + "\n", encoding="utf8")
    per = f"; {summary['seconds'] / tested:.1f} s per mutant" if tested else ""
    print(f"{name} shard {k}/{n}: {tested} of {len(picked)} selected mutants ({len(rows)} in all); killed "
          f"{c['killed']}, survived {c['survived']}, timeout {c['timeout']}, invalid {c['invalid']}; baseline "
          f"{summary['baseline_seconds']} s{per}")
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="what", required=True)
    p = sub.add_parser("list")
    p.add_argument("out", type=Path)
    p.add_argument("--layers", default="")
    p.add_argument("--contracts", default="")
    p.add_argument("--skip", default="")
    p.add_argument("--mutators", default=None)
    p = sub.add_parser("run")
    p.add_argument("list", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--shard", type=int, default=1)
    p.add_argument("--shards", type=int, default=1)
    p.add_argument("--timeout", type=float, default=600)
    p.add_argument("--optimized-timeout", type=float, default=1800)
    p = sub.add_parser("count")
    p.add_argument("file")
    p.add_argument("contract")
    p.add_argument("--mutators", default=None)
    args = parser.parse_args()
    if getattr(args, "mutators", "x") is None:
        args.mutators = default_mutators()
    if args.what == "list":
        return list_all(args)
    if args.what == "count":
        from slither import Slither

        rows, _ = mutants(Slither(args.file), args.file, args.contract, args.mutators.split(","))
        print(len(rows))
        return 0
    if not 1 <= args.shard <= args.shards:
        parser.error("--shard must be between 1 and --shards")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
