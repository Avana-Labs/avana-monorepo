Implementation pending: links point to interfaces; update to implementation functions once the hand-written contracts exist.

# LPVault lifecycle

The LPVault is the immutable custodian of one AMM protocol's positions on one chain: it binds each market to its pool and exact shape, holds pledged positions, removes exactly the units Collateralization names, and pays fees and principal only to the depositor of record or LPVaultSwap. `ILPVault` extends [`IAmmIntegration`](../../amm/IAmmIntegration.sol) and [`IAmmIntegrationHooks`](../../amm/IAmmIntegrationHooks.sol).

## Walkthrough

Setup (Base market 3, Aerodrome Slipstream USDC/USDT, tick spacing 1, exact range `[−887,272, 887,272]`, from 3.1 `DEP-029`). Every state-changing call except `bindMarket` and `returnStray` comes from Collateralization while the Lock is held.

1. **MarketRegistry → [`bindMarket`](../../amm/IAmmIntegration.sol#L58)** inside `listCollateralMarket`: stores pool, shape and tokens `[USDC, USDT]` for market 3, once. Event: [`MarketBound`](ILPVaultEvents.sol#L21). Errors: [`NotMarketRegistry`](ILPVaultErrors.sol#L20), [`MarketBinding`](ILPVaultErrors.sol#L25), [`InvalidPool`](ILPVaultErrors.sol#L30), [`InvalidShape`](ILPVaultErrors.sol#L35).
2. **Lens / app → [`validatePosition`](../../amm/IAmmIntegration.sol#L134)** before Carol signs: checks owner, pool, exact ticks, gauge staking and returns 10,000,000,000 units without moving anything.
3. **Collateralization → [`checkReadSafe`](../../amm/IAmmIntegrationHooks.sol#L17), then [`receivePosition`](../../amm/IAmmIntegration.sol#L88)`(3, Carol, key1)`.** Pulls the NFT from Carol (she approved the LPVault on the NFPM), re-reads units after custody and records Carol as depositor. Event: [`PositionReceived`](ILPVaultEvents.sol#L25). Errors: [`PoolLocked`](ILPVaultErrors.sol#L52), [`NotTokenOwner`](ILPVaultErrors.sol#L56), [`PoolMismatch`](ILPVaultErrors.sol#L39), [`RangeMismatch`](ILPVaultErrors.sol#L47) (a `[−10, 10]` range would be credited about 2,000 times its value), [`PositionEncumbered`](ILPVaultErrors.sol#L60).
4. **LPOracle → [`composition`](../../amm/IAmmIntegration.sol#L159)** on every price evaluation: 1 whole vault token holds 1 USDC + 1 USDT at the oracle price vector, so $2.00. **RiskModule → [`riskStatus`](../../amm/IAmmIntegration.sol#L227)** for the pool-share and depth checks (Avana holds 2.05% of the pool after Carol's pledge).
5. **Collateralization → [`collectFees`](../../amm/IAmmIntegration.sol#L207)`(key1, Carol)`.** Calls the NFPM's `collect` with Carol as recipient: 16.50 USDC and 15.95 USDT; liquidity unchanged. Event: [`FeesCollected`](ILPVaultEvents.sol#L43). Errors: [`NotDepositor`](ILPVaultErrors.sol#L72), [`FeesRolledIn`](ILPVaultErrors.sol#L105) for AMMs that compound fees.
6. **Collateralization → [`releaseToDepositor`](../../amm/IAmmIntegration.sol#L191)`(key1, 2,000,000,000, [1,990e6, 1,990e6])`** for a partial removal: `decreaseLiquidity` then `collect` capped at that principal, about 2,000 USDC + 2,000 USDT to Carol. Event: [`UnitsReleased`](ILPVaultEvents.sol#L39). Errors: [`BelowMinimum`](ILPVaultErrors.sol#L101), [`ZeroUnits`](ILPVaultErrors.sol#L64).
7. **Collateralization → [`unwind`](../../amm/IAmmIntegration.sol#L179)`(key, 1,020,000,000, [0, 0], LPVaultSwap)`** in Carol's liquidation (3.5 `LIQ-089`): reads Slipstream's own `slot0()` layout for the lock check, removes exactly 1,020 vault tokens of liquidity and sends about 1,020 USDC + 1,020 USDT to LPVaultSwap; owed fees stay with the position for Carol. Event: [`UnitsUnwound`](ILPVaultEvents.sol#L35). Error: [`NotInCustody`](ILPVaultErrors.sol#L68).
8. **Collateralization → [`topUpPosition`](../../amm/IAmmIntegration.sol#L114)** for fungible-share AMMs only; NFT integrations revert [`TopUpNotSupported`](ILPVaultErrors.sol#L117) and take units through the NFPM's `increaseLiquidity` instead.
9. **Collateralization → [`returnPosition`](../../amm/IAmmIntegration.sol#L100)`(keyB)`** when Carol withdraws: the NFT goes back to Carol with every fee it accrued. Event: [`PositionReturned`](ILPVaultEvents.sol#L31).
10. **AvanaTimelock → [`returnStray`](ILPVault.sol#L39)** for an NFT sent to the LPVault outside a pledge (recorded by `onERC721Received` as [`StrayReceived`](ILPVaultEvents.sol#L47)); normal delay. Event: [`StrayReturned`](ILPVaultEvents.sol#L51). Errors: [`NotTimelock`](ILPVaultErrors.sol#L88), [`NotStray`](ILPVaultErrors.sol#L76).

## What the UI reads and calls

- Lens: [`getRecords`](../../lens/lens/ILensAccount.sol#L45), [`checkRecordBacking`](../../lens/lens/ILensMarket.sol#L31) (custody and live liquidity per record); direct views [`validatePosition`](../../amm/IAmmIntegration.sol#L134), [`isInCustody`](ILPVault.sol#L47), [`depositorOf`](../../amm/IAmmIntegration.sol#L235), [`unitsOf`](../../amm/IAmmIntegration.sol#L249) (all revert `Locked` while the Lock is held).
- Events to index: [ILPVaultEvents.sol](ILPVaultEvents.sol): `PositionReceived`, `PositionReturned`, `UnitsUnwound`, `UnitsReleased`, `FeesCollected`, `StrayReceived`, `StrayReturned`, `MarketBound`.
- User calls: none; the depositor approves the LPVault on the NFPM before `AaveAdapter.pledge`.

## Spec

- [2.2 LP Vault](../../../../spec/02-contracts/02-lp-vault.md): `REQ-VAULT-010`, `REQ-VAULT-031`, `REQ-VAULT-064`–`REQ-VAULT-066`, `REQ-AMM-CORE-007`, `REQ-AMM-CORE-011`, `SPEC-BACK-008`.
- [2.19 AMM Integration Interface](../../../../spec/02-contracts/19-amm-integration-interface.md), [2.20 Uniswap v3](../../../../spec/02-contracts/20-uniswap-v3-integration.md), [2.21 Aerodrome Slipstream](../../../../spec/02-contracts/21-aerodrome-slipstream-integration.md).
