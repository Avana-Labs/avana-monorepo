#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Implementation evidence for trace.py and contract_checklist.py: which `verifies:` tags count, and whether the check
behind each one ran and passed.

A tag in contracts/test or contracts/certora counts only when all of these hold:

  1. Placement. It sits in the comment block directly above a test function (`test*`, `invariant*`, Halmos `check_*`,
     hevm `prove*`) or a CVL `rule` / `invariant`. A tag anywhere else (a mock, a handler, a helper, a comment block
     between functions) is "loose": reported, never counted.
  2. Own row. A `TEST-NNN verifies:` tag on a function whose name carries other TEST ids (`test_TEST_180_...`) and not
     `TEST_NNN` is "misplaced" and counts for nothing, unless the tag line says why the test is shared:
     `// TEST-104 verifies: INV-001; shared: <reason of at least ten characters>`. A `PROP-NNN` tag counts only on a
     CVL rule, a Halmos `check_` or an hevm `prove` function: a fuzz test is not a prover result.
  3. Result. The function ran and passed in the results given (`forge test --json-file` output, Halmos logs), or, for a
     CVL rule, a prover result with a job id is recorded (contracts/certora/RUNS.md, or a certora result file). A tag
     whose check has no result is "not run", never "verified"; a failed or timed-out check is "failed" / "not run".
  4. No stand-in. The test does not replace the contract the row belongs to: a test file that uses (directly or through
     the fixtures, handlers and base tests it imports) a stand-in listed in STAND_INS for contract X does not count
     for X's rows. Only what the test runs counts as use: from an imported test file, the contracts, libraries and
     file-level definitions the test's code names (used_code), so importing a fixture's structs uses none of the
     stand-ins its fixture contract deploys. A CVL conf that verifies or links a stand-in for X does not count for X's
     rows.
  5. Exercises the contract (TEST rows naming several contracts, contract_checklist.py). A test counts for contract X
     of such a row only when the code it runs deploys or calls X's real contract (exercises).

`/// @custom:spec` tags in contracts/src stay implementation pointers; on a body-less declaration (an interface, a
function without a body, an abstract contract that no concrete contract in src/ inherits) they are "declaration only"
and never count as the implementation of the rule.

Result files (passed to --results; a directory is searched for *.json and *.txt):
  - forge:   `forge test --json-file <file>` (or `--json` stdout): {"<path>:<Contract>": {"test_results": {...}}}
  - halmos:  console output: "Running N tests for <path>:<Contract>" then "[PASS] <fn>(...)" lines
  - certora: {"tool": "certora", "conf": "<Conf>", "job": "<url or id>", "rules": {"<rule>": "VERIFIED", ...}} or
             {"tool": "certora", "conf": "<Conf>", "job": "...", "all_rules_verified": true}
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "contracts"
TEST_DIR = CONTRACTS / "test"
SRC_DIR = CONTRACTS / "src"
CERTORA = CONTRACTS / "certora"
RUNS_MD = CERTORA / "RUNS.md"
HALMOS_LOGS = ROOT / "audit" / "halmos" / "results"

CHECK_ID = r"(?:TEST|PROP)-[A-Z0-9]+(?:-[A-Z0-9]+)*"
TAG = re.compile(rf"({CHECK_ID})\s+verifies:\s*(.*)$")
SHARED = re.compile(r"\bshared(?: with [^:]{1,80})?:\s*(\S.{9,})")
TEST_FN = re.compile(r"^\s*function\s+((?:test|invariant|check|prove)\w*)\s*\(")
ANY_FN = re.compile(r"^\s*function\s+(\w+)\s*\(")
CVL_RULE = re.compile(r"^\s*(?:rule|invariant)\s+(\w+)\b")
DECL = re.compile(r"^\s*(abstract\s+)?(contract|library|interface)\s+(\w+)\b")
OWN_TEST = re.compile(r"TEST_([0-9]{3}[a-z]?)(?![0-9])")
JOB = re.compile(r"\b[0-9a-f]{32}\b")

PASS, FAIL, NOT_RUN = "verified", "failed", "not run"

# Stand-ins: test contracts that replace an Avana contract, by the checklist key(s) of the contract they replace
# (contract_checklist.CONTRACTS). A test that uses one of them does not count for that contract's rows. Mocks of
# external code (Chainlink, Uniswap and Slipstream pools and position managers, the Aave V3 Pool, GSM, PSM, tokens),
# exposer harnesses over a library or internal functions of the real code, call recorders and hostile implementations
# a test installs on purpose (BrokenAdapter, HostileAdapter, AdapterPlaceholder, which the fixture replaces with the
# real Adapter before any test runs) are not stand-ins.
STAND_INS: dict[str, tuple[str, ...]] = {
    # LPOracle: the harness's linear module replaces the CL pricing hooks of LPOracleCL.
    "LPOracleHarness": ("LPOracle", "ClPricing"),
    "LPOracleHarnessModule": ("LPOracle", "ClPricing"),
    "LPOracleHarnessViewLogic": ("LPOracle", "ClPricing"),
    "LPOracleHarnessPokeLogic": ("LPOracle", "ClPricing"),
    "LPOracleHarnessListingLogic": ("LPOracle", "ClPricing"),
    "CollOracleMock": ("LPOracle",),
    "LVSLPOracleMock": ("LPOracle",),
    "LensLPOracleMock": ("LPOracle",),
    "MockLPOracle": ("LPOracle",),
    "RegistryLPOracleMock": ("LPOracle",),
    "RiskLPOracleMock": ("LPOracle",),
    "IntegLPOracleMock": ("LPOracle",),
    # DebtOracle
    "IntegDebtOracleMock": ("DebtOracle",),
    "LVSDebtOracleMock": ("DebtOracle",),
    "LensDebtOracleMock": ("DebtOracle",),
    "RegistryDebtOracleMock": ("DebtOracle",),
    "RiskDebtOracleMock": ("DebtOracle",),
    # AaveAdapter
    "AaveAdapterMock": ("AaveAdapter",),
    "AaveAdapterLensMock": ("AaveAdapter",),
    "RegistryAdapterMock": ("AaveAdapter",),
    "RiskAdapterMock": ("AaveAdapter",),
    "LockMember": ("AaveAdapter", "LPVaultSwap"),
    # LPVaultSwap
    "LPVaultSwapMock": ("LPVaultSwap",),
    "LPVaultSwapLensMock": ("LPVaultSwap",),
    "MockLiquidationSwap": ("LPVaultSwap",),
    "RiskSwapMock": ("LPVaultSwap",),
    "MockRouteCaller": ("LPVaultSwap",),
    "MockFlashReceiver": ("LPVaultSwap",),
    "PayoutDepositor": ("LPVaultSwap",),
    # MarketRegistry
    "AdapterRegistryMock": ("MarketRegistry",),
    "DebtRegistryMock": ("MarketRegistry",),
    "OracleRegistryMock": ("MarketRegistry",),
    "FreezeRegistryMock": ("MarketRegistry",),
    "GasMarketRegistry": ("MarketRegistry",),
    "HarnessMarketRegistry": ("MarketRegistry",),
    "IntegRegistryMock": ("MarketRegistry",),
    "LVSMarketRegistryMock": ("MarketRegistry",),
    "LensRegistryMock": ("MarketRegistry",),
    "MockMarketRegistry": ("MarketRegistry",),
    # ParameterStore
    "AdapterParameterStoreMock": ("ParameterStore",),
    "DebtStoreMock": ("ParameterStore",),
    "OracleStoreMock": ("ParameterStore",),
    "LVSParameterStoreMock": ("ParameterStore",),
    "LensStoreMock": ("ParameterStore",),
    "RegistryParameterStoreMock": ("ParameterStore",),
    "RiskStoreMock": ("ParameterStore",),
    "MockFlashFeeCap": ("ParameterStore",),
    "IntegStoreMock": ("ParameterStore",),
    # RiskModule
    "AdapterRiskModuleMock": ("RiskModule",),
    "CollRiskModuleMock": ("RiskModule",),
    "LensRiskModuleMock": ("RiskModule",),
    "RegistryRiskModuleMock": ("RiskModule",),
    # Collateralization
    "CollateralizationLockMock": ("Collateralization",),
    "MockCollateralization": ("Collateralization",),
    "RegistryCollateralizationMock": ("Collateralization",),
    "RiskCollateralizationMock": ("Collateralization",),
    # AMM integrations (the LPVaults)
    "CollLPVaultMock": ("UniswapV3Integration", "SlipstreamIntegration"),
    "LensLPVaultMock": ("UniswapV3Integration", "SlipstreamIntegration"),
    "RegistryLPVaultMock": ("UniswapV3Integration", "SlipstreamIntegration"),
    "RiskLPVaultMock": ("UniswapV3Integration", "SlipstreamIntegration"),
    "MockIntegration": ("UniswapV3Integration", "SlipstreamIntegration"),
    "LPVaultIdentityMock": ("UniswapV3Integration", "SlipstreamIntegration"),
    "IntegLPVaultMock": ("UniswapV3Integration", "SlipstreamIntegration"),
    # Flash source
    "LVSFlashSourceMock": ("AaveV3FlashSource",),
    "LensFlashSourceMock": ("AaveV3FlashSource",),
    "RegistryFlashSourceMock": ("AaveV3FlashSource",),
    # First-Loss Reserve
    "MockAvanaFirstLossReserve": ("AvanaFirstLossReserve",),
    "RegistryAvanaFirstLossReserveMock": ("AvanaFirstLossReserve",),
    "LensCoverageMock": ("AvanaFirstLossReserve",),
    # Proxies, vault token, Lock
    "MockPositionProxy": ("PositionProxy",),
    "MockProxyBindings": ("PositionProxy",),
    "MockProxyManager": ("ProxyManager",),
    "MockVaultToken": ("VaultToken",),
    "HarnessLock": ("Lock",),
    # Settlement routes
    "RegistryRouteMock": ("SwapRoutes",),
    "LVSRevertingRoute": ("SwapRoutes",),
    "LVSLyingRoute": ("SwapRoutes",),
    "LVSHarnessRoute": ("SwapRoutes",),
}
STAND_IN_RE = re.compile(r"\b(" + "|".join(sorted(STAND_INS, key=len, reverse=True)) + r")\b")


# ---------------------------------------------------------------------------------------------------------------------
# Solidity scanning
# ---------------------------------------------------------------------------------------------------------------------

def _rel(p: Path) -> str:
    return str(p.relative_to(CONTRACTS))


def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def _leading_comments(lines: list[str], i: int) -> list[int]:
    """Line indexes of the contiguous comment block directly above line i (no blank line in between)."""
    out, j = [], i - 1
    while j >= 0:
        s = lines[j].strip()
        if s.startswith(("//", "/*", "*")):
            out.append(j)
            j -= 1
            continue
        break
    return out


def _declarations(text: str, path: Path) -> list[dict]:
    """Top-level contract / library / interface declarations with their bases and line span."""
    lines = text.splitlines()
    decls = []
    for i, line in enumerate(lines):
        m = DECL.match(line)
        if not m:
            continue
        head = line
        k = i
        while "{" not in head and k + 1 < len(lines):
            k += 1
            head += " " + lines[k]
        bases = []
        b = re.search(r"\bis\s+(.*?)\{", head, re.S)
        if b:
            bases = [re.match(r"\s*([A-Za-z0-9_]+)", x).group(1) for x in b.group(1).split(",") if x.strip()]
        decls.append({"name": m.group(3), "kind": m.group(2), "abstract": bool(m.group(1)), "bases": bases,
                      "file": path, "line": i})
    return decls


@lru_cache(maxsize=None)
def _sol_files(root: Path) -> tuple[Path, ...]:
    return tuple(sorted(p for p in root.rglob("*.sol") if p.is_file()))


@lru_cache(maxsize=None)
def _text(path: Path) -> str:
    return path.read_text(errors="ignore")


@lru_cache(maxsize=None)
def test_contracts() -> dict[str, list[dict]]:
    """Contract name -> declarations under contracts/test (a name may repeat in different files)."""
    out: dict[str, list[dict]] = defaultdict(list)
    for p in _sol_files(TEST_DIR):
        for d in _declarations(_text(p), p):
            out[d["name"]].append(d)
    return out


def _concrete_runners(contract: str, file: Path) -> list[tuple[str, str]]:
    """(file, contract) of every concrete test contract that inherits `contract` (itself included when concrete)."""
    decls = test_contracts()
    children: dict[str, set[str]] = defaultdict(set)
    for name, ds in decls.items():
        for d in ds:
            for b in d["bases"]:
                children[b].add(name)
    seen, todo, out = set(), [contract], []
    while todo:
        c = todo.pop()
        if c in seen:
            continue
        seen.add(c)
        for d in decls.get(c, []):
            if d["kind"] == "contract" and not d["abstract"] and (c != contract or d["file"] == file):
                out.append((_rel(d["file"]), c))
        todo.extend(children.get(c, ()))
    return out


def _resolve(path: Path, spec: str) -> Path | None:
    """The test file an import of `path` names, or None (a library, a src file, a missing file)."""
    if spec.startswith("."):
        q = (path.parent / spec).resolve()
    elif spec.startswith("test/"):
        q = (CONTRACTS / spec).resolve()
    else:
        return None
    return q if q.is_file() and TEST_DIR in q.parents else None


IMPORT = re.compile(r'\bimport\s+([^;"]*?)?\s*"([^"]+)"\s*(?:as\s+(\w+))?\s*;', re.S)
IDENT = re.compile(r"\b[A-Za-z_]\w*\b")
FILE_LEVEL = re.compile(r"\b(?:struct|enum|error|event|function|type)\s+(\w+)|\bconstant\s+(\w+)")


@lru_cache(maxsize=None)
def _code(path: Path) -> str:
    """A file's code: comments and import statements left out."""
    return IMPORT.sub("", _strip_comments(_text(path)))


@lru_cache(maxsize=None)
def _chunks(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    """(name -> chunk id, chunk id -> code) of a file. Each contract, library and interface is its own chunk (from its
    declaration to its closing brace); the code outside them (structs, enums, errors, free functions, constants) is the
    chunk "", which every name declared there maps to."""
    code = _code(path)
    names: dict[str, str] = {}
    text: dict[str, str] = {}
    outside, i = [], 0
    for m in re.finditer(r"\b(?:abstract\s+)?(?:contract|library|interface)\s+(\w+)[^{;]*\{", code):
        if m.start() < i:
            continue
        depth, j = 1, m.end()
        while j < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[j], 0)
            j += 1
        outside.append(code[i:m.start()])
        names[m.group(1)] = m.group(1)
        text[m.group(1)] = code[m.start():j]
        i = j
    outside.append(code[i:])
    text[""] = "\n".join(outside)
    for m in FILE_LEVEL.finditer(text[""]):
        names.setdefault(m.group(1) or m.group(2), "")
    return names, text


@lru_cache(maxsize=None)
def _visible(path: Path) -> dict[str, tuple[Path, str]]:
    """Names a file imports from other test files -> (that file, chunk id, or "*" for a whole-file alias). Mocks and
    harnesses are left out: a test that uses one names it, and the name is what counts."""
    out: dict[str, tuple[Path, str]] = {}
    for m in IMPORT.finditer(_strip_comments(_text(path))):
        q = _resolve(path, m.group(2))
        if q is None or "utils/mocks" in str(q) or "utils/harness" in str(q):
            continue
        clause = (m.group(1) or "").strip()
        names = _chunks(q)[0]
        brace = re.match(r"^\{(.*)\}\s*from$", clause, re.S)
        if brace:
            for item in brace.group(1).split(","):
                parts = item.split()
                if parts and parts[0] in names:
                    out[parts[-1]] = (q, names[parts[0]])
        elif re.match(r"^\*\s+as\s+(\w+)\s+from$", clause) or m.group(3):
            alias = m.group(3) or re.match(r"^\*\s+as\s+(\w+)", clause).group(1)
            out[alias] = (q, "*")
        elif not clause:
            for n, cid in names.items():
                out.setdefault(n, (q, cid))
    return out


@lru_cache(maxsize=None)
def used_code(path: Path) -> tuple[str, ...]:
    """The code a test file runs: the file itself and, from each test file it imports (fixtures, handlers, base
    tests), only the contracts, libraries and file-level definitions its code names, transitively. A test that imports
    a fixture file for its structs uses the file-level chunk only, never the fixture contract beside them."""
    out = [_code(path)]
    seen: set[tuple[Path, str]] = set()
    todo: list[tuple[Path, str]] = [(path, "*")]
    while todo:
        p, cid = todo.pop()
        if (p, cid) in seen:
            continue
        seen.add((p, cid))
        names, text = _chunks(p)
        code = _code(p) if cid == "*" else text[cid]
        if (p, cid) != (path, "*"):
            out.append(code)
        vis = _visible(p)
        for ident in set(IDENT.findall(code)):
            if ident in vis:
                todo.append(vis[ident])
            if cid != "*" and ident in names and names[ident] != cid:
                todo.append((p, names[ident]))
    return tuple(out)


@lru_cache(maxsize=None)
def _used_stand_ins(path: Path) -> frozenset[str]:
    """Stand-in names in the code a test file runs (its own contract definitions left out)."""
    return frozenset(n for code in used_code(path)
                     for n in STAND_IN_RE.findall(re.sub(r"\b(?:abstract\s+)?contract\s+\w+", "", code)))


@lru_cache(maxsize=None)
def _used_deploys(path: Path) -> frozenset[str]:
    out: set[str] = set()
    for code in used_code(path):
        out |= set(re.findall(r"\bnew\s+(\w+)\s*[({]", code))
        out |= set(re.findall(r'deployCode\(\s*"(?:[^"]*:)?(\w+)', code))
    return frozenset(out)


# The real contract of each key, by the names a test deploys it with. A test that deploys the real contract and also
# names a stand-in for it uses the stand-in as a placeholder the fixture replaces (a registry fixture wires a
# RiskModule stand-in until the RiskModule fixture deploys the real one), so the stand-in does not exclude it. LPOracle
# and ClPricing are the concentrated-liquidity LPOracle, LPOracleCL, whose constructor takes its logic contracts.
# The library keys add their exposer harness, which runs the library's own code.
REAL: dict[str, tuple[str, ...]] = {
    "UniswapV3Integration": ("UniswapV3Integration", "UniswapV3IntegrationHarness"),
    "SlipstreamIntegration": ("SlipstreamIntegration",),
    "LPOracle": ("LPOracleCL",),
    "ClPricing": ("LPOracleCL",),
    "SwapRoutes": ("DexPathRoute", "WrapperThenDexRoute", "PegModuleRoute"),
    "Lock": ("Lock",),
    "LPPriceMath": ("LPPriceMath", "LPPriceMathHarness"),
    "SettlementMath": ("SettlementMath", "SettlementMathHarness"),
}

# Contracts that only an Avana factory creates: a test exercises one when it deploys the real factory, which makes
# real instances (exercises only; a stand-in is still judged by REAL).
MADE_BY: dict[str, tuple[str, ...]] = {
    "VaultToken": ("VaultTokenFactory",),
    "PositionProxy": ("ProxyManager",),
}


@lru_cache(maxsize=None)
def stand_ins_of(path: Path) -> frozenset[str]:
    """Stand-ins a test file uses, directly or through the test code it imports (used_code), less those whose real
    contract the same code deploys (see REAL)."""
    names = _used_stand_ins(path)
    deployed = _used_deploys(path)
    real = {k for k in {k for n in names for k in STAND_INS[n]} if set(REAL.get(k, (k,))) & deployed}
    return frozenset(n for n in names if not set(STAND_INS[n]) <= real)


def _use_re(names: tuple[str, ...]) -> re.Pattern:
    alt = "|".join(re.escape(n) for n in names)
    return re.compile(
        rf"(?<![\w.])(?:{alt})\b(?=\s*(?:\.|\(|\{{|\s+(?:(?:internal|public|private|immutable|memory|storage|calldata)"
        rf"\s+)*[a-z_$]\w*\s*[;=,)]))"
        rf'|deployCode\(\s*"(?:[^"]*:)?(?:{alt})\b')


@lru_cache(maxsize=None)
def _exercises_file(path: Path, names: tuple[str, ...]) -> bool:
    rx = _use_re(names)
    return any(rx.search(code) for code in used_code(path))


def exercises(tag: dict, names: tuple[str, ...]) -> bool:
    """Whether the code a tagged test runs (its file or the file of any concrete runner) deploys or calls one of
    `names`: `new X`, `deployCode("X")`, a cast and call `X(a).f()`, a library or static call `X.f()`, or a
    variable of type X. A CVL rule exercises the contract its conf verifies."""
    if not names:
        return False
    if tag["kind"] == "cvl":
        return any(c["verify"] in names for c in confs().values()
                   if c["spec"].endswith("/" + Path(tag["file"]).name))
    files = {(CONTRACTS / tag["file"]).resolve()} | {(CONTRACTS / f).resolve() for f, _ in tag["runners"]}
    return any(_exercises_file(f, tuple(sorted(names))) for f in files)


def stand_in_keys(names) -> set[str]:
    return {k for n in names for k in STAND_INS.get(n, ())}


# ---------------------------------------------------------------------------------------------------------------------
# Tags on checks
# ---------------------------------------------------------------------------------------------------------------------

def _tag_targets(rest: str, split: re.Pattern) -> tuple[list[str], str]:
    """IDs of the comma-separated list after `verifies:` (it stops at the first token that is not an ID) and the
    shared-test reason, if the line gives one."""
    ids = []
    for tok in rest.split(","):
        tok = tok.strip()
        m = split.match(tok)
        if not m:
            break
        ids.append(m.group(0))
        if tok != m.group(0):
            break
    s = SHARED.search(rest)
    return ids, (s.group(1).strip() if s else "")


@lru_cache(maxsize=None)
def scan_tags(target_pattern: str) -> tuple[tuple, tuple]:
    """(tags on checks, loose tags) under contracts/test and contracts/certora.

    A tag on a check: {check, targets, file, line, fn, contract, kind ('foundry'|'halmos'|'hevm'|'cvl'), shared,
    misplaced, runners, stand_ins}. A loose tag: {check, targets, file, line, why}."""
    split = re.compile(target_pattern)
    on, loose = [], []
    for p in _sol_files(TEST_DIR):
        lines = _text(p).splitlines()
        decls = sorted(_declarations(_text(p), p), key=lambda d: d["line"])
        attached: set[int] = set()
        for i, line in enumerate(lines):
            m = TEST_FN.match(line)
            if not m:
                continue
            fn = m.group(1)
            owner = next((d for d in reversed(decls) if d["line"] < i), None)
            kind = "halmos" if fn.startswith("check") else "hevm" if fn.startswith("prove") else "foundry"
            own = set(OWN_TEST.findall(fn))
            for j in _leading_comments(lines, i):
                t = TAG.search(lines[j])
                if not t:
                    continue
                attached.add(j)
                targets, shared = _tag_targets(t.group(2), split)
                cid = t.group(1)
                misplaced = (cid.startswith("TEST-") and cid[5:] not in own and not shared)
                excluded = ("tag on a test named for another row" if misplaced else
                            "a PROP tag on a Foundry test: a property needs a prover or symbolic result"
                            if cid.startswith("PROP-") and kind == "foundry" else "")
                on.append({"check": cid, "targets": targets, "file": _rel(p), "line": j + 1, "fn": fn,
                           "contract": owner["name"] if owner else "", "kind": kind, "shared": shared,
                           "misplaced": misplaced, "excluded": excluded,
                           "runners": tuple(_concrete_runners(owner["name"], p)) if owner else (),
                           "stand_ins": stand_ins_of(p)})
        for j, line in enumerate(lines):
            t = TAG.search(line)
            if t and j not in attached:
                targets, _ = _tag_targets(t.group(2), split)
                nxt = next((x for x in lines[j + 1:] if x.strip() and not x.strip().startswith(("//", "*", "/*"))), "")
                f = ANY_FN.match(nxt)
                why = (f"above `{f.group(1)}`, which is not a test function" if f and not TEST_FN.match(nxt)
                       else "not in the comment block directly above a test function")
                loose.append({"check": t.group(1), "targets": targets, "file": _rel(p), "line": j + 1, "why": why})
    for p in sorted(CERTORA.rglob("*")):
        if not p.is_file() or p.suffix not in (".spec", ".cvl", ".conf", ".sol"):
            continue
        lines = _text(p).splitlines()
        attached = set()
        for i, line in enumerate(lines):
            m = CVL_RULE.match(line) if p.suffix in (".spec", ".cvl") else None
            if not m:
                continue
            for j in _leading_comments(lines, i):
                t = TAG.search(lines[j])
                if not t:
                    continue
                attached.add(j)
                targets, shared = _tag_targets(t.group(2), split)
                on.append({"check": t.group(1), "targets": targets, "file": _rel(p), "line": j + 1, "fn": m.group(1),
                           "contract": p.stem, "kind": "cvl", "shared": shared, "misplaced": False, "excluded": "",
                           "runners": (),
                           "stand_ins": frozenset()})
        for j, line in enumerate(lines):
            t = TAG.search(line)
            if t and j not in attached:
                targets, _ = _tag_targets(t.group(2), split)
                loose.append({"check": t.group(1), "targets": targets, "file": _rel(p), "line": j + 1,
                              "why": "not directly above a CVL rule or invariant"})
    return tuple(on), tuple(loose)


# ---------------------------------------------------------------------------------------------------------------------
# Certora confs and recorded prover results
# ---------------------------------------------------------------------------------------------------------------------

@lru_cache(maxsize=None)
def confs() -> dict[str, dict]:
    """Conf name -> {spec, verify, files, stand_ins, rules (the conf's own rule filter, if any)}."""
    out = {}
    for p in sorted((CERTORA / "conf").glob("*.conf")):
        text = _text(p)
        v = re.search(r'"verify"\s*:\s*"(\w+):([^"]+)"', text)
        files = re.findall(r'"((?:src|test|certora)/[^"]+\.sol)(?::(\w+))?"', text)
        names = {v.group(1)} if v else set()
        names |= {c or Path(f).stem for f, c in files}
        only = re.search(r'"rule"\s*:\s*\[([^\]]*)\]', text)
        out[p.stem] = {"spec": v.group(2) if v else "", "verify": v.group(1) if v else "",
                       "stand_ins": frozenset(n for n in names if n in STAND_INS),
                       "rules": re.findall(r'"(\w+)"', only.group(1)) if only else []}
    return out


@lru_cache(maxsize=None)
def spec_rules(spec: str) -> tuple[str, ...]:
    """Rules and invariants of a CVL spec, its imports included."""
    path = CONTRACTS / spec
    if not path.is_file():
        return ()
    names, seen, todo = [], set(), [path]
    while todo:
        q = todo.pop()
        if q in seen or not q.is_file():
            continue
        seen.add(q)
        text = _text(q)
        names += [m.group(1) for m in re.finditer(r"(?m)^\s*(?:rule|invariant)\s+(\w+)\b", text)]
        todo += [(q.parent / i).resolve() for i in re.findall(r'(?m)^\s*import\s+"([^"]+)"', text)]
    return tuple(dict.fromkeys(names))


def _cells(line: str) -> list[str]:
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


@lru_cache(maxsize=None)
def recorded_prover_results() -> tuple[dict, list[str]]:
    """(conf, rule) -> (status, job ids, source line) from contracts/certora/RUNS.md, newest entry last; and warnings.

    Read: the per-conf tables `| Conf | Job(s) | Verified | Violated | Sanity fail | Timeout |` (a Verified cell names
    rules in backticks, or says `all N`, which counts only while the conf's spec still has exactly N rules and
    invariants), the per-rule tables `| Conf | Rule | Status | Job |` (Status exactly "Verified" or "Verified: ... in
    `<job>`"; a rule cell with words other than rule names is skipped; the prover's envfree static check counts as one
    of the N), and lines
    `- **Prover verified** <Conf> job <job>: \\`rule\\`, ...`. A result without a job id is not read. A later entry
    replaces an earlier one, so a later TIMEOUT or violation clears an earlier pass."""
    res: dict[tuple[str, str], tuple[str, tuple[str, ...], str]] = {}
    warn: list[str] = []
    if not RUNS_MD.exists():
        return res, warn
    cf = confs()
    header = ""
    for n, line in enumerate(RUNS_MD.read_text().splitlines(), 1):
        where = f"contracts/certora/RUNS.md:{n}"
        m = re.match(r"^\s*-\s+\*\*Prover verified\*\*\s+(\w+)\s+job\s+`?([0-9a-f]{32})`?\s*:(.*)$", line)
        if m:
            for r in re.findall(r"`(\w+)`", m.group(3)):
                res[(m.group(1), r)] = (PASS, (m.group(2),), where)
            continue
        if line.startswith("| Conf |"):
            header = line
            continue
        if not line.startswith("| ") or line.startswith("|---"):
            if not line.startswith("|"):
                header = ""
            continue
        c = _cells(line)
        conf = c[0].strip("`")
        if conf not in cf:
            continue
        rules = spec_rules(cf[conf]["spec"])
        if header.startswith("| Conf | Job(s) | Verified |") and len(c) >= 6:
            jobs = tuple(JOB.findall(c[1]))
            if not jobs:
                continue
            allm = re.match(r"^all (\d+)$", c[2])
            if allm:
                # The prover reports the envfree static check as one more result, so "all N" is N rules or N - 1
                # rules plus that check.
                if int(allm.group(1)) in (len(rules), len(rules) + 1):
                    for r in rules:
                        res[(conf, r)] = (PASS, jobs, where)
                else:
                    warn.append(f"{where}: {conf} 'all {allm.group(1)}' verified, but its spec now has {len(rules)} "
                                f"rules and invariants; not counted")
            else:
                for r in re.findall(r"`(\w+)`", c[2]):
                    if r in rules:
                        res[(conf, r)] = (PASS, jobs, where)
            for col in c[3:6]:
                for r in re.findall(r"`(\w+)`", col):
                    if r in rules:
                        res[(conf, r)] = (FAIL if col is c[3] else NOT_RUN, jobs, where)
        elif header.startswith("| Conf | Rule | Status | Job |") and len(c) >= 4:
            names = re.findall(r"`(\w+)`", c[1])
            if re.sub(r"`\w+`|,|\s", "", c[1]):
                continue  # the rule cell qualifies the result ("over `pauseAll`"); not a whole-rule result
            jobs = tuple(JOB.findall(c[2] + " " + c[3]))
            status = c[2]
            if re.match(r"^Verified(?::|$)", status) and not re.search(r"running|requires|except", status):
                st = PASS
            elif re.match(r"^(TIMEOUT|Violated|UNKNOWN)", status, re.I):
                st = NOT_RUN if not status.lower().startswith("violated") else FAIL
            else:
                st = NOT_RUN
            if not jobs:
                continue
            for r in names:
                if r in rules:
                    res[(conf, r)] = (st, jobs, where)
    return res, warn


# ---------------------------------------------------------------------------------------------------------------------
# Run results
# ---------------------------------------------------------------------------------------------------------------------

def _norm_test_path(p: str) -> str:
    p = p.replace("\\", "/")
    i = p.find("test/")
    return p[i:] if i >= 0 else p


class Results:
    """Results of one run: Foundry and Halmos functions, and prover results (recorded ones always included)."""

    def __init__(self, paths: list[Path] | None = None, recorded: bool = True):
        self.given = bool(paths)
        self.tests: dict[tuple[str, str, str], list[str]] = defaultdict(list)  # (file, contract, fn) -> statuses
        self.prover, self.warnings = (dict(recorded_prover_results()[0]), list(recorded_prover_results()[1])) \
            if recorded else ({}, [])
        self.halmos_recorded = recorded
        files: list[Path] = []
        for p in paths or []:
            files += sorted(x for x in p.rglob("*") if x.suffix in (".json", ".txt")) if p.is_dir() else [p]
        if recorded and HALMOS_LOGS.is_dir():
            for f in sorted(HALMOS_LOGS.glob("*.txt")):
                self._halmos(f, recorded=True)
        for f in files:
            self._load(f)

    def _load(self, f: Path) -> None:
        text = f.read_text(errors="ignore")
        s = text.lstrip()
        if s.startswith("{"):
            try:
                data = json.loads(s)
            except json.JSONDecodeError:
                # `forge test --json` may print one JSON object per invocation; read each line that parses.
                for line in s.splitlines():
                    line = line.strip()
                    if line.startswith("{"):
                        try:
                            self._json(json.loads(line), f)
                        except json.JSONDecodeError:
                            self.warnings.append(f"{f}: a line is not JSON")
                return
            self._json(data, f)
        elif "Running " in text and re.search(r"^\[(PASS|FAIL|TIMEOUT|ERROR)\]", text, re.M):
            self._halmos(f)

    def _json(self, data: dict, f: Path) -> None:
        if data.get("tool") == "certora":
            conf, job = data.get("conf", ""), str(data.get("job", ""))
            jobs = tuple(JOB.findall(job)) or ((job,) if job else ())
            if not jobs:
                self.warnings.append(f"{f}: certora result without a job id; not counted")
                return
            cf = confs().get(conf)
            if not cf:
                self.warnings.append(f"{f}: certora result for unknown conf {conf}")
                return
            rules = data.get("rules") or {}
            if data.get("all_rules_verified"):
                rules = {r: "VERIFIED" for r in (cf["rules"] or spec_rules(cf["spec"]))}
            for r, st in rules.items():
                ok = str(st).upper() in ("VERIFIED", "SUCCESS", "PASS")
                bad = str(st).upper() in ("VIOLATED", "FAIL", "FAILURE", "SANITY_FAIL", "ERROR")
                self.prover[(conf, r)] = (PASS if ok else FAIL if bad else NOT_RUN, jobs, str(f))
            return
        for key, suite in data.items():
            if not isinstance(suite, dict) or "test_results" not in suite:
                continue
            path, _, contract = key.rpartition(":")
            for name, r in suite["test_results"].items():
                fn = name.split("(")[0]
                st = (r or {}).get("status", "")
                self.tests[(_norm_test_path(path), contract, fn)].append(
                    PASS if st == "Success" else FAIL if st == "Failure" else NOT_RUN)
                # Foundry runs every invariant of a test contract in one campaign and reports it under one name; each
                # invariant's own result is in invariant_predicate_results.
                for p in (r or {}).get("invariant_predicate_results") or []:
                    if p.get("name") and p["name"] != fn:
                        ps = p.get("status", "")
                        self.tests[(_norm_test_path(path), contract, p["name"])].append(
                            PASS if ps == "Success" else FAIL if ps == "Failure" else NOT_RUN)

    def _halmos(self, f: Path, recorded: bool = False) -> None:
        current = None
        for line in f.read_text(errors="ignore").splitlines():
            m = re.search(r"Running \d+ tests for (\S+):(\w+)", line)
            if m:
                current = (_norm_test_path(m.group(1)), m.group(2))
                continue
            m = re.match(r"^\[(PASS|FAIL|TIMEOUT|ERROR)\]\s+(\w+)\(", line)
            if m and current:
                st = {"PASS": PASS, "FAIL": FAIL, "ERROR": FAIL}.get(m.group(1), NOT_RUN)
                self.tests[(current[0], current[1], m.group(2))].append(st)

    def state(self, tag: dict) -> tuple[str, str]:
        """(state, evidence) of one tag on a check."""
        if tag["kind"] == "cvl":
            spec = "certora/specs/" + Path(tag["file"]).name if tag["file"].startswith("certora/specs/") else tag["file"]
            states = []
            for conf, c in confs().items():
                if c["spec"] != spec and not c["spec"].endswith("/" + Path(tag["file"]).name):
                    continue
                r = self.prover.get((conf, tag["fn"]))
                if r:
                    states.append((r[0], f"{conf} job {r[1][0]}"))
            return _combine(states)
        states = []
        for f, c in tag["runners"]:
            for st in self.tests.get((f, c, tag["fn"]), []):
                states.append((st, f"{f}:{c}.{tag['fn']}"))
        return _combine(states)


def _combine(states: list[tuple[str, str]]) -> tuple[str, str]:
    if any(s == FAIL for s, _ in states):
        return FAIL, next(e for s, e in states if s == FAIL)
    if any(s == PASS for s, _ in states):
        return PASS, next(e for s, e in states if s == PASS)
    return NOT_RUN, (states[0][1] + " (skipped or timed out)") if states else "no result"


def cvl_stand_in_keys(tag: dict) -> set[str]:
    """Contract keys whose stand-ins the confs of a CVL tag's spec verify or link."""
    name = Path(tag["file"]).name
    return stand_in_keys(n for c in confs().values() if c["spec"].endswith("/" + name) for n in c["stand_ins"])


def tag_stand_in_keys(tag: dict) -> set[str]:
    if tag["kind"] == "cvl":
        return cvl_stand_in_keys(tag)
    names = set(tag["stand_ins"])
    for f, _ in tag["runners"]:
        names |= stand_ins_of((CONTRACTS / f).resolve())
    return stand_in_keys(names)


# ---------------------------------------------------------------------------------------------------------------------
# @custom:spec in contracts/src
# ---------------------------------------------------------------------------------------------------------------------

@lru_cache(maxsize=None)
def _src_decls() -> dict[str, dict]:
    out = {}
    for p in _sol_files(SRC_DIR):
        for d in _declarations(_text(p), p):
            out.setdefault(d["name"], d)
    return out


@lru_cache(maxsize=None)
def _has_concrete_heir(name: str) -> bool:
    decls = _src_decls()
    children: dict[str, set[str]] = defaultdict(set)
    for n, d in decls.items():
        for b in d["bases"]:
            children[b].add(n)
    seen, todo = set(), list(children.get(name, ()))
    while todo:
        c = todo.pop()
        if c in seen:
            continue
        seen.add(c)
        d = decls.get(c)
        if d and d["kind"] == "contract" and not d["abstract"]:
            return True
        todo.extend(children.get(c, ()))
    return False


def declaration_only(path: Path, line_index: int) -> str:
    """Why a `@custom:spec` tag at this line of a src file is on a body-less declaration, or "" when it marks code."""
    lines = _text(path).splitlines()
    j = line_index + 1
    while j < len(lines) and (not lines[j].strip() or lines[j].strip().startswith(("//", "/*", "*"))):
        j += 1
    if j >= len(lines):
        return "no declaration follows"
    decl = DECL.match(lines[j])
    if decl:
        if decl.group(2) == "interface":
            return f"interface {decl.group(3)}"
        if decl.group(1) and not _has_concrete_heir(decl.group(3)):
            return f"abstract contract {decl.group(3)}, which no concrete contract in src/ inherits"
        return ""
    owner = None
    for d in sorted(_declarations(_text(path), path), key=lambda d: d["line"]):
        if d["line"] < j:
            owner = d
    if owner and owner["kind"] == "interface":
        return f"a member of interface {owner['name']}"
    if re.match(r"^\s*(function|modifier)\b", lines[j]):
        head, k = "", j
        while k < len(lines):
            head += lines[k]
            depth = head.count("(") - head.count(")")
            if depth <= 0 and ("{" in lines[k] or ";" in lines[k]):
                break
            k += 1
        body = head.find("{")
        semi = head.rfind(";")
        if body < 0 or (0 <= semi < body):
            name = re.match(r"^\s*(?:function|modifier)\s+(\w+)", lines[j])
            return f"`{name.group(1) if name else '?'}` has no body"
        if owner and owner["abstract"] and not _has_concrete_heir(owner["name"]):
            return f"abstract contract {owner['name']}, which no concrete contract in src/ inherits"
    return ""
