#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Outcome of the Halmos step of the slow security tier (script/security-slow.sh halmos).

    halmos-outcome.py check
        Fails unless ../.github/security/halmos-bounds.json holds an empty `bounded` list. Every check must run to completion
        within its budget; there is no "bounded" outcome, so a check that runs out of time cannot pass by being listed.
    halmos-outcome.py classify <log> <rc> <budget-exhausted 0|1> <out.json> [<contract> <check>]
        Reads the output of one Halmos run (<log>), its exit code and whether the wall-clock budget ended it, prints
        the outcome, writes it to <out.json> and, in GitHub Actions, to the job summary (GITHUB_STEP_SUMMARY).
        <contract> and <check> name the one check of a single-check run (each CI job). Exits 0 on `pass`, 1 on `fail`.

Outcomes, in this order (Halmos 0.3.3 prints each counterexample as soon as the solver finds it, during the run, so a
run that the budget ends still shows every counterexample found before it):
    fail     the build failed; the run reached the memory cap (SECURITY_MEMORY_MAX) or was killed outside the budget;
             any `Counterexample` line (also "potentially invalid") or `[FAIL]` result; any `[ERROR]` result (an
             exception, a stuck path, every path reverting)
    fail     the wall-clock budget ended the run, Halmos reported `[TIMEOUT]` (a solver query answered unknown), or
             Halmos warned that the loop unrolling bound cut paths short (it still prints `[PASS]` then): the check
             did not run to completion, which is not a proof
    pass     Halmos exited 0 with "Symbolic test result: <n> passed; 0 failed" (exactly "1 passed" for a single check)
    fail     anything else (no result line, a non-zero exit)
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BOUNDS = ROOT / "../.github/security/halmos-bounds.json"
LOOP_BOUND = "paths have not been fully explored due to the loop unrolling bound"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def check_bounds() -> None:
    data = json.loads(BOUNDS.read_text(encoding="utf8"))
    entries = data.get("bounded")
    if not isinstance(entries, list):
        raise SystemExit(f"halmos-outcome: {BOUNDS.name} has no `bounded` list")
    if entries:
        names = ", ".join(f"{e.get('contract')}.{e.get('check')}" for e in entries if isinstance(e, dict))
        raise SystemExit(
            f"halmos-outcome: {BOUNDS.name} lists {len(entries)} check(s) ({names}); a check that does not run to "
            "completion fails, so make it complete (split its domain, prove a cheaper equivalent, or move the "
            "property to a tool that proves it) instead of listing it"
        )


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
    if exhausted:
        return "fail", "the wall-clock budget ran out before the check completed"
    if re.search(r"^\[TIMEOUT\]", text, re.M):
        return "fail", "a solver query timed out ([TIMEOUT]), so the check did not complete"
    # Halmos prints [PASS] for a check whose paths the loop unrolling bound cut short, with a warning that links its
    # wiki's loop-bound section; the warning's text may wrap across lines.
    if "warnings#loop-bound" in text or LOOP_BOUND in re.sub(r"\s+", " ", text):
        return "fail", "the loop unrolling bound cut paths short (Halmos warning loop-bound), so the check did not complete"
    want = r"1 passed; 0 failed" if check else r"[0-9]+ passed; 0 failed"
    if rc == 0 and re.search(rf"Symbolic test result: {want}", text):
        return "pass", "ran to completion"
    if not re.search(r"Symbolic test result: [0-9]+ passed", text):
        return "fail", f"no test result (exit code {rc})"
    return "fail", f"Halmos exited {rc}"


def report(outcome: str, detail: str, check: tuple[str, str] | None, out: Path, rc: int, exhausted: bool) -> None:
    name = f"{check[0]}.{check[1]}" if check else "Halmos run"
    print(f"halmos {name}: {outcome.upper()}, {detail}")
    record = {"check": name, "outcome": outcome, "detail": detail, "exit_code": rc, "budget_exhausted": exhausted}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(record, indent=2) + "\n", encoding="utf8")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        heading = {"pass": "passed", "fail": "FAILED"}[outcome]
        with open(summary, "a", encoding="utf8") as f:
            f.write(f"### Halmos {name}: {heading}\n\n{detail[0].upper()}{detail[1:]}.\n\n")


def main(argv: list[str]) -> int:
    if argv == ["check"]:
        check_bounds()
        return 0
    if argv and argv[0] == "classify" and len(argv) in (5, 7):
        check_bounds()
        log, rc, exhausted, out = argv[1], int(argv[2]), argv[3] == "1", Path(argv[4])
        check = (argv[5], argv[6]) if len(argv) == 7 else None
        text = Path(log).read_text(encoding="utf8", errors="replace") if Path(log).is_file() else ""
        outcome, detail = classify(text, rc, exhausted, check)
        report(outcome, detail, check, out, rc, exhausted)
        return 0 if outcome == "pass" else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
