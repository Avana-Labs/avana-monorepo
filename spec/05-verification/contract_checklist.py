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
contracts/certora. It is the "every ID linked" step of the per-contract gate in spec/contracts-build-todo.md.
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
CONTRACTS: dict[str, tuple[list[str], list[str], list[str]]] = {
    "AvanaRoles": (["15-governance-and-timelock.md"], ["AvanaRoles"], []),
    "Lock": (["16-lock.md"], ["Lock"], ["Lock.spec"]),
    "AvanaTimelock": (["15-governance-and-timelock.md"], ["AvanaTimelock", "Timelock"], ["AvanaTimelock.spec"]),
    "LPPriceMath": (["10-lp-oracle.md"], ["LPPriceMath"], []),
    "SettlementMath": (["11-lpvaultswap.md"], ["SettlementMath"], []),
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
    "AaveV3FlashSource": (["11-lpvaultswap.md"], ["AaveV3FlashSource", "IFlashSource", "flash source"], ["FlashSource.spec"]),
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


def word_re(names: list[str]) -> re.Pattern:
    return re.compile(r"(?<![A-Za-z0-9])(?:" + "|".join(re.escape(n) for n in names) + r")(?![A-Za-z0-9])")


def page_ids(pages: list[str]) -> tuple[list[tuple[str, str, str]], set[str]]:
    """REQ-/SPEC- IDs defined on the pages, and every INV- cited on them."""
    defined, cited_inv = [], set()
    for page in pages:
        path = CONTRACT_PAGES / page
        for n, line in enumerate(path.read_text().splitlines(), 1):
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

    def box(ok: bool) -> str:
        return "[x]" if ok else "[ ]"

    lines = [f"# Checklist: {args.contract}", "",
             f"Spec pages: {', '.join(pages)}. CVL specs: {', '.join(cvl) or 'none'}.", "",
             f"## REQ / SPEC on the page ({len(reqs)})", ""]
    lines += [f"- {box(r in links)} `{r}` ({where}) {text}" + (f" — {', '.join(links[r])}" if r in links else "")
              for r, text, where in reqs]
    lines += ["", f"## TEST rows ({len(tests)})", ""]
    lines += [f"- {box(t in done)} `{t}` [{kind}] {text}" for t, kind, text in tests]
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

    missing = ([r for r, _, _ in reqs if r not in links] + [t for t, _, _ in tests if t not in done]
               + [p for p, _, _ in props if p not in done])
    if args.check and missing:
        print(f"{len(missing)} IDs without a link from contracts/: {', '.join(missing[:20])}"
              + (" …" if len(missing) > 20 else ""), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
