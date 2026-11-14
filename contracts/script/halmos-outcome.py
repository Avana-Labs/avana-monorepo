#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Budgets and outcomes of the Halmos step of the slow security tier (script/security-slow.sh halmos).

    halmos-outcome.py budget <contract> <check>
        Prints "<timeout> <loop>" when security/halmos-bounds.json lists the check (<loop> is "-" when the entry keeps
        HALMOS_LOOP), and nothing when it does not. Fails when the file is malformed: every entry needs `contract`,
        `check`, a positive integer `timeout` (seconds), a `reason` and an `approval`; `loop` is an optional positive
        integer; a check is listed at most once.
    halmos-outcome.py classify <log> <rc> <budget-exhausted 0|1> <out.json> [<contract> <check>]
        Reads the output of one Halmos run (<log>), its exit code and whether the wall-clock budget ended it, prints
        the outcome, writes it to <out.json> and, in GitHub Actions, to the job summary (GITHUB_STEP_SUMMARY), with a
        warning annotation for a bounded check. <contract> and <check> name the one check of a single-check run (each
        CI job); without them the run covered several checks and no outcome can be "bounded". Exits 0 on `pass` and
        `bounded`, 1 on `fail`.

Outcomes, in this order (Halmos 0.3.3 prints each counterexample as soon as the solver finds it, during the run, so a
run that the budget ends still shows every counterexample found before it):
    fail     the build failed; the run reached the memory cap (SECURITY_MEMORY_MAX) or was killed outside the budget;
             any `Counterexample` line (also "potentially invalid") or `[FAIL]` result; any `[ERROR]` result (an
             exception, a stuck path, every path reverting)
    bounded  a single check listed in security/halmos-bounds.json, with no counterexample, that the wall-clock budget
             ended (no result line) or that Halmos reported as `[TIMEOUT]` (a solver query answered unknown): no
             violation was found within the bounds, but the check did not run to completion
    fail     the same for a check not listed there, or for a run of several checks: a new slow check is noticed and
             either made faster or listed with a reason
    pass     Halmos exited 0 with "Symbolic test result: <n> passed; 0 failed" (exactly "1 passed" for a single check)
    fail     anything else (no result line, a non-zero exit)
A listed check that passes is reported as passing with a note that its entry can be removed.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BOUNDS = ROOT / "security/halmos-bounds.json"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def bounds() -> dict[tuple[str, str], dict]:
    data = json.loads(BOUNDS.read_text(encoding="utf8"))
    entries = data.get("bounded")
    if not isinstance(entries, list):
        raise SystemExit(f"halmos-outcome: {BOUNDS.name} has no `bounded` list")
    out: dict[tuple[str, str], dict] = {}
    for i, e in enumerate(entries):
        where = f"{BOUNDS.name} entry {i + 1}"
        for field in ("contract", "check", "reason", "approval"):
            if not isinstance(e.get(field), str) or not e[field].strip():
                raise SystemExit(f"halmos-outcome: {where} has no `{field}`")
        for field in ("timeout", "loop"):
            v = e.get(field)
            if (field == "timeout" or v is not None) and (type(v) is not int or v <= 0):
                raise SystemExit(f"halmos-outcome: {where}: `{field}` must be a positive integer")
        key = (e["contract"], e["check"])
        if key in out:
            raise SystemExit(f"halmos-outcome: {where}: {key[0]}.{key[1]} is listed twice")
        out[key] = e
    return out


def classify(log: str, rc: int, exhausted: bool, check: tuple[str, str] | None) -> tuple[str, str]:
    """(outcome, detail) of one run; see the module docstring."""
    text = ANSI.sub("", log)
    if re.search(r"Build failed|Unable to resolve imports|Compiler run failed", text):
        return "fail", "the build failed"
    if not exhausted and re.search(r"OUT OF MEMORY|killed by SIGKILL", text):
        return "fail", "ended by the memory cap or SIGKILL before its budget"
    if re.search(r"Counterexample", text) or re.search(r"^\[FAIL\]", text, re.M):
        return "fail", "counterexample"
    if re.search(r"^\[ERROR\]", text, re.M):
        return "fail", "Halmos reported [ERROR]"
    solver_timeout = re.search(r"^\[TIMEOUT\]", text, re.M) is not None
    if exhausted or solver_timeout:
        why = "the wall-clock budget ran out" if exhausted else "a solver query timed out ([TIMEOUT])"
        if check is None:
            return "fail", f"{why} on a run of several checks"
        entry = bounds().get(check)
        if entry is None:
            return "fail", f"{why}, and the check is not in security/halmos-bounds.json"
        return "bounded", f"{why}; no violation found within the bounds, not run to completion"
    want = r"1 passed; 0 failed" if check else r"[0-9]+ passed; 0 failed"
    if rc == 0 and re.search(rf"Symbolic test result: {want}", text):
        if check and check in bounds():
            return "pass", "ran to completion; its entry in security/halmos-bounds.json can be removed"
        return "pass", "ran to completion"
    if not re.search(r"Symbolic test result: [0-9]+ passed", text):
        return "fail", f"no test result (exit code {rc})"
    return "fail", f"Halmos exited {rc}"


def report(outcome: str, detail: str, check: tuple[str, str] | None, out: Path, rc: int, exhausted: bool) -> None:
    name = f"{check[0]}.{check[1]}" if check else "Halmos run"
    label = {"pass": "PASS", "bounded": "BOUNDED", "fail": "FAIL"}[outcome]
    line = f"halmos {name}: {label}, {detail}"
    print(line)
    entry = bounds().get(check) if check else None
    record = {"check": name, "outcome": outcome, "detail": detail, "exit_code": rc, "budget_exhausted": exhausted}
    if entry:
        record.update({"timeout": entry["timeout"], "loop": entry.get("loop"), "reason": entry["reason"]})
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(record, indent=2) + "\n", encoding="utf8")
    if os.environ.get("GITHUB_ACTIONS") == "true" and outcome == "bounded":
        print(f"::warning title=Halmos bounded::{name}: no violation found within the bounds, not run to completion")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        heading = {
            "pass": "passed",
            "bounded": "bounded, no violation found (not run to completion)",
            "fail": "FAILED",
        }[outcome]
        with open(summary, "a", encoding="utf8") as f:
            f.write(f"### Halmos {name}: {heading}\n\n{detail[0].upper()}{detail[1:]}.\n")
            if entry:
                f.write(f"\nBudget {entry['timeout']} s (security/halmos-bounds.json): {entry['reason']}\n")
            f.write("\n")


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "budget":
        entry = bounds().get((argv[1], argv[2]))
        if entry:
            print(f"{entry['timeout']} {entry.get('loop') or '-'}")
        return 0
    if argv and argv[0] == "classify" and len(argv) in (5, 7):
        log, rc, exhausted, out = argv[1], int(argv[2]), argv[3] == "1", Path(argv[4])
        check = (argv[5], argv[6]) if len(argv) == 7 else None
        text = Path(log).read_text(encoding="utf8", errors="replace") if Path(log).is_file() else ""
        outcome, detail = classify(text, rc, exhausted, check)
        report(outcome, detail, check, out, rc, exhausted)
        return 0 if outcome in ("pass", "bounded") else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
