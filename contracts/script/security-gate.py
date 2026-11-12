#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Severity gate for the security tools of security-fast.sh and security-slow.sh.

Reads one tool report, drops the findings accepted in a triage file, and exits 1 when a finding at or above the
threshold remains. Every finding is printed with its fingerprint so it can be fixed or accepted.

    security-gate.py <tool> <report> --triage <file> --fail-on <severity> [--summary <file>]

tool        slither | slither-upgradeability | aderyn | mythril | semgrep | 4naly3er | gambit
severity    high | medium | low | informational | optimization

For `gambit` the report is the output folder of security-gambit.sh (out-security/gambit): every
`<layer>/<Contract>/status.tsv` lists each mutant's result, and `<layer>/<Contract>/gambit/gambit_results.json` holds
its diff. A mutant the tests did not kill (`survived`) or did not finish on within the per-mutant budget (`timeout`) is
a high finding; its fingerprint hashes the operator, the file and the original and mutated source lines, so it stays
the same when code above it moves or the mutant gets another number.

Severity of Semgrep findings: ERROR high, WARNING medium, INFO low, and every rule of the `performance` category
optimization. Severity of 4naly3er findings: H high, M medium, L low, NC informational, GAS optimization.

Triage file (JSON):

    {
      "excluded_detectors": [{"check": "<detector>", "reason": "<why the detector does not run>"}],
      "accepted": [
        {"fingerprint": "<from the gate output>", "check": "<detector>", "file": "<path>", "reason": "<why>"},
        {"check": "<detector>", "files": "<glob>", "while": "no-implementation-in-folder", "reason": "<why>"}
      ]
    }

A fingerprint entry accepts one finding. A `files` entry accepts every finding of `check` in matching files; with
`while: no-implementation-in-folder` it applies only while the file's folder holds no implementation file (a contract,
or a library with functions), so the acceptance ends by itself once the folder holds one. Every entry needs a
non-empty reason. For Slither, `excluded_detectors` must list exactly the detectors in slither.config.json's
`detectors_to_exclude`, so every disabled detector carries a reason; for Semgrep and 4naly3er, findings of a check
listed in `excluded_detectors` (Semgrep rule ID, 4naly3er issue title) are dropped before the gate.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEVERITIES = ["optimization", "informational", "low", "medium", "high"]
IMPL_CONTRACT = re.compile(r"^\s*(abstract\s+)?contract\s", re.M)
LIBRARY = re.compile(r"^\s*library\s", re.M)
FUNCTION = re.compile(r"^\s*function\s", re.M)


def rank(severity: str) -> int:
    return SEVERITIES.index(severity.lower())


def source_line(path: str, line: int | None) -> str:
    """Whitespace-normalized source line, so a fingerprint survives code moving up or down the file."""
    if not path or not line:
        return ""
    try:
        lines = (ROOT / path).read_text(encoding="utf8").splitlines()
    except OSError:
        return ""
    return " ".join(lines[line - 1].split()) if 0 < line <= len(lines) else ""


def fingerprint(*parts: str) -> str:
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:16]


def slither_findings(report: dict) -> list[dict]:
    if not report.get("success", False):
        raise SystemExit(f"security-gate: Slither reported an error: {report.get('error')}")
    out = []
    for r in report.get("results", {}).get("detectors", []):
        path, line = "", None
        for el in r.get("elements", []):
            sm = el.get("source_mapping") or {}
            if sm.get("filename_relative"):
                path = sm["filename_relative"]
                line = (sm.get("lines") or [None])[0]
                break
        out.append(
            {
                "check": r["check"],
                # slither-check-upgradeability results carry no impact; each one is a storage or initializer defect.
                "severity": r.get("impact", "High").lower(),
                "file": path,
                "line": line,
                # Slither's own `id` hashes a description that carries line numbers, so it changes whenever code
                # above the finding moves; the source-line fingerprint does not.
                "fingerprint": fingerprint("slither", r["check"], path, source_line(path, line)),
                "description": " ".join(r.get("description", "").split()),
            }
        )
    return out


def aderyn_findings(report: dict) -> list[dict]:
    out = []
    for key, severity in (("high_issues", "high"), ("low_issues", "low")):
        for issue in report.get(key, {}).get("issues", []):
            for inst in issue.get("instances", []):
                path, line = inst.get("contract_path", ""), inst.get("line_no")
                out.append(
                    {
                        "check": issue["detector_name"],
                        "severity": severity,
                        "file": path,
                        "line": line,
                        "fingerprint": fingerprint("aderyn", issue["detector_name"], path, source_line(path, line)),
                        "description": issue.get("title", ""),
                    }
                )
    return out


def mythril_findings(report: dict) -> list[dict]:
    """Report written by security-mythril.sh: {"<contract>": <myth -o json output>}."""
    out = []
    for contract, result in report.items():
        if result.get("error"):
            raise SystemExit(f"security-gate: Mythril failed on {contract}: {result['error']}")
        for issue in result.get("issues", []):
            check = f"SWC-{issue.get('swc-id', '?')}"
            out.append(
                {
                    "check": check,
                    "severity": issue.get("severity", "high").lower(),
                    "file": contract,
                    "line": None,
                    "fingerprint": fingerprint("mythril", contract, check, issue.get("function", ""), issue["title"]),
                    "description": f"{issue['title']} in {issue.get('function', '?')}",
                }
            )
    return out


SEMGREP_SEVERITY = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}


def semgrep_findings(report: dict) -> list[dict]:
    if report.get("errors"):
        msgs = "; ".join(f"{e.get('type')}: {' '.join(str(e.get('message', '')).split())[:200]}" for e in report["errors"])
        raise SystemExit(f"security-gate: Semgrep reported {len(report['errors'])} error(s): {msgs}")
    out = []
    for r in report.get("results", []):
        # Rule IDs carry the path of the rules folder (tools.semgrep-smart-contracts.solidity.<category>.<id>); the
        # check is the rule's own ID, so a triage entry does not depend on where the rules are installed.
        check = r["check_id"].rsplit(".", 1)[-1]
        meta = r.get("extra", {}).get("metadata", {})
        severity = SEMGREP_SEVERITY.get(r.get("extra", {}).get("severity", "ERROR"), "high")
        if meta.get("category") == "performance":
            severity = "optimization"
        path, line = r["path"], r["start"]["line"]
        out.append(
            {
                "check": check,
                "severity": severity,
                "file": path,
                "line": line,
                "fingerprint": fingerprint("semgrep", check, path, source_line(path, line)),
                "description": " ".join(r.get("extra", {}).get("message", "").split()),
            }
        )
    return out


FOURNALYZER_SEVERITY = {"H": "high", "M": "medium", "L": "low", "NC": "informational", "GAS": "optimization"}
FOURNALYZER_ISSUE = re.compile(r'^### <a name="(H|M|L|NC|GAS)-\d+"></a>\[(?:H|M|L|NC|GAS)-\d+\] (.+)$')
FOURNALYZER_FILE = re.compile(r"^File: (\S+)$")
FOURNALYZER_LINE = re.compile(r"^(\d+): ")


def fournalyzer_findings(report: str) -> list[dict]:
    """Report written by 4naly3er (report.md): one `### [<type>-<n>] <title>` section per issue, then code blocks
    headed `File: <path>` whose instance lines start with `<line>: ` (continuation lines are indented)."""
    out = []
    severity = title = path = None
    for raw in report.splitlines():
        m = FOURNALYZER_ISSUE.match(raw)
        if m:
            severity, title, path = FOURNALYZER_SEVERITY[m.group(1)], m.group(2).strip(), None
            continue
        m = FOURNALYZER_FILE.match(raw)
        if m and title:
            path = m.group(1)
            continue
        if raw.startswith("```") and not raw.startswith("```solidity"):
            path = None
            continue
        m = FOURNALYZER_LINE.match(raw)
        if m and title and path:
            line = int(m.group(1))
            out.append(
                {
                    "check": title,
                    "severity": severity,
                    "file": path,
                    "line": line,
                    "fingerprint": fingerprint("4naly3er", title, path, source_line(path, line)),
                    "description": title,
                }
            )
    return out


def gambit_lines(diff: str) -> tuple[int | None, str, str]:
    """First original line number, original lines and mutated lines of a Gambit diff, whitespace-normalized; the
    `///` comment Gambit adds above each mutated line is dropped."""
    old: list[str] = []
    new: list[str] = []
    line: int | None = None
    first: int | None = None
    for raw in diff.splitlines():
        if raw.startswith("@@"):
            m = re.match(r"@@ -(\d+)", raw)
            line = int(m.group(1)) if m else None
        elif raw.startswith(("---", "+++")):
            continue
        elif raw.startswith("-"):
            old.append(" ".join(raw[1:].split()))
            if first is None:
                first = line
            line = line + 1 if line is not None else None
        elif raw.startswith("+"):
            text = " ".join(raw[1:].split())
            if not text.startswith("///"):
                new.append(text)
        elif line is not None:
            line += 1
    return first, " ".join(old), " ".join(new)


def gambit_findings(report_dir: Path) -> list[dict]:
    out = []
    statuses = sorted(report_dir.glob("*/*/status.tsv"))
    if not statuses:
        raise SystemExit(f"security-gate: no <layer>/<Contract>/status.tsv under {report_dir}")
    for status_file in statuses:
        results = status_file.parent / "gambit" / "gambit_results.json"
        mutants = {m["id"]: m for m in json.loads(results.read_text(encoding="utf8"))} if results.exists() else {}
        for row in status_file.read_text(encoding="utf8").splitlines():
            mid, _, status = row.partition("\t")
            if status not in ("survived", "timeout"):
                continue
            m = mutants.get(mid)
            if m is None:
                raise SystemExit(f"security-gate: mutant {mid} of {status_file} is missing from {results}")
            line, old, new = gambit_lines(m["diff"])
            path, check = m["original"], m["description"]
            out.append(
                {
                    "check": check,
                    "severity": "high",
                    "file": path,
                    "line": line,
                    "fingerprint": fingerprint("gambit", check, path, old, new),
                    "description": f"{status}: `{old}` -> `{new}` ({status_file.parent.name}, mutant {mid})",
                }
            )
    return out


def has_implementation(folder: Path) -> bool:
    for sol in folder.glob("*.sol"):
        text = sol.read_text(encoding="utf8")
        if IMPL_CONTRACT.search(text) or (LIBRARY.search(text) and FUNCTION.search(text)):
            return True
    return False


def accepted_by(finding: dict, entries: list[dict]) -> dict | None:
    for e in entries:
        if "fingerprint" in e:
            if e["fingerprint"] == finding["fingerprint"]:
                return e
            continue
        if e.get("check") != finding["check"] or not fnmatch.fnmatch(finding["file"], e.get("files", "")):
            continue
        if e.get("while") == "no-implementation-in-folder" and has_implementation((ROOT / finding["file"]).parent):
            continue
        return e
    return None


def check_triage(tool: str, triage: dict) -> list[str]:
    errors = []
    for e in triage.get("accepted", []) + triage.get("excluded_detectors", []):
        if not str(e.get("reason", "")).strip():
            errors.append(f"triage entry without a reason: {json.dumps(e)}")
        if "while" in e and e["while"] != "no-implementation-in-folder":
            errors.append(f"unknown condition in triage entry: {json.dumps(e)}")
    if tool == "slither":
        config = json.loads((ROOT / "slither.config.json").read_text(encoding="utf8"))
        disabled = {d for d in config.get("detectors_to_exclude", "").split(",") if d}
        explained = {e.get("check") for e in triage.get("excluded_detectors", [])}
        for d in sorted(disabled - explained):
            errors.append(f"slither.config.json excludes {d} without a reason in the triage file")
        for d in sorted(explained - disabled):
            errors.append(f"triage file explains {d}, which slither.config.json does not exclude")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "tool", choices=["slither", "slither-upgradeability", "aderyn", "mythril", "semgrep", "4naly3er", "gambit"]
    )
    parser.add_argument("report", type=Path)
    parser.add_argument("--triage", type=Path, required=True)
    parser.add_argument("--fail-on", default="low", choices=SEVERITIES)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()

    if args.tool == "gambit":
        report = args.report
    else:
        text = args.report.read_text(encoding="utf8")
        report = text if args.tool == "4naly3er" else json.loads(text)
    triage = json.loads(args.triage.read_text(encoding="utf8")) if args.triage.exists() else {}
    errors = check_triage(args.tool, triage)

    findings = {
        "slither": slither_findings,
        "slither-upgradeability": slither_findings,
        "aderyn": aderyn_findings,
        "mythril": mythril_findings,
        "semgrep": semgrep_findings,
        "4naly3er": fournalyzer_findings,
        "gambit": gambit_findings,
    }[args.tool](report)
    if args.tool in ("semgrep", "4naly3er"):
        excluded = {e.get("check") for e in triage.get("excluded_detectors", [])}
        findings = [f for f in findings if f["check"] not in excluded]

    entries = triage.get("accepted", [])
    used: set[int] = set()
    blocking, accepted, reported = [], [], []
    for f in findings:
        entry = accepted_by(f, entries)
        if entry is not None:
            used.add(id(entry))
            accepted.append((f, entry["reason"]))
        elif rank(f["severity"]) >= rank(args.fail_on):
            blocking.append(f)
        else:
            reported.append(f)

    lines = [f"{args.tool}: {len(findings)} finding(s); gate at {args.fail_on} and above"]
    groups: dict[tuple[str, str, str], int] = {}
    for f, reason in accepted:
        key = (f["severity"], f["check"], reason)
        groups[key] = groups.get(key, 0) + 1
    for (severity, check, reason), count in groups.items():
        lines.append(f"  accepted  {count} x [{severity}] {check}: {reason}")
    for f in reported:
        lines.append(f"  reported  [{f['severity']}] {f['check']} {f['file']}:{f['line'] or '-'} {f['fingerprint']}")
    for f in blocking:
        lines.append(f"  BLOCKING  [{f['severity']}] {f['check']} {f['file']}:{f['line'] or '-'} {f['fingerprint']}")
        lines.append(f"            {f['description'][:300]}")
    for e in entries:
        if id(e) not in used and "fingerprint" in e:
            lines.append(f"  stale triage entry (no matching finding): {e['fingerprint']} {e.get('check', '')}")
    for err in errors:
        lines.append(f"  TRIAGE ERROR {err}")
    status = 1 if blocking or errors else 0
    lines.append(f"{args.tool}: {'FAIL' if status else 'pass'} ({len(blocking)} blocking, {len(accepted)} accepted)")

    text = "\n".join(lines)
    print(text)
    if args.summary:
        args.summary.write_text(text + "\n", encoding="utf8")
    return status


if __name__ == "__main__":
    sys.exit(main())
