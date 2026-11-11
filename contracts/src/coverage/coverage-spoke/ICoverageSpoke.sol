// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICoverageSpoke
/// @notice Interface of a Coverage Spoke (Avana Umbrella), the holder of the Avana First-Loss Reserve for one covered
/// `(Hub, asset)`. Avana writes and deploys the contract; the Aave DAO controls it: the functions Avana contracts, the Lens and monitoring use, and the events they index.
/// @dev Each Coverage Spoke is a supply-only Spoke on one asset of one Hub with zero draw capacity, funded by Avana Labs
/// in that asset and controlled by the Aave DAO through the Aave DAO's AccessManager (`COVERAGE_ROLE`,
/// `RESERVE_ADMIN_ROLE`); no Avana contract, multisig, timelock or keeper holds a role on it. There is one instance per
/// (Hub, debt asset) on each chain; a debt reserve is enabled only with an instance on its own `(hub, hubAssetId)`,
/// funded to its minimum before the reserve's `drawCap` rises above 0 (at launch: GHO on the Stable LP Hubs). A deficit
/// is covered only by the instance of its own (Hub, asset), never across assets or Hubs. Avana contracts call only
/// `fund`: LPVaultSwap, from `settlePending`, on the instance of the market's (Hub, debt asset), after approving exactly
/// `amount` of that asset. The asset moves straight from the
/// caller to the Hub and the added shares belong to the Coverage Spoke; the funder gets no claim. Tokens sent to it by
/// plain transfer are not counted. Amounts are in base units of `ASSET()`. The allowlist, minimum-balance and
/// withdrawal-request functions are DAO-only and not used by Avana (`ICoverageSpokeAdmin`). The Lens and monitoring read
/// `isBelowMinimum()` for the low-balance alert, the Lens reads `fundedBalance()` and `firstLossReserveMinimum()` for
/// tail coverage, and the MarketRegistry reads them for the readiness check of `enableDebtReserve`. Every
/// instance is in the address-freeze protected set.
/// @custom:spec REQ-FLR-001, REQ-FLR-005, REQ-FLR-010, REQ-FLR-014, REQ-FLR-038, REQ-FLR-039, REQ-FLR-040, Q-142, Q-211, Q-236, Q-241, Q-242
interface ICoverageSpoke {
    /// @notice Emitted when `fund` succeeds, including a pending-settlement top-up from LPVaultSwap.
    /// @param funder The caller (LPVaultSwap for pending-settlement proceeds).
    /// @param amount Asset base units added.
    /// @param shares Hub added shares credited to the Coverage Spoke.
    /// @param balanceAfter `fundedBalance()` after the call.
    /// @custom:spec REQ-FLR-010, REQ-FLR-038
    event ReserveFunded(address indexed funder, uint256 amount, uint256 shares, uint256 balanceAfter);

    /// @notice Emitted when `coverDeficit` succeeds.
    /// @param borrowSpoke The covered CDP Spoke.
    /// @param caller The `COVERAGE_ROLE` holder.
    /// @param covered Asset base units of deficit eliminated.
    /// @param sharesBurned Coverage Spoke shares burned by the Hub.
    /// @param deficitRayBefore The CDP Spoke's `deficitRay` on the asset before the call.
    /// @param deficitRayAfter The CDP Spoke's `deficitRay` on the asset after the call.
    /// @param balanceAfter `fundedBalance()` after the call.
    /// @custom:spec REQ-FLR-018, SPEC-FLR-001
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
    /// @param balance `fundedBalance()`.
    /// @param minimum `firstLossReserveMinimum` of the instance.
    /// @custom:spec REQ-FLR-014, REQ-FLR-031
    event ReserveBelowMinimum(uint256 balance, uint256 minimum);

    /// @notice Emitted when the Aave DAO requests a withdrawal.
    /// @param id Request ID.
    /// @param amount Asset base units requested.
    /// @param to Recipient.
    /// @param executableAt Earliest execution time, seconds.
    /// @custom:spec REQ-FLR-023
    event WithdrawalRequested(uint256 indexed id, uint256 amount, address indexed to, uint64 executableAt);

    /// @notice Emitted when the Aave DAO cancels a withdrawal request.
    /// @param id Request ID.
    /// @custom:spec REQ-FLR-024
    event WithdrawalCancelled(uint256 indexed id);

    /// @notice Emitted when a withdrawal executes.
    /// @param id Request ID.
    /// @param withdrawn Asset base units withdrawn.
    /// @param sharesBurned Coverage Spoke shares burned by the Hub.
    /// @param to Recipient.
    /// @param balanceAfter `fundedBalance()` after the call.
    /// @custom:spec REQ-FLR-025, SPEC-FLR-003
    event WithdrawalExecuted(
        uint256 indexed id, uint256 withdrawn, uint256 sharesBurned, address indexed to, uint256 balanceAfter
    );

    /// @notice Pulls `amount` of `ASSET()` from the caller straight to the Hub and adds it to the reserve.
    /// @dev Callable by anyone. The call reverts if `amount == 0`; it moves exactly `amount` from `msg.sender` to `HUB()`
    /// with `safeTransferFrom` and calls `HUB.add(ASSET_ID, amount)`; the Hub reverts when the Coverage Spoke is
    /// inactive or halted or `firstLossReserveAddCap` would be exceeded. Emits `ReserveFunded`.
    /// @param amount Asset base units.
    /// @return shares Hub added shares credited to the Coverage Spoke.
    /// @custom:spec REQ-FLR-010, REQ-FLR-011, REQ-FLR-038, Q-211
    function fund(
        uint256 amount
    ) external returns (uint256 shares);

    /// @notice Eliminates up to `maxAmount` of `borrowSpoke`'s recorded deficit on `ASSET_ID()` by burning this
    /// instance's shares.
    /// @dev `COVERAGE_ROLE` only (`AccessManagedUnauthorized`); reverts `SpokeNotAllowlisted` unless `borrowSpoke` is on
    /// the allowlist and `NothingToCover` if its deficit on the asset or the computed amount is 0. Covers
    /// `min(maxAmount, ceil(deficitRay / RAY), fundedBalance())` (SPEC-FLR-001) through
    /// `HUB.eliminateDeficit(ASSET_ID, amount, borrowSpoke)`; never touches another asset. Emits `DeficitCovered` and,
    /// below the minimum, `ReserveBelowMinimum`.
    /// @param borrowSpoke The CDP Spoke whose deficit is covered.
    /// @param maxAmount Most asset base units to eliminate.
    /// @return shares Coverage Spoke shares burned.
    /// @return covered Asset base units of deficit eliminated.
    /// @custom:spec REQ-FLR-016, REQ-FLR-018, REQ-FLR-019, REQ-FLR-021, REQ-FLR-040, SPEC-FLR-001, Q-236
    function coverDeficit(
        address borrowSpoke,
        uint256 maxAmount
    ) external returns (uint256 shares, uint256 covered);

    /// @notice The covered asset.
    /// @return asset Token address (the instance's debt asset).
    /// @custom:spec REQ-FLR-039
    function ASSET() external view returns (address asset);

    /// @notice The Hub whose asset this instance covers.
    /// @return hub Hub address.
    /// @custom:spec REQ-FLR-039
    function HUB() external view returns (address hub);

    /// @notice `ASSET()`'s asset ID on `HUB()`.
    /// @return assetId Hub asset ID.
    /// @custom:spec REQ-FLR-008, REQ-FLR-039
    function ASSET_ID() external view returns (uint256 assetId);

    /// @notice What the instance's added shares redeem for on the Hub, rounded down (SPEC-FLR-002).
    /// @return balance Asset base units.
    /// @custom:spec REQ-FLR-014, SPEC-FLR-002
    function fundedBalance() external view returns (uint256 balance);

    /// @notice Whether `fundedBalance()` is below the instance's `firstLossReserveMinimum`.
    /// @dev Never reverts on a listed, active instance. The Lens and monitoring read it for the low-balance alert; no
    /// breaker reads it and no on-chain borrowing stop follows from it (Q-399): the guardians decide on a manual debt
    /// breaker. It clears with the condition, with no reset call.
    /// @return below True when below the minimum.
    /// @custom:spec REQ-FLR-013, REQ-FLR-014, Q-241, Q-399
    function isBelowMinimum() external view returns (bool below);

    /// @notice The instance's minimum funded balance, `firstLossReserveMinimum[ASSET]`, set only by the Aave DAO.
    /// @dev Read by the Lens for `getTailCoverage` and by monitoring; sized per SPEC-FLR-004 and SPEC-FLR-005.
    /// @return minimum Asset base units.
    /// @custom:spec REQ-FLR-013, REQ-FLR-041, SPEC-FLR-005
    function firstLossReserveMinimum() external view returns (uint256 minimum);
}
