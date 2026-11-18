// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../types/PositionShape.sol";
import {IntegrationCapabilities} from "./types/IntegrationCapabilities.sol";
import {RiskMetadata} from "./types/RiskMetadata.sol";
import {RiskStatus} from "./types/RiskStatus.sol";

/// @title IAmmIntegration
/// @notice Avana's adapter for one AMM protocol, implemented by its LPVault. Amounts are in pool token order.
/// @dev Value-moving functions are Collateralization-only and run only while the Lock is held.
interface IAmmIntegration {
    /// @notice Returns the integration identifier assigned at registration in the VaultTokenFactory.
    function INTEGRATION_ID() external view returns (uint32 integrationId);

    /// @notice Returns the AMM protocol tag, `keccak256` of its name.
    function AMM_PROTOCOL() external view returns (bytes32 protocol);

    /// @notice Returns the fixed description of the integration.
    function capabilities() external view returns (IntegrationCapabilities memory caps);

    /// @notice The most open records one account may hold in one market of this integration.
    /// @dev Sized so a whole-account seizure fits the liquidation gas budget.
    function maxRecordsPerAccountMarket() external view returns (uint256 records);

    /// @notice Binds a market to its pool and exact shape, once, at listing.
    /// @dev MarketRegistry-only.
    /// @param pool Pool address (address(0) for an identifier-keyed protocol).
    /// @param poolId Pool identifier (bytes32(0) for an address-keyed protocol).
    /// @return tokens Pool tokens in pool order (native ETH as the wrapped token).
    function bindMarket(
        uint256 marketId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        bytes calldata integrationData
    ) external returns (address[] memory tokens, uint8 unitDecimals);

    /// @notice Returns a bound market's pool, shape and tokens; reverts `MarketBinding` for an unbound market.
    function marketOf(
        uint256 marketId
    ) external view returns (address pool, bytes32 poolId, PositionShape memory shape, address[] memory tokens);

    /// @notice Validates a position against a market, pulls it from its owner into custody and returns its units.
    /// @param owner Wallet that owns the position and becomes its depositor of record.
    function receivePosition(
        uint256 marketId,
        address owner,
        bytes32 positionKey
    ) external returns (uint128 units);

    /// @notice Sends a custodied position, whole, to its depositor of record.
    /// @dev Deletes the custody entry before the transfer.
    function returnPosition(
        bytes32 positionKey
    ) external returns (address depositor);

    /// @notice Adds units to a custodied fungible-share position by pulling the LP amount `topUp` encodes from `owner`.
    /// @dev Reverts `TopUpNotSupported` where anyone can add to a position directly (NFT positions).
    /// @return unitsAdded Units added, measured by balance delta.
    function topUpPosition(
        bytes32 positionKey,
        address owner,
        bytes calldata topUp
    ) external returns (uint128 unitsAdded);

    /// @notice Returns the current owner of a position in the AMM protocol, or address(0) when it does not exist.
    function positionOwner(
        bytes32 positionKey
    ) external view returns (address owner);

    /// @notice Returns a position's units if a market accepts it; reverts with `receivePosition`'s error otherwise.
    function validatePosition(
        uint256 marketId,
        address owner,
        bytes32 positionKey
    ) external view returns (uint128 units);

    /// @notice Returns the token amounts `units` of the market hold at the oracle price vector `prices`.
    /// @dev Reads no spot state and rounds every amount down, so collateral is never overvalued.
    /// @param prices Oracle prices in pool order, 8 decimals.
    function composition(
        uint256 marketId,
        uint256 units,
        uint256[] calldata prices
    ) external view returns (uint256[] memory amounts, bool exact);

    /// @notice Removes exactly `units` of a custodied position and sends the principal to `recipient`; fees stay owed.
    /// @dev Reverts `BelowMinimum` (or the AMM's slippage error) under any minimum.
    function unwind(
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts,
        address recipient
    ) external returns (uint256[] memory amounts);

    /// @notice Removes exactly `units` and sends the principal to the depositor of record; custody is kept.
    function releaseToDepositor(
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts);

    /// @notice Collects every owed fee of a custodied position to its depositor of record.
    /// @dev Reads no pause, breaker or price, so it works in every application state.
    function collectFees(
        bytes32 positionKey,
        address depositor
    ) external returns (uint256[] memory amounts);

    /// @notice Returns range status, pool share and position units of a market.
    /// @param positionKey Position to report (bytes32(0) for none).
    function riskMetadata(
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (RiskMetadata memory meta);

    /// @notice Returns the pool's time-weighted depth over `window` seconds, in the market's units.
    function riskStatus(
        uint256 marketId,
        uint32 window
    ) external view returns (RiskStatus memory status);

    /// @notice Returns the depositor of record of a custodied position, or address(0).
    /// @dev Reverts `Locked` while the lock is held.
    function depositorOf(
        bytes32 positionKey
    ) external view returns (address depositor);

    /// @notice Returns the market a custodied position was received for (0 when not in custody).
    function marketOfPosition(
        bytes32 positionKey
    ) external view returns (uint256 marketId);

    /// @notice Returns the live units of a custodied position.
    /// @dev Reverts `Locked` while the lock is held unless the caller is Collateralization.
    function unitsOf(
        bytes32 positionKey
    ) external view returns (uint128 units);
}
