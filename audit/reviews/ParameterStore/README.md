# ParameterStore review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/policy/parameter-store/` (UUPS router plus five immutable delegatecall logic contracts) |
| Spec | [2.9 ParameterStore](../../../spec/02-contracts/09-parameter-store.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 1 Medium, 3 Low, 6 Informational; fixes queued |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Medium | A standby-route feed change can leave the token's tolerance below its bound once the standby is in force, which blocks the short-delay tighten setters | Check every slot substitution, the standby included; tighten setters revert only on failures their own change causes | fix queued |
| 2 | Low | `setTokenCollateralFactorBps`, `setFeed` and a pool risk factor raise did not re-run the `SPEC-CF-004` listing margin for every market holding the token | Re-run for every affected market | fix queued |
| 3 | Low | `restoreSecondSource` did not re-run `checkConfig`; `useStandbySecondSource` did not re-check independence | Both re-check; events only on a change | fix queued |
| 4 | Low | The fee-recipient check missed a counterfactual proxy address and other Avana contracts | Compare `ProxyManager.predictProxy` and exclude every Avana contract | fix queued |
| 5 | Info | Logic contracts callable directly | `address(this) != SELF` guard on each logic contract | fix queued |
| 6 | Info | Missing checks: `_requireHub` in `tightenBreakerDeficitMax`; zero check before dividing by `stressFloorUsd`; no market-count bound on chain-wide re-checks; `CapLoosened` emitted without a raise; `setFeed` resetting a tightened `borrowPriceMaxAge` | Each added | fix queued |

## Spec text queued

The guardian sentence in 2.9 Permissions and the 1.5 Emergency row, the `routeDepthThreshold` key and units, the `caller` field claim, `SPEC-CF-004` and `REQ-CONFIG-024` with the standby. Tests for each finding.

## PoC tests

- `ParameterStore.Review.unit.t.sol`: `test_PoC_F1_poolRiskFactorRaiseRechecksMargin`, `test_PoC_F1_collateralFactorRaiseBreaksListingMargin`, `test_PoC_F2_standbySwitchBlocksShortDelayTighten`, `test_PoC_F3_restoreSecondSourceNoRecheck`, `test_PoC_Info_logicCallableDirectly`, `test_PoC_Info_counterfactualProxyRecipient`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; after a fix lands, the regression test in `contracts/test/` asserts the fixed behavior.
