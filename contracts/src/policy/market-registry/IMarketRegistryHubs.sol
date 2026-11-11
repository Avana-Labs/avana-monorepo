// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {RiskTier} from "./types/RiskTier.sol";

/// @title IMarketRegistryHubs
/// @notice The chain's Hubs, AMM integrations, Coverage Spokes and cross-Hub credit lines, and the drift check of the
/// standard Spoke settings.
/// @dev Writes require `APPLICATION_ADMIN` (the chain's timelock, normal delay). Views never revert; an unknown key
/// returns zeros, so every check fails closed. A cross-Hub credit line lets a CDP Spoke of one Hub borrow an asset
/// funded by another Hub on the same chain. Lines are fully specified and off at launch (`crossHubLinesEnabled()` is
/// false until a timelock operation sets it): the funding Hub owns the cap, this registry sums every line per (funding
/// Hub, asset), a pause of the funding Hub stops every line it funds, and the sum is capped at that Hub's first-loss
/// coverage for the asset, so no line can lend more than the coverage that absorbs its losses (AMMN-SM-01,
/// AMMN-RT-11, AMMN-FLOW-05).
interface IMarketRegistryHubs {
    /// @notice A Hub was recorded.
    /// @custom:spec Q-378
    event HubRecorded(address indexed hub, RiskTier tier);

    /// @notice An AMM integration was registered.
    /// @custom:spec Q-376
    event IntegrationRegistered(uint32 indexed integrationId, address lpVault, address pricing);

    /// @notice The Coverage Spoke of a (Hub, asset) pair was recorded.
    /// @custom:spec Q-379
    event CoverageSpokeSet(address indexed hub, address indexed asset, address coverageSpoke);

    /// @notice A cross-Hub credit line cap changed; `total` is the new sum for (fundingHub, asset).
    /// @custom:spec Q-378
    event CrossHubLineSet(
        address indexed fundingHub, address indexed asset, address indexed spoke, uint256 cap, uint256 total
    );

    /// @notice Cross-Hub credit lines were turned on or off.
    /// @custom:spec Q-378
    event CrossHubLinesEnabledSet(bool enabled);

    /// @notice The chain's IFlashSource implementation was replaced.
    /// @param previous The former source (address(0) for the first).
    /// @param current The new source.
    /// @custom:spec REQ-CONFIG-005, Q-386
    event FlashSourceSet(address indexed previous, address indexed current);

    /// @notice A Hub argument is zero, unrecorded, already recorded, of the wrong tier, or the borrowing Spoke's home.
    /// @custom:spec Q-378
    error InvalidHub(address hub);

    /// @notice An integration identifier is 0 or already used, or the LPVault reports another identifier.
    /// @custom:spec Q-376
    error InvalidIntegration(uint32 integrationId);

    /// @notice The Coverage Spoke does not report the Hub and asset, or the pair already has one.
    /// @custom:spec Q-379
    error InvalidCoverageSpoke(address coverageSpoke);

    /// @notice A non-zero cross-Hub line cap while lines are off for the chain.
    /// @custom:spec Q-378
    error CrossHubLinesDisabled();

    /// @notice The sum of cross-Hub lines for (funding Hub, asset) would exceed that Hub's first-loss coverage.
    /// @param total The sum the call would produce, base units.
    /// @param coverage The Coverage Spoke's first-loss coverage, base units.
    /// @custom:spec Q-378
    error CrossHubCapExceeded(uint256 total, uint256 coverage);

    /// @notice A cross-Hub debt reserve was enabled with no open line.
    /// @custom:spec Q-378
    error CrossHubLineClosed(address fundingHub, address asset, address spoke);

    /// @notice Records a Hub of the chain with its risk tier.
    /// @dev Normal delay. Reverts `InvalidHub` for a zero address, a Hub already recorded, or `tier == None`, and
    /// `InvalidRoute` when `hub == flashSource().LENDER()`, so the flash source never borrows from a recorded Hub.
    /// @param hub Aave V4 Hub.
    /// @param tier Stable LP, Correlated LP or Volatile LP.
    /// @custom:spec REQ-CONFIG-016, Q-378
    function recordHub(
        address hub,
        RiskTier tier
    ) external;

    /// @notice Registers an AMM integration: the AMM protocol's LPVault on this chain and its pricing implementation.
    /// @dev Normal delay. Reverts `InvalidIntegration` for `integrationId == 0`, an identifier already used, or an
    /// `lpVault` whose `INTEGRATION_ID()` differs. Identifiers are never reused, so a stored `PositionRef` always names
    /// the same AMM protocol.
    /// @param integrationId New identifier.
    /// @param lpVault The AMM protocol's immutable LPVault on this chain.
    /// @param pricing The AMM protocol's pricing library or oracle implementation used by its LPOracles.
    /// @custom:spec REQ-CONFIG-016, Q-376, Q-378
    function registerIntegration(
        uint32 integrationId,
        address lpVault,
        address pricing
    ) external;

    /// @notice Records the Coverage Spoke of a (Hub, debt asset) pair.
    /// @dev Normal delay. Reverts `InvalidCoverageSpoke` unless the Spoke reports `hub` and `asset` and the pair has no
    /// Coverage Spoke yet. Pending settlement of every market whose debt reserve is funded by `hub` in `asset` sends its
    /// recovered value here.
    /// @param hub Funding Hub.
    /// @param asset Debt asset.
    /// @param coverageSpoke The Coverage Spoke.
    /// @custom:spec REQ-MREG-009, Q-378, Q-379
    function setCoverageSpoke(
        address hub,
        address asset,
        address coverageSpoke
    ) external;

    /// @notice Sets the cap of the cross-Hub credit line that lets `spoke` borrow `asset` from `fundingHub`.
    /// @dev Normal delay. Reverts `CrossHubLinesDisabled` while lines are off and `cap > 0`, `InvalidHub` when
    /// `fundingHub == hubOf(spoke)`, and `CrossHubCapExceeded` when the new sum of lines for (fundingHub, asset) would
    /// exceed the first-loss coverage of `coverageSpokeOf(fundingHub, asset)`. A cap of 0 closes the line at once: no
    /// new draw passes, while repay, withdrawal and liquidation of existing debt continue. Emits `CrossHubLineSet`.
    /// @param fundingHub Hub that lends.
    /// @param asset Debt asset.
    /// @param spoke Borrowing CDP Spoke of another Hub.
    /// @param cap Most the line may have drawn, base units of `asset`.
    /// @custom:spec Q-378
    function setCrossHubLine(
        address fundingHub,
        address asset,
        address spoke,
        uint256 cap
    ) external;

    /// @notice Turns cross-Hub credit lines on or off for the chain.
    /// @dev Normal delay. Turning off leaves every line's cap stored but blocks every new cross-Hub draw.
    /// @param enabled True to allow lines with a non-zero cap.
    /// @custom:spec Q-378
    function setCrossHubLinesEnabled(
        bool enabled
    ) external;

    /// @notice Risk tier of a recorded Hub (`None` for an unknown Hub).
    /// @param hub The Hub.
    /// @return tier The tier.
    /// @custom:spec Q-378
    function hubTier(
        address hub
    ) external view returns (RiskTier tier);

    /// @notice Whether `account` is a Hub recorded on the chain (any tier).
    /// @param account The address.
    /// @return recorded True for a recorded Hub.
    /// @custom:spec REQ-FLASH-005, REQ-FLASH-006, INV-095
    function isRecordedHub(
        address account
    ) external view returns (bool recorded);

    /// @notice Every recorded Hub of the chain, in recording order.
    /// @return hubs The Hubs.
    /// @custom:spec Q-378
    function getHubs() external view returns (address[] memory hubs);

    /// @notice Home Hub of a CDP Spoke.
    /// @param spoke The Spoke.
    /// @return hub The home Hub, or `address(0)`.
    /// @custom:spec Q-378
    function hubOf(
        address spoke
    ) external view returns (address hub);

    /// @notice The LPVault and pricing implementation of an AMM integration.
    /// @param integrationId The integration.
    /// @return lpVault The AMM protocol's LPVault, or `address(0)`.
    /// @return pricing The pricing implementation.
    /// @custom:spec Q-376
    function integrationOf(
        uint32 integrationId
    ) external view returns (address lpVault, address pricing);

    /// @notice Integration identifier of an LPVault (0 if unknown).
    /// @param lpVault The LPVault.
    /// @return integrationId The identifier.
    /// @custom:spec Q-376
    function integrationIdOf(
        address lpVault
    ) external view returns (uint32 integrationId);

    /// @notice Coverage Spoke of a (Hub, debt asset) pair (`address(0)` if none).
    /// @param hub Funding Hub.
    /// @param asset Debt asset.
    /// @return coverageSpoke The Coverage Spoke.
    /// @custom:spec REQ-MREG-009, Q-379
    function coverageSpokeOf(
        address hub,
        address asset
    ) external view returns (address coverageSpoke);

    /// @notice Cap of one cross-Hub credit line.
    /// @param fundingHub Hub that lends.
    /// @param asset Debt asset.
    /// @param spoke Borrowing CDP Spoke.
    /// @return cap The cap, base units; 0 when closed or unknown.
    /// @custom:spec Q-378
    function crossHubLineCap(
        address fundingHub,
        address asset,
        address spoke
    ) external view returns (uint256 cap);

    /// @notice Sum of every cross-Hub line cap for (funding Hub, asset).
    /// @param fundingHub Hub that lends.
    /// @param asset Debt asset.
    /// @return total Sum of caps, base units.
    /// @custom:spec Q-378
    function crossHubLineTotal(
        address fundingHub,
        address asset
    ) external view returns (uint256 total);

    /// @notice Whether cross-Hub credit lines are on for the chain (false at launch).
    /// @return enabled The switch.
    /// @custom:spec Q-378
    function crossHubLinesEnabled() external view returns (bool enabled);

    /// @notice Drift check of the standard Spoke settings Avana depends on, for every listed market of a CDP Spoke.
    /// @dev Never reverts. Returns the first drift found: the Spoke's implementation is not current
    /// (`spokeImplementationStatus`, `SpokeImplementation`), a market's collateral reserve is on another Hub than the
    /// home Hub, holds another underlying than the market's vault token or another Hub asset ID than the market's
    /// (`ReserveIdentity`), has `receiveSharesEnabled` true, a `liquidationFee` above 0, or a reinvestment controller
    /// on its Hub asset; a read that fails reports `ReserveIdentity`. `marketId` is 0 for a
    /// Spoke-wide drift. Any drift makes the RiskModule refuse new activity on the Spoke and trips its market breakers;
    /// liquidation never reads it.
    /// @param spoke The CDP Spoke.
    /// @return marketId First drifting market, or 0.
    /// @return reason The drift reason, `None` when the settings hold.
    /// @custom:spec REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030, Q-378
    function spokeSettingsDrift(
        address spoke
    ) external view returns (uint256 marketId, DriftReason reason);

    /// @notice Replaces the chain's IFlashSource implementation.
    /// @dev `APPLICATION_ADMIN`, normal delay. Emits `FlashSourceSet`. The source's `LENDER()` (the Aave V3 Pool at
    /// launch) joins the protected set of the address freeze with the source itself (REQ-MREG-020). Reverts `InvalidRoute` unless `newSource.LP_VAULT_SWAP() ==
    /// LP_VAULT_SWAP` and `isRecordedHub(newSource.LENDER())` is false: `LENDER()` is the pool or Hub that holds the
    /// liquidity the source lends, so a flash Spoke whose Hub funds a listed market is refused even though the Spoke's
    /// own address is no Hub (AMMN N1, Q-386). LPVaultSwap repeats
    /// the check on every flash call, so a Hub recorded later also stops the source. If the new source lacks liquidity
    /// for an asset, liquidation falls back to the caller-funded path.
    /// @param newSource The new implementation.
    /// @custom:spec REQ-FLASH-006, INV-095, Q-379, Q-386
    function setFlashSource(
        address newSource
    ) external;
}
