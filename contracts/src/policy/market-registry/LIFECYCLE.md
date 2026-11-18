Function links point to the interface that declares each function.

# MarketRegistry lifecycle

The MarketRegistry is the chain's directory and safety switchboard: it records Hubs, CDP Spokes, debt reserves, tokens, markets and swap routes through timelock operations, and holds each Hub's pause state, the address freeze and the breaker latches that stop new activity.

```mermaid
stateDiagram-v2
  [*] --> Registered: listCollateralMarket(def)
  Registered --> Active: activateMarket(marketId), short delay
  Registered --> Cancelled: cancelRegistration(marketId)
  Cancelled --> Registered: listCollateralMarket(def), relisting
  Active --> Offboarding: setMarketOffboarding(marketId), short delay
  Offboarding --> Closed: closeMarket(marketId) after the notice, no indebted account
  Closed --> [*]
```

```mermaid
stateDiagram-v2
  state "Paused, General" as General
  state "Paused, MintPathSuspect" as MintPathSuspect
  [*] --> None
  None --> Frozen: freeze(hub)
  Frozen --> None: unfreeze(hub)
  None --> General: pause(hub, General)
  Frozen --> General: pause(hub, General)
  None --> MintPathSuspect: pause(hub, MintPathSuspect)
  Frozen --> MintPathSuspect: pause(hub, MintPathSuspect)
  General --> MintPathSuspect: pause(hub, MintPathSuspect)
  MintPathSuspect --> General: pause(hub, General)
  General --> None: unpause(hub)
  MintPathSuspect --> None: unpause(hub)
  note right of None
    freeze and pause by the Emergency Guardian at once
    or the timelock at the short delay, unfreeze and unpause
    by the pause guardian or the timelock at the normal delay.
    Repay, debt-free withdrawal, fee collection and
    liquidation never read this state.
  end note
```

## Walkthrough

Setup (Ethereum market 1: Uniswap v3 USDC/USDT 0.01%, exact range, on the "Uniswap v3 Stable" CDP Spoke `S` of the Stable LP Hub). Normal delay 5 days, short delay 12 hours.

1. **AvanaTimelock → [`approveSpokeCodeHash`](IMarketRegistry.sol#L509) (the reviewed hash of `S`'s implementation; every Aave V4 Spoke implementation has its own), [`deployCdpSpoke`](IMarketRegistry.sol#L29), [`recordIntegrationContracts`](IMarketRegistry.sol#L527) (the Uniswap v3 NonfungiblePositionManager and factory, now protected from the address freeze) and [`finalizeIntegrationContracts`](IMarketRegistry.sol#L534) (from here the integration's routes can be set; a later addition disables at once any route that runs through it, `RouteDisabled`), [`enableDebtReserve`](IMarketRegistry.sol#L35) (GHO, USDC), [`listToken`](IMarketRegistry.sol#L49) (USDC with `PausedFlag` and USDT with the combined `UsdtFeeRateAndPaused` probe, each with primary, alternate and standby routes; GHO, a fixed-price debt asset that is no pool token, with its GHO/USD monitoring feed only)** at the normal delay. Enabling a reserve checks the draw cap against the credit line ([`recordCreditLine`](IMarketRegistry.sol#L430)) and that a swap route of each pool token passes its depth test. Every debt asset, GHO included, is a listed token with its issuer probe; a monitoring-only listing serves only a fixed-price reserve and is refused as a pool token (`ListingCheckFailed("routeLength")`) until `setPriceSource` gives it three routes. Events: [`SpokeCodeHashApproved`](IMarketRegistry.sol#L496), [`SpokeApproved`](IMarketRegistryBase.sol#L113), [`IntegrationContractsRecorded`](IMarketRegistry.sol#L499), [`IntegrationContractsFinalized`](IMarketRegistry.sol#L502), [`DebtReserveApproved`](IMarketRegistryBase.sol#L122), [`CreditLineSet`](IMarketRegistry.sol#L411), [`TokenListed`](IMarketRegistryBase.sol#L137). Errors: [`InvalidSpokeCodeHash`](IMarketRegistry.sol#L505), [`InvalidSpoke`](IMarketRegistryBase.sol#L34), [`InvalidDebtReserve`](IMarketRegistryBase.sol#L48), [`ListingCheckFailed`](IMarketRegistryBase.sol#L39), [`LivenessBound`](IMarketRegistryBase.sol#L104).
2. **AvanaTimelock → VaultTokenFactory `deployVaultToken` and the LPOracle proxy, earlier in the same normal-delay batch as separate timelock calls; then [`listCollateralMarket`](IMarketRegistry.sol#L66)**, which checks `VaultTokenFactory.tokenOf(spoke, marketKey)` against the vault token and its immutables (`VaultTokenMismatch`), calls the LPVault's `bindMarket` for a new market and runs `RiskModule.checkAaveConfig(spoke, [])`; market 1 is `Registered` (a new market past [`MAX_MARKET_COUNT`](IMarketRegistry.sol#L599) reverts [`MarketCountLimit`](IMarketRegistryBase.sol#L110); Closed and Cancelled markets count, a relisting does not). Then [`setRoute`](IMarketRegistryRoutes.sol#L12) sets the primary and backup USDT→USDC and USDC/USDT→GHO swap routes. Events: [`MarketRegistered`](IMarketRegistryBase.sol#L148), [`RouteSet`](IMarketRegistryBase.sol#L172). Errors: [`DuplicateMarketKey`](IMarketRegistryBase.sol#L15), [`InvalidRoute`](IMarketRegistryBase.sol#L20) (a route calling market 1's own pool or a recorded Uniswap v3 contract, or any route before the integration's record is finalized).
3. **AvanaTimelock → [`activateMarket`](IMarketRegistry.sol#L72)** (short delay) after ParameterStore `setInitialMarketParams` and caps: runs the activation checks (Hub shares equal assets, Aave config, oracle Live). Event: [`MarketActivated`](IMarketRegistryBase.sol#L160). Error: [`ActivationCheckFailed`](IMarketRegistryBase.sol#L41).
4. **RiskModule → [`recordBreach`](IMarketRegistry.sol#L305)** from the keeper's `pokeBreakers`: Avana holds 1,040 bps of the pool (illustrative per-pool cap 1,000 bps) at `t = 1,000`, so `lastBreachAt = 1,000` and new borrowing and pool-increasing pledges stop; with `gateRecoverySeconds = 1,800` the gate reopens at 2,800 if the share stays below 10%. A 10,000 GHO deficit latches `DEFICIT` on the GHO reserve. Events: [`GateBreached`](IMarketRegistryBase.sol#L199), [`BreakerLatched`](IMarketRegistryBase.sol#L195). Error: [`NotRiskModule`](IMarketRegistryBase.sol#L89).
5. **Emergency Guardian → [`tripMarketBreaker`](IMarketRegistry.sol#L312)`(1)`** once monitoring confirms the approved swap routes cannot settle liquidations at size (3 route failures in 1 hour is an alert, not a trip). Adds `MANUAL`. Later [`resetMarketBreaker`](IMarketRegistry.sol#L325) or [`resetDebtBreaker`](IMarketRegistry.sol#L331) clears latches. Event: [`BreakerReset`](IMarketRegistryBase.sol#L201). Errors: [`Unauthorized`](IMarketRegistryBase.sol#L66), [`NothingToReset`](IMarketRegistryBase.sol#L84), [`ConditionStillHolds`](IMarketRegistryBase.sol#L87).
6. **Emergency Guardian → [`freeze`](IMarketRegistry.sol#L232)`(hub)` or [`pause`](IMarketRegistry.sol#L238)`(hub, General)`** (immediate; the timelock at the short delay). Frozen stops new-account pledges and borrowing; `Paused(General)` also stops non-rescue top-ups and withdrawals with debt; `Paused(MintPathSuspect)` stops every mint. Repay, debt-free withdrawal, fee collection and liquidation never read it. [`unfreeze`](IMarketRegistry.sol#L255) / [`unpause`](IMarketRegistry.sol#L261) by the pause guardian or the timelock at the normal delay. Events: [`PauseStateChanged`](IMarketRegistryBase.sol#L183), [`PauseReasonChanged`](IMarketRegistryBase.sol#L187). Errors: [`AlreadyPaused`](IMarketRegistryBase.sol#L54), [`NotPaused`](IMarketRegistryBase.sol#L60), [`CannotUnfreezeWhilePaused`](IMarketRegistryBase.sol#L63).
7. **Emergency Guardian → [`freezeAddress`](IMarketRegistry.sol#L279)`(X)`**: X can no longer borrow, pledge a non-rescue top-up or call `liquidate`; X can still repay and exit debt-free. At most 20 freezes per caller in the 24 one-hour buckets ending with the current hour. The Aave V3 Pool behind the flash source and every recorded AMM contract are protected. Event: [`AddressFrozen`](IMarketRegistryBase.sol#L189). Errors: [`ProtectedAddress`](IMarketRegistryBase.sol#L72), [`FreezeLimitReached`](IMarketRegistryBase.sol#L81).
8. **Emergency Guardian → [`useStandbyRoute`](IMarketRegistry.sol#L369)`(USDT, Primary)`** at 09:12 when USDT's primary ($0.9900) and alternate ($0.9998) disagree (3.6 `EMG-107`); the standby reads $0.9997 and the next LPOracle `poke` serves Live. [`restorePriceRoute`](IMarketRegistry.sol#L382) later at the normal delay. If the Aave governance executor instead calls [`cancelStandbySwitch`](IMarketRegistry.sol#L376), no guardian can switch USDT again for 5 days ([`StandbySwitchLocked`](IMarketRegistry.sol#L365), [`standbySwitchLockedUntil`](IMarketRegistry.sol#L394)); the timelock's own switch or `setPriceSource` ends the lock. Events: [`StandbyRouteActivated`](IMarketRegistryBase.sol#L204), [`PriceRouteRestored`](IMarketRegistryBase.sol#L210).
9. **AvanaTimelock → [`disableRoute`](IMarketRegistryRoutes.sol#L20) / [`restoreRoute`](IMarketRegistryRoutes.sol#L31)** (short delay) for a failing swap route; LPVaultSwap falls back to the backup. Event: [`RouteDisabled`](IMarketRegistryBase.sol#L176).
10. **End of life:** [`setMarketOffboarding`](IMarketRegistry.sol#L83) (short delay) records the threshold `LT0` and publishes the target `⌊LT0 × 5,000 / 10,000⌋` (7,500 → 3,750 bps) and the earliest date, 5 days later, in [`windDownState`](IMarketRegistry.sol#L479); after that date the Aave DAO lowers the reserve's threshold once, to the target, in its own payload; [`closeMarket`](IMarketRegistry.sol#L473) ([body](MarketRegistryWindDownLogic.sol)) once the 5-day notice has run and Collateralization reports no indebted account. Events: [`MarketOffboarding`](IMarketRegistryBase.sol#L168), [`MarketClosed`](IMarketRegistry.sol#L458). Errors: [`OffboardNoticeRunning`](IMarketRegistry.sol#L466), [`MarketHasDebt`](IMarketRegistry.sol#L469).

## What the UI reads and calls

- Lens: [`getApplicationState`](../../lens/lens/ILensLiquidation.sol#L29), [`getPauseReason`](../../lens/lens/ILensLiquidation.sol#L35), [`getBreakerStatus`](../../lens/lens/ILensRisk.sol#L14), [`getDebtBreakerStatus`](../../lens/lens/ILensRisk.sol#L19), [`isFrozenAddress`](../../lens/lens/ILensRisk.sol#L25), [`getTailCoverage`](../../lens/lens/ILensRisk.sol#L31), [`getHubAssetExposure`](../../lens/lens/ILensRisk.sol#L43); direct views [`spokeImplementationStatus`](IMarketRegistry.sol#L521), [`creditLineCoverage`](IMarketRegistry.sol#L453), [`windDownState`](IMarketRegistry.sol#L485), [`getMarket`](IMarketRegistry.sol#L544), [`getRoute`](IMarketRegistry.sol#L664), [`activePriceRoutes`](IMarketRegistry.sol#L388).
- Events to index: `SpokeCodeHashApproved`, `IntegrationContractsRecorded`, `IntegrationContractsFinalized`, `FlashSourceSet`, `CreditLineSet`, `PauseStateChanged`, `PauseReasonChanged`, `AddressFrozen`, `AddressUnfrozen`, `BreakerLatched`, `GateBreached`, `BreakerReset`, `StandbyRouteActivated`, `MarketActivated`, `MarketOffboarding`, `MarketClosed`, `RouteDisabled`.
- User calls: [`closeMarket`](IMarketRegistry.sol#L473) (anyone); everything else is governance or guardian.

## Spec

- [2.8 Market Registry](../../../../docs/spec/02-contracts/08-market-registry.md): `REQ-MREG-006`–`REQ-MREG-010`, `REQ-MREG-024`–`REQ-MREG-027`, `REQ-MREG-030`–`REQ-MREG-035`, `REQ-CONFIG-016`–`REQ-CONFIG-048`, `REQ-CONFIG-080`, `REQ-CONFIG-081`, `SPEC-BRK-005`–`SPEC-BRK-008`, `SPEC-CAP-010`.
- Flows: [3.6 Emergency](../../../../docs/spec/03-operations/06-emergency-operations.md) `EMG-041`, `EMG-057`, `EMG-107`; [3.8 Market lifecycle](../../../../docs/spec/03-operations/08-market-lifecycle.md) `MKT-049`, `MKT-057`, `MKT-059`.
