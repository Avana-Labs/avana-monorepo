// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LensFeesSlipstreamFixture} from "../utils/fixtures/LensFeesFixture.sol";

/// @title LensFeesSlipstreamFuzzTest
/// @notice For any fee-growth state of a Slipstream pool, any earlier collect and any owed tokens, the Lens's
/// uncollected fees of a Slipstream position equal what the real Slipstream LPVault's `collectFees` pays.
/// forge-config: default.isolate = false
contract LensFeesSlipstreamFuzzTest is LensFeesSlipstreamFixture {
    function _apply(
        uint256[6] memory g,
        int256 tick
    ) internal {
        pool1.setFeeGrowthGlobal(g[0], g[1]);
        pool1.setFeeGrowthOutside(M1_LOWER, g[2], g[3]);
        pool1.setFeeGrowthOutside(M1_UPPER, g[4], g[5]);
        pool1.setPrice(int24(bound(tick, -300, 300)));
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
    function testFuzz_TEST_247_slipstreamFeesEqualCollectFees(
        uint128 liquidity,
        uint256[6] memory first,
        int256 tick1,
        uint256[6] memory second,
        int256 tick2,
        uint64 owed0,
        uint64 owed1
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint112).max));
        bytes32 key = _pledge1(alice, liquidity);
        _apply(first, tick1);
        _collect(key);
        _apply(second, tick2);
        _npm1().accrue(_id(key), owed0, owed1);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertTrue(f.supported, "supported");
        (uint256 a0, uint256 a1) = _collect(key);
        assertEq(f.amounts[0], a0, "token0 = collectFees");
        assertEq(f.amounts[1], a1, "token1 = collectFees");
    }
}
