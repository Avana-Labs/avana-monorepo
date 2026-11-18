Function links point to the interface that declares each function.

# LPVault lifecycle

The LPVault is the immutable custodian of one AMM protocol's positions on one chain: it binds each market to its pool and exact shape, holds pledged positions, removes exactly the units Collateralization names, and pays fees and principal only to the depositor of record or LPVaultSwap. `ILPVault` extends [`IAmmIntegration`](../../amm/IAmmIntegration.sol) and [`IAmmIntegrationHooks`](../../amm/IAmmIntegrationHooks.sol).

```mermaid
stateDiagram-v2
  state "Held by its owner" as Wallet
  state "In custody, depositor of record" as Custody
  state "Stray, held outside a pledge" as Stray
  [*] --> Wallet
  Wallet --> Custody: receivePosition(marketId, owner, key) by Collateralization
  Custody --> Custody: collectFees(key, depositor), fees to the depositor
  Custody --> Custody: releaseToDepositor(key, units, minAmounts), principal to the depositor
  Custody --> Custody: unwind(key, units, minAmounts, LPVaultSwap), principal to LPVaultSwap
  Custody --> Wallet: returnPosition(key), position and its fees to the depositor
  Wallet --> Stray: sent outside a pledge, onERC721Received records it
  Stray --> Wallet: returnStray(key, recipient) by the AvanaTimelock
  note right of Custody
    every change of custody comes from Collateralization
    while a Lock member holds the Lock
  end note
```

## Walkthrough

Setup (Base market 3, Aerodrome Slipstream USDC/USDT, tick spacing 1, exact range `[−887,272, 887,272]`, from 3.1 `DEP-029`). Every state-changing call except `bindMarket` and `returnStray` comes from Collateralization while the Lock is held.

1. **MarketRegistry → [`bindMarket`](../../amm/IAmmIntegration.sol#L30)** inside `listCollateralMarket`: stores pool, shape and tokens `[USDC, USDT]` for market 3, once. Event: [`MarketBound`](ILPVaultEvents.sol#L15). Errors: [`NotMarketRegistry`](ILPVaultErrors.sol#L14), [`MarketBinding`](ILPVaultErrors.sol#L17), [`InvalidPool`](ILPVaultErrors.sol#L20), [`InvalidShape`](ILPVaultErrors.sol#L23).
2. **RiskModule `previewPledge` (and the app directly) → [`validatePosition`](../../amm/IAmmIntegration.sol#L71)** before Carol signs: checks owner, pool, exact ticks, gauge staking and returns 10,000,000,000 units without moving anything.
3. **Collateralization → [`checkReadSafe`](../../amm/IAmmIntegrationHooks.sol#L12), then [`receivePosition`](../../amm/IAmmIntegration.sol#L47)`(3, Carol, key1)`.** Pulls the NFT from Carol (she approved the LPVault on the NFPM), re-reads units after custody and records Carol as depositor. Event: [`PositionReceived`](ILPVaultEvents.sol#L17). Errors: [`PoolLocked`](ILPVaultErrors.sol#L32), [`NotTokenOwner`](ILPVaultErrors.sol#L35), [`PoolMismatch`](ILPVaultErrors.sol#L25), [`RangeMismatch`](ILPVaultErrors.sol#L30) (a `[−10, 10]` range would be credited about 2,000 times its value), [`PositionEncumbered`](ILPVaultErrors.sol#L38).
4. **Pricing:** the LPOracle computes the composition with its own pricing module on every price evaluation, without calling the LPVault (its [`composition`](../../amm/IAmmIntegration.sol#L83) view is called by no Avana contract): 1 whole vault token holds 1 USDC + 1 USDT at the oracle price vector, so $2.00. **RiskModule → [`riskStatus`](../../amm/IAmmIntegration.sol#L118)** for the pool-share and depth checks (Avana holds 2.05% of the pool after Carol's pledge).
5. **Collateralization → [`collectFees`](../../amm/IAmmIntegration.sol#L106)`(key1, Carol)`.** Calls the NFPM's `collect` with Carol as recipient: 16.50 USDC and 15.95 USDT; liquidity unchanged. Event: [`FeesCollected`](ILPVaultEvents.sol#L30). Errors: [`NotDepositor`](ILPVaultErrors.sol#L44), [`FeesRolledIn`](ILPVaultErrors.sol#L62) for AMMs that compound fees.
6. **Collateralization → [`releaseToDepositor`](../../amm/IAmmIntegration.sol#L96)`(key1, 2,000,000,000, [1,990e6, 1,990e6])`** for a partial removal: `decreaseLiquidity` then `collect` capped at that principal, about 2,000 USDC + 2,000 USDT to Carol. Event: [`UnitsReleased`](ILPVaultEvents.sol#L28). Errors: [`BelowMinimum`](ILPVaultErrors.sol#L59), [`ZeroUnits`](ILPVaultErrors.sol#L40).
7. **Collateralization → [`unwind`](../../amm/IAmmIntegration.sol#L92)`(key, 1,020,000,000, [0, 0], LPVaultSwap)`** in Carol's liquidation (3.5 `LIQ-089`): reads Slipstream's own `slot0()` layout for the lock check, removes exactly 1,020 vault tokens of liquidity and sends about 1,020 USDC + 1,020 USDT to LPVaultSwap; owed fees stay with the position for Carol. Event: [`UnitsUnwound`](ILPVaultEvents.sol#L25). Error: [`NotInCustody`](ILPVaultErrors.sol#L42).
8. **Collateralization → [`topUpPosition`](../../amm/IAmmIntegration.sol#L62)** for fungible-share AMMs only; NFT integrations revert [`TopUpNotSupported`](ILPVaultErrors.sol#L71) and take units through the NFPM's `increaseLiquidity` instead.
9. **Collateralization → [`returnPosition`](../../amm/IAmmIntegration.sol#L52)`(keyB)`** when Carol withdraws: the NFT goes back to Carol with every fee it accrued. Event: [`PositionReturned`](ILPVaultEvents.sol#L22).
10. **AvanaTimelock → [`returnStray`](ILPVault.sol#L17)** for an NFT sent to the LPVault outside a pledge (recorded by `onERC721Received` as [`StrayReceived`](ILPVaultEvents.sol#L33)); normal delay. Event: [`StrayReturned`](ILPVaultEvents.sol#L36). Errors: [`NotTimelock`](ILPVaultErrors.sol#L55), [`NotStray`](ILPVaultErrors.sol#L47).

The Uniswap v4 LPVault runs the same steps through the v4 PositionManager ([Uniswap v4 lifecycle](../../amm/uniswap-v4/LIFECYCLE.md)). Steps 5 to 7 are each one `modifyLiquidities` batch that pays the fees to the depositor before any principal moves, because a v4 decrease pays both in one delta. A native ETH leg arrives as WETH. An account holds at most 8 open records in a v4 market (`REQ-AMM-V4-012`), against 16 for Uniswap v3 and Slipstream.

## What the UI reads and calls

- Lens: [`getRecords`](../../lens/lens/ILensAccount.sol#L29), [`checkRecordBacking`](../../lens/lens/ILensMarket.sol#L21) (custody and live liquidity per record); direct views [`validatePosition`](../../amm/IAmmIntegration.sol#L71), [`isInCustody`](ILPVault.sol#L24), [`depositorOf`](../../amm/IAmmIntegration.sol#L121), [`unitsOf`](../../amm/IAmmIntegration.sol#L133) (all revert `Locked` while the Lock is held).
- Events to index: [ILPVaultEvents.sol](ILPVaultEvents.sol): `PositionReceived`, `PositionReturned`, `UnitsUnwound`, `UnitsReleased`, `FeesCollected`, `StrayReceived`, `StrayReturned`, `MarketBound`.
- User calls: none; the depositor approves the LPVault on the NFPM before `AaveAdapter.pledge`.

## Spec

- [2.2 LP Vault](../../../../docs/spec/02-contracts/02-lp-vault.md): `REQ-VAULT-010`, `REQ-VAULT-031`, `REQ-VAULT-064`–`REQ-VAULT-066`, `REQ-AMM-CORE-007`, `REQ-AMM-CORE-011`, `SPEC-BACK-008`.
- [2.19 AMM Integration Interface](../../../../docs/spec/02-contracts/19-amm-integration-interface.md), [2.20 Uniswap v3](../../../../docs/spec/02-contracts/20-uniswap-v3-integration.md), [2.23 Uniswap v4](../../../../docs/spec/02-contracts/23-uniswap-v4-integration.md), [2.21 Aerodrome Slipstream](../../../../docs/spec/02-contracts/21-aerodrome-slipstream-integration.md).
