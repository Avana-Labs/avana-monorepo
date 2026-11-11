# Swap routes review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/liquidation/settlement-routes/` (`DexPathRoute`, `WrapperThenDexRoute`, `PegModuleRoute`, `DexHops`, `RouteMath`, `SwapRouteBase`) |
| Spec | [2.12 Settlement Routes](../../../spec/02-contracts/12-settlement-routes.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 1 Medium, 3 Low, 1 Informational; fixes queued |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Medium | A transfer fee switched on (USDT) reverts every Uniswap v3 or Slipstream hop the token enters, as input or intermediate, so both route slots can fail together | A token whose issuer can switch on a transfer fee enters only Curve hops (or a peg module proven to handle it), checked at route deployment and listing; `REQ-ROUTE-008` and the `swap` NatSpec corrected; `REQ-ROUTE-003` independence extended to a shared fee switch; the GSM static-aToken deposit verified on the fork | fix queued |
| 2 | Low | A look-alike pool with the right tokens but from no factory passes the constructor | Pools checked against pinned factories (Uniswap `getPool(t0, t1, fee)`, Slipstream `getPool(t0, t1, tickSpacing)`, the Curve NG registry) | fix queued |
| 3 | Low | The caller can sandwich its own liquidation within `oracleValue − minOut` per leg | Accepted trade-off, as SettlementMath S1; for contract 23 the aggregate floor values residues paid to the caller | accepted |
| 4 | Low | An input that credits `amountIn + 1` is accepted and counted as `amountIn` | Measured input rule stated | fix queued |
| 5 | Info | Constructor failures revert with mixed reasons; a LitePSM with the wrong gem deploys | Every constructor failure reverts `InvalidRouteConfig`; LitePSM `gem`, `dai`, conversion factor and converter tokens checked at deployment | fix queued |

## Also queued

Spec: 2.12 Outputs and the "no balance left" interface text against `REQ-ROUTE-016` donations; `intermediates()` NatSpec; `REQ-ROUTE-011` GSM wording; `REQ-ROUTE-016` rebasing rounding. Tests: fee on pool hops and intermediates, constructor failure cases, a callback refusal while a hop is in progress, rebasing inputs, fork tests (`REQ-ROUTE-043`). Balancer hops are out of the launch routes (decided 2026-11-10).

## PoC tests

- `RoutesReview.poc.t.sol`: `test_PoC_M1_feeOnTransferInputRevertsOnClHop`, `test_PoC_M1_feeOnTransferIntermediateRevertsOnClHop`, `test_PoC_L1_lookalikePoolPassesConstructorAndKeepsSlack`, `test_PoC_I1_constructorRevertReasonNotInvalidRouteConfig`, `test_PoC_I2_litePsmWithWrongGemDeploys`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; after a fix lands, the regression test in `contracts/test/` asserts the fixed behavior.
