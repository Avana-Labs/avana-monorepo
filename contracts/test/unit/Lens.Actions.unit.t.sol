// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {ActionPreview} from "../../src/lens/lens/types/ActionPreview.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LensActionsUnitTest
/// @notice `previewBorrowAfter`, `previewRepayAfter`, `previewPledgeAfter` and `previewWithdrawAfter` on the real Aave V4
/// Spoke and Collateralization: every health factor, liquidation price and debt value after equals what Aave reports
/// once the action has run in the same block, including after interest, with a risk premium, with two debts and after a
/// collateral-factor change.
/// forge-config: default.isolate = false
contract LensActionsUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    // ─── helpers ───

    function _repay(
        address proxy,
        uint256 reserveId,
        address asset,
        uint256 amount
    ) internal {
        CollPoolToken(asset).mint(proxy, amount);
        vm.startPrank(proxy);
        CollPoolToken(asset).approve(aave.cdpSpoke, amount);
        IAaveV4Spoke(aave.cdpSpoke).repay(reserveId, amount, proxy);
        vm.stopPrank();
    }

    /// @dev The preview's `after` half against Aave's account data and the Lens's own liquidation price, now.
    function _assertAfter(
        ActionPreview memory v,
        address wallet,
        address proxy
    ) internal view {
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy);
        assertEq(v.healthFactorAfter, a.healthFactor, "health factor after = Aave");
        assertEq(v.debtValueAfterRay, a.totalDebtValueRay, "debt value after = Aave");
        assertEq(v.collateralValueAfter, a.totalCollateralValue, "collateral value after = Aave");
        assertEq(v.liquidationPriceAfter, lens.getAccountRisk(wallet, MARKET_ID).liquidationPrice, "price after");
    }

    function _addCollateralFactor(
        uint16 cf
    ) internal {
        _spokeConfig(
            abi.encodeWithSignature("addCollateralFactor(address,uint256,uint16)", aave.cdpSpoke, vtReserveId, cf)
        );
    }

    // ─── borrow ───

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-005
    function test_TEST_247_borrowAfterEqualsAave() public {
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, 8000e18);
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.timestamp, block.timestamp, "time");
        assertEq(v.proxy, aliceProxy, "proxy");
        assertEq(v.amount, 8000e18, "amount");
        assertEq(v.healthFactorBefore, type(uint256).max, "no debt before");
        assertEq(v.liquidationPriceBefore, 0, "no debt, no liquidation price");
        assertEq(v.healthFactorAfter, 2e18, "$20,000 x 0.8 / $8,000");
        assertEq(v.liquidationPriceAfter, 1e8, "8,000 / (0.8 x 10,000) = $1.00");
        _borrow(aliceProxy, 8000e18);
        _assertAfter(v, alice, aliceProxy);
    }

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_secondBorrowAfterInterestOnAnotherReserve() public {
        _borrow(aliceProxy, 5000e18);
        vm.warp(block.timestamp + 200 days);
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, usdcReserveId, 3_333_123_456);
        assertEq(v.healthFactorBefore, _hf(aliceProxy), "before = Aave");
        assertEq(v.liquidationPriceBefore, lens.getAccountRisk(alice, MARKET_ID).liquidationPrice, "price before");
        _borrowUsdc(aliceProxy, 3_333_123_456);
        _assertAfter(v, alice, aliceProxy);
        assertLt(v.healthFactorAfter, v.healthFactorBefore, "borrowing lowers the health factor");
        assertGt(v.liquidationPriceAfter, v.liquidationPriceBefore, "and raises the liquidation price");
    }

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_borrowAfterUsesTheLatestCollateralFactor() public {
        _borrow(aliceProxy, 4000e18);
        // A new dynamic configuration at 70 %: the borrow refreshes the account to it.
        _addCollateralFactor(7000);
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, 1000e18);
        assertEq(v.healthFactorBefore, 4e18, "before: the account's own 80 %");
        assertEq(v.healthFactorAfter, 2.8e18, "after: 20,000 x 0.7 / 5,000");
        _borrow(aliceProxy, 1000e18);
        _assertAfter(v, alice, aliceProxy);
    }

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_borrowAfterForAWalletWithoutAccount() public view {
        ActionPreview memory v = lens.previewBorrowAfter(bob, MARKET_ID, debtReserveId, 100e18);
        assertEq(v.healthFactorBefore, type(uint256).max, "no account");
        assertEq(v.healthFactorAfter, 0, "debt against no collateral");
        assertEq(v.liquidationPriceAfter, type(uint256).max, "no collateral counted");
        assertEq(v.collateralValueAfter, 0, "no collateral");
        assertEq(v.debtValueAfterRay, 100e18 * 1e8 * 1e27, "100 GHO at $1 in value x RAY");
    }

    // ─── repay ───

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_partialRepayAfterEqualsAave() public {
        _borrow(aliceProxy, 6000e18);
        vm.warp(block.timestamp + 90 days);
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, 2500e18);
        assertEq(v.amount, 2500e18, "within the debt");
        _repay(aliceProxy, debtReserveId, address(debt), 2500e18);
        _assertAfter(v, alice, aliceProxy);
        assertGt(v.healthFactorAfter, v.healthFactorBefore, "repaying raises the health factor");
    }

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_repayAfterWithPremiumFirst() public {
        _spokeConfig(
            abi.encodeWithSignature("updateCollateralRisk(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, 2000)
        );
        _borrow(aliceProxy, 6000e18);
        vm.warp(block.timestamp + 365 days);
        (, uint256 premium) = _userDebt(aliceProxy, debtReserveId);
        assertGt(premium, 1, "a premium accrued");
        // Below the premium: only the premium falls.
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, premium / 2);
        _repay(aliceProxy, debtReserveId, address(debt), premium / 2);
        _assertAfter(v, alice, aliceProxy);
        // Above the premium: the premium clears and drawn shares are restored, rounded down.
        v = lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, 1000e18 + 7);
        _repay(aliceProxy, debtReserveId, address(debt), 1000e18 + 7);
        _assertAfter(v, alice, aliceProxy);
    }

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_repayAllAfterLeavesTheOtherDebt() public {
        _borrow(aliceProxy, 3000e18);
        _borrowUsdc(aliceProxy, 2000e6);
        vm.warp(block.timestamp + 30 days);
        uint256 total = _debtOf(aliceProxy, debtReserveId);
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, type(uint256).max);
        assertEq(v.amount, total, "repaid = the whole debt");
        _repay(aliceProxy, debtReserveId, address(debt), total);
        assertEq(_debtOf(aliceProxy, debtReserveId), 0, "GHO cleared");
        _assertAfter(v, alice, aliceProxy);
        v = lens.previewRepayAfter(alice, MARKET_ID, usdcReserveId, type(uint256).max);
        assertEq(v.healthFactorAfter, type(uint256).max, "nothing owed after");
        assertEq(v.liquidationPriceAfter, 0, "no liquidation price");
        assertEq(v.debtValueAfterRay, 0, "no debt");
    }

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_repayAfterWithoutDebtChangesNothing() public view {
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, usdcReserveId, 100e6);
        assertEq(v.amount, 0, "nothing to repay");
        assertEq(v.healthFactorAfter, type(uint256).max, "no debt");
        assertEq(v.collateralValueAfter, 20_000e26, "$20,000");
    }

    // ─── pledge ───

    // TEST-247 verifies: REQ-LENS-053
    function test_TEST_247_pledgeAfterEqualsAave() public {
        _borrow(aliceProxy, 9000e18);
        vault.mintPosition(_key(2), alice, MARKET_ID, 5000e6);
        ActionPreview memory v = lens.previewPledgeAfter(alice, MARKET_ID, _key(2));
        assertEq(v.amount, 5000e6, "the position's units");
        assertEq(v.healthFactorAfter, uint256(24_000e18) / 9000, "30,000 x 0.8 / 9,000");
        _pledge(alice, aliceProxy, _key(2), 5000e6);
        _assertAfter(v, alice, aliceProxy);
        assertGt(v.healthFactorAfter, v.healthFactorBefore, "pledging raises the health factor");
    }

    // TEST-247 verifies: REQ-LENS-053
    function test_TEST_247_pledgeAfterKeepsTheAccountsFactorAndFirstPledgeTakesTheLatest() public {
        _borrow(aliceProxy, 4000e18);
        _addCollateralFactor(6000);
        vault.mintPosition(_key(2), alice, MARKET_ID, 10_000e6);
        ActionPreview memory v = lens.previewPledgeAfter(alice, MARKET_ID, _key(2));
        assertEq(v.healthFactorAfter, 8e18, "40,000 x 0.8 / 4,000: supply keeps the account's key");
        _pledge(alice, aliceProxy, _key(2), 10_000e6);
        _assertAfter(v, alice, aliceProxy);
        // A first pledge enables the collateral, which moves the new account to the latest factor.
        adapterMock.bind(bob, bobProxy, aave.cdpSpoke, MARKET_ID, vt, vtReserveId);
        vault.mintPosition(_key(3), bob, MARKET_ID, 1000e6);
        v = lens.previewPledgeAfter(bob, MARKET_ID, _key(3));
        assertEq(v.collateralValueAfter, 2000e26, "$2,000");
        assertEq(v.healthFactorAfter, type(uint256).max, "no debt");
        _pledge(bob, bobProxy, _key(3), 1000e6);
        _assertAfter(v, bob, bobProxy);
    }

    // TEST-247 verifies: REQ-LENS-053
    function test_TEST_247_pledgeAfterRevertsForAnotherOwner() public {
        vault.mintPosition(_key(2), bob, MARKET_ID, 1000e6);
        vm.expectRevert(bytes("NotTokenOwner"));
        lens.previewPledgeAfter(alice, MARKET_ID, _key(2));
    }

    // ─── withdraw ───

    // TEST-247 verifies: REQ-LENS-053
    function test_TEST_247_withdrawAfterEqualsAave() public {
        _pledge(alice, aliceProxy, _key(2), 6000e6);
        _borrow(aliceProxy, 7000e18);
        ActionPreview memory v = lens.previewWithdrawAfter(alice, MARKET_ID, _key(2));
        assertEq(v.amount, 6000e6, "the record's credited units");
        assertEq(v.healthFactorAfter, uint256(16_000e18) / 7000, "20,000 x 0.8 / 7,000");
        _withdraw(aliceProxy, _key(2), 6000e6);
        _assertAfter(v, alice, aliceProxy);
    }

    // TEST-247 verifies: REQ-LENS-053
    function test_TEST_247_withdrawAfterUsesTheLatestFactorAndIgnoresForeignRecords() public {
        _pledge(alice, aliceProxy, _key(2), 6000e6);
        _borrow(aliceProxy, 3000e18);
        _addCollateralFactor(5000);
        ActionPreview memory v = lens.previewWithdrawAfter(alice, MARKET_ID, _key(2));
        assertEq(v.healthFactorAfter, uint256(10_000e18) / 3000, "the withdrawal refreshes the key to 50 %");
        _withdraw(aliceProxy, _key(2), 6000e6);
        _assertAfter(v, alice, aliceProxy);
        // Bob's record is not Alice's: nothing to withdraw, the account's own factor stays.
        _open(bob, bobProxy, 9, 1000e6);
        v = lens.previewWithdrawAfter(alice, MARKET_ID, _key(9));
        assertEq(v.amount, 0, "not her record");
        assertEq(v.healthFactorAfter, v.healthFactorBefore, "unchanged");
        assertEq(lens.previewWithdrawAfter(alice, MARKET_ID, _key(77)).amount, 0, "no record");
    }

    // ─── failures ───

    // TEST-247 verifies: REQ-LENS-006, REQ-LENS-021, REQ-LENS-022, REQ-LENS-032
    function test_TEST_247_actionPreviewsRevertWhenLockedOrUnknown() public {
        _holdLock();
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, 1);
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, 1);
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.previewPledgeAfter(alice, MARKET_ID, _key(1));
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.previewWithdrawAfter(alice, MARKET_ID, _key(1));
        _releaseLock();
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 99));
        lens.previewBorrowAfter(alice, 99, debtReserveId, 1);
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 77));
        lens.previewBorrowAfter(alice, MARKET_ID, 77, 1);
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 77));
        lens.previewRepayAfter(alice, MARKET_ID, 77, 1);
    }

    function _userDebt(
        address proxy,
        uint256 reserveId
    ) internal view returns (uint256 drawn, uint256 premium) {
        (bool ok, bytes memory ret) =
            aave.cdpSpoke.staticcall(abi.encodeWithSignature("getUserDebt(uint256,address)", reserveId, proxy));
        require(ok, "getUserDebt");
        (drawn, premium) = abi.decode(ret, (uint256, uint256));
    }
}
