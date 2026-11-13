// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CloseAccountView} from "../../src/lens/lens/types/CloseAccountView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LensCloseAccountFuzzTest
/// @notice For any records, debts and time, the close-account preview lists exactly the debts owed with spend caps that
/// cover them at the deadline, and records whose units the withdrawals accept; running the closing calls it lists
/// leaves the account empty.
/// forge-config: default.isolate = false
contract LensCloseAccountFuzzTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    // TEST-247 verifies: REQ-LENS-056, REQ-LENS-036
    function testFuzz_TEST_247_closingCallsEmptyTheAccount(
        uint128 u1,
        uint128 u2,
        uint256 gho,
        uint256 usdcDebt,
        uint256 dt,
        uint256 wait
    ) public {
        u1 = uint128(bound(u1, 1000e6, 200_000e6));
        u2 = uint128(bound(u2, 0, 100_000e6));
        _open(alice, aliceProxy, 1, u1);
        if (u2 > 0) _pledge(alice, aliceProxy, _key(2), u2);
        uint256 value = (uint256(u1) + u2) * 2;
        gho = bound(gho, 0, value * 0.3e12);
        usdcDebt = bound(usdcDebt, 0, value * 30 / 100);
        if (gho > 0) _borrow(aliceProxy, gho);
        if (usdcDebt > 0) _borrowUsdc(aliceProxy, usdcDebt);
        vm.warp(block.timestamp + bound(dt, 0, 365 days));
        uint256 deadline = block.timestamp + bound(wait, 0, 1 days);
        CloseAccountView memory c = lens.previewCloseAccount(alice, MARKET_ID, deadline);
        assertEq(c.debts.length, (gho > 0 ? 1 : 0) + (usdcDebt > 0 ? 1 : 0), "one entry per debt owed");
        assertEq(c.records.length, u2 > 0 ? 2 : 1, "one entry per record");
        for (uint256 i = 0; i < c.debts.length; ++i) {
            assertEq(
                c.debts[i].maxRepaySpend,
                lens.quoteRepayAll(alice, MARKET_ID, c.debts[i].reserveId, deadline),
                "the repay-all quote"
            );
        }
        vm.warp(deadline);
        for (uint256 i = 0; i < c.debts.length; ++i) {
            uint256 owed = _debtOf(aliceProxy, c.debts[i].reserveId);
            assertGe(c.debts[i].maxRepaySpend, owed, "the spend cap covers the debt at the deadline");
            CollPoolToken(c.debts[i].asset).mint(aliceProxy, owed);
            vm.startPrank(aliceProxy);
            CollPoolToken(c.debts[i].asset).approve(aave.cdpSpoke, owed);
            IAaveV4Spoke(aave.cdpSpoke).repay(c.debts[i].reserveId, owed, aliceProxy);
            vm.stopPrank();
        }
        for (uint256 i = 0; i < c.records.length; ++i) {
            _withdraw(aliceProxy, c.records[i].positionKey, c.records[i].units);
        }
        assertEq(_shares(aliceProxy), 0, "no collateral left");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).totalDebtValueRay, 0, "no debt left");
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 0, "no record left");
    }
}
