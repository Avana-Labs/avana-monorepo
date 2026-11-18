// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaFirstLossReserve
/// @notice A First-Loss Reserve (Avana Umbrella): the Avana-funded first-loss capital for one covered `(Hub, asset)`.
/// @dev Controlled by the Aave DAO's AccessManager; no Avana contract holds a role on it.
interface IAvanaFirstLossReserve {
    /// @notice Emitted when `fund` succeeds, including a pending-settlement top-up from LPVaultSwap.
    event ReserveFunded(address indexed funder, uint256 amount, uint256 shares, uint256 balanceAfter);

    /// @param covered Asset base units of deficit eliminated.
    event DeficitCovered(
        address indexed borrowSpoke,
        address indexed caller,
        uint256 covered,
        uint256 sharesBurned,
        uint256 deficitRayBefore,
        uint256 deficitRayAfter,
        uint256 balanceAfter
    );

    /// @notice Emitted after `coverDeficit` or `executeWithdrawal` leaves `fundedBalance()` below the minimum.
    event ReserveBelowMinimum(uint256 balance, uint256 minimum);

    event WithdrawalRequested(uint256 indexed id, uint256 amount, address indexed to, uint64 executableAt);

    event WithdrawalCancelled(uint256 indexed id);

    event WithdrawalExecuted(
        uint256 indexed id, uint256 withdrawn, uint256 sharesBurned, address indexed to, uint256 balanceAfter
    );

    /// @notice Pulls `amount` of `ASSET()` from the caller straight to the Hub and adds it to the reserve.
    /// @dev Callable by anyone; the funder gets no claim.
    function fund(
        uint256 amount
    ) external returns (uint256 shares);

    /// @notice Eliminates up to `maxAmount` of `borrowSpoke`'s deficit on the asset by burning this instance's shares.
    /// @dev `COVERAGE_ROLE` only; `borrowSpoke` must be allowlisted. Covers at most the deficit and `fundedBalance()`.
    function coverDeficit(
        address borrowSpoke,
        uint256 maxAmount
    ) external returns (uint256 shares, uint256 covered);

    /// @notice The covered asset.
    function ASSET() external view returns (address asset);

    /// @notice The Hub whose asset this instance covers.
    function HUB() external view returns (address hub);

    /// @notice `ASSET()`'s asset ID on `HUB()`.
    function ASSET_ID() external view returns (uint256 assetId);

    /// @notice What the instance's added shares redeem for on the Hub, rounded down.
    function fundedBalance() external view returns (uint256 balance);

    /// @notice Whether `fundedBalance()` is below the instance's `firstLossReserveMinimum`.
    function isBelowMinimum() external view returns (bool below);

    /// @notice The instance's minimum funded balance, set only by the Aave DAO.
    function firstLossReserveMinimum() external view returns (uint256 minimum);
}
