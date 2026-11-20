# Event and read catalogue

Every event the indexer handles, read from the interfaces under `contracts/src/**/I*.sol`, `packages/liquidator/src/IFlashLiquidator.sol` and, for Aave V4, from the Aave ABIs built at the pinned commit (`contracts/out-aave/ISpoke.sol`, `IHub.sol`). Every handled log first writes an `event_log` row keyed `chainId + txHash + logIndex` with its block number, block hash and timestamp ([`src/lib/record.ts`](src/lib/record.ts)); the **Updates** column names the entity table it also changes. Values that change without an event are listed under [Live reads](#live-reads).

**Finality.** Each consumer reads at its own depth (services/README.md, Finality and reorgs):

| Code | Consumer | Depth |
|---|---|---|
| B | Bot runner (the LiquidationBot) | Chain head, through the [bot stream](EXPORT.md#keeper-stream) |
| M | Monitoring | Chain head; every alert is confirmed on-chain before paging |
| C | Convex | `finalized` only, through the [export](EXPORT.md) |

Indexed parameters are marked `idx`. `MarketKind`: FullRange 0, CustomRange 1.

**Sources.** Each chain has one core stack per AMM integration (LPVault, RiskModule, LiquidationModule, AaveAdapter, FlashloanRepay; `RiskModule.LP_VAULT` is immutable). Each contract kind is one Ponder source over every integration of the manifest ([`src/config/sources.ts`](src/config/sources.ts)), so a log's contract address tells its integration. None of Avana's core contracts is upgradeable.

## Markets (RiskModule)

| Event | Updates | Used by |
|---|---|---|
| `MarketListed(uint256 marketId idx, bytes32 pool idx, MarketKind kind, int24 bandLower, int24 bandUpper, uint8 unitDecimals)` | `market` (one row per market) | B C M |
| `PoolListed(bytes32 pool idx, address spoke idx, uint256 fullRange, uint256 customRange, int24 listingTick, uint16 ltvBps)` | both markets' `spoke`, `listingTick`, `ltvBps`; `amm_pool` (fee read once) or `amm_pool_id` (Uniswap v4) | B C M |
| `MarketActivated(uint256 marketId idx, address vaultToken, uint256 reserveId, address lpOracle)` | `market` (`active`, vault token, reserve, LPOracle); starts the `VaultToken` source | B C M |
| `DebtReserveSet(address spoke idx, uint256 reserveId idx, address hub, address asset, address firstLossReserve)` | `debt_reserve`; starts the `FirstLossReserve` source | C M |
| `DebtReserveRemoved(address spoke idx, uint256 reserveId idx)` | `debt_reserve.listed = false` | C M |
| `KeeperAdded(address keeper idx)`, `KeeperRemoved(address keeper idx)` | `keeper` | B M |
| `SpokeRegistered`, `SpokeWidthSet`, `CoverageRatioSet`, `FeeSet` | log | M |

Each pool listed gets two markets: **Full range** (exact full-range ticks) and **Custom range** (positions inside the band: Stable ±1 %, Correlated ±5 %, Volatile 0.345x–2.898x). Both have the same LTV, and a band is fixed for life. `MarketListed` is emitted for both markets before their `PoolListed`.

## Accounts

| Contract | Event | Updates | Used by |
|---|---|---|---|
| AaveAdapter | `AccountCreated(address wallet idx, uint256 marketId idx, address account)` | `account` (keyed under the market's Spoke) | B C M |

One account proxy per (wallet, market), with at most 16 positions. An account of a market whose `PoolListed` the indexer has not handled stops the indexer (fail closed).

## AaveAdapter actions

| Event | Updates | Used by |
|---|---|---|
| `Pledged(address wallet idx, uint256 marketId idx, bytes32 positionKey idx, uint128 credit)` | `position.wallet` | B C |
| `LiquidityAdded(address wallet idx, bytes32 positionKey idx, uint128 liquidity, uint128 credit)` | log | C |
| `Withdrawn(address wallet idx, bytes32 positionKey idx, address recipient idx, uint128 liquidity, uint256 burned)` | log | B C |
| `WithdrawAllowed(address wallet idx, bytes32 positionKey idx, address operator idx, uint128 maxLiquidity)` | log | C |
| `Borrowed(address wallet idx, uint256 marketId idx, uint256 reserveId idx, uint256 amount, address recipient)` | log | B C |
| `Repaid(address wallet idx, uint256 marketId idx, uint256 reserveId idx, uint256 amount, address payer)` | log | B C |

The Adapter routes a pledge itself (`RiskModule.routeOf`): exact full-range ticks to the Full range market, positions inside the Custom band to the Custom range market; anything else reverts `NoMarketFits`. A `Repaid` whose payer is not the wallet is a valid third-party repay. `WithdrawAllowed` opens a repay with collateral (below).

## Positions and pledges per market (LPVault)

| Event | Updates | Used by |
|---|---|---|
| `PositionPledged(bytes32 positionKey idx, address account idx, uint256 marketId idx, address from, uint128 liquidity, uint128 credit)` | `position`; `market_collateral` +1 position, + liquidity, + credit, +1 pledge | B C |
| `LiquidityAdded(bytes32 positionKey idx, address payer idx, uint128 liquidity, uint128 credit, uint256 amount0, uint256 amount1)` | `position`, `market_collateral` + liquidity, + credit | C |
| `LiquidityRemoved(bytes32 positionKey idx, address recipient idx, uint128 liquidity, uint128 credit, uint256 amount0, uint256 amount1)` | `position`, `market_collateral` − liquidity, − credit, +1 withdrawal | B C |
| `PositionReleased(bytes32 positionKey idx, address account idx, address recipient idx, uint128 liquidity, uint128 credit)` | `position.held = false`; `market_collateral` −1 position, +1 withdrawal | B C |
| `PositionUnwound(bytes32 positionKey idx, address recipient idx, uint128 liquidity, uint128 credit, uint256 amount0, uint256 amount1)` | `position`, `market_collateral` − liquidity, − credit, +1 unwind (a liquidation) | B C M |
| `MarketListed`, `FeesCollected`, `FeesHeld` | log | C |

`market_collateral` keeps a pool's Full range and Custom range markets apart. A change to a position the indexer never saw pledged stops it (fail closed).

## Vault tokens (mint and burn)

| Event | Updates | Used by |
|---|---|---|
| `Transfer(address from idx, address to idx, uint256 value)` | `vault_token_supply`: a mint (from zero) adds, a burn (to zero) subtracts | C M |
| `Approval`, `ProxyAdded(address proxy idx)` | log | M |

Vault tokens are followed from the manifest (`VaultTokenListed`) and from every `MarketActivated` (`VaultToken`); a log both deliver is counted once.

## Liquidations and repayments with collateral

| Contract | Event | Updates | Used by |
|---|---|---|---|
| LiquidationModule | `Liquidated(address account idx, uint256 marketId idx, address liquidator idx, uint256 debtReserveId, uint256 debtRepaid, uint256 seized, uint256 creditUnwound, uint256 amount0, uint256 amount1)` | `liquidation` | B C M |
| LiquidationModule | `FeePaid(address account idx, uint256 marketId idx, address recipient idx, uint256 units, uint256 fee0, uint256 fee1)` | the same transaction's `liquidation` row (fee) | C M |
| FlashLiquidator | `FlashLiquidated(address account idx, uint256 marketId idx, address asset idx, uint256 flashAmount, uint256 premium, uint256 debtRepaid, uint256 topUp, uint256 profit)` | the same transaction's `liquidation` row (flash loan, premium, top-up, profit) | B M |
| FlashloanRepay | `RepaidWithCollateral(address wallet idx, bytes32 positionKey idx, address asset idx, uint256 repaid, uint256 premium, uint128 liquidity)` | `collateral_repay` | C |

Liquidation is in kind: the liquidator receives both pool tokens. A `FeePaid` or `FlashLiquidated` without the `Liquidated` before it in the same transaction stops the indexer. Repay with collateral (partial or full) is one `allowWithdraw` to the FlashloanRepay: its log sits beside the Adapter's `WithdrawAllowed`, `Repaid` and `Withdrawn` in one transaction.

## First-Loss cover

| Event | Updates | Used by |
|---|---|---|
| `Funded(address funder idx, uint256 amount, uint256 shares, uint256 balanceAfter)` | `coverage_balance` | C M |
| `DeficitCovered(address spoke idx, address caller idx, uint256 covered, uint256 shares, uint256 balanceAfter)` | `first_loss_cover`; `coverage_balance` | C M |
| `Withdrawn(address to idx, uint256 amount, uint256 shares, uint256 balanceAfter)` | `coverage_balance` | C M |
| `SpokeAllowed`, `MinimumSet`, `BelowMinimum` | log | M |

Loss layers are followed under three sources ([`src/config/aaveSources.ts`](src/config/aaveSources.ts)): `FirstLossReserveListed` (the manifest's First-Loss Reserves and DAO deficit offsets, from their deployment), `FirstLossReserve` (every reserve a RiskModule registers with `DebtReserveSet`) and `DaoDeficitOffset` (every Spoke a manifest Hub adds). A log several deliver is recorded once under `FirstLossReserve.<Event>`.

## Governance

| Contract | Event | Updates | Used by |
|---|---|---|---|
| AccessManager | `RoleGranted`, `RoleRevoked`, `RoleLabel`, `RoleAdminChanged`, `RoleGuardianChanged`, `RoleGrantDelayChanged`, `TargetFunctionRoleUpdated`, `TargetAdminDelayUpdated`, `TargetClosed`, `OperationScheduled`, `OperationExecuted`, `OperationCanceled` | log | M |
| Aave Hub, Spoke | `Upgraded(address implementation idx)` | `implementation` | M |

## Aave V4 Spokes and Hub

Avana's `IAaveV4Spoke` declares none of the Spoke's events, so the indexer decodes them with the Aave ABIs in `packages/protocol`, built from the pinned Aave V4 commit (`premiumDelta` is `(int256, int256, uint256)`):

| Contract | Event | Updates | Used by |
|---|---|---|---|
| Spoke | `Supply`, `Withdraw` | log | B C M |
| Spoke | `Borrow(uint256 reserveId idx, address caller idx, address user idx, uint256 drawnShares, uint256 drawnAmount)` | `account_debt` + shares | B C |
| Spoke | `Repay(uint256 reserveId idx, address caller idx, address user idx, uint256 drawnShares, uint256 totalAmountRepaid, premiumDelta)` | `account_debt` − shares | B C |
| Spoke | `LiquidationCall(...)` | `account_debt` − shares | B C M |
| Spoke | `ReportDeficit(uint256 reserveId idx, address user idx, uint256 drawnShares, premiumDelta)` | `account_debt` deficit | B C M |
| Spoke | `SetUsingAsCollateral(uint256 reserveId idx, address caller idx, address user idx, bool usingAsCollateral)` | `account.usingAsCollateral` | B C |
| Spoke | `UpdateUserRiskPremium(address user idx, uint256 riskPremium)` | `account_premium` (attributed accounts) | C (the refresh list) |
| Spoke | `UpdateReserveConfig(uint256 reserveId idx, ReserveConfig config)` | `reserve_config` | C M (a frozen vault-token reserve is a depeg freeze) |
| Spoke | `RefreshPremiumDebt`, `RefreshAllUserDynamicConfig`, `RefreshSingleUserDynamicConfig`, `AddReserve`, `AddDynamicReserveConfig`, `UpdateDynamicReserveConfig`, `UpdateLiquidationConfig`, `UpdateReservePriceSource`, `UpdatePositionManager`, `SetUserPositionManager`, `SetSpokeImmutables`, `AuthorityUpdated` | log | C M |
| Hub | `AddSpoke(uint256 assetId idx, address spoke idx)` | `hub_spoke`; starts the `AaveSpokeAdded` and `DaoDeficitOffset` sources | C M |
| Hub | `Add`, `Remove`, `Draw`, `Restore`, `ReportDeficit`, `EliminateDeficit`, `RefreshPremium`, `TransferShares`, `MintFeeShares`, `UpdateAsset`, `UpdateAssetConfig`, `UpdateSpokeConfig`, `AddAsset`, `Reclaim`, `Sweep`, `AuthorityUpdated` | log | M |

Hubs and Spokes are followed under `AaveHub` and `AaveSpoke` (the manifest's, from their deployment) and `AaveSpokeAdded` (every Spoke a manifest Hub adds). A log two sources match is recorded once, and `account_debt` moves on its first delivery only. Spoke events of a user that is not an attributed account are logged and attributed to nobody; attribution uses `user`, never `liquidator`.

## AMM pools and chart series

The pools of the manifest's markets on concentrated-liquidity integrations (Uniswap v3, Aerodrome Slipstream) are followed by address (`AmmPool`; the pool key is the address left-padded); both markets of a pool share it. Pool logs are not written to `event_log`: they only feed the pool's series through the merge rules of `@avana/services-common/series`. A pool's logs are kept from its `PoolListed` on (`amm_pool`); earlier history comes from the export's [pool-history endpoint](EXPORT.md#pool-history). A pool listed after the manifest is followed from the next release manifest.

| Contract | Event | Updates | Used by |
|---|---|---|---|
| Pool | `Swap(address sender idx, address recipient idx, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)` | `series_point` pool: `volume0`, `volume1`, `fees0`, `fees1`, `swaps`, `sqrtPriceX96`, `tick`, `tickHigh`, `tickLow`, `liquidity` | C |
| Pool | `Mint`, `Burn` | `series_point` pool: `mints`, `liquidityAdded`, `burns`, `liquidityRemoved` | C |

A pool of a Uniswap v4 integration is a PoolId in the chain's PoolManager (`UniswapV4PoolManager`, from the manifest's `uniswapV4.poolManager`); its `PoolListed` writes `amm_pool_id`, and PoolManager logs of other pools are dropped.

| Contract | Event | Updates | Used by |
|---|---|---|---|
| PoolManager | `Swap(bytes32 id idx, ...)` | `series_point` pool; the amounts are the swapper's deltas (negated), the fee is the log's own | C |
| PoolManager | `ModifyLiquidity(bytes32 id idx, ...)` | `series_point` pool: mints or burns by the sign of `liquidityDelta` | C |
| PoolManager | `Donate(bytes32 id idx, ...)` | `series_point` pool: added to `fees0`, `fees1` | C |

The `SeriesSampler` block source runs once an hour of block time from the later of Avana's deployment and the first Lend Spoke's. At each sample block it runs the snapshot reader (`@avana/services-common/views`) through Ponder's client pinned to that block:

| Scope (`series_point.scopeKind`) | Key | Reads | Metrics |
|---|---|---|---|
| `hubAsset` | `chainId:hub:assetId` | Hub `getAssetCount`, `getAssetUnderlyingAndDecimals`, `getAssetConfig`, `getSpokeCount`, `getSpokeAddress`, `getSpoke`, `getAddedAssets`, `getAddedShares`, `getAssetOwed`, `getAssetLiquidity`, `getAssetDeficitRay`, `getAssetAccruedFees`, `getAssetDrawnRate`, `getAssetDrawnIndex`; each Lend Spoke's reserves and `ORACLE().getReservePrice`; the rate strategy; `FirstLossReserve.fundedBalance()` and every RiskModule's `coverage(hub, asset)` | `priceUsd8`, `added`, `addedShares`, `drawn`, `premium`, `owed`, `liquidity`, `deficit`, `accruedFees`, `drawnIndexRay`, `drawnRateRay`, `supplyRateRay`, `utilizationBps` |
| `hubAssetSpoke` | `chainId:hub:assetId:spoke` | Hub `getSpokeAddedAssets`, `getSpokeTotalOwed` | `added`, `addedShares`, `owed`, `drawnShares`, `premiumShares`, `deficit`, `addCap`, `drawCap` |
| `market` | `chainId:marketId` | `RiskModule.getMarket`, `LPOracle.latestAnswer`, the Spoke's vault-token reserve and dynamic config, Hub `getSpokeAddedAssets` | `suppliedUnits`, `acceptedPrice`, `suppliedUsd8`, `debtUsd8`, `borrowers` |
| `marketReserve` | `chainId:marketId:spoke:reserveId` | `Spoke.getUserDebt(reserveId, account)` of every account of the market | `debt`, `borrowers` |
| `position` (daily) | `chainId:spoke:account` | `Spoke.getUserSuppliedAssets`, `getUserDebt` per debt reserve | `marketId`, `collateralUnits`, `collateralUsd8`, `debtUsd8` |

Every point of one sample carries that block, so a bucket's Spoke slices add up to its Hub totals. A Slipstream pool's dynamic `fee()` is re-read at each sample and applies to the next hour's swaps.

## Live reads

Values that change with time, interest or prices and emit no event. Convex, the bot runner and the monitor read them over RPC at a stated block; indexed values only choose which accounts and markets to read.

| Value | Read | Read by |
|---|---|---|
| Health factor | `Spoke.getUserAccountData(account)` | B (every pass), C, M |
| Debt per reserve | `Spoke.getUserTotalDebt(reserveId, account)` | B C |
| Market record and band | `RiskModule.getMarket(marketId)`, `marketsOf(pool)`, `routeOf(pool, tickLower, tickUpper)` | B C M |
| Vault-token price | `LPOracle.latestAnswer()`, `getPrices()` (token prices and the pool's `sqrtPriceX96`) | C M (band-edge and depeg alerts) |
| Liquidation unwind preview | `LiquidationModule.previewUnwind(account, marketId, units)` | B |
| Draw-cap coverage | `RiskModule.coverage(hub, asset)`, `FirstLossReserve.fundedBalance()`, `isBelowMinimum()` | C M |
| Keeper registry | `RiskModule.getKeepers()`, `isKeeper(account)` | B M |
| Flash path | `FlashLiquidator.isFlashBorrower()`, `flashPremium(amount)` | B |
| Chainlink feed rounds | `latestRoundData()` of every feed leg in the manifest (`LPOracle.feedsOf`) | M |
| Wallet gas balances | `eth_getBalance` of each keeper wallet and the keeper top-up wallet | M |

## Not indexed

`UniswapV4PoolManager.Initialize`: a pool is initialized before any market can list it. `test/coverage.test.ts` fails on any event of a followed contract that has no handler, and on a handler for an event the ABI does not have.
