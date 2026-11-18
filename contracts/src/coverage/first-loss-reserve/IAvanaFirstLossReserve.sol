// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaFirstLossReserve
/// @notice A First-Loss Reserve (Avana Umbrella): the Avana-funded first-loss capital for one covered `(Hub, asset)`.
/// @dev Controlled by an AccessManager; no Avana contract holds a role on it. `withdraw` is delayed by the manager's
/// execution delay of its role (14 days).
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

    /// @notice Emitted after `coverDeficit` or `withdraw` leaves `fundedBalance()` below the minimum.
    event ReserveBelowMinimum(uint256 balance, uint256 minimum);

    event ReserveWithdrawn(address indexed to, uint256 withdrawn, uint256 sharesBurned, uint256 balanceAfter);

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

    event BorrowSpokeAllowlistUpdated(address indexed spoke, bool allowed);

    event FirstLossReserveMinimumUpdated(uint256 oldMinimum, uint256 newMinimum);

    /// @notice Adds `spoke` to, or removes it from, the allowlist of CDP Spokes whose deficits may be covered.
    /// @dev Adding requires `spoke` to be listed on the Hub asset; removal is immediate.
    function setAllowedBorrowSpoke(
        address spoke,
        bool allowed
    ) external;

    /// @notice Sets `firstLossReserveMinimum`; it never blocks funding, coverage or withdrawal.
    function setFirstLossReserveMinimum(
        uint256 minimum
    ) external;

    /// @notice Withdraws `min(amount, fundedBalance())` to `to`.
    /// @dev Restricted to the withdraw role, whose AccessManager execution delay is the withdrawal delay (14 days).
    /// Reverts `DeficitOutstanding` while an allowlisted Spoke has a deficit on the asset.
    function withdraw(
        uint256 amount,
        address to
    ) external returns (uint256 withdrawn);

    /// @notice A constructor address input (`hub`, `asset`, `authority`) or an allowlisted Spoke is the zero address.
    error ZeroAddress();

    /// @notice `HUB.getAssetUnderlyingAndDecimals(assetId)` does not return the asset with its token decimals.
    error InvalidHubAsset(uint256 assetId);

    /// @notice `fund` or `withdraw` was called with a zero amount.
    error ZeroAmount();

    /// @notice The Hub's balance of the asset did not rise by exactly the funded amount.
    error TransferAmountMismatch(uint256 expected, uint256 received);

    error SpokeNotAllowlisted(address borrowSpoke);

    /// @notice The Spoke's deficit on the asset, or the computed coverage amount, is zero.
    error NothingToCover(address borrowSpoke);

    /// @notice `setAllowedBorrowSpoke(spoke, true)` for a Spoke not listed on the instance's Hub asset.
    error BorrowSpokeNotListed(address spoke);

    /// @notice A withdrawal recipient is the zero address, the First-Loss Reserve itself or the Hub.
    error InvalidRecipient(address to);

    /// @notice `withdraw` ran while an allowlisted Spoke has a recorded deficit on the asset.
    /// @param spoke The first such Spoke in the Hub's list.
    error DeficitOutstanding(address spoke);

    /// @notice Whether `spoke`'s deficits on the asset may be covered.
    function allowedBorrowSpoke(
        address spoke
    ) external view returns (bool allowed);

    /// @notice The instance's Hub added shares.
    function fundedShares() external view returns (uint256 shares);

    /// @notice Cumulative amount added through `fund`.
    function totalFunded() external view returns (uint256 amount);

    /// @notice Cumulative deficit eliminated through `coverDeficit`.
    function totalCovered() external view returns (uint256 amount);

    /// @notice Cumulative amount withdrawn through `withdraw`.
    function totalWithdrawn() external view returns (uint256 amount);
}
