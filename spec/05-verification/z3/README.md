# Z3 models of the Avana math

Every formula of the specification is modelled here in exact integers (or Solidity bit widths where overflow or truncation is the question) and checked with Z3 4.13. A property Avana relies on is proved by showing its negation is unsat. Counterexamples are searched for on purpose: a wrong reading of a formula that the specification rules out, a boundary the specification states, or a state outside the modelled bounds. Every worked example on the spec pages is recomputed exactly.

| Folder | What it covers | Spec IDs |
|---|---|---|
| [`units-oracle/`](units-oracle/) | Vault-token units and decimals, full-range amounts, LPOracle and DebtOracle price math, price states (backup routes, standby switch, stale-at-Expired valuation, lower-route price on disagreement), backing ledger (partial removal and re-credit, rescue top-ups and rescue-unit exclusion, one-sided backing check), cap counters | `SPEC-UNIT-001`…`006`, `SPEC-ORC-001`…`018`, `SPEC-BACK-001`…`014` |
| [`aave-risk/`](aave-risk/) | Collateral factor and health factor on Aave V4 `a3ef63ea`, opening gate with rescue-unit exclusion, liquidation sizing and bonus curve, repay and repay-all quote, risk premium, vault shares, caps and cap sizing, circuit breakers and pause reasons, address freeze, repay with collateral | `SPEC-HUB-001`…`008`, `SPEC-CF-001`…`005`, `SPEC-CAP-001`…`008`, `SPEC-BRK-001`…`006`, `SPEC-PROXY-001`…`009` |
| [`settlement/`](settlement/) | Net bonus and effective slippage, recovery floor, per-leg minimums, caller shortfall top-up, buy leg and covered debt cost, sell-back floor, waterfall with the fee from oracle value, SettlementBudget per-call, rolling-window and per-market caps, in-kind settlement, debit equalities, repay with collateral, First-Loss coverage and reserve sizing | `SPEC-LIQ-001`…`020`, `SPEC-SET-001`…`006`, `SPEC-FLR-001`…`005` |
| [`governance/`](governance/) | Timelock delay, execution window and expiry, delay changes, the delay floor and short-delay allowlist, exit window before an upgrade, cancel rights, pause state, the market-count limit | `SPEC-GOV-001`…`015` |
| [`amm-pricing/`](amm-pricing/) | Fair-composition LP pricing per AMM type (concentrated liquidity, constant product, stable and weighted pools): the pricing proofs each AMM integration carries before listing | `SPEC-AMM-CORE-001`, `SPEC-AMM-V3-001`, `SPEC-AMM-V2-001`, `SPEC-AMM-BAL-001`, `SPEC-AMM-CURVE-001` (`MATH-AMM-<P>-PRICE-NN`) |

Each folder's `README.md` gives the formulas modelled with their rounding, one table per script (ID, statement, the IDs it verifies, bounds, result), the findings, and the run log. Every check carries a `# MATH-…-NN verifies: <IDs>` tag directly above it; [`../trace.py`](../trace.py) reads the tags and reports 0 errors for these folders.

## Run

```bash
../run_all.sh                                          # every spec-stage check
../.venv/bin/python settlement/st03_waterfall.py       # one model
```

All models run on the shared `spec/05-verification/.venv` (`z3-solver 4.13.0` from [`../requirements.txt`](../requirements.txt)). A script exits 1 only when a result differs from the one it records; a property of the specification that fails keeps its expected `PROVED` or `COMPUTED`, so its script exits 1 until the specification changes.

## Results

Run on 2026-11-11 with Python 3.9.6 and z3-solver 4.13.0, every script one at a time, 120 s per query, no timeouts.

| Folder | Scripts | Proved | Counterexample | Computed | Mismatch | Scripts exiting 1 |
|---|---|---|---|---|---|---|
| `units-oracle/` | 16 (`uo01`…`uo16`) | 212 | 40 (all deliberate) | 27 | 0 | none |
| `aave-risk/` | 13 (`ar01`…`ar12`, `ch01`; `ar12` is `MATH-AR-70`) | 149 | 12 (all deliberate) | 55 | 0 | none (F-AR-1…F-AR-5 resolved in spec) |
| `settlement/` | 17 (`st01`…`st17`) | 199 | 58 (all deliberate) | 33 | 0 | none (findings MATH-ST-58, 75, 77, 84 resolved in spec) |
| `governance/` | 3 | 31 | 4 (all deliberate) | — | 0 | none |
| `amm-pricing/` | 3 | 50 | 9 (all deliberate) | 16 | 0 | none |
| **Total** | **52** | **641** | **123** | **131** | **0** | **0** |

Findings against the final text, with counterexamples and the exact recommended changes, are listed in each folder's README:

| Check | Spec text | Severity | Summary |
|---|---|---|---|
| MATH-AR-37 | 2.6 and 3.2 worked examples | low | The "largest USDC borrow 14,183.24" fails the opening gate; 14,183.23 is the largest. Resolved in spec: MATH-AR-37 COMPUTED |
| MATH-AR-24d | `SPEC-HUB-004` example | low | Cites a 1,000 GHO minimum debt that no longer exists. Resolved in spec: MATH-AR-24d PROVED |
| MATH-AR-47c | `SPEC-CAP-003` | low | "At most 3 units" of rounding holds only while `price8 ≥ stressFloorUsd`. Resolved in spec: MATH-AR-47c PROVED |
| MATH-AR-44b, MATH-ST-77 | `SPEC-CAP-007`(ii), `SPEC-CAP-008`, `SPEC-FLR-005` | low (guidance) | The tail term divides by `minOpeningHealthFactor`; debt can reach collateral × `CF_t` before liquidation. Resolved in spec for `SPEC-CAP-007`, `SPEC-CAP-008`, `tokenUsdCap`, `Q-249` and `MKT-013`: MATH-AR-44b PROVED; `SPEC-FLR-005` resolved in spec under MATH-ST-77: MATH-ST-78 PROVED, MATH-ST-91 COMPUTED |
| MATH-AR-50c | `SPEC-CAP-006` | low | After a cap tightening a slice top-up can pass Avana's budget but fail the Hub's `addCap`. Resolved in spec: MATH-AR-50c PROVED |
| MATH-ST-58 | `SPEC-SET-002` example | low | Its parameters gave `s = 0`, so no draw happens. Resolved in spec (cBuy 150, `Bd = 1.000004089556` GHO): MATH-ST-58 COMPUTED |
| MATH-ST-84 | `SPEC-LIQ-014` example | low | `U` omitted the USDT price ($0.9995). Resolved in spec: MATH-ST-84 COMPUTED |
| MATH-ST-75 | `SPEC-LIQ-020` | low | The health-factor threshold ignored `U` and rounding. Resolved in spec: MATH-ST-75 PROVED (corrected threshold) |
