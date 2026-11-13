// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LensFeesSlipstreamFixture, LensRecordsStub} from "../utils/fixtures/LensFeesFixture.sol";
import {AaveAdapterLensMock} from "../utils/mocks/AaveAdapterLensMock.sol";
import {MockCLPool} from "../utils/mocks/SlipstreamMocks.sol";

/// @title LensFeesSlipstreamUnitTest
/// @notice `getPositionFees` on the real Aerodrome Slipstream LPVault: the 6-field `slot0`, the 10-field `ticks` and the
/// `int24 tickSpacing` position layout decode to the same fees `collectFees` pays; a key of another generation or a
/// position of another tick spacing is not the market's.
/// forge-config: default.isolate = false
contract LensFeesSlipstreamUnitTest is LensFeesSlipstreamFixture {
    uint256 internal constant Q128 = 1 << 128;
    uint128 internal constant L = 5e11;

    function _collect(
        bytes32 key,
        address depositor
    ) internal returns (uint256[2] memory got) {
        uint256 b0 = _token0().balanceOf(depositor);
        uint256 b1 = _token1().balanceOf(depositor);
        _asColl(abi.encodeCall(vault.collectFees, (key, depositor)));
        got = [_token0().balanceOf(depositor) - b0, _token1().balanceOf(depositor) - b1];
    }

    function _assertMatches(
        bytes32 key
    ) internal returns (PositionFeesView memory f) {
        f = lens.getPositionFees(M1, key);
        assertTrue(f.supported, "supported");
        uint256[2] memory got = _collect(key, alice);
        assertEq(f.amounts[0], got[0], "token0 = collectFees");
        assertEq(f.amounts[1], got[1], "token1 = collectFees");
    }

    // TEST-247 verifies: REQ-LENS-050, REQ-LENS-005
    function test_TEST_247_slipstreamInRangeFeesEqualCollect() public {
        bytes32 key = _pledge1(alice, L);
        pool1.setPrice(10);
        pool1.setFeeGrowthGlobal(8 * Q128, 6 * Q128);
        pool1.setFeeGrowthOutside(M1_LOWER, 3 * Q128, Q128);
        pool1.setFeeGrowthOutside(M1_UPPER, Q128, 2 * Q128);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.amounts[0], 4 * uint256(L), "8 - 3 - 1");
        assertEq(f.amounts[1], 3 * uint256(L), "6 - 1 - 2");
        assertEq(f.liquidity, L, "liquidity");
        assertEq(f.depositor, alice, "depositor");
        assertEq(f.blockNumber, block.number, "block");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_slipstreamBelowAndAboveRange() public {
        bytes32 key = _pledge1(alice, L);
        pool1.setFeeGrowthGlobal(10 * Q128, 10 * Q128);
        pool1.setFeeGrowthOutside(M1_LOWER, 6 * Q128, 2 * Q128);
        pool1.setFeeGrowthOutside(M1_UPPER, 4 * Q128, 9 * Q128);
        pool1.setPrice(-51);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertEq(f.amounts[0], 2 * uint256(L), "below: 6 - 4");
        pool1.setPrice(51);
        pool1.setFeeGrowthOutside(M1_LOWER, 2 * Q128, 2 * Q128);
        pool1.setFeeGrowthOutside(M1_UPPER, 7 * Q128, 9 * Q128);
        f = _assertMatches(key);
        assertEq(f.amounts[0], 5 * uint256(L), "above: outside(upper) - outside(lower) = 7 - 2");
        assertEq(f.amounts[1], 7 * uint256(L), "9 - 2");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_slipstreamOwedAndSnapshotAfterCollect() public {
        bytes32 key = _pledge1(alice, L);
        pool1.setFeeGrowthGlobal(2 * Q128, 2 * Q128);
        _collect(key, alice);
        _npm1().accrue(_id(key), 10, 20);
        pool1.setFeeGrowthGlobal(5 * Q128, 3 * Q128);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.tokensOwed[0], 10, "owed");
        assertEq(f.amounts[0], 3 * uint256(L) + 10, "growth since the collect plus owed");
        assertEq(f.amounts[1], uint256(L) + 20, "token1");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_slipstreamOtherGenerationIsUnsupported() public {
        // Market 1 binds generation 2; the same token ID on generation 3 belongs to another position manager.
        bytes32 key = _pledge1(alice, L);
        bytes32 other = _key(G2, _id(key));
        PositionFeesView memory f = lens.getPositionFees(M1, other);
        assertFalse(f.supported, "another generation's manager");
        assertEq(f.amounts[0] + f.amounts[1], 0, "no amount");
        assertTrue(lens.getPositionFees(M1, key).supported, "the market's generation");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_slipstreamOtherTickSpacingIsUnsupported() public {
        MockCLPool p = MockCLPool(factories[G1].createPool(address(usdc), address(usdt), 50));
        bytes32 key = _mint(alice, G1, p, -100, 100, L);
        assertFalse(lens.getPositionFees(M1, key).supported, "spacing 50 is not market 1's pool");
    }

    // TEST-247 verifies: REQ-LENS-051
    function test_TEST_247_slipstreamAccountFees() public {
        bytes32 k1 = _pledge1(alice, L);
        address proxy = makeAddr("aliceProxy");
        AaveAdapterLensMock(adapter).bind(alice, proxy, address(0x5509E), M1, address(0x7777), 1);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = k1;
        LensRecordsStub(coll).setRecords(proxy, keys);
        pool1.setFeeGrowthGlobal(Q128, Q128);
        PositionFeesView[] memory fs = lens.getAccountFees(alice, M1);
        assertEq(fs.length, 1, "one record");
        assertEq(fs[0].amounts[0], uint256(L), "growth 1");
        assertEq(_collect(k1, alice)[0], fs[0].amounts[0], "collectFees");
    }
}
