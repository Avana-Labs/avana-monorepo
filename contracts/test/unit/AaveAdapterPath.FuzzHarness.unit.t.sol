// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapterBorrowProperties} from "../invariant/echidna/AaveAdapterBorrowProperties.sol";
import {AaveAdapterWithdrawProperties} from "../invariant/echidna/AaveAdapterWithdrawProperties.sol";
import {Test} from "forge-std/Test.sol";

/// @title AaveAdapterPathFuzzHarnessUnitTest
/// @notice Replays the Medusa call sequence of slow-tier run 43708786168 that failed
/// `AaveAdapterWithdrawProperties.withdrawLp`: a debt-free withdrawal reverted `InvalidTarget` in `PositionProxy.execute`
/// because the stand-in world that created the proxy (their ProxyManager, never a valid target) was also the Spoke they
/// call. The proxies now come from `BorProxyFactory`. A borrow through a proxy must also land in the borrow harness.
contract AaveAdapterPathFuzzHarnessUnitTest is Test {
    // TEST-237 verifies: INV-081
    function test_TEST_237_debtFreeWithdrawalLandsInTheHarness() public {
        AaveAdapterWithdrawProperties h = new AaveAdapterWithdrawProperties();
        vm.roll(11);
        vm.warp(11);
        h.seedPosition(0, 0, 0);
        h.seedPosition(0, 0, 0);
        h.clearDebt(0);
        h.withdrawLp(0, 0, 0, 0);
        assertEq(h.done(1), 1, "withdrawal completed");
        assertEq(h.violations(), 0, "no violation");
        assertTrue(h.property_debtFreeWithdrawalAlwaysOpen(), "debtFreeWithdrawalAlwaysOpen");
    }

    // TEST-082 verifies: TEST-007
    function test_TEST_082_borrowLandsInTheHarness() public {
        AaveAdapterBorrowProperties h = new AaveAdapterBorrowProperties();
        h.pledgeLp(0, 3);
        assertEq(h.done(0), 1, "pledge completed");
        // A quarter of the room to the required HF, with no minHealthFactor.
        h.borrowDebt(0, 0, 0);
        assertEq(h.done(1), 1, "borrow completed");
        assertEq(h.violations(), 0, "no violation");
    }
}
