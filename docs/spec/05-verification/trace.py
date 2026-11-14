#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Avana requirement traceability checker.

Builds the matrix  requirement -> verification checks -> implementation  from IDs
written in the repo, regenerates traceability.md, and fails when:

  * an ID is defined twice,
  * a check or implementation links to an ID that is not defined,
  * a requirement's English text changed since its checks were last accepted
    (re-verify, then run with --accept ID ... or --accept-all).

It also fails when a FINDING about an AMM integration names no check or no spec rule, when an
accepted requirement disappears without `retired_to` in the lock, and when an AMM integration
marked `listed` in amm-integrations.json lacks a listing method or a passing result.

With --strict it also fails when a requirement has no spec-stage check, or (once
contracts exist) no counting implementation check, only declaration Solidity links or none, a check that did not run
or failed (with --results), a TEST tag placed on another row's test, or a Foundry test function under contracts/test
(`test*`, `invariant*`) not named `test_TEST_NNN_<behavior>`, `testFuzz_TEST_NNN_<behavior>` or
`invariant_TEST_NNN_<name>` (TEST-008; Halmos `check_*` and hevm `prove*` functions are not Foundry tests).

ID kinds
  Requirements (defined in docs/spec/01-04 as the first `ID` of a list item, table row or heading):
    REQ-<CONTRACT>-NNN   contract rule (REQ-FLASH-NNN flash source, REQ-CHAIN-NNN per-chain rules)
    INV-NNN              global invariant
    REQ-AMM-CORE-NNN, SPEC-AMM-CORE-NNN      rules and formulas every AMM integration meets
    REQ-/SPEC-/INV-/ATTACK-AMM-<P>-NNN       one AMM protocol's integration, <P> in AMM below
    SPEC-<AREA>-NNN      formula / math rule      ATTACK-NNN    attack scenario
    <FLOW>-NNN, <FLOW>-F-NNN, <FLOW>-POST-NNN     operation step / failure / postcondition
    Q-NNN                design decision (docs/spec/04-security/04-design-decisions.md)
  Checks and implementation (defined and linked with a `verifies:` tag in the model file; a spec rule
  may also cite a defined check, e.g. "Checked by: MATH-AR-03", which links it to that rule):
    MATH-* (Z3)  SYM-* (SymPy)  QNT-* (Quint)  HYP-* (Hypothesis)  SIM-* (simulation)
    TEST-* (Foundry)  PROP-* (Certora / Halmos / SMTChecker)
    Solidity: `/// @custom:spec REQ-VAULT-001, INV-003` in contracts/src.
  A check may also name a design-review finding it closes (AMMN-RT-01, defined in
  docs/audit/design-review/amm-neutral/); those links are listed apart from the requirement matrix.
  ATTACK-* entries name their checks in the `| Checks |` row under their heading.

Implementation evidence (evidence.py). A TEST-*/PROP-* tag counts for a row only when it sits in the comment block
directly above a test function or a CVL rule, carries its own row (a TEST tag on a function named for another TEST
row counts for nothing unless the tag says `shared: <reason>`), its check ran and passed in the results given with
--results (`forge test --json-file` output, Halmos logs; CVL rules: a prover result with a job id recorded in
contracts/certora/RUNS.md or a certora result file), and its test does not use a stand-in (evidence.STAND_INS) for a
contract whose spec page defines the row. Each row's implementation state is one of
  Verified   a counting check ran and passed
  Failed     a counting check ran and failed
  Not run    counting checks exist, none has a result (no --results, skipped, timed out, or no prover job)
  Unlinked   no counting check
A `@custom:spec` tag on a body-less declaration (an interface, a function without a body, an abstract contract no
concrete src/ contract inherits) is shown as "(decl.)" and is not an implementation link.

Without --results the matrix is written to traceability.md (committed): every Foundry row is then "Not run", since
no run is given. With --results it is written to the file named by --out (the CI evidence job's report).

Tag format (any comment style):   <CHECK-ID> verifies: <REQ-ID>, <REQ-ID>[; shared: <reason>]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evidence as ev  # noqa: E402  (tag placement, stand-ins and run results; beside this file)

ROOT = Path(__file__).resolve().parents[3]
SPEC = ROOT / "docs" / "spec"
VERIF = SPEC / "05-verification"
LOCK = VERIF / "traceability.lock.json"
OUT = VERIF / "traceability.md"

FLOWS = "DEP|BOR|REP|WDR|LIQ|EMG|FEE|MKT|DEF"
# AMM protocols with an integration page: Uniswap v2/v3/v4, Aerodrome Slipstream, Aerodrome v2-style
# pools, Curve, Balancer, Sushi. CORE holds the AMM-neutral rules every integration meets.
AMM = "V2|V3|V4|SLIP|AERO|CURVE|BAL|SUSHI"
AMM_ID = rf"(?:(?:REQ|SPEC)-AMM-(?:CORE|{AMM})|(?:INV|ATTACK)-AMM-(?:{AMM}))-[0-9]{{3}}"
AMMN_ID = r"AMMN-(?:RT|FLOW|GAS|INT|ARCH|SM)-[0-9]{2}"   # design-review findings, closed by checks
REQ_ID = rf"(?:{AMM_ID}|REQ-[A-Z]+-[0-9]{{3}}|INV-[0-9]{{3}}|SPEC-[A-Z]+-[0-9]{{3}}|ATTACK-[0-9]{{3}}|(?:{FLOWS})-(?:F-|POST-)?[0-9]{{3}}[a-z]?|Q-[0-9]{{3}})"
CHECK_ID = r"(?:MATH|SYM|QNT|HYP|SIM|TEST|PROP|FV)-[A-Z0-9]+(?:-[A-Z0-9]+)*"
CHECK_KIND = {"MATH": "Z3", "SYM": "SymPy", "QNT": "Quint", "HYP": "Hypothesis",
              "SIM": "Simulation", "TEST": "Foundry", "PROP": "Formal",
              "FV": "Internal FV"}
SPEC_STAGE = {"Z3", "SymPy", "Quint", "Hypothesis", "Simulation", "Internal FV"}

DEF_LINE = re.compile(rf"^\s*(?:[-*]\s+|\|\s*|#+\s+)`?({REQ_ID})`?(?:[\s|:·—-]+)(.*)$")
TARGET = rf"(?:{REQ_ID}|{AMMN_ID})"
TAG = re.compile(rf"({CHECK_ID})\s+verifies:\s*((?:{TARGET})(?:\s*,\s*{TARGET})*)")
SOL_TAG = re.compile(rf"@custom:spec\s+((?:{REQ_ID})(?:\s*,\s*{REQ_ID})*)")
SPLIT = re.compile(TARGET)

REQ_DIRS = ["01-architecture", "02-contracts", "03-operations", "04-security"]
CHECK_GLOBS = ["docs/spec/05-verification/**/*.py", "docs/spec/05-verification/**/*.qnt",
               "contracts/test/**/*.sol", "contracts/certora/**/*", "contracts/src/**/*.sol",
               "docs/audit/formal-verification/**/*.py", "docs/audit/formal-verification/**/*.qnt"]
SKIP = {".venv", "node_modules", "__pycache__", ".hypothesis"}

# Verification methods an AMM integration carries before it may be listed. Check IDs name the
# method: <KIND>-AMM-<P>-<METHOD>-NN, e.g. MATH-AMM-SLIP-PRICE-01, TEST-AMM-V3-UNWIND-003.
AMM_METHODS = {
    "PRICE": ({"Z3", "SymPy"}, None),                        # pricing proof of every SPEC-AMM-<P>-*
    "MANIP": ({"Foundry", "Hypothesis"}, None),              # manipulation tests of every ATTACK-AMM-<P>-*
    "UNWIND": ({"Foundry"}, "contracts/test/fork/"),         # fork test of unwind rounding on the pinned AMM code
    "INVAR": ({"Foundry"}, "contracts/test/invariant/"),     # invariant suite run with this AMM protocol's markets
}
AMM_INVARIANTS = ["INV-001", "INV-074"]                       # backing and per-asset solvency, asserted per protocol
AMM_MANIFEST = VERIF / "amm-integrations.json"                # {"V3": {"status": "review", "results": {...}}, ...}
AMM_STATUS = ("draft", "review", "listed")
PASS = {"proved", "computed", "holds", "pass"}
FINDINGS = VERIF / "03-audit-findings.md"
REVIEW = ROOT / "docs" / "audit" / "design-review" / "amm-neutral"


FOUNDRY_TEST_FN = re.compile(r"^\s*function\s+((?:test|invariant)\w*)\s*\(")
TEST_NAME = re.compile(r"^(?:test|testFuzz|invariant)_TEST_[0-9]{3}_[A-Za-z0-9]\w*$")


def misnamed_tests() -> list[str]:
    """Foundry test functions under contracts/test whose name does not carry its TEST row in the form of TEST-008."""
    out = []
    for path in sorted((ROOT / "contracts" / "test").rglob("*.sol")):
        for n, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
            m = FOUNDRY_TEST_FN.match(line)
            if m and not TEST_NAME.match(m.group(1)):
                out.append(f"{path.relative_to(ROOT)}:{n}: test function `{m.group(1)}` is not named "
                           "test_TEST_NNN_<behavior>, testFuzz_TEST_NNN_<behavior> or invariant_TEST_NNN_<name> (TEST-008)")
    return out


def norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().strip("|").strip())


def collect_requirements(errors: list[str]) -> dict[str, dict]:
    reqs: dict[str, dict] = {}
    for d in REQ_DIRS:
        for path in sorted((SPEC / d).glob("*.md")):
            is_decisions = path.name == "04-design-decisions.md"
            for n, line in enumerate(path.read_text().splitlines(), 1):
                m = DEF_LINE.match(line)
                if not m:
                    continue
                rid, text = m.group(1), norm(m.group(2))
                if not text or text.startswith("—") and len(text) < 3:
                    continue  # empty template row
                where = f"{path.relative_to(ROOT)}:{n}"
                if rid.startswith("Q-"):
                    if not is_decisions:
                        continue  # Q- only defined in the decision log
                    # Decisions appear in the index and again with their resolution; keep the longest text.
                    if rid not in reqs or len(text) > len(reqs[rid]["text"]):
                        reqs[rid] = {"text": text, "where": where}
                    continue
                if rid in reqs:
                    errors.append(f"duplicate definition of {rid}: {reqs[rid]['where']} and {where}")
                    continue
                reqs[rid] = {"text": text, "where": where}
    return reqs


def collect_links() -> tuple[dict[str, list[dict]], dict[str, set]]:
    """Requirement -> links, and check -> the IDs it names.

    Spec-stage models link through any `verifies:` tag in their file. Tags under contracts/test and contracts/certora
    link only from the comment block directly above a test function or CVL rule (evidence.scan_tags); each such link
    carries its tag, so its state and stand-ins can be read. Loose tags still name their IDs in `check_targets` (an
    undefined ID fails), but link nothing; main() reports them as errors. `@custom:spec` links in contracts/src carry
    `decl`: why the tag is on a body-less declaration, or ""."""
    links: dict[str, list[dict]] = defaultdict(list)
    check_targets: dict[str, set] = defaultdict(set)
    impl_roots = ("contracts/test/", "contracts/certora/")
    for pattern in CHECK_GLOBS:
        for path in ROOT.glob(pattern):
            if not path.is_file() or SKIP & set(path.parts) or path.resolve() == Path(__file__).resolve():
                continue
            rel = path.relative_to(ROOT).as_posix()
            in_src = rel.startswith("contracts/src/")
            for n, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
                if not rel.startswith(impl_roots):
                    for m in TAG.finditer(line):
                        cid = m.group(1)
                        kind = CHECK_KIND[cid.split("-")[0]]
                        for rid in SPLIT.findall(m.group(2)):
                            links[rid].append({"id": cid, "kind": kind, "where": f"{rel}:{n}"})
                            check_targets[cid].add(rid)
                for m in SOL_TAG.finditer(line):
                    decl = ev.declaration_only(path, n - 1) if in_src else ""
                    for rid in SPLIT.findall(m.group(1)):
                        links[rid].append({"id": Path(rel).stem, "kind": "Solidity", "where": f"{rel}:{n}",
                                           "decl": decl})
    on, loose = ev.scan_tags(TARGET)
    for tag in on:
        for rid in tag["targets"]:
            links[rid].append({"id": tag["check"], "kind": CHECK_KIND[tag["check"].split("-")[0]],
                               "where": f"contracts/{tag['file']}:{tag['line']}", "tag": tag})
            check_targets[tag["check"]].add(rid)
    for tag in loose:
        check_targets[tag["check"]].update(tag["targets"])
    return links, check_targets


_STATE: dict[int, tuple[str, str]] = {}


def tag_state(tag: dict, results: "ev.Results") -> tuple[str, str]:
    """(state, evidence) of a tag's check in this run, computed once per tag."""
    key = id(tag)
    if key not in _STATE:
        _STATE[key] = results.state(tag)
    return _STATE[key]


def owner_keys() -> dict[str, set[str]]:
    """REQ-/SPEC- ID -> the contract keys of contract_checklist.CONTRACTS whose spec pages (or page sections) define it.
    A link whose test uses a stand-in for one of them does not count for the row."""
    import contract_checklist as cc  # noqa: E402  (imports this module; loaded here to avoid a cycle)
    out: dict[str, set[str]] = defaultdict(set)
    for key, (pages, _, _) in cc.CONTRACTS.items():
        for rid, _, _ in cc.page_ids(pages)[0]:
            out[rid].add(key)
    return out


def counts_for(link: dict, owners: set[str]) -> bool:
    """A Foundry or formal link counts for a row owned by `owners` when its tag sits on a check, carries its own row
    (a PROP tag: sits on a prover or symbolic check) and its test uses no stand-in for any of the owners."""
    return (link["kind"] in ("Foundry", "Formal") and "tag" in link and not link["tag"]["excluded"]
            and not (ev.tag_stand_in_keys(link["tag"]) & owners))


def impl_state(checks: list[dict], owners: set[str], results: "ev.Results") -> tuple[str, list[dict]]:
    """Implementation state of a row (Verified, Failed, Not run, Unlinked) and the links that count."""
    counting = [c for c in checks if counts_for(c, owners)]
    states = {tag_state(c["tag"], results)[0] for c in counting}
    if not counting:
        return "Unlinked", counting
    if ev.FAIL in states:
        return "Failed", counting
    if ev.PASS in states:
        return "Verified", counting
    return "Not run", counting


def collect_attack_checks(links: dict, check_targets: dict) -> None:
    """ATTACK-* entries name their checks in a `| Checks |` row under the heading, not on the definition line."""
    path = SPEC / "04-security" / "02-attack-scenarios.md"
    rel = path.relative_to(ROOT).as_posix()
    current = None
    for n, line in enumerate(path.read_text().splitlines(), 1):
        h = re.match(rf"^#+\s+`?(ATTACK-(?:AMM-[A-Z0-9]+-)?[0-9]{{3}})", line)
        if h:
            current = h.group(1)
        elif current and line.startswith("| Checks |"):
            for cid in set(re.findall(rf"(?<![A-Za-z0-9-])({CHECK_ID})[a-z]?\b", line)):
                if cid in check_targets and not any(it["id"] == cid for it in links.get(current, [])):
                    links[current].append({"id": cid, "kind": CHECK_KIND[cid.split("-")[0]], "where": f"{rel}:{n}"})


def check_findings(errors: list[str], warnings: list[str]) -> dict[str, str]:
    """Every FINDING names a check and a spec rule; returns each FINDING's status.

    Missing either is an error for a FINDING about an AMM ID and a warning for the others."""
    rule = re.compile(rf"(?:{AMM_ID}|REQ-[A-Z]+-[0-9]{{3}}|INV-[0-9]{{3}}|SPEC-[A-Z]+-[0-9]{{3}}|(?:{FLOWS})-(?:F-|POST-)?[0-9]{{3}})")
    parts = re.split(r"^#### (FINDING-[0-9]+)[^\n]*\n", FINDINGS.read_text(), flags=re.M)
    defined: dict[str, str] = {}
    for i in range(1, len(parts), 2):
        fid, body = parts[i], parts[i + 1]
        ver = re.search(r"^\| Verification \| (.*) \|$", body, re.M)
        status = re.search(r"^\| Status \| (.*) \|$", body, re.M)
        defined[fid] = status.group(1) if status else ""
        out = errors if re.search(r"\b(?:REQ|SPEC|INV|ATTACK)-AMM-", body) else warnings
        checks = re.findall(rf"(?<![A-Za-z0-9-])({CHECK_ID})[a-z]?\b", ver.group(1) if ver else "")
        if not checks and not defined[fid].startswith("Accepted"):
            out.append(f"{fid} names no verification check")
        if not rule.search(body):
            out.append(f"{fid} links no spec rule (only decisions)")
    return defined


def check_amm(reqs: dict, links: dict, findings: dict[str, str], errors: list[str], warnings: list[str]) -> None:
    """Listing gate: an AMM integration carries every method before its status may be `listed`."""
    manifest = json.loads(AMM_MANIFEST.read_text()) if AMM_MANIFEST.exists() else {}
    core = sorted(r for r in reqs if r.startswith(("REQ-AMM-CORE-", "SPEC-AMM-CORE-")))
    for p in sorted({m.group(1) for r in reqs for m in [re.match(rf"^\w+-AMM-({AMM})-", r)] if m} | set(manifest)):
        status = manifest.get(p, {}).get("status", "draft")
        if p not in AMM.split("|") or status not in AMM_STATUS:
            errors.append(f"{AMM_MANIFEST.name}: {p} has status {status!r}; protocols are {AMM}, statuses {AMM_STATUS}")
            continue
        if status == "draft":
            continue
        out = errors if status == "listed" else warnings
        own = sorted(r for r in reqs if re.match(rf"^\w+-AMM-{p}-", r))
        # every check named for this protocol, whatever it links (a rule, a core rule or an AMMN finding)
        checks = {c["id"]: c for items in links.values() for c in items if f"-AMM-{p}-" in c["id"]}
        for method, (kinds, folder) in AMM_METHODS.items():
            found = [c for cid, c in checks.items() if f"-AMM-{p}-{method}-" in cid and c["kind"] in kinds
                     and (folder is None or c["where"].startswith(folder))]
            if not found:
                out.append(f"AMM {p}: no {method} check" + (f" under {folder}" if folder else "") + f" (status {status})")
        for r in own:
            want = {"SPEC": "PRICE", "ATTACK": "MANIP", "INV": "INVAR"}.get(r.split("-")[0])
            ids = [c["id"] for c in links.get(r, [])]
            if not ids:
                out.append(f"AMM {p}: {r} has no check")
            elif want and not any(f"-AMM-{p}-{want}-" in i for i in ids):
                out.append(f"AMM {p}: {r} has no {want} check")
        for r in core + AMM_INVARIANTS:
            if not any(f"-AMM-{p}-" in c["id"] for c in links.get(r, [])):
                out.append(f"AMM {p}: {r} has no check run against this protocol")
        if status == "listed":
            results = manifest[p].get("results", {})
            for cid in sorted(checks):
                if f"-AMM-{p}-" not in cid:
                    continue
                res = results.get(cid, {})
                if res.get("result") not in PASS:
                    if findings.get(res.get("finding"), "").startswith(("Resolved", "Accepted")):
                        continue  # failed on purpose or fixed in spec, and traceable to its FINDING
                    errors.append(f"AMM {p}: {cid} has result {res.get('result', 'none')} and no resolved FINDING")


def review_findings() -> dict[str, str]:
    """AMMN-* design-review findings defined in docs/audit/design-review/amm-neutral/."""
    found: dict[str, str] = {}
    for path in sorted(REVIEW.glob("*.md")):
        for n, line in enumerate(path.read_text().splitlines(), 1):
            for fid in re.findall(rf"(?<![A-Za-z0-9-])({AMMN_ID})\b", line):
                found.setdefault(fid, f"{path.relative_to(ROOT)}:{n}")
    return found


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true", help="fail on coverage gaps too")
    ap.add_argument("--accept", nargs="*", default=[], metavar="ID", help="record re-verified requirement(s)")
    ap.add_argument("--accept-all", action="store_true", help="record every requirement as re-verified")
    ap.add_argument("--results", nargs="+", type=Path, metavar="PATH",
                    help="run results: forge --json-file output, Halmos logs, certora result files, or folders of them")
    ap.add_argument("--out", type=Path, help="write the matrix here (required with --results; default traceability.md)")
    args = ap.parse_args()
    if args.results and not args.out:
        ap.error("--results needs --out: traceability.md is the committed matrix, written without run results")
    out = args.out or OUT
    results = ev.Results(args.results)

    errors: list[str] = []
    warnings: list[str] = []
    reqs = collect_requirements(errors)
    links, check_targets = collect_links()
    # Spec rules may also cite the checks that verify them ("Checked by: MATH-AR-03, QNT-07").
    # Such a citation links the check to the rule, provided the check is defined in a model file.
    # A lowercase suffix names one case of a check ("MATH-UO-39a") and cites the check itself.
    cite = re.compile(rf"(?<![A-Za-z0-9-])({CHECK_ID})[a-z]?\b")
    for d in REQ_DIRS:
        for path in sorted((SPEC / d).glob("*.md")):
            for n, line in enumerate(path.read_text().splitlines(), 1):
                m = DEF_LINE.match(line)
                if not m or m.group(1).startswith("Q-"):
                    continue
                rid = m.group(1)
                for cid in set(cite.findall(m.group(2))):
                    if cid.split("-")[0] in ("TEST", "PROP"):
                        continue  # implementation-stage IDs are linked from code, not cited
                    where = f"{path.relative_to(ROOT)}:{n}"
                    if cid not in check_targets:
                        errors.append(f"{where}: {rid} cites {cid}, which no model file defines")
                        continue
                    if not any(it["id"] == cid for it in links.get(rid, [])):
                        links[rid].append({"id": cid, "kind": CHECK_KIND[cid.split("-")[0]], "where": where})
    collect_attack_checks(links, check_targets)
    findings = check_findings(errors, warnings)
    check_amm(reqs, links, findings, errors, warnings)
    review = review_findings()
    owners = owner_keys()
    on, loose = ev.scan_tags(TARGET)
    for t in loose:
        errors.append(f"contracts/{t['file']}:{t['line']}: {t['check']} verifies: tag {t['why']}; it links nothing")
    misplaced = sorted({(t["check"], t["file"], t["line"], t["fn"]) for t in on if t["misplaced"]})
    for cid, f, n, fn in misplaced:
        warnings.append(f"contracts/{f}:{n}: {cid} tag on `{fn}`, a test of another row; it counts for nothing "
                        f"(name the test for {cid} or give `shared: <reason>`)")
    warnings.extend(results.warnings)
    warnings.extend(misnamed_tests())
    lock = json.loads(LOCK.read_text()) if LOCK.exists() else {}
    for rid, entry in lock.items():
        if rid not in reqs and not entry.get("retired_to"):
            errors.append(f"{rid} was accepted but is no longer defined; record its replacement as retired_to in the lock")

    closed: dict[str, list[dict]] = {}
    for rid, items in links.items():
        if re.fullmatch(AMMN_ID, rid):
            if rid not in review:
                errors.extend(f"{it['where']}: {it['id']} links to undefined design-review finding {rid}" for it in items)
            closed[rid] = items
        elif rid not in reqs:
            for it in items:
                errors.append(f"{it['where']}: {it['id']} links to undefined {rid}")

    accept = set(reqs) if args.accept_all else set(args.accept)
    contracts_exist = any((ROOT / "contracts" / "src").glob("**/*.sol"))
    rows = []
    tally: dict[str, int] = defaultdict(int)
    for rid in sorted(reqs, key=lambda r: (r.split("-")[0], r)):
        h = digest(reqs[rid]["text"])
        checks = links.get(rid, [])
        kinds = {c["kind"] for c in checks}
        mine = owners.get(rid, set())
        state, counting = impl_state(checks, mine, results)
        status = state
        if rid in accept:
            lock[rid] = {**lock.get(rid, {}), "hash": h, "checks": sorted({c["id"] for c in checks})}
        if rid in lock and lock[rid]["hash"] != h:
            status = "Changed — re-verify"
            errors.append(f"{rid} changed since last accepted ({reqs[rid]['where']}); re-run its checks, then --accept {rid}")
        tally[status] += 1
        if not rid.startswith(("Q-", "ATTACK-")) and not kinds & SPEC_STAGE:
            warnings.append(f"{rid} has no spec-stage check ({reqs[rid]['where']})")
        if contracts_exist and rid.startswith(("REQ-", "INV-", "SPEC-")):
            if state == "Unlinked":
                why = ("its only test links are excluded (stand-in, a tag on another row's test, or a PROP tag on a "
                       "fuzz test)"
                       if any(c["kind"] in ("Foundry", "Formal") for c in checks) else "no test or property links it")
                warnings.append(f"{rid} has no counting implementation check: {why}")
            elif state == "Failed":
                warnings.append(f"{rid}: a counting check failed in the results given")
            elif state == "Not run" and results.given:
                warnings.append(f"{rid}: no counting check ran and passed in the results given")
            sol = [c for c in checks if c["kind"] == "Solidity"]
            if not sol:
                warnings.append(f"{rid} has no Solidity link (@custom:spec)")
            elif all(c.get("decl") for c in sol):
                warnings.append(f"{rid} has only declaration links in contracts/src ({sol[0]['decl']})")

        def mark(c):
            if not any(c is x for x in counting):
                return "‡"
            return {ev.PASS: "", ev.FAIL: "✗"}.get(tag_state(c["tag"], results)[0], "°")

        def cell(kset):
            if kset == {"Solidity"}:
                return ", ".join(sorted({f"`{c['id']}`" + (" (decl.)" if c.get("decl") else "")
                                         for c in checks if c["kind"] == "Solidity"})) or "—"
            return ", ".join(sorted({f"`{c['id']}`" + (mark(c) if "tag" in c else "")
                                     for c in checks if c["kind"] in kset})) or "—"
        # Links in rule text are relative to the rule's own page; show their labels only.
        shown = re.sub(r"\[([^\]]*)\]\([^)]*\)?", r"\1", reqs[rid]["text"])
        rows.append(f"| `{rid}` | {shown[:90]}{'…' if len(shown) > 90 else ''} "
                    f"| {cell({'Z3', 'SymPy'})} | {cell({'Quint'})} | {cell({'Hypothesis', 'Simulation'})} "
                    f"| {cell({'Foundry', 'Formal'})} | {cell({'Solidity'})} | {status} |")

    if accept:
        LOCK.write_text(json.dumps(dict(sorted(lock.items())), indent=2) + "\n", newline="\n")

    run = ("Run results: " + ", ".join(str(p) for p in args.results) + ".") if args.results else (
        "No run results are given to this matrix (it is committed and must not depend on a run), so no Foundry test "
        "counts as Verified here; a CVL rule or Halmos check counts when contracts/certora/RUNS.md or "
        "docs/audit/halmos/results/ records its pass with a job id or log. The CI evidence job writes the same matrix "
        "from the run's results.")
    out.write_text(newline="\n", data=
        "# Requirement Traceability\n\n"
        "> **Generated by `trace.py` — do not edit by hand.** Run `.venv/bin/python trace.py` from this folder.\n\n"
        "Every English rule links to its checks, tests and Solidity. A changed rule fails `trace.py` until its checks "
        "are re-run and the change is accepted (`--accept ID`).\n\n"
        "Requirements: `REQ-*`, `INV-*`, `SPEC-*` (formulas), `ATTACK-*`, flow steps (`DEP-001` …), and design decisions "
        "`Q-*` until they are drafted into requirements. Checks: `MATH-*` Z3, `SYM-*` SymPy, `QNT-*` Quint, `HYP-*` "
        "Hypothesis, `SIM-*` simulation, `TEST-*` Foundry, `PROP-*` Certora/Halmos/SMTChecker. Link with "
        "`<CHECK-ID> verifies: <REQ-ID>, …`; Solidity with `/// @custom:spec <REQ-ID>`. AMM integration rules use "
        "`REQ-AMM-CORE-*` and `REQ-/SPEC-/INV-/ATTACK-AMM-<P>-*`; flash-source and per-chain rules `REQ-FLASH-*`, "
        "`REQ-CHAIN-*`.\n\n"
        "Status is the row's implementation state: **Verified** (a counting test or property ran and passed), "
        "**Failed** (a counting check failed), **Not run** (counting checks exist and none has a result), "
        "**Unlinked** (no counting check), or **Changed — re-verify**. A test or rule counts when its tag sits "
        "directly above it, carries its own row, and its test uses no stand-in (harness or mock) for a contract whose "
        "page defines the row. In the Impl. column, ° marks a check without a result, ✗ a failed one and ‡ one that "
        "does not count (stand-in or a tag on another row's test); in the Solidity column, (decl.) marks a "
        "`@custom:spec` tag on a body-less declaration, which is not an implementation link.\n\n"
        + run + "\n\n"
        f"**{len(reqs)} requirements · " + " · ".join(f"{tally[k]} {k.lower()}" for k in
                                                  ("Verified", "Failed", "Not run", "Unlinked", "Changed — re-verify"))
        + f" · {len(errors)} errors · {len(warnings)} warnings**\n\n"
        "| Requirement | Statement | Math (Z3/SymPy) | State (Quint) | Scenario (Hypothesis/Sim) | Impl. test/property | Solidity | Status |\n"
        "|---|---|---|---|---|---|---|---|\n" + "\n".join(rows) + "\n"
        + ("\n## Design-review findings closed by checks\n\n"
           "Checks that name an `AMMN-*` finding of `docs/audit/design-review/amm-neutral/` they close. A finding listed "
           "here still needs the spec rule that fixes it.\n\n"
           "| Finding | Checks |\n|---|---|\n"
           + "\n".join(f"| `{fid}` | {', '.join(sorted({'`' + c['id'] + '`' for c in closed[fid]}))} |"
                       for fid in sorted(closed)) + "\n" if closed else "")
    )

    for e in errors:
        print("ERROR  ", e)
    for w in warnings if args.strict else warnings[:20]:
        print("WARN   ", w)
    if not args.strict and len(warnings) > 20:
        print(f"WARN    … {len(warnings) - 20} more (use --strict to list and enforce)")
    print(f"traceability: {len(reqs)} requirements (" + ", ".join(f"{tally[k]} {k.lower()}" for k in
          ("Verified", "Failed", "Not run", "Unlinked", "Changed — re-verify")) + f"), {len(errors)} errors, "
          f"{len(warnings)} warnings -> {out}")
    return 1 if errors or (args.strict and warnings) else 0


if __name__ == "__main__":
    sys.exit(main())
