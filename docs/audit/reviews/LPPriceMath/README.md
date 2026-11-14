# LPPriceMath review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/oracle/lp-oracle/LPPriceMath.sol` (library) |
| Spec | [2.10 LPOracle, LPPriceMath and DebtOracle](../../../spec/02-contracts/10-lp-oracle.md#lppricemath) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 2 Medium, 5 Low, 1 Informational; code fixes merged after the gate |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Medium | Array-length mismatches in `lpPrice`, `vaultDecimals` and `inUsdBand` read out of bounds or misprice | Malformed inputs return a validity flag (`lpPrice` and `inUsdBand` return `(bool valid, …)`, `vaultDecimals` returns `found`), mapped by the oracles to reason bit 1 | fixed |
| 2 | Medium | Signed feed answers cast without a sign check: a negative answer normalised to a huge price | Answers taken as `int256`; 0 for `answer ≤ 0` or `≥ 2^128` | fixed |
| 3 | Low | The served price under disagreement could sit above the fresh price | `served = min(lower, fresh, A)` | fixed |
| 4 | Low | `deviationBps` reverted on large inputs, at route scale too | Saturates instead of reverting | fixed |
| 5 | Low | The USD band check depended on token order | `usdLevel = max{L : L^⊗n ≤ ⊗q}` by binary search (answers the `SPEC-ORC-011` question) | fixed |
| 6 | Low | `servedTimestamp([])` returned a value for an empty input | Fails closed | fixed |
| 7 | Low | Saturation in `_fixedMul` was not sticky across a chain of multiplications | Sticky saturation | fixed |
| 8 | Informational | `pokeMinGasFloor` differed from the Z3 model `MATH-UO-57c` | Matched to `MATH-UO-57c`. Rated Informational: no deployed code calls the function (only the unit and differential tests and the off-chain sizing of `POKE_MIN_GAS_FLOOR` use it), so the difference could not move value or starve a read | fixed |

## Spec-text changes

`INV-055` formula and `min(lower, fresh, A)`; `INV-087`, `PROP-074`, `TEST-230` with `min(lower, fresh, A)`; `PROP-026` bounds; `TEST-037` reference wording; 1.5 `POKE_MIN_GAS_FLOOR` and `POST_CALL_GAS` rows; `PriceStateView.usdLevel` docs; ParameterStore `FeedDef.maxAnswerCap` (`REQ-ORACLE-049`) and `heartbeatMargin` as `uint16`. Status: decided. The LPOracle and the DebtOracle use the new signatures.

## Evidence after the fixes

Unit, fuzz (10,000 runs) and differential tests pass; Z3 `uo13` and SymPy `sym08` (82 / 82) recompute the new bounds. Halmos `PROP-023`, `PROP-024` symmetry and `PROP-026` time out; their fuzz twins carry them.

## PoC tests

- `PoC.t.sol` with `LPPriceMathHarness.sol`: `test_lpPriceLengthMismatch`, `test_negativeCastNormalize`, `test_negativeCastRoute`, `test_servedAboveFresh`, `test_deviationBpsReverts`, `test_deviationBpsRevertsAtRouteScale`, `test_bandOrderDependent`, `test_servedTimestampEmpty`, `test_saturationNotSticky`, `test_minObsZeroBlockTime`, `test_agreeOverflow`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; for each fixed finding, a regression test in `contracts/test/` asserts the fixed behavior.
