---
title: Access Control
description: Who can configure, list, cover and withdraw on each Avana contract: AccessManager roles, role holders, execution delays and Aave governance controls.
updated: {{updated}}
---

Every chain has its own Avana AccessManager, governance Safe and Joint Configuration Safe, with the same roles; each network's role holders and governance delay are in its section. No role on one chain can act on another chain. The Aave DAO administers the Hubs, the Lend Spokes and the CDP Spokes; Avana holds no role on any of them.

Avana's AccessManager is an unmodified OpenZeppelin `AccessManager` and the only authority of every Avana core contract. Its admin (`ADMIN_ROLE`) is the Aave governance executor: the deployer grants it during `03_DeployAvana` and renounces the role in the same run. No Avana contract is upgradeable, has an owner or keeps roles of its own; each restricted function is mapped to one role, and a role's holder calls it after that holder's execution delay.

Collateral factors, caps, liquidation bonuses, rate curves and First-Loss Reserve minimums are Aave-side values. The Aave DAO sets them through its payloads; Avana's AccessManager has no authority over them.

{{networks}}

## All networks

### Contracts

| Contract | Upgradeable | Authority | Source |
| --- | --- | --- | --- |
| AccessManager (OpenZeppelin) | No | Its own `ADMIN_ROLE`, held by the Aave governance executor | `03_DeployAvana.s.sol` |
| LPVault, one per integration (`UniswapV3Integration`, `UniswapV4Integration`, `SlipstreamIntegration`) | No | Avana's AccessManager | `LPVault.sol` |
| RiskModule, one per integration | No | Avana's AccessManager | `RiskModule.sol` |
| LiquidationModule, one per integration | No | None: no admin | `LiquidationModule.sol` |
| AaveAdapter, one per integration | No | None: no admin | `AaveAdapter.sol` |
| AccountProxy, one per wallet and market | No | None: only its AaveAdapter acts for it, and only for its wallet | `AccountProxy.sol` |
| FlashloanRepay, one per integration | No | None: no admin | `FlashloanRepay.sol` |
| VaultToken, one per market | No | Avana's AccessManager | `VaultToken.sol` |
| LPOracle, one per market | No | None: stateless | `LPOracle.sol` |
| FirstLossReserve, two per (Hub, debt asset): Avana's First-Loss Reserve and the DAO deficit offset | No | The Aave AccessManager | `FirstLossReserve.sol`, `07_DeployFirstLossReserves.s.sol` |
| FlashLiquidator, one per integration and operator | No | None: only its `OPERATOR` calls it | `packages/liquidator/src/FlashLiquidator.sol`, `03_DeployAvana.s.sol` |

### Roles on Avana's AccessManager

Delay is the holder's execution delay: a call by a holder with a delay is scheduled first and executed once the delay has passed. The governance delay of each network is in its section.

| Role | Id | Held by | Functions | Delay | Source |
| --- | --- | --- | --- | --- | --- |
| `ADMIN_ROLE` | 0 | Aave governance executor | Every admin function of the AccessManager (`grantRole`, `revokeRole`, `setTargetFunctionRole`, `labelRole`, `setRoleGuardian` and the rest); as the default guardian of every role, `cancel` of any scheduled call | None | `AvanaRoles.sol`, `03_DeployAvana.s.sol` `_configureRoles` |
| `AVANA_GOVERNANCE_ROLE` | 2 | Governance Safe | RiskModule `registerSpoke`, `setSpokeWidth`, `listPool`, `activateMarket`, `setDebtReserve`, `setCoverageRatio`, `setFee`, `addKeeper` | Governance delay, 4 to 5 days | `AvanaAccess.sol` `riskModuleGovernanceSelectors` |
| `AVANA_TIGHTEN_ROLE` | 1 | Governance Safe; Joint Configuration Safe | RiskModule `removeDebtReserve`, `removeKeeper` | 12 hours for the governance Safe; none for the Joint Configuration Safe | `AvanaAccess.sol` `riskModuleTightenSelectors`, `TIGHTEN_DELAY` |
| `AVANA_RESERVE_WITHDRAW_ROLE` | 3 | — | Labelled on Avana's AccessManager; no Avana function is mapped to it. The loss layers' withdraw role is on the Aave AccessManager (below) | — | `AvanaRoles.sol`, `03_DeployAvana.s.sol` |
| `AVANA_I<n>_RISK_MODULE_ROLE` | 100·n + 1 | Integration n's RiskModule | LPVault `listMarket` | None | `AvanaAccess.sol` `coreRole`, `lpVaultRiskSelectors` |
| `AVANA_I<n>_ADAPTER_ROLE` | 100·n + 2 | Integration n's AaveAdapter | LPVault `pledge`, `addLiquidity`, `removeLiquidity`, `release`, `collectFees`; each of its vault tokens' `mint` and `addValidProxy` | None | `AvanaAccess.sol` `lpVaultAdapterSelectors`, `vaultTokenAdapterSelectors` |
| `AVANA_I<n>_LIQUIDATION_ROLE` | 100·n + 3 | Integration n's LiquidationModule | LPVault `unwind` | None | `AvanaAccess.sol` `lpVaultLiquidationSelectors` |
| `AVANA_I<n>_BURN_ROLE` | 100·n + 4 | Integration n's AaveAdapter and LiquidationModule | Each of its vault tokens' `burn` | None | `AvanaAccess.sol` `vaultTokenBurnSelectors` |

> Core roles are per integration, so one integration's AaveAdapter cannot call another integration's LPVault. The vault tokens' function roles are set by the vault-token role operation, which the Aave governance executor sends as the AccessManager's admin (`09_ListMarkets.s.sol` `_sendAsAdmin`).

### Roles on the Aave AccessManager

The Aave DAO grants these through its payloads; the role ids come from the deploy config (`aavePayload.lossLayerRoles`, `aavePayload.guardianRole`).

| Role | Held by | Functions | Delay | Source |
| --- | --- | --- | --- | --- |
| Coverage role | The coverage caller: the Aave governance executor unless the loss-layers AIP names another | `coverDeficit` on each First-Loss Reserve and DAO deficit offset | None | `08_AaveLossLayersPayload.s.sol` |
| Reserve-admin role | Aave governance executor | `setAllowedSpoke`, `setMinimum` on each loss layer | None | `08_AaveLossLayersPayload.s.sol`, `AvanaAccess.sol` `reserveAdminSelectors` |
| Withdraw role | Aave governance executor | `withdraw` on each loss layer; reverts while an allowed Spoke has a recorded deficit | 14 days (`WITHDRAWAL_DELAY`) | `08_AaveLossLayersPayload.s.sol`, `FirstLossReserve.sol` |
| `HUB_DEFICIT_ELIMINATOR_ROLE` (Aave role 103) | Each First-Loss Reserve and DAO deficit offset | Hub `eliminateDeficit` | Aave governance | `08_AaveLossLayersPayload.s.sol` |
| `AVANA_RESERVE_GUARDIAN_ROLE` | Aave Protocol Guardian, Aave governance executor | SpokeConfigurator `freezeReserve`, `pauseReserve`: each sets its flag and never clears it | None | `AaveGuardianRole.sol`, `06_AaveDeploymentPayload.s.sol` |

### Aave governance controls

| Control | Held by | What it covers | Source |
| --- | --- | --- | --- |
| Hub and Spoke configuration | Aave governance executor | Each Hub's assets and rate curves, Spoke registrations, add and draw caps, collateral factors, liquidation configuration, reserve flags, and every upgrade of the Hub and Spoke proxies | `01_DeployAaveV4.s.sol`, `06_AaveDeploymentPayload.s.sol` |
| Deployment payload (06) | Aave governance executor | Each debt asset on each Hub with its rate curve; the Lend Spoke and the CDP Spokes on it; the CDP debt reserves, not borrowable yet; each CDP Spoke's liquidation configuration, copied from its price Spoke; the Guardian's freeze and pause role; `FLASH_BORROWER` on Aave V3 for the FlashLiquidators | `06_AaveDeploymentPayload.s.sol` |
| Loss-layers payload (08) | Aave governance executor | Both loss layers listed on their Hub asset with no draw and `HUB_DEFICIT_ELIMINATOR_ROLE`; their function roles; each layer's allowed CDP Spokes and minimum | `08_AaveLossLayersPayload.s.sol` |
| Listing payload (10) | Aave governance executor | Each AaveAdapter as a position manager on its CDP Spokes; the debt reserves made borrowable; each market's vault token on the Hub and on its CDP Spoke, priced by its LPOracle, with the LTV as collateral factor, the market's add cap, no draw, liquidation fee 0, not borrowable and no share transfers | `10_AaveListingPayload.s.sol` |
| Avana's AccessManager | Aave governance executor | `ADMIN_ROLE`: every Avana role grant and function mapping, and cancellation of any scheduled Avana call | `03_DeployAvana.s.sol` |

### Permissionless functions

| Function | Contract | Notes | Source |
| --- | --- | --- | --- |
| `liquidate` | LiquidationModule | Open to anyone; the keeper registry gates no call. Reverts with Aave's errors when the account is healthy | `ILiquidationModule.sol` |
| `repay` | AaveAdapter | Any payer, for any wallet's debt in a market, with its own funds | `IAaveAdapter.sol` |
| `pledge`, `addLiquidity`, `withdraw`, `allowWithdraw`, `borrow`, `collectFees` | AaveAdapter | Any wallet, for its own account and positions only (and `withdraw`, in part, by the operator of an open `allowWithdraw`); `borrow` passes `RiskModule.checkBorrow` and Aave's health check | `IAaveAdapter.sol` |
| `fund` | Each First-Loss Reserve and DAO deficit offset | Anyone; the funder gets no claim | `IFirstLossReserve.sol` |
