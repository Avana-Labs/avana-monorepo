// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LensFeesV3Fixture} from "../utils/fixtures/LensFeesFixture.sol";

/// @title LensFeesEdgesUnitTest
/// @notice Uncollected fees at the edges of the position manager's arithmetic: growth so large that the owed amount
/// wraps `uint128` as in the 0.7 sources, a position whose ticks sit below a tick that was never initialized, a
/// position of the pool's other market range, and an unknown token ID (the manager's error propagates).
/// forge-config: default.isolate = false
contract LensFeesEdgesUnitTest is LensFeesV3Fixture {
    uint256 internal constant Q128 = 1 << 128;

    function _collect(
        bytes32 key
    ) internal returns (uint256 a0) {
        uint256 b0 = _token0().balanceOf(alice);
        _asColl(abi.encodeCall(vault.collectFees, (key, alice)));
        a0 = _token0().balanceOf(alice) - b0;
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_owedWrapsLikeTheManager() public {
        bytes32 key = _pledge1(alice, 3);
        // 3 x (2^128 / 2) = 1.5 x 2^128: the 0.7 cast keeps the low 128 bits, 2^127.
        pool500.setFeeGrowthGlobal(Q128 * (Q128 / 2), 0);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertEq(f.amounts[0], Q128 / 2, "(3 x 2^127) mod 2^128 = 2^127");
        assertEq(_collect(key), f.amounts[0], "the manager pays the wrapped amount");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_otherRangeOfTheSamePoolIsSupported() public {
        // The Lens follows the position's own ticks; the market fixes only the pool, tokens and fee tier.
        bytes32 key = _mint(alice, pool500, -100, 100, 1e12);
        pool500.setFeeGrowthGlobal(4 * Q128, 0);
        pool500.setFeeGrowthOutside(-100, Q128, 0);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertTrue(f.supported, "same pool");
        assertFalse(f.inCustody, "the LPVault would refuse its shape at pledge");
        assertEq(f.amounts[0], 3e12, "4 - 1 inside [-100, 100]");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_uninitializedTicksCountAsZero() public {
        bytes32 key = _pledge1(alice, 1e12);
        pool500.setPrice(-70);
        pool500.setFeeGrowthGlobal(6 * Q128, 0);
        // Both ticks read 0: below the range the growth inside is 0 - 0 = 0.
        assertEq(lens.getPositionFees(M1, key).amounts[0], 0, "no fee earned below the range");
        assertEq(_collect(key), 0, "nothing collected");
    }

    // TEST-247 verifies: REQ-LENS-050, REQ-LENS-007
    function test_TEST_247_unknownTokenIdRevertsWithTheManagersError() public {
        vm.expectRevert(bytes("Invalid token ID"));
        lens.getPositionFees(M1, bytes32(uint256(999)));
    }
}
