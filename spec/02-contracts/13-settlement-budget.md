# 2.13 Settlement Budget (removed)

> **Status:** In review · **Owner:** Avana Labs · **Last reviewed:** 2026-11-10
>
> **Requirement prefix:** `REQ-BUDGET-NNN` · **Formula prefix:** `SPEC-SET-NNN`

## Purpose

Avana has no SettlementBudget contract (`Q-397`). No chain deploys one, no contract holds a settlement-budget balance, and no liquidation draws from a pool of Avana funds. Every parameter of the former contract is removed: `perCallCap`, the market and asset windows, `reservedFloor`, `PER_CALL_CAP_MAX_USD` and `BUCKET`. The rule IDs of this page are kept, each restated as the rule that replaces it.

The budget existed to close a rounding gap: the few units of the debt asset by which a routed liquidation's recovery can fall short of the debt Aave pulled. Two facts make it unnecessary:

1. **The caller sizes the repayment up front.** Aave V4's dust rule can raise the repayment needed to finish a liquidation: when a partial repayment would leave less debt or collateral than the reserve's dust threshold, Aave requires the whole debt. The caller (Avana's keeper or any other address, directly or through a flash liquidation helper) sizes `debtToCover` for that amount before the call and funds it itself ([2.11](11-lpvaultswap.md) `REQ-SWAP-005`, `REQ-SWAP-011`).
2. **The caller bears any rounding loss.** Aave pulls the debt out of the caller's own funding, so a recovery below the debt repaid is not a gap any contract must close: it lowers the caller's payout `keeperOut = Kf + R' − D − A − B` ([2.11](11-lpvaultswap.md) `SPEC-LIQ-010`). The loss is bounded by the rounding terms of the floor, a few units of the debt asset, and a recovery below the floor itself is closed by the caller's shortfall top-up or the call reverts (`SPEC-LIQ-019`).

Why: a budget keyed by Spoke, debt reserve, market and asset needed windows, reserves, refills, caps per call and a funded balance in every debt asset of every chain, each a parameter to set and a state to monitor, to pay amounts that are a fraction of a cent to a few dollars. Moving the gap to the caller removes a funded contract, its timelocked setters and its draw path from every liquidation, and keeps the conservation identity of LPVaultSwap exact with one fewer term. Avana's keepers already hold debt-asset inventory to fund liquidations (`REQ-SWAP-014`), so the loss is borne from that inventory.

Example: the dust liquidation of [2.11](11-lpvaultswap.md) repays `D = 3` USDC from a caller funding of `Kf = 3` USDC; the routes recover `R = 2.95` USDC, above the floor. The gap is `max(0, 3 + 0 + 0 − 3 − 2.95) = 0`, no top-up is pulled, and the caller receives `keeperOut = 2.95` USDC, a 0.05 USDC loss. The same call through the public flash liquidation helper with `F = 3` USDC at 5 bps needs `3.0015` USDC to repay the Pool, so the helper pulls 0.0515 USDC from its caller within the caller's top-up bound ([2.11](11-lpvaultswap.md) `REQ-HELPER-007`); with a bound of 0 the helper reverts and the caller resubmits from its own funds.

## Inputs

None. No contract exists.

## Outputs

None. LPVaultSwap's `LiquidationResult` and `LiquidationSettled` event carry no `budgetDraw` field ([2.11](11-lpvaultswap.md)).

## Storage

None.

## Functions

None. LPVaultSwap has no `SETTLEMENT_BUDGET` immutable and makes no `draw` call.

## Permissions

None. No timelock operation, guardian action or role refers to a settlement budget.

## Dependencies

None. The RiskModule has no `BUDGET` breaker condition and reads no budget window ([2.7](07-risk-module.md)).

## Settlement math

- `SPEC-SET-001` **Settlement gap, paid by the caller.** Replaces the draw amount. LPVaultSwap computes the gap `g = max(0, D + A + B − Kf − R)`, with `D` the debt Aave pulled, `A` and `B` Avana's fee and the borrower surplus of the waterfall on `R_f = max(R, minRec)` ([2.11](11-lpvaultswap.md) `SPEC-LIQ-008`, `SPEC-LIQ-009`, `SPEC-LIQ-022`), `Kf` the caller funding LPVaultSwap received and `R` the recovery, all in units of the debt asset `T`, and includes it in the shortfall the caller pays: `shortfall = max(0, minRec − R, g)` ([2.11](11-lpvaultswap.md) `SPEC-LIQ-019`). No flash premium or transfer-fee term appears: LPVaultSwap takes no flash loan, and a helper's loan, premium and transfer fees are the helper's own (`Q-404`). Because Aave pulls `D` out of the `Kf` it was approved for, `D ≤ Kf`, and because `A + B ≤ max(0, R_f − D)`, the gap never exceeds the floor gap: `g ≤ max(0, minRec − R)`. So `shortfall = max(0, minRec − R)`, the part of `shortfall` above the floor gap is always 0, and the `InsufficientProceeds` check on `g` is defensive. Units: debt units. Rounding: exact. Why: `Kf + R + shortfall ≥ D + A + B` is exactly what the conservation identity of `SPEC-LIQ-010` needs for `keeperOut ≥ 0`, and the caller's own funding already provides it; a recovery below `D` lowers only the caller's payout. No Avana funds are spent. Example: `D = Kf = 3`, `R = 2.95` USDC above `minRec` give `A = B = 0` and `g = max(0, 3 − 3 − 2.95) = 0`, so the call settles with `shortfall = 0` and `keeperOut = 2.95` USDC; routes returning `R = 2,000` USDC against `minRec = 2,026.024998` and `Kf = D = 1,950` give `A + B ≤ 76.024998`, `g ≤ max(0, 1,950 + 76.024998 − 1,950 − 2,000) = 0`, and the floor gap 26.024998 USDC is the whole shortfall. Checked by: MATH-ST-17, MATH-ST-18, MATH-ST-19, MATH-ST-23, MATH-ST-25, MATH-ST-26, MATH-ST-53, MATH-ST-121, MATH-ST-122, SYM-46a–d. (Source: Q-117, Q-190, Q-397, Q-404)
- `SPEC-SET-002` **No per-call cap.** Replaces the per-call cap. The caller's own `maxShortfall` bounds what one call can pull from it; no Avana-funded amount exists to cap. (Source: Q-198, Q-267, Q-397)
- `SPEC-SET-003` **No rolling windows.** Replaces the window running sums. No settlement amount is counted across calls or time, so no liquidation depends on what earlier liquidations of the market or asset used. (Source: Q-167, Q-236, Q-397)
- `SPEC-SET-004` **No withdrawal timing.** Replaces the withdrawal timing. No Avana settlement balance exists to withdraw. (Source: Q-101, Q-167, Q-397)
- `SPEC-SET-005` **No remaining-capacity view.** Replaces `remainingToday`. The Lens previews the loss a call may leave its caller instead, `expectedCallerLoss`, which a helper's caller uses to size its top-up bound ([2.17](17-lens.md) `REQ-LENS-029`). (Source: Q-236, Q-397)
- `SPEC-SET-006` **No market partition.** Replaces the partition of the asset window into market windows. Each liquidation's gap is paid by its own caller, so one market's liquidations can never consume another market's settlement capacity (`AMMN-RT-13` holds by construction). (Source: Q-343, Q-397)
- `SPEC-SET-007` **No reserved floor.** Replaces the per-market reserve. No market needs a reserved balance, because no market draws. (Source: Q-387, Q-397)

## Draw rules

- `REQ-BUDGET-001` LPVaultSwap MUST NOT call any settlement-budget contract; no such contract exists on any chain. (Source: Q-167, Q-397)
- `REQ-BUDGET-002` A floor gap that the caller's `maxShortfall` does not cover MUST revert the liquidation with `RecoveryBelowFloor`, never be paid from Avana funds; the gap `g` never exceeds the floor gap, so its `InsufficientProceeds` check is defensive ([2.11](11-lpvaultswap.md) `SPEC-LIQ-019`). (Source: Q-117, Q-397)
- `REQ-BUDGET-003` The caller's gap payment MUST be measured as the rise of LPVaultSwap's `T` balance and MUST equal the amount pulled, like every other caller payment (`REQ-SWAP-108`). (Source: Q-167, Q-390, Q-397)
- `REQ-BUDGET-004` The gap rule of `SPEC-SET-001` MUST apply identically to every caller of `liquidate`, the only liquidation entry point; `deleverage` and `settlePending` have no gap term (`deleverage` sizes its repayment within the recovered value, `SPEC-LIQ-020`; `settlePending` repays no debt). (Source: Q-127, Q-213, Q-397)

## Funding, caps and withdrawals

- `REQ-BUDGET-005` Avana Labs funds no settlement balance. Avana's keepers hold debt-asset inventory on each chain that covers the largest `debtToCover` the market caps allow plus the rounding loss it can leave (`REQ-SWAP-014`, `INV-038`). (Source: Q-167, Q-336, Q-397, Q-404)
- `REQ-BUDGET-006` No settlement cap setter exists; the ParameterStore holds no `perCallCap`, window, `reservedFloor`, `PER_CALL_CAP_MAX_USD` or `BUCKET` value ([2.9](09-parameter-store.md)). (Source: Q-228, Q-397)
- `REQ-BUDGET-007` No settlement withdrawal operation exists. (Source: Q-101, Q-397)
- `REQ-BUDGET-008` No settlement balance exists, so no withdrawal can take Avana funds that a liquidation needs. (Source: Q-387, Q-397)
- `REQ-BUDGET-009` No settlement timelock operation exists to cancel. (Source: Q-047, Q-397)
- `REQ-BUDGET-010` LPVaultSwap MUST hold no settlement balance between calls: its debt-asset change over each call is exactly 0 (`SPEC-LIQ-010`). (Source: Q-104, Q-397)

## Events

None. LPVaultSwap's `LiquidationSettled` reports `shortfall`, which includes any settlement gap the caller paid.

## Restrictions

- `REQ-BUDGET-011` Coverage Spoke capital MUST NOT be used for settlement gaps, and no settlement gap is ever reported as a deficit: a liquidation's rounding loss falls on its caller's payout, and a floor gap is closed by the caller or the call reverts. Proceeds of `settlePending` go to a Coverage Spoke ([2.14](14-first-loss-reserve.md)). (Source: Q-071, Q-397)
- `REQ-BUDGET-012` No Avana contract pays a keeper, a borrower or any caller for a settlement gap; the caller pays it from its own funds. (Source: Q-127, Q-397)
- `REQ-BUDGET-020` No settlement key (Spoke and debt reserve, market and asset, or asset) is stored anywhere. (Source: Q-236, Q-397)
- `REQ-BUDGET-021` No rolling total of settlement payments exists for any asset. (Source: Q-236, Q-397)
- `REQ-BUDGET-022` Listing a debt asset needs no settlement-budget configuration ([2.8](08-market-registry.md) `enableDebtReserve`). (Source: Q-236, Q-397)
- `REQ-BUDGET-024` No liquidation names a market to any settlement-funding contract. (Source: Q-343, Q-397)
- `REQ-BUDGET-027` What replaces the budget's guarantees (`INV-097`): for every liquidation, Avana funds spent on its settlement are 0, and the caller pays at most its own `maxShortfall`. (Source: Q-236, Q-343, Q-387, Q-397)
- `REQ-BUDGET-028` No reserve refill exists. (Source: Q-387, Q-397)
- `REQ-BUDGET-029` No reserved-floor setter exists. (Source: Q-387, Q-397)

## Failure Conditions

| ID | Condition | Behavior |
|---|---|---|
| `REQ-BUDGET-013` | A call to a settlement-budget address | Nothing to call; LPVaultSwap has no such dependency (Source: Q-167, Q-397) |
| `REQ-BUDGET-014` | Settlement gap above the caller's `maxShortfall` | Unreachable while `Kf ≥ D` (`SPEC-SET-001`); the defensive check reverts with `InsufficientProceeds`, and a floor gap above `maxShortfall` reverts with `RecoveryBelowFloor` first (Source: Q-117, Q-397, Q-404) |
| `REQ-BUDGET-015` | Caller's inventory too small for the gap | That caller's call reverts; any other caller can liquidate the account; no market depends on a shared balance (Source: Q-387, Q-397) |
| `REQ-BUDGET-016` | Settlement timelock operation | None exists (Source: Q-228, Q-397) |
| `REQ-BUDGET-017` | Per-call cap below the rounding allowance | Not applicable: no cap exists; `floorRoundingAllowance` still bounds the floor (`SPEC-LIQ-005`) (Source: Q-198, Q-397) |
| `REQ-BUDGET-018` | Privileged settlement function | None exists (Source: Q-228, Q-397) |
| `REQ-BUDGET-019` | Settlement cap tighten or loosen | None exists (Source: Q-343, Q-397) |
| `REQ-BUDGET-023` | Asset window exceeded | Not applicable: no windows (Source: Q-236, Q-397) |
| `REQ-BUDGET-025` | Market window exceeded | Not applicable: each call's caller pays its own gap (Source: Q-343, Q-397) |
| `REQ-BUDGET-026` | Market windows above the asset window | Not applicable (Source: Q-343, Q-397) |
| `REQ-BUDGET-030` | Withdrawal above an unreserved balance | Not applicable (Source: Q-387, Q-397) |
