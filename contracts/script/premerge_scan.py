#!/usr/bin/env python3
"""Scan staged changes, outgoing commits, PR text, or an email draft against the local disclosure policy."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.getenv("PREMERGE_REPO_ROOT", Path(__file__).resolve().parents[2]))
POLICY = Path(os.getenv("PREMERGE_POLICY_PATH", ROOT / ".github" / "security" / "premerge-names.json"))

METADATA_RULES = (
    ("private IP address", re.compile(r"(?<![\d.])(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.(?:\d{1,3}\.)\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.(?:\d{1,3}\.)\d{1,3})(?![\d.])")),
    ("internal hostname", re.compile(r"\b(?:[a-z0-9-]+\.)+(?:internal|intranet|corp|private|cluster\.local)\b", re.IGNORECASE)),
    ("local user path", re.compile(r"(?:[A-Z]:\\Users\\[^\\\s]+|/home/[^/\s]+|/Users/[^/\s]+)", re.IGNORECASE)),
    ("infrastructure account identifier", re.compile(r"\b(?:aws[_ -]?)?(?:account[_ -]?)?\d{12}\b", re.IGNORECASE)),
    ("debug output", re.compile(r"\b(?:console\.log\s*\(|debugger\s*;|print\s*\(\s*['\"](?:DEBUG|TRACE))", re.IGNORECASE)),
)
SENSITIVE_FILENAMES = re.compile(r"(?:^|/)(?:\.env(?:\.[^/]+)?|id_rsa|id_ed25519|[^/]+\.(?:pem|p12|pfx|key))$", re.IGNORECASE)


def git(*args: str) -> str:
    result = subprocess.run(["git", *args], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def load_policy() -> dict:
    policy = json.loads(POLICY.read_text(encoding="utf-8"))
    for key in ("disallowed_names", "restricted_names"):
        if key not in policy:
            policy[key] = []
        if not isinstance(policy[key], list) or any(not isinstance(item, str) or not item.strip() for item in policy[key]):
            raise ValueError(f"{key} in {POLICY.relative_to(ROOT)} must be a list of non-empty strings")
    for key in ("incorrect_terminology",):
        if key not in policy:
            policy[key] = []
        if not isinstance(policy[key], list):
            raise ValueError(f"{key} in {POLICY.relative_to(ROOT)} must be a list")
    return policy


def findings_for_text(text: str, source: str, policy: dict) -> list[str]:
    findings = [f"{source}: possible {label}" for label, pattern in METADATA_RULES if pattern.search(text)]
    for name in policy["disallowed_names"]:
        # AI product names are case-sensitive here to avoid flagging ordinary words such as `continue`.
        flags = re.IGNORECASE if source in ("push branch", "PR branch") else 0
        pattern = re.compile(rf"(?<![A-Za-z0-9]){re.escape(name)}(?![A-Za-z0-9])", flags)
        if pattern.search(text):
            findings.append(f"{source}: disallowed name ({name})")
    for name in policy["restricted_names"]:
        pattern = re.compile(rf"(?<![A-Za-z0-9]){re.escape(name)}(?![A-Za-z0-9])", re.IGNORECASE)
        if pattern.search(text):
            findings.append(f"{source}: disallowed name ({name})")
    for entry in policy["incorrect_terminology"]:
        phrase = entry.get("phrase")
        preferred = entry.get("preferred", "approved terminology")
        if not isinstance(phrase, str) or not phrase:
            raise ValueError("each incorrect_terminology entry needs a non-empty phrase")
        if re.search(rf"(?<![A-Za-z0-9]){re.escape(phrase)}(?![A-Za-z0-9])", text, re.IGNORECASE):
            findings.append(f"{source}: use approved terminology '{preferred}'")
    return findings


def scan_diff(diff: str, policy: dict) -> list[str]:
    findings: list[str] = []
    path = "(unknown file)"
    line_no = 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path = line[6:]
            # The policy file contains the names being checked; scanning it would be self-referential.
            if path == ".github/security/premerge-names.json":
                continue
            if SENSITIVE_FILENAMES.search(path) and not path.endswith((".env.example", ".env.template")):
                findings.append(f"{path}: sensitive file name; do not commit local credentials/configuration")
        elif line.startswith("@@"):
            match = re.search(r"\+(\d+)", line)
            line_no = int(match.group(1)) - 1 if match else 0
        elif line.startswith("+") and not line.startswith("+++"):
            line_no += 1
            if path in (".github/security/premerge-names.json", "contracts/script/premerge_scan.py"):
                # Gitleaks and security-owned review cover edits to policy/control files.
                continue
            findings.extend(findings_for_text(line[1:], f"{path}:{line_no}", policy))
    return findings


def scan_range(spec: str, policy: dict) -> list[str]:
    return scan_diff(git("diff", "--no-ext-diff", "--unified=0", spec, "--"), policy)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--staged", action="store_true", help="scan staged additions")
    source.add_argument("--push", action="store_true", help="scan outgoing commit ranges and branch names from pre-push input")
    source.add_argument("--range", dest="diff_range", help="scan a Git revision range such as BASE...HEAD")
    source.add_argument("--pr-text", action="store_true", help="scan title, body and branch from PREMERGE_TITLE/BODY/BRANCH")
    source.add_argument("--email-file", type=Path, help="scan a UTF-8 email draft; provider DLP is still required for automatic enforcement")
    args = parser.parse_args()
    try:
        policy = load_policy()
        findings: list[str] = []
        if args.staged:
            findings.extend(scan_diff(git("diff", "--cached", "--no-ext-diff", "--unified=0", "--"), policy))
        elif args.diff_range:
            findings.extend(scan_range(args.diff_range, policy))
        elif args.pr_text:
            for label, value in (("PR title", os.getenv("PREMERGE_TITLE", "")), ("PR body", os.getenv("PREMERGE_BODY", "")), ("PR branch", os.getenv("PREMERGE_BRANCH", ""))):
                findings.extend(findings_for_text(value, label, policy))
        elif args.email_file:
            content = args.email_file.read_text(encoding="utf-8")
            findings.extend(findings_for_text(content, "email draft", policy))
        else:
            for row in sys.stdin:
                fields = row.strip().split()
                if len(fields) != 4:
                    continue
                local_ref, local_sha, _remote_ref, remote_sha = fields
                findings.extend(findings_for_text(local_ref, "push branch", policy))
                if set(local_sha) == {"0"}:
                    continue
                if set(remote_sha) == {"0"}:
                    try:
                        parent = git("rev-parse", f"{local_sha}^").strip()
                        spec = f"{parent}..{local_sha}"
                    except RuntimeError:
                        spec = f"{local_sha}^..{local_sha}"
                else:
                    spec = f"{remote_sha}..{local_sha}"
                findings.extend(scan_range(spec, policy))
        if findings:
            print("Pre-merge policy found possible disclosures or naming violations:", file=sys.stderr)
            for finding in findings:
                print(f"  {finding}", file=sys.stderr)
            return 1
        print("Pre-merge policy passed.")
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"premerge scan failed closed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

