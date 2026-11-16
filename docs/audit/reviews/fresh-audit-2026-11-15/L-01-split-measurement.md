# L-01 split-liquidation measurement

Measures the split variant of L-01, where the same underwater account is liquidated in one call and in several partial calls, and records the fix.

**Decision (2026-11-16): insolvent → reserve.** Before each liquidation, if the account's collateral value is below its debt times the liquidation bonus, `B` goes to the First-Loss Reserve on every call, not only on the call that books the deficit. The fallback from PR #80 stays: the borrower receives any part the reserve does not take. The fix is in PR #90 (`LPVaultSwapLiquidationLogic._seize` and `_waterfall`).

Test: `contracts/test/integration/LPVaultSwap.SplitLiquidation.integration.t.sol` (local Aave V4, real LPVaultSwap and First-Loss Reserve, the BadDebt fixture).

```bash
forge test -j 2 --match-path test/integration/LPVaultSwap.SplitLiquidation.integration.t.sol -vv
```

## Is partial liquidation of an insolvent account allowed?

Yes. Aave V4 has no close factor:

- A call repays `min(debtToCover, debt to the target health factor)`. For an insolvent account the target-HF debt is above the whole debt, so the caller's `debtToCover` sets the size (`LiquidationLogic._calculateDebtToLiquidate`).
- The only limit is the dust rule. A call that would leave less than $1,000 of collateral and some debt must seize all the collateral, and it reverts with `MustNotLeaveDust` if `debtToCover` is too small for that.
- LPVaultSwap adds no size rule, and Aave's self-liquidation check compares the account with LPVaultSwap, not with the caller. The borrower can therefore act as its own keeper.

Tests:

- `test_TEST_216_partialCallOnAnUnderwaterAccountFundsTheReserve`: a 1,000 USDC call on the report's account settles, leaves collateral and books no deficit. Before the fix it paid `B` to the borrower; now its `B` funds the reserve.
- `test_TEST_216_dustRuleKeepsTheLastThousandDollarsForTheDeficitCall`: a call that would leave $500 of collateral reverts with `MustNotLeaveDust`.

Before the fix, the borrower could therefore keep `B` on all collateral except the last call's slice, and that slice need be only just over $1,000.

## Setup

- Account: 10,000 USDC debt, collateral worth 9,000 at the oracle price (the report's example), plus a 1,000,000 / 900,000 account.
- Tiers (anvil listing config): Stable CF 35%, bonus 10,500, slippage 195 bps; Correlated 34%, 10,600, 230 bps; Volatile 30%, 10,800, 300 bps.
- Spread: realized swap proceeds `R` above the oracle value `V` of the seized units: 0.10%, 0.40% (the report's 8,991 vs 8,955), 1% and 2%.
- Splits:
  - 1 call.
  - 2, 4 and 8 calls: equal partial calls, then one call for the rest.
  - "2 (max)": one partial call that leaves $1,010 of collateral, then the final call.
- The borrower is the caller. Avana fee share is 20%.

## Results before the fix

These numbers come from the measurement run on `main` before the fix.


`B` totals depend only on the spread and the split; they are identical in the three tiers (the tier changes the deficit and the keeper reward, which do not depend on the split). Amounts in USDC; "% of V" is the borrower's `B` over the oracle value of everything seized (9,000).

| Spread | Split | Total `B` | `B` to borrower | `B` to reserve | Borrower % of V |
|---|---|---|---|---|---|
| 0.10% | 1 | 9.00 | 0.00 | 9.00 | 0.000% |
| 0.10% | 2 | 9.00 | 4.50 | 4.50 | 0.050% |
| 0.10% | 4 | 9.00 | 6.75 | 2.25 | 0.075% |
| 0.10% | 8 | 9.00 | 7.88 | 1.13 | 0.087% |
| 0.10% | 2 (max) | 9.00 | 7.99 | 1.01 | 0.088% |
| 0.40% | 1 | 36.00 | 0.00 | 36.00 | 0.000% |
| 0.40% | 2 | 36.00 | 18.00 | 18.00 | 0.200% |
| 0.40% | 4 | 36.00 | 27.00 | 9.00 | 0.300% |
| 0.40% | 8 | 36.00 | 31.50 | 4.50 | 0.350% |
| 0.40% | 2 (max) | 36.00 | 31.96 | 4.04 | 0.355% |
| 1.00% | 1 | 90.00 | 0.00 | 90.00 | 0.000% |
| 1.00% | 2 | 90.00 | 45.00 | 45.00 | 0.500% |
| 1.00% | 4 | 90.00 | 67.50 | 22.50 | 0.750% |
| 1.00% | 8 | 90.00 | 78.75 | 11.25 | 0.875% |
| 1.00% | 2 (max) | 90.00 | 79.90 | 10.10 | 0.887% |
| 2.00% | 1 | 180.00 | 0.00 | 180.00 | 0.000% |
| 2.00% | 2 | 180.00 | 90.00 | 90.00 | 1.000% |
| 2.00% | 4 | 180.00 | 135.00 | 45.00 | 1.499% |
| 2.00% | 8 | 180.00 | 157.50 | 22.50 | 1.749% |
| 2.00% | 2 (max) | 180.00 | 159.80 | 20.20 | 1.775% |

Deficit and keeper reward. Both are the same for every split and spread; the deficit matches to the cent.

| Tier | Final deficit (reserve pays) | Keeper reward |
|---|---|---|
| Stable | 1,428.57 | 342.86 |
| Correlated | 1,509.43 | 407.55 |
| Volatile | 1,666.67 | 533.33 |

Large account, Stable tier, 0.40% spread (1,000,000 debt, 900,000 collateral). The deficit is 142,857.14 and the keeper reward 34,285.71.

| Split | Total `B` | `B` to borrower | `B` to reserve | Borrower % of V |
|---|---|---|---|---|
| 1 | 3,600.00 | 0.00 | 3,600.00 | 0.000% |
| 2 | 3,600.00 | 1,800.00 | 1,800.00 | 0.200% |
| 8 | 3,600.00 | 3,150.00 | 450.00 | 0.350% |
| 2 (max) | 3,600.00 | 3,595.96 | 4.04 | 0.399% |

Reading:

- The borrower's take is `total B × (collateral seized before the last call / all collateral)`. This is at most the spread times the seized value. Two calls are enough to reach almost all of it.
- Because the dust slice is a fixed $1,000, the share grows with account size. On the $900,000 account the reserve keeps 4.04 of 3,600 (0.1%).
- Splitting does not change the deficit the reserve covers or the keeper reward. The borrower gains only the `B` column, minus the gas of the extra calls. On the $9,000 account that gain is a few dollars; on the $900,000 account it is $3,596 for one extra call.

## Results after the fix

Same test, same cases, with the fix. The test checks every row below, and `B` goes to the borrower only in the solvent rows.

- **Underwater account, every split.** This covers 1, 2, 4 and 8 calls and the 2 (max) split, in all three tiers, at all four spreads, plus the $900,000 account. The reserve receives all of `B` and the borrower receives 0.00. Total `B`, the deficit and the keeper reward are the same as before the fix. At 0.40%: total `B` 36.00 goes to the reserve (3,600.00 on the $900,000 account).
- **Account between `debt` and `debt × bonus`.** This is 10,000 USDC of debt against collateral halfway to `debt × bonus` (10,250 on Stable). Its first call starts with collateral above the debt, so a `V < debt` test would have missed it. Both calls fund the reserve, and the last call books a deficit.
- **Solvent account.** This is 10,000 USDC of debt against 11,000 of collateral, repaid in one call or two. No deficit, and the borrower receives all of `B`.

Borrower `B` and reserve `B`, in USDC:

| Case (2 calls) | Tier | 0.10% | 0.40% | 1% | 2% |
|---|---|---|---|---|---|
| Between `debt` and `debt × bonus`: all to the reserve | Stable | 10.25 | 41.00 | 102.50 | 205.00 |
| | Correlated | 10.30 | 41.20 | 103.00 | 206.00 |
| | Volatile | 10.40 | 41.60 | 104.00 | 208.00 |
| Solvent: all to the borrower | Stable | 10.50 | 42.00 | 105.00 | 210.00 |
| | Correlated | 10.60 | 42.40 | 106.00 | 212.00 |
| | Volatile | 10.80 | 43.20 | 108.00 | 216.00 |

Final deficits in the "between `debt` and `debt × bonus`" case: Stable 238.10, Correlated 283.02, Volatile 370.37.

Gas: each liquidation costs 1,996 more (`snapshots/WholeAccountSeizure.json`). The per-call budget `G(16)` in `LPVaultSwap.Liquidation.gas.t.sol` still holds.

## Fix options and measured effect

1. **Accept and document.**
   - The borrower keeps up to about the spread times the seized value. Measured: 0.355% of V at 0.40% spread and 1.775% at 2%.
   - On large accounts this is nearly all of `B` (99.9% on the $900,000 account).
   - The reserve still pays the full deficit. PR #80 then only covers keepers that liquidate in one call.
2. **Send `B` to the reserve whenever the account is insolvent before the call (`V < debt`).**
   - In every case measured, every call began with the account insolvent (asserted in each case). Under this rule the borrower receives 0.00 in every row, and the reserve receives the full total `B`, the same as the one-call row.
   - It needs no new state. The check compares the account's collateral and debt values from `getUserAccountData`, which `_entryChecks` already reads (it uses only `healthFactor` and `borrowCount` today).
   - Limit: Aave seizes collateral at `debt × bonus`, so an account with `debt ≤ collateral < debt × bonus` also ends in a deficit, and `V < debt` misses its earlier calls. A check of `collateral value < debt × bonus` covers that band. This band was not measured here.
   - Side effect: if prices recover after an early partial call, the borrower loses that call's `B` even though no deficit is ever booked.
3. **Cap `B` per account.**
   - This needs a per-account running total in LPVaultSwap. `REQ-SWAP-019` allows only per-call deltas and snapshots, so the spec would have to change.
   - It bounds the leak only to the cap. Total `B` here is 9 to 180 on a $9,000 account and 3,600 on the $900,000 account, so a cap that matters is close to zero, which in effect is option 2.
   - Not measured, because measuring it would need a contract change.

Chosen: option 2 with the `collateral value < debt × bonus` condition (decision of 2026-11-16, PR #90). It closes every measured case, adds no state and uses values the call already reads.
