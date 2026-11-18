---
title: Access Control
description: Who can upgrade, configure, pause and cover each Avana contract: roles, role holders, timelock delays and Aave governance controls.
updated: {{updated}}
---

Every chain has its own Avana Timelock, governance Safe, Emergency Guardian and Joint Configuration Safe, with the same roles; each network's role holders and timelock delays are in its section. No role on one chain can act on another chain. Each chain has one Hub (Avana Ethereum Hub, Avana Base Hub) that holds all of its Spokes: one Lend Spoke and every CDP Spoke. A per-Hub pause or freeze therefore covers the whole chain, and each debt asset has one First-Loss Reserve and one DAO deficit offset on that Hub. The Aave DAO administers the Hub, the Lend Spoke and the CDP Spokes; Avana holds no role on any of them.

The Avana Timelock is the only admin of every Avana contract. It is a non-upgradeable extension of the OpenZeppelin `TimelockController` and is its own admin. On every upgradeable Avana contract it holds `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`, and a grant of either role to any other account reverts `AdminRoleOnlyTimelock`. Immutable contracts check `msg.sender == TIMELOCK` instead of keeping roles. The deployer holds no role once deployment ends: the timelock is built with `admin = address(0)` and each proxy's `initialize` grants its admin roles to the timelock only.

Caps, collateral factors, liquidation bonuses, rate models, credit lines and First-Loss Reserve amounts are Aave-side values. The Aave DAO sets them through its payloads and ARFCs; Avana's timelock has no authority over them.

{{networks}}

## All networks

### Contracts

Upgradeable contracts are UUPS implementations behind a fixed ERC-1967 proxy. `_authorizeUpgrade` requires `APPLICATION_ADMIN`, which only the Avana Timelock holds, so every upgrade is a timelock operation at the normal delay. No Avana contract has an `Ownable` owner or a ProxyAdmin. The logic contracts an implementation delegates to are fixed in that implementation and change only with an upgrade.

| Contract | Upgradeable | Upgraded by | Delay | Source |
| --- | --- | --- | --- | --- |
| AvanaTimelock | No (immutable) | None | None | `REQ-ACCESS-013`, `AvanaCoreDeploy.sol:66-91` |
| MarketRegistry | UUPS proxy (ERC-1967) | Avana Timelock | Normal | `MarketRegistry.sol:467-469`, `REQ-ROLE-022` |
| ParameterStore | UUPS proxy (ERC-1967) | Avana Timelock | Normal | `ParameterStore.sol:268-270`, `REQ-ROLE-022` |
| RiskModule | UUPS proxy (ERC-1967) | Avana Timelock | Normal | `RiskModule.sol:522`, `REQ-ROLE-022` |
| AaveAdapter | UUPS proxy (ERC-1967) | Avana Timelock | Normal | `AaveAdapter.sol:363-365`, `REQ-ROLE-022` |
| LPVaultSwap | UUPS proxy (ERC-1967) | Avana Timelock | Normal | `LPVaultSwap.sol:322-324`, `REQ-ROLE-022` |
| LPOracle (one per market) | UUPS proxy (ERC-1967) | Avana Timelock | Normal | `LPOracle.sol:359-361`, `REQ-ROLE-022` |
| DebtOracle (one per non-GHO debt asset) | UUPS proxy (ERC-1967) | Avana Timelock | Normal | `DebtOracle.sol:465-467`, `REQ-ROLE-022` |
| Collateralization | No (immutable) | None | None | `REQ-ACCESS-066`, `AvanaPeripheryDeploy.sol:20` |
| Lock | No (immutable) | None | None | `REQ-ACCESS-066`, `Lock.sol:52` |
| ProxyManager | No (immutable) | None | None | `REQ-ACCESS-015`, `Q-375` |
| PositionProxy (one per wallet, CDP Spoke and market) | No (immutable, logic-free) | None; account logic changes only with an AaveAdapter upgrade | None | `REQ-ACCESS-147`, `Q-375` |
| VaultTokenFactory | No (immutable) | None | None | `REQ-ACCESS-010`, `VaultTokenFactory.sol:105-107` |
| Vault token (one per market) | No (immutable) | None | None | `REQ-ROLE-016`, `VaultToken.sol:86-88` |
| LPVault, Uniswap v3 (`UniswapV3Integration`) | No (immutable) | None | None | `REQ-ACCESS-060`, `ClLPVaultCustody.sol:161` |
| LPVault, Aero Slipstream (`SlipstreamIntegration`) | No (immutable) | None | None | `REQ-ACCESS-060`, `ClLPVaultCustody.sol:161` |
| LPVault, Uniswap v4 (`UniswapV4Integration`) | No (immutable) | None | None | `REQ-ACCESS-060`, `ClLPVaultCustody.sol:161`, `UniswapV4Integration.sol:45` |
| PayoutEscrow | No (immutable) | None | None | `REQ-ROLE-099`, `REQ-ROLE-100` |
| Flash source (`AaveV3FlashSource`) | No (immutable) | None; the Avana Timelock can replace it with `MarketRegistry.setFlashSource` | Normal (replacement) | `REQ-ACCESS-174`, `MarketRegistry.sol:118-120` |
| Public flash liquidation helper (`FlashLiquidator`) | No (immutable) | None | None | `REQ-ROLE-098` |
| Operator flash liquidation helper (`OperatorFlashLiquidator`) | No (immutable) | None | None | `REQ-ROLE-098`, `OperatorFlashLiquidator.sol:72-98` |
| Swap routes (`DexPathRoute`, `WrapperThenDexRoute`, `PegModuleRoute`) | No (immutable) | None; the Avana Timelock records a new route with `setRoute` | Normal (new route) | `REQ-ACCESS-046`, `SwapRouteBase.sol:89` |
| Lens | No (immutable) | None; replaced by a new deployment | None | `Q-288`, `REQ-ACCESS-066` |
| AvanaGasVault | No (immutable) | None | None | `REQ-GASV-001`, `12_DeployGasVault.s.sol:12-27` |
| First-Loss Reserve (`AvanaFirstLossReserve`, one per debt asset on the chain's Hub) | No (immutable) | None; the Aave DAO controls it through its AccessManager | None | `REQ-FLR-008`, `07_DeployAvanaFirstLossReserves.s.sol:100-112` |
| DAO deficit offset (`DaoDeficitOffset`, one per debt asset on the chain's Hub) | No (immutable) | None; deployed and controlled by the Aave DAO | None | `Q-410`, `08_AaveLossLayersPayload.s.sol:170-179` |

> Each chain has one Avana Hub. It holds the Lend Spoke and every CDP Spoke of that chain, from Stable to Stocks; each Spoke sets its own risk parameters.

### Roles

Delay is the wait before the holder's call takes effect. Granting or revoking any Avana role is a role-change operation at the normal delay that only the Aave governance executor can cancel (`REQ-ROLE-006`). Each network's short and normal delays are in its Timelock section. The guardian and risk-steward roles are granted by the first timelock operation after deployment (`04_ConfigureAccess.s.sol:107-142`).

| Role | Contract | Held by | Gated functions | Delay | Source |
| --- | --- | --- | --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | AvanaTimelock | Avana Timelock (itself only) | `grantRole`, `revokeRole` of the timelock's own roles | Normal (role-change operation) | `AvanaTimelock.sol:351-377`, `REQ-ACCESS-001` |
| `PROPOSER_ROLE` | AvanaTimelock | Governance Safe, Aave governance executor | `schedule`, `scheduleBatch` | None (immediate); the call queues an operation | `AvanaCoreDeploy.sol:70-71`, `REQ-ACCESS-004` |
| `CANCELLER_ROLE` | AvanaTimelock | Governance Safe, Emergency Guardian, Aave Protocol Guardian, Aave governance executor | `cancel` of any queued operation that is not a role-change or restoring operation | None (immediate) | `AvanaTimelock.sol:202-210`, `AvanaCoreDeploy.sol:74-76`, `REQ-ACCESS-005` |
| `DAO_CANCELLER_ROLE` | AvanaTimelock | Aave governance executor | `cancel` of role-change and restoring operations (together with `CANCELLER_ROLE`) | None (immediate) | `AvanaTimelock.sol:205-207`, `REQ-ACCESS-006` |
| `EXECUTOR_ROLE` | AvanaTimelock | Governance Safe; anyone while public execution is on (each network's setting is in its Timelock section) | `execute`, `executeBatch` of a ready operation | None once the operation is ready; expires after 14 days | `AvanaTimelock.sol:396`, `AvanaCoreDeploy.sol:72-73,88`, `REQ-ACCESS-007` |
| Self-call (not a role) | AvanaTimelock | Avana Timelock | `setNormalDelay`, `setShortDelaySelector`, `togglePublicExecution` | Normal | `AvanaTimelock.sol:116-119,225-252`, `REQ-ACCESS-029` |
| `DEFAULT_ADMIN_ROLE` | AaveAdapter, RiskModule, MarketRegistry, ParameterStore, each LPOracle, each DebtOracle, LPVaultSwap | Avana Timelock | `grantRole`, `revokeRole` | Normal (role-change operation) | `MarketRegistry.sol:161-169`, `REQ-ACCESS-002` |
| `APPLICATION_ADMIN` | MarketRegistry | Avana Timelock | `recordHub`, `registerIntegration`, `setAvanaFirstLossReserve`, `setCrossHubLine`, `setCrossHubLinesEnabled`, `setFlashSource`, `approveSpokeCodeHash`, `recordIntegrationContracts`, `finalizeIntegrationContracts`, `deployCdpSpoke`, `enableDebtReserve`, `removeDebtReserve`, `listToken`, `setPriceSource`, `listCollateralMarket`, `activateMarket`, `cancelRegistration`, `setMarketOffboarding`, `setRoute`, `disableRoute`, `restoreRoute`, `useStandbyRoute`, `restorePriceRoute`, `freeze`, `pause`, `freezeAll`, `pauseAll`, `unfreeze`, `unpause`, `freezeAddress`, `unfreezeAddress`, `tripMarketBreaker`, `tripDebtBreaker`, `resetMarketBreaker`, `resetDebtBreaker`, `setSettlementReserve`, `recordCreditLine`, `upgradeToAndCall` | Short for selectors on the short list; normal for all others | `MarketRegistry.sol:70-469`, `TimelockSelectors.sol:61-75`, `REQ-ACCESS-003` |
| `APPLICATION_ADMIN` | ParameterStore | Avana Timelock | Every `tighten*` and `loosen*` setter, `setAvanaFeeShareBps`, `setFeeRecipient`, `setMaxFlashFeeBps`, `setSecondSource`, `restoreSecondSource`, `setFeed`, `setTwapWindow`, `setCachedWindow`, `setDisagreementPauseMax`, `setUsdBand`, `setBorrowPriceMaxAge`, `setLiquidationPriceMaxAge`, `setFeedMaxAge`, `setGraceDuration`, `setGraceHealthFactor`, `setConsistencyToleranceBps`, `setFeedAgreementToleranceBps`, `setFeedAgreementMarginBps`, `setPoolRiskFactor`, `setSlippageAllowanceMinBps`, `setTokenCollateralFactorBps`, `setStressFloorUsd`, `setInitialMarketParams`, `setInitialMarketCaps`, `setInitialTokenCap`, `setDebtAssetParams`, `setLiquidationExpectations`, `setSequencer`, `setCoverageRatioBps`, `upgradeToAndCall` | Short for the 21 `tighten*` setters; normal for all others | `ParameterStore.sol:171-270`, `ParameterStoreForwardAdmin.sol:23-262`, `ParameterStoreForwardRisk.sol:19-235`, `ParameterStoreForwardSpeed.sol:36-68` |
| `APPLICATION_ADMIN` | LPVaultSwap | Avana Timelock | `addKeeper`, `removeKeeper`, `upgradeToAndCall` | `addKeeper`: normal (DAO-only cancel); `removeKeeper`: short | `LPVaultSwap.sol:158-190`, `REQ-ROLE-045`, `REQ-ROLE-046` |
| `APPLICATION_ADMIN` | Each LPOracle, each DebtOracle | Avana Timelock | `setPokeMinGas`, `upgradeToAndCall` | Normal | `LPOracle.sol:335-337`, `DebtOracle.sol:187-189`, `REQ-ROLE-092` |
| `APPLICATION_ADMIN` | AaveAdapter, RiskModule | Avana Timelock | `upgradeToAndCall` only | Normal | `AaveAdapter.sol:363-365`, `RiskModule.sol:522`, `REQ-ACCESS-066` |
| `APPLICATION_PAUSE_GUARDIAN` | MarketRegistry | Emergency Guardian, Aave Protocol Guardian, Joint Configuration Safe | `pause`, `pauseAll`, `unpause`, `unfreeze`, `resetMarketBreaker`, `resetDebtBreaker`, `useStandbyRoute` | None (immediate); a guardian's `useStandbyRoute` waits 5 days after an Aave DAO `cancelStandbySwitch` of the same token | `MarketRegistry.sol:272-358,408-423`, `MarketRegistryStorage.sol:143`, `REQ-ACCESS-008` |
| `APPLICATION_FREEZE_GUARDIAN` | MarketRegistry | Emergency Guardian, Aave Protocol Guardian, Joint Configuration Safe | `freeze`, `freezeAll`, `freezeAddress`, `tripMarketBreaker`, `tripDebtBreaker` | None (immediate); at most 20 address freezes per caller in 24 hours | `MarketRegistry.sol:309-331,362-367,389-404`, `REQ-ACCESS-009`, `REQ-ACCESS-157` |
| `APPLICATION_PAUSE_GUARDIAN` | ParameterStore | Emergency Guardian, Aave Protocol Guardian | `useStandbySecondSource` | None (immediate) | `ParameterStoreForwardAdmin.sol:101-103`, `Q-385` |
| `APPLICATION_RISK_STEWARD` | ParameterStore | Joint Configuration Safe | The 21 `tighten*` setters, each with every check of the timelock path; `setAvanaFeeShareBps` in either direction within 0 to 5,000 bps | None (immediate) | `ParameterStoreRouter.sol:86-96`, `REQ-ACCESS-185`, `REQ-ROLE-117` |
| `TIMELOCK` immutable (not a role) | Each LPVault, VaultTokenFactory | Avana Timelock | `returnStray`; `registerIntegration`, `deployVaultToken` | Normal | `ClLPVaultCustody.sol:157-161`, `VaultTokenFactory.sol:105-157`, `REQ-ACCESS-010` |
| `AAVE_GOVERNANCE_EXECUTOR` immutable (not a role) | MarketRegistry | Aave governance executor | `cancelStandbySwitch` | None (immediate) | `MarketRegistry.sol:288-293`, `REQ-ACCESS-159` |
| `TIMELOCK` immutable (not a role) | AvanaGasVault | Avana Timelock | `addSigner`, `setSignerConfig`, `unpause`, `withdraw` (to the fee recipient), and also `tightenSigner`, `removeSigner`, `pause` | Normal | `AvanaGasVault.sol:69-77,175-262`, `REQ-ROLE-118` |
| `GUARDIAN` immutable (not a role) | AvanaGasVault | Emergency Guardian | `tightenSigner`, `removeSigner`, `pause`: the guardian can only make the vault send less | None (immediate) | `AvanaGasVault.sol:74-77,229-262`, `REQ-ROLE-118`, `REQ-GASV-009` |
| `SIGNER` immutable (not a role) | OperatorFlashLiquidator | Liquidation keeper | `flashLiquidate`, `claimEscrowed` (credits go to the keeper funding Safe) | None (immediate) | `OperatorFlashLiquidator.sol:72-98`, `REQ-ROLE-098` |
| Committed operator (keeper list, not a role) | LPVaultSwap | Liquidation keeper | None: the list gates no call. It counts toward `keeperFloor` (1) and new borrowing halts with no active committed operator | Added at normal delay, removed at short delay | `LPVaultSwap.sol:158-190`, `Q-404`, `REQ-ROLE-081` |
| `COVERAGE_ROLE` (Aave AccessManager) | Each First-Loss Reserve and each DAO deficit offset | Emergency Guardian, Aave Protocol Guardian | `coverDeficit` | None (immediate); granted and revoked by the Aave DAO | `08_AaveLossLayersPayload.s.sol:102-115,206-214`, `Q-142` |
| `RESERVE_ADMIN_ROLE` (Aave AccessManager) | Each First-Loss Reserve and each DAO deficit offset | Aave governance executor | `setAllowedBorrowSpoke`, `setFirstLossReserveMinimum`, `requestWithdrawal`, `cancelWithdrawal`, `executeWithdrawal` | Aave governance; withdrawals execute 14 days after the request | `08_AaveLossLayersPayload.s.sol:114,208-215`, `REQ-FLR-023` |
| `HUB_DEFICIT_ELIMINATOR_ROLE` (Aave role 103) | Hub | Each First-Loss Reserve and each DAO deficit offset | `eliminateDeficit` | Aave governance | `08_AaveLossLayersPayload.s.sol:63,205` |

> The code has 21 `tighten*` setters (`TimelockSelectors.sol:102-126`; `tightenDepositorUsdCap` was removed), matching `REQ-ACCESS-185`, `REQ-ROLE-117` and the 2.15 short-delay list. The 2.15 actor table and the 1.4 `APPLICATION_RISK_STEWARD` row still say 20, and the NatSpec still says 22 (`AvanaRoles.sol:29`, `TimelockSelectors.sol:58-59`, which also says 34 short-list selectors instead of 33).

> The 1.4 "Immediate (guardian)" delay class does not list `freezeAll` and `pauseAll`. The code lets the guardians call both (`MarketRegistry.sol:328-340`), which matches 2.15 `REQ-ACCESS-172`.

> The 1.4 and 2.15 `TIMELOCK` rows name only `returnStray` and `deployVaultToken`. The code also limits `VaultTokenFactory.registerIntegration` to the timelock (`VaultTokenFactory.sol:117-120`), and the chain-wiring operation calls it (`04_ConfigureAccess.s.sol:174-179`).

> `COVERAGE_ROLE` and `RESERVE_ADMIN_ROLE` use role IDs 500 and 501 on local and test networks. The mainnet IDs are TBD: Aave governance assigns them, and the script refuses the test IDs on Ethereum and Base (`08_AaveLossLayersPayload.s.sol:58-60,80-84`).

### Timelock delays

The delay is set by the calls in an operation, not by the proposer: an operation takes the short delay only when every call is on the short list. Every operation can be executed for 14 days after it is ready and then expires.

| Action class | Delay | Functions | Source |
| --- | --- | --- | --- |
| Short | `SHORT_DELAY`, per network | ParameterStore: the 21 `tighten*` setters (`tightenHardHealthFloor`, `tightenSlippageAllowanceBps`, `tightenFloorRoundingAllowance`, `tightenBorrowPriceMaxAge`, `tightenConsistencyToleranceBps`, `tightenFeedAgreementToleranceBps`, `tightenPoolRiskFactor`, `tightenRouteDepthThreshold`, `tightenMarketUsdCap`, `tightenTopUpSliceUsd`, `tightenTokenUsdCap`, `tightenPoolShareMaxBps`, `tightenPoolShareMaxBpsOf`, `tightenMinPledgeUsd`, `tightenBreakerDeficitMax`, `tightenGateRecoverySeconds`, `tightenMaxShortfallBps`, `tightenDebtStressRiseBps`, `tightenMaxFlashFeeBps`, `tightenMarketSpeedLimits`, `tightenDebtSpeedLimit`); MarketRegistry: `disableRoute`, `restoreRoute`, `setMarketOffboarding`, `activateMarket`, `cancelRegistration`, `freeze`, `pause`, `freezeAddress`, `tripMarketBreaker`, `tripDebtBreaker`, `useStandbyRoute`; LPVaultSwap: `removeKeeper` | `AvanaTimelock.sol:26`, `TimelockSelectors.sol:58-75`, `REQ-ACCESS-141` |
| Normal | `normalDelay`, per network, settable within `MIN_NORMAL_DELAY` to `MAX_DELAY` | Every call not on the short list, including upgrades, `freezeAll` and `pauseAll` by the timelock, and `unfreeze`, `unpause`, breaker resets, `unfreezeAddress` and `restorePriceRoute` by the timelock, and every AvanaGasVault call by the timelock | `AvanaTimelock.sol:28-30,225-231`, `AvanaCoreDeploy.sol:88`, `SPEC-GOV-003` |
| Never short | Normal | `grantRole`, `revokeRole`, `renounceRole`, `upgradeToAndCall`, `setFlashSource`, `deployCdpSpoke`, `listCollateralMarket`, `enableDebtReserve`, `setCrossHubLinesEnabled`, `setCrossHubLine`, every Avana `initialize` | `TimelockSelectors.sol:46-56`, `REQ-ACCESS-142` |
| Role change (DAO-only cancel) | Normal | Operations in which every call is `grantRole`, `revokeRole` or `renounceRole`; only the Aave governance executor can cancel them | `AvanaTimelock.sol:206`, `REQ-ACCESS-019` |
| Restoring (DAO-only cancel) | Short or normal, by selector | Operations in which every call is `restoreRoute`, `useStandbyRoute`, `unfreezeAddress` or `addKeeper`; only the Aave governance executor can cancel them | `AvanaTimelock.sol:207`, `TimelockSelectors.sol:77-86`, `REQ-ACCESS-156` |
| Immediate | None | Guardian calls (including the Emergency Guardian's AvanaGasVault `tightenSigner`, `removeSigner` and `pause`), risk-steward calls, `cancelStandbySwitch` and `cancel` (outside the timelock queue) | `REQ-ROLE-105`, `REQ-ACCESS-172`, `REQ-ROLE-118` |
| Grace period | 1,209,600 s (14 days) after the ready time | Every scheduled operation; an expired operation can only be cleaned up | `AvanaTimelock.sol:32,324-330`, `SPEC-GOV-002` |
| `updateDelay` | Disabled | Always reverts `UpdateDelayDisabled`; `getMinDelay()` always returns the short delay | `AvanaTimelock.sol:254-268`, `REQ-ACCESS-030` |
| First-Loss Reserve withdrawal (Aave-side) | 1,209,600 s (14 days) | `requestWithdrawal` then `executeWithdrawal` on each First-Loss Reserve and DAO deficit offset | `07_DeployAvanaFirstLossReserves.s.sol:107`, `08_AaveLossLayersPayload.s.sol:174`, `REQ-FLR-008` |

### Aave governance controls

The Aave DAO controls the Hub, the Spokes and the First-Loss Reserves, and holds a proposer and veto seat on each Avana Timelock. Avana holds no role on any Aave contract.

| Control | Held by | What it covers | Source |
| --- | --- | --- | --- |
| Hub and Spoke configuration | Aave governance executor | The chain's single Hub: its assets and rate curves, Spoke registrations, supply and draw caps, collateral factors, liquidation bonus and target health factor, reserve flags, and every upgrade of the Hub and Spoke proxies | `REQ-ROLE-056`, `REQ-ACCESS-071` |
| Risk values | Aave DAO (payloads and ARFCs) | Caps, collateral factors, bonuses, rate models, credit lines and First-Loss Reserve amounts. Avana's values are recommendations | `REQ-ROLE-067`, `Q-391` |
| Lend Spoke | Aave governance executor | The Hub's one Lend Spoke: supply-only, open to every lender, supply cap set by the DAO. Avana holds no role on it | `06_AaveDeploymentPayload.s.sol:58-70`, `chain.ts:136-143` (`stack/hub-structure-only`), `REQ-ACCESS-071` |
| Credit lines | Aave governance executor | Each CDP Spoke's `drawCap` per (Hub, asset) and the Lend Spoke's `addCap`; Avana records the line and checks the sum | `REQ-ACCESS-071`, `Q-282`, `Q-407` |
| Deployment payload (06) | Aave governance executor | Hub asset per debt asset with its rate curve; the Lend Spoke and each CDP Spoke; debt reserves (CDP ones not borrowable); CDP liquidation configuration; bootstrap supply on test networks; `FLASH_BORROWER` for the flash source and the public flash liquidation helper | `06_AaveDeploymentPayload.s.sol:58-70,264-272` |
| Loss-layers payload (08) | Aave governance executor | One DAO deficit offset behind each First-Loss Reserve; `HUB_DEFICIT_ELIMINATOR_ROLE` for both layers; `COVERAGE_ROLE` to the Emergency Guardian and the Aave Protocol Guardian; `RESERVE_ADMIN_ROLE` to the executor; CDP Spoke allowlists, minimums and DAO offset funding | `08_AaveLossLayersPayload.s.sol:48-57,102-115` |
| Listing payload (10) | Aave governance executor | Debt reserves: price source and `borrowable = true`. Markets: the vault token as a Hub asset with `drawCap = 0`, and the collateral reserve priced by the market's LPOracle with `borrowable = false`, `receiveSharesEnabled = false` and `liquidationFee = 0` | `10_AaveListingPayload.s.sol:24-33` |
| `COVERAGE_ROLE` | Emergency Guardian, Aave Protocol Guardian; granted and revoked by the Aave DAO | `coverDeficit` on each First-Loss Reserve, then on its DAO deficit offset once the reserve is exhausted, for allowlisted CDP Spokes only | `08_AaveLossLayersPayload.s.sol:112-113`, `Q-142`, `Q-410` |
| `RESERVE_ADMIN_ROLE` | Aave governance executor | First-Loss Reserve allowlist, minimum and withdrawals (14-day delay) | `08_AaveLossLayersPayload.s.sol:114`, `REQ-FLR-023` |
| SpokeConfigurator `freezeReserve`, `pauseReserve` | Aave Protocol Guardian (one-way) and the Aave DAO | Freeze and pause of CDP Spoke reserves; freeze only of Lend Spoke reserves. Only the DAO unfreezes or unpauses | `REQ-ROLE-057`, `REQ-ACCESS-070`, `Q-408` |
| `SPOKE_USER_POSITION_UPDATER_ROLE` | Aave governance executor | `updateUserRiskPremium` and `updateUserDynamicConfig` for Avana proxies | `REQ-ROLE-058`, `Q-145` |
| Avana Timelock seats | Aave governance executor | `PROPOSER_ROLE`, `CANCELLER_ROLE` and `DAO_CANCELLER_ROLE`: proposes, cancels any operation, and is the only canceller of role-change and restoring operations | `AvanaCoreDeploy.sol:70-78`, `REQ-ROLE-005` |
| Standby route reversal | Aave governance executor | `cancelStandbySwitch` undoes a guardian's standby price-route switch at once | `MarketRegistry.sol:288-293`, `REQ-ACCESS-159` |

> The spec says the deployment AIP grants the Aave Protocol Guardian `freezeReserve` and `pauseReserve` (`REQ-ACCESS-070`). `06_AaveDeploymentPayload.s.sol` contains no such grant, so where that grant is made is TBD.

> `REQ-FLR-009` and the code agree that the loss-layers payload grants `COVERAGE_ROLE` (`08_AaveLossLayersPayload.s.sol:112-113`). The 2.14 permissions list still says it is granted in the Aave DAO's listing payload.

### Permissionless functions

These functions carry no role. Repay, fee collection, debt-free withdrawal, zero-credit release, liquidation and pending settlement never read the pause state, a breaker or the address freeze, except the freeze check on the caller of `liquidate` (`REQ-ROLE-068`).

| Function | Contract | Notes | Source |
| --- | --- | --- | --- |
| `liquidate` | LPVaultSwap | The one liquidation entry point. Any address that is not frozen; the keeper list gates no call. Never blocked by the pause state or a breaker | `LPVaultSwap.sol:73`, `REQ-ROLE-043`, `Q-404` |
| `settlePending` | LPVaultSwap | Anyone. The caller receives nothing; recovered value goes to the First-Loss Reserve of the market's debt reserve | `LPVaultSwap.sol:87`, `REQ-ROLE-097` |
| `flashLiquidate`, `claimEscrowed` | Public flash liquidation helper | Any caller. Calls `liquidate` as an ordinary caller and pays only its caller; `claimEscrowed` sends credits to `feeRecipient`. A frozen address can still liquidate through it | `FlashLiquidatorBase.sol:112,188`, `REQ-ROLE-098` |
| `repay` | AaveAdapter | Any payer, for any borrower, with its own funds | `AaveAdapter.sol:108`, `REQ-ROLE-018` |
| `pledge`, `recredit`, `borrow`, `withdraw`, `removeLiquidity`, `repayAllAndWithdraw`, `repayWithCollateral`, `collectFees`, `releaseZeroCredit` | AaveAdapter | Any wallet, only for its own proxy or its own records. New-activity calls are gated by the pause state, breakers and the address freeze | `REQ-ROLE-010`, `REQ-ROLE-011`, `REQ-ROLE-018`, `REQ-ROLE-115` |
| `poke` | Each LPOracle | Anyone; needs `pokeMinGas` | `LPOracle.sol:226`, `REQ-ROLE-041` |
| `poke` | Each DebtOracle | Anyone; needs `pokeMinGas` | `DebtOracle.sol:152`, `REQ-ROLE-113` |
| `pokeBreakers` | RiskModule | Anyone. Records breaches and latches only for conditions that hold in the same call | `RiskModule.sol:233`, `REQ-ROLE-050` |
| `syncDrawCap` | MarketRegistry | Anyone. Re-reads a CDP Spoke's live `drawCap` into the credit-line sum | `MarketRegistry.sol:458-463`, `REQ-CONFIG-081` |
| `closeMarket` | MarketRegistry | Anyone, for an offboarding market with no debt after the 5-day notice | `MarketRegistry.sol:431-435`, `REQ-CONFIG-080` |
| `claim` | PayoutEscrow | Only the credited recipient, for all or part of its own credit; no role can block or redirect it | `PayoutEscrow.sol:106,118`, `REQ-ROLE-100` |
| `fund` | Each First-Loss Reserve | Anyone (Avana Labs and LPVaultSwap in practice) | `AvanaFirstLossReserve.sol:116`, `Q-142` |
| `topUp`, `topUpAll`, `fund` | AvanaGasVault | Anyone. A top-up sends gas only to an allowlisted keeper signer below its minimum, within its 24-hour cap | `AvanaGasVault.sol:116-143`, `REQ-GASV-001` |
| `execute`, `executeBatch` | AvanaTimelock | Anyone while public execution is on (each network's setting is in its Timelock section), once the operation is ready and before it expires | `AvanaTimelock.sol:396`, `REQ-ROLE-101` |
| `cleanupExpiredOperation` | AvanaTimelock | Anyone, for an expired operation only | `AvanaTimelock.sol:213-220`, `REQ-ROLE-102` |
