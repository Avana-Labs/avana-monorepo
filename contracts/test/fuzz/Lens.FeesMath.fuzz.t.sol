// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LensFeesV3Fixture} from "../utils/fixtures/LensFeesFixture.sol";

/// @title LensFeesMathFuzzTest
/// @notice Differential check of the Lens's fee-growth-inside against the line-by-line port of v3-core's
/// `Tick.getFeeGrowthInside` in the pool stand-in: for any globals, outside values, current tick (below, at, inside, at
/// and above the bounds) and snapshot, a position of liquidity 1 whose snapshot sits `k` units of 2^128 below the
/// reference's growth inside is owed exactly `k`, and the owed tokens add on top.
/// forge-config: default.isolate = false
contract LensFeesMathFuzzTest is LensFeesV3Fixture {
    uint256 internal constant Q128 = 1 << 128;

    function _positions(
        bytes32 key,
        uint128 liquidity,
        uint256 last0,
        uint256 last1,
        uint128 owed0,
        uint128 owed1
    ) internal {
        bytes memory head = abi.encode(uint96(0), address(0), pool500.token0(), pool500.token1(), uint24(500), M1_LOWER);
        bytes memory tail = abi.encode(M1_UPPER, liquidity, last0, last1, owed0, owed1);
        vm.mockCall(
            address(nfpm), abi.encodeWithSignature("positions(uint256)", uint256(key)), abi.encodePacked(head, tail)
        );
    }

    // TEST-247 verifies: REQ-LENS-050
    function testFuzz_TEST_247_insideGrowthMatchesTheV3CorePort(
        uint256[6] memory g,
        int256 tick,
        uint64 k0,
        uint64 k1,
        uint64 owed0,
        uint64 owed1
    ) public {
        bytes32 key = _pledge1(alice, 1);
        pool500.setFeeGrowthGlobal(g[0], g[1]);
        pool500.setFeeGrowthOutside(M1_LOWER, g[2], g[3]);
        pool500.setFeeGrowthOutside(M1_UPPER, g[4], g[5]);
        // Ticks around both bounds, so the at-bound comparisons (>= lower, < upper) are exercised.
        pool500.setPrice(int24(bound(tick, M1_LOWER - 3, M1_UPPER + 3)));
        (uint256 i0, uint256 i1) = pool500.feeGrowthInside(M1_LOWER, M1_UPPER);
        uint256 last0;
        uint256 last1;
        unchecked {
            last0 = i0 - uint256(k0) * Q128;
            last1 = i1 - uint256(k1) * Q128;
        }
        _positions(key, 1, last0, last1, owed0, owed1);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        vm.clearMockedCalls();
        assertEq(f.amounts[0], uint256(k0) + owed0, "k0 units of growth plus owed");
        assertEq(f.amounts[1], uint256(k1) + owed1, "k1 units of growth plus owed");
        assertEq(f.tokensOwed[0], owed0, "owed 0");
        assertEq(f.liquidity, 1, "liquidity");
    }

    // TEST-247 verifies: REQ-LENS-050
    function testFuzz_TEST_247_growthScalesWithLiquidityAndRoundsDown(
        uint128 liquidity,
        uint256 delta
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        bytes32 key = _pledge1(alice, 1);
        pool500.setPrice(0);
        delta = bound(delta, 0, type(uint256).max / 2);
        pool500.setFeeGrowthGlobal(delta, 0);
        _positions(key, liquidity, 0, 0, 0, 0);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        vm.clearMockedCalls();
        uint256 exact;
        unchecked {
            // The manager keeps the low 128 bits of floor(delta x L / 2^128).
            exact = uint256(uint128(_mulDiv(delta, liquidity)));
        }
        assertEq(f.amounts[0], exact, "uint128(floor(delta x L / 2^128))");
    }

    function _mulDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        // a < 2^255 and b < 2^128: split a so every product fits 256 bits.
        uint256 hi = a >> 128;
        uint256 lo = a & (Q128 - 1);
        return hi * b + (lo * b >> 128);
    }
}
