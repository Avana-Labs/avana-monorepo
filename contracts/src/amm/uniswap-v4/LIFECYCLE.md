# Uniswap v4 LPVault lifecycle

The contract is [`UniswapV4Integration`](UniswapV4Integration.sol) on the shared concentrated-liquidity base ([`ClLPVaultCustody`](../concentrated-liquidity/ClLPVaultCustody.sol), [`ClLPVaultMarkets`](../concentrated-liquidity/ClLPVaultMarkets.sol), [`ClPriceMath`](../concentrated-liquidity/ClPriceMath.sol)), which the Uniswap v3 and Slipstream LPVaults also use. [`UniswapV4State`](UniswapV4State.sol) reads the PoolManager's storage (`extsload`) and its unlock flag (`exttload`).

The Uniswap v4 LPVault on Ethereum custodies PositionManager positions of hookless v4 pools in exact-range markets. A market is keyed by its `PoolId` (`keccak256(abi.encode(PoolKey))`, `pool = address(0)`); `positionKey = bytes32(tokenId)` and a position's units are its liquidity `L`, read from the PoolManager, not from the PositionManager. Every removal and fee collection is one `PositionManager.modifyLiquidities` batch. A native ETH leg reaches its recipient as WETH, so no Avana contract holds ETH. Each pool has a *reference pool*, the same pair's Uniswap v3 pool, which supplies the time-weighted price and the depth that v4 does not keep.

```mermaid
sequenceDiagram
  autonumber
  participant MR as MarketRegistry
  participant CO as Collateralization
  participant V as Uniswap v4 LPVault
  participant PO as PositionManager
  participant PM as PoolManager
  participant R as v3 WETH/USDC pool (reference)
  MR->>V: bindMarket(1, address(0), poolId, shape, abi.encode(key, R, p0, p1))
  V->>PM: extsload slot0 (pool initialized)
  V->>R: fee(), token0(), token1(); factory.getPool must equal R
  CO->>V: checkReadSafe(1)
  V->>PM: exttload IS_UNLOCKED (must be locked)
  CO->>V: receivePosition(1, W, bytes32(42))
  V->>PO: ownerOf(42), getPoolAndPositionInfo(42)
  V->>PM: extsload position liquidity (owner PositionManager, salt bytes32(42))
  V->>PO: transferFrom(W, LPVault, 42)
  V-->>CO: units = L = 150,000,000,000,000
  CO->>V: collectFees(bytes32(42), W)
  V->>PO: modifyLiquidities: DECREASE_LIQUIDITY(42, 0), TAKE ETH, WRAP, TAKE USDC, SWEEP WETH to W
  CO->>V: unwind(key, 37,500,000,000,000, [0, 0], LPVaultSwap)
  V->>PO: modifyLiquidities: fees to W first, then DECREASE_LIQUIDITY and the take to LPVaultSwap
  CO->>V: returnPosition(bytes32(42))
  V->>PO: transferFrom(LPVault, W, 42)
```

## Walkthrough

Setup (Ethereum market 1, native ETH/USDC 0.05% hookless pool, `tickSpacing = 10`, full usable range `[−887,270, 887,270]`, reference pool the Uniswap v3 WETH/USDC 0.05% pool, ETH at $2,000 and USDC at $1). Wallet `W` holds PositionManager NFT #42 with `L = 150,000,000,000,000`. Figures are illustrative.

1. **MarketRegistry → [`bindMarket`](UniswapV4Integration.sol#L137)`(1, address(0), poolId, shape, abi.encode(key, ref, price0, price1))`.** The LPVault checks that `poolId` is the hash of the PoolKey and that the hook is allowed (only `address(0)`, else `HookNotAllowed`; `REQ-AMM-V4-001`). Through [`_poolConfig`](UniswapV4Integration.sol#L463) it then checks that the pool is initialized, that the tick spacing is between 1 and 6,931, and that the pool is not ETH/WETH. [`_supplyOk`](UniswapV4Integration.sol#L501) checks that both tokens report `totalSupply() < 2^127` (`REQ-AMM-V4-009`). [`_checkReference`](UniswapV4Integration.sol#L480) checks that the reference pool is the v3 factory's pool of the two tokens, with native ETH read as WETH (`REQ-AMM-V4-007`). The token pair is stored as `[WETH, USDC]`. [`v4Market`](UniswapV4Integration.sol#L189) returns the PoolKey and the reference pool.
2. **W approves the LPVault on the PositionManager; Collateralization → [`receivePosition`](../concentrated-liquidity/ClLPVaultCustody.sol#L22)`(1, W, bytes32(42))`.** [`_readPosition`](UniswapV4Integration.sol#L313) reads the PoolKey and ticks from `getPoolAndPositionInfo(42)`. The position belongs to the market only when the PoolKey hashes to the market's `PoolId` and the ticks equal the range. The liquidity is read from the PoolManager. [`_isEncumbered`](UniswapV4Integration.sol#L326) refuses a position with a subscriber (`SubscribedPosition`, `REQ-AMM-V4-002`) and checks the hook again. The LPVault pulls the NFT and returns 150,000,000,000,000 units. Errors: `PoolMismatch`, `RangeMismatch`, `NotTokenOwner`, `SubscribedPosition`, `HookNotAllowed`.
3. **[`checkReadSafe`](UniswapV4Integration.sol#L247)** runs before every custody change and reverts `PoolLocked` while the PoolManager is unlocked, that is, inside another contract's `unlock` callback ([`_requireReadSafe`](UniswapV4Integration.sol#L343), `REQ-AMM-V4-003`).
4. **The LPOracle prices the market with its v4 module** ([`LPOracleV4Module`](../../oracle/lp-oracle/LPOracleV4Module.sol)), using the concentrated-liquidity math of Uniswap v3 at the clamped oracle price (`SPEC-AMM-V4-001`). The vault's units hold about 3.3541 ETH and 6,708.20 USDC, worth about $13,416. [`composition`](../concentrated-liquidity/ClLPVaultMarkets.sol#L43) gives the same amounts as a view. [`consistencyDeviation`](UniswapV4Integration.sol#L255) takes the larger of two deviations from the feeds' tick: the v4 pool's `slot0` tick, and the reference pool's mean tick over the window (`SPEC-AMM-V4-002`). Above `consistencyToleranceBps`, the market is Drifting, so borrowing stops and liquidation continues.
5. **RiskModule → [`riskStatus`](UniswapV4Integration.sol#L234)**: the depth is the reference pool's harmonic-mean in-range liquidity over the window, in the market's units (`REQ-AMM-V4-008`). v4 keeps no seconds-per-liquidity accumulator, and a seized v4 position is sold through the pair's v3 routes.
6. **Collateralization → [`collectFees`](../concentrated-liquidity/ClLPVaultCustody.sol#L112)`(bytes32(42), W)`.** [`_collectAll`](UniswapV4Integration.sol#L384) computes the owed fees with unchecked fee growth (`REQ-AMM-V4-010`), then runs one batch: `DECREASE_LIQUIDITY(42, 0, 0, 0)`, then the take to W. [`_takeTo`](UniswapV4Integration.sol#L431) takes the ETH leg to the PositionManager, wraps it (`WRAP`), takes USDC to W and sweeps the WETH to W. Liquidity and credited units are unchanged. A position with no liquidity accrues no fee, and the call is skipped.
7. **Liquidation → [`unwind`](../concentrated-liquidity/ClLPVaultCustody.sol#L77)`(key, 37,500,000,000,000, [0, 0], LPVaultSwap)`.** [`_removePrincipal`](UniswapV4Integration.sol#L350) first computes the removal amounts at the pool's `slot0` with the PoolManager's rounding: about 0.8385 ETH and 1,677.05 USDC (`SPEC-AMM-V4-003`). It checks them against the minimums (`BelowMinimum`). Then it runs one batch: the zero decrease, with the fees taken to the depositor W, then the decrease of 37,500,000,000,000, with the principal taken to LPVaultSwap, where the ETH leg arrives as WETH (`REQ-AMM-V4-004`). A v4 decrease pays every accrued fee together with the principal, so taking the fees first keeps them with the depositor. [`releaseToDepositor`](../concentrated-liquidity/ClLPVaultCustody.sol#L95) runs the same batch with the depositor's minimums and the depositor as recipient.
8. **W → AaveAdapter `withdraw`; Collateralization → [`returnPosition`](../concentrated-liquidity/ClLPVaultCustody.sol#L54)`(bytes32(42))`** sends NFT #42 back to W with its remaining liquidity.
9. **NFT sent outside a pledge:** [`onERC721Received`](../concentrated-liquidity/ClLPVaultCustody.sol#L142) records it as stray only when it comes from the PositionManager, else `UnsupportedNft`. The AvanaTimelock returns it with [`returnStray`](../concentrated-liquidity/ClLPVaultCustody.sol#L128).
10. **Record cap:** [`maxRecordsPerAccountMarket`](UniswapV4Integration.sol#L211) is 8 (`REQ-AMM-V4-012`), so a 9th pledge of one account in one v4 market reverts `TooManyRecords(8)`. A v4 removal costs about 253,000 gas per record in a whole-account seizure, about 279,000 with fees owed in both tokens, and about 344,000 when the depositor cannot receive a fee token and the fallback batch runs; 8 such records with 4 debts measure 7,141,742, within the 7.5M liquidation budget.

## What the UI reads and calls

- Lens: [`getRecords`](../../lens/lens/ILensAccount.sol#L34), [`checkRecordBacking`](../../lens/lens/ILensMarket.sol#L21), [`getPositionFees`](../../lens/lens/ILensFees.sol#L14) (uncollected v4 fees, computed as the PoolManager would credit them). Direct views: [`validatePosition`](../concentrated-liquidity/ClLPVaultCustody.sol#L42), [`tokenIdOf`](../concentrated-liquidity/ClLPVaultMarkets.sol#L35), [`v4Market`](UniswapV4Integration.sol#L189).
- Events to index: LPVault `MarketBound`, `PositionReceived`, `PositionReturned`, `UnitsUnwound`, `UnitsReleased`, `FeesCollected`, `StrayReceived`, `StrayReturned` ([ILPVaultEvents.sol](../../custody/lp-vault/ILPVaultEvents.sol)); the PoolManager's `ModifyLiquidity`.
- User calls: the depositor mints through the PositionManager (with Permit2 approvals for ERC-20 legs), approves the LPVault on the PositionManager, and must not subscribe the position. A pledged v4 position cannot take more liquidity: the v4 PositionManager adds liquidity only for the NFT's owner or an approved address, and the LPVault owns it and approves no one, so more collateral means a new position (review finding V4-02, open).

## Spec

- [2.23 Uniswap v4 Integration](../../../../docs/spec/02-contracts/23-uniswap-v4-integration.md): `REQ-AMM-V4-001`–`REQ-AMM-V4-012`, `SPEC-AMM-V4-001`–`SPEC-AMM-V4-003`.
- [2.19 AMM Integration Interface](../../../../docs/spec/02-contracts/19-amm-integration-interface.md): `REQ-AMM-CORE-020` (record cap per integration).
- Custody rules shared with every concentrated-liquidity LPVault: [2.2](../../../../docs/spec/02-contracts/02-lp-vault.md) `REQ-VAULT-155`, `REQ-VAULT-162`, `SPEC-BACK-001`, `SPEC-BACK-008`.
