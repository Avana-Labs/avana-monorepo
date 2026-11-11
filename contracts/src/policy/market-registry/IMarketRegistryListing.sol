// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketDef} from "../../types/MarketDef.sol";
import {DebtReserveDef} from "./types/DebtReserveDef.sol";
import {SpokeDef} from "./types/SpokeDef.sol";
import {TokenDef} from "./types/TokenDef.sol";

/// @title IMarketRegistryListing
/// @notice Governance listing of the MarketRegistry: initialization, the three deployment operations
/// (`deployCdpSpoke`, `listCollateralMarket`, `enableDebtReserve`), pool tokens and debt assets with their Chainlink
/// routes, and market activation, cancellation and offboarding.
/// @dev Every function except `initialize` requires `APPLICATION_ADMIN` (the Avana timelock); each function's developer note names the
/// delay class.
interface IMarketRegistryListing {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, atomically with the proxy deployment. Grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to
    /// `timelock`, sets `APPLICATION_ADMIN` as admin of both guardian roles, and leaves every Hub's pause state `None`.
    /// Reverts `AdminRoleOnlyTimelock` unless `timelock == TIMELOCK`.
    /// @param timelock The Avana timelock.
    /// @custom:spec REQ-CONFIG-002, REQ-MREG-005, Q-228, Q-259
    function initialize(
        address timelock
    ) external;

    /// @notice Records a CDP Spoke: the standard, unmodified Aave V4 Spoke that the Aave payload deployed with its
    /// AaveOracle, under its home Hub with one AMM integration and one risk tier; or re-approves a recorded Spoke after
    /// an Aave DAO upgrade of its implementation.
    /// @dev Normal delay. The Spoke is `IAaveV4Oracle(def.aaveOracle).spoke()`. Reverts `InvalidSpoke` unless the
    /// oracle names a Spoke whose `ORACLE()` is `def.aaveOracle` with 8 decimals, the Spoke's EIP-1967 implementation
    /// (read through `extSload` in the proxy's storage, never the proxy's own code) is `def.implementation` and its code
    /// hash is approved (`isApprovedSpokeCodeHash`: `STANDARD_SPOKE_IMPLEMENTATION`'s or one added by
    /// `approveSpokeCodeHash`; each Aave V4 Spoke implementation embeds its own `ORACLE`, `MAX_USER_RESERVES_LIMIT`
    /// and EIP-712 domain cache, so each deployment has its own hash), records that hash for
    /// `spokeImplementationStatus`,
    /// and, for a new Spoke, `def.hub` is recorded with tier `def.riskTier`, `def.integrationId` is registered and no
    /// Spoke is recorded for `(hub, integrationId, riskTier)`; for a recorded Spoke, the Hub, integration, tier and
    /// oracle must be the recorded ones and only the implementation changes. Then runs
    /// `RISK_MODULE.checkAaveConfig(spoke, [])` (Spoke-wide standard-Spoke settings) and reverts `InvalidSpoke` when it
    /// fails. Every Avana collateral reserve must have `receiveSharesEnabled = false`, `liquidationFee = 0` and no
    /// reinvestment controller; a later drift trips the breaker of new activity, never liquidation. The Spoke takes
    /// no borrow until `enableDebtReserve` and no collateral until a market is listed and activated. Emits
    /// `SpokeApproved`.
    /// @param def Home Hub, AMM integration, risk tier and standard Spoke implementation.
    /// @return spoke The CDP Spoke.
    /// @custom:spec REQ-CONFIG-016, REQ-CONFIG-074, Q-281, Q-378
    function deployCdpSpoke(
        SpokeDef calldata def
    ) external returns (address spoke);

    /// @notice Enables a debt reserve on a CDP Spoke: sets its funding Hub and asset, checks caps and swap routes, and
    /// enables borrowing.
    /// @dev Normal delay. Reverts `InvalidSpoke` for an unrecorded Spoke and `InvalidDebtReserve(check)` unless
    /// `def.reserveId` is a reserve the standard Spoke already lends (Q-281: a standard Spoke has no fixed debt-reserve
    /// set, and the RiskModule's standard-Spoke drift check keeps the enabled set equal to the Spoke's borrowable
    /// reserves, REQ-MREG-007), its Aave reserve matches `def` (underlying, funding Hub, Hub asset ID, decimals), it is
    /// borrowable with collateral factor 0, the AaveOracle source equals `def.priceSource` (a
    /// fixed-price source with `fixedPrice`, else the asset's DebtOracle with `ASSET() == def.asset`,
    /// `MARKET_REGISTRY() == address(this)`, `PARAMETER_STORE() == PARAMETER_STORE` and 8 decimals), `def.coverageSpoke`
    /// is `coverageSpokeOf(def.fundingHub, def.asset)` and reports the same asset, Hub and Hub asset ID, the chain's IFlashSource can lend
    /// the asset (`maxFlashLoan > 0`, premium `phi` on amount `F` with `phi × 1e4 ≤ maxFlashFeeBps × F`) from a
    /// `LENDER()` that is no recorded Hub, and it is not already enabled; reverts `TransferFeeActive(asset)` unless the
    /// asset's transfer fee is 0 at listing (its issuer probe reads a fee of 0, or the asset has no fee switch; AMMN
    /// N2b); every asset, a fixed-price one included, must be a listed token, so its issuer probe is recorded
    /// (`TokenNotListed`), and an asset without a fixed price also needs `debtStressRiseBps(asset) >= 100`. `def.crossHub` must equal `def.fundingHub != hubOf(spoke)`; a cross-Hub reserve also requires an open
    /// credit line (`CrossHubLineClosed`). Then reverts `LivenessBound` unless every Active or Offboarding market of the
    /// Spoke has a usable swap route (or the asset among its pool tokens) for this asset. Marks the Coverage Spoke as
    /// protected from the address freeze. Emits `DebtReserveApproved`.
    /// @param spoke CDP Spoke.
    /// @param def Debt-reserve definition.
    /// @custom:spec REQ-MREG-006, REQ-MREG-007, REQ-MREG-008, REQ-MREG-009, REQ-MREG-018, REQ-MREG-020, REQ-MREG-032, REQ-CONFIG-079, Q-233, Q-236, Q-281, Q-238, Q-248, Q-261, Q-378, Q-379, INV-095
    function enableDebtReserve(
        address spoke,
        DebtReserveDef calldata def
    ) external;

    /// @notice Removes a debt reserve that has nothing owed.
    /// @dev Normal delay. Reverts `UnknownDebtReserve` unless approved and `DebtReserveInUse` unless the Spoke's total
    /// owed and deficit on the reserve's `(hub, hubAssetId)` are both 0. Emits `DebtReserveRemoved`.
    /// @param spoke CDP Spoke.
    /// @param reserveId Debt reserve identifier.
    /// @custom:spec REQ-MREG-010, REQ-MREG-018, Q-281
    function removeDebtReserve(
        address spoke,
        uint256 reserveId
    ) external;

    /// @notice Lists a pool token or a debt asset without a fixed-price source with its primary, alternate and standby
    /// Chainlink routes and its issuer probe.
    /// @dev Normal delay (a new price source). Token decimals are read on-chain. Reverts `ListingCheckFailed` unless
    /// the three routes each hold one or two feeds, share no feed with each other, every feed has a ParameterStore feed
    /// definition whose heartbeat is the feed's own configured heartbeat (Chainlink stablecoin feeds run 82,800 to
    /// 86,400 s, so no fixed 3,600 s bound applies, AMMN-INT-01), and `def.replacedSlot == None`. Emits
    /// `TokenListed`.
    /// @param token Pool token or debt asset.
    /// @param def Token definition.
    /// @custom:spec REQ-CONFIG-017, REQ-CONFIG-018, REQ-CONFIG-021, REQ-CONFIG-025, REQ-CONFIG-026, REQ-MREG-027, Q-248, Q-274
    function listToken(
        address token,
        TokenDef calldata def
    ) external;

    /// @notice Replaces a token's primary, alternate and standby Chainlink routes (a new price source) and clears any
    /// standby switch.
    /// @dev Normal delay. Re-runs the route, heartbeat, common-mode (standby counted as a possible alternate), tolerance
    /// lower-bound and listing-margin checks for every route that can be in force and reverts
    /// `ListingCheckFailed("oracleConfig")` when the LPOracle of any market using the token returns a non-zero
    /// `checkConfig`. Sets `replacedSlot = None` and increments `priceRouteVersion(token)`. Failover to the alternate is
    /// automatic inside the oracles and has no selector. Emits `PriceSourceSet`.
    /// @param token Listed token.
    /// @param primaryRoute New primary route feeds.
    /// @param alternateRoute New alternate route feeds.
    /// @param standbyRoute New standby route feeds.
    /// @custom:spec REQ-CONFIG-021, REQ-CONFIG-026, REQ-CONFIG-027, REQ-CONFIG-034, REQ-MREG-027, REQ-ORACLE-077, Q-091, Q-248
    function setPriceSource(
        address token,
        address[] calldata primaryRoute,
        address[] calldata alternateRoute,
        address[] calldata standbyRoute
    ) external;

    /// @notice Lists a collateral market on a CDP Spoke: binds the vault token and LPOracle deployed earlier in the
    /// listing batch, binds the exact shape in the market's integration and records the market in `Registered`
    /// status (treated as not listed by every reader); or re-registers a cancelled market of the same (Spoke, market
    /// key) under its reserved identifier.
    /// @dev Normal delay. The timelock's `VaultTokenFactory.deployVaultToken` runs earlier in the same batch; this call
    /// requires `tokenOf(spoke, marketKeyOf(def)) == def.vaultToken` and the token's `marketKey()`, `integrationId()`,
    /// `integration()`, `hub()`, `spoke()`, `marketId()`, `lpOracle()`, `decimals()`, `adapter()`,
    /// `collateralization()` and `lpVaultSwap()` to match (`VaultTokenMismatch`), so a batch cannot pair one shape's
    /// token with another shape's market. A new market takes `marketCount + 1` and calls the integration's
    /// `bindMarket`; a relisting reuses the token's reserved `marketId` (that market must be `Cancelled`, on the same
    /// Spoke and market key) and requires the integration's existing binding to be the same pool and shape. Runs the
    /// registration checks: `def.spoke` recorded with home Hub `def.hub` and integration `def.integrationId`; the
    /// integration's `validateMarket` (pool from the integration's canonical factory, keyed by address or by
    /// identifier; the copied configuration matches that integration's position manager and factory, AMMN-RT-15;
    /// for concentrated liquidity an exact `[tickLower, tickUpper]` aligned to the pool's tick spacing with signed
    /// arithmetic, AMMN-RT-01; the integration's listing guards for its pricing model); every pool token listed; the
    /// decimals rule; the common-mode guard; the raw-price bound; and the LPOracle seed (`decimals() == 8`,
    /// `latestAnswer() > 0`, this market and integration). `DuplicateMarketKey` when the market key, the vault token or
    /// the LPOracle is held by a market that is neither Cancelled nor Closed. Records the Spoke's first enabled debt
    /// reserve as the settlement reserve (`ListingCheckFailed("settlementReserve")` when it has none) and runs
    /// `RISK_MODULE.checkAaveConfig(spoke, [])` (`ActivationCheckFailed(marketId, "aaveConfig")`). Emits
    /// `MarketRegistered`.
    /// @param def Market definition.
    /// @return marketId Sequential identifier, starting at 1, unique on the chain, or the reserved identifier on a
    /// relisting.
    /// @custom:spec REQ-MREG-030, Q-265, REQ-CONFIG-006, REQ-CONFIG-007, REQ-CONFIG-011, REQ-CONFIG-028, REQ-CONFIG-029, REQ-CONFIG-030, REQ-CONFIG-031, REQ-CONFIG-032, REQ-CONFIG-033, REQ-CONFIG-034, REQ-CONFIG-035, REQ-CONFIG-037, REQ-CONFIG-065, Q-376, Q-378
    function listCollateralMarket(
        MarketDef calldata def
    ) external returns (uint256 marketId);

    /// @notice Runs the activation checks and sets the market `Active`.
    /// @dev Short delay. Reverts `MarketNotRegistered` unless Registered; sets `hubAssetId` and `reserveId`; runs
    /// `RISK_MODULE.checkAaveConfig(spoke, [marketId])` and `isHubSharesEqualAssets`; requires CF > 0 and at most
    /// `expectedCollateralFactorBps`, the bonus bound SPEC-CF-002, liquidity fee 0, the liquidation-config bound, the
    /// ParameterStore's market parameters, caps and `minPledgeUsd` set with SPEC-CAP-006, the listing margin, the TWAP
    /// observation, reserve not paused or frozen, LPOracle Live, an Active primary and backup swap route from every pool
    /// token into every enabled debt asset of the Spoke (a token equal to the debt asset needs none), and the
    /// registration checks still holding; else `ActivationCheckFailed`. The liquidation-config bound reads
    /// `PARAMETER_STORE.aaveTargetHealthFactor(spoke)` and `minLiquidationBonus(spoke)`. Then reverts `LivenessBound`
    /// unless the swap-route liveness check holds against every enabled debt reserve of the Spoke. Emits
    /// `MarketActivated`.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-MREG-032, Q-261, Q-270, REQ-CONFIG-036, REQ-CONFIG-038, REQ-CONFIG-042, REQ-CONFIG-043, REQ-CONFIG-044, REQ-CONFIG-045, REQ-CONFIG-046, REQ-CONFIG-047, REQ-CONFIG-066, REQ-CONFIG-073
    function activateMarket(
        uint256 marketId
    ) external;

    /// @notice Cancels a market still in `Registered` status: sets it `Cancelled`, frees its pool, vault-token and
    /// LPOracle keys, and keeps its identifier reserved for its pool.
    /// @dev Short delay: it only removes a market that never took collateral. Reverts `MarketNotRegistered` unless
    /// Registered. Emits `MarketRegistrationCancelled`.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-CONFIG-048, REQ-MREG-030, Q-265
    function cancelRegistration(
        uint256 marketId
    ) external;

    /// @notice Moves an `Active` market to `Offboarding`, for good.
    /// @dev Short delay. Reverts `MarketNotActive` unless Active. The RiskModule then rejects every pledge into the
    /// market and every borrow by an account with collateral in it; repay, withdrawals and liquidation continue.
    /// Paired with an Aave freeze of the vault-token reserve. Emits `MarketOffboarding`.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-CONFIG-013, REQ-MREG-015, Q-227
    function setMarketOffboarding(
        uint256 marketId
    ) external;
}
