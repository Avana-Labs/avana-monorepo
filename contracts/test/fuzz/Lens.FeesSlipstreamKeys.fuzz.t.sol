// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {LensFeesSlipstreamFixture} from "../utils/fixtures/LensFeesFixture.sol";

/// @title LensFeesSlipstreamKeysFuzzTest
/// @notice Slipstream position keys carry their generation: for any token ID only the market's generation is read as
/// the market's position (its fees linear in liquidity and growth, equal to `collectFees`), another generation is
/// unsupported without reading any manager, and a generation the LPVault does not know reverts with its error.
/// forge-config: default.isolate = false
contract LensFeesSlipstreamKeysFuzzTest is LensFeesSlipstreamFixture {
    uint256 internal constant Q128 = 1 << 128;

    // TEST-247 verifies: REQ-LENS-050
    function testFuzz_TEST_247_onlyTheMarketsGenerationIsRead(
        uint128 liquidity,
        uint64 perUnit,
        uint8 gen
    ) public {
        liquidity = uint128(bound(liquidity, 1, type(uint64).max));
        bytes32 key = _pledge1(alice, liquidity);
        pool1.setFeeGrowthGlobal(uint256(perUnit) * Q128, 0);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertTrue(f.supported, "the market's generation");
        assertEq(f.amounts[0], uint256(liquidity) * perUnit, "L x growth");
        uint256 b0 = _token0().balanceOf(alice);
        _asColl(abi.encodeCall(vault.collectFees, (key, alice)));
        assertEq(_token0().balanceOf(alice) - b0, f.amounts[0], "collectFees");
        gen = uint8(bound(gen, 0, 3));
        vm.assume(gen != G1);
        PositionFeesView memory other = lens.getPositionFees(M1, _key(gen, _id(key)));
        assertFalse(other.supported, "another generation's manager");
        assertEq(other.amounts[0] + other.amounts[1], 0, "no amount");
    }

    // TEST-247 verifies: REQ-LENS-050, REQ-LENS-007
    function testFuzz_TEST_247_unknownGenerationReverts(
        uint8 gen,
        uint248 id
    ) public {
        gen = uint8(bound(gen, 4, 255));
        vm.expectRevert(ILPVaultErrors.InvalidPool.selector);
        lens.getPositionFees(M1, _key(gen, id));
    }
}
