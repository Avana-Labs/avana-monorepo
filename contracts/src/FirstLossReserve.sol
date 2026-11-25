// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "./dependencies/aave/IAaveV4Hub.sol";
import {IFirstLossReserve} from "./interfaces/IFirstLossReserve.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FirstLossReserve
/// @notice Covers recorded deficits of one `(Hub, debt asset)` before Aave's suppliers. Deployed twice per pair: as
/// Avana's First-Loss Reserve (`firstLossLayer == 0`) and as the DAO Deficit Offset behind it.
/// @dev Not upgradeable. Holds no tokens: its funds are Hub added shares. Its only authority is its AccessManager.
contract FirstLossReserve is IFirstLossReserve, AccessManaged, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Aave's deficit scale: asset units times 1e27.
    uint256 internal constant RAY = 1e27;

    /// @inheritdoc IFirstLossReserve
    uint32 public constant override WITHDRAWAL_DELAY = 14 days;

    /// @inheritdoc IFirstLossReserve
    address public immutable override HUB;
    /// @inheritdoc IFirstLossReserve
    address public immutable override ASSET;
    /// @inheritdoc IFirstLossReserve
    uint256 public immutable override ASSET_ID;
    /// @inheritdoc IFirstLossReserve
    address public immutable override FIRST_LOSS_LAYER;

    /// @inheritdoc IFirstLossReserve
    mapping(address spoke => bool allowed) public override isAllowedSpoke;
    /// @inheritdoc IFirstLossReserve
    uint256 public override minimum;

    /// @dev Reverts `ZeroAddress` for a zero Hub, asset or authority, `InvalidHubAsset` unless the Hub lists `asset`
    /// with its decimals under `assetId`, and `InvalidFirstLossLayer` for a layer of another pair or one that is
    /// itself an offset.
    /// @param hub The Hub.
    /// @param asset The covered debt asset.
    /// @param assetId The asset's ID on the Hub.
    /// @param authority The AccessManager.
    /// @param firstLossLayer Zero for Avana's First-Loss Reserve; Avana's reserve of the same pair for the DAO offset.
    constructor(
        address hub,
        address asset,
        uint256 assetId,
        address authority,
        address firstLossLayer
    ) AccessManaged(authority) {
        if (hub == address(0) || asset == address(0) || authority == address(0)) revert ZeroAddress();
        (address underlying, uint8 hubDecimals) = IAaveV4Hub(hub).getAssetUnderlyingAndDecimals(assetId);
        if (underlying != asset || hubDecimals != IERC20Metadata(asset).decimals()) revert InvalidHubAsset(assetId);
        if (firstLossLayer != address(0)) {
            IFirstLossReserve layer = IFirstLossReserve(firstLossLayer);
            if (
                layer.HUB() != hub || layer.ASSET() != asset || layer.ASSET_ID() != assetId
                    || layer.FIRST_LOSS_LAYER() != address(0)
            ) revert InvalidFirstLossLayer(firstLossLayer);
        }
        (HUB, ASSET, ASSET_ID, FIRST_LOSS_LAYER) = (hub, asset, assetId, firstLossLayer);
    }

    /// @inheritdoc IFirstLossReserve
    function fund(
        uint256 amount
    ) external override nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        IERC20 asset = IERC20(ASSET);
        uint256 before = asset.balanceOf(HUB);
        asset.safeTransferFrom(msg.sender, HUB, amount);
        uint256 received = asset.balanceOf(HUB) - before;
        if (received != amount) revert TransferAmountMismatch(amount, received);
        shares = IAaveV4Hub(HUB).add(ASSET_ID, amount);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Funded(msg.sender, amount, shares, fundedBalance());
    }

    /// @inheritdoc IFirstLossReserve
    function coverDeficit(
        address spoke,
        uint256 maxAmount
    ) external override nonReentrant restricted returns (uint256 shares, uint256 covered) {
        if (!isAllowedSpoke[spoke]) revert SpokeNotAllowed(spoke);
        // Below ceil(deficitRay / RAY) the Hub cancels exactly `amount`; at it, the whole recorded deficit.
        uint256 owed = Math.ceilDiv(IAaveV4Hub(HUB).getSpokeDeficitRay(ASSET_ID, spoke), RAY);
        // The loss order by amount: what the layer in front holds is its share, so this layer pays only the part beyond
        // it. A deposit into that layer (`fund` is open) lowers this layer's part instead of blocking it.
        uint256 front = _frontBalance();
        if (front != 0 && front >= owed) revert FirstLossLayerNotExhausted(FIRST_LOSS_LAYER, front);
        uint256 amount = Math.min(Math.min(maxAmount, owed - front), fundedBalance());
        if (amount == 0) revert NothingToCover(spoke);
        (shares, covered) = IAaveV4Hub(HUB).eliminateDeficit(ASSET_ID, amount, spoke);
        uint256 balance = fundedBalance();
        // forge-lint: disable-next-line(reentrancy-events)
        emit DeficitCovered(spoke, msg.sender, covered, shares, balance);
        _alertIfBelowMinimum(balance);
    }

    /// @inheritdoc IFirstLossReserve
    function setAllowedSpoke(
        address spoke,
        bool allowed
    ) external override restricted {
        if (allowed) {
            if (spoke == address(0)) revert ZeroAddress();
            if (!IAaveV4Hub(HUB).isSpokeListed(ASSET_ID, spoke)) revert SpokeNotListed(spoke);
        }
        isAllowedSpoke[spoke] = allowed;
        // forge-lint: disable-next-line(reentrancy-events)
        emit SpokeAllowed(spoke, allowed);
    }

    /// @inheritdoc IFirstLossReserve
    function setMinimum(
        uint256 newMinimum
    ) external override restricted {
        minimum = newMinimum;
        // forge-lint: disable-next-line(reentrancy-events)
        emit MinimumSet(newMinimum);
    }

    /// @inheritdoc IFirstLossReserve
    function withdraw(
        uint256 amount,
        address to
    ) external override nonReentrant restricted returns (uint256 withdrawn) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0) || to == address(this) || to == HUB) revert InvalidRecipient(to);
        _checkNoDeficit();
        withdrawn = Math.min(amount, fundedBalance());
        if (withdrawn == 0) revert ZeroAmount();
        uint256 shares = IAaveV4Hub(HUB).remove(ASSET_ID, withdrawn, to);
        uint256 balance = fundedBalance();
        // forge-lint: disable-next-line(reentrancy-events)
        emit Withdrawn(to, withdrawn, shares, balance);
        _alertIfBelowMinimum(balance);
    }

    /// @inheritdoc IFirstLossReserve
    function fundedBalance() public view override returns (uint256) {
        return IAaveV4Hub(HUB).getSpokeAddedAssets(ASSET_ID, address(this));
    }

    /// @inheritdoc IFirstLossReserve
    function fundedShares() external view override returns (uint256) {
        return IAaveV4Hub(HUB).getSpokeAddedShares(ASSET_ID, address(this));
    }

    /// @inheritdoc IFirstLossReserve
    function isBelowMinimum() external view override returns (bool) {
        return fundedBalance() < minimum;
    }

    /// @dev What the layer in front holds: zero for Avana's own layer, and for a deactivated layer, which cannot call
    /// `eliminateDeficit`, so the offset may then pay the whole deficit.
    function _frontBalance() internal view returns (uint256) {
        address layer = FIRST_LOSS_LAYER;
        if (layer == address(0) || !IAaveV4Hub(HUB).getSpokeConfig(ASSET_ID, layer).active) return 0;
        return IFirstLossReserve(layer).fundedBalance();
    }

    /// @dev Reverts `DeficitOutstanding` with the first allowed Spoke in the Hub's list that has a deficit.
    function _checkNoDeficit() internal view {
        IAaveV4Hub hub = IAaveV4Hub(HUB);
        uint256 count = hub.getSpokeCount(ASSET_ID);
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        for (uint256 i; i < count; ++i) {
            address spoke = hub.getSpokeAddress(ASSET_ID, i);
            if (isAllowedSpoke[spoke] && hub.getSpokeDeficitRay(ASSET_ID, spoke) != 0) {
                revert DeficitOutstanding(spoke);
            }
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    function _alertIfBelowMinimum(
        uint256 balance
    ) internal {
        uint256 min = minimum;
        // forge-lint: disable-next-line(reentrancy-events)
        if (balance < min) emit BelowMinimum(balance, min);
    }
}
