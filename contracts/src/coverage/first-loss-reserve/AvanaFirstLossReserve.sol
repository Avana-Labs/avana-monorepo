// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAvanaFirstLossReserve} from "./IAvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserveAdmin} from "./IAvanaFirstLossReserveAdmin.sol";
import {IAvanaFirstLossReserveErrors} from "./IAvanaFirstLossReserveErrors.sol";
import {IAvanaFirstLossReserveViews} from "./IAvanaFirstLossReserveViews.sol";
import {Withdrawal, WithdrawalStatus} from "./types/Withdrawal.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title AvanaFirstLossReserve
/// @notice Avana Umbrella (First-Loss Reserve): the First-Loss Reserve of one `(HUB, ASSET)`. A supply-only Spoke with
/// zero draw capacity whose Hub added shares are Avana-funded first-loss capital; it burns them only through
/// `Hub.eliminateDeficit` on its own asset, for recorded deficits of DAO-allowlisted CDP Spokes, never above the
/// recorded deficit or its funded balance, and releases them otherwise only through a DAO withdrawal after
/// `RESERVE_WITHDRAWAL_DELAY`.
/// @dev Immutable (no proxy, owner or upgrade path); its only authority is the Aave DAO's AccessManager
/// (OpenZeppelin `AccessManaged`), which maps `coverDeficit` to `COVERAGE_ROLE` and the `IAvanaFirstLossReserveAdmin`
/// functions to `RESERVE_ADMIN_ROLE`. State-changing Hub calls: `add` (from `fund`), `eliminateDeficit` (from
/// `coverDeficit`) and `remove` (from `executeWithdrawal`), each on `ASSET_ID` only. It holds no tokens between
/// transactions: `fund` moves the asset from the caller straight to the Hub and `remove` pays the recipient from the
/// Hub. Every state-changing function is non-reentrant (EIP-1153 transient guard) and writes its state before its
/// external calls; the events that report the Hub's results (shares, balances after) follow those calls.
/// @custom:spec REQ-FLR-001, REQ-FLR-002, REQ-FLR-003, REQ-FLR-004, REQ-FLR-005, REQ-FLR-006, REQ-FLR-012, REQ-FLR-015, REQ-FLR-020, REQ-FLR-022, REQ-FLR-035, REQ-FLR-036, REQ-FLR-040, REQ-FLR-042, INV-042, INV-071, Q-101, Q-142, Q-236
contract AvanaFirstLossReserve is
    IAvanaFirstLossReserve,
    IAvanaFirstLossReserveAdmin,
    IAvanaFirstLossReserveViews,
    IAvanaFirstLossReserveErrors,
    AccessManaged,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice `reserveWithdrawalDelay` of 1.5 Parameters: 14 days.
    uint256 internal constant RESERVE_WITHDRAWAL_DELAY_VALUE = 1_209_600;

    /// @dev Aave's deficit scale: deficits are asset units × 1e27.
    uint256 internal constant RAY = 1e27;

    /// @dev The Hub whose asset this instance covers.
    IAaveV4Hub internal immutable _HUB;

    /// @dev The covered debt asset.
    address internal immutable _ASSET;

    /// @dev `_ASSET`'s asset ID on `_HUB`.
    uint256 internal immutable _ASSET_ID;

    /// @dev Seconds from a withdrawal request to its earliest execution.
    uint256 internal immutable _RESERVE_WITHDRAWAL_DELAY;

    /// @notice DAO-set allowlist of CDP Spokes whose deficits on the asset may be covered (2.14 Storage).
    mapping(address spoke => bool allowed) public override allowedBorrowSpoke;

    /// @inheritdoc IAvanaFirstLossReserve
    uint256 public override firstLossReserveMinimum;

    /// @inheritdoc IAvanaFirstLossReserveViews
    uint256 public override nextWithdrawalId = 1;

    /// @inheritdoc IAvanaFirstLossReserveViews
    uint256 public override totalFunded;

    /// @inheritdoc IAvanaFirstLossReserveViews
    uint256 public override totalCovered;

    /// @inheritdoc IAvanaFirstLossReserveViews
    uint256 public override totalWithdrawn;

    /// @dev Withdrawal requests by ID.
    mapping(uint256 id => Withdrawal request) internal _withdrawals;

    /// @notice Fixes the instance's Hub, asset, asset ID, withdrawal delay and AccessManager.
    /// @dev Reverts `ZeroAddress`, `InvalidHubAsset` unless the Hub lists `asset` under `assetId` with the token's own
    /// decimals, and `InvalidWithdrawalDelay` unless the delay is `reserveWithdrawalDelay`.
    /// @param hub The funding Hub.
    /// @param asset The covered debt asset.
    /// @param assetId `asset`'s asset ID on `hub`.
    /// @param authority The Aave DAO's AccessManager.
    /// @param reserveWithdrawalDelay Seconds; must be 1,209,600.
    /// @custom:spec REQ-FLR-003, REQ-FLR-008, REQ-FLR-039
    constructor(
        address hub,
        address asset,
        uint256 assetId,
        address authority,
        uint256 reserveWithdrawalDelay
    ) AccessManaged(authority) {
        if (hub == address(0) || asset == address(0) || authority == address(0)) revert ZeroAddress();
        if (reserveWithdrawalDelay != RESERVE_WITHDRAWAL_DELAY_VALUE) {
            revert InvalidWithdrawalDelay(reserveWithdrawalDelay);
        }
        _HUB = IAaveV4Hub(hub);
        _ASSET = asset;
        _ASSET_ID = assetId;
        _RESERVE_WITHDRAWAL_DELAY = reserveWithdrawalDelay;
        (address underlying, uint8 hubDecimals) = IAaveV4Hub(hub).getAssetUnderlyingAndDecimals(assetId);
        if (underlying != asset || hubDecimals != IERC20Metadata(asset).decimals()) revert InvalidHubAsset(assetId);
    }

    // ─── Funding (anyone) ───

    /// @inheritdoc IAvanaFirstLossReserve
    /// @custom:spec REQ-FLR-005, REQ-FLR-006, REQ-FLR-010, REQ-FLR-011, REQ-FLR-035, REQ-FLR-037, REQ-FLR-038, Q-211
    function fund(
        uint256 amount
    ) external override nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        totalFunded += amount;
        address hub = address(_HUB);
        IERC20 asset = IERC20(_ASSET);
        uint256 hubBefore = asset.balanceOf(hub);
        asset.safeTransferFrom(msg.sender, hub, amount);
        uint256 received = asset.balanceOf(hub) - hubBefore;
        if (received != amount) revert TransferAmountMismatch(amount, received);
        shares = _HUB.add(_ASSET_ID, amount);
        // forge-lint: disable-next-line(reentrancy-events)
        emit ReserveFunded(msg.sender, amount, shares, fundedBalance());
    }

    // ─── Coverage (COVERAGE_ROLE) ───

    /// @inheritdoc IAvanaFirstLossReserve
    /// @custom:spec REQ-FLR-004, REQ-FLR-006, REQ-FLR-014, REQ-FLR-016, REQ-FLR-018, REQ-FLR-019, REQ-FLR-022, REQ-FLR-027, REQ-FLR-029, REQ-FLR-030, REQ-FLR-031, REQ-FLR-032, REQ-FLR-040, REQ-FLR-048, SPEC-FLR-001, INV-042, INV-071
    function coverDeficit(
        address borrowSpoke,
        uint256 maxAmount
    ) external override nonReentrant restricted returns (uint256 shares, uint256 covered) {
        if (!allowedBorrowSpoke[borrowSpoke]) revert SpokeNotAllowlisted(borrowSpoke);
        uint256 deficitRayBefore = _HUB.getSpokeDeficitRay(_ASSET_ID, borrowSpoke);
        if (deficitRayBefore == 0) revert NothingToCover(borrowSpoke);
        _beforeCover();
        uint256 amount = Math.min(Math.min(maxAmount, Math.ceilDiv(deficitRayBefore, RAY)), fundedBalance());
        if (amount == 0) revert NothingToCover(borrowSpoke);
        // SPEC-FLR-001: amount <= ceil(deficitRay / RAY), so the Hub eliminates exactly `amount` (MATH-ST-114).
        totalCovered += amount;
        (shares, covered) = _HUB.eliminateDeficit(_ASSET_ID, amount, borrowSpoke);
        uint256 balanceAfter = fundedBalance();
        uint256 deficitRayAfter = _HUB.getSpokeDeficitRay(_ASSET_ID, borrowSpoke);
        // forge-lint: disable-next-line(reentrancy-events)
        emit DeficitCovered(borrowSpoke, msg.sender, covered, shares, deficitRayBefore, deficitRayAfter, balanceAfter);
        _alertIfBelowMinimum(balanceAfter);
    }

    // ─── Aave DAO (RESERVE_ADMIN_ROLE) ───

    /// @inheritdoc IAvanaFirstLossReserveAdmin
    /// @custom:spec REQ-FLR-016, REQ-FLR-017
    function setAllowedBorrowSpoke(
        address spoke,
        bool allowed
    ) external override nonReentrant restricted {
        if (allowed) {
            if (spoke == address(0)) revert ZeroAddress();
            if (!_HUB.isSpokeListed(_ASSET_ID, spoke)) revert BorrowSpokeNotListed(spoke);
        }
        allowedBorrowSpoke[spoke] = allowed;
        // forge-lint: disable-next-line(reentrancy-events)
        emit BorrowSpokeAllowlistUpdated(spoke, allowed);
    }

    /// @inheritdoc IAvanaFirstLossReserveAdmin
    /// @custom:spec REQ-FLR-013
    function setFirstLossReserveMinimum(
        uint256 minimum
    ) external override nonReentrant restricted {
        uint256 oldMinimum = firstLossReserveMinimum;
        firstLossReserveMinimum = minimum;
        // forge-lint: disable-next-line(reentrancy-events)
        emit FirstLossReserveMinimumUpdated(oldMinimum, minimum);
    }

    /// @inheritdoc IAvanaFirstLossReserveAdmin
    /// @custom:spec REQ-FLR-023, SPEC-FLR-003
    function requestWithdrawal(
        uint256 amount,
        address to
    ) external override nonReentrant restricted returns (uint256 id) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this) || to == address(_HUB)) revert InvalidRecipient(to);
        uint64 executableAt = (block.timestamp + _RESERVE_WITHDRAWAL_DELAY).toUint64();
        id = nextWithdrawalId++;
        _withdrawals[id] =
            Withdrawal({amount: amount, to: to, executableAt: executableAt, status: WithdrawalStatus.Pending});
        // forge-lint: disable-next-line(reentrancy-events)
        emit WithdrawalRequested(id, amount, to, executableAt);
    }

    /// @inheritdoc IAvanaFirstLossReserveAdmin
    /// @custom:spec REQ-FLR-024
    function cancelWithdrawal(
        uint256 id
    ) external override nonReentrant restricted {
        Withdrawal storage request = _withdrawals[id];
        if (request.status != WithdrawalStatus.Pending) revert WithdrawalNotPending(id);
        request.status = WithdrawalStatus.Cancelled;
        // forge-lint: disable-next-line(reentrancy-events)
        emit WithdrawalCancelled(id);
    }

    /// @inheritdoc IAvanaFirstLossReserveAdmin
    /// @custom:spec REQ-FLR-004, REQ-FLR-006, REQ-FLR-014, REQ-FLR-025, REQ-FLR-026, REQ-FLR-033, REQ-FLR-034, REQ-FLR-035, REQ-FLR-045, SPEC-FLR-003
    function executeWithdrawal(
        uint256 id
    ) external override nonReentrant restricted returns (uint256 withdrawn) {
        Withdrawal storage request = _withdrawals[id];
        if (request.status != WithdrawalStatus.Pending) revert WithdrawalNotPending(id);
        uint64 executableAt = request.executableAt;
        if (block.timestamp < executableAt) revert WithdrawalNotReady(id, executableAt);
        _requireNoAllowlistedDeficit();
        address to = request.to;
        withdrawn = Math.min(request.amount, fundedBalance());
        request.status = WithdrawalStatus.Executed;
        totalWithdrawn += withdrawn;
        uint256 sharesBurned = _HUB.remove(_ASSET_ID, withdrawn, to);
        uint256 balanceAfter = fundedBalance();
        // forge-lint: disable-next-line(reentrancy-events)
        emit WithdrawalExecuted(id, withdrawn, sharesBurned, to, balanceAfter);
        _alertIfBelowMinimum(balanceAfter);
    }

    // ─── Views ───

    /// @inheritdoc IAvanaFirstLossReserve
    /// @custom:spec REQ-FLR-014, REQ-FLR-015, SPEC-FLR-002
    function fundedBalance() public view override returns (uint256 balance) {
        balance = _HUB.getSpokeAddedAssets(_ASSET_ID, address(this));
    }

    /// @inheritdoc IAvanaFirstLossReserve
    /// @custom:spec REQ-FLR-013, REQ-FLR-014, Q-399
    function isBelowMinimum() external view override returns (bool below) {
        below = fundedBalance() < firstLossReserveMinimum;
    }

    /// @inheritdoc IAvanaFirstLossReserveViews
    /// @custom:spec REQ-FLR-001
    function fundedShares() external view override returns (uint256 shares) {
        shares = _HUB.getSpokeAddedShares(_ASSET_ID, address(this));
    }

    /// @inheritdoc IAvanaFirstLossReserveViews
    /// @custom:spec REQ-FLR-023
    function getWithdrawal(
        uint256 id
    ) external view override returns (Withdrawal memory withdrawal) {
        withdrawal = _withdrawals[id];
    }

    /// @inheritdoc IAvanaFirstLossReserve
    /// @custom:spec REQ-FLR-039
    function ASSET() external view override returns (address asset) {
        asset = _ASSET;
    }

    /// @inheritdoc IAvanaFirstLossReserve
    /// @custom:spec REQ-FLR-039
    function HUB() external view override returns (address hub) {
        hub = address(_HUB);
    }

    /// @inheritdoc IAvanaFirstLossReserve
    /// @custom:spec REQ-FLR-008, REQ-FLR-039
    function ASSET_ID() external view override returns (uint256 assetId) {
        assetId = _ASSET_ID;
    }

    /// @inheritdoc IAvanaFirstLossReserveViews
    /// @custom:spec REQ-FLR-008, SPEC-FLR-003
    function RESERVE_WITHDRAWAL_DELAY() external view override returns (uint256 delay) {
        delay = _RESERVE_WITHDRAWAL_DELAY;
    }

    // ─── Internal ───

    /// @notice Reverts `DeficitOutstanding(spoke)` for the first Spoke of the Hub's list on `ASSET_ID` that is on the
    /// allowlist and has a recorded deficit, so no withdrawal runs while a deficit this reserve can cover is open.
    /// @dev Bounded by the Hub's Spoke count on the asset, which only the Aave DAO raises; views only.
    /// @custom:spec REQ-FLR-026, REQ-FLR-045, SPEC-FLR-003
    function _requireNoAllowlistedDeficit() internal view {
        uint256 count = _HUB.getSpokeCount(_ASSET_ID);
        address open = address(0);
        // Views of the instance's own Hub, one Spoke per iteration, bounded by the Spokes the Aave DAO lists on the asset.
        // forge-lint: disable-start(calls-loop)
        for (uint256 i = 0; i < count && open == address(0); ++i) {
            address spoke = _HUB.getSpokeAddress(_ASSET_ID, i);
            if (allowedBorrowSpoke[spoke] && _HUB.getSpokeDeficitRay(_ASSET_ID, spoke) != 0) open = spoke;
        }
        // forge-lint: disable-end(calls-loop)
        if (open != address(0)) revert DeficitOutstanding(open);
    }

    /// @notice Loss-order hook run by `coverDeficit` after the allowlist and recorded-deficit checks and before the
    /// amount is computed; the Avana Umbrella has no layer in front of it, so it accepts every call.
    /// @dev `DaoDeficitOffset` overrides it to require a first-loss layer with a funded balance of zero.
    /// @custom:spec REQ-FLR-048, Q-410
    function _beforeCover() internal view virtual {}

    /// @dev Emits `ReserveBelowMinimum` when the balance left by a coverage or withdrawal is below the minimum.
    /// @custom:spec REQ-FLR-014, REQ-FLR-031
    function _alertIfBelowMinimum(
        uint256 balance
    ) internal {
        uint256 minimum = firstLossReserveMinimum;
        // forge-lint: disable-next-line(reentrancy-events)
        if (balance < minimum) emit ReserveBelowMinimum(balance, minimum);
    }
}
