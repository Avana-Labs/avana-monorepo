// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {INonfungiblePositionManager} from "../../dependencies/uniswap/INonfungiblePositionManager.sol";
import {LPVault} from "../../vault/LPVault.sol";
import {INfpmPositions} from "./interfaces/INfpmPositions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title NfpmLPVault
/// @notice LPVault part shared by the NonfungiblePositionManager AMMs (Uniswap v3, Slipstream): their
/// `increaseLiquidity`, `decreaseLiquidity` and `collect` share one ABI.
/// @dev A decrease collects exactly the principal it removed, so the fees stay owed to the NFT until `_collect`.
abstract contract NfpmLPVault is LPVault {
    using SafeERC20 for IERC20;

    uint256 private constant Q128 = 1 << 128;

    /// @dev The pool of a position's tokens and fee or tick spacing on the factory of the position's manager.
    function _poolOf(
        bytes32 positionKey,
        INfpmPositions.NfpmPositionData memory position
    ) internal view virtual returns (address pool);

    /// @dev The pool's current tick and its global fee growth.
    function _poolGrowth(
        address pool
    ) internal view virtual returns (int24 tick, uint256 global0, uint256 global1);

    /// @dev Fee growth outside a tick.
    function _feeGrowthOutside(
        address pool,
        int24 tick
    ) internal view virtual returns (uint256 outside0, uint256 outside1);

    function _readPosition(
        bytes32 positionKey
    ) internal view override returns (bytes32 pool, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        INfpmPositions.NfpmPositionData memory p = _position(positionKey);
        return (bytes32(uint256(uint160(_poolOf(positionKey, p)))), p.tickLower, p.tickUpper, p.liquidity);
    }

    /// @dev Approves the manager for the desired amounts only for the call.
    function _increase(
        Market storage m,
        bytes32 positionKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal override returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256, uint256) {
        (INonfungiblePositionManager nfpm, uint256 tokenId) = _manager(positionKey);
        IERC20(m.token0).forceApprove(address(nfpm), amount0Desired);
        IERC20(m.token1).forceApprove(address(nfpm), amount1Desired);
        (liquidity, amount0, amount1) = nfpm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        IERC20(m.token0).forceApprove(address(nfpm), 0);
        IERC20(m.token1).forceApprove(address(nfpm), 0);
        return (liquidity, amount0, amount1, 0, 0);
    }

    /// @dev `collect` is capped at exactly the removed amounts, which the position now owes.
    function _decrease(
        Market storage,
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal override returns (uint256 amount0, uint256 amount1, uint256, uint256) {
        (INonfungiblePositionManager nfpm, uint256 tokenId) = _manager(positionKey);
        (amount0, amount1) = nfpm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        if (amount0 != 0 || amount1 != 0) {
            (amount0, amount1) = nfpm.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: SafeCast.toUint128(amount0),
                    amount1Max: SafeCast.toUint128(amount1)
                })
            );
        }
        return (amount0, amount1, 0, 0);
    }

    /// @dev The manager's `collect` updates the position's owed fees first.
    function _collect(
        Market storage,
        bytes32 positionKey
    ) internal override returns (uint256 amount0, uint256 amount1) {
        (INonfungiblePositionManager nfpm, uint256 tokenId) = _manager(positionKey);
        (amount0, amount1) = nfpm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
    }

    /// @dev Owed fees plus `liquidity · (inside − insideLast) / 2^128`, the growth differences taken modulo 2^256.
    function _uncollectedFees(
        Market storage,
        bytes32 positionKey
    ) internal view override returns (uint256 amount0, uint256 amount1) {
        INfpmPositions.NfpmPositionData memory p = _position(positionKey);
        (amount0, amount1) = (p.tokensOwed0, p.tokensOwed1);
        if (p.liquidity == 0) return (amount0, amount1);
        address pool = _poolOf(positionKey, p);
        (int24 tick, uint256 g0, uint256 g1) = _poolGrowth(pool);
        (uint256 lo0, uint256 lo1) = _feeGrowthOutside(pool, p.tickLower);
        (uint256 hi0, uint256 hi1) = _feeGrowthOutside(pool, p.tickUpper);
        uint256 d0;
        uint256 d1;
        // Fee growth wraps by design; Uniswap takes these differences modulo 2^256.
        unchecked {
            uint256 in0;
            uint256 in1;
            if (tick < p.tickLower) (in0, in1) = (lo0 - hi0, lo1 - hi1);
            else if (tick >= p.tickUpper) (in0, in1) = (hi0 - lo0, hi1 - lo1);
            else (in0, in1) = (g0 - lo0 - hi0, g1 - lo1 - hi1);
            d0 = in0 - p.feeGrowthInside0LastX128;
            d1 = in1 - p.feeGrowthInside1LastX128;
        }
        amount0 += Math.mulDiv(d0, p.liquidity, Q128);
        amount1 += Math.mulDiv(d1, p.liquidity, Q128);
    }

    function _position(
        bytes32 positionKey
    ) private view returns (INfpmPositions.NfpmPositionData memory) {
        (INonfungiblePositionManager nfpm, uint256 tokenId) = _manager(positionKey);
        return INfpmPositions(address(nfpm)).positions(tokenId);
    }

    function _manager(
        bytes32 positionKey
    ) private view returns (INonfungiblePositionManager nfpm, uint256 tokenId) {
        (IERC721 nft, uint256 id) = _nft(positionKey);
        return (INonfungiblePositionManager(address(nft)), id);
    }
}
