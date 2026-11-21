#!/usr/bin/env python3
"""Scan staged or outgoing additions for confidential metadata and unauthorized AI names."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / ".github" / "security" / "premerge-names.json"

# High-confidence disclosure patterns. Gitleaks handles credential formats separately.
METADATA_RULES = (
    ("private IP address", re.compile(r"(?<![\d.])(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.(?:\d{1,3}\.)\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.(?:\d{1,3}\.)\d{1,3})(?![\d.])")),
    ("internal hostname", re.compile(r"\b(?:[a-z0-9-]+\.)+(?:internal|intranet|corp|private)\b", re.IGNORECASE)),
    ("local user path", re.compile(r"(?:[A-Z]:\\Users\\[^\\\s]+|/home/[^/\s]+|/Users/[^/\s]+)", re.IGNORECASE)),
    ("debug output", re.compile(r"\b(?:console\.log\s*\(|debugger\s*;|print\s*\(\s*['\"](?:DEBUG|TRACE))", re.IGNORECASE)),
)


def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def load_names() -> list[str]:
    data = json.loads(POLICY.read_text(encoding="utf-8"))
    names = data.get("disallowed_names", [])
    if not isinstance(names, list) or any(not isinstance(name, str) or not name.strip() for name in names):
        raise ValueError(f"{POLICY.relative_to(ROOT)} must contain a list of non-empty disallowed_names")
    return names


def scan_diff(diff: str, names: list[str]) -> list[str]:
    name_rules = [(name, re.compile(rf"(?<![A-Za-z0-9]){re.escape(name)}(?![A-Za-z0-9])", re.IGNORECASE)) for name in names]
    findings: list[str] = []
    path = "(unknown file)"
    line_no = 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
        elif line.startswith("@@"):
            match = re.search(r"\+(\d+)", line)
            line_no = int(match.group(1)) - 1 if match else 0
        elif line.startswith("+") and not line.startswith("+++"):
            line_no += 1
            content = line[1:]
            if path == ".github/security/premerge-names.json":
                continue
            for label, pattern in METADATA_RULES:
                if pattern.search(content):
                    findings.append(f"{path}:{line_no}: possible {label}")
            for name, pattern in name_rules:
                if pattern.search(content) or pattern.search(path):
                    findings.append(f"{path}:{line_no}: disallowed name from AI/tool vocabulary ({name})")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--staged", action="store_true", help="scan staged additions")
    source.add_argument("--push", action="store_true", help="scan outgoing commit ranges from Lefthook pre-push input")
    args = parser.parse_args()
    try:
        names = load_names()
        if args.staged:
            diff = git("diff", "--cached", "--no-ext-diff", "--unified=0", "--")
            findings = scan_diff(diff, names)
        else:
            findings = []
            for row in sys.stdin:
                fields = row.strip().split()
                if len(fields) != 4:
                    continue
                local_ref, local_sha, _remote_ref, remote_sha = fields
                for name in names:
                    pattern = re.compile(rf"(?<![A-Za-z0-9]){re.escape(name)}(?![A-Za-z0-9])", re.IGNORECASE)
                    if pattern.search(local_ref):
                        findings.append(f"branch name contains a disallowed AI/tool name ({name})")
                if set(local_sha) == {"0"}:
                    continue
                if set(remote_sha) == {"0"}:
                    parent = git("rev-parse", f"{local_sha}^").strip()
                    spec = f"{parent}..{local_sha}"
                else:
                    spec = f"{remote_sha}..{local_sha}"
                diff = git("diff", "--no-ext-diff", "--unified=0", spec, "--")
                findings.extend(scan_diff(diff, names))
        if findings:
            print("Pre-merge local scan found possible disclosures or disallowed names:", file=sys.stderr)
            for finding in findings:
                print(f"  {finding}", file=sys.stderr)
            print("Review the changed line or update the security-owned name policy.", file=sys.stderr)
            return 1
        print("Pre-merge local scan passed.")
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"premerge scan failed closed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
