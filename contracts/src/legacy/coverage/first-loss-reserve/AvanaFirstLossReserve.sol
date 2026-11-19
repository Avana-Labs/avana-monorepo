// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAvanaFirstLossReserve} from "./IAvanaFirstLossReserve.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AvanaFirstLossReserve
/// @notice Avana Umbrella of one `(HUB, ASSET)`: a supply-only Spoke whose Hub shares cover allowlisted deficits.
/// @dev Immutable; its only authority is its AccessManager. Holds no tokens between transactions.
contract AvanaFirstLossReserve is IAvanaFirstLossReserve, AccessManaged, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Aave's deficit scale (asset units * 1e27).
    uint256 internal constant RAY = 1e27;

    IAaveV4Hub internal immutable _HUB;

    address internal immutable _ASSET;

    uint256 internal immutable _ASSET_ID;

    mapping(address spoke => bool allowed) public override allowedBorrowSpoke;

    /// @inheritdoc IAvanaFirstLossReserve
    uint256 public override firstLossReserveMinimum;

    /// @inheritdoc IAvanaFirstLossReserve
    uint256 public override totalFunded;

    /// @inheritdoc IAvanaFirstLossReserve
    uint256 public override totalCovered;

    /// @inheritdoc IAvanaFirstLossReserve
    uint256 public override totalWithdrawn;

    constructor(
        address hub,
        address asset,
        uint256 assetId,
        address authority
    ) AccessManaged(authority) {
        if (hub == address(0) || asset == address(0) || authority == address(0)) revert ZeroAddress();
        _HUB = IAaveV4Hub(hub);
        _ASSET = asset;
        _ASSET_ID = assetId;
        (address underlying, uint8 hubDecimals) = IAaveV4Hub(hub).getAssetUnderlyingAndDecimals(assetId);
        if (underlying != asset || hubDecimals != IERC20Metadata(asset).decimals()) revert InvalidHubAsset(assetId);
    }

    /// @inheritdoc IAvanaFirstLossReserve
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

    /// @inheritdoc IAvanaFirstLossReserve
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
        // `amount <= ceil(deficitRay / RAY)`, so the Hub eliminates exactly `amount`.
        totalCovered += amount;
        (shares, covered) = _HUB.eliminateDeficit(_ASSET_ID, amount, borrowSpoke);
        uint256 balanceAfter = fundedBalance();
        uint256 deficitRayAfter = _HUB.getSpokeDeficitRay(_ASSET_ID, borrowSpoke);
        // forge-lint: disable-next-line(reentrancy-events)
        emit DeficitCovered(borrowSpoke, msg.sender, covered, shares, deficitRayBefore, deficitRayAfter, balanceAfter);
        _alertIfBelowMinimum(balanceAfter);
    }

    /// @inheritdoc IAvanaFirstLossReserve
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

    /// @inheritdoc IAvanaFirstLossReserve
    function setFirstLossReserveMinimum(
        uint256 minimum
    ) external override nonReentrant restricted {
        uint256 oldMinimum = firstLossReserveMinimum;
        firstLossReserveMinimum = minimum;
        // forge-lint: disable-next-line(reentrancy-events)
        emit FirstLossReserveMinimumUpdated(oldMinimum, minimum);
    }

    /// @inheritdoc IAvanaFirstLossReserve
    function withdraw(
        uint256 amount,
        address to
    ) external override nonReentrant restricted returns (uint256 withdrawn) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this) || to == address(_HUB)) revert InvalidRecipient(to);
        _requireNoAllowlistedDeficit();
        withdrawn = Math.min(amount, fundedBalance());
        totalWithdrawn += withdrawn;
        uint256 sharesBurned = _HUB.remove(_ASSET_ID, withdrawn, to);
        uint256 balanceAfter = fundedBalance();
        // forge-lint: disable-next-line(reentrancy-events)
        emit ReserveWithdrawn(to, withdrawn, sharesBurned, balanceAfter);
        _alertIfBelowMinimum(balanceAfter);
    }

    /// @inheritdoc IAvanaFirstLossReserve
    function fundedBalance() public view override returns (uint256 balance) {
        balance = _HUB.getSpokeAddedAssets(_ASSET_ID, address(this));
    }

    /// @inheritdoc IAvanaFirstLossReserve
    function isBelowMinimum() external view override returns (bool below) {
        below = fundedBalance() < firstLossReserveMinimum;
    }

    /// @inheritdoc IAvanaFirstLossReserve
    function fundedShares() external view override returns (uint256 shares) {
        shares = _HUB.getSpokeAddedShares(_ASSET_ID, address(this));
    }

    /// @inheritdoc IAvanaFirstLossReserve
    function ASSET() external view override returns (address asset) {
        asset = _ASSET;
    }

    /// @inheritdoc IAvanaFirstLossReserve
    function HUB() external view override returns (address hub) {
        hub = address(_HUB);
    }

    /// @inheritdoc IAvanaFirstLossReserve
    function ASSET_ID() external view override returns (uint256 assetId) {
        assetId = _ASSET_ID;
    }

    function _requireNoAllowlistedDeficit() internal view {
        uint256 count = _HUB.getSpokeCount(_ASSET_ID);
        address open = address(0);
        // forge-lint: disable-start(calls-loop)
        for (uint256 i = 0; i < count && open == address(0); ++i) {
            address spoke = _HUB.getSpokeAddress(_ASSET_ID, i);
            if (allowedBorrowSpoke[spoke] && _HUB.getSpokeDeficitRay(_ASSET_ID, spoke) != 0) open = spoke;
        }
        // forge-lint: disable-end(calls-loop)
        if (open != address(0)) revert DeficitOutstanding(open);
    }

    /// @notice Loss-order hook run by `coverDeficit`; `DaoDeficitOffset` overrides it.
    function _beforeCover() internal view virtual {}

    function _alertIfBelowMinimum(
        uint256 balance
    ) internal {
        uint256 minimum = firstLossReserveMinimum;
        // forge-lint: disable-next-line(reentrancy-events)
        if (balance < minimum) emit ReserveBelowMinimum(balance, minimum);
    }
}
