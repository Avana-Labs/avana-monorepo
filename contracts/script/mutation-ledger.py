#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Keys and stored results of the mutation gate (mutation-gate.yml), so a nightly run tests only what changed.

Each target has a key: a SHA-256 over everything its outcome depends on.

    mutate:<layer>:<Contract>   the contract's file and the files its tests compile: every file the matched test
                                files import, followed through relative and root-relative imports (src/, test/ and
                                script/ files) and through `deployCode`/`getCode` artifact names ("<Name>.sol:...",
                                every src/ or test/ file of that name), plus the paths of the matched test files
    gambit:<layer>:<Contract>   the same, plus security/gambit-triage.json
    necessist:<layer>:<file>    the test file and its imports, followed the same way

and every key also covers the files shared by all targets: foundry.toml, remappings.txt, soldeer.lock (the
dependencies and the Aave V4 and Uniswap v3 builds come from it), .foundry-version, requirements.txt,
script/install-security-tools.sh (tool versions), security/mutation-layers.json, the mutation scripts and
.github/workflows/mutation-gate.yml (budgets).

The ledger is a folder kept between runs (the `mutation-ledger-*` Actions cache): <tool>/<layer>/<target>/<key>/
holds the reports of a target's jobs that passed with that key. A target is current when its folder for today's key
holds a passed report of every shard (the `done` file each job writes when its tool step passed). Nightly runs skip
current targets; the full campaign (manual dispatch, `v*` tags) runs everything and refreshes the ledger.

    mutation-ledger.py keys [--layers L] [--contracts C]          JSON {"<tool>:<layer>:<target>": key}
    mutation-ledger.py current <ledger> <keys.json>               JSON list of the current targets
    mutation-ledger.py done <report dir> <entry> <key> [--shard K --shards N]
                                                                  marks a job's report as passed
    mutation-ledger.py merge <ledger> <reports> <keys.json>       adds the passed reports of a run to the ledger,
                                                                  keeps only today's keys, prints what it added

<reports>: a folder holding the run's artifacts as actions/download-artifact writes them (one folder per artifact).
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent
SHARED = [
    "foundry.toml",
    "remappings.txt",
    "soldeer.lock",
    ".foundry-version",
    "requirements.txt",
    "script/install-security-tools.sh",
    "security/mutation-layers.json",
    "script/ci-shards.py",
    "script/mutation-targets.py",
    "script/mutation-test.py",
    "script/mutation-slither.py",
    "script/mutation-ledger.py",
    "script/mutation-records.py",
    "script/security-slow.sh",
    "script/security-gambit.sh",
    "script/security-gate.py",
]
SHARED_REPO = [".github/workflows/mutation-gate.yml"]
IMPORT = re.compile(r"""\bimport\s+(?:[^;"']*?\bfrom\s+)?["']([^"']+)["']""", re.S)
ARTIFACT = re.compile(r"""["'](\w+)\.sol:\w+""")


def _module(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "script" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def remappings() -> list[tuple[str, str, str]]:
    out = []
    for line in (ROOT / "remappings.txt").read_text(encoding="utf8").splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        lhs, target = line.split("=", 1)
        ctx, _, prefix = lhs.rpartition(":")
        out.append((ctx, prefix, target))
    return out


class Closure:
    def __init__(self) -> None:
        self.remaps = remappings()
        self.by_name: dict[str, list[Path]] = {}
        for top in ("src", "test"):
            for sol in (ROOT / top).rglob("*.sol"):
                self.by_name.setdefault(sol.stem, []).append(Path(os.path.normpath(sol)))
        self.edges: dict[Path, tuple[list[Path], list[str]]] = {}
        self.memo: dict[Path, tuple[frozenset[Path], frozenset[str]]] = {}

    def resolve(self, frm: Path, spec: str) -> Path | str | None:
        """The project file an import names, None for a dependency, or the spec itself when nothing matches."""
        if spec.startswith("."):
            return Path(os.path.normpath(frm.parent / spec))
        rel = frm.relative_to(ROOT).as_posix()
        best = None
        for ctx, prefix, target in self.remaps:
            if spec.startswith(prefix) and (not ctx or rel.startswith(ctx)):
                if best is None or len(prefix) > len(best[0]):
                    best = (prefix, target)
        if best:
            spec = best[1] + spec[len(best[0]) :]
        if spec.startswith("dependencies/"):
            return None
        path = Path(os.path.normpath(ROOT / spec))
        return path if path.is_file() else spec

    def direct(self, f: Path) -> tuple[list[Path], list[str]]:
        """The project files one file imports or names as an artifact, and import specs that name no file."""
        if f not in self.edges:
            text = f.read_text(encoding="utf8", errors="replace")
            files: list[Path] = []
            loose: list[str] = []
            for spec in IMPORT.findall(text):
                r = self.resolve(f, spec)
                if isinstance(r, Path):
                    files.append(r)
                elif isinstance(r, str):
                    loose.append(r)
            for name in ARTIFACT.findall(text):
                files.extend(self.by_name.get(name, []))
            self.edges[f] = (files, loose)
        return self.edges[f]

    def files(self, start: Path) -> tuple[frozenset[Path], frozenset[str]]:
        """Every project file `start` compiles with, and any import spec that names no file."""
        start = Path(os.path.normpath(start if start.is_absolute() else ROOT / start))
        if start in self.memo:
            return self.memo[start]
        seen: set[Path] = set()
        loose: set[str] = set()
        todo = [start]
        while todo:
            f = todo.pop()
            if f in seen or not f.is_file():
                continue
            seen.add(f)
            files, lo = self.direct(f)
            todo.extend(files)
            loose.update(lo)
        self.memo[start] = (frozenset(seen), frozenset(loose))
        return self.memo[start]


FILE_HASHES: dict[Path, str] = {}


def file_hash(p: Path) -> str:
    if p not in FILE_HASHES:
        FILE_HASHES[p] = hashlib.sha256(p.read_bytes()).hexdigest()
    return FILE_HASHES[p]


def digest(paths: set[Path], extra: list[str]) -> str:
    h = hashlib.sha256()
    for p in sorted(paths, key=lambda p: p.as_posix()):
        rel = os.path.relpath(p, REPO).replace(os.sep, "/")
        h.update(rel.encode("utf8") + b"\0")
        h.update(file_hash(p).encode("ascii") + b"\n")
    for e in sorted(extra):
        h.update(b"extra\0" + e.encode("utf8") + b"\n")
    return h.hexdigest()


def keys(layers: str, contracts: str) -> dict[str, str]:
    targets = _module("mutation_targets_keys", "mutation-targets.py")
    config = json.loads((ROOT / "security/mutation-layers.json").read_text(encoding="utf8"))
    shared = {ROOT / f for f in SHARED if (ROOT / f).is_file()} | {REPO / f for f in SHARED_REPO if (REPO / f).is_file()}
    triage = ROOT / "security/gambit-triage.json"
    closure = Closure()
    want_layers, want_names = set(layers.split()), set(contracts.split())
    out: dict[str, str] = {}
    for layer, entries in config["layers"].items():
        if want_layers and layer not in want_layers:
            continue
        seen_tests: set[str] = set()
        for entry in entries:
            folder = ROOT / entry["src"]
            globs = entry.get("files", ["*"])
            files = [f for f in targets.implementations(folder)
                     if (not want_names or f.stem in want_names) and any(_match(f.stem, g) for g in globs)]
            if not files:
                continue
            tests = sorted({Path(os.path.normpath(t)) for pattern in targets.braces(entry["tests"])
                            for t in ROOT.glob(pattern) if t.suffix == ".sol"})
            test_files: set[Path] = set()
            loose: set[str] = set()
            for t in tests:
                f, l = closure.files(t)
                test_files |= f
                loose |= l
            names = [t.relative_to(ROOT).as_posix() for t in tests]
            for sol in files:
                own, own_loose = closure.files(sol)
                paths = shared | own | test_files
                extra = sorted(loose | own_loose) + [f"tests:{entry['tests']}"] + [f"test:{n}" for n in names]
                out[f"mutate:{layer}:{sol.stem}"] = digest(paths, extra)
                out[f"gambit:{layer}:{sol.stem}"] = digest(paths | ({triage} if triage.is_file() else set()), extra)
            for t in tests:
                rel = t.relative_to(ROOT).as_posix()
                if rel in seen_tests:
                    continue
                seen_tests.add(rel)
                f, l = closure.files(t)
                out[f"necessist:{layer}:{rel}"] = digest(shared | f, sorted(l))
    return out


def _match(name: str, glob: str) -> bool:
    import fnmatch

    return fnmatch.fnmatchcase(name, glob)


def entry_dir(ledger: Path, entry: str) -> Path:
    tool, layer, target = entry.split(":", 2)
    return ledger / tool / layer / target.replace("/", "__")


def current(ledger: Path, wanted: dict[str, str]) -> list[str]:
    out = []
    for entry, key in sorted(wanted.items()):
        d = entry_dir(ledger, entry) / key
        if not d.is_dir():
            continue
        done = [json.loads(p.read_text(encoding="utf8")) for p in d.glob("**/done*.json")]
        done = [x for x in done if x.get("entry") == entry]
        if not done or any(x.get("key") != key for x in done):
            continue
        shards = {x.get("shards", 1) for x in done}
        if len(shards) != 1:
            continue
        n = shards.pop()
        if sorted(x.get("shard", 1) for x in done) == list(range(1, n + 1)):
            out.append(entry)
    return out


def merge(ledger: Path, reports: Path, wanted: dict[str, str]) -> int:
    added = 0
    for done_file in sorted(reports.glob("*/**/done*.json")):
        done = json.loads(done_file.read_text(encoding="utf8"))
        entry, key = done.get("entry", ""), done.get("key", "")
        if wanted.get(entry) != key:
            continue
        dest = entry_dir(ledger, entry) / key
        # The job's report folder: the folder of its done file, without the per-mutant logs and sources.
        src = done_file.parent
        target = dest / (f"shard-{done['shard']}" if done.get("shards", 1) > 1 or entry.startswith("mutate:") else ".")
        target.mkdir(parents=True, exist_ok=True)
        for f in src.iterdir():
            if f.name.startswith("done") and f != done_file:
                continue
            if f.is_file() and f.suffix in (".json", ".tsv", ".log", ".txt"):
                shutil.copy2(f, target / f.name)
        if entry.startswith("gambit:"):
            mlog = src / "gambit" / "mutants.log"
            if mlog.is_file():
                (target / "gambit").mkdir(exist_ok=True)
                shutil.copy2(mlog, target / "gambit" / "mutants.log")
        added += 1
    # Keep only today's key of each target.
    for tool_dir in [d for d in ledger.iterdir() if d.is_dir()] if ledger.is_dir() else []:
        for layer_dir in [d for d in tool_dir.iterdir() if d.is_dir()]:
            for target_dir in [d for d in layer_dir.iterdir() if d.is_dir()]:
                entry = f"{tool_dir.name}:{layer_dir.name}:{target_dir.name.replace('__', '/')}"
                for key_dir in [d for d in target_dir.iterdir() if d.is_dir()]:
                    if entry in wanted and wanted[entry] != key_dir.name:
                        shutil.rmtree(key_dir)
    ledger.mkdir(parents=True, exist_ok=True)
    print(f"ledger: {added} job report(s) added, {len(current(ledger, wanted))} of {len(wanted)} targets current")
    return 0


def done(folder: Path, entry: str, key: str, shard: int, shards: int) -> int:
    """Marks a job's report folder as passed for the ledger: done.json (done-<k>.json for a shard of a slither-mutate
    target, done-<hash>.json for one test file of a Necessist job)."""
    if not key or key == "-":
        print(f"ledger: no key for {entry}; its report is not stored")
        return 0
    record = {"entry": entry, "key": key, "shard": shard, "shards": shards}
    name = "done.json"
    if entry.startswith("mutate:"):
        name = f"done-{shard}.json"
    elif entry.startswith("necessist:"):
        name = f"done-{hashlib.sha256(entry.encode('utf8')).hexdigest()[:12]}.json"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / name).write_text(json.dumps(record) + "\n", encoding="utf8")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="what", required=True)
    p = sub.add_parser("keys")
    p.add_argument("--layers", default="")
    p.add_argument("--contracts", default="")
    p = sub.add_parser("current")
    p.add_argument("ledger", type=Path)
    p.add_argument("keys", type=Path)
    p = sub.add_parser("merge")
    p.add_argument("ledger", type=Path)
    p.add_argument("reports", type=Path)
    p.add_argument("keys", type=Path)
    p = sub.add_parser("done")
    p.add_argument("dir", type=Path)
    p.add_argument("entry")
    p.add_argument("key")
    p.add_argument("--shard", type=int, default=1)
    p.add_argument("--shards", type=int, default=1)
    args = parser.parse_args()
    if args.what == "done":
        return done(args.dir, args.entry, args.key, args.shard, args.shards)
    if args.what == "keys":
        print(json.dumps(keys(args.layers, args.contracts), indent=0, sort_keys=True))
    elif args.what == "current":
        print(json.dumps(current(args.ledger, json.loads(args.keys.read_text(encoding="utf8")))))
    else:
        return merge(args.ledger, args.reports, json.loads(args.keys.read_text(encoding="utf8")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
