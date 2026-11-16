// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4PoolManager} from "../../interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title UniswapV4State
/// @notice Reads of Uniswap v4 PoolManager state through `extsload` and `exttload` with the slot layout of v4-core's
/// `StateLibrary` and `Lock` (v4.0.0, e50237c), and the fee arithmetic of its `Pool.getFeeGrowthInside` and
/// `Position.update`.
/// @dev Pool state of `poolId` sits at `keccak256(abi.encode(poolId, 6))`: word 0 is `slot0` (`sqrtPriceX96` in the low
/// 160 bits, `tick` in the next 24), words 1 and 2 the global fee growths, word 3 the in-range liquidity, then the
/// `ticks` mapping at +4 and the `positions` mapping at +6. Fee-growth differences are taken unchecked modulo 2^256, as
/// the PoolManager does, so a wrapped accumulator never panics (`REQ-AMM-V4-010`).
/// @custom:spec REQ-AMM-V4-003, REQ-AMM-V4-010, SPEC-AMM-V4-003
library UniswapV4State {
    /// @dev `StateLibrary.POOLS_SLOT`.
    uint256 internal constant POOLS_SLOT = 6;
    /// @dev Offsets inside a pool's state.
    uint256 internal constant FEE_GROWTH_GLOBAL0_OFFSET = 1;
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    uint256 internal constant TICKS_OFFSET = 4;
    uint256 internal constant POSITIONS_OFFSET = 6;
    /// @dev `Lock.IS_UNLOCKED_SLOT`: non-zero while the PoolManager is inside an `unlock` callback.
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    /// @dev 2^128, the fixed-point base of fee growth.
    uint256 internal constant Q128 = 1 << 128;

    /// @notice A position's fee inputs: its liquidity and the fee growth inside its range at its last update.
    struct PositionState {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    /// @notice Whether the PoolManager is inside an `unlock` callback (`REQ-AMM-V4-003`).
    function isUnlocked(
        IUniswapV4PoolManager manager
    ) internal view returns (bool) {
        return manager.exttload(IS_UNLOCKED_SLOT) != bytes32(0);
    }

    /// @notice Storage slot of a pool's state.
    function poolStateSlot(
        bytes32 poolId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, POOLS_SLOT));
    }

    /// @notice The pool's square-root price and tick; `sqrtPriceX96 == 0` for an uninitialized pool.
    function slot0(
        IUniswapV4PoolManager manager,
        bytes32 poolId
    ) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        // A view read; the Lens calls it in its loop over at most 16 records of one account-market.
        // forge-lint: disable-next-line(calls-loop)
        uint256 word = uint256(manager.extsload(poolStateSlot(poolId)));
        // Low 160 bits, then the 24-bit two's-complement tick above them.
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(word);
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = int24(int256(word >> 160));
    }

    /// @notice The pool's in-range liquidity.
    function liquidity(
        IUniswapV4PoolManager manager,
        bytes32 poolId
    ) internal view returns (uint128) {
        // The low 128 bits of the word.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(uint256(manager.extsload(_offset(poolStateSlot(poolId), LIQUIDITY_OFFSET))));
    }

    /// @notice `Position.calculatePositionKey`: `keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))`.
    function positionId(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    /// @notice A position's liquidity and last fee growth inside, read from the PoolManager (`REQ-AMM-V4-003`).
    function position(
        IUniswapV4PoolManager manager,
        bytes32 poolId,
        bytes32 id
    ) internal view returns (PositionState memory p) {
        bytes32 mappingSlot = _offset(poolStateSlot(poolId), POSITIONS_OFFSET);
        // A view read; the Lens calls it in its loop over at most 16 records of one account-market.
        // forge-lint: disable-next-line(calls-loop)
        bytes32[] memory w = manager.extsload(keccak256(abi.encode(id, mappingSlot)), 3);
        // The struct's first word holds only the uint128 liquidity.
        // forge-lint: disable-next-line(unsafe-typecast)
        p.liquidity = uint128(uint256(w[0]));
        (p.feeGrowthInside0LastX128, p.feeGrowthInside1LastX128) = (uint256(w[1]), uint256(w[2]));
    }

    /// @notice A position's liquidity only.
    function positionLiquidity(
        IUniswapV4PoolManager manager,
        bytes32 poolId,
        bytes32 id
    ) internal view returns (uint128) {
        bytes32 mappingSlot = _offset(poolStateSlot(poolId), POSITIONS_OFFSET);
        // The low 128 bits of the struct's first word.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(uint256(manager.extsload(keccak256(abi.encode(id, mappingSlot)))));
    }

    /// @notice `Pool.getFeeGrowthInside` of `[tickLower, tickUpper]` at the pool's current tick, unchecked.
    function feeGrowthInside(
        IUniswapV4PoolManager manager,
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 inside0, uint256 inside1) {
        bytes32 state = poolStateSlot(poolId);
        (, int24 tick) = slot0(manager, poolId);
        (uint256 lo0, uint256 lo1) = _feeGrowthOutside(manager, state, tickLower);
        (uint256 hi0, uint256 hi1) = _feeGrowthOutside(manager, state, tickUpper);
        unchecked {
            if (tick < tickLower) return (lo0 - hi0, lo1 - hi1);
            if (tick >= tickUpper) return (hi0 - lo0, hi1 - lo1);
            // A view read; the Lens calls it in its loop over at most 16 records of one account-market.
            // forge-lint: disable-next-line(calls-loop)
            bytes32[] memory g = manager.extsload(_offset(state, FEE_GROWTH_GLOBAL0_OFFSET), 2);
            return (uint256(g[0]) - lo0 - hi0, uint256(g[1]) - lo1 - hi1);
        }
    }

    /// @notice Fees `Position.update` would credit now: `mulDiv(inside - last, liquidity, 2^128)` per token, with the
    /// difference unchecked (`REQ-AMM-V4-010`).
    function feesOwed(
        PositionState memory p,
        uint256 inside0,
        uint256 inside1
    ) internal pure returns (uint256 fees0, uint256 fees1) {
        uint256 d0;
        uint256 d1;
        unchecked {
            d0 = inside0 - p.feeGrowthInside0LastX128;
            d1 = inside1 - p.feeGrowthInside1LastX128;
        }
        fees0 = Math.mulDiv(d0, p.liquidity, Q128);
        fees1 = Math.mulDiv(d1, p.liquidity, Q128);
    }

    /// @dev Fee growth outside a tick (`TickInfo` words 1 and 2).
    function _feeGrowthOutside(
        IUniswapV4PoolManager manager,
        bytes32 state,
        int24 tick
    ) private view returns (uint256 g0, uint256 g1) {
        bytes32 slot = keccak256(abi.encode(int256(tick), _offset(state, TICKS_OFFSET)));
        // A view read; the Lens calls it in its loop over at most 16 records of one account-market.
        // forge-lint: disable-next-line(calls-loop)
        bytes32[] memory w = manager.extsload(_offset(slot, 1), 2);
        (g0, g1) = (uint256(w[0]), uint256(w[1]));
    }

    function _offset(
        bytes32 slot,
        uint256 n
    ) private pure returns (bytes32) {
        return bytes32(uint256(slot) + n);
    }
}
