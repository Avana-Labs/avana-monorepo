// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LensFeesV3Fixture} from "../utils/fixtures/LensFeesFixture.sol";

/// @title LensFeesLifecycleUnitTest
/// @notice Uncollected fees through a position's life on the real Uniswap v3 LPVault: an unwind or a partial release
/// collects only principal and leaves the fees owed, a third party's added liquidity settles the fees earned so far
/// first, two positions of one range keep their own snapshots, and a released position's fees stay readable.
/// forge-config: default.isolate = false
contract LensFeesLifecycleUnitTest is LensFeesV3Fixture {
    uint256 internal constant Q128 = 1 << 128;
    uint128 internal constant L = 1e12;

    function _collect(
        bytes32 key,
        address depositor
    ) internal returns (uint256 a0, uint256 a1) {
        uint256 b0 = _token0().balanceOf(depositor);
        uint256 b1 = _token1().balanceOf(depositor);
        _asColl(abi.encodeCall(vault.collectFees, (key, depositor)));
        (a0, a1) = (_token0().balanceOf(depositor) - b0, _token1().balanceOf(depositor) - b1);
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_unwindLeavesTheFeesOwed() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(4 * Q128, 2 * Q128);
        PositionFeesView memory before = lens.getPositionFees(M1, key);
        assertEq(before.amounts[0], 4 * uint256(L), "earned before the unwind");
        assertEq(before.tokensOwed[0], 0, "nothing credited yet");
        _asColl(abi.encodeCall(vault.unwind, (key, uint128(L / 4), _zeros(), lpVaultSwap)));
        PositionFeesView memory after_ = lens.getPositionFees(M1, key);
        assertEq(after_.liquidity, L - L / 4, "a quarter removed");
        assertEq(after_.tokensOwed[0], before.amounts[0], "the removal credited the fees to the position");
        assertEq(after_.amounts[0], before.amounts[0], "and left them owed: the unwind took principal only");
        assertEq(after_.amounts[1], before.amounts[1], "token1");
        (uint256 a0, uint256 a1) = _collect(key, alice);
        assertEq(a0, after_.amounts[0], "collectFees pays them to the depositor");
        assertEq(a1, after_.amounts[1], "token1");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_growthAfterAnUnwindCountsTheSmallerLiquidity() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(Q128, Q128);
        _asColl(abi.encodeCall(vault.unwind, (key, uint128(L / 2), _zeros(), lpVaultSwap)));
        pool500.setFeeGrowthGlobal(3 * Q128, 2 * Q128);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertEq(f.amounts[0], uint256(L) + 2 * uint256(L / 2), "1 x L before, then 2 x L/2");
        assertEq(f.amounts[1], uint256(L) + uint256(L / 2), "1 x L, then 1 x L/2");
        (uint256 a0, uint256 a1) = _collect(key, alice);
        assertEq(a0, f.amounts[0], "collect 0");
        assertEq(a1, f.amounts[1], "collect 1");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_thirdPartyLiquiditySettlesFeesFirst() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(2 * Q128, 2 * Q128);
        // Anyone may add liquidity; the manager credits the fees earned so far at the old liquidity first.
        nfpm.increaseLiquidity(uint256(key), 3 * L);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertEq(f.liquidity, 4 * L, "donated liquidity stays with the position");
        assertEq(f.tokensOwed[0], 2 * uint256(L), "credited at the old liquidity");
        assertEq(f.amounts[0], 2 * uint256(L), "nothing since");
        pool500.setFeeGrowthGlobal(3 * Q128, 2 * Q128);
        f = lens.getPositionFees(M1, key);
        assertEq(f.amounts[0], 2 * uint256(L) + 4 * uint256(L), "then 1 x 4L");
        (uint256 a0,) = _collect(key, alice);
        assertEq(a0, f.amounts[0], "collectFees");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_twoPositionsKeepTheirOwnSnapshots() public {
        bytes32 k1 = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(5 * Q128, 5 * Q128);
        // A position minted now starts at the current growth inside.
        bytes32 k2 = _pledge1(alice, L);
        assertEq(lens.getPositionFees(M1, k2).amounts[0], 0, "a new position owes nothing");
        pool500.setFeeGrowthGlobal(6 * Q128, 7 * Q128);
        assertEq(lens.getPositionFees(M1, k1).amounts[0], 6 * uint256(L), "the older position since mint");
        assertEq(lens.getPositionFees(M1, k2).amounts[0], uint256(L), "the newer one since its own mint");
        assertEq(lens.getPositionFees(M1, k2).amounts[1], 2 * uint256(L), "token1");
        (uint256 a0,) = _collect(k2, alice);
        assertEq(a0, uint256(L), "collectFees of the newer position");
        (a0,) = _collect(k1, alice);
        assertEq(a0, 6 * uint256(L), "collectFees of the older position");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_releasedPositionStaysReadable() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(Q128, Q128);
        PositionFeesView memory before = lens.getPositionFees(M1, key);
        _asColl(abi.encodeCall(vault.returnPosition, (key)));
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertFalse(f.inCustody, "returned to its owner");
        assertEq(f.depositor, address(0), "no depositor of record");
        assertTrue(f.supported, "still a position of the market's pool");
        assertEq(f.amounts[0], before.amounts[0], "its fees did not move");
        assertEq(nfpm.ownerOf(uint256(key)), alice, "Alice holds it");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_feesReportedInPoolOrder() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(Q128, 9 * Q128);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertEq(f.amounts.length, 2, "two pool tokens");
        assertEq(f.amounts[0], uint256(L), "token0 first");
        assertEq(f.amounts[1], 9 * uint256(L), "then token1");
        uint256 b0 = _token0().balanceOf(alice);
        uint256 b1 = _token1().balanceOf(alice);
        _collect(key, alice);
        assertEq(_token0().balanceOf(alice) - b0, f.amounts[0], "token0 paid in token0");
        assertEq(_token1().balanceOf(alice) - b1, f.amounts[1], "token1 paid in token1");
    }
}
