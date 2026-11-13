#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Per-contract checklist: every spec ID one contract must cover, and whether a check of it ran and passed.

For one contract it lists
  - the REQ-/SPEC- IDs defined on its spec page (2.x);
  - the TEST rows of 5.1 whose "Contract / flow" column names the contract;
  - the PROP rows mapped to its CVL spec in contracts/certora/README.md, plus the 5.2 rows that name it, with the tool;
  - the INV rows of 4.1 the page cites or that name the contract;
  - the ATTACK scenarios of 4.2 whose Target names the contract.

Each row has one of four states (evidence.py decides which tags count):
  [x] verified   a counting test, Halmos check or CVL rule ran and passed (a CVL rule: a prover result with a job id)
  [!] failed     a counting check ran and failed
  [~] not run    counting checks exist and none has a result in the results given
  [ ] unlinked   no counting check: no tag, only tags on another row's test, or only tests that use a stand-in
                 (evidence.STAND_INS) for this contract
For a REQ/SPEC/INV/ATTACK row, a test counts when a tag on it names the row; for a TEST or PROP row, when the test
or rule is tagged with that TEST/PROP id and (for a TEST id) its function name carries it. A TEST row whose
"Contract / flow" column names several contracts counts for each of them separately: for contract X only through a
test whose code deploys or calls X's real contract (exercise_names, evidence.exercises).

Usage, from the repository root:
    spec/05-verification/.venv/bin/python spec/05-verification/contract_checklist.py --list
    spec/05-verification/.venv/bin/python spec/05-verification/contract_checklist.py Lock [--out FILE] [--check]
        [--results PATH ... | --links-only]
    spec/05-verification/.venv/bin/python spec/05-verification/contract_checklist.py --all [--check] [--out-dir DIR]
        [--summary FILE] [--results PATH ... | --links-only]
    spec/05-verification/.venv/bin/python spec/05-verification/contract_checklist.py --uncovered [--check] ...

--results takes `forge test --json-file` output, Halmos logs and certora result files (or folders of them); recorded
prover results (contracts/certora/RUNS.md) and Halmos logs (audit/halmos/results/) are always read. --check exits 1
when a row in scope is not verified. With --links-only (no run results, the check of models.yml), --check exits 1
only on unlinked and failed rows; "not run" is then expected and reported. --check without either is refused.

--all runs every contract key and prints one line per contract. --uncovered lists the TEST rows of 5.1 that are on
no contract's checklist (their "Contract / flow" column names no key); with --check it exits 1 on any of them that is
not verified (not linked, with --links-only) and is not in OUTSIDE_CONTRACTS with its reason. --all includes it.

Rows owned by a contract not written yet (PENDING) are shown as deferred to it and are not part of another
contract's --check. A contract specified in one section of a shared page takes that section only ("page.md#Heading");
a row of that section another contract decides is shown as owned by it (OWNED_ELSEWHERE) and stays on the owner's
checklist. Table rows of a shared page that only a pending contract decides, and TEST rows whose test drives a pending
contract, are deferred by name (DEFERRED_ROWS); rows about a deployed chain's configuration, an off-chain sizing rule,
the keeper and off-chain services, or a CI tool's own run are shown as checked outside contracts/ (OUTSIDE_CONTRACTS),
with the reason, and are not part of --check.

Rows of a "Future integrations" section (a "## " heading on a contract page, a "### " heading in 5.1) bind an AMM
integration of the kind their "Integration kind" column names by `IntegrationCapabilities` fields. While no
`IntegrationCapabilities({...})` literal in contracts/src returns all of those fields, the row is shown as future and is
not part of --check; the commit that adds such an integration brings the row into scope (future_rows).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evidence as ev  # noqa: E402  (tag placement, stand-ins and run results; beside this file)
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
    "Lens": (["17-lens.md"], ["Lens", "LensSpeedModule"], []),
    "FlashLiquidator": (
        ["11-lpvaultswap.md#Flash liquidation helper"],
        ["FlashLiquidator", "OperatorFlashLiquidator", "Flash liquidation helper", "flash liquidation helper"],
        [],
    ),
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
PENDING: tuple[str, ...] = ()
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
    # Keeper, indexer, web and monitoring rows: checked by tests under services/ and packages/, not contracts/. No test
    # there carries these IDs yet, so they are not checked anywhere today; they are listed here so the contract gate
    # does not hide them, and services.yml is where their tests belong.
    "TEST-136": "monitoring service (scheduled live-configuration rerun and drift alerts) in services/; no services "
                "test carries the ID yet",
    "TEST-140": "keeper observe-only mode, services/keeper; no keeper test carries the ID yet",
    "TEST-141": "keeper behaviour, services/keeper; no keeper test carries the ID yet",
    "TEST-142": "keeper liquidation path, services/keeper; no keeper test carries the ID yet",
    "TEST-178": "keeper behaviour, services/keeper; no keeper test carries the ID yet",
    "TEST-143": "Ponder replay and reorg handling, services/indexer; no indexer test carries the ID yet",
    "TEST-144": "Ponder and web, services/ and the app; no test there carries the ID yet",
    "TEST-145": "Convex export, services/; no test there carries the ID yet",
    "TEST-146": "packages/protocol builders and the web app; no test there carries the ID yet",
    "TEST-147": "web app; no test there carries the ID yet",
    "TEST-148": "Convex and web app; no test there carries the ID yet",
    "TEST-149": "web, Ponder and keeper; no test there carries the ID yet",
    "TEST-297": "Lend page builders in packages/protocol; no test there carries the ID yet",
    "REQ-ORACLE-037": "keeper poke schedule (3.6), services/keeper/src/jobs/oraclePoke.ts: every LPOracle and "
                      "DebtOracle at least once per min(3,600 s, fastest leg's heartbeat); checked by "
                      "services/keeper/test/oraclePoke.test.ts (services.yml keeper tests)",
    # CI tool rows: the row is the CI step itself, and the step's own result is the evidence (no Foundry test can be).
    "TEST-001": "contracts.yml build job: `forge soldeer install` against soldeer.lock, the solc and EVM pins of "
                "foundry.toml, and the Foundry version check",
    "TEST-008": "`trace.py --strict`, run locally (not in CI since 2026-11-13): fails on a Foundry test function not "
                "named test_TEST_NNN_…, testFuzz_TEST_NNN_… or invariant_TEST_NNN_… (trace.misnamed_tests) and on a "
                "requirement without a test or property",
    "TEST-005": "models.yml contract-checklists job: contracts/script/check-mock-counterparts.py against "
                "contracts/script/mock-counterparts.json (every mocked external has a fork test on its chain)",
    "TEST-007": "contracts.yml test job: the ci profile's fuzz and invariant runs, and the gate's every-shard rule",
    "TEST-207": "contracts.yml build job: script/check-file-size.sh",
    "TEST-253": "contracts.yml build job and security-fast.sh: `forge fmt --check`, `forge lint`",
    "TEST-254": "security-fast.sh (contracts.yml fast-security job): build with warnings denied, solhint",
    "TEST-255": "security-fast.sh (contracts.yml fast-security job): Slither and slither-check-upgradeability",
    "TEST-256": "security-fast.sh (contracts.yml fast-security job): Aderyn",
    "TEST-257": "contracts.yml build job: script/check-file-size.sh and `forge build --sizes`",
    "TEST-258": "security-slow.yml echidna jobs (nightly, release tags, by hand)",
    "TEST-259": "security-slow.yml medusa jobs (nightly, release tags, by hand)",
    "TEST-260": "security-slow.yml halmos and hevm jobs (nightly, release tags, by hand)",
    "TEST-261": "security-slow.yml mythril jobs (nightly, release tags, by hand)",
    "TEST-262": "security-slow.yml hevm jobs (nightly, release tags, by hand)",
    "TEST-263": "the fast tier is contracts.yml's fast-security job and the slow tier security-slow.yml (TEST-253 to "
                "TEST-262); the upgrade gate is contracts/script/upgrade-operation.py, which builds a timelock "
                "upgradeToAndCall operation only when security-slow.yml has a completed successful slow-tier run on "
                "the implementation's commit, checked by script/upgrade-operation.test.sh (contracts.yml build job)",
    "TEST-137": "security-fast.sh storage-layout step (script/storage-layout.js); the diff against a deployed version "
                "starts with the first deployment",
}


FUTURE_HEADING = "Future integrations"
FUTURE_COLUMN = "Integration kind"
_FUTURE: dict[str, tuple[str, ...]] = {}


def _cells(line: str) -> list[str]:
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


def future_rows() -> dict[str, tuple[str, ...]]:
    """ID -> the `IntegrationCapabilities` fields (`feeMode: FeeMode.RolledIn`, ...) of the integration kind its row
    binds, for every table row of a "Future integrations" section whose header has an "Integration kind" column."""
    if not _FUTURE:
        for path in [*sorted(CONTRACT_PAGES.glob("*.md")), TESTS]:
            level, col = 0, None
            for line in path.read_text().splitlines():
                h = re.match(r"^(#+) (.*)$", line)
                if h:
                    if h.group(2).strip() == FUTURE_HEADING:
                        level, col = len(h.group(1)), None
                    elif level and len(h.group(1)) <= level:
                        level = 0
                    continue
                if not level or not line.startswith("|"):
                    continue
                cells = _cells(line)
                if cells[0] == "ID":
                    col = cells.index(FUTURE_COLUMN) if FUTURE_COLUMN in cells else None
                elif col is not None and col < len(cells) and re.fullmatch(rf"`?(?:{tr.REQ_ID}|TEST-[0-9]{{3}})`?", cells[0]):
                    _FUTURE[cells[0].strip("`")] = tuple(re.findall(r"`([^`]+)`", cells[col]))
    return _FUTURE


_CAPS: list[str] = []


def integration_present(fields: tuple[str, ...]) -> bool:
    """Whether a concrete integration in contracts/src returns every one of `fields` from `capabilities()`: one
    `IntegrationCapabilities({...})` literal (comments and whitespace ignored) contains them all."""
    if not _CAPS:
        for f in sorted((ROOT / "contracts" / "src").rglob("*.sol")):
            code = ev._strip_comments(f.read_text(errors="ignore"))
            _CAPS.extend(re.sub(r"\s+", "", m.group(1))
                         for m in re.finditer(r"IntegrationCapabilities\s*\(\s*\{(.*?)\}\s*\)", code, re.S))
        _CAPS.append("")  # the scan ran
    want = [re.sub(r"\s+", "", x) for x in fields]
    return bool(want) and any(all(w in lit for w in want) for lit in _CAPS if lit)


def future_inactive() -> dict[str, str]:
    """Future rows whose integration kind no contract in contracts/src has yet: ID -> the fields it waits for."""
    return {i: ", ".join(f"`{x}`" for x in fields) for i, fields in future_rows().items()
            if not integration_present(fields)}


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


_PAGE_IDS: dict[tuple[str, ...], tuple[list[tuple[str, str, str]], set[str]]] = {}


def page_ids(pages: list[str]) -> tuple[list[tuple[str, str, str]], set[str]]:
    """REQ-/SPEC- IDs defined on the pages (or on the named "## " section of a "page.md#Heading" entry), and every
    INV- cited there."""
    key = tuple(pages)
    if key not in _PAGE_IDS:
        _PAGE_IDS[key] = _page_ids(pages)
    return _PAGE_IDS[key]


def _page_ids(pages: list[str]) -> tuple[list[tuple[str, str, str]], set[str]]:
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
    """Cells of the table rows that start with `prefix`; an escaped pipe (`\\|`, as in `|p − b|`) stays in its cell."""
    rows = []
    for line in path.read_text().splitlines():
        if line.startswith(f"| `{prefix}-") or line.startswith(f"| {prefix}-"):
            rows.append([c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))])
    return rows


_TEST_KEYS: dict[str, frozenset[str]] = {}


def test_keys() -> dict[str, frozenset[str]]:
    """TEST ID -> the contract keys its "Contract / flow" column names."""
    if not _TEST_KEYS:
        rx = {k: word_re(names) for k, (_, names, _) in CONTRACTS.items()}
        for cols in table_rows(TESTS, "TEST"):
            if len(cols) >= 4:
                _TEST_KEYS[cols[0].strip("`")] = frozenset(k for k, r in rx.items() if r.search(cols[3]))
    return _TEST_KEYS


def exercise_names(key: str) -> tuple[str, ...]:
    """Contracts whose deployment or call by a test exercises `key`: its real contract (evidence.REAL), the factory
    that makes its instances (evidence.MADE_BY), and every name of CONTRACTS[key] (the key included) that is a
    concrete contract or library in contracts/src. A TEST row naming several contracts counts for `key` only through
    a test that exercises it."""
    src = ev._src_decls()
    concrete = {n for n, d in src.items() if d["kind"] == "library" or (d["kind"] == "contract" and not d["abstract"])}
    names = set(ev.REAL.get(key, ())) | set(ev.MADE_BY.get(key, ()))
    names |= {n for n in [key, *CONTRACTS[key][1]] if n in concrete}
    return tuple(sorted(names))


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


BOX = {ev.PASS: "[x]", ev.FAIL: "[!]", ev.NOT_RUN: "[~]", "unlinked": "[ ]"}
STATES = (ev.PASS, ev.FAIL, ev.NOT_RUN, "unlinked")


class Evidence:
    """Tags, links and run results, read once and shared by every checklist of one invocation."""

    def __init__(self, results: list[Path] | None):
        self.results = ev.Results(results)
        self.links, _ = tr.collect_links()
        self.by_check: dict[str, list[dict]] = {}
        for tag in ev.scan_tags(tr.TARGET)[0]:
            self.by_check.setdefault(tag["check"], []).append(tag)

    def _state(self, tags: list[dict], key: str, names: tuple[str, ...] | None = None) -> tuple[str, str]:
        """State of a row from the tags that could count for it on `key`'s checklist, and a note on excluded tags.
        With `names` (a TEST row naming several contracts) a tag counts only when its test exercises one of them."""
        def why_not(t: dict) -> str:
            if t["excluded"]:
                return t["excluded"]
            if key in ev.tag_stand_in_keys(t):
                return f"uses a stand-in for {key}"
            if names is not None and not ev.exercises(t, names):
                return f"its test does not exercise {key}"
            return ""
        reasons = [(t, why_not(t)) for t in tags]
        counting = [t for t, r in reasons if not r]
        note = ""
        if reasons and not counting:
            note = f" (only excluded checks: {'; '.join(sorted({r for _, r in reasons}))})"
        if not counting:
            return "unlinked", note
        states = [self.results.state(t) for t in counting]
        for want in (ev.FAIL, ev.PASS):
            hit = next((e for s, e in states if s == want), None)
            if hit:
                return want, f" — {hit}"
        return ev.NOT_RUN, ""

    def row(self, rid: str, key: str) -> tuple[str, str, list[str]]:
        """(state, note, check ids) of a REQ/SPEC/INV/ATTACK row: checks whose tags name it."""
        tags = [c["tag"] for c in self.links.get(rid, []) if "tag" in c]
        state, note = self._state(tags, key)
        return state, note, sorted({t["check"] for t in tags})

    def check(self, cid: str, key: str, names: tuple[str, ...] | None = None) -> tuple[str, str]:
        """(state, note) of a TEST or PROP row: the tests and rules tagged with that id (with `names`, only those whose
        test exercises the contract, see exercise_names)."""
        return self._state(self.by_check.get(cid, []), key, names)


def checklist(key: str, evd: Evidence) -> dict:
    """Every row of one contract's checklist with its state, and the rows its --check covers."""
    pages, names, cvl = CONTRACTS[key]
    rx = word_re(names)
    reqs, cited = page_ids(pages)
    tests, props = tests_for(rx), props_for(rx, cvl)
    invs, attacks = invs_for(rx, cited), attacks_for(rx)
    req_later, test_later = deferred_page_rows(pages, key), deferred_test_rows(key)
    req_ids = {r for r, _, _ in reqs}
    req_later.update({r: owner for r, (owner, _) in DEFERRED_ROWS.items() if r in req_ids and r not in req_later})
    test_ids = {t for t, _, _ in tests}
    test_later.update({t: owner for t, (owner, _) in DEFERRED_ROWS.items() if t in test_ids and t not in test_later})
    outside = {i: why for i, why in OUTSIDE_CONTRACTS.items() if i in req_ids or i in test_ids}
    future = {i: f for i, f in future_inactive().items() if i in req_ids or i in test_ids}
    owned = {r: OWNED_ELSEWHERE[r] for r, _, _ in reqs if OWNED_ELSEWHERE.get(r, (key,))[0] != key}

    def entry(rid, text, state, note, extra="", scope=True):
        return {"id": rid, "text": text, "state": state, "note": note, "extra": extra, "scope": scope}

    sections = {"REQ / SPEC on the page": [], "TEST rows": [], "PROP rows": [], "INV": [], "ATTACK": []}
    for r, text, where in reqs:
        st, note, ids = evd.row(r, key)
        extra = (f" — {', '.join(ids)}" if ids else "")
        scope = r not in req_later and r not in owned and r not in outside and r not in future
        if r in req_later:
            extra += f" — deferred to {req_later[r]} (not written yet)"
        if r in outside:
            extra += f" — checked outside contracts/: {outside[r]}"
        if r in owned:
            extra += f" — owned by {owned[r][0]}: {owned[r][1]}"
        if r in future:
            extra += f" — future integration: binds an integration whose capabilities() returns {future[r]}; none in contracts/src"
        sections["REQ / SPEC on the page"].append(entry(r, f"({where}) {text}", st, note, extra, scope))
    for t, kind, text in tests:
        st, note = evd.check(t, key, exercise_names(key) if len(test_keys().get(t, ())) > 1 else None)
        extra = ""
        if t in test_later:
            extra += f" — deferred to {test_later[t]} (not written yet)"
        if t in outside:
            extra += f" — checked outside contracts/: {outside[t]}"
        if t in future:
            extra += f" — future integration: binds an integration whose capabilities() returns {future[t]}; none in contracts/src"
        sections["TEST rows"].append(entry(t, f"[{kind}] {text}", st, note, extra,
                                           t not in test_later and t not in outside and t not in future))
    for p, tool, text in props:
        st, note = evd.check(p, key)
        sections["PROP rows"].append(entry(p, f"[{tool}] {text}", st, note))
    for i, text in invs:
        st, note, ids = evd.row(i, key)
        sections["INV"].append(entry(i, text, st, note, f" — {', '.join(ids)}" if ids else ""))
    for a, title in attacks:
        st, note, ids = evd.row(a, key)
        sections["ATTACK"].append(entry(a, title, st, note, f" — {', '.join(ids)}" if ids else ""))
    return {"key": key, "pages": pages, "cvl": cvl, "sections": sections, "owned": owned}


def blocking(rows: list[dict], links_only: bool) -> list[dict]:
    """Rows in --check scope that fail it: anything not verified, or with --links-only anything unlinked or failed.
    INV and ATTACK rows are listed for review and are not part of --check, as before."""
    bad = {"unlinked", ev.FAIL} if links_only else {"unlinked", ev.FAIL, ev.NOT_RUN}
    return [r for r in rows if r["scope"] and r["state"] in bad]


def check_rows(c: dict) -> list[dict]:
    s = c["sections"]
    return s["REQ / SPEC on the page"] + s["TEST rows"] + s["PROP rows"]


def render(c: dict, given: str) -> str:
    lines = [f"# Checklist: {c['key']}", "",
             f"Spec pages: {', '.join(c['pages'])}. CVL specs: {', '.join(c['cvl']) or 'none'}.", "",
             f"Run results: {given}. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), "
             "[ ] unlinked (no counting check).", ""]
    for title, rows in c["sections"].items():
        tally = ", ".join(f"{sum(1 for r in rows if r['state'] == s)} {s}" for s in STATES)
        lines += [f"## {title} ({len(rows)}: {tally})", ""]
        lines += [f"- {BOX[r['state']]} `{r['id']}` {r['text']}{r['extra']}{r['note']}" for r in rows]
        lines.append("")
    cross = cross_tests()
    lines += [f"## Cross-cutting TEST rows, every contract ({len(cross)}): see --uncovered", ""]
    lines += [f"- `{t}` [{kind}] {text}" for t, kind, text in cross]
    return "\n".join(lines) + "\n"


def uncovered(evd: Evidence) -> list[dict]:
    """TEST rows of 5.1 on no contract's checklist, with their state."""
    on = set()
    for key, (_, names, _) in CONTRACTS.items():
        on |= {t for t, _, _ in tests_for(word_re(names))}
    out, future = [], future_inactive()
    for cols in table_rows(TESTS, "TEST"):
        tid = cols[0].strip("`")
        if len(cols) >= 4 and tid not in on:
            st, note = evd.check(tid, "")
            extra = (f" — checked outside contracts/: {OUTSIDE_CONTRACTS[tid]}" if tid in OUTSIDE_CONTRACTS else
                     f" — future integration: waits for {future[tid]}" if tid in future else "")
            out.append({"id": tid, "text": f"[{cols[1]}] {cols[3]}", "state": st, "note": note, "extra": extra,
                        "scope": tid not in OUTSIDE_CONTRACTS and tid not in future})
    return out


def structural_errors() -> list[str]:
    errs = []
    stale = sorted(r for r, (owner, _) in DEFERRED_ROWS.items() if any(k not in PENDING for k in owner.split(", ")))
    if stale:
        errs.append(f"DEFERRED_ROWS names a contract that is not in PENDING for: {', '.join(stale)}")
    landed = implemented_pending()
    if landed:
        errs.append(f"PENDING lists contracts that now have code in contracts/src: {', '.join(landed)}; remove them")
    for key in CONTRACTS:
        for r, (owner, _) in OWNED_ELSEWHERE.items():
            if r in {i for i, _, _ in page_ids(CONTRACTS[key][0])[0]} and owner != key \
                    and r not in {i for i, _, _ in page_ids(CONTRACTS[owner][0])[0]}:
                errs.append(f"OWNED_ELSEWHERE names an owner whose pages do not define: {r}")
    for i, fields in future_rows().items():
        if not fields:
            errs.append(f"{i}: a Future integrations row names no IntegrationCapabilities field in its "
                        f"'{FUTURE_COLUMN}' column")
    return sorted(set(errs))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("contract", nargs="?", help="contract key (see --list)")
    ap.add_argument("--list", action="store_true", help="list contract keys with ID counts")
    ap.add_argument("--all", action="store_true", help="every contract key, then --uncovered")
    ap.add_argument("--uncovered", action="store_true", help="TEST rows on no contract's checklist")
    ap.add_argument("--out", type=Path, help="write the checklist to this file instead of stdout")
    ap.add_argument("--out-dir", type=Path, help="with --all: write <dir>/<Contract>.md for every contract")
    ap.add_argument("--summary", type=Path, help="with --all: also write the per-contract table here (Markdown)")
    ap.add_argument("--check", action="store_true", help="exit 1 if a row in scope is not verified")
    ap.add_argument("--results", nargs="+", type=Path, metavar="PATH", help="run results (see evidence.py)")
    ap.add_argument("--links-only", action="store_true",
                    help="no run results: --check fails only on unlinked and failed rows")
    args = ap.parse_args()

    if args.list or not (args.contract or args.all or args.uncovered):
        print(f"{'contract':24} {'REQ/SPEC':>8} {'TEST':>5} {'PROP':>5} {'INV':>4} {'ATTACK':>6}")
        for key, (pages, names, cvl) in CONTRACTS.items():
            rx = word_re(names)
            reqs, cited = page_ids(pages)
            print(f"{key:24} {len(reqs):>8} {len(tests_for(rx)):>5} {len(props_for(rx, cvl)):>5} "
                  f"{len(invs_for(rx, cited)):>4} {len(attacks_for(rx)):>6}")
        return 0
    if args.check and not args.results and not args.links_only:
        ap.error("--check needs --results (the run's results) or --links-only (links only, no run)")
    if args.contract and args.contract not in CONTRACTS:
        print(f"unknown contract {args.contract}; use --list", file=sys.stderr)
        return 2

    evd = Evidence(args.results)
    given = ("; ".join(str(p) for p in args.results) if args.results else
             "none given (links only); recorded prover results and Halmos logs are read")
    for w in evd.results.warnings:
        print(f"note: {w}", file=sys.stderr)
    errs = structural_errors() if args.check else []
    rc = 0

    if args.contract and not args.all:
        c = checklist(args.contract, evd)
        text = render(c, given)
        if args.out:
            args.out.write_text(text)
        else:
            sys.stdout.write(text)
        bad = blocking(check_rows(c), args.links_only)
        if args.check and bad:
            print(f"{len(bad)} IDs in scope not {'linked' if args.links_only else 'verified'}: "
                  + ", ".join(f"{r['id']} ({r['state']})" for r in bad[:20]) + (" …" if len(bad) > 20 else ""),
                  file=sys.stderr)
            rc = 1

    if args.all:
        table = ["| Contract | Verified | Failed | Not run | Unlinked | Out of scope | --check |",
                 "|---|---:|---:|---:|---:|---:|---|"]
        print(f"{'contract':24} {'verified':>8} {'failed':>6} {'not run':>7} {'unlinked':>8} {'out of scope':>12}  check")
        if args.out_dir:
            args.out_dir.mkdir(parents=True, exist_ok=True)
        for key in CONTRACTS:
            c = checklist(key, evd)
            rows = check_rows(c)
            inscope = [r for r in rows if r["scope"]]
            n = {s: sum(1 for r in inscope if r["state"] == s) for s in STATES}
            bad = blocking(rows, args.links_only)
            verdict = "pass" if not bad else f"FAIL ({len(bad)})"
            if bad:
                rc = 1
            print(f"{key:24} {n[ev.PASS]:>8} {n[ev.FAIL]:>6} {n[ev.NOT_RUN]:>7} {n['unlinked']:>8} "
                  f"{len(rows) - len(inscope):>12}  {verdict}")
            table.append(f"| {key} | {n[ev.PASS]} | {n[ev.FAIL]} | {n[ev.NOT_RUN]} | {n['unlinked']} | "
                         f"{len(rows) - len(inscope)} | {verdict} |")
            if args.out_dir:
                (args.out_dir / f"{key}.md").write_text(render(c, given))
        if args.summary:
            args.summary.write_text("### Contract checklists (REQ/SPEC, TEST and PROP rows in scope)\n\n"
                                    f"Run results: {given}.\n\n" + "\n".join(table) + "\n")

    if args.uncovered or args.all:
        rows = uncovered(evd)
        bad = blocking(rows, args.links_only)
        print(f"\nTEST rows on no contract checklist: {len(rows)} ("
              + ", ".join(f"{sum(1 for r in rows if r['state'] == s)} {s}" for s in STATES)
              + f"; {sum(1 for r in rows if not r['scope'])} in OUTSIDE_CONTRACTS)")
        for r in rows:
            print(f"- {BOX[r['state']]} `{r['id']}` {r['text'][:90]}{r['extra'][:120]}{r['note']}")
        if args.summary and args.all:
            with args.summary.open("a") as f:
                f.write(f"\n### TEST rows on no contract checklist ({len(rows)}; {len(bad)} block --check)\n\n"
                        + "\n".join(f"- {BOX[r['state']]} `{r['id']}` {r['text'][:90]}"
                                    + (" — outside contracts/" if not r["scope"] else "") for r in rows) + "\n")
        if args.check and bad:
            print(f"{len(bad)} TEST rows on no checklist, not {'linked' if args.links_only else 'verified'} and "
                  f"not in OUTSIDE_CONTRACTS: {', '.join(r['id'] for r in bad)}", file=sys.stderr)
            rc = 1

    for e in errs:
        print(e, file=sys.stderr)
    return 1 if errs or rc else 0


if __name__ == "__main__":
    sys.exit(main())
