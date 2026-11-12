#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Per-contract checklist: every spec ID one contract must cover, and whether a test already links it.

For one contract it lists
  - the REQ-/SPEC- IDs defined on its spec page (2.x), with their link status in contracts/test and contracts/certora;
  - the TEST rows of 5.1 whose "Contract / flow" column names the contract;
  - the PROP rows mapped to its CVL spec in contracts/certora/README.md, plus the 5.2 rows that name it, with the tool;
  - the INV rows of 4.1 the page cites or that name the contract;
  - the ATTACK scenarios of 4.2 whose Target names the contract.

Usage, from the repository root:
    spec/05-verification/.venv/bin/python spec/05-verification/contract_checklist.py --list
    spec/05-verification/.venv/bin/python spec/05-verification/contract_checklist.py Lock [--out FILE] [--check]

--check exits 1 when a REQ-/SPEC- ID of the page, a TEST row or a PROP row has no link from contracts/test or
contracts/certora. It is the "every ID linked" step of the per-contract gate. Rows owned by a contract not written
yet (PENDING) are shown as deferred to it and are not part of another contract's --check. A contract specified in
one section of a shared page takes that section only ("page.md#Heading"); a row of that section another contract
decides is shown as owned by it (OWNED_ELSEWHERE) and stays on the owner's checklist. Table rows of a shared page that
only a pending contract decides, and TEST rows whose test drives a pending contract, are deferred by name
(DEFERRED_ROWS); rows about a deployed chain's configuration or an off-chain sizing rule are shown as checked outside
contracts/ (OUTSIDE_CONTRACTS), with the reason, and are not part of --check.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import trace as tr  # noqa: E402  (the traceability script in this folder; its main() is guarded)

ROOT = tr.ROOT
SPEC = tr.SPEC
CONTRACT_PAGES = SPEC / "02-contracts"
TESTS = SPEC / "05-verification" / "01-test-requirements.md"
PROPS = SPEC / "05-verification" / "02-formal-properties.md"
INVS = SPEC / "04-security" / "01-global-invariants.md"
ATTACKS = SPEC / "04-security" / "02-attack-scenarios.md"
CERTORA_README = ROOT / "contracts" / "certora" / "README.md"

# key: (spec pages, names used for the contract in 5.1 / 4.1 / 4.2 / 5.2, CVL spec files)
# A page written "page.md#Heading" contributes only the IDs under that "## Heading" of the page (its "###"
# sub-sections included): a library or adapter specified in one section of a page it shares with the contract that
# uses it. The page's main contract keeps the whole page, so every ID on it stays on at least one checklist.
CONTRACTS: dict[str, tuple[list[str], list[str], list[str]]] = {
    "AvanaRoles": (["15-governance-and-timelock.md"], ["AvanaRoles"], []),
    "Lock": (["16-lock.md"], ["Lock"], ["Lock.spec"]),
    "AvanaTimelock": (["15-governance-and-timelock.md"], ["AvanaTimelock", "Timelock"], ["AvanaTimelock.spec"]),
    "LPPriceMath": (["10-lp-oracle.md#LPPriceMath"], ["LPPriceMath"], []),
    "SettlementMath": (["11-lpvaultswap.md#Settlement math"], ["SettlementMath"], []),
    "ParameterStore": (["09-parameter-store.md"], ["ParameterStore"], ["ParameterStore.spec"]),
    "MarketRegistry": (["08-market-registry.md"], ["MarketRegistry"], ["MarketRegistry.spec"]),
    "LPOracle": (["10-lp-oracle.md"], ["LPOracle"], ["LPOracle.spec"]),
    "DebtOracle": (["10-lp-oracle.md"], ["DebtOracle"], ["DebtOracle.spec"]),
    "VaultToken": (["04-vault-tokens.md"], ["VaultToken", "vault token", "Vault token"], ["VaultToken.spec"]),
    "VaultTokenFactory": (["04-vault-tokens.md"], ["VaultTokenFactory"], ["VaultTokenFactory.spec"]),
    "Collateralization": (["03-collateralization.md"], ["Collateralization"], ["Collateralization.spec"]),
    "ClPricing": (["10-lp-oracle.md", "20-uniswap-v3-integration.md"], ["LPOracleCL", "CL LPOracle"], []),
    "UniswapV3Integration": (
        ["02-lp-vault.md", "19-amm-integration-interface.md", "20-uniswap-v3-integration.md"],
        ["UniswapV3Integration", "Uniswap v3 integration", "LPVault", "LPVaults", "AMM integrations"],
        ["UniswapV3Integration.spec", "LPVault.spec"],
    ),
    "SlipstreamIntegration": (
        ["19-amm-integration-interface.md", "21-aerodrome-slipstream-integration.md"],
        ["SlipstreamIntegration", "Slipstream integration", "LPVault", "LPVaults", "AMM integrations"],
        ["SlipstreamIntegration.spec", "LPVault.spec"],
    ),
    "AaveV3FlashSource": (
        ["11-lpvaultswap.md#Flash source"], ["AaveV3FlashSource", "IFlashSource", "flash source"], ["FlashSource.spec"]
    ),
    "PositionProxy": (["05-position-proxy-and-proxy-manager.md"], ["PositionProxy"], ["PositionProxy.spec"]),
    "ProxyManager": (
        ["05-position-proxy-and-proxy-manager.md"], ["ProxyManager"], ["ProxyManager.spec", "ProxyManagerIsolation.spec"]
    ),
    "RiskModule": (["07-risk-module.md"], ["RiskModule"], ["RiskModule.spec", "RiskModuleDrift.spec"]),
    "AaveAdapter": (["06-aave-adapter.md"], ["AaveAdapter", "Adapter"], ["AaveAdapter.spec", "AaveAdapterGates.spec"]),
    "SwapRoutes": (
        ["12-settlement-routes.md"],
        ["DexPath", "WrapperThenDex", "PegModule", "swap routes", "Swap routes", "settlement routes", "routes", "Routes",
         "Route contracts", "ISettlementRoute"],
        ["SettlementRoute.spec"],
    ),
    "PayoutEscrow": (["18-payout-escrow.md"], ["PayoutEscrow", "payout escrow"], ["PayoutEscrow.spec"]),
    "LPVaultSwap": (["11-lpvaultswap.md"], ["LPVaultSwap"], ["LPVaultSwap.spec"]),
    "CoverageSpoke": (["14-first-loss-reserve.md"], ["CoverageSpoke", "Coverage Spoke", "Coverage Spokes"], ["CoverageSpoke.spec"]),
    "Lens": (["17-lens.md"], ["Lens"], []),
}

# 5.1 rows whose "Contract / flow" column applies to every contract (shown separately, not part of --check).
CROSS = re.compile(r"(?i)\b(?:all (?:avana )?contracts|every (?:avana )?contract|(?:all |every |hostile )?upgradeable contracts?|"
                   r"immutable contracts|all upgradeable contracts|whole system)\b")

ID_IN_TEXT = re.compile(rf"\b({tr.REQ_ID})\b")
PAGE_REQ = re.compile(r"^(?:REQ|SPEC)-")

# Contracts whose code has not landed in contracts/src yet. A row that only they can satisfy is shown as deferred
# to them and left out of --check for every other contract: a TEST row whose "Contract / flow" column names one
# of them (the test drives that contract), and a page REQ/SPEC row in which every contract named by its deciding
# part is one of them (see deferred_to). Such a row returns to scope when the contract lands; --check fails once
# a listed contract has a `contract <Name>` definition in contracts/src, so this tuple cannot go stale.
PENDING: tuple[str, ...] = ("Lens",)
MODAL = re.compile(r"\b(?:MUST|MAY|SHALL)\b")

# Rows inside a "page.md#Heading" section that the section's library or adapter does not decide: ID -> (the contract
# whose checklist keeps the row, the reason). Shown as owned there and left out of every other contract's --check;
# --check fails if the owner's own pages do not define the row, so no row drops off every checklist.
OWNED_ELSEWHERE: dict[str, tuple[str, str]] = {}

# Rows of a shared page (a role table, a restricted-function matrix, or a list item that names written contracts only
# as context) whose rule only a PENDING contract can satisfy, which deferred_to cannot see because it never reads
# those tables, and TEST rows of 5.1 whose test drives a PENDING contract its "Contract / flow" column does not name:
# ID -> (the pending contracts, comma-separated, and the reason). Deferred exactly like deferred_to's rows, on every
# checklist that lists the row; --check fails on an entry naming a contract that is not pending, so each row returns
# to scope when its contract lands and the entry cannot go stale.
DEFERRED_ROWS: dict[str, tuple[str, str]] = {}

# Rows that state a property of a deployed chain (release manifest, Safe owners and thresholds, Aave-side roles, the
# launch listing's routes measured on a fork), of a contract that does not exist, or a sizing rule the Aave DAO and
# its risk service providers apply with no on-chain enforcement, which no test under contracts/ can check:
# ID -> reason. Listed as checked outside contracts/ and left out of --check; the deployment checks (TEST-135,
# TEST-214, TEST-224), the live-config check and the spec-stage sizing models own them.
OUTSIDE_CONTRACTS: dict[str, str] = {
    "REQ-ACCESS-023": "the live-config check reads hasRole for every release-manifest pair on a deployed chain",
    "REQ-ACCESS-070": "the Aave Protocol Guardian's permissions on the Aave SpokeConfigurator are Aave's AccessManager",
    "REQ-ACCESS-071": "who holds SPOKE_USER_POSITION_UPDATER_ROLE and Aave-side authority is Aave's configuration",
    "REQ-ACCESS-102": "Safe owners and threshold of each chain's governance multisig (getOwners, getThreshold)",
    "REQ-ACCESS-103": "Safe owners and threshold of each chain's Emergency Guardian",
    "REQ-ACCESS-104": "pairwise-disjoint signer sets of the four Safes of each chain",
    "REQ-ACCESS-173": "one AvanaTimelock, governance Safe and Emergency Guardian per chain, set by deployment",
    "REQ-ACCESS-115": "names the fork tests on the deployed configuration (TEST-067, TEST-214, TEST-224)",
    "REQ-ACCESS-058": "no SettlementBudget contract exists, so there is no selector signature to test; the deployed "
                      "selector inventory of REQ-ACCESS-025 fails on any unlisted selector",
    "REQ-ACCESS-059": "no SettlementBudget contract exists, so there is no withdraw selector to test; the deployed "
                      "selector inventory of REQ-ACCESS-025 fails on any unlisted selector",
    "TEST-129": "quarterly guardian rehearsal with the real Safe payloads on a fork of the deployed chain",
    "TEST-214": "role snapshot against the release manifest and the deployed Safes",
    "REQ-FLR-009": "Aave Labs' confirmation of the coverage caller is recorded in each chain's deployment manifest "
                   "before any CDP Spoke drawCap is raised above 0; the deployment check reads the manifest",
    "SPEC-FLR-004": "reserve sizing against caps is Aave DAO and risk-service-provider guidance with no on-chain "
                    "enforcement (Q-249); the spec-stage models MATH-ST-76 and MATH-ST-90 check the formula",
    "REQ-FLR-028": "the risk service providers size caps against SPEC-FLR-004 and SPEC-FLR-005 before approval; no "
                   "contract reads the sizing (Q-249)",
    "REQ-ROUTE-039": "a Base GHO reserve's drawCap is sized to measured off-chain route depth and Aave V3 Pool "
                     "liquidity by the listing payload; that every market has both routes into GHO before "
                     "enableDebtReserve is REQ-ROUTE-036, tested in MarketRegistry.MultiDebt",
    "TEST-120": "measures the launch listing's routes on both forks at the pinned blocks (RPC_MAINNET, RPC_BASE): "
                "which pools, thresholds and stress sizes the listing payload sets; the route rules it relies on "
                "(own pool refused, token class, primary and backup per debt asset) are TEST-054 locally",
    "REQ-ORACLE-052": "an off-chain listing rule: which Chainlink proxy is each token's primary and that no alternate "
                      "route assumes a peg are reviewed in the listing package (3.8); checkConfig's on-chain route "
                      "rules are REQ-ORACLE-046 to REQ-ORACLE-051 (TEST-219)",
    "REQ-ORACLE-057": "an off-chain listing rule: the (1 - CF) margin study, the per-pool manipulation-cost study and "
                      "each second source's stress history are evidence in the listing package (3.8)",
    "REQ-RISK-046": "cap and reserve sizing is the Aave DAO's and its risk service providers' off-chain decision with "
                    "no on-chain enforcement (Q-249); the spec-stage models of SPEC-CAP-007 check the formula",
    "SPEC-CAP-007": "cap sizing guidance for the Aave DAO and its risk service providers; Avana enforces none of it "
                    "on-chain (Q-249); MATH-AR-29/30/31/43/44 and SIM-02B/08A check the formula",
    "REQ-AMM-CORE-015": "a listing measurement: the worst-case seizure gas of a market is measured on a fork of its "
                        "chain at listing; the local bound G(16) <= 5.15M is TEST-123 (LPVaultSwap.Liquidation.gas)",
    "SPEC-AMM-SLIP-002": "Slipstream's own fee split on Base, which no Avana contract computes; the custodied position "
                         "is paid whatever the NPM's collect returns (TEST-017); comparing tokensOwed growth with the "
                         "formula is a Base fork measurement",
    "TEST-117": "measures the deployed Chainlink feeds on both forks at the pinned blocks (decimals, min/max answers, "
                "heartbeats of the launch feeds); the rules it relies on are local tests: same round never refreshes "
                "(TEST-040), per-feed borrowPriceMaxAge (TEST-028, TEST-201), disjoint backup routes and normalised "
                "minimum >= 1 (TEST-219), fixed GHO source (TEST-201)",
}


CONTRACT_IDENT = re.compile(r"^[A-Z][A-Za-z0-9]*$")


def named_contracts(text: str) -> set[str]:
    """Contracts the text names by an identifier (`AaveAdapter`, `LPVault`, `Collateralization`); the generic aliases
    of CONTRACTS ("vault token", "routes", "flash source") are ordinary nouns in prose and name no contract here."""
    return {k for k, (_, names, _) in CONTRACTS.items()
            if any(CONTRACT_IDENT.match(n) for n in names)
            and word_re([n for n in names if CONTRACT_IDENT.match(n)]).search(text)}


def deferred_to(text: str, key: str) -> str:
    """The pending contracts a row is deferred to, or "" when the row stays in scope for `key`.

    The deciding part is the subject before the first MUST/MAY/SHALL of a list item or heading (the whole item when
    that names no contract), and the behaviour column of a failure table row. A row is deferred only when that part
    names at least one contract and every contract it names is pending and is not `key`."""
    found = named_contracts(text)
    if not found or any(k not in PENDING or k == key for k in found):
        return ""
    return ", ".join(sorted(found))


def implemented_pending() -> list[str]:
    srcs = [p.read_text(errors="ignore") for p in (ROOT / "contracts" / "src").rglob("*.sol")]
    return [k for k in PENDING if any(re.search(rf"^\s*(?:abstract\s+)?contract\s+{k}\b", s, re.M) for s in srcs)]


def deferred_page_rows(pages: list[str], key: str) -> dict[str, str]:
    """REQ-/SPEC- ID -> pending contracts, for page rows deferred under deferred_to. Tables other than the failure
    tables (`| ID | Condition | Behavior ...`) are never deferred: their rows name contracts in lists and scopes."""
    out: dict[str, str] = {}
    for entry in pages:
        header = ""
        for line in (CONTRACT_PAGES / entry.partition("#")[0]).read_text().splitlines():
            if line.startswith("| ID |"):
                header = line
            m = tr.DEF_LINE.match(line)
            if not m or not PAGE_REQ.match(m.group(1)) or m.group(1) in out:
                continue
            if line.lstrip().startswith("|"):
                if not re.match(r"^\| ID \| Condition \|", header):
                    continue
                part = line.strip().strip("|").split("|")[-1]
            else:
                modal = MODAL.search(line)
                part = line[:modal.start()] if modal and named_contracts(line[:modal.start()]) else line
            owner = deferred_to(part, key)
            if owner:
                out[m.group(1)] = owner
    return out


def deferred_test_rows(key: str) -> dict[str, str]:
    """TEST ID -> pending contracts named in its "Contract / flow" column (other than `key`)."""
    out = {}
    for cols in table_rows(TESTS, "TEST"):
        if len(cols) >= 4:
            later = sorted(k for k in named_contracts(cols[3]) if k in PENDING and k != key)
            if later:
                out[cols[0].strip("`")] = ", ".join(later)
    return out


def word_re(names: list[str]) -> re.Pattern:
    return re.compile(r"(?<![A-Za-z0-9])(?:" + "|".join(re.escape(n) for n in names) + r")(?![A-Za-z0-9])")


def page_ids(pages: list[str]) -> tuple[list[tuple[str, str, str]], set[str]]:
    """REQ-/SPEC- IDs defined on the pages (or on the named "## " section of a "page.md#Heading" entry), and every
    INV- cited there."""
    defined, cited_inv = [], set()
    for entry in pages:
        page, _, section = entry.partition("#")
        path = CONTRACT_PAGES / page
        if section and not any(h.strip().strip("`") == section for h in re.findall(r"(?m)^## (.*)$", path.read_text())):
            raise SystemExit(f"{entry}: no '## {section}' heading on {page}")
        current = ""
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if line.startswith("## "):
                current = line[3:].strip().strip("`")
            if section and current != section:
                continue
            m = tr.DEF_LINE.match(line)
            if m and PAGE_REQ.match(m.group(1)):
                defined.append((m.group(1), tr.norm(m.group(2))[:110], f"{page}:{n}"))
            cited_inv.update(i for i in ID_IN_TEXT.findall(line) if i.startswith("INV-"))
    seen, unique = set(), []
    for row in defined:
        if row[0] not in seen:
            seen.add(row[0])
            unique.append(row)
    return unique, cited_inv


def table_rows(path: Path, prefix: str) -> list[list[str]]:
    rows = []
    for line in path.read_text().splitlines():
        if line.startswith(f"| `{prefix}-") or line.startswith(f"| {prefix}-"):
            rows.append([c.strip() for c in line.strip().strip("|").split("|")])
    return rows


def tests_for(names: re.Pattern) -> list[tuple[str, str, str]]:
    out = []
    for cols in table_rows(TESTS, "TEST"):
        if len(cols) >= 4 and names.search(cols[3]):
            out.append((cols[0].strip("`"), cols[1], tr.norm(cols[2])[:110]))
    return out


def cross_tests() -> list[tuple[str, str, str]]:
    return [(c[0].strip("`"), c[1], tr.norm(c[2])[:110]) for c in table_rows(TESTS, "TEST")
            if len(c) >= 4 and CROSS.search(c[3])]


def props_for(names: re.Pattern, cvl: list[str]) -> list[tuple[str, str, str]]:
    tools = {c[0].strip("`"): (c[3] if len(c) > 3 else "", tr.norm(c[1])[:110]) for c in table_rows(PROPS, "PROP")}
    picked: set[str] = set()
    for cols in table_rows(CERTORA_README, "PROP"):
        if len(cols) >= 3 and any(spec in cols[2] for spec in cvl):
            picked.add(cols[0].strip("`"))
    for pid, (_, text) in tools.items():
        if names.search(text):
            picked.add(pid)
    return [(p, tools.get(p, ("?", ""))[0], tools.get(p, ("", "?"))[1]) for p in sorted(picked)]


def invs_for(names: re.Pattern, cited: set[str]) -> list[tuple[str, str]]:
    out = []
    for cols in table_rows(INVS, "INV"):
        iid = cols[0].strip("`")
        if iid in cited or (len(cols) > 1 and names.search(cols[1])):
            out.append((iid, tr.norm(cols[1])[:110] if len(cols) > 1 else ""))
    return out


def attacks_for(names: re.Pattern) -> list[tuple[str, str]]:
    out, current = [], None
    for line in ATTACKS.read_text().splitlines():
        m = re.match(r"^### (ATTACK-[0-9]{3}): (.*)$", line)
        if m:
            current = (m.group(1), m.group(2).strip())
            continue
        if current and line.startswith("| Target |") and names.search(line):
            out.append(current)
            current = None
    return out


def linked_ids() -> dict[str, list[str]]:
    """ID -> check IDs from contracts/test and contracts/certora only (not the spec-stage models)."""
    links, _ = tr.collect_links()
    out: dict[str, list[str]] = {}
    for rid, hits in links.items():
        checks = [h["id"] for h in hits if h["where"].startswith("contracts/") and h["kind"] != "Solidity"]
        if checks:
            out[rid] = sorted(set(checks))
    return out


def implemented_tests() -> set[str]:
    """TEST-/PROP- IDs that have a test or rule tag in contracts/."""
    _, check_targets = tr.collect_links()
    return set(check_targets)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("contract", nargs="?", help="contract key (see --list)")
    ap.add_argument("--list", action="store_true", help="list contract keys with ID counts")
    ap.add_argument("--out", type=Path, help="write the checklist to this file instead of stdout")
    ap.add_argument("--check", action="store_true", help="exit 1 if any listed ID has no link from contracts/")
    args = ap.parse_args()

    if args.list or not args.contract:
        print(f"{'contract':24} {'REQ/SPEC':>8} {'TEST':>5} {'PROP':>5} {'INV':>4} {'ATTACK':>6}")
        for key, (pages, names, cvl) in CONTRACTS.items():
            rx = word_re(names)
            reqs, cited = page_ids(pages)
            print(f"{key:24} {len(reqs):>8} {len(tests_for(rx)):>5} {len(props_for(rx, cvl)):>5} "
                  f"{len(invs_for(rx, cited)):>4} {len(attacks_for(rx)):>6}")
        return 0

    if args.contract not in CONTRACTS:
        print(f"unknown contract {args.contract}; use --list", file=sys.stderr)
        return 2
    pages, names, cvl = CONTRACTS[args.contract]
    rx = word_re(names)
    reqs, cited = page_ids(pages)
    tests, props = tests_for(rx), props_for(rx, cvl)
    invs, attacks = invs_for(rx, cited), attacks_for(rx)
    links, done = linked_ids(), implemented_tests()
    req_later, test_later = deferred_page_rows(pages, args.contract), deferred_test_rows(args.contract)
    req_ids = {r for r, _, _ in reqs}
    req_later.update({r: owner for r, (owner, _) in DEFERRED_ROWS.items() if r in req_ids and r not in req_later})
    test_ids = {t for t, _, _ in tests}
    test_later.update({t: owner for t, (owner, _) in DEFERRED_ROWS.items() if t in test_ids and t not in test_later})
    stale = sorted(r for r, (owner, _) in DEFERRED_ROWS.items()
                   if any(k not in PENDING for k in owner.split(", ")))
    outside = {i: why for i, why in OUTSIDE_CONTRACTS.items()
               if i in req_ids or i in {t for t, _, _ in tests}}
    owned = {r: OWNED_ELSEWHERE[r] for r, _, _ in reqs if OWNED_ELSEWHERE.get(r, (args.contract,))[0] != args.contract}
    orphaned = [r for r, (owner, _) in owned.items() if r not in {i for i, _, _ in page_ids(CONTRACTS[owner][0])[0]}]

    def box(ok: bool) -> str:
        return "[x]" if ok else "[ ]"

    def later(rid: str, deferred: dict[str, str], ok: bool) -> str:
        return f" — deferred to {deferred[rid]} (not written yet)" if rid in deferred and not ok else ""

    def offchain(rid: str, ok: bool) -> str:
        return f" — checked outside contracts/: {outside[rid]}" if rid in outside and not ok else ""

    lines = [f"# Checklist: {args.contract}", "",
             f"Spec pages: {', '.join(pages)}. CVL specs: {', '.join(cvl) or 'none'}.", "",
             f"## REQ / SPEC on the page ({len(reqs)})", ""]
    lines += [f"- {box(r in links)} `{r}` ({where}) {text}" + (f" — {', '.join(links[r])}" if r in links else "")
              + later(r, req_later, r in links) + offchain(r, r in links)
              + (f" — owned by {owned[r][0]}: {owned[r][1]}" if r in owned and r not in links else "")
              for r, text, where in reqs]
    lines += ["", f"## TEST rows ({len(tests)})", ""]
    lines += [f"- {box(t in done)} `{t}` [{kind}] {text}" + later(t, test_later, t in done) + offchain(t, t in done)
              for t, kind, text in tests]
    cross = cross_tests()
    lines += ["", f"## Cross-cutting TEST rows, every contract ({len(cross)})", ""]
    lines += [f"- {box(t in done)} `{t}` [{kind}] {text}" for t, kind, text in cross]
    lines += ["", f"## PROP rows ({len(props)})", ""]
    lines += [f"- {box(p in done)} `{p}` [{tool}] {text}" for p, tool, text in props]
    lines += ["", f"## INV ({len(invs)})", ""]
    lines += [f"- {box(i in links)} `{i}` {text}" for i, text in invs]
    lines += ["", f"## ATTACK ({len(attacks)})", ""]
    lines += [f"- {box(a in links)} `{a}` {title}" for a, title in attacks]
    text = "\n".join(lines) + "\n"
    if args.out:
        args.out.write_text(text)
    else:
        sys.stdout.write(text)

    missing = ([r for r, _, _ in reqs if r not in links and r not in req_later and r not in owned and r not in outside]
               + [t for t, _, _ in tests if t not in done and t not in test_later and t not in outside]
               + [p for p, _, _ in props if p not in done])
    if args.check and stale:
        print(f"DEFERRED_ROWS names a contract that is not in PENDING for: {', '.join(stale)}", file=sys.stderr)
        return 1
    landed = implemented_pending()
    if args.check and landed:
        print(f"PENDING lists contracts that now have code in contracts/src: {', '.join(landed)}; remove them",
              file=sys.stderr)
        return 1
    if args.check and orphaned:
        print(f"OWNED_ELSEWHERE names an owner whose pages do not define: {', '.join(orphaned)}", file=sys.stderr)
        return 1
    if args.check and missing:
        print(f"{len(missing)} IDs without a link from contracts/: {', '.join(missing[:20])}"
              + (" …" if len(missing) > 20 else ""), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
