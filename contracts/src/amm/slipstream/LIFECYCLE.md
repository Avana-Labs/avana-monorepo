# Aerodrome Slipstream LPVault lifecycle

The Aerodrome Slipstream LPVault on Base custodies unstaked Slipstream positions in exact-range markets across the four position-manager and factory generations it accepts (Initial, Gauge Caps, Gauges V3, Aero); the position key carries the generation, and pools are looked up by tick spacing. Custody, removal, fees and pricing are the shared concentrated-liquidity base ([ClLPVaultCustody](../concentrated-liquidity/ClLPVaultCustody.sol), [ClLPVaultMarkets](../concentrated-liquidity/ClLPVaultMarkets.sol)); [SlipstreamIntegration](SlipstreamIntegration.sol) supplies the Slipstream layouts, the generation allowlist and the gauge check.

## Walkthrough

Setup (Base market 3, USDC/USDT, tick spacing 1 on the Gauges V3 generation (index 2), exact range `[−887,272, 887,272]`, vault token 6 decimals, $2.00 per whole token, from 3.1 `DEP-029`, 3.7 `FEE-009`, 3.5 `LIQ-089`). Carol holds an unstaked NFT with `L = 10,000,000,000`.

1. **MarketRegistry → [`bindMarket`](../concentrated-liquidity/ClLPVaultMarkets.sol#L38)`(3, pool, 0, shape, abi.encode(2, 1e8, 1e8))`.** [`_validatePool`](SlipstreamIntegration.sol#L218) checks the pool is the EIP-1167 clone of generation 2's `poolImplementation()` before calling it, then `pool.factory()`, `pool.nft()`, the enabled spacing (at most 6,931, so `maxLiquidityPerTick ≤ 2^120 − 1`) and `CLFactory.getPool(USDC, USDT, 1) == pool`; the fee is not stored (`fee = 0`).
2. **App → [`positionKeyOf`](SlipstreamIntegration.sol#L124)`(2, tokenId)`** returns `bytes32((2 << 248) | tokenId)`; [`isStaked`](SlipstreamIntegration.sol#L134)`(3, tokenId)` is false (the NFT is not held by `pool.gauge()`).
3. **Carol approves the LPVault on the generation-2 NPM; Collateralization → [`receivePosition`](../concentrated-liquidity/ClLPVaultCustody.sol#L31)`(3, Carol, key)`.** The NPM comes from the key ([`_positionManager`](SlipstreamIntegration.sol#L153)); the owner check, the gauge check ([`_isEncumbered`](SlipstreamIntegration.sol#L245)), the pool derived by tick spacing ([`_readPosition`](SlipstreamIntegration.sol#L185)) and the exact range pass; the NFT moves with `transferFrom`; units 10,000,000,000 ($20,000). The same token ID on another generation reverts `PoolMismatch`, since the key's manager is not the market's pinned one, whatever that generation's factory returns; a gauge-staked NFT reverts `NotTokenOwner` for its staker and `PositionEncumbered` when the gauge is named as owner.
4. **[`checkReadSafe`](../concentrated-liquidity/ClLPVaultMarkets.sol#L189)** reads Slipstream's six-field `slot0()` ([`_slot0`](SlipstreamIntegration.sol#L200)), only for the lock flag, never for a price.
5. **Collateralization → [`collectFees`](../concentrated-liquidity/ClLPVaultCustody.sol#L129)`(key, Carol)`** inside the AaveAdapter's Lock session (LPVaultSwap's is refused with `LockNotHeld`), during a sequencer outage (submitted through L1 forced inclusion): the NPM's `collect` pays 16.50 USDC and 15.95 USDT, net of the pool's `unstakedFee` share. Units and health factor (1.2420) are unchanged; a custodied position earns no AERO.
6. **Collateralization → [`returnPosition`](../concentrated-liquidity/ClLPVaultCustody.sol#L67)`(keyB)`** when Carol withdraws her 2,500,000,000-unit top-up.
7. **Liquidation (Carol owes 20,000 USDC, `LIQ-089`) → [`unwind`](../concentrated-liquidity/ClLPVaultCustody.sol#L96)`(key, 1,020,000,000, [0, 0], LPVaultSwap)`:** about 1,020 USDC + 1,020 USDT to LPVaultSwap; recovery 2,038.5 USDC against the floor 2,018.60.
8. **Oracle:** [`oracleSqrtPrice`](../concentrated-liquidity/ClLPVaultMarkets.sol#L139) and [`composition`](../concentrated-liquidity/ClLPVaultMarkets.sol#L123) work as for Uniswap v3; [`consistencyDeviation`](../concentrated-liquidity/ClLPVaultMarkets.sol#L200) needs 901 observations for a 1,800 s window at 2 s blocks; [`tokenIdOf`](../concentrated-liquidity/ClLPVaultMarkets.sol#L111) drops the generation byte.

## What the UI reads and calls

- Lens: [`getRecords`](../../lens/lens/ILensAccount.sol#L45), [`checkRecordBacking`](../../lens/lens/ILensMarket.sol#L31); direct [`positionKeyOf`](SlipstreamIntegration.sol#L124), [`isStaked`](SlipstreamIntegration.sol#L134), [`generation`](SlipstreamIntegration.sol#L115), [`validatePosition`](../concentrated-liquidity/ClLPVaultCustody.sol#L52).
- Events to index: LPVault events ([ILPVaultEvents.sol](../../custody/lp-vault/ILPVaultEvents.sol)); Slipstream NPM `DecreaseLiquidity` and `Collect`.
- User calls: the depositor unstakes the NFT from the gauge and approves the LPVault on the NPM of its generation before AaveAdapter `pledge`.

## Spec

- [2.21 Aerodrome Slipstream Integration](../../../../spec/02-contracts/21-aerodrome-slipstream-integration.md): `REQ-AMM-SLIP-001`–`REQ-AMM-SLIP-020`, `SPEC-AMM-SLIP-001` (pool identity), key encoding `bytes32((uint256(generation) << 248) | tokenId)`.
- Flows: [3.1](../../../../spec/03-operations/01-deposit.md) `DEP-029`, [3.5](../../../../spec/03-operations/05-liquidation.md) `LIQ-089`, [3.7](../../../../spec/03-operations/07-collect-fees.md) `FEE-009`.
