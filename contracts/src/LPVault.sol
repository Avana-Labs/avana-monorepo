// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "./interfaces/ILPVault.sol";
import {ClTickMath} from "./libraries/ClTickMath.sol";
import {FloorCreditMath} from "./libraries/FloorCreditMath.sol";
import {LPVaultStorage} from "./libraries/LPVaultStorage.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPVault
/// @notice Shared concentrated-liquidity base of every AMM's LPVault: band markets, one record per pledged NFT, floor
/// credit, liquidity top-ups, partial and full release, liquidation unwinds and per-position fees.
/// @dev Pool-neutral: an AMM part supplies the position reads and the liquidity calls. Every mutating function is
/// `nonReentrant` on one transient guard, then `restricted` (AccessManager roles: the adapter for user flows, the
/// liquidation role for `unwind`, the risk role for `listMarket`), so the lock is held before any external call. NFTs
/// move only by `transferFrom`, so no receiver hook runs and a pushed NFT is refused.
abstract contract LPVault is ILPVault, LPVaultStorage, AccessManaged, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @inheritdoc ILPVault
    uint256 public constant override MAX_POSITIONS = 16;

    /// @notice Binds the AccessManager.
    /// @dev Reverts `InvalidDeployment` for a zero authority.
    constructor(
        address authority
    ) AccessManaged(authority) {
        if (authority == address(0)) revert InvalidDeployment();
    }

    /// @inheritdoc ILPVault
    function listMarket(
        uint256 marketId,
        bytes32 pool,
        int24 bandLower,
        int24 bandUpper
    ) external override nonReentrant restricted {
        if (marketId == 0 || marketId > type(uint96).max || _markets[marketId].pool != bytes32(0)) {
            revert InvalidMarketId(marketId);
        }
        if (pool == bytes32(0)) revert InvalidPool(pool);
        (address token0, address token1, int24 spacing) = _poolInfo(pool);
        if (
            bandLower >= bandUpper || spacing <= 0 || bandLower % spacing != 0 || bandUpper % spacing != 0
                || bandLower < ClTickMath.MIN_TICK || bandUpper > ClTickMath.MAX_TICK
        ) revert InvalidBand(bandLower, bandUpper);
        _markets[marketId] = Market({
            pool: pool, token0: token0, token1: token1, bandLower: bandLower, bandUpper: bandUpper, totalCredit: 0
        });
        // nonReentrant holds the lock across the calls before this event, so no reentrant call can reorder or forge it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MarketListed(marketId, pool, token0, token1, bandLower, bandUpper);
    }

    /// @inheritdoc ILPVault
    /// @dev The record is written before the NFT is pulled; the pull is checked by `ownerOf` after.
    function pledge(
        address from,
        address account,
        uint256 marketId,
        bytes32 positionKey
    ) external override nonReentrant restricted returns (uint128 credit) {
        _checkAddress(account);
        Market storage m = _listed(marketId);
        if (_positions[positionKey].account != address(0)) revert AlreadyPledged(positionKey);
        uint128 liquidity;
        (liquidity, credit) = _creditOf(m, positionKey);
        if (credit == 0) revert ZeroCredit(positionKey);
        (IERC721 nft, uint256 tokenId) = _nft(positionKey);
        if (from == address(this) || nft.ownerOf(tokenId) != from) revert NotTokenOwner(positionKey);
        _checkPledgeable(m, positionKey);
        bytes32[] storage list = _accountPositions[account];
        if (list.length >= MAX_POSITIONS) revert TooManyPositions(account);
        list.push(positionKey);
        // marketId fits uint96, checked at listing.
        // forge-lint: disable-next-line(unsafe-typecast)
        _positions[positionKey] =
            Position({account: account, marketId: SafeCast.toUint96(marketId), liquidity: liquidity, credit: credit});
        m.totalCredit += credit;
        _recordPledge(positionKey);
        // nonReentrant holds the lock across the calls before this event, so no reentrant call can reorder or forge it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PositionPledged(positionKey, account, marketId, from, liquidity, credit);
        nft.transferFrom(from, address(this), tokenId);
        if (nft.ownerOf(tokenId) != address(this)) revert NotTokenOwner(positionKey);
    }

    /// @inheritdoc ILPVault
    function addLiquidity(
        bytes32 positionKey,
        address payer,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    )
        external
        override
        nonReentrant
        restricted
        returns (uint128 liquidity, uint128 credit, uint256 amount0, uint256 amount1)
    {
        Market storage m = _markets[_record(positionKey).marketId];
        uint256[4] memory amounts = [amount0Desired, amount1Desired, amount0Min, amount1Min];
        // `payer` is the adapter's own caller (AaveAdapter.addLiquidity passes msg.sender); only the adapter role reaches this.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (amount0Desired != 0) IERC20(m.token0).safeTransferFrom(payer, address(this), amount0Desired);
        // Same `payer` as the line above.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        if (amount1Desired != 0) IERC20(m.token1).safeTransferFrom(payer, address(this), amount1Desired);
        (liquidity, amount0, amount1) = _addLiquidity(m, positionKey, amounts);
        credit = _creditAdded(m, positionKey, liquidity);
        // nonReentrant holds the lock across the calls before this event, so no reentrant call can reorder or forge it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit LiquidityAdded(positionKey, payer, liquidity, credit, amount0, amount1);
        if (amount0Desired > amount0) IERC20(m.token0).safeTransfer(payer, amount0Desired - amount0);
        if (amount1Desired > amount1) IERC20(m.token1).safeTransfer(payer, amount1Desired - amount1);
    }

    /// @inheritdoc ILPVault
    function removeLiquidity(
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override nonReentrant restricted returns (uint128 credit, uint256 amount0, uint256 amount1) {
        Position storage p = _record(positionKey);
        if (liquidity == 0 || liquidity > p.liquidity) revert InvalidAmount(positionKey, liquidity);
        credit = _debit(p, positionKey, liquidity);
        (amount0, amount1) = _remove(positionKey, p.marketId, liquidity, amount0Min, amount1Min, recipient);
        // nonReentrant holds the lock across the calls before this event, so no reentrant call can reorder or forge it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit LiquidityRemoved(positionKey, recipient, liquidity, credit, amount0, amount1);
    }

    /// @inheritdoc ILPVault
    function release(
        bytes32 positionKey,
        address recipient
    ) external override nonReentrant restricted returns (uint128 credit) {
        _checkAddress(recipient);
        Position memory p = _record(positionKey);
        credit = p.credit;
        _markets[p.marketId].totalCredit -= credit;
        _removeFromAccount(p.account, positionKey);
        delete _positions[positionKey];
        uint256[2] memory held = _heldFees[positionKey];
        delete _heldFees[positionKey];
        // nonReentrant holds the lock across the calls before this event, so no reentrant call can reorder or forge it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PositionReleased(positionKey, p.account, recipient, p.liquidity, credit);
        (IERC721 nft, uint256 tokenId) = _nft(positionKey);
        nft.transferFrom(address(this), recipient, tokenId);
        _payFees(positionKey, _markets[p.marketId], held[0], held[1], recipient);
    }

    /// @inheritdoc ILPVault
    function unwind(
        bytes32 positionKey,
        uint128 credit,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    )
        external
        override
        nonReentrant
        restricted
        returns (uint128 liquidity, uint128 creditRemoved, uint256 amount0, uint256 amount1)
    {
        Position storage p = _record(positionKey);
        if (credit == 0 || p.credit == 0) revert InvalidAmount(positionKey, credit);
        // ceil(credit · L / C) ≤ L once credit ≤ C; the cap covers credit > C.
        uint256 needed = Math.mulDiv(credit, p.liquidity, p.credit, Math.Rounding.Ceil);
        // At most the record's uint128 liquidity.
        // forge-lint: disable-next-line(unsafe-typecast)
        liquidity = needed < p.liquidity ? uint128(needed) : p.liquidity;
        creditRemoved = _debit(p, positionKey, liquidity);
        (amount0, amount1) = _remove(positionKey, p.marketId, liquidity, amount0Min, amount1Min, recipient);
        // nonReentrant holds the lock across the calls before this event, so no reentrant call can reorder or forge it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PositionUnwound(positionKey, recipient, liquidity, creditRemoved, amount0, amount1);
    }

    /// @inheritdoc ILPVault
    function collectFees(
        address account,
        bytes32[] calldata positionKeys,
        address recipient
    ) external override nonReentrant restricted returns (uint256[] memory amounts0, uint256[] memory amounts1) {
        _checkAddress(recipient);
        uint256 n = positionKeys.length;
        amounts0 = new uint256[](n);
        amounts1 = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            bytes32 key = positionKeys[i];
            Position storage p = _record(key);
            // A failed check reverts the whole call, the intended outcome also when a caller loops.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (p.account != account) revert NotPositionAccount(key, account);
            Market storage m = _markets[p.marketId];
            uint256[2] memory held = _heldFees[key];
            // One delete per position the caller asked to collect; the caller bounds the loop.
            // forge-lint: disable-next-line(costly-loop)
            delete _heldFees[key];
            (uint256 c0, uint256 c1) = _collect(m, key);
            (amounts0[i], amounts1[i]) = (held[0] + c0, held[1] + c1);
            _payFees(key, m, amounts0[i], amounts1[i], recipient);
        }
    }

    /// @inheritdoc ILPVault
    function getMarket(
        uint256 marketId
    ) external view override returns (Market memory) {
        return _markets[marketId];
    }

    /// @inheritdoc ILPVault
    function getPosition(
        bytes32 positionKey
    ) external view override returns (Position memory) {
        return _positions[positionKey];
    }

    /// @inheritdoc ILPVault
    function positionsOf(
        address account
    ) external view override returns (bytes32[] memory) {
        return _accountPositions[account];
    }

    /// @inheritdoc ILPVault
    function accountCredit(
        address account,
        uint256 marketId
    ) external view override returns (uint256 credit) {
        bytes32[] storage list = _accountPositions[account];
        for (uint256 i = 0; i < list.length; ++i) {
            Position storage p = _positions[list[i]];
            if (p.marketId == marketId) credit += p.credit;
        }
    }

    /// @inheritdoc ILPVault
    function positionInfo(
        bytes32 positionKey
    ) external view override returns (bytes32 pool, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        return _readPosition(positionKey);
    }

    /// @inheritdoc ILPVault
    function previewCredit(
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (uint128 credit) {
        (, credit) = _creditOf(_listed(marketId), positionKey);
    }

    /// @inheritdoc ILPVault
    function feesOf(
        bytes32 positionKey
    ) external view override returns (uint256 amount0, uint256 amount1) {
        Position storage p = _record(positionKey);
        (amount0, amount1) = _uncollectedFees(_markets[p.marketId], positionKey);
        amount0 += _heldFees[positionKey][0];
        amount1 += _heldFees[positionKey][1];
    }

    /// @inheritdoc ILPVault
    function locked() external view override returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @dev The NFT contract and token ID of a position key.
    function _nft(
        bytes32 positionKey
    ) internal view virtual returns (IERC721 nft, uint256 tokenId);

    /// @dev The position's pool (zero when none), ticks and live liquidity.
    function _readPosition(
        bytes32 positionKey
    ) internal view virtual returns (bytes32 pool, int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @dev The tokens and tick spacing of a canonical, usable pool; reverts `InvalidPool` otherwise.
    function _poolInfo(
        bytes32 pool
    ) internal view virtual returns (address token0, address token1, int24 tickSpacing);

    /// @dev AMM-specific pledge checks that move nothing.
    function _checkPledgeable(
        Market storage m,
        bytes32 positionKey
    ) internal view virtual {}

    /// @dev AMM-specific bookkeeping of a new record, before the NFT is pulled.
    function _recordPledge(
        bytes32 positionKey
    ) internal virtual {}

    /// @dev Adds liquidity from tokens the LPVault holds; returns the liquidity added, the tokens used and any fees
    /// the AMM paid out to the LPVault on the way.
    function _increase(
        Market storage m,
        bytes32 positionKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal virtual returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);

    /// @dev Removes exactly `liquidity`, delivering principal and any fees paid out with it to the LPVault.
    function _decrease(
        Market storage m,
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal virtual returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1);

    /// @dev Collects every owed fee of the position to the LPVault.
    function _collect(
        Market storage m,
        bytes32 positionKey
    ) internal virtual returns (uint256 amount0, uint256 amount1);

    /// @dev Fees the AMM would pay the position now.
    function _uncollectedFees(
        Market storage m,
        bytes32 positionKey
    ) internal view virtual returns (uint256 amount0, uint256 amount1);

    function _listed(
        uint256 marketId
    ) internal view returns (Market storage m) {
        m = _markets[marketId];
        if (m.pool == bytes32(0)) revert MarketNotListed(marketId);
    }

    function _record(
        bytes32 positionKey
    ) internal view returns (Position storage p) {
        p = _positions[positionKey];
        // A failed check reverts the whole call, the intended outcome also when a caller loops.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (p.account == address(0)) revert NotPledged(positionKey);
    }

    /// @dev Live liquidity and floor credit of a position of the market's pool; reverts outside the band.
    function _creditOf(
        Market storage m,
        bytes32 positionKey
    ) internal view returns (uint128 liquidity, uint128 credit) {
        (bytes32 pool, int24 tickLower, int24 tickUpper, uint128 live) = _readPosition(positionKey);
        if (pool != m.pool) revert PoolMismatch(positionKey, pool);
        liquidity = live;
        credit = _floorCredit(m, tickLower, tickUpper, live);
    }

    /// @dev Runs the AMM's increase on `[desired0, desired1, min0, min1]`, checks it and keeps any fees it paid out.
    function _addLiquidity(
        Market storage m,
        bytes32 positionKey,
        uint256[4] memory amounts
    ) private returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        uint256 fee0;
        uint256 fee1;
        (liquidity, amount0, amount1, fee0, fee1) =
            _increase(m, positionKey, amounts[0], amounts[1], amounts[2], amounts[3]);
        if (liquidity == 0) revert InvalidAmount(positionKey, 0);
        _checkMinimums(amount0, amount1, amounts[2], amounts[3]);
        _holdFees(positionKey, fee0, fee1);
    }

    /// @dev Credits added liquidity with the floor credit of `liquidity` alone. The floor credit is superadditive (each
    /// rounding step is a floor of a non-decreasing linear map), so the record stays within the floor of its total.
    function _creditAdded(
        Market storage m,
        bytes32 positionKey,
        uint128 liquidity
    ) private returns (uint128 credit) {
        (, int24 tickLower, int24 tickUpper,) = _readPosition(positionKey);
        credit = _floorCredit(m, tickLower, tickUpper, liquidity);
        Position storage p = _positions[positionKey];
        p.liquidity += liquidity;
        p.credit += credit;
        m.totalCredit += credit;
    }

    /// @dev Floor credit of `liquidity` on `[tickLower, tickUpper]` in the market's band. A position on exactly the band's
    /// ticks is `liquidity` band units, so it is credited exactly that (the formula would lose a few units to rounding).
    function _floorCredit(
        Market storage m,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) private view returns (uint128) {
        if (tickLower == m.bandLower && tickUpper == m.bandUpper) return liquidity;
        return FloorCreditMath.credit(tickLower, tickUpper, m.bandLower, m.bandUpper, liquidity);
    }

    /// @dev Lowers a record by `liquidity` and its credit in proportion, rounded down and capped at the floor credit of
    /// the liquidity left (the floor rounds per amount, so a proportional share can exceed it by a few units).
    function _debit(
        Position storage p,
        bytes32 positionKey,
        uint128 liquidity
    ) private returns (uint128 removed) {
        uint128 left = p.liquidity - liquidity;
        // At most the record's uint128 credit.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 creditLeft = uint128(Math.mulDiv(p.credit, left, p.liquidity));
        if (creditLeft != 0) {
            Market storage m = _markets[p.marketId];
            (, int24 tickLower, int24 tickUpper,) = _readPosition(positionKey);
            uint128 floor = _floorCredit(m, tickLower, tickUpper, left);
            if (floor < creditLeft) creditLeft = floor;
        }
        removed = p.credit - creditLeft;
        p.liquidity = left;
        p.credit = creditLeft;
        _markets[p.marketId].totalCredit -= removed;
    }

    /// @dev Removes liquidity through the AMM, keeps its fees for the position and sends the principal.
    function _remove(
        bytes32 positionKey,
        uint256 marketId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) private returns (uint256 amount0, uint256 amount1) {
        _checkAddress(recipient);
        Market storage m = _markets[marketId];
        uint256 fee0;
        uint256 fee1;
        (amount0, amount1, fee0, fee1) = _decrease(m, positionKey, liquidity, amount0Min, amount1Min);
        _checkMinimums(amount0, amount1, amount0Min, amount1Min);
        _holdFees(positionKey, fee0, fee1);
        if (amount0 != 0) IERC20(m.token0).safeTransfer(recipient, amount0);
        if (amount1 != 0) IERC20(m.token1).safeTransfer(recipient, amount1);
    }

    function _holdFees(
        bytes32 positionKey,
        uint256 fee0,
        uint256 fee1
    ) private {
        if (fee0 == 0 && fee1 == 0) return;
        _heldFees[positionKey][0] += fee0;
        _heldFees[positionKey][1] += fee1;
        // nonReentrant holds the lock across the calls before this event, so no reentrant call can reorder or forge it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FeesHeld(positionKey, fee0, fee1);
    }

    function _payFees(
        bytes32 positionKey,
        Market storage m,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) private {
        if (amount0 == 0 && amount1 == 0) return;
        // nonReentrant holds the lock across the calls before this event, so no reentrant call can reorder or forge it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FeesCollected(positionKey, recipient, amount0, amount1);
        if (amount0 != 0) IERC20(m.token0).safeTransfer(recipient, amount0);
        if (amount1 != 0) IERC20(m.token1).safeTransfer(recipient, amount1);
    }

    function _removeFromAccount(
        address account,
        bytes32 positionKey
    ) private {
        bytes32[] storage list = _accountPositions[account];
        uint256 last = list.length - 1;
        for (uint256 i = 0; i < last; ++i) {
            if (list[i] == positionKey) {
                list[i] = list[last];
                break;
            }
        }
        list.pop();
    }

    function _checkMinimums(
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min
    ) private pure {
        if (amount0 < amount0Min) revert BelowMinimum(0, amount0, amount0Min);
        if (amount1 < amount1Min) revert BelowMinimum(1, amount1, amount1Min);
    }

    function _checkAddress(
        address account
    ) private view {
        if (account == address(0) || account == address(this)) revert InvalidAddress(account);
    }
}
