// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @title CollateralizationSeizureCreditUnitTest
/// @notice A seizure the account's credit cannot carry, on the real Collateralization and local Aave V4 (2.3
/// REQ-VAULT-117): the proxy supplies 5,000 units beyond its 5,000 credited units (vault tokens a non-conforming
/// Adapter minted to it), so reconciliation finds no shortfall and leaves the credit at 5,000; a liquidation that
/// seizes more than that credit reverts `InsufficientCredit` in `settleSeizure` and nothing is debited, while one that
/// seizes within the credit settles.
/// forge-config: default.isolate = false
contract CollateralizationSeizureCreditUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));

    function setUp() public {
        _deployCollateralization();
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        token.mint(aliceProxy, 5_000_000_000);
        vm.stopPrank();
        _supply(aliceProxy, 5_000_000_000);
        vm.prank(adapter);
        lock.release();
        _borrow(aliceProxy, 13_000e18);
        vtPrice.set(1.3e8);
    }

    function _seize(
        uint256 debtToCover
    ) internal returns (uint256 seized) {
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(aliceProxy, vt);
        seized = _seizeAndKeep(aliceProxy, debtToCover);
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);
    }

    // TEST-057 verifies: REQ-VAULT-117, REQ-VAULT-054, SPEC-BACK-006, Q-194
    function test_TEST_057_seizureAboveCreditAfterReconcileReverts() public {
        assertEq(coll.getAccountCredited(aliceProxy, vt), 5_000_000_000, "credit");
        assertEq(_shares(aliceProxy), 10_000_000_000, "supplied shares above the credit");

        uint256 snapshot = vm.snapshotState();
        uint256 seized = _seize(7000e18);
        assertGt(seized, 5_000_000_000, "the seizure exceeds the credit");
        vm.prank(lpVaultSwap);
        vm.expectRevert(ICollateralizationErrors.InsufficientCredit.selector);
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        vm.prank(lpVaultSwap);
        lock.release();
        assertEq(coll.getAccountCredited(aliceProxy, vt), 5_000_000_000, "nothing debited");
        assertEq(_record(KEY42).credited, 5_000_000_000, "record unchanged");
        vm.revertToState(snapshot);

        seized = _seize(3000e18);
        assertLe(seized, 5_000_000_000, "within the credit");
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        vm.prank(lpVaultSwap);
        lock.release();
        assertEq(coll.getAccountCredited(aliceProxy, vt), 5_000_000_000 - seized, "debited");
    }
}
