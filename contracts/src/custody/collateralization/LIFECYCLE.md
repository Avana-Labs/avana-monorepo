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

1. **AaveAdapter → [`pledge`](CollateralizationPledge.sol#L179)`(Carol, P, VT, key1, false)`.** Checks the vault token, `isValidProxy(P)`, no open record for the key, fewer than 16 records, the pool lock (`checkReadSafe`); calls LPVault [`receivePosition`](../lp-vault/ILPVault.sol#L72) (units 10,000,000,000), LPOracle [`poke`](../../oracle/lp-oracle/ILPOracle.sol#L56) and RiskModule [`checkPledge`](../../policy/risk-module/IRiskModule.sol#L31), which returns a $20,000 charge with `sliceUsd = 0`. Writes record 1, inserts it largest-first, adds $20,000 to `Regular` and the USDC and USDT counters, and returns `credited = 10,000,000,000`. Event: [`CollateralPledged`](ICollateralizationBase.sol#L93). Errors: [`InvalidDepositor`](ICollateralizationBase.sol#L71), [`InvalidVaultToken`](ICollateralizationBase.sol#L19), [`UnknownProxy`](ICollateralizationBase.sol#L21), [`AlreadyPledged`](ICollateralizationBase.sol#L29), [`TooManyRecords`](ICollateralizationBase.sol#L23), [`InvalidCharge`](ICollateralizationBase.sol#L35); RiskModule errors pass through unchanged.
2. **AaveAdapter → [`pledge`](CollateralizationPledge.sol#L179) of `keyB` (2,500,000,000 units, $5,000).** Record 2 of 16; the account's credited units are 12,500,000,000. A borrow in between only set the indebted mark through [`markIndebted`](CollateralizationSeizure.sol); it booked no charge.
3. **AaveAdapter → [`recredit`](CollateralizationPledge.sol#L250)** (Ethereum example of 3.1): after `increaseLiquidity`, `added = live − credited = 27,500,000,000 − 25,000,000,000 = 2,500,000,000`; charge $5,000; the record's basis becomes 27,500,000,000 units and $55,000 and it keeps its list position. Event: [`RecordRecredited`](ICollateralizationBase.sol#L154). Errors: [`NothingToRecredit`](ICollateralizationBase.sol#L81), [`NotDepositor`](ICollateralizationBase.sol#L44).
4. **AaveAdapter → [`release`](CollateralizationPledge.sol#L31)`(P, VT, keyB, 2,500,000,000)`** after the Adapter burned the units. Reconciles first against the proxy's supplied shares, requires `units == credited`, releases the $5,000 charge, closes the record, then calls LPVault [`returnPosition`](../lp-vault/ILPVault.sol#L76). Event: [`CollateralReleased`](ICollateralizationBase.sol#L107). Errors: [`RecordNotFound`](ICollateralizationBase.sol#L37), [`NotRecordProxy`](ICollateralizationBase.sol#L39), [`UnitsMismatch`](ICollateralizationBase.sol#L42).
5. **AaveAdapter → [`releasePartial`](CollateralizationPledge.sol#L46)`(P, VT, key1, 2,000,000,000, [1,990e6, 1,990e6])`.** Requires `0 < units < credited`; debits in place to 8,000,000,000 units, releases `$20,000 × 2 / 10 = $4,000`, then calls LPVault [`releaseToDepositor`](../lp-vault/ILPVault.sol#L120), which pays about 2,000 USDC + 2,000 USDT to Carol. Event: [`RecordReduced`](ICollateralizationBase.sol#L151). Errors: [`PartialRemovalTooLarge`](ICollateralizationBase.sol#L78), [`BelowMinimum`](ICollateralizationBase.sol#L27).
6. **AaveAdapter → [`collectFees`](CollateralizationPledge.sol#L112)`(Carol, VT, key1)`.** The LPVault's [`collectFees`](../lp-vault/ILPVault.sol#L132) pays 16.50 USDC and 15.95 USDT to Carol; no unit or counter changes. Error: [`NotDepositor`](ICollateralizationBase.sol#L44).
7. **LPVaultSwap → [`beginSeizure`](CollateralizationSeizure.sol#L106)`(Q, VT)`** before `Spoke.liquidationCall` on Bob's account (3.5 `LIQ-069`). Stores `sharesBefore` and `supplyBefore` in transient storage. Errors: [`SharesNotEqualAssets`](ICollateralizationBase.sol#L48), [`SeizureActive`](ICollateralizationBase.sol#L50).
8. **LPVaultSwap → [`settleSeizure`](CollateralizationSeizure.sol#L121)`(Q, VT, 975e18, minAmounts)`** after the AaveAdapter's `burnSeized`. Checks supply drop = 975e18 and share drop ≥ 975e18 (with Aave's `liquidationFee` at 0 the two are equal; a fee's extra share drop is reconciled into the pending balance, `REQ-VAULT-176`), reconciles, debits 975 vault tokens from the head of the largest-first list, releases exposure, and calls LPVault [`unwind`](../lp-vault/ILPVault.sol#L116) for each debited record: about 1,030 USDC + 1,010 USDT reach LPVaultSwap; fees stay with the position. Events: [`RecordDebited`](ICollateralizationBase.sol#L119), [`SeizureSettled`](ICollateralizationBase.sol#L131), [`SeizureReconciled`](ICollateralizationBase.sol#L136) when a shortfall is reconciled. Errors: [`SeizureMismatch`](ICollateralizationBase.sol#L53), [`DebitMismatch`](ICollateralizationBase.sol#L56), [`SupplyDropMismatch`](ICollateralizationBase.sol#L60), [`InsufficientCredit`](ICollateralizationBase.sol#L63), [`BelowMinimum`](ICollateralizationBase.sol#L27).
9. **Pending balance.** If a seizure is never settled, the next reconcile (3.4 worked example) moves the 12,000,000,000 missing units of `key7` into `pending[VT] = {12,000,000,000; [11,998.500187 USDC, 12,001.5 USDT]}`. Anyone then calls LPVaultSwap `settlePending`, which calls [`settlePending`](CollateralizationSeizure.sol#L30)`(VT, units)`; 300 of 1,000 pending units pay `[180, 120]` of `[600, 401]`. Event: [`PendingSettled`](ICollateralizationBase.sol#L139). Errors: [`PendingExceeded`](ICollateralizationBase.sol#L66), [`SupplyDropMismatch`](ICollateralizationBase.sol#L60).
10. **AaveAdapter → [`releaseForDeleverage`](CollateralizationPledge.sol#L71)** inside a repay with collateral: debits 1,500,000,000 units of record #31 and unwinds them to LPVaultSwap; closes the record when credited reaches 0. Then [`markDebtFree`](CollateralizationSeizure.sol#L77) clears the mark once Aave reports `borrowCount == 0` (a read that fails with under 50,000 gas left reverts [`InsufficientGas`](ICollateralizationBase.sol#L75); one that fails with more keeps the mark, and anyone clears it later through the AaveAdapter's [`refreshDebtMark`](../../policy/aave-adapter/IAaveAdapter.sol#L152)); [`releaseZeroCredit`](CollateralizationPledge.sol#L94) returns a record a seizure took to 0 (error [`RecordHasCredit`](ICollateralizationBase.sol#L46) otherwise).

## What the UI reads and calls

- Lens: [`getRecords`](../../lens/lens/ILensAccount.sol#L28), [`getAccount`](../../lens/lens/ILensAccount.sol#L19), [`checkBacking`](../../lens/lens/ILensMarket.sol#L14), [`checkRecordBacking`](../../lens/lens/ILensMarket.sol#L20), [`getPendingSettlement`](../../lens/lens/ILensMarket.sol#L27), [`getCapHeadroom`](../../lens/lens/ILensMarket.sol#L32); direct views [`previewRelease`](CollateralizationViews.sol#L129) (the `units` argument of `withdraw`), [`previewRecredit`](CollateralizationViews.sol#L139), [`getAccountRecords`](CollateralizationViews.sol#L40), [`getPending`](CollateralizationViews.sol#L85).
- Events to index: [ICollateralizationBase.sol](ICollateralizationBase.sol): `CollateralPledged`, `CollateralReleased`, `RecordReduced`, `RecordRecredited`, `RecordDebited`, `SeizureSettled`, `SeizureReconciled`, `PendingSettled`, `CounterSaturated`.
- User calls: none directly; users reach it through the AaveAdapter (`pledge`, `withdraw`, `removeLiquidity`, `recredit`, `collectFees`, `releaseZeroCredit`).

## Spec

- [2.3 Collateralization](../../../../docs/spec/02-contracts/03-collateralization.md): `REQ-VAULT-007`–`REQ-VAULT-019` (pledge), `REQ-VAULT-046`–`REQ-VAULT-063` (seizure), `REQ-VAULT-137`–`REQ-VAULT-146` (pending), `REQ-COLL-014`–`REQ-COLL-017`, `REQ-COLL-038`–`REQ-COLL-040`, `SPEC-BACK-004`–`SPEC-BACK-009`, `SPEC-BACK-011`–`SPEC-BACK-014`.
- Flows: [3.1](../../../../docs/spec/03-operations/01-deposit.md) `DEP-012`, [3.4](../../../../docs/spec/03-operations/04-withdraw.md) `WDR-025`–`WDR-028`, [3.5](../../../../docs/spec/03-operations/05-liquidation.md) `LIQ-020`–`LIQ-024`, `LIQ-057`.
