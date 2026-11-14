# Event and read catalogue

Every event the indexer handles, read from the interfaces under `contracts/src/**/I*.sol` and, for Aave V4, from the Aave ABIs built at the pinned commit (`contracts/out-aave/ISpoke.sol`, `IHub.sol`). Every handled log first writes an `event_log` row keyed `chainId + txHash + logIndex` with its block number, block hash and timestamp ([`src/lib/record.ts`](src/lib/record.ts)); the **Updates** column names the entity table it also changes. Values that change without an event are listed under [Live reads](#live-reads).

**Finality.** Each consumer reads at its own depth (services/README.md, Finality and reorgs):

| Code | Consumer | Depth |
|---|---|---|
| K | Keeper | Chain head, through the indexer stream and its own RPC logs |
| M | Monitoring | Chain head; every alert is confirmed on-chain before paging |
| C | Convex | `finalized` only, through the [export](EXPORT.md) |

Indexed parameters are marked `idx`. Enum values: `PriceState` Live 0, Drifting 1, Cached 2, Expired 3; `PauseState` None 0, Frozen 1, Paused 2; `PauseReason` None 0, General 1, MintPathSuspect 2; `RouteMode` PrimaryThenBackup 0, BackupOnly 1; `BreakerScope` Market 0, DebtReserve 1; `RouteSlot` None 0, Primary 1, Alternate 2.

## Accounts and proxies

| Contract | Event | Updates | Used by |
|---|---|---|---|
| AaveAdapter | `UserProxyCreated(address wallet idx, address spoke idx, uint256 marketId idx, address proxy)` | `account` (`adapterSeen`) | K C M |
| ProxyManager | `ProxyDeployed(address wallet idx, address spoke idx, uint256 marketId idx, address proxy)` | `account` (`managerSeen`) | K C M |
| VaultToken | `ProxyAdded(address proxy idx)` | log | M |

An account is attributed once both creation events name the same wallet and market; a proxy announced by only one of them raises a monitoring alert and receives no Spoke events (`TEST-144`). The proxy address is `predictProxy(wallet, spoke, marketId)`, the CREATE2 address under the manifest's `proxyCreationCodeHash`.

## AaveAdapter actions

| Event | Updates | Used by |
|---|---|---|
| `CollateralAdded(address wallet idx, uint256 marketId idx, address vaultToken idx, address proxy, uint256 recordId, uint32 integrationId, bytes32 positionKey, uint128 units)` | log | K C |
| `Borrowed(address wallet idx, uint256 marketId idx, uint256 debtReserveId idx, address receiver, uint256 amount, uint256 nonce, uint256 healthFactorAfter)` | log | K C |
| `Repaid(address payer idx, address borrower idx, uint256 marketId idx, uint256 debtReserveId, uint256 spent, uint256 debtAfter, bool repayAll)` | log | K C |
| `CollateralWithdrawn(address wallet idx, uint256 marketId idx, address vaultToken idx, bytes32 positionKey, uint256 units, bool withDebt, uint256 healthFactorAfter)` | log | K C |
| `CollateralReduced(address wallet idx, uint256 marketId idx, address vaultToken idx, bytes32 positionKey, uint128 units, uint256[] amounts, bool withDebt, uint256 healthFactorAfter)` | log | K C |
| `CollateralRecredited(address wallet idx, uint256 marketId idx, address vaultToken idx, uint256 recordId, bytes32 positionKey, uint128 added, uint128 rescueUnits)` | log | K C |
| `RepaidWithCollateral(address wallet idx, uint256 marketId idx, address vaultToken idx, bytes32 positionKey, uint128 units, uint256 debtReserveId, uint256 debtRepaid, uint256 debtAssetToWallet, uint256 healthFactorBefore, uint256 healthFactorAfter)` | log | K C |
| `SeizedUnitsBurned(uint256 marketId idx, address vaultToken idx, uint256 units)` | log | C M |
| `CollateralSupplied(address proxy idx, uint256 marketId idx, uint256 units, uint256 shares)` | log | C |
| `CollateralDisabled(address proxy idx, uint256 reserveId)` | log | K C |

`healthFactorAfter` is the value at that block; the app and the keeper re-read it.

## Collateralization

| Event | Updates | Used by |
|---|---|---|
| `CollateralPledged(uint256 recordId idx, bytes32 positionKey idx, address depositor idx, uint32 integrationId, address proxy, address vaultToken, uint128 credited, uint256 usdCharge, uint256 sliceUsd)` | `collateral_record` insert | C |
| `CollateralReleased(uint256 recordId idx, bytes32 positionKey idx, address depositor idx, address proxy, address vaultToken, uint256 unitsBurned)` | `collateral_record` closed | C |
| `RecordDebited(uint256 recordId idx, bytes32 positionKey idx, address proxy idx, address vaultToken, uint256 unitsDebited, uint256 creditedAfter, uint256[] amounts, uint256 capReleased)` | `collateral_record.credited` | C |
| `RecordReduced(uint256 recordId idx, uint128 units, uint256 release)` | `collateral_record.credited` | C |
| `RecordRecredited(uint256 recordId idx, uint128 added, uint256 charge, uint128 rescueUnits)` | `collateral_record.credited`, `rescueUnits` | C |
| `SeizureSettled(address proxy idx, address vaultToken idx, uint256 units, uint256[] amounts, uint256 recordsDebited)` | log | C M |
| `SeizureReconciled(address proxy idx, address vaultToken idx, uint256 units, uint256[] amounts)` | `pending_settlement` + units | K C M |
| `PendingSettled(address vaultToken idx, uint256 units, uint256[] amounts)` | `pending_settlement` − units | K C |
| `CounterSaturated(CounterKind counterKind, address hub idx, address key, uint256 valueBefore, uint256 subtracted)` | log | M (`M-21`) |

## LPVault (one per AMM integration)

| Event | Updates | Used by |
|---|---|---|
| `MarketBound(uint256 marketId idx, address pool, bytes32 poolId, int24 tickLower, int24 tickUpper)` | log | C |
| `PositionReceived(bytes32 positionKey idx, uint256 marketId idx, address depositor idx, uint128 units)` | `lp_position` held | C |
| `PositionReturned(bytes32 positionKey idx, address depositor idx)` | `lp_position` returned | C |
| `UnitsUnwound(bytes32 positionKey idx, uint128 units, address recipient idx, uint256[] amounts)` | log | C |
| `UnitsReleased(bytes32 positionKey idx, uint128 units, address depositor idx, uint256[] amounts)` | log | C |
| `FeesCollected(bytes32 positionKey idx, address depositor idx, uint256[] amounts)` | log | C |
| `StrayReceived(bytes32 positionKey idx, address from, address operator)` | `lp_position` stray | C M |
| `StrayReturned(bytes32 positionKey idx, address recipient)` | `lp_position` returned | C |

The position managers' own events (`IncreaseLiquidity`, `DecreaseLiquidity`, `Collect`) are not indexed: custody changes appear as LPVault events, and liquidity a depositor adds to a pledged position is read live with `Lens.previewRecredit`.

## Vault tokens and factory

| Contract | Event | Updates | Used by |
|---|---|---|---|
| VaultTokenFactory | `IntegrationRegistered(uint32 integrationId idx, address lpVault idx, bytes32 ammProtocol, PoolKeying poolKeying, ShapeKind shapeKind)` | log | C |
| VaultTokenFactory | `VaultTokenDeployed(address vaultToken idx, uint256 marketId idx, address spoke idx, VaultTokenBindings bindings, address pool, bytes32 poolId, PositionShape shape)` | log; starts the VaultToken source (child address in `vaultToken`) | C |
| VaultToken | `Transfer(address from idx, address to idx, uint256 value)` | log | C M |

## LPVaultSwap and liquidation

| Contract | Event | Updates | Used by |
|---|---|---|---|
| LPVaultSwap | `LiquidationSettled(address caller idx, address proxy idx, uint256 marketId idx, SettlementReport report)` | `liquidation` | K C M |
| LPVaultSwap | `BorrowerSurplusPaid(address proxy idx, address wallet idx, address debtAsset idx, uint256 amount, bool escrowed)` | log | C |
| LPVaultSwap | `FlashLoanUsed(uint256 marketId idx, address flashSource idx, address asset idx, uint256 amount, uint256 premium)` | log | M |
| LPVaultSwap | `RouteFailed(uint256 marketId idx, address token idx, address route, bytes4 errorSelector)` | log | K M (`M-10`) |
| LPVaultSwap | `ResidueReturned(address caller idx, address token idx, uint256 amount, bool escrowed)` | log | M |
| LPVaultSwap | `PendingSettlementForwarded(address caller idx, uint256 marketId idx, address vaultToken, uint256 units, uint256[] amounts, address debtAsset idx, uint256 added, uint256 minPending, address firstLossReserve, uint8[] routeUsed, uint256 funded, uint256 carried)` | log | K C M |
| LPVaultSwap | `Deleveraged(address proxy idx, uint256 marketId idx, uint256 debtReserveId idx, uint128 units, uint256 debtRepaid, uint256 recovered, uint256 flashPremium, uint256 debtAssetOut)` | log | C |
| LPVaultSwap | `KeeperAdded(address keeper idx)`, `KeeperRemoved(address keeper idx)` | `committed_operator` | K M |
| PayoutEscrow | `RemainderEscrowed(address token idx, address account idx, uint256 amount)` | `escrow_credit` + | C M (`M-25` when `account` is `feeRecipient`) |
| PayoutEscrow | `RemainderClaimed(address token idx, address account idx, address recipient, uint256 amount)` | `escrow_credit` − | C |
| Flash liquidation helpers | `FlashLiquidated(address caller idx, address recipient idx, address asset idx, uint256 flashAmount, uint256 premium, uint256 keeperOut, uint256 topUp, uint256 payout)` | log | K M |

`SettlementReport` fields: `debtReserveId, debtAsset, debtRepaid, unitsSeized, amountsOut[], recovered, minOut, effectiveSlippageBps, bonusBps, callerFunds, surplus, avanaFee, keeperReward, borrowerSurplus, keeperOut, minPayout, routeMode, routeUsed[], shortfall`. A settlement is valid whoever the caller is (`Q-404`).

## Oracles

LPOracle (one per market, followed from `MarketRegistered.lpOracle`) and DebtOracle (one per non-GHO debt asset, followed from `DebtReserveApproved.priceSource`):

| Contract | Event | Updates | Used by |
|---|---|---|---|
| LPOracle | `PriceStateChanged(PriceState previous, PriceState current, uint256 reasons, uint64 servedUpdatedAt)` | `oracle_state.state` | K M (`M-01`) |
| LPOracle | `PriceAccepted(int256 answer, uint64 updatedAt, uint256[] prices)` | `oracle_state.acceptedPrice` | C |
| LPOracle | `DisagreementRecorded(uint64 since, uint256[] primary, uint256[] alternate)`, `DisagreementCleared(uint64 since, uint64 clearedAt)` | `oracle_state.disagreeSince` | K M (`M-02`) |
| LPOracle | `GraceStarted(uint64 recoveredAt, uint64 graceEndsAt, bool fromLatch)` | `oracle_state.graceEndsAt` | K |
| LPOracle | `PriceSeeded`, `RouteChanged`, `FailureRecorded`, `FailureCleared`, `OutageExpiredLatched`, `QuoteChangeCapped`, `PokeMinGasUpdated`, `PriceCheckpointed`, `PriceRouteVersionObserved` | log | M |
| DebtOracle | `DebtPriceStateChanged(PriceState previous, PriceState current, uint256 reasons)` | `oracle_state.state` | K M (`M-01`) |
| DebtOracle | `DebtPriceAccepted(uint256 price8, uint64 updatedAt, RouteSlot source)` | `oracle_state.acceptedPrice` | C |
| DebtOracle | `DebtDisagreementRecorded(uint64 since, uint256 primary, uint256 alternate)`, `DebtDisagreementCleared(uint64 since, uint64 clearedAt)` | `oracle_state.disagreeSince` | K M |
| DebtOracle | `DebtGraceStarted(uint64 recoveredAt, uint64 graceEndsAt, bool fromLatch)` | `oracle_state.graceEndsAt` | K |
| DebtOracle | `DebtPriceSeeded`, `DebtRouteChanged`, `DebtFailureRecorded`, `DebtFailureCleared`, `DebtOutageExpiredLatched`, `DebtRouteVersionObserved`, `PokeMinGasUpdated` | log | M |

An oracle emits only when it is poked or read by a transaction. A market becomes Cached or Expired by the passage of time, with no event until the next poke, so `oracle_state` is never a current state.

## MarketRegistry

| Event | Updates | Used by |
|---|---|---|
| `MarketRegistered(uint256 marketId idx, uint32 integrationId idx, address pool, bytes32 poolId, address[] tokens, address vaultToken, address lpOracle, address spoke idx)` | `market` insert; starts the LPOracle source | K C M |
| `MarketActivated(uint256 marketId, uint256 chainId, address spoke, uint256 reserveId, address hub, uint256 hubAssetId)` | `market` Active | K C M |
| `MarketRegistrationCancelled(uint256 marketId)`, `MarketClosed(uint256 marketId idx)` | `market.status` | K C M |
| `MarketOffboarding(uint256 marketId)` | `market.status` Offboarding, `market.offboardedAt` (block time; the notice ends at `offboardedAt + 5 days`, the earliest time of the Aave DAO's one threshold drop to `windDownState(marketId).targetLtBps` and of `closeMarket`) | K C M |
| `SettlementReserveSet(uint256 marketId idx, uint256 debtReserveId)` | `market.settlementReserveId` | K |
| `DebtReserveApproved(address spoke idx, uint256 reserveId idx, address asset, address fundingHub, uint256 hubAssetId, address priceSource, address firstLossReserve)` | `debt_reserve`; starts the DebtOracle source | K C M |
| `DebtReserveRemoved(address spoke idx, uint256 reserveId idx)` | `debt_reserve.approved` | K C M |
| `SpokeApproved(address spoke idx, address hub idx, uint32 integrationId idx, address implementation, address aaveOracle)` | `cdp_spoke`; starts the `AaveSpokeApproved` source | C M (`M-20`) |
| `HubRecorded(address hub idx, uint8 tier)` | `hub`; starts the `AaveHubRecorded` source | C M |
| `CrossHubLineSet(address fundingHub idx, address asset idx, address spoke idx, uint256 cap, uint256 total)` | `cross_hub_line` | C M |
| `CrossHubLinesEnabledSet(bool enabled)` | `cross_hub_config` | C M |
| `CreditLineSet(address hub idx, address asset idx, uint256 line, uint256 sum)` | `credit_line` | C M |
| `CreditLineRecorded(address hub idx, address asset idx, address spoke idx, uint256 drawCap, uint256 sum)` | `credit_line_spoke`, `credit_line.sum` | C M |
| `TokenListed(address token, uint8 decimals, address[] primaryRoute, address[] alternateRoute, address pegModule)`, `PriceSourceSet(address token, address[] primaryRoute, address[] alternateRoute, address[] standbyRoute)` | log | K (feed list) M |
| `RouteSet`, `RouteDisabled`, `RouteRestored` (`uint256 marketId idx, address token, address debtAsset, uint8 kind, address route[/caller]`) | log | K (code check list) M (`M-10`, `M-11`) |
| `PauseStateChanged(address hub idx, PauseState previous idx, PauseState current idx, address caller)` | `pause_state.state` | K C M (`M-24`) |
| `PauseReasonChanged(address hub idx, PauseReason previous, PauseReason current, address caller idx)` | `pause_state.reason` | C M (`M-24`) |
| `AddressFrozen(address account idx, address caller idx)`, `AddressUnfrozen(address account idx)` | `frozen_address` | K C M (`M-24`) |
| `BreakerLatched(BreakerScope scope idx, bytes32 key idx, uint32 reasons)` | `breaker` | K C M (`M-08`) |
| `BreakerReset(BreakerScope scope idx, bytes32 key idx, address caller idx)` | `breaker` cleared | K C M |
| `GateBreached(bytes32 key idx, uint32 reasons, uint64 at)` | log | M (`M-08`) |
| `StandbyRouteActivated(address token idx, RouteSlot slot, address caller idx)`, `StandbySwitchCancelled(address token idx, address caller idx)`, `PriceRouteRestored(address token idx)` | log | K M (`M-24`) |
| `IntegrationRegistered`, `AvanaFirstLossReserveSet` (starts the First-Loss Reserve source), `FlashSourceSet`, `SpokeCodeHashApproved`, `IntegrationContractsRecorded` | log | M |

## ParameterStore and RiskModule

| Contract | Event | Updates | Used by |
|---|---|---|---|
| ParameterStore | `ParameterTightened`, `ParameterLoosened` (`bytes32 name, bytes32 scope, uint256 oldValue, uint256 newValue, address caller`), `ParameterSet(bytes32 name, bytes32 scope, uint256 oldValue, uint256 newValue)` | log | K (reloads cached parameters) M |
| ParameterStore | `MarketSpeedLimitsSet(uint256 marketId idx, MarketSpeedLimits oldLimits, MarketSpeedLimits newLimits, bool tightened)`, `DebtSpeedLimitSet(address hub idx, address asset idx, SpeedLimit oldLimit, SpeedLimit newLimit, bool tightened)` | log | M |
| ParameterStore | `CapTightened`, `CapLoosened` (`bytes32 capKind, bytes32 scope, uint256 oldValue, uint256 newValue, address caller`), `StressFloorSet`, `MinPledgeUsdSet`, `RouteDepthThresholdSet`, `DebtAssetParamsSet` | log | C M |
| ParameterStore | `FeedConfigured(address feed, uint8 decimals, int256 minAnswer, int256 maxAnswer, uint32 feedHeartbeat, uint16 heartbeatMargin, uint32 feedMaxAge, uint16 feedDeviationThresholdBps, uint16 heartbeatDriftBps, uint32 borrowPriceMaxAge, uint32 liquidationPriceMaxAge)` | log | K (poke cadence) M (`M-03`, `M-04`) |
| ParameterStore | `SequencerSet(address feed, uint32 gracePeriod)`, `SecondSourceSwitched(address token idx, bool standby, address by)` | log | K M |
| RiskModule | `ConfigDriftDetected(address spoke idx, DriftReason reason)` | log | K M (`M-20`) |
| RiskModule | `BreakersPoked(uint256 marketId idx, uint32 reasons)` | log | M |

## Governance

| Contract | Event | Updates | Used by |
|---|---|---|---|
| AvanaTimelock (OpenZeppelin) | `CallScheduled(bytes32 id idx, uint256 index idx, address target, uint256 value, bytes data, bytes32 predecessor, uint256 delay)` | `timelock_operation` Scheduled | M (`M-22`) |
| AvanaTimelock | `CallExecuted(bytes32 id idx, uint256 index idx, address target, uint256 value, bytes data)`, `Cancelled(bytes32 id idx)` | `timelock_operation.status` | M |
| AvanaTimelock | `ExpiredOperationCleaned(bytes32 id idx)` | `timelock_operation` Cleaned | M |
| AvanaTimelock | `NormalDelayChanged(uint256 previousDelay, uint256 newDelay)`, `ShortDelaySelectorSet(address target idx, bytes4 selector idx, bool enabled)`, `PublicExecutionToggled(bool enabled)`, `CallSalt`, `MinDelayChange` | log | M (`M-22`) |
| Every upgradeable Avana contract | `Upgraded(address implementation idx)` (ERC-1967) | `implementation` | K (manifest refresh) M (`M-22`, `M-26`) |
| Every role-managed Avana contract and the timelock | `RoleGranted`, `RoleRevoked`, `RoleAdminChanged` (OpenZeppelin AccessControl) | `role_member` | M (`M-22`) |

An operation's expiry emits no event: `expiresAt = readyAt + GRACE_PERIOD` (14 days, `REQ-ACCESS-108`), and `readyAt = block timestamp of CallScheduled + delay`.

## First-Loss Reserves

| Event | Updates | Used by |
|---|---|---|
| `ReserveFunded(address funder idx, uint256 amount, uint256 shares, uint256 balanceAfter)` | `coverage_balance` | C M (`M-13`) |
| `DeficitCovered(address borrowSpoke idx, address caller idx, uint256 covered, uint256 sharesBurned, uint256 deficitRayBefore, uint256 deficitRayAfter, uint256 balanceAfter)` | `coverage_balance` | C M (`M-13`, `M-15`) |
| `WithdrawalExecuted(uint256 id idx, uint256 withdrawn, uint256 sharesBurned, address to idx, uint256 balanceAfter)` | `coverage_balance` | M |
| `WithdrawalRequested(uint256 id idx, uint256 amount, address to idx, uint64 executableAt)`, `WithdrawalCancelled(uint256 id idx)`, `ReserveBelowMinimum(uint256 balance, uint256 minimum)`, `BorrowSpokeAllowlistUpdated(address spoke idx, bool allowed)`, `FirstLossReserveMinimumUpdated(uint256 oldMinimum, uint256 newMinimum)` | log | M |

## Aave V4 Spokes and Hub

Avana's `IAaveV4Spoke` declares none of the Spoke's events, so the indexer decodes them with the Aave ABIs in `packages/protocol`, built from the pinned Aave V4 commit. Signatures at that commit (`premiumDelta` is `(int256, int256, uint256)`):

| Contract | Event | Updates | Used by |
|---|---|---|---|
| Spoke | `Supply(uint256 reserveId idx, address caller idx, address user idx, uint256 suppliedShares, uint256 suppliedAmount)` | log | K C |
| Spoke | `Withdraw(uint256 reserveId idx, address caller idx, address user idx, uint256 withdrawnShares, uint256 withdrawnAmount)` | log | K C M (`M-19` on the Lend Spoke) |
| Spoke | `Borrow(uint256 reserveId idx, address caller idx, address user idx, uint256 drawnShares, uint256 drawnAmount)` | `account_debt` + shares | K C |
| Spoke | `Repay(uint256 reserveId idx, address caller idx, address user idx, uint256 drawnShares, uint256 totalAmountRepaid, premiumDelta)` | `account_debt` − shares | K C |
| Spoke | `LiquidationCall(uint256 collateralReserveId idx, uint256 debtReserveId idx, address user idx, address liquidator, bool receiveShares, uint256 debtAmountRestored, uint256 drawnSharesLiquidated, premiumDelta, uint256 collateralAmountRemoved, uint256 collateralSharesLiquidated, uint256 collateralSharesToLiquidator)` | `account_debt` − shares | K C M |
| Spoke | `ReportDeficit(uint256 reserveId idx, address user idx, uint256 drawnShares, premiumDelta)` | `account_debt` deficit | K C M (`M-15`) |
| Spoke | `SetUsingAsCollateral(uint256 reserveId idx, address caller idx, address user idx, bool usingAsCollateral)` | `account.usingAsCollateral` | K C |
| Spoke | `UpdateUserRiskPremium(address user idx, uint256 riskPremium)`, `RefreshPremiumDebt`, `RefreshAllUserDynamicConfig`, `RefreshSingleUserDynamicConfig` | log | C (`Q-145`) |
| Spoke | `AddReserve`, `UpdateReserveConfig`, `AddDynamicReserveConfig`, `UpdateDynamicReserveConfig`, `UpdateLiquidationConfig`, `UpdateReservePriceSource`, `UpdatePositionManager`, `SetUserPositionManager`, `SetSpokeImmutables`, `AuthorityUpdated` | log | M (`M-20`) |
| Hub | `AddSpoke(uint256 assetId idx, address spoke idx)` | `hub_spoke`; starts the `AaveSpokeAdded` source | C M (`M-20`) |
| Hub | `Add`, `Remove`, `Draw`, `Restore`, `ReportDeficit`, `EliminateDeficit`, `RefreshPremium`, `TransferShares`, `MintFeeShares`, `UpdateAsset`, `UpdateAssetConfig`, `UpdateSpokeConfig`, `AddAsset`, `Reclaim`, `Sweep`, `AuthorityUpdated` | log | M (`M-15`, `M-18`, `M-19`, `M-20`) |

A chain has several Hubs, each with its Lend and CDP Spokes. Hubs and Spokes are followed under several sources ([`src/config/aaveSources.ts`](src/config/aaveSources.ts)): `AaveHub` and `AaveSpoke` hold the manifest's Hubs and Lend and CDP Spokes from their deployment blocks; `AaveHubRecorded` every Hub the MarketRegistry records (`HubRecorded`); `AaveSpokeApproved` every CDP Spoke it approves (`SpokeApproved`); `AaveSpokeAdded` every Spoke a manifest Hub adds (`AddSpoke`). A Hub, CDP Spoke or Lend Spoke on a manifest Hub listed after start-up is therefore indexed with no restart. A log matched by two sources is recorded once under the Aave contract's kind (`AaveSpoke.Borrow`, `AaveHub.AddSpoke`), and `account_debt` moves on its first delivery only. A Lend Spoke on a Hub recorded after start-up is read by the sampler at once; its own events are indexed once the manifest names it.

Every `LiquidationCall` on a CDP Spoke has `liquidator == LPVaultSwap` (`Q-222`); attribution uses `user`, never `liquidator` (`LIQ-056`). The Spoke events of a user that is not an attributed account are logged and attributed to nobody.

## AMM pools and chart series

The pool of every listed market is followed from its `MarketRegistered` (`AmmPool`, a factory source on the `pool` field); Uniswap v3 and Aerodrome Slipstream pools share these signatures. Pool logs are not written to `event_log`: they only feed the pool's series, through the merge rules of `@avana/services-common/series` (volumes and fees add up, price and liquidity keep the last swap). Ponder matches a pool's logs from the block that announced it on; earlier history comes from the export's [pool-history endpoint](EXPORT.md#pool-history).

| Contract | Event | Updates | Used by |
|---|---|---|---|
| MarketRegistry | `MarketRegistered` (above) | `amm_pool` (fee read once with `fee()`) | C |
| Pool | `Swap(address sender idx, address recipient idx, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)` | `series_point` pool: `volume0`, `volume1`, `fees0`, `fees1` (input side × fee), `swaps`, `sqrtPriceX96`, `tick`, `tickHigh`, `tickLow`, `liquidity` | C |
| Pool | `Mint(address sender, address owner idx, int24 tickLower idx, int24 tickUpper idx, uint128 amount, uint256 amount0, uint256 amount1)` | `series_point` pool: `mints`, `liquidityAdded` | C |
| Pool | `Burn(address owner idx, int24 tickLower idx, int24 tickUpper idx, uint128 amount, uint256 amount0, uint256 amount1)` | `series_point` pool: `burns`, `liquidityRemoved` | C |

The `SeriesSampler` block source runs once an hour of block time (300 blocks on Ethereum, 1,800 on Base) from the later of the Lens and the first Lend Spoke deployment on, so a full reindex rebuilds the history from archive reads. At each sample block it reads, through Ponder's client pinned to that block, every Hub of the manifest and every Hub the MarketRegistry has recorded, with all their assets and Spokes (`@avana/services-common/views`, `discovery.ts`):

| Scope (`series_point.scopeKind`) | Key | Reads | Metrics |
|---|---|---|---|
| `hubAsset` | `chainId:hub:assetId` | MarketRegistry `getHubs`, `getSpokes`, `hubOf`, `isRecordedHub`, `hubTier`, `firstLossReserveOf`; Hub `getAssetCount`, `getAssetUnderlyingAndDecimals`, `getAssetConfig`, `getSpokeCount`, `getSpokeAddress`, `getSpoke` (discovery of every Hub, Hub asset and Spoke); every Lend Spoke's `getReserveCount`, `getReserve`, `getReserveConfig`, its `ORACLE().getReservePrice`; Hub `getAddedAssets`, `getAddedShares`, `getAssetOwed`, `getAssetLiquidity`, `getAssetDeficitRay`, `getAssetAccruedFees`, `getAssetDrawnRate`, `getAssetDrawnIndex`, `getAssetConfig`; the rate strategy's `getInterestRateData`; `Lens.getHubAssetExposure` | `priceUsd8`, `added`, `addedShares`, `drawn`, `premium`, `owed`, `liquidity`, `deficit`, `accruedFees`, `drawnIndexRay`, `drawnRateRay`, `supplyRateRay`, `utilizationBps` |
| `hubAssetSpoke` | `chainId:hub:assetId:spoke` | Hub `getSpokeCount`, `getSpokeAddress`, `getSpoke`, `getSpokeAddedAssets`, `getSpokeTotalOwed`; `FIRST_LOSS_LAYER()` of each Spoke of an asset with a First-Loss Reserve that is none of the known kinds (finds the DAO deficit offset) | `added`, `addedShares`, `owed`, `drawnShares`, `premiumShares`, `deficit`, `addCap`, `drawCap` |
| `creditLine` | `chainId:fundingHub:assetId:spoke` | MarketRegistry `crossHubLineCap`, `crossHubLineTotal`, `crossHubLinesEnabled`, for every CDP Spoke drawing on a Hub other than its home Hub | `cap`, `total`, `enabled` (1 or 0); the draw is the `hubAssetSpoke` series of the same Spoke |
| `market` | `chainId:marketId` | `Lens.getMarkets`, Spoke `getReserve` (collateral risk), Hub `getAssetUnderlyingAndDecimals` (vault-token decimals); `Lens.getBorrowSpeed(marketId, debtReserveId)` per debt reserve and `Lens.getPledgeSpeed(marketId)` (read for the current rows, not charted) | `suppliedUnits`, `acceptedPrice`, `suppliedUsd8`, `marketHeadroomUsd8`, `debtUsd8`, `borrowers` |
| `marketReserve` | `chainId:marketId:spoke:reserveId` | `Spoke.getUserDebt(reserveId, proxy)` of every attributed account of the market | `debt`, `borrowers` |
| `position` (daily) | `chainId:spoke:proxy` | `Spoke.getUserSuppliedAssets(collateralReserveId, proxy)`, `getUserDebt` per debt reserve | `marketId`, `collateralUnits`, `collateralUsd8`, `debtUsd8` |

Every point of one sample carries that block, so a bucket's Spoke slices add up to its Hub totals and its market debts to the Spoke's owed amount. A sampled bucket keeps its first sample; a dynamic-fee pool's `fee()` is re-read at each sample and applies to the next hour's swaps.

## Live reads

These values change with time, interest or prices and emit no event, or emit only when a transaction touches them. Convex and the keeper read them over RPC at a stated block; indexed values only choose which accounts and markets to read.

| Value | Read | Read by |
|---|---|---|
| Health factor, collateral value, debt value, borrow count | `Spoke.getUserAccountData(proxy)` | K (every block, multicall pinned to the block), C (on view and after each receipt) |
| Debt per reserve with accrued interest | `Spoke.getUserTotalDebt(reserveId, proxy)`, `Spoke.getUserPosition(reserveId, proxy)`; `Lens.getAccount(wallet, marketId).debts` | K C |
| Liquidation sizing and gates | `Lens.previewLiquidation(proxy, debtReserveId, deadline)` | K |
| Market price state, age, disagreement, grace | `Lens.getPriceState(vaultToken)`; `LPOracle.getPriceState()`; `LPOracle.liquidationPriceMaxAge()` | K C M |
| Debt reserve price state | `Lens.getDebtPriceState(spoke, debtReserveId)`; `DebtOracle.getPriceState()` | K C M |
| Chainlink feed rounds (poke cadence, `M-03`, `M-04`) | `latestRoundData()` of every feed leg in the manifest | K M |
| Sequencer status (Base) | Sequencer-uptime feed `latestRoundData()` | K M |
| Breakers | `Lens.getBreakerStatus(marketId)`, `Lens.getDebtBreakerStatus(spoke, debtReserveId)`; `MarketRegistry.lastBreachAt(key)`; a breaker condition true now: `eth_call RiskModule.pokeBreakers(marketId)` | K C M |
| Spoke setting drift | `eth_call RiskModule.pokeConfig(spoke)` | K M (`M-20`) |
| Application state and freezes | `MarketRegistry.pauseState(hub)`, `pauseReason(hub)`, `isFrozenAddress(account)` | K C |
| Pending seized units | `Collateralization.getPending(vaultToken)`, `Lens.getPendingSettlement(vaultToken)`, `MarketRegistry.settlementReserve(marketId)` | K |
| Committed-operator registry | `LPVaultSwap.isApprovedKeeper(helper)`, `activeKeeperCount()`, `getKeepers()` | K M |
| Flash liquidity and premium | `helper.maxFlashLoan(asset)`, `helper.flashPremium(asset, amount)` | K M (`M-17`) |
| Escrow credits | `PayoutEscrow.claimable(token, account)`; `Lens.getEscrowClaimable(account, tokens)` | C |
| Borrow nonce | `AaveAdapter.borrowNonce(proxy)` | browser (intent preparation) |
| Backing and caps | `Lens.checkBacking(vaultToken)`, `Lens.getCapHeadroom(vaultToken, depositor)` | C M (`M-21`) |
| Tail coverage and deficits | `Lens.getTailCoverage(debtAsset)` (with the DAO deficit offset and its funds, `deficitOffset`, `offsetFunded`), `Lens.uncoveredDeficit(hub, asset)`, `Hub.getSpokeDeficitRay(assetId, spoke)` | M (`M-14`, `M-15`) |
| Speed limits (BOR-024) | `Lens.getBorrowSpeed(marketId, debtReserveId)` ("available to borrow now", "more from"), `Lens.getPledgeSpeed(marketId)`, through the snapshot reader | C |
| Account previews and sizing | `Lens.getPositionFees`, `getAccountFees`, `previewBorrowAfter`, `previewRepayAfter`, `previewPledgeAfter`, `previewWithdrawAfter`, `previewMaxWithdraw`, `previewDeleverageTo`, `previewCloseAccount`, `getHubAsset` (`@avana/services-common/views`, `appViews.ts`) | browser |
| Hub utilization and draw caps | `Hub.getAssetLiquidity`, `getAddedAssets`, `getSpokeTotalOwed`, `getSpokeConfig` | M (`M-18`, `M-19`) |
| First-Loss Reserve balance | `AvanaFirstLossReserve.totalFunded()`, `totalCovered()`, `totalWithdrawn()` | M (`M-13`) |
| Timelock expiry | `AvanaTimelock.getTimestamp(id)` plus `GRACE_PERIOD()` | M (`M-22`) |
| Implementations and code | `eth_getStorageAt(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)`; `keccak256(eth_getCode(address))` | K (`Q-219`) M (`M-26`) |
| Safes | `getOwners()`, `getThreshold()`, guard and module slots | M (`M-23`) |
| Token issuers | `paused()`, `basisPointsRate()` and the issuer's blocklist reads | M (`M-25`) |
