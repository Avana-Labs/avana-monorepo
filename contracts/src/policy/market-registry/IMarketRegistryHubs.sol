// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {RiskTier} from "./types/RiskTier.sol";

/// @title IMarketRegistryHubs
/// @notice The chain's Hubs, AMM integrations, First-Loss Reserves, cross-Hub lines and Spoke drift check.
/// @dev Writes require `APPLICATION_ADMIN`. Views never revert; an unknown key returns zeros.
interface IMarketRegistryHubs {
    event HubRecorded(address indexed hub, RiskTier tier);

    event IntegrationRegistered(uint32 indexed integrationId, address lpVault, address pricing);

    event AvanaFirstLossReserveSet(address indexed hub, address indexed asset, address firstLossReserve);

    /// @notice A cross-Hub credit line cap changed; `total` is the new sum for (fundingHub, asset).
    event CrossHubLineSet(
        address indexed fundingHub, address indexed asset, address indexed spoke, uint256 cap, uint256 total
    );

    event CrossHubLinesEnabledSet(bool enabled);

    /// @param previous The previous source (address(0) for the first).
    event FlashSourceSet(address indexed previous, address indexed current);

    /// @notice A Hub argument is zero, unrecorded, already recorded, of the wrong tier, or the borrowing Spoke's home.
    error InvalidHub(address hub);

    /// @notice An integration identifier is 0 or already used, or the LPVault reports another identifier.
    error InvalidIntegration(uint32 integrationId);

    /// @notice The First-Loss Reserve does not report the Hub and asset, or the pair already has one.
    error InvalidAvanaFirstLossReserve(address firstLossReserve);

    /// @notice A non-zero cross-Hub line cap while lines are off for the chain.
    error CrossHubLinesDisabled();

    /// @notice The sum of cross-Hub lines for (funding Hub, asset) would exceed that Hub's first-loss coverage.
    /// @param total The sum the call would produce, base units.
    /// @param coverage The First-Loss Reserve's first-loss coverage, base units.
    error CrossHubCapExceeded(uint256 total, uint256 coverage);

    /// @notice A cross-Hub debt reserve was enabled with no open line.
    error CrossHubLineClosed(address fundingHub, address asset, address spoke);

    /// @notice Records a Hub of the chain with its risk tier.
    /// @dev Reverts `InvalidRoute` when `hub` is the flash source's lender.
    function recordHub(
        address hub,
        RiskTier tier
    ) external;

    /// @notice Registers an AMM integration: the AMM protocol's LPVault on this chain and its pricing implementation.
    /// @dev Identifiers are never reused.
    function registerIntegration(
        uint32 integrationId,
        address lpVault,
        address pricing
    ) external;

    /// @notice Records the First-Loss Reserve of a (Hub, debt asset) pair.
    /// @dev Set once per pair; the reserve must report `hub` and `asset`.
    function setAvanaFirstLossReserve(
        address hub,
        address asset,
        address firstLossReserve
    ) external;

    /// @notice Sets the cap of the cross-Hub credit line that lets `spoke` borrow `asset` from `fundingHub`.
    /// @dev Reverts `CrossHubCapExceeded` when a raise takes the sum of lines past first-loss coverage.
    /// @param cap Most the line may have drawn, base units of `asset`.
    function setCrossHubLine(
        address fundingHub,
        address asset,
        address spoke,
        uint256 cap
    ) external;

    /// @notice Turns cross-Hub credit lines on or off for the chain.
    /// @dev Turning off keeps stored caps but blocks every new cross-Hub draw.
    function setCrossHubLinesEnabled(
        bool enabled
    ) external;

    /// @notice Risk tier of a recorded Hub (`None` for an unknown Hub).
    function hubTier(
        address hub
    ) external view returns (RiskTier tier);

    /// @notice Whether `account` is a Hub recorded on the chain (any tier).
    function isRecordedHub(
        address account
    ) external view returns (bool recorded);

    /// @notice Every recorded Hub of the chain, in recording order.
    function getHubs() external view returns (address[] memory hubs);

    /// @notice Home Hub of a CDP Spoke.
    /// @return hub The home Hub, or `address(0)`.
    function hubOf(
        address spoke
    ) external view returns (address hub);

    /// @notice The LPVault and pricing implementation of an AMM integration.
    /// @return lpVault The AMM protocol's LPVault, or `address(0)`.
    function integrationOf(
        uint32 integrationId
    ) external view returns (address lpVault, address pricing);

    /// @notice Integration identifier of an LPVault (0 if unknown).
    function integrationIdOf(
        address lpVault
    ) external view returns (uint32 integrationId);

    /// @notice First-Loss Reserve of a (Hub, debt asset) pair (`address(0)` if none).
    function firstLossReserveOf(
        address hub,
        address asset
    ) external view returns (address firstLossReserve);

    /// @notice Cap of one cross-Hub credit line.
    /// @return cap The cap, base units; 0 when closed or unknown.
    function crossHubLineCap(
        address fundingHub,
        address asset,
        address spoke
    ) external view returns (uint256 cap);

    /// @notice Sum of every cross-Hub line cap for (funding Hub, asset).
    /// @return total Sum of caps, base units.
    function crossHubLineTotal(
        address fundingHub,
        address asset
    ) external view returns (uint256 total);

    /// @notice Whether cross-Hub credit lines are on for the chain (false by default).
    function crossHubLinesEnabled() external view returns (bool enabled);

    /// @notice Drift check of the standard Spoke settings Avana depends on, for every listed market of a CDP Spoke.
    /// @dev Never reverts; a failed read reports drift. `marketId` is 0 for a Spoke-wide drift.
    /// @return marketId First drifting market, or 0.
    /// @return reason The drift reason, `None` when the settings hold.
    function spokeSettingsDrift(
        address spoke
    ) external view returns (uint256 marketId, DriftReason reason);

    /// @notice Replaces the chain's IFlashSource implementation.
    /// @dev Reverts `InvalidRoute` if the source's lender is a recorded Hub.
    function setFlashSource(
        address newSource
    ) external;
}
