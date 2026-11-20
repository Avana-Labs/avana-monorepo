// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV2TestBase} from "../utils/UniswapV2TestBase.sol";
import {MintableToken} from "../utils/mocks/UniswapV3Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fuzzed attacks on the Uniswap v2 LPVault's √k credit and its in-kind unwind.
contract UniswapV2IntegrationFuzzTest is UniswapV2TestBase {
    function setUp() public {
        _deploy(address(new MintableToken("A", 18)), address(new MintableToken("B", 18)), 1000e18, 1000e18);
    }

    /// @dev Any sequence of price-moving swaps leaves a pledged position's live liquidity at or above its credit.
    function testFuzz_swapsNeverLowerLiveLiquidityBelowCredit(
        uint256[6] memory amounts,
        uint8 directions
    ) public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        for (uint256 i = 0; i < 6; ++i) {
            _swap(attacker, (directions >> i) & 1 == 1, bound(amounts[i], 1e6, 1e24));
        }
        (,,, uint128 live) = vault.positionInfo(key);
        assertGe(live, credit);
    }

    /// @dev A synced donation raises a holder's liquidity by less than half the donation (valued at the 1:1 fair price,
    /// full-range liquidity L is worth at most 2L), so donating to inflate collateral always loses.
    function testFuzz_donationGainBelowDonation(
        uint256 donation0,
        uint256 donation1,
        uint256 share
    ) public {
        donation0 = bound(donation0, 0, 1e24);
        donation1 = bound(donation1, 0, 1e24);
        share = bound(share, 1e15, 1e24);
        vm.assume(donation0 + donation1 > 0);
        (bytes32 key, uint128 credit) = _position(attacker, share, share);
        MintableToken(t0).mint(address(pair), donation0);
        MintableToken(t1).mint(address(pair), donation1);
        pair.sync();
        (,,, uint128 live) = vault.positionInfo(key);
        assertLe(2 * (uint256(live) - credit), donation0 + donation1);
    }

    /// @dev An unwind of any credit burns at most the position's proportional LP, pays out exactly what arrived, and
    /// leaves every other position's LP untouched, at any
    /// price an attacker pushes the pair to.
    function testFuzz_unwindTakesAtMostTheProportionalShare(
        uint256 creditPart,
        uint256 swapIn
    ) public {
        (bytes32 key, uint128 credit) = _position(user, 100e18, 100e18);
        (bytes32 keyB,) = _position(other, 30e18, 30e18);
        _swap(attacker, true, bound(swapIn, 0, 1e22));
        creditPart = bound(creditPart, 1, credit);
        uint256 held = _held(key);
        uint256 heldB = _held(keyB);
        vm.prank(adapter);
        (uint128 l, uint128 removed,,) = vault.unwind(key, uint128(creditPart), 0, 0, recipient);
        assertLe(removed, credit);
        // At most the proportional LP; none when it would redeem zero of a token (the dust stays).
        assertLe(held - _held(key), Math.mulDiv(held, l, credit));
        assertEq(_held(keyB), heldB);
        assertEq(_bal(t0, address(vault)), 0);
        assertEq(_bal(t1, address(vault)), 0);
    }
}
