# Verification coverage and AMM-neutral traceability

Measured on 2026-11-10 against `spec/01`–`04` (decisions `Q-001`…`Q-278`), `spec/05-verification/`, `audit/findings-register.md` and `contracts/certora/`. Rule under test: every critical requirement has a verification method, and every failed verification has a traceable finding.

## 1. Result

| Measure | Value |
|---|---|
| Requirement IDs that `trace.py` reads | 2,927 (2,497 rules, 152 attack scenarios, 278 decisions) |
| Critical requirements (section 2) | 2,465 of the 2,649 non-decision IDs |
| Critical behaviour explicitly defined | about 99 %: 0 rows with TBD, TODO or an open placeholder; 4 rows depend on an outside approval or launch condition (`REQ-ROLE-077`, `REQ-RISK-046`, `REQ-ROUTE-006`, `REQ-FLR-009`) |
| Critical requirements independently checked (a spec-stage check that ran and passed links to the row) | 925 (37.5 %) |
| Critical requirements with only a planned check named directly (a `TEST-…` or `PROP-…` row or tag that has not run) | 90 (3.7 %) |
| Critical requirements with only an indirect plan (the row cites a `Q-…` decision that some `TEST-…` or `PROP-…` covers; no check names the row) | 1,415 (57.4 %) |
| Critical requirements with no verification method | 35 (1.4 %) |
| Critical requirements checked on Solidity | 0 % — `contracts/src` holds interfaces only, no Foundry test is written, and no CVL rule has run |

The spec-stage models carry the formulas, invariants and oracle, settlement and custody rules: 4.1 invariants (86 of 90 checked), LPOracle (76 of 111), LPVaultSwap (87 of 128), Collateralization (72 of 140), in-kind escrow (14 of 14). Architecture, roles, the Hub and Spokes, and the operation steps rest almost entirely on decision-level plans.

## 2. Method

A requirement is critical when its text moves funds (transfer, mint, burn, seize, pledge, borrow, repay, withdraw, settle, flash, escrow, NFT custody), computes value or price (price, value, oracle, HF, CF, LTV, bonus, fee, rounding, units), controls access (role, timelock, guardian, admin, upgrade, caller), gates liquidation or exits (liquidation, exit, pause, freeze, halt, grace, stale, Cached, Expired, breaker, offboarding), enforces caps (cap, budget, limit, ceiling, allowance, minOut, slippage, minimum, maximum) or states an invariant. Every `INV-…`, `SPEC-…` and `ATTACK-…` is critical; `Q-…` decisions are rationale and are not counted. The classification is a keyword pass over the rule text, so the counts are an estimate; 184 rows fall outside it (scope statements such as `REQ-ARCH-020`, table rows naming a caller without an action).

Status per critical row:

- **Checked**: a `MATH-`, `SYM-`, `QNT-`, `HYP-`, `SIM-` or `FV-` check links to it through a `verifies:` tag or a citation on its definition line, as `trace.py` resolves them. For `ATTACK-…` the `| Checks |` row of the entry is read as well (section 5).
- **Planned, direct**: only a `TEST-…` row of 5.1, a `PROP-…` row of 5.2 or a CVL `PROP-… verifies:` tag names it.
- **Planned, via decision**: the row cites `Q-n`, and a 5.1 or 5.2 row lists `Q-n` under Covers. No check names the row itself, so nothing records which test proves which sentence.
- **None**: none of the above.

## 3. Critical gaps per spec page

| Page | Critical | Checked | Planned, direct | Planned, via decision | None |
|---|---|---|---|---|---|
| `01-architecture/01-protocol-overview.md` | 37 | 1 | 0 | 35 | 1 |
| `01-architecture/02-contract-relationships.md` | 150 | 1 | 0 | 147 | 2 |
| `01-architecture/04-permissions-and-roles.md` | 111 | 15 | 0 | 96 | 0 |
| `02-contracts/01-avana-hub-and-spokes.md` | 109 | 9 | 1 | 99 | 0 |
| `02-contracts/02-lp-vault.md` | 52 | 16 | 0 | 36 | 0 |
| `02-contracts/03-collateralization.md` | 140 | 72 | 0 | 68 | 0 |
| `02-contracts/04-vault-tokens.md` | 44 | 23 | 0 | 21 | 0 |
| `02-contracts/05-position-proxy-and-proxy-manager.md` | 43 | 19 | 0 | 24 | 0 |
| `02-contracts/06-aave-adapter.md` | 109 | 50 | 0 | 59 | 0 |
| `02-contracts/07-risk-module.md` | 124 | 43 | 1 | 80 | 0 |
| `02-contracts/08-market-registry.md` | 74 | 38 | 0 | 36 | 0 |
| `02-contracts/09-parameter-store.md` | 48 | 21 | 0 | 27 | 0 |
| `02-contracts/10-lp-oracle.md` | 111 | 76 | 0 | 35 | 0 |
| `02-contracts/11-lpvaultswap.md` | 128 | 87 | 1 | 40 | 0 |
| `02-contracts/12-settlement-routes.md` | 39 | 13 | 0 | 26 | 0 |
| `02-contracts/13-settlement-budget.md` | 30 | 19 | 0 | 11 | 0 |
| `02-contracts/14-first-loss-reserve.md` | 40 | 24 | 0 | 16 | 0 |
| `02-contracts/15-governance-and-timelock.md` | 179 | 80 | 0 | 99 | 0 |
| `02-contracts/16-lock.md` | 22 | 6 | 0 | 16 | 0 |
| `02-contracts/17-lens.md` | 34 | 21 | 0 | 13 | 0 |
| `02-contracts/18-payout-escrow.md` | 14 | 14 | 0 | 0 | 0 |
| `03-operations/01-deposit.md` | 60 | 13 | 0 | 47 | 0 |
| `03-operations/02-borrow.md` | 44 | 9 | 0 | 35 | 0 |
| `03-operations/03-repay.md` | 47 | 9 | 0 | 38 | 0 |
| `03-operations/04-withdraw.md` | 73 | 17 | 0 | 56 | 0 |
| `03-operations/05-liquidation.md` | 130 | 47 | 0 | 83 | 0 |
| `03-operations/06-emergency-operations.md` | 118 | 18 | 0 | 97 | 3 |
| `03-operations/07-collect-fees.md` | 19 | 4 | 0 | 15 | 0 |
| `03-operations/08-market-lifecycle.md` | 68 | 17 | 0 | 51 | 0 |
| `03-operations/09-deficit-coverage.md` | 26 | 17 | 0 | 9 | 0 |
| `04-security/01-global-invariants.md` | 90 | 86 | 4 | 0 | 0 |
| `04-security/02-attack-scenarios.md` | 152 | 40 | 83 | 0 | 29 |
| **All** | **2465** | **925** | **90** | **1415** | **35** |

Critical rows with no verification method (35):

- Operations and monitoring: `REQ-ARCH-178` (blast radius of each upgradeable contract), `REQ-ARCH-187` (monitoring alert levels and playbooks), `REQ-ARCH-204` (monitoring reads), `EMG-075`, `EMG-076` (incident log and alert confirmation), `EMG-084` (Hub liquidity crunch playbook).
- Attack scenarios whose `Checks` field is `None` or names no defined check (29): `ATTACK-004`, `008`, `013`, `017`, `020`, `031`, `037`, `039`, `040`, `041`, `043`, `045`, `049`, `060`, `072`, `073`, `074`, `081`, `082`, `088`, `092`, `093`, `094`, `105`…`110`.

Critical rows whose only direct method is planned (90): `REQ-HUB-100`, `REQ-RISK-026`, `REQ-SWAP-040`, `INV-017`, `INV-022`, `INV-065`, `INV-073` (CVL rule or 5.1 row, not run), and 83 attack scenarios whose `Checks` name only `TEST-…` or `PROP-…`, among them every scenario from `ATTACK-111` to `ATTACK-152` (the scenarios added with `Q-241`…`Q-278`).

Largest gaps:

1. **No check has run on code.** 263 `TEST-…` rows in 5.1 are "Not written"; the only Solidity test files are two Echidna property files without `verifies:` tags. 299 CVL rules and invariants carry `PROP-… verifies:` tags, the methods check passes, and the prover has never run (`contracts/certora/RUNS.md`). `trace.py` still counts a CVL tag as an implementation check, so the 167 rows the matrix marks **Verified** rest on rules that have not executed.
2. **Rule-to-test mapping is missing.** 5.1 maps tests to decisions, and to `INV-…` in section D; it names 2 `REQ-…` IDs and 6 `SPEC-…` IDs. 1,415 critical rows are covered only by inference through a cited decision.
3. **Flows and architecture are unmodelled.** 505 of 660 operation steps (`DEP`, `BOR`, `REP`, `WDR`, `LIQ`, `EMG`, `FEE`, `MKT`, `DEF`) and 190 of 192 `REQ-ARCH-…` rows have no spec-stage check. Liquidation alone has 83 critical steps with only a decision-level plan.
4. **Roles and the Hub.** `04-permissions-and-roles.md` (96 of 111 critical rows) and `01-avana-hub-and-spokes.md` (99 of 109) rely on decision-level plans; access control is the category with the lowest checked share (414 of 1,033 rows mentioning roles, callers or upgrades).
5. **Uniswap v3 coupling.** 187 rules name v3 mechanics (ticks, `slot0`, `positions`, the NonfungiblePositionManager, full range); 74 are checked, and those checks (`MATH-UO-06`…`13`, `SYM-…`) are written for v3 full range only. The AMM-neutral refactor must re-home or re-scope every one of them (section 6).

## 4. Findings traceability

### 4.1 Findings in 5.3

200 entries (`FINDING-001`…`FINDING-200`); index and detail sections agree, and every `TEST-…` and `PROP-…` they name exists in 5.1 or 5.2.

| Check | Result |
|---|---|
| Links a requirement | 200 of 200 link a decision `Q-…`. 105 link **only** decisions and model checks, with no `REQ-`, `SPEC-`, `INV-` or flow-step ID: `FINDING-001`…`040`, `043`, `045`…`088`, `090`, `092`, `093`, `095`…`097`, `099`…`103`, `124`, `144`, `145`, `160`, `163`, `172`, `182`, `185`, `186` |
| Links a passing or planned check | 198 of 200. **Orphans: `FINDING-197`** (deficit-coverage worked example, `DEF-006`) and **`FINDING-198`** (liquidation worked example, `LIQ-068`) have Verification `None` while their Evidence says "confirmed by the Verification tests". Five more name only a spec-stage check and no code test: `FINDING-164`, `165`, `166`, `168` (`MATH-AR-…`), `169` (`SYM-138d`, `SYM-138e`) |

### 4.2 Register rows in `audit/findings-register.md`

102 rows; every row names a mirrored `FINDING-…` that exists in 5.3, and every row has a "Verified by" entry.

| Check | Rows |
|---|---|
| "Spec rules involved" names no spec rule ID | `FV-CTL-F-17` (circuit-breaker rule, named in prose), `DR-14`, `SIM-GAP-10`, `CVL-F-02`, `CVL-F-05`, `CVL-F-06` |
| Verified only by spec-stage or FV checks, no `TEST-…` or `PROP-…` on code | `FV-CUS-F-09`, `FV-LIQ-F-18`, `FV-LIQ-F-19`, `F-AR-1`…`F-AR-5`, `SYM-138d`, `CVL-F-06`, `CVL-F-07` |
| Proving check not yet passed ("Resolved in spec — re-verification pending") | `DR-01`, `DR-03`, `DR-05`, `DR-10`, `DR-12`, `DR-13`, `DR-15`, `DR-17`, `DR-20` |

### 4.3 Failed checks without a finding

5.2 and the folder READMEs state that every counterexample is a `FINDING-…`. Three are not:

| Check | Recorded in | Counterexample | Finding |
|---|---|---|---|
| `SIM-02H` | `spec/05-verification/simulation/README.md` | Both USDC routes fail 24 h with no standby: 24.7 liquidations of accounts healthy at market prices | none |
| `SIM-04C` | same | No approved keeper for 48 h: permissionless fallback leaves 9,874 GHO of bad debt | none |
| `QNT-F1` | `spec/05-verification/quint/README.md` | A hostile LPVaultSwap seizes an Expired market in full for one unit of debt | none in 5.3 or the register |

The other simulation counterexamples (`SIM-01D`, `SIM-05A`, `SIM-05C`, `SIM-07C`), every Z3, SymPy and Hypothesis finding, and the seven violated `FV-CTL-R3` checks map to findings.

### 4.4 Count drift

The summary in `spec/05-verification/README.md` disagrees with the folder READMEs: Z3 "504 proved, 87 counterexamples (6 findings), 3 mismatches" against `z3/README.md` "509 proved, 83 counterexamples (all deliberate), 0 mismatches"; SymPy "228 hold, 2 counterexamples" against "229 hold, 1"; Quint "43 invariants, 35 scenarios" against 58 properties `QNT-01`…`QNT-58`. `z3/amm-pricing/ap01_concentrated_liquidity.py` carries no `verifies:` tags and has no README, so `trace.py` does not see it.

## 5. The 4,033 warnings

`trace.py` (without `--strict`) reports 2,927 requirements, 0 errors and 4,033 warnings. It warns on three conditions; `Q-…` and `ATTACK-…` are excluded from the first, and only `REQ-`, `INV-` and `SPEC-` rows are tested for the second and third.

| Kind | Count | Breakdown | Cause |
|---|---|---|---|
| No implementation test or property | 1,762 | `REQ` 1,620, `SPEC` 117, `INV` 25 | No `TEST-… verifies:` tag exists anywhere; only CVL `PROP-…` tags count, and they name 75 `REQ`/`SPEC`/`INV` rows (most name `INV-…` and `Q-…`) |
| No spec-stage check | 1,571 | `REQ` 1,062 (largest: `ARCH` 190, `HUB` 109, `VAULT` 101, `ROLE` 100, `ACCESS` 100, `PROXY` 66, `RISK` 60, `ADAPTER` 57), flow steps 505 (`EMG` 115, `LIQ` 96, `WDR` 65, `MKT` 65, `DEP` 55, `REP` 44, `BOR` 41, `FEE` 15, `DEF` 9), `INV` 4 | Models are written per formula and per invariant, not per contract rule or step |
| No Solidity link | 700 | `REQ` 612, `INV` 62, `SPEC` 26 | `@custom:spec` tags exist on the interfaces only; 1,348 IDs are linked |

What the warnings do not show:

- `ATTACK-…` rows are never warned on, and `trace.py` reads checks only from the definition line, which for an attack is its heading. The `| Checks |` row is ignored, so 148 of 152 attacks show as Unverified although 40 cite passing spec-stage checks.
- Nothing checks findings: a `FINDING-…` without a rule or a check, and a failed check without a finding, pass silently.
- A requirement removed from the spec drops out of the matrix without an error; its lock entry stays.

## 6. Traceability rules for the AMM-neutral refactor

### 6.1 ID prefixes

| Prefix | Holds | Defined in |
|---|---|---|
| `REQ-AMM-CORE-NNN` | AMM-neutral rules every integration meets: custody interface, quote interface (fair composition at oracle prices, value = Σ amountᵢ × priceᵢ), unwind interface and its rounding direction, the ledger's credited units, seizure order, pending settlement and reconciliation | the AMM-neutral core page |
| `SPEC-AMM-CORE-NNN` | Shared formulas: value per whole VaultToken, the bound between quoted value and unwind proceeds, the minimum-recovery check | same |
| `REQ-AMM-<P>-NNN` | One AMM protocol's custody, intake (range and liquidity checks moved out of Collateralization), pool identity, unwind calls | that protocol's integration page |
| `SPEC-AMM-<P>-NNN` | That protocol's pricing math and unwind rounding | same |
| `INV-AMM-<P>-NNN` | Invariants specific to the protocol (for example: a Slipstream position held by the LPVault is never staked in a gauge) | same, indexed from 4.1 |
| `ATTACK-AMM-<P>-NNN` | Manipulation and integration attacks on that protocol (spot push, donation, tick-crossing, hooks on removal, read-only reentrancy) | 4.2 |

`<P>` is one of `V3` (Uniswap v3), `SLIP` (Aerodrome Slipstream), `AERO` (Aerodrome v2-style pools), `V2` (Uniswap v2), `V4` (Uniswap v4), `CRV` (Curve), `BAL` (Balancer), `SUSHI` (Sushi). Global `INV-…` and the flow steps stay protocol-neutral. Deployment-scope rules (per Hub, per CDP Spoke, per collateral market) keep their contract prefixes.

Migration of the current v3 rules: each of the 187 rules naming v3 mechanics is either rewritten as a `REQ-AMM-CORE-…` rule or moved to `REQ-AMM-V3-…`/`SPEC-AMM-V3-…`. The old ID's lock entry records `"retired_to": [<new IDs>]`, and the checks that verified it (`MATH-UO-06`…`13`, the `SYM-…` and `HYP-…` oracle checks) are re-tagged to the new IDs and re-run.

### 6.2 Methods each AMM integration carries before listing

Check IDs name the protocol and the method, `<KIND>-AMM-<P>-<METHOD>-NN`:

| Method | ID form | Required evidence |
|---|---|---|
| Pricing proof | `MATH-AMM-<P>-PRICE-NN` (Z3) or `SYM-AMM-<P>-PRICE-NN` (SymPy) | Every `SPEC-AMM-<P>-…` proved with exact integer rounding at Solidity widths: the quote uses oracle prices only, a spot move alone leaves it unchanged, the quote never exceeds the holdings, the rounding direction favours the protocol, no overflow inside the listing bounds, each worked example recomputed |
| Manipulation tests | `TEST-AMM-<P>-MANIP-NNN` (Foundry, fork) or `HYP-AMM-<P>-MANIP-NN` | Every `ATTACK-AMM-<P>-…` reproduced: spot and TWAP pushes, flash-loan sandwiches of pledge, borrow, liquidation and each settlement leg, donations to the pool and to the position, liquidity moves of 90 % of the pool; the quote and every per-leg `minOut` hold |
| Fork test of unwind rounding | `TEST-AMM-<P>-UNWIND-NNN` under `contracts/test/fork/` | Against the pinned AMM protocol code on a mainnet or Base fork: unwind proceeds per leg ≥ the `SPEC-AMM-<P>-…` lower bound, differ from the quote by at most the stated raw units per leg, at the range edges, at minimum and maximum liquidity, for partial and full removal |
| Invariant tests | `TEST-AMM-<P>-INVAR-NNN` under `contracts/test/invariant/` | The multi-actor suite (`TEST-215`) run with this protocol's markets, asserting `INV-001` (backing), `INV-074` (solvency per debt asset) and every `INV-AMM-<P>-…` after each step |
| Core conformance | any check with `-AMM-<P>-` in its ID | Every `REQ-AMM-CORE-…` and `SPEC-AMM-CORE-…` linked by at least one check that runs against this protocol |

Results: each listing records, per required check, the result and the run in `spec/05-verification/amm-integrations.json`:

```json
{
  "V3":   {"status": "listed", "results": {"MATH-AMM-V3-PRICE-01": {"result": "proved", "run": "2026-11-20"}}},
  "SLIP": {"status": "review", "results": {}},
  "V2":   {"status": "draft"}
}
```

A failed result names its finding (`"finding": "FINDING-201"`); the integration can list only once that finding is Resolved or Accepted.

### 6.3 Enforcement in `trace.py`

| Rule | `draft` | `review` | `listed` |
|---|---|---|---|
| AMM IDs parse as requirements | yes | yes | yes |
| Each of the four methods present, in the right folder | — | warning | error |
| Each `REQ-AMM-<P>-…` has a check; each `SPEC-…` a PRICE check, each `ATTACK-…` a MANIP check, each `INV-…` an INVAR check | — | warning | error |
| Each core rule, `INV-001` and `INV-074` checked against this protocol | — | warning | error |
| Every `-AMM-<P>-` check has a passing result, or a failed result with a resolved `FINDING-…` | — | — | error |

General rules added in the same change:

- read the `| Checks |` row of `ATTACK-…` entries;
- every `FINDING-…` names a check in Verification unless Accepted (error), and names a spec rule, not only decisions (warning; error when the finding concerns an `AMM-` ID);
- a requirement with a lock entry that is no longer defined fails unless the entry carries `retired_to`.

### 6.4 Proposed patch (not applied)

Tested on a copy against the current repo: `patch --dry-run -p1` applies cleanly; the run reports 2 errors (`FINDING-197`, `FINDING-198`, no verification check) and 4,138 warnings (the 4,033 above plus 105 findings that link only decisions). Attack scenarios move from 1,825 Unverified rows to 1,789. With a manifest marking `SLIP` as `listed` and no AMM checks, it reports the six listing errors (four methods missing, `INV-001` and `INV-074` not run against Slipstream).

```diff
--- a/spec/05-verification/trace.py
+++ b/spec/05-verification/trace.py
@@ -43,7 +43,10 @@
 OUT = VERIF / "traceability.md"
 
 FLOWS = "DEP|BOR|REP|WDR|LIQ|EMG|FEE|MKT|DEF"
-REQ_ID = rf"(?:REQ-[A-Z]+-[0-9]{{3}}|INV-[0-9]{{3}}|SPEC-[A-Z]+-[0-9]{{3}}|ATTACK-[0-9]{{3}}|(?:{FLOWS})-(?:F-|POST-)?[0-9]{{3}}[a-z]?|Q-[0-9]{{3}})"
+# AMM protocol integrations. CORE holds the AMM-neutral rules every integration must meet.
+AMM = "V2|V3|V4|SLIP|AERO|CRV|BAL|SUSHI"
+AMM_ID = rf"(?:(?:REQ|SPEC)-AMM-(?:CORE|{AMM})|(?:INV|ATTACK)-AMM-(?:{AMM}))-[0-9]{{3}}"
+REQ_ID = rf"(?:{AMM_ID}|REQ-[A-Z]+-[0-9]{{3}}|INV-[0-9]{{3}}|SPEC-[A-Z]+-[0-9]{{3}}|ATTACK-[0-9]{{3}}|(?:{FLOWS})-(?:F-|POST-)?[0-9]{{3}}[a-z]?|Q-[0-9]{{3}})"
 CHECK_ID = r"(?:MATH|SYM|QNT|HYP|SIM|TEST|PROP|FV)-[A-Z0-9]+(?:-[A-Z0-9]+)*"
 CHECK_KIND = {"MATH": "Z3", "SYM": "SymPy", "QNT": "Quint", "HYP": "Hypothesis",
               "SIM": "Simulation", "TEST": "Foundry", "PROP": "Formal",
@@ -61,7 +64,20 @@
                "audit/formal-verification/**/*.py", "audit/formal-verification/**/*.qnt"]
 SKIP = {".venv", "node_modules", "__pycache__", ".hypothesis"}
 
+# Verification methods an AMM integration must carry before listing. Check IDs name the method:
+# <KIND>-AMM-<P>-<METHOD>-NN, e.g. MATH-AMM-SLIP-PRICE-01, TEST-AMM-V3-UNWIND-003.
+AMM_METHODS = {
+    "PRICE": ({"Z3", "SymPy"}, None),                        # pricing proof of every SPEC-AMM-<P>-*
+    "MANIP": ({"Foundry", "Hypothesis"}, None),              # manipulation tests of every ATTACK-AMM-<P>-*
+    "UNWIND": ({"Foundry"}, "contracts/test/fork/"),         # fork test of unwind rounding on the pinned AMM code
+    "INVAR": ({"Foundry"}, "contracts/test/invariant/"),     # invariant suite with this AMM protocol's markets
+}
+AMM_INVARIANTS = ["INV-001", "INV-074"]                       # backing and per-asset solvency, asserted per protocol
+AMM_MANIFEST = VERIF / "amm-integrations.json"                # {"V3": {"status": "listed", "results": {...}}, ...}
+PASS = {"proved", "computed", "holds", "pass"}
+FINDINGS = VERIF / "03-audit-findings.md"
 
+
 def norm(text: str) -> str:
     return re.sub(r"\s+", " ", text.strip().strip("|").strip())
 
@@ -112,8 +128,80 @@
                     for rid in SPLIT.findall(m.group(1)):
                         links[rid].append({"id": Path(rel).stem, "kind": "Solidity", "where": f"{rel}:{n}"})
     return links, check_targets
+
+
+def collect_attack_checks(links: dict, check_targets: dict) -> None:
+    """ATTACK-* entries name their checks in a `| Checks |` row under the heading, not on the definition line."""
+    path = SPEC / "04-security" / "02-attack-scenarios.md"
+    rel = str(path.relative_to(ROOT))
+    current = None
+    for n, line in enumerate(path.read_text().splitlines(), 1):
+        h = re.match(rf"^#+\s+`?(ATTACK-(?:AMM-[A-Z0-9]+-)?[0-9]{{3}})", line)
+        if h:
+            current = h.group(1)
+        elif current and line.startswith("| Checks |"):
+            for cid in set(re.findall(rf"(?<![A-Za-z0-9-])({CHECK_ID})[a-z]?\b", line)):
+                if cid in check_targets and not any(it["id"] == cid for it in links.get(current, [])):
+                    links[current].append({"id": cid, "kind": CHECK_KIND[cid.split("-")[0]], "where": f"{rel}:{n}"})
+
+
+def check_findings(reqs: dict, check_targets: dict, errors: list[str], warnings: list[str]) -> dict[str, str]:
+    """Every FINDING names a spec rule and a check; returns each FINDING's status."""
+    rule = re.compile(rf"(?:{AMM_ID}|REQ-[A-Z]+-[0-9]{{3}}|INV-[0-9]{{3}}|SPEC-[A-Z]+-[0-9]{{3}}|(?:{FLOWS})-(?:F-|POST-)?[0-9]{{3}})")
+    text = FINDINGS.read_text()
+    parts = re.split(r"^#### (FINDING-[0-9]+)[^\n]*\n", text, flags=re.M)
+    defined: dict[str, str] = {}
+    for i in range(1, len(parts), 2):
+        fid, body = parts[i], parts[i + 1]
+        ver = re.search(r"^\| Verification \| (.*) \|$", body, re.M)
+        status = re.search(r"^\| Status \| (.*) \|$", body, re.M)
+        defined[fid] = status.group(1) if status else ""
+        checks = re.findall(rf"(?<![A-Za-z0-9-])({CHECK_ID})[a-z]?\b", ver.group(1) if ver else "")
+        if not checks and not (status and status.group(1).startswith("Accepted")):
+            errors.append(f"{fid} names no verification check")
+        if not rule.search(body):
+            (errors if "AMM-" in body else warnings).append(f"{fid} links no spec rule (only decisions)")
+    return defined
 
 
+def check_amm(reqs: dict, links: dict, findings: dict[str, str], errors: list[str], warnings: list[str]) -> None:
+    """Listing gate: each AMM protocol must carry every method before its status is `listed`."""
+    manifest = json.loads(AMM_MANIFEST.read_text()) if AMM_MANIFEST.exists() else {}
+    core = sorted(r for r in reqs if r.startswith("REQ-AMM-CORE-") or r.startswith("SPEC-AMM-CORE-"))
+    for p in sorted({m.group(1) for r in reqs for m in [re.match(rf"^\w+-AMM-({AMM})-", r)] if m} | set(manifest)):
+        status = manifest.get(p, {}).get("status", "draft")
+        if status == "draft":
+            continue
+        out = errors if status == "listed" else warnings
+        own = sorted(r for r in reqs if re.match(rf"^\w+-AMM-{p}-", r))
+        checks = {c["id"]: c for r in own + core + AMM_INVARIANTS for c in links.get(r, [])}
+        for method, (kinds, folder) in AMM_METHODS.items():
+            found = [c for cid, c in checks.items() if f"-AMM-{p}-{method}-" in cid and c["kind"] in kinds
+                     and (folder is None or c["where"].startswith(folder))]
+            if not found:
+                out.append(f"AMM {p}: no {method} check" + (f" under {folder}" if folder else ""))
+        for r in own:
+            want = {"SPEC": "PRICE", "ATTACK": "MANIP", "INV": "INVAR"}.get(r.split("-")[0])
+            ids = [c["id"] for c in links.get(r, [])]
+            if not ids:
+                out.append(f"AMM {p}: {r} has no check")
+            elif want and not any(f"-AMM-{p}-{want}-" in i for i in ids):
+                out.append(f"AMM {p}: {r} has no {want} check")
+        for r in core + AMM_INVARIANTS:
+            if not any(f"-AMM-{p}-" in c["id"] for c in links.get(r, [])):
+                out.append(f"AMM {p}: {r} has no check run against this protocol")
+        if status == "listed":
+            results = manifest[p].get("results", {})
+            for cid in sorted(checks):
+                if f"-AMM-{p}-" not in cid:
+                    continue
+                res = results.get(cid, {})
+                if res.get("result") not in PASS:
+                    if findings.get(res.get("finding"), "").startswith(("Resolved", "Accepted")):
+                        continue  # failed on purpose or fixed in spec, and traceable to its FINDING
+                    errors.append(f"AMM {p}: {cid} has result {res.get('result', 'none')} and no resolved FINDING")
+
+
 def digest(text: str) -> str:
     return hashlib.sha256(text.encode()).hexdigest()[:16]
 
@@ -148,7 +236,13 @@
                         continue
                     if not any(it["id"] == cid for it in links.get(rid, [])):
                         links[rid].append({"id": cid, "kind": CHECK_KIND[cid.split("-")[0]], "where": where})
+    collect_attack_checks(links, check_targets)
+    findings = check_findings(reqs, check_targets, errors, warnings)
+    check_amm(reqs, links, findings, errors, warnings)
     lock = json.loads(LOCK.read_text()) if LOCK.exists() else {}
+    for rid, entry in lock.items():
+        if rid not in reqs and not entry.get("retired_to"):
+            errors.append(f"{rid} was accepted but is no longer defined; record its replacement as retired_to in the lock")
 
     for rid, items in links.items():
         if rid not in reqs:
```

Follow-ups outside `trace.py`: add `TEST-NNN verifies: <REQ/SPEC IDs>` to each 5.1 row so the 1,415 decision-level plans become direct links; write findings for `SIM-02H`, `SIM-04C` and `QNT-F1`, and a check for `FINDING-197` and `FINDING-198`; tag `z3/amm-pricing/` with `MATH-AMM-V3-PRICE-…` and `MATH-AMM-SLIP-PRICE-…`; reconcile the result counts in `spec/05-verification/README.md`; mark a `PROP-…` as an implementation check only after a logged prover run, so the matrix stops showing unrun CVL rules as Verified.
