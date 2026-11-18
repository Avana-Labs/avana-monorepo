Function links point to the interface that declares each function.

# LPVaultSwap lifecycle

LPVaultSwap is Avana's only liquidator: it pulls the repayment from its caller, repays an unhealthy account's debt on the Aave V4 Spoke, receives the seized vault tokens, has them burned and unwound into pool tokens, swaps those into the debt asset and pays Avana's fee, the borrower and the caller, all in one call. It takes no flash loan in a liquidation; a caller without the debt asset uses the [flash liquidation helper](../../periphery/flash-liquidator/LIFECYCLE.md).

```mermaid
sequenceDiagram
  autonumber
  actor K as Keeper K1
  participant SW as LPVaultSwap
  participant LK as Lock
  participant O as LPOracle
  participant CO as Collateralization
  participant S as CDP Spoke
  participant AD as AaveAdapter
  participant R as Swap route
  participant E as PayoutEscrow
  K->>SW: liquidate(proxy Q, debtToCover 1,950e6, minPayout 2,019e6, maxShortfall 0)
  Note right of SW: deadline, caller freeze. Never reads the pause<br/>state, a breaker or the keeper registry
  SW->>LK: acquire()
  SW->>O: poke()
  Note right of SW: HF below 1, Hub shares = assets,<br/>the USDC DebtOracle Live
  K-->>SW: 1,950 USDC pulled by transferFrom, Kf
  SW->>CO: beginSeizure(Q, VT)
  SW->>S: liquidationCall(collateral, debt, Q, Kf, false)
  S-->>SW: 975 vault tokens
  SW->>AD: burnSeized(m, VT, 975e18)
  SW->>CO: settleSeizure(Q, VT, 975e18, minAmounts)
  CO-->>SW: about 1,030 USDC + 1,010 USDT from the LPVault unwind
  SW->>R: swap(1,010 USDT, minOut)
  Note right of R: on a revert, RouteFailed and the backup route
  SW-->>K: keeperOut 2,020.8 USDC, a plain transfer
  opt the fee or surplus transfer is refused
    SW->>E: deposit(USDC, recipient, amount)
  end
  SW->>LK: release()
```

## Walkthrough

Uniswap v3 on Ethereum (Bob, USDC debt, 3.5 `LIQ-069`). Setup: Bob pledged a USDC/USDT position; each vault token is priced at $2.10; he borrowed USDC; HF < 1; Aave's bonus is 5%; `slippageAllowanceBps = 100`; `floorRoundingAllowance` = 1 USDC.

1. **Avana's keeper K1 → Lens [`previewLiquidation`](../../lens/lens/ILensLiquidation.sol#L41)`(Q, 2, now + 120)`:** repay 1,950 USDC, `expectedPayout = 2,028` USDC at the oracle value (1,950 funding back plus 78), `expectedCallerLoss = 0`.
2. **K1 → [`liquidate`](ILPVaultSwapLiquidation.sol#L15)`({proxy: Q, marketId: m, debtReserveId: 2, debtToCover: 1,950e6, routeMode: PrimaryThenBackup, minAmounts: [], deadline: now + 120, minPayout: 2,019e6, maxShortfall: 0})`**, directly or through its [helper](../../periphery/flash-liquidator/IFlashLiquidator.sol#L17). Implementation: [`LPVaultSwap.liquidate`](LPVaultSwap.sol#L49) delegates to [`LPVaultSwapLiquidationLogic.liquidate`](LPVaultSwapLiquidationLogic.sol#L77); the checks are [`_entryChecks`](LPVaultSwapLiquidationLogic.sol#L95), [`_checkCollateralPrice`](LPVaultSwapSettlement.sol#L90) and [`_checkDebtPrice`](LPVaultSwapSettlement.sol#L106). Checks the deadline and the caller's freeze (no keeper check), takes Lock [`acquire`](../../lock/lock/ILock.sol#L26), checks the proxy, Hub shares = assets, pokes the market's LPOracle and checks that the repaid reserve's USDC DebtOracle is Live within `liquidationPriceMaxAge` (`DebtPriceStale` otherwise), then reads `HF < 1` after both pokes. It never reads the pause state, a breaker or the committed-operator registry. Errors: [`DeadlineExpired`](ILPVaultSwapErrors.sol#L76), [`AddressIsFrozen`](ILPVaultSwapErrors.sol#L84), [`LockHeld`](ILPVaultSwapErrors.sol#L9), [`InvalidAmount`](ILPVaultSwapErrors.sol#L21), [`NotLiquidatable`](ILPVaultSwapErrors.sol#L23), [`SharesNotEqualAssets`](ILPVaultSwapErrors.sol#L26), [`StalePrice`](ILPVaultSwapErrors.sol#L29), [`DebtPriceStale`](ILPVaultSwapErrors.sol#L32), [`GraceHealthFactor`](ILPVaultSwapErrors.sol#L35).
3. **Caller funding ([`_fund`](LPVaultSwapLiquidationLogic.sol#L118)):** `transferFrom(K1, LPVaultSwap, 1,950e6)` measured by balance delta, `Kf = 1,950` USDC. Error: [`FundingMismatch`](ILPVaultSwapErrors.sol#L38) unless `0 < Kf ≤ debtToCover`.
4. **[`_seize`](LPVaultSwapLiquidationLogic.sol#L130): Collateralization [`beginSeizure`](../../custody/collateralization/ICollateralizationSeizure.sol#L11)`(Q, VT)`, then [`Spoke.liquidationCall`](../../interfaces/external/aave/IAaveV4Spoke.sol#L110)`(collateral, debt, Q, Kf, false)`:** Aave repays the debt and sends 975 vault tokens (1,950 × 1.05 ÷ 2.10) to LPVaultSwap; the vault token's transfer rule ([`isAllowedTransfer`](../../vault-token/vault-token/VaultToken.sol#L127)) admits no other liquidator.
5. **[`_unwindAndSwap`](LPVaultSwapLiquidationLogic.sol#L178): AaveAdapter [`burnSeized`](../../policy/aave-adapter/IAaveAdapter.sol#L51); Collateralization [`settleSeizure`](../../custody/collateralization/ICollateralizationSeizure.sol#L21)** → LPVault [`unwind`](../../amm/IAmmIntegration.sol#L92) returns about 1,030 USDC + 1,010 USDT. Error: [`NothingSeized`](ILPVaultSwapErrors.sol#L51).
6. **Swap USDT→USDC with a per-leg oracle minimum** ([`_swapLeg`](LPVaultSwapSettlement.sol#L223), [`_tryRoute`](LPVaultSwapSettlement.sol#L240)) through [`ISettlementRoute.swap`](../settlement-routes/ISettlementRoute.sol#L32); the backup runs if the primary reverts ([`RouteFailed`](ILPVaultSwapEvents.sol#L38)). Recovery 2,040.30 USDC ≥ the floor 2,026.02; settlement gap `g = max(0, 1,950 + 19.5 − 1,950 − 2,040.30) = 0`. Errors: [`NoRouteAvailable`](ILPVaultSwapErrors.sol#L54), [`RecoveryBelowFloor`](ILPVaultSwapErrors.sol#L58) (only when `R` plus a top-up up to `maxShortfall` stays below the floor), [`InsufficientProceeds`](ILPVaultSwapErrors.sol#L61) (defensive).
7. **[`_waterfall`](LPVaultSwapLiquidationLogic.sol#L245): Avana fee 19.5 (20% of the oracle gain `2,047.50 − 1,950 = 97.5`); keeper reward 70.8; borrower surplus 0; `keeperOut = 1,950 + 70.8 = 2,020.8` USDC to K1.** The fee and any borrower surplus are gas-limited transfers ([`_deliver`](LPVaultSwapSettlement.sol#L301): a gas check right before a 100,000-gas call, the amount that left LPVaultSwap measured, the rest escrowed); a refused one goes to PayoutEscrow [`deposit`](../payout-escrow/IPayoutEscrow.sol#L49) credited to its recipient. `keeperOut` is a plain transfer: if it fails, the whole call reverts. Lock [`release`](../../lock/lock/ILock.sol#L30). Events: [`LiquidationSettled`](ILPVaultSwapEvents.sol#L11), [`BorrowerSurplusPaid`](ILPVaultSwapEvents.sol#L17) when `B > 0`, [`DeficitSurplusFunded`](ILPVaultSwapEvents.sol#L24) when a call that books a deficit pays `B` into the First-Loss Reserve (the wallet then gets only the part the reserve does not take), [`ResidueReturned`](ILPVaultSwapEvents.sol#L41) when a route leaves input. Error: [`PayoutTooLow`](ILPVaultSwapErrors.sol#L78) (routes returning 2,035 USDC give 2,015.5 < 2,019).
8. **Any address → [`liquidate`](ILPVaultSwapLiquidation.sol#L15)** runs the same steps with either route mode; a frozen address can still go through the public helper, which LPVaultSwap sees as the caller.
9. **Any address → [`settlePending`](ILPVaultSwapLiquidation.sol#L22)`(m, r)`** (implementation [`LPVaultSwap.settlePending`](LPVaultSwap.sol#L54) → [`LPVaultSwapPendingLogic.settlePending`](LPVaultSwapPendingLogic.sol#L56), [`_fundCoverage`](LPVaultSwapPendingLogic.sol#L157)) burns vault tokens left at LPVaultSwap by an unsettled seizure, has Collateralization pay the pending pool tokens, swaps them and adds `R` to the First-Loss Reserve of `(funding Hub, settlement asset)` through `fund(R)`, or carries it while it is worth less than one Hub share. Event: [`PendingSettlementForwarded`](ILPVaultSwapEvents.sol#L51). Errors: [`NothingPending`](ILPVaultSwapErrors.sol#L74), [`FundingMismatch`](ILPVaultSwapErrors.sol#L38).
10. **AaveAdapter → [`deleverage`](ILPVaultSwapDeleverage.sol#L14)** (implementation [`LPVaultSwap.deleverage`](LPVaultSwap.sol#L63) → [`LPVaultSwapDeleverageLogic.deleverage`](LPVaultSwapDeleverageLogic.sol#L81); callback [`LPVaultSwap.onFlashLoan`](LPVaultSwap.sol#L70) → [`LPVaultSwapDeleverageLogic.onFlashLoan`](LPVaultSwapDeleverageLogic.sol#L119)) for a repay with collateral, the only path with a flash loan (through the core [`IFlashSource`](../../flash/IFlashSource.sol#L39), callback [`onFlashLoan`](../../flash/IFlashReceiver.sol#L13)): V's 1,500 vault tokens repay 2,968.505747 USDC, premium 1.484253, 29.41 USDC to V, no bonus and no Avana fee. Events: [`FlashLoanUsed`](ILPVaultSwapEvents.sol#L33), [`Deleveraged`](ILPVaultSwapEvents.sol#L66). Errors: [`NotAdapter`](ILPVaultSwapErrors.sol#L93), [`DeleverageTooSmall`](ILPVaultSwapErrors.sol#L87), [`DeleverageShortfall`](ILPVaultSwapErrors.sol#L90), [`FlashLiquidityShort`](ILPVaultSwapErrors.sol#L56), [`FlashFeeTooHigh`](ILPVaultSwapErrors.sol#L41), [`FlashSourceIsHub`](ILPVaultSwapErrors.sol#L43), [`InvalidFlashCallback`](ILPVaultSwapErrors.sol#L49).
11. **AvanaTimelock → [`addKeeper`](ILPVaultSwapAdmin.sol#L19)** (normal delay; implementation [`LPVaultSwap.addKeeper`](LPVaultSwap.sol#L101)) / [`removeKeeper`](ILPVaultSwapAdmin.sol#L25) (short delay; [`LPVaultSwap.removeKeeper`](LPVaultSwap.sol#L112)): the committed-operator registry. Initial registry: Avana's own keeper (`KEEPER_FLOOR = 1`, `MAX_KEEPERS = 32`); it gates no call, and new borrowing halts only when [`activeKeeperCount`](ILPVaultSwapViews.sol#L18) ([`LPVaultSwap.activeKeeperCount`](LPVaultSwap.sol#L146)) is 0. Events: [`KeeperAdded`](ILPVaultSwapEvents.sol#L43), [`KeeperRemoved`](ILPVaultSwapEvents.sol#L45). Errors: [`KeeperFloor`](ILPVaultSwapErrors.sol#L69), [`TooManyKeepers`](ILPVaultSwapErrors.sol#L71), [`InvalidKeeper`](ILPVaultSwapErrors.sol#L66).

## What the UI reads and calls

- Lens: [`previewLiquidation`](../../lens/lens/ILensLiquidation.sol#L41) (returns `LiquidationParams` ready to send), [`getPriceState`](../../lens/lens/ILensLiquidation.sol#L15), [`getDebtPriceState`](../../lens/lens/ILensLiquidation.sol#L21), [`getPendingSettlement`](../../lens/lens/ILensMarket.sol#L28), [`previewRepayWithCollateral`](../../lens/lens/ILensPreview.sol#L52), [`getEscrowClaimable`](../../lens/lens/ILensAccount.sol#L37); registry views [`getKeepers`](ILPVaultSwapViews.sol#L24), [`activeKeeperCount`](ILPVaultSwapViews.sol#L18); the helper's quotes [`maxFlashLoan`](../../periphery/flash-liquidator/IFlashLiquidator.sol#L40) and [`flashPremium`](../../periphery/flash-liquidator/IFlashLiquidator.sol#L46).
- Events to index: [ILPVaultSwapEvents.sol](ILPVaultSwapEvents.sol): `LiquidationSettled`, `BorrowerSurplusPaid`, `DeficitSurplusFunded`, `FlashLoanUsed`, `RouteFailed`, `ResidueReturned`, `PendingSettlementForwarded`, `Deleveraged`, `KeeperAdded`, `KeeperRemoved`.
- User calls: `liquidate` and `settlePending` (anyone); the flash liquidation helper's `flashLiquidate` (anyone, public instance).

## Spec

- [2.11 LPVaultSwap](../../../../docs/spec/02-contracts/11-lpvaultswap.md): `REQ-SWAP-001`–`REQ-SWAP-016`, `REQ-SWAP-026`, `REQ-SWAP-032`–`REQ-SWAP-038`, `REQ-SWAP-042`–`REQ-SWAP-045`, `REQ-SWAP-072`–`REQ-SWAP-076`, `REQ-SWAP-100`, `REQ-SWAP-101`, `REQ-SWAP-105`, `REQ-SWAP-106`, `REQ-FLASH-001`–`REQ-FLASH-006`, `SPEC-LIQ-009`, `SPEC-LIQ-010`, `SPEC-LIQ-014`, `SPEC-LIQ-018`–`SPEC-LIQ-020`.
- Flow: [3.5 Liquidation](../../../../docs/spec/03-operations/05-liquidation.md) `LIQ-011`, `LIQ-030`, `LIQ-041`, `LIQ-061`, `LIQ-062`, `LIQ-068`, `LIQ-069`, `LIQ-089`.
