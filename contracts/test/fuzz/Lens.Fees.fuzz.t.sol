// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LensFeesV3Fixture} from "../utils/fixtures/LensFeesFixture.sol";

/// @title LensFeesFuzzTest
/// @notice For any fee-growth state of the pool (globals, both ticks' outside values, the current tick below, inside or
/// above the range, wrapping values included), any earlier collect and any owed tokens, the Lens's uncollected fees of
/// a Uniswap v3 position equal what the real LPVault's `collectFees` pays in the same block.
/// forge-config: default.isolate = false
contract LensFeesFuzzTest is LensFeesV3Fixture {
    struct Growth {
        uint256 g0;
        uint256 g1;
        uint256 lo0;
        uint256 lo1;
        uint256 hi0;
        uint256 hi1;
        int24 tick;
    }

    function _apply(
        Growth memory s
    ) internal {
        pool500.setFeeGrowthGlobal(s.g0, s.g1);
        pool500.setFeeGrowthOutside(M1_LOWER, s.lo0, s.lo1);
        pool500.setFeeGrowthOutside(M1_UPPER, s.hi0, s.hi1);
        pool500.setPrice(int24(bound(s.tick, -300, 300)));
    }

    function _collect(
        bytes32 key
    ) internal returns (uint256 a0, uint256 a1) {
        uint256 b0 = _token0().balanceOf(alice);
        uint256 b1 = _token1().balanceOf(alice);
        _asColl(abi.encodeCall(vault.collectFees, (key, alice)));
        (a0, a1) = (_token0().balanceOf(alice) - b0, _token1().balanceOf(alice) - b1);
    }

    // TEST-247 verifies: REQ-LENS-050
    function testFuzz_TEST_247_feesEqualCollectFees(
        uint128 liquidity,
        Growth memory first,
        Growth memory second,
        uint64 owed0,
        uint64 owed1
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint112).max));
        bytes32 key = _pledge1(alice, liquidity);
        _apply(first);
        _collect(key);
        _apply(second);
        nfpm.accrue(uint256(key), owed0, owed1);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertTrue(f.supported, "supported");
        assertEq(f.tokensOwed[0], owed0, "owed 0");
        assertEq(f.tokensOwed[1], owed1, "owed 1");
        (uint256 a0, uint256 a1) = _collect(key);
        assertEq(f.amounts[0], a0, "token0 = collectFees");
        assertEq(f.amounts[1], a1, "token1 = collectFees");
        f = lens.getPositionFees(M1, key);
        assertEq(f.amounts[0] + f.amounts[1], 0, "nothing left after the collect");
    }

    // TEST-247 verifies: REQ-LENS-050
    function testFuzz_TEST_247_growthIsLinearInLiquidityInsideTheRange(
        uint128 liquidity,
        uint128 perUnit0,
        uint128 perUnit1
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint64).max));
        bytes32 key = _pledge1(alice, liquidity);
        pool500.setPrice(0);
        pool500.setFeeGrowthGlobal(uint256(perUnit0) << 128, uint256(perUnit1) << 128);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertEq(f.amounts[0], uint256(uint128(uint256(liquidity) * perUnit0)), "L x growth, mod 2^128 as the manager");
        assertEq(f.amounts[1], uint256(uint128(uint256(liquidity) * perUnit1)), "token1");
        (uint256 a0, uint256 a1) = _collect(key);
        assertEq(a0, f.amounts[0], "collect 0");
        assertEq(a1, f.amounts[1], "collect 1");
    }
}
