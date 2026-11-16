// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensFees} from "../../src/lens/lens/ILensFees.sol";
import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LensFeesV3Fixture} from "../utils/fixtures/LensFeesFixture.sol";

/// @title LensFeesLifecycleFuzzTest
/// @notice For any fee growth before and after an unwind of any part of a Uniswap v3 position, and any donated
/// liquidity, the Lens's uncollected fees equal `collectFees`, and the entry point answers exactly as the module.
/// forge-config: default.isolate = false
contract LensFeesLifecycleFuzzTest is LensFeesV3Fixture {
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant MAX_GROWTH = (1 << 30) - 1;

    function _collect(
        bytes32 key
    ) internal returns (uint256 a0, uint256 a1) {
        uint256 b0 = _token0().balanceOf(alice);
        uint256 b1 = _token1().balanceOf(alice);
        _asColl(abi.encodeCall(vault.collectFees, (key, alice)));
        (a0, a1) = (_token0().balanceOf(alice) - b0, _token1().balanceOf(alice) - b1);
    }

    // TEST-247 verifies: REQ-LENS-050
    function testFuzz_TEST_247_feesSurviveUnwindsAndDonations(
        uint128 liquidity,
        uint128 removed,
        uint128 donated,
        uint64[4] memory growth
    ) public {
        liquidity = uint128(bound(liquidity, 2, type(uint96).max));
        // Each growth word stays below 2^30, so liquidity times either growth step over 2^128 stays below 2^126 and the
        // fees owed plus the unwound principal fit the manager's uint128 `tokensOwed` (above it the manager truncates).
        for (uint256 i; i < 4; ++i) {
            growth[i] = uint64(bound(growth[i], 0, MAX_GROWTH));
        }
        bytes32 key = _pledge1(alice, liquidity);
        pool500.setFeeGrowthGlobal(uint256(growth[0]) * Q128 / 7, uint256(growth[1]) * Q128 / 3);
        PositionFeesView memory before = lens.getPositionFees(M1, key);
        removed = uint128(bound(removed, 1, liquidity - 1));
        _asColl(abi.encodeCall(vault.unwind, (key, removed, _zeros(), lpVaultSwap)));
        assertEq(lens.getPositionFees(M1, key).amounts[0], before.amounts[0], "an unwind leaves the fees owed");
        nfpm.increaseLiquidity(uint256(key), uint128(bound(donated, 0, type(uint64).max)));
        pool500.setFeeGrowthGlobal(
            uint256(growth[0]) * Q128 / 7 + uint256(growth[2]) * Q128 / 5,
            uint256(growth[1]) * Q128 / 3 + uint256(growth[3]) * Q128
        );
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        (bool ok, bytes memory direct) =
            lens.MODULES()[6].staticcall(abi.encodeCall(ILensFees.getPositionFees, (M1, key)));
        assertTrue(ok, "the module answers");
        assertEq(keccak256(direct), keccak256(abi.encode(f)), "the entry point returns the module's bytes");
        (uint256 a0, uint256 a1) = _collect(key);
        assertEq(f.amounts[0], a0, "token0 = collectFees");
        assertEq(f.amounts[1], a1, "token1 = collectFees");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_ciCounterexample20261115() public {
        testFuzz_TEST_247_feesSurviveUnwindsAndDonations(
            245_003_304_183_075_693_693_629,
            3_402_992_956_809_132_418_596_140_100_660_247_210,
            2_026_024_998,
            [uint64(10_528), 2_500_000_000_000_000_000, 8431, 7623]
        );
    }
}
