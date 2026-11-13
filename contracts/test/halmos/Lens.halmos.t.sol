// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensBase} from "../../src/lens/lens/LensBase.sol";
import {LensFees} from "../../src/lens/lens/LensFees.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Exposes the Lens's pure fee arithmetic to the symbolic checks.
contract LensMathHalmosHarness is LensFees {
    constructor() LensBase(_noCore()) {}

    function _noCore() private pure returns (address[9] memory core) {}

    function feeGrowthInside(
        int24 tick,
        int24 lower,
        int24 upper,
        uint256 global,
        uint256 outsideLower,
        uint256 outsideUpper
    ) external pure returns (uint256) {
        return _feeGrowthInside(tick, lower, upper, global, outsideLower, outsideUpper);
    }

    function owedWithoutLiquidity(
        uint128 owed,
        uint256 last,
        uint256 global
    ) external pure returns (uint256) {
        ClFees memory f;
        (f.owed[0], f.last[0], f.global[0]) = (owed, last, global);
        return _owedAfterUpdate(f, 0);
    }
}

/// @title LensHalmosTest
/// @notice Symbolic checks of the Lens arithmetic that the views stake an exact claim on: the fee growth inside a
/// range equals v3-core's position identities for a tick below, inside and above it in wrapping arithmetic
/// (REQ-LENS-050), and a position without liquidity is owed exactly its recorded tokens. The removal bound of REQ-LENS-054
/// is proved in integer arithmetic by MATH-AR-76 instead: its products and divisions are nonlinear in bit-vectors and
/// time out here even at a fixed value per unit.
contract LensHalmosTest is Test {
    LensMathHalmosHarness internal h;

    function setUp() public {
        h = new LensMathHalmosHarness();
    }

    // TEST-247 verifies: REQ-LENS-050, MATH-AR-77
    /// @notice For `lower < upper` and any stored accumulators: inside the range the growth is
    /// `global − outsideLower − outsideUpper`, below it `outsideLower − outsideUpper`, at or above the upper tick
    /// `outsideUpper − outsideLower`, every difference mod 2^256.
    function check_feeGrowthInsideIdentities(
        int24 tick,
        int24 lower,
        int24 upper,
        uint256 g,
        uint256 ol,
        uint256 ou
    ) public view {
        vm.assume(lower < upper);
        uint256 inside = h.feeGrowthInside(tick, lower, upper, g, ol, ou);
        unchecked {
            if (tick < lower) assertEq(inside, ol - ou);
            else if (tick < upper) assertEq(inside, g - ol - ou);
            else assertEq(inside, ou - ol);
        }
    }

    // TEST-247 verifies: REQ-LENS-050
    /// @notice With `L = 0` the position is owed its recorded tokens, whatever the growth since its snapshot.
    function check_noLiquidityOwesTheRecordedTokens(
        uint128 owed,
        uint256 last,
        uint256 global
    ) public view {
        assertEq(h.owedWithoutLiquidity(owed, last, global), owed);
    }
}
