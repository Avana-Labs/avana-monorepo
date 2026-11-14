// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CloseAccountView} from "../../src/lens/lens/types/CloseAccountView.sol";
import {DeleverageSizing} from "../../src/lens/lens/types/DeleverageSizing.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensSizingGatesUnitTest
/// @notice `previewDeleverageTo` is unreachable exactly when the repay with collateral it sizes is closed: a Hub Paused
/// for `MintPathSuspect`, a Hub whose vault-token shares differ from its assets, a market whose collateral price is not
/// liquidation-grade, a debt reserve the account does not owe, or a record that is not the account's; and the
/// close-account preview's quotes and units follow the deadline and the record list.
/// forge-config: default.isolate = false
contract LensSizingGatesUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
        _borrow(aliceProxy, 12_000e18);
    }

    function _reachable() internal view returns (bool) {
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 1.6e18);
        if (!s.reachable) assertEq(s.units + s.debtRepaid + s.debtAssetToWallet + s.healthFactorAfter, 0, "zeros");
        return s.reachable;
    }

    // TEST-247 verifies: REQ-LENS-055, REQ-LENS-038
    function test_TEST_247_openByDefault() public view {
        assertTrue(_reachable(), "every gate open");
    }

    // TEST-247 verifies: REQ-LENS-055, REQ-LENS-038, REQ-ADAPTER-080, REQ-ADAPTER-082
    function test_TEST_247_onlyMintPathSuspectPauseClosesIt() public {
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        assertFalse(_reachable(), "Paused(MintPathSuspect)");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        assertTrue(_reachable(), "Paused(General) keeps it open");
        reg.setPause(aave.hub, PauseState.Frozen, PauseReason.None);
        assertTrue(_reachable(), "Frozen keeps it open");
        reg.setPause(aave.hub, PauseState.None, PauseReason.None);
        reg.setFrozen(alice, true);
        assertTrue(_reachable(), "a frozen wallet keeps it open");
    }

    // TEST-247 verifies: REQ-LENS-055, REQ-LENS-038
    function test_TEST_247_sharesDifferingFromAssetsCloseIt() public {
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedShares(uint256)", vtAssetId), abi.encode(uint256(1)));
        assertFalse(_reachable(), "shares != assets");
        vm.clearMockedCalls();
        assertTrue(_reachable(), "equal again");
    }

    // TEST-247 verifies: REQ-LENS-055, REQ-LENS-038, REQ-SWAP-008
    function test_TEST_247_collateralPriceNotLiquidationGradeClosesIt() public {
        lpo.setState(lpo.state(), 0, true);
        assertFalse(_reachable(), "liquidation paused on the market");
        lpo.setState(lpo.state(), 0, false);
        assertTrue(_reachable(), "resumed");
        vm.warp(block.timestamp + FEED_AGE + 1);
        assertFalse(_reachable(), "an input older than its liquidation age");
    }

    // TEST-247 verifies: REQ-LENS-055, REQ-LENS-038
    function test_TEST_247_noDebtOrForeignRecordClosesIt() public {
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), usdcReserveId, 1.6e18);
        assertFalse(s.reachable, "nothing owed on USDC");
        _open(bob, bobProxy, 7, 1000e6);
        s = lens.previewDeleverageTo(alice, MARKET_ID, _key(7), debtReserveId, 1.6e18);
        assertFalse(s.reachable, "Bob's record");
        s = lens.previewDeleverageTo(alice, MARKET_ID, _key(99), debtReserveId, 1.6e18);
        assertFalse(s.reachable, "no record");
    }

    // TEST-247 verifies: REQ-LENS-055
    function test_TEST_247_proxyIsReportedEvenWhenClosed() public {
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 1.6e18);
        assertEq(s.proxy, aliceProxy, "the account");
        assertEq(s.blockNumber, block.number, "block");
        assertEq(s.timestamp, block.timestamp, "time");
    }

    // ─── close account ───

    // TEST-247 verifies: REQ-LENS-056, REQ-LENS-036
    function test_TEST_247_closeQuotesGrowWithTheDeadline() public {
        vm.warp(block.timestamp + 30 days);
        CloseAccountView memory now_ = lens.previewCloseAccount(alice, MARKET_ID, block.timestamp - 1);
        CloseAccountView memory later = lens.previewCloseAccount(alice, MARKET_ID, block.timestamp + 7 days);
        uint256 total = _debtOf(aliceProxy, debtReserveId);
        assertEq(now_.debts[0].total, total, "the debt now");
        assertEq(now_.debts[0].maxRepaySpend, (total * 10_010 + 9999) / 10_000, "a past deadline: the debt plus 0.1 %");
        assertGt(later.debts[0].maxRepaySpend, now_.debts[0].maxRepaySpend, "a later deadline quotes more");
    }

    // TEST-247 verifies: REQ-LENS-056, REQ-LENS-011
    function test_TEST_247_closeRecordsMatchGetRecords() public {
        _pledge(alice, aliceProxy, _key(2), 4000e6);
        _pledge(alice, aliceProxy, _key(3), 15_000e6);
        CloseAccountView memory c = lens.previewCloseAccount(alice, MARKET_ID, block.timestamp);
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        assertEq(c.records.length, r.length, "same records");
        for (uint256 i = 0; i < r.length; ++i) {
            assertEq(c.records[i].positionKey, r[i].positionKey, "same order");
            assertEq(c.records[i].units, r[i].creditedAfterReconcile, "the withdrawal's units");
        }
    }
}
