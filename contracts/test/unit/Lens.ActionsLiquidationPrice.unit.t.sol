// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ActionPreview} from "../../src/lens/lens/types/ActionPreview.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensActionsLiquidationPriceUnitTest
/// @notice The liquidation price an after-action preview shows is the exact one Aave applies once the action has run:
/// with the vault token at that price the account's health factor is at least 1.00, and one 8-decimal unit lower it is
/// below, after a borrow, a repay, a pledge and a withdrawal.
/// forge-config: default.isolate = false
contract LensActionsLiquidationPriceUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 12_345e6);
        _borrow(aliceProxy, 7777e18);
        vm.warp(block.timestamp + 17 days);
    }

    function _assertBoundary(
        uint256 price
    ) internal {
        assertGt(price, 0, "a debt");
        _setVtPrice(int256(price));
        assertGe(_hf(aliceProxy), 1e18, "at the liquidation price: HF >= 1.00");
        _setVtPrice(int256(price - 1));
        assertLt(_hf(aliceProxy), 1e18, "one unit lower: HF < 1.00");
        _setVtPrice(2e8);
    }

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-047
    function test_TEST_247_liquidationPriceAfterABorrowIsExact() public {
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, usdcReserveId, 3_210_987_654);
        _borrowUsdc(aliceProxy, 3_210_987_654);
        _assertBoundary(v.liquidationPriceAfter);
        assertEq(v.liquidationPriceAfter, lens.getAccountRisk(alice, MARKET_ID).liquidationPrice, "getAccountRisk");
    }

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-047
    function test_TEST_247_liquidationPriceAfterARepayIsExact() public {
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, 1234e18);
        debt.mint(aliceProxy, 1234e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, 1234e18);
        (bool ok,) = aave.cdpSpoke
            .call(abi.encodeWithSignature("repay(uint256,uint256,address)", debtReserveId, 1234e18, aliceProxy));
        vm.stopPrank();
        assertTrue(ok, "repaid");
        _assertBoundary(v.liquidationPriceAfter);
        assertLt(v.liquidationPriceAfter, v.liquidationPriceBefore, "repaying lowers the liquidation price");
    }

    // TEST-247 verifies: REQ-LENS-053, REQ-LENS-047
    function test_TEST_247_liquidationPriceAfterAPledgeAndAWithdrawalIsExact() public {
        vault.mintPosition(_key(2), alice, MARKET_ID, 4321e6);
        ActionPreview memory v = lens.previewPledgeAfter(alice, MARKET_ID, _key(2));
        _pledge(alice, aliceProxy, _key(2), 4321e6);
        _assertBoundary(v.liquidationPriceAfter);
        v = lens.previewWithdrawAfter(alice, MARKET_ID, _key(2));
        _withdraw(aliceProxy, _key(2), 4321e6);
        _assertBoundary(v.liquidationPriceAfter);
    }

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-047
    function test_TEST_247_noLiquidationPriceOnceEverythingIsRepaid() public view {
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, type(uint256).max);
        assertEq(v.amount, _debtOf(aliceProxy, debtReserveId), "the whole debt");
        assertEq(v.liquidationPriceAfter, 0, "no debt, no liquidation price");
        assertEq(v.healthFactorAfter, type(uint256).max, "no debt, no health factor bound");
        assertGt(v.liquidationPriceBefore, 0, "there was one before");
        v = lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, 0);
        assertEq(v.liquidationPriceAfter, v.liquidationPriceBefore, "borrowing nothing changes nothing");
        assertEq(v.healthFactorAfter, v.healthFactorBefore, "same health factor");
    }
}
