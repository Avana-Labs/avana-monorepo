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

    /// @notice Records a withdrawal of up to `amount` to `to`, executable after `RESERVE_WITHDRAWAL_DELAY`.
    /// @return id Request ID, starting at 1.
    function requestWithdrawal(
        uint256 amount,
        address to
    ) external returns (uint256 id);

    /// @notice Cancels a Pending request.
    function cancelWithdrawal(
        uint256 id
    ) external;

    /// @notice Executes a Pending request once due, withdrawing `min(amount, fundedBalance())` to the recipient.
    /// @dev Reverts `DeficitOutstanding` while an allowlisted Spoke has a deficit on the asset.
    function executeWithdrawal(
        uint256 id
    ) external returns (uint256 withdrawn);

    /// @notice A constructor address input (`hub`, `asset`, `authority`) or an allowlisted Spoke is the zero address.
    error ZeroAddress();

    /// @notice `HUB.getAssetUnderlyingAndDecimals(assetId)` does not return the asset with its token decimals.
    error InvalidHubAsset(uint256 assetId);

    /// @notice The constructor's withdrawal delay is not the required `reserveWithdrawalDelay`.
    error InvalidWithdrawalDelay(uint256 delay);

    /// @notice `fund` or `requestWithdrawal` was called with a zero amount.
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

    error WithdrawalNotPending(uint256 id);

    /// @notice The withdrawal request is Pending but `block.timestamp < executableAt`.
    /// @param executableAt Earliest execution time, seconds.
    error WithdrawalNotReady(uint256 id, uint64 executableAt);

    /// @notice `executeWithdrawal` ran while an allowlisted Spoke has a recorded deficit on the asset.
    /// @param spoke The first such Spoke in the Hub's list.
    error DeficitOutstanding(address spoke);

    /// @notice Delay between a withdrawal request and its earliest execution.
    /// @return delay Seconds.
    function RESERVE_WITHDRAWAL_DELAY() external view returns (uint256 delay);

    /// @notice Whether `spoke`'s deficits on the asset may be covered.
    function allowedBorrowSpoke(
        address spoke
    ) external view returns (bool allowed);

    /// @notice The instance's Hub added shares.
    function fundedShares() external view returns (uint256 shares);

    /// @notice A withdrawal request; an ID never requested has status `None`.
    function getWithdrawal(
        uint256 id
    ) external view returns (Withdrawal memory withdrawal);

    /// @notice The ID the next request gets.
    function nextWithdrawalId() external view returns (uint256 id);

    /// @notice Cumulative amount added through `fund`.
    function totalFunded() external view returns (uint256 amount);

    /// @notice Cumulative deficit eliminated through `coverDeficit`.
    function totalCovered() external view returns (uint256 amount);

    /// @notice Cumulative amount withdrawn through `executeWithdrawal`.
    function totalWithdrawn() external view returns (uint256 amount);
}

/// @notice State of a First-Loss Reserve withdrawal request. `None` is an ID never requested.
enum WithdrawalStatus {
    None,
    Pending,
    Cancelled,
    Executed
}

/// @notice A withdrawal request of the Aave DAO on a First-Loss Reserve.
/// @param amount Asset base units requested; execution withdraws at most `fundedBalance()`.
/// @param executableAt Earliest execution time, seconds.
struct Withdrawal {
    uint256 amount;
    address to;
    uint64 executableAt;
    WithdrawalStatus status;
}
