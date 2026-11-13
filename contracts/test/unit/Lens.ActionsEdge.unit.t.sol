// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ActionPreview} from "../../src/lens/lens/types/ActionPreview.sol";
import {RemovalSizing} from "../../src/lens/lens/types/RemovalSizing.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LensActionsEdgeUnitTest
/// @notice The after-action previews and the removal sizing at their edges: a 6-decimal debt with a risk premium, a
/// price move, collateral switched off, the application paused (previews still answer), many records and the
/// rescue-free account with no debt.
/// forge-config: default.isolate = false
contract LensActionsEdgeUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 20_000e6);
    }

    function _assertAfter(
        ActionPreview memory v
    ) internal view {
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy);
        assertEq(v.healthFactorAfter, a.healthFactor, "health factor");
        assertEq(v.debtValueAfterRay, a.totalDebtValueRay, "debt value");
        assertEq(v.collateralValueAfter, a.totalCollateralValue, "collateral value");
    }

    function _repayUsdc(
        uint256 amount
    ) internal {
        CollPoolToken(address(usdc)).mint(aliceProxy, amount);
        vm.startPrank(aliceProxy);
        CollPoolToken(address(usdc)).approve(aave.cdpSpoke, amount);
        IAaveV4Spoke(aave.cdpSpoke).repay(usdcReserveId, amount, aliceProxy);
        vm.stopPrank();
    }

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_usdcRepayWithPremiumAtSixDecimals() public {
        _spokeConfig(
            abi.encodeWithSignature("updateCollateralRisk(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, 3000)
        );
        _borrowUsdc(aliceProxy, 12_345_678_901);
        vm.warp(block.timestamp + 300 days);
        _setUsdcPrice(1.0002e8);
        uint256 total = _debtOf(aliceProxy, usdcReserveId);
        for (uint256 i = 0; i < 3; ++i) {
            uint256 amount = i == 0 ? 3 : (i == 1 ? 1_000_000_001 : total);
            ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, usdcReserveId, amount);
            uint256 owed = _debtOf(aliceProxy, usdcReserveId);
            uint256 paid = amount < owed ? amount : owed;
            assertEq(v.amount, paid, "repaid part");
            _repayUsdc(paid);
            _assertAfter(v);
        }
        assertEq(_debtOf(aliceProxy, usdcReserveId), 0, "cleared");
    }

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-007
    function test_TEST_247_borrowAfterAtAMovedPrice() public {
        _borrow(aliceProxy, 10_000e18);
        _setVtPrice(1.37e8);
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, 2000e18);
        assertEq(v.collateralValueAfter, 20_000 * 1.37e26, "valued at the served $1.37");
        assertEq(v.healthFactorAfter, uint256(20_000 * 137 * 8) * 1e15 / 12_000, "0.8 x 27,400 / 12,000");
        assertEq(v.liquidationPriceAfter, 75_000_000, "12,000 / (0.8 x 20,000) = $0.75");
        _borrow(aliceProxy, 2000e18);
        _assertAfter(v);
    }

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-053
    function test_TEST_247_collateralSwitchedOffCountsNothingUntilAPledge() public {
        vm.prank(aliceProxy);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(vtReserveId, false, aliceProxy);
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, 1e18);
        assertEq(v.collateralValueAfter, 0, "not counted while off");
        assertEq(v.healthFactorAfter, 0, "debt against nothing");
        assertEq(v.liquidationPriceBefore, 0, "no debt before");
        vault.mintPosition(_key(2), alice, MARKET_ID, 1000e6);
        v = lens.previewPledgeAfter(alice, MARKET_ID, _key(2));
        assertEq(v.collateralValueAfter, 21_000 * 2e26, "the pledge turns it on: every unit counts");
        _pledge(alice, aliceProxy, _key(2), 1000e6);
        _assertAfter(v);
        v = lens.previewWithdrawAfter(alice, MARKET_ID, _key(2));
        assertEq(v.collateralValueAfter, 20_000 * 2e26, "the record's units leave");
    }

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-004
    function test_TEST_247_previewsAnswerInEveryPauseState() public {
        _borrow(aliceProxy, 1000e18);
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        reg.setFrozen(alice, true);
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, 500e18);
        assertEq(v.healthFactorAfter, uint256(32_000e18) / 500, "the arithmetic does not depend on the gates");
        v = lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, 500e18);
        assertEq(v.healthFactorAfter, uint256(32_000e18) / 1500, "advisory: the Adapter re-checks every gate");
    }

    // TEST-247 verifies: REQ-LENS-054
    function test_TEST_247_manyRecordsFitInOrderOfSize() public {
        _pledge(alice, aliceProxy, _key(2), 7000e6);
        _pledge(alice, aliceProxy, _key(3), 3000e6);
        _pledge(alice, aliceProxy, _key(4), 500e6);
        _borrow(aliceProxy, 20_000e18);
        // $61,000 x 0.8 = $48,800; target 2.0 needs $40,000: (48,800 - 40,000) / 1.6 = 5,500 tokens.
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 2e18);
        assertEq(s.maxUnits, 5500e6, "5,500 vault tokens");
        assertEq(s.records.length, 4, "four records");
        assertEq(s.records[0].units, 20_000e6, "largest first");
        assertEq(s.records[1].units, 7000e6, "then 7,000");
        assertFalse(s.records[0].fits || s.records[1].fits, "too large");
        assertTrue(s.records[2].fits && s.records[3].fits, "3,000 and 500 fit");
        assertEq(s.bestIndex, 2, "the larger of the two that fit");
        _withdraw(aliceProxy, s.records[2].positionKey, s.records[2].units);
        assertGe(_hf(aliceProxy), 2e18, "the chosen record keeps the target");
    }

    // TEST-247 verifies: REQ-LENS-054, REQ-LENS-053
    function test_TEST_247_removalAndWithdrawAfterAgreeOnTheBestRecord() public {
        _pledge(alice, aliceProxy, _key(2), 4000e6);
        _borrow(aliceProxy, 15_000e18);
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 1.5e18);
        for (uint256 i = 0; i < s.records.length; ++i) {
            ActionPreview memory v = lens.previewWithdrawAfter(alice, MARKET_ID, s.records[i].positionKey);
            assertEq(s.records[i].fits, v.healthFactorAfter >= s.target, "fits iff the withdrawal keeps the target");
        }
    }
}
