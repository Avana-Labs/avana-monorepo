// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {CapView} from "../../src/types/CapView.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensChargePriceFreshUnitTest
/// @notice `getCapHeadroom`'s charge price on the real Collateralization: a pledge is booked at the lower of the fresh
/// and accepted prices, never below the market's stress floor; a non-positive fresh price (a failed market) leaves
/// the accepted price.
/// forge-config: default.isolate = false
contract LensChargePriceFreshUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    /// @dev The LPOracle's price-state report with `freshAnswer` set to `fresh`, every other field unchanged.
    function _fresh(
        int256 fresh
    ) internal {
        PriceStateView memory ps = ILPOracle(address(lpo)).getPriceState();
        ps.freshAnswer = fresh;
        vm.mockCall(address(lpo), abi.encodeWithSelector(ILPOracle.getPriceState.selector), abi.encode(ps));
    }

    function _charge() internal view returns (uint256) {
        CapView memory c = lens.getCapHeadroom(vt, alice);
        return c.chargePricePerWholeToken;
    }

    /// @notice Accepted $2.00, stress floor $1.00. A fresh $1.80 is below the accepted price, so the charge is $1.80; a
    /// fresh $0.50 is below the floor, so the charge is the floor $1.00; a fresh $2.40 is above the accepted price,
    /// so the charge stays $2.00.
    // TEST-230 verifies: REQ-LENS-018; shared: TEST-230 books a pledge at min(fresh, A) and the Lens previews that same charge price, A after a rally
    // TEST-247 verifies: REQ-LENS-018
    function test_TEST_247_chargePriceIsTheLowerOfFreshAndAccepted() public {
        _fresh(1.8e8);
        assertEq(_charge(), 1.8e8, "fresh below accepted: the fresh price");
        _fresh(0.5e8);
        assertEq(_charge(), 1e8, "fresh below the stress floor: the floor");
        _fresh(2.4e8);
        assertEq(_charge(), 2e8, "fresh above accepted: the accepted price");
        _fresh(2e8);
        assertEq(_charge(), 2e8, "equal: the accepted price");
        vm.clearMockedCalls();
    }

    /// @notice A failed market reports a fresh price of 0 (or a negative one from a broken source): the charge stays at
    /// the accepted $2.00, and at the $2.50 stress floor once the floor is above it.
    // TEST-247 verifies: REQ-LENS-018
    function test_TEST_247_chargePriceIgnoresANonPositiveFreshPrice() public {
        _fresh(0);
        assertEq(_charge(), 2e8, "fresh 0: the accepted price");
        _fresh(-1);
        assertEq(_charge(), 2e8, "fresh negative: the accepted price");
        store.setCaps(MARKET_ID, 1_000_000e8, 100_000e8, 2.5e8);
        assertEq(_charge(), 2.5e8, "the stress floor above accepted");
        vm.clearMockedCalls();
    }
}
