#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Builds the AvanaTimelock operation for a UUPS upgrade, only after the slow security tier passed on the commit (TEST-263).

Every timelock-scheduled upgrade's implementation commit must have a green slow-tier run (5.1 TEST-263). Before it
outputs anything, this script asks GitHub for completed, successful runs of `.github/workflows/security-slow.yml` on
that commit:

    gh api repos/<repo>/actions/workflows/security-slow.yml/runs?head_sha=<sha>&status=success

and accepts a run only when its `head_sha` is the commit, it completed with conclusion `success`, its `slow-gate` job
passed, at least one slow-tier tool job (echidna, medusa, halmos, hevm, mythril) passed, and no campaign job ran (a
`workflow_dispatch` campaign run also ends with a green `slow-gate`, but it is not the slow tier). Any other answer,
including a `gh` error, refuses with exit 1 and prints nothing on stdout. On acceptance it runs
`script/upgrade/UpgradeOperation.s.sol` (forge script, no RPC), which writes the `schedule` and `execute` calldata of
`proxy.upgradeToAndCall(implementation, initData)` and records the commit and the run id.

Usage, from contracts/:
    script/upgrade-operation.py --proxy-name RiskModule --proxy 0x... --implementation-name RiskModule \
        --implementation 0x... --commit <sha> [--init-data 0x...] [--delay 432000] [--predecessor 0x...]

Environment: AVANA_GITHUB_REPO (default Avana-Labs/avana-monorepo). `gh` must be authenticated (GH_TOKEN in CI).
script/upgrade-operation.test.sh checks the refusals and the pass path with a stand-in `gh` on PATH.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CONTRACTS = Path(__file__).resolve().parents[1]
WORKFLOW = "security-slow.yml"
SCRIPT = "script/upgrade/UpgradeOperation.s.sol"
TOOL_JOBS = ("echidna ", "medusa ", "halmos ", "hevm ", "mythril ")
ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
HEX = re.compile(r"^0x(?:[0-9a-fA-F]{2})*$")
WORD = re.compile(r"^0x[0-9a-fA-F]{64}$")


class Refused(Exception):
    pass


def gh_json(path: str) -> dict:
    """`gh api <path>` as JSON; any failure refuses."""
    try:
        out = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=False)
    except FileNotFoundError as e:
        raise Refused("gh is not installed") from e
    if out.returncode != 0:
        raise Refused(f"gh api {path} failed: {out.stderr.strip() or out.returncode}")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError as e:
        raise Refused(f"gh api {path} returned no JSON") from e


def jobs_of(repo: str, run_id: int) -> list[dict]:
    jobs: list[dict] = []
    page = 1
    while True:
        batch = gh_json(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100&page={page}").get("jobs") or []
        jobs += batch
        if len(batch) < 100:
            return jobs
        page += 1


def slow_tier_run(repo: str, sha: str) -> dict:
    """The newest completed, successful slow-tier run of security-slow.yml on `sha`; refuses when there is none."""
    runs = gh_json(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?head_sha={sha}&status=success&per_page=100")
    candidates = [r for r in runs.get("workflow_runs") or []
                  if r.get("head_sha") == sha and r.get("status") == "completed" and r.get("conclusion") == "success"
                  and str(r.get("path", "")).endswith(f"/{WORKFLOW}")]
    why = []
    for run in sorted(candidates, key=lambda r: r.get("run_number", 0), reverse=True):
        jobs = {j.get("name", ""): j.get("conclusion") for j in jobs_of(repo, run["id"])}
        if jobs.get("slow-gate") != "success":
            why.append(f"run {run['id']}: slow-gate did not pass")
        elif any(n.startswith("campaign ") and c == "success" for n, c in jobs.items()):
            why.append(f"run {run['id']}: a fuzzing campaign run, not the slow tier")
        elif not any(n.startswith(TOOL_JOBS) and c == "success" for n, c in jobs.items()):
            why.append(f"run {run['id']}: no slow-tier tool job passed")
        else:
            return run
    detail = f" ({'; '.join(why)})" if why else ""
    raise Refused(f"no completed successful {WORKFLOW} slow-tier run on commit {sha}{detail}")


def full_sha(commit: str) -> str:
    out = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}"], cwd=CONTRACTS,
                         capture_output=True, text=True, check=False)
    sha = out.stdout.strip()
    if out.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise Refused(f"{commit} is not a commit of this repository")
    return sha


def parse(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--proxy-name", required=True)
    ap.add_argument("--proxy", required=True)
    ap.add_argument("--implementation-name", required=True)
    ap.add_argument("--implementation", required=True)
    ap.add_argument("--commit", required=True, help="the implementation's source commit")
    ap.add_argument("--init-data", default="0x")
    ap.add_argument("--delay", type=int, default=432_000)
    ap.add_argument("--predecessor", default="0x" + "00" * 32)
    a = ap.parse_args(argv)
    for flag, value, rx in (("--proxy-name", a.proxy_name, NAME), ("--implementation-name", a.implementation_name, NAME),
                            ("--proxy", a.proxy, ADDRESS), ("--implementation", a.implementation, ADDRESS),
                            ("--init-data", a.init_data, HEX), ("--predecessor", a.predecessor, WORD)):
        if not rx.match(value):
            raise Refused(f"{flag} {value!r} is not valid")
    if a.proxy.lower() == a.implementation.lower():
        raise Refused("--proxy and --implementation are the same address")
    return a


def main(argv: list[str]) -> int:
    try:
        a = parse(argv)
        sha = full_sha(a.commit)
        run = slow_tier_run(os.environ.get("AVANA_GITHUB_REPO", "Avana-Labs/avana-monorepo"), sha)
    except Refused as e:
        print(f"REFUSED  {e}", file=sys.stderr)
        return 1
    print(f"security-slow run {run['id']} passed on {sha}: {run.get('html_url', '')}", file=sys.stderr)
    env = dict(os.environ, AVANA_UPGRADE_PROXY_NAME=a.proxy_name, AVANA_UPGRADE_PROXY=a.proxy,
               AVANA_UPGRADE_IMPLEMENTATION_NAME=a.implementation_name, AVANA_UPGRADE_IMPLEMENTATION=a.implementation,
               AVANA_UPGRADE_COMMIT=sha, AVANA_UPGRADE_SLOW_RUN=str(run["id"]), AVANA_UPGRADE_INIT_DATA=a.init_data,
               AVANA_UPGRADE_DELAY=str(a.delay), AVANA_UPGRADE_PREDECESSOR=a.predecessor)
    return subprocess.run(["forge", "script", SCRIPT], cwd=CONTRACTS, env=env, check=False).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
