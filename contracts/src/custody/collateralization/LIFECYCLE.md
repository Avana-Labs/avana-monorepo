# Collateralization lifecycle

Collateralization is the immutable backing ledger: it holds one record per pledged position, books the RiskModule's cap charge, decides which records a seizure debits, and keeps every market's vault-token supply at or below credited plus pending units.

```mermaid
sequenceDiagram
  autonumber
  participant AD as AaveAdapter
  participant SW as LPVaultSwap
  participant CO as Collateralization
  participant V as LPVault
  participant O as LPOracle
  participant RM as RiskModule
  AD->>CO: pledge(Carol, P, VT, key1, false)
  CO->>V: checkReadSafe(3)
  CO->>V: receivePosition(3, Carol, key1)
  CO->>O: poke()
  CO->>RM: checkPledge(Carol, P, 3, integrationId, key1, units, counters, false)
  CO-->>AD: credited = 10,000,000,000
  AD->>CO: release(P, VT, keyB, 2,500,000,000)
  CO->>V: returnPosition(keyB)
  AD->>CO: releasePartial(P, VT, key1, 2,000,000,000, [1,990e6, 1,990e6])
  CO->>V: releaseToDepositor(key1, 2,000,000,000, [1,990e6, 1,990e6])
  AD->>CO: collectFees(Carol, VT, key1)
  CO->>V: collectFees(key1, Carol)
  Note over SW,V: liquidation, Lock held by LPVaultSwap
  SW->>CO: beginSeizure(Q, VT)
  Note right of SW: Spoke.liquidationCall, then<br/>AaveAdapter.burnSeized
  SW->>CO: settleSeizure(Q, VT, 975e18, minAmounts)
  loop each debited record, largest first
    CO->>V: unwind(key, units, minAmounts, LPVaultSwap)
  end
  SW->>CO: settlePending(VT, units)
  CO-->>SW: pending pool tokens, no LPVault call
```

## Walkthrough

Setup (Base market 3, from 3.1 `DEP-029` and 3.4 `WDR-045`): one whole vault token (10^6 units) is worth $2.00; `marketUsdCap = $5,000,000` with $1,000,000 booked in `Regular`; at most 16 open records per account and market. Every call below comes from the AaveAdapter or LPVaultSwap while it holds the Lock.

1. **AaveAdapter → [`pledge`](CollateralizationPledge.sol#L40)`(Carol, P, VT, key1, false)`.** Checks the vault token, `isValidProxy(P)`, no open record for the key, fewer than 16 records, the pool lock (`checkReadSafe`); calls LPVault [`receivePosition`](../../amm/IAmmIntegration.sol#L90) (units 10,000,000,000), LPOracle [`poke`](../../oracle/lp-oracle/ILPOracle.sol#L162) and RiskModule [`checkPledge`](../../policy/risk-module/IRiskModuleChecks.sol#L58), which returns a $20,000 charge with `sliceUsd = 0`. Writes record 1, inserts it largest-first, adds $20,000 to `Regular` and the USDC, USDT and depositor counters, and returns `credited = 10,000,000,000`. Event: [`CollateralPledged`](ICollateralizationEvents.sol#L29). Errors: [`InvalidDepositor`](ICollateralizationErrors.sol#L133), [`InvalidVaultToken`](ICollateralizationErrors.sol#L30), [`UnknownProxy`](ICollateralizationErrors.sol#L35), [`AlreadyPledged`](ICollateralizationErrors.sol#L58), [`TooManyRecords`](ICollateralizationErrors.sol#L41), [`InvalidCharge`](ICollateralizationErrors.sol#L69); RiskModule errors pass through unchanged.
2. **AaveAdapter → [`pledge`](CollateralizationPledge.sol#L40) of `keyB` (2,500,000,000 units, $5,000).** Record 2 of 16; the account's credited units are 12,500,000,000. A borrow in between only set the indebted mark through [`markIndebted`](CollateralizationDebtMark.sol#L22); it booked no charge.
3. **AaveAdapter → [`recredit`](CollateralizationPledge.sol#L111)** (Ethereum example of 3.1): after `increaseLiquidity`, `added = live − credited = 27,500,000,000 − 25,000,000,000 = 2,500,000,000`; charge $5,000; the record's basis becomes 27,500,000,000 units and $55,000 and it keeps its list position. Event: [`RecordRecredited`](ICollateralizationEvents.sol#L135). Errors: [`NothingToRecredit`](ICollateralizationErrors.sol#L152), [`NotDepositor`](ICollateralizationErrors.sol#L87).
4. **AaveAdapter → [`release`](CollateralizationRelease.sol#L33)`(P, VT, keyB, 2,500,000,000)`** after the Adapter burned the units. Reconciles first against the proxy's supplied shares, requires `units == credited`, releases the $5,000 charge, closes the record, then calls LPVault [`returnPosition`](../../amm/IAmmIntegration.sol#L102). Event: [`CollateralReleased`](ICollateralizationEvents.sol#L51). Errors: [`RecordNotFound`](ICollateralizationErrors.sol#L73), [`NotRecordProxy`](ICollateralizationErrors.sol#L78), [`UnitsMismatch`](ICollateralizationErrors.sol#L83).
5. **AaveAdapter → [`releasePartial`](CollateralizationRelease.sol#L49)`(P, VT, key1, 2,000,000,000, [1,990e6, 1,990e6])`.** Requires `0 < units < credited`; debits in place to 8,000,000,000 units, releases `$20,000 × 2 / 10 = $4,000`, then calls LPVault [`releaseToDepositor`](../../amm/IAmmIntegration.sol#L193), which pays about 2,000 USDC + 2,000 USDT to Carol. Event: [`RecordReduced`](ICollateralizationEvents.sol#L127). Errors: [`PartialRemovalTooLarge`](ICollateralizationErrors.sol#L147), [`BelowMinimum`](ICollateralizationErrors.sol#L54).
6. **AaveAdapter → [`collectFees`](CollateralizationRelease.sol#L116)`(Carol, VT, key1)`.** The LPVault's [`collectFees`](../../amm/IAmmIntegration.sol#L209) pays 16.50 USDC and 15.95 USDT to Carol; no unit or counter changes. Error: [`NotDepositor`](ICollateralizationErrors.sol#L87).
7. **LPVaultSwap → [`beginSeizure`](CollateralizationSeizure.sol#L29)`(Q, VT)`** before `Spoke.liquidationCall` on Bob's account (3.5 `LIQ-069`). Stores `sharesBefore` and `supplyBefore` in transient storage. Errors: [`SharesNotEqualAssets`](ICollateralizationErrors.sol#L95), [`SeizureActive`](ICollateralizationErrors.sol#L99).
8. **LPVaultSwap → [`settleSeizure`](CollateralizationSeizure.sol#L45)`(Q, VT, 975e18, minAmounts)`** after the AaveAdapter's `burnSeized`. Checks share drop = supply drop = 975e18, reconciles, debits 975 vault tokens from the head of the largest-first list, releases exposure, and calls LPVault [`unwind`](../../amm/IAmmIntegration.sol#L181) for each debited record: about 1,030 USDC + 1,010 USDT reach LPVaultSwap; fees stay with the position. Events: [`RecordDebited`](ICollateralizationEvents.sol#L71), [`SeizureSettled`](ICollateralizationEvents.sol#L89), [`SeizureReconciled`](ICollateralizationEvents.sol#L99) when a shortfall is reconciled. Errors: [`SeizureMismatch`](ICollateralizationErrors.sol#L103), [`DebitMismatch`](ICollateralizationErrors.sol#L107), [`SupplyDropMismatch`](ICollateralizationErrors.sol#L114), [`InsufficientCredit`](ICollateralizationErrors.sol#L118), [`BelowMinimum`](ICollateralizationErrors.sol#L54).
9. **Pending balance.** If a seizure is never settled, the next reconcile (3.4 worked example) moves the 12,000,000,000 missing units of `key7` into `pending[VT] = {12,000,000,000; [11,998.500187 USDC, 12,001.5 USDT]}`. Anyone then calls LPVaultSwap `settlePending`, which calls [`settlePending`](CollateralizationPending.sol#L33)`(VT, units)`; 300 of 1,000 pending units pay `[180, 120]` of `[600, 401]`. Event: [`PendingSettled`](ICollateralizationEvents.sol#L106). Errors: [`PendingExceeded`](ICollateralizationErrors.sol#L122), [`SupplyDropMismatch`](ICollateralizationErrors.sol#L114).
10. **AaveAdapter → [`releaseForDeleverage`](CollateralizationRelease.sol#L74)** inside a repay with collateral: debits 1,500,000,000 units of record #31 and unwinds them to LPVaultSwap; closes the record when credited reaches 0. Then [`markDebtFree`](CollateralizationDebtMark.sol#L35) clears the mark once Aave reports `borrowCount == 0` (a read that fails with under 50,000 gas left reverts [`InsufficientGas`](ICollateralizationErrors.sol#L140); one that fails with more keeps the mark, and anyone clears it later through the AaveAdapter's [`refreshDebtMark`](../../policy/aave-adapter/IAaveAdapterUser.sol#L194)); [`releaseZeroCredit`](CollateralizationRelease.sol#L97) returns a record a seizure took to 0 (error [`RecordHasCredit`](ICollateralizationErrors.sol#L91) otherwise).

## What the UI reads and calls

- Lens: [`getRecords`](../../lens/lens/ILensAccount.sol#L47), [`getAccount`](../../lens/lens/ILensAccount.sol#L32), [`checkBacking`](../../lens/lens/ILensMarket.sol#L20), [`checkRecordBacking`](../../lens/lens/ILensMarket.sol#L33), [`getPendingSettlement`](../../lens/lens/ILensMarket.sol#L43), [`getCapHeadroom`](../../lens/lens/ILensMarket.sol#L53); direct views [`previewRelease`](CollateralizationViews.sol#L136) (the `units` argument of `withdraw`), [`previewRecredit`](CollateralizationViews.sol#L146), [`getAccountRecords`](CollateralizationViews.sol#L47), [`getPending`](CollateralizationViews.sol#L92).
- Events to index: [ICollateralizationEvents.sol](ICollateralizationEvents.sol): `CollateralPledged`, `CollateralReleased`, `RecordReduced`, `RecordRecredited`, `RecordDebited`, `SeizureSettled`, `SeizureReconciled`, `PendingSettled`, `CounterSaturated`.
- User calls: none directly; users reach it through the AaveAdapter (`pledge`, `withdraw`, `removeLiquidity`, `recredit`, `collectFees`, `releaseZeroCredit`).

## Spec

- [2.3 Collateralization](../../../../spec/02-contracts/03-collateralization.md): `REQ-VAULT-007`–`REQ-VAULT-019` (pledge), `REQ-VAULT-046`–`REQ-VAULT-063` (seizure), `REQ-VAULT-137`–`REQ-VAULT-146` (pending), `REQ-COLL-014`–`REQ-COLL-017`, `REQ-COLL-038`–`REQ-COLL-040`, `SPEC-BACK-004`–`SPEC-BACK-009`, `SPEC-BACK-011`–`SPEC-BACK-014`.
- Flows: [3.1](../../../../spec/03-operations/01-deposit.md) `DEP-012`, [3.4](../../../../spec/03-operations/04-withdraw.md) `WDR-025`–`WDR-028`, [3.5](../../../../spec/03-operations/05-liquidation.md) `LIQ-020`–`LIQ-024`, `LIQ-057`.
