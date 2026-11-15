#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Summarises the reports of a mutation-gate run into docs/audit/mutation/results/.

Input: a folder holding the run's artifacts as `gh run download <run>` writes them (one folder per artifact), and the
run's job list (`gh run view <run> --json jobs > jobs.json`). Output: `README.md` (the summary tables) and
`survivors.md` (every surviving or timed-out mutant and every Necessist removal that left its tests passing).

    slither-mutate  mutate-<layer>-<Contract>-<group>/<layer>/<Contract>.log: "<Kind> mutants: k caught of n" per
                    kind, "UNCAUGHT" lines for the survivors; a mutant that does not compile is not counted by
                    slither-mutate and is reported here as not compiled.
    Gambit          gambit-<layer>-<Contract>/<layer>/<Contract>/status.tsv (id, killed | survived | timeout |
                    invalid) and gambit/mutants.log (id, operator, file, line:column, original, replacement).
    Necessist       necessist-<layer>-<file>/<layer>.log: "N candidates in ..." and one "... passed" line per
                    statement whose removal left the tests passing.

A job that has not finished is listed as pending, one that failed or was cancelled without a report as inconclusive.

    mutation-report.py <artifacts dir> <jobs.json> <run id> <commit> <out dir> [<inflated>]

<inflated>: comma-separated contract name patterns whose mutants this run tested without some of their own test
suites (a test-selection gap in security/mutation-layers.json); their survivors are marked "inflated, rerun pending".
"""

import fnmatch
import importlib.util
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

KIND = re.compile(r"(Revert|Comment|Tweak) mutants: (\d+) caught of (\d+)")
COMPILE_FAIL = "ERROR:CryticCompile:'forge' returned non-zero exit code"
JOB = re.compile(r"^(mutate|gambit|necessist) (\S+) (.+?)(?: \(group (\d)\))?$")


def _records():
    """script/mutation-records.py, which reads a mutant or statement that spans several log lines whole."""
    spec = importlib.util.spec_from_file_location("mutation_records", Path(__file__).with_name("mutation-records.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RECORDS = _records()


def rate(killed: int, counted: int) -> str:
    return f"{100.0 * killed / counted:.1f} %" if counted else "-"


def md(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ").strip()


def main() -> int:
    art, jobs_file, run, commit, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4], Path(sys.argv[5])
    jobs = json.loads(jobs_file.read_text(encoding="utf8"))["jobs"]
    inflated = [p for p in (sys.argv[6] if len(sys.argv) > 6 else "").split(",") if p]

    def mark(contract: str, result: str) -> str:
        return f"{result} (inflated, rerun pending)" if any(fnmatch.fnmatch(contract, p) for p in inflated) else result

    # Per contract: tool -> counters; survivors as rows.
    stats: dict[tuple[str, str], dict[str, int]] = defaultdict(lambda: defaultdict(int))
    survivors: list[tuple[str, str, str, str, str, str]] = []  # tool, layer, contract, location, change, result
    necessist: list[tuple[str, str, int, int]] = []  # layer, files, candidates, passed
    necessist_rows: list[tuple[str, str, str]] = []  # layer, location, statement
    pending: list[str] = []
    inconclusive: list[str] = []

    for job in jobs:
        m = JOB.match(job["name"])
        if not m:
            continue
        tool, layer, target, group = m.groups()
        if job["status"] != "completed":
            pending.append(job["name"])
            continue
        if tool == "mutate":
            log = art / f"mutate-{layer}-{target}-{group}" / layer / f"{target}.log"
            if not log.exists():
                inconclusive.append(f"{job['name']} ({job['conclusion']}, no report)")
                continue
            text = log.read_text(encoding="utf8", errors="replace")
            s = stats[(layer, target)]
            for _, caught, total in KIND.findall(text):
                s["mutate_total"] += int(total)
                s["mutate_killed"] += int(caught)
            s["mutate_not_compiled"] += text.count(COMPILE_FAIL)
            for _, kind, line, orig, mut in RECORDS.uncaught(text):
                survivors.append(("slither-mutate", layer, target, f"line {line} ({kind})", f"`{md(orig)}` → `{md(mut)}`", mark(target, "survived")))
            if job["conclusion"] != "success":
                inconclusive.append(f"{job['name']} ({job['conclusion']})")
        elif tool == "gambit":
            base = art / f"gambit-{layer}-{target}" / layer / target
            status = base / "status.tsv"
            if not status.exists():
                inconclusive.append(f"{job['name']} ({job['conclusion']}, no report)")
                continue
            ops = {}
            mlog = base / "gambit" / "mutants.log"
            if mlog.exists():
                for row in mlog.read_text(encoding="utf8", errors="replace").splitlines():
                    parts = row.split(",", 5)
                    if len(parts) == 6:
                        ops[parts[0]] = parts
            s = stats[(layer, target)]
            for row in status.read_text(encoding="utf8").splitlines():
                if "\t" not in row:
                    continue
                mid, result = row.split("\t", 1)
                s[f"gambit_{result}"] += 1
                if result in ("survived", "timeout"):
                    p = ops.get(mid, [mid, "?", "?", "?", "?", "?"])
                    survivors.append(("Gambit", layer, target, f"`{p[2]}` {p[3]} ({p[1]}, mutant {mid})", f"`{md(p[4])}` → `{md(p[5])}`", mark(target, result)))
            s["gambit_seen"] += 1
            if job["conclusion"] != "success" and not any(s[f"gambit_{r}"] for r in ("killed", "survived", "timeout", "invalid")):
                inconclusive.append(f"{job['name']} ({job['conclusion']})")
        else:
            files = target
            # The artifact is named after the last test file of the leg.
            stem = Path(files.split()[-1]).stem
            log = art / f"necessist-{layer}-{stem}" / f"{layer}.log"
            if not log.exists():
                inconclusive.append(f"{job['name']} ({job['conclusion']}, no report)")
                continue
            text = log.read_text(encoding="utf8", errors="replace")
            cand = re.search(r"(\d+) candidates in", text)
            passed = [(loc, stmt) for _, loc, stmt in RECORDS.necessist_passed(text)]
            necessist.append((layer, files, int(cand.group(1)) if cand else 0, len(passed)))
            necessist_rows.extend((layer, loc, md(stmt)) for loc, stmt in passed)

    out.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Mutation results",
        "",
        f"Run: `mutation-gate` {run} on `main`, commit `{commit}`. Generated by `contracts/script/mutation-report.py` from the run's "
        "reports; `certoraMutate` did not run (`CERTORA_ENABLED` off). Kill rate = killed / (killed + survived + timed out); "
        "mutants that did not compile are not counted.",
        "",
        "## Summary",
        "",
        "| Contract | Layer | Mutations | Killed by existing tests | Survived | Timed out | Not compiled | Kill rate |",
        "|---|---|---|---|---|---|---|---|",
    ]
    tot = defaultdict(int)
    for (layer, name), s in sorted(stats.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        killed = s["mutate_killed"] + s["gambit_killed"]
        surv = (s["mutate_total"] - s["mutate_killed"]) + s["gambit_survived"]
        tout = s["gambit_timeout"]
        nc = s["mutate_not_compiled"] + s["gambit_invalid"]
        counted = killed + surv + tout
        for k, v in (("m", counted), ("k", killed), ("s", surv), ("t", tout), ("n", nc)):
            tot[k] += v
        flag = " (inflated, rerun pending)" if any(fnmatch.fnmatch(name, p) for p in inflated) else ""
        lines.append(f"| {name}{flag} | {layer} | {counted} | {killed} | {surv} | {tout} | {nc} | {rate(killed, counted)} |")
    lines.append(f"| **All** | | **{tot['m']}** | **{tot['k']}** | **{tot['s']}** | **{tot['t']}** | **{tot['n']}** | **{rate(tot['k'], tot['m'])}** |")
    lines += ["", "By tool:", "", "| Contract | Layer | slither-mutate killed / tested | Gambit killed / survived / timed out / invalid |", "|---|---|---|---|"]
    for (layer, name), s in sorted(stats.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        g = f"{s['gambit_killed']} / {s['gambit_survived']} / {s['gambit_timeout']} / {s['gambit_invalid']}" if s["gambit_seen"] else "pending"
        lines.append(f"| {name} | {layer} | {s['mutate_killed']} / {s['mutate_total']} | {g} |")
    lines += ["", "## Necessist", "", "Statements removed from the tests one at a time; a removal that leaves the tests passing is listed in [survivors.md](survivors.md#necessist).", "",
              "| Layer | Test files | Candidates | Removals that left the tests passing |", "|---|---|---|---|"]
    nc_tot = [0, 0]
    for layer, files, cand, passed in sorted(necessist):
        nc_tot[0] += cand
        nc_tot[1] += passed
        lines.append(f"| {layer} | {', '.join(f'`{f}`' for f in files.split())} | {cand} | {passed} |")
    lines.append(f"| **All** | | **{nc_tot[0]}** | **{nc_tot[1]}** |")
    if inflated:
        lines += ["", "Inflated: the mutants of " + ", ".join(f"`{p}`" for p in inflated) + " ran without some of their own test "
                  "suites in this run (the `tests` globs of `security/mutation-layers.json`, fixed after the run), so their survivors "
                  "are an upper bound; the mutation gate is re-dispatched for their layers once the fix is on `main`."]
    lines += ["", f"Jobs still running or queued when this was generated: {len(pending)}.", ""]
    if inconclusive:
        lines += ["Inconclusive jobs (failed or cancelled):", ""] + [f"- {j}" for j in inconclusive] + [""]
    (out / "README.md").write_text("\n".join(lines), encoding="utf8", newline="\n")

    sl = ["# Surviving mutants", "", f"`mutation-gate` {run}, commit `{commit}`. Each survivor is triaged in "
          "[findings-register.md](../../findings-register.md) section 2.2: a test that kills it, or the reason it is equivalent.", "",
          "## slither-mutate and Gambit", "", "| Tool | Layer | Contract | Location | Change | Result |", "|---|---|---|---|---|---|"]
    for row in sorted(survivors, key=lambda r: (r[1], r[2], r[0], r[3])):
        sl.append("| " + " | ".join(row) + " |")
    sl += ["", "## Necessist", "", "| Layer | Location | Removed statement |", "|---|---|---|"]
    for layer, loc, stmt in sorted(necessist_rows):
        sl.append(f"| {layer} | `{loc}` | `{stmt[:200]}` |")
    (out / "survivors.md").write_text("\n".join(sl) + "\n", encoding="utf8", newline="\n")
    print(f"contracts {len(stats)}, counted mutants {tot['m']}, killed {tot['k']}, survived {tot['s']}, timeouts {tot['t']}, "
          f"necessist passed {nc_tot[1]} of {nc_tot[0]}, pending jobs {len(pending)}, inconclusive {len(inconclusive)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
