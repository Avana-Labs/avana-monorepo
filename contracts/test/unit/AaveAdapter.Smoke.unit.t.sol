// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// forge-config: default.isolate = false
contract AaveAdapterSmokeUnitTest is AaveAdapterFixture {
    // TEST-010 verifies: REQ-ADAPTER-065, REQ-ADAPTER-068
    function test_TEST_010_smokeLifecycle() public {
        (bytes32 key, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        assertEq(_sharesOf(proxy, vtReserveId), UNITS, "supplied");
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        assertEq(debt.balanceOf(alice), 1000e18, "borrowed");
        vm.warp(block.timestamp + 30 days);
        uint256 d = _debtOf(proxy, debtReserveId);
        _fund(alice, debtReserveId, d + 1e18);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, d + 1e18, true, _deadline());
        assertEq(_debtOf(proxy, debtReserveId), 0, "repaid");
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(key), UNITS, _deadline(), 0);
        assertEq(_sharesOf(proxy, vtReserveId), 0, "withdrawn");
        assertEq(lpVault.ownerOf(key), alice, "position back");
    }
}
