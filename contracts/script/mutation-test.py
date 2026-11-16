#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Runs a target's Foundry tests on the code as it is (one mutant applied, or none) and names the outcome, for
script/mutation-slither.py and script/security-gambit.sh. Run from the project copy the mutant is written into.

One `forge test -j 2 --fail-fast --match-path <tests>` in the `mutation` profile of foundry.toml (no optimizer, no
via-IR outside the files that need it) compiles src/ and the matched test files (only those: forge test compiles no
other test file) and runs the tests, bounded by <timeout> seconds for compile and tests together. The tests that
profile leaves out (its `no_match_test`: tests of the release build's gas) then run in the default profile, with their
own build folders (out-optimized/, cache-optimized/) and budget, only when every other test passed and only when the
matched files declare one of them; so a mutant they killed before is still killed. Outcomes:

    killed    a test failed (with `--test-compile-kills`, also: the tests no longer compile against the mutant while
              every src/ file still does, which is how slither-mutate counted it)
    survived  every matched test passed
    timeout   a run took longer than its budget; never counted as killed
    invalid   the mutant does not compile (a compiler error in a src/ file; without `--test-compile-kills`, any
              compiler error)

    mutation-test.py run <tests glob> <log> [--timeout S] [--optimized-timeout S] [--test-compile-kills]
        prints the outcome; exit 0 for every outcome
    mutation-test.py baseline <tests glob> <log>
        exit 0 when the tests pass without a mutant in the mutation profile and, when the glob matches one, the
        optimized-only tests pass in the default profile; 1 otherwise. No timeout: this first build of the copy
        compiles everything the tests need.

The fuzz runs come from FOUNDRY_FUZZ_RUNS in the environment, as for every forge run.
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import time
import tomllib
from pathlib import Path
from typing import Callable

PROFILE = "mutation"
OPTIMIZED_DIRS = {"FOUNDRY_OUT": "out-optimized", "FOUNDRY_CACHE_PATH": "cache-optimized"}
COMPILE_FAILED = re.compile(r"Compiler run failed|^Error(?: \(\d+\))?:", re.M)
ERROR_AT = re.compile(r"-->\s+(\S+?\.sol):\d+", re.M)


def braces(pattern: str) -> list[str]:
    """Expands {a,b} groups recursively, as forge --match-path globs do."""
    m = re.search(r"\{([^{}]*)\}", pattern)
    if not m:
        return [pattern]
    out = []
    for alt in m.group(1).split(","):
        out.extend(braces(pattern[: m.start()] + alt + pattern[m.end() :]))
    return out


def optimized_only_names(root: Path = Path(".")) -> list[str]:
    """The test names the mutation profile leaves out (`no_match_test`, an alternation of exact names)."""
    config = tomllib.loads((root / "foundry.toml").read_text(encoding="utf8"))
    pattern = config.get("profile", {}).get(PROFILE, {}).get("no_match_test", "")
    return [n for n in pattern.split("|") if re.fullmatch(r"\w+", n)]


def optimized_only_tests(tests: str, root: Path = Path(".")) -> list[str]:
    """The optimized-only tests declared in the files the glob matches."""
    names = optimized_only_names(root)
    found: list[str] = []
    for pattern in braces(tests):
        for path in sorted(root.glob(pattern)):
            if path.suffix == ".sol":
                text = path.read_text(encoding="utf8")
                found += [n for n in names if n not in found and re.search(rf"\bfunction\s+{n}\s*\(", text)]
    return found


def forge(args: list[str], log: Path, timeout: float | None, profile: str) -> tuple[int | None, str]:
    """`forge test -j 2 --fail-fast <args>` in the profile, in its own process group, its output appended to the log.
    Returns (exit code, output); the code is None when the run passed its timeout (the whole group is then stopped)."""
    env = dict(os.environ, FOUNDRY_PROFILE=profile)
    if profile == "default":
        env.update(OPTIMIZED_DIRS)
    cmd = ["forge", "test", "-j", "2", "--fail-fast", *args]
    posix = os.name == "posix"
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, start_new_session=posix)
    try:
        out, _ = proc.communicate(timeout=timeout)
        code: int | None = proc.returncode
    except subprocess.TimeoutExpired:
        if posix:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
        out, _ = proc.communicate()
        code = None
    text = out.decode("utf8", errors="replace")
    with log.open("a", encoding="utf8") as f:
        f.write(f"$ FOUNDRY_PROFILE={profile} {' '.join(cmd)}\n{text}\n")
        if code is None:
            f.write(f"timeout after {timeout:.0f} s\n")
    return code, text


def classify(code: int | None, text: str, test_compile_kills: bool) -> str:
    if code is None:
        return "timeout"
    if code == 0:
        return "survived"
    if COMPILE_FAILED.search(text):
        if not test_compile_kills:
            return "invalid"
        files = [f.replace("\\", "/").removeprefix("./") for f in ERROR_AT.findall(text)]
        if not files or any(f.startswith("src/") for f in files):
            return "invalid"
    return "killed"


def optimized_args(tests: str, names: list[str]) -> list[str]:
    return ["--match-path", tests, "--match-test", "^(" + "|".join(names) + r")\("]


def run(
    tests: str,
    log: Path,
    timeout: float,
    optimized_timeout: float,
    test_compile_kills: bool,
    optimized_ready: Callable[[], bool] | None = None,
) -> str:
    """The outcome of the code as it is. `optimized_ready`, when given, is called before the first default-profile run
    and must return whether the optimized-only tests pass without the mutant (the caller restores the file to check);
    when it returns False this raises RuntimeError, since no outcome of that check could be trusted."""
    log.write_text("", encoding="utf8")
    code, text = forge(["--match-path", tests], log, timeout, PROFILE)
    outcome = classify(code, text, test_compile_kills)
    names = optimized_only_tests(tests) if outcome == "survived" else []
    if not names:
        return outcome
    if optimized_ready is not None and not optimized_ready():
        raise RuntimeError(f"the optimized-only tests {', '.join(names)} fail without a mutant")
    code, text = forge(optimized_args(tests, names), log, optimized_timeout, "default")
    return classify(code, text, test_compile_kills)


def baseline(tests: str, log: Path, optimized: bool = True) -> bool:
    """Whether the tests pass without a mutant (and, with `optimized`, the optimized-only tests in the default
    profile). Appends to the log."""
    code, _ = forge(["--match-path", tests], log, None, PROFILE)
    if code != 0:
        return False
    return optimized_baseline(tests, log) if optimized else True


def optimized_baseline(tests: str, log: Path) -> bool:
    names = optimized_only_tests(tests)
    if not names:
        return True
    code, _ = forge(optimized_args(tests, names), log, None, "default")
    return code == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("what", choices=["run", "baseline"])
    parser.add_argument("tests")
    parser.add_argument("log", type=Path)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--optimized-timeout", type=float, default=1800)
    parser.add_argument("--test-compile-kills", action="store_true")
    args = parser.parse_args()
    if args.what == "baseline":
        args.log.write_text("", encoding="utf8")
        return 0 if baseline(args.tests, args.log) else 1
    start = time.monotonic()
    outcome = run(args.tests, args.log, args.timeout, args.optimized_timeout, args.test_compile_kills)
    with args.log.open("a", encoding="utf8") as f:
        f.write(f"outcome {outcome} in {time.monotonic() - start:.1f} s\n")
    print(outcome)
    return 0


if __name__ == "__main__":
    sys.exit(main())
